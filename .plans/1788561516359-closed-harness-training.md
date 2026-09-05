# closed-harness-training

Assisted-by: ZCode · GLM 5.3 <zcode-clinepass-glm53@local>

Provenance: [1788561516359-closed-harness-training.prompts.md](./1788561516359-closed-harness-training.prompts.md)

## context

Today a closed-source harness (`harness_license == "NONE"` — cursor, copilot,
zcode) is unconditionally `.not_reciprocal`: `computeReciprocal`/
`reciprocityOf` (`src/lib/core.zig:2108-2154`) fail the harness conjunct
before the model/provider conjuncts are even consulted. The user wants a
closed-source harness to be *permitted* when it is verified to not train on
user conversations — zcode's "Improve experience / Allow us to use your
conversations to improve the Agent experience" toggle
(`optimizeAgentExperienceEnabled` in `~/.zcode/v2/setting.json`, read-only)
being the first instance signal. This adds a new harness-training dimension:
a docs-derived static posture on the rule table plus an instance-resolved
state on `Detection`, with the conjunct gated to closed harnesses only.

Research performed during planning (2026-09-05):

- zcode: the toggle is persisted as `optimizeAgentExperienceEnabled` in
  `~/.zcode/v2/setting.json` — the same file `detectZcode` already parses
  for `modelProviderFamilySelectedKeys`.
- cursor: `cursor-agent` writes `~/.cursor/cli-config.json` with
  `privacyCache.privacyMode` (observed value `2` alongside `ghostMode:
  true`) — a candidate instance signal, gated on verifying the enum
  semantics from Cursor's public policy pages.
- copilot: no local training/opt-out artifact exists (config.json is
  auto-managed auth state; settings.json empty; DBs are sessions only) —
  instance state stays null.
- Public-doc citation was blocked from the planning session (plan mode
  blocked curl/gh api; docs.github.com and cursor.com block the fetch
  agent; the subagent provider hit its usage limit) — static rule values
  stay null until sources are cited at implementation time (never-guess).

## decisions (confirmed with user)

1. **Four-state harness-training determination** — coincides with provider
   handling (null dims → unknown, encouraging closed-harness users to
   correct their data; "we looked but couldn't determine a clear answer"
   fails safe):
   - `NONE` + `null` (no data) → `.unknown` (exit 9), same as null
     `provider_closed_training`/`model_reciprocity` today.
   - `NONE` + `"training"` → `.not_reciprocal` (exit 10).
   - `NONE` + `"not-training"` → fall through to model/provider conjuncts.
   - `NONE` + `"inconclusive"` (looked, no clear answer) →
     `.not_reciprocal` (exit 10) — mirrors the license field's
     `NOASSERTION` semantics (attempted-but-inconclusive ≠
     never-attempted).
2. **Training conjunct applies to closed-source harnesses only** (`license
   == "NONE"`); open-source harness reciprocity is unchanged.
3. **No `--harness-training` recipe flag** — new branches covered by unit
   tests and future live captures.
4. **No fixture-file edits** — committed fixtures regenerate organically
   via the existing `--stale-by-output` queue/dequeue sweeps; the
   identify_keys test exempts the new key for pre-growth fixtures
   (existing precedent: the raw-schema keyset test).

## determination matrix

| harness_license | harness_training        | result                                    |
| --------------- | ----------------------- | ----------------------------------------- |
| SPDX id         | (n/a)                   | fall through to model/provider conjuncts  |
| null / NOASSERTION | (n/a)                | `.unknown` (unchanged)                    |
| NONE            | `"training"`            | `.not_reciprocal` (exit 10)               |
| NONE            | `"not-training"`        | fall through to model/provider conjuncts  |
| NONE            | `"inconclusive"`        | `.not_reciprocal` (exit 10)               |
| NONE            | `null`                  | `.unknown` (exit 9)                       |

`harness_training` is a string tri-state-plus-null (house style, like
`model_reciprocity`; a bool cannot express the inconclusive state).

## revision: provider-mirrored two-field schema (2026-09-05, same session)

Supersedes the single `harness_training` dimension (committed 928fb7e)
after user review: the dimension mirrors the provider two-field model
exactly.

- `HarnessRule` gains `open_training` + `closed_training` (vocabulary
  `enforced | opt-in | opt-out | never | NOASSERTION | null`,
  docs-derived, never-guess) + one `training_sources` array.
- `Detection`/`buildCooked` gain `harness_open_training` +
  `harness_closed_training` (19 → 20 identify fields);
  `harness_open_training` is informational (like
  `provider_open_training`).
- Resolution per field: instance read wins (zcode toggle:
  `false` → `never`/`never`; `true` → open `enforced` + closed
  `NOASSERTION` fail-safe; key absent → `NOASSERTION`/`NOASSERTION`;
  file missing → untouched); static fallback copies the rule verbatim.
- Conjunct (gated to license NONE, consumes only
  `harness_closed_training`): `enforced`/`NOASSERTION` →
  `.not_reciprocal` (10); `null` → `.unknown` (9);
  `never`/`opt-in`/`opt-out` → fall through to model/provider —
  capability-based, mirroring `provider_closed_training`.
- Sourced values: cursor `opt-in`/`opt-in` (privacy policy: no
  training without explicit agreement); copilot closed `opt-out`
  (ToS J.3: trains unless account-settings opt-out), open `null`.
- Z.ai catalog research (this session): the served lineup is open-weight
  EXCEPT GLM-ASR-2512 — API-only (HF 401 under zai-org and THUDM; only
  the Nano variant has public weights) — so Z.ai does have a closed
  model and the blanket `closed_training = "never"` is structurally
  unsafe: zcode stays `null`/`null` with the toggle-ON fail-safe.
- Post-plan follow-up (user, noted): evaluate `open_training_config` /
  `closed_training_config` fields to isolate training policy
  (docs-derived posture) from active training config
  (instance-determined state); revisit once live captures exercise the
  merged fields.

## work items

1. `src/lib/rules.zig` — `HarnessRule` gains `training: ?[]const u8 =
   null` (static posture: `enforced | opt-in | opt-out | never |
   NOASSERTION | null`, never-guess) and `training_sources: []const
   []const u8 = &.{}` mirroring `license_sources`. Closed-harness rule
   entries keep `training = null` until sources are cited.
2. `src/lib/core.zig` — `Detection` gains `harness_training: ?[]const u8
   = null`; shared resolution helper (instance read wins; static fallback
   `"never"` → `"not-training"`, `"enforced"` → `"training"`,
   `"NOASSERTION"` → `"inconclusive"`, else null) applied in `detect()`
   before the compute step and in `resolveRecipe()`.
3. `detectZcode` — extend the existing `~/.zcode/v2/setting.json` parse
   with `optimizeAgentExperienceEnabled`: `true` → `"training"`, `false`
   → `"not-training"`, file-present-key-absent → `"inconclusive"`, file
   missing → `null`. Recorded as a `FileObservation` field + evidence
   claim (dim harness, source config). Read-only.
4. `computeReciprocal`/`reciprocityOf` — the matrix above.
5. `buildCooked` — insert `harness_training` after `harness_license`
   (18 → 19 fields); `fixtures/fixture.d.ts` `Identify` gains the optional
   field.
6. Tests — `src/exit_statuses.test.zig`: the six-cell NONE matrix;
   `src/known_fixtures.test.zig`: `identify_keys` gains
   `harness_training` with the pre-growth exemption (raw-schema
   precedent). No fixture files are edited.
7. CI — cursor case becomes exit 9 (empty stdout + data-incomplete
   stderr); keep not-reciprocal coverage via a validated closed-model
   recipe combo.
8. Docs — README (reciprocity section + stale PowerShell comment), 
   DESIGN.md (19-field contract, exit registry, harness training
   posture), CONTRIBUTING.md (rule field table + resolution order +
   never-guess).
9. Follow-up research (separate commits, never-guess): z.ai coding-plan
   provider training values; ollama local-serving training value (the
   likely first live reciprocal combo is zcode + ollama +
   glm-5.3-flash); cursor privacy-mode doc verification + wiring;
   copilot data-usage doc relocation.

Hard constraints: no harness config writes ever; the user alone toggles
their own "Improve experience" / privacy settings — the project never
flips them, including for testing.
