# ollamacloud individuation, paid-only blocklist, free-model refresh, and the zcode + free regeneration

## Where we left off

The last plan (`.plans/1788916141-posture-setting-model-training.md`) is **implemented** — phases A/B/C landed as `a9b0f89`/`064fb88`/`f82b43a`. Its "What this plan does not do" section names the unfinished threads this session picks up: the ollama `:cloud` individuation (DESIGN #15 — "re-individuate before the next large ollama sweep"), plus the blocklist/free-model refresh and the fixture regeneration. New directives: split `ollama` → `ollama` (local) + `ollama-cloud` (cloud, slug `ollamacloud`); rename-but-don't-rewrite the fixtures; make the blocklist paid-only and add `clinepass` + `ollamacloud`; refresh free models everywhere (recent free push); then regenerate **zcode + all free models**, plus a **full ollamacloud sweep** (user-confirmed), with **from-capture upgrades** where invocations of record exist (user-confirmed).

## Phase 0 — the plan files

Write `.plans/<ts>-ollamacloud-blocklist-free-regen.md` + `.prompts.md` per `plans.md` (house style, `Assisted-by` trailer via `./zig-out/bin/agent-detect trailer assisted-by`). Land with the docs commit.

## Phase A — the ollama / ollama-cloud individuation (DESIGN #15 executed)

Both recorded discriminators go live; the `local` umbrella idea stays deferred (no second local runtime observed).

1. **`src/lib/rules.zig`** — new `ProviderRule` `.name = "ollama-cloud"`, label `Ollama Cloud`, training `never/never` (cloud = transient processing, never trains; sources ollama.com/privacy + terms), no scandal; comment absorbs the retired pre-fold rule name. The `ollama` rule drops its `ollama-cloud` variation (its slug `ollamacloud` must not match two rules) and its comment rewrites: local runtime only, fold flaw resolved, zero fixtures.
2. **`src/lib/core.zig`** — `providerHostFold`: `ollama.com` → `ollama-cloud` (was `ollama`); `inference.phala.com` unchanged. New cross-dim post-pass after provider+model resolution: provider `ollama` ∧ raw model spelling carries `:cloud` → provider re-resolves `ollama-cloud` (covers zcode's localhost:11434 custom provider serving `:cloud` models). Model rules keep their `:cloud` variations.
3. **Fixture renames — content untouched** (DESIGN #16 + directive): `git mv` all **129** stems `-ollama-` → `-ollamacloud-` (116 from-identity + 13 from-capture; every observed fixture is cloud traffic).
4. **`fixtures/index.json`** — re-key the 32 `invocations` keys and 18 `known_but_failed` keys; re-key the 2 queue entries' provider dim (`ollama` → `ollamacloud`). Argv strings inside entries stay (historical launch commands).
5. **Grids** — `map-harness-provider`: zcode row's `ollama` cell moves to the cloud rule (kilo/omp/opencode `ollamacloud` cells and hermes `ollama-cloud` cell already resolve to it); `map-provider-model`: row key `ollama` → `ollama-cloud`, cells unchanged (all cloud-catalog launch ids); no local `ollama` row remains. Confirm cell semantics against the grid reader (`dev.zig:741–783`) while editing.
6. **Tests** — `known_fixtures.test.zig`: combo-match test gains a rename-transition allowance (provider segment `ollamacloud` with content `provider_id: "ollama"` → **warn, not fail**, with the queue nudge — the unverified-harness_license warning is the precedent; drop it when zero warnings remain); `rule_only_providers` += `ollama`; `isLegacyCrossChannel` stem re-keys to `hermes-ollamacloud-glm53flash-darwin`; stem-dim name-match is satisfied by name `ollama-cloud`. `exit_statuses.test.zig` / `index_store.test.zig`: cover the `:cloud` flip and the new host-fold target.
7. **Docs** — DESIGN #15 marked executed (both discriminators live; umbrella deferred); CONTRIBUTING fold-doctrine line, hermes/phala section notes updated.
8. Build + `zig build test`, commit: `core: the ollama/ollama-cloud individuation (DESIGN #15) — rules, detectors, renames, store, grids`.

## Phase B — the paid-only blocklist

The blocklist today blocks the **whole** provider (`dev.zig:1394`/`1441` run before the free-axis check; capture refusal `dev.zig:2067–2082` is unconditional). Per the directive it blocks **only paid models**: free-grid combos of a blocked provider stay eligible.

1. **`src/dev/dev.zig`** — all three gates become `blocked(provider) ∧ !FreeGrid.has(provider, model)`; the capture path loads the FreeGrid.
2. **`fixtures/index.json`** — `blocklist.balupton.providers` += `clinepass`, `ollamacloud` (strict slugs; alongside `chutes`, `opencodego`, `deepseek`, `hyper`).
3. **`fixtures/index.d.ts` + DESIGN.md** blocklist paragraphs rewritten to paid-only semantics.
4. `index_store.test.zig`: exclusion test gains the free-exemption case. Commit: `store: the paid-only blocklist semantics and the clinepass + ollamacloud entries`.

## Phase C — the free-model refresh (research)

Follow the CONTRIBUTING probing runbook (lines ~168–230): for `clinepass, opencode, openrouter, zenmux, nvidia, vercel` + new `ollamacloud`, cross-check current catalogs (OpenRouter `/api/v1/models`, harness catalogs, evergreen snapshot curls, web search for the recent free push). Update `fixtures/map-provider-model-freeprovidermodel.csv` (sparse; slugs must resolve to rules); new free models without rules get new `ModelRule`s (license/openness research per the rule-writing sections) + `map-provider-model` cells so combos are feasible; add the `ollamacloud` row if it has free models. **Watch the free-signal test** (`known_fixtures.test.zig:932`): a free-listed combo with an existing from-capture must carry `free` in its launch id — existing ollama captures launch `ollama-cloud/<model>` with no free signal, so only list models that are genuinely free (or leave until re-capture). Commits: `rules:` (any new model rules), then the grid.

## Phase D — regeneration: zcode + all free models + the full ollamacloud sweep

`--stale-by-output` cannot see the rename (it compares identity↔capture channels, which still agree), so the queues use **`--refresh`**:

1. Queue (re-asserting identical flags per dedupe rules):
   - `fixtures queue --harness=zcode --refresh --from-identity` (the 6 zcode fixtures, incl. the renamed zcode-ollamacloud pair)
   - `fixtures queue --provider=ollamacloud --refresh --from-identity` (full sweep — all 129 renamed files; also mints feasible-unfixtured grid combos, zero-token, same as the earlier zcode sweep minted its six)
   - per free provider: `fixtures queue --provider=<p> --free --refresh --from-identity`
   - capture upgrades: `fixtures queue --provider=<p> --free --refresh --from-capture` (invocation-of-record combos only; zcode has none — from-identity only)
2. **User runs the daemon per host** (never inside the agent): `zig build dev && ./zig-out/bin/agent-detect-dev fixtures daemon --write-log` — linux here; darwin/windows on the other hosts later (each daemon drains only its platform, `dev.zig:2975`).
3. Review landed batches (`fixtures status`, `daemon.log`, backlog), commit per batch as they land: `fixtures: the zcode + free-model + ollamacloud regeneration`; burn the combo-match allowance down as warnings reach zero, then drop it.

## Verification & risks

- `zig build && zig build test` green at every commit; generated co-author trailer per `commits.md`.
- The interim combo-match warnings are by design (DESIGN #16) and burn down as daemons drain.
- New free models may need model-rule research (bounded by the runbook); the free-signal/old-capture conflict is checked before listing.
- zcode from-capture stays impossible until an invocation of record is authored (out of scope).
- Harness config/auth files are never touched (AGENTS.md hard rule) — the daemon/capture flow is read-only on `~/.zcode/`.