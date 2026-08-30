# prompts — 1787972028734-chutes-opencodego-model-license

Provenance companion for
[1787972028734-chutes-opencodego-model-license.md](./1787972028734-chutes-opencodego-model-license.md),
per [plans.md](../plans.md).

Agent model: as reported by the harness at plan commit time —
`Kimi Code · Qwen3.8 Flash <kimicode-opencodego-qwen38flash@local>`
(the live `agent-detect` fallback line; the change being planned
replaces it with the verified rules).

Timestamps: this harness does not expose per-message timestamps to
the agent, so none are recorded — ordering below is authoritative
and no timestamps were fabricated.

## Original prompt

> Read `CONTRIBUTING.md`. We are likely an unknown combo. We are now chutes provider with `Qwen3.8 27B` as the model running on macos in the kimi harness. Add support.

## Prompts that shaped the approach (verbatim, in order)

1. > Using variations for this is the correct way, as per .kilo/plans/1786610549727-chutes-tee-variations.md. However, we can fetch all available models from the chutes provider, and add them now in this flow. Document how to fetch available models from chutes provider (whether it can be done via a chutes api call, or wheter the harness exposes it - the harness should expose it as it selects which model from the provider - so that likely means the provider has an api that exposes it).

2. > tell me the overall plan you are doing, especially re TEE folding - are you just adding aliases? or are you doing a programtic trimming of tee suffixes?

3. > You are allowed to do probes, executions, that develop the plan. Just don't go commencing the plan yet.
   >
   > "✨ tell me the overall plan you are doing, especially re TEE folding - are you just adding aliases? or are you doing a programtic trimming of tee suffixes?" - ignore that, we are doing variations, and are already in plan mode
   >
   > You are distracted. Get back to querying chutes (or kimi) for all chutes available models. You are allowed to do probes, executions, that develop the plan. Just don't go commencing the plan yet.

4. > ✨ Note that the OpenRouter API also provides details for which models are available for which providers. So when we add a new provider, we should check the various sources for getting its models (the providers api, the openrouter api, the harness surface). We should refresh the evergreen models list. Then once all that is done, we can add all its models THAT are evergreen, ignoring unadded models that are not evergreen, but note them somewhere. Note that when fetching models, we only care about models suitable for coding, this retraint should already be documented.
   >
   > ✨ okay, yeah the **B stuff should be folded into as a variation into the family, providing it has the same properties as the family, e.g. if Qwen/Qwen3.8-2.4T-A95B and Qwen/Qwen3.8-27B have the same properties that this projects cares about, they can be folded into the Qwen3.8 family. Such a family can be see from https://huggingface.co/collections/Qwen/qwen38 - are there are ways to see the family? note that. Also note that https://huggingface.co/collections/Qwen/qwen38-flash-next is a different family to Qwen3.8. Actually be critical of this suggestion, what would such more dramtic family folding entail, compromise, lose, gain, win - is it a good or bad idea?

5. > Note that Qwen3.8-Max is the non-open source variant of qwen3.8-2.4t-a95b as per https://www.qwencloud.com/models and https://huggingface.co/Qwen/Qwen3.8-2.4T-A95B 
   > > In particular, Qwen3.8-Max is the official version based on Qwen3.8-2.4T-A95B with more features, such as vision input & non-thinking support, 1M context length by default, official built-in tools, etc. For more information, please refer to the Qwen3.8-Max Overview.

6. > Lets add a model_license SPDX field to the cooked output, akin to the harness_license field. This makes it clearer that model folding should not fold on license variations. I've also decided we want to maintain separation on paramters, on cases there there is indeed a separation on params, e.g. if a model version is released in two param sizes but all other props the same, lets keep that separate, but if a model version is only released with one param size, we don't need to include the param size information in its id.

7. > Note that an already supported model should only be dropped, not when it is no longer evergreen, but once its added dim is no longer supported (the harness, or provider has dropped it). As an added dim is something someone is using agent-detect for.

8. > your sessions talled with chutes, we are now Qwen3.8 Flash on opencode-go. Continue with what you were doing. Last reasoning was "● Two policy refinements: a model_license SPDX field in the cooked output, and param-size separation in rule identity. Let me check the fixture contract surface this touches before updating the plan."

9. > Go through our prompt history and see if any important prompts were missed due to the provider change. Furthermore, as part of our AGENTS.md we want our different harnesses to all write their plans to the same location (this should be a AGENTS.md referenced file, not a config change in the harnesses), which should follow what `kilo.md` does, plans should go to .plans with their plan and prompt files.

10. > Note that `kilo.md` can be dropped with the new `plans.md`, and that we should migrate existing plans to the new .plans directory

11. > Inside `fixtures` keep a `.provider_models.csv` and `.harness_providers.csv` with cells with the provider model-id and the harness provider id as the cells (or a dash if no data), so rows are our alphanumeric id of the harness or provider, and the columns our alphanumeric id of the provider or model. This will make it easier for us to see what providers have what. This is merely a developer reference file similar to the evergreen files, it should not be sourced by our zig program.

12. > Actually all them `.providers_models.csv`, and `.harnesses_providers.csv`

## Post-approval steers (executed directly, logged here)

13. > Note that the OpenRouter API ... contributor tiers ... opencode free models ... these should not be "never" values but "opt-in" values — this must be noted as a harder rule ... (opt-in-by-model: closed trainers flip closed_training, open trainers flip open_training; opt-out/enforced unchanged)

    → `openrouter` open_training never→opt-in; `opencode-go` opt-in/opt-in; hard rule in CONTRIBUTING.
14. > Are there any known model rules/ids that would be affected by the folding rules, if we retroactively applied them?

    → audit; proposal `.plans/1787978000867-retroactive-folding-options.md`.
15. > Give me an expanded plan on the options and their wins/gains and their losses/effects.
16. > B is good. I don't understand C and D. Do B then go into more details about C and D ...

    → B executed (rules folded, store migrated, free-table remapped, grids regenerated). C/D explained; decision pending.
17. > Furthermore, `.index.json` needs a typescript schema defined (even though zig doesn't use typescript). The docs can then reference the typescript schema as the source of truth, rather than using written words to describe the schema. Furthermore, in `.index.json` fields with `null` values can be omitted, as they cause too much bloat to the output.

    → `fixtures/.index.d.ts` written as the normative structure; DESIGN state-store section now semantics-only pointing at it; `queueEntryValue` switched to null-as-absent; store normalized (8,105 nulls removed, 534KB→283KB); queue-invariants test updated to treat absent as unset.
18. > Add `.providers_freemodels.csv` where the rows are the providers, the columns are our alphanumeric model ids, and the cells are the provider's model id - only have rows and columns for when there is a free model id. This will be the source of truth for free models instead of `.index.json:free_provider_to_model`

    → `fixtures/.providers_freemodels.csv` created (4 providers × 10 free-capable models, provider-native free spellings); `FreeGrid` loader replaces the store table in dev.zig (expansion reads it; `indexLoad` drops the legacy table); store migrated (table removed → three tables); `.index.d.ts`, DESIGN, CONTRIBUTING, dev help text, and both test suites updated (free-grid test asserts rule resolution, sparsity, launch free-signals, and absence of the legacy table).
19. > "...this is wrong on our part, the provider there is hyper, it should be `crush-hyper-qwen37plus`... Check other harness provider combos for such a discrepancy. Re C. I don't know what you mean, if you are talking about the queue, you are overthinking it. The queue does not need ids checked/modified. IDs are popped at runtime, and if they are invalid or variations, then those are known cases then. RE D. The paramater size should not necessarily be a hard rule, but a rule in combination with the other factors. So if the model is primarily known as blah-version then we don't need blah-version-param distinction in its name, any distinction is only important if the distinction is necessary to discern it from a non-distinct name - e.g. if the model is released with multiple param sizes or other distinctions, and none of them have official claim nor competing claims on the non-distinct model name. If there is any competing claim on the official name, then we hard rule we need the distinction of param, etc."

    → Phantom `qwen3.7-plus` provider rule removed (audit: it was the only provider rule whose name is a model id; minimax-code/deepseek-flash/kimi-code/cline-pass are genuine configured surfaces and stay); `detectCrush` folds model-id-as-hyper-key to `hyper`; `applyProviderMeta` folds provider spellings via `canonicalIdFor`; C voided (the orphan rules are test-exempted; no queue curation); D rewritten as official-claim naming with distinction-only-when-contested (CONTRIBUTING + DESIGN #13 + rule comments).
