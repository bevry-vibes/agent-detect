# Seed rows are actions: re-queue all applicable combos on expansion

## Context

`known/index.jsonl` is a state store with one event per 4-tuple; partial rows (missing dims) are **seeds**. The daemon's `expandSeed` (src/main.zig:3899) expands seeds over the `knownFixturesForKnownAgents` recipes and then deletes the seed (phase-1 plan, Decision 8).

**Current behavior (the gap):** a combo row that is already `refresh:false` is *skipped* — the seed only fills missing combos. So `known queue --harness=goose` flips existing goose rows (create-or-flip), but a `refresh:true, harness:goose` **seed** — the `known queue` no-match branch, or a partial `known agent` detection — does NOT refresh already-captured combos. Observed live: seed `harness:goose platform:darwin` was processed with no goose re-capture line at all.

**Decided semantics (user-confirmed):** a `refresh:true` partial row is an **action**: "re-run the recipes matching my set dims". `harness:goose` refreshes existing goose entries AND adds missing combos; `harness:goose provider:X` constrains to goose×X. `known queue` and seeds are one and the same verb (create-or-flip); no separate `known seed` command.

**Working-tree caveat:** a partial DRAFT edit to `expandSeed` already exists (src/main.zig:3888-3954). Reconcile it — do not reuse blindly:
- (a) the call site (src/main.zig:3832) still passes only `&warned` → **does not compile**;
- (b) the draft clears BOTH `processed` and `queued` — `queued` must NOT be touched (see Decision 2).

## Decisions

1. **Seed = action.** `expandSeed` re-queues EVERY applicable combo as a full `refresh:true` row via upsert — unconditionally, regardless of a prior `refresh:false` — then deletes the seed. Applicability is unchanged: recipe set-dims equal the seed's set dims, seed platform empty-or-host, and `harnessAvailable(io, combo.agent_alphanumeric_id)`. No-applicable-recipe still warns once per run and leaves the seed unchanged.
2. **Clear `processed` only, never `queued`.** After upserting a combo, do `_ = processed.remove(combo_key);`. `processed` and `queued` are disjoint: a key is in `queued` only while its event sits in the poll queue array, and enters `processed` only after it is popped. Clearing `queued` would let the next `enqueuePending` append a combo that is already in the queue → the same combo captured twice in one poll. If the combo is pending in the queue it will be captured anyway; if it was already processed this run, clearing `processed` re-arms it — which is exactly the point.
3. **Signature:** `fn expandSeed(a, io, ev, warned: *std.StringHashMapUnmanaged(void), processed: *std.StringHashMapUnmanaged(void)) !void` — drop the draft's `queued` parameter.
4. **No new command.** `known queue` already create-or-flips; documents should state that a seed is just the persisted form of the queue action.
5. **Warn-and-keep unchanged.** Seeds with applicable-but-unavailable harness or unknown dims warn once per daemon run and are left unchanged.

## Tasks

### 1 — `expandSeed` final form (src/main.zig:3888-3954)
- Signature: `expandSeed(a, io, ev, warned, processed)`.
- Applicability loop: unchanged (`recipeMatchesEv` + `harnessAvailable`).
- If `applicable.items.len == 0`: warn-once path unchanged.
- For each applicable recipe: upserve the full combo as `refresh:true` (`.runner = getParentPid()`, `.generated_at = now`, platform = host); then `_ = processed.remove(combo_key);`.
- Keep at the end: `deleteTupleKey(a, io, "known/index.jsonl", seed_key);`.
- Update the doc comment above `expandSeed` to the action semantics: "re-queues every applicable combo — refreshing existing `refresh:false` entries and adding missing combos — deletes the seed, and clears `processed` so this run re-enqueues combos captured earlier."

### 2 — call site (src/main.zig:3832)
- Change `try expandSeed(a, io, ev, &warned);` to `try expandSeed(a, io, ev, &warned, &processed);`.

### 3 — docs
- **DESIGN.md** (~73-81): clarify that every applicable combo is re-queued `refresh:true` (refreshing existing rows and adding missing ones) when a seed is expanded.
- **CONTRIBUTING.md** (~18-22): same clarity; optionally state that `known queue`'s no-match branch *is* the seed (one verb).
- **dev.knownUsage** (~2050): daemon subcommand text remains accurate; optional one-phrase note that expansion re-runs the matching recipes.

### 4 — supersede the phase-1 plan lines
- `.kilo/plans/1786024609174-partial-index-filter-daemon.md` lines 20 (Decision 8) and 73 (Task 6) say "unless already `refresh:false`" — amend to the action semantics and point to this plan.

## Validation

1. `zig build`, `zig build dev`, `zig build test` all green.
2. User restarts the daemon (`Ctrl+C`, then `known daemon --write-log`) so it runs the rebuilt binary and the log is clean (the current log has ~18KB NUL padding from an out-from-under truncation).
3. **Refresh-existing:** ensure goose rows are `refresh:false`, then `known queue --harness=goose --no-provider --no-model` → seed `harness:goose`. The daemon must log a re-capture of `goose-goose-claudesonnet4-darwin` (previously silently skipped), the row returns to `refresh:false` with a new runner, and the seed row is deleted.
4. **Add-missing:** `known purge --harness=goose --provider=goose --model=claudesonnet4 --platform=darwin` (removes just the darwin row), then repeat scenario 3 → the daemon re-adds that row before capturing it.
5. **Constraint:** `known queue --harness=goose --provider=zzz` → warn-and-keep, seed unchanged, warning once per run.
6. **Full-row create-or-flip unchanged:** `known queue --harness=goose` (matches rows) still prints `known queue: queued N` and flips the rows.
7. **Partial `known agent`:** a harness-only session (as with the earlier `env -i HOME=... GOOSE_WORKING_DIR=...` repro) records a seed → the daemon now re-captures that harness instead of silently consuming the seed.
8. **No duplicate captures:** if a combo is already sitting in the poll queue when a seed is processed, the log must show it captured once (not twice).

## Risks / notes

- Re-capturing already-captured combos is now expected: a seed is an explicit refresh action. Churn is bounded because a successful capture flips the combo back to `refresh:false` and the seed is deleted — there is no self-perpetuating loop.
- A failed capture leaves the combo `refresh:true`; `processed` still bounds retries to once per run unless a seed re-arms it (existing retry behavior preserved).
- No locking beyond the existing `upsertIndexEvent` rewrite; single daemon assumed.
- Work already applied earlier this session and NOT part of this plan's diff: `queued seed` message de-duplication, `known agent` partial message de-duplication, and newline-aware daemon log prefixes (single `[sec.ms]` per line). These are in the working tree and should remain.
