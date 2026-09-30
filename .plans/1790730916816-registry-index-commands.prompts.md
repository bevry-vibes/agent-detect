# prompts — 1790730916816-registry-index-commands

The session's prompts, verbatim, in order.

## prompt 1

> create a new plan
>
> rename `web` command to `registry`
> agent-detect registry --{harness,provider,model,agent/id,email,platform}= --web/json
> default to json output
>
> add a new `index` command
> agent-detect index --{harness,provider,model} --web/json
>
> additional filters can be considered later
>
> for index and registry commands
> default to json output, --no-json will not json output a, adding --web will open the website for it, --no-json --no-web is fine it is just the same as --no-json`, in which no output is fine, it just means we only want the exit status
>
> index is a new command that will show all harnesses, all providers, all models; each only having their generic outputs, data that is consistent across all its associated combos, including which associations it has
> an index filter only filters the list of of all (eg. a provider filter only filters providers, not harnesses.cline.providers); index becomes an ability for consumers to quickly understand the available harnesses/providers/models, their properties and associations; as well as to be able to get name/variation to our canonical alphanumeric id
>
> drop platform from from-identity as it has no effect
> for website registry, platform now represents platforms we have captures for, they are no longer clickable on result page, just normal tags/pills
>
> website result page still has an issue: the line with reciprocal, platforms, and dates can still multiline on mobile, they should always be a single line, shrink if necessary
>
> (selected from the plan review: "--platform= repurposed. … with the result page's platform tabs gone static, multi-fixture combos render all their fixtures stacked latest-first under platform · channel · date headings — identical to today for the single-fixture majority, nothing lost to the dead tabs. If you'd rather keep a local (non-URL) tab selector there, that's the one decision to veto.")

## prompt 2

> Note sure what you mean. The result page pills of `platform - declared` stuff should have only ever been `platform`. So it should be say `reciprocal`    `linux` `macos` `windows`     `date`          with the platforms if we have observed captures for them, clicking them does nothing, drop the ?platform url filter on the result page
>
>
> Doing `index --harness=cline` should filter the `.{providers,models}[](.harnesses.includes('cline'))` and `.harnesses[](.id = 'cline')` so we are only showing what is available for that harness. Same goes for `--{provider,model,platform}=` - yes add `index --platform=`, also add `--free` to filter by models that are free, and `--reciprocal` to filter only those that are reciprocal, and `--no-reciprocal | --reciprocal=false` for only those that are not reciprocal; we can figure out the training filters stuff later (add the free and reciprocal filter to `registry` command and website too)
>
> we don't need `counts` in index shape
>
> we can drop the csv data, it can be modelled into the index data instead

## prompt 3

> there shouldn't be any of this, the page should just be showing from-identity results! where did you get the idea it from-capture results?!?!?! as I never stated that ever
>
> give me a typescript schema in the plan for the index
>
> (selected from the plan review: "the page renders one section per captured platform, each headed by just the platform pill — no platform - declared")

## prompt 4

> why is indexdata and indexfile diffeerent? there is no need - was there a technical reason they are divergent?
>
> the entries for harness provider and model should be the same as the from-identity fixture, so harness_* provider_* model_* - naturally setting fields are not present, as they are for capture fixtures

## prompt 5

> instead of {providers,models}: object, do {providers,models}(_free)? or if better, just have it in the IndexFile providers_models_free: [provider, model][]
>
>   /** per-combo fixture facts from the from-identity channel — absent = never declared.
>    * Refreshed by `agent-detect-dev fixtures index`; `--check` pins freshness. */
>   combos: Record<string, { platforms: Platform[]; reciprocal: boolean }>
>
> why is this needed?
>
> I think we can drop the {harness,provider,model_} prefixes in their entries
> also, we can drop the associations object, so associations.providers becomes providers
>
> (selected from the plan review: "free lives on the provider↔model association cells (associations.models: { id, free?: true }[], mirrored on the model side), because that's the only place the axis exists — there is no per-model or per-provider free fact. The dev surface's paid-blocklist gate needs cell-level precision, so it can't collapse to a model-level flag.")

## prompt 6

> okay, change `combos` then to be `agent_map_to_platforms_reciprocal`
> would providers_models_free be better as a `provider_map_to_free_models: Record<string, string[]>` - would that be more performanent for our use cases?
