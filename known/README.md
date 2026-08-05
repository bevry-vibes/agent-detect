# `known/` — committed detection-output snapshots

Each file documents what `agent-detection` emits for one canonical
(harness, model) combination. The filename is the trailer's email
local — the same identifier a `Co-authored-by:` line would carry in a
git commit.

Pattern: `known/<email-local>.{json,trailer}.txt`
Example: `known/kimicode-minimaxm3.trailer.txt`

A `.trailer.txt` is omitted for cases where the harness resolves but
the model is still unset (currently `pi`, which has `--trailer` exit 2 in
real detection — the json-only fixture documents the partial shape).

Refresh via `zig build refresh-known` after intentional rule changes;
the diff is reviewed in the same commit as the rule change. The
`known_fixtures` zig test enforces that the on-disk fixtures match what
the binary currently emits.
