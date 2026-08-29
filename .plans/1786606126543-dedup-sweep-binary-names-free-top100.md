# Dedup sweep: binary_names, file split, cost tiers, top-100 move

## Provenance

Per the kilo.md tweak recorded in AGENTS.md, this plan records its
provenance at the top of the file.

- Agent reference (generated fresh with `./zig-out/bin/agent-detect trailer assisted-by`,
  exactly as this plan proposes kilo.md mandates, never cached):

    > `Assisted-by: Kilo Code · Kimi K3 Tee <kilo-chutes-kimik3tee@local>`

    Note: the `Kimi K3 Tee` label in this very line is the bug the
    sibling plan `.kilo/plans/1786610549727-chutes-tee-variations.md`
    fixes — the trailer resolved a Chutes TEE-suffixed model id with no
    rule match and title-cased the slug instead of resolving the base
    `kimi-k3` rule. (It was this plan's Task 6 until followup 6 split it
    out.)

- Original prompt (verbatim):

    > There is still too much duplication/redundancy inside our \*.zig, and between our {AGENTS,CONTRIBUTING,zig,powershell}.md files.
    >
    > For instance, in oour zig files there is probeNames, proc_names, and \*\_procs variables. These are all the same thing.
    >
    > Scan the zig code for deduplication, and helpful abstractions, and in the plan propose the before and after and the pros and cons. There is no reason the zig file is so large.
    >
    > Our markdown files do not need to reiterate what is inside a referenced markdown file, they just need to specify the context of a reference, not the contents.
    >
    > During this sweep, we also want to consider where to place agent priorities, such as as which are free for everyone, which are cheap for the user, which are expensive for the user, and which are not paid for by the user; the free for everyone could be included in the zig code, and we can have a `--free` filter. However, the rest would be best for CONTRIBTUING.md.
    >
    > Secondly, the docs/top50\* file is best to go in fixtures/ as it is not documentation. It should also expand to the top 100.

- Followup prompts (verbatim, in order):
    1. > Use the `agent-detect trailer assisted-by` for the kilo.md plan providence agent reference. Update kilo.md to state this.
    2. > The TEE suffix should have been trimmed away, Chutes adds TEE suffixes its model labels to indicate they are running in an secure enclave, but they are the same model as without the TEE suffix. Make sure the code adds these aliases.
    3. > Call the single-origin binary_names instead, as probe_names uses one use case context name for all contexts.
    4. > The binary names list for each harness should include all of that harnesses binaries with extensions, as not all extensions apply for all harnesses, so we do not want a generic expander.
    5. > When we are launching and probing, we just cycle through each until one works. There is no need for more intelligence here, right?
    6. > I GIVE UP. SPLIT OUR chutes/tee tasks from .kilo\plans\1786606126543-dedup-sweep-binary-names-free-top100.md into its own plan - the plan that just does hardcoded variations. Will will do it after .kilo\plans\1786606126543-dedup-sweep-binary-names-free-top100.md lands. Commit the plans.

## Context

`src/main.zig` is 6596 lines / 372 KB. The same knowledge — "what are
this harness's binaries" — is hand-written in three places with three
different names and three subtly different contents:

| origin                                      | lines                                | content                                        | consumer                                           |
| ------------------------------------------- | ------------------------------------ | ---------------------------------------------- | -------------------------------------------------- |
| `HarnessRule.proc_names` + `*_procs` consts | 650, 679-684                         | ancestry exes, some rules empty (node-based)   | `detect()` ancestry scan (2892-2902)               |
| `RecipesForFixtures.probeNames`             | 4032, × ~177 recipe rows (4232-4480) | PATH-probe names incl. `.cmd`/`.ps1`           | `harnessVersion` (4546), `harnessAvailable` (5368) |
| `assertNotInAgent` inline `proc_names`      | 6232-6248                            | a third hand-written union (+ `claude` extras) | daemon user-only guard                             |

These drift independently: `kimi_procs` is `{"kimi.exe","kimi","kimi-code.exe","kimi-code"}`
while the kimi-code recipes carry
`{"kimi","kimi-code","kimi.exe","kimi-code.exe","kimi.cmd","kimi.ps1"}`
(different order, different entries); the guard includes the node-based
harnesses (`mmx`, `qwen`, `omp`, `crush`, `vibe`) whose rule
`proc_names` are empty — so the daemon guard matches ancestors that
`detect()` ancestry deliberately never matches.

Additionally:

- The daemon guard's env-marker list (6206-6219) is a hand-flattened
  copy of the rules' `env_markers` sets (a fourth copy; it omits
  `CLINE_WRAPPER_PATH`/`CLINE_BUILD_ENV`/etc. that the rules declare).
- The `*_env` consts (656-677) exist solely to be referenced once each
  by `rulesForHarnesses`; mixed styles (procs sometimes inline,
  sometimes const).
- Id joiners/splitters: `splitAgentId`/`splitFixtureId` are the same
  shape at two arities; `agentIdFrom`, `fixtureIdFrom`, `tupleKey`,
  `derivedAgentId`, `derivedFixtureId` are five near-identical
  `{s}~{s}`/`{s}#{s}` joiners.
- `providerForName` duplicates `providerMetaForName`'s loop (label
  accessor only); `resolveRecipe` re-implements the model-rule scan
  (2828-2833) after `canonicalIdFor` already resolved it.
- `daemonWrite`/`daemonWriteErr` (826-856) are the same body with a
  different fd; the `try upsertFixture(... available=N, successful=M)`
  block repeats ~6× in `runOneComboCapture` (6022-6152).
- TEE suffix: Chutes serves models as `<id>-tee` (trusted execution
  environment). `modelForName` has no match for `kimi-k3-tee`, hits the
  `kimi`-family fallback, and fabricates label `Kimi K3 Tee` — a silent
  false identity in trailers. Fixed by the sibling plan
  `.kilo/plans/1786610549727-chutes-tee-variations.md`, which lands
  after this plan.

## Decisions (locked with the user)

1. **One origin: `HarnessRule.binary_names`.** Per-harness explicit
   lists **with extensions** — no generic stem expander (not all
   extensions apply to all harnesses; user decision, prompt 4). Every
   consumer derives from the same list:
    - `detect()` ancestry match iterates `binary_names` (this _adds_
      ancestry matching for node-shim harnesses like omp — matching a
      literal `omp.exe` ancestor is semantically correct and unifies the
      guard/detect discrepancy; noted as intentional).
    - PATH probe cycles `binary_names` until one works (unchanged
      semantics — prompt 5 answer: cycle-until-works, no ranking).
    - Launch argv[0] substitutes the _first working_ probe name; after a
      successful spawn there is no re-cycle across binary variants on
      runtime failure (a failed real launch is an artifact failure, not
      a name miss; retrying burns tokens twice).
    - Daemon guard matches the union of all rules' `binary_names` plus a
      small explicit `pending_binary_names` list for not-yet-ruled
      harnesses (today: `claude`, `claude.exe`).
    - Daemon guard env markers iterate the rules' `env_markers`
      directly (flatten at comptime) instead of the hand-copied list.
2. **2-way file split** (user chose this over a layered 5-file split):
   `src/main.zig` keeps the released surface; the entire dev namespace
   moves to `src/fixtures.zig` behind the existing comptime gate
   (`pub const dev = if (build_options.dev) @import("fixtures.zig") else struct {};`
   — Zig prunes the untaken branch's analysis, so released builds never
   compile it). Tests keep working through `main.dev.*`.
3. **Cost tiers.** Four tiers, two enforcement points:
    - **free for everyone** → encoded in code: `.free = true` on the
      `RecipesForFixtures` rows whose capture costs nothing for anyone;
      new `--free` scope flag on `fixtures queue`/`dequeue`.
    - **cheap for the user / expensive for the user / not paid by the
      user** → prose only, a new "capture cost tiers" section in
      CONTRIBUTING.md (no new flags). DESIGN.md records only _that_ the
      tiers exist and where they're maintained (one sentence).
4. **DESIGN.md is the "what", CONTRIBUTING.md is the "how"** (user
   refinement): DESIGN.md gives the project overview and the important
   decisions — problem, architecture, exit registry, state store,
   matrix policy, evergreen decisions. CONTRIBUTING.md holds the
   operational runbooks — refresh, add-rule, release, installs, the
   cost-tier table — and should end up the smaller document. Anything
   in CONTRIBUTING.md that explains a _decision_ moves to DESIGN.md;
   anything DESIGN.md says about a _step_ stays in CONTRIBUTING.md as
   one line + pointer.
5. **TEE handling lives in the sibling plan** (user decision, prompt
   6): TEE-stamped Chutes model ids fold via hardcoded model-rule
   `variations` — the documented alias machinery — not the programmatic
   suffix stripper this plan originally proposed. See
   `.kilo/plans/1786610549727-chutes-tee-variations.md`; it lands after
   this plan.
6. **docs → fixtures for the evergreen list**, expanded to top 100,
   renamed `fixtures/evergreen-top100-models.txt`; `docs/` directory
   removed; markdown references collapse to pointers.

## Task list

Ordered; each task is independently landable, but T4's free-marker
sweep depends on T1's recipe-table move landing first, and T7 (docs)
references the final paths.

### T1 — `binary_names` single origin (+ probe/launch cycling)

**Before:** three hand-written lists (table above) + `Detect()` ladder
matches `proc_names` only.

**After:**

```zig
pub const HarnessRule = struct {
    name: []const u8,
    label: []const u8,
    short_title: ?[]const u8 = null,
    version: ?[]const u8 = null,
    license: ?[]const u8,
    license_sources: []const []const u8,
    env_markers: []const []const u8,
    /// every binary this harness can be installed as, with extensions —
    /// single origin for ancestry matching, PATH probing, launch argv0
    /// substitution, and the daemon's user-only guard. Extensions are
    /// explicit per harness (no stem expander): e.g. npm installs leave
    /// `.cmd`/`.ps1` shims, scoop/brew leave real `.exe`s, unix leaves
    /// bare names.
    binary_names: []const []const u8,
    variations: []const []const u8 = &.{},
};

const cline_binary_names = [_][]const u8{ "cline", "cline.exe", "cline.cmd", "cline.ps1" };
const goose_binary_names = [_][]const u8{ "goose", "goose.exe", "goosed", "goosed.exe" };
const kimi_binary_names  = [_][]const u8{ "kimi", "kimi-code", "kimi.exe", "kimi-code.exe", "kimi.cmd", "kimi.ps1" };
const mmx_binary_names   = [_][]const u8{ "mmx", "mmx.exe", "mmx.cmd", "mmx.ps1" };
const kilo_binary_names  = [_][]const u8{ "kilo", "kilo.exe", "kilo.cmd", "kilo.ps1" };
const qwen_binary_names  = [_][]const u8{ "qwen", "qwen.exe", "qwen.cmd", "qwen.ps1" };
const cursor_binary_names = [_][]const u8{ "cursor-agent", "cursor-agent.exe", "cursor-agent.cmd", "cursor-agent.ps1" };
// pi: { "pi", "pi.exe" } · omp/reasonix/crush/opencode/vibe/copilot: "<h>", "<h>.exe"
```

The per-harness const lists are formed by **unioning** the current
`proc_names` and `probeNames` sets (order: bare stems first, then
extensions — preserves today's probe-first-hit behavior, e.g. kimi
probes `kimi` before `kimi-code`).

Consumers:

- `detect()` ancestry scan (2892-2902): `for (r.binary_names)`.
- Delete `RecipesForFixtures.probeNames` and all ~177 per-row values.
  Add a lookup `harnessRuleForFixtureId(agent_id) ?HarnessRule` that
  slug-resolves the first `agent_id` segment through `canonicalIdFor`
  (rules' `name`/`label` normalize to the same slug, so `kimicode` →
  the `kimi-code` rule) — recipes with an unknown harness segment
  return null (callers treat as unavailable → `invalid`/skip paths
  already exist).
- `harnessVersion` + `harnessAvailable`: iterate the rule's
  `binary_names`. `probeBinary` returns `?[]const u8` (the working
  name) instead of `bool`; `harnessAvailable` adapts.
- Launch (in `runOneComboCapture`): keep each recipe's `launch` argv
  template; substitute argv[0] with argv0 candidates from `binary_names`
  in order until `std.process.spawn` succeeds (prompt-5 semantics:
  cycle until one works). Spawn failure after all candidates → the
  existing `available=1, successful=0` path. No re-cycle after a
  successful spawn.
- `assertNotInAgent`: env loop iterates `rulesForHarnesses`
  `env_markers` directly (nesting `while` over the rule list — same
  fail-closed semantics, one flattened source); proc loop iterates a
  const built from all rules' `binary_names` ++
  `const pending_binary_names = [_][]const u8{ "claude", "claude.exe" };`
  (pending harnesses deliberately not in rules yet).

**Pros:** one hand-maintained list per harness; probe/ancestry/guard
can never drift; ~180 field initializers deleted; recipes shrink to
`agent_id` (+ `launch`?); the ladder and the guard agree for the first
time. **Cons:** ancestry matching for `mmx`/`qwen`/`omp`/`crush`/`vibe`
newly fires when one of those exact exe names is an ancestor —
intentional unification, but it changes live-detection results on
machines where such a process exists (that process _is_ the harness, so
the change is a fix, not a regression); the `pending_binary_names`
extras list still needs a hand when new harnesses are pending.

Tests (`exit_statuses.test.zig` gains): every recipe's harness segment
resolves to a rule (totality of derivation); every rule's
`binary_names` are all-lowercase and non-empty; the guard union
contains every rule binary.

### T2 — 2-way split: `src/main.zig` + `src/fixtures.zig`

**Before:** one 6596-line file; the dev gate is an inline
`pub const dev = if (build_options.dev) struct { ... ~3200 lines ... } else struct {};`.

**After:**

- `src/fixtures.zig` — everything under the dev struct plus its
  dev-only top-level helpers: `fixturesUsage`/`queueDequeueFlags`/
  `queueUsage`/`dequeueUsage` texts, sqlite layer (`sqliteRun`,
  `ensureSchema`, `sqliteQuery`, `sqlQuote`/`sqlOptStr`/`sqlOptInt`,
  `sjstr`/`sjint`/`sjoptstr`/`sjoptint`, `jsonTo*`/`select*`/`insert*`/
  `delete*`), `RecipesForFixtures` + `recipesForFixtures` +
  `capture_prompt`, split/join/hash helpers (`splitAgentId`,
  `splitFixtureId`, `agentIdFrom`, `fixtureIdFrom`, `tupleKey`,
  `derivedAgentId`, `derivedFixtureId`, `generationHash`,
  `channelJson`), `probeBinary`, `scanVersionToken`, `harnessVersion`,
  merge/capture builders, queue/dequeue/daemon/capture runners,
  `assertNotInAgent`, `isEnvValueAllowed` (re-expose), kill/timeout
  workers. It imports `main.zig` for `Detection`, the rule tables,
  builders and resolvers (circular `@import` is legal in Zig; analysis
  is lazy). It imports `build_options` for `dev`/`version`.
- `src/main.zig` — exit registry + messages, `Detection` and the raw
  observation structs, rule tables + resolvers (`canonicalIdFor`,
  `slugId`, `titleCase`, `modelForName`, `providerMetaForName` —
  `providerForName` folded in, `harnessRuleForName`,
  `applyModel`/`setProvider`/`setAgentId`), ancestry/session helpers,
  the ladder + `detect*()` fns, reciprocity, report/trailer builders,
  usage texts, `resolveRecipe`, `main`/`mainInner`/`runAction`, and
  `pub const dev = if (build_options.dev) @import("fixtures.zig") else struct {};`
  (the gate keeps the type-level guarantee the released binary never
  links the fixtures surface — confirm with T7's size check).
- `build.zig` unchanged (same `src/main.zig` root everywhere).
- Test files unchanged at their call sites — `main.dev.recipesForFixtures`
  etc. still resolve through the re-exported namespace.

While moving, apply the small dedups (no behavior change):
`splitAgentId`/`splitFixtureId` → one `splitId(a, id, comptime n: usize)`;
the five `{s}~{s}`/`{s}#{s}`/`{s}-{s}` joiners → one
`joinId(a, sep: u8, parts: []const []const u8)`; `daemonWrite`/
`daemonWriteErr` → one `daemonWriteTo(io, file: std.Io.File, bytes)`,plus
a `markCaptureOutcome(available: u8, successful: u8)` helper absorbing
the ~6 repeated `upsertFixture` dances in `runOneComboCapture`/
`runOneComboIdentity`; `providerForName` deleted (use
`providerMetaForName().label`); the duplicated model-rule scan in
`resolveRecipe` uses one `modelRuleForName`.

**Pros:** navigable files; rule/recipe edits stop colliding with
detection logic in diffs; the dev surface has one import boundary;
future harness additions touch one data file region. **Cons:** one
large mechanical diff (must land in a single commit to stay
buildable); `pub` visibility churn on shared decls; circular import
between the two files is unavoidable (legal, but worth a comment).

### T3 — Markdown dedup: pointers, not paraphrases

Guiding rules (user): (1) a file that references another file records
the _context_ of the reference (why/when to consult it), never the
referenced contents; (2) **DESIGN.md is the "what"** — project overview
and the important decisions; **CONTRIBUTING.md is the "how"** —
operational runbooks, kept smaller than DESIGN.md.

- **DESIGN.md = what (overview + decisions).** Keeps the
  evergreen-top-N policy and the license/`NONE` semantics rationale;
  decision #13 retitled to "top 100" and its path line points to
  `fixtures/evergreen-top100-models.txt`. Gains two one-paragraph
  evergreen decisions: #14 (binary names have one origin —
  `HarnessRule.binary_names`; launch/probe/guard cycle it until one
  works) and #15 (cost tiers: what the four tiers are, that
  free-for-everyone is enforced in code via recipes' `.free` + `--free`,
  and that per-combo tier assignments are maintainer-maintained in
  CONTRIBUTING.md).
- **CONTRIBUTING.md = how (runbooks, smaller than DESIGN).** Specific
  edits:
    - "add a new harness rule" table: `proc_names` row → `binary_names`
      row (one-origin description).
    - Scope-flags list: add `--free` line.
    - The evergreen paragraph (253-279) collapses to ~3 lines: the gate
      is policy in DESIGN.md; the tracked set is
      `fixtures/evergreen-top100-models.txt` (+ how to expand it).
    - "recipe-mode identify / trailer" loses its inline alias-resolution
      re-explanation — keep the usage examples and one line pointing at
      "alias conventions" below it (which stays as the single home).
    - "refresh / token warning" (366-374) folds into "common expected
      failures when refreshing" (two sentences + pointer) — both
      sections restate the same from-identity/from-capture split.
    - "global-settings rule" section: keep one line + pointer to
      DESIGN.md "test matrix" (the policy home).
    - New section "capture cost tiers": a maintainer-owned table mapping
      provider/combo → tier — **free for everyone** (code-enforced:
      recipes' `.free`, selected with `--free`), **cheap for the user**
      (maintainer funds at low cost; e.g. DeepSeek paid API secondary
      tier), **expensive for the user** (maintainer funds the MiniMax
      subscription default only, per DESIGN.md "Paid default"), **not
      paid by the user** (contributor scope — captured on contributors'
      machines; ties to the pending-harness list + "catalog-inference
      verdicts"). Rows seeded from DESIGN.md's existing statements;
      maintainer adjusts freely — the plan does not adjudicate wallets.
- **powershell.md = shell-side gotchas only.** Delete "Iterate the
  right directory" (verbatim dup of zig.md's `Dir.iterate()` note);
  slim "sqlite3 CLI verification patterns" to the PowerShell-side
  invocation recipes (`-json -batch`, connection-local `SELECT
changes()` in one invocation, the three spot-check commands) and
  point at zig.md for the backend semantics (`ensureSchema`/
  `sqliteRun`/`sqliteQuery`).
- **zig.md = Zig/stdlib/backend notes.** Gains the split structure note
  (`dev` namespace now in `src/fixtures.zig`, imported via the comptime
  gate from `src/main.zig`); its "patterns this repo uses" list updates
  (moved helpers named once).
- **AGENTS.md.** (a) kilo.md tweak paragraph updated to: plans record
  their provenance at the top — the original prompt + every followup
  prompt verbatim — and the agent reference is generated fresh with
  `./zig-out/bin/agent-detect trailer assisted-by` (regenerated per
  plan; never cached, never hand-written). Upstreaming this wording to
  `kilo.md` proper stays a follow-up (the bevry-vibes/skills repo is
  not checked out on this machine); AGENTS.md remains the local record,
  per precedent (same pattern the strip-raw plan used for kilo.md
  amendments). (b) The zig section line naming the split
  (`src/main.zig` + `src/fixtures.zig`).

### T4 — `--free` filter (dev binary)

- `RecipesForFixtures` gains `free: bool = false`; doc comment:
  "capture and identity generation cost nothing for anyone — free for
  everyone (see CONTRIBUTING.md 'capture cost tiers'). When unsure,
  leave `false`."
- Marker sweep: annotate recipes whose capture is genuinely free for
  anyone, verified per the source-of-truth order already pinned in
  DESIGN.md #13 (harness catalog cost field → OpenRouter
  `/api/v1/models` `:free`/`pricing` → artificialanalysis.ai). Expected
  hits: openrouter `:free` routes, the opencode-router
  `deepseekv4flashfree` recipe, kilo's free-tier `~*-latest` router
  recipes, groq free-tier recipes, cerebras/z.ai free-trial recipes,
  DeepSeek free-tier recipes. Doubt → `false`.
- CLI: `--free` joins the scope-flag family (`queueDequeueFlags`,
  `FilterOptions`, `parseFilters`, `scopeCount`, `scopeCandidates` —
  enumerates free recipes on the host platform; composes (AND) with dim
  filters and mode flags like the other scopes; there is no `--no-*`
  spelling per DESIGN.md #5).
- Store: `queue` gains a `scope_free` marker column threaded exactly
  like `scope_recipes` (ensureSchema DDL +
  idempotent `ALTER TABLE`-style add per the existing column-add
  pattern, `QueueRow`, `upsertQueueRow`, `jsonToQueueRow`,
  `deleteQueueRows` condition, `describeQueueRow`, dequeue marker
  match). The daemon needs no new logic — queued rows are rows
  (the freshness conjunction ignores this marker, as it does
  `scope_recipes`).
- `fixtures help`/queue help gain the line; exit-status coverage reuses
  the scope-conflict rules (3) and no-filter rule (4).

**Alternative considered and rejected:** a provider- or model-level
`free` field — cost is pairwise (DeepSeek is simultaneously free-tier
and paid; OpenRouter mixes `:free` with priced ids), so the per-recipe
marker is the only honest granularity. **Pros:** `--free` lets any
contributor sweep zero-cost captures without knowing the wallet map.
**Cons:** one more queue marker column → committed-DB migration (same
pattern as previous scope columns), and the marker must be re-audited
when providers change pricing.

### T5 — docs→fixtures move + top 100

- `git mv docs/evergreen-top50-models.txt fixtures/evergreen-top100-models.txt`;
  remove the empty `docs/` directory.
- `.gitignore`: delete the three exception lines
  (`!docs/`, `docs/*`, `!docs/evergreen-top50-models.txt`) and retarget
  the comment — `fixtures/` already tracks everything except the
  gitignored daemon/DB-journal files.
- Expand the set from top-50 → top-100: same format (`family` +
  canonical variant per line, coalesced name variations), same sources
  pinned in DESIGN.md #13 (artificialanalysis.ai, arena.ai/LMArena,
  llm-stats.com, HF trending, OpenRouter top-weekly — curated from
  accessible signals since the boards are JS-rendered; intersect with
  the harness catalogs already used for batch additions). Append the
  new rank band below the existing entries; keep every existing row.
  Header contract line updated to "top 100".
- Prose touchpoints: DESIGN.md #13 title/wording (top 100),
  CONTRIBUTING.md paragraph (new path + pointer form), the recipe-block
  comments in `src/fixtures.zig` that say "evergreen top-50" (mechanical
  comment rewording, no rule changes).

### T6 — TEE suffix canonicalization — moved

Superseded (user decision, prompt 6): the programmatic suffix
stripper proposed here is rejected in favor of hardcoded model-rule
`variations` (the documented alias machinery). The whole task —
chutes provider rule, `kimi-k3` TEE variations, live-detection fold,
tests, docs — now lives in
`.kilo/plans/1786610549727-chutes-tee-variations.md`, which lands
after this plan.

### T7 — Sweep verification

- `zig build` (released) and `zig build dev` both green; confirm the
  released binary did not grow the fixtures surface
  (`./zig-out/bin/agent-detect.exe fixtures` → unrecognized-arg usage;
  compare binary size vs. pre-split).
- `zig build test` green (both test files + the new assertions).
- `./zig-out/bin/agent-detect-dev fixtures queue --free --from-identity`
  enqueues only `.free` recipes (spot-check with sqlite3:
  `SELECT * FROM queue WHERE scope_free IS NOT NULL;`), and
  `fixtures dequeue --free` deletes them.
- `./zig-out/bin/agent-detect identify --harness=kilo --provider=chutes --model=Kimi-K3-TEE`
  TEE verification: sibling plan's task (this plan leaves TEE/chutes
  untouched).
- Daemon behavior unchanged: run a small `--from-identity` batch on
  Windows and confirm probe/launch cycling picks the working binary
  name (for npm-shim installs: the `.cmd` name wins where the bare name
  fails).
- `git diff --stat` sanity: no line-ending full-file rewrites
  (powershell.md's LF discipline for any scripted edits).

## Out of scope

- Layered 5-file split (rejected by user; 2-way chosen).
- Chutes provider rule + TEE-id variations: the sibling plan
  `.kilo/plans/1786610549727-chutes-tee-variations.md`.
- Other latent rule gaps found by the totality test (fix forward
  separately).
- Per-provider/model cost tiers encoded in code (only free-for-everyone
  is code; the rest is CONTRIBUTING.md prose per decision 3).
- Upstreaming the kilo.md tweak to bevry-vibes/skills (no checkout on
  this machine; AGENTS.md is the local record).
- Reflowing recipe rows to multiple-per-line (one row per line keeps
  git blame useful).
