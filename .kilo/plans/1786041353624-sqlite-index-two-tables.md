# SQLite index: replace known/index.jsonl with a two-table store (fixtures + actions)

## Status: IMPLEMENTATION-READY

Supersedes all in-flight JSONL work (`queue-scope-filters`, seed-action semantics, `index-lock`;
also abandons `zic` `flock` + temp-file rename). The JSONL state store is abandoned and is
**not** maintained/repaired. For the switch-over, the existing `known/index.jsonl` is imported
**once only** (best-effort + sanitized, see "Rollout / migration"), then deleted; it is never
read thereafter.

## Why we stopped (recap)

1. **Memory aliasing / corruption** in the parse/emit/upsert arena-slice lifecycle (reproduced:
   `queue --harness=goose` then one more `queue` produced a duplicate goose row whose
   `platform_alphanumeric_id` was `"sonnet"`, a stale slice of the model). Not worth more time.
2. **Concurrency races**: daemon + CLI did whole-file read-modify-writes with no mutual
   exclusion (lost updates observed).
3. **Scope/subcommand sprawl**: `queue-{stale,all,missing,fixtures}` was being folded into
   scope filters and kept growing; a flat tuple store is the wrong abstraction.

## Supported platform matrix (this session's scope)

`known` + SQLite must run (not just the released detection binary) on:
- **linux x86_64** (musl)
- **linux aarch64** (musl)
- **macos aarch64**
- **windows x86_64** (gnu)

These are exactly the platforms the released binary already cross-compiles to, so no new OS/arch
support is invented — the change is that the **`known` capability is now cross-compiled and
distributed** too, not native-only. `ancestorInfo`/`assertNotInAgent` are already cross-platform
(`src/main.zig` 712-869: `ancestorsWindows`/`ancestorsLinux`/`ancestorsMacos`), so the daemon and
detection run on all four.

## Decisions (resolved this session)

- **SQLite binding**: `pmarreck/zig-sqlite` **@ branch `yolo`** (a Zig 0.16-compatible fork of
  `vrischmann/zig-sqlite`; MIT; bundles the SQLite 3.49 amalgamation). Pin by branch/commit, not
  `main`. Contingency if it does not compile on Zig 0.16.0: vendor the amalgamation + a thin
  hand-written C-API wrapper.
- **SQLite is now cross-compiled to linux-musl, mac-arm, windows-gnu and must be STATICALLY
  linked** (single-file artifact, no `libsqlite3.so`/`sqlite3.dll`/system dep). The fork builds
  its sqlite lib as `.linkage = .dynamic`, which is wrong for cross-compiled single-file
  artifacts. Therefore do **not** use the fork's pre-linked library: compile the bundled
  `sqlite3.c` ourselves (via `sqlite_dep.path("sqlite3.c")`, headers from `sqlite_dep.path(".")`)
  into a **static** library with zig's clang, and link the fork's Zig wrapper sources
  (`sqlite.zig`, `c.zig`, `errors.zig`, `helpers.zig`, `query.zig`) against it. Each `-known`
  executable: `link_libc = true`, `.strip = true`, static link mode (musl abi for linux, gnu
  static CRT for windows). Verify per target with `otool -L`/`ldd`/`file` that the binary is
  self-contained.
- **Artifact shape**: `zig build dist` now emits, for each of the 4 supported targets, BOTH the
  minimal released `agent-detection-<os>-<arch>` (dev=false, **no SQLite**) AND a
  `agent-detection-<os>-<arch>-known` (dev=true, statically-linked SQLite). Preserves DESIGN's
  "released stays minimal" pillar; all `@import("sqlite")` and SQLite links live only in the
  `dev` block / `-known` artifacts.
- **Keep `known/<id>.agent.json` + `.trailer.txt` fixtures.** SQLite is index/queue only; the
  13-test `known_fixtures.test.zig` suite (which validates those files and never imports
  main.zig) is unchanged. `runKnownAgent` still writes the fixture files.
- **`known purge` removed.** `fixtures` rows are never deleted out-of-band. The malformed-fixture
  artifact sweep (`purgeMalformedFixtures`) moves into the daemon **idle loop**.
- **Two-table model**: `fixtures` = state, `actions` = work queue. **No `refresh` column** on
  `fixtures`; the action row is the sole carrier of "re-capture me".
- **`actions` is self-describing**: every action row carries the full queue/dequeue filter. Dims
  are the 4 TEXT columns (NULL = unset/under-development seed). **Each scope filter is its own
  column** using three-valued logic: `1` active, `0` explicit-off, `NULL` undeclared. Staleness
  is a threshold column, not a bool: `--stale` ≡ `stale_by_days = 7`, plus `stale_by_minutes`.
- **`--available` is a stored probe-status column (three-valued 1/0/NULL).** It records the
  harness-availability probe on the **actions** row itself: `1` = probed available, `0` = probed
  unavailable, `NULL` = not probed / undeclared (bare dims/seed). `0` is deliberately a **queued
  handoff state** — a harness unavailable on this host/platform is *recorded and kept queued*
  (`available=0`), not dropped, so the next agent on the next platform (where it may be
  available) can pick it up. `--available` therefore changes from "narrow candidates to
  available harnesses" (drop unavailable) to "probe and record the status per candidate row".
  The **daemon still re-probes at evaluation time** (never trusts the stored value for the
  capture decision) and updates `available` when it re-queues. `fixtures` does NOT get an
  `available` column — availability is a runtime probe, kept only on `actions`.
- **`--no-*` flags are dropped: `--no-harness`, `--no-provider`, `--no-model`,
  `--no-platform`.** These four (main.zig 2982-2989) constrained a dim to *unset*. They are
  redundant under the two-table model: a `fixtures` row always has all 4 dims NOT NULL, and an
  unset dim is expressed only as a NULL seed dim in `actions`, which a bare dims queue
  (`--harness=goose`) already produces by omitting it. `--no-X` just names an already-unset dim,
  so it adds no expressiveness. Remove all four from `parseFilters`, `matchesFilter`,
  `scopeCandidates`, `any`, the composite-contradiction check (3070), the "no-X-only is not a
  valid seed" guards (3346/3371), and `knownUsage` help (2124).
- **Shared validation (single source of truth):** one `validateActionRows`-style function is
  called by BOTH the writer paths (queue/dequeue) and the reader path (daemon) so an invalid
  filter combination can never be persisted or acted on. Invalid = >1 scope column set to `1`
  (all/partial/recipes/missing_fixture/stale are mutually exclusive); stale_by_days AND
  stale_by_minutes both set; a threshold `< 1`; `--all`/`--recipes`/`--missing-fixture` without
  all 4 dims; `--partial` without at least one NULL dim; unknown `action`; `available` outside
  `{1,0,NULL}` or a non-NULL `available` with no accompanying scope column (it is a modifier,
  never the sole filter). The daemon skips + warns + deletes any row that fails validation on
  read.
- **`known queue` = enumerate + upsert only.** It resolves the candidate rows for the filter
  (SELECT fixtures for `--all`/`--stale`, iterate the recipe table for `--recipes`/
  `--missing-fixture`, SELECT seed actions for `--partial`, or the given dims), sets the scope
  columns (`1` for the active scope, `0` for the others, `NULL` for a bare dims queue),
  validates via the shared rule, and `INSERT OR REPLACE`s into `actions`. It does **not**
  evaluate staleness, harness availability, or fixture-file existence — the daemon does. Queued
  count = rows upserted, not "work still pending."
- **`known dequeue` = DELETE only.** Remove matching action rows by dims + scope columns
  (three-valued predicate); no staleness/file checks; no fixture mutation. Validated like queue.
- **`known daemon` owns all evaluation.** It pops one action atomically, runs the shared
  validator on it (skip+warn+delete if invalid), then decides by the scope columns + dims +
  current `fixtures`/filesystem: expand seeds (`--partial` or any NULL dim); skip-and-complete
  full rows already freshly captured (UNLESS `scope_all=1`); re-validate staleness with the
  row's `stale_by_days`/`stale_by_minutes` threshold; re-probe `--available`; then spawn
  `runOneCombo`. Success → upsert `fixtures` row (action already popped); failure → re-queue.
- **`known agent` = fixtures only** (confirmed this session): one function `runKnownAgent`
  serves both `known agent` (user) and `refresh run` (daemon child). On full capture it writes
  the `.agent.json`/`.trailer.txt` and upserts a **`fixtures` row only** — it never reads or
  writes `actions`. Partial/zero → **no store change** (report + exit 2; partial is bad data per
  DESIGN, never guessed). Seeds are only created via `known queue`. The daemon reconciles any
  queued full action against `fixtures` freshness.
- **`--write-log`** daemon log tee: keep exactly as-is (`daemon_log_file`, `daemonWrite*`,
  `src/main.zig` 452, 520-550, 3884-3918).
- **Recipe table** (`knownFixturesForKnownAgents`, 2177-2650) stays the source of truth for seed
  expansion. Scope-filter vocabulary stays `--all --stale --partial --recipes --missing-fixture
  --available` plus dims `--harness=/--provider=/--model=/--platform=` and composite
  `--known=/--agent=`, now as SQL predicates; **`--no-harness`/`--no-provider`/`--no-model`/
  `--no-platform` are removed** (see Decisions), staleness is `--stale` (alias
  `--stale-by-days=7`) with `--stale-by-days=N` / `--stale-by-minutes=N`, and `--available`
  records a probe-status column instead of narrowing candidates.
- **Daemon guard** (`assertNotInAgent`, 4272-4321) stays; daemon user-only, cross-platform.
- **SQLite journaling**: default rollback journal (not WAL) for simple + robust multi-process
  locking (daemon + CLI are separate processes). Set `PRAGMA busy_timeout` (~5s). Short
  transactions per poll; never hold a transaction across `child.wait()` (fixes the old
  holds-lock-across-wait bug).

## Schema (final)

DB file: constant `INDEX_DB_PATH = "known/index.sqlite3"`. Opened fresh on the host platform;
schema created idempotently (`IF NOT EXISTS`) by a shared init helper used by every `known`
subcommand and the daemon.

```sql
-- The state: exactly one row per captured fixture dim-set (always full; platform = host).
-- No derived columns: agent_alphanumeric_id = harness||'-'||provider||'-'||model and the
-- fixture paths are derived per use (agentIdFrom/knownIdFrom), never stored (per DESIGN).
CREATE TABLE IF NOT EXISTS fixtures (
    harness                 TEXT NOT NULL,
    provider                TEXT NOT NULL,
    model                   TEXT NOT NULL,
    platform                TEXT NOT NULL,
    runner                  INTEGER NOT NULL, -- writing pid
    generated_at            INTEGER NOT NULL, -- unix epoch seconds; staleness source
    PRIMARY KEY (harness, provider, model, platform)
);

-- The queue: what to do, not the resulting state.
-- The dim columns are TEXT nullable. NULL = "unspecified / still under development" (a SEED to
-- expand during recipe dev); a value = an exact dim constraint. The --no-harness/--no-provider/
-- --no-model/--no-platform flags are DROPPED: a valid fixture always has all dims (fixtures
-- requires them NOT NULL), so partial state lives only here in actions, as a seed with NULL
-- dims; a bare dims queue ("--harness=goose") already leaves unmentioned dims NULL, so the
-- --no-X is redundant. --agent= fills 3 dims, --known= fills 4.
-- Each SCOPE filter is its own column using three-valued logic (shared by queue/dequeue and the
-- daemon, enforced by the shared validator):
--   1 (active)        -> row was created by this scope; a positive filter matches it
--   0 (explicit off)-> set on the OTHER exclusive scope columns so a --recipes row is
--                      unambiguously "not --all"
--   NULL (undeclared)-> the request never named this filter (bare dims/--agent=/--known=);
--                      matches no positive scope predicate
-- Staleness is a threshold: `--stale` is an ALIAS for `stale_by_days = 7`; `stale_by_minutes`
-- gives hour granularity.
-- `available` is a stored three-valued probe-status column: 1 = probed available, 0 = probed
-- unavailable (recorded + kept queued as a handoff for the next agent/platform), NULL = not
-- probed / undeclared. The daemon re-probes live at evaluation time and never trusts this for
-- the capture decision.
CREATE TABLE IF NOT EXISTS actions (
    harness              TEXT,               -- NULL = unset seed / under-development
    provider             TEXT,
    model                TEXT,
    platform             TEXT,               -- NULL = unset; set to host at capture
    scope_all            INTEGER,            -- 1/0/NULL three-valued scope filters
    scope_partial        INTEGER,
    scope_recipes        INTEGER,
    scope_missing_fixture INTEGER,
    stale_by_days        INTEGER,            -- '--stale' alias = 7; NULL if not a days request
    stale_by_minutes     INTEGER,            -- '--stale-by-minutes=N'; NULL if not used
    available            INTEGER,            -- 1/0/NULL probe status; recorded, not trusted
    action               TEXT NOT NULL DEFAULT 'capture', -- extensible; only 'capture' today
    runner               INTEGER NOT NULL,   -- writing pid (who queued it)
    created_at           INTEGER NOT NULL    -- unix epoch seconds; queue order
);
-- Idempotent create-or-flip: dedupe on COALESCE(dim,'') + COALESCE(filter,0) so NULL treats as
-- the neutral value. NULL/'' collapse for dims (two identical seeds dedupe). The same dims
-- queued under different scope filters / probe states are distinct instructions.
CREATE UNIQUE INDEX IF NOT EXISTS actions_dedupe
    ON actions (COALESCE(harness,''), COALESCE(provider,''), COALESCE(model,''),
                COALESCE(platform,''), COALESCE(scope_all,0), COALESCE(scope_partial,0),
                COALESCE(scope_recipes,0), COALESCE(scope_missing_fixture,0),
                COALESCE(stale_by_days,0), COALESCE(stale_by_minutes,0),
                COALESCE(available,0), action);
```

Notes:
- `fixtures.platform` is always the host platform (captures happen on-host only). Enforced at
  write time, not by a CHECK, so the same DB is valid on every platform.
- No derived strings are stored. `tupleKey` (2259) is only used as the COALESCE-key model /
  for messaging; `agentIdFrom` (2240) / `knownIdFrom` (2249) / `platformAlphanumericId` (2699)
  are recomputed per use for filenames and messaging, as today.
- Three-valued filter rule applies to the scope columns on `actions`: active (1) /
  explicit-off (0) / undeclared (NULL). A positive scope predicate (`--recipes`, `--all`,
  `--partial`, `--missing-fixture`, `--stale`) matches only rows whose column is `1`; `0` and
  NULL rows don't match it. A bare dims/`--agent=`/`--known=` dequeue (no scope) matches any
  scope state.
- `available` is a three-valued **probe-status** column, distinct from the exclusive scope
  columns: `1` = probed available, `0` = probed unavailable (recorded + kept queued as handoff
  for the next agent/platform), `NULL` = not probed / undeclared. It combines with (never
  excludes) a scope column. The shared validator requires `available` to be `1`/`0`/`NULL` only,
  and that a non-NULL `available` accompanies a scope column (never the sole filter). The daemon
  re-probes at evaluation time and updates the stored value on re-queue; it never trusts the
  stored value for the capture decision.
- Staleness: `--stale` ≡ `stale_by_days = 7`. `--stale-by-days=N` / `--stale-by-minutes=N` store
  the exact threshold so the daemon re-validates "still stale" with the same threshold. Only one
  of stale_by_days / stale_by_minutes may be set; the shared validator enforces ≥1 and not both.
- `fixtures` holds only completed, fully-validated captures (all 4 dims NOT NULL). Any
  in-progress / under-development work (e.g. a recipe still being written) is a partial/NULL-dim
  SEED row in `actions` — regenerated via `known queue --partial` or a fresh dims queue; never a
  `fixtures` row. `--no-harness`/`--no-provider`/`--no-model`/`--no-platform` are dropped
  (fixtures require all dims; a bare dims queue already leaves unmentioned dims NULL).

## Rollout / migration (switch-over, one-time)

The new DB starts empty. There is **no auto-reconcile** that scans `known/*.agent.json` into
`fixtures`; the `.agent.json` files stay authoritative for what is captured and
`--missing-fixture` already keys off filesystem existence, so committed fixtures are **not**
mass re-captured. The only import is a **one-time, best-effort migration of the existing
`known/index.jsonl`** into the two tables:

1. Runs once, on the first DB open when both (a) `known/index.jsonl` exists and (b) `actions` +
   `fixtures` are empty.
2. Per line: parse as JSON; **skip** lines that fail to parse (torn/partial lines) or that lack
   `refresh`/`runner`/`generated_at` (today's parse contract at 2739-2763).
3. Unset dims normalize to **NULL** (never `''`), matching the new column convention.
4. **Sanitize known corruption**: drop any full row whose `platform` != host
   `platformAlphanumericId()` (captures are host-only; this specifically removes the
   goose/`sonnet` aliased row). Field-level aliasing inside otherwise-valid JSON (e.g.
   omp→`nimaxm`) is not machine-detectable and will pass through — call this out in the
   migration log so the operator recaptures.
5. Map rows: `refresh:false` **with all 4 dims full** → `INSERT OR REPLACE INTO fixtures`
   (`generated_at` carried over, `runner` carried over). `refresh:true` (any) → `INSERT OR
   REPLACE INTO actions` with `scope = NULL` and `available = NULL` (they were direct
   refresh-requests; the daemon dedupes against fixtures freshness) and `created_at` from
   `generated_at` (it was a `"0"` stub in the JSONL, accept as-is). Seeds (partial dims) land in
   `actions` as `scope=NULL`, `available=NULL` (the old `--available` output has no prior status
   to carry).
6. Dedupe via the normal unique indexes; later lines win (matches `latestEventsPerTuple` 2857).
   Count and log what was imported / skipped.
7. After a successful import the operator runs `known queue --all` (recapture everything) or
   `known queue --missing-fixture` (recapture only absent fixtures) once to converge the
   best-effort state; the daemon then owns it thereafter.
8. The legacy file is deleted once migrated (see task list); never read again.

## Storage surface to replace

Delete the JSONL machinery and replace with SQL over the two tables:
- `latestEventsPerTuple` (2857) → `fixtures`/`actions` SELECTs predicated on the dim columns.
- `upsertIndexEvent` (2813) → `INSERT OR REPLACE INTO actions(harness,provider,model,platform,
  scope_all,scope_partial,scope_recipes,scope_missing_fixture,stale_by_days,stale_by_minutes,
  available,action,runner,created_at)` (queue: enumeration + upsert with the per-filter columns,
  including the `available` probe status, validated by the shared rule; must satisfy
  `actions_dedupe`, giving create-or-flip without a key string) and `INSERT OR REPLACE INTO
  fixtures(...)` (state, written only by `known agent` and the daemon; no `available` column —
  availability is a runtime probe kept only on `actions`).
- `deleteTupleKey` (4091), `deleteIndexEvents` (3745), `deleteIndexKeys` (3779) → `DELETE FROM
  actions WHERE <dim-predicate built from the filter>` (and dequeue's per-scope variants over
  `fixtures`).
- `parseIndexEvent` (2739) is reused by `migrateIndexJsonl` (Rollout/migration) for the one-time
  import of `known/index.jsonl`.
- `writeIndexAtomic` (507), `lockIndex`/`unlockIndex` (473-502), `INDEX_LOCK_PATH` (470), and
  the `known/index.jsonl` literals → remove; replaced by SQLite's own locking.
- `runKnownQueue`/`runKnownQueueScope` (3351/3451), `runKnownDequeue`/`_Scope` (3599/3658),
  `runKnownPurge` (3710), `runKnownDaemon` (3884), `runKnownAgent` (3235), `expandSeed` (4034),
  `runOneCombo` (4111), `enqueuePending` (3978) rewritten against the two tables.
- `purgeMalformedFixtures` (3826) preserved but called from the daemon idle loop, not `purge`.

## Command → SQL mapping

- `known queue <dims|--known=|--agent=|--X=|scope>` → **enumerate + upsert only; no evaluation.**
  Resolve candidate rows for the filter; for each, derive dim columns, set the scope columns
  (`1` active, `0` for the other exclusive scopes, `NULL` for a bare dims queue), populate
  `stale_by_days`/`stale_by_minutes` when relevant (`--stale` → `stale_by_days=7`), and when
  `--available` is present **probe each candidate and record its status into `available`**
  (`1`/`0`; unavailable rows are recorded and kept queued, NOT dropped — they become handoff
  work for the next agent/platform). Run the SHARED validator, then `INSERT OR REPLACE INTO
  actions(harness,provider,model,platform,scope_all,scope_partial,scope_recipes,
  scope_missing_fixture,stale_by_days,stale_by_minutes,available,action,runner,created_at)`
  (idempotent via `actions_dedupe`; re-queue refreshes `runner`/`created_at` and the recorded
  probe status). No staleness/availability/-file evaluation beyond the probe at queue time.
  Candidate sources:
  - `--all`: `SELECT harness,provider,model,platform FROM fixtures` → `scope_all=1`;
    with `--available`, probe each and store status.
  - `--stale` / `--stale-by-days=N` / `--stale-by-minutes=N`: `SELECT ... FROM fixtures WHERE
    generated_at < threshold OR runner-not-alive` (snapshot at queue time; daemon re-validates
    with the stored threshold later) → row carries the threshold.
  - `--partial`: `SELECT ... FROM actions WHERE harness IS NULL OR provider IS NULL OR model IS
    NULL OR platform IS NULL` → refresh those seeds (`scope_partial=1`), so the daemon
    re-attempts expansion.
  - `--recipes`: iterate `knownFixturesForKnownAgents` (as `scopeCandidates` 3127-3172), apply
    dim filters to narrow → full rows, `scope_recipes=1`. `--available` here probes each recipe's
    harness and records `1`/`0` instead of dropping unavailable ones.
  - `--missing-fixture`: iterate recipes whose `.agent.json`/`.trailer.txt` are absent on disk →
    full rows, `scope_missing_fixture=1`.
  - bare dims/`--agent=`/`--known=`: the given dims as a seed (NULL dims) or full row, all scope
    columns `NULL`, `available` `NULL`.
  Prints rows upserted (NOT "work still pending" — pending is evaluated by the daemon).
- `known dequeue <dims|--known=|--agent=|--X=|scope>` → **DELETE only; shared validator.** Build
  the WHERE from dims (`--X=foo`→`col IS 'foo'`; a seed/undeclared dequeue matches NULL dims
  too) and the scope columns using the three-valued rule (`--recipes`→`scope_recipes = 1`;
  `--all`→`scope_all = 1`; `--stale[--by-*]`→the staleness columns; a bare dequeue matches any
  scope state). `--available` matches `available IS 1`; add `--unavailable` (or `--available=0`)
  to match `available IS 0` if the operator wants to purge/retarget handoff rows. Reject invalid
  combos before running. `DELETE FROM actions WHERE ...`. Print count deleted; no fixtures/
  filesystem checks; no fixture mutation.
- `known daemon` → owns evaluation. Loop: atomically pop one row (`DELETE FROM actions WHERE
  rowid IN (SELECT rowid FROM actions ORDER BY created_at,rowid LIMIT 1) RETURNING harness,
  provider,model,platform,scope_all,scope_partial,scope_recipes,scope_missing_fixture,
  stale_by_days,stale_by_minutes,available,action`). Run the SHARED validator on the popped row;
  if invalid, warn + drop (already deleted) and continue. Then per row:
  - Seed (any dim NULL; e.g. `scope_partial=1` or NULL-scope partial) → `expandSeed` (expand over
    recipes; warn+drop unknown seeds; insert child full actions).
  - Full combo → apply the scope policy: skip-and-complete if an up-to-date `fixtures` row exists
    (or `.agent.json` present & fresh) UNLESS `scope_all=1`; for `scope_recipes`/
    `scope_missing_fixture` re-probe fixture-file existence; for staleness re-check the row's
    stored `stale_by_days`/`stale_by_minutes` threshold; complete early if the condition already
    passed. **`--available` rows: re-probe harness availability LIVE** (never trust the stored
    value): if now available → `runOneCombo` (spawn `refresh run`); if unavailable → this host
    cannot capture, so **re-insert the row with `available=0` preserved and its original
    `created_at`** — it is queued as handoff work for the next agent/platform (the poll sleep
    paces the retry; a permanently-unavailable harness on the sole platform stays queued, which
    is the intended handoff). Otherwise (available NULL / no `--available`) → `runOneCombo`.
  - Child success → action already removed; daemon (or child) `INSERT OR REPLACE INTO
    fixtures(...)`. Failure → `INSERT OR REPLACE INTO actions(...)` re-queue (update `available`
    from a fresh probe only if the row carried `--available`).
  Idle → `purgeMalformedFixtures` + sleep. `assertNotInAgent` at startup. No long-lived
  transaction is ever held across the child spawn/wait.
- `known agent` / `refresh run` → **fixtures only.** `detect`; full → write `.agent.json`/
  `.trailer.txt` + `INSERT OR REPLACE INTO fixtures(harness,provider,model,platform,runner,
  generated_at)`; partial or zero → report + exit 2, **no store change** (partial during recipe
  dev is expressed as a seed action via `known queue`, not via `known agent`). It never reads or
  writes `actions`. Any queued full action for this combo is reconciled later by the daemon's
  freshness skip.

## Ordered implementation tasks

1. **build.zig**: add `pmarreck/zig-sqlite`@`yolo` to `build.zig.zon` (`zig fetch --save
   git+https://github.com/pmarreck/zig-sqlite`). Define the supported matrix constants for the 4
   targets (linux x86_64+aarch64 musl, macos aarch64, windows x86_64 gnu).
2. **build.zig**: compile the bundled `sqlite3.c` into a **static** lib (zig clang), link the
   fork's Zig wrapper module against it; wire the `sqlite` import into each `-known` executable
   only (NOT released/dist detection-only artifacts). Add a `known` via `dist`: for each of the 4
   targets emit `agent-detection-<os>-<arch>` (dev=false) + `agent-detection-<os>-<arch>-known`
   (dev=true, static SQLite). Verify per target the `-known` binary is single-file/static.
3. Add `INDEX_DB_PATH = "known/index.sqlite3"` constant and a shared `SqlConn` init helper
   (`PRAGMA busy_timeout`, `CREATE TABLE IF NOT EXISTS`) used by all `known` paths, all under the
   `dev` block.
4. Add thin SQL helper layer: `upsertAction(row)` with `actions_dedupe` idempotency (refreshes
   runner/created_at, includes the `available` probe status), `deleteActions(filter)` building
   the WHERE from dims `--X=`/`--agent=`/`--known=` and the scope columns using the three-valued
   rule plus the `available` column (`--available`→`available IS 1`; `--unavailable`/
   `--available=0`→`available IS 0`), `popPendingAction()` (single-statement
   `DELETE ... RETURNING`, returns all columns incl. scope + staleness + available),
   `upsertFixture(h,p,m,plat,runner,generated_at)` (no `available` column),
   `selectFixtures(filter)`, `selectStaleFixtures(stale_by_days/stale_by_minutes)`,
   `fixtureFresh(h,p,m,plat)`, and `migrateIndexJsonl(SqlConn)` (one-time import, see
   Rollout/migration) — replacing the four removed JSONL functions.
5. Add the **shared validator** `validateActionRow(row) !void` (the single source of truth for
   valid filter combinations — see Decisions) and call it from BOTH `runKnownQueue`
   /`deleteActions` (before write/delete) AND `runKnownDaemon` (before acting on each popped
   row; invalid → warn + drop). Validator rules over the scope columns, staleness thresholds, an
   unavailable-combo check, and the `available` modifier (must be `1`/`0` or `NULL`; a non-NULL
   `available` must accompany at least one scope column and is never the sole filter). Also
   update `parseFilters` in `src/main.zig`: remove the four `--no-harness`/`--no-provider`/
   `--no-model`/`--no-platform` flags (and their `matchesFilter`/`scopeCandidates`/composite-
   contradiction guards), fold `--stale` into `stale_by_days=7`, add
   `--stale-by-days=N` / `--stale-by-minutes=N`, and wire `--available` to produce a probe to
   record into the `available` column (plus an `--unavailable`/`--available=0` dequeue match).
6. Rewrite `runKnownQueue` / `runKnownQueueScope` to **enumerate + upsert only** (per Command→SQL
   mapping): resolve candidate rows for the filter, set the per-filter columns, probe-and-record
   `available` when `--available` is present (recording unavailable rows rather than dropping
   them), validate, then `INSERT OR REPLACE` into `actions`. No staleness/availability/fixture-
   file evaluation beyond the probe at queue time.
7. Rewrite `runKnownDequeue` / `runKnownDequeueScope` to **DELETE only** matching action rows
   (dims + three-valued scope predicate + optional `available`/`unavailable` match). No fixture
   logic.
8. Remove `runKnownPurge` subcommand + its dispatch arm; move `purgeMalformedFixtures` into the
   daemon idle loop.
9. Rewrite `runKnownDaemon` as the **sole evaluator**: pop one action atomically, run the shared
   validator (warn + drop if invalid), then dispatch by scope columns/dims — `expandSeed` for
   seeds (any NULL dim); `runOneCombo` for full combos after applying the row's scope
   skip/re-validate policy (`fixtureFresh`/file-existence; UNLESS `scope_all=1`); staleness
   re-validated with the row's `stale_by_days`/`stale_by_minutes`; **for `--available` rows,
   re-probe harness availability LIVE and, when still unavailable, re-insert the row unchanged
   (`available=0`, original `created_at`) as queued handoff work for the next agent/platform —
   never trust the stored value for the capture decision**; success → upsert fixture + action
   already removed; failure → re-insert action (refreshing `available` only for `--available`
   rows). Keep `--write-log` tee and `assertNotInAgent`.
10. Rewrite `runKnownAgent` (and `refresh run`) to be **fixtures only**: full → write files +
    upsert fixture row; partial/zero → report + exit 2, no store change; never touches `actions`.
11. Update `knownUsage` help: drop `purge`, store name → `known/index.sqlite3`, remove the
    `--no-*` lines (`--no-harness`, `--no-provider`, `--no-model`, `--no-platform`), document
    `--available` as probe-and-record (not narrow) and the `--unavailable`/`--available=0`
    dequeue match.
12. Wire `migrateIndexJsonl` to run once at first DB open (guarded by "index.jsonl exists AND
    tables empty"), applying the Rollout/migration sanitization rules. After it succeeds, delete
    legacy `known/index.jsonl` + `known/index.jsonl.lock` from the tree and stop reading it.
13. `.gitignore`: add `known/*.sqlite3`, `known/*.sqlite3-journal`, `known/*.sqlite3-wal`; keep
    `known/daemon.log`, `**/*.log`, `**/*.lock` rules.
14. Update `DESIGN.md`: document the two-table model, SQLite dependency, cross-platform `known`
    binaries (replace the native-only/two-binary-split claim; keep released binary minimal with
    separate `-known` artifacts), `dequeue`=delete semantics, daemon-owned fixture sweep, the
    stored `available` probe-status column (with `0` = queued handoff for another platform), and
    the removal of the `--no-*` flags.

## Out of scope / deferred (explicit)

- New action types beyond `capture` (schema column exists; no code paths).
- Auto-reconciling committed `known/*.agent.json` into `fixtures` (user decided: no reconcile;
  `--missing-fixture` keys off filesystem so committed fixtures are not mass re-captured).
- `known purge` (removed by decision); no out-of-band state deletion.
- macOS x86_64 and windows aarch64 `-known` artifacts (not in the requested matrix; released
  detection binary may retain them if the current 6-target `dist` is kept).

## Validation plan

- `zig build` (released, dev=false): compiles; artifact has no SQLite linkage.
- `zig build dist`: emits the 4 `-known` artifacts; each self-contained/static
  (`otool -L`/`ldd`/`file`; no `libsqlite3`, no `sqlite3.dll`; linux shows musl static).
- `zig build dev` (native): compiles and runs on the host.
- `zig build test`: existing `known_fixtures.test.zig` tests pass (unchanged) + new index tests.
- Reproducibility (the failure that started this): `known queue --recipes` then `known queue
  --harness=goose`, inspect `fixtures`/`actions` — no aliased/corrupt rows; goose stays goose; no
  `sonnet` platform bleed.
- Semantics: `known queue` upserts action rows with the correct `scope` tag and performs **no**
  evaluation (no fixtures/file checks at queue time); `known dequeue` DELETEs matching action
  rows (dims + scope) and never touches `fixtures`; `known agent` (direct and `refresh run`)
  writes fixtures only and leaves `actions` untouched (verify `actions` count unchanged after a
  manual capture); the daemon skips-and-completes a full action already covered by a fresh
  fixture UNLESS that action's `scope='all'`.
- Freshness-dedupe: queue `known queue --known=goose-goose-claudesonnet4-darwin`, capture with
  `known agent`, then start the daemon — it must complete (skip) that action without
  re-capturing.
- `--no-*` removed: `known queue --no-model` (and each of `--no-harness`/`--no-provider`/
  `--no-platform`) is rejected/undefined (no longer parsed); confirm no `no_*` fields remain in
  `FilterOptions`/`matchesFilter`/`scopeCandidates`; equivalent seed behavior still achievable
  via bare dims (`known queue --harness=goose` leaves the other dims NULL).
- `available` column: `known queue --recipes --available` on a host where some recipe harness is
  unavailable records that row with `available=0` and KEEPS it queued (not dropped); the daemon
  re-probes live — if still unavailable on this host it re-inserts with `available=0`/original
  `created_at` (queued handoff) and never captures; on the platform where the harness IS
  available it proceeds to capture and upserts the fixture. `--available` may combine with a
  scope only (rejected as sole filter). `known dequeue --unavailable`/`--available=0` matches
  and deletes only `available IS 0` rows. `zig build test` covers the `available` validator rules
  (1/0/NULL, must accompany a scope, dedupe distinguishes probe states).
- Concurrency: `known daemon --write-log` in one terminal while `known queue` / `known dequeue` /
  `known agent` run in another; no lost updates, no torn reads; idle sweep removes malformed
  `*.agent.json`. Repeat at least once on a non-macos target to validate SQLite multi-process
  locking on that host.
- Run the `-known` binary on each of the 4 platforms (or under CI matrix) for daemon +
  queue/dequeue/agent + scope filters (`--all/--stale/--partial/--recipes/--missing-fixture/
  --available`, dims, `--known=`/`--agent=`).
