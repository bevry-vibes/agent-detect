# AGENTS.md

This project conforms to Bevry's skills. Reference their remote URLs
only — do not pull their contents into this file. When a referenced
skill applies with this project's tweaks, the local `<name>.md` file at
this repo root references the remote URL and lists the tweaks
underneath; this process is documented in [meta.md](./meta.md).

- https://github.com/bevry-vibes/skills/blob/main/policy.md —
  **not applied to this project.** agent-detect is the enforcement
  mechanism that policy.md delegates to, so this project must run
  on all agents, including those that violate that policy; it cannot
  apply the policy to itself.
- [commits.md](./commits.md) —
  **applies**, with this project's tweaks (zig build, generated
  co-author trailer).
- https://github.com/bevry-vibes/skills/blob/main/minimax.md —
  **applies** when the running agent is a MiniMax M3 model (its rules
  gate themselves on model and harness).
- [kilo.md](./kilo.md) —
  **applies** when the running harness is `kilo` (its rules gate
  themselves on harness), with this project's tweak (to be upstreamed).

This file is not policy — it is a pointer.

## splat naming

Never refer to a to-be-defined name with `X`, `Xxx`, or `XXX`.
Use an asterisk splat (`build*Env`) or the interpolated form matching
the language's conventions — `build<Harness>Env` (camelCase),
`build<HARNESS>_ENV` (UPPER_SNAKE), `build{Harness}Env` /
`build${HARNESS}Env` as the syntax dictates. Always a real, greppable
pattern — never `X`.

## token cost

`agent-detect` consumes no model tokens: detection reads only local
state (env markers, process ancestry, harness config/session files, the
local Kilo DB) and performs no network I/O. Token cost arises only from
the session hosting it — e.g. a live `fixtures capture` runs inside a
real agent session, and that session is a model conversation.

## powershell

All PowerShell work must run on PowerShell 7.6 or later. Every
PowerShell script starts with `#Requires -Version 7.6`, and scripts
should use modern syntax where appropriate — pipeline chain operators
(`&&` / `||`), ternary / null-coalescing expressions (`?:` / `??` /
`??=`), switch expressions, `ForEach-Object -Parallel`, typed class
definitions, native-command `2>&1` stderr capture — instead of legacy
forms.

The machine-specific gotchas — the `Set-Content` line-ending traps
(`Set-Content -NoNewline` concatenates arrays; plain `Set-Content`
rewrites LF files as CRLF, and `* -text` means git won't fix it),
regex-timeout IndexOf splicing, stale-line-number splices, this host's
tooling fallbacks, and the sqlite3 verification patterns — live in
`powershell.md`. Never round-trip a bulk rewrite through `Set-Content`.

## zig

Build with `zig build` (released), `zig build dev` (maintainer
`fixtures` binary), and `zig build test`. The source is split across
four files — `src/lib/rules.zig` (rule tables + pure name resolution),
`src/lib/core.zig` (ladder + policy), `src/dev/dev.zig` (the dev-gated
fixtures surface), `src/main.zig` (thin entry + re-exports) — in a
strict no-cycles import DAG. Zig 0.16 API notes, this repo's patterns,
and its gotchas live in `zig.md`.

## harness configuration

Never create, modify, or overwrite a harness's config/auth files or set
API keys on the user's machine — this includes anything under
`~/.<harness>/`, `~/.config/<harness>/`, `%APPDATA%`, and credential
stores. Harness setup, logins, and API keys are the user's
responsibility alone, and the user decides when configs change. This is
a hard rule; do not probe for, ask for, offer to set, or write
credentials. `agent-detect` reads these files read-only; the project
performs no harness config writes — nothing lands in a sandboxed HOME or
anywhere else.
