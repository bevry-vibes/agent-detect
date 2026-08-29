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
