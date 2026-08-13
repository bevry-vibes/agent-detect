# windows.md

PowerShell / Windows work notes for this repo. AGENTS.md references this
file for the machine-specific bits that don't belong in policy.

## Tooling on this host

- The Kilo `grep`/`glob` tools are broken on this host (they fail with a
  `Microsoft.PowerShell.Archive` / `Expand-Archive` load error). Use
  `Select-String -Path ... -Pattern ...` (bash tool) instead. `rg` is
  also not installed — same fallback.
- `zig version` reports `0.16.0` (installed via scoop). Build with
  `zig build dev` / `zig build test`; the dev binary lands in
  `zig-out/bin/agent-detect-dev.exe`.

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
   up as a full-file diff in git (nothing to blame but yourself).

Both cost a full revert during the strip-from-raw implementation
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

`Get-Content -Raw` yields a single string; a plain `.Replace(old, new)`
on it followed by the byte-level write above is the safe way to do
targeted edits without disturbing every other line. After any rewrite,
verify with `git diff --stat` that the diff stayed small.

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

Small deterministic regexes are fine (e.g. stripping a repeated
`.buildEnv = build\w+` initializer from recipe rows).

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
