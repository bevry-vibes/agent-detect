Assisted-by: Kimi Code · Qwen3.8 Flash <kimicode-opencodego-qwen38flash@local>
(provenance companion: [1787978000867-retroactive-folding-options.prompts.md](./1787978000867-retroactive-folding-options.prompts.md))

# Retroactive folding — options and trade-offs

Status: proposal awaiting a decision. Companion to
[1787972028734-chutes-opencodego-model-license.md](./1787972028734-chutes-opencodego-model-license.md),
which shipped the forward-looking folding policy; this document asks
what, if anything, to retrofit.

## Problem statement

The new identity rules (version × param-size × license; serving
spellings fold as variations; evergreen gates additions only) are
documented as non-retroactive. An audit found three classes of
pre-existing state that the rules would change if applied backwards:

1. **Split same-model rules**: `deepseek-v4-flash-free` and
   `zai-glm-4.7` are separate rules whose comments/`sources` show
   they are the *same weights and license* as their parents
   (`deepseek-v4-flash`, `glm-4.7`) — exactly what the variation
   mechanism exists to fold.
2. **Orphan rules (store contract debt)**: 12 rules appear in zero
   `.index.json` rows — 8 models (`qwen3.5`, `gemini-3.1-pro`,
   `gpt-5.5`, `grok-3-mini`, `claude-opus-4`, `claude-haiku-4`,
   `glm-4.6`, `devstral-2`) + 4 providers (`cline`,
   `qwen3.7-plus`, `moonshot`, `google`). The "every rule appears in
   ≥1 row" test currently passes only because it returns at the
   first failure; these will surface one sweep at a time. (Not a
   folding issue per se, but discovered in the same audit and gated
   on a daemon run either way.)
3. **Family ids over multi-size lines**: `qwen3`, `qwen3.5`,
   `qwen3.6`, `qwen3-coder`, `llama-4` (whose `llama-4-maverick`
   sibling already follows the per-size convention). Whether these
   "violate" depends on an interpretation the policy doesn't yet
   state explicitly.

## Fact base (measured 2026-08-29)

| item | rows | fixture files on disk | queue entries | free-table mentions |
|---|---|---|---|---|
| `deepseekv4flashfree` | 3 (`opencode-opencode-*`) | darwin only | 3 | `free_provider_to_model.opencode` |
| `zaiglm47` | 3 (`pi-cerebras-*`) | darwin only | 3 | — |
| fold-target combos (`opencode-opencode-deepseekv4flash`, `pi-cerebras-glm47`) | 0 — no collision | — | — | — |
| parent coverage today | `deepseekv4flash`: 22 provider-harness rows; `glm47`: `omp-gmicloud-*` 3 rows | — | — | zenmux/clinepass list parents, not the `-free` twin (except opencode) |

## Options

### A — Status quo: nothing retroactive (pure non-retroactivity)

Keep all 100 rules as they are; the policy governs future additions
only; queue the 12 orphans' rows so the contract test can go green.

- **Wins**: zero identity churn — every `<agent_id>@local` trailer
  already written into downstream git histories stays valid; zero
  recapture cost; simplest history.
- **Losses**: the table keeps two known same-model split rules
  (`-free`, `zai-` prefixed) that the policy calls foldable — new
  contributors see contradictions and may re-litigate them; the
  alias resolver stays ambiguous in spirit (two rules with
  near-colliding alias surfaces kept apart only by deliberate label
  skew).
- **Effects**: docs gain a sentence that A is a deliberate,
  bounded exception ("splits grandfathered 2026-08; no new splits").

### B — Fold the two same-model splits (recommended slice)

Delete the `deepseek-v4-flash-free` and `zai-glm-4.7` rules; add
their old names+labels as `variations` on the parents
(`deepseek-v4-flash` += `deepseek-v4-flash-free`,
`DeepSeek V4 Flash (free)`; `glm-4.7` += `zai-glm-4.7`,
`Z.ai GLM 4.7`). Migrate state:

- store: drop the 6 fold-id rows from the fixtures map, drop the 3+3
  queue entries (dequeue), enqueue replacement from-identity rows at
  the parent combos (`opencode-opencode-deepseekv4flash-*`,
  `pi-cerebras-glm47-*`) — daemon writes them, zero tokens;
- `free_provider_to_model.opencode`: `deepseekv4flashfree` →
  `deepseekv4flash`; re-check the free-signal test (the opencode
  combo launches via harness config default → exemption path exists,
  verify it holds);
- files: old `fixtures/*-deepseekv4flashfree-*.json` /
  `*-zaiglm47-*.json` become orphans whose ids resolve to no row —
  delete at user discretion (CONTRIBUTING: "purging fixture files
  is user discretion") or keep as history;
- alias-uniqueness test re-passes automatically (old aliases move to
  the parents; nothing collides);
- docs: one note that B executed the grandfathered splits.

- **Wins**: the table says exactly one thing per model forever;
  live detection of opencode's free alias resolves to the canonical
  `deepseek-v4-flash` (the fold machinery earns its first real
  dedup); future `-free`/`zai-` style additions have zero incentive
  to become rules; `check-reciprocal` outcomes unchanged (same
  reciprocity + license values on the parents).
- **Losses**: **identity break**: `opencode-opencode-deepseekv4flashfree@local`
  and `pi-cerebras-zaiglm47@local` already appear in git trailers of
  anything that ran these combos; after B, detection of the same
  live setup emits `…-deepseekv4flash@local` / `…-glm47@local` —
  two different emails for one historical model-run lineage. Rebuild
  bumps + `--stale-by-detect-version` sweeps will regenerate the
  from-identity channels anyway; capture channels for the deleted
  rows are lost to history (re-capturable, tokens).
- **Effects**: the two rows' `harness_version`/capture ledgers
  disappear; the evergreen-combo matrix loses `-free` as a separate
  test slot (the free axis now rides the parent row, matching the
  table's own per-(provider,model) free semantics — arguably a bug
  fix, since free-ness was always provider-tier, not model).

### C — Heal the 12 orphans (independent of A/B)

For each orphan, enqueue one evidence-backed `--unknown
--from-identity` row (declared, zero tokens). Candidate combos from
the grids (provider actually serves the model): `qwen3.5` →
kimicode-openrouter; `gemini-3.1-pro` → qwen-google (baseUrl maps to
`google`) or kimicode-openrouter; `gpt-5.5` → kimicode-openrouter;
`grok-3-mini`, `claude-opus-4`, `claude-haiku-4` → openrouter
combos; `glm-4.6` → kimicode-openrouter; `devstral-2` →
vibe-mistral or opencode-mistral; providers `cline` →
cline-cline-* direct combo; `moonshot` → kimicode-moonshot-kimik3;
`google` → the gemini row's provider dim; `qwen3.7-plus` →
crush-qwen37plus-* (the crush hyper.json provider-key case its rule
comment documents).

- **Wins**: the contract test goes durably green after the pending
  daemon run (today it is red-behind-red); every rule becomes
  detectable+declared somewhere, so recipe mode + queue tooling
  cover the full table; exposes the orphan class as fixed, not
  latent.
- **Losses**: 12 declared-but-never-captured rows (matrix grows
  without evidence depth — that is what from-identity *is* for, but
  it slightly dilutes "known universe" with combos we only infer
  plausible; pick only combos with real evidence — the grids cap
  this).
- **Effects**: more daemon pop volume (zero tokens, ~5s each).

### D — Codify the family-alias interpretation (docs-only)

Amend CONTRIBUTING's identity section to state: a **hosted alias
rule** (`qwen3`, `qwen3.5`, `qwen3.6`, `qwen3-coder`, `llama-4`,
`mistral-*-latest`) is the *service's own model name*, not a family
bucket — it may coexist with per-size rules of the same line
(`qwen3.5` + `qwen3.5-397b-a17b` is legal; the alias must NOT carry
size-encoding variations). The alternative (D2: split every family
rule into per-size rules and retire the aliases) is rejected.

- **Wins** (D): kills the ambiguity cheaply; matches what the
  chutes/opencode-go sweep already does in practice; preserves every
  existing agent_id (35+ rows ride family ids).
- **Losses** (D): a family id observed *as a bare serving spelling*
  (e.g. `Qwen/Qwen3.6-27B`) still has no rule to fold into if the
  27B size isn't evergreen/needed — acceptable (never-guess keeps it
  raw) but leaves a known thin spot.
- **Effects** (D2, if chosen): mass renames (9+ rows for
  `qwen3coder` alone), trailer-email breaks across several harness
  matrices, weeks of regen — strictly worse than D at every axis.

### E — Everything (B + C + D) — recommended

One coherent sweep: table semantics, store contract, and policy text
all say the same thing; the pending daemon run then heals the
18-field bump, the 16 new-rule rows, the 12 orphans, the pi legacy
file, and the fold replacements in one pass.

## Trade-off summary

| option | table truth | identity stability | test durability | token cost | user action beyond daemon |
|---|---|---|---|---|---|
| A | two known splits persist | fully stable | green after C-less heals, orphans latent until swept | 0 | none |
| B | exact | 2 trailer emails break (historical) | green | 0 (recaptures optional) | dequeue/enqueue approval, file purge call |
| C | unchanged | stable | **green (removes last latent reds)** | 0 | none |
| D | unchanged | stable | unchanged | 0 | none |
| E | exact + stable aliases | only the 2 B breaks | green, durable | 0 | same as B |

## Code-impact inventory (E)

- `src/lib/rules.zig`: −2 rules, +2 variation sets, comments.
- `fixtures/.index.json`: −6 rows, −6 queue entries (dequeue), +2
  parent-combo from-identity queue entries (3 platforms each), +12
  orphan queue entries, `free_provider_to_model` remap (1 key move).
- `fixtures/*.json`: 2 darwin files for fold ids → user purge
  decision; 12+6 new declared files land via daemon.
- `src/known_fixtures.test.zig`: no change (dims resolve via
  variations; the free-signal exemption check must pass on the
  remapped opencode entry — verify).
- `CONTRIBUTING.md`: family-alias clause (D), B-execution note,
  fold-completed cleanup in the verdicts.
- No `core.zig`/`dev.zig` changes; resolution machinery is already
  in place from the main change.

## Decisions needed

1. A (leave splits) or B/E (fold them)? Deciding factor: how much
   the two historical trailer emails matter vs. table self-consistency.
2. C: approve the 12 orphan combos (or name better ones — combos
   are declared-only, but should be real).
3. D: approve the hosted-alias clause wording (docs-only).
4. Disposition of the 2 orphaned fold-id fixture files (purge or
   keep).
5. Implementation commits still owed from the main change (user's
   call, unchanged).
