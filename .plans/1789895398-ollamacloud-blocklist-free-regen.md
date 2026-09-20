Assisted-by: ZCode · GLM 5.3 <zcode-zcode-glm53@local>
(provenance companion: [1789895398-ollamacloud-blocklist-free-regen.prompts.md](./1789895398-ollamacloud-blocklist-free-regen.prompts.md))

# The ollamacloud individuation, the paid-only blocklist, the free-model refresh, and the regeneration

Status: **executed 2026-09-20** (phases: the individuation
`552afca` with the zcode 3.14 drift repair, the paid-only blocklist
`e76bae0`, the free-axis refresh `f05b5f1`, the regeneration queues
`9c56614`). The daemon drains the queues per platform after hand-off;
the rename-transition warnings burn down with each landed batch. This
plan picks up the threads the
1788916141 plan left open: the ollama `:cloud` individuation (DESIGN
decision #15), the blocklist and free-model refresh, and the fixture
regeneration. It also carries one repair found at implementation time:
the zcode 3.14 rollout drift (below).

## The ollama / ollama-cloud individuation — DESIGN decision #15 executed

`ollama` and `ollama-cloud` were individuated 2026-09-06 and folded
2026-09-07 because the boundary was not observable. Both recorded
discriminators are now implemented, so the rules individuate again:

- **The rule tables.** A new provider rule `ollama-cloud` (strict slug
  `ollamacloud`, label `Ollama Cloud`) takes the cloud service —
  training `never/never` (the cloud processes prompts and responses
  transiently and never trains on them; sources ollama.com/privacy and
  ollama.com/terms). The `ollama` rule keeps the local runtime, drops
  the `ollama-cloud` variation (its slug must not match two rules), and
  rewrites its comment: local models, nothing leaves the machine, the
  fold flaw is resolved. The `ollama` rule lands with a rule-only
  coverage exemption — every committed fixture is cloud traffic, so no
  stem carries it.
- **The baseUrl discriminator.** `providerHostFold` folds
  `ollama.com` → `ollama-cloud` (it folded to `ollama` before). Local
  endpoints (localhost, LAN) stay on the name path and resolve
  `ollama`.
- **The `:cloud` suffix discriminator.** A cross-dim post-pass runs
  after the provider and the model resolve: provider `ollama` plus a
  raw model spelling that carries the `:cloud` suffix re-resolves the
  provider to `ollama-cloud`. This covers the observed fold flaw —
  ZCode's custom provider named `ollama` on localhost:11434 serves
  `:cloud`-tagged models that route to ollama.com.
- **The `local` umbrella stays deferred.** No second local runtime was
  observed. The idea stays recorded in DESIGN decision #15.

### The fixture renames — names move, content does not

Every ollama fixture (129 stems — 116 from-identity, 13 from-capture)
is cloud traffic. All rename `-ollama-` → `-ollamacloud-` with `git
mv`. Per decision #16 and the maintainer directive, the file content
does not change: content refreshes only on regeneration. The renamed
files carry `provider_id: "ollama"` until their queue drain rewrites
them.

Propagation:

- `fixtures/index.json` — the 32 `invocations` keys and the 18
  `known_but_failed` keys re-key; the two queued entries with provider
  dim `ollama` re-key to `ollamacloud`. The launch argv strings inside
  the entries stay (they are the historical launch commands).
- The grids — `map-harness-provider`: the zcode row's `ollama` cell
  moves to the cloud rule (the kilo/omp/opencode `ollamacloud` cells
  and the hermes `ollama-cloud` cell already resolve to it).
  `map-provider-model`: the row key `ollama` becomes `ollama-cloud`
  with its cells unchanged (every cell is a cloud-catalog launch id);
  no local `ollama` row remains.
- `src/known_fixtures.test.zig` — the envelope combo-match test gains a
  rename-transition allowance: a stem whose provider segment is
  `ollamacloud` may carry `provider_id: "ollama"` until regeneration —
  it warns with the queue nudge, it does not fail (the
  unverified-harness-license warning is the precedent). The allowance
  drops when no warning remains. `rule_only_providers` gains `ollama`;
  the `isLegacyCrossChannel` stem re-keys with its file.

## The zcode 3.14 rollout drift — the repair found at implementation time

The `trailer` action failed in the ratifying session (`model = null`),
so commits.md demanded a repair before any commit. The cause is a
zcode 3.14 shape drift in `~/.zcode/cli/rollout/`:

- The rollout records no longer carry `model.role`. The main-role
  filter rejected every record, so the model dim resolved nothing. The
  filter now treats an absent role as main (subagent sessions get
  their own files, which the scan now skips by the `_subagent_` name
  segment — the per-session file is the scope boundary).
- The coding-plan keys renamed: the settings' selected key is
  `coding-plan:builtin:zai-coding-plan` and the rollout providerId is
  `account:zai-individual-coding-plan` (observed 2026-09-20).
  `zcodeProviderCanonical` maps both to `zcode` beside the retired
  `builtin:zai-start-plan`.

## The paid-only blocklist

The blocklist today blocks the whole provider: the daemon expansion
skips every combo of a blocked provider (`dev.zig`, both loops), and
`fixtures capture` refuses the provider outright. The maintainer
ruling (2026-09-20): the blocklist blocks only the paid models of a
blocked provider — the paid plan expired, the paid surface is never
tested again, but the free models stay testable.

- All three gates become `blocked(provider) ∧ the combo is not in the
  free grid`. The capture path loads the free grid for the check.
- `blocklist.balupton.providers` gains `clinepass` and `ollamacloud`
  (strict slugs) — both paid plans expired.
- DESIGN and `fixtures/index.d.ts` rewrite the blocklist paragraphs to
  the paid-only semantics; `index_store.test.zig` gains the
  free-exemption case.

## The free-model refresh

A new free push landed recently. The free grid
(`map-provider-model-freeprovidermodel.csv`) refreshes for every
provider — `clinepass`, `opencode`, `openrouter`, `zenmux`, `nvidia`,
`vercel`, and the new `ollamacloud` — per the CONTRIBUTING probing
runbook: the harness catalogs, the OpenRouter models API, and the
evergreen snapshots are the cross-checks. A new free model without a
rule gets a `ModelRule` (license and openness researched per the
rule-writing sections) plus a `map-provider-model` cell, so the combo
is feasible. The free-signal test governs: a free-listed combo with an
existing from-capture must carry the free signal in its launch id —
the old ollama captures launch `ollama-cloud/<model>` with no signal,
so a model lists as free only when it is genuinely free (or it waits
for a re-capture).

Execution findings (2026-09-20): OpenRouter's live API carries the
push (21 free ids; `nemotron-3-nano-30b-a3b:free` died in favour of
the omni-reasoning variant), ZenMux dropped its old `-free` ids
except the two z-ai flashes, and the NIM catalog gained
nemotron-3.5-lightning and the nano-omni reasoning variant. Eight new
rules cleared the evergreen gate with HF-verified licenses; the
ling-3.0-flash rule folds the `-fin`/`-sante` fine-tune spellings.
**Ollama Cloud gained no free row**: its catalog marks no model free
(the Free plan's "starter models" are unidentified) and no launch id
carries a free signal — never-guess. The clinepass, opencode, and
vercel rows stand unchanged: their free surfaces sit behind the
selector and the auth-gated dashboard, which this refresh cannot
probe; cline's free models rotate by the docs' own statement.

## The regeneration — zcode, the free models, and the full ollamacloud sweep

`--stale-by-output` cannot see the rename (it compares the two
channels, which still agree with each other), so the queues carry
`--refresh`:

- `fixtures queue --harness=zcode --refresh --from-identity` — the six
  zcode fixtures, including the renamed zcode-ollamacloud pair.
- `fixtures queue --provider=ollamacloud --refresh --from-identity` —
  the full sweep (maintainer choice, 2026-09-20): every renamed file
  regenerates, and the sweep mints the feasible-unfixtured grid combos
  the same way the earlier zcode sweep minted its six. Zero tokens.
- Per free provider: `fixtures queue --provider=<p> --free --refresh
  --from-identity`, and the capture upgrades `fixtures queue
  --provider=<p> --free --refresh --from-capture` (maintainer choice,
  2026-09-20) — the capture channel works only combos with an
  invocation of record, so zcode stays from-identity only.
- The daemon is user-run and never runs inside an agent; each host
  drains its own platform. The landed batches commit as they land, and
  the rename-transition allowance burns down with them.

## What this plan does not do

- It does not author a zcode invocation of record, so no zcode
  from-capture exists yet.
- It does not build the `local` umbrella, the provider setting
  readers, or the `--query-remote` flag (unchanged triggers).
- It does not touch harness config or auth files (the AGENTS.md hard
  rule); every `~/.zcode/` read is read-only.
