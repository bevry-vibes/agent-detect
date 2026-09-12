# research/ — how to research, generate, and update

This directory holds the controversy research that informs rule
curation for `agent-detect`. The current subject is provider and
harness scandals ([scandals.md](./scandals.md)). Add one file per
research subject; give each file the same shape: a header with the
generation date, the criterion, the findings with sources, and the
mapping to rules.

## When to update

Update `scandals.md` when any of these fire:

- A new harness or provider rule is about to land (research it
  before the rule merges, so the flag and its sources land with it).
- The maintainer's grading thread updates (the source of record:
  [AIs graded on openness, morality, code, reasoning, and research
  citation](https://discourse.bevry.me/t/ais-graded-on-openness-morality-code-reasoning-and-research-citation/1310)).
- A major news event names a ruled entity (a suit, a regulator
  action, an official report, a wire-capture finding).
- A rule's `reciprocity_scandal` value is questioned in review.

Suits and reports move slowly; a quarterly re-check of the flagged
entities is enough, plus event-driven updates.

## The method

1. **List the entities.** Take every rule in `rulesForHarnesses` and
   `rulesForProviders` from `src/lib/rules.zig`, plus the pending
   harnesses from CONTRIBUTING.md. Group them by company — one
   company's findings often attach to several rules (Microsoft →
   azure-foundry, github-copilot; Z.ai → zai, zcode, autoclaw).
2. **Search per entity**, in batches of roughly ten to keep each
   research pass reviewable. For each entity, search for: the entity
   name plus "lawsuit", "training data", "GDPR", "opt out",
   "exfiltration", "controversy", and any known incident name. Read
   the primary source where one exists (the filing, the regulator's
   page, the wire-capture post) — secondary coverage only frames it.
3. **Judge each finding against the criterion** (the liberation
   ethic, in `scandals.md`). The four clauses: (a) third-party
   content piracy; (b) user-data betrayal — default-on training,
   paid opt-outs, non-consensual transfer; (c) closed-output
   distillation of a reciprocal source; (d) proven false claims
   about data handling. A disclosed, terms-consented behaviour is a
   caveat. An unproven suspicion is a caveat. Record the clause with
   the finding so a later reader can re-judge it.
4. **Record the surface.** State which surface each finding attaches
   to — the model training, the API surface, a CLI tool, a consumer
   app. A finding on a consumer app does not automatically flag the
   API rule; that mapping is a maintainer decision, recorded in the
   mapping table.
5. **Map to rules.** The mapping table at the end of `scandals.md`
   states, per rule, the recommendation: flag `true` with the
   clauses, or leave absent with the reason. The rule change itself
   lands as a commit: the `reciprocity_scandal` flag, the
   `reciprocity_scandal_sources` array (the URLs), and a comment
   that names the clauses.
6. **Date and preserve.** Every verdict line carries its dates; every
   claim carries a source URL. Never edit a verdict without a
   source. Unverified items go in the watch list at the bottom, not
   in a verdict.

## Judgement rules of thumb

- A scandal needs an actor with standing: a court, a regulator, an
  official report, or wire-capture-level evidence. Journalism alone
  can carry clause (a) when the underlying facts (the dataset, the
  admission) are public.
- Distillation is not wrong by default. Ask two questions: does the
  output ship back as open weights (liberation, acquitted)? Did a
  closed output take from an open source (the one distillation
  scandal)?
- **Judge the purpose, not only the act.** A taking that feeds
  weights that ship back is fair use — let it slide, whatever the
  act looked like. A taking that feeds enclosure violates fair use —
  flag it. Consent is not needed for fair use; that is the balance.
  Flagging every user-data finding would leave almost no reciprocal
  options, because all AI companies train on whatever they can get.
- "Open licensed" says nothing about data behaviour — Grok Build is
  Apache-2.0 and uploaded whole repositories with secrets. Judge the
  behaviour, never the licence.
- A paywall on privacy is clause (b) in shape, but verify whether a
  free toggle exists before writing "charged for the opt-out".

## Generating the file

The 2026-09-10 pass ran four parallel web-research agents: the
western labs, the Chinese labs, the inference providers, and the
harnesses. Re-running the same split works well — each agent gets the
entity list, the criterion, and the instruction to return per-entity
verdicts with clauses, dates, and source URLs. The agents' reports
are then compiled by hand into `scandals.md`, preserving every
finding and URL. Do not let an agent write the file directly: the
compilation step is where surface-attachment and rule-mapping
judgements happen.
