Assisted-by: ZCode · GLM 5.3 <zcode-zcode-glm53@local>
(provenance companion: [1788716755355-provider-fold-individuation-review.prompts.md](./1788716755355-provider-fold-individuation-review.prompts.md))

# Provider fold / individuation review — commits 506a5f0 (hermes) + 327922a (autoclaw)

Status: **executed 2026-09-07** (D1–D8 + B1–B10 landed in the working
tree after maintainer ratification; D3 executed with the maintainer's
addendum — all prior ollama fixtures were cloud traffic and migrated
with the fold; the hermes/autoclaw queue entries were dropped per the
maintainer's uninstall — the harness rules stand at contributor scope;
counts removed from CONTRIBUTING per "don't do counts that will
drift"; the `phala` provider rule + zcode custom-provider baseUrl fold
added for the maintainer's new session provider; comment
single-sourcing applied across the touched rules). D9 (the wrap
cascade) remains grandfather-and-write-new-unwrapped. The upstream
conventions change landed separately as bevry-vibes/skills a219384.

Second pass (2026-09-07, commit 62034fc): the recorded follow-ups
worked — autoclaw's harness postures sourced (opt-out/opt-out from
the AutoClaw privacy policy's legitimate-interests training + objection
right — the exit-9 treadmill resolved); opencode zen sourced
(opt-in/opt-in from the same docs/zen statement the go rule cites —
null was never honest, the page carried the answer); arcee's closed
axis resolved to the documented vacuous never (exclusively open); zcode
+ cloudflare audits attempted and honestly inconclusive (JS-dead /
DPA-silent — comments record the attempts); the known_but_failed table
re-keyed to the folded ids (missed by the rename pass); the two zcode
config readers merged into one read. Still open: the cloudflare
service-specific-terms wording (needs a JS-capable read), zcode's
static postures (instance read covers live sessions), the ollama
individuation before any new ollama sweep, and the contributor-scope
hermes/autoclaw fixture sweeps.

Scope: a holistic review of the harness/model/provider rules those two
commits added or refreshed, their grids, fixtures, detectors, and docs —
folding vs individuation decided against the external indexes rather
than any single harness's perception, per the maintainer's directive.

## Method — the indexes consulted

- **models.dev** (live `GET https://models.dev/api.json`, 213 provider
  keys) — the primary provider-identity index. Key results used below:
  `moonshotai` (api.moonshot.ai) beside `kimi-for-coding`
  (api.kimi.com/coding/v1); `kilo` "Kilo Gateway"; `nebius` "Nebius
  Token Factory"; `opencode` "OpenCode Zen" beside `opencode-go`;
  `ollama-cloud` (no local `ollama`); `lmstudio` (exists — relevant to
  the local-provider discernment); `google` beside `google-vertex` (and
  a third `google-vertex-anthropic`); `cloudflare-workers-ai` beside
  `cloudflare-ai-gateway`; `zai` beside `zai-coding-plan` /
  `zhipuai-coding-plan`; `alibaba` beside `alibaba-coding-plan`
  (+cn/token-plan mirrors); `stepfun` "StepFun (China)" beside
  `stepfun-ai` (Global) and the `*-step-plan` coding surfaces.
- **OpenRouter** — the committed providers snapshot
  (`fixtures/evergreen-providers.json`: `moonshotai`, `z-ai`,
  `amazon-bedrock`, `azure`, `google-ai-studio` + `google-vertex`,
  `cloudflare`, `ollama`, `stepfun`, `nebius`, …) and the live models
  API (confirms `z-ai/glm-5-turbo` exists).
- **Hermes's own surfaces** (read-only): `~/.hermes/models_dev_cache.json`
  (hermes's models.dev mirror) and the packaged
  `plugins/model-providers/` catalog (39 profiles with `name` +
  `aliases` + `base_url`) — the authoritative source of hermes's
  provider-key spellings (`gemini`, `vertex`, `bedrock`, `kimi-coding`,
  `nebius-token-factory`, `kilocode`, `ai-gateway`, `qwen-oauth`, …).
- **The kimi-code CLI package** (`dist/main.mjs` endpoint strings):
  `api.moonshot.ai/v1` / `api.moonshot.cn/v1` beside
  `api.kimi.com/coding/v1` / `api.kimi.ai/coding/v1` — the CLI itself
  talks to BOTH Kimi/Moonshot surfaces, which is what disambiguates
  its two provider keys.
- **Live policy pages** — ollama.com/privacy and
  ai.google.dev/gemini-api/terms re-verified during this review (quotes
  below); the remaining ~22 providers re-verified by a dedicated
  research pass (section I).
- **Repo state**: rule tables, both feasibility grids + the free axis,
  `fixtures/index.json` (queue/invocations), fixture inventory, the
  detectors, and the contract test.

A sizeable structural fact frames everything below: **the hermes
from-identity + from-capture sweeps and the autoclaw from-identity
entry are still queued** (6 store entries; zero `hermes-*` from-identity
fixtures exist yet). Every fold/fix landed BEFORE the user drains the
daemon avoids hermes-side fixture churn entirely — the sweep will
declare under the corrected ids.

## A. Verdict summary

| family | today | verdict |
| --- | --- | --- |
| moonshot + kimi + kimi-code + kimi-coding + kimi-coding-cn (5 rules) | over-split + one conflation | **fold to 2 rules**: `moonshotai` + `kimi-coding` (D1, D2) |
| ollama + ollama-cloud (2 rules) | over-split per directive | **fold to `ollama`** now, individuation designed + deferred (D3) |
| opencode + opencode-free + opencode-zen + opencode-go (4 rules) | one duplicate pair | **fold free+zen into `opencode`** → 2 rules (D4) |
| google vs google-vertex | individuated | **keep**; do NOT rename to google-gemini (D5) |
| cloudflare-workers-ai | ruled, null/null policy | keep name (models.dev concurs); policy audit follow-up; `cloudflare-ai-gateway` known-unruled (D6) |
| zai / zcode / autoclaw | individuated by harness bundle | keep — models.dev's `zai` vs `zai-coding-plan`/`zhipuai-coding-plan` concurs |
| alibaba / qwen / alibaba-coding-plan | individuated by policy | keep (Model Studio never vs qwen.ai opt-in) |
| everything else added by the two commits | — | names + variations index-consistent; mechanical fixes only (section B) |

## B. Bugs and mechanical fixes (do regardless of fold decisions)

1. **Duplicate provider rules.** `google-vertex`, `amazon-bedrock`,
   `azure-foundry` are each declared TWICE in `rulesForProviders`
   (`src/lib/rules.zig:760/765/772` and `788/793/800`) — the hermes
   commit added the same three rules in two places. Resolution is
   first-match so behavior is accidentally right, but it is table
   corruption and double maintenance. Delete the second set.
2. **`kilocode` does not resolve.** Hermes's kilo profile is
   `name="kilocode", aliases=("kilo-code","kilo","kilo-gateway"),
   base_url=https://api.kilo.ai/api/gateway` — the same surface the
   `kilo` provider rule covers (models.dev key `kilo`, "Kilo Gateway").
   The hermes commit grid-recorded the surface (harnessprovider hermes
   cell + a full providermodel `kilocode` row) but added no rule or
   variation, so a live hermes session on that profile reports a raw
   unruled provider id with no policy (and any capture post-check
   mismatches). Fix: variations on the `kilo` rule
   (`kilo-code`, `Kilo Gateway` — slugs `kilocode`/`kilogateway`) and
   merge the `kilocode` grid row/column into `kilo`. (This mirrors what
   the same commit did correctly for `meta-ai` → variation on `meta`.)
3. **`nebius-token-factory` does not resolve.** Hermes's nebius profile
   key is `nebius-token-factory` (models.dev key `nebius`, name
   "Nebius Token Factory"). Fix: relabel the `nebius` rule
   "Nebius Token Factory" (the label slug `nebiustokenfactory` then
   resolves hermes's key natively — labels are id-safe:
   `provider_id` slugs the rule `name`, not the label), or add an
   explicit variation.
4. **Dead harnessprovider cells.** `nous`, `kimi-coding`,
   `kimi-coding-cn`, `openai-codex` have hermes cells but NO
   providermodel rows, so no (provider × model) pair is feasible for
   them — the cells can never produce candidates. `kimi-coding`
   deserves a real row (its catalog is kimi-k3 via the `k3` alias — see
   5); `openai-codex` serves the gpt-5.x-codex family (ruled models);
   `nous` serves the Hermes model family (none ruled — its cell is
   future-signal only; annotate or drop). Also: CONTRIBUTING's hermes
   verdict says "kimi-coding … recorded only ruled ids" — no such row
   exists; the verdict text and the grid disagree.
5. **`k3` model alias does not resolve.** The providermodel `kimicode`
   row records the served spelling `kimi-code/k3`; the namespace strip
   yields `k3`, which matches nothing (`kimi-k3`'s slug is `kimik3`).
   A live session on the Kimi-for-Coding surface reporting `k3` lands a
   raw model id. Fix: variation `k3` on the `kimi-k3` model rule
   (models.dev's `kimi-for-coding` catalog is exactly `k3`,
   `k3-256k`, `kimi-for-coding(-highspeed)` — the short-alias dialect
   of that endpoint).
6. **Ragged harnessprovider rows.** 15 pre-existing harness rows carry
   41 fields against the 62-column header (the two commits appended
   columns but only padded the rows they touched; providermodel was
   padded fully — inconsistent). `loadPairGrid` tolerates short rows
   (it breaks at the row's end), and the missing trailing cells are all
   `-`-semantics, so this is hygiene, not corruption. Pad all rows to
   header length.
7. **Doc-count drift in CONTRIBUTING's hermes verdict.** "17 new
   provider rules" — actually 19 deliberate additions (kimi-coding,
   kimi-coding-cn, alibaba-coding-plan, opencode-free, opencode-zen,
   openai-codex, google-vertex, amazon-bedrock, azure-foundry,
   novita-ai, deepinfra, nebius, nvidia, upstage, xiaomi, stepfun,
   arcee, vercel, nous) plus the 3 accidental duplicates. "hermes row
   (35 providers)" — 34 distinct surfaces (the `opencode-free` key
   fills two columns). Correct the text when the folds land.
8. **pi × kimi grid cell carries the wrong spelling.** The cell says
   `kimi`, but pi's actual provider key is `moonshotai` (that is why
   `piProviderCanonical` special-cases it). Cells are supposed to carry
   the harness's own spelling. Correct it alongside D1.
9. **autoclaw harness training postures null/null.** AutoClaw is
   `license "NONE"` with no instance read and no sourced postures, so
   every autoclaw `check-reciprocal` exits 9 (data-incomplete) — an
   exit-9 treadmill on the maintainer's daily driver. zcode shares the
   null static state but has the `optimizeAgentExperienceEnabled`
   instance read. Follow-up: research the AutoClaw agreement
   (already cited as a license source) for any conversation-data-use
   language; if it is silent, null is the honest state and the exit-9
   nudge is working as designed — but that should be a documented
   decision, not an accident.
10. **DESIGN.md's "the ladder's exact steps live in the doc block above
    `pub fn detect`" is stale** — no such doc block exists (the ladder
    is documented inline; `resolveRecipe`'s doc block is the nearest
    thing). Pre-existing drift; fix the pointer whenever convenient.

Verified-correct claims from the commits (no action): glm-5-turbo
individuation (models.dev `zai.glm-5-turbo` carries `open_weights:
false`; no `zai-org` weights on HF (author-search returns `[]` while
GLM-5.x weights exist); OpenRouter lists `z-ai/glm-5-turbo`; a distinct
license from the open glm-5 line means it can never fold — the
individuation is exactly right); evergreen gating of gpt-oss-20b,
laguna-s-2.1, laguna-xs-2.1 (all present in the tracked snapshot;
laguna-m1 absent); the free-axis nvidia/vercel rows and the
`laguna-s-2.1-free` cell; `openclaw` in `pending_binary_names`;
AUTOCLAW_* env markers with the URL-valued ones deliberately excluded
from the value allowlist; the tdpsk_/zaicoding_/zai_ channel-spelling
variation folds; the deliberate non-ruling of zai_auto/zai_auto-fast.

## C. The Kimi/Moonshot family — five rules are two surfaces (D1, D2)

The indexes individuate TWO providers here, and neither is what our
five rules say:

- **Moonshot AI API** — `api.moonshot.ai/v1` (intl) / `api.moonshot.cn`
  (CN). models.dev `moonshotai` (+`moonshotai-cn`); OpenRouter slug
  `moonshotai`; HF org `moonshotai`. Model dialect: full ids
  (`kimi-k2.6`, `kimi-k2.7-code`, `kimi-k3`). Our `moonshot` rule is
  this surface (dormant — zero fixtures, no grid row); our `kimi` rule
  is ALSO mostly this surface (pi's `moonshotai` key, canonicalized by
  the `piProviderCanonical` special case; and the kimi-code CLI's `kimi`
  provider key, which serves the full-id dialect — the CLI's dist talks
  to api.moonshot.ai).
- **Kimi for Coding** — `api.kimi.com/coding/v1` (intl) /
  `api.kimi.ai/coding` (CN): the subscription product. models.dev
  `kimi-for-coding`; hermes profile `kimi-coding` (+`kimi-coding-cn`).
  Model dialect: short aliases (`k3`, `k3-256k`,
  `kimi-for-coding-highspeed`). Our `kimi-code` rule is this surface
  (the CLI's subscription key, serving `k3`), as are `kimi-coding` and
  `kimi-coding-cn`.

So "kimi and moonshot could be folded" is half right: they are not one
thing, they are two — but our five rules collapse onto those two with
one conflation removed (the `kimi` rule currently straddles both).

**D1 — fold `moonshot` + `kimi` into one rule named `moonshotai`**
(label "Moonshot AI"), variations `moonshot`, `kimi`, `moonshotai-cn`
(+`moonshot-cn` if observed). Rationale: `moonshotai` is the id every
index uses (models.dev key, OpenRouter slug, HF org, the API domain);
the `kimi` name actively misleads once the subscription surface is
individuated (Kimi is the product brand, not the API provider).
`piProviderCanonical`'s special case deletes itself (pi's key resolves
natively). Churn: 16 from-identity files (`kimicode-kimi-*`,
`pi-kimi-*`) + 2 from-capture files rename to `*-moonshotai-*`, the pi
grid cell corrects to `moonshotai`, grids merge.
*Zero-churn alternative (rejected):* keep the name `kimi` and add
variations — saves 18 renames but perpetuates a name no index uses and
inverts the brand. Flagged for the maintainer in case churn matters
more than naming.

**D2 — fold `kimi-code` + `kimi-coding` + `kimi-coding-cn` into one
rule named `kimi-coding`** (label "Kimi for Coding"), variations
`kimi-code`, `kimi-for-coding`, `kimi-coding-cn`. Rationale: hermes's
live key names the rule (harness-config convention); it is the closest
of the three spellings to models.dev's `kimi-for-coding`; zero fixture
churn on the surviving name; and it avoids the `kimicode` provider slug
colliding cosmetically with the `kimicode` harness segment in fixture
ids (`kimicode-kimicode-k3-darwin`). Churn: the 2
`omp-kimicode-kimik3-*` from-identity files rename to
`omp-kimicoding-*`; grids merge. The CN spelling folds as a variation
(regional mirrors get rules only when their policy actually diverges —
same policy family, same docs).

Both folds ride the option-B retroactive-fold mechanics
(`.plans/1787978000867-retroactive-folding-options.md`, executed
2026-08-29): delete the folded rules, add the variations, rename the
fixture files, merge the grid rows/columns, rename the
`invocations`-table keys (`kimicode-kimi-kimik3-darwin`,
`pi-kimi-kimik3-darwin`, `omp-kimicode-kimik3-*`), shrink the
`rule_only_providers` exemptions (post-fold every surviving name has
stems), and re-run the daemon's `--repair` + a from-identity sweep to
regenerate the declared channels. The two from-capture files carry live
evidence — rename + re-derive their identify blocks, or let the next
natural re-capture refresh them.

## D. ollama / ollama-cloud — fold now, individuation designed (D3)

**D3 — fold `ollama-cloud` into `ollama`** (variation `ollama-cloud`),
per the maintainer's standing directive. Both postures are never/never,
re-verified live during this review (ollama.com/privacy: "When using
cloud-hosted models, we process your prompts and responses transiently
to provide the service and never train on it"; "We do not use your
inputs or outputs to train any AI models"; local models: nothing
leaves the machine). models.dev individuates (`ollama-cloud`), OpenRouter
does not (slug `ollama` for the cloud service) — the indexes disagree,
the policy values agree, and the boundary is already unreliable in the
wild (below), so one rule is the honest current state. Churn: 114
from-identity files (kilo 38 / omp 38 / opencode 38) + 1 from-capture
(`hermes-ollamacloud-glm53flash-darwin`) + 38 invocations-table keys +
grid merges (the `ollamacloud` column's four occupants and the
providermodel row's ~19 cells fold into `ollama`). Preserve the KNOWN
FOLD FLAW comment.

**The deferred individuation — what it involves** (do before the next
large ollama sweep to avoid double churn):

- *Discriminator 1 — the `:cloud` model suffix.* Sessions whose provider
  resolves to `ollama` but whose raw model spelling ends in `:cloud`
  (observed: ZCode's custom provider named `ollama` serving
  `glm-5.3-flash:cloud`; the committed `zcode-ollama-glm53flash-*`
  fixtures are exactly this cloud traffic) are ollama-cloud sessions.
  Implementation: a detector-level post-pass — `applyProviderMeta` is
  spelling-only and cannot see the model dim; the cross-dim inference
  (provider resolves `ollama` ∧ model spelling carries `:cloud` →
  re-resolve provider to `ollama-cloud`) belongs beside the
  `setProvider`/`applyModel` calls in the harness detectors, or as a
  shared pass after both dims land. The `:cloud` spellings then move
  from the model rules' variation lists to wherever the individuated
  surface records them, and the `ollama` providermodel row's
  `:cloud`-suffixed cells re-home to the `ollama-cloud` row.
- *Discriminator 2 — the provider baseUrl (stronger).* ollama.com/v1 IS
  the cloud API; a local runtime is localhost/LAN. The autoclaw
  commit's baseUrl fold (`models.providers[key].baseUrl` → surface) is
  the exact precedent: detectZcode should fold a custom provider named
  `ollama` on an `ollama.com` baseUrl to the cloud surface, keeping
  `ollama` for local endpoints. This catches cloud traffic even when
  the model id lacks the suffix.
- *Policy semantics:* local = nothing leaves the machine (the vendor's
  cloud/account policy is simply out of scope); cloud = transient
  third-party processing per ollama.com/privacy. Both `never` today —
  the individuation is semantic honesty plus insurance against future
  policy divergence, not a current reciprocity difference.
- *The `local` umbrella (future discernment, recorded):* all local
  runtimes serving non-cloud models (ollama, lmstudio, llama.cpp
  servers — models.dev already carries `lmstudio` as a provider key)
  may want a shared `local` provider rule with a "nothing leaves the
  machine" posture. Caveats recorded from the directive: local surfaces
  still carry their own vendor policies (telemetry, crash reports —
  ollama's own privacy policy covers its account services), and a
  local runtime can still be configured to proxy cloud endpoints, so
  the umbrella would need the same baseUrl/suffix discriminators. Do
  not build until at least one more local runtime is actually observed
  in a session.

**`:cloud` mis-individuation audit (asked for): clean.** Exactly one
model rule carries a `:cloud` spelling — `glm-5.3-flash`'s variation
`glm-5.3-flash:cloud` — and it is correctly a variation, not a rule.
No model was individuated on a `:cloud` id. The only `:cloud` data
outside that variation is the `ollama` providermodel row's
`glm-5.3-flash:cloud` cell, which is the documented fold flaw, not a
mis-individuation. (`:size` tags need no variations — `slugEquals`
strips the colon, so `gpt-oss:120b` / `gemma4:31b` resolve naturally;
verified.)

## E. The opencode family — two surfaces, four rules (D4)

models.dev individuates exactly two: `opencode` ("OpenCode Zen") and
`opencode-go`. Hermes's two profiles `opencode-free` and `opencode-zen`
are the KEYLESS and SUBSCRIBED tiers of the SAME relay
(`https://opencode.ai/zen/v1` — the free profile's own docstring says
so, and its Ox Alpha model is reachable through both), with identical
catalogs in our providermodel grid and identical null policies. The
pre-existing `opencode` rule already covers the relay (its grid row
records `opencode/nemotron-3-ultra-free`).

**D4 — fold `opencode-free` + `opencode-zen` into `opencode`**
(variations `opencode-free`, `opencode-zen`; label "OpenCode Zen" per
models.dev, which also disambiguates from the `opencode` HARNESS).
Free-vs-paid is a tier distinction and rides model-id spellings
(`-free` suffixes), exactly like OpenRouter's `:free` tiers per DESIGN
#13. Zero fixture churn if executed before the staged hermes sweep
drains — otherwise the sweep would mint `hermes-opencodefree-*` /
`hermes-opencodezen-*` stems that immediately rename. Grid: the two
columns/rows merge into `opencode` (the hermes row's duplicate
`opencode-free` cells collapse; the merged providermodel row is the
union — the full zen catalog plus the `opencode/nemotron-3-ultra-free`
spelling). `opencode-go` stays (a genuinely different subscription
with a different catalog and a sourced opt-in posture). Follow-up:
the zen relay's own training policy is still null/null — research
`https://opencode.ai/docs/zen` for a data-use statement.

## F. google — keep `google`, keep the split (D5)

**D5 — no rename to `google-gemini`.** `google` is what every index and
harness calls the Gemini API surface: models.dev key `google`, OpenRouter
endpoint slugs `google`/`google-ai-studio`, kilo/crush/opencode org-style
`google/gemini-*`, hermes's `gemini` key already folded via variation.
`google-gemini` would diverge from all of them. The individuation from
`google-vertex` is correct and policy-load-bearing, re-verified live
during this review: the Gemini API terms put UNPAID services
(AI Studio / free-tier quota) into "provide, improve, and develop
Google products … and machine learning technologies" while paid
services are excluded — opt-in under the opt-in-by-model rule; Vertex's
Service Specific Terms Training Restriction ("Google will not use
Customer Data to train or fine-tune any AI/ML models without Customer's
prior permission") is never. Known-unruled third surface to record:
`google-vertex-anthropic` (Vertex-served Anthropic models, separate
billing) — add when any harness is observed reaching it.
`google-antigravity` stays as the bundled harness surface it is.

## G. cloudflare (D6)

models.dev individuates `cloudflare-workers-ai` and
`cloudflare-ai-gateway` — our `cloudflare-workers-ai` rule name matches
exactly (pi reaches it; hermes has no cloudflare profile at all), so no
rename. `cloudflare-ai-gateway` is a known-but-unruled surface: record
it in the catalog-inference verdicts and add a rule only when a harness
is observed reaching it. Follow-up: the workers-ai rule's training
values are null/null with a comment claiming "Cloudflare trains on
nothing per its commercial terms" — that is a maintainer audit away
from never/never; it was out of the hermes commit's scope (not
hermes-reachable) but should be closed with the next policy sweep.

## H. Training-policy double-check (research pass)

Every posture the two commits set was independently re-verified against
the live policy pages (24 providers; a dedicated research pass — the
verifier's full evidence table with per-provider verbatim quotes is
preserved in this session's record; the operative outcomes below).
Five rules carry wrong values (D8); the rest confirm, several with
comment-level nuances. The verification predates nothing — all quotes
were fetched live on 2026-09-07.

**D7 — axis semantics convention (proposed, needs ratification):**

1. A policy that does not distinguish which model types it trains
   (the common case) applies its value to BOTH axes — mirrored values
   are the default, not an accident.
2. An exclusively closed-model company (serves no open-weight models)
   keeps the open axis `null` (not applicable) — the existing
   precedent: `anthropic` (closed `never`, open `null`) and
   `github-copilot` (closed `opt-out`, open `null`, comment says
   exactly this). xai and openai-codex belong here too (open weights
   exist on HF but are not served on the API surface the rule covers —
   comment, don't set).
3. An exclusively open-model company (serves no closed models) CANNOT
   use `null` on the closed axis — `provider_closed_training` null is
   load-bearing (exit 9 data-incomplete) and would break
   check-reciprocal for open-model sessions. Candidate: closed `never`
   as a commented vacuous truth ("they serve no closed models to
   train"). **Now concrete:** `xiaomi` (MiMo open weights, HF
   XiaomiMiMo, no closed weights found) and `arcee` (exclusively
   open-weight producer so far) are the first two rules this applies
   to. Flagged for the maintainer.
4. Tiered policies (free tier trains / paid doesn't; unpaid instances
   train / paid don't) resolve to the strictest REACHABLE surface —
   the existing opt-in-by-model rule, restated.

**D8 — training-value corrections (the research pass; five rules carry
wrong values, all with live verbatim evidence):**

| rule | today | corrected | evidence (live, verbatim) |
| --- | --- | --- | --- |
| `nvidia` | never/never | **enforced/enforced** (conservative floor: opt-out) | API Trial Terms §3.3 (assets.ngc.nvidia.com/products/api-catalog/legal/…): "NVIDIA will collect … (iv) User Content and Generated Content to improve NVIDIA products and services, including AI models" — default-on, no opt-out anywhere in the live doc. The claimed §2.2/2.3 clauses exist but §3.3 overrides them for the trial tier — the reachable free surface. **Reciprocity impact: enforced fails the conjunct — every kilo/pi nvidia combo becomes not-reciprocal; the free-axis row stays (free ≠ reciprocal).** |
| `qwen` | opt-in/opt-in | **enforced/enforced** (fallback opt-out if a UI toggle is ever found) | qwen.ai/termsservice: "You hereby expressly authorise and consent to us: (i) using and storing User Content that is not personal data to develop and improve our machine-learning … technologies" — a mandatory standing grant, no training opt-out in the terms or privacy policy. |
| `zai` (and the `zcode`/`autoclaw` mirrors) | closed opt-out / open null | **opt-in/opt-in** | docs.z.ai/legal-agreement/terms-of-use: "We will not use End User Content to develop or improve Services, unless you explicitly agree to such use" — training OFF by default, enabled only by explicit agreement = opt-in in the project vocabulary (the hermes session misread it as an "agreement-level opt-out"). Ambiguous over model types + Z.ai serves both open (HF zai-org) and closed → both axes. Cascade: `zcode` and `autoclaw` mirror zai and flip with it. |
| `nebius` | opt-in/opt-in | **opt-out/opt-out** | Token Factory ToS §7: speculative-decoding draft-model training is on by default AND "You may opt out at any time" (onboarding form / support email) — the hermes session missed the documented opt-out. Comment: only draft models are trained, not the served target models. |
| `xiaomi` | opt-in/opt-in | **never/never** (API surface) — or opt-out if the rule is meant to cover the desktop app | MiMo open-platform privacy policy (privacy.mi.com/XiaomiMiMoPlatformos/en_GB/): "Xiaomi will not use the content you provide for model training or any other purposes" — the surface hermes actually reaches. The current sources cite the DESKTOP app's policy (default-on training, opt-out via Experience Optimization Plan). Decision needed: which surface the rule covers (recommend: the API surface, per the harness-reachability doctrine; keep the desktop wording as a comment). Plus the D7.3 closed-axis flag. |

**Confirmed as claimed (value stands):** alibaba (never/never verbatim,
Model Studio), google-vertex (Training Restriction §18), azure-foundry
(both pages verbatim), novita-ai (ToS §10.2 + trust FAQ), deepinfra
(ToS §7b + "We do not train on your data"), upstage (API never — see
nuance), stepfun (program-gated, off by default = opt-in), arcee
(unpaid trains/opt-out, paid never), vercel (own ZDR never — see
nuance), nous (Privacy Mode, default off = opt-out), openai-codex
(consumer opt-out verbatim), github-copilot (Individual opt-out /
Business never verbatim), moonshot-family (the three-document conflict
is genuine and current — NOASSERTION stands), gmi-cloud (inconclusive
verified; null stands), google + ollama (re-verified directly during
this review).

**Comment-level nuances to fold into the rule comments (no value
change):**

- `xai`: enterprise/API = off-by-default (stricter than the recorded
  opt-out); consumer = opt-out; logged-out free usage = enforced
  (unreachable via API key — comment only). Open axis stays null with
  the closed-company comment.
- `amazon-bedrock`: the cited docs URLs no longer carry the claimed
  sentence; the live equivalent is on the product page ("Amazon Bedrock
  never shares your data with model providers or uses it to train
  foundation models") — update the evidence URL. New Claude
  Fable 5/5.1 carve-out: 30-day prompt retention for provider-required
  human review (not training) — worth a comment.
- `vercel`: Vercel's own handling is ZDR-never, but "By default, AI
  Gateway does not route based on the data retention policy of
  providers" and `disallowPromptTraining: true` is opt-in (free) —
  comment that downstream providers may train unless the flag/ZDR
  (Pro/Enterprise) is on.
- `huggingface`: the never covers HF's routing layer; the inference
  provider behind the request has its own policy — comment.
- `upstage`: API never confirmed; Console Playground conversation
  content is used "to improve and develop our Services and conduct
  research" — if the project counts service-improvement research as
  training, the free Playground surface pushes to opt-in. Decision
  (recommend: keep never on the API surface, comment the Playground).
- `moonshot`/`kimi-coding` (post-D1/D2 names): if ever forced off
  NOASSERTION, the strictest documented posture is opt-out (the terms).

## I. Execution plan (ordered, after ratification)

1. **Before anything else:** land the mechanical fixes (B1–B8) and the
   folds (D1–D4) — the staged hermes/autoclaw queue entries must NOT be
   drained until the rule tables are final, or the sweep mints ids that
   immediately churn.
2. B-mechanics: delete the duplicate rules; add the `kilo`/`nebius`
   alias fixes; add the `k3` model variation; add the missing
   providermodel rows (kimi-coding, openai-codex) or annotate the dead
   cells; pad the ragged grid rows.
2b. D7/D8: apply the training-value corrections (nvidia, qwen,
   zai + the zcode/autoclaw mirrors, nebius, xiaomi — plus the
   comment-level nuances and the updated bedrock evidence URL) and
   record the axis-semantics convention in CONTRIBUTING's provider-rule
   guidance. Also pre-drain is the right time: the hermes from-identity
   sweep will emit the corrected values into ~hundreds of declared
   fixtures.
3. D-folds via the option-B mechanics (delete folded rules → add
   variations → rename fixtures/invocations → merge grids → shrink
   exemptions → `zig build test` → `fixtures status`).
4. Update CONTRIBUTING's hermes/autoclaw verdicts (counts corrected,
   the fold outcomes recorded, `cloudflare-ai-gateway` +
   `google-vertex-anthropic` + `lmstudio` recorded as known-unruled
   surfaces, the kimi family re-verified against models.dev).
5. The user drains the daemon; review the declared hermes/autoclaw
   fixtures as they land.
6. Follow-ups, in priority order: autoclaw/zcode harness training
   research (B9); cloudflare-workers-ai policy audit (D6); opencode zen
   policy research (E); the ollama individuation implementation
   (section D) before any new ollama sweep; the `local`-provider
   discernment (one more local runtime observed); the D7 ratification
   applied to any rule the research pass flagged.

## J. Upstream conventions change (landed during this review)

The upstream bevry-vibes `conventions.md` now forbids hard line/word
wraps — one paragraph per line, viewers soft-wrap; the same rationale
as tabs over spaces (agents author at different column policies, fixed
widths are diff churn, a sentence stays greppable only while it is one
line). Landed as bevry-vibes/skills `a219384` (the file itself
unwrapped to practice the rule).

**D10 — individuation-granularity doctrine (maintainer clarification,
2026-09-07, recorded in CONTRIBUTING "Individuation granularity").**
The indexes are inputs for identity resolution, never authorities on
granularity: models.dev individuates regional mirrors, tier surfaces
(zen free/paid/go), and endpoint variants because its job is
configuration — a user must select the exact one. agent-detect's
provider rules serve identification and reciprocation, so same-vendor
same-policy surfaces fold regardless of how many index keys exist,
providers absent from every index get ruled (`phala`), and a future
configuration surface (`agent-detect provider-config` style) would
attach the index ids to our rules as selectable sub-providers —
selection needs their granularity, identification does not.

**D9 — cascade to this repo (decision needed).** agent-detect's
markdown (AGENTS.md, CONTRIBUTING.md, DESIGN.md, commits.md, plans.md,
zig.md, powershell.md, the .plans corpus) is hard-wrapped at ~76
columns throughout, which the new upstream rule makes non-conformant.
Options: (a) a mechanical unwrap pass over prose (large diffs, git
blame churn — mitigate with `git log -L`/annotation patience or do it
file-by-file as each is next touched); (b) grandfather existing files
and write all NEW content unwrapped (zero churn, a permanent split);
recommendation: (b) now, promoting files to unwrapped opportunistically
when they receive substantive edits — the same non-retroactivity
posture the model-rule folding policy takes. Code blocks, tables, and
the grids keep their structure either way.

## Decisions for maintainer review

| id | decision | churn | alternative |
| --- | --- | --- | --- |
| D1 | `moonshot`+`kimi` → **`moonshotai`** (label "Moonshot AI") | 18 files | keep `kimi` name, variations only (zero churn, index-divergent) |
| D2 | `kimi-code`+`kimi-coding`+`kimi-coding-cn` → **`kimi-coding`** (label "Kimi for Coding") | 2 files | name it `kimi-code` (CLI key, 2-file churn, slug-collides with harness id cosmetically) |
| D3 | `ollama-cloud` → **`ollama`** (variation); individuation designed + deferred | 115 files + 38 invocation keys | keep split (zero churn, boundary already broken in the wild) |
| D4 | `opencode-free`+`opencode-zen` → **`opencode`** (label "OpenCode Zen") | 0 if pre-drain | keep three rules (models.dev disagrees) |
| D5 | `google` keeps its name; split from vertex stays | 0 | `google-gemini` (rejected: no index uses it) |
| D6 | cloudflare: keep `cloudflare-workers-ai`; record `cloudflare-ai-gateway` known-unruled | 0 | — |
| D7 | axis-semantics convention (ambiguous→both; closed-only→open null; open-only→closed never-vacuous, flagged) | 0 | — |
| D8 | training corrections: `nvidia` never→**enforced** (conjunct-failing — review the free-axis implications), `qwen` opt-in→**enforced**, `zai`(+`zcode`/`autoclaw` mirrors) opt-out→**opt-in** both axes, `nebius` opt-in→**opt-out**, `xiaomi` opt-in→**never** (API surface; desktop would be opt-out) + comment-level nuances (xai, bedrock URL, vercel routing, hf routing, upstage Playground) | 0 (values only) | conservative floors: nvidia opt-out, qwen opt-out |
| B1–B10 | mechanical fixes (duplicates, alias gaps, `k3`, dead cells, ragged rows, doc drift) | ~0 | — |
| D9 | cascade of the upstream no-hard-wraps rule (landed: bevry-vibes/skills `a219384`) to this repo's hard-wrapped markdown — recommended: grandfather + write new content unwrapped | 0 | full mechanical unwrap pass (blame churn) |

The highest-risk single change is `nvidia`: it flips a free-axis
provider from reciprocity-passing (`never`) to conjunct-failing
(`enforced`) for every harness that reaches it — the maintainer should
personally re-read the API Trial Terms §3.3 quote before ratifying
that one (it is the reachable free tier that trains, not a corner
surface).
