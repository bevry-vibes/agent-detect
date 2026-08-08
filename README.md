# agent-detect

Infers the current agent's **harness**, **provider**, and **model** — multi-harness, multi-OS, multi-arch — so AI agents can identify themselves as required by [Bevry's skills](https://github.com/bevry-vibes/skills) (`ai-policy.md` identification + reciprocity, `commits.md` co-author trailers).

## usage

Identify the binary for your platform from the [latest release](https://github.com/bevry-vibes/agent-detect/releases/latest):

| binary                                                                                                                                              | os                   | arch   |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ------ |
| [`agent-detect-windows-x86_64.exe`](https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-windows-x86_64.exe)   | Windows              | x86_64 |
| [`agent-detect-windows-aarch64.exe`](https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-windows-aarch64.exe) | Windows              | ARM64  |
| [`agent-detect-macos-x86_64`](https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-macos-x86_64)               | macOS                | x86_64 |
| [`agent-detect-macos-aarch64`](https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-macos-aarch64)             | macOS                | ARM64  |
| [`agent-detect-linux-x86_64`](https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-linux-x86_64)               | Linux (static, musl) | x86_64 |
| [`agent-detect-linux-aarch64`](https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-linux-aarch64)             | Linux (static, musl) | ARM64  |

> If your platform is not supported, skip ahead to [contributing](#contributing).

Download the binary for your platform using whichever tool is appropriate:

```sh
# example: linux x86_64 (sh)
curl -Lo agent-detect https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-linux-x86_64
chmod +x agent-detect
```

```powershell
# example: windows x86_64 (powershell 7.6)
Invoke-WebRequest https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-windows-x86_64.exe -OutFile agent-detect.exe
```

Once downloaded, the use cases:

**identify yourself / model** (per [minimax.md](https://github.com/bevry-vibes/skills/blob/main/minimax.md)) — report the harness, provider, and model, with their provenance:

```sh
# sh (linux, macos)
./agent-detect cooked   # machine-readable JSON report
```

```powershell
# powershell (windows)
.\agent-detect.exe cooked   # machine-readable JSON report
```

Sample report (excerpt):

```json
{
  "harness_label": "Kilo Code",
  "provider_label": "DeepSeek",
  "model_label": "DeepSeek V4 Flash",
  "model_name": "deepseek-v4-flash",
  "agent_id": "kilo-deepseek-deepseekv4flash"
}
```

`cooked` (and `trailer co-author` / `trailer assisted-by` /
`is-reciprocal`) also accept a full combo
`--harness=H --provider=P --model=M` to resolve the report from the
rule tables instead of live detection.

Rules for this use case: on exit `8` (identity unresolved, nothing on
stdout) agent-detect must be updated to detect your agent (harness,
provider, model). On exit `9` (partial report still printed to stdout)
agent-detect must be updated for the reciprocity of your agent
(harness, provider, model). Exit `7` means the combo you named is not
a known recipe.

**reciprocity compliance** (per [ai-policy.md](https://github.com/bevry-vibes/skills/blob/main/ai-policy.md)) — check whether the current agent is reciprocal under Bevry's AI policy:

```sh
./agent-detect is-reciprocal   # prints "is reciprocal" (0) or "not reciprocal" (10)
```

Rules for this use case, by exit code:

| exit | stdout | what it means | what to do |
| ---- | ------ | ------------- | ---------- |
| 0 | `is reciprocal` | the agent's harness/provider/model satisfy the policy | proceed |
| 10 | `not reciprocal` | the policy requirement failed | not permitted — stop |
| 9 | — | identity resolved, but reciprocity data is incomplete (policy fields null) | agent-detect must be updated for the reciprocity of your agent (harness, provider, model) |
| 8 | — | live detection couldn't resolve the identity | agent-detect must be updated to detect your agent (harness, provider, model) |
| 7 | — | the named combo is not a known recipe | check the spelling against the rule tables |

On exit `10`, the full message `agent (harness, provider, model) data
complete and requirement failed` is written to stderr alongside the
`not reciprocal` verdict on stdout.

**co-author trailer** (per [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md)) — emit only the `Co-authored-by` trailer:

```sh
# sh
git commit --trailer "$(./agent-detect trailer co-author)"
```

```powershell
# powershell
git commit --trailer "$(.\agent-detect.exe trailer co-author)"
```

Example trailer: `Co-authored-by: Cline · Kimi K3 <cline-clinepass-kimik3@local>`.

Rules for this use case: never guess or cache the identity — generate
it fresh per commit. On exit `8`, agent-detect must be updated to
detect your agent (harness, provider, model); do not commit without
the trailer.

**assisted-by trailer** (e.g. [GCC's AI policy](https://gcc.gnu.org/ai-policy.html)) — emit only the `Assisted-by` trailer:

```sh
git commit --trailer "$(./agent-detect trailer assisted-by)"
```

Example trailer: `Assisted-by: Cline · Kimi K3 <cline-clinepass-kimik3@local>`.

Other actions: `agent-detect help` (also `--help`, `-h`, or no
arguments) and `agent-detect version` (also `--version`, `-V`).

Exit codes appear contextually in each example above; the full
canonical exit-status registry lives in
[DESIGN.md](./DESIGN.md#exit-status-registry).

The released binary has zero runtime dependencies. The maintainer
`fixtures` workflow (see [CONTRIBUTING.md](./CONTRIBUTING.md))
additionally needs the system `sqlite3` CLI to reach the sqlite state
store.

## contributing

If your platform is not detected, or the agent-detect CLI failed,
you will need to contribute a patch. See
[CONTRIBUTING.md](./CONTRIBUTING.md) for refresh / add-rule /
cut-a-release workflows.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->
