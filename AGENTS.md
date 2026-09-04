# AGENTS.md

This project conforms to Bevry's skills. Reference their remote URLs
only — do not pull their contents into this file. When a referenced
skill applies with this project's tweaks, the local `<name>.md` file at
this repo root references the remote URL and lists the tweaks
underneath; this process is documented in the upstream repo's
[local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

- https://github.com/bevry-vibes/skills/blob/main/policy.md —
  **not applied to this project.** agent-detect is the enforcement
  mechanism that policy.md delegates to, so this project must run
  on all agents, including those that violate that policy; it cannot
  apply the policy to itself.
- [commits.md](./commits.md) —
  **applies**, with this project's tweaks (zig build, generated
  co-author trailer).
- https://github.com/bevry-vibes/skills/blob/main/conventions.md —
  **applies** (the base config files were pulled in at scaffold time;
  the splat-naming rule lives here).
- https://github.com/bevry-vibes/skills/blob/main/minimax.md —
  **applies** when the running agent is a MiniMax M3 model (its rules
  gate themselves on model and harness).
- [plans.md](./plans.md) —
  **applies to every harness** that writes a plan for this project
  (plans + `.prompts.md` companions in `.plans/`; supersedes the
  `kilo.md` skill, now retired upstream, whose plan tweaks it
  absorbed).

This file is not policy — it is a pointer.

## token cost

`agent-detect` consumes no model tokens: detection reads only local
state (env markers, process ancestry, harness config/session files, the
local Kilo DB) and performs no network I/O. Token cost arises only from
the session hosting it — e.g. a live `fixtures capture` runs inside a
real agent session, and that session is a model conversation.

## powershell

The bevry-vibes [powershell.md](https://github.com/bevry-vibes/skills/blob/main/powershell.md)
skill **applies** — the 7.6+ mandate, modern-syntax preferences, the
`Set-Content` line-ending traps, IndexOf splicing, and the sqlite3 CLI
patterns live there. This repo's and this host's tweaks — the
`* -text` line-ending fact, the broken-tooling fallbacks, cleanup
scoping — live in [powershell.md](./powershell.md). Never round-trip a
bulk rewrite through `Set-Content`.

## zig

Build with `zig build` (released), `zig build dev` (maintainer
`fixtures` binary), and `zig build test`. The bevry-vibes
[zig.md](https://github.com/bevry-vibes/skills/blob/main/zig.md) skill
carries the Zig 0.16 API notes and general gotchas; this repo's
patterns and gotchas live in [zig.md](./zig.md). The source is split
across four files — `src/lib/rules.zig` (rule tables + pure name
resolution), `src/lib/core.zig` (ladder + policy), `src/dev/dev.zig`
(the dev-gated fixtures surface), `src/main.zig` (thin entry +
re-exports) — in a strict no-cycles import DAG.

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
