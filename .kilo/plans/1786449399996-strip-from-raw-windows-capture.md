# Strip from-raw; capture Windows fixtures (from-identity + from-capture)

## Goal

1. Commit the current working tree (AGENTS.md hard rule + the previous
   plan file, which stays as the record of the pre-strip state).
2. Remove the `from-raw` capture mode end-to-end; `from-identity` becomes
   the default.
3. Capture Windows fixtures: `from-identity` for all 177 recipes
   (declared, zero-token), plus `from-capture` for every combo with a
   launch spec (real evidence, token-consuming, user-confirmed), driven
   by `fixtures queue` calls.
4. Review and commit the Windows fixtures.

## Decisions (confirmed with user)

- **Full removal of from-raw**: worker (`runOneComboResult`), `refresh
  run` subcommand, all `build*Env` fabricators, `EnvSetup`/`WriteSpec`,
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

- Uncommitted (before this plan): `AGENTS.md` (+13: harness-config hard
  rule) and the previous plan file (pre-strip record).
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

## Open question: should `fixtures/index.sqlite3` be committed to git?

The index DB is currently gitignored (`fixtures/*.sqlite3` plus the
`-journal`/`-wal`/`-shm` variants in `.gitignore`, rationale: "carries
per-host queue state and fixture history — never committed"). This work
is being handed off to a different environment, so the trade-off is
live.

### Option A — keep gitignored (current; recommended default)

**Pros**
- The `fixtures/*.json` files are the durable, reviewable artifact.
  The daemon lazily backfills `fixtures` rows from any valid committed
  `fixtures/<id>.json`, and `fixtures queue --recipes --available`
  rebuilds the queue + probe state on a fresh machine (~6 min here).
  A new environment fully reconstructs the index with two commands.
- SQLite is binary: diffs are unreadable, and every probe/re-queue
  rewrites the file — noisy, unmergeable commits.
- `queue` rows are per-host by design (`runner` pid, `created_at`,
  `available` probe results, platform).

**Costs**
- No single committed manifest of capture state (`generated_at`,
  `runner`, `harness_version`) — the JSON files carry `trailer`/
  `origin` per fixture but no aggregate index.
- A fresh environment must re-run the availability probe to restore
  `available` flags and the reasonix handoff rows.
- Two environments writing the DB concurrently would conflict.

### Option B — commit a text manifest instead of the binary

Commit a generated `fixtures/manifest.txt` (or `.json`) derived from the
committed `fixtures/*.json`: `harness|provider|model|platform|origin`
per row. Gives the audit + portability with readable, mergeable diffs.
Cost: a small generator step that must stay in sync.

### Option C — commit the binary index

`.gitignore` exception for `fixtures/index.sqlite3`. Exact state handoff
to the receiving environment, at the cost of binary churn in every
commit and per-host noise (runner/created_at/available).

### Decision

Deferred to the receiving environment; the recommended default is
**Option A** (keep `fixtures/*.sqlite3` gitignored). If an aggregate
audit is wanted across environments, prefer **Option B** (text
manifest) over **Option C** (binary DB).

## Tasks

### 1. Commit the pre-strip state (git — implementation-capable agent)

This session runs in plan mode and cannot run git; an
implementation-capable agent (or the user's terminal) executes:

```pwsh
.\zig-out\bin\agent-detect.exe trailer co-author
git add AGENTS.md .kilo/plans/1786449399996-sqlite-recipe-ps1-availability.md
git commit -m "chore: harness-config hard rule + capture plan" --trailer "Co-authored-by: <trailer>"
```

### 2. Strip from-raw in `src/main.zig`

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

### 3. Update docs

- `CONTRIBUTING.md`: mode list/default, the runbook commands
  (187-203), "common expected failures" (130-149), install-table note if
  it references from-raw.
- `DESIGN.md`: mode descriptions (decision #7, 437-456).
- `README.md` only if it mentions the modes.

### 4. Build + tests

```pwsh
zig build
zig build test
zig build dev
```

### 5. Re-queue the Windows batch

```pwsh
$env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' +
            [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + $env:PATH
.\zig-out\bin\agent-detect-dev.exe fixtures dequeue --recipes
.\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes                 # all 177, from-identity (default)
.\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes --from-capture   # launch-spec combos (real evidence)
```

- from-capture rows replace identity rows for the same combo (dedupe key
  excludes `mode`).
- Combos without a launch spec (pi-anthropic-claudesonnet4, pi-groq-*,
  pi-xai-grok4, pi-kimi-kimik3, reasonix-deepseek-deepseekv4flash,
  reasonix-minimax-minimaxm3) get warned by the daemon; re-queue those
  specifically as `--from-identity` if needed.
- reasonix capture rows gate on `available=0` → re-queued as handoff.

### 6. User runs the daemon (fresh terminal, user-only)

```pwsh
.\zig-out\bin\agent-detect-dev.exe fixtures daemon --write-log
```

- from-identity workers write declared fixtures (fast, zero-token).
- from-capture jobs announce ~15s before each capture
  (`--capture-review-seconds`); token-consuming — stop with Ctrl+C or
  write `stop` to `fixtures/daemon.ctl`. Trim scope per-harness with
  `fixtures queue --harness=H --from-capture` if the cost is too high.
- Watch `fixtures/daemon.log`.

### 7. Review + commit fixtures

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
