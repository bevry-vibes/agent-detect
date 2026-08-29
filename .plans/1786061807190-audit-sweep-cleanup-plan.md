# Audit sweep: dead code removal + docs alignment + evergreen design notes

## Context

The `agent-detection` repo evolved from a JSONL state store to a SQLite CLI shell-out
(two tables: `fixtures` + `actions`), plus live Kilo DB detection and scope-filter queue/
dequeue. The old JSONL machinery and several helpers were left orphaned in `src/main.zig`,
and the docs (DESIGN.md / CONTRIBUTING.md / README.md) still describe the abandoned
architecture in places. This plan removes dead code and aligns docs with the shipped
behavior, and records the evergreen design decisions that should guide future work.

No new functionality. All changes are deletions / doc rewrites / comment fixes.

## Decisions (all confirmed against source)

- **Dead code confirmed dead:** every item below has zero live callers in `src/main.zig`
  (verified by grep + read of call sites).
- **Keep the one-time JSONL migration:** `migrateIndexJsonl` (src/main.zig:2727) reads a
  legacy `known/index.jsonl` if present and both tables empty, then deletes it. Keep the
  function (it documents the migration contract) but fix its stale comment. Remove the
  now-dead helpers it indirectly references where safe.
- **Keep `parseIndexEvent`** (src/main.zig:3360) — still used by `migrateIndexJsonl`.
- **Keep `describeAction`**, `splitAgentAlphanumericId`, `splitKnownAlphanumericId`,
  `agentIdFrom`, `knownIdFrom`, `tupleKey`, `knownAlphanumericId`, `platformAlphanumericId`
  — all live.
- **Keep `getParentPid`** — live (runner column).
- **Keep `probeBinary`/`harnessAvailable`** — live (available probe).
- **Keep `purgeMalformedFixtures`** — live (daemon idle loop).
- **Keep `kiloSqliteJson`** (src/main.zig:1621) — shares the sqlite3-CLI pattern but takes a
  db-path arg and lives outside the `dev` block (used by released `trailer`/`agent` under
  the Kilo CLI). Do NOT merge into `dev.sqliteRun` — the dev helper is `dev`-gated and the
  released binary must stay minimal. Leave as-is; note the duplication is intentional
  (see DESIGN.md note).
- **Keep `known/index.jsonl` in the repo for now** — the SQLite store (`known/index.sqlite3`)
  is not yet verified working end-to-end; the JSONL file stays committed as the fallback
  until the `known` workflow on sqlite is proven (queue → daemon pop → capture → fixture →
  dequeue). The committed file is migrated automatically at first DB open (and deleted from
  disk after), so it is harmless while it lingers. **Remove all dead code + doc references to
  `index.jsonl` now; do NOT `git rm` the file.**
- **Add a follow-up task elsewhere (unblocked by this plan):** once sqlite is verified
  working and the JSONL fallback is proven unnecessary, `git rm known/index.jsonl` in a
  separate change after confirming `migrateIndexJsonl` no longer reports an unparsed/leftover
  file. Mark this explicitly as a separate, deferred step.

## Tasks

### 1 — Delete dead JSONL machinery in `src/main.zig`

Remove all of the following (with their doc comments). Re-check each by grep after edit.

1. `RawObservation.harness_env_markers` + `harness_proc_names` (lines 276-284).
   - Also remove the assignments at lines 2091-2092 in `detect()`.
   - Fix the comment at 2088-2090 (no longer writes those fields).
2. `lockIndex` / `unlockIndex` / `writeIndexAtomic` / `INDEX_LOCK_PATH` globals
   (lines 455-511) — dead since SQLite migration. The `daemon_log_file` global must stay.
3. `timestampNow` (3295-3301) — returns literal `"0"`; dead.
4. `jsonString` (3303-3306) — only used by `emitIndexEvent`/`jstrOrNull`; dead after 5-7.
5. `latestEventsPerTuple` (3478-3509) — dead.
6. `matchesFilter(ev: IndexEvent, ...)` (3689-3695) — no callers (queue uses `scopeCandidates`).
7. `pidIsAlive` (4028-4047) — dead; only annoted "Used by `refresh all`", which no longer exists.
8. `describeEvent(ev: IndexEvent)` (2889-...) — replaced by `describeAction(ActionRow)`.
   Note `describeAction` is the live equivalent (src/main.zig:2686).
9. `emitIndexEvent` (3399-3422) + `jstrOrNull` (3424-3429) — dead.
10. `upsertIndexEvent` (3431-3473) — dead (migration uses `parseIndexEvent` directly).
11. `IndexEvent` struct (3347-3355) — still referenced by `parseIndexEvent`, `migrateIndexJsonl`.
    Keep it. But the doc comment on the struct (3357-3346) says "one row in known/index.jsonl"
    — update to "legacy JSONL event row, read only by the one-time migration".
12. `jdim` (3388-3394) — used only by `parseIndexEvent`; keep.
13. Fix misleading comments:
    - `parseIndexEvent` docstring — it's now only for migration, not the poll cycle.
    - The block at 2178-2195 (the daemon comment above `pub const dev =`) still says
      "polls known/index.jsonl" — replace with the SQLite actions-poking description.
    - runKnownAgent doc comment (3823-3831) says "append a refresh:false event to
      known/index.jsonl" — correct to "upsert a fixtures row".
    - main() dispatch comment at 4585-4593 / 4621-4626 mention `known purge` and
      "append a refresh:false event to known/index.jsonl" — fix both.
    - `TimestampNow` doc comment at 3295 lies ("ISO-8601") — removed anyway.

### 2 — Remove **references to** `known/index.jsonl` (keep the file for now)

- `git rm known/index.jsonl` is **deferred** until the sqlite store is verified working
  (see Risks / follow-up task). This task removes every code/doc reference instead, so the
  tree no longer points at the legacy file as a live thing:
  - `src/main.zig` — already deleting the dead JSONL helpers in Task 1; additionally make sure
    no remaining comment says the daemon/queue/agent *polls* jsonl. `migrateIndexJsonl` doc
    comment and `ensureMigrated` doc comment may mention the legacy path (that's fine — they
    are the historical migration), but they must not imply the store is still in use.
  - DESIGN.md / CONTRIBUTING.md / README.md — any sentence describing the store as
    `known/index.jsonl` (vs. `known/index.sqlite3`) gets rewritten to the sqlite two-table
    model. Grep `index.jsonl` across the repo and update every user-facing doc mention.
  - Do NOT touch the committed `known/index.jsonl` file itself.
- Add a deferred follow-up bullet (unblocked change): "Once the `known` sqlite workflow is
  verified working (queue → daemon → capture → fixture → dequeue round-trip), `git rm
  known/index.jsonl` in a separate commit and re-run the round-trip to confirm the legacy file
  is gone and the store is self-sufficient."

### 3 — Unify duplication (optional, low-risk)

- `kiloSqliteJson` (1621-1647) duplicates `dev.sqliteRun` (2272-2296) aside from the db-path
  arg. Leave as-is — intentional (dev-gated vs released-slim). Add a one-line comment to each
  noting the deliberate mirror.

### 4 — DESIGN.md — fix stale claims, add evergreen notes

Replace/update:
- "two-binary split (released + dev-only)" section (29-34): the `known` capability is now
  cross-platform — the SQLite store is reached via the system `sqlite3` CLI, so `known`
  runs on every OS the released binary ships to; the two-binary split still holds for the
  *code* (`dev` block) but not for "native-only".
- "SQLite state store" (60-94): fine, but update:
  - The sentence "Written only by `known agent` and the daemon" (69) — add "and the
    one-time JSONL migration".
  - Remove the `--no-*` four-valued-flag implications: since `--no-X` flags are removed,
    the "three-valued scope columns" section can keep `1/0/NULL` but must drop any phrase
    implying `--no-harness` etc. (already absent — verify).
  - `available` (75-76): already documents probe-and-record. Keep.
  - The "user-only daemon" (95-103) is accurate.
- Add an **evergreen decisions** section (markdown) at the end, capturing:
  1. **Never guess** — partial detection exits 2 and writes nothing; fixtures-only approach.
  2. **Seeds are actions** — a partial `actions` row means "re-run every recipe matching my
     set dims", not just "fill missing combos".
  3. **SQLite via the `sqlite3` CLI, not a binding** — single-file cross-platform state,
     no dependency in the released binary; the `sqlite3` CLI is a runtime requirement of the
     `known` workflow (document it).
  4. **Kilo live-DB fallback** — env marker → `KILO_MODEL` → live `~/.local/share/kilo/kilo.db`
     read (newest session row for cwd). Production stays SQLite-free.
  5. **`--no-*` flags removed** — a `fixtures` row always has all dims NOT NULL; unset dims are
     expressed as NULL seed dims in `actions` only.
  6. **No auto-reconcile** — committed `known/*.agent.json` are authoritative; `--missing-fixture`
     keys off filesystem; option B (reconcile-on-read) rejected.
  7. **Daemon is user-only** — agent never runs it; env-marker + ancestry guard fail-closed.
  8. **Released binary stays minimal** — no SQLite, no `known`, no raw dump; the `dev` modular
     `if (dev_build)` block drops dead code at comptime.
  9. **The 18-field canonical fixture contract** — test-enforced; the raw block is shapeless
     (source-grouped keys), and harness rule *static* data (env-marker/proc-name lists) is
     intentionally NOT re-emitted in raw.
  10. **`known dequeue` = DELETE**, `known agent` = fixtures-only, `purge` removed.
- Fix any broken line-number references to `src/main.zig` (they drifted); point to top-level
  names instead.

### 5 — CONTRIBUTING.md — align with shipped behavior

- "refresh a fixture" (8-26): already largely accurate; update the mention of
  "append a refresh:false event to known/index.jsonl" pattern in the end-to-end flow (step 3,
  line 85-86) → "upserts the matching fixtures row".
- Remove/update any claim that `known agent` writes to `actions` (grep — verify).
- Add a "tooling" note: the `sqlite3` CLI is required for the `known` workflow
  (dev/purge fixturessweep + queue/daemon); released binary has zero deps.
- "add a new harness rule" table (96-108): correct — add explicit first-step "git rm the old
  known/index.jsonl if present" isn't needed.
- "cut a release" (151-179): accurate. Add note: `known` workflow unchanged in release.
- "pending harnesses" (200-211): keep — genuine TODO. Add note that the daemon's
  recipe table (`knownFixturesForKnownAgents`) must contain the harness for expansion.

### 6 — README.md — minimal alignment

- Remove the per-platform **binary size** column (drifts; sizes in the table are stale).
  Keep the binary-name table.
- If a line references `known/index.jsonl` — none today, verify.
- Keep the "contributing" pointer and the actions list; they're correct.
- Optionally add one line under "usage" noting the `sqlite3` CLI is only needed for the
  maintainer `known` workflow, not for the released binary.

### 7 — `build.zig` comment fixes (optional)

- build.zig:26-31/40-50 mention `queued, dequeue, purge` — purge removed. Update the
  `--dev` comment to list `queue/dequeue/agent/daemon` only, and drop "purge".

## Validation

1. `zig build` (released) green.
2. `zig build dev` green.
3. `zig build test` green (fixture tests unaffected; they don't touch main.zig symbol names
   we removed — verify no `pub` items removed that tests import — `buildJson`, `Detection`,
   `alphanumericId` stay `pub`).
4. `git grep -i "index.jsonl\|queue-fixtures\|queue-all\|queue-stale\|known purge"` on
   src/ + docs → only the migration/rollout comments remain; no live code or user-facing doc
   points at `known/index.jsonl` as the active store.
5. Manual smoke: `./zig-out/bin/agent-detection --version`, `agent` on this session (env
   marker present), `./zig-out/bin/agent-detection-dev known --help` prints updated usage
   (no `purge`).
6. `ls known/index.sqlite3` still absent (not created by this cleanup) and `known/index.jsonl`
   still present (not deleted).

## Follow-up (unblocked, separate change, NOT in this plan)

- Verify the sqlite-backed `known` workflow end-to-end first:
  `known queue --recipes` → `known daemon --write-log` → confirm captures land in
  `known/index.sqlite3` fixtures/actions and `known/<id>.agent.json` files → `known dequeue`.
- Only then `git rm known/index.jsonl` and re-run the round-trip once to confirm the store is
  self-sufficient without the legacy file. This plan leaves the file in place.

## Risks / notes

- `known/index.jsonl` stays committed deliberately. It is read+migrated on first sqlite open
  (tables empty + file present), then deleted from disk — so a leftover stale file cannot
  break the store, and removing its code/docs references is safe.
- `IndexEvent` stays but only for migration; removing the dead fields could surface a
  type-check error if a stray ref remains — grep each symbol after removal.
- The `dev` block is `comptime`-gated; removing dead code there only shrinks the dev binary.
- Release/README binary-size column: deleting sizes avoids a maintenance trap; the actual
  URL patterns are stable.
