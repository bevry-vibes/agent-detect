Assisted-by: Pi · GLM 5.3 Flash <pi-opencodego-glm53flash@local>
(provenance companion: [1788146135433-drop-fixture-map-in-file-state.prompts.md](./1788146135433-drop-fixture-map-in-file-state.prompts.md);
prior state: [1788107876077-handoff-chutes-opencodego-state.md](./1788107876077-handoff-chutes-opencodego-state.md))

# Proposal — retire the `fixtures` map: per-channel fixture files, per-folder layout, hashes deleted

Written 2026-08-31 by the live pi session (glm-5.3-flash × opencode-go).
Status: **fleshed-out proposal — two open decisions (§5 argv home,
plus sign-off on §4's folder split) before implementation.**
Everything else is settled by user directives (see companion).

## 1. Problem — the row table duplicates the fixtures

`fixtures/.index.json` today has three tables. Two of them (`queue`,
`errors`) hold information that exists nowhere else. The third
(`fixtures`, 527 rows) holds information that is *derivable from, or
duplicated by, the fixture files themselves*:

| Row property | Duplicates / mirrors | Verdict |
|---|---|---|
| `identity.declared_at` | the existence of the declared channel — the channel WAS the declaration | move into the identity file |
| `capture.captured_at` | ditto for the captured channel | move into the capture file |
| `capture.harness_version` | already emitted in the raw block's `harness_version` | move into the capture file (raw keeps its "not yet knowable" null) |
| `agent_detect_version` | per-writer provenance; nothing else records it | move into each channel file (the version that wrote THAT channel — more precise than the row's last-writer-wins single field) |
| `runner` (writer pid) | provenance of a dead process; git history covers attribution | **dropped from fixture files**; persists only on queue entries (`QueueEntry.runner` unchanged) |
| `identity.channel_hash` | BLAKE3 of content already in the file | **drop** |
| `capture.channel_hash` | ditto | **drop** |
| `fixture_hash` | BLAKE3 of the whole file — mirrors the file | **drop** |
| `prompt_launch` / `version_launch` | curated serving spellings; partially duplicates `.providers_models.csv` | **§5 decision** |

Costs of the current shape, concretely:

- **Write amplification**: every capture/declaration merges into the
  fixture file AND locks/reloads/mutates/atomically-saves
  `.index.json` (`withFixtureRowUpdate`). The store is the noisiest
  file in git ("store dirties on every mutation; commit when work
  lands" — CONTRIBUTING).
- **Hash upkeep**: three hash fields stamped per write, compared by
  two staleness markers, asserted by one test, documented in the
  schema — all to answer questions the files can answer directly
  (§6 keeps the one genuinely useful check without hashes).
- **Two sources of truth for "what happened"**: the ledgers say
  *when* a channel was written; the file says *what* was written.
  They can disagree (the divergence markers exist precisely because
  they do).

## 2. Non-goals

- The `queue` and `errors` tables stay in `.index.json` unchanged in
  shape (they hold non-derivable state), including `QueueEntry.runner`.
- The free axis stays in `.providers_freemodels.csv`.
- The daemon pop protocol (one candidate per poll, done rule,
  crash-resume) is preserved semantically — its inputs change source,
  not meaning.
- No detection-surface changes: `src/lib/*` and the released binary
  are untouched. This is a dev/fixtures-surface + store refactor.
- No fixture *content* changes: the 18-field `identify` contract, the
  trailer derivations, and the raw block's keys are frozen by this
  plan (only their envelope moves).

## 3. Per-channel file design (settled)

Each channel becomes a whole self-contained file, owned exclusively
by its writer. No merge-write: a channel writer serializes its entire
file and atomically replaces it (temp + rename stays; the store lock
is only for `.index.json`).

### 3a. The identity file — `fixtures/identity/<fixture-id>.json`

Written by the from-identity worker (declared generation; zero
tokens; recipe-mode detection against the rule tables).

```jsonc
{
  "identify": { /* the 18-field contract, unchanged */ },
  "trailer co-author": "Co-authored-by: Pi · GLM 5.3 Flash <…>",
  "trailer assisted-by": "Assisted-by: Pi · GLM 5.3 Flash <…>",
  "declared_at": 1788143986,              // was identity.declared_at
  "agent_detect_version": "2026.8.11-3"   // the version that declared it
}
```

### 3b. The capture file — `fixtures/captures/<fixture-id>.json`

Written by `fixtures capture` inside a live session (token-consuming)
or the daemon's from-capture worker.

```jsonc
{
  "identify": { /* the 18-field contract, unchanged */ },
  "trailer co-author": "…",
  "trailer assisted-by": "…",
  "captured_at": 1788143986,              // was capture.captured_at
  "harness_version": "0.84.4",            // was capture.harness_version
  "agent_detect_version": "2026.8.11-3",
  "raw": { /* the from-capture-raw block verbatim, including its own
             platform_id, process_lineage, evidence, *_urls, and its
             "not yet knowable" harness_version */ }
}
```

Optional provenance field (small, recommended): `capture` also stamps
`invoked_by: ["pi","--provider",…,"-p","<prompt> redacted>"]` — the
launch argv that produced the session. This lets a launch stub be
deleted once a capture exists without losing the curation record
(interacts with §5 option A).

### 3c. What disappears

`runner`, `channel_hash` (×2), `fixture_hash`, the
`IdentityLedger`/`CaptureLedger`/`FixtureRow` types, and the
read-modify-write merge of two channels into one file. The channel
key prefixes (`from-identity` / `from-capture`) also die — the folder
is the channel, so file-internal keys lose the prefix.

## 4. OPEN — folder split (recommended: yes)

Two layouts considered for the file universe:

| | **4a. Two folders** (recommended) | 4b. Single folder, channel keys inside |
|---|---|---|
| Path shape | `fixtures/identity/<id>.json`, `fixtures/captures/<id>.json` | `fixtures/<id>.json` with top-level `identity` / `capture` keys |
| Writer contention | none — each channel owns a file; declaration and capture never touch the same bytes | read-modify-write merge per write (today's `mergeWriteFixture`) |
| Drift check | compare two files' `identify` objects | compare two keys in one file |
| Git semantics | identity churn and capture churn isolated per file; PR review sees exactly which channel changed | one file churns from both sides |
| Channel-state enumeration | scan a folder; channel presence = file existence (no JSON parse needed for "has this channel run?") | parse every file to know channel presence |
| Crash safety | a torn write can only damage one channel | a torn merge can clobber the other channel's data |
| Partial combos | a combo can exist in one folder only — first-class | same, but implied by key presence |
| Repo | ~177 files → ~354 (each two-channel file becomes two) | unchanged count |

4a wins on every mechanical axis; its only cost is file count and a
one-time migration split. The `discoverStems` dotfile-skip rule keeps
the grids and `.index.json` coexisting inside `fixtures/` (they are
dotfiles; the new subdirectories are not scanned as fixtures — only
`fixtures/identity/*` and `fixtures/captures/*` are).

Test-corpus note: the envelope/shape tests in
`src/known_fixtures.test.zig` scan `fixtures/*.json` today; they
re-point at the two folders with per-folder assertions (§8).

## 5. OPEN DECISION — where curated launch argv lives

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

### Option A — launch folder (stubs in their own folder)

Curated argv becomes a third file class: `fixtures/launch/<id>.json`.

```jsonc
// fixtures/launch/pi-chutes-kimik3-darwin.json — a stub
{
  "prompt_launch": ["pi","--provider","chutes","--model","moonshotai/Kimi-K3-TEE","-p","<prompt>"],
  "version_launch": ["pi","--version"]
}
```

The known universe = `identity/ ∪ captures/ ∪ launch/` filename
stems. On a successful capture, the stub is deleted — its content is
preserved as the capture file's `invoked_by` (§3b).

- ✅ Single home per artifact; the store shrinks to `store_version` +
  `errors` + `queue`. No state for a fixture exists outside
  `fixtures/`.
- ✅ Symmetric with the folder split: three folders, three file
  schemas, one enumeration rule ("known universe = union of folder
  stems").
- ✅ Curated argv becomes per-combo reviewable in PRs.
- ❌ ~350 new stub files (repo grows ~1k lines of JSON stubs;
  `fixtures/` goes from 177 files + 3 dirs to ~530 files + 3 dirs).
- ❌ Stub deletion-on-capture adds a write step to the capture worker
  (and a race rule: daemon-captured combos delete their stub
  idempotently).

### Option B — launch table in the store (slimmest change)

`declared_at` / `captured_at` / `harness_version` /
`agent_detect_version` move into the per-channel files exactly as §3.
The row table dies, but curated argv moves into a dedicated store
table (`launch: Record<FixtureId, {prompt_launch?, version_launch?}>`).
Known universe = launch-table keys ∪ identity stems ∪ capture stems.

- ✅ No stub files; folders contain only real identifications.
- ✅ Store keeps only non-derivable state (launch + errors + queue) —
  the "overkill" objection is met: hashes, ledgers, runner gone.
- ✅ Curation does not touch `fixtures/` subfolders; store writes are
  already locked/atomic.
- ❌ Not the literal "move its properties into their fixture files"
  for the argv half (the ledger half is).
- ❌ The known universe spans two sources (store table + folder
  scans) — marginally more expansion code than A's pure scan.

### Option C — derive argv; store nothing (kills the treadmill)

Encode a per-harness launch template on `HarnessRule`
(`capture_argv` pattern: argv slots + where provider/model spellings
go), pull serving spellings from `.providers_models.csv` (+ the
harness→provider grid), keep per-combo flag extras as a minimal
exception table (empty under the minimal-invocation policy). The 502
curated rows are then the *verification corpus*: a test asserts
derivation reproduces every curated argv exactly, after which the
argv data is deleted everywhere.

- ✅ No stubs, no launch table, no store dirtying; the handoff's
  standing chore ("Launch argv curation" follow-up #3) dies as a
  class — new combos need zero curation when the grids already hold
  the spelling.
- ✅ The known universe becomes fully derivable: rules × grids −
  errors. The queue's `known=false` sweep and `known=true` sweep
  converge into one sweep.
- ❌ Largest scope: touches `rules.zig` (released surface, albeit
  data-only), needs per-provider prefix conventions; risk of subtle
  argv drift on 14 harnesses.
- ❌ Serving spellings missing from the grids block curation until
  the grid row is added (chutes is fully covered — all 14 — but
  several openrouter/others may need grid completion).

### Recommendation

**B now, C later.** B is the smallest change that fully answers the
"overkill" objection: hashes, ledgers, runner, and the row table all
die; the launch table is the one piece of genuinely non-derivable
data with a single obvious home. C remains a clean follow-up (the
B-era launch table is exactly C's verification corpus) and can be
adopted per-harness incrementally. A's ~350 stubs buy store-free
argv at the cost of real repo noise for data the daemon reads once
per expansion — and A's stub-deletion step adds machinery B and C
don't need.

## 6. Staleness markers — final matrix

| Marker | Fate |
|---|---|
| `--stale-by-missing-entry` | **dropped** — no entry table; the file IS the registration |
| `--stale-by-missing-fixture` | **dropped** — the store no longer references files |
| `--stale-by-fixture-hash` | **dropped** — hash gone |
| `--stale-by-channel-hash` | **replaced** by `--stale-by-channel-drift`: stale iff both channel files exist and their `identify` objects are not deep-equal, OR a channel file is missing (same semantics as `channelHashDivergent`, hash-free) |
| `--stale-by-minutes` / `--stale-by-hours` / `--stale-by-days` | kept — mode-scoped: `identity/<id>.json.declared_at` for from-identity, `captures/<id>.json.captured_at` for from-capture |
| `--stale-by-harness-version` | kept — `captures/<id>.json.harness_version` vs the live `version_launch` probe |
| `--stale-by-detect-version` | kept — the channel file's `agent_detect_version` vs this binary's version |

Done rule / crash-resume: unchanged — completion timestamp is the
mode's own channel date (now read from the mode's own file), else
`errors.<key>.failed_at`.

## 7. Code-impact inventory

**`src/dev/dev.zig`** (the whole change is inside the dev struct):

- Deleted: `FixtureRow`, `FixtureUpdate`, `fixtureRowFromMap`,
  `fixtureRowValue`, `defaultRow`, `fixtureRowUpdatePure`,
  `withFixtureRowUpdate`, `fixtureRowByKey`, `mergeWriteFixture`'s
  merge semantics (becomes plain whole-file writes per folder),
  `channelHashDivergent` (replaced by identify deep-compare),
  `expandMissingEntryPlatform`, `runMissingEntryRegistration`, the
  `registration` update variant, markers `stale_by_missing_entry` /
  `stale_by_missing_fixture` / `stale_by_fixture_hash` /
  `stale_by_channel_hash` (CLI flags, `QueueEntry` fields, conflict
  matrix slots, usage texts), `generationHash` (if no other caller).
- New: `loadFixtureFile` (path → slim `ChannelFile` struct: dims from
  stem, `identify`, trailers, ledger fields); `identityPathFor` /
  `capturesPathFor` path helpers; identify deep-compare
  (`identifyEqual` — canonical stringify + mem.eql).
- Changed: `expandKnownPlatform` enumerates
  `fixtures/identity/` + `fixtures/captures/` (+ launch source per
  §5); `entryMarkerStale` + `completionTimestamp` read the loaded
  channel file; the capture writer (`runFixturesCapture`) and the
  daemon's identity worker write their whole file atomically and
  drop the row-stamp step; `INDEX_STORE_VERSION` → 2 with load-time
  drop of the legacy `fixtures` table (same pattern as the dropped
  `free_provider_to_model`); usage texts (`fixturesUsage`,
  `queueDequeueFlags`, `queueUsage`, `dequeueUsage`) updated for the
  marker matrix and the folder layout.
- Unchanged: daemon guard, pop protocol order, errors ledger, free
  grid, `--free` axis.

**Tests**:

- `src/index_store.test.zig`: helpers rebuild in-memory stores with
  the new shape; done-rule tests re-source dates from channel files;
  identify-drift tests replace hash-divergence tests; stub/launch
  tests per §5 choice.
- `src/known_fixtures.test.zig`: envelope tests re-point at
  `fixtures/identity/` (18-field identify + trailers + declared_at +
  agent_detect_version, nothing else) and `fixtures/captures/`
  (+ captured_at + harness_version + raw block); combo-match test
  runs per folder; the `fixture_hash` BLAKE3 test is deleted;
  `prompt_launch` tests re-point at §5's chosen home; store_version
  test → 2; coverage tests ("every provider/model rule appears in ≥1
  row") scan folder stems instead of store rows.

**Schema/docs**:

- `fixtures/.index.d.ts`: slimmed to `store_version` + `errors` +
  `queue` (+ `launch` table per §5); `FixtureRow`, ledgers, hash
  fields removed.
- NEW `fixtures/fixture.d.ts`: normative schemas for
  `IdentityFile`, `CaptureFile` (+ `LaunchFile` under option A) —
  the user asked for an additional schema for fixture files; this is
  it.
- DESIGN.md "index.json state store" rewritten semantics-only with a
  pointer to the schemas; CONTRIBUTING.md curation/doctrine
  paragraphs updated (minimal-invocation policy written up there).

## 8. Migration (one-off, committed separately from the code)

1. Land the code reading the NEW shape (store_version 2, drop-on-load
   of legacy tables) — back-compat by drop, not dual-read.
2. One-off pass (python, then `zig build test` green):
   - split the 177 fixture files into `identity/` + `captures/`
     (per channel present), inlining
     `declared_at`/`captured_at`/`harness_version`/
     `agent_detect_version` from the row table and dropping all
     hash fields;
   - apply the §5 choice to the 502 argv rows, **minimizing
     non-essential flags per the minimal-invocation policy** (§5);
   - rewrite `.index.json` without the `fixtures` table (queue
     `runner` fields untouched).
3. Re-queue the pi-chutes captures (tonight's original goal) and
   commit.

Ordering note: the migration script must run with the store lock
held (no daemon active); the plan is committed before this step per
plans.md.

## 9. Verification

- `zig build && zig build dev && zig build test` fully green (the
  two currently-red tests are expected green after the migration
  half, since folder-stem coverage replaces row coverage).
- `fixtures capture` re-run on this session must produce the same
  canonical identify output as the committed pre-split fixture
  (`pi-opencodego-glm53flash-darwin`), modulo the new envelope.
- Daemon smoke: a `--stale-by-minutes=0` from-capture sweep listing
  `--harness=pi --provider=chutes` must list exactly the 12 pi-chutes
  darwin candidates; a from-identity drain must complete with zero
  token spend.

## 10. Decision checklist

1. §4 folder split — recommended **yes** (two folders).
2. §5 launch-argv home — recommended **B** (slim store table) now,
   C as an incremental follow-up.
3. §3b `invoked_by` provenance stamp — recommended **yes** (tiny;
   makes A's stub-deletion or B's future stub-free curation lossless).
