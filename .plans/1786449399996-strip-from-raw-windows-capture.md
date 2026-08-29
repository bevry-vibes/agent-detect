# Strip from-raw; capture Windows fixtures (from-identity + from-capture)

## Goal

1. Remove the `from-raw` capture mode end-to-end; `from-identity` becomes
   the default.
2. Capture Windows fixtures: `from-identity` for all 177 recipes
   (declared, zero-token), plus `from-capture` for every combo with a
   launch spec (real evidence, token-consuming, user-confirmed), driven
   by `fixtures queue` calls.
3. Review and commit the Windows fixtures.

## Decisions (confirmed with user)

- **Full removal of from-raw**: worker (`runOneComboResult`), `refresh run`
  subcommand, all `build*Env` fabricators, `EnvSetup`/`WriteSpec`,
  `resolveHome`, `devProviderMetaFor`, sandbox-HOME logic, the
  `AGENT_DETECT_FIXTURE_ORIGIN="from-raw"` value, mode parsing/default/
  ordering, and docs. `from-identity` becomes the default mode.
- **Windows batch**: `fixtures queue --recipes` (from-identity, all 177)
  then `fixtures queue --recipes --from-capture` (every launch-spec
  combo; from-capture rows replace the identity rows for the same combo
  because `mode` is not in the queue dedupe key). Combos without a
  launch spec stay declared.
- **Darwin fixtures stay**: committed `fixtures/*-darwin.json` with
  `origin: "from-raw"` remain historical artifacts; the fixture
  validator keeps accepting the `"from-raw"` origin string.
- **reasonix**: declared `from-identity` fixture only (2 combos have no
  launch spec; the one that does is gated `available=0` → handoff).

## Verified facts

- from-raw surface in `src/main.zig`: mode default `'from-raw'` (3400,
  3444, 4863), mode parsing (4850), daemon ordering (3682, 3695),
  `runOneComboResult` (5985) + call site (5803), `refresh run` (5108,
  6761), all `build*Env` (3988-4328), `EnvSetup` (3801), `resolveHome`
  (3904), `devProviderMetaFor` (3946), sandbox (6025-6037), origin rank
  (5847-5904), from-raw version stamping (5809-5812), post-check (6132),
  usage text (2775, 3102-3107, 3132-3135).
- Queue holds 177 recipe rows in mode `from-raw` (stale after the strip
  — must be dequeued and re-queued).
- `known_fixtures.test.zig` keeps `"from-raw"` as a valid origin and the
  observed-fixture evidence check covers committed darwin fixtures.
- `runOneComboIdentity` (6378) and `runOneComboCapture` (6442) stay.

## Tasks

### 1. Strip from-raw in `src/main.zig`

- Mode: delete `"from-raw"` from `parseFilters` (4850), the default
  stamp (4863), `QueueRow.mode` default → `"from-identity"` (3444), the
  `CREATE TABLE` default → `'from-identity'` (3400), the daemon pop
  ORDER BY CASE (3682) and DELETE (3695), `modeRank` (5847-5850).
- Remove `runOneComboResult` (5985) and its branch (5803); the daemon
  branches only between `runOneComboIdentity` and `runOneComboCapture`.
- Remove the `refresh run` subcommand (5108, 6761) and its usage line
  (2775).
- Remove `RecipesForFixtures.buildEnv` (3827), all `build*Env`
  (3988-4328), `EnvSetup`/`WriteSpec` (3801-3817), `resolveHome`
  (3904), `DevProviderMeta`/`devProviderMetaFor` (3910, 3946) and the
  provider-meta table if otherwise unused.
- Remove the sandbox-HOME block (6025-6037) and
  `AGENT_DETECT_FIXTURE_ORIGIN="from-raw"` (6037).
- Simplify `harnessVersion` stamping (5809-5812) to from-capture only.
- Remove the `postCheckComboFixture(..., "from-raw")` call (6132).
- Collapse origin rank/backfill (5875-5904) to the two remaining modes.
- Update usage text (2767-2775, 3102-3107): drop `--from-raw`,
  document `from-identity` as default.
- Keep `"from-raw"` valid in the fixture origin validator (committed
  darwin fixtures).

### 2. Update docs

- `CONTRIBUTING.md`: mode list/default, the runbook commands
  (187-203), "common expected failures" (130-149), install-table note if
  it references from-raw.
- `DESIGN.md`: mode descriptions (decision #7, 437-456).
- `README.md` only if it mentions the modes.

### 3. Build + tests

```pwsh
zig build
zig build test
zig build dev
```

### 4. Re-queue the Windows batch

```pwsh
$env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' +
            [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + $env:PATH
.\zig-out\bin\agent-detect-dev.exe fixtures dequeue --recipes
.\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes                 # all 177, from-identity (default)
.\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes --from-capture   # launch-spec combos (real evidence)
```

- from-capture rows replace identity rows for the same combo (dedupe key
  excludes `mode`).
- Combos without a launch spec (pi-anthropic-claudesonnet4, pi-groq-\*,
  pi-xai-grok4, pi-kimi-kimik3, reasonix-deepseek-deepseekv4flash,
  reasonix-minimax-minimaxm3) get warned by the daemon; re-queue those
  specifically as `--from-identity` if needed.
- reasonix capture rows gate on `available=0` → re-queued as handoff.

### 5. User runs the daemon (fresh terminal, user-only)

```pwsh
.\zig-out\bin\agent-detect-dev.exe fixtures daemon --write-log
```

- from-identity workers write declared fixtures (fast, zero-token).
- from-capture jobs announce ~15s before each capture
  (`--capture-review-seconds`); token-consuming — stop with Ctrl+C or
  write `stop` to `fixtures/daemon.ctl`. Trim scope per-harness with
  `fixtures queue --harness=H --from-capture` if the cost is too high.
- Watch `fixtures/daemon.log`.

### 6. Review + commit fixtures

- Verify each `fixtures/<id>-windows.json`: cooked dims, `origin` is
  `from-identity` or `from-capture`, evidence present on capture
  fixtures.
- `zig build test` stays green (known_fixtures validates the new
  windows fixtures).
- Commit with the generated trailer.

## Validation

- `sqlite3 fixtures/index.sqlite3 "SELECT mode, COUNT(*) FROM queue GROUP BY mode;"`
  → only `from-identity` + `from-capture` rows (no `from-raw`).
- `sqlite3 fixtures/index.sqlite3 "SELECT COUNT(*) FROM fixtures WHERE platform='windows';"`
  → 177 fixture files (one per combo).
- `zig build test` green after the strip and after the fixture commit.
- `git status` clean after the commits (index.sqlite3 gitignored).

## Risks / notes

- from-capture for ~169 combos = ~169 real model sessions (token-heavy);
  the daemon pauses before each and can be stopped/trimmed.
- Stale `from-raw` queue rows are invalid after the strip — task 5
  clears them.
- Committed darwin fixtures keep `origin: "from-raw"`; do not delete or
  re-tag them.
- `fixtures capture` (the in-agent capture used by from-capture) is
  unchanged.
