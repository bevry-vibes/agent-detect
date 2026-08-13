# Dedup sweep plan (restored) — binary_names, dev split, top-100, markdown reduction

Supersedes the two prior dedup plans (`.kilo/plans/1786606126543-*.md` and the
earlier draft of this file, committed as `ea30157`). Written for the codebase
as it stands after `.kilo/plans/1786534409840-strip-from-raw-consolidated-implementation.md`
landed (verified: no `buildEnv`/`EnvSetup`/`origin`/`from-raw` remain; the
4-table store with `scope_recipes`/`scope_missing_fixture_file` markers is live).

## Provenance

Every prompt that shaped this plan is recorded verbatim (untruncated,
timestamped, in order) in the companion file
`.kilo/plans/1786614488977-dedup-sweep-binary-names-dev-split.prompts.md` —
plans link to it; they do not inline prompts. Agent model: deepseek-v4-pro
(reported by harness).

## Convergence / divergence register (good bits vs bad bits)

| Topic | Older plan (…6543) | First draft (this file, ea30157) | Synthesized decision |
|---|---|---|---|
| binary_names source | explicit per-harness lists, no generic expander (user f/p 4) | generic comptime expander (`.exe`/`.cmd`/`.ps1` for all) | **inline ternary in each harness rule** — no expander, no `*_procs` arrays; each rule's `binary_names = if (builtin.os.tag == .windows) … else …` |
| file split | 2-way (`main.zig` + `fixtures.zig`, circular import) | 3-way (`lib/core.zig` + `dev/dev.zig` + thin `main.zig`) | **4-way with data-only `lib/rules.zig`** — rule tables + pure name lookups split from the ladder; strict DAG, no cycles |
| launch argv[0] | substitute argv[0] by cycling `binary_names` until spawn succeeds | deferred as out-of-scope | **adopt substitution** (the user's "cycle until one works" applied to launching) |
| `--free` storage | full scope flag with `scope_free` queue marker column | recipe-only enumeration, no column | **deferred** — the whole `--free` proposal moves to Deferred follow-ups (would complicate this sweep); the earlier `scope_free`-column design is recorded there for later |
| probe return | `probeBinary` returns `?[]const u8` (working name) | left `bool` | **adopt `?[]const u8`** (feeds launch substitution + `harnessVersion`) |
| small dedups | splitId/joinId, daemonWriteTo, markCaptureOutcome, providerForName fold, resolveRecipe scan | only noted, not tasked | **adopt all** (verified still present post-strip-from-raw) |
| markdown split | DESIGN=what, CONTRIBUTING=how, detailed per-file cuts | high-level §5 | **adopt the detailed cuts**, refreshed against current files |
| top-50 file | `git mv` + `.gitignore` exception cleanup + expand | move only | **adopt the `.gitignore` cleanup** (exceptions at `.gitignore:53,65-68`) |
| recipes row count | ~177 (correct) | ~200 (wrong) | **177** |

**Bad bits discarded:** the generic expander (mis-lists scoop/brew/uv/winget
harnesses and kimi, whose Windows install is `.exe`-only); deferring launch
argv[0] substitution; the recipe-only `--free` (inconsistent with the
scope-marker architecture); the 2-way circular-import split; the stale
pre-strip-from-raw line numbers in the older plan (re-locate everything by
symbol, not line).

**Convergent (both plans agree):** one `binary_names` origin; docs→fixtures
top-100 move; markdown reference-not-restate; DESIGN=what / CONTRIBUTING=how.
(`--free` + cost tiers, agreed convergent in principle, are deferred — see
Deferred follow-ups.)

## Final decisions

### 1. `binary_names` — inline platform ternary in each harness rule

`HarnessRule.proc_names` → `binary_names`. Each rule writes its `binary_names`
value inline as a comptime ternary — **no generic expander, no `*_procs`
const arrays, no stems/shim flags**:

```zig
pub const rulesForHarnesses = [_]HarnessRule{
    .{ .name = "kilo", .label = "Kilo Code", .license = "MIT",
       .license_sources = &.{ "…", "…" }, .env_markers = &kilo_env,
       .binary_names = if (builtin.os.tag == .windows)
           &[_][]const u8{ "kilo", "kilo.exe", "kilo.cmd", "kilo.ps1" }
       else
           &[_][]const u8{ "kilo" } },
    .{ .name = "kimi-code", …, .env_markers = &kimi_env,
       .binary_names = if (builtin.os.tag == .windows)
           &[_][]const u8{ "kimi", "kimi-code", "kimi.exe", "kimi-code.exe" }
       else
           &[_][]const u8{ "kimi", "kimi-code" } },
    // …
};
```

(Each branch's `&[_][]const u8{…}` coerces to the field type
`[]const []const u8` via the result location; if a branch ever resists,
annotate it `: []const []const u8` or write `&[_][]const u8{…}[0..]`.)

- Windows branch content comes from the CONTRIBUTING install table: bare
  names + `.exe` always; `+ .cmd/.ps1` only for npm-shimmed harnesses
  (`cline`, `mmx`, `qwen`, `kilo`, `cursor`). NOT for `kimi` (native
  `~\.kimi-code\bin\kimi.exe`), `pi`, `omp`, `reasonix`, `crush`, `opencode`,
  `vibe`, `copilot`, `goose` (scoop/brew/uv/winget shims) — this also
  deletes today's phantom `kimi.cmd`/`kimi.ps1` probe entries.
- Order = today's probe order (bare stems first, then extensions) so
  first-hit behavior is preserved.
- `goose` keeps two stems (`goose`, `goosed`).
- Every consumer reads the same list: `detect()` ancestry scan, PATH probe
  (`probeBinary`), `--version` (`harnessVersion`), launch argv[0]
  substitution, and the daemon guard. `RecipesForFixtures.probeNames` and all
  177 per-row values are deleted; a new `harnessRuleForFixtureId(agent_id)`
  slug-resolves the first `agent_id` segment through `canonicalIdFor(a,
  HarnessRule, &rulesForHarnesses, segment)` (`name`/`label` normalization
  makes `kimicode` resolve to the `kimi-code` rule); an unknown segment →
  null (callers treat it as unavailable → the existing `invalid`/skip paths).
- Daemon guard (`assertNotInAgent`): iterate `rulesForHarnesses[*].binary_names`
  (and `.env_markers` — deleting the hand-copied env list at 6206-6219) plus
  a small `pending_binary_names` const for not-yet-ruled harnesses
  (`claude`, `codex`, `grok`, `gemini` — today's `claude` entries stay;
  same inline ternary style, `+ .exe` on Windows).
- Ancestry-matching semantic change (intentional, from the older plan): the
  node-shim harnesses (`mmx`, `qwen`, `omp`, `crush`, `vibe`) whose
  `proc_names` were empty now match their literal exe names in ancestry —
  the ladder and the guard agree for the first time.

**Pros:** one hand-maintained list per harness; probe/launch/ancestry/guard
can never drift; ~180 field initializers deleted; the released binary's
list is platform-accurate (no pointless `.exe` on Unix). **Cons:** ancestry
for the ex-node-based harnesses newly fires on an exact-name ancestor (a
fix, not a regression — that process *is* the harness); `pending_binary_names`
still needs a hand when new pending harnesses are added.

### 2. Split: `src/lib/rules.zig` + `src/lib/core.zig` + `src/dev/dev.zig` + thin `src/main.zig`

Dependency graph (strict DAG, no cycles):

```
src/lib/rules.zig   → std + builtin only (curated data + pure lookups)
src/lib/core.zig    → rules.zig  (+ std/builtin/build_options)
src/dev/dev.zig     → rules.zig + core.zig
src/main.zig        → all three (entry + re-exports)
```

- `src/lib/rules.zig` — the curated **data + pure name resolution** (~800
  lines; no `Detection`, no I/O, never imports core/dev): `ModelRule`/
  `ProviderRule`/`HarnessRule` structs + the three tables, the `*_env`
  marker arrays, the inline ternary `binary_names` values,
  `env_value_allowlist`, `license_none`/`license_noassertion`, and the pure
  helpers `titleCase`, `slugId`, `slugEquals`, `modelForName`,
  `providerForName`, `providerMetaForName`, `providerForBaseUrl`,
  `harnessRuleForName`, `canonicalIdFor`, `canonicalFilterDim`.
- `src/lib/core.zig` — the ladder + policy (~2,200 lines): exit codes +
  messages, `Detection` + observation structs, ancestry/session helpers,
  the `detect*` functions, the mutating applicators (`applyModel`,
  `applyProviderMeta`, `setProvider`, `setAgentId`), `addEvidenceClaim`,
  `envValueAllowed`, `jstr`/`jint`/`extractAfter`, reciprocity,
  `buildCooked`/`buildJson`/`buildTrailer`/`buildTrailerLine`,
  `resolveRecipe`, `detect`, `usage`/`trailerUsage`.
- `src/dev/dev.zig` — today's lines 3035-6262: `pub const dev =
  if (build_options.dev) struct { … } else struct {};`, the 177-recipe
  table + `capture_prompt`, sqlite layer, queue/dequeue/daemon/capture
  runners, `probeBinary`/`scanVersionToken`/`harnessVersion`,
  `assertNotInAgent`, `isEnvValueAllowed` (re-expose), timeout workers.
  Imports `../lib/core.zig` (+ `../lib/rules.zig` for `HarnessRule`/
  `canonicalIdFor`).
- `src/main.zig` — thin entry (~350 lines): `usage`/`trailerUsage`/
  `devUsage`, `main`/`mainInner`/`runAction`/`isKnownAction`, re-exports
  `pub const dev = @import("dev/dev.zig").dev;` plus aliases of the
  rules.zig + core.zig pub API the tests use (`Detection`, `HarnessRule`,
  `rulesFor*`, `slugId`, `canonicalIdFor`, `reciprocityOf`,
  `buildTrailerLine`, `modelFromMessageData`, `modelFromSessionRow`, …)
  so `known_fixtures.test.zig` / `exit_statuses.test.zig` keep compiling
  through `main.*`.
- `build.zig` unchanged (root module stays `src/main.zig`).
- Fix the mis-indented dev functions (`derivedAgentId`, `derivedFixtureId`,
  `generationHash`, `channelJson`, `spawnTrailerLine`, `mergeWriteFixture`,
  `readChannelObject` — indented as top-level but actually inside `dev`)
  while moving them.
- Fold the small dedups while moving (no behavior change):
  `splitAgentId`/`splitFixtureId` → one `splitId(a, id, comptime n)`;
  the five `{s}~{s}`/`{s}#{s}`/`{s}-{s}` joiners → one `joinId`;
  `daemonWrite`/`daemonWriteErr` → one `daemonWriteTo`;
  `markCaptureOutcome(available, successful)` absorbing the ~6 repeated
  `upsertFixture` dances in `runOneComboCapture`/`runOneComboIdentity`;
  `providerForName` becomes `return (providerMetaForName(name) orelse
  return null).label;` (verified duplicate loop at 895-907);
  `resolveRecipe`'s re-scan uses `modelRuleForName`.

### 3. Launch + probe: cycle `binary_names`, substitute argv[0]

- `probeBinary(io, names) ?[]const u8` — returns the working name (first
  exit-0 `--version` spawn), null when none work. `harnessAvailable` adapts;
  `harnessVersion` iterates the same list.
- Launch (`runOneComboCapture`): keep each recipe's `launch` argv template;
  build argv with argv[0] replaced by each `binary_names` candidate in
  order until `std.process.spawn` succeeds. After a successful spawn there
  is **no re-cycle** on runtime failure (a failed real launch is an
  artifact failure, not a name miss — retrying burns tokens twice). All
  candidates fail → existing `available=1, successful=0` path.

### 4. docs → fixtures, top 100

- `git mv docs/evergreen-top50-models.txt fixtures/evergreen-top100-models.txt`;
  delete the empty `docs/` dir; `.gitignore`: drop the `docs/` exceptions
  (lines 65-68) and the generic `docs/` line (53); `fixtures/` needs no
  change.
- Expand to 100 entries (same `family + canonical variant` format, keep all
  existing rows, append the new band; curated from the leaderboards in
  DESIGN.md #13, never guessed). Update DESIGN.md #13 wording (top 100,
  new path) and the CONTRIBUTING pointer.

### 5. Markdown synthesis — reference, don't restate

Adjudication rule (user-confirmed): a paragraph that explains **what/why**
(a decision, contract, registry, schema, policy) lives in DESIGN.md; a
paragraph that explains **what to do** (commands, steps, fill-in tables,
runbooks) lives in CONTRIBUTING.md. When one section mixes both, split it —
the what/why goes to DESIGN.md, the steps stay in CONTRIBUTING.md with a
pointer.

Single-source-of-truth map:

| Topic | Single home | Others keep |
|---|---|---|
| exit status registry | DESIGN.md "exit status registry" | README: one-line what-to-do per use case |
| SQLite store schema | DESIGN.md "SQLite state store" | CONTRIBUTING: 1-line pointer |
| fixture envelope shape | DESIGN.md "per-platform fixtures" | CONTRIBUTING: 1-line pointer |
| evergreen top-N policy | DESIGN.md decision #13 | CONTRIBUTING: probing runbook + pointer |
| alias conventions | CONTRIBUTING "alias conventions" | recipe-mode section points to it |
| binary_names origin | code (`HarnessRule`) | DESIGN.md #14 (one sentence); CONTRIBUTING add-rule table row |
| per-harness install commands | CONTRIBUTING install table | (nowhere else) |
| zig API gotchas | zig.md | AGENTS.md pointer; powershell.md keeps shell-side only |
| powershell gotchas | powershell.md | AGENTS.md pointer |

Concrete cuts (current → target):

- **CONTRIBUTING.md 597 → ~480-510 (-15-20%):** sqlite-schema restatement
  (22-34) → pointer; "test matrix" prose (199-229) → keep install table
  only, pointer to DESIGN; evergreen paragraph (252-279) → probing runbook
  only; LaunchAgent bootstrap (300-364) tightened to ~35 lines (plist +
  commands, cut prose); "refresh / token warning" (366-374) folded into
  "common expected failures"; global-settings rule (376-382) → 1 line +
  pointer; recipe-mode alias re-explanation (384-407) → examples + pointer
  to alias conventions; license-semantics table (424-436) trimmed to the
  fill-in guidance (the reciprocity rationale is DESIGN's).
- **DESIGN.md 507 → ~499:** trim "test matrix" (447-507) to the policy
  bullets (drop install/recipe mechanics); #13 retitled "top 100" with new
  path; add #14 (binary_names single origin).
- **README.md 124 → ~118:** per-exit-code table (67-73) → pointer to DESIGN.
- **zig.md:** update "patterns this repo uses" (main.dev → `src/dev/dev.zig`
  imported through the comptime gate; helpers moved); add the split-structure
  note.
- **powershell.md 149 → ~131 (-12%):** delete "Iterate the right directory"
  (duplicate of zig.md's `Dir.iterate()` note); slim the sqlite section to
  the shell-side invocation recipes and point at zig.md for backend
  semantics.
- **AGENTS.md:** restructure the skill bullets per the new reference
  pattern (below); update the zig bullet to name the four files
  (`src/lib/rules.zig`, `src/lib/core.zig`, `src/dev/dev.zig`,
  `src/main.zig`).
- **New: the skill-reference pattern** (user directive): when a referenced
  bevry-vibes skill applies with this project's tweaks, create a local
  `<name>.md` at the repo root that references the remote URL and lists the
  tweaks underneath; AGENTS.md references the local file. This process is
  documented in a new **`meta.md`** referenced by AGENTS.md. Applied to:
  - **`kilo.md`** (local): remote kilo.md URL + the plan-provenance tweak
    ("to be upstreamed"). The tweak **is** the accompanying-`.prompts.md`
    change: every plan gets a companion `<plan>.prompts.md` that carries
    all prompts verbatim, untruncated, timestamped, in order; the plan
    file itself only links to it and never inlines prompts (inlined
    prompts with plans confuse readers/agents).
  - **`commits.md`** (local): remote commits.md URL + the `zig build` /
    `agent-detect trailer co-author` tweaks.
  - Unmodified skills (minimax.md) keep their remote URL bullet; the
    not-applied policy.md rationale stays as an AGENTS.md bullet (a
    non-application decision, not a tweak).

## Second-pass findings (further pruning beyond the older plan)

A deeper scan of the post-strip-from-raw code found these additional items,
now folded into the task list:

- **`probeBinary` vs `harnessVersion`** (4489-4504, 4542-4575): two
  near-identical spawn loops over the same name list, but with different
  stop conditions — availability stops at the first exit-0 name, version
  cycles on until a token parses (4570-4572). Extract one
  `spawnVersion(io, name) ?[]const u8` (spawn `name --version`, pipe
  stdout, return the raw output on exit 0, null otherwise) plus two thin
  wrappers: `findBinary` = first name where `spawnVersion != null`
  (today's `probeBinary`), and `probeVersion` = first name where
  `spawnVersion != null` **and** `scanVersionToken` matches (today's
  `harnessVersion`). Only the spawn/read loop is shared.
- **Five identical child-output read loops** (2211, 3362, 4172, 4564,
  6094): extract one `readChildOutput(io, child, a, comptime stderr: bool) ![]u8`.
- **Three identical self-path blocks** (5131, 5955, 6077): extract
  `selfPath(io, buf: *[std.fs.max_path_bytes]u8) []const u8`.
- **Ten `bufPrint("{d}")` count emissions** (e.g. 5312-5318): extract
  `writeCount(io, n: anytype)` / `daemonWriteCount`.
- **Two JSON accessor families**: core `jstr`/`jint` (994, 1002) vs dev
  `sjstr`/`sjint`/`sjoptstr`/`sjoptint` (3709-3732) — 66 combined uses.
  `sjoptstr`/`sjoptint` are exact duplicates of `jstr`/`jint` → delete;
  `sjstr`/`sjint` (missing → `""`/`0`) become thin wrappers over them.
- **Stale/legacy wording** (post-strip-from-raw): the devUsage doc comment
  says "three refresh modes" — only two exist (2756); help text "resolve
  cooked from provided ids" (3104) → "resolve the declared identification
  from provided ids"; a duplicated `// refresh subcommands` banner
  (5069-5070 — splice artifact from the strip-from-raw edits) → one line;
  recipe-block comments "evergreen top-50" (4249, 4319, 4340, 4420, 4443) →
  top-100; user-facing doc comments that still say "cooked" (118, 581, 940,
  2524, 2556, 3232-3234, 3267) → "identify"/canonical-object wording.
  `buildCooked`/`buildRaw` internal names stay (strip-from-raw decision).
- **Docs with the same stale wording**: DESIGN.md "resolve cooked from
  provided ids" (494) and its "bulk additions, evergreen top 50" pointer
  (445); CONTRIBUTING.md's `proc_names` row (421); zig.md's "dev struct
  (`main.dev`)" note (89) → the new split paths.

Verified **not** orphaned (keep as-is): `license_none`/`license_noassertion`,
`buildTrailer`, `Reciprocity`, `canonicalFilterDim`, `kimiArgvOverride`,
`currentDir`, `reporterHome`, `redactHome`, `extractAfter`,
`stringListValue`, `titleCase`, every `EXIT_*`/`MSG_*` constant.

## Ordered task list

1. **Split (mechanical, single commit, build stays green):** create
   `src/lib/rules.zig` (data + pure lookups), `src/lib/core.zig` (ladder +
   policy), and `src/dev/dev.zig`; shrink `src/main.zig` to the entry +
   re-exports (`pub const dev = …` + aliases for the test-facing names);
   move `dev` content verbatim; fix the mis-indented functions; promote to
   `pub` only the names each importer needs (`envValueAllowed`,
   `optStringValue`, `addEvidenceClaim`, `modelRuleForName`-style lookups).
   Update the two test files' imports if `main.*` re-exports don't cover them.
2. **binary_names:** rename field, write the inline ternary value in each
   harness rule, delete `*_procs` + `probeNames` (all 177), add
   `harnessRuleForFixtureId`, rewire `detect()` ancestry,
   `probeBinary`/`harnessVersion`/`harnessAvailable`, and `assertNotInAgent`
   (rules-derived + `pending_binary_names`).
3. **Launch argv[0] substitution** in `runOneComboCapture` (cycle
   `binary_names` until spawn succeeds; no re-cycle after success).
4. **Small dedups + micro-abstractions** (second-pass findings; no behavior
   change):
   - id helpers: `splitAgentId`/`splitFixtureId` → one generic
     `splitId(a, id, comptime n)` with two thin typed wrappers kept —
     call sites distinguish `error.InvalidAgentId` vs
     `error.InvalidFixtureId` for their messages (5392-5393), so the
     per-arity error names must be preserved; the five
     `{s}~{s}`/`{s}#{s}`/`{s}-{s}` joiners → one `joinId(a, sep, parts)`
     with the null-when-any-dim-empty check kept in the two
     `?[]const u8`-returning wrappers (`agentIdFrom`/`fixtureIdFrom`
     semantics differ from `tupleKey`/`derived*`);
     `daemonWrite`/`daemonWriteErr` → one `daemonWriteTo`;
     `markCaptureOutcome(available, successful)` absorbing the ~6 repeated
     `upsertFixture` dances in `runOneComboCapture`/`runOneComboIdentity`;
     `providerForName` folds into `providerMetaForName().label`;
     `resolveRecipe`'s re-scan uses `modelRuleForName`.
   - probe/launch: extract `spawnVersion(io, name) ?[]const u8` (spawn
     `name --version`, pipe stdout, raw output on exit 0, null otherwise)
     plus the two thin wrappers `findBinary` (first exit-0 name —
     today's `probeBinary`) and `probeVersion` (first exit-0 **and**
     `scanVersionToken` match — today's `harnessVersion`); each keeps its
     stop condition, only the spawn/read loop is shared. Also extract
     `readChildOutput` (5 identical read loops; lives in `lib/core.zig`
     because `kiloSqliteJson` is a core consumer), `selfPath` (3 blocks),
     `writeCount`/`daemonWriteCount` (10 count emissions).
   - accessors: `sjoptstr`/`sjoptint` are exact duplicates of core
     `jstr`/`jint` — delete them; `sjstr`/`sjint` (missing → `""`/`0`)
     become thin wrappers over `jstr`/`jint`.
   - legacy wording sweep in code comments + help text: "three refresh
     modes" → two; "resolve cooked from provided ids" → "resolve the
     declared identification"; the duplicated `// refresh subcommands`
     banner (5069-5070) → one line; recipe comments "evergreen top-50" →
     top-100; reword output-facing "cooked" doc comments (`buildCooked`
     name stays).
5. **New test assertions** (`exit_statuses.test.zig` or `known_fixtures.test.zig`):
   every recipe's harness segment resolves to a rule; every rule's
   `binary_names` non-empty, all-lowercase, and (Windows) contains each bare
   stem + its `.exe`; the guard union covers every rule binary.
6. **docs → fixtures:** move/rename/expand to 100; `.gitignore` cleanup.
7. **Markdown synthesis** per decision 5 (CONTRIBUTING, DESIGN, README,
   zig.md, powershell.md, AGENTS.md, plus the new `meta.md` / local
   `kilo.md` / local `commits.md` per the skill-reference pattern; local
   `kilo.md` records the `.prompts.md` provenance rule).
8. **Validate** (below), then commit per AGENTS.md/commits.md (build first;
   trailer via `./zig-out/bin/agent-detect trailer co-author`, never cached).

Suggested commit grouping: (a) code = tasks 1-5; (b) docs = tasks 6-7 +
this plan file + its `.prompts.md` companion.

## Risks / watch-outs

- core ↔ dev must never import each other (only dev imports core; main
  imports both). `rules.zig` is data-only: it imports only `std`/`builtin`
  and must never import `core.zig` or `dev.zig` or the DAG cycles. The
  comptime gate (`if (build_options.dev)`) still drops dev code from
  released builds — verify released binary size/surface.
- The split is a large mechanical diff — land in one commit, relocate by
  symbol (the older plan's line numbers are pre-strip-from-raw and stale).
- `binary_names` order preserves probe first-hit (bare stems first).
- Tests run in ReleaseSmall — structural asserts only (no timing).
- Line-ending discipline (powershell.md): `Get-Content -Raw` + anchored
  splices + LF byte-write, never `Set-Content`; verify `git diff --stat`
  shows net deletion, no full-file churn.
- `detect()`'s ancestry scan has pre-existing "last match wins" overwrite
  semantics when two rules match the same ancestor — leave the behavior
  unchanged (note it in a comment when rewiring to `binary_names`).

## Validation

- `zig build`, `zig build dev`, `zig build test` green; `zig build dist`
  emits the six released binaries; released binary still rejects
  `fixtures`/`raw` and its size doesn't grow.
- Greps: no `probeNames`/`proc_names`/`*_procs`/`buildEnv`/`EnvSetup` remain;
  `git grep -n "top-50\|top 50" src/` → none (top-100 wording everywhere);
  `git grep -n "three refresh modes\|resolve cooked" src/ DESIGN.md` → none;
  `git grep -n "sjstr\|sjint"` → thin wrappers or none;
  `git grep -c "bufPrint(&n" src/` → 0 (writeCount used).
- Daemon: a small `--from-identity` batch on Windows confirms probe/launch
  cycling picks the working name (npm-shim `.cmd` wins where bare fails).
- Docs: `docs/` gone; `fixtures/evergreen-top100-models.txt` has 100
  entries; cross-references resolve.

## Deferred follow-ups (undecided — moved out of this sweep per user)

1. **`--free` (whole proposal deferred)** — was a scope flag with a
   `scope_free` queue marker column mirroring `scope_recipes` (ensureSchema
   DDL + idempotent column add, `queue_dedupe` index, `QueueRow`,
   upsert/jsonTo/pop/delete/validate/parse/usage) and a non-destructive
   migration (`PRAGMA table_info(queue)` → `ALTER TABLE` + index rebuild;
   the live DB holds 177 `fixtures` / 692 `queue` / 16 `invalid` rows, so
   no delete-and-recreate). Deferred because it would complicate this
   sweep; the zuckdb/tsv store rewrite (Out of scope) would port whatever
   lands.
2. **Free placement (undecided)** — verified fact: free-ness is a
   (provider, model-spec) property, **never harness** (every free signal
   lives in the provider/model string; the same provider+model has
   identical pricing across harnesses; DESIGN #13's sources are
   per-provider catalogs + OpenRouter pricing). Three placements compared
   and left undecided: per-recipe `free: bool` (denormalized, review-
   enforced consistency); a `freeModelSpecs` list + derivation (single
   source, but requires the launch spec to be data); a list + argv parsing
   (rejected pattern — string-sniffing).
3. **Launch/fixture spec refactor (undecided)** — Option A: keep inline
   launch argv. Option B: `LaunchSpec` union (`fixed` / `provider_model` /
   `model`) + one `launchArgvFor` builder + data-only rows (~-8 KB chars,
   +30-70 net lines). Cycling insight: everything derivable derives (argv,
   probe names, free-ness, ids); two irreducible data elements remain —
   the curated valid-combo set (177 of ~31,500) and the per-provider
   model-spec strings. cline's `--thinking high` is illustrative-only and
   will not persist.
4. **Capture cost tiers** (free for everyone / cheap / expensive / not
   paid for by the user) — the code markers and the CONTRIBUTING "capture
   cost tiers" section land with the deferred `--free` work.

## Out of scope

- Chutes/TEE `variations` — deferred sibling plan (`1786610549727-chutes-tee-variations.md`).
- Upstreaming the local `kilo.md` provenance tweak to bevry-vibes/skills.
- Linux/macOS fixture re-capture sweeps (need those hosts).
- **Dropping sqlite for zuckdb.zig + `.tsv` (or pure `.tsv` with Zig-native
  locking + atomic read/writes)** — user-declared follow-up after this
  sweep lands. zuckdb.zig = https://github.com/karlseguin/zuckdb.zig
  (DuckDB Zig binding); lock/atomic-write semantics and which backend wins
  get decided when writing that plan. The split positions it well: the
  sqlite layer is one bounded section of `src/dev/dev.zig`
  (`ensureSchema`/`sqliteRun`/`sqliteQuery`/`sj*` accessors), the exact
  seam the new backend replaces; any deferred `--free` schema work ports
  over with the rest.
- strip-from-raw's own out-of-scope leftovers: `runner` column cleanup,
  invalid-table remediation workflows, a queue-inspection subcommand, and
  semver-aware version comparison — separate follow-ups, not part of this
  sweep.
