# powershell.md

PowerShell 7.6+ work notes for this repo; AGENTS.md points here for the
shell-side gotchas.

## Tooling on this host

- The Kilo `grep`/`glob` tools are broken on this host (they fail with a
  `Microsoft.PowerShell.Archive` / `Expand-Archive` load error). Use
  `Select-String -Path ... -Pattern ...` (bash tool) instead. `rg` is
  also not installed — same fallback.
- `findstr /n "pattern" file` is the other no-alloc fallback for the
  stdlib sources (they're one long line in places, so `Select-String`
  on the raw file can miss; read line-slices with
  `(Get-Content file)[a..b]`).

## Line endings: never round-trip through Set-Content

This repo's `.gitattributes` is `* -text` — git will **not** normalize
line endings for you. The checked-out files are LF. Two PowerShell traps
follow from that:

1. `Set-Content -Value <array> -NoNewline` writes every array element
   **back-to-back with no separator** — the file comes back as one giant
   line, not an array of lines.
2. `Set-Content` without `-NoNewline` separates array elements with the
   platform newline (**CRLF on Windows**) and rewrites the whole file —
   silently converting an LF file to CRLF. A CRLF-converted file shows
   up as a full-file diff in git.

Both cost a full revert during the strip-raw implementation
(2026-08-13). For any bulk file rewrite (splices, large replacements,
line-ending normalization) build the final content as a single string
with explicit `` "`n" `` joins and write it as raw bytes:

```powershell
$lines = Get-Content src/main.zig
$newblock = Get-Content "$env:TEMP\kilo\new_block.zig"
$content = ($lines[0..4684] -join "`n") + "`n" + $newblock + "`n" +
           ($lines[5000..($lines.Count - 1)] -join "`n")
[System.IO.File]::WriteAllText(
    (Resolve-Path src/main.zig),
    $content,
    [System.Text.UTF8Encoding]::new($false)   # LF, no BOM
)
```

After any rewrite, verify with `git diff --stat` that the diff stayed
small (a full-file diff means a line-ending conversion slipped through)
and confirm the file is LF (see the byte check below).

## Targeted edits: Get-Content -Raw + .Replace + byte write

`Get-Content -Raw` yields a single string; a plain `.Replace(old, new)`
on it followed by the byte-level write above is the safe way to do
targeted edits without disturbing every other line. `.Replace` is
**literal** — `-replace` and `[regex]::Replace` are regex, so only use
them for small deterministic patterns (e.g. stripping a repeated
`.buildEnv = build\w+` field), and `[regex]::Escape` the needle when in
doubt.

## Regex on huge files: use IndexOf slicing, not regex Replace

`[regex]::Replace` over a ~390 KB single string with a non-greedy
`.*?` pattern throws `RegexMatchTimeoutException` (the engine's default
15-second budget is exhausted by catastrophic backtracking). Don't tune
timeouts — avoid regex for large-block surgery entirely. Anchor with
`String.IndexOf` and slice:

```powershell
function Slice($content, $startAnchor, $endAnchor, $replacement, $what) {
    $s = $content.IndexOf($startAnchor)
    if ($s -lt 0) { throw "start anchor `"$what`" not found" }
    $e = $content.IndexOf($endAnchor, $s + $startAnchor.Length)
    if ($e -lt 0) { throw "end anchor `"$what`" not found" }
    return $content.Substring(0, $s) + $replacement + $content.Substring($e)
}
```

## Stale line numbers are a trap when scripting splices

A line-number-based splice (`$lines[0..N] + $block + $lines[M..]`) is
only valid for the file state it was computed against. Any prior edit
that shifts lines invalidates the numbers silently — the splice lands in
the middle of a function and the file is corrupted. Always anchor on
**content** (unique surrounding text), not line numbers, and re-verify
the boundary lines after each splice.

## Line-ending byte check

To count LF vs CRLF without regex backtick hell:

```powershell
$b = [System.IO.File]::ReadAllBytes((Resolve-Path src/main.zig))
$lf = 0; $crlf = 0
for ($i = 0; $i -lt $b.Length; $i++) {
    if ($b[$i] -eq 10) {
        if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } else { $lf++ }
    }
}
"lf=$lf crlf=$crlf"
```

## sqlite3 CLI verification patterns

The store is reached by shelling out to `sqlite3`; these are the
fast checks for the `fixtures/index.sqlite3` state:

- `sqlite3 -json -batch db "<sql>"` — every result row comes back as a
  JSON array line; a scalar statement still emits a row, e.g. a
  `PRAGMA busy_timeout = N;` setter prints `[{"timeout":N}]` (harmless
  if discarded).
- `SELECT changes() AS c` after a DELETE → `[{"c":N}]`. The count is
  **connection-local**, so run the DELETE and `SELECT changes()` in ONE
  `sqlite3` invocation (the codebase does exactly that).
- Schema/state spot-checks: `sqlite3 db ".tables"`,
  `"PRAGMA table_info(queue)"`, and
  `"SELECT mode, COUNT(*) FROM queue GROUP BY mode;"`.
- **Fresh-store gotcha:** a command that only runs DML (e.g.
  `fixtures dequeue --all`) fails with "no such table" against a
  freshly-deleted DB unless the schema is ensured first. In the Zig
  code this is the `sqliteRun` vs `sqliteQuery` distinction — only
  `sqliteQuery` runs `ensureSchema`. When recreating the store, run a
  schema-ensuring command first. (Found when the migration's
  `Remove-Item fixtures/index.sqlite3` made the next `dequeue` fail;
  fixed by routing `deleteQueueRows` through `sqliteQuery`.)

## Iterate the right directory

`std.Io.Dir.cwd().iterate()` iterates the CWD's immediate children —
it does **not** recurse into `fixtures/`. Filtering its entries for
`fixtures/*.json` silently finds nothing (a real no-op bug: the
`--missing-fixture-entry` scan found 0 files until it was switched to
`openDir(io, "fixtures", .{ .iterate = true })`).

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
