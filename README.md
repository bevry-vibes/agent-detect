# agent-detection

Infers the current agent's **harness**, **provider**, and **model** — multi-harness, multi-OS, multi-arch — so AI agents can identify themselves as required by [Bevry's skills](https://github.com/bevry-labs/skills) (`policy.md` identification, `commits.md` co-author trailers).

## usage

Identify the binary for your platform from the [latest release](https://github.com/bevry-labs/agent-detection/releases/latest):

| binary                                                                                                                                              | os                   | arch   |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ------ |
| [`agent-detection-windows-x86_64.exe`](https://github.com/bevry-labs/agent-detection/releases/latest/download/agent-detection-windows-x86_64.exe)   | Windows              | x86_64 |
| [`agent-detection-windows-aarch64.exe`](https://github.com/bevry-labs/agent-detection/releases/latest/download/agent-detection-windows-aarch64.exe) | Windows              | ARM64  |
| [`agent-detection-macos-x86_64`](https://github.com/bevry-labs/agent-detection/releases/latest/download/agent-detection-macos-x86_64)               | macOS                | x86_64 |
| [`agent-detection-macos-aarch64`](https://github.com/bevry-labs/agent-detection/releases/latest/download/agent-detection-macos-aarch64)             | macOS                | ARM64  |
| [`agent-detection-linux-x86_64`](https://github.com/bevry-labs/agent-detection/releases/latest/download/agent-detection-linux-x86_64)               | Linux (static, musl) | x86_64 |
| [`agent-detection-linux-aarch64`](https://github.com/bevry-labs/agent-detection/releases/latest/download/agent-detection-linux-aarch64)             | Linux (static, musl) | ARM64  |

> If your platform is not supported, skip ahead to [contributing](#contributing).

Download the binary for your platform using whichever tool is appropriate:

```sh
# example: linux x86_64 (sh)
curl -Lo agent-detection https://github.com/bevry-labs/agent-detection/releases/latest/download/agent-detection-linux-x86_64
chmod +x agent-detection
```

```powershell
# example: windows x86_64 (powershell 7.6)
Invoke-WebRequest https://github.com/bevry-labs/agent-detection/releases/latest/download/agent-detection-windows-x86_64.exe -OutFile agent-detection.exe
```

Once downloaded, the use cases:

**identify yourself** (per [policy.md](https://github.com/bevry-labs/skills/blob/main/policy.md)) — report the harness, provider, and model, with their provenance:

```sh
# sh (linux, macos)
./agent-detection agent   # machine-readable JSON report
```

```powershell
# powershell (windows)
.\agent-detection.exe agent   # machine-readable JSON report
```

Running `agent-detection` with no arguments prints this help; the JSON
report is produced by the `agent` action (`--json` is accepted as a
legacy alias).

**credit your commits** (per [commits.md](https://github.com/bevry-labs/skills/blob/main/commits.md)) — emit only the `Co-authored-by` trailer:

```sh
# sh
git commit --trailer "$(./agent-detection trailer)"
```

```powershell
# powershell
git commit --trailer "$(.\agent-detection.exe trailer)"
```

Example trailer: `Co-authored-by: Cline · Kimi K3 <cline-clinepass-kimik3@local>`.

Other actions: `agent-detection help` (also `--help`, `-h`, or no
arguments) and `agent-detection version` (also `--version`, `-V`).

Exit codes: `0` = identified; `2` = unable to identify — stop and inform the user, never guess.

## contributing

If your platform is not detected, or the agent-detection CLI failed,
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
