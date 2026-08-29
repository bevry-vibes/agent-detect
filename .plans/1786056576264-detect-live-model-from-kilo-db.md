# Detect live model/provider from the Kilo session DB (Charm Hyper etc.)

## Status: PROPOSED — depends on the dev SQLite plan

This plan is **not** implementation-ready. It builds on
`.kilo/plans/1786041353624-sqlite-index-two-tables.md` (the dev-only SQLite index), which must
land first. It also requires a **separate decision** (see "Open question") about whether the
SQLite dependency should ever be bundled into the released/production `agent-detection` binary —
we probably do **not** want to, so the production story needs its own evaluation.

## Problem

`agent-detection trailer` cannot identify the current session when run from the Kilo CLI:

- The `kilo` harness rule (`src/main.zig:365`) matches on the env marker `KILO_API_KEY` (unset in
  a normal session) and has empty `proc_names`, so the harness is never detected even though the
  parent process is literally `kilo` and `KILO=1` is set.
- `detectKilo` (`src/main.zig:1539`) requires `KILO_MODEL`/`KILO_PROVIDER` env vars that Kilo does
  **not** export to child processes.
- Result: `unable to determine trailer` (exit 2), and per commits.md we must never commit without
  a trailer nor guess the identity.

## Where the live identity actually lives

The running Kilo session records its model + provider in the Kilo state DB
`~/.local/share/kilo/kilo.db`, `session` table, `model` column, as JSON, e.g.:

```json
{"id":"deepseek-v4-flash-0731","providerID":"hyper","variant":"default"}
```

The provider is **dynamic per session** — observed changing across sessions this day:
`fireworks-ai` → `ollama` → `hyper` (Charm Hyper). It must be read fresh, never hardcoded or
cached (per commits.md: "Always and only ever use `agent-detection --trailer` fresh for each
commit").

## Approach

The dev SQLite plan already introduces a SQLite binding (`pmarreck/zig-sqlite`) and a shared
`SqlConn` init helper for the `known` index. The **same** binding can open the **Kilo** DB
(`~/.local/share/kilo/kilo.db`) read-only and query the current session's `model` JSON to resolve
provider + model.

- Add a dev-only `detectKiloFromDb(a, io, env, d)` that opens the Kilo DB read-only
  (`PRAGMA query_only`) and selects the current session's `model` JSON. "Current session" is the
  most recent `session` row for the process's working directory (`session.directory`), ordered by
  `time_updated DESC` (the CLI session we run under is the newest row for this project).
- Parse `providerID` → `setProvider(a, d, providerID)` (already maps `hyper` → "Charm Hyper",
  `fireworks-ai` → "Fireworks AI", `ollama` → "Ollama Cloud" via `knownRulesForKnownProviders`).
  Parse `id` → `applyModel(a, d, modelName, raw)`. For model ids with a trailing build stamp
  (e.g. `deepseek-v4-flash-0731`) strip the `-NNN` suffix so it matches the `deepseek-v4-flash`
  rule and labels as "DeepSeek V4 Flash" instead of the titleCase fallback.
- **Harness detection:** extend the `kilo` rule to also match when `KILO=1` / `KILO_PID` is set
  or when an ancestor is named `kilo` (add `kilo` to `proc_names`), so the harness resolves
  without `KILO_API_KEY`.
- **Fallback order:** keep the existing env-marker + `KILO_MODEL`/`KILO_PROVIDER` path first (the
  launcher shim in DESIGN still sets those for `known agent` captures); the DB read is the
  fallback for the `trailer`/`agent` actions run directly under the Kilo CLI.

## Open question — production binary bundling

The dev SQLite plan keeps SQLite **dev-only** (`-known` artifacts); the released
`agent-detection` binary stays minimal and dependency-free. Reading the Kilo DB needs SQLite at
runtime, which collides with that pillar for the **released** `trailer`/`agent` actions.

Options to evaluate after the dev plan lands:

1. **Dev-only only.** The DB-read detection lives only in the `-known`/dev binary. The released
   binary keeps requiring `KILO_MODEL`/`KILO_PROVIDER` (set by the launcher shim). Simple, keeps
   prod minimal, but the plain released `trailer` still can't self-identify under the CLI.
2. **Bundle SQLite into the released binary.** Simplest UX (released `trailer` just works), but
   adds the SQLite dependency + static linkage to every production artifact — the thing we
   probably don't want unless warranted.
3. **A tiny standalone reader.** Vendor only the minimal SQLite read path (or a hand-written
   reader for the `session` table) into the released binary, avoiding the full dependency. More
   work, but keeps prod dependency-light.

**Recommendation:** do not bundle SQLite onto the production binary unless a concrete need
emerges. Prefer option 1 now, revisit 2/3 only if released `trailer` self-identification becomes a
requirement. This decision is deferred until the dev SQLite plan is implemented and evaluated.

## Validation

- Run `agent-detection trailer` under the Kilo CLI for this project and confirm it prints
  `Co-authored-by: Kilo Code · DeepSeek V4 Flash 0731 <kilo-hyper-deepseekv4flash0731@local>`
  (or the correct provider for the live session).
- Confirm the trailer changes correctly when the session's provider changes (Fireworks → Ollama
  Cloud → Charm Hyper) without recompiling.
- Confirm the released (dev=false) binary behavior is unchanged / as decided under "Open question".

## Out of scope / deferred

- The production-bundling decision (see "Open question") — deferred until the dev SQLite plan is
  done and evaluated.
- Any change to the `known` index itself; this plan only reuses the SQLite binding for detection.
