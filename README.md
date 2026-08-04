# agent-detection

Infers the current agent's **harness**, **interface** (provider product), and **model** — multi-harness, multi-OS, multi-arch — so AI agents can identify themselves as required by [Bevry's skills](https://github.com/bevry-labs/skills) (`policy.md` identification, `commits.md` co-author trailers).

## usage

Download the binary for your platform from [`bin/`](./bin), or build it (see below), then run it inside the agent session:

```sh
agent-detection            # human-readable detection report
agent-detection --json     # machine-readable detection report
agent-detection --trailer  # only the Co-authored-by trailer (for git commits)
```

Exit codes: `0` = identified; `2` = unable to identify — stop and inform the user, never guess.

Example inside a Cline CLI session:

```text
harness: Cline
harness_env: true
interface: Cline Pass
interface_id: cline-pass
model: Kimi K3
model_id: cline-pass/kimi-k3
open_weight: true
model_updated_at: 2026-08-04T04:37:50.830Z
session_id: 1785813522727_5ugi8
session_resolution: ancestry
session_provider: cline-pass
session_model: cline-pass/kimi-k3
last_msg_provider: cline-pass
last_msg_model: cline-pass/kimi-k3
trailer: Co-authored-by: Cline - Kimi K3 <cline-kimik3@local>
```

## how it works

Least-invasive-first detection ladder:

1. **Environment variables** — `CLINE_*` markers → harness `Cline`; `PI_CODING_AGENT=true` → harness `pi`.
2. **Live selection** — `~/.cline/data/settings/providers.json`: `lastUsedProvider` + `providers.<id>.settings.model` + `updatedAt`. Auth tokens in that file are never emitted.
3. **Own session** — process ancestry (Windows: Toolhelp32 snapshot walk; Linux: `/proc` walk; nearest ancestor pid with a `running` session wins, corroborated by `cwd`), reading `~/.cline/data/sessions/<id>/<id>.json`. Fallback: newest `running` session with matching `cwd`. On **macOS** the cross-built binary cannot walk processes (no libc), so only the cwd fallback is used — avoid parallel sessions in one directory there.
4. **Generation truth** — the last assistant message's `modelInfo.id` / `modelInfo.provider` in the session's `messages.json`.

Steps 2–4 currently apply to the Cline CLI harness; other harnesses are detected by env only. Extend `cline_markers`, `model_rules`, and `interface_rules` in [`src/main.zig`](./src/main.zig) as new harnesses/models appear.

## platforms

| binary | os | arch |
| --- | --- | --- |
| `agent-detection-windows-x86_64.exe` | Windows | x86_64 |
| `agent-detection-windows-aarch64.exe` | Windows | ARM64 |
| `agent-detection-macos-x86_64` | macOS | x86_64 |
| `agent-detection-macos-aarch64` | macOS | ARM64 |
| `agent-detection-linux-x86_64` | Linux (static, musl) | x86_64 |
| `agent-detection-linux-aarch64` | Linux (static, musl) | ARM64 |

## building

Requires [zig](https://ziglang.org) 0.16:

```sh
zig build                     # native binary -> zig-out/bin/
zig build dist --prefix .     # all six targets -> bin/
```

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->
