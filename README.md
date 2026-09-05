# agent-detect

Infers the current agent's **harness**, **provider**, and **model** — multi-harness, multi-OS, multi-arch — so AI agents can identify themselves accurately, as required by various AI policies and skills.

## usage

### installation

Identify the binary for your platform from the [latest release](https://github.com/bevry-vibes/agent-detect/releases/latest):

| binary                                                                                                                                      | os                   | arch   |
| ------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ------ |
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

### identification

Identify your agent (harness, model, provider) via:

```sh
# sh (linux, macos)
./agent-detect identify   # machine-readable JSON report
```

```powershell
# powershell (windows)
.\agent-detect.exe identify   # machine-readable JSON report
```

### reciprocity compliance

Check your agent (harness, model, provider)'s reciprocity compliance via:

```sh
# sh (linux, macos)
./agent-detect check-reciprocal   # prints "is reciprocal" (0) or "not reciprocal" (10)
```

```powershell
# powershell (windows)
.\agent-detect.exe check-reciprocal   # prints "is reciprocal" (0) or "not reciprocal" (10)
```

A closed-source harness's `harness_open_training` /
`harness_closed_training` identify fields mirror the provider pair:
the closed-training conjunct passes on a `never`/`opt-in`/`opt-out`
value (capability-based, exactly as providers are treated) and fails
on `enforced` (verified training) or `NOASSERTION` (a settings read
with no clear answer); an undeterminable state is policy data
incomplete so you can correct the data (for zcode: the "Improve
experience" toggle) rather than failing silently.

Exit codes — 0 = reciprocal, 10 = not reciprocal, 9 = policy data
incomplete, 8 = undetectable, 7 = unknown combo — follow the registry
in DESIGN.md "exit status registry"; see it for what each means and
what to do.

### co-author trailer

Generate your agent (harness, model, provider) co-author trailer via:

```sh
# sh (linux, macos)
git commit --trailer "$(./agent-detect trailer co-author)"
```

```powershell
# powershell (windows)
git commit --trailer "$(.\agent-detect.exe trailer co-author)"
```

Never guess or cache the identity — generate it fresh per commit. Never commit without the resolved trailer.

### assisted-by trailer

```sh
# sh (linux, macos)
git commit --trailer "$(./agent-detect trailer assisted-by)"
```

```powershell
# powershell (windows)
git commit --trailer "$(.\agent-detect.exe trailer assisted-by)"
```

Never guess or cache the identity — generate it fresh per commit. Never commit without the resolved trailer.

## contributing

If your platform is not detected, or the `agent-detect` CLI failed,
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
