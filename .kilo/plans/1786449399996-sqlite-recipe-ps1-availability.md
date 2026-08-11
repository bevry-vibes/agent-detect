# Windows fixture capture — what's next

## Goal

Capture `fixtures/*-windows.json` for all capturable recipes (Windows
parity with the committed darwin fixtures) via the zero-token `from-raw`
path, and land the pending commits.

## State (verified 2026-08-11)

- Queue (`fixtures/index.sqlite3`): 177 recipe rows; `available=1` for
  all harnesses except **reasonix** (3 rows `available=0` → handoff).
- No `fixtures/*-windows.json` exist yet.
- Dev binary is current (rebuilt after the Windows detection/build fixes
  and the `.cmd`/`.ps1` shim probe-name edits).
- `sqlite3` on PATH (`scoop install sqlite` → 3.53.4).
- Uncommitted: `AGENTS.md` hard rule (never touch harness configs/API
  keys).
- Committed: `2c344e5` (CONTRIBUTING.md install docs + install plan),
  `fd60e9d` (Windows session-store detection + dev build; shim probe
  names).

## Constraints / hard rules

- **The daemon runs only from the user's terminal** (`assertNotInAgent`
  refuses inside an agent session via env markers + ancestry). The agent
  cannot start it.
- `from-raw` writes config only into the sandboxed worker HOME
  (`~/.cache/agent-detect/workers/<agent_id>`), never the real harness
  configs — zero tokens, no credentials, no harness execution.
- reasonix rows (`available=0`) are re-queued as handoff, never captured.
- No harness config/auth writes on the user's machine (AGENTS.md hard
  rule).

## Tasks

### 1. Commit the AGENTS.md hard rule

```pwsh
.\zig-out\bin\agent-detect.exe trailer co-author   # capture the trailer
git add AGENTS.md
git commit -m "chore: hard rule - never touch harness configs or API keys" --trailer "Co-authored-by: <trailer>"
```

### 2. User runs the capture daemon (fresh terminal)

```pwsh
cd C:\Users\balup\Projects\vibes\agent-detect
$env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' + [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + $env:PATH
.\zig-out\bin\agent-detect-dev.exe fixtures daemon --write-log
```

- Pops the 177 queued rows in `from-raw` mode (default, zero tokens):
  fabricates env markers + config files in the sandboxed worker HOME,
  runs the live detection ladder, writes `fixtures/<id>-windows.json`,
  upserts `fixtures` rows, stamps `harness_version`.
- reasonix rows are re-queued as handoff (never captured).
- ~174 capturable combos expected. Runs to completion; Ctrl+C is the
  graceful stop; write `stop` to `fixtures/daemon.ctl` to stop.
- Watch `fixtures/daemon.log` (gitignored).

### 3. Triage from-raw failures (agent work, in-repo)

- A failed combo logs `daemon: worker failed for <combo> (exit code N) —
  re-queued` with worker stderr → a **detection-code bug** (unresolved
  detection, missing config read, contradictory evidence claim). The row
  stays queued; fix and let the daemon re-run.
- Windows-specific suspects to pre-check in `src/main.zig`:
  - cline: session detection via `~/.cline/data/sessions` +
    `findOwnSession` (ancestry, then cwd fallback) and `providers.json`.
  - copilot: `detectCopilotFromDb` session-store read (cwd matching).
  - goose: `%APPDATA%\Block\goose\config\config.yaml` path.
  - `build*Env` sandbox env: `HOME`/`USERPROFILE` both point at the
    worker HOME on Windows.
- Fix `detect*` / rules / `build*Env`, `zig build dev`, re-run daemon.

### 4. Review fixtures

- Each `fixtures/<id>-windows.json`: cooked 18-field object correct
  (harness/provider/model), evidence claims coherent, trailer present,
  `raw.env_vars`/`raw.process_lineage` plausible.
- Cross-check agent_id ↔ filename and the `fixtures` table:
  `SELECT harness, COUNT(*) FROM fixtures WHERE platform='windows' GROUP BY harness`.

### 5. Commit the windows fixtures

- With the generated co-author trailer.
- Expect ~174 fixtures (177 recipes minus reasonix's 3; any remaining
  unfixable from-raw failures stay queued and are noted).

## Known gaps / handoff

- **reasonix**: not configurable on win10 per the user → 3 combos stay
  queued `available=0`, no windows fixtures. Noted in the commit message.

## Validation

- `zig build test` still green after any detection fixes.
- `SELECT harness, COUNT(*) FROM queue WHERE scope_recipes=1 AND available=0;`
  → only reasonix rows.
- `SELECT COUNT(*) FROM fixtures WHERE platform='windows';` → ~174.
- `git status` clean after the fixture commit (index.sqlite3 gitignored).

## Out of scope

- `from-capture` (real, token-consuming) — deferred unless the user asks
  for specific harnesses.
- reasonix config/setup on Windows.
- Release cut (`release: 2026.8.11-N` pattern) — only after fixtures
  land and are reviewed.
