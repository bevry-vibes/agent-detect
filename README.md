# agent-detection

Infers the current agent's **harness**, **provider** (LLM provider product), and **model** — multi-harness, multi-OS, multi-arch — so AI agents can identify themselves as required by [Bevry's skills](https://github.com/bevry-labs/skills) (`policy.md` identification, `commits.md` co-author trailers).

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
provider: Cline Pass
provider_id: cline-pass
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

1. **Harness** — env markers first (e.g. `CLINE_*`, `GOOSE_*`, `KIMI_CODE_*`, `MMX_CONFIG_DIR`/`MINIMAX_*`, `PI_CODING_AGENT=true`), then ancestor process names (`cline`, `goose`, `kimi`). Windows uses a Toolhelp32 snapshot walk, Linux a `/proc` walk; macOS cross-builds cannot walk processes (no libc), so env markers are required there.
2. **Live selection** — the harness's config store (see the table below). Auth material in these files is never emitted.
3. **Own session** (Cline) — the nearest ancestor pid with a `running` session under `~/.cline/data/sessions/` wins, corroborated by `cwd`; fallback: newest `running` session with matching `cwd`.
4. **Generation truth** (Cline) — the last assistant message's `modelInfo.id` / `modelInfo.provider` in the session's `messages.json`.

| harness | detected by | provider + model source |
| --- | --- | --- |
| Cline (CLI) | `CLINE_*` env, `cline` ancestor | `~/.cline/data/settings/providers.json` (live), session json, `messages.json` |
| Goose | `GOOSE_*` env, `goose` ancestor | `GOOSE_PROVIDER`/`GOOSE_MODEL` env, else `config.yaml` (`active_provider` + `providers.<p>.model`) — `%APPDATA%\Block\goose\config\config.yaml` on Windows, `~/.config/goose/config.yaml` elsewhere |
| Kimi Code | `KIMI_*` env, `kimi` ancestor | `~/.kimi-code/config.toml` `default_model` (`<provider>/<model-id>`) |
| MiniMax Code (`mmx`) | `MMX_CONFIG_DIR` / `MINIMAX_*` env | `~/.mmx/config.json` `defaultTextModel`/`model`, else bundle default `MiniMax-M3` |
| pi | `PI_CODING_AGENT=true` | todo (sessions `model_change` metadata) |

Extend `harness_rules`, `model_rules`, and `provider_rules` in [`src/main.zig`](./src/main.zig) as new harnesses/models appear.

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
