# Partial-index entries, filterable queuing, daemon expansion, and `.agent.json` fixtures

## Context

The `known` fixture workflow curates real captures of known agents in `known/index.jsonl` (one event per combo) plus generated fixtures. Today `known queue` requires `--harness`, fabricates flat `agent_alphanumeric_id`/`known_alphanumeric_id` from h-p-m (collapsing partials), `purge` deletes incomplete rows, the daemon only executes rows that match a full recipe, `known agent` writes nothing on partial detection, and fixtures are `<known-id>.json`.

Goal: first-class *partial* rows (seeds) so we can queue/test by any subset of harness/provider/model/platform, have the daemon expand seeds over known recipes, warn-and-keep what it cannot handle, and rename fixtures to `<known-id>.agent.json`.

All decisions below were confirmed with the user.

## Decisions (resolved)

1. **IndexEvent stores facts only** — drop stored `agent_alphanumeric_id` and `known_alphanumeric_id` (derived). Keep `refresh`, `runner`, `generated_at`, and the four dims `harness_alphanumeric_id`, `provider_alphanumeric_id`, `model_alphanumeric_id`, `platform_alphanumeric_id`, each nullable. All empty/falsey values serialize as JSON `null`.
2. **Row identity = 4-tuple key** `(h, p, m, platform)`; partial rows have empty slots. Upsert/dedupe/lookup operate on the tuple, not a flattened id. In-memory helpers `agentId(h,p,m)` / `knownId(h,p,m,platform)` return null when any dim is missing (used for fixture naming and messaging only).
3. **Shared filter language** for `queue`, `dequeue`, `purge`. The four *dimension flags* are `--harness=`, `--provider=`, `--model=`, `--platform=` (written `--X=` below), their null-constraining variants are `--no-harness`, `--no-provider`, `--no-model`, `--no-platform` (written `--no-X`). Plus two shorthands: `--known=` (4-part full id → h,p,m,platform) and `--agent=` (3-part → h,p,m, leaving platform unfiltered unless `--platform=` is also given). Semantics: a `--X=` value constrains that dim to equality; `--no-X` constrains it to null; an unmentioned dim is unconstrained (any, including null); `--agent=` sets h,p,m and composes with `--platform=`. Conflict rules: `--known=` cannot combine with `--agent=` or any `--X=`; `--agent=` cannot combine with `--harness=`/`--provider=`/`--model=`, but may combine with `--platform=` (identical to `--known=` when combined).
4. **At least one option/filter required** for `queue`, `dequeue`, and `purge`; otherwise error + usage, exit 2.
5. **`known queue` = create-or-flip.** If existing rows match the filter: set them all to `refresh:true`. If none match: create a seed row with the positive dims set (from the dimension flags `--harness=`/`--provider=`/`--model=`/`--platform=`, `--agent=` h/p/m, and/or `--known=` all four) and the others `null`, `refresh:true` (platform `null` unless given; no host default). Unknown ids are allowed (that is the seed path). A `--no-*`-only call is invalid for creation — at least one positive dim or `--agent=`/`--known=` is required.
6. **`known dequeue`** = set `refresh:false` on all matching rows.
7. **`known purge`** = delete all matching rows. The old "purge incomplete rows" mode is removed (partial rows are first-class).
8. **Daemon expansion = recipe-match + warn** (option B, chosen). For a `refresh:true` row with missing dims, the daemon enumerates `knownFixturesForKnownAgents` recipes; a recipe applies when every set dim of the row equals the recipe's dim; missing dims are filled from the recipe; platform constrained to the host. Applicable combos are ensured as full `refresh:true` rows (unless already `refresh:false`), then the seed row is **removed**. No applicable recipe / unknown id → **warning**, entry **left unchanged**, continue. Warn once per key per daemon run.
9. **`known agent` partial detection → record a partial seed.** If at least one dim resolves, upsert a partial row (resolved dims, others `null`, `refresh:true`), write **no fixture**, still exit 2. Nothing written if zero dims resolve.
10. **Fixtures rename** to `<known-id>.agent.json` (mirrors `<known-id>.trailer.txt`).
11. **Out of scope:** retargeting/parameterizing `buildEnv*` to inject arbitrary models (option A, rejected); capturing platforms other than the host.

## Tasks (ordered; implementer should follow this order)

### Task 0 — Rename fixtures to `.agent.json`
- `git mv` every `known/<id>.json` → `known/<id>.agent.json` (24 committed files; content unchanged).
- `src/known_fixtures.test.zig`: `discoverStems` matches `*.agent.json` and strips the `.agent.json` suffix to produce the `known_id` stem; `readFixtureParsed` reads `known/{s}.agent.json`; the pretty-print test at ~line 327 also builds `known/{s}.agent.json`.
- `src/main.zig` `runKnownAgent`: `json_name = "{known_aid}.agent.json"` (trailer stays `{known_aid}.trailer.txt`).
- `runKnownQueueMissing`: the `json_exists` check uses `{known_aid}.agent.json`.
- Update filename references in `CONTRIBUTING.md`, `DESIGN.md`, `dev.knownUsage`.

### Task 1 — IndexEvent schema: drop derived ids, nullable dims, null normalization
- `IndexEvent` (src/main.zig:2547): remove `known_alphanumeric_id` and `agent_alphanumeric_id`.
- `parseIndexEvent`: read the 4 dims; accept JSON `null` or missing and normalize to internal `""` (unset).
- `emitIndexEvent`: serialize unset dims as JSON `null` (not `""`).
- Helpers (add + reuse): `splitAgentAlphanumericId` (3 parts, already exists — reuse for recipes), new `splitKnownAlphanumericId` (4 non-empty parts), `agentIdFrom(h,p,m)` / `knownIdFrom(h,p,m,plat)` (return null when any dim missing — used for fixture naming and messages only, never stored), a canonical tuple key `tupleKey(h,p,m,plat)` using a separator that cannot appear in alphanumeric ids (e.g. `~` or `.`), and `describeEvent(ev)` for diagnostics (full rows → `knownIdFrom`; partial rows → concise dims summary like `seed harness:crush`).
- `upsertIndexEvent` dedupe key: compute from the parsed row's dims via the tuple key (replaces the old `known_alphanumeric_id` key).
- `latestEventsPerId`: key the map by the tuple key; copy dims/generated_at into the stored event.

### Task 2 — Shared filter parser
- New `FilterOptions` struct + `parseFilters(init)` used by queue/dequeue/purge: parses the 11 flags (`--known=`, `--agent=`, `--harness=`, `--provider=`, `--model=`, `--platform=`, `--no-harness`, `--no-provider`, `--no-model`, `--no-platform`); requires ≥1 present (else error + usage, return 2).
- Validation: `--known=` splits into exactly 4 non-empty parts; `--agent=` splits into exactly 3 non-empty parts; conflict rules per Decision 3; `--known=` sets all four dims and makes `--platform=` redundant (still accepted if identical).
- Predicate `matchesFilter(ev, f)`: for each dim — set value → equality; `--no-X` → dim unset (`""`); else any.
- Call sites: replace `runKnownQueue`'s ad-hoc arg parsing, `runKnownDequeue`'s ad-hoc parsing, and add fresh parsing to `runKnownPurge`.

### Task 3 — `known queue` = create-or-flip
- Rewrite `runKnownQueue` (src/main.zig:2813):
  - Parse filters; ≥1 required (else exit 2).
  - Require at least one positive dim, `--agent=`, or `--known=` for creation (a `--no-*`-only call is not a valid seed) → else error.
  - Build the prospective row dims from positive values (`--known=` sets all four; `--agent=` sets h/p/m; `--no-*` → unset).
  - `matches = all existing rows matching the filter`. If `matches.len >= 1`: upsert each as `refresh:true` (preserve its dims/runner; new `generated_at`). Print `known queue: queued N`.
  - Else: upsert a seed row (positive dims, others `""`, `refresh:true`, `runner=getParentPid()`, `generated_at=timestampNow()`). Print `known queue: queued seed <dims>`.
  - Idempotent: re-running a seed request matches the existing seed → flip path, no duplicate row.

### Task 4 — `known dequeue` = filtered `refresh:false`
- Rewrite `runKnownDequeue` (src/main.zig:3321) to use `parseFilters`; ≥1 required (removes the old "no filters = dequeue everything" behavior).
- For every matching row, upsert `refresh:false` (same dims). Print count. Nothing is deleted (unchanged).

### Task 5 — `known purge` = filtered delete
- Rewrite `runKnownPurge` (src/main.zig:3385) to use `parseFilters`; ≥1 required.
- Delete every matching row (rewrite the index excluding those tuple keys — add a `deleteIndexEvents(a, io, keys)` helper). Print count removed.
- Remove the old implicit "incomplete row" purge logic.

### Task 6 — Daemon: recipe-match expansion + warn-and-keep + seed removal
- In the daemon loop / `enqueuePending` / `runOneCombo` (src/main.zig:3483+ flow):
  - **Full row** (all 4 dims set): match recipe by exact agent id; platform must equal host; capture as today; the capture's own `refresh:false` upsert flips the same tuple (still works). No recipe → warn once + skip.
  - **Partial row (seed)** via new `expandSeed(ev)`:
    - Universe = `knownFixturesForKnownAgents`; recipe dims recovered via `splitAgentAlphanumericId`.
    - Applicable = every set dim of `ev` equals the recipe's dim, AND `ev.platform` is empty or equals the host platform, AND `harnessAvailable(io, recipe.agent_alphanumeric_id)`.
    - If empty: `daemonWriteErr("daemon: warning: no capture recipe applicable for <seed desc>")`; leave the entry unchanged; continue. Track warned tuple keys in a `warned` set so it warns once per run (no 5s spam).
    - Else: for each applicable combo, ensure a full `refresh:true` row exists unless the row with that tuple is already `refresh:false`; then **delete the seed row** (its tuple key). Combos carry their own retry state and are captured one per poll by the existing loop.

### Task 7 — `known agent` partial seed
- `runKnownAgent` (src/main.zig:2720):
  - Full detection: unchanged (writes `<known-id>.agent.json` + trailer + full `refresh:false` row).
  - Partial detection with ≥1 resolved dim: upsert partial row (resolved dims, others `""`, `refresh:true`, runner, generated_at), no fixture, exit 2 (message notes the record).
  - Zero resolved dims: exit 2, nothing written (unchanged).
  - Caveat (document in a comment): a daemon-spawned child that partially fails on a full combo writes a partial seed with a different tuple; the combo row stays `refresh:true` (retry), and the seed re-enters expansion next poll — bounded retry loop, surfaced by the daemon warning.

### Task 8 — queue-all / queue-stale / queue-missing
- `runKnownQueueAll` (src/main.zig:3087): iterate rows, flip `refresh:true` for host platform + harnessAvailable; keyed by tuple; seeds are already `refresh:true` (no-op).
- `runKnownQueueStale` (src/main.zig:2979): same logic, tuple-keyed; reuses `queueEventFrom` which must be updated to build rows from dims.
- `runKnownQueueMissing` (src/main.zig:3080±): only full rows (all dims set) lacking `{known-id}.agent.json` are re-queued; skip partial rows (no filename).

### Task 9 — Usage + docs
- `dev.knownUsage` (src/main.zig:2033): document queue/dequeue/purge filters + `--no-*`, the ≥1-option rule, create-or-flip seeding, `.agent.json` naming, daemon warn-and-keep.
- `CONTRIBUTING.md` "refresh a fixture": `<id>.agent.json` filename; index is a state store (one tuple-keyed event, nullable dims, no derived ids); queue create-or-flip; dequeue/purge filters; daemon expansion + warn.
- `DESIGN.md`: state-store section already rewritten — extend with: derived ids not stored, partial rows are queue/agent seeds consumed by the daemon (recipe-match; warn-and-keep), `.agent.json` naming in "per-platform fixtures" + filename contract.
- README: no fixture-filename references; nothing required beyond already-updated CLI section.

### Task 10 — Migration + validation
- After Task 1, run `known queue-fixtures` to regenerate `known/index.jsonl` from fixtures (validates the new parse/emit round-trip). Old partial/todo rows are dropped; re-queue as needed.
- Build/test: `zig build`, `zig build dev`, `zig build test` all green.
- Manual checks:
  - `known queue --harness=crush` with no crush rows → seed row `crush,null,null,null` `refresh:true`; rerun → "queued 1" (flip).
  - Daemon: seed expands to crush recipe combos, they are captured, seed removed; `tail known/index.jsonl` shows only full rows.
  - `known queue --model=minimax3` (absent everywhere) → seed; daemon warns and keeps it.
  - `known purge --no-provider --no-model --harness=crush` deletes only those rows; bare `known purge` / `known dequeue` / `known queue` → exit 2.
  - `known agent` inside a partial-detection session → partial seed row written (no fixture), exit 2.
  - Fixture tests pass against renamed `*.agent.json` files.

## Risks / notes
- Row-identity refactor touches every `known` subcommand plus the daemon — implement Tasks 1–2 first and keep `zig build` green per task.
- Daemon warning spam is prevented by a per-run warned set; document the bounded retry loop on failed full-row captures (existing behavior).
- Existing `known/index.jsonl` rows carry the old schema; the queue-fixtures regeneration (Task 10) is the migration path.
