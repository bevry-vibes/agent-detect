# Expand captures across all harnesses + add the maintained CLI harnesses

Continuation of `.kilo/plans/1786233189526-testing-matrix-harness-provider-model.md`
(fully implemented + committed 2026-08-11; this is the next phase).

## Goal

1. **Part 1 — programmatic combo inference for the other harnesses**, the way
   omp's was done from its local catalog: for every coding harness, determine
   whether its provider×model combos are enumerable from a local/CLI catalog,
   then add the recipes (and rules, and fixtures) the inference yields.
2. **Part 2 — add the maintained/popular/high-quality CLI coding harnesses**
   from https://github.com/vercel-labs/skills#supported-agents, as rules +
   recipes now (zero-token `from-ids` fixtures immediately; `from-raw`/real
   captures when the harness is installed or a paid plan exists).

`zig build test` stays green throughout; every committed fixture keeps a valid
`origin` + evidence claims (the existing test suite enforces this).

## Current state (verified 2026-08-11)

- 110 recipes, 100 committed fixtures (13 `from-capture`, 87 `from-raw`), 11
  coding harnesses; recipe count per harness: cline 6, crush 4, goose 1, kilo 5,
  kimicode 3, mmx 2, omp 63, opencode 6, pi 11, qwen 3, reasonix 3, vibe 3.
- The omp evergreen+free expansion (4 batches) proved the pattern: read the
  harness's local model catalog → intersect the coalesced evergreen top-50
  (`docs/evergreen-top50-models.txt`) → select the free models per provider →
  add provider/model rules + recipes → capture via the `from-raw` daemon sweep.
- **Git user is Benjamin Lupton (`b@lupton.cc`)** — the model-preference spec
  applies (given in the omp session): for model additions, do them in this
  order: 1. all providers, free models; 2. minimax provider, all models (skip
  its free models if still fresh / not stale); 3. clinepass provider, all
  models (skip free if fresh); 4. deepseek provider, all models (skip free if
  fresh). This explicit user preference supersedes the evergreen-top-50
  constraint for the named providers (the constraint stays for other providers'
  paid models).
- **Cross-harness blocker from the previous plan still holds:** the free
  evergreen providers (zenmux, siliconflow, ollama-cloud, gmi-cloud, nanogpt,
  huggingface, cursor, github-copilot, sakana, meta, google-antigravity,
  kimi-code) are configured only on omp. The other harnesses are authed against
  their own provider sets (see matrix below), so each harness's inference is
  scoped to the providers *that harness* is actually configured with.

## Part 1 — per-harness catalog inference matrix (verified this machine)

| harness | catalog source | result | inferable combos |
| --- | --- | --- | --- |
| omp | `~/.omp/agent/models.db` (SQLite `model_cache`, JSON per provider incl. `cost`) | **DONE** (63 recipes) | all evergreen+free across ~20 providers |
| pi | `pi --list-models` (394 models, 8 providers: cerebras, deepseek, groq, minimax, mistral, moonshotai, openrouter, xai) + `~/.pi/agent/models-store.json` (per-provider JSON incl. `cost`; free = `cost.input==0`) | **INFERABLE** | free models across the 8 authed providers + minimax/deepseek all models |
| opencode | `opencode models` (83 models; providers alibaba, cline-pass, deepseek, minimax + free `opencode/*-free` router) | **INFERABLE** | free `opencode/*-free` tier + per-provider catalog per ordering spec |
| kilo | `kilo models` (481 models; providers alibaba, cline-pass, deepseek, fireworks-ai, hyper, kilo, minimax, ollama-cloud, opencode + free `kilo/~*-latest` router) | **INFERABLE** | free `kilo/~*-latest` tier + per-provider catalog per ordering spec |
| crush | `crush models` (models.dev catalog, 40 providers; runtime = hyper provider only) | **PARTIAL** | hyper-provider models (check `~/.config/crush/hyper.json`); the rest of the catalog is not runnable |
| qwen | `~/.qwen/settings.json` `modelProviders` (per-provider arrays with `baseUrl`+`envKey`; free via `:free` suffix on ids) | **INFERABLE** | the configured providers' combos (openai/requesty, minimax, grok/xai, deepseek, dashscope) per ordering spec |
| kimi | `kimi provider list` → none configured; `kimi provider catalog` imports models.dev | **PARTIAL** | none until the user runs `kimi provider catalog`; then the imported providers |
| reasonix | `~/.reasonix/config.toml` `[[providers]]` (name/kind/base_url/models/default/prices) | **PARTIAL** | the configured providers only (currently deepseek-flash) |
| goose | `goose local-models` (local inference only) | **NO** | — |
| mmx | `~/.mmx/config.json` (oauth only) | **NO** | — |
| vibe | `~/.vibe/config.toml` (`active_model`) | **NO** | — |

**Note:** the underlying shared catalog for cline/kimi/pi/crush is
[models.dev](https://models.dev/api.json); each harness exposes its authed
provider subset. A network catalog fetch (opencode/kilo/crush models commands)
is a plain GET — consumes no model tokens.

## Part 2 — new harnesses (curated tiered list, user-confirmed)

**Tier 1 — full treatment (rule + detect fn + buildEnv + recipes + fixtures):**
- **claude-code** (`claude`) — installed but the native binary is broken on
  this machine (npm postinstall didn't run); add rules/recipes now, fix install
  → `from-raw` later. Detection: env `ANTHROPIC_MODEL`/`ANTHROPIC_BASE_URL`/
  `ANTHROPIC_AUTH_TOKEN` + `CLAUDE_CODE_*`; config `~/.claude/settings.json` +
  `~/.claude.json`; sessions `~/.claude/projects/`; proc `claude`. Launch
  (verify): `claude -p <prompt>`.
- **codex** (`codex`) — installed, `~/.codex` has no config yet. Detection:
  config `~/.codex/config.toml` (`model`, `model_provider`); sessions
  `~/.codex/sessions/`; proc `codex`. Launch (verify): `codex exec <prompt>`.
- **grok** (`grok`) — installed + actively used (`~/.grok/config.toml`,
  `models_cache.json`, `sessions/`, `worktrees.db`). Detection: config
  `~/.grok/config.toml` + models from `models_cache.json`; sessions
  `~/.grok/sessions/`; proc `grok`. Launch (verify): `grok --always-approve
  <prompt>`.
- **gemini-cli** (`gemini`) — not installed. Detection: config
  `~/.gemini/settings.json`; proc `gemini`. Launch (verify): `gemini -p <prompt>`.
- **amp** (`amp`, Replit/Anvil) — not installed. Detection: config under
  `~/.config/amp/`; proc `amp`. Launch (verify): `amp run <prompt>`.
- **roo** (`roo`, Roo Code) — not installed. Detection: config
  `~/.config/roo/`; proc `roo`.
- **qoder** (`qoder`, Alibaba) — not installed. Detection: config `~/.qoder/`;
  proc `qoder`. Launch (verify): `qoder -p <prompt>`.
- **openhands** (`openhands`) — not installed (docker runtime). Detection:
  config `~/.openhands/`; proc `openhands`. Launch (verify): `openhands
  --headless ...`.

**Tier 2 — declared recipes only (`from-ids`, zero tokens; real captures
deferred until access):** cursor (`~/.cursor/`), devin for Terminal
(`~/.config/devin/`), droid/Factory (`~/.factory/`), zencoder
(`~/.zencoder/`), kimchi (`~/.config/kimchi/harness/`), firebender
(`~/.firebender/`), copilot CLI (`~/.copilot/`). Rule + ≥1 recipe each;
provider/model dims must resolve in the rule tables (add rules as needed).

**Out of scope (unchanged):** machine-control agents (openclaw); IDE-embedded
agents (continue, cody, windsurf, codebuddy, trae, trae-cn); editors (warp,
zed); autocomplete (tabnine); bot frameworks (astrbot); the obscure/unverified
remainder of the list. `jcode` stays dropped.

## Work items

### 1. Part 1 — catalog inference + expansion batches

Do these harness-by-harness, `zig build test` green at each checkpoint, in this
order (front-loads the free-tier wins):

1a. **pi** — read `pi --list-models` (and `~/.pi/agent/models-store.json` for
`cost`); free = `cost.input==0` (omp analog). Per the ordering spec: add free
models across the 8 authed providers first (cerebras free trio already in;
openrouter `:free` models, groq free tier), then minimax all models, then
deepseek all models. Add missing model/provider rules (e.g. mistral's
codestral/devstral set already partially present; verify against
`rulesForModels`). Recipes + `from-raw` sweep.

1b. **opencode** — parse `opencode models`. Add the free `opencode/*-free`
tier (provider `opencode`, models `deepseek-v4-flash-free` already present;
add `nemotron-3-ultra-free`, `longcat-2.0-free`, `north-mini-code-free`, etc.
per catalog + evergreen set), then the authed providers' models per ordering
spec. Recipes + `from-raw` sweep (the opencode session-db fallback makes
`from-raw` evidence clean).

1c. **kilo** — parse `kilo models`. Add the free `kilo/~*-latest` router
models (provider `kilo`), then per ordering spec. Recipes + `from-raw` sweep
(`KILO_MODEL` env path makes evidence clean).

1d. **crush** — `crush models` lists the full models.dev catalog, but the
runtime provider is `hyper`. Confirm the runnable set from
`~/.config/crush/hyper.json` (absent on this machine → likely hyper only).
Add hyper-provider recipes per ordering spec; do not add recipes for catalog
providers crush cannot actually run. Recipes + `from-raw` sweep.

1e. **qwen** — parse `modelProviders` from `~/.qwen/settings.json`; map
`baseUrl`→provider via `providerForBaseUrl` (requesty→openai? verify;
minimax; x.ai→xai; deepseek; dashscope→qwen). Add the configured combos'
free models first (`:free` ids), then per ordering spec. Recipes + `from-raw`
sweep (qwen reads `modelProviders[].baseUrl`).

1f. **kimi / reasonix** — limited catalogs. kimi: only proceed if the user
runs `kimi provider catalog` (models.dev import) and configures providers;
until then keep the 3 existing recipes. reasonix: add recipes only for the
configured `[[providers]]` (deepseek-flash) per ordering spec.

1g. **goose / mmx / vibe** — no enumerable catalog; keep existing recipes.
Record the "not inferable" verdict per harness in CONTRIBUTING.md so the
decision is not re-litigated.

1h. **Evergreen cache check** — refresh `docs/evergreen-top50-models.txt` only
if the leaderboards shifted materially; the ordering spec's named providers
(minimax/clinepass/deepseek) bypass the evergreen gate.

### 2. Part 2 — new harnesses

For each Tier-1 harness (then Tier-2 declared):
- Add `HarnessRule` (env_markers, proc_names, license + license_sources) to
  `rulesForHarnesses` (main.zig:587).
- Add the `detect*` fn wired into the ladder dispatch (main.zig:2644). Verify
  each detection surface (env vars, config paths, session paths, proc names)
  from the harness's docs/installed binary before committing — the
  CONTRIBUTING.md "add a new harness rule" section is the checklist.
- Add `buildEnv` for the harness (from-raw fabricator) and ≥1 recipe in
  `recipesForFixtures` (the test suite enforces: every harness rule has ≥1
  recipe; every recipe dims resolve in the rule tables).
- Add any new provider/model rules the recipes reference (missing providers
  spotted: `alibaba`, `gemini`, `openai`, `fireworks-ai`; verify each).
- Add `devProviderMeta` entries for the new providers (base_url + key_env).
- Add launch specs where a headless mode is verified (claude, codex, grok,
  gemini, amp, qoder, openhands); leave `null` for the rest.
- Fixtures: `from-ids` declared fixture for every new recipe immediately
  (zero tokens, no harness needed — satisfies the origin/evidence tests).
  Then `from-raw` sweep for the installed harnesses (grok first — actively
  used; then codex; claude after the install is fixed).

### 3. Tests

- Existing tests already enforce: recipe dims resolve in rule tables, every
  harness has ≥1 recipe, origin valid, evidence claims valid. New harnesses
  must pass all of these (from-ids fixtures pass by construction).
- No new test files expected unless a detection pattern needs one (mirror the
  kilo/opencode session-db evidence follow-ups if a new harness needs one).

### 4. Run

1. `zig build dev`
2. For each Part-1 batch (1a–1e): add rules/recipes → `fixtures daemon
   --write-log` running (user terminal, per CONTRIBUTING.md) →
   `fixtures queue --recipes --available` (default from-raw, zero tokens) →
   review fixtures + evidence as they land → fix any detection failures →
   `zig build test` green → commit (AGENTS.md commits policy incl. co-author
   trailer via `./zig-out/bin/agent-detect trailer co-author`).
3. For Part-2: add each harness's rule/detect/buildEnv/recipe → capture its
   `from-ids` fixture (`fixtures queue --agent=<h>-<p>-<m> --from-ids`) →
   `from-raw` sweep for grok/codex (claude once fixed) → `zig build test` →
   commit per harness or in a small batch.
4. Update CONTRIBUTING.md install table (claude, codex, grok, gemini, amp,
   roo, qoder, openhands + Tier-2 rows), the pending-harnesses list (remove the
   added ones), and DESIGN.md harness scope list. Update the "not inferable"
   verdicts per harness (1g).

## Validation

- `zig build test` green at every checkpoint (recipe-dims, ≥1-recipe-per-harness,
  origin, evidence-claims tests all pass).
- Part 1: each inferable harness gains recipes from its catalog (free-tier
  combos first per ordering spec); fixtures are `from-raw` with valid evidence
  claims; no speculative combos (recipes restricted to the harness's own
  authed providers).
- Part 2: every new harness has ≥1 recipe + a `from-ids` fixture (origin +
  empty evidence); the installed ones (grok, codex, claude) additionally get
  `from-raw` fixtures with valid evidence; launch specs present only where the
  headless mode was verified.
- `fixtures queue --recipes --available` still probes all harnesses; real
  harness configs unmutated (sandboxed worker HOME).
- Docs updated: CONTRIBUTING.md install table + pending list; DESIGN.md scope.

## Risks

- **New-harness detection surfaces unverified** (config paths/env/proc names
  guessed from docs) → `from-raw` fixtures could be mechanically-valid but
  semantically wrong. Mitigation: only `from-ids` (declared) fixtures for
  unverified harnesses; verify surfaces against the installed binary or docs
  before `from-raw`. Semantic deducibility stays human review per decision #11.
- **Speculative recipes:** adding a recipe for a provider the harness can't
  reach wastes a fixture and misleads. Restricted to the harness's authed
  providers (Part 1) and verified launch modes (Part 2).
- **claude native binary is broken** on this machine → claude `from-raw`/
  capture deferred until the npm postinstall is fixed; rules + from-ids land
  regardless.
- **Fixture count grows** (~100 → 150+): the schema/evidence tests scale
  automatically; the sweep is the only cost (zero tokens for from-ids/from-raw).
- **Catalog drift:** harness `models` commands hit live catalogs; recipes must
  coalesce name variations to canonical models per decision #13.

## Follow-ups (logged, not faked)

- **Real captures for the new paid harnesses** (claude/codex/grok/gemini/amp/
  roo/qoder/openhands + Tier-2) — user-confirmed, token-consuming, via the
  daemon's `from-capture` mode once the user has the plans/installs.
- **kimi catalog import** — run `kimi provider catalog`, then re-run 1f.
- **Any custom evidence source** a new detector needs (session DBs, custom
  config formats) gets the kilo/opencode session-db treatment: claimed if it
  maps to env/config/session shapes, logged here if not.

## Out of scope

- IDE-embedded (continue/cody/windsurf/codebuddy/trae), machine-control
  (openclaw), editors (warp/zed), autocomplete (tabnine), bot frameworks
  (astrbot), and the obscure/unverified remainder of the vercel-labs list.
- Configuring the free evergreen providers on the non-omp harnesses (needs the
  user to add them to each harness first).
- Removing/recapturing existing closed-model fixtures; `from-capture` sweeps.
