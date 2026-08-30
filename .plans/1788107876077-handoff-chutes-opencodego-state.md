Assisted-by: Kimi Code · Qwen3.8 Flash <kimicode-opencodego-qwen38flash@local>
(provenance companion: [1788107876077-handoff-chutes-opencodego-state.prompts.md](./1788107876077-handoff-chutes-opencodego-state.prompts.md);
full prior prompt history: [1787972028734-chutes-opencodego-model-license.prompts.md](./1787972028734-chutes-opencodego-model-license.prompts.md))

# Handoff — chutes/opencode-go support + model_license + store overhaul

Written 2026-08-31 at the end of the implementation session, before
push. Read this first in a new session, then
`1787972028734-chutes-opencodego-model-license.md` (the plan) and
`1787978000867-retroactive-folding-options.md` (decided proposal).

## What this change was

Started as "support our unknown live combo: kimi-code × chutes ×
Qwen3.8-27B-TEE on darwin", expanded by user steering into: the full
chutes catalog, a mid-session provider switch to
`opencode-go/qwen3.8-flash` (live capture), a retroactive opencode-go
catalog sweep, the `model_license` contract field, folding/identity
policy doctrine, the `.plans/` convention, store schema + bloat
overhaul, and the free-models grid.

## Landed state (committed by this handoff commit)

- **Rules** (`src/lib/rules.zig`): providers `chutes`, `opencode-go`
  (opt-in/opt-in — see hard rule), `openrouter` open_training
  `opt-in` (contributor tiers train); removed phantom provider
  `qwen3.7-plus`, splits `deepseek-v4-flash-free` + `zai-glm-4.7`
  (folded as parent variations); ~16 new model rules (chutes +
  opencode-go evergreen sweeps + live-combo `qwen3.8-flash`); TEE/
  tier/stamp variations on 7 existing rules; `license` (SPDX,
  harness-table semantics) on every touched rule.
- **Detection** (`src/lib/core.zig`): `applyModel` +
  `applyProviderMeta` fold served spellings through `canonicalIdFor`
  (never-guess preserved: miss ⇒ raw passthrough); `detectCrush`
  folds hyper.json model-id-as-key to `hyper`; `model_license` full
  plumbing — identify contract is now **18 fields** (`plans.md`
  nulls are emitted as `null` in fixture files; store nulls are
  absent — different channels, different rules).
- **Store/schema** (`src/dev/dev.zig`, `fixtures/.index.d.ts`):
  normative TS schema declares the store structure; null-as-absent in
  `queueEntryValue` + load-time drop of legacy
  `free_provider_to_model`; **free axis source of truth = `fixtures/
  .providers_freemodels.csv`** (sparse grid; the only grid zig
  reads); reference grids `fixtures/.providers_models.csv` +
  `.harnesses_providers.csv` (never read by zig); evergreen
  snapshots refreshed (unauthenticated — no `OPENROUTER_API_KEY` in
  env).
- **Governance**: `plans.md` (all harnesses → `.plans/` +
  `.prompts.md` companions), `kilo.md` retired, 32 historical plans
  migrated (commit `017c64a`).
- **Fixtures/store data**: live capture
  `fixtures/kimicode-opencodego-qwen38flash-darwin.json` (+ curated
  kimi argv on its row); 6 split-id rows + 2 files removed (option
  B); 705 queue entries staged incl. `--unknown` from-identity rows
  for every new rule, `--known --from-identity` 18-field regen sweep,
  and the `pi-groq-llama318b-darwin` legacy regen.
- **Tests**: `zig build test` = 23/25 green; the 2 reds are
  store-state pending the daemon (see next step), not code.
- Docs: CONTRIBUTING (identity/folding doctrine incl. official-claim
  naming + phantom-provider guard + opt-in-by-model hard rule +
  three-source provider discovery + grids + 18-field contract +
  verdicts), DESIGN (state-store semantics-only w/ schema pointer,
  #13 updates).

## Immediate next step (the unblock)

Run the user-only daemon (never inside an agent):
`./zig-out/bin/agent-detect-dev fixtures daemon` (or `--write-log`).
It drains the 705 queued entries (~5s/pop for from-identity; the
~690-row `--known` regen is the bulk). When it finishes: `zig
build test` should be fully green; commit the dirty store + fresh
declared fixtures ("store dirties on every mutation; commit when
work lands" — CONTRIBUTING). Expected known failures during the
drain: `pi-groq-llama318b-darwin` from-capture may stamp
unavailable/capture-failed (legacy file + pi/groq account state);
that's the failure ledger working, not a bug.

## Pending follow-ups (prioritised)

1. **`qwen3.8-flash` backing** — rule exists with
   reciprocity/license `null` (never-guess): no `Qwen/Qwen3.8-Flash`
   HF repo; OR lists it with no `hugging_face_id`; the open 3.8-flash
   line is `Qwen3.8-Flash-Next` (collection `qwen38-flash-next` —
   DISTINCT family from `qwen38`). If it's confirmed as the hosted
   Flash-Next form: fill reciprocity `open-weight` + license
   `NOASSERTION` ("Qwen Community License 1.0") + sources, or fold
   the spelling as a variation onto a `qwen3.8-flash-next` rule
   (that renames the live agent_id — recapture after). Ask the user;
   they run it.
2. **Chutes capture** for `kimicode-chutes-qwen3827b-darwin`: only
   from-identity is queued (session moved providers). To capture:
   point `~/.kimi-code/config.toml` `default_model` back at
   `chutes/Qwen/Qwen3.8-27B-TEE` (user's action) and hand-run
   `fixtures capture`, OR curate the row's kimi
   `prompt_launch`/`version_launch` (pattern:
   `["kimi","-p","<prompt>"]` / `["kimi","--version"]`) and let a
   daemon `from-capture` pop do it (token-consuming, user-confirmed).
3. **Launch argv curation** for the new declared rows as captures
   become wanted (same kimi pattern per platform). Specifically the
   opencode parent combo from option B: curate
   `opencode-opencode-deepseekv4flash` prompt_launch with the free
   spec `opencode/deepseek-v4-flash-free` so the free-signal test
   passes once its row lands.
4. **`model_license` backfill** for untouched rules (many default
   `null`) — cheap sweep: HF `license` tag per rule; SPDX id |
   NOASSERTION | NONE. Consider `--stale-by-detect-version` after
   the next release bump so declared channels re-emit with filled
   licenses.
5. **Cross-device coverage**: new rows/combos are darwin-only;
   linux/windows daemons expand the same queue tuples per the
   cross-device runbook (CONTRIBUTING).
6. **Audit `providerForBaseUrl`**: it maps `requesty.ai → openai` —
   a router-naming shortcut, same class the phantom-provider guard
   now forbids in rules; decide whether requesty deserves its own
   provider surface or a documented exemption.
7. **Grid maintenance**: append every newly cataloged provider's
   row to `.providers_models.csv` (+ free spellings to
   `.providers_freemodels.csv` — it is normative; re-run
   `zig build test` after edits, the free-grid test checks sparsity
   + rule resolution + launch free-signals).
8. Rotate the chutes `api_key` (surfaced in the old session
   transcript — see the plan file's warning block).

## Learnings (so they aren't relitigated)

- **Variations folding**: aliases only (data), never programmatic
  suffix trimming — the `canonicalIdFor` fold in `applyModel`/
  `applyProviderMeta` is the whole mechanism; live + recipe paths
  must both route through it (recipe already did — live didn't).
- **Naming**: official-claim naming; distinction (param size, etc.)
  only where competing claims on the non-distinct name make it
  necessary; folding never crosses license/size; closed derivatives
  separate (`qwen3.8-max` ↔ 2.4T-A95B evidence: HF card +
  qwencloud.com); HF collections bound families (`qwen38` ≠
  `qwen38-flash-next`); family discovery via collections API
  (`.items`), Model-tree, `?author=&search=`.
- **Providers**: rules mirror provider SURFACES the user configures
  (cline-pass, minimax-code, deepseek-flash, opencode-go ✓);
  never a model id masquerading as one (crush `qwen3.7-plus` was —
  removed; detector folds it to hyper). **Opt-in-by-model hard
  rule**: contributor/free-period trainers ⇒ axis `opt-in`, never
  `never` (openrouter open axis; opencode-go both axes).
- **Evergreen gates additions, never removals** — drop a dim only
  when the harness/provider drops it; observed-but-unadded ids live
  in the grids (that's where the "note them somewhere" requirement
  landed).
- **Three-source provider cataloging**: provider API
  (`llm.chutes.ai/v1/models`, `opencode.ai/zen/go/v1/models` — both
  unauth), OpenRouter (per-model `…/endpoints` lists serving
  providers — confirms chutes), harness (`kimi provider list
  [--json]`, config `[models.*]`, `kimi provider catalog`
  models.dev). Coding-suitability = `supported_parameters ∋ tools`.
- **Store**: shape source of truth is `fixtures/.index.d.ts` (TS as
  docs-contract, zig doesn't compile it); null-as-absent there,
  while fixture identify files emit explicit `null`s (18-field
  contract); free axis = `.providers_freemodels.csv` (sparse,
  normative, zig-read).
- **Contract-test quirks**: `rule_only_*` exemption lists already
  cover row-less detection-coverage rules (the "orphan treadmill"
  fear was wrong); `identify_keys` presence checks pass vacuously
  until from-identity channels exist; queue re-asserts must repeat
  the SAME axis flags (an `--unknown` tuple re-asserted without
  `--unknown` becomes a second, differently-defaulting entry);
  fixture `discoverStems` skips dotfiles, so grids/`index` coexist
  safely in `fixtures/`; `queueEntryValue` rewrites only upserted
  entries — bulk re-serialization needs a one-off pass.
- **Ops**: zig reinstall happened mid-session (0.16 API:
  `ObjectMap.orderedRemove`, `ArrayList` is unmanaged-style
  `.empty` + `append(a, …)`); a broad config grep leaked an api_key
  into transcript — key-filter (`grep -v -i key`) harness config
  reads, and `agent-detect` itself redacts env values by default.
- **Plans**: `.plans/<epoch-ms>-<slug>.md` + verbatim `.prompts.md`
  companions, live `Assisted-by` intros, commit plan before
  plan_exit (plans.md; kilo.md retired).

## Verification snapshot (pre-commit)

- `zig build` ✓ `zig build dev` ✓
- `zig build test`: 23/25 — reds: envelope `pi-groq-llama318b-
  darwin` (legacy shape, regen queued) + "every rule appears in
  ≥1 row" (new rules pending daemon). No leaks.
- Recipes: `chutes/Qwen3.8-27B-TEE` → `qwen3.8-27b`/Apache-2.0/
  reciprocal ✓; `Kimi-K3-TEE` → `kimi-k3` ✓;
  `crush hyper qwen3.7-plus` → `crush-hyper-qwen37plus` ✓; phantom
  provider exit 7 ✓; live session →
  `kimicode-opencodego-qwen38flash` with real rule hit ✓.
