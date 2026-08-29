Assisted-by: Kimi Code · Qwen3.8 Flash <kimicode-opencodego-qwen38flash@local>
(provenance companion: `.plans/1787972028734-chutes-opencodego-model-license.prompts.md`,
created at execution step 0; line generated live via
`./zig-out/bin/agent-detect trailer assisted-by` — today's fallback
spelling, which this change replaces with verified rules.)

# kimi-code support: chutes + opencode-go, Qwen3.8 family, `model_license` contract bump, `.plans/` convention, reference grids

Live combo is now **`opencode-go/qwen3.8-flash`** (session earlier
tailed on `chutes/Qwen/Qwen3.8-27B-TEE`); harness `kimi-code`, darwin.
Both combos get rules + store rows; this session captures the live one.

⚠️ One earlier config grep surfaced the **chutes `api_key` value**
into the session transcript. Local-only, but rotate if this transcript
ever leaves the machine; later greps key-filter.

## Prompt-history review (per rejection feedback)

Every steering prompt and where it lands:
1. original: chutes + Qwen3.8 27B support → rules applied; row
   queued declared-only; its capture deferred (session moved providers).
2. full chutes catalog + document how to fetch it → steps 2 + 7
   (provider API / OR / harness — all three verified live today).
3. variations, not programmatic TEE trimming → decision 1 (fold
   landed in `applyModel`, alias data only).
4. OpenRouter per-provider availability + refresh evergreen +
   evergreen-gate additions + note non-evergreen + coding-suitability
   (`tools`) → steps 5 + 7, decisions 3-4.
5. critical family-folding analysis + HF collection discovery +
   flash-next boundary → decision 2 + step 7 docs.
6. `model_license` SPDX field + no folding across license → step 1.
7. param-size separation (multi-size → per-size rules; single-size →
   omit size) → decision 2 + steps 2-3 (reverts the earlier family
   rename; `qwen3.8-27b` stays).
8. evergreen gates additions only; drop dims only when the harness/
   provider drops them → decision 3 + step 7.
9. provider change to opencode-go/qwen3.8-flash → step 3 + live
   capture (step 9).
10. rejection: plan-location convention + history review → step 0.
11. rejection: `kilo.md` drops once `plans.md` exists; existing
    `.kilo/plans` files migrate to `.plans/` → step 0.
12. rejections: `.providers_models.csv` + `.harnesses_providers.csv`
    reference grids in `fixtures/` (cells = observed id strings or
    `-`; dev reference only; never sourced by zig) → decision 7 +
    step 6.
Delta fixes found in review: the old `.kilo` plan's `stash@{0}`
handoff item is **dead** (`git stash list` empty — dropped). Nothing
else missing.

## Decisions (user-steered, verified)

1. **TEE folding = alias-only**: observed provider spellings as
   hardcoded `variations`, folded by `canonicalIdFor` + the applied
   `applyModel` fold. No trimming/regex. Never-guess.
2. **Rule identity = version × param-size × license**: multi-size
   version → per-size rules (size in id); single-size → size omitted
   from id; serving-variant spellings (TEE, `-turbo`, `-0731`,
   quant/template stamps, namespaces) → variations; never fold across
   differing `model_license` or size; closed derivatives separate
   (`qwen3.8-max` = closed derivative of 2.4T-A95B, HF card +
   qwencloud); HF collections bound families (`qwen38` ≠
   `qwen38-flash-next`). Family discovery: collections page/API
   (`.items`), card Model-tree link, `?author=&search=`.
3. **Evergreen gates additions, not removals**: dims already in are
   dropped only when the harness/provider drops them; non-evergreen
   catalog hits are **noted in the reference grids (decision 7), not
   added**.
4. **Three-source provider discovery** (documented): provider API,
   OpenRouter (`/api/v1/models`, `/api/v1/models/<id>/endpoints`,
   `/api/v1/providers`), harness (`kimi provider list [--json]`,
   config `[models.*]`, `kimi provider catalog`). Coding-suitability =
   documented `supported_parameters` ∋ `tools`.
5. **`model_license` (SPDX) joins identify: 17 → 18 fields**, emitted
   after `model_reciprocity`, same semantics as the harness license
   table (SPDX id / `NOASSERTION` custom / `NONE` verified closed /
   `null` unverified). Audit/identity only — `reciprocityOf` untouched.
6. **Plans convention**: all harnesses write plans + `.prompts.md`
   companions to repo-root `.plans/`. `plans.md` **replaces
   `kilo.md`** (whose entire content is plan conventions, absorbed
   into `plans.md`) and is referenced from AGENTS.md per `meta.md`'s
   pattern — not harness config. Existing `.kilo/plans/*` (32 tracked
   files) migrate to `.plans/`.
7. **Reference grids** (new tracked dev-reference files in
   `fixtures/`, same status as the `.evergreen-*` snapshots —
   human/agent maintenance aids, **never read by the zig program**;
   verified: `known_fixtures` stem discovery ignores dotfiles/CSVs):
   - `fixtures/.providers_models.csv` — rows = provider alphanum ids,
     columns = model alphanum ids, cell = that provider's served
     model-id string, `-` where not offered. Shows what each provider
     has, with exact spellings (the TEE/namespace evidence trail).
   - `fixtures/.harnesses_providers.csv` — rows = harness alphanum
     ids, columns = provider alphanum ids, cell = the harness's
     provider-id spelling, `-` where no evidence of support.
   - Seeded from today's catalogs (chutes 14 rows-cells, opencode-go
     33) + existing committed evidence (fixtures map rows + fixture
     `raw_input`/config observations for the other harness×provider
     pairs); regeneration documented with the discovery runbook.

## Verified facts (probed)

- Chutes catalog `GET https://llm.chutes.ai/v1/models` (unauth) = 14
  TEE ids, agrees with harness surface. Chutes policy: privacy + ToS →
  never/never (zero logging, TEE/E2E, "do not use your API requests…
  to train").
- opencode-go = OpenCode Zen "Go" subscription, base
  `https://opencode.ai/zen/go/v1`; catalog unauth = 33 ids
  (`kimi-k2.6`, `glm-5.1/5.2/5.3(-flash)`, `qwen3.8-flash/-max`,
  `longcat-2.0`, `mimo-*`, `hy*`, `gpt-5.6-luna`, `grok-4.5/4.6`, …);
  docs/zen: zero-retention + no-training, named free-period
  exceptions (Big Pickle, MiMo-V2.5 Free) → never/never for the paid
  Go tier (second source TBD at apply — /privacy & /terms are 404).
- Licenses (HF, probed): Qwen3.8-27B Apache-2.0 · 2.4T-A95B
  `license:other` · Flash-Next "Qwen Community License 1.0" ·
  Kimi-K2.6 "Modified MIT" · GLM-5.1 plain MIT (no "Pure Open" →
  open-weight) · Mistral-Nemo-Instruct-2407 Apache-2.0 · Nemotron
  Nano-Omni `license:other`.
- Evergreen: committed snapshot stale vs fresh unauth
  `?sort=top-weekly&limit=100` (fresh adds qwen3.8-27b,
  2.4t-a95b, 3.5-397b-a17b, glm-5.3(-flash),
  deepseek-v4-flash-vision-exp…); `qwen3.8-flash` NOT evergreen →
  live combo rides the explicit-user-need exception.
- Contract: `known_fixtures.test.zig` strictly `contains()`-checks
  `identify_keys` but **only on `from-identity`** → the 18-field bump
  is healed by the zero-token `fixtures queue --known --from-identity`
  regeneration; legacy `from-capture.identify` stays 17 (not
  asserted).
- Live fallback already emits the combo shape (`…opencodego-qwen38flash…`)
  with null reciprocity/license → after this change it must become a
  verified identity (check-reciprocal exits 0, not 9).

## Already applied (pre-plan-mode)

- `rules.zig`: `chutes` provider rule; `qwen3.8-27b` model rule (stays
  size-specific per decision 2).
- `core.zig` `applyModel`: `canonicalIdFor` fold, miss = legacy
  passthrough.
- `main.zig`: `applyModel` re-export.

## Steps

0. **`.plans/` convention + `kilo.md` retirement** (first execution
   action, after approval):
   - probe `https://github.com/bevry-vibes/skills/blob/main/plans.md`
     — if it exists, `plans.md` references it per `meta.md`; else
     `plans.md` is a project-local convention marked "to be
     upstreamed".
   - root **`plans.md`**: absorbs all four `kilo.md` tweaks verbatim
     in spirit (companion `.prompts.md` with original + every shaping
     prompt verbatim, ordered — timestamps only where observable,
     never fabricated; agent model as reported by the harness; no
     condensed proposals — write a proper comparison doc first;
     commit plan + companion before `plan_exit`, per commits.md;
     intro carries the live `Assisted-by` line + companion link) and
     extends them: **every** harness writes plans to
     `.plans/<epoch-ms>-<slug>.md` (repo root), names preserved.
   - **delete `kilo.md`** (all of it is plan convention, now in
     plans.md); **AGENTS.md**: remove the kilo bullet, add "plans.md
     — applies to every harness writing plans" (pointer only, per
     meta pattern); sweep repo-wide for `kilo.md` / `.kilo/plans`
     references (CONTRIBUTING, DESIGN, commits.md, README, meta.md
     examples) and update.
   - **migrate the 32 tracked `.kilo/plans/*`** (plans +
     `.prompts.md`) via `git mv` to `.plans/`, names unchanged; check
     `.kilo/` for untracked leftovers before removing the now-empty
     dir.
   - migrate this plan + write the prompts companion into `.plans/`;
     commit plan + companion (trailer generated live).
1. **`model_license` plumbing**: `ModelRule.license ?[]const u8 =
   null` (+doc), `ModelOut.license`, `modelForName` passes it
   (fallbacks → null), `Detection.model_license`, `applyModel` +
   `resolveRecipe` set it, `buildJson` emits after
   `model_reciprocity`. Fill `license` on every rule touched (values
   above; `qwen3.8-max` → `NONE`); untouched rules stay null
   (backfill = later maintenance; no warning-test extension).
2. **Rules — chutes sweep** (decisions 1-4): new per-size rules
   `qwen3.5-397b-a17b`, `qwen3-235b-a22b` (verify licenses at apply;
   Thinking-2507 spelling folds here), `kimi-k2.6`, `glm-5.1`,
   `mistral-nemo-instruct-2407`, `nemotron-3-nano-omni` (single size →
   no `30b`; bare chutes id → 1 variation); variations (bare+namespaced)
   on `kimi-k3`, `glm-5.2`, `deepseek-v4-flash` (0731),
   `deepseek-v3.2`, `gemma-4-31b` (turbo); non-evergreen
   `Qwen3-32B-TEE`/`Qwen3.6-27B-TEE` recorded in the grids (step 6),
   not rules.
3. **Rules — opencode-go sweep**: provider rule (facts above); jq
   intersection of its 33 ids × refreshed evergreen → new rules for
   evergreen-only hits lacking rules (expected candidates: glm-5.3,
   glm-5.3-flash, deepseek-v4-flash-vision-exp, longcat-2.0,
   minimax-m2.5, mimo/hy/luna/grok-4.6/muse — per the actual
   intersection; reciprocity+license verified per model via HF at
   apply); non-evergreen remainder recorded in the grids (step 6).
   Live-combo model: verify `qwen3.8-flash` backing (opencode docs
   model table); names Flash-Next → rule `qwen3.8-flash-next`
   (open-weight, NOASSERTION) + variation `qwen3.8-flash`;
   unverifiable → rule `qwen3.8-flash` as served,
   reciprocity/license null (`step-3.7-flash` pattern). Either way
   the live capture resolves a real rule hit, no fabricated label.
4. **Evergreen refresh**: regenerate `.evergreen-models.json` +
   `.evergreen-providers.json` unauthenticated (no
   `OPENROUTER_API_KEY` in env; documented authenticated command
   stays canonical).
5. **Tests**: alias/fold/trailer suite (size-separated ids:
   `Qwen/Qwen3.8-27B-TEE`→`qwen3.8-27b`; spot-checks per steps 2-3
   incl. flash + providers `chutes`/`opencode-go`; never-guess nulls);
   `applyModel` fold + passthrough + `model_license` asserts;
   `known_fixtures.test.zig` `identify_keys` → 18 (title/comments).
6. **Reference grids**: create `fixtures/.providers_models.csv` +
   `fixtures/.harnesses_providers.csv` per decision 7; seed all
   observed provider catalogs (chutes, opencode-go) + backfill cells
   from committed fixtures-map evidence via a one-off local pass
   (python over `.index.json` + fixture raw channels — reference
   data only, no zig reads); `-` cells for no-data.
7. **Docs**: `CONTRIBUTING.md` — field table += `license`; 17→18;
   new "model rule identity & family folding" subsection; new
   "provider model discovery" block (3 sources + commands + tools
   filter + evergreen-gates-additions + drop-when-dim-dies +
   append-the-grids as each provider is cataloged); state-store
   section += the two grid files (dev reference, not sourced by the
   binary); alias-conventions TEE sentence; catalog-inference
   verdicts: chutes + opencode-go. `DESIGN.md` — 17→18
   (:67/:327/:461 + lists); #13 += TEE folding, size/license
   identity, additions-only gate. `AGENTS.md` += plans.md pointer
   (step 0).
8. **Build + verify**: `zig build test`/`dev` green; recipe
   `--model=Qwen3.8-27B-TEE` → `qwen3.8-27b` + Apache-2.0;
   `--model=qwen3.8-flash` → flash rule; live `identify` in this
   session → `kimi-code`/`opencode-go`/flash, 18-field canonical,
   `check-reciprocal` exit 0 (was unknown/9 via fallback); trailer
   verified.
9. **Store/fixture flow**: queue `--unknown
   --harness=kimicode --provider=opencodego --model=<flashid>
   --platform=darwin` (both modes) + `--unknown …
   --provider=chutes --model=qwen3827b --platform=darwin
   --from-identity` + `fixtures queue --known --from-identity`
   (18-field regen, zero tokens); **user runs the daemon**; I run
   `fixtures capture` (live combo); curate kimi
   `prompt_launch`/`version_launch` on the darwin rows; free axis
   unset. Implementation commit(s) per user's call.

## Out of scope

- Retro-fitting existing ids to the size-naming rule;
  `model_license` backfill for untouched rules; fixtures for other
  combos; linux/windows rows; zig reads of the grid CSVs (by design).
