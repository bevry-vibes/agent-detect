# design

## problem

AI agents working on Bevry projects must identify their **harness**, **model**, and **provider** before working ([policy.md](https://github.com/bevry-labs/skills/blob/main/policy.md)) and must credit commits with an accurate `Co-authored-by` trailer ([commits.md](https://github.com/bevry-labs/skills/blob/main/commits.md)), inferred fresh per session and per model change. Hard-coded answers rot; manual per-harness techniques documented in markdown rot faster and go unread. This repo provides a single small native binary, `agent-detection`, that infers the identity from live evidence.

## requirements

- **multi-harness** — Cline, Goose, Kimi Code, MiniMax Code (`mmx`), pi; extensible by table edit
- **multi-OS/arch** — Windows, macOS, Linux on x86_64 and aarch64
- **zero runtime dependencies** — agent environments may have nothing installed
- **never guess** — exit non-zero and say so when identification is impossible
- **never leak secrets** — provider config files contain live auth tokens
- **cheap to distribute** — tiny binaries, no git-history pollution

## detection design (least-invasive-first ladder)

1. **env markers** → harness (`CLINE_*`, `GOOSE_*`, `KIMI_*`, `MMX_CONFIG_DIR`/`MINIMAX_*`, `PI_CODING_AGENT=true`)
2. **ancestor process names** → harness fallback (Windows Toolhelp32 snapshot, Linux `/proc`; unsupported on macOS cross-builds)
3. **harness config store** → live provider + model (per-harness table in [README.md](./README.md))
4. **own session** (Cline) → nearest ancestor pid with a `running` session under `~/.cline/data/sessions/`, corroborated by `cwd`; fallback: newest `running` session in cwd — parallel sessions exist, so never pick the newest globally
5. **generation truth** (Cline) → last assistant `modelInfo` in the session's `messages.json`

Secrets hygiene: only the required fields are read; auth tokens are never emitted or persisted. Output modes: text / `--json` / `--trailer`. Exit codes: `0` identified, `2` unable (stop and inform the user).

## toolchain selection

| option | cross targets | binary size | maintainer fit | verdict |
| --- | --- | --- | --- | --- |
| `deno compile` | 5 (no Windows ARM64) | ~80–120 MB | TS, high | rejected: size, missing target |
| `bun build --compile` | 13 (incl. win-arm64, musl) | ~50–100 MB | TS, high | rejected: size |
| rust | all (per-target) | ~2–10 MB | low | rejected: no advantage over zig here |
| **zig 0.16** | all, incl. win-arm64, linux-musl, macOS without SDK | **~0.2–0.5 MB** | low, but the codebase is tiny | **chosen** |

zig 0.16 std notes (for future contributors): file/process IO goes through the `std.Io` interface; `main` takes `std.process.Init` (`arena`, `gpa`, `io`, `minimal.args`, `environ_map`); search fns are `std.mem.find*`; Toolhelp32 was removed from `std.os.windows` (externs declared locally in `src/main.zig`); all targets build without libc, which is also why process walking is unsupported on macOS cross-builds (no `posix_spawn`/`sysctl` without the Apple SDK).

## binary formats ("universal" / fat binaries)

Native executables are OS- and ISA-bound (PE/ELF/Mach-O; x86_64/aarch64); no compiler emits one native file for every OS. Fat formats are per-OS-family:

- **Mach-O Universal 2** (macOS only, N slices) — combinable today on any host via `llvm-lipo -create`; optional future CI step (`agent-detection-macos-universal`).
- **APE / Cosmopolitan** — one x86_64 file runs on Windows/Linux/macOS/BSD, plus an aarch64 APE for Linux/macOS ARM; requires a C rewrite (`cosmocc`) or Rust tier-3 `*-unknown-linux-cosmo` targets, and loses the Windows Toolhelp32 ancestry walk (POSIX-everywhere model) → degraded to env+cwd detection. Rejected for now: rewrite cost + capability loss.
- **ARM64X/ARM64EC PE** — Windows 11 ARM only, MSVC toolchain.
- **FatELF** — never mainlined, dead.
- **WASM / JVM / .NET FDD** — one file, but a runtime must be installed; violates zero-dependency.

**Decision: per-platform native binaries.** Six files at ~0.2–0.5 MB each cover Windows/Linux/macOS × x86_64/aarch64 completely.

## distribution: committed binaries → CI artifacts

Binaries were initially committed to `bin/` (they are tiny). Reconsidered: committed binaries still bloat every clone forever, fight source-only review, and desynchronize from source (rebuilds produce binary diffs unrelated to logical changes). **Decision:** GitHub Actions builds all six targets on every push/PR and attaches them as workflow artifacts; `bin/` was purged from git history (filter-branch) and is gitignored. Tags can later publish the same artifacts to GitHub Releases at zero history cost.

## platform caveats

- **macOS** — no-libc cross-builds cannot walk processes; harness detection relies on env markers, and Cline session resolution falls back to cwd+running+newest (avoid parallel sessions in one directory).
- **mmx** — node shim, so its ancestor exe name is generic (`node.exe`); detection relies on env markers (`MMX_CONFIG_DIR`, `MINIMAX_*`). Model comes from `~/.mmx/config.json` when present, else the bundle default `MiniMax-M3`.
- **goose** — Windows config lives at `%APPDATA%\Block\goose\config\config.yaml` (`active_provider` + `providers.<p>.model`); `GOOSE_PROVIDER`/`GOOSE_MODEL` env override it.
- **pi** — harness env-detected; model detection (sessions `model_change` metadata) is TODO.

## future work

- pi model detection
- universal2 Mach-O via `llvm-lipo` in CI (matrix 6 → 5 files)
- GitHub Releases on tags, attaching the CI artifacts
- Grok Build detection (previously `@todo` in skills/commits.md)
- optional Rust cosmo/APE spike (2 files per-ISA, every OS) if single-file-per-arch ever becomes a hard requirement
