# sqlite + Windows recipe probe names + availability probe + install docs

## Goal

1. **Save the install plan** — record how each of the 14 harnesses was
   installed on Windows with its binary location (appendix below; full
   narrative in `.kilo/plans/1786449399996-harness-installs-windows.md`,
   both currently untracked — commit both with the AGENTS.md co-author
   trailer when the work lands).
2. **Update CONTRIBUTING.md** — extend the per-harness install table with
   Windows install options and install locations (CONTRIBUTING.md owns
   install docs; DESIGN.md:457 defers to it, so DESIGN.md stays untouched).
3. Install `sqlite3` via scoop (the `fixtures` workflow spawns the system
   `sqlite3` CLI; it is not on PATH today).
4. Update the harness recipes (`recipesForFixtures` `probeNames` in
   `src/main.zig`) to note the Windows `.cmd` + `.ps1` shim forms, not just
   `.exe`, for the Windows-shimmed harnesses (cline, kilo, mmx, qwen,
   cursor-agent).
5. Rebuild the dev binary and run
   `fixtures queue --recipes --available` to record `available=1/0` for
   every recipe in `fixtures/index.sqlite3`.

## Verified context

- The `fixtures` workflow shells out to the system `sqlite3` binary
  (`sqlite3 -json -batch fixtures/index.sqlite3 <sql>`) —
  `src/main.zig:3312-3322`. `sqlite3` is NOT on PATH → `scoop install sqlite`
  provides `~\scoop\shims\sqlite3.exe`.
- Recipes live in the `RecipesForFixtures` table
  (`src/main.zig:4329-4575`; struct at `3791-3817`, field `probeNames`).
- Probe path: `fixtures queue --recipes --available` →
  `runFixturesQueueScope` (`5283`) → `scopeCandidates` recipes branch
  (`4984-5027`) → `harnessAvailable` (`5323`) → `probeBinary` (`4584`),
  which spawns `<name> --version` and returns true on exit 0.
- **Zig 0.16.0 Windows spawn supports only CreateProcess-native extensions
  `bat/cmd/com/exe`** (`.cmd`/`.bat` are wrapped in `cmd.exe /c`); `.ps1`
  cannot be spawned. Therefore `.cmd` variants make probing succeed; `.ps1`
  variants are documentation (inert, spawn fails fast).
- Windows shim reality (verified): cline/kilo/mmx/qwen are
  `scoop\apps\nodejs\current\bin\<name>{,.cmd,.ps1}` (no `.exe`);
  cursor-agent is `%LOCALAPPDATA%\cursor-agent\cursor-agent{,.cmd,.ps1}`
  (no `.exe`). All other harnesses have a real `.exe` (scoop shims
  copilot/pi/goose/omp/reasonix/opencode, winget crush, uv `vibe.exe`,
  `~/.kimi-code/bin/kimi.exe`) and need no change.
- `zig build dev` (`build.zig:99`) → `zig-out/bin/agent-detect-dev.exe`.
  Neither the dev binary nor `fixtures/index.sqlite3` exists yet.
- No test asserts on `probeNames` contents → edits will not break
  `zig build test` (tests iterate recipes for rule/fixture cross-checks).

## Tasks

### 1. Install sqlite3

```pwsh
scoop install sqlite
sqlite3 --version   # resolves from ~\scoop\shims\sqlite3.exe
```

### 2. Edit `src/main.zig` recipe probeNames

Append `.cmd` and `.ps1` variants, keeping existing names first (macOS
behavior unchanged). Each harness's rows share an identical `probeNames`
string, so do one global replace per harness:

| harness | rows | replace |
| ------- | ---- | ------- |
| cline | 4329-4335 (6) | `&.{ "cline", "cline.exe" }` → `&.{ "cline", "cline.exe", "cline.cmd", "cline.ps1" }` |
| kilo | 4407-4429 (17) | `&.{ "kilo", "kilo.exe" }` → `&.{ "kilo", "kilo.exe", "kilo.cmd", "kilo.ps1" }` |
| mmx | 4355-4356 (2) | `&.{ "mmx", "mmx.exe" }` → `&.{ "mmx", "mmx.exe", "mmx.cmd", "mmx.ps1" }` |
| qwen | 4391-4405 (10) | `&.{ "qwen", "qwen.exe" }` → `&.{ "qwen", "qwen.exe", "qwen.cmd", "qwen.ps1" }` |
| cursor | 4561-4567 (7) | `&.{ "cursor-agent", "cursor-agent.exe" }` → `&.{ "cursor-agent", "cursor-agent.exe", "cursor-agent.cmd", "cursor-agent.ps1" }` |

No change for: goose, kimi, pi, omp, reasonix, crush, opencode, copilot,
vibe (all have real `.exe` / existing coverage).

### 3. Build

```pwsh
zig build test   # recipes changed structurally; must still pass
zig build dev    # -> zig-out/bin/agent-detect-dev.exe
```

### 4. Pre-check `--version` exit codes (recommended)

`probeBinary` counts only exit code 0. Manually verify each changed
harness first; known-good: `cursor-agent --version` → `2026.08.04-aaa8809`.
If `cline/kilo/mmx/qwen --version` exit non-zero, those rows record
`available=0` despite the binary existing — document it, do not change
probe semantics.

### 5. Run the availability probe with a fresh PATH

The probe inherits the parent env PATH, which is stale for
`%LOCALAPPDATA%\cursor-agent` (cursor) and winget Links (crush). Merge the
persisted scopes explicitly (or run in a fresh terminal):

```pwsh
$env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' +
            [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + $env:PATH
.\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes --available
```

Expect `fixtures queue: queued N rows`; creates `fixtures/index.sqlite3`.

### 6. Verify availability

```pwsh
sqlite3 fixtures/index.sqlite3 `
  "SELECT harness, available, COUNT(*) FROM queue WHERE scope_recipes=1 GROUP BY harness, available;"
```

Expect all 14 harnesses present and `available=1` in a fresh-PATH shell.
`available=0` rows are kept queued as handoff work — do not dequeue them.

### 7. Update CONTRIBUTING.md install docs

Edit `CONTRIBUTING.md` under the existing `### per-harness install table`
section (`CONTRIBUTING.md:161-180`). Keep the existing macOS + npm/uv
columns; append a Windows subsection with the install options and binary
locations (facts from the record below). Suggested content:

```markdown
### windows installs + binary locations (verified 2026-08-11)

On Windows the maintainer installs with scoop / npm / winget / uv / the
official script, in that preference order. `Get-Command <bin>` resolves the
binaries below. npm global and scoop installs expose `.ps1`/`.cmd` shims
(no `.exe` for npm bins); the availability probe reaches `.cmd` via
`cmd.exe /c` — `.ps1` cannot be spawned (see recipe `probeNames`). PATH
entries added by the cursor installer and winget appear only in a fresh
shell.

| harness | install | binary location |
| ------- | ------- | --------------- |
| cline | `npm i -g cline` | `~\scoop\apps\nodejs\current\bin\cline{,.cmd,.ps1}` |
| kilo | `npm i -g @kilocode/cli` | `~\scoop\apps\nodejs\current\bin\kilo{,.cmd,.ps1}` |
| mmx | `npm i -g mmx-cli` | `~\scoop\apps\nodejs\current\bin\mmx{,.cmd,.ps1}` |
| pi | `scoop install pi-coding-agent` | `~\scoop\shims\pi.exe` |
| goose | `scoop install goose-cli` | `~\scoop\shims\goose.exe` |
| omp | `scoop install oh-my-pi` | `~\scoop\shims\omp.exe` |
| reasonix | `scoop install reasonix` | `~\scoop\shims\reasonix.exe` |
| opencode | `scoop install opencode` | `~\scoop\shims\opencode.exe` |
| copilot | `scoop install copilot-cli` | `~\scoop\shims\copilot.exe` |
| qwen | `npm i -g @qwen-code/qwen-code` | `~\scoop\apps\nodejs\current\bin\qwen{,.cmd,.ps1}` |
| kimi-code | `npm i -g @moonshot-ai/kimi-code` | `~\.kimi-code\bin\kimi.exe` |
| crush | `winget install charmbracelet.crush` | winget package dir + `winget` Links alias (PATH) |
| vibe | `uv tool install mistral-vibe` | `~\scoop\persist\uv\tools\shims\vibe.exe` |
| cursor | `irm 'https://cursor.com/install?win32=true' | iex` | `%LOCALAPPDATA%\cursor-agent\{cursor-agent,agent}{,.cmd,.ps1}` |

Maintainer tooling: `scoop install sqlite` → `~\scoop\shims\sqlite3.exe`
(the `fixtures` workflow's `sqlite3` CLI).
```

Optionally drop a one-line pointer from DESIGN.md's install sentence
(`DESIGN.md:456-457`) to the new subsection; not required.

## Out of scope

- Actual `fixtures/*-windows.json` captures (daemon/capture is
  token-consuming and needs harness auth — a separate step).
- Harness auth / configuration.
- `assertNotInAgent` daemon proc-name guard (`src/main.zig:6592-6607`);
  on Windows these harnesses run as `node.exe`/python, a different
  detection concern.
- Commit. If committing, per AGENTS.md generate the co-author trailer with
  `.\zig-out\bin\agent-detect trailer co-author` and attach it with
  `git commit --trailer "$(.\zig-out\bin\agent-detect trailer co-author)"`.

## Risks / notes

- Stale-shell PATH is the main failure mode for the probe (cursor + crush
  entries appear only in a new shell) — step 5 mitigates.
- `.ps1` names are inert (Zig cannot spawn them) but requested as
  documentation; `.cmd` names are the functional addition. Harmless on
  macOS (nonexistent names fail fast).
- `fixtures/index.sqlite3` does not exist yet; the queue command creates it.
- A harness whose `--version` is non-zero will show `available=0` even when
  installed — expected, not a bug.

## Appendix: install plan record (Windows, verified 2026-08-11)

Package managers present: scoop (main bucket), node v26.5.1, npm 12.0.2,
bun 1.3.14, uv 0.12.1, winget v1.29.280, git 2.55.0 (Git Bash for
kimi-code/vibe), zig 0.16.0.

### Already installed (skipped)

| harness | source | binary |
| ------- | ------ | ------ |
| cline | npm `cline@3.0.50` | `~\scoop\apps\nodejs\current\bin\cline{,.cmd,.ps1}` |
| kilo | npm `@kilocode/cli@7.4.21` | `~\scoop\apps\nodejs\current\bin\kilo{,.cmd,.ps1}` |
| mmx | npm `mmx-cli@1.0.19` | `~\scoop\apps\nodejs\current\bin\mmx{,.cmd,.ps1}` |
| pi | scoop `pi-coding-agent@0.83.0` (0.84.1 avail.) | `~\scoop\shims\pi.exe` |
| goose | scoop `goose-cli@1.45.0` | `~\scoop\shims\goose.exe` |

### Installed this effort

| harness | method | version | binary location |
| ------- | ------ | ------- | --------------- |
| omp | `scoop install oh-my-pi` | 17.2.12 | `~\scoop\shims\omp.exe` |
| reasonix | `scoop install reasonix` | v1.23.0 | `~\scoop\shims\reasonix.exe` |
| opencode | `scoop install opencode` | 1.18.16 | `~\scoop\shims\opencode.exe` |
| copilot | `scoop install copilot-cli` | 1.0.79 | `~\scoop\shims\copilot.exe` |
| kimi-code | `npm i -g @moonshot-ai/kimi-code` | 0.31.1 | `~\.kimi-code\bin\kimi.exe` |
| qwen | `npm i -g @qwen-code/qwen-code` | 0.21.9 | `~\scoop\apps\nodejs\current\bin\qwen{,.cmd,.ps1}` |
| crush | `winget install charmbracelet.crush` | v0.88.0 | winget package dir + `winget` Links alias |
| vibe | `uv tool install mistral-vibe` | 2.24.0 | `~\scoop\persist\uv\tools\shims\vibe.exe` |
| cursor | `irm 'https://cursor.com/install?win32=true' \| iex` | 2026.08.04-aaa8809 | `%LOCALAPPDATA%\cursor-agent\{cursor-agent,agent}{,.cmd,.ps1}` |

### Notes

- **cursor**: no native `cursor-agent.exe` on Windows — a node launcher
  (`cursor-agent.ps1/.cmd` + `cursor-agent-svc.js`), so lineage proc-name
  detection (`proc cursor-agent`) will not fire; needs env/config markers.
  `agent` is a copy alias of `cursor-agent`. PATH entry added by installer
  → fresh shell required.
- **kimi-code / qwen**: npm `allow-scripts` policy blocked postinstall
  (`node-pty`/`sharp`); both binaries still run. kimi-code + vibe spawn Git
  Bash on Windows; set `KIMI_SHELL_PATH` to scoop git `bash.exe` if needed.
- **crush**: winget added a command-line alias; PATH via winget Links →
  fresh shell required.
- **sqlite3**: not installed at record time; this plan installs it via
  `scoop install sqlite` → `~\scoop\shims\sqlite3.exe`.
