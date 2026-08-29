# Strip `--from-raw` everywhere; `--from-capture` default; `--from-identity` opt-in; committed state store with success model + `--stale-by-detection`

## Goal

Remove the `from-raw` refresh mode **end-to-end and everywhere**: the
worker, `refresh run`, all `build*Env` fabricators, sandbox-HOME logic,
mode default/ordering, the `queue` table's `from-raw` schema trace, the
committed `from-raw` fixtures, the fixture validator's `from-raw`
acceptance, the mechanical evidence-claim checks, and docs. In its
place:

- `--from-capture` becomes the **default** queue mode (real, observed,
  token-consuming, user-confirmed).
- `--from-identity` stays as an **explicit opt-in** shallow mode:
  declared fixtures for initial recipe authoring and for combos whose
  harness is not installed (the documented contributor path).
- **The state store is committed to git** (`fixtures/index.sqlite3`
  leaves `.gitignore`; journal/wal/shm stay ignored). The queue and
  fixtures state now sync across hosts via git, which is what makes the
  cross-device "redo all fixtures" workflow literal: queue rows for
  other platforms sit in the committed queue until that host's daemon
  pulls and pops them.
- **Role split (hard invariant):** `queue` and `dequeue` never evaluate
  anything — queue enumerates scope rows into the queue table, dequeue
  deletes by filters; **only the daemon evaluates** (availability,
  staleness, success, capture). It now pops only rows for its own
  platform (or NULL-platform seeds, which it expands to its platform).
- **Success-state model:** the `queue.available` column is removed; the
  `fixtures` table gains `success` (1/0/NULL) recording each combo's
  last attempt outcome. Availability failures and generation failures
  both stamp `success=0`; the queue row is consumed (no auto-retry, no
  spin); retry is manual via `queue --unsuccessful` / `queue
  --unavailable` — pure queue scopes over `fixtures.success=0`.
- **All state lives in the table, none in the file:** `generated_at`,
  `harness_version`, `success`, `agent_detect_version` exist only in
  the `fixtures` table. The fixture file carries only `cooked` + `raw`
  + `trailer`. The `origin` key is **dropped entirely** (declared-vs-
  observed is inferable from `raw.evidence`: empty = declared).
- **Cross-device "redo all fixtures"** via `--stale-by-detection`:
  `fixtures.agent_detect_version` (the binary that captured the row) is
  compared against the running binary at pop; stale rows are
  re-captured per host. Contract: format-affecting changes ship with a
  `build.zig.zon` version bump.
- `raw` + `evidence` remain **review artifacts** — not zig-test
  material. All automated evidence-claim validation is removed.
- The committed fixture matrix is regenerated **zero-token**: the 160
  `from-raw` fixtures are deleted and replaced by 177 declared
  `from-identity` fixtures; the 17 existing `from-identity` darwin
  fixtures stay. No `from-capture` fixture is required to commit.

This supersedes `.kilo/plans/1786449399996-strip-from-raw-windows-capture.md`
(docs-only, never implemented) and resolves the open question in
`.kilo/plans/1786449399996-consider-commit-sqlite.md` (Option C —
commit the binary DB — is chosen).

## Confirmed decisions

1. **`--from-raw` is purged everywhere.** Code, CLI surface, usage text,
   schema, committed fixtures, fixture validator, tests, docs, and the
   local DB. The only permitted residue is historical
   `.kilo/plans/*.md` records (not rewritten; this plan supersedes them).
2. **Default mode becomes `from-capture`** — `fixtures queue` with no
   mode flag stamps `from-capture`; `dequeue` with no mode flag still
   filters all modes (unchanged).
3. **`--from-identity` stays as an explicit opt-in** — no implicit
   daemon mode selection. The daemon executes exactly the mode stamped
   on each queue row; the old "daemon will just do from-identity unless
   conditions are met" notion was assumed behavior, never spec.
4. **`queue`/`dequeue` never evaluate; only the daemon evaluates.**
   No probing, no staleness/success judgment in queue/dequeue.
5. **The SQLite state store is committed.** `.gitignore` drops
   `fixtures/*.sqlite3` (keeps `*.sqlite3-journal`, `*-wal`, `*-shm`,
   `daemon.log`, `daemon.ctl`). Consequences:
   - Cross-host queue sync: rows queued on one host (with their
     platform dim) are popped by the matching host's daemon.
   - The daemon pops only rows whose `platform` = host or is NULL
     (seeds); non-host rows stay queued for their host.
   - The lazy file-based backfill shrinks to a repair path (row missing
     but valid file exists → populate unconditionally).
   - Single-writer workflow assumed (binary merge conflicts otherwise).
   - The DB is committed alongside fixtures; it dirties on every
     capture/upsert — commit when work lands, like fixtures.
6. **Success-state model replaces `available`.** `queue.available`,
   `--available`, `--unavailable` (dequeue modifier), `--available=0`,
   and the queue-time probe are removed. `fixtures` gains
   `success INTEGER` (1 = captured, 0 = last attempt failed, NULL =
   never attempted). Availability outcomes fold into `success` — there
   is no separate availability column. Failures are consumed, not
   re-queued; retry is manual via `queue --unsuccessful` and
   `queue --unavailable` — both queue scopes over `fixtures.success=0`
   (one state column; two names, no failure-cause column). No
   auto-retry → no spin by construction (the `probed_at`/cooldown
   deferral design is dropped).
7. **All state in the table, none in the file.** The fixture file is
   `cooked` + `raw` + `trailer` only. `generated_at`,
   `harness_version`, `success`, `agent_detect_version` live only in
   the `fixtures` table. `raw.harness_version` (rule-static, never
   emitted today) is dropped per decision #9 compliance. The file's
   `origin` key is removed entirely (see 8).
8. **`origin` is dropped entirely** — no file key, no table column.
   Its consumers die with it: the post-checks lose the origin check
   (parse + combo-match remain), `fixtureFileOriginRank` is deleted,
   the backfill no longer ranks. Declared-vs-observed is inferable from
   `raw.evidence` (empty = declared). Legacy committed files keep their
   old origin key harmlessly (no validator).
9. **Cross-device redo via `--stale-by-detection`.** New scope flag;
   new `fixtures.agent_detect_version` column (the
   `build_options.version` that captured the row; NULL for backfilled
   rows and legacy rows = stale). The daemon compares it against the
   running binary at pop. Because the table is committed, the version
   state syncs across hosts. Backfilled rows carry NULL (unknown
   provenance → the first `--stale-by-detection` on a fresh host redoes
   them once). Same-version dev churn falls back to per-host
   `--recipes`.
10. **`raw` + `evidence` are review artifacts, not test material.** The
    zig test "observed fixtures pass the evidence-claim check" is
    removed, and the daemon post-check drops its `evidenceClaimsValid`
    gate. `evidenceClaimsValid` + `valueMatchesDim` become orphans and
    are removed. Detection still *records* evidence claims;
    recording, redaction, and `providerForBaseUrl` stay.
11. **Committed fixtures: purge and regenerate zero-token.** Delete the
    160 `fixtures/*.json` with `origin == "from-raw"`. Keep the 17
    committed `from-identity` fixtures. Regenerate the full matrix as
    declared fixtures (`fixtures queue --recipes --from-identity` +
    daemon → 177 new `-windows.json`). The origin fixture test is
    removed (no origin key anymore).
12. **Database migration is a one-time committed change.** The
    implementer: `fixtures dequeue --all` (drops every queue row),
    `DROP TABLE IF EXISTS queue;` (recreated with the new DDL on the
    next command), and `ALTER TABLE fixtures ADD COLUMN success
    INTEGER; ADD COLUMN agent_detect_version TEXT;` (the `fixtures`
    table is not recreated by `ensureSchema`). The migrated DB is
    committed with the strip.

## DB vs fixture-file duplication map (what lives where)

Current `fixtures` table: `harness`, `provider`, `model`, `platform`
(PK), `runner`, `generated_at`, `harness_version`. Current `queue`
table: dims (nullable) + `scope_partial`/`scope_recipes`/
`scope_missing_fixture` + `stale_by_minutes`/`stale_by_version` +
`available` + `runner`/`created_at` + `mode` (dedupe index on dims +
scopes + `available`). Fixture file today: `cooked` (18 fields), `raw`
(`platform_id`, `detectable`, `detected`, `process_lineage`,
`*-urls`, `evidence`, optional `harness_version`), `trailer`,
`origin`.

After this plan:

| data | table | file | verdict |
|---|---|---|---|
| 4 dims | slugs | cooked names/ids | necessary overlap; file authoritative, table derived (backfill) |
| platform | column | raw.platform_id | necessary (PK/queries vs portable artifact) |
| generated_at | column | **absent** | table-only (files carry no timestamps → content-only churn); doubles as "last attempt" with `success` |
| harness_version (live) | column | **absent** | table-only (the raw rule-static key is dropped) |
| success / availability outcome | **new `success`** | absent | table-only — per-host attempt state, committed with the DB |
| agent_detect_version | **new column** | absent | table-only — committed DB syncs it cross-host; backfilled rows = NULL (stale) |
| origin | **dropped** | **dropped** | gone entirely; class inferable from `raw.evidence` |
| runner / scope markers / stale markers / mode | queue only | absent | transient work state |

## The success model (how failures flow)

1. `fixtures queue <scope> [--from-identity|--from-capture]` — pure
   enqueue. No probing, no evaluation. Table-based scopes
   (`--all`, `--stale-by-*`, `--unsuccessful`, `--unavailable`) queue
   rows with their stored platform (any host's rows); `--recipes`/
   `--missing-fixture` stay host-platform.
2. The daemon pops only rows for its own platform (or NULL-platform
   seeds, which it expands to host-platform full rows) and evaluates:
   - **Availability** (from-capture only — from-identity needs no
     harness): probe `harnessAvailable`; unavailable → upsert
     `fixtures` row (`success=0`, `generated_at=now`,
     `harness_version=null`, `agent_detect_version=null`), log, row
     **consumed** (never re-queued). No spin by construction.
   - **Staleness markers** (unchanged): skip only when every marker the
     row carries is fresh.
   - **Generation**: worker success → `success=1` + fresh
     `generated_at`/`harness_version`/`agent_detect_version`; worker
     failure → `success=0`, row consumed. The from-capture 3-attempt
     cap is removed — every retry is user-driven.
3. `queue --unsuccessful` / `queue --unavailable` — pure queue scopes:
   enumerate `fixtures` rows with `success=0` (any platform) and
   enqueue them for retry (dim filters + mode flag compose). Run it on
   whichever host has the harness installed — the row's platform
   ensures only that host's daemon pops it.
4. Never-attempted combos have no `fixtures` row — covered by
   `--recipes`/`--missing-fixture`. `--all`/`--stale-by-*` enumerate
   all rows regardless of `success`.
5. Files never carry `success` — per-host attempt state lives in the
   committed table.

## Cross-device redo: `--stale-by-detection`

Goal scenario: format change on macOS → redo every platform's
fixtures. Darwin can only be captured on macOS, windows/linux on those
hosts (`platform_id` is compile-time). With the committed DB the intent
travels in git:

1. On macOS after a format change + version bump:
   `fixtures queue --stale-by-detection [--from-identity]` → the scope
   enumerates **all** `fixtures` rows whose `agent_detect_version`
   differs from (or is NULL vs) the running binary's version, queued
   with their stored platform → darwin rows are popped and regenerated
   by the macOS daemon; windows/linux rows sit in the committed queue.
   Commit fixtures + DB.
2. On Windows later (after pull): the daemon pops only the windows
   rows → regenerates only windows fixtures → commit.
3. Linux likewise.

Mechanism:

- **Column:** new `fixtures.agent_detect_version TEXT` — stamped by the
  daemon's success-path upserts (and `runFixturesCapture`) with
  `build_options.version`; NULL for backfilled rows and legacy rows
  (= stale). `runOneComboIdentity`'s rows get the daemon's stamp on its
  success upsert (no file stamping at all).
- **Flag:** new scope flag `--stale-by-detection` on `queue`/`dequeue`,
  mirroring `--stale-by-version`: parses, stamps a new queue column
  `stale_by_detection INTEGER` (in `queue_dedupe` like
  `stale_by_version`), enumerates the `fixtures` table (all platforms),
  and is filtered by `dequeue`.
- **Pop-time evaluation (daemon only):** the staleness block gains a
  `detection_fresh` term — `fixtureRow(...).agent_detect_version`
  equals `build_options.version` → fresh; NULL/mismatch → stale. A row
  skips only when every marker it carries is fresh (age AND
  harness-version AND agent-detect-version).
- **Backfill ordering fix (latent bug):** the lazy backfill currently
  completes rows *before* the staleness block runs, so a stale-marker
  row with no `fixtures` row would be backfilled without evaluation.
  Gate the backfill on the absence of any stale marker
  (`stale_by_minutes`, `stale_by_version`, `stale_by_detection`) so
  marked rows always capture. (A `success=0` row also blocks the
  backfill naturally — it exists.)
- **Caveats:** a format change without a version bump does not fire
  `--stale-by-detection`; fall back to `--recipes`. First-time hosts
  with an empty table enumerate nothing — use `--recipes`. Combines
  with either mode flag.

## Current `from-raw` surface in `src/main.zig` (verified 2026-08-12)

- Worker: `runOneComboResult` (~5985-6150) + daemon call site (~5803) +
  `postCheckComboFixture(..., "from-raw")` (~6132).
- Subcommand: `refresh run` dispatch (~6760-6768) + doc comments
  (~3021, 3034, 5108-5128) + `devUsage` line (~2775) + `mainInner`
  comment (~6707-6708).
- Fabricators: all `build*Env` (~3988-4341) — cline/kimi/mmx/goose/pi/
  qwen/omp/reasonix/crush/kilo/opencode/vibe/cursor/copilot. 177
  `.buildEnv = buildXxxEnv` references in `recipesForFixtures`
  (~4348-4597) must be dropped with the field.
- Support orphans: `EnvSetup`/`WriteSpec` (~3801-3817),
  `RecipesForFixtures.buildEnv` field (~3827-3832), `resolveHome`
  (~3904-3907), `DevProviderMeta`/`devProviderMeta`/`devProviderMetaFor`
  (~3910-3951), `canonicalHarnessName`/`canonicalProviderName`/
  `canonicalModelName`/`comboDims` (~3953-3986), sandbox-HOME block
  (~6025-6037), `AGENT_DETECT_FIXTURE_ORIGIN="from-raw"` (~6037).
- Mode surface: `QueueRow.mode` default (~3444), schema default
  `'from-raw'` (~3400), mode parse (~4850), default stamp (~4863),
  pop ORDER BY / DELETE CASE (~3682, 3695), `modeRank` (~5848-5852).
- `available` surface: column + dedupe entry (~3397, 3407-3408),
  `QueueRow.available` (~3441), upsert/select/parse, `validateQueueRow`
  (~3765-3766), `parseFilters` `--available`/`--unavailable`/
  `--available=0` + implies-`--all` (~4840-4890), `scopeCandidates`
  probe stamps (~5042-5044, ~5094-5097), daemon gate (~5770-5781).
- `origin` surface: `runFixturesCapture` origin write + env read
  (~5175-5182), `runOneComboIdentity` origin write (~6405),
  `postCheckComboFixture` origin check (~6196-6207),
  `postCheckDeclaredFixture` origin check (~6236-6240),
  `fixtureFileOriginRank` (~5881-5906), backfill rank gate (~5703-5723),
  `known_fixtures.test.zig` origin test (~514-546) + comments.
- Evidence machinery: `evidenceClaimsValid` (~6295-6340) +
  `valueMatchesDim` (~6348-6370) — orphans; the call in
  `postCheckComboFixture` (~6208). `providerForBaseUrl` (~914)
  **stays** (live claim recording ~1751).
- `assertNotInAgent` env-marker comment (~6596-6599) — fix, keep
  markers.
- **Stays**: `harnessVersion`/`scanVersionToken` (version stamp +
  `--stale-by-version`), `probeBinary`/`harnessAvailable` (daemon-only
  availability check), `capture_prompt`, `runOneComboIdentity`,
  `runOneComboCapture`, `runTimeoutWorker`/`killPid`, evidence claim
  *recording* (`addEvidenceClaim`, `envValueAllowed`, `buildRaw`
  evidence block).

## Tasks

### 1. Strip `from-raw` from `src/main.zig`

- Delete `runOneComboResult` and its daemon call-site branch (~5803);
  the daemon branches only between `runOneComboIdentity` and
  `runOneComboCapture`.
- Delete the `refresh run` dispatch in `mainInner` (~6760-6768) and the
  `refresh run` line in `devUsage` (~2775); update the surrounding doc
  comments (~3021, 3034, 5108-5128, 6707-6708).
- Delete all `build*Env` (~3988-4341), `EnvSetup`/`WriteSpec`
  (~3801-3817), `resolveHome` (~3904), `DevProviderMeta` +
  `devProviderMetaFor` (~3910-3951), `canonicalHarnessName`/
  `canonicalProviderName`/`canonicalModelName`/`comboDims`
  (~3953-3986) — each confirmed orphaned.
- Drop `RecipesForFixtures.buildEnv` (~3827-3832) and remove the
  `.buildEnv = buildXxxEnv` field from **all 177** `recipesForFixtures`
  entries (~4348-4597); recipes keep `agent_id`, `probeNames`,
  `launch`.
- Remove the sandbox-HOME block (~6025-6037) and the
  `AGENT_DETECT_FIXTURE_ORIGIN="from-raw"` put.
- Update `assertNotInAgent` comment (~6596-6599).
- Grep `from-raw` in `src/` after editing — zero matches.

### 2. Evidence-claim checks removed (review-artifact reframing)

- `postCheckComboFixture` (~6159-6215): drop the `evidenceClaimsValid`
  call (~6208) and the origin check (~6196-6207); keep parse and
  `cooked.agent_id` combo-match.
- `postCheckDeclaredFixture` (~6221-6247): drop the origin check
  (~6236-6240); keep the cooked dims match.
- Delete `evidenceClaimsValid` (~6295-6340) and `valueMatchesDim`
  (~6348-6370) — orphans. Keep `providerForBaseUrl`.
- Keep evidence claim *recording* untouched: `addEvidenceClaim`,
  `envValueAllowed`/`isEnvValueAllowed`, the `buildRaw` evidence block
  (~3267-3287).

### 3. Two-mode model: default `from-capture`

- Mode parse (~4850): accept only `--from-identity` / `--from-capture`;
  two together → exit 3.
- Default stamp (~4863) and `QueueRow.mode` default (~3444): `from-raw`
  → `from-capture`. Schema default (~3400): `'from-capture'`.
- `popQueueRow` SELECT + DELETE CASE (~3682, 3695) and `modeRank`
  (~5848-5852): two-way — `from-identity` (0) < `from-capture` (1).
- `runFixturesCapture` (~5169-5182): drop the origin write and the
  `AGENT_DETECT_FIXTURE_ORIGIN` read entirely — the fixture file has no
  origin key.
- Usage text: `queueDequeueFlags` (~3100-3136), `devUsage`
  (~2765-2777), `FilterOptions.mode` doc (~4767).

### 4. Origin removal (file key gone; post-checks/backfill simplified)

- `runFixturesCapture` and `runOneComboIdentity`: no `origin` key in
  the written file (covered in T3/T7).
- Delete `fixtureFileOriginRank` (~5881-5906) and `modeRank`'s origin
  comment; the lazy backfill (~5693-5724) becomes: no `fixtures` row +
  valid committed file + no stale markers → populate the row
  (`success=1`, `generated_at=now`, `harness_version=null`,
  `agent_detect_version=null`) and complete without capture.
- The "raw is slim" fixture test: drop the `harness_version` allowance
  (~250) — the raw fixed key set is now `platform_id`, `detectable`,
  `detected`, `process_lineage`, `*-urls`, `evidence`.

### 5. Success-state model (replaces `available`)

- **Schema:** `queue` DDL (~3387-3401) drops `available`; `queue_dedupe`
  (~3402-3408) drops `COALESCE(available,0)`. `fixtures` DDL
  (~3377-3386) gains `success INTEGER` and `agent_detect_version TEXT`
  (both nullable).
- **`FixtureRow` (~3451-3459):** add `success: ?i64 = null` and
  `agent_detect_version: ?[]const u8 = null`; add to `upsertFixture`
  (~3529-3540), `selectFixtures` (~3543-3544), `jsonToFixtures`
  (~3551-3569), `fixtureRow` (~3662-3674).
- **Writers set `success=1` + `agent_detect_version`:** the daemon's
  success-path upserts (~5605, ~5813) and `runFixturesCapture` upsert
  (~5210) stamp both; the lazy backfill stamps `success=1` and NULL
  version (T4).
- **`QueueRow` (~3431-3445):** drop `available`; remove from
  `upsertQueueRow` (~3496-3523), `selectSeedQueueRows` (~3573-3574),
  `jsonToQueueRow` (~3595-3611), `popQueueRow` SELECT (~3682),
  `deleteQueueRows` WHERE (~3720-3721), `validateQueueRow`
  (~3765-3766), `scopeCandidates` stamps (~5042-5044, ~5094-5097).
- **`parseFilters` (~4840-4890):** remove `--available`,
  `--unavailable`, `--available=0` and the implies-`--all` logic; add
  `--unsuccessful` and `--unavailable` as **queue scope flags**
  (`f.unsuccessful`/`f.unavailable`, both enumerating
  `fixtures.success=0` — pure state reads, no probing); include them in
  `scope_count`/`scopeCount`. Rejected on `dequeue` (queue-only
  scopes).
- **`scopeCandidates`:** new branch — `--unsuccessful`/`--unavailable`
  select `fixtures` rows WHERE `success=0` (dim filters + mode flag
  compose), queued with their stored platform.
- **Daemon (~5770-5781):** replace the flag-gated availability check
  with a mode-based one — from-capture rows always probe
  `harnessAvailable`; unavailable → upsert `fixtures` row with
  `success=0` (`generated_at=now`, `harness_version=null`,
  `agent_detect_version=null`, `runner` = daemon pid), log, **consume
  the row**. from-identity rows skip the check.
- **Worker failure paths (~5822-5830, from-capture phase
  ~5617-5638):** replace re-queue logic with: upsert `fixtures` row
  `success=0`, consume the row. Remove the `capture_attempts`
  3-attempt map (~5532, ~5599-5637).
- **Help text:** `queueDequeueFlags` — drop the `--available`/
  `--unavailable` modifiers; add `--unsuccessful`/`--unavailable`
  scope lines ("queue rows for fixtures whose last attempt failed").

### 6. Platform-aware popping (committed-queue requirement)

- `popQueueRow` (~3682, 3695): append
  `AND (platform IS NULL OR platform = '<host>')` to both the SELECT
  and the DELETE subselect — non-host rows stay queued for their host;
  NULL-platform seeds are expanded by the host daemon via `expandSeed`
  (which already stamps host platform). Update the doc comment.

### 7. `--stale-by-detection` (cross-device redo)

- New queue column `stale_by_detection INTEGER` (DDL + `queue_dedupe` +
  `QueueRow` + upsert/select/parse), mirroring `stale_by_version`.
- `parseFilters`: `--stale-by-detection` → `f.stale_by_detection =
  true`; include in `scope_count`/`scopeCount`; `--partial` guard
  (~5055) rejects combination.
- `validateQueueRow` (~3754-3771): staleness scope unit = age-marker
  OR version-marker OR detection-marker (counts once; ANDs with the
  other markers).
- `deleteQueueRows` (~3718-3722): `AND stale_by_detection=1`.
- `scopeCandidates` fixtures-table branch (~5077-5100): stamp
  `row.stale_by_detection = 1` (rows keep their stored platform).
- Daemon staleness block (~5732-5765): add the detection term —
  `detection_fresh = fixtureRow.agent_detect_version equals
  build_options.version` (NULL/missing row → not fresh); skip only
  when age_fresh AND version_equal AND detection_fresh.
- Backfill ordering fix (~5693-5724): gate the backfill on the absence
  of all three stale markers (see T4).
- Help text: `queueDequeueFlags` gains the `--stale-by-detection`
  scope line.

### 8. Replace from-raw's zero-token `detect()` coverage (the main orphan)

New `src/detect_ladder.test.zig`: an in-process regression test that
exercises the live detection ladder against synthetic state.

- Feasibility verified against zig 0.16 std: `std.process.Init` is a
  plain struct — construct it directly in the test:
  ```zig
  var arena = std.heap.ArenaAllocator.init(testing.allocator);
  var env_map = std.process.Environ.Map.init(arena.allocator());
  try env_map.put("KILO_API_KEY", "fake");
  // ... recipe marker env + HOME temp-dir entries ...
  const init = std.process.Init{
      .minimal = .{ .environ = std.process.Environ.empty, .args = .{ .vector = &.{} } },
      .arena = &arena,
      .gpa = testing.allocator,
      .io = std.testing.io,
      .environ_map = &env_map,
      .preopens = .{},
  };
  var d = main.Detection{};
  _ = try main.detect(init, &d);
  ```
- Env-marker-first scanning makes resolution deterministic even when the
  test runner runs inside a harness: set the recipe's marker env
  (`KILO_MODEL`/`KILO_API_KEY`, `MMX_CONFIG_DIR`,
  `PI_CODING_AGENT`+`PI_PROVIDER`+`PI_MODEL`, `GOOSE_*`, `CLINE_*`);
  for one config-reading case (qwen/kimi), point HOME at a temp dir
  with the fabricated config.
- Cover a representative subset, not all 177 recipes. Add the file to
  `build.zig` `test_files` (~105-108).

### 9. Tests: `known_fixtures.test.zig`

- Delete the origin test (~514-546) — the file has no origin key.
- Delete the test "fixtures: observed (from-raw/from-capture) fixtures
  pass the evidence-claim check" (~548-576) — evidence is a review
  artifact (and `evidenceClaimsValid` is removed).
- "raw is slim" (~222-274): drop the `harness_version` allowance; the
  fixed raw key set is `platform_id`, `detectable`, `detected`,
  `process_lineage`, `*-urls`, `evidence`.
- Update comments describing `from-raw` as producible (~476-478, 516,
  553) and the `main.dev.evidenceClaimsValid` reference.

### 10. Fixture purge + zero-token regeneration

- `git rm` the 160 committed fixtures with `origin == "from-raw"`.
- Keep the 17 committed `from-identity` fixtures (their legacy origin
  keys are harmless — no validator reads them).
- Regenerate the full matrix as declared fixtures (zero tokens):
  ```pwsh
  $env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' +
              [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + $env:PATH
  .\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes --from-identity
  .\zig-out\bin\agent-detect-dev.exe fixtures daemon --write-log
  ```
  → 177 new `fixtures/<id>-windows.json` declared fixtures (cooked +
  raw + trailer, no origin key). The daemon's success upserts stamp
  `success=1` + `agent_detect_version` into the table.
- **reasonix host state:** reasonix is now configured and available on
  this Windows host — its combos probe available, so it is **not** an
  example of an unavailable harness anywhere in this plan; the
  unavailable messaging/behaviour notes (mode-based availability
  check, `success=0`, row consumed, manual retry via
  `--unsuccessful`/`--unavailable`) remain generic. Of the three
  reasonix recipes, only `reasonix-deepseekflash-deepseekv4flash` has
  a launch spec (from-capture-able); `reasonix-deepseek-deepseekv4flash`
  and `reasonix-minimax-minimaxm3` have none → from-identity-only
  (a from-capture row without a launch spec is warned by the daemon
  and fails — keep those queued as `--from-identity`).
- Result: 194 committed fixtures — 17 darwin + 177 windows declared.

### 11. Database migration + commit (one-time, then tracked)

On the implementer machine, with the newly built dev binary:

```pwsh
.\zig-out\bin\agent-detect-dev.exe fixtures dequeue --all            # drops EVERY queue row (WHERE 1=1)
sqlite3 fixtures/index.sqlite3 "DROP TABLE IF EXISTS queue;"         # recreated with the new DDL on next command
sqlite3 fixtures/index.sqlite3 "ALTER TABLE fixtures ADD COLUMN success INTEGER;"
sqlite3 fixtures/index.sqlite3 "ALTER TABLE fixtures ADD COLUMN agent_detect_version TEXT;"
```

- `.gitignore` (~77-81): remove `fixtures/*.sqlite3`; keep
  `fixtures/*.sqlite3-journal`, `*-wal`, `*-shm` (and `daemon.log`,
  `daemon.ctl`) ignored; update the comment — the store is now
  committed state.
- Commit the migrated DB with the strip; from then on it is tracked
  like the fixtures (commit when work lands).
- Alternative (cleanest if the local DB is disposable): delete
  `fixtures/index.sqlite3` entirely — `ensureSchema` recreates both
  tables with the new schema and the lazy backfill repopulates
  `fixtures` from the committed files.

### 12. Docs

- `DESIGN.md`:
  - "two-binary split" (~29-45): drop the `refresh run` mention.
  - "SQLite state store" (~98-136): rewrite — committed store,
    per-host `platform` rows coexist, the daemon pops only host rows,
    `mode` default `from-capture`, no `available`, `fixtures.success`
    (1/0/NULL; failures consumed, manual retry via
    `--unsuccessful`/`--unavailable`), `fixtures.agent_detect_version`
    (cross-device staleness), the role split (queue/dequeue never
    evaluate).
  - "lazy file-based backfill" (~138-150): repair-only path —
    unconditional on a valid file, never when a row exists, never for
    stale-marker rows; no origin rank.
  - "Evidence-attribution rule (decision #11)" (~436-443): rewrite —
    raw + evidence are recorded for human/dev-agent review; no
    mechanical code gate or test.
  - "Refresh flavours" (~449-456): two modes — `from-identity`
    (explicit opt-in, declared, recipe authoring / uninstalled
    harnesses) and `from-capture` (**default**, real, token-consuming,
    user-confirmed); the file carries `cooked`/`raw`/`trailer` only
    (no `origin`).
  - Remove the "daemon will just do from-identity unless conditions are
    met" implication wherever it appears.
- `CONTRIBUTING.md`: "refresh a fixture" flow (~8-128); "common expected
  failures" (~130-149 — failures stamp `success=0`, retried via
  `queue --unsuccessful`); probing runbook (~183-203); monitoring
  runbook (~234-251); "refresh / token warning" (~319-329);
  global-settings rule (~331-336 — no worker config writes exist
  anymore); add-a-harness step 2 (~395); pending harnesses (~522-538).
  Add the cross-device workflow: format change + version bump →
  `fixtures queue --stale-by-detection [--from-identity]` on each host
  → commit fixtures + DB per platform. Add the committed-store note:
  commit `fixtures/index.sqlite3` with each fixture change; never
  commit journal/wal/shm or daemon files.
- `AGENTS.md` (~63): replace the "from-raw fixture worker" sentence —
  `agent-detect` no longer writes any harness config; the hard rule
  simplifies to "never create/modify harness config/auth files or set
  API keys; agent-detect reads them read-only".
- `build.zig` (~70-71): drop `refresh run` from the dev-binary comment.
- `README.md`: no mode references — no change.
- Historical `.kilo/plans/*.md` remain records; do not rewrite.

### 13. Build + validate

```pwsh
zig build
zig build dev
zig build test
```

- `git grep -ni "from-raw" src/ fixtures/ CONTRIBUTING.md DESIGN.md AGENTS.md build.zig`
  → zero matches.
- `git grep -n "refresh run"` → no matches outside `.kilo/plans/`.
- `git grep -n "evidenceClaimsValid\|valueMatchesDim\|fixtureFileOriginRank"` →
  zero matches.
- `git grep -n "available" src/` → zero matches.
- `git grep -n '"origin"' src/ fixtures/` → zero matches (legacy 17
  darwin files may retain the key on disk until regenerated — flag and
  accept, or leave as historical; no code reads it).
- `git ls-files fixtures/index.sqlite3` → tracked; `.gitignore` no
  longer excludes it (journal/wal/shm still ignored).
- Help surface: two modes (default `from-capture`),
  `--unsuccessful`/`--unavailable`, `--stale-by-detection`, no
  `--available`, no `refresh run`.
- DB: `PRAGMA table_info(queue)` → no `available`, has
  `stale_by_detection`; `PRAGMA table_info(fixtures)` → has `success`
  and `agent_detect_version`.
- Behavior check: queue a from-capture row for an uninstalled harness →
  daemon consumes it (single attempt in the log, no repeats), the
  `fixtures` row gains `success=0`; `queue --unsuccessful` re-enqueues
  it. A row whose `platform` ≠ host stays queued (never popped on the
  wrong host).
- Regenerated fixtures: no `origin` key; table rows carry
  `success=1` + a non-empty `agent_detect_version`.

## Commit grouping (AGENTS.md/commits.md: build first, trailer via
`./zig-out/bin/agent-detect trailer co-author`, attach with
`git commit --trailer "$(...)"`)

- commit 1 — code: strip (T1-T3), evidence removal (T2), origin removal
  (T4), success model (T5), platform-aware popping (T6),
  `--stale-by-detection` (T7), detect-ladder test (T8), fixture-test
  purge (T9), `.gitignore` change (T11).
- commit 2 — the migrated `fixtures/index.sqlite3` (T11) + fixture
  purge/regeneration (T10) + docs (T12) + this plan file.

## Validation

- `zig build test` green after commit 1 (the 17 committed
  `from-identity` fixtures pass the tightened raw-shape tests; the
  origin and evidence tests are gone) and after commit 2 (194 declared
  fixtures).
- `git status` clean after commits — the DB is now tracked, so it must
  be committed, not ignored.
- No `from-raw` residue anywhere: code, CLI, schema, fixtures, tests,
  live docs.

## Risks / notes

- The 160 `from-raw` fixtures are deleted, not re-tagged — they cannot
  be reproduced (fabricators removed).
- The regenerated matrix is entirely declared (`from-identity`):
  evidence arrays are empty by design; real captures are produced on
  demand via `--from-capture` (token-consuming, user-confirmed).
- **No auto-retry by design:** a transient from-capture failure (rate
  limit, timeout) requires a manual `queue --unsuccessful` retry.
  Trade-off accepted in the success model.
- `--unsuccessful` and `--unavailable` are two names for the same
  `success=0` scope (no failure-cause column).
- **Committed DB:** the store dirties on every capture/upsert — commit
  it with each work landing, like fixtures. Binary merge conflicts are
  possible if two hosts commit concurrently; single-writer workflow
  assumed. `runner`/`created_at` are per-host noise by design.
- **Platform-aware popping is required** for the committed queue to
  work; without it a host would pop and mis-capture another platform's
  rows.
- `--stale-by-detection` requires a `build.zig.zon` version bump to
  fire; same-version format churn falls back to per-host `--recipes`.
  Backfilled and legacy rows carry NULL `agent_detect_version` → the
  first `--stale-by-detection` on a host redoes them once.
- The backfill-gating change (T7/T4) fixes a latent bypass: stale
  marker rows with no `fixtures` row are no longer completed without
  evaluation.
- `fixtures.success` is per-host attempt state; committed fixture
  files never carry it (no churn, no duplication — see the map).
- `dequeue` with no mode flag keeps filtering all modes (unchanged);
  only the queue *stamp* default changes.
