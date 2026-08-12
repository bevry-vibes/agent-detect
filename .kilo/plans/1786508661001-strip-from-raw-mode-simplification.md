# Strip `--from-raw`; from-capture default; failure-mark model; `--stale-by-detection`

Supersedes `1786449399996-strip-from-raw-windows-capture.md` (that plan kept
from-identity as the default and the daemon-side backfill; this one goes
further per user direction).

## Goal

Dramatically simplify fixture generation/testing:

1. Remove `--from-raw` end-to-end (worker, fabricators, sandbox HOME,
   `refresh run`, docs) and every orphan it leaves behind.
2. Two modes remain: `from-identity` (declared, zero-token, explicit opt-in
   only) and `from-capture` (real session, token-consuming, **the default**).
3. Replace the queue `available` column + handoff re-queue + retry-cap
   machinery with a **failure-mark model**: any pop failure marks the
   `fixtures` row (`success=0`, and `available=0` when the cause was a
   probe), drops the queue row, and moves on. Re-queue explicitly via
   `queue --unsuccessful` / `queue --unavailable`.
4. Add `--stale-by-detection`: queue recipes whose committed host-platform
   fixture file is missing or carries a different `agent_detect_version`
   (new top-level fixture key, stamped from `build_options.version`). This
   is the cross-OS driver: each host evaluates its own committed fixture
   files (shared via git), so macOS work re-does darwin fixtures and a later
   Windows/Linux run re-does only that host's — no queue sync needed.
5. Queue-time backfill for `from-identity` (bootstrap a fresh clone's
   `fixtures` table from committed files via
   `queue --recipes --from-identity`), replacing the daemon's origin-rank
   lazy backfill entirely.
6. Re-capture all capturable darwin fixtures on macOS as `from-capture`;
   re-declare the no-launch-spec ones as `from-identity`; then tighten the
   origin validator to drop `"from-raw"`.

## Decisions (confirmed with user)

- **Default mode = `from-capture`.** `fixtures queue` stamps `from-capture`
  when no `--from-*` flag is given; `dequeue` still defaults to "" (all
  modes, filter-only). The assumed "daemon does from-identity unless
  conditions are met" behavior is removed, not reimplemented.
- **`from-identity` kept, three narrow roles:** (a) shallow recipe-authoring
  check (writes a declared fixture for a new combo), (b) fresh-clone
  `fixtures`-table bootstrap — handled by `queue --recipes
  --from-identity` at queue time, **not** by daemon pop-time magic,
  (c) declared fixtures for combos that can't be captured — only when the
  user explicitly passes `--from-identity`. Otherwise: warning + the
  unavailable/failure flow, **no** fixture generation.
- **Failure-mark model (replaces cooldown proposal):** `fixtures` table
  gains `available INTEGER` (NULL not probed / 1 / 0) and
  `success INTEGER` (NULL no attempt / 1 ok-or-backfilled / 0 last attempt
  failed). Any pop failure (worker nonzero, post-check fail, no launch
  spec, probe unavailable) upserts the fixtures row `success=0`
  (`available=0` too when the live probe failed) and **drops** the queue
  row. No auto re-queue, no `capture_attempts` map, no 3-attempt cap, no
  handoff, no cooldown column. Retry = `queue --unsuccessful` (fixtures
  rows `success=0`) or `queue --unavailable` (fixtures rows `available=0`),
  both composable with the dim filters.
- **`queue --available`** stays as a queue-time **probe filter** (only
  queue candidates whose harness binary runs `--version`); alone it still
  implies `--all`. The queue table's `available` column and dequeue's
  `--unavailable` modifier are removed.
- **No-launch-spec from-capture candidates** are skipped at queue time
  (recipe scope and daemon seed expansion) with a warning suggesting
  `--from-identity`; the daemon additionally guards at pop (mark
  `success=0`, warn, drop) as a backstop. The `launch` field is optional
  on the recipe — "no launch spec" ≠ "no recipe", so both layers work.
- **Darwin fixtures:** re-capture all on macOS (user-chosen). Capturable →
  `from-capture`; no-launch-spec → explicit `--from-identity` re-declare.
  The origin validator keeps accepting `"from-raw"` until the sweep commit
  lands, then drops it (tests enforce sweep completeness: any remaining
  `origin:"from-raw"` file fails the suite).
- **Column placement rule** (answers the duplication question): per-host
  operational state lives in the DB (`generated_at`, live `harness_version`,
  `available`, `success`, `runner`); committed artifact provenance lives in
  the fixture JSON (`origin`, `agent_detect_version`, plus the existing
  identity dims in `cooked`/filename). The four key columns duplicate the
  filename/cooked ids by design — they are the SQL index.
- **Naming:** `--stale-by-detection` (flag), `agent_detect_version`
  (fixture key, top-level beside `origin`), `success`/`available`
  (fixtures columns). No version bump needed for the mechanism: a missing
  `agent_detect_version` key counts as stale, so the first sweep queues
  everything; later release bumps make files stale only when the
  maintainer explicitly runs the sweep.
- The sqlite store stays (per-host, gitignored, `sqlite3` CLI). There is
  intentionally no cross-OS queue sync; cross-OS coordination happens
  through the committed fixture files + `--stale-by-detection` /
  `--missing-fixture`.

## Current state (verified 2026-08-12)

- Queue: 177 rows, all `mode='from-raw'` (174 `available=1`, 3 reasonix
  `available=0`). `fixtures` table empty. Stale after this change — the DB
  file is deleted (schema changes; gitignored, disposable; schema
  recreates on next use).
- Committed fixtures: 160 `origin:"from-raw"` + 17 `origin:"from-identity"`,
  all darwin.
- from-raw surface in `src/main.zig`: worker `runOneComboResult`
  (~5979–6150) incl. sandbox-HOME + `AGENT_DETECT_FIXTURE_ORIGIN`
  (6011–6037) and its post-check call (6132); `EnvSetup`/`WriteSpec`
  (3801–3810); `RecipesForFixtures.buildEnv` field (3823–3832) + the 177
  `.buildEnv =` initializers in `recipesForFixtures` (4348+); `resolveHome`
  (3904–3907); `DevProviderMeta`/`devProviderMeta`/`devProviderMetaFor`
  (3909–3951, call sites only at 4144/4209 inside fabricators);
  `canonicalHarnessName`/`canonicalProviderName`/`canonicalModelName`
  (3955–3967) + `comboDims` (3969–3986) — used only by the fabricators;
  14 `build*Env` fabricators (3988–~4345); `refresh run` dispatch alias
  (6760–6768) + its `devUsage` lines (2775–2776); mode default
  `'from-raw'` (schema 3400, `QueueRow.mode` 3444, parse stamp 4863);
  mode parsing (4850); pop ORDER BY CASE + DELETE (3682, 3695);
  `modeRank` (5846–5852) + `fixtureFileOriginRank` (5873–5906, daemon
  call site 5693–5724); version-stamp branch (5806–5812);
  `AGENT_DETECT_FIXTURE_ORIGIN` read in `runFixturesCapture` (5175–5182);
  usage text (`devUsage` 2767–2776, `queueDequeueFlags` 3100–3110,
  `fixturesUsage` 3052–3095, `dequeueUsage` 3162+); comments at 912,
  1658, 1742, 1894, 1963, 2299, 3261, 3836, 4069, 4386, 4767–4769,
  5659, 5806, 6153, 6464, 6596.
- `providerForBaseUrl` (914) has its **own** table and is used by live
  qwen detection (1751) + evidence matching (6365) — STAYS; only its
  comment references the fabricator (reword).
- `exit_statuses.test.zig` has no queue/mode/available coverage.
- `build_options.version` is already compiled in (currently
  `2026.8.11-3`) — stamping `agent_detect_version` is a one-liner in each
  fixture-writing path.
- Queue rows carry `platform` = host; recipe `--available` probing is
  per-host by nature; the gitignored DB never crosses machines, so the
  "handoff for the next agent/platform" wording was always inert.

## Schema changes (`ensureSchema`, ~3376–3410)

`fixtures` — add two columns:
```sql
available INTEGER,   -- NULL not probed · 1 available · 0 unavailable (daemon probe at pop)
success   INTEGER,   -- NULL no attempt · 1 captured/backfilled/declared · 0 last attempt failed
```
`queue` — drop `available`; add `scope_stale_by_detection INTEGER`;
`mode` default `'from-capture'`; `queue_dedupe` drops the
`COALESCE(available,0)` term and gains `COALESCE(scope_stale_by_detection,0)`.
No migration: delete `fixtures/index.sqlite3` (per-host disposable state).

## Tasks

### 1. Strip from-raw in `src/main.zig`

- Delete `runOneComboResult`, `EnvSetup`/`WriteSpec`,
  `RecipesForFixtures.buildEnv` (+ all `.buildEnv =` initializers),
  `resolveHome`, `DevProviderMeta`/`devProviderMeta`/`devProviderMetaFor`,
  `canonical*Name` wrappers, `comboDims`, all 14 `build*Env`.
- Delete the `refresh run` dispatch alias + its usage lines.
  `runFixturesCapture` stays as `fixtures capture`; remove the
  `AGENT_DETECT_FIXTURE_ORIGIN` read — origin is always `"from-capture"`
  on this path now.
- Mode plumbing: schema default + `QueueRow.mode` default +
  `parseFilters` stamp → `"from-capture"`; drop `--from-raw` from flag
  parsing; pop ORDER BY CASE → `WHEN 'from-identity' THEN 0 ELSE 1`.
- Delete `modeRank` + `fixtureFileOriginRank` + the daemon backfill block
  (~5693–5724). Backfill moves to queue time (task 4).
- Worker dispatch (~5800–5803): non-capture rows go to
  `runOneComboIdentity`; `else runOneComboResult` branch dies.
- Reword fabricator-framing comments (912, 1658, 1742, 1894, 1963, 2299,
  3836, 4069, 4386, 6464 "use from-identity", 6596 from-capture only,
  etc.). `providerForBaseUrl`/`devProviderMetaFor` split verified above.

### 2. Failure-mark model (daemon rework)

- `FixtureRow` gains `available`/`success`; `upsertFixture` writes them;
  `jsonToFixtures` reads them. `QueueRow` loses `available`;
  `upsertQueueRow`/`jsonToQueueRow`/`deleteQueueRows`/`validateQueueRow`
  updated (drop available checks, add `scope_stale_by_detection` to
  scope_count; it joins the staleness unit for skip composition).
- Daemon pop: remove the `available` re-probe/handoff block (~5767–5781).
  New from-capture gate, in order: launch-spec guard (null → upsert
  `success=0`, warn with the `--from-identity` hint, drop) → live
  `harnessAvailable` probe (fail → upsert `available=0, success=0`, warn,
  drop). from-identity rows: never probe.
- Success paths upsert `success=1` (+ `available=1` on capture).
- Failure paths (worker nonzero, post-check fail, abnormal termination):
  delete the fixture file if one was written, upsert `success=0`
  (keep `available=1` — it probed), drop the row. Delete the
  `capture_attempts` map + 3-attempt cap + all re-queue branches.
  `deleteFixtureFileAndRow` becomes file-delete + `success=0` mark.
- New queue scopes (fixtures-table universe, compose with dim filters):
  `--unsuccessful` (`success=0`), `--unavailable` (`available=0`).
  `--available` becomes a pure queue-time probe filter (any universe;
  alone ⇒ `--all`). Remove queue-`available` stamping in
  `scopeCandidates`/`expandSeed`; remove dequeue `--unavailable`.
- Seed expansion (`expandSeed`): skip no-launch-spec recipes when
  `seed.mode == "from-capture"` (warn); drop available stamping; add the
  task-4 backfill call for from-identity seeds.

### 3. `--stale-by-detection` + fixture version key

- `runFixturesCapture` and `runOneComboIdentity` stamp top-level
  `"agent_detect_version": build_options.version` (after `origin`).
- `parseFilters`/`FilterOptions`: add `--stale-by-detection`
  (`f.stale_by_detection: bool`).
- `scopeCandidates`: recipe-universe scope — candidate when the
  host-platform `fixtures/<id>.json` is missing OR its
  `agent_detect_version` ≠ `build_options.version` (missing key = stale;
  subsumes `--missing-fixture`). Stamp `scope_stale_by_detection=1`.
  Absorbs `--recipes`/`--missing-fixture` when combined (same universe).
- Daemon pop re-validation: for `scope_stale_by_detection=1` rows, re-read
  the file; skip when its version now equals the binary's (composes with
  the existing age/version markers — all markers fresh ⇒ skip).
- `deleteQueueRows`: `if (f.stale_by_detection) … scope_stale_by_detection=1`.

### 4. Queue-time backfill for from-identity

- Shared helper `backfillFromCommittedFile(h,p,m,plat) !bool`: false when
  a `fixtures` row already exists (explicit refresh intent → caller queues
  normally); else, when a valid committed `fixtures/<id>.json` exists
  (parses, `cooked` dims match), upsert the fixtures row
  (`success=1`, `harness_version`/`available` NULL, `generated_at=now`)
  and return true.
- `scopeCandidates` recipe branch, `f.mode == "from-identity"`: call the
  helper per candidate; skip queueing when it backfilled. So
  `queue --recipes --from-identity` on a fresh clone populates the
  `fixtures` table synchronously (no daemon needed) and only queues rows
  for recipes with no committed file (→ daemon writes declared fixtures).
- `expandSeed` (from-identity seeds): same helper per expanded recipe —
  prevents a fresh-clone identity seed from downgrading committed
  observed fixtures to declared.
- from-capture candidates NEVER backfill (unchanged).

### 5. Usage text + docs

- `src/main.zig`: `devUsage` (drop `refresh run`, fix pop-order line),
  `fixturesUsage` state/daemon blurbs, `queueDequeueFlags` (two modes,
  default from-capture; `--available` filter; `--unavailable`/
  `--unsuccessful` scopes; `--stale-by-detection`), `dequeueUsage`.
- `CONTRIBUTING.md`: state-store intro (new columns, no handoff), role
  split, scope list, failure triage (~130–149: failures mark `success=0`;
  re-queue via `--unsuccessful`/`--unavailable`; no from-raw worker),
  matrix runbook (~185–203), pacing (~236–240: from-identity/from-capture
  only), modes (~321–334), recipe-authoring flow (~508–536:
  `--from-identity` shallow check first).
- `DESIGN.md`: "SQLite state store" (new columns; queue loses
  `available`; no handoff wording), replace "lazy file-based backfill"
  with queue-time backfill, "harness-version tracking" section gains
  `--stale-by-detection` + `agent_detect_version` (file-based,
  cross-host, vs per-host DB `harness_version`), evergreen decisions:
  update #6, #9 (identity→capture ordering), the refresh-flavours bullet
  (two modes, from-capture default), the evidence-attribution rule
  (observed = from-capture; from-raw historical), the global-settings
  rule (drop the "sandboxed HOME" clause — no sandbox remains), and add a
  decision: no auto re-queue — failures mark `success=0`, re-queue via
  explicit scopes.
- `AGENTS.md`: harness-configuration section — the from-raw worker's
  sandboxed-HOME exception is gone; state that the project performs no
  harness config writes at all.
- README.md: no fixture references — untouched. `.kilo/plans/*`: leave
  (historical).

### 6. Tests

- `known_fixtures.test.zig`: keep `"from-raw"` accepted for now; the
  evidence-claim test keeps treating it as observed. In the sweep commit
  (task 8): drop `"from-raw"` from valid origins and add an
  `agent_detect_version` presence/non-empty assertion (old files are all
  replaced by then).
- `zig build`, `zig build test`, `zig build dev` green after the strip
  (before any re-capture).

### 7. Local reset + smoke (this host)

```pwsh
zig build && zig build test && zig build dev
Remove-Item fixtures/index.sqlite3   # schema changed; gitignored disposable state
.\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes --from-identity
# fresh DB + no windows fixture files on disk → nothing to backfill → all
# 177 recipes queue as from-identity rows (host platform = windows; the
# committed darwin files are NOT matches). Verify:
sqlite3 fixtures/index.sqlite3 "SELECT mode, COUNT(*) FROM queue GROUP BY mode;"
# → from-capture 0 / from-identity 177; .schema shows the new columns.
.\zig-out\bin\agent-detect-dev.exe fixtures dequeue --all   # leave the queue empty
.\zig-out\bin\agent-detect-dev.exe fixtures queue --help    # new text
```
Backfill's positive path (valid host-platform file + no fixtures row →
upsert, skip queueing) is exercised naturally during the macOS sweep
(task 8), where darwin files exist.

### 8. macOS sweep (user-driven, darwin host)

```pwsh
git pull; zig build dev
./zig-out/bin/agent-detect-dev fixtures queue --recipes
    # from-capture default; no-launch recipes skipped with warnings
./zig-out/bin/agent-detect-dev fixtures daemon --write-log
# then re-declare the no-launch list explicitly:
./zig-out/bin/agent-detect-dev fixtures queue --recipes --from-identity
    # backfills rows for the fresh captures; queues identity rows only for
    # recipes still lacking a darwin file (the no-launch set) → daemon
```
- Verify zero `fixtures/*-darwin.json` with `origin:"from-raw"` remain;
  then tighten `known_fixtures.test.zig` (drop `"from-raw"`, add
  `agent_detect_version` assertion) in the same commit.
- Commit fixtures + test change with the generated trailer
  (`./zig-out/bin/agent-detect trailer co-author`).

### 9. Windows sweep (user-driven, this host)

```pwsh
git pull; zig build dev
.\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes --stale-by-detection
   # every recipe: no windows fixture files exist → all stale; from-capture
   # default; no-launch skipped with warnings
.\zig-out\bin\agent-detect-dev.exe fixtures daemon --write-log
```
- Unavailable harnesses (e.g. reasonix) mark `available=0, success=0` and
  drop; re-queue later with `queue --unavailable` after installing.
- Review + commit `fixtures/*-windows.json` with the generated trailer.

## Validation

- `zig build test` green after task 6 (interim: 160 from-raw fixtures
  still valid) and again after each sweep commit.
- `rg -n "from-raw|from_raw" src/ docs/ CONTRIBUTING.md DESIGN.md AGENTS.md`
  → only the intentional legacy mentions (validator until task 8;
  historical narrative where deliberately kept).
- `rg -n "buildEnv|EnvSetup|devProviderMeta|resolveHome|comboDims|refresh run|AGENT_DETECT_FIXTURE_ORIGIN|modeRank|fixtureFileOriginRank|capture_attempts" src/` → zero.
- `sqlite3 fixtures/index.sqlite3 ".schema queue"` shows no `available`,
  has `scope_stale_by_detection`; `.schema fixtures` has
  `available`/`success`.
- After the macOS sweep: zero files match `"origin": "from-raw"`.

## Risks / notes

- The sweeps are token-heavy (~170 real sessions per host); the daemon's
  15s pre-capture window + `daemon.ctl` remain the brakes.
- A fixtures row can now exist without a fixture file (failed attempt) —
  consumers checked: `--all`/stale scopes (fine, re-capture),
  `--missing-fixture` (file-based, fine), known_fixtures tests (files
  only, fine).
- Backfilled rows carry `harness_version=NULL` → a later
  `--stale-by-version` sweep treats them as version-stale (over-captures
  once per fresh clone; conservative direction, acceptable).
- Re-capturing the no-launch recipes as `from-identity` downgrades their
  darwin fixtures from fabricated-observed to declared — honest, since the
  fabrication path no longer exists; their old evidence was synthetic.
- `--stale-by-detection` makes every fixture stale after any version bump,
  but nothing re-captures automatically — the maintainer chooses to run
  the sweep.

## Out of scope

- Removing the sqlite store itself; adding a queue-inspection subcommand;
  semver-aware version comparison; `runner` column cleanup; Linux sweep
  (no host currently).
