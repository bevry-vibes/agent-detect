# design

## problem

AI agents working on Bevry projects must identify their **harness**, **provider**, and **model** before working ([policy.md](https://github.com/bevry-labs/skills/blob/main/policy.md) — a use-case of this project, not a policy for it) and must credit commits with an accurate `Co-authored-by` trailer ([commits.md](https://github.com/bevry-labs/skills/blob/main/commits.md)) — inferred fresh per session and per model change. Hard-coded answers rot; manual per-harness techniques documented in markdown rot faster and go unread. This repo provides a single small native binary, `agent-detection`, that infers the identity from live evidence.

## requirements

- **multi-harness** — Cline, Goose, Kimi Code, MiniMax Code (`mmx`), pi; extensible by table edit
- **multi-OS/arch** — Windows, macOS, Linux on x86_64 and aarch64
- **zero runtime dependencies** — agent environments may have nothing installed
- **never guess** — exit non-zero and say so when identification is impossible
- **never leak secrets** — provider config files contain live auth tokens
- **cheap to distribute** — tiny binaries, no git-history pollution

## detection design (least-invasive-first ladder)

1. **env markers** → harness (`CLINE_*`, `GOOSE_*`, `KIMI_*`, `MMX_CONFIG_DIR`/`MINIMAX_*`, `PI_CODING_AGENT=true`)
2. **ancestor process names** → harness fallback (Windows Toolhelp32 snapshot, Linux `/proc`, macOS `libproc` + `sysctl`; unsupported on cross-builds without libc)
3. **harness config store** → live provider + model (per-harness table below)
4. **own session** (Cline) → nearest ancestor pid with a `running` session under `~/.cline/data/sessions/`, corroborated by `cwd`; fallback: newest `running` session in cwd — parallel sessions exist, so never pick the newest globally
5. **generation truth** (Cline) → last assistant `modelInfo` in the session's `messages.json`

Secrets hygiene: provider config files mix auth material with selection state, so only allowlisted fields are read — for recognized provider ids the known token keys (`apiKey`, `token`, `secret`, `password`, `authorization`) are trimmed out, and for unrecognized ids any `key`/`token`/`secret`-looking field is dropped. Auth material is never emitted or persisted.

Emitted fields carry their own provenance: `harness_source` (`env` / `ancestor` / `none`), `model_source` (`providers.json` / `config.yaml` / `config.toml` / `config.json` / `bundle-default` / `env`), `session_resolution` (`ancestry` / `fallback-cwd` / `none`). `model_updated_at` mirrors the Cline provider entry's `lastUpdated`. Output modes: text / `--json` / `--trailer`. Exit codes: `0` identified, `2` unable (stop and inform the user).

Example (Cline CLI session, text output):

```text
harness: Cline
harness_id: cline
harness_source: env
harness_env: true
provider: Cline Pass
provider_id: cline-pass
model: Kimi K3
model_id: cline-pass/kimi-k3
model_source: providers.json
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

| harness              | detected by                        | provider + model source                                                                                                                                                                             |
| -------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cline (CLI)          | `CLINE_*` env, `cline` ancestor    | `~/.cline/data/settings/providers.json` (live), session json, `messages.json`                                                                                                                       |
| Goose                | `GOOSE_*` env, `goose` ancestor    | `GOOSE_PROVIDER`/`GOOSE_MODEL` env, else `config.yaml` (`active_provider` + `providers.<p>.model`) — `%APPDATA%\Block\goose\config\config.yaml` on Windows, `~/.config/goose/config.yaml` elsewhere |
| Kimi Code            | `KIMI_*` env, `kimi` ancestor      | `~/.kimi-code/config.toml` `default_model` (`<provider>/<model-id>`)                                                                                                                                |
| MiniMax Code (`mmx`) | `MMX_CONFIG_DIR` / `MINIMAX_*` env | `~/.mmx/config.json` `defaultTextModel`/`model`, else bundle default `MiniMax-M3`                                                                                                                   |
| pi                   | `PI_CODING_AGENT=true`             | todo (sessions `model_change` metadata)                                                                                                                                                             |

Extend `harness_rules`, `provider_rules`, and `model_rules` in [`src/main.zig`](./src/main.zig) as new harnesses/providers/models appear.

## toolchain selection

| option | cross targets | binary size | maintainer fit | verdict |
| --- | --- | --- | --- | --- |
| `deno compile` | 5 (no Windows ARM64) | ~80–120 MB | TS, high | rejected: size, missing target |
| `bun build --compile` | 13 (incl. win-arm64, musl) | ~50–100 MB | TS, high | rejected: size |
| rust | all (per-target) | ~2–10 MB | low | rejected: no advantage over zig here |
| **zig 0.16** | all, incl. win-arm64, linux-musl, macOS without SDK | **~0.2–0.5 MB** | low, but the codebase is tiny | **chosen** |

zig 0.16 std notes (for future contributors): file/process IO goes through the `std.Io` interface; `main` takes `std.process.Init` (`arena`, `gpa`, `io`, `minimal.args`, `environ_map`); search fns are `std.mem.find*`; Toolhelp32 was removed from `std.os.windows` (externs declared locally in `src/main.zig`); all targets build without libc, which is also why process walking is unsupported on macOS cross-builds (no `posix_spawn`/`sysctl` without the Apple SDK).

## building

Requires [zig](https://ziglang.org) 0.16:

```sh
zig build                     # native binary -> zig-out/bin/
zig build dist --prefix .     # all six targets -> bin/
```

## committing

Follow [commits.md](https://github.com/bevry-labs/skills/blob/main/commits.md) — the `Co-authored-by` trailer comes from `agent-detection --trailer`, never constructed by hand.

### co-author trailer format

```
Co-authored-by: ${harness} - ${model} <${lowercase-alphanumeric-harness}-${lowercase-alphanumeric-model}@local>
```

Rules:

- `${harness}` and `${model}` are the display names from `harness_rules` / `model_rules` in [src/main.zig](./src/main.zig) (e.g. `Cline`, `Kimi Code CLI`, `MiniMax-M3`).
- The `<…>` local part is generated by [`trailerEmail`](./src/main.zig) — it strips every non-alphanumeric character from each side (spaces, dashes, dots), lowercases the rest, joins the two sides with a single `-`, and appends `@local`.
- `@local` is a TLD marker, not a real address; it identifies the trailer as the agent's local credit, not a routable contact.
- The trailer line is preceded by a blank line inside the commit message body.

When the display names in `harness_rules` / `model_rules` change, the generated local changes too — keep the list below in sync.

### Known co-author identities

- `Co-authored-by: Cline - Kimi K3 <cline-kimik3@local>`
- `Co-authored-by: Kimi Code CLI - MiniMax-M3 <kimicodecli-minimaxm3@local>`
- `Co-authored-by: MiniMax Code - MiniMax-M3 <minimaxcode-minimaxm3@local>`
- `Co-authored-by: pi - MiniMax-M3 <pi-minimaxm3@local>`

Planned (harness or model not yet implemented):

- Grok Build / Grok 4.5

## binary formats ("universal" / fat binaries)

Native executables are OS- and ISA-bound (PE/ELF/Mach-O; x86_64/aarch64); no compiler emits one native file for every OS. Fat formats are per-OS-family:

- **Mach-O Universal 2** (macOS only, N slices) — combinable on any host via `llvm-lipo -create`; rejected: per-platform binaries suffice.
- **APE / Cosmopolitan** — one x86_64 file runs on Windows/Linux/macOS/BSD, plus an aarch64 APE for Linux/macOS ARM; requires a C rewrite (`cosmocc`) or Rust tier-3 `*-unknown-linux-cosmo` targets, and loses the Windows Toolhelp32 ancestry walk (POSIX-everywhere model) → degraded to env+cwd detection. Rejected for now: rewrite cost + capability loss.
- **ARM64X/ARM64EC PE** — Windows 11 ARM only, MSVC toolchain.
- **FatELF** — never mainlined, dead.
- **WASM / JVM / .NET FDD** — one file, but a runtime must be installed; violates zero-dependency.

**Decision: per-platform native binaries.** Six files at ~0.2–0.5 MB each cover Windows/Linux/macOS × x86_64/aarch64 completely.

## distribution: committed binaries → CI artifacts

Binaries were initially committed to `bin/` (they are tiny). Reconsidered: committed binaries still bloat every clone forever, fight source-only review, and desynchronize from source (rebuilds produce binary diffs unrelated to logical changes). **Decision:** GitHub Actions builds all six targets on every push to `main` and attaches them to a rolling `nightly` GitHub Release, giving every platform a stable, auth-free direct-download URL: `https://github.com/bevry-labs/agent-detection/releases/latest/download/<asset>`. `bin/` was purged from git history (filter-branch) and is gitignored — no binary ever touches history.

## platform caveats

- **macOS** — native builds walk processes via `libproc` (`proc_pidinfo` for parent pid, `proc_pidpath` for the executable basename) and `sysctl` (`KERN_PROCARGS` for the argv blob). Node-launched harnesses (kimi-code CLI, mmx, etc.) have basename `node`, so we additionally scan argv for a per-harness marker (e.g. `kimi-code` in `argv[1]` when launched as `exec -a "kimi-code" node …`). Cross-builds without libc still cannot walk processes; harness detection falls through to env markers, and Cline session resolution falls back to cwd+running+newest (avoid parallel sessions in one directory).
- **mmx** — node shim, so its ancestor exe name is generic (`node.exe`); detection relies on env markers (`MMX_CONFIG_DIR`, `MINIMAX_*`). Model comes from `~/.mmx/config.json` when present, else the bundle default `MiniMax-M3`.
- **goose** — Windows config lives at `%APPDATA%\Block\goose\config\config.yaml` (`active_provider` + `providers.<p>.model`); `GOOSE_PROVIDER`/`GOOSE_MODEL` env override it.
- **pi** — harness env-detected; model detection (sessions `model_change` metadata) is TODO.

## future work

Expanded harness, provider, and model detections:

- pi model detection (sessions `model_change` metadata)
- Grok Build detection (previously `@todo` in skills/commits.md)
