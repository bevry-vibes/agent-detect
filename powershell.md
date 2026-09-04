# powershell.md

Local application of the bevry-vibes skills [powershell.md](https://github.com/bevry-vibes/skills/blob/main/powershell.md) —
see the upstream [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

## this project's and this host's tweaks

- This repo's `.gitattributes` is `* -text` — git will **not**
  normalize line endings for you, and the checked-out files are LF, so
  the upstream Set-Content traps apply with full force.
- The Kilo `grep`/`glob` tools are broken on this host (they fail with a
  `Microsoft.PowerShell.Archive` / `Expand-Archive` load error). Use
  `Select-String -Path ... -Pattern ...` (bash tool) instead. `rg` is
  also not installed — same fallback.
- `findstr /n "pattern" file` is the other no-alloc fallback for the
  stdlib sources (they're one long line in places, so `Select-String`
  on the raw file can miss; read line-slices with
  `(Get-Content file)[a..b]`).

## Cleanup scoping

`fixtures dequeue --agent=X` is **platform-unfiltered** — it deletes
rows for every platform (windows + darwin) that share the dims. When
cleaning up test artifacts, add `--platform=` (or use `--fixture=` for
the exact id) so you don't nuke committed-state rows. This one deleted
3 rows instead of the intended 1.

## Reading test failures

A failing `zig build test` is not automatically a regression. The
envelope-shape failure on the 177 legacy `cooked`-shaped darwin
fixtures is an **intended regeneration-completeness signal** (per the
strip-raw plan) — verify a failure is expected before "fixing" it.
