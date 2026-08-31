Assisted-by: Pi · GLM 5.3 Flash <pi-opencodego-glm53flash@local>
(provenance companion: [1788146135433-drop-fixture-map-in-file-state.prompts.md](./1788146135433-drop-fixture-map-in-file-state.prompts.md);
prior state: [1788107876077-handoff-chutes-opencodego-state.md](./1788107876077-handoff-chutes-opencodego-state.md))

# Plan — retire the `fixtures` map: per-channel folders, outputs/meta envelope, hashes deleted

Written 2026-08-31 by the live pi session (glm-5.3-flash × opencode-go).
Status: **all design decisions resolved by user steering — ready to
implement.** The earlier open questions (§4 folder split, §5 argv
home, provenance stamp) were closed in the steering round; see the
companion for the verbatim directives.

## 1. Problem — the row table duplicates the fixtures

`fixtures/.index.json` today has three tables. Two of them (`queue`,
`errors`) hold information that exists nowhere else. The third
(`fixtures`, 527 rows) holds information that is *derivable from, or
duplicated by, the fixture files themselves*:

| Row property | Duplicates / mirrors | Verdict |
|---|---|---|
| `identity.declared_at` | the existence of the declared channel — the channel WAS the declaration | move into the identity file's `meta`, renamed `updated_at` (distinct names were only needed while the channels shared one file) |
| `capture.captured_at` | ditto for the captured channel | move into the capture file's `meta`, renamed `updated_at` (same reason) |
| `capture.harness_version` | already emitted in the raw block's `harness_version` | move into the capture file's `meta` (raw keeps its "not yet knowable" null) |
| `agent_detect_version` | per-writer provenance; nothing else records it | move into each file's `meta` — the version that wrote THAT channel (more precise than the row's last-writer-wins single field) |
| `runner` (writer pid) | provenance of a dead process; git history covers attribution | **dropped from fixture files**; persists only on queue entries (`QueueEntry.runner` unchanged) |
| `identity.channel_hash` | BLAKE3 of content already in the file | **drop** |
| `capture.channel_hash` | ditto | **drop** |
| `fixture_hash` | BLAKE3 of the whole file — mirrors the file | **drop** |
| `prompt_launch` / `version_launch` | curated serving spellings + per-harness flag conventions | move into the **from-capture file's `meta`** (user decision; see §5) |

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

- The `queue` table stays in `.index.json` unchanged in shape (it
  holds non-derivable work intent), including `QueueEntry.runner`.
  The `errors` table is **dropped entirely** (§6d) — its remaining
  mechanical role moves to daemon session memory + log.
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

Each channel becomes a whole self-contained file under its own
directory, owned exclusively by its writer. No merge-write: a writer
serializes the entire file and atomically replaces it (temp + rename
stays; the store lock is only for `.index.json`). The directory IS
the channel — no channel key prefixes inside files.

Every file has exactly two top-level objects:

- **`outputs`** — the saved outputs of the channel: `identify` (the
  18-field contract), the two trailers, and — for from-capture only —
  the `raw` block.
- **`meta`** — everything else: ledger dates, writer version, and the
  curated launch argv (from-capture only).

### 3a. `fixtures/from-identity/<fixture-id>.json`

Written by the from-identity worker (declared generation; zero
tokens; recipe-mode detection against the rule tables).

```jsonc
{
  "outputs": {
    "identify": { /* the 18-field contract, unchanged */ },
    "trailer co-author": "Co-authored-by: Pi · GLM 5.3 Flash <…>",
    "trailer assisted-by": "Assisted-by: Pi · GLM 5.3 Flash <…>"
  },
  "meta": {
    "updated_at": 1788143986,               // was identity.declared_at
    "agent_detect_version": "2026.8.11-3"   // the version that declared it
  }
}
```

### 3b. `fixtures/from-capture/<fixture-id>.json`

Written by `fixtures capture` inside a live session (token-consuming)
or the daemon's from-capture worker.

```jsonc
{
  "outputs": {
    "identify": { /* the 18-field contract, unchanged */ },
    "trailer co-author": "…",
    "trailer assisted-by": "…",
    "raw": { /* the raw block verbatim: platform_id, detectable,
                detected, process_lineage, *_urls, evidence, and its
                own "not yet knowable" harness_version */ }
  },
  "meta": {
    "updated_at": 1788143986,               // was capture.captured_at
    "agent_detect_version": "2026.8.11-3",
    "harness_version": "0.84.4",            // was capture.harness_version
    "prompt_launch": ["pi","--provider","chutes","--model","moonshotai/Kimi-K3-TEE","-p","<prompt>"],
    "version_launch": ["pi","--version"]
  }
}
```

### 3c. Curation = meta-only from-capture files

Curating launch argv for a not-yet-run combo creates a from-capture
file whose `meta` carries only `prompt_launch` + `version_launch` —
no `outputs`, no ledger dates. This is the 350 curated-but-never-run
rows' new home (the old stub-file debate, collapsed into the
from-capture folder). On a successful capture the SAME file gains its
`outputs` + the remaining `meta` fields; `prompt_launch` /
`version_launch` persist untouched — the curation record doubles as
the provenance of what was invoked, with **no stub-deletion step and
no separate `invoked_by` field**. The store's row table leaves
nothing behind: launch argv now lives with the artifact it launches.

Writer rule for `meta` on capture: the worker reads the file it is
about to replace, preserves any `meta.prompt_launch` /
`meta.version_launch` it finds (they are the curation of record),
and stamps `updated_at` / `agent_detect_version` /
`harness_version`, fresh. A capture that runs with no curated argv
(hand-run `fixtures capture`, as in tonight's pi-opencodego fixture)
writes `meta` without the launch fields.

### 3d. What disappears

`runner`, `channel_hash` (×2), `fixture_hash`, the
`IdentityLedger`/`CaptureLedger`/`FixtureRow` types, the
read-modify-write merge of two channels into one file, and the
`from-identity` / `from-capture` / `from-capture-raw` top-level keys
(replaced by the folders + the `outputs`/`meta` envelope).

## 4. Folder layout (settled)

| Directory | Contents | Writer |
|---|---|---|
| `fixtures/from-identity/` | declared identifications (always with `outputs`) | from-identity worker |
| `fixtures/from-capture/` | live captures (`outputs` + full `meta`) **and** curated meta-only stubs | capture worker / daemon |

- Known universe = the union of the two folders' filename stems
  (`<h>-<p>-<m>-<platform>`, all strict slugs). A stem present in
  both folders has both channels.
- Channel presence = file existence — no JSON parse needed to know
  whether a channel ran.
- Writer contention: none — each channel owns a file; declaration
  and capture never touch the same bytes.
- Git semantics: identity churn and capture churn isolated per file;
  PR review sees exactly which channel changed.
- Crash safety: a torn write damages only one channel.
- The `discoverStems` dotfile-skip rule keeps the grids and
  `.index.json` coexisting inside `fixtures/` (dotfiles; the new
  subdirectories are only scanned as their own universes).

Test-corpus note: the envelope/shape tests in
`src/known_fixtures.test.zig` scan `fixtures/*.json` today; they
re-point at the two folders with per-folder assertions (§7).

## 5. Launch argv — resolved

`prompt_launch` / `version_launch` live in the from-capture file's
`meta` (§3b/§3c). Consequences:

- No `launch/` folder, no `launch` store table, no derivation engine.
  The earlier A/B/C trade-off collapses: the meta-only-stub variant
  keeps option A's single-home property while option B's slimness
  (no store table), and the stub lifecycle problem (deletion-on-
  capture) vanishes because the stub IS the capture file's pre-state.
- The store holds zero fixture state: `store_version` + `errors` +
  `queue`.

**Minimal-invocation policy (user steering, 2026-08-31):** curated
invocations carry only the arguments *necessary* to pin harness +
provider + model and run the capture prompt. Extra flags that merely
alter runtime behaviour (observed: cline's `--thinking` on the
deepseek row) are **dropped unless documented as necessary** by the
harness for the invocation to work. The migration audits all 502
curated rows against this policy and minimizes offenders.

## 6. Staleness model (final)

### 6a. Criteria flags

| Flag | Criterion |
|---|---|
| `--stale-by-output-drift` | (renamed from the channel-hash replacement) stale iff the two channel files' `outputs.identify` objects are not both present and deep-equal — a missing channel file counts stale, same semantics as the old `channelHashDivergent` |
| `--stale-by-minutes=N` / `--stale-by-hours=N` / `--stale-by-days=N` | mode-scoped age of `meta.updated_at` (`from-identity/<id>.json` for from-identity, `from-capture/<id>.json` for from-capture); stored in minutes |
| `--stale-by-harness-version` | `from-capture/<id>.json.meta.harness_version` vs the live `version_launch` probe |
| `--stale-by-detect-version` | the channel file's `meta.agent_detect_version` vs this binary's version |
| `--stale-by-missing-entry` / `--stale-by-missing-fixture` / `--stale-by-fixture-hash` / `--stale-by-channel-hash` | **dropped** — no entry table, no store→file references, no hashes |

The old one-marker-per-entry constraint dies: a queue entry carries a
**set** of criteria and a candidate is stale iff ANY carried criterion
says stale (OR; short-circuit per candidate).

### 6b. `--stale` composite and defaulting (user decision)

- New flag **`--stale`** ≡ `--stale-by-output-drift` OR
  `--stale-by-days=27` OR `--stale-by-harness-version` OR
  `--stale-by-detect-version`.
- **Default:** `--stale` is defaulted to true — a queue upsert with
  no staleness flags carries the full composite set. Exceptions:
  - any explicit `--stale-*` flag ⇒ `--stale` is NOT defaulted (the
    explicit flags alone form the entry's set);
  - `--refresh` ⇒ functions as if `--stale` was neither defaulted nor
    provided — the entry carries NO criteria, so every candidate is
    worked regardless of freshness (the explicit opt-back-in to full
    re-evaluation).
- **Component overwrite:** `--stale` provided together with an
  explicit `--stale-*` ⇒ the explicit value overwrites the composite's
  default for that component only. Examples: `--stale
  --stale-by-days=0` = output-drift + days=0 + harness-version +
  detect-version; `--stale --stale-by-days=999999999` effectively
  disables the age component while keeping the other three.
- **Conflicts:** `--refresh` conflicts with `--stale` and every
  `--stale-*` (exit 3) — refresh already means "everything is stale",
  so OR-combining explicit criteria would be a no-op.
- **Uniform default rule (user decision):** a queue item with no
  `--stale-*` and no `--refresh*` pops with the same `--stale`
  default — no per-universe carve-outs. Absent evidence ⇒ stale, so
  unfixtured and backlog candidates (no files, no meta) fire the
  composite naturally; nothing is ever exempt from staleness
  evaluation.
- **Dedupe identity:** the upsert tuple becomes (dims, mode,
  stale-set, `free`); a re-assert must repeat the same flag set
  (defaults included) or it lands as a second, differently-defaulting
  entry — the handoff's "repeat the SAME axis flags" learning,
  extended to staleness.
- **Why:** churn prevention. Previously a no-marker queue entry
  re-evaluated ALL its candidates every sweep — the staged 705-entry
  queue would re-work combos forever. With `--stale` defaulted, idle
  re-queues only pick genuinely stale combos; `--refresh` is the one
  explicit way to force a full pass.

Done rule / crash-resume: unchanged — completion timestamp is the
mode's own channel date (now `meta.updated_at`, read from the mode's
own file), else `errors.<key>.failed_at`.

### 6c. Backlog, `--repair`, and the final flag surface

**All axis pairs are dropped** — old (`--known/--unknown`,
`--valid/--invalid`, `--successful/--unsuccessful`) and their
interim replacements (`--fixtured/--unfixtured`,
`--resolvable/--unresolvable`). There is one default universe and
one action flag.

**Default expansion universe** (no flags): candidates = dims resolve
against the current rule tables ∧ (fixtured ∨ feasible-unfixtured),
selected by the staleness criteria. Feasible-unfixtured = the
grid-filtered cross-product — `(h,p) ∈ .harnesses_providers.csv ∧
(p,m) ∈ .providers_models.csv` − fixtured — so impossible combos
(known ids, combos no provider serves) never become candidates and
from-identity can never mint them. The reference grids become
load-bearing (a doctrine change: they were zig-unread). From-capture
expansion further requires `meta.prompt_launch` — candidates without
argv are backlog, not errors.

**The backlog** (new store table, replacing the errors ledger's
actionable half — derived from scans, idempotent union on write):

```jsonc
"backlog": {
  "unknown_harnesses": ["someharness"],   // harness slugs in stems, absent from rulesForHarnesses
  "unknown_providers": ["someprovider"],  // ditto vs rulesForProviders
  "unknown_models": ["gpt4o"],            // ditto vs rulesForModels
  "needs_curation": ["pi-opencodego-glm53flash-darwin"]  // fixtured from-capture files whose meta lacks prompt_launch
}
```

- Contents are unique alphanumeric dim slugs (or fixture ids for
  needs_curation) — **never null/empty**. A stem that can't even
  split 4-way attributes no dim and lands in no set (the envelope
  test flags the file).
- The three unknown_* sets are the old `unresolvable`, decomposed by
  which dim failed — so a fix (adding a rule) is addressable per dim.
- Seeded at migration, then maintained by the daemon's scan and
  `fixtures status` — union on write, removed when an item resolves.

**`--repair`** (the one action flag; on `fixtures queue`): pops the
backlog, re-evaluates each item against the CURRENT binary's rule
tables and grids, and adds the now-actionable items back to the
queue:

- unknown_harnesses/providers/models item now resolvable → removed
  from the backlog; upsert one queue entry per item filtered on that
  dim (`--agent=X` / `--provider=X` / `--model=X`) — one entry covers
  all of the item's combos.
- needs_curation item whose from-capture file NOW carries
  `meta.prompt_launch` → removed; upsert a `--fixture=<id>`
  from-capture entry.
- unfixtured (derived from grids − fixtured, never a stored list —
  it is hundreds of ids) → upsert a from-identity entry (zero-token
  declarations) over the feasible universe, honoring dims filters.
- Items still unresolvable / still argv-less stay in the backlog;
  the repair pop logs them.

**Done rule / failure memory** (errors ledger fully dropped):
completion timestamp = the mode's success `meta.updated_at`, else
this daemon session already failed it (in-memory damping — one
attempt per candidate per daemon run), else it is a candidate.
Failures persist only in `.daemon.log` for the dev agent to discern;
the targeted retry workflow is a dims-filtered `--refresh` re-queue,
not a ledger query.

**`fixtures status`** (new dev action): the derived snapshot — counts
and ids per backlog set, feasible-unfixtured totals, stale/fresh
breakdowns. This is the dev agent's discernment surface; the log is
the timeline, status is the now.

**Final flag surface on queue/dequeue:** dims filters
(`--fixture` / `--agent` / `--harness` / `--provider` / `--model` /
`--platform`), the staleness family (`--stale`, `--stale-by-*`,
`--refresh`), `--repair`, and `--free` / `--paid` (kept — genuinely
two-sided; membership needs resolvable dims, so backlog items are
moot for it). Dequeue defaulting mirrors queue, so a bare dequeue
filter matches exactly the entry a bare upsert created; `--refresh`
on dequeue matches criteria-less entries.

## 7. Code-impact inventory

**`src/dev/dev.zig`** (the whole change is inside the dev struct):

- Deleted: `FixtureRow`, `FixtureUpdate`, `fixtureRowFromMap`,
  `fixtureRowValue`, `defaultRow`, `fixtureRowUpdatePure`,
  `withFixtureRowUpdate`, `fixtureRowByKey`, `mergeWriteFixture`'s
  merge semantics (becomes whole-file writes per folder),
  `channelHashDivergent` (replaced by identify deep-compare),
  `expandMissingEntryPlatform`, `runMissingEntryRegistration`, the
  `registration` update variant, markers `stale_by_missing_entry` /
  `stale_by_missing_fixture` / `stale_by_fixture_hash` /
  `stale_by_channel_hash`, the errors ledger and its accessors
  (`errorEntryFor`, `errorReasonClass`, `ErrorClass`, `errorKey`,
  `putErrorEntry`, `clearErrorEntry`) and its "no launch spec" /
  "unknown fixture file" reasons, the axis fields on `QueueEntry`
  (`known`, `valid`, `successful`) with their CLI flags and conflict
  slots, and `generationHash` (if no other caller).
- New: `loadChannelFile` (path → slim struct: dims from stem,
  `outputs.identify`, trailers, `meta` fields); `identityPathFor` /
  `capturePathFor` path helpers; identify deep-compare
  (`identifyEqual` — canonical stringify + mem.eql); the backlog
  table accessors (idempotent union/remove of unique slugs);
  `runFixturesStatus` (the derived snapshot action); grid readers
  for feasibility (`.providers_models.csv`,
  `.harnesses_providers.csv` — the reference grids become
  zig-read); `--repair` backlog-pop logic on the queue action.
- Changed: candidate expansion becomes one universe — resolvable
  dims ∧ (fixtured ∨ feasible-unfixtured per grids) ∧ staleness;
  from-capture expansion requires `meta.prompt_launch` (backlog
  items are excluded, not errored); `entryMarkerStale` OR-evaluates
  the carried criteria set against the loaded file's `meta`; the CLI
  parser gains `--stale` / `--refresh` / `--repair` and the
  defaulting + component-overwrite rules (§6b); the capture writer
  (`runFixturesCapture`) and the daemon's identity worker write
  their whole file atomically per §3c's meta-preservation rule;
  the daemon gains session-scoped failure damping (in-memory, one
  attempt per candidate per run) replacing the errors-ledger done
  rule; `INDEX_STORE_VERSION` → 2 with load-time drop of the legacy
  `fixtures` AND `errors` tables (same pattern as the dropped
  `free_provider_to_model`); usage texts (`fixturesUsage`,
  `queueDequeueFlags`, `queueUsage`, `dequeueUsage`) updated for
  the staleness model, backlog, and folder layout.
- Unchanged: daemon guard, pop protocol order, free grid,
  `--free` / `--paid`.

**Tests**:

- `src/index_store.test.zig`: helpers rebuild in-memory stores with
  the new shape; done-rule tests re-source dates from channel-file
  meta; identify-drift tests replace hash-divergence tests;
  meta-only from-capture expansion tests; `--stale` defaulting,
  component-overwrite, `--refresh`, and OR-evaluation tests; backlog
  union/remove idempotence; `--repair` re-queue derivation
  (now-resolvable, now-curated, feasible-unfixtured).
- `QueueEntry` shape note: the seven mutually-exclusive flat marker
  fields become a four-field stale set — `stale_by_output_drift: bool`,
  `stale_by_minutes: ?i64`, `stale_by_harness_version: bool`,
  `stale_by_detect_version: bool` (absent = criterion not carried;
  all absent = a `--refresh` entry) — and the `known`/`valid`/
  `successful` axis fields are deleted; `free` stays.
- `src/known_fixtures.test.zig`: per-folder envelope tests —
  `from-identity/`: `outputs` (identify 18 fields + trailers) +
  `meta` (updated_at + agent_detect_version), nothing else;
  `from-capture/`: `outputs` (+ raw) + `meta` (+ updated_at +
  harness_version + optional launch argv); combo-match per folder
  (identify ids equal the filename's dims); meta-only stubs asserted
  output-less; the `fixture_hash` BLAKE3 test is deleted;
  `prompt_launch` tests re-point at capture-file meta (minimal-
  invocation audit included); store_version test → 2; coverage tests
  ("every provider/model rule appears in ≥1 row") scan folder stems
  instead of store rows.

**Schema/docs**:

- `fixtures/.index.d.ts`: slimmed to `store_version` + `queue` +
  `backlog`; `FixtureRow`, ledgers, hash fields, and the `errors`
  table removed.
- NEW `fixtures/fixture.d.ts`: normative schemas for
  `IdentityFile` and `CaptureFile` (the `outputs`/`meta` envelope) —
  the additional schema for fixture files the user asked for.
- DESIGN.md "index.json state store" rewritten semantics-only with a
  pointer to the schemas; CONTRIBUTING.md curation/doctrine
  paragraphs updated (minimal-invocation policy written up there).

## 8. Migration (one-off, committed separately from the code)

1. Land the code reading the NEW shape (store_version 2, drop-on-load
   of legacy tables) — back-compat by drop, not dual-read.
2. One-off pass (python, then `zig build test` green), run with no
   daemon active:
   - split the 177 fixture files into `fixtures/from-identity/` +
     `fixtures/from-capture/` (per channel present), re-enveloped as
     `outputs`/`meta` with `updated_at`/
     `harness_version`/`agent_detect_version` inlined from the row
     table and all hash fields dropped;
   - create meta-only from-capture files for the ~350 curated rows
     with no file, **minimizing non-essential flags per the
     minimal-invocation policy** (§5);
   - rewrite `.index.json` without the `fixtures` and `errors`
     tables (queue `runner` fields untouched) and seed the `backlog`
     from a full scan: unknown_harnesses / unknown_providers /
     unknown_models (unique dim slugs from unresolvable stems),
     needs_curation (fixtured from-capture files without
     `meta.prompt_launch` — e.g. tonight's pi-opencodego);
     cross-check curated argv against grid spellings while at it
     (the completeness audit).
3. Re-queue the pi-chutes captures (tonight's original goal) and
   commit.

## 9. Verification

- `zig build && zig build dev && zig build test` fully green (the
  two currently-red tests are expected green after the migration
  half, since folder-stem coverage replaces row coverage).
- `fixtures capture` re-run on this session must produce the same
  canonical identify output as the committed pre-split fixture
  (`pi-opencodego-glm53flash-darwin`), modulo the new envelope.
- Daemon smoke: a no-flag `fixtures queue --harness=pi
  --provider=chutes` upsert must carry the full `--stale` composite
  (drift + days=27 + harness-version + detect-version) in its entry;
  a `--refresh` entry must re-list fresh candidates; a
  `--stale-by-minutes=0` from-capture sweep listing `--harness=pi
  --provider=chutes` must list exactly the 12 pi-chutes darwin
  candidates; a from-identity drain must complete with zero token
  spend.
- `fixtures status` must classify tonight's session correctly:
  `pi-opencodego-glm53flash-darwin` under needs_curation (no launch
  argv), the 12 pi-chutes meta-only files under fixtured (capture
  pending), and empty unknown_* sets.
- `--repair` smoke: with a deliberately-unknown model slug in a
  fixture stem, status must list it under unknown_models; after
  adding a rule for it, `fixtures queue --repair` must remove it
  from the backlog and upsert a `--model=<slug>` entry.
