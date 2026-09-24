# The regeneration sweep, the check-reciprocal channel, and the qwen3.8-flash audit

Written 2026-09-24, directly after `.plans/1790216125460-introspection-explain-found.md` landed
(`0069949`/`898a32b`; the upstream skills push `18b73d7`). This plan is the follow-up triage of that
plan's deferrals plus the live store state — four workstreams in scope, everything else recorded
below as standing considerations or left where it already lives.

## Provenance

Every prompt that shaped this plan is recorded verbatim (untruncated, timestamped, in order) in the
companion file `.plans/1790219820902-regen-sweep-checkreciprocal-qwen38flash.prompts.md` — plans link
to it; they do not inline prompts. Agent model: GLM-5.3 (reported by harness).

## Workstream 1 — the check-reciprocal fixture channel (lands BEFORE the sweep)

The one code change in this plan, and it must land first so the regenerated corpus carries it:

- `outputs["check-reciprocal"]` — the stdout verdict string (`"is reciprocal"` / `"not reciprocal"`),
  present on the states that print stdout (0 and 10; exit 9 is stderr-only).
- `outputs["check-reciprocal.stderr"]` — the newline-split line array (registry first line + the
  compact reason lines), present on 9 and 10, absent otherwise. Same arrays-not-multiline convention
  as `identify.stderr`/`explain.stderr`.
- `stderrLinesFor` gains a `.check_reciprocal` case (MSG line + compact reason lines — exactly what
  the CLI prints per runAction); the verdict string is a one-line helper.
- Writers: both fixture channels (from-identity regen, from-capture) emit both keys.
- Validator (`known_fixtures.test.zig`): the two keys join the outputs allow-lists + the array-shape
  checks. `fixtures/fixture.d.ts`: the channel types. DESIGN.md "failure reasons & remediation" +
  CONTRIBUTING "refresh a fixture" mention them.
- Unit tests: the `.check_reciprocal` stderrLinesFor cases (0 → both absent; 9 → stderr only; 10 →
  verdict + stderr).

## Workstream 2 — the qwen3.8-flash backing audit

The live-combo alias rule carries reciprocity/license `null` pending a backing audit: no
`Qwen/Qwen3.8-Flash` HF repo exists, and the 3.8-flash open line is the separate `qwen38-flash-next`
collection (recorded at CONTRIBUTING "catalog-inference verdicts"). The audit determines what the
alias actually serves — the never-guess rule applies: findings set `openness`/`model_license`/
`closed_training` with two same-provider sources; inconclusive stays `NOASSERTION` with the research
sources, never a guess. Update the rule + its comment, regen its combos (rides workstream 4's sweep).

## Workstream 3 — the regeneration sweep + queue drain (user-side daemon)

The daemon refuses to run inside an agent session by design, so this workstream is the user's run,
queued by the agent:

1. **The ollamacloud refresh** — 131 fixture files still carry the pre-individuation
   `provider_id: "ollama"` (the test-run warnings name them). Queue via
   `agent-detect-dev fixtures queue --provider=ollamacloud --refresh --from-identity`.
2. **The queued entries** — 13 live in `fixtures/index.json` (zcode + cloudflareworkersai from-identity
   passes, two phala darwin combos, the free-provider sweeps — clinepass/opencode/openrouter/nvidia/
   vercel/zenmux/ollama — and one whole-universe from-identity entry).
3. **The known_but_failed triage** — 310 retryable operational failures, dominated by host-platform
   mismatches (darwin captures attempted where `ioreg` doesn't exist) plus copilot `--model`
   rejections and a cursor Workspace-Trust prompt. The sweep should clear the entries the regen
   obsoletes and leave the genuinely-environmental ones; `known_but_failed` is informational, never a
   gate.
4. The sweep is also the convergence carrier: every file it rewrites gains the `found`/`explain`/
   `.stderr` channels (legacy `raw` retires per file as it regenerates) — and, via workstream 1, the
   check-reciprocal channels.

## Workstream 4 — the unsourced-value residue (verification, not research)

The training-policy exploration already landed — the reports are
`.plans/provider-training-policy-research.md` (the worksheet) and
`.plans/1788716755355-provider-fold-individuation-review.md` D8 (the corrections re-verified into the
rules); the worksheet's TBD column is stale, the rule tables are the truth. What genuinely remains
(checked against `rulesForProviders`/`rulesForModels` this session): **11 provider cells**
(`moonshotai`, `zenmux`, `siliconflow`, `sakana`, `kimi-coding`, `meta`, `google-antigravity`,
`gmi-cloud`, `nanogpt` null; `cursor`, `kilo` NOASSERTION — cursor is scandal-flagged so its cell is
moot) and **~8 model cells** (6 openness-null + 2 closed-training NOASSERTION). No new research in
this plan: the sweep's `explain` channels surface exactly these per combo, and closing them is a
later call.

## Considerations stored for later (not this plan's work)

- **Settings visibility** (merged 5+6) — the same theme from both ends: more per-harness
  `closed_setting_hint` values (survey each detector's config surface; only zcode carries one today)
  and the `--query-remote` future flag (provider toggles are server-enforced account state no harness
  mirrors; query the panel only for the ambiguous opt-in/opt-out cases, user consent, no-network
  rule).
- **Fixtures as a website** — a static site rendered from the fixture corpus (dev-bin generator
  step); the fixture JSONs already carry everything it would need.
- **Windows `KILL_ON_JOB_OBJECT`** — the stronger orphaned-worker fix; future work for when a
  Windows daemon runner exists.
- **The shared `local` provider rule** — the standing deferral (DESIGN #15c): revisit when a second
  local runtime (lmstudio, llama.cpp servers) is actually observed.
- **Kilo sqlite evidence claims** — what this means: `EvidenceClaim` cites readable sources (env var,
  config/session file field, lineage name), but kilo's live model dim is read from a binary sqlite
  store with no JSON field to point at, so its model-dim claim can't serialize — logged follow-up,
  never faked. Closing it means extending the claim vocabulary with a db source shape (name = db
  path, field = the table/column read) plus its redaction rules.
- **`pending_binary_names`** — what this means and what's needed: `dev.zig` keeps a hardcoded list of
  executable names for harnesses that have no rule yet (claude, codex, grok, gemini, openclaw) so the
  daemon's in-agent guard also refuses to run inside their sessions. It is a maintenance coupling:
  when a pending harness gets its rule, drop its entry here; when CONTRIBUTING's pending list gains a
  harness, add its binary name here. Nothing else is owed.
- **Contributor-scope** (store for another contributor): the autoclaw desktop from-capture
  invocations (no headless launcher mapped; version source identified — Info.plist
  CFBundleShortVersionString), and the `open_training_config`/`closed_training_config` field split
  (separating docs-derived policy from instance-determined active config; revisit once live captures
  exercise the merged fields).

## Explicitly not carried forward

- **Option B** (identify gaining a `reasons` key) — lives only in the introspection plan
  (`.plans/1790216125460`); deliberately not resurfaced.
- **The pending-harnesses backlog** — stays in CONTRIBUTING for other contributors.
- **Legacy meta stems** — the 9 hardcoded `isLegacyRequiredMeta` exemptions (pi-anthropic…,
  reasonix-… darwin captures predating the full-meta rule); each drops automatically as its fixture
  is next re-captured — self-resolving, nothing to plan.
- **`nous`/`openai-codex` harnessprovider cells** — inert until a ruled-model catalog lands;
  CONTRIBUTING already records them.

## Implementation order (each commit per commits.md: build first, generated trailer)

1. this plan file pair.
2. `core+dev+fixtures: the check-reciprocal channels` — stderrLinesFor case, verdict helper, writers,
   validator, d.ts, DESIGN/CONTRIBUTING notes, unit tests.
3. `rules: the qwen3.8-flash backing audit` — research, rule values (or NOASSERTION) + sources,
   comment update; its fixture regen rides the sweep.
4. `fixtures: queue the regen` — the ollamacloud refresh queue entry (+ confirm the 13 existing
   entries), commit the store; the daemon run itself is the user's (in-agent refusal by design).
5. Final: `zig build && zig build dev && zig build test`; after the user's daemon run, the corpus
   lands as its own `fixtures:` commit.
