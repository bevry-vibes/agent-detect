# rename org/project + is-reciprocal + trailer subtypes + help rework + exit registry + AGENTS.md conformance

## context

Project renamed `agent-detection` → `agent-detect`; org `bevry-labs` → `bevry-vibes`. Remote already `git@github.com:bevry-vibes/agent-detect.git`. `bevry-vibes/skills` (`ai-policy.md`, `commits.md`, `minimax.md`) delegate to this project's README for how to satisfy them. Work:

1. Sweep stale `bevry-labs` / `agent-detection` references.
2. New `is-reciprocal` action (AI-policy reciprocity check, tri-state + detection failures).
3. `trailer` subtypes: `trailer co-author` + `trailer assisted-by`; bare `trailer` errors.
4. Reimagine `--help`/`help`/`-h` formatting + handling.
5. Exit status registry (project-specific, each distinct kind its own number).
6. README minimal examples for the three skill docs.
7. AGENTS.md conformance to bevry-vibes/skills.

## exit status registry (final, user-approved)

| code | name | meaning |
| ---- | ---- | ------- |
| 0 | success | action completed; also explicitly-requested help/version |
| 1 | unrecognised error | unexpected/unclassified (uncaught zig error, bug) |
| 2 | unrecognised argument | unknown action / flag / subcommand |
| 3 | conflicting argument | recognised but incompatible combination |
| 4 | missing required arguments | required arg(s) absent |
| 5 | incompatible environment refusing run | env present but incompatible → tool refuses |
| 6 | incomplete environment preventing run | env missing required dependency → can't run |
| 7 | missing specified agent | user-named combo not in rule tables |
| 8 | unable to detect unspecified agent | live detection identity unresolvable |
| 9 | agent data incomplete to make a determination | identity resolved, policy data missing |
| 10 | agent data complete and requirement failed | determination definitive + negative (e.g. not reciprocal) |
| 11 | out of memory | allocation failed (released + dev) |
| 12 | sqlite query error | sqlite3 ran but failed; bad SQL / corrupt store (dev) |
| 13 | filesystem I/O error | read/write/dir op failed (dev capture/daemon) |

**The full table + explanations above are the canonical registry and live in DESIGN.md (a dedicated "exit status registry" section). The CLI `--help` text only states that the full table is in DESIGN.md (plus brief per-action exit codes in context). README.md mentions exit codes contextually per example only.**

Examples per group:

- **0** — `cooked` (identified) → JSON; `trailer co-author` → `Co-authored-by: ...`; `trailer assisted-by` → `Assisted-by: ...`; `is-reciprocal` → `is reciprocal`; `version` → `agent-detect 2026.8.6-1`; `help`/`--help`/`-h`/no args/`trailer help`/`help trailer` → usage.
- **1** — uncaught error → `error: <name>` + trace.
- **2** — `agent-detect foobar` → `unrecognised argument: 'foobar'` + usage; `--bogus`; dev `fixtures frobnicate`.
- **3** — `agent-detect cooked trailer` → `conflicting argument` + usage; dev `fixtures queue --all --stale`.
- **4** — `cooked --harness=cline` (partial combo); bare `agent-detect trailer`; dev `fixtures queue` without filter.
- **5** — dev `fixtures daemon` inside an agent → `incompatible environment refusing run`.
- **6** — dev `fixtures *` with no `sqlite3` on PATH → `incomplete environment preventing run`.
- **7** — `cooked/trailer co-author/is-reciprocal --harness=foo --provider=bar --model=baz` → `missing specified agent (harness, provider, model)`.
- **8** — `cooked`/`trailer co-author`/`is-reciprocal` when live detection resolves nothing (plain shell); dev `fixtures capture` partial → `unable to detect unspecified agent (harness, provider, model)`.
- **9** — `is-reciprocal` with identity resolved but `harness_license`/`model_reciprocity`/`provider_closed_training` null (e.g. crush/hyper/qwen3.7-plus) → `agent (harness, provider, model) data incomplete to make a determination`.
- **10** — `is-reciprocal` for kilo/anthropic/claude-sonnet-4 (closed model) → stderr `agent (harness, provider, model) data complete and requirement failed`, stdout `not reciprocal`.
- **11** — allocation failure anywhere (`try a.dupe`/`allocPrint` etc.) → `error.OutOfMemory`.
- **12** — dev `fixtures *` where sqlite3 runs but query fails (corrupt `fixtures/index.sqlite3`, bad SQL) → `error.SqliteError`. Released `kiloSqliteJson` catches its own, so hard sqlite errors are dev-only.
- **13** — dev capture/daemon `createDirPath`/`openDir`/`writeFile`/log-`createFile` failures → filesystem I/O error.

`is-reciprocal` ladder: 7 (can't detect, recipe) / 8 (can't detect, live) → 9 (can't determine) → 10 (failed) → 0 (passed).

## decisions (confirmed with user)

- **Bare `agent-detect trailer`** → error + trailer usage dumped, exit **4** (missing required arguments). No alias.
- **Error messages = exit-status registry names** (with `(harness, provider, model)` where the name references agent dims), per the "exact message verbage" section — **no repo clause, no prose** in the error output. Repo-update rules live in README.md per use case (exit 8 → "agent-detect must be updated to detect your agent (harness, provider, model)"; exit 9 → "agent-detect must be updated for the reciprocity of your agent (harness, provider, model)").
- **Skills policy link filename** = `ai-policy.md` (user confirmed `policy.md` was typo).
- **Help**: explicit help/version request → exit **0** (success). Help dumped because of bad args → the failure code (2/3/4). `trailer help` / `help trailer` → trailer usage, exit 0.
- **Conflicting arguments** → own group, exit **3** (injected between 2 and 4). Must fix current bug where `registerAction` conflict propagates an uncaught error (today exits 1).
- **AGENTS.md**: references the three skills by URL only (no pulling). `ai-policy.md` **ignored for this project** — agent-detect is the enforcement mechanism ai-policy.md delegates to, so it must run on all agents, including ones violating that policy. `commits.md` **applies**, with this project's existing tweaks (build binary, `trailer co-author`, never guess/cache). `minimax.md` **applies** (user chose B).
- **Exit codes as named constants** in one place so numbers are easy to tweak. `1` is **not** a fallback for everything — only genuinely unexpected/unclassified errors (1 = unrecognised error). Known error kinds each get their own status (2–13).
- **Registry location**: full canonical exit-status table + explanations live **only in DESIGN.md** (a dedicated section). The `--help` usage text points at DESIGN.md and carries only brief per-action exit codes in context — no registry dump in help. README.md mentions exit codes contextually within each example only (e.g. under is-reciprocal/trailer).
- **Fixtures `process_lineage`** name strings mechanically updated (`agent-detection-dev`→`agent-detect-dev`, `agent-detection`→`agent-detect`).
- `.kilo/plans/*` = historical, leave unchanged.

## exact message verbage (user-approved scheme)

Error messages = the exit-status registry names, with a `(harness, provider, model)` parenthetical inserted after `agent` where the name references the agent dims. **STDERR carries the full registry-name message; STDOUT carries the concise verdict.** No repo clause, no prose — the repo-update rules live in README.md per use case.

| exit | STDERR (full) | STDOUT (concise) |
| ---- | ------------- | ---------------- |
| 0 | — (success) | `is reciprocal` |
| 2 | `unrecognised argument: '<x>'` | usage text |
| 3 | `conflicting argument` | usage text |
| 4 | `missing required arguments: --harness= --provider= --model=` (partial combo) · `missing required arguments: trailer subtype (co-author \| assisted-by)` (bare trailer) · `missing required arguments` (fixtures no-filter) | usage text |
| 5 | `incompatible environment refusing run` | — |
| 6 | `incomplete environment preventing run` | — |
| 7 | `missing specified agent (harness, provider, model)` | — (pure error) |
| 8 | `unable to detect unspecified agent (harness, provider, model)` | — (no stdout: detection failed, no sensible data) |
| 9 | `agent (harness, provider, model) data incomplete to make a determination` | cooked/raw: partial report · is-reciprocal: — |
| 10 | `agent (harness, provider, model) data complete and requirement failed` | `not reciprocal` |
| 11 | `out of memory` | — |
| 12 | `sqlite query error` | — |
| 13 | `filesystem I/O error` | — |

Placement: `is-reciprocal` STDOUT carries the **determination** only — `is reciprocal` (0) and `not reciprocal` (10). `not reciprocal` is a negative determination (advisory to the caller to not continue), NOT an exception. `is-reciprocal` exits 7/8/9 are stderr-only, **no stdout**.

`cooked`/`raw` are **data-output** actions. Exit 8 (identity unresolved): **no stdout** — detection failed, there is no sensible data; stderr explainer + exit 8 only. Exit 9 (identity complete, reciprocity/policy data incomplete): **data exists** → partial report to stdout + stderr explainer + exit 9. Exit 0: full report to stdout. Usage errors (2/3/4) also dump the relevant usage text.

`trailer` writes to STDOUT **only on success** (the trailer line). Exits 4/7/8 are stderr-only — there is no partial case for `trailer`.

Trailer lines (stdout): `Co-authored-by: {harness_label} · {model_label} <{agent_id}@local>` and `Assisted-by: {harness_label} · {model_label} <{agent_id}@local>`.

## tasks

### 1. renames
- `build.zig.zon`: `.name = .agent_detection` → `.agent_detect`.
- `README.md`: all `bevry-labs` → `bevry-vibes`; skills links `policy.md` → `ai-policy.md`; **remove the standalone `Exit codes: 0 = identified; 2 = unable to identify` note (line 69)** — exit codes appear only contextually per example (task 6).
- `AGENTS.md`: rewrite per decisions (task 7).
- `DESIGN.md`: `bevry-labs` → `bevry-vibes`; `policy.md` → `ai-policy.md`; update CLI-surface mentions (add `is-reciprocal`, trailer subtypes; lines ~30, ~209, two-binary-split narrative); **add the full canonical "exit status registry" section (0–13 table + per-code examples, per the registry above)**. Renumber stale exit-2 references: line 122 (`partial detection exits 2`), 156 (`unknown id exits 2`), 169 (`binary exits 2`), 181 (evergreen `Partial detection exits 2`).
- `CONTRIBUTING.md`: recipe-mode example `trailer` → `trailer co-author` (line ~114); renumber stale exit-2 references (lines 42 `partial detection exits 2`, 119 `rule tables exits 2`).
- `fixtures/*.json` (13 files): `agent-detection-dev` → `agent-detect-dev`, `agent-detection` → `agent-detect` in `raw.process_lineage` name strings only.
- Skip `.kilo/plans/*`, untracked `zig-out/`, `bin/`.

### 2. exit registry + message updates (`src/main.zig`)
- Add named constants: `EXIT_OK=0`, `EXIT_UNRECOGNISED_ERROR=1`, `EXIT_UNRECOGNISED_ARG=2`, `EXIT_CONFLICTING_ARG=3`, `EXIT_MISSING_ARG=4`, `EXIT_ENV_INCOMPATIBLE=5`, `EXIT_ENV_INCOMPLETE=6`, `EXIT_MISSING_SPECIFIED_AGENT=7`, `EXIT_UNABLE_TO_DETECT=8`, `EXIT_AGENT_DATA_INCOMPLETE=9`, `EXIT_REQUIREMENT_FAILED=10`, `EXIT_OUT_OF_MEMORY=11`, `EXIT_SQLITE_QUERY=12`, `EXIT_IO=13`.
- All current exit-2 failure paths renumber: unknown arg → 2; conflicting → 3; partial combo/bare trailer/fixtures-no-filter → 4; unknown combo → 7; unable-to-identify → 8.
- `cooked`/`raw` (data-output actions): exit 0 → full report to stdout. Exit 9 (identity complete, `reciprocityOf` `.unknown` — policy field null) → partial report to stdout + stderr `agent (harness, provider, model) data incomplete to make a determination`. Exit 8 (identity incomplete) → **no stdout** (no sensible data) + stderr `unable to detect unspecified agent (harness, provider, model)`. No repo clause — the repo-update rule lives in README.
- `trailer` on failure writes only to stderr (exit 8 identity incomplete, exit 7 unknown combo) — no stdout on failure.
- `registerAction`: return exit 3 (conflicting argument) explicitly instead of propagating `error.ConflictingAction`.
- Catch formerly-uncaught paths and map them (no more accidental exit 1): args-iterator init failures + `error.OutOfMemory` → 11; dev sqlite spawn failure → 6; dev `SqliteError` → 12; dev filesystem I/O failures → 13. Truly unexpected/unclassified stays 1.

**Dev (`fixtures`/`raw`) mapping** (verified against current `agent-detect-dev` — many paths currently leak uncaught errors → exit 1, must be caught):

| condition | current | new |
| --- | --- | --- |
| `fixtures` / `fixtures --help` / `-h` / `help` (usage shown) | 0 | 0 |
| unknown subcommand (`fixtures frobnicate`) | 2 | 2 |
| malformed `--fixture=`/`--agent=` id, bad `--stale-by-*` value | 2 | 2 (invalid arg value) |
| conflicting filters (`fixtures queue --all --stale`) | 2 | 3 |
| `validateQueueRow` error `InvalidQueueRow` (scope_count>1, days+minutes, available w/o scope) | 1 (uncaught) | 3 |
| `fixtures queue`/`dequeue` with no filter/scope | 2 | 4 |
| `fixtures daemon` inside an agent (`error.RunningInAgent`) | 1 (uncaught) | 5 |
| `sqlite3` binary missing (`error.SqliteSpawnFailed`) | 1 (uncaught) | 6 |
| `SqliteError` (sqlite ran but query failed — bad SQL / corrupt DB) | 1 (uncaught) | 12 |
| `fixtures daemon --write-log` log-open failure; capture cannot create/open `fixtures/` dir; ensureSchema `createDirPath` failure | 2 (or 1) | 13 |
| args-iterator init failure + `FilterError.OutOfMemory` + any `error.OutOfMemory` | 1/2 | 11 |
| `fixtures capture` partial (1–2 dims) / zero dims / agent_id uncomputed | 2 | 8 |
| `raw` (always emits raw block) | 0 | 0 |
| success (`fixtures queue --all`, `dequeue --all`, capture full) | 0 | 0 |

### 3. reciprocity tri-state + `is-reciprocal` (`src/main.zig`)
- `const Reciprocity = enum { reciprocal, not_reciprocal, unknown };` + `pub fn reciprocityOf(d) Reciprocity`:
  - `unknown` when any of `harness_license` / `model_reciprocity` / `provider_closed_training` is null;
  - else `reciprocal` iff current conjunction passes, else `not_reciprocal`.
- `computeReciprocal` delegates: `return reciprocityOf(d) == .reciprocal;` (cooked JSON output unchanged).
- `is-reciprocal` action (released + dev, recipe mode supported):
  - recipe: `resolveRecipe` null → exit-7 stderr message, exit 7.
  - live: `detect` not fully identified → exit-8 stderr message, exit 8.
  - else `reciprocityOf`: reciprocal → stdout `is reciprocal`, exit 0; not_reciprocal → stdout `not reciprocal` + stderr exit-10 message, exit 10; unknown → exit-9 stderr message, exit 9.
- STDOUT carries the determination only (0 `is reciprocal`, 10 `not reciprocal`). Errors 7/8/9 are stderr-only — no stdout output. Exit codes from the named constants.

### 4. trailer subtypes (`src/main.zig`)
- `fn buildTrailerLine(a, d, keyword) ?[]u8` → `"{keyword}: {harness_label} · {model_label} <{agent_id}@local>"` when all three non-null. `detect` and `resolveRecipe` build `d.trailer` with keyword `"Co-authored-by"` via it (output unchanged).
- Dispatch: `trailer co-author` → `d.trailer`; `trailer assisted-by` → `buildTrailerLine(..., "Assisted-by")`. Both: print + newline, exit 0; identity incomplete → exit-8 message (stderr), exit 8; unknown combo → exit-7 message, exit 7.
- Bare `trailer` → `missing required arguments: trailer subtype (co-author | assisted-by)` + trailer usage, exit 4.
- Parser rework: accept subtype word after `trailer` (`co-author`|`assisted-by`|`help`|`--help`|`-h`); second bare word after any other action → exit 3. Preserve `--harness=/--provider=/--model=` combo for `cooked`/`trailer *`/`is-reciprocal`.

### 5. help rework (`src/main.zig`)
- Rewrite `usage` (draft):

```
agent-detect — infer the harness, provider, and model of the current agent session

usage:
  agent-detect <action> [options]

actions:
  cooked         print the detection report as JSON (harness, provider, model, policy)
  trailer        print a commit trailer — requires a subtype (see `trailer help`)
                   co-author     Co-authored-by: (Bevry commits.md)
                   assisted-by   Assisted-by:   (e.g. GCC AI policy)
  is-reciprocal  check reciprocity compliance with Bevry's AI policy
  help           this help (also --help, -h, or no arguments)
  version        print the version (also --version, -V)

options:
  --harness=H --provider=P --model=M
                 resolve the action from the rule tables instead of live
                 detection (all three together, or none)

examples:
  agent-detect cooked
  agent-detect trailer co-author
  agent-detect trailer assisted-by
  agent-detect is-reciprocal
  agent-detect cooked --harness=kilo --provider=deepseek --model=deepseek-v4-flash

exit codes:
  is-reciprocal: 0 is reciprocal · 10 not reciprocal · 9 undeterminable ·
  8 undetectable · 7 unknown combo; others: 0 ok · 2 unrecognised argument ·
  3 conflicting argument · 4 missing required arguments · 8 undetectable.
  Full registry: DESIGN.md "exit status registry".
```

- Add `trailerUsage` (draft):

```
agent-detect trailer — print a commit trailer for the detected agent

usage:
  agent-detect trailer <type> [--harness=H --provider=P --model=M]

types:
  co-author      print the Co-authored-by: trailer (Bevry's commits.md)
  assisted-by    print the Assisted-by: trailer (e.g. GCC AI policy)

examples:
  git commit --trailer "$(agent-detect trailer co-author)"
  git commit --trailer "$(agent-detect trailer assisted-by)"
```

- Handling:
  - **help/version win over everything**: `help`/`--help`/`-h` anywhere at top level → top usage, exit 0 (NOT a conflict). After `trailer`, they → trailer usage, exit 0. `version`/`--version`/`-V` anywhere → version, exit 0.
  - `help trailer` → trailer usage, exit 0; `help <other-known-action>` → top usage, exit 0; `help <unknown>` → `unrecognised argument: '<x>'` + usage, exit 2.
  - no args → top usage, exit 0.
  - unknown action word → `unrecognised argument: '<x>'` + usage, exit 2; genuine conflict (`cooked trailer`, no help flag) → `conflicting argument`, exit 3.
- Light reformat `fixturesUsage` for legibility (optional).

### 6. README — use cases with rules
Keep install/download/links (org → `bevry-vibes`). README organizes by **use case**, each with the command(s) and the **rules** for that use case — including the repo-update rules tied to exit codes. No full exit-status registry; referenced via DESIGN.md link only. Sections:
- **Identify yourself / model** (`minimax.md`): `./agent-detect cooked` + small sample JSON (`model_name`/`model_label`); note exit 9 still prints the partial report to stdout, exit 8 prints nothing (stderr only). Rules: exit 8 → agent-detect must be updated to detect your agent (harness, provider, model); exit 9 → agent-detect must be updated for the reciprocity of your agent (harness, provider, model).
- **Reciprocity compliance** (`ai-policy.md`): `./agent-detect is-reciprocal` + rules per exit: 0 `is reciprocal` → proceed; 10 `not reciprocal` → not permitted; 9 `agent (harness, provider, model) data incomplete to make a determination` → agent-detect must be updated for the reciprocity of your agent; 8 `unable to detect unspecified agent (harness, provider, model)` → agent-detect must be updated to detect your agent; 7 `missing specified agent (harness, provider, model)` → combo is not a known recipe.
- **Co-author trailer** (`commits.md`): `./agent-detect trailer co-author` + `git commit --trailer "$(./agent-detect trailer co-author)"`; example line; rules: never guess/cache the identity, fresh per commit; exit 8 → agent-detect must be updated to detect your agent.
- **Assisted-by trailer** (GCC policy): `./agent-detect trailer assisted-by`, same `git commit --trailer` pattern; note target <https://gcc.gnu.org/ai-policy.html>.
- Keep zero-dependency + contributing sections; full exit-status registry referenced (not pasted) via DESIGN.md link.

### 7. AGENTS.md conformance
Rewrite as pointer (URL-only, no pulling). Mention all three skills, noting tweaks. Draft:

```md
# AGENTS.md

This project conforms to Bevry's skills. Reference their remote URLs only —
do not pull their contents into this file.

- https://github.com/bevry-vibes/skills/blob/main/ai-policy.md — **not
  applied to this project.** agent-detect is the enforcement mechanism that
  ai-policy.md delegates to, so this project must run on all agents,
  including those that violate that policy; it cannot apply the policy to
  itself.
- https://github.com/bevry-vibes/skills/blob/main/commits.md — **applies**,
  with this project's tweaks: build via `zig build`, generate the co-author
  trailer with `./zig-out/bin/agent-detect trailer co-author`, attach it with
  `git commit --trailer "$(./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather than
  commit without it.
- https://github.com/bevry-vibes/skills/blob/main/minimax.md — **applies**
  when the running agent is a MiniMax M3 model (its rules gate themselves on
  model and harness).

This file is not policy — it is a pointer.
```

## validation

1. `zig build`, `zig build dev`, `zig build test` all pass (fixture tests unaffected).
2. Manual smoke (native binary) with expected exits + messages:
   - `--help`/`-h`/`help`/no args → usage, 0; `help trailer`/`trailer help` → trailer usage, 0; `version` → 0.
   - `foobar` → `unrecognised argument: 'foobar'`, 2; `cooked trailer` → `conflicting argument`, 3; `trailer` (bare) → `missing required arguments: trailer subtype (co-author | assisted-by)`, 4; `cooked --harness=cline` → `missing required arguments: --harness= --provider= --model=`, 4.
   - `cooked --harness=foo --provider=bar --model=baz` → `missing specified agent (harness, provider, model)`, 7.
   - `cooked`/`trailer co-author` in plain shell → stderr `unable to detect unspecified agent (harness, provider, model)`, **no stdout**, 8.
   - `cooked --harness=crush --provider=hyper --model=qwen3.7-plus` → stdout partial JSON + stderr `agent (harness, provider, model) data incomplete to make a determination`, 9.
   - `trailer co-author --harness=cline --provider=clinepass --model=kimik3` → `Co-authored-by: Cline · Kimi K3 <cline-clinepass-kimik3@local>`, 0.
   - `trailer assisted-by --harness=cline --provider=clinepass --model=kimik3` → `Assisted-by: Cline · Kimi K3 <cline-clinepass-kimik3@local>`, 0.
   - `is-reciprocal` live (kilo session) → stdout `is reciprocal`, 0.
   - `is-reciprocal --harness=kilo --provider=deepseek --model=deepseek-v4-flash` → stdout `is reciprocal`, 0; `... --provider=anthropic --model=claude-sonnet-4` → stdout `not reciprocal` + stderr `agent (harness, provider, model) data complete and requirement failed`, 10; `... --harness=crush --provider=hyper --model=qwen3.7-plus` → stderr `agent (harness, provider, model) data incomplete to make a determination`, no stdout, 9.
3. Dev smoke: `fixtures` / `fixtures --help` → usage, 0; `fixtures frobnicate` → 2; `fixtures queue --fixture=bad` → 2; `fixtures queue --all --stale` → 3; `fixtures queue --all --available` (InvalidQueueRow: available needs scope) → 3; `fixtures queue` (no filter) → 4; `fixtures daemon` inside agent → 5; fixtures without `sqlite3` on PATH → 6; `fixtures daemon --write-log` with unwritable dir → 13; `fixtures capture` with empty env (no harness) → 8; `fixtures capture` full → 0; `raw` → 0.
4. `git grep -i "bevry-labs\|agent-detection"` → only `.kilo/plans/*` remain.
5. README links sanity: `bevry-vibes/agent-detect`, `bevry-vibes/skills/.../ai-policy.md`.

## out of scope / open

- **Tests expansion — POST-PLAN FOLLOW-UP** (deferred; a lot of testing revision is needed before release): new `src/exit_statuses.test.zig` for `reciprocityOf` (`.reciprocal` / `.not_reciprocal` / `.unknown` / `computeReciprocal` delegation) and `buildTrailerLine` (exact `Co-authored-by:` / `Assisted-by:` strings, `null` on missing identity); register in `build.zig` `test_files`; extend `.github/workflows/build.yml` smoke (smoke/nightly/release) with `trailer co-author` + `is-reciprocal` recipe-mode success-path asserts. Not part of this implementation.
- `Assisted-by` exact format: mirrors co-author (`Assisted-by: {label} · {label} <{id}@local>`); GCC policy only specifies the `Assisted-by:` tag.
- ANSI styling for help — explicitly out of scope.
- Exit 1 = "unrecognised error" reserved strictly for genuinely-unexpected/unclassified failures (uncaught zig errors, bugs). Every known error kind has its own status (2–13); do not widen 1's use.
