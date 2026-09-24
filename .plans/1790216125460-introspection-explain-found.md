# The introspection surface — `explain` + `found` — fixture channels, and trailer-selection guidance

Approved 2026-09-24. Supersedes nothing; new surface. Written for the tree as it stands after
`3f0edea` (the declared-raw regeneration wave) landed.

## Provenance

Every prompt that shaped this plan is recorded verbatim (untruncated,
timestamped, in order) in the companion file
`.plans/1790216125460-introspection-explain-found.prompts.md` — plans link to
it; they do not inline prompts. Agent model: GLM-5.3 (reported by harness).

## Layer taxonomy (evidence/raw vs reasons — the consolidation verdict)

Two different "why" layers, separate payloads, shared plumbing:

| | `found` (formerly the dev-only `raw` action) | `explain` (new) |
|---|---|---|
| answers | *what did the ladder observe on this machine?* | *why did the verdict come out as it did, and what now?* |
| content | process_lineage, evidence claims, detectable/detected, *-urls, platform/version | per-entity reason codes (which rung fired), judged values, sources, remediation actions, alternatives |
| audience | debugging detection, rule contributions ("what I saw") | any agent/user hitting exit 8/9/10 who needs to act |
| level | implementation detail | consumer interpretation |

Payloads do not merge (similar but too different); plumbing consolidates: both
released, both built from the same `Detection`, both mirror the tri-state in
exit codes, `explain` points to `found` for the observation trail.

## Workstreams

1. **The reason engine** (pure, `src/lib/core.zig`) — `ReasonEntity`/`ReasonCode`/`ActionKind`/`Action`/`Reason`
   types + `reasonsFor(a, d, rule)`; classification mirrors the ladder rung order (scandal → enforced →
   setting-enabled → disabled → never/opt → NOASSERTION/null); `values` carries judged pairs inline.
   Action kinds: fix_setting (per-harness `closed_setting_hint` rule field), switch_entity,
   preflight_combo (recipe-mode command), contribute_data (dual reference: `agent-detect found` command +
   CONTRIBUTING.md url), read_policy. Exit 6 (sqlite) stays a stderr one-liner, not a Reason.
2. **`explain`** — new released action, live + recipe, no identity gate (exit-8 states yield dim-missing
   reasons), exit mirrors state; `buildExplain` JSON: `{state, identity:{harness,provider,model} (no agent_id), reasons[]}`.
3. **`found`** — the dev `raw` action promoted + renamed; `buildRaw`/`buildDeclaredRaw`/`platformId` move
   to core.zig; always emits on exit 8 (observations are most wanted exactly then); recipe mode free via
   shared dispatch; fixture `outputs.raw` key becomes `found` **going forward only** (legacy `raw` accepted
   by the validator; no back-edit of existing files).
4. **stderr — both, layered** — registry first lines stay byte-stable; compact derived lines after
   (one per failing entity, judged value + explain pointer); single source of truth `reasonsFor`.
5. **Fixture channels** — `outputs.explain` (pure from Detection + rules: from-identity via resolveRecipe,
   captures in-process); dotted stderr channels `outputs["<action>.stderr"]` as **newline-split line
   arrays** (never multiline strings); corpus converges via natural regeneration waves.
6. **Reciprocal alternatives** (exit 10) — from the compiled rule tables (data already exists; nothing to
   add); resolve-true only, capped ~5, stable table order; wired into switch_entity instructions.
7. **Trailer-selection guidance** — README lead subsection (one trailer per artifact, never both; org
   instructions take precedence; context-default table: commits → co-author, issue-tracker posts →
   assisted-by); help texts; bare `trailer` exit 4 gains compact guidance after the stable first line.
8. **Upstream merge then retire** — upstream bevry-vibes/skills commits.md §"github issues, pull requests,
   and comments" gains the four-surface enumeration (issues, PRs, discussions, comments — best of both),
   pushed; only then agent-detect's local commits.md tweak (11-12) retires.

## Surfacing decision (A′ over B/C)

A′ = `explain` + `found` + layered stderr; identify keyset untouched. B (identify gains `reasons`)
stays available later — it reuses `reasonsFor` — but costs the frozen-keyset break (fixture.d.ts,
known_fixtures keyset, regeneration over the from-identity corpus). C (stderr-only) is subsumed by A′.

## Implementation order (each commit per commits.md: build first, generated trailer)

1. this plan file pair.
2. `core: the reason engine` — types, `reasonsFor`, compact renderer, tests.
3. `core: the raw builders move` — byte-stability smoke test against a committed from-capture fixture.
4. `core+main: the found action` — promote + rename, always-emit-on-exit-8, recipe mode, usage/help.
5. `core+main: the explain action` — dispatch live+recipe, `buildExplain`, usage/help.
6. `core+main: the failure stderr enrichment` — layered blocks on exits 8/9/10 (+6 sqlite line).
7. `fixtures: the new channels` — found + explain + `.stderr` line-arrays; d.ts + validator legacy raw.
8. `rules+core: setting hints + reciprocal alternatives`.
9. `docs: trailer-selection guidance` — README, help texts, bare-trailer stderr.
10. `skills: the upstream merge` — discussions enumerated upstream, commit + push.
11. `agent-detect: retire the landed local tweak`.
12. Final: `zig build && zig build dev && zig build test`, dist cross-compile check.

## Standing decisions

- explain `identity` = harness/provider/model — no `agent_id` (derivable from the trio).
- fixture key `found` going forward; `raw` accepted legacy; existing files untouched.
- stderr fixture channels = dotted keys holding newline-split line arrays.
- contribute_data refers to both `agent-detect found` (runnable now) and CONTRIBUTING.md (workflow).
- the issue-posts rule lands upstream with all four surfaces before the local tweak retires.
- guidance-on-exit-4 for bare `trailer`; no `--context` flag; non-interactive CLI (no stdin, ever).
