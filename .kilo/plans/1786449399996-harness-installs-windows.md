# Install agent-detect harnesses on Windows

## Goal

Reach parity with the macOS harness set on this Windows machine: every
harness that has committed `fixtures/*-darwin.json` gets its CLI binary
installed and on PATH. Prefer what is already installed, then scoop,
then npm / uv / winget / official scripts.

## Current state (verified)

Package managers present: scoop (main bucket), node v26.5.1, npm 12.0.2,
bun 1.3.14, uv 0.12.1, winget v1.29.280, git 2.55.0 (ships Git Bash for
kimi-code/vibe), zig 0.16.0.

`sqlite3` is NOT on PATH — only needed by the maintainer `fixtures`
workflow, not by the harness installs. Optional install below if the
end-to-end probe is wanted.

### Already installed — skip

| harness | source | binary |
| ------- | ------ | ------ |
| cline   | npm `cline@3.0.50` | `cline` |
| kilo    | npm `@kilocode/cli@7.4.21` | `kilo` |
| mmx     | npm `mmx-cli@1.0.19` | `mmx` |
| pi      | scoop `pi-coding-agent@0.83.0` | `pi.exe` (0.84.1 update available; optional `scoop update pi-coding-agent`) |
| goose   | scoop `goose-cli@1.45.0` | `goose` |

## Target set (14)

`cline, copilot, crush, cursor, goose, kilo, kimi-code, mmx, omp,
opencode, pi, qwen, reasonix, vibe` — derived from the darwin fixtures
and matching the CONTRIBUTING.md per-harness install table.

## Install plan (9 to install)

### scoop (4)

1. `scoop install oh-my-pi` — bin `omp.exe`. Matches the `omp` harness
   rule exactly (can1357/oh-my-pi, MIT; manifest verified).
2. `scoop install reasonix` — bin `reasonix.exe`. Matches the `reasonix`
   harness rule (reasonix.io, MIT; manifest verified).
3. `scoop install opencode` — bin `opencode.exe`. Matches the `opencode`
   harness rule (anomalyco/opencode, MIT; manifest verified).
4. `scoop install copilot-cli` — bin `copilot.exe`. Official GitHub
   Copilot CLI (github/copilot-cli releases; manifest verified).

### npm (2)

5. `npm i -g @moonshot-ai/kimi-code` — bin `kimi`. Matches the
   `kimi-code` harness rule (MoonshotAI/kimi-code, MIT). Node >=22.19
   required (have 26.5.1). Windows needs Git Bash — scoop git provides
   it. NOTE: scoop's `kimi-cli` is a **different product**
   (MoonshotAI/kimi-cli); do not install it in place of kimi-code.
   If the npm postinstall fails to fetch the native binary, fall back to
   the official installer: `irm https://code.kimi.com/kimi-code/install.ps1 | iex`.
6. `npm i -g @qwen-code/qwen-code` — bin `qwen`. Matches the `qwen`
   harness rule (QwenLM/qwen-code, Apache-2.0). Node 22+ required.

### winget (1)

7. `winget install charmbracelet.crush` — bin `crush`. Official crush
   README package (chosen over npm / scoop charm bucket per user).

### uv (1)

8. `uv tool install mistral-vibe` — bin `vibe`. Matches the `vibe`
   harness rule (mistralai/mistral-vibe, Apache-2.0; PyPI 2.24.0,
   requires Python >=3.12, uv provides). Windows managed shell prefers
   Git Bash — scoop git provides it.

### official script (1)

9. `irm 'https://cursor.com/install?win32=true' | iex` — Cursor CLI. No
   package-manager option exists on Windows. CAVEAT: the current docs
   call the binary `agent` (`agent --version`), while agent-detect's
   `cursor` rule expects proc name `cursor-agent` (macOS brew installs
   `cursor-agent`). After install, run `Get-Command cursor-agent, agent`
   and record which binary exists; do NOT hack a rename — if it is
   `agent` only, the lineage step may not fire and that is a rule/install
   discrepancy to log as a follow-up.

## Verification

For each of the 9 installed harnesses:

- `Get-Command <bin>` resolves on PATH.
- Version probe where safe: `kimi --version`, `qwen --version`,
  `omp --version`, `reasonix --version`, `crush --version`,
  `opencode --version`, `vibe --version`, `agent --version` (cursor),
  `copilot --version`.
- Optional end-to-end availability probe: `scoop install sqlite`, then
  `zig build dev` and
  `.\zig-out\bin\agent-detect-dev.exe fixtures queue --recipes --available`
  to record `available=1` for each harness. (Needs the sqlite3 CLI,
  absent today.)

## Risks / notes

- `kimi-code` npm postinstall may download a native binary; if it fails,
  use the official Windows installer (see step 5).
- Cursor binary naming (`agent` vs `cursor-agent`) — see step 9.
- kimi-code / vibe spawn Git Bash as their shell on Windows; if that
  fails, set `KIMI_SHELL_PATH` to the scoop git `bash.exe`.
- This task is install-only for parity. No harness is authenticated or
  configured; auth/setup is a separate step.
- `pi` has an available update (0.83.0 -> 0.84.1); optional.

## Deliverable

All 14 harness binaries present and resolvable via `Get-Command`.
