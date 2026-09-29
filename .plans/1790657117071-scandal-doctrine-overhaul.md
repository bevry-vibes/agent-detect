# The scandal doctrine overhaul — the liberation matrix, the redemption gates, and the reclassifications

Written 2026-09-28, on the linux host, after the release cut (`2026.9.28-1`) and the corpus drain
(`1abe86f`). This plan lands the session's scandal-criteria rewrite: the four clause dotpoints and
the purpose-test paragraph retire in favour of one governing sentence, a taking×outcome matrix, and
an explicit redemption policy. It also records the session's entity rulings and their table
consequences (one unflag, one model verification, no new flags).

## Provenance

Every prompt that shaped this plan is recorded verbatim (untruncated, timestamped, in order) in the
companion file `.plans/1790657117071-scandal-doctrine-overhaul.prompts.md` — plans link to it; they
do not inline prompts. Agent model: GLM-5.3 Flash (reported by harness). The doctrine decisions are
the maintainer's, made interactively across the session; the companion records them in order.

## The law (replaces the clause dotpoints and the purpose-test paragraph)

> We care about consent and copyright violations — except takings that feed reciprocal output
> (liberation, fair use into reciprocal models). Violations that feed no model are out of scope.

Ambiguity is allowed: only an explicit promise, instruction, or license binds. A copyright holder
may do what it wants with its own models (same-entity distillation is out of scope). Proven lying
about data handling escalates any finding one level (recorded-as-context → recorded-no-effect →
scandal).

## The matrix

| What was taken ↓ / What it fed → | Fed reciprocal output (weights shipped back) | Fed non-reciprocal output (closed) | Fed no model (serving, infra) |
|---|---|---|---|
| Pirated copyrighted content | recorded, no effect | scandal | recorded as context, out of scope |
| — with destruction of original works (buying up out-of-print books to scan and destroy) | scandal | scandal | recorded as context, out of scope |
| User data, breaching explicit terms/instructions | recorded, no effect — scandal if intentional, unremedied, or unrectified | scandal | recorded as context — a proven lie escalates it |
| User data, silent/ambiguous policy | out of scope | recorded, no effect | out of scope |
| A third-party closed model's outputs, distilled | fine — liberation | scandal — proprietary mischief | — |
| Open-source/open-weight software or models, used in violation of their license | recorded, no effect — scandal if intentional, unremedied, or unrectified | scandal | recorded as context — a proven lie escalates it |

The three states: **scandal** (flags; shows in `identify`, `explain`, `scandal-urls`) /
**recorded, no effect** (stays in the research file permanently; never changes the determination) /
**recorded as context** (real finding, wrong lane — history only).

**The unverifiable-recipient rule**: when the recipient of a taking cannot be verified (unreleased,
rumoured, vanished), the finding is recorded with no effect; it re-derives if the recipient ever
ships (fine, if open) or ever serves closed (scandal).

## The redemption gates (one policy for every vector)

| Gate | Question | Pass | Fail |
|---|---|---|---|
| 1. Intent | Deliberate practice, or accident/negligence? | Accident proceeds on 3–6 | Deliberate proceeds only with every later gate plus a longer clean record |
| 2. Malice | Deception, concealment, or harm to users? | — | Path closed while it stands; a proven cover-up survives only via self-disclosure or independent verification of the fix |
| 3. Remedy | Affected parties made whole (deletion, notice, compensation)? | Required | Without remedy: closed |
| 4. Rectification | Structural change (policy rewrite, technical fix, independent audit, open-sourcing)? | Required, verified by someone other than the entity | Self-attestation is insufficient |
| 5. Recurrence | Any further violation since rectification? | None | Any recurrence resets; repeat findings compound |
| 6. Sustained record | A year or more clean after rectification | Scandal steps down to recorded-no-effect; with years more, removal | — |
| **Character clause** | A pattern of findings, especially with concealment | — | **Path permanently closed.** OpenAI and Anthropic are ruled character-flawed (maintainer, 2026-09-28) |

## Session rulings this plan records

1. **DeepSeek-Korea** — prompts to ByteDance's Volcano Engine: fed no model; PIPC noted lack of
   intent; remediated (transfers blocked, Korea annex, app restored); no recurrence → recorded as
   context + redeemed. The misleading keystroke disclosure → redeemed the same way. **The deepseek
   flag dissolves.**
2. **ZCode** — the repo-upload episode: consented opt-in feature, since resolved (open-sourced
   client, audit, standing response mechanism) → recorded, no effect. ZCode/Z.ai stay clean.
3. **Grok/X-posts → closed Grok** — public-by-visibility is not the exception; the exception is
   about what ships back. Stays a scandal leg (with the Grok Build proven lie as the second leg).
4. **moonshotai / zai CAC findings (May 2025)** — excessive-collection discipline: not deliberate,
   rectified in-window, 16+ months clean → recorded, no effect under the redemption gates.
5. **StepFun Step 4 (CISA AA26-251A)** — the taking is proven and deliberate (account pools, origin
   obfuscation), but the recipient never shipped and cannot be verified → the unverifiable-recipient
   rule applies: recorded, no effect, re-derivation triggers noted. **No flag.**
6. **OpenAI/Anthropic** — character clause: their scandals (Books/LibGen piracy into closed models,
   proven deletions) are not redeemable.
7. **grok-1 / grok-2** — remain unruled (never observed served by any provider); grok-2's community
   license is anti-liberation (outputs may not train other models) and worth citing when a rule
   ever lands.

## Workstream 1 — `research/scandals.md` rewrite

Rebuild the file around: the law; the matrix; the three states; the redemption gates; the proof
scale (regulator finding / wire capture / admission / approved settlement = flag-worthy; suit-stage
allegation = recorded); then the per-entity findings reclassified under the matrix — every existing
section keeps its sources, each finding gains its cell citation. Preserve the file's method note
("never edit a verdict without a source"). The clause letters (a)–(d) retire; findings cite matrix
rows.

## Workstream 2 — `src/lib/rules.zig`

1. **deepseek unflags**: drop `.reciprocity_scandal = true` and the sources array; the comment
   records the reclassification (Korea = fed-no-model + redeemed; the flag's only legs dissolve)
   and points at the research file.
2. **step-3.7-flash verifies**: `openness = "open-weight"`, `license = "Apache-2.0"`, sources =
   the HF card + its LICENSE (stepfun-ai org, Apache-2.0 tag verified 2026-09-28). The unverified
   comment retires.

No other table edits: no new flags (moonshotai/zai/stepfun all record clean), no training-axis
changes.

## Workstream 3 — doc pointers

- CONTRIBUTING "deduction guidance" → **the purpose-test paragraph retires**, replaced by a short
  pointer to the research file's law + matrix (the ladder guidance around it stays).
- DESIGN.md / fixture.d.ts scandal-field wording stays accurate (flags remain booleans; scandal-urls
  remain the citations) — no edits required beyond verifying that on the pass through.

## Workstream 4 — validation

`zig build && zig build dev && zig build test`. Coverage holds (deepseek and step37flash stems
still exist). No schema changes; the identify/explain/raw shapes are untouched — flags stay
booleans, scandal-urls stay the citations.

## Workstream 5 — corpus consequences

| Combos | Effect | Path |
|---|---|---|
| deepseek-provider (all platforms) | identify flips on regen (boolean false, urls empty, reason drops) | **blocklisted-paid — daemon cannot regen them** (the standing exclusion, same as ollamacloud); stale until the blocklist or the free grid changes, or the files are purged (user discretion) |
| step37flash combos (openrouter/kilo/vercel) | identify gains `model_openness`/`model_license` + model-urls → stale-by-output | daemon-regenerable (none blocklisted): `fixtures queue --model=step-3.7-flash --refresh --from-identity`, then the normal drain |
| everything else | untouched | no sweep |

## Implications on the prior harnesses, providers, and models

| Entity | Before | After | Mechanism |
|---|---|---|---|
| deepseek (provider) | flagged | **unflagged** | Ruling 1 |
| anthropic, openai (providers) | flagged | flagged (unchanged) | Character clause; piracy-into-closed legs re-cited under the matrix |
| xai (provider) | flagged | flagged (unchanged) | Tweets → closed Grok (row 2, col 2) + the Grok Build proven lie |
| github-copilot (provider) + copilot (harness) | flagged | flagged (unchanged) | Doe v. GitHub now cited under both the piracy row and the license-violation row (copyleft stripped into closed models) |
| moonshotai, zai (providers) | clean | clean + recorded, no effect | Ruling 4 |
| meta, mistral (providers) | clean | clean + recorded, no effect | Piracy fed shipped weights; no originals destroyed on the record |
| stepfun (provider) | clean (opt-in/opt-in) | unchanged | Ruling 5 — no flag |
| step-3.7-flash (model) | openness null | **open-weight, Apache-2.0** | Workstream 2 |
| zcode (provider + harness) | clean; combos exit 10 on the training ladder | **no determination change** | The failure is the training ladder (opt-in, unreadable setting), not a scandal; the upload episode records clean (ruling 2). Issue #3 stays open |
| qwen, cursor, google, alibaba, amazon-bedrock, the Part-3 inference providers | caveats | caveats (reclassified under the matrix, no flags) | Disclosed/unproven findings stay out of the flag lane |
| grok (pending harness) | lands pre-flagged | lands pre-flagged | The wire-capture lie is the escalator's reference case |
| grok-1, grok-2 (models) | unruled | unruled (unobserved) | Ruling 7 note for whoever lands them |
| all models generally | carry no flags | carry no flags | Flags are provider/harness-level; the matrix judges entities, not weights |

## Explicitly not carried

- **Issue #3's exceptions mechanism** — the zcode "not reciprocal" fix remains a separate work item;
  this plan neither fixes nor worsens it (see the zcode rows above).
- **The training-axis verification of Z.ai's Optimization Program** (does the opt-in program feed
  closed models?) — the cheapest zcode fix, but a training-ladder sourcing task, not scandal work.
- **Step-5-Preview** — a third-party HF repo of unverified provenance; not ruled.
- **Step 4 re-derivation** — recorded as a trigger, not a task; it fires only if StepFun ships or
  serves the model.

## Implementation order (each commit per commits.md: build first, generated trailer)

1. this plan file pair.
2. `research: the scandal doctrine — the liberation matrix and the redemption gates` (workstreams
   1 + 3).
3. `rules: the scandal reclassifications — deepseek unflagged, step-3.7-flash verified`
   (workstream 2).
4. `zig build && zig build dev && zig build test` (workstream 4).
5. queue the step37flash sweep entry (`fixtures: queue the step-3.7-flash verification sweep`),
   and let the next daemon drain carry the corpus (its own `fixtures:` commit after).
