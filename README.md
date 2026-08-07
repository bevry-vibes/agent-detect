# agent-detect

Infers the current agent's **harness**, **provider**, and **model** — multi-harness, multi-OS, multi-arch — so AI agents can identify themselves as required by [Bevry's skills](https://github.com/bevry-labs/skills) (`policy.md` identification, `commits.md` co-author trailers).

## usage

Identify the binary for your platform from the [latest release](https://github.com/bevry-labs/agent-detect/releases/latest):

| binary                                                                                                                                              | os                   | arch   |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ------ |
| [`agent-detect-windows-x86_64.exe`](https://github.com/bevry-labs/agent-detect/releases/latest/download/agent-detect-windows-x86_64.exe)   | Windows              | x86_64 |
| [`agent-detect-windows-aarch64.exe`](https://github.com/bevry-labs/agent-detect/releases/latest/download/agent-detect-windows-aarch64.exe) | Windows              | ARM64  |
| [`agent-detect-macos-x86_64`](https://github.com/bevry-labs/agent-detect/releases/latest/download/agent-detect-macos-x86_64)               | macOS                | x86_64 |
| [`agent-detect-macos-aarch64`](https://github.com/bevry-labs/agent-detect/releases/latest/download/agent-detect-macos-aarch64)             | macOS                | ARM64  |
| [`agent-detect-linux-x86_64`](https://github.com/bevry-labs/agent-detect/releases/latest/download/agent-detect-linux-x86_64)               | Linux (static, musl) | x86_64 |
| [`agent-detect-linux-aarch64`](https://github.com/bevry-labs/agent-detect/releases/latest/download/agent-detect-linux-aarch64)             | Linux (static, musl) | ARM64  |

> If your platform is not supported, skip ahead to [contributing](#contributing).

Download the binary for your platform using whichever tool is appropriate:

```sh
# example: linux x86_64 (sh)
curl -Lo agent-detect https://github.com/bevry-labs/agent-detect/releases/latest/download/agent-detect-linux-x86_64
chmod +x agent-detect
```

```powershell
# example: windows x86_64 (powershell 7.6)
Invoke-WebRequest https://github.com/bevry-labs/agent-detect/releases/latest/download/agent-detect-windows-x86_64.exe -OutFile agent-detect.exe
```

Once downloaded, the use cases:

**identify yourself** (per [policy.md](https://github.com/bevry-labs/skills/blob/main/policy.md)) — report the harness, provider, and model, with their provenance:

```sh
# sh (linux, macos)
./agent-detect cooked   # machine-readable JSON report
```

```powershell
# powershell (windows)
.\agent-detect.exe cooked   # machine-readable JSON report
```

Running `agent-detect` with no arguments prints this help; the JSON
report is produced by the `cooked` action. `cooked` (and `trailer`)
also accept a full combo `--harness=H --provider=P --model=M` to
resolve the report from the rule tables instead of live detection.

**credit your commits** (per [commits.md](https://github.com/bevry-labs/skills/blob/main/commits.md)) — emit only the `Co-authored-by` trailer:

```sh
# sh
git commit --trailer "$(./agent-detect trailer)"
```

```powershell
# powershell
git commit --trailer "$(.\agent-detect.exe trailer)"
```

Example trailer: `Co-authored-by: Cline · Kimi K3 <cline-clinepass-kimik3@local>`.

Other actions: `agent-detect help` (also `--help`, `-h`, or no
arguments) and `agent-detect version` (also `--version`, `-V`).

Exit codes: `0` = identified; `2` = unable to identify — stop and inform the user, never guess.

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
