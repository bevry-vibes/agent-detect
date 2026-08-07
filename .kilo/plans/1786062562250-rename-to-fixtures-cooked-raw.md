# Rename project to `agent-detect`, restructure CLI around `cooked`/`raw`/`trailer`, drop JSONL, unify fixture format

## Context

The repo evolved from a JSONL state store to a SQLite two-table store
(`fixtures` + `queue`), but retains legacy naming and structure that no
longer matches the shipped behavior:

- The CLI namespace is `known`; the directory is `known/`; sqlite DB is
  `known/index.sqlite3`; internal identifiers use `Known*`/`known*`.
- Fixtures are `.agent.json` + a separate `.trailer.txt` sibling, with a
  `canonical`/`raw` root shape.
- The `agent` action produces a JSON report; the released binary also has
  `--json`/`--trailer` flag aliases.
- A one-time JSONL migration (`migrateIndexJsonl`/`ensureMigrated`)
  bootstraps the sqlite store from a legacy `known/index.jsonl`.
- The project/binary is named `agent-detection` everywhere except the git
  repo directory itself.

This plan renames the project to `agent-detect`, restructures the CLI
around `cooked`/`raw`/`trailer`, renames `known` → `fixtures`, drops the
JSONL migration in favor of lazy file-based backfill, unifies the fixture
format into a single `{cooked, raw, trailer}` file, and adds recipe-mode
generation for hard-to-detect agents.

No new detection heuristics. Primarily renames, re-formatting, and
removal of the JSONL path.

## Decisions (confirmed with user)

- **Drop JSONL entirely.** Remove `migrateIndexJsonl`/`ensureMigrated`/
  `IndexEvent`/`parseIndexEvent`/`jdim` and delete `known/index.jsonl`
  from the repo (this time for real — no keep-for-fallback).
- **Lazy backfill, not init reconcile.** The `fixtures` sqlite table is
  NOT backfilled at init. Instead, when the daemon/queue processes a combo
  (a `queue` row, `refresh:false` semantics) for which a valid committed
  `fixtures/<id>.json` exists, populate the `fixtures` row from that file's
  cooked details (skip-and-complete) instead of re-capturing. This replaces
  the JSONL migration's role.
- **Full rename `known` → `fixtures`** everywhere: directory `known/` →
  `fixtures/`, sqlite DB `known/index.sqlite3` → `fixtures/index.sqlite3`,
  CLI namespace `known` → `fixtures`, and all internal identifiers
  (`KnownFixturesForKnownAgents` → `RecipesForFixtures`,
  `knownAlphanumericId` → `fixtureId`, `knownRulesForKnown*`
  etc.). The git repo directory stays `agent-detection` (per user bullet).
- **SQLite tables renamed** (no migration — the DB doesn't exist yet,
  `CREATE TABLE IF NOT EXISTS` is the whole story): `fixtures` stays
  `fixtures` (the captured-state table); `actions` → `queue` (the work
  queue), matching the "one table for fixtures, one for queue" wording.
  All row-struct + helper identifiers follow (`ActionRow` → `QueueRow`,
  `upsertAction` → `upsertQueueRow`, `popPendingAction` →
  `popQueueRow`, etc.).
- **Drop the `action` column** on the queue table (and `QueueRow.action`
  / `validateQueueRow`'s `action != "capture"` check): it is always
  `'capture'`, nothing writes or reads another value, no query filters
  on it — dead weight. Also drop `tableCount` (only used by the
  removed `ensureMigrated`).
- **Project/binary rename `agent-detection` → `agent-detect`** everywhere
  except the physical repo directory name. Released binary:
  `agent-detect`; dev binary: `agent-detect-dev`. Cross-compile artifacts:
  `agent-detect-<os>-<arch>`. Update build.zig, AGENTS.md, README.md,
  DESIGN.md, CONTRIBUTING.md, CI workflow, and version/release strings.
- **CLI actions:**
  - Released binary (`agent-detect`): `cooked`, `trailer`, `help`,
    `version`. `raw` and `fixtures` are NOT compiled into the released
    binary (dev-only).
  - Dev binary (`agent-detect-dev`): adds standalone `raw` (raw report)
    and the `fixtures` namespace.
- **Action renames:**
  - `agent` → `cooked` (report). Drop the `agent` spelling entirely.
  - `agent-detection-dev agent` (capture) → `agent-detect-dev fixtures
    capture`.
  - New standalone dev `raw` action outputs only the raw block.
  - Drop `--json` and `--trailer` flag aliases entirely.
- **New fixture format:** single `fixtures/<fixture_id>.json`
  with top-level keys `{cooked, raw, trailer}`. `cooked` = the 18-field
  canonical object `cooked` emits; `raw` = runtime observations; `trailer`
  = the trailer string. Replaces `.agent.json` + `.trailer.txt`.
- **Fixture-set consolidation:** the repo's `known/` dir has 22
  `.agent.json` files in two unrelated generations:
  - 12 current `-darwin.agent.json` captures (current 18-field schema,
    real env values, `platform_alphanumeric_id: darwin`).
  - 10 non-suffixed `.agent.json` legacy files (old `-`-separator
    trailers with 2-part ids, `value: "fake"` / `present: false` env,
    no platform). 9 of them duplicate a current `-darwin` capture of
    the same combo; 1 (`mmx-minimax-minimaxm3`) is the only capture
    its recipe ever got.
  Final set: **13 unique fixtures**, one per recipe, each
  `fixtures/<agent_id>-<platform>.json`:
  - 12 current `-darwin` captures convert in place (the `.agent.json`
    suffix + `.trailer.txt` sibling merge into one `{cooked,raw,trailer}`
    file).
  - `mmx-minimax-minimaxm3` converts from its legacy non-suffixed file
    to `fixtures/mmx-minimax-minimaxm3-darwin.json`.
  - The 9 stale duplicate non-suffixed files are `git rm`'d (they
    cannot co-exist under the unique `fixture_id` naming and are
    superseded).
- **`cooked` and `trailer` recipe mode:** each may take no args (live
  detection) OR a complete `--harness=H --provider=P --model=M` combo
  (resolved against the recipe/rule tables, skipping live detection).
  Partial combo is NOT allowed — all three required or none.
- **`detectable` + `detected` fields:** live at the top of the `raw`
  block, adjacent to each other:
  - `detectable: []` — the array of `"harness"|"provider"|"model"`
    dims that *could* be resolved for this capture (what the recipe
    implies / the ladder reached). In live detection it's filled by the
    detection ladder; in recipe mode (no live detection) it reflects
    whatever the recipe can supply (up to all three).
  - `detected: []` — the array of dims actually captured into the
    `cooked`/canonical block (a subset of, and typically equal to,
    `detectable`). Lets a reader instantly see what the fixture
    actually recorded in `cooked` without scanning it. A fixture
    written by `fixtures capture` stores both as captured.
  - Both are `raw`-block top-level keys (immediately after
    `platform_id`), not nested under `detectable`. (`detected` is the
    post-hoc record of what landed in `cooked`; `detectable` is the
    pre-hoc capability list.)
- **Do NOT run the daemon in this batch.** Daemon wiring is repaired for
  the renames and the lazy backfill, but it is not exercised end-to-end;
  that is a follow-up.

## Tasks

### 1 — Drop JSONL machinery

- Remove `migrateIndexJsonl`, `ensureMigrated`, `IndexEvent`,
  `parseIndexEvent`, `jdim`, and any remaining `index.jsonl` references in
  `src/main.zig`.
- Remove the `ensureMigrated(a, io)` call sites at the start of every
  `known`/`fixtures` subcommand (currently in `runKnownAgent`,
  `runKnownQueue`, `runKnownDequeue`, `runKnownDaemon`).
- Delete `known/index.jsonl` from the repo (`git rm`). This is now
  intentional per the decision.
- The bootstrapping role of the removed migration is replaced by Task 2;
  the schema itself is reshaped in Task 9 (sqlite renames + drop
  `action` column) — no data migration needed since the DB is absent.

### 2 — Lazy file-based backfill (replaces migration)

- Add a helper that, given a combo `(h, p, m, plat)`, checks whether a
  valid committed `fixtures/<fixture_id>.json` exists whose
  `cooked` block parses and matches the recipe table (valid per recipe).
- Wire it into the daemon's skip-and-complete path: when a full non-`--all`
  queue row is about to capture, if the committed file is valid, populate
  the `fixtures` sqlite row from the file's cooked details and complete
  without spawning a capture (this is the `refresh:false`/already-captured
  semantics).
- No init-time scan; the table is populated lazily on demand.

### 3 — Fixture format + naming

- Replace `knownAlphanumericId` with `fixtureId`
  (`agent_id` + `-` + `platform_id`), and rename its usages.
- Change `fixtures capture` to write a single
  `fixtures/<fixture_id>.json` with `{cooked, raw, trailer}`.
- **Migrate the committed fixture set** (see Decisions "fixture-set
  consolidation"):
  1. `git mv known/<agent_id>-darwin.agent.json →
     fixtures/<agent_id>-darwin.json` for the 12 current captures, and
     merge each `.trailer.txt` sibling into the new `trailer` key.
     The `cooked` block is the old `canonical` object (keys renamed per
     Task 10 `*_id`); `raw` is the old `raw` object; `trailer` folds in
     the `.trailer.txt` content.
  2. Convert `known/mmx-minimax-minimaxm3.agent.json` →
     `fixtures/mmx-minimax-minimaxm3-darwin.json` (re-cooked layout,
     platform `darwin`; the file has no `.trailer.txt` sibling — NAS,
     so trailer comes from its embedded `canonical.trailer`).
  3. `git rm` the 9 stale duplicate non-suffixed `.agent.json` +
     `.trailer.txt` pairs (the combos already covered by a current
     `-darwin` capture).
  The converted files gain `detectable`/`detected` derived from the
  dims present in their recovered canonical/cooked block (all three
  for these full captures).
- Update `purgeMalformedFixtures` to scan `fixtures/*.json` (new suffix),
  validate the `cooked` block, and delete the single file (no trailer
  sibling).
- Update `--missing-fixture` scope logic to check for the single
  `fixtures/<id>.json` file (drop the `.trailer.txt` existence check).
- Update the fixture test file `src/known_fixtures.test.zig`:
  - `discoverStems` filters `fixtures/*.json` (new directory + suffix).
  - Tests read the `cooked` block where they previously read `canonical`;
    the `raw` and `trailer` keys are verified at top level.
  - Add assertions that each fixture's `raw` carries both
    `detectable` and `detected` at the top (adjacent to `platform_id`).
    For committed full captures both equal `["harness","provider",
    "model"]`.
  - The "usages" in test comments and the `agent`/`known` references are
    updated.

### 4 — CLI action restructure

- Released action parser: `cooked`, `trailer`, `help`, `version`. Remove
  `agent`, `--json`, `--trailer` aliases.
- `cooked` (no args) → live detection, emit the 18-field canonical object.
  `cooked --harness=H --provider=P --model=M` → recipe mode (see Task 6).
- `trailer` (no args) → live detection trailer. `trailer
  --harness=H --provider=P --model=M` → recipe-mode trailer.
- Standalone dev `raw` action → emit only the raw block (with
  `detectable` + `detected`).
- The `fixtures` namespace (dev): `fixtures help`, `fixtures capture`,
  `fixtures daemon`, `fixtures queue`, `fixtures dequeue`.
- `raw` and `fixtures` are compiled out of the released binary (dev-only),
  matching the existing `dev` gating.

### 5 — Split `buildJson` into cooked/raw components

- The current `buildJson` emits either the slim canonical report (released)
  or the `{canonical, raw}` fixture (dev). Refactor into:
  - `buildCooked(d, ...)` → the 18-field canonical object (used by
    `cooked`, and embedded as the `cooked` key in fixtures).
  - `buildRaw(d, ...)` → the raw observations object including the new
    `detectable` + `detected` arrays at the top (used by standalone
    `raw`, and embedded as the `raw` key in fixtures).
  - `buildTrailer(d)` → the trailer string.
- `fixtures capture` assembles `{cooked, raw, trailer}` from these.
- The `trailer` field already exists in `Detection`; keep it.

### 6 — Recipe-mode cooked/trailer

> Note: identifiers below use the pre-rename names
> (`agent_alphanumeric_id` etc.); Task 10 renames them to `*_id`.
> Implement against the current code, then let Task 10's sweep rename
> the new code along with the rest.

- Add a function to resolve a full combo `(h, p, m)` against the rule
  tables to produce a `Detection`-shaped value without live detection:
  harness rule lookup by id → label/name/license/urls; provider via
  `providerForName`/`providerMetaForName`; model via `modelForName`;
  recompute `agent_alphanumeric_id`, `reciprocal`, `trailer`.
- `cooked --harness=H --provider=P --model=M` returns the cooked report
  from this resolution (exit 0).
- `trailer --harness=H --provider=P --model=M` returns the trailer from
  this resolution.
- Invalid/unknown combo → exit 2 with a clear error.
- `detectable`/`detected` in recipe mode: both emitted in `raw`
  reflecting the recipe — `detectable` = what the recipe implies
  (typically all three), `detected` = the dims that actually resolved
  into `cooked` from the recipe lookup (identical to `detectable` on a
  full known combo); the raw block otherwise is minimal/empty.

### 7 — `detectable` + `detected` fields

> Note: same pre-rename identifier caveat as Task 6 — `*_alphanumeric_id`
> becomes `*_id` in Task 10.

- Add `detectable: []const []const u8` and
  `detected: []const []const u8` to `RawObservation` (or emit both
  directly in `buildRaw`).
- **`detectable` semantics** — what the ladder/recipe *could* resolve:
  - Live detection: fill from which of `harness_alphanumeric_id` /
    `provider_alphanumeric_id` / `model_alphanumeric_id` the detection
    ladder reached (reuse the existing `hsrc` logic and per-dim null
    checks).
  - Recipe mode (`cooked --harness= --provider= --model=`, no live
    detection): the recipe implies all three, so `detectable`
    = `["harness","provider","model"]`.
- **`detected` semantics** — what actually landed in the `cooked`
  block this run: the subset of `detectable` whose canonical fields
  were populated into `cooked`. For a successful live/recipe capture
  with a full combo, `detected` = `detectable` = all three. When
  partial (only some dims produced output), `detected` is the reduced
  subset. Purpose: a reader instantly sees what the fixture actually
  recorded without scanning `cooked`.
- **Emit order:** both are top-level `raw` object keys emitted
  immediately after `platform_id`, with `detectable` first then
  `detected`, e.g.:
  ```json
  "raw": {
    "platform_id": "darwin",
    "detectable": ["harness", "provider", "model"],
    "detected": ["harness", "provider", "model"],
    ...
  }
  ```
- Live `cooked`/`raw`/`trailer` and `fixtures capture` all include both.

### 8 — `known` → `fixtures` full rename

- Rename directory `known/` → `fixtures/` (git mv committed fixtures;
  update `.gitignore` to ignore `fixtures/*.sqlite3*` and
  `fixtures/daemon.log`).
- Rename `INDEX_DB_PATH` literal `known/index.sqlite3` →
  `fixtures/index.sqlite3`.
- Rename all internal identifiers. Concrete mapping (the `knownRulesForKnown*`
  family is the tricky one — the deduped pattern is:
  `knownRulesForKnownAgents` → `rulesForHarnesses`, and the type
  `KnownRuleForKnownAgent` → `HarnessRule`, so the pair reads
  `const rulesForHarnesses = [_]HarnessRule{...}`):
  - `knownRulesForKnownAgents` → `rulesForHarnesses`
  - `KnownRuleForKnownAgent` → `HarnessRule`
  - `knownRulesForKnownModels` → `rulesForModels`
  - `KnownRuleForKnownModel` → `ModelRule`
  - `knownRulesForKnownProviders` → `rulesForProviders`
  - `KnownRuleForKnownProvider` → `ProviderRule`
  - `KnownFixturesForKnownAgents` → `RecipesForFixtures`
  - `knownFixturesForKnownAgents` → `recipesForFixtures`
  - `knownAlphanumericId` → `fixtureId`
  - `splitKnownAlphanumericId` → `splitFixtureId`
  - `knownIdFrom` → `fixtureIdFrom`
  - `runKnownAgent` → `runFixturesCapture`
  - `runKnownDaemon`/`runKnownQueue`/`runKnownDequeue`/`runKnownHelp` →
    `runFixtures*`
  - `knownUsage` → `fixturesUsage`
  - `createDirPath(io, "known")` / `openDir(io, "known")` →
    `"fixtures"`
  - `purgeMalformedFixtures` → stays (name already fixture-focused)
- Update the `main()` dev dispatch: `known` → `fixtures`, `known agent` →
  `fixtures capture`, `refresh run` handling (keep the child invocation as
  `fixtures capture`).
- Update all `known/` path references in comments and docs.

### 9 — SQLite store rename (`actions` → `queue`, drop `action` column)

The DB file becomes `fixtures/index.sqlite3` (via Task 8). Table +
row-model renames; no data migration because the DB does not exist yet
(schema is created fresh by `ensureSchema`).

- **Table rename in every SQL string + schema DDL:**
  `FROM actions` / `INTO actions` / `DELETE FROM actions` / `ON actions`
  → `queue`. Affected sites: the `ensureSchema` DDL + `actions_dedupe`
  index, and the SELECT/INSERT/DELETE helpers `upsertAction`,
  `selectSeedActions`, `popPendingAction`, `deleteActions`.
- **Index rename:** `actions_dedupe` → `queue_dedupe` (stays the unique
  dedup key; the `COALESCE(...)` column list drops `action` per below).
- **Drop the `action` column** from the DDL, from `upsertAction`'s
  INSERT column/value list, from the `queue_dedupe` index columns, from
  `selectSeedActions`/`popPendingAction` SELECT lists, from
  `jsonToActionObj`, and from the `ActionRow` struct. Remove
  `validateQueueRow`'s `action != "capture"` rejection.
- **Row-struct + helper renames** (concrete mapping; this list is
  authoritative for the queue machinery):
  - `ActionRow` → `QueueRow`
  - `upsertAction` → `upsertQueueRow`
  - `jsonToActions` / `jsonToActionObj` → `jsonToQueueRows` /
    `jsonToQueueRow`
  - `selectSeedActions` → `selectSeedQueueRows`
  - `popPendingAction` → `popQueueRow`
  - `deleteActions` → `deleteQueueRows`
  - `validateActionRow` → `validateQueueRow`
  - `describeAction` → `describeQueueRow`
  - any other `filterActions`/`parseFilters`-adjacent helper discovered by
    grep during implementation — apply the same `Actions` → `QueueRows`
    naming.
  - `tableCount` → **remove** (only used by `ensureMigrated`).
- Update every error literal: `error.InvalidActionRow` →
  `error.InvalidQueueRow`; `describeAction`-derived user/daemon messages
  keep their wording but the identifiers change.
- Update the queue-related doc comments: "One row in the `actions` queue"
  → "One row in the `queue` table"; `popPendingAction`'s race note stays.

### 10 — `_alphanumeric_id` → `_id` rename (fields, JSON keys, helpers)

The historic conflict was `_id` vs `_name`; today `*_name` carries the
service's canonical spelling and `*_id` was renamed to
`*_alphanumeric_id` to avoid confusion. That nuance is gone — `*_name`
is the readable form, `*_id` is the strict slug. Drop `Alphanumeric`
from the identifier (both Zig and JSON), and document the
"strict lowercase-alphanumeric slug" constraint in comments/DESIGN
instead.

- **Detection struct fields:**
  - `harness_alphanumeric_id` → `harness_id`
  - `provider_alphanumeric_id` → `provider_id`
  - `model_alphanumeric_id` → `model_id`
  - `agent_alphanumeric_id` → `agent_id`
- **JSON output keys** (cooked report + fixture `cooked` block + raw
  `platform_alphanumeric_id`):
  - `"harness_alphanumeric_id"` → `"harness_id"`
  - `"provider_alphanumeric_id"` → `"provider_id"`
  - `"model_alphanumeric_id"` → `"model_id"`
  - `"agent_alphanumeric_id"` → `"agent_id"`
  - `"platform_alphanumeric_id"` → `"platform_id"`
- **Helper functions:**
  - `alphanumericId` → `slugId` (keeps the "id derived from name via
    slug" intent; the doc comment states the lowercase-alphanumeric
    constraint)
  - `setAgentAlphanumericId` → `setAgentId`
  - `splitAgentAlphanumericId` → `splitAgentId`
  - `splitKnownAlphanumericId` → `splitFixtureId` (already in Task 8)
  - `platformAlphanumericId` → `platformId`
  - `harnessAvailable(agent_alphanumeric_id:)` →
    `harnessAvailable(agent_id:)`
  - struct/ramda field refs at QueueRow/RecipesForFixtures all drop
    `alphanumeric_` (IndexEvent is gone from Task 1).
- **Fixture files** (`fixtures/*.json`): the `cooked` block keys change
  to `*_id`; the raw `platform_alphanumeric_id` → `platform_id`.
- **Tests** (`src/known_fixtures.test.zig`): the 18-key canonical
  expectation list and any `*_alphanumeric_id` asserts use the new
  `*_id` names.
- **Docs**: the fixture contract / canonical-field lists in DESIGN.md
  and CONTRIBUTING.md use `*_id`.

### 11 — Project rename to `agent-detect`

- `build.zig`: `.name = "agent-detection"` → `"agent-detect"`;
  `"agent-detection-dev"` → `"agent-detect-dev"`; dist artifact
  `agent-detection-{s}` → `agent-detect-{s}`; step/comment strings.
- `src/main.zig`: `usage`/`knownUsage`/version strings that print
  `agent-detection` → `agent-detect`.
- `AGENTS.md`: binary path `./zig-out/bin/agent-detection trailer` →
  `./zig-out/bin/agent-detect trailer`; `agent-detection` tool name →
  `agent-detect`.
- `.github/workflows/build.yml`: `bin/agent-detection-*` →
  `bin/agent-detect-*`; release/rolling body text.
- `README.md`: binary table links `agent-detection-<os>-<arch>` →
  `agent-detect-<os>-<arch>`; usage examples; contributing pointer.
- `DESIGN.md` / `CONTRIBUTING.md`: `agent-detection` → `agent-detect`
  throughout; the big block comment above `pub const dev` in main.zig.
- Note: the git repo directory and its remote URL stay `agent-detection`
  (user decision). Only the binaries, CLI, docs, and build output change.

### 12 — Docs alignment

- `DESIGN.md`:
  - Rewrite "two-binary split" to reflect `cooked`/`raw`/`trailer` +
    `fixtures` namespace and the dev-gated nature.
  - Rewrite "per-platform fixtures" to describe the single
    `fixtures/<id>.json` `{cooked, raw, trailer}` format.
  - Rewrite the SQLite section to drop the JSONL-migration sentence and
    describe the lazy file-based backfill; name the two tables
    `fixtures` + `queue` (no `action` column).
  - Update evergreen decisions #1/#6 to reflect the new "recipe-mode
    cooked" (non-auto-detectable = warning for a later dev agent, not a
    hard failure) and the lazy backfill.
  - Rename `known` → `fixtures` throughout.
- `CONTRIBUTING.md`:
  - Update every `agent-detection-dev known` → `agent-detect-dev fixtures`
    command; `known agent` → `fixtures capture`; `known queue` →
    `fixtures queue`; etc.
  - Update the "refresh a fixture" flow for the new single-file format and
    lazy backfill.
  - Update the "add a new harness rule" for recipe-mode cooked (a rule
    with hard-to-detect provider/model can still emit cooked/trailer).
  - Update the tooling note (sqlite3 CLI) for the renamed paths.
- `README.md`: binary table, usage (cooked/trailer/help/version), the
  sqlite3-for-maintainer note, contributing link.

### 13 — Validation

1. `zig build` (released) green — `cooked`/`trailer`/`help`/`version`,
   no `raw`/`fixtures` compiled in.
2. `zig build dev` green — `raw` standalone + `fixtures` namespace present.
3. `zig build test` green — fixture tests updated for the new
   `cooked`/`raw`/`trailer` file shape and `fixtures/` directory.
4. `git grep -ir "index.jsonl\|known/|agent-detection\b"` across
   src/ + docs + build.zig + CI + AGENTS.md shows only legit historical/
   repo-directory references (the git repo dir name) — no live code or
   user-facing doc points at `known`/jsonl/`agent-detection` binaries.
5. `git grep -rn "ensureMigrated\|tableCount\|migrateIndexJsonl" src/` —
   zero hits after Task 1; `git grep -rn "\\\\bactions\\\\b\|\"action\"\|ActionRow\|\\.action\\b" src/` — zero hits after Task 9.
6. Smoke: `./zig-out/bin/agent-detect --version`, `./zig-out/bin/agent-detect
   cooked` (live), `./zig-out/bin/agent-detect trailer`, `./zig-out/bin/agent-detect
   cooked --harness=cline --provider=clinepass --model=kimik3`
   (recipe mode), `./zig-out/bin/agent-detect-dev raw`,
   `./zig-out/bin/agent-detect-dev fixtures --help`.
7. `ls fixtures/index.sqlite3` absent (not created by this batch) and
   `known/` directory gone (renamed to `fixtures/`).
8. sqlite smoke (dev, creates the DB only by explicit command): run
   `agent-detect-dev fixtures queue --all`, then `sqlite3 fixtures/index.sqlite3
   ".tables"` shows `fixtures` + `queue` (no `actions`), and
   `.schema queue` shows no `action` column.

## Follow-ups (NOT in this batch)

- Exercise the daemon end-to-end after the renames: `fixtures queue` →
  `fixtures daemon --write-log` → confirm the lazy file-based backfill
  populates `fixtures/index.sqlite3` (tables `fixtures` + `queue`) from
  valid committed files and captures for missing combos →
  `fixtures dequeue`.
- Re-run the `fixtures` round-trip to confirm the store is self-sufficient
  without the legacy JSONL file.

## Risks / notes

- The rename is invasive (structs, functions, paths, docs, sqlite DDL).
  Grep each identifier after editing; compile between batches.
- `buildJson` is referenced by the fixture test file? Verify — the test
  file reads fixtures from disk and does not import `main.zig` symbols, so
  renaming `pub` items is safe, but keep `buildCooked`/`buildRaw` `pub` if
  anything references them.
- Recipe-mode cooked resolves labels/sources from the rule tables; ensure
  the harness rule lookup by id exists (currently lookup is by name in
  `detect()`). Add a `harnessRuleForName` helper if needed.
- The released binary must stay minimal: `cooked` and `trailer` are
  released; `raw`, the `detectable`/`detected` raw fields, and the
  `fixtures` namespace are dev-gated. `raw`-block code already lives
  inside `buildJson`'s dev branch; move it wholesale into the
  dev-gated `buildRaw`.
- `popPendingAction` → `popQueueRow` retains a pre-existing
  select-then-delete race (out of scope). Leave as-is.
- The `action` column removal touches the `queue_dedupe` unique index
  (active system), the DDL, and `validateQueueRow` — all moved together
  so the dedupe key stays consistent. No data migration needed (fresh
  DB), but keep the index's column list in lockstep with the DDL.