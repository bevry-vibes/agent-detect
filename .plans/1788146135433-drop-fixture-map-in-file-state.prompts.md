# Provenance — 1788146135433-drop-fixture-map-in-file-state

Agent: Pi · GLM 5.3 Flash (provider opencode-go), 2026-08-31.
Prompts verbatim, in order, untruncated.

---

1. (session context — the commit step of the fixture capture task)

> okay, commit; then we'll do the chutes stuff by doing `pi install npm:pi-chutes` from https://github.com/mark182es/pi-chutes

2.

> Okay, pi is now authed with chutes, so you can run its fixtures. We are still glm-5.3-flash though. Before we do this, review the plan at  .plans/1788107876077-handoff-chutes-opencodego-state.md for relevant follow-ups, and considerations for me.

3.

> What is channel-hash?

4.

> What is a channel? how is this different from fixture hash?

5. (the initiating prompt for this plan)

> I think this is a lot of overkill. Let's drop .index.json:fixtures and move its properties into their fixture .json files. Update the existing typescript schema or do an additional one for the schema of the fixture files. Drop the hashes, it was a bad idea.

6.

> `--thinking` extra flags are perhaps unnecessary unless documented as necessary - we should only include necessary args/flags in invocations

7.

> Drop the runner id from the fixture files

8.

> Drop the runner id from the fixture files - persist only in the queue.

9.

> give me these plans fleshed out some more - also consider having from-identity in its own folder and from-capture in its own folder

10.

> prompt_launch and version_launch should be inside the from-capture fixture file; the direcetories should be `from-identity` and `from-capture`; the saved outputs should be inside a outputs object (identify, trailer ..., [raw - if from-capture]); and the other fields in a meta object (captured_at, agent_detet_version, harness_version, prompt_launch, version_launch)

11.

> put agent_detect_version before the captured_at/declared_at

12.

> rename declared_at and captured_at to just be updated_at, and put it before agent_detect_version - the prior distinct names was only necessary when they were in the same file

13.

> rename --stale-by-channel-drift to --stale-by-output-drift; add a new `--stale` that is --stale-by-channel-drift OR --stale-by-days=27 OR --stale-by-harness-version OR --stale-by-detect-version; have it so that --stale is defaulted to true unless one of the --stale-* are added, or if --refresh is added which functions as if --stale was not defaulted/provided; if --stale is provided and --stale-* is provided then the --stale-*= value will overwrite the default of it that --stale provides; this will make it easier to prevent churn

14.

> Give me more details about these and how they will operate now: [the axes help text block]

15.

> without updating the plan yet, what are better names or recatogirisation for known/unknown valid/invalid - as it is pretty obtuse right now

16.

> how about --fixtured/--unfixtured (for whether fixture files exist), --known/unknown (for whether the dims are known)

17.

> change --known and --unknown to --resolvable and --unresolvable; now let's consider errors; perhaps we can change it to be like the queue or a bit divergent to the queue; what are some proposals; and we should also note that if a queue item has no stale* or refresh* then it should be popped with the same stale default

18.

> What if we drop errors completely and just have them in the daemon log for the dev agent to discern?

19.

> But when would say "no launch spec" actually occur, if it is resolvable then it should not happen- this would be for like if we tried a evergreen item that didn't exist yet right? Or is it for say for known ids, but an unknown harness-provider-model combo - how about we add fields to .index.json that contains these action items easily by their distinctions - what types of distinctions do we need? we already have pretty good error reporting / exit statuses

20.

> have unresolvable become unknown_agents unknown_providers and unknown_models of their alphanumeric ids, unique, no null/empty

21.

> now change/drop: [the axes block] and their new verisons to just be a --repair that works on these actionable errors, so when an unresolvable is now resolvable, or a needs-curation now has curation, or an unfixtured can now get fixtures - --repair should just pop them and add them back to the queue

22.

> unknown_agents should be unknown_harnesses

23.

> we lost lot errors for general failures that can be retried, so known_but_failed["dim"]: "stderr or whatever"
