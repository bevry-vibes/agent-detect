# Consolidate `queue-{stale,all,missing,fixtures}` into scope filters on `known queue`/`dequeue`/`purge`

## Context

Today the dev `known` namespace has four near-duplicate subcommands that differ only in *what set of events* they target:
- `queue-all` (src/main.zig:3345) — flip every **index row** on host platform whose harness is available.
- `queue-stale` (3265) — flip index rows that are stale: `refresh:true` with a dead runner, or older than a threshold (default 7d; `--older-than-days=`/`--older-than-hours=`).
- `queue-missing` (3378) — iterate the **recipe table** (`knownFixturesForKnownAgents`), queue any whose `known/<id>.agent.json`/`.trailer.txt` files are absent on disk (if no `refresh:true` row is already pending).
- `queue-fixtures` (3461) — iterate the recipe table, queue any recipe that has no `refresh:false` row.

All four are flip-only; the generic `known queue <dims>` (3117) already does create-or-flip + seed. The `knownUsage` line 2083 ("queue-fixtures regenerate known/index.jsonl from disk") is stale — the impl is a bulk re-queue over recipes.

Goal: delete the four subcommands and express their behavior as **scope filters** shared by `queue`, `dequeue`, and `purge`, so the CLI is one verb + filters rather than five verbs. `parseFilters`/`FilterOptions` (2828-2980) is the natural home.

**Related plan (do not re-implement here):** `.kilo/plans/1786031823390-seed-action-refresh-semantics.md` — `expandSeed` re-queues ALL applicable combos as `refresh:true` (a seed is an action) and clears the daemon's `processed` set. That plan's code draft also touches `runKnownQueue`'s output messaging. Keep the two changes consistent; this plan does not modify `expandSeed`.

## Decisions

1. **Names (user-confirmed):** row-scope `--all`, `--stale`, `--partial`; recipe-scope `--recipes`, `--missing-fixture`. No `--no-fixture` (would collide with the `--no-*` dim family). No `--full` counterpart (user chose `--partial` only; `--all` already covers everything and full rows are addressable via dim filters).
2. **Uniform scope model:** each scope flag selects a *candidate set*; each verb applies its action to that set:
   - `--all` → every index row on the host platform, as today's `queue-all`.
   - `--stale` → stale subset of index rows (dead-runner `refresh:true` OR older than threshold). Threshold flags keep their names and default (7 days).
   - `--partial` → index rows with at least one missing dim (negation of the daemon's `full` test at src/main.zig:3815-3818) — i.e. seeds already in the index. `queue --partial` re-arms them as `refresh:true` actions (flip-only, no new rows), `dequeue --partial` marks them done, `purge --partial` deletes them.
   - `--recipes` → the full recipe table (`knownFixturesForKnownAgents`), as today's `queue-fixtures`.
   - `--missing-fixture` → recipe tuples whose `.agent.json` AND/OR `.trailer.txt` are absent from disk, as today's `queue-missing`.
   - Actions: `queue` ensures candidates have `refresh:true` rows (creating full rows for recipe-scope candidates; flip-only for row-scope); `dequeue` sets `refresh:false` on existing candidate rows; `purge` deletes existing candidate rows.
3. **`--available` modifier + flipped defaults (user-confirmed):** scope flags do **not** gate on availability by default — `--recipes` queues *every* known recipe (host platform) even if the harness binary is missing, and `--missing-fixture` has no availability gate (as today). `--available` is an orthogonal modifier (combinable with exactly one scope flag + dim filters) that restricts candidates to those whose harness is available (`harnessAvailable(io, agent_alphanumeric_id)`). Under `--available`, candidates where the harness cannot be determined — e.g. `--partial` rows missing h-p-m, or recipes with no probe — are excluded.
4. **Share with dequeue/purge (user-confirmed):** all five scope flags (`--all`, `--stale`, `--partial`, `--recipes`, `--missing-fixture`) and `--available` work on all three verbs. `purge --all` / `purge --recipes` intentionally reintroduce bulk delete — the user accepted the risk; the `>=1 filter` guard still blocks bare `purge`.
5. **Dim filters compose (AND):** dim filters (`--harness=`, `--provider=`, `--model=`, `--platform=`, `--no-*`, `--agent=`, `--known=`) may combine with a scope flag to narrow the candidate set. With no scope flag, dim filters keep today's per-verb semantics.
6. **Exactly one scope flag** per invocation (`--all`+`--stale` etc. → `ConflictingFilters`). `--older-than-*` is only valid with `--stale` (else error). `--available` is a modifier, not a scope flag, and may combine with any single scope flag.
7. **At least one selector:** one scope flag OR one dim filter required, else exit 2 with the existing NoFilter message/usage.
8. **Seeds stay dim-only:** with a scope flag, `queue` never creates a partial seed row (recipe-scope creates *full* rows for the recipe tuples; row-scope only flips existing rows). Partial seeds remain the exclusive result of dim-filter `queue` and `known agent` partial detection.
9. **Verb messages:** keep the `known <verb>: ...` prefix; drop the per-subcommand names (`queue-all`, etc.) everywhere.

## Tasks

### 1 — extend `FilterOptions`/`parseFilters` (src/main.zig:2828-2964)
- Add fields: `all: bool`, `stale: bool`, `partial: bool`, `recipes: bool`, `missing_fixture: bool`, `available: bool`, `older_than_days: ?i64`, `older_than_hours: ?i64`.
- Parse the new flags in the argv loop (`--all`, `--stale`, `--partial`, `--recipes`, `--missing-fixture`, `--available`, `--older-than-days=`, `--older-than-hours=`); parse the threshold values as integers (same error style as `queue-stale` today: message + exit path via a new `FilterError.InvalidThreshold`).
- `f.any` includes the five scope flags.
- New conflict rules: >1 scope flag → `ConflictingFilters`; `--older-than-*` without `--stale` → `ConflictingFilters`; `--available` requires a scope flag → `ConflictingFilters` (or NoFilter if nothing else present — pick the clearer of the two and match dequeue/purge messaging).

### 2 — refactor `runKnownQueue` (3117) into scope + dim paths
- Build the candidate set (default: NO availability gate; `--available` narrows):
  - `--recipes` → every `knownFixturesForKnownAgents` entry on the host platform (all harnesses, available or not, unless `--available`), a candidate tuple; `queue` upserts full `refresh:true` rows (skip if an existing `refresh:false` row is present — same dedupe as `queue-fixtures`).
  - `--missing-fixture` → recipe tuples with a missing fixture file; dedupe against any existing `refresh:true` row (same as `queue-missing`). Availability gating applies only under `--available`.
  - `--all` → every index row on the host platform (flip-only). `--stale` → stale subset (dead-runner `refresh:true` OR older than threshold). `--partial` → index rows with ≥1 missing dim. Row-scope flips via existing row-preserving upsert; under `--available` each row must have full h-p-m with an available harness (partial rows auto-excluded).
- With no scope flag: unchanged create-or-flip + seed path (incl. the "needs a positive dim" seed rule and the dequeued message fix already in the working tree).
- Print `known queue: queued N` (keep `, skipped N` only where a variant already prints it — prefer single count for uniformity).

### 3 — refactor `runKnownDequeue` (3569) and `runKnownPurge` (3629)
- Apply scope candidates: dequeue sets `refresh:false` on existing rows in the candidate set; purge deletes them. Dim-only behavior (+ `>=1 filter` guard) unchanged.

### 4 — delete the four subcommands
- Remove `runKnownQueueStale` (3265), `runKnownQueueAll` (3345), `runKnownQueueMissing` (3378), `runKnownQueueFixtures` (3461).
- Remove their dispatch branches (4222-4229); update the dispatch comment (4195-4200) to the new filter vocabulary.
- Update `knownUsage` (2048-2089): delete the four `queue-*` lines; expand the `filters` section with the scope flags (`--all`, `--stale`, `--partial`, `--recipes`, `--missing-fixture`), the `--available` modifier, and the threshold flags (`--older-than-days=`, `--older-than-hours=`), noting they are shared by queue/dequeue/purge, exactly one scope flag per call, and `--available` further narrows by harness availability.

### 5 — docs
- CONTRIBUTING.md "For batch refreshes" paragraph (68-71) → describe the scope filters (`--all`, `--stale` (with threshold), `--partial`, `--recipes`, `--missing-fixture`), that they queue by default regardless of harness/platform availability, and that they can be narrowed with dim filters and `--available`; remove the `queue-*` command names.
- DESIGN.md: only if it names `queue-*` (verify; the state-store section mostly uses "seed/daemon" language — update any mention).

## Validation

1. `zig build`, `zig build dev`, `zig build test` all green.
2. `known queue --recipes` queues one full `refresh:true` row per known recipe on the host platform **even when the harness binary is unavailable**, skipping recipes already `refresh:false`; idempotent on rerun. `known queue --recipes --available` queues only harnesses whose binary is present.
3. `known queue --missing-fixture` queues only recipes whose files are absent (e.g. after `rm known/<id>.agent.json`); skips if a `refresh:true` row is pending. `--missing-fixture --available` narrows to available harnesses.
4. `known queue --stale` on a row with a dead runner / old `generated_at` flips it; `--older-than-days=0` catches everything; integer parse error exits 2.
5. `known queue --all` flips every host-platform row regardless of availability; `--all --harness=crush` flips only crush rows; `--all --available` flips only rows whose harness is available.
6. `known queue --partial` re-arms existing seed rows (rows with ≥1 missing dim) as `refresh:true` (flip-only, no new rows); `--partial --available` excludes partial rows whose h-p-m can't be derived.
7. Scope × dequeue/purge: `known dequeue --stale`, `known purge --all`, `known purge --partial` behave. `>1 scope flag`, `--older-than-*` without `--stale`, and `--available` without a scope flag exit 2.
8. Bare `known queue`/`dequeue`/`purge` still exit 2 (NoFilter); dim-filter seeds still work (`known queue --harness=goose --no-provider --no-model` → seed row; daemon re-captures under the seed-action plan).
9. Usage text and CONTRIBUTING show the scope filters, no `queue-*` remnants (grep repo).

## Risks / notes

- `purge --all` / `purge --recipes` / `purge --partial` are destructive by design (user accepted). The `>=1 filter` guard prevents a bare `purge`, but `purge --all` has no other safety net — the fixture sweep (`purgeMalformedFixtures`, 3691) still runs on every `purge`.
- Recipe-scope candidates resolve to the **host platform** only (as today's fixture-based commands). By default nothing is gated on harness availability; `--available` applies the gate.
- Flipped availability defaults change behavior vs. today: `queue-all`/`queue-stale`/`queue-fixtures` previously skipped unavailable harnesses — those invocations now queue everything unless `--available` is added. Intentional per user decision.
- Compatibility break is intentional: old `queue-*` spellings will fail with the unknown-subcommand message; docs/usage updated accordingly.
- The daemon's `--write-log` behavior and the seed-action semantics plan are unaffected by this CLI change.
