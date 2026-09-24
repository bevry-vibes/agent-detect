# Identity fixtures carry `outputs.raw`, and the scandal booleans become explicit `true`/`false`

Two schema changes, one regeneration pass. Per DESIGN #16 no file is hand-edited — the drain rewrites them.

## A. The scandal booleans: null-as-absent → always emitted

1. **`src/lib/core.zig` `buildCooked`** (lines 2502, 2509): drop the `if (d.…_reciprocity_scandal)` gates — emit `harness_reciprocity_scandal` and `provider_reciprocity_scandal` as `.{ .bool = d.… }` unconditionally, in their current emission positions (before the computed `*_reciprocity`). Update the doc comment at 2486 (the settings stay null-as-absent; the scandal flags are explicit booleans).
2. **`src/known_fixtures.test.zig`**: add both keys to `identify_keys` at their emission positions (`harness_reciprocity_scandal` before `harness_reciprocity`; `provider_reciprocity_scandal` before `provider_reciprocity`) — the list finally holds all 29 keys its name advertises; fix the stale "20 canonical" header comment. Add both to `growth_exempt_keys` so pre-growth fixtures (which lack them) stay valid until their next sweep; replace the line-106 "never join identify_keys" comment.
3. **`fixtures/fixture.d.ts`**: `harness_reciprocity_scandal?: true` → `harness_reciprocity_scandal: boolean` (same for provider), header note that pre-growth fixtures may lack the keys until regeneration.

## B. Identity fixtures gain `outputs.raw` — the rule-derived evidence

The declared raw is a **reduced** shape: only what the rules actually assert. Instance-observation fields (`platform_id`, `harness_version`, `process_lineage`, `evidence`) stay absent — a declared fixture observed nothing, and the worker's own lineage would be fiction.

1. **`src/dev/dev.zig`**: new `buildDeclaredRaw(a, &d) !std.json.Value` emitting, in order: `detectable`, `detected` (via the existing `detectedDims` helper), `harness-urls`, `provider-urls`, `model-urls`, `scandal-urls` — `resolveRecipe` already populates all six from the rule tables (core.zig 2800-2823), so this is pure assembly.
2. **`runOneComboIdentity`**: build and put `raw` into `outputs` after the two trailers (matching the capture channel's key order); rewrite the "carries no raw block" comment.
3. **Tests**: the envelope-shape test's identity branch — outputs count 3 → 4, allow `raw` beside the whitelist; add a tolerant declared-raw schema test over `identity_dir` (present ⇒ exactly the six keys, `*-urls` items `https://`, `detectable`/`detected` len 3; absent ⇒ pre-growth, tolerated). The two existing capture-scoped raw tests stay untouched.
4. **`fixtures/fixture.d.ts`**: new `DeclaredRaw` interface; `IdentityFile.outputs` gains `raw: DeclaredRaw`; channel-header docs updated.
5. **`DESIGN.md`**: decision #9 (the scandal flags are explicit booleans; raw is no longer capture-only — identity carries the declared raw); the channel description at ~45; the evidence-attribution rule at ~381 ("Declared fixtures carry no evidence at all" → they carry the rule-derived URL evidence; instance-only fields stay absent); the stale "20-field" counts at ~219.

## C. Propagation — one zero-token refresh sweep

Build + full test run, commit (selective staging — the other agent's files stay out). Then queue the whole identity universe for regeneration:

```sh
./zig-out/bin/agent-detect-dev fixtures queue --refresh --from-identity
```

The running transient-unit daemon rewrites every identity file with the new shape (~2,000 files at the 0.25s pacing, zero tokens); pre-growth files gain the booleans and the raw block in the same pass. Review a sample, `zig build test` green, commit the regenerated batch. The flag-bearing fixtures (deepseek, anthropic, xai, github-copilot, copilot) will now visibly carry `*_reciprocity_scandal: true` and `scandal-urls` — the visibility that motivated this.