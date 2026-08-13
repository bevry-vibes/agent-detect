# AGENTS.md

This project conforms to Bevry's skills. Reference their remote URLs
only — do not pull their contents into this file.

- https://github.com/bevry-vibes/skills/blob/main/policy.md —
  **not applied to this project.** agent-detect is the enforcement
  mechanism that policy.md delegates to, so this project must run
  on all agents, including those that violate that policy; it cannot
  apply the policy to itself.
- https://github.com/bevry-vibes/skills/blob/main/commits.md —
  **applies**, with this project's tweaks: build via `zig build`,
  generate the co-author trailer with
  `./zig-out/bin/agent-detect trailer co-author`, attach it with
  `git commit --trailer "$(./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather
  than commit without it.
- https://github.com/bevry-vibes/skills/blob/main/minimax.md —
  **applies** when the running agent is a MiniMax M3 model (its rules
  gate themselves on model and harness).
- https://github.com/bevry-vibes/skills/blob/main/kilo.md —
  **applies** when the running harness is `kilo` (its rules gate
  themselves on harness), with this project's tweak (to be upstreamed):
  every plan file the agent generates records its provenance at the top
  of the file — the original prompt that initiated the plan, every
  followup prompt that shaped it (verbatim, in order), and the agent
  model that generated it (as reported by the harness).

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

### Set-Content -NoNewline with an array concatenates, it does not join

`Set-Content -Value <array> -NoNewline` writes every array element
back-to-back with **no separator** — the file comes back as one giant
line, not an array of lines. `Set-Content` without `-NoNewline`
separates array elements with the platform newline (CRLF on Windows),
and even then it **rewrites the file with the platform newline**,
silently converting an LF file to CRLF.

For any bulk file rewrite (splices, large replacements, line-ending
normalization), never round-trip through `Set-Content`. Build the final
content as a single string with explicit `"`n"` joins and write it as
raw bytes:

```powershell
$content = ($lines[0..4684] -join "`n") + "`n" + $newblock + "`n" +
           ($lines[5000..($lines.Count - 1)] -join "`n")
[System.IO.File]::WriteAllText(
    (Resolve-Path src/main.zig),
    $content,
    [System.Text.UTF8Encoding]::new($false)   # LF, no BOM
)
```

`Get-Content -Raw` yields a single string; a plain `.Replace(old, new)`
on it followed by the byte-level write above is the safe way to do
targeted edits without disturbing every other line. This project's
`* -text` git attribute means git will **not** normalize line endings
for you — a CRLF-converted file shows up as a full-file diff, so always
verify `git diff --stat` stayed small after any rewrite and confirm the
file is LF. This gotcha cost a full revert during the strip-raw
implementation (2026-08-13).

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
