Assisted-by: Pi · GLM 5.3 Flash <pi-opencodego-glm53flash@local>
(provenance companion: [1788146135433-drop-fixture-map-in-file-state.prompts.md](./1788146135433-drop-fixture-map-in-file-state.prompts.md);
prior state: [1788107876077-handoff-chutes-opencodego-state.md](./1788107876077-handoff-chutes-opencodego-state.md))

# Proposal — drop the `fixtures` map; fixture files carry their own state; hashes deleted

Written 2026-08-31 by the live pi session (glm-5.3-flash × opencode-go).
Status: **proposal — awaiting decision on §4 (the launch-argv home) before
implementation.** Everything else in this document is settled by the
user's directive.

## 1. Problem — the row table duplicates the fixtures

`fixtures/.index.json` today has three tables. Two of them (`queue`,
`errors`) hold information that exists nowhere else. The third
(`fixtures`, 527 rows) holds information that is *derivable from, or
duplicated by, the fixture files themselves*:

| Row property | Duplicates / mirrors | Verdict |
|---|---|---|
| `identity.declared_at` | the existence of the file's `from-identity` channel — the channel WAS the declaration | move into the channel |
| `capture.captured_at` | ditto for `from-capture` | move into the channel |
| `capture.harness_version` | already emitted in `from-capture-raw.harness_version` | move into the capture channel (raw keeps its "not yet knowable" null) |
| `agent_detect_version` | per-writer provenance; nothing else records it | move into the file |
| `runner` (writer pid) | provenance of a dead process; git history covers attribution | **drop from fixture files**; persists only on queue entries (`QueueEntry.runner` unchanged) |
| `identity.channel_hash` | BLAKE3 of content already in the file | **drop** |
| `capture.channel_hash` | ditto | **drop** |
| `fixture_hash` | BLAKE3 of the whole file — mirrors the file | **drop** |
| `prompt_launch` / `version_launch` | curated serving spellings; partially duplicates `.providers_models.csv` | **§4 decision** |

Costs of the current shape, concretely:

- **Write amplification**: every capture/declaration merges into the
  fixture file AND locks/reloads/mutates/atomically-saves
  `.index.json` (`withFixtureRowUpdate`). The store is the noisiest
  file in git ("store dirties on every mutation; commit when work
  lands" — CONTRIBUTING).
- **Hash upkeep**: three hash fields stamped per write, compared by
  two staleness markers, asserted by one test
  (`index.json: fixture_hash equals the BLAKE3…`), documented in the
  schema — all to answer questions the files can answer directly
  (§3 keeps the one genuinely useful check without hashes).
- **Two sources of truth for "what happened"**: the ledgers say
  *when* a channel was written; the file says *what* was written.
  They can disagree (the divergence markers exist precisely because
  they do).

## 2. Non-goals

- The `queue` and `errors` tables stay in `.index.json` unchanged in
  shape (they hold non-derivable state).
- The free axis stays in `.providers_freemodels.csv`.
- The daemon pop protocol (one candidate per poll, done rule,
  crash-resume) is preserved semantically — its inputs change source,
  not meaning.
- No detection-surface changes: `src/lib/*` and the released binary
  are untouched. This is a dev/fixtures-surface + store refactor.

## 3. What every fixture file will carry (settled)

New envelope, applied to all 177 existing files:

```jsonc
{
  // NEW top-level meta object — replaces the row's non-channel fields
  "fixture": {
    "agent_detect_version": "2026.8.11-3"   // last writer wins
    // §4: prompt_launch / version_launch live here OR stay in the store
  },
  "from-identity": {
    "identify": { /* 18-field contract, unchanged */ },
    "trailer co-author": "…",
    "trailer assisted-by": "…",
    "declared_at": 1788143986               // NEW: was identity.declared_at
  },
  "from-capture": {
    "identify": { /* … */ },
    "trailer co-author": "…",
    "trailer assisted-by": "…",
    "captured_at": 1788143986,              // NEW: was capture.captured_at
    "harness_version": "0.84.4"             // NEW: was capture.harness_version
  },
  "from-capture-raw": { /* unchanged, including its own harness_version */ }
}
```

Deleted outright: `runner`, `channel_hash` (×2), `fixture_hash`.
The store's `IdentityLedger` / `CaptureLedger` / `FixtureRow` types
die with the map. Note: `runner` is dropped from fixture files only —
queue entries keep their `runner` (enqueueing-pid provenance) exactly
as today.

**Drift check survives, hash-free.** `--stale-by-channel-hash`
(tested by `channelHashDivergent`) becomes `--stale-by-channel-drift`:
stale iff both channels exist and their `identify` objects are not
deep-equal (a missing channel counts stale, same as today). The
identify payload is the semantic core; the trailers derive from it
deterministically, and the raw block is excluded by design already.
No hash needed to compare two objects you are about to load anyway.

**Marker matrix**:

| Marker | Fate |
|---|---|
| `--stale-by-missing-entry` | **dropped** — no entry table to miss; the file IS the registration |
| `--stale-by-missing-fixture` | **dropped** — the store no longer references files |
| `--stale-by-fixture-hash` | **dropped** — hash gone |
| `--stale-by-channel-hash` | **replaced** by `--stale-by-channel-drift` (§3) |
| `--stale-by-minutes/hours/days` | kept — dates now read from the file's channels |
| `--stale-by-harness-version` | kept — `from-capture.harness_version` |
| `--stale-by-detect-version` | kept — `fixture.agent_detect_version` |

## 4. OPEN DECISION — where curated launch argv lives

The row table's one non-derivable property is `prompt_launch` /
`version_launch` (curated serving spellings + per-harness flag
conventions). Inventory: **502 of 527 rows** carry argv; **350 rows
have no fixture file** (mostly linux/windows of the cross-product,
plus darwin rows queued but never run). The argv encodes real data —
provider-prefixed model ids (`cline-pass/kimi-k3`,
`openrouter/deepseek-v4-flash`), free-tier spellings
(`google/gemma-4-31b-it:free`) — not derivable from the rule slugs
alone.

**Minimal-invocation policy (user steering, 2026-08-31):** curated
invocations carry only the arguments *necessary* to pin harness +
provider + model and run the capture prompt. Extra flags that merely
alter runtime behaviour (observed: cline's `--thinking` on the
deepseek row) are **dropped unless documented as necessary** by the
harness for the invocation to work. The migration audits all 502
curated rows against this policy and minimizes offenders; under
option C the exception table shrinks to (ideally) empty.

### Option A — stub files (the literal ask)

Everything moves into fixture files. The 350 file-less rows become
**stub files** carrying only `"fixture": { prompt_launch,
version_launch }`. The known universe = the set of fixture files
(stubs included).

```jsonc
// fixtures/pi-chutes-kimik3-darwin.json — a stub
{ "fixture": { "prompt_launch": ["pi","--provider","chutes","--model","moonshotai/Kimi-K3-TEE","-p","<prompt>"],
               "version_launch": ["pi","--version"] } }
```

- ✅ Single home; the store shrinks to `store_version` + `errors` +
  `queue`. No state for a fixture exists outside its file.
- ✅ Curated argv becomes per-combo reviewable in PRs next to its
  fixture.
- ✅ Expansion is a directory scan — no store lock for candidate
  enumeration.
- ❌ ~350 new tiny files in one sweep (repo grows ~1k lines of JSON
  stubs; `fixtures/` listing goes from 177 to ~530 entries).
- ❌ "Fixture exists" no longer implies "identification ran" — the
  envelope test and coverage tests must treat stubs as a third class.
- ❌ Curating a not-yet-run combo = committing a stub (fine, but it
  makes the store's queue the only place left holding "intent").

### Option B — ledgers move, argv stays (slimmest change)

`declared_at` / `captured_at` / `harness_version` /
`agent_detect_version` move into files exactly as §3. The row table
dies, but curated argv moves into a dedicated store table
(`launch`: `Record<FixtureId, {prompt_launch?, version_launch?}>`)
or a `fixtures/.launch.csv` grid alongside the other grids.

- ✅ No stub files; files exist only when an identification ran.
- ✅ Store keeps only non-derivable state (launch + errors + queue) —
  the "overkill" objection is met: hashes, ledgers, runner gone.
- ❌ Not the literal ask: launch argv stays in the store.
- ❌ Two files still change per capture? No — capture writes only the
  fixture file; launch argv is written at curation time. Store
  dirtying drops the same as A.

### Option C — derive argv; store nothing (kills the treadmill)

Encode a per-harness launch template on `HarnessRule`
(`capture_argv` pattern: argv slots + where provider/model spellings
go), pull serving spellings from `.providers_models.csv` (+ the
harness→provider grid), keep per-combo flag extras as a tiny
exception table. The 502 curated rows are then the *verification
corpus*: a test asserts derivation reproduces every curated argv
exactly, after which the argv data is deleted everywhere.

- ✅ No stubs, no launch table, no store dirtying; the handoff's
  standing chore ("Launch argv curation" follow-up #3) dies as a
  class — new combos need zero curation when the grids already hold
  the spelling.
- ✅ The known universe becomes fully derivable: rules × grids −
  errors. The queue's `known=false` sweep and `known=true` sweep
  converge.
- ❌ Largest scope: touches `rules.zig` (released surface, albeit
  data-only), needs per-provider prefix conventions + exception
  table; risk of subtle argv drift on 14 harnesses.
- ❌ Serving spellings missing from the grids block curation until
  the grid row is added (the chutes spellings are already there —
  all 14 — but several openrouter/others may need grid completion).

### Recommendation

**B now, C later.** B is the smallest change that fully answers the
"overkill" objection: hashes, ledgers, runner, and the row table all
die tonight; the launch table is the one piece of genuinely
non-derivable data and keeps a single obvious home. C remains a clean
follow-up (its verification corpus is exactly the B-era launch
table) and can be adopted per-harness incrementally. A's 350 stubs
buy single-homedness at the cost of real repo noise for data the
daemon reads once per expansion.

## 5. Code-impact inventory

**`src/dev/dev.zig`** (the whole change is inside the dev struct):

- Deleted: `FixtureRow`, `FixtureUpdate`, `fixtureRowFromMap`,
  `fixtureRowValue`, `defaultRow`, `fixtureRowUpdatePure`,
  `withFixtureRowUpdate`, `fixtureRowByKey`, `channelJson`'s hash
  role (kept, now writes ledger fields inline),
  `generationHash` (only if no other caller),
  `channelHashDivergent` (replaced by identify deep-compare),
  `expandMissingEntryPlatform`, `runMissingEntryRegistration`,
  the `registration` update variant, markers
  `stale_by_missing_entry` / `stale_by_missing_fixture` /
  `stale_by_fixture_hash` / `stale_by_channel_hash` (CLI flags,
  QueueEntry fields, conflict matrix slots, usage text).
- Changed: `expandKnownPlatform` iterates `fixtures/*.json` (stem →
  dims; stub file ⇒ candidate with no channels);
  `entryMarkerStale` + `completionTimestamp` read the loaded file;
  capture/identity writers write `declared_at`/`captured_at`/
  `harness_version`/`fixture.agent_detect_version` inline via
  `mergeWriteFixture` and drop the row-stamp step; `errors` ledger
  unchanged; `INDEX_STORE_VERSION` → 2 with load-time drop of the
  legacy `fixtures` table (same pattern as the dropped
  `free_provider_to_model`).
- New: fixture-file loader (`loadFixtureFile` — parse stem + channels
  + meta into a slim `FixtureFile` struct), identify deep-compare.

**Tests**:

- `src/index_store.test.zig`: rework helpers (rows → in-memory file
  shapes); delete hash/divergence tests; add identify-drift and
  stub-file expansion tests; done-rule tests re-source dates.
- `src/known_fixtures.test.zig`: envelope test accepts the `fixture`
  key + inline ledger fields; `index.json` tests — `fixture_hash`
  test deleted, `prompt_launch` tests re-point at §4's chosen home,
  store_version → 2, coverage tests scan files instead of rows.

**Schema/docs**: `fixtures/.index.d.ts` slimmed (errors + queue +
launch table per §4); new `fixtures/fixture.d.ts` as the normative
fixture-envelope schema; DESIGN.md "index.json state store" rewritten
semantics-only; CONTRIBUTING.md curation/doctrine paragraphs updated.

**Migration** (one-off, committed separately from the code):

1. Land code reading the NEW shape (store_version 2, drop-on-load of
   legacy tables) — back-compat by drop, not by dual-read.
2. One-off pass (python, then `zig build test` green): merge
   `declared_at`/`captured_at`/`harness_version`/`agent_detect_version`
   into the 177 files; apply §4 choice to the 502 argv rows,
   **minimizing non-essential flags per the minimal-invocation
   policy** (§4); rewrite `.index.json` without the `fixtures` table
   (queue `runner` fields untouched).
3. Re-queue pi-chutes captures (tonight's original goal) and commit.

## 6. Verification

- `zig build && zig build dev && zig build test` fully green (the
  two currently-red tests are expected green after the migration
  half, since file-scan coverage replaces row coverage).
- `fixtures capture` re-run on this session must produce the same
  canonical output as the committed fixture modulo the new envelope.
- Daemon smoke: `--stale-by-minutes=0` sweep must list all 12
  pi-chutes candidates and nothing else; a full drain of
  from-identity entries must complete with zero token spend.
