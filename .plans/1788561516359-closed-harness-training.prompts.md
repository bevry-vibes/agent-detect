# 1788561516359-closed-harness-training — prompts

Prompts that initiated and shaped
[1788561516359-closed-harness-training.md](./1788561516359-closed-harness-training.md),
verbatim and in order. All from one session on 2026-09-05, hosted by the
ZCode desktop harness (agent model as reported by the harness:
`zcode-clinepass-glm53` — GLM 5.3 via cline-pass). Per-harness message
timestamps were not observable and are not fabricated.

## 1. initiating prompt

Update agent-detect to permit closed-source harnesses re reciprocity:true
only if that closed source harness is not training. For instance, in
zcode, our current harness, it is a closed-source harness, however
training can be turned off. There is a "Improve experience
Allow us to use your conversations to improve the Agent experience. We
protect your data privacy and security." option. Start with zcode, but do
a plan for other harnesses too.

## 2. continue (after the question round returned no answers)

.

## 3. re-ask request

ask me the questions again, as something went wrong and I didn't see them

### 3a. answers to the re-asked questions

- When a closed-source harness's training state cannot be determined →
  "Exit 10 — not reciprocal" (later revised in prompt 6).
- Scope → "Closed-source only (Recommended)".
- Recipe flag → counter-question: "Does check-reciprocal already support
  dims args?" (answered: yes — `--harness/--provider/--model`, used by CI
  today), then answered: "Skip the flag".

## 4. plan note

all good - note that we've done new commits, mostly around the *.md files

## 5. revision request

Don't update the fixture files, let them be regenerated when they become
stale.     Also, do more research on cursor and copilot training now.

## 6. final revision request (decision 1 superseded)

Actually, change "NONE	null (undeterminable)	.not_reciprocal (exit 10)" to
the unkown. But change we looked and we couldn't determine a clear answer
to not_reciprocal. This should coincide wiht our provider handling right?
As we want to encourage people running closed harnesses to correct the
data.

## 7. two-field revision request

Actually, harness_training should be two fields, like provider, so
harness_open_training, and harness_closed_training - for instance, zcode
seems to (please confirm) only do harnesss_open_training - and their
values should also be the opt-in, opt-out, etc when not able to be
directly determined by the harness instance config

## 8. follow-up additions

Note a post-plan follow-up on whether to add open_training_config and
closed_training_config fields for isolating training policy from active
training config. Also, for zcode, whose creator is zai, do they have any
closed models? or are they only open-weight+ models? This should be
factored into their closed_training score.
