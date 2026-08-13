# Dedup sweep: unify binary names, split dev.zig, trim markdown, free filter, top-100

> Provenance: original prompt (verbatim) — "Develop a fresh plan … There is still too much
> duplication/redundancy inside our *.zig, and between our {AGENTS,CONTRIBUTING,zig,powershell}.md files."
> Follow-up decision prompts (verbatim, in order):
> 1. "How should the unified `binary_names` list be generated? …" → **Comptime platform helper (Recommended)**
> 2. "Where should 'free for everyone' live …?" → **Per-recipe free bool (Recommended)**
> 3. "For the evergreen top-50 file …?" → **Move, rename, expand now (Recommended)**
> Agent model: deepseek-v4-pro (reported by harness).

## Goal

Cut the size and duplication of `src/main.zig` (6,596 lines) and of the four
root `*.md` files, without changing observable behavior of the released
`agent-detect` binary. Consolidate the three-plus duplicate "executable name"
lists into one `binary_names`, split the dev-only half of `main.zig` into a
separate `dev.zig`, add a dev-only `--free` filter, and move/expand the
evergreen top-50 catalog.

## Findings (before state)

`src/main.zig` has an internal boundary that is already the right seam:

- **Lines 1–3034** — released core (exit codes, messages, `Detection`, the
  `rulesForModels`/`rulesForProviders`/`rulesForHarnesses` tables, `detect*`
  functions, policy/`buildJson`/`buildTrailer`, `resolveRecipe`, `detect`,
  `usage`/`trailerUsage`).
- **Lines 3035–6262** — a single `pub const dev = if (build_options.dev) struct { … }`
  block (~half the file, ~3,200 lines): the `fixtures` namespace, sqlite
  helpers, `RecipesForFixtures` (~200 rows), probe/launch, `scanVersionToken`.
- **Lines 6263–6596** — entry (`main`, `mainInner`, `runAction`, `isKnownAction`).

Four copies of "the executable names for a harness" exist:

| # | Location | Shape | Used for |
|---|----------|-------|----------|
| 1 | `HarnessRule.proc_names` (line 650) + `cline_procs`/`goose_procs`/… const arrays (679–684) | bare + `.exe` | ancestry matching (`detect`, line 2893) |
| 2 | `RecipesForFixtures.probeNames` (line 4032), repeated across ~200 rows (4232–4480) | bare + `.exe` + `.cmd`/`.ps1` (npm harnesses only) | PATH availability probe (`probeBinary`) + `--version` (`harnessVersion`) |
| 3 | `assertNotInAgent` inline `proc_names` (6232–6248) | bare + `.exe` + extra `claude`/`claude.exe` | daemon user-only guard |
| 4 | `assertNotInAgent` inline `env_markers` (6206–6219) | (duplicates `*_env` arrays) | daemon guard |

Other dedup/quality findings:

- Dev-only functions `derivedAgentId`, `derivedFixtureId`, `generationHash`,
  `channelJson`, `spawnTrailerLine`, `mergeWriteFixture`, `readChannelObject`
  (4105–4226) are **mis-indented as top-level** but are actually inside the
  `dev` block (Zig ignores indentation). Confusing and error-prone.
- `harnessVersion` (4542) and `harnessAvailable` (5364) each re-implement
  "look up recipe by `agent_id`, then iterate the probe names".
- `std.process.executablePath` self-path boilerplate is repeated 3× (5131,
  5955, 6077); `bufPrint("{d}")` count-emission is repeated many times.
- Docs overlap: CONTRIBUTING.md restates the sqlite schema (22–34) and the
  evergreen-top-50 policy (252–279) that DESIGN.md already owns (106–144,
  408–445); README.md restates a per-exit-code table (67–73) that DESIGN.md
  "exit status registry" owns (264–342).

## Decisions

### 1. Unify to `binary_names` via a comptime platform helper

**Before** — three name lists with slightly different contents (see table above).

**After** — one comptime helper expands base names per platform:

```zig
/// e.g. binaryNames(&.{"kimi", "kimi-code"}) →
///   Windows: { "kimi", "kimi.exe", "kimi.cmd", "kimi.ps1",
///              "kimi-code", "kimi-code.exe", "kimi-code.cmd", "kimi-code.ps1" }
///   else:    { "kimi", "kimi-code" }
fn binaryNames(comptime bases: []const []const u8) []const []const u8 { … }
```

- Rename `HarnessRule.proc_names` → `HarnessRule.binary_names`; fill inline via
  the helper (drop the `*_procs` const arrays).
- Delete `RecipesForFixtures.probeNames`; add a dev helper
  `binaryNamesForHarness(harness_id)` that looks up the harness rule and
  returns `.binary_names`. `probeBinary`/`harnessVersion`/`harnessAvailable`
  use it.
- Rewrite `assertNotInAgent` to derive in-scope names from
  `rulesForHarnesses[*].binary_names` (and `env_markers` from
  `rulesForHarnesses[*].env_markers`), keeping a **short literal** for the
  pending-but-known harnesses (`claude`, `codex`, `grok`, `gemini`) that have
  no rule yet.
- Ancestry matching, PATH probing, `--version`, and the daemon guard all
  consume the same list.

**Pros:** one source of truth (no drift); removes ~200 rows × 4 string
literals plus 6 const arrays; fixes the `.cmd`/`.ps1` asymmetry; smaller file;
the released binary's ancestry list becomes platform-accurate (drops pointless
`.exe` entries on non-Windows).

**Cons:** the released Windows binary now carries `.cmd`/`.ps1` literals it
will only ever use for ancestry matching where they never appear (negligible
size, zero behavior change); probing may try one or two non-existent shim
names on scoop/brew-installed harnesses (harmless — `catch continue` skips);
a single helper means the exact install-surface nuance from CONTRIBUTING's
install table is encoded as "uniform shims on Windows" rather than
per-harness (accepted per the "cycle until one works" philosophy).

### 2. Split dev-only code into `src/dev/dev.zig`, shared code into `src/lib/core.zig`

Target layout (no circular imports):

```
src/main.zig          entry + help text + re-exports (~350 lines)
src/lib/core.zig      everything shared by both binaries (old lines 1–3034)
src/dev/dev.zig       pub const dev = if (build_options.dev) struct {…} else struct {} (old 3035–6262)
src/exit_statuses.test.zig   (imports updated)
src/known_fixtures.test.zig  (imports updated)
```

- `src/lib/core.zig` imports `std`/`builtin`/`build_options` only; re-home the
  exit codes, messages, `Detection`, rule structs + tables, `binaryNames`
  helper, `detect*`, policy builders, `resolveRecipe`, `detect`, `slugId`,
  `canonicalIdFor`, `envValueAllowed`, `optStringValue`, `addEvidenceClaim`,
  `usage`/`trailerUsage`.
- `src/dev/dev.zig` imports `../lib/core.zig`; keeps `pub const dev =
  if (build_options.dev) struct { … } else struct {};` (same comptime gate as
  today), plus the recipes table, sqlite helpers, probe/launch, and
  `scanVersionToken`.
- `src/main.zig` imports `lib/core.zig` and `dev/dev.zig`; re-exports
  `pub const dev = @import("dev/dev.zig").dev;` and the public core API that
  tests/entry need, so the two `*.test.zig` files keep working with minimal
  churn (`main.dev.scanVersionToken`, `main.dev.recipesForFixtures`,
  `main.dev.isEnvValueAllowed`, and `main.buildJson`/`main.Detection`/…).
- Make currently-file-private core helpers `pub` where `dev.zig` or the entry
  needs them: `envValueAllowed`, `optStringValue`, `addEvidenceClaim`, and any
  rule lookup used by `binaryNamesForHarness`.
- `build.zig` needs no structural change (root module stays `src/main.zig`;
  `@import("build_options")` resolves for both imported files). Verify
  `zig build`, `zig build dev`, `zig build test`, `zig build dist` all pass.
- Fix the mis-indented dev functions (correct 4-space indent inside the
  struct) as part of the move.

### 3. `--free` filter (dev-only)

- Add `free: bool = false` to `RecipesForFixtures` (dev.zig).
- Mark `free = true` on the free-for-everyone combos: OpenRouter `:free` ids,
  Groq/Cerebras/DeepSeek/ZenMux/… free tiers, and any already-free recipe
  (e.g. `cline-clinepass-deepseekv4flash` `free/deepseek-v4-flash`,
  `opencode-opencode-deepseekv4flashfree`, the `omp-zenmux-*-free` rows).
- Add `--free` to `FilterOptions`/`parseFilters` and `scopeCandidates` so
  `fixtures queue --free` / `fixtures dequeue --free` enumerate recipes where
  `free == true` (recipe-scoped, like `--recipes`; not a stored `fixtures`
  column).
- Cheap / expensive / not-paid-for-by-user tiers stay **documentation only**
  (they are per-user, not per-recipe) — see §5.

### 4. Move + rename + expand the evergreen catalog

- Move `docs/evergreen-top50-models.txt` → `fixtures/evergreen-top100-models.txt`.
- Rename (top50 → top100) and expand to 100 entries, curating the additions
  from the documented leaderboards (artificialanalysis.ai, arena/LMArena,
  llm-stats.com, HF trending, OpenRouter top-weekly) — never guessed.
- Update the two references (CONTRIBUTING.md ~line 276, DESIGN.md decision #13)
  to the new path/name/count, and drop the duplicated prose in CONTRIBUTING
  (keep the full policy in DESIGN.md).

### 5. Markdown dedup (reference, don't restate)

Apply the rule "specify the context of a reference, not its contents":

- **CONTRIBUTING.md** keeps only *how-to* runbooks; replace restatements with
  pointers:
  - Sqlite schema paragraph (22–34) → one-line pointer to DESIGN.md
    "SQLite state store".
  - "bulk additions … evergreen top 50" prose (252–279) → pointer to
    DESIGN.md decision #13, keeping only the actionable free/paid probing
    runbook.
  - Add the new **"agent cost priorities"** section: free-for-everyone (coded,
    `--free`), then cheap-for-user / expensive-for-user / not-paid-for-by-user
    as per-account guidance.
- **README.md** per-exit-code table (67–73) → point to DESIGN.md "exit status
  registry", keeping only the one-line "what to do" per use case.
- **AGENTS.md** / **zig.md** / **powershell.md** are already pointers; keep
  them (no content moves, just fix any stale `src/main.zig` line references
  after the split — e.g. zig.md's "patterns this repo uses" and "the dev
  struct (`main.dev`)" notes).
- No markdown file should repeat what another owns; cross-references carry
  context only.

## Ordered task list

1. Create `src/lib/core.zig`: move lines 1–3034 of `src/main.zig` verbatim,
   make the helper functions that `dev.zig`/entry need `pub`, add the
   `binaryNames(comptime bases)` helper, rename `proc_names` → `binary_names`,
   fill via helper, delete the `*_procs` arrays.
2. Create `src/dev/dev.zig`: move lines 3035–6262 verbatim, re-indent the
   mis-indented functions, `@import("../lib/core.zig")`, replace `probeNames`
   uses with `binaryNamesForHarness`, add `free: bool` + `--free` filter, and
   rewrite `assertNotInAgent` to derive names/markers from the rule tables +
   a short pending-harness literal.
3. Rewrite `src/main.zig` as the thin entry: `main`/`mainInner`/`runAction`/
   `isKnownAction`/`usage`/`trailerUsage`/`devUsage`, importing and re-exporting
   `lib/core.zig` + `dev/dev.zig`.
4. Update `src/exit_statuses.test.zig` and `src/known_fixtures.test.zig`
   imports for the new module paths (or rely on `main.zig` re-exports).
5. Move/rename/expand `docs/evergreen-top50-models.txt` →
   `fixtures/evergreen-top100-models.txt` (+20 curated entries).
6. Dedup the markdown per §5, update stale paths/line references.
7. Validate (below); commit only when the user asks (use the generated
   co-author trailer per AGENTS.md).

## Risks / watch-outs

- **Circular import:** core ↔ dev must never reference each other. Only
  `main.zig` and `dev.zig` import `core.zig`; `core.zig` imports nothing
  project-local. `dev.zig` must not be imported by `core.zig`.
- **Comptime gate still holds:** released binary must still drop all dev code
  (`zig build dist` output unchanged in behavior/size-wise no dev surface).
- **Tests are ReleaseSmall** (build.zig): keep asserts structural, not
  timing-based (existing zig.md gotcha).
- **`--free` is recipe-scoped** (like `--recipes`), not a `fixtures` column —
  do not conflate it with `available`/`successful`.
- **Line-ending discipline** (powershell.md): use `Get-Content -Raw` +
  `.Replace` / content-anchored splices + LF byte-write, never `Set-Content`;
  verify `git diff --stat` stays small after the bulk split.

## Validation

- `zig build` and `zig build dev` both succeed; `zig-out/bin/agent-detect.exe`
  `--help`, `identify`, `trailer co-author`, `check-reciprocal`, `--version`
  behave identically to before.
- `zig build test` passes (both test files).
- `zig build dist` emits the six released binaries; confirm the released
  binary still rejects `fixtures`/`raw` (dev surface absent).
- Grep confirms no `probeNames`/`proc_names`/`*_procs` remain; exactly one
  `binary_names` source per harness.
- `fixtures queue --free` (dev) enumerates only `free == true` recipes.
- `git diff --stat` shows a large net deletion, no full-file line-ending
  churn; `docs/evergreen-top50-models.txt` gone, `fixtures/evergreen-top100-models.txt`
  present with 100 entries and updated cross-references.

## Out of scope

- Further `RecipesForFixtures` normalization (generating the ~200-row table
  from rules + per-harness launch templates) — a possible follow-up, not this
  sweep.
- The launch argv[0] Windows-extension issue (bare `kilo` vs `kilo.cmd`) — a
  separate correctness concern; note and defer.
- Changing `build.zig`/`build.zig.zon` structure or CI.
