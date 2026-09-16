# Prompts — posture / setting / model_training (1788916141)

The user's directives that produced
[1788916141-posture-setting-model-training.md](./1788916141-posture-setting-model-training.md),
paraphrased compactly; wording follows the session.

1. (Context, from the 2026-09-09 code review thread) The provider
   NOASSERTION cases (moonshotai, kimi-coding) currently fail closed at
   exit 10 with a "data complete" message that is false for an
   inconclusive audit; the maintainer's instinct is that inconclusive
   should be null/exit-9 and the behaviour should be consistent — but
   asked for the options and considerations to be revealed before any
   implementation. (The earlier options analysis — values→null, flip
   both conjuncts, docs-only, strictest-posture opt-out — was presented;
   no option picked yet.)

2. Add `model_training` for whether that model does training — some free
   models must do training; currently this flips the provider trainings
   to opt-in or whatever. Instead this would allow provider values to
   stay the course, and move that exceptional activity to
   `model_training`.

3. Add `{provider,harness}_{open,closed}_setting` for whether they are
   configured to train/surveil/share-data or not. Currently this is
   overloading their `_training` properties — individuating it out
   allows them to be distinct.

4. Naturally, this allows for greater discernment on what is going on.
   Give a proper plan on this, and how it impacts the
   NOASSERTION/NONE/null cases; and their intersections with each other.

5. (Amendment, 2026-09-09) `model_training` should be
   `model_{open,closed}_training` — a pair — as the training that the
   model is tied to / enables might be different than its own
   open/closed status.

6. (Amendment, 2026-09-09) Rename the setting values: `on` → `enabled`,
   `off` → `disabled`. Precedence rulings — err on the side of
   worst-case: `enforced` takes precedence over `enabled`/`disabled`
   (consider the setting telemetry rather than a peculiar training
   override); `enabled`/`disabled` take precedence over `never`
   (consider the setting training and a potential false-flag `never`).

7. (Amendment, 2026-09-10) Upstream bevry-vibes/skills conventions.md
   has new rules on language conventions (the writing style section:
   ASD-STE100 — short sentences, imperative instructions, active
   voice, no contractions, no gerunds as nouns or modifiers, small
   noun clusters, articles kept, conditions before instructions, no
   metaphors, International English spelling, one word per meaning).
   Rewrite the plan with the new conventions.

8. (Amendment, 2026-09-10) The precedence paragraph is still too
   difficult to parse — "just jargon salad"; the plan is intended for
   human review. Rewrite it.

9. (Ruling, 2026-09-10) For the matrix row
   `NONE | never/opt-in/opt-out | null/NOASSERTION | pass`: if the
   setting cannot be deduced, then opt-in and opt-out should be
   worst-case, which is active. Use `active` and `inactive` as the
   lingo for (training OR setting) == does training. Reciprocal is
   fine if it is training only on open, but not closed.

10. (Amendment, 2026-09-10) The plan currently uses posture, training,
    setting, enabled, disabled, active, and inactive. We need a
    clearer vocabulary here and how they all relate to each other; we
    need a glossary in the plan.

11. (Ruling, 2026-09-10) "Posture" violates the English convention —
    it is invented jargon, not the most common term; never invent
    jargon nor do linguistic contortions. Just use `training
    deduction`, `setting deduction`, and so on — clear without any
    jargon. Introduce `{harness,provider}_reciprocity_scandal:
    true/null` for whether that harness or provider has been
    implicated in a scandal involving reciprocity (background and
    sources: discourse.bevry.me/t/1310, "AIs graded on openness,
    morality, code, reasoning, and research citation"). Introduce
    `{harness,provider,model}_reciprocity` for storing the computed
    deduction from scandal + training + {setting, license, ...}. Then
    it becomes easier to deduce the algorithm, and to explain the
    algorithm.

12. (Ruling + research directive, 2026-09-10) The Grok Build harness
    has a controversy — search "grok uploaded repos". Do a complete
    search for all our existing providers and harnesses for
    controversies. Like licenses, the scandal sources/urls should be
    included in the raw under `scandal-urls`. Liberation ethic: it is
    fine for reciprocal models/providers to train on reciprocal
    models/providers (they give back), and fine for reciprocal
    models/providers to train on non-reciprocal ones (they Robin Hood
    it back to the commons, per the grading thread's rationale) — but
    not fine for closed models/providers to train on reciprocal ones
    (nothing is given back). The provider setting lives on the
    provider website configuration panel, not locally; if no harness
    exposes/mirrors it locally, drop the provider setting field
    entirely, note it as a shortcoming and a future task that
    probably needs a `--query-remote` flag (permitting a remote query
    when the case is ambiguous — the provider is opt-in or opt-out);
    research whether cursor/claude/zed/codex/zcode (the provider
    ones) mirror the cloud panel settings locally.

13. (Directive, 2026-09-10) Save the subagent scandal research into a
    top-level `research` directory, plus a .md on how to generate,
    research, and update it; reference this in DESIGN.md.

14. (Ruling + question, 2026-09-10) D2: do we know / is it explicitly
    asserted or prohibited that muse-spark only does open training
    and not closed training? D4: Grok Build is open licensed yet may
    train — so training setting, training, and licence do not relate
    to each other; what matters is their implications — does the
    setting do training — which is irrespective of the harness
    licence.

15. (Rulings, 2026-09-10) D1/D2: when an axis could not be
    determined, it should be the null/NOASSERTION case — note this in
    the deduction guidance. D7: if avoiding training requires
    billing, that should be opt-out, as it requires a user action to
    not train — in this case the user action is billing; note this in
    the deduction guidance. D8: whatever works. D10: flagging (b) on
    entities behind open-weight harnesses/providers/models will
    really limit options, as it seems all AI companies are training
    on whatever they can get their hands on — if it is more fair use
    (for reciprocal purposes) let it slide; if it is more
    non-reciprocal purposes, note it as a violation, as that is not
    fair use and violates fair use; note that even with fair use
    outside of AI, consent is not needed, as fair use is a right that
    overrides enforcements that would otherwise be draconian — this
    is the balance here.
16. (Directive, 2026-09-15) Implement the plan (D10 ratified with the
    purpose-test refinement). Executed as three phases: code+schema+tests,
    rules data (including the D4 sweep values from the two research
    passes), documents.
