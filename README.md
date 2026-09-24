# agent-detect

Infers the current agent's **harness**, **provider**, and **model** — multi-harness, multi-OS, multi-arch — so AI agents can identify themselves accurately, as required by various AI policies and skills.

## usage

### installation

There is no npm or crates.io package — agent-detect ships as the prebuilt binaries below, so `npx agent-detect` and friends will 404.

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
# example: linux x86_64 (sh) — substitute your platform's asset name from the table above
curl -fLo agent-detect https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-linux-x86_64
chmod +x agent-detect
```

```powershell
# example: windows x86_64 (powershell 7.6)
Invoke-WebRequest https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-windows-x86_64.exe -OutFile agent-detect.exe
```

The `-f` flag is load-bearing: without it, a mistyped asset name saves GitHub's "Not Found" page as the binary, which then fails to execute with a baffling error instead of a clear download failure.
(`Invoke-WebRequest` already fails on HTTP errors.)

**Optional dependency — `sqlite3`.** The binary has no required runtime dependencies.
Live detection inside some harnesses (Kilo Code, OpenCode, GitHub Copilot CLI, Crush, Hermes) reads that harness's local session store via the `sqlite3` CLI; when it is absent from `PATH` there, `identify`/`trailer`/`check-reciprocal` exit `6` (incomplete environment preventing run) instead of guessing — every other code path never spawns it, so a store-less environment needs nothing else installed.

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

A closed-source harness's `harness_open_training` / `harness_closed_training` identify fields mirror the provider pair: the closed-training conjunct passes on a `never`/`opt-in`/`opt-out` value (capability-based, exactly as providers are treated) and fails on `enforced` (verified training) or `NOASSERTION` (a settings read with no clear answer);
an undeterminable state is policy data incomplete so you can correct the data (for zcode: the "Improve experience" toggle) rather than failing silently.

Exit codes — 0 = reciprocal, 10 = not reciprocal, 9 = policy data incomplete, 8 = undetectable, 7 = unknown combo — follow the registry in DESIGN.md "exit status registry"; see it for what each means and what to do.

### failure introspection

When a determination fails or stalls, two actions explain it:

```sh
# sh (linux, macos)
./agent-detect explain   # why the verdict resolved as it did — per-entity reasons, judged values, sources, remediation actions, as JSON
./agent-detect found     # what the detection ladder observed on this machine — the observation trail, as JSON
```

```powershell
# powershell (windows)
.\agent-detect.exe explain   # reasons + remediation, as JSON
.\agent-detect.exe found     # observations, as JSON
```

`explain` never gates on a successful detection — exit-8/9/10 states yield their reasons (which entity, which ladder rung, what to do: fix the setting, switch the entity with suggested reciprocal alternatives, verify a candidate combo first via recipe mode, or contribute the missing sourced value).
`found` is the observation trail for debugging detection and for contributing — the failure actions refer to both `agent-detect found` (gather the evidence now) and [CONTRIBUTING.md](./CONTRIBUTING.md) (the submission workflow).
Both accept a recipe-mode combo (`--harness=H --provider=P --model=M`) to introspect a hypothetical switch before making it.
Their exit codes mirror the state (0/8/9/10) exactly like `check-reciprocal`, so wrappers gate on them identically.

### choosing a trailer

Exactly **one** trailer per artifact — never both on the same commit, and never both on the same issue/PR/discussion/comment.
Precedence: **your org's or harness's instructions win** when they name a trailer type; the table below is the default for when nothing specifies one.

| artifact | trailer | conventions |
| --- | --- | --- |
| git commits | `trailer co-author` | Bevry [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md) ("commit identities and verification"); also matches GitHub's native `Co-authored-by` rendering |
| issue-tracker posts — issues, PRs, discussions, comments | `trailer assisted-by` | Bevry commits.md §"github issues, pull requests, discussions, and comments"; the GCC AI policy's `Assisted-by` |

Never guess or cache the identity — generate it fresh for each artifact. Never post the artifact without the resolved trailer; if generation fails, fix it (see [contributing](#contributing)) rather than skip it.

### co-author trailer

For git commits:

```sh
# sh (linux, macos)
git commit --trailer "$(./agent-detect trailer co-author)"
```

```powershell
# powershell (windows)
git commit --trailer "$(.\agent-detect.exe trailer co-author)"
```

### assisted-by trailer

For issue-tracker posts (issues, PRs, discussions, comments):

```sh
# sh (linux, macos)
git commit --trailer "$(./agent-detect trailer assisted-by)"
```

```powershell
# powershell (windows)
git commit --trailer "$(.\agent-detect.exe trailer assisted-by)"
```

## contributing

If your platform is not detected, or the `agent-detect` CLI failed, you will need to contribute a patch.
See [CONTRIBUTING.md](./CONTRIBUTING.md) for refresh / add-rule / cut-a-release workflows.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->
