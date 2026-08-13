# index.json replaces fixtures/index.sqlite3 — finalized plan

Plan file: `1786625833570-index-json-replaces-sqlite.md`. Companion prompt log
(per kilo.md provenance rule): `1786625833570-index-json-replaces-sqlite.prompts.md`
(written during planning; both files are committed before each `plan_exit` per
the traceability rule in §2).

## Status

All design forks are resolved. Implementation-ready.

**Resolved decisions:**
1. Launch/version data live in fixture rows (`prompt_launch` / `version_launch`,
   concrete per-platform argv); the `recipes` table and the top-level
   `versions` table are gone.
2. Free table = `free_provider_to_model` (provider id → [canonical model ids]).
3. **Pre-seeding: A** — seed all 177 combos × darwin/linux/windows = 531 rows
   at conversion time.
4. **Key separator: A** — dash-joined key == filename stem.
5. **Migration: B** — one-off throwaway conversion by the implementing agent;
   no shipped migrate code; sqlite purge is complete.
6. **Timestamps: B (drop all)** — the only timestamps in the store are
   `identity.declared_at` and `capture.captured_at`; nothing else carries one
   (see §7 for the `--stale-by-minutes` consequence).
7. **`invalid`: C** — append-only array of self-describing rows (no key rule).
8. Queue = array of rows with nested `pending` and a single `scope` field.
9. Exit code 12 repurposed to "index store error".
10. Locking = `std.Io.File.lock` on `fixtures/index.json.lock` + temp/rename
    atomic writes.

## 1. Goal + hard constraints

Replace the dev-only SQLite store (`fixtures/index.sqlite3`, four tables,
reached by shelling out to the system `sqlite3` CLI) with a single
**`fixtures/index.json`** using Zig-native file locks, so that:

1. the store plays well with git (JSON diffs, hand-editable),
2. curated data moves out of Zig into index.json — the per-combo launch argv
   (`prompt_launch`), the per-platform version argv (`version_launch`), the
   free provider+model table — letting dev.zig shed its two biggest
   data/code blocks (the 177-recipe table, the sqlite layer),
3. data is self-contained per row: a maintainer (human or dev agent) reviews
   one fixture row and sees everything about it — what launched it, what
   version probe it uses, what was captured — without consulting Zig code,
4. zig code gets dumber, not smarter: launch/version are read verbatim from
   the row; no argv[0] name cycling, no per-harness version-flag logic.

**Hard constraint (user-stated, must never regress):** the released
`agent-detect` binary must never depend on index.json. The store lives
entirely inside the comptime-gated `pub const dev = if (build_options.dev) …
else struct {}` block in `src/dev/dev.zig` — the released binary never links
it. Validation adds a grep test: `index.json` / the store module must never be
referenced outside `src/dev/dev.zig`. The released binary's read-only
kilo/opencode **session** sqlite reads (`core.zig` `kiloSqliteJson`, used by
live detection) are unrelated and stay.

## 2. kilo.md rules (user directives — apply with implementation)

Add to the repo-root `kilo.md` (the local skill-reference file, per
AGENTS.md/meta.md) two project tweaks:

> **Never do condensed proposals for complicated changes.** For non-trivial
> design changes, write a proper proposal/comparison document (schema options,
> concrete examples, trade-off tables, code-impact inventory) before asking
> for a decision. Multi-choice tool questions alone are not acceptable for
> complicated changes.

> **Commit the plan before `plan_exit`.** The plan file and its `.prompts.md`
> companion are committed (per commits.md, build + generated trailer) before
> each `plan_exit`, so plan and prompt updates are traceable in git history.

## 3. Verified current state

- `src/dev/dev.zig` (3,341 lines): sqlite layer
  (`ensureSchema`/`sqliteRun`/`sqliteQuery`/`sqlQuote`/`sqlOptStr`/`sqlOptInt`
  + ~20 row-accessor functions, lines ~449–1061), the 177-recipe
  `recipesForFixtures` table + `capture_prompt` (lines ~1317–1568), probe
  helpers (`spawnVersion`/`findBinary`/`harnessVersion`/`scanVersionToken`),
  queue/dequeue/daemon/capture runners, post-checks, staleness conjunction,
  guard, timeout worker.
- Committed `fixtures/index.sqlite3`: 177 `fixtures` rows, 692 `queue` rows,
  0 `pending` rows, 16 `invalid` rows. 180 committed `fixtures/*.json` files.
- `harness_version` is **not** in the identify output today (`buildCooked`
  emits the 17-field contract without it; it appears only in `buildRaw`'s raw
  block and the sqlite `fixtures.harness_version` column). The user's note
  ("removes harness_version from the identify output, it should just be in
  the raw output") is therefore already true — identify keeps it out, raw
  keeps it, and index.json keeps it **nested under `capture`**.
- Zig 0.16 has `std.Io.File.lock(file, io, .exclusive/.shared)` + `tryLock`
  (kernel-released on process exit; Windows via the Io vtable).
- Committed `adb220e` (this planning session): the arena free-list
  use-after-free fix landed (removed the freed-returned-slice bugs in
  `kiloSqliteJson`/`sqliteRun`/`readChannelObject`/`readControlAction`) — the
  store rewrite inherits the rule: **never free an arena slice that a
  returned value aliases** (zig.md should record this gotcha).

## 4. Target schema (final)

```json
{
  "store_version": 1,
  "free_provider_to_model": { "openrouter": ["nemotron3ultra", "gemma431b"], "deepseek": ["deepseekv4flash"] },
  "fixtures": {
    "cline-clinepass-kimik3-darwin": {
      "runner": 12345, "available": true, "successful": true,
      "agent_detect_version": "2026.8.11-1",
      "identity": { "declared_at": 1750000000, "hash": "0123…" },
      "capture": { "captured_at": 1750000001, "hash": "4567…", "harness_version": "3.14.2" },
      "prompt_launch": ["cline", "--auto-approve", "--provider=cline-pass", "--model=cline-pass/kimi-k3", "run `agent-detect-dev fixtures capture` in the current working directory and report the result"],
      "version_launch": ["cline", "--version"]
    }
  },
  "invalid": [
    { "harness": "cline", "provider": "clinepass", "model": "kimik3", "platform": "darwin",
      "reason": "unknown fixture file" }
  ],
  "queue": [
    {
      "harness": "cline", "provider": "clinepass", "model": "kimik3", "platform": "darwin",
      "mode": "from-capture", "scope": "recipes",
      "runner": 12345,
      "pending": { "cline-clinepass-kimik3-darwin": { "started_at": 1750000010, "finished_at": null } }
    }
  ]
}
```

### 4a. fixtures table — one table is the recipe universe + the state

- Key = the dash-joined 4-part fixture id == the filename stem
  (`cline-clinepass-kimik3-darwin`); dims NOT repeated inside the row
  (recoverable via `splitFixtureId`). Queue/invalid rows keep explicit dims.
- Row payload, self-contained by design (user rationale: human review, dev
  agent review, dumber zig code):
  - `runner`, `available`/`successful` (JSON booleans, not 0/1/NULL),
    `agent_detect_version` — unchanged semantics.
  - `identity` = `{ declared_at, hash }` (BLAKE3 of the channel object);
    `capture` = `{ captured_at, hash, harness_version }` — harness_version
    nests under capture because only capture stamps it; `--stale-by-version`
    reads it there. Absent objects/channels = not yet written.
  - `prompt_launch`: the launch argv that (re)captures this fixture —
    argv[0] = the concrete binary for this platform (`.cmd`/`.ps1` shims
    written explicitly on Windows rows, e.g. `kilo.cmd`), args per harness
    (implied combos like `kimi -p <prompt>` carry no provider/model flags),
    last element = the capture prompt (inline per row). **Never a
    placeholder**: argv[0] is a real binary name at write time. Absent ⇒
    from-identity-only row (today's `launch = null`).
  - `version_launch`: the version-probe argv (concrete binary + flags, e.g.
    `["kilo.cmd", "--version"]`). Availability probe = spawn `version_launch`,
    exit 0 ⇒ installed; `harnessVersion` = spawn `version_launch` +
    `scanVersionToken`. Absent ⇒ version/availability probes fail closed.
- **No row-level timestamp.** The age check for `--stale-by-minutes` (the
  only consumer of the old `generated_at`) is **mode-scoped**, exactly like
  `--stale-by-hash`'s channel selection (DESIGN.md already specs the
  mode-picks-the-channel pattern for hash): a `from-identity` queue row is
  age-stale iff `identity.declared_at` is missing or older than the
  threshold; a `from-capture` row iff `capture.captured_at` is missing or
  older. No mode flag queues both rows, so the default sweep is the
  "either date older than N" (OR) behavior — whichever channel is age-stale
  gets re-queued under its own mode. Specifying both mode flags together
  still errors (exit 3, existing `parseFilters` conflict); omitting them is
  how the OR is expressed. Consequence (accepted, decision 6): outcome-only
  attempts (`markCaptureOutcome` availability/successful stamps) do NOT
  refresh any channel date, so age sweeps retry failed rows eagerly instead
  of rate-limiting by attempt time.
- **The recipes table is gone.** `--recipes` scope = rows whose platform is
  the host; seed expansion = host-platform rows matching the seed's set dims;
  `--missing-fixture-file` = host rows whose `<fixture_id>.json` is absent.
  This works because the conversion seeds a row for every known combo on all
  three platforms (531 rows; §6).
- `fixtures capture` upserts markers/channels/`harness_version`; it never
  writes `prompt_launch`/`version_launch` (it cannot know the launch argv). A
  capture for a combo with no row creates the row without launch data; a
  later from-capture for it routes to `invalid` ("no launch spec") until a
  maintainer fills the fields in.

### 4b. queue — array of rows, `pending` nested, one `scope` field

- Array: no dedupe key, no `created_at`. Upsert dedupe = linear scan for an
  equal row (dims + mode + scope); on match, replace the row in place (the
  old `queue_dedupe` flip semantics; position preserved). ~692 rows × ~600
  upserts is trivial. The `queue_id` autoincrement dies.
- Pop order: the array's order IS the queue order — scan for the first
  host-platform `from-identity` row, else the first `from-capture` row (mode
  rank wins over position; append = oldest-first).
- Dims stay explicit in the row (seeds have null dims — human-readable).
- `scope` single field: `"recipes"` | `"missing-fixture-file"` |
  `{"stale_by_minutes": N}` | `"stale-by-version"` | `"stale-by-detect"` |
  `"stale-by-hash"` | `"available"` | `"unavailable"` | `"successful"` |
  `"unsuccessful"` (absent = bare seed). "At most one scope" becomes
  structural; `validateQueueRow`'s scope-count half dies.
- `pending` nested per row: `{ "<fixture_id>": { "started_at": N,
  "finished_at": N|null } }` — pending rows keep their two timestamps (they
  are the crash-resume protocol, not log metadata). Crash-resume = first
  unfinished entry; drained = delete the row. Kills `queueRowById`/
  `deleteQueueRowById`/`insertPendingRow`/`nextUnfinishedPending`/
  `markPendingStarted`/`markPendingFinished`/`pendingDrained`/
  `clearPendingAndQueueRow`.

### 4c. invalid — append-only array of self-describing rows

- Decision 7 (user): keep the array (the hash-table sketch was withdrawn).
  No key rule, no dedupe, no `created_at`. Fields: explicit dims
  (`harness`/`provider`/`model`/`platform`, each optional), optional
  `fixture_id`/`agent_id` (kept: they are the only identity for bad-stem
  files and malformed pending ids, which have null dims), and `reason`
  (required). Semantics unchanged: never evaluated, dev-agent remedy only.

### 4d. `free_provider_to_model`

- Provider id → [canonical model ids]. Consumed by the deferred `--free` scope
  flag later; lands now as data + tests:
  - every provider/model entry resolves to known provider+model rules;
  - every row whose (provider, model) is listed must carry a free-signal in
    its `prompt_launch` model spec (`:free`, `-free`, `free/`, `-free`
    service ids) — a paid-spec row of a listed combo fails the test (catches
    spec collisions the moment they appear).

## 5. Resolved forks (answers recorded in the .prompts.md)

- **5a pre-seeding: A** — seed all 177 combos × darwin/linux/windows = 531
  rows.
- **5b separator: A** — dash key == filename stem.
- **5c migration: B** — one-off throwaway conversion, no shipped code.
- **5d timestamps: B** — drop all timestamps outside the channel objects.
- **5e invalid: C** — keep array.

## 6. One-off conversion (migration decision B)

The implementing agent converts once with a throwaway script (e.g. a
`/tmp`-side zig or shell script driving the system `sqlite3 -json` CLI —
pattern already in core's `kiloSqliteJson`), producing `fixtures/index.json`:

- `fixtures` rows from the sqlite `fixtures` table (177) → keyed by their
  dash-joined fixture_id, channel objects from the four generation columns
  (`identity.declared_at`/`hash`, `capture.captured_at`/`hash`/
  `harness_version`), markers/`agent_detect_version`/`runner` verbatim. The
  sqlite `generated_at` column is **not** carried over.
- `queue` rows (692) → array entries in rowid order; `created_at` dropped;
  `pending` empty objects (table has 0 rows); scope from the marker columns
  (the one marker set, or absent for seeds).
- `invalid` rows (16) → array entries; `created_at` dropped.
- **531 seeded rows** from `recipesForFixtures` (177 combos × 3 platforms):
  `prompt_launch` from the recipe's `launch` (argv[0] = bare stem on
  darwin/linux; windows argv[0] per the CONTRIBUTING install table —
  `.cmd`/`.ps1` for the npm-shimmed harnesses `cline`, `mmx`, `qwen`, `kilo`,
  `cursor`, `.exe` otherwise); `version_launch` = `[<same binary>, "--version"]`;
  `free_provider_to_model` curated from the recipe comments' free-tier notes
  (free spec markers; unverified combos omitted — flagged in the commit body).
  Seeded rows carry only the launch/version fields; no markers/channels
  (uncaptured state).
- Commit `fixtures/index.json` and `git rm fixtures/index.sqlite3` together.
- Known trade-off (accepted): other hosts lose queue rows queued locally
  since their last sync; their fixture state is the committed index.json.

## 7. Timestamps — the final set

Only two timestamps exist in the whole store, both inside channel objects:

- `identity.declared_at` — when the from-identity channel was declared
  written.
- `capture.captured_at` — when the from-capture channel was written.

Plus `pending.started_at`/`pending.finished_at` (crash-resume protocol, not
log metadata — kept). Everything else dropped: fixtures top-level
`updated_at` (ex-`generated_at`), queue `created_at`, invalid `created_at`.
The `--stale-by-minutes` check becomes **mode-scoped**: the queue row's
mode picks the channel date (identity row → `identity.declared_at`;
capture row → `capture.captured_at`; missing → stale). The default
no-mode-flag queueing of both rows is what yields the user's "stale if
either date is older than N" behavior — never a min/max of the two dates
inside one row's check. This is
not sqlite legacy being dropped blindly — queue order now lives in the array
order and invalid's timestamp was write-only — but note the accepted
semantic change for the fixtures anchor in §4a.

## 8. Locking + write protocol

- Lock file `fixtures/index.json.lock` (gitignored); lock the lock file, not
  the data file (the atomic rename must never swap a locked inode out from
  under a waiter).
- Write cycle (every mutation): `.exclusive` via `std.Io.File.lock` (or
  `tryLock` retry loop, ~5s budget mirroring today's `busy_timeout=5000`,
  sleep 50ms between tries), read index.json (missing/corrupt → empty state +
  error), mutate the in-memory object, serialize `whitespace = .indent_2`,
  write `fixtures/index.json.tmp`, rename over index.json, unlock.
- Readers take no lock (temp+rename gives atomic visibility; the daemon
  re-reads per poll — same semantics as today's sqlite per-poll reads).
- Kernel-managed locks release on process exit/crash — no stale-lock
  heuristics. `fixtures capture`/`queue`/`dequeue` serialize against a
  running daemon through the same lock.
- Failure modes: lock timeout → exit 13; unparseable index.json → exit 12
  (repurposed, §9); write/rename failure → exit 13.

## 9. Exit code 12 repurposing

`EXIT_SQLITE_QUERY` (12) → `EXIT_INDEX_STORE` — "index store error"
(index.json corrupt/unparseable/unknown `store_version`). Same number, new
meaning; usage text + DESIGN registry row + MSG_ constant updated. The
released binary never hits it (its sqlite session reads catch their own).

## 10. What leaves dev.zig (~1,000 lines)

- sqlite layer: `ensureSchema`, `sqliteRun`, `sqliteQuery`, `sqlQuote`,
  `sqlOptStr`, `sqlOptInt`, all ~20 row accessors (`upsert*`, `select*`,
  `jsonTo*`, `fixtureExists`, `fixtureRow`, `popQueueRow`, `queueRowById`,
  `deleteQueueRowById`, `insertPendingRow`, `nextUnfinishedPending`,
  `markPendingStarted/Finished`, `pendingDrained`, `clearPendingAndQueueRow`,
  `insertInvalid`, `deleteQueueRows`, `parseJsonCount`, `appendCond`, dev
  `sj*` accessors). No sqlite remains in dev.zig after this sweep.
- `recipesForFixtures` (177 rows) + `recipeForAgent` + `capture_prompt` → data
  (inline per-row prompt).
- `spawnVersion`'s hardcoded `--version` + `findBinary` (replaced by
  `version_launch` spawn); `harnessVersion`'s binary_names cycling (replaced
  by `version_launch`); **argv[0] cycling in `runOneComboCapture` dies** —
  launch argv is read verbatim from the row.
- `derivedAgentId`/`derivedFixtureId` (`#`-joined forms die).
- `validateQueueRow`'s scope-count half (structural now).
- `unixNow` stays (pending marks + channel timestamps still need it); the
  fixture/queue/invalid timestamp stamps go away with their fields.

**Added (~250 lines):** `IndexStore` (load/save under lock), key builders,
map/array accessors, the `scope` field's parse/serialize pair, lock-retry
helper.

**Kept:** daemon loop + phases, `runOneComboCapture`/`runOneComboIdentity`
(minus cycling), post-checks, staleness conjunction (`rowMarkersAllFresh`
over new shapes, age mode-scoped to the row's channel date — identity row
checks `identity.declared_at`, capture row checks `capture.captured_at`,
missing → stale), `parseFilters`/
`scopeCandidates` enumeration, fixture-file I/O (`mergeWriteFixture`/
`channelJson`/`generationHash`), `assertNotInAgent`, timeout worker, usage
texts (wording updates: index.json, exit 12 meaning).

**Note:** `binary_names` stays in rules.zig for ancestry detection + the
daemon guard only — probing/launching no longer read it.

## 11. Tests + docs

- Rewrite the recipe tests in `known_fixtures.test.zig` to read
  `fixtures/index.json`: fixture keys split (4-part) and equal their filename
  stem; every row's dims resolve to rule tables; every harness rule has ≥1
  row per platform; `prompt_launch[0]`/`version_launch[0]` ∈ the harness
  rule's `binary_names` (host platform); free table entries resolve +
  free-signal consistency (§4d); queue rows match their scope/mode/dims
  invariants; pending keys are 4-part.
- Released-binary isolation grep/compile check (index.json never referenced
  outside `src/dev/dev.zig`).
- DESIGN.md — rewrite "SQLite state store" → "index.json state store" (new
  schema, locking, guarantees, timestamp cuts + the mode-scoped
  `--stale-by-minutes` channel-date check — mirroring the hash scope's
  existing "mode flags pick the channel" wording; both mode flags together
  stay exit 3), rewrite decision #3 (sqlite via CLI → JSON store + native
  locks), scope section (the `fixtures` workflow loses the sqlite3 CLI
  runtime requirement), exit-12 row. CONTRIBUTING.md — store sections,
  per-platform `prompt_launch`/`version_launch` curation guidance when adding
  a harness, the one-off conversion note for other hosts. `.gitignore` —
  drop sqlite journal lines; ignore `fixtures/index.json.lock`,
  `fixtures/index.json.tmp`, `fixtures/index.sqlite3*`; index.json is
  committed. powershell.md/zig.md — index.json editing + lock/atomic-write
  patterns + the arena free-list gotcha. AGENTS.md zig bullet — file list
  unchanged. kilo.md — the two rules from §2.

## 12. Ordered task list

1. kilo.md rule additions (§2).
2. `IndexStore` + lock/atomic-write layer in dev.zig (no command rewiring yet).
3. Rewire fixtures/queue/pending/invalid accessors onto the store; delete the
   sqlite layer; scope-field encode/decode + queue-scan upserts + nested
   pending (daemon protocol change).
4. Delete `recipesForFixtures`/`recipeForAgent`/`capture_prompt`; rewire
   recipe consumers (seed expansion, `--recipes`, `--missing-fixture-file`,
   launch resolution, probes) onto the rows.
5. Exit-12 repurpose + usage text updates (fixturesUsage, queue/dequeue usage,
   daemon "index file" line).
6. One-off conversion of the committed DB + 531 seeded rows → commit
   `fixtures/index.json`, `git rm fixtures/index.sqlite3`.
7. Tests (schema + isolation + ported recipe checks).
8. Docs (.gitignore, DESIGN, CONTRIBUTING, zig.md, powershell.md, AGENTS.md,
   kilo.md).
9. Validate (§13).

Suggested commit grouping: (a) code = tasks 2–5; (b) store conversion = 6;
(c) tests + docs = 7–8. Each commit per commits.md (build first; trailer via
`./zig-out/bin/agent-detect trailer co-author`).

## 13. Validation

- `zig build`, `zig build dev`, `zig build test` green (the pre-existing
  `pi-groq-llama318b-darwin` legacy-shape failure is unrelated committed
  state); `zig build dist` released binary unchanged in size/surface, still
  rejects `fixtures`; grep: no index.json reference outside
  `src/dev/dev.zig`; no sqlite references outside core session reads.
- Converted index.json: 531 fixture rows + 692 queue + 16 invalid;
  `fixtures queue --recipes`/`--missing-fixture-entry` behave identically;
  a `--from-identity` seed runs end-to-end through the daemon (or a shape
  test of pop→pending→drain). **Note: daemon/fixtures execution is
  user-confirmed only — the implementing agent must not run the daemon or
  real captures.**
- Concurrent-write test: `fixtures queue` racing the daemon does not corrupt
  the file (lock retry + temp+rename) — verify via shape/unit coverage, not a
  live daemon.
- `git diff fixtures/index.json` after a command run shows clean, reviewable
  JSON changes.
