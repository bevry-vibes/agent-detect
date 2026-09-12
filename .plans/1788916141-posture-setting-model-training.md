Assisted-by: ZCode · Glm 5.3:cloud <zcode-ollama-glm53cloud@local>
(provenance companion: [1788916141-posture-setting-model-training.prompts.md](./1788916141-posture-setting-model-training.prompts.md))

# Training, setting, and scandal — the split fields and the per-entity reciprocity

Status: **drafted 2026-09-09; it waits for maintainer ratification of
D10 alone** (rulings resolved D1 through D9 — see the digest).
It supersedes the 2026-09-09 #11 options analysis for the provider
NOASSERTION cases. This design resolves #11 at the determination
layer, and it downgrades no data.

## Glossary — the vocabulary and how the terms relate

The plan measures one thing: the **data use**. The data use is any use
of your conversation data — to train a model, to surveil, or to share
the data with a third party. Every term below is a facet of the data
use. A **deduction** is what the code concludes from an input, or from
a set of inputs.

**Entity.** One of harness, provider, or model. Each entity has two
axes.

**Axis (open, closed).** The kind of model that the data use would
train. The open axis covers open-weight models. The closed axis covers
closed models. The determination gates the closed axis; the open axis
informs.

**The training** (fields `{provider,harness}_{open,closed}_training`
and the model pair `model_{open,closed}_training`). What the published
terms permit for the data use, by default. The rule tables hold it. It
is static, and no detector writes it. Values: `enforced`, `opt-in`,
`opt-out`, `never`, `NOASSERTION` (we looked; the documents do not
agree), `null` (we have no data).

**The setting** (fields `harness_{open,closed}_setting` — harness
only; see "The provider setting shortcoming"). What the local artifact
of this installation configures for the data use. The detection holds
it; the rules never do; recipe mode emits null, because no instance
exists. Values: `enabled`, `disabled`, `NOASSERTION` (an artifact
exists; its meaning cannot be mapped), `null` (nothing is readable).
A model has no setting, and — as the research below shows — neither
does a locally-readable provider.

**Artifact.** A locally readable file or value that carries the
setting — for example, the zcode settings file, or the cursor
privacyMode value. A detector reads artifacts; it never reads the
published terms and never queries a remote service.

**Scandal** (fields `{harness,provider}_reciprocity_scandal`, and the
raw `scandal-urls` array). Whether a court, a regulator, an official
report, or a wire-capture finding implicated the entity in a scandal
that involves reciprocity. The value is `true` or absent. See "The
scandal field".

**Training deduction.** What one training value resolves to on one
axis: `active`, `inactive`, `depends on the setting`, or
`undeterminable`.

**Setting deduction.** What one setting value resolves to on one axis:
`active`, `inactive`, or `nothing readable`.

**The ladder.** The order of precedence that combines the training
deduction and the setting deduction into the **axis outcome**:
`active` (the training happens on this axis), `inactive` (it does
not), or `undeterminable` (the data cannot settle the question). The
worst case wins.

**`{entity}_reciprocity`** (computed fields `harness_reciprocity`,
`provider_reciprocity`, `model_reciprocity`). The deduction for one
whole entity: `true` (the entity passes), `false` (it fails), `null`
(undeterminable). Each one combines the scandal, the axis outcomes,
and — for the harness — the license, or — for the model — the
openness.

**`model_openness`.** The openness tier of the model weights
(`open-source`, `open-weight`, `closed`). This is the former
`model_reciprocity` field, renamed: the name `model_reciprocity` now
belongs to the computed deduction.

**Determination.** The final result of `check-reciprocal`, read from
the three computed reciprocities. The licence fields inform only (D4).

The chain, from rule to exit code:

```
rule (static)                      instance (read at detection time)
the training ....................  the setting (harness only)
        \                            /
         '-------- the ladder ------'
                     |
        axis outcome: active | inactive | undeterminable
                     |
   {entity}_reciprocity = scandal + axis outcomes (+ license | openness)
        harness_reciprocity ∧ provider_reciprocity ∧ model_reciprocity
                     |
        determination: exit 0 | exit 10 | exit 9
```

The value sets never mix. Each value belongs to exactly one field
family:

| field family | lives on | values | the question it answers |
| ------------ | -------- | ------ | ----------------------- |
| the training | the rule | `enforced`, `opt-in`, `opt-out`, `never` | what do the published terms permit by default? |
| the setting | the detection | `enabled`, `disabled` | what does the local artifact configure? |
| the scandal | the rule | `true` | did a scandal implicate the entity? |
| the axis outcome | computed at run time | `active`, `inactive`, `undeterminable` | does the training happen on this axis? |
| `{entity}_reciprocity` | computed at run time | `true`, `false`, `null` | does the entity pass its part? |
| the determination | the exit code | reciprocal (0), not reciprocal (10), undeterminable (9) | does the agent pass the policy? |

`NOASSERTION` and `null` appear in both the training and the setting
vocabulary, with one shared meaning: `NOASSERTION` means "we looked,
and we could not conclude"; `null` means "we have no data". The axis
outcome has its own word for that state: `undeterminable`.

The word "training" plays two roles, and the context separates them.
As an activity, it names what the data use does ("the training
happens"). As a field-name suffix, it marks a training field
(`harness_closed_training`). No field is named "active" or "enabled"
except the setting fields.

## Problem — two fields carry three concepts

`{provider,harness}_{open,closed}_training` mixes three concepts today:

1. What the published terms of the entity permit by default. The rule
   tables hold this value. It is static, and the published terms are
   its only source.
2. What this installation is configured to do. The zcode toggle read
   (`optimizeAgentExperienceEnabled`) overwrites the fields at
   detection time. The cursor signal (`privacyCache.privacyMode`) is a
   candidate of the same class; it stays unwired.
3. Model-reachable exceptions — training that occurs only when you
   select a specific model (OpenRouter contributor tiers, the zen
   free-period models). These exceptions raise the PROVIDER values
   today through the opt-in-by-model rule. The raised value says only
   "some reachable selection trains". A provider training value must
   say more than that.

The mix produces two symptoms. First, the exit-10 message ("data
complete and requirement failed") is false for the
research-inconclusive cases (`moonshotai` and `kimi-coding`,
NOASSERTION — the #11 thread). Second, the zcode instance read must
abuse NOASSERTION as an instance value to express its fail-safe
state.

## The split fields

### A. The training — what the published terms permit

The rule tables keep this field. The vocabulary does not change. The
meaning narrows to the published default. No detector writes this
field again. `NOASSERTION` keeps its meaning: we researched, and the
documents do not agree.

### B. The setting — what the local artifact configures (harness only)

The detection holds this field. Detectors populate it from locally
readable artifacts at detection time. Recipe mode emits null, because
no instance exists. The values: `enabled` (the artifact explicitly
configures the data use — the zcode toggle at `true` is the
affirmative state), `disabled` (the artifact explicitly configures
against the data use — the toggle at `false`, or a
`disallowPromptTraining` style flag, is the protective state),
`NOASSERTION` (an artifact exists; its meaning cannot be mapped —
never-guess), and `null` (nothing is readable; this is the default
state).

### C. The model training pair — what the model selection trains

The pair `model_{open,closed}_training` says what YOUR DATA trains as
a consequence of the model selection. It is independent of the
openness of the model itself: `model_openness` states the status of
the weights; the training pair states what the serving arrangement
enables. An open model can enable the training of closed models. A
closed model can enable none. The pair uses the same vocabulary as
the training, and the same axis doctrine: the closed axis gates, the
open axis informs. The values are `null`/`null` for most models,
because training is a provider activity, not a model property.

Scope rule (the most important rule in this plan): the pair records
model-intrinsic arrangements only. An arrangement is model-intrinsic
when it is tied to the model wherever you select it. The OpenRouter
contributor listing of muse-spark is model-intrinsic.
Surface-specific or tier-specific exceptions are not: the zen free
period on `mimo-v2.5` and the google unpaid tier serve the same model
in different ways elsewhere. They stay at the provider level, in
comments or in the training values. If we set
`mimo-v2.5.model_closed_training`, the xiaomi combos fail without
cause, because xiaomi is a verified never.

## The provider setting shortcoming

The provider-side data-use toggles (OpenAI's "improve the model"
control, the Copilot account opt-out, the Nous Portal Privacy Mode,
the xAI console settings) live on the provider website configuration
panel. They are server-enforced account state. A research pass over
every ruled harness's local config surface (2026-09-10) found exactly
one mirror: Cursor's `~/.cursor/cli-config.json`
`privacyCache.privacyMode`/`ghostMode` caches the account-level
Privacy Mode — but its integer enum is undocumented, its freshness is
unknown, and it may be absent. Every other harness stores only its
own telemetry flags, or nothing.

Consequences, per the maintainer ruling (2026-09-10):

- **Drop the `provider_{open,closed}_setting` fields entirely.** A
  field the code can never populate honestly is worse than no field.
- The provider axis resolves from the training alone, and "nothing
  readable" is its permanent state: `enforced`, `opt-in`, and
  `opt-out` resolve active (the worst case, per the 2026-09-10
  ruling); `never` resolves inactive; `NOASSERTION` and `null` stay
  undeterminable.
- Record the shortcoming in DESIGN and CONTRIBUTING: the provider
  setting needs a remote query. Future task, out of scope here: a
  `--query-remote` flag that lets the binary query the provider panel
  only when the case is ambiguous (the training is `opt-in` or
  `opt-out`), with user consent per the no-network rule.
- The cursor privacyCache stays the one future local source: when
  someone documents its enum, wire it as the harness setting (cursor
  is both harness and provider, and the toggle is account-level).

## The ladder — the training deduction, the setting deduction, and the axis outcome

The training deduction, from one training value:

- `enforced` → `active`
- `opt-in` or `opt-out` → `depends on the setting` (the terms say a
  toggle exists)
- `never` → `inactive`
- `NOASSERTION` or `null` → `undeterminable`

The setting deduction, from one setting value:

- `enabled` → `active`
- `disabled` → `inactive`
- `NOASSERTION` or `null` → `nothing readable`

The ladder combines the two deductions into the axis outcome. When
they disagree, the worst case wins: take the side that assumes more
training (maintainer rulings, 2026-09-09 and 2026-09-10).

1. **`enforced` resolves active, whatever the setting says.** The
   terms say the entity trains and offers no opt-out. A settings
   artifact may only steer telemetry, so it cannot prove that the
   training stopped.
2. **`enabled` resolves active, whatever the training says.** An
   artifact that explicitly turns the data use on is hard evidence. A
   `never` in a document can be false.
3. **`disabled` resolves inactive.** The artifact explicitly turns
   the data use off. No training value below `enforced` contradicts
   that.
4. **`never` with nothing readable resolves inactive.** The claim is
   verified, and nothing contradicts it.
5. **`opt-in` and `opt-out` with nothing readable resolve active**
   (ruling, 2026-09-10). The training says a toggle exists. If we
   cannot read the toggle, assume it sits in the training branch.
6. **`NOASSERTION` or `null` with nothing readable resolves
   undeterminable.**

The outcome per axis: active on the closed axis fails the entity.
Inactive passes it. Undeterminable gives null. Active on the open
axis is informational: the agent stays reciprocal if the entity
trains only on open models, and leaves reciprocity if it trains on
closed ones.

A model has no setting, so its training pair resolves directly:
`enforced`, `opt-in`, and `opt-out` resolve active; `never` resolves
inactive; `NOASSERTION` resolves undeterminable; `null` records no
exception and does not block. A provider has no readable setting
today, so rung 5 is its permanent state until `--query-remote` exists.

## The algorithm — three entity deductions, one determination

```
harness_reciprocity = true | false | null:
  harness_reciprocity_scandal == true        → false
  axis outcome = ladder(harness_closed_training, harness_closed_setting)
  active → false; undeterminable → null; inactive → true

provider_reciprocity = true | false | null:
  provider_reciprocity_scandal == true       → false
  provider_closed_training:
    enforced | opt-in | opt-out              → false   (active; no readable setting)
    never                                    → true    (inactive)
    NOASSERTION | null                       → null    (undeterminable)

model_reciprocity = true | false | null:
  model_openness null                        → null
  model_openness closed                      → false
  model_openness open-source | open-weight:
    model_closed_training active             → false
    model_closed_training undeterminable     → null
    else                                     → true

the determination, from the three fields:
  any false → exit 10, stdout "not reciprocal"
  else any null → exit 9
  else → exit 0, stdout "is reciprocal"
```

The `reciprocal` field in the identify report keeps its rule: an
unverified status cannot be assumed reciprocal, so the value is false
when the determination is undeterminable. The tri-state result lives
in the exit code and in the three computed fields.

The license does not gate anything (ruling, 2026-09-10 — D4): Grok
Build is open licensed and still uploaded whole repositories. The
training, the setting, and the licence do not relate to each other;
what matters is their implications — does the entity do training.
`harness_license` becomes pure information, exactly as `model_license`
already is. The ladder therefore applies to every harness, whatever
its licence. A scandal still fails first, because the scandal check
runs before the ladder.

## The scandal field

`{harness,provider}_reciprocity_scandal: true` marks an entity that a
court, a regulator, an official report, or a wire-capture finding
implicated in a reciprocity scandal. The rule holds the flag and a
`reciprocity_scandal_sources` array; the raw block carries the URLs
under `scandal-urls`, beside `harness-urls` / `provider-urls` /
`model-urls`. The field stores `true` or stays absent (null-as-absent);
it never stores `false`.

The criterion encodes the liberation ethic (maintainer ruling,
2026-09-10, per the grading thread): it is fine for reciprocal
models to train on reciprocal models — they give back; it is fine for
reciprocal models to train on non-reciprocal models — they Robin Hood
it back to the commons; it is not fine for closed models to take from
reciprocal models — nothing is given back. Therefore:

- **(a) Piracy of third-party content** (books, articles, code
  scraped without license) → scandal, whoever does it, whatever the
  output.
- **(b) User-data betrayal** — training on user/customer data against
  the terms or by default without consent, charging for the opt-out,
  or transferring user data to third parties without consent →
  scandal.
- **(c) Distillation** → scandal only when a closed output takes from
  a reciprocal source. Distillation into open weights that ship back
  is liberation, not a scandal, whatever the source. Closed-on-closed
  is not a commons concern.
- **(d) False claims about data handling**, proven by wire capture or
  admission → scandal.

## Deduction guidance — sourcing the rule values

The guidance below governs every rule-curation pass. It rides the
CONTRIBUTING rule-writing sections, and the tests enforce what they
can.

- **The axis rule (D1, D2).** When an axis could not be determined,
  record `null` (we never researched) or `NOASSERTION` (we researched,
  and the documents do not agree) — never guess an axis. A known
  training arrangement with an unknown axis records NOASSERTION on
  the closed axis, with the inference and its gaps in the comment.
  The axis outcome is then undeterminable, and the exit-9 nudge
  drives the research.
- **The billing rule (D7).** If avoiding the training requires
  billing, the value is `opt-out`: it takes a user action to not
  train, and the user action is the billing. Record the billing
  escape in the comment.
- **The purpose test (D10).** Judge every scandal finding by its
  purpose, not only by its act. A taking in service of reciprocal
  purposes — it feeds weights that ship back — is fair use: let it
  slide, and note it as a caveat. A taking in service of
  non-reciprocal purposes — it feeds enclosure — violates fair use:
  flag it. Fair use is a right that overrides enforcement that would
  otherwise be draconian, and consent is not needed for fair use.
  That is the balance.

## Rule changes — honest provider values, and new rules

- `openrouter`: open `opt-in` → `never`; closed stays `never`. Move
  the contributor-tier exception to the model training pair of
  muse-spark. Update the comment to say this.
- `opencode` and `opencode-go`: `opt-in/opt-in` → `never/never`. This
  matches the default statement in the zen documents. The exceptions
  move: Big Pickle gets its own model rule (below); the MiMo-V2.5
  free period is surface-specific, so it stays in a comment on the
  provider rule, and the model training pair of `mimo-v2.5` stays
  null (the scope rule).
- `muse-spark-1.2`: `model_closed_training` `NOASSERTION` (D2 — the
  contributor-tier training is known; the axis is not asserted, and
  the D1 guidance forbids guessing an axis). The open-lab-model
  inference and the absence of an explicit assertion stay in the
  comment. `model_open_training` stays null.
- **NEW RULE `big-pickle`**: `model_openness` `null` (the openness is
  unverified); `model_closed_training` `NOASSERTION` (D2 — the
  free-period training is known; the axis depends on the unverified
  openness, and the D1 guidance forbids guessing an axis); sources
  cite the zen documents. It lands with a rule-only coverage
  exemption (the autoclaw precedent). If a maintainer later confirms
  Big Pickle is open, resolve the axis then, with the research.
- `mimo-v2.5`: both model training fields stay null. Update the
  comment: name the zen free-period exception, and mark it
  surface-specific.
- `google`: `opt-in/opt-in` → `opt-out/opt-out` (D7: avoiding the
  unpaid-tier training requires billing, and the billing is the user
  action — the shape of `opt-out`). The unpaid-tier training is
  disclosed in the terms, so it is a caveat, not a scandal. The same
  shape keeps `alibaba` and `amazon-bedrock` clean (see D10).
- `moonshotai` and `kimi-coding`: **no change**;
  NOASSERTION/NOASSERTION stays. The determination gives exit 9 (D1).
- Every other provider keeps its training values. See D10 for the
  scandal population.

Rewrite the opt-in-by-model rule in CONTRIBUTING to match. Training
that is model-intrinsic goes to the model training pair. Training
that is tier-reachable or surface-reachable keeps the
strictest-reachable-surface value at the provider (the google and
nvidia precedent).

## Detector changes

- `detectZcode` — the toggle read now populates
  `harness_{open,closed}_setting`, not the training fields. Map
  `true` to enabled/enabled; map `false` to disabled/disabled; map a
  present non-bool value to NOASSERTION/NOASSERTION; map an absent key
  to null/null; map a missing file to null. `applyHarnessTraining`
  then copies the rule training into the training fields; the copy
  becomes unconditional, because no instance competes.
- `detectCursor` — keep `privacyCache.privacyMode` unwired
  (never-guess: the integer enum is undocumented). When someone
  documents it, wire it as the harness setting; it is the only local
  mirror of a provider-panel toggle that the research found.
- No provider setting reader ships, and none can (see "The provider
  setting shortcoming"). The `--query-remote` future flag is out of
  scope for this plan.
- `applyModel`, `resolveRecipe`, and `buildCooked` carry the model
  training pair, the scandal flags with their sources, and the three
  computed reciprocities. `buildRaw` emits `scandal-urls`. Recipe
  mode emits null settings, because no instance exists.

## Schema, tests, and documents — the near-zero fixture churn

- `Detection` gains the two harness setting fields, the two model
  training fields, the two scandal fields, and the three computed
  reciprocity fields. The identify contract grows from 20 to **29
  fields**, and one field renames: `model_reciprocity` (the openness
  tier) becomes `model_openness`, and the freed name
  `model_reciprocity` becomes the computed deduction. The provider
  setting fields are dropped (the shortcoming above). DESIGN #9 and
  `fixtures/fixture.d.ts` follow.
- The raw block gains `scandal-urls` (the flag's sources, beside the
  other `*-urls` arrays). The instance fields (`*_setting`,
  `*_reciprocity_scandal`) are null-as-absent (`?:`). The computed
  fields (`*_reciprocity`) emit `true`, `false`, or `null`.
- `known_fixtures.test.zig`: `identify_keys` grows to 29, with growth
  exemptions for both the new keys and the rename. **Do not force a
  mass regeneration.** Pre-growth files stay valid, and each file
  gains the keys at its next queued sweep (decision #16).
- `exit_statuses.test.zig`: add the ladder, the three entity
  functions, every matrix row, and the zcode instance split
  (enabled/disabled/non-bool/absent/missing).
- DESIGN: update #9 (29 fields); rewrite the harness-training policy
  section as training, setting, scandal, and the computed
  reciprocities; add the #11 resolution note; add the provider
  setting shortcoming and the `--query-remote` future task; extend
  the model policy section with the model training pair.
- The `ProviderRule.closed_training` field doc gains the NOASSERTION
  note: NOASSERTION is a researched, inconclusive training value; the
  axis outcome is undeterminable, and the determination gives exit 9.

## The matrices

The harness conjunct, over closed training × closed setting. The
licence does not gate (D4), so the table covers every harness:

| closed training | closed setting | determination |
| --------------- | -------------- | ------------- |
| enforced        | any (incl. disabled) | **exit 10** — active |
| never/opt-in/opt-out | enabled | **exit 10** — active |
| never/opt-in/opt-out | disabled | pass — inactive |
| never           | null/NOASSERTION | pass — inactive |
| opt-in/opt-out  | null/NOASSERTION | **exit 10** — active (ruling, 2026-09-10) |
| NOASSERTION     | enabled        | exit 10 — active |
| NOASSERTION     | disabled       | pass — inactive |
| NOASSERTION     | null/NOASSERTION | **exit 9** — undeterminable (D1) |
| null            | enabled        | exit 10 — active |
| null            | disabled       | pass — inactive |
| null            | null/NOASSERTION | exit 9 — undeterminable |

The provider conjunct has no setting column (the shortcoming):
`enforced`/`opt-in`/`opt-out` → exit 10; `never` → pass;
`NOASSERTION`/`null` → exit 9; scandal → exit 10 first.

The model conjunct; `model_open_training` informs in every row:

| model_openness | model_closed_training | determination |
| -------------- | --------------------- | ------------- |
| open-source / open-weight | null or never | pass to the provider conjunct |
| open-*         | enforced, opt-in, or opt-out | **exit 10** — active |
| open-*         | NOASSERTION           | exit 9 — undeterminable |
| closed         | any                   | exit 10 (the openness gate fires first) |
| null           | any                   | exit 9 |

## Before and after — the complete determination inventory

| combo class | before | after | why |
| ----------- | ------ | ----- | --- |
| every provider with closed training opt-in or opt-out (minimax 63 stems, github-copilot 28, mistral 18, xai 16, zcode 4, cloudflare-workers-ai 2, minimax-code 2, openai 2, zai 2; 137 stems total, plus the live minimax subscription) | pass | **exit 10** | no readable setting; rung 5 |
| every closed harness with closed training opt-in or opt-out and no readable setting — cursor (22), copilot (14) | pass | **exit 10** | rung 5 |
| the D10 scandal set — anthropic, openai, meta, mistral, xai, github-copilot, deepseek, moonshotai, zai (providers); copilot (harness) | mixed | **exit 10** | the scandal check runs first |
| every open-licence harness with null closed training — cline (427 stems), omp (345), kilo (263), pi (259), opencode (250), kimicode (220), crush (69), qwen (34), reasonix (15), vibe (13), mmx (8), goose (4), hermes (1); 1,908 stems total | pass (the licence gated) | **exit 9** — undeterminable (D4: the licence no longer gates; null training is unresearched) | the exit-9 nudge drives the D4 sweep below |
| moonshotai / kimi-coding (21 fixtures + live sessions) | exit 10 / identify exit 0 | **exit 9** | D1 — undeterminable (the scandal question is D10) |
| zcode, toggle enabled | exit 10 | exit 10 — active | rung 2 |
| zcode, toggle disabled | pass | pass — inactive | rung 3 |
| zcode, key absent | exit 10 | exit 10 — active | rung 5 |
| zcode, settings file missing | pass | **exit 10** — active | rung 5 |
| openrouter / opencode / opencode-go combos | pass | pass | opt-in → never; both pass |
| openrouter × muse-spark-1.2-contributor | pass | pass + `model_closed_training` NOASSERTION visible | the openness is null, so exit 9 fires first (D2) |
| opencode zen × Big Pickle | unresolvable (exit 7/8) | **exit 9** (model openness null) | the honest state of the new rule |
| everything else | — | — | the never providers, the enforced providers, and the null-training providers keep their determinations |

## Decisions for maintainer review

- **D1 — RESOLVED (2026-09-10).** NOASSERTION gives exit 9,
  uniformly. The data keeps the NOASSERTION values. The deduction
  guidance gains the rule: when an axis could not be determined,
  record `null` (never researched) or `NOASSERTION` (researched,
  inconclusive) — never guess an axis.
- **D2 — RESOLVED (2026-09-10).** The maintainer question: is it
  explicitly asserted or prohibited that muse-spark's contributor
  tier trains only open models? **No.** Nothing in the
  contributor-tier terms asserts what the data trains, and nothing
  prohibits closed-model training. Per the D1 guidance — when an axis
  could not be determined, record `null` or `NOASSERTION`, never
  guess an axis — both muse-spark and big-pickle record
  `model_closed_training: NOASSERTION` (the training is known; the
  axis is not). The inference and the absence of an explicit
  assertion stay in the comments. The openness of both models is
  null, so the openness check fires first either way (exit 9).
- **D3 — RESOLVED (2026-09-09).** `enforced` + `disabled` → active →
  exit 10 (rung 1); `enabled` beats a possibly false `never` (rung 2).
- **D4 — RESOLVED by a maintainer ruling (2026-09-10).** The licence
  does not gate. Grok Build is open licensed and may still train —
  training, setting, and licence do not relate to each other; what
  matters is their implications: does the setting do training,
  irrespective of the harness licence. The ladder now applies to
  every harness, and `harness_license` becomes pure information (like
  `model_license`). Consequence: 1,908 committed stems under
  open-licence harnesses with null closed training flip from pass to
  exit 9 (undeterminable — unresearched). The required follow-up is
  the **D4 sweep**: research the closed training for every
  open-licence harness rule. Most are BYO-key clients that train
  nothing; the expected landing values are `never`/`never`, which
  restores the pass. The exit-9 nudge is the designed driver for the
  sweep, the same way it drove the closed-harness sweep.
- **D5 — RESOLVED (2026-09-10).** An unreadable setting plus `opt-in`
  or `opt-out` resolves active. Unreadable means worst case.
- **D6 — RESOLVED (2026-09-10).** Drop the provider setting fields:
  the research found no honest local source (Cursor's privacyCache is
  the one mirror, and its enum is undocumented). The shortcoming and
  the `--query-remote` future flag go in DESIGN and CONTRIBUTING.
- **D7 — RESOLVED (2026-09-10).** If avoiding the training requires
  billing, the value is `opt-out`: it takes a user action to not
  train, and the user action is the billing. Google changes
  `opt-in/opt-in` → `opt-out/opt-out` (the free tier trains; the
  paid tier does not). No determination moves — `opt-in` and
  `opt-out` both resolve active with no readable setting. The
  guidance is noted below. The unpaid tier stays at the provider
  level: it depends on billing, not on the model.
- **D8 — RESOLVED (2026-09-10, "whatever works").** Three commits:
  (A) code, schema, tests; (B) rules data; (C) documents. Build each
  commit first, then add the generated trailer, per commits.md.
- **D9 — RESOLVED (2026-09-10).** The report carries the computed
  deductions, as the `{entity}_reciprocity` fields.
- **D10 — the scandal population** (research pass 2026-09-10; all
  findings carry sources in `reciprocity_scandal_sources` /
  raw `scandal-urls`). Ruling refinement (2026-09-10): flagging every
  user-data finding would leave almost no reciprocal options,
  because all AI companies train on whatever they can get. The
  purpose test decides. A taking in service of reciprocal purposes —
  it feeds weights that ship back — is fair use: let it slide. A
  taking in service of non-reciprocal purposes — it feeds enclosure
  — violates fair use: flag it. Fair use is a right that overrides
  enforcement that would otherwise be draconian, and consent is not
  needed for fair use. That is the balance. Under the purpose test,
  the recommendation below moves `meta`, `mistral`, `moonshotai`,
  and `zai` off the flag list: their takings fed weights that ship
  back. Recommendation — flag `true`:
  - `anthropic` — (a) LibGen/PiLiMi ~7M books, $1.5B settlement
    approved Jul 2026; (b) Reddit scrape suit; (b) consumer
    default-training window 2025; (b) the Bedrock
    `provider_data_share` 30-day mandatory retention episode
    (Aug–Sep 2026, walked back Sep 1).
  - `openai` — (a) Books1/Books2 + NYT, Authors Guild, Britannica,
    400-newspaper suits; (d) the Jul 2026 sanctions motion (deleted
    chats and datasets).
  - `xai` — (b) X posts fed to Grok by default, 60M EU users, NOYB
    complaints; (b)+(d) Grok Build uploaded whole git repositories —
    history, secrets, and files it was told not to read — while xAI
    claimed "no code" (wire capture, Jul 2026). The pending grok
    harness rule lands with the flag when it is written.
  - `github-copilot` (provider + `copilot` harness) — (a) Doe v.
    GitHub: trained on public repos with copyleft licenses and
    attribution stripped; (b) from Apr 24 2026, individual-tier
    interaction data trains by default.
  - `deepseek` — (b) Korea PIPC: full prompts transferred to
    ByteDance without consent — a transfer with no reciprocal
    purpose; the Italy Garante ban.
  - Leave absent, moved off the earlier list by the purpose test —
    their takings fed weights that ship back (fair use; slide, note
    as caveats):
  - `meta` — LibGen/Books3 fed the open Llama weights (81.7 TB,
    Zuckerberg approval, Kadrey). Borderline: re-flag if you read
    Meta's re-enclosure as the dominant purpose.
  - `mistral` — the Mediapart books and the Le Chat free-tier
    training fed Apache-2.0 open weights (privacy only if you pay
    stays a caveat).
  - `moonshotai` — the CAC app finding and the API default training
    fed the K3 weights, which shipped Jul 2026 (modified-MIT).
  - `zai` — the CAC Qingyan finding fed the GLM open weights (and the
    surface question dissolves: no flag either way).
  - Leave absent, unchanged: the distillation reports (Anthropic Feb 2026, CISA
    AA26-251A Sep 2026) — under the liberation ethic, DeepSeek,
    Moonshot, MiniMax, Alibaba, StepFun, and Z.ai distilled closed
    sources into weights that ship back, which is liberation, not
    scandal; `azure-foundry` (the Megatron piracy attaches to the
    model maker; the Foundry serving surface has no finding);
    `google`, `alibaba`, `amazon-bedrock` (disclosed default-training
    terms — caveats); the inference providers (nvidia, openrouter,
    nous, sakana, phala, chutes, deepinfra, siliconflow — caveats
    only: terms-consented tiers, self-corrected benchmark overclaims,
    a patched attestation gap, unproven quantization suspicions); and
    the harnesses cursor, zcode, autoclaw, kimi-code, qwen, opencode,
    crush, hermes (transparency caveats and governance rows, no
    criterion-fitting finding).

## What this plan does not do

- It forces no fixture regeneration (per #16). The growth exemptions
  carry the transition, and the sweeps add the keys naturally.
- It does no ollama `:cloud` work (a separate thread, DESIGN #15).
  The trailer in the header is the fold flaw live, and it exposed an
  unrouted `glm-5.3:cloud` spelling — a rules-sweep candidate for
  the variations of the glm-5.3 rule, independent of this plan.
- The `local` umbrella, the provider setting readers, and the
  `--query-remote` flag stay unstarted, until their triggers fire.