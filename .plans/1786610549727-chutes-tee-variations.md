# Chutes provider rule + TEE-id variations

## Provenance (kilo.md tweak)

Generated fresh with `./zig-out/bin/agent-detect trailer assisted-by`:

- Generated-by: Kilo Code · Kimi K3 Tee <kilo-chutes-kimik3tee@local>
(the `Tee` in that very line is the bug this plan fixes — after it
lands, the regenerated line reads `Kimi K3 <kilo-chutes-kimik3@local>`)

- Original prompt:

    > I GIVE UP. SPLIT OUR chutes/tee tasks from .kilo\plans\1786606126543-dedup-sweep-binary-names-free-top100.md into its own plan - the plan that just does hardcoded variations. Will will do it after .kilo\plans\1786606126543-dedup-sweep-binary-names-free-top100.md lands. Commit the plans.

- Prompts that shaped the approach (verbatim, in order):
    1. > The TEE suffix should have been trimmed away, Chutes adds TEE suffixes its model labels to indicate they are running in an secure enclave, but they are the same model as without the TEE suffix. Make sure the code adds these aliases.
    2. > STOP. We do not need a function for this, or regex. It is purely just hardcoded aliases, chutes model ids as aliases that are folded into the model ids.
       >
       > We already have work done for how to handle aliases/variations of names and such folding, as we needed the ability for say `--model='Kimi K3 TEE'` to fold into `--model='Kimi K3'` already, or say `Kilo Code CLI` to fold into `Kilo`, see this from CONTRIBUTING.md:
       >
       > (verbatim quotes of CONTRIBUTING.md's "add a new model or provider rule" field tables, its "alias conventions" section, and `.kilo/plans/1786429467666-alias-cli-flags.md` step 3 "Starter variations data" followed — those live in the repo, not duplicated here)
    3. > Okay, do the chutes and tee stuff now

## Order

Lands **after** `.kilo/plans/1786606126543-dedup-sweep-binary-names-free-top100.md`
(the sibling dedup-sweep plan). All edits here are additive against
structures the sibling keeps in `src/main.zig` (the rule tables,
`applyModel`), so the only coupling is mechanical: post-sibling line
numbers and post-sibling doc prose.

## Context

Two latent gaps, one mechanism:

- **No chutes provider rule.** `chutes` (Kilo's free-router upstream)
  resolves to nothing in `rulesForProviders`, so provider metadata
  (training policies, source URLs) is unproposed it in reports.
- **TEE-stamped ids fabricate identities.** Chutes serves models from
  a trusted execution environment and stamps the id:
  `chutes/moonshotai/Kimi-K3-TEE`. `applyModel` strips the first
  provider segment, calls `modelForName("moonshotai/Kimi-K3-TEE")`,
  gets no rule hit, and the family fallback title-cases a fabricated
  label: `Kimi K3 Tee`. Today's live trailer proves it:
  `Assisted-by: Kilo Code · Kimi K3 Tee <kilo-chutes-kimik3tee@local>`.

**The mechanism is the existing alias folding, nothing else** (user
decision — prompt 2): `canonicalIdFor` resolves every CLI id against
each rule's normalized alias set (`name` + `label` + `short_title` +
`variations`, whole-string strict slug, exact-name-first,
first-rule-in-array-order; documented in CONTRIBUTING.md "alias
conventions" and tested by the alias-uniqueness test). No new function,
no suffix stripping, no regex. The fold happens by adding hardcoded
chutes id spellings as `variations` on the model rule — exactly how
`kilo` folds `Kilo Code CLI`.

Two call paths, two states today:

- **Recipe/CLI (`resolveRecipe`, line 2825):** already resolves
  `--model=` through `canonicalIdFor` → the variations alone make
  `--model=Kimi-K3-TEE` / `--model='Kimi K3 TEE'` fold to `kimi-k3`.
- **Live detection (`applyModel`, line 785):** calls `modelForName`
  (exact rule-name match + family-prefix fallback) and never consults
  `variations` → needs a one-half-line change to route through
  `canonicalIdFor` first.

Never-guess contract holds: `variations` only fold spellings a rule
explicitly names. An unknown `foo-tee` hits no variation and keeps
today's raw passthrough (titleCase fallback) — it cannot fabricate a
`foo` rule.

Stash state: `stash@{0}` ("chutes", 30 lines) carries exactly the T1+T2
edits below. This plan ports them as-is; the stash is superseded once
this lands (user drops it).

## Tasks

### T1 — chutes provider rule (port from stash, verbatim)

In `rulesForProviders`, after the `cerebras` row (matching the row's
current neighbors):

```zig
    // chutes: never/never — Chutes ToS states "We do not use your API
    // requests, responses, or application content to train AI models";
    // the privacy policy states public-API content is never logged,
    // stored, or persisted (zero content logging; TEE/E2E modes), and
    // app content "is not used for model training".
    .{ .name = "chutes", .label = "Chutes", .closed_training = "never", .open_training = "never", .sources = &.{ "https://chutes.ai/privacy", "https://chutes.ai/terms" } },
```

### T2 — kimi-k3 TEE variations (port from stash, verbatim)

On the existing `kimi-k3` row in `rulesForModels`:

```zig
    // variations: Chutes suffixes its secure-enclave model ids with
    // "-TEE" (marketing); the id `chutes/moonshotai/Kimi-K3-TEE`
    // canonicalizes to `moonshotai/kimi-k3-tee` after applyModel's
    // first-segment provider-prefix strip, so both forms are needed.
    // (…row unchanged…, .variations = &.{ "Kimi-K3-TEE", "moonshotai/Kimi-K3-TEE" } },
```

Evidence-driven: kimi-k3 is the only chutes TEE id observed so far
(this machine's live Kilo config resolves to
`chutes/moonshotai/Kimi-K3-TEE`). When another chutes TEE id is actually
observed, add its two-form variations the same way. No new model-rule
rows; rule counts unchanged.

### T3 — live-detection fold in `applyModel`

After `applyModel` strips the first `provider/` segment, resolve the
remaining id through `canonicalIdFor(.models...)` **before** calling
`modelForName`. On a hit, set `d.model_name` to the rule's canonical
`name` and take label/reciprocity/sources from that rule
(`modelForName` on the canonical name). On null, behavior is byte-for-
byte today's: raw stripped name + family-prefix/titleCase fallback.
No new function; the fold reuses the documented resolver.

Effects: `chutes/moonshotai/Kimi-K3-TEE` and bare
`moonshotai/Kimi-K3-TEE` both yield `model_name = "kimi-k3"`,
`model_label = "Kimi K3"`, reciprocity `open-weight`,
`agent_id = kilo-chutes-kimik3`. Unknown `kimi-r1` still takes the
kimi-family fallback unchanged.

### T4 — tests (`src/exit_statuses.test.zig`)

- `canonicalIdFor(ModelRule, …)`: `"Kimi K3 TEE"`, `"Kimi-K3-TEE"`,
  `"kimi-k3-tee"`, `"moonshotai/Kimi-K3-TEE"` → `"kimi-k3"`;
  exact-name-first still wins (`"kimi-k3"` → `"kimi-k3"`).
- Provider aliases: `"Chutes"` → `"chutes"`.
- Never-guess: `"foo-tee"`, `"Foo Tee"` → `null`.
- The existing `alias sets: no normalized slug maps to two rules within
  a table` test already iterates `variations` — it must pass with the
  two new entries (asserts they collide with nothing, incl. each other).
- `applyModel` fold test (following the file's existing Detection
  construction pattern): input `chutes/moonshotai/Kimi-K3-TEE` →
  `model_name == "kimi-k3"`, `model_label == "Kimi K3"`.
- Trailer expectation via the existing `buildTrailerLine` pattern:
  a kilo/chutes/kimi-k3 detection emits
  `Kilo Code · Kimi K3 <kilo-chutes-kimik3@local>`.

### T5 — docs

- CONTRIBUTING.md "alias conventions": extend the variations guidance
  with the observed case — provider-served id forms (chutes'
  `Kimi-K3-TEE` / `moonshotai/Kimi-K3-TEE`) are recorded as
  `variations` when a provider stamps serving-environment suffixes;
  add only ids actually observed, never speculative ones.
- PROVIDERS.md: add the `chutes` row (never/never, its two sources).
- MODELS.md: no change (variations are alias surface, not a new model).
- DESIGN.md #13's name-coalescing sentence gains: TEE-stamped serving
  ids (trusted execution environment) fold into the base model via
  model-rule variations.
- Provider counts: +1 wherever the post-sibling docs state a provider
  count — count the table at apply time (AGENTS.md style; do not
  fabricate, do not carry over the sibling's numbers).

### T6 — verification

- `zig build`, `zig build dev`, `zig build test` all green.
- `./zig-out/bin/agent-detect identify --harness=kilo --provider=chutes --model=Kimi-K3-TEE`
  → JSON `model_name` = `kimi-k3`; trailer ends
  `Kimi K3 <kilo-chutes-kimik3@local>`.
- Live dogfood: `./zig-out/bin/agent-detect trailer assisted-by` →
  `Assisted-by: Kilo Code · Kimi K3 <kilo-chutes-kimik3@local>`
  (no `Tee`).
- Report `stash@{0}` superseded for the user to drop.

## Out of scope

- Programmatic TEE suffix stripping (rejected by the user — prompt 2;
  the sibling plan's T6 explains the abandoned approach).
- Variations for models without an observed chutes TEE id
  (evidence-driven additions only).
- Anything in the sibling dedup-sweep plan.
