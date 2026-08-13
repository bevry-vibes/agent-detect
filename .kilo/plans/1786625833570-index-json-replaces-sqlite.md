# index.json replaces fixtures/index.sqlite3 — proposal + comparison

Plan file: `1786625833570-index-json-replaces-sqlite.md`. Companion prompt log
(per kilo.md provenance rule): `1786625833570-index-json-replaces-sqlite.prompts.md`
(to be created by the implementing agent; this planning session's questions are
recorded there).

## Status

**Open for decision — 3 unresolved design choices** (sections 4, 5, 6 below each
end in "Ask the user"). Everything else is a working recommendation this plan
assumes unless the user overrides. The kilo.md rule requested by the user
(section 2) is recorded and lands with implementation.

## 1. Goal + hard constraints

Replace the dev-only SQLite store (`fixtures/index.sqlite3`, four tables,
reached by shelling out to the system `sqlite3` CLI) with a single
**`fixtures/index.json`** that uses Zig-native file locks for read/write
coordination, so that:

1. the store plays well with git (JSON diffs, hand-editable),
2. curated data moves out of Zig into index.json — recipes + launch argv,
   per-harness/per-platform version argv, free provider+model combos —
   letting dev.zig shed its two biggest data/code blocks (the 177-recipe
   table, the sqlite layer),
3. table structure encodes guarantees JSON naturally (object keys = unique
   ids; a single `scope` field = the "at most one scope" invariant), and
4. duplication is reduced (dims live in object keys, not row payloads;
   `pending` nests inside its queue row; the `queue_id` autoincrement and
   the derived `#`-joined ids disappear).

**Hard constraint (user-stated, must never regress):** the released
`agent-detect` binary must never depend on index.json. The store lives
entirely inside the comptime-gated `pub const dev = if (build_options.dev) …
else struct {}` block in `src/dev/dev.zig` — the released binary never links
it. Validation adds a grep test: `index.json` / the store module must never be
referenced outside `src/dev/dev.zig`. The released binary's read-only
kilo/opencode **session** sqlite reads (`core.zig` `kiloSqliteJson`, used by
live detection) are unrelated and stay.

## 2. kilo.md rule (user directive — apply with implementation)

Add to the repo-root `kilo.md` (the local skill-reference file, per
AGENTS.md/meta.md) a project tweak:

> **Never do condensed proposals for complicated changes.** For non-trivial
> design changes, write a proper proposal/comparison document (schema options,
> concrete examples, trade-off tables, code-impact inventory) before asking
> for a decision. Multi-choice tool questions alone are not acceptable for
> complicated changes.

## 3. Current state (verified)

- `src/dev/dev.zig` (3,341 lines): sqlite layer
  (`ensureSchema`/`sqliteRun`/`sqliteQuery`/`sqlQuote`/`sqlOptStr`/`sqlOptInt`
  + ~20 row-accessor functions, lines ~449–1061), the 177-recipe
  `recipesForFixtures` table + `capture_prompt` (lines ~1317–1568),
  probe helpers (`spawnVersion`/`findBinary`/`harnessVersion`/
  `scanVersionToken`), queue/dequeue/daemon/capture runners, post-checks,
  staleness conjunction, guard, timeout worker.
- Committed `fixtures/index.sqlite3`: 177 `fixtures` rows, 692 `queue` rows,
  0 `pending` rows, 16 `invalid` rows. 180 committed `fixtures/*.json` files.
- `harness_version` is **not** in the identify output today (`buildCooked`
  emits the 17-field contract without it; `harness_version` appears only in
  `buildRaw`'s raw block and the sqlite `fixtures.harness_version` column).
  The user's note ("removes harness_version from the identify output, it
  should just be in the raw output") is therefore already true — the plan
  keeps identify without it, keeps it in raw, and keeps a per-fixture
  `harness_version` field in index.json because `--stale-by-version` compares
  against it.
- Zig 0.16 has `std.Io.File.lock(file, io, .exclusive/.shared)` +
  `tryLock` (kernel-released on process exit, Windows supported via the Io
  vtable; `FileLocksUnsupported` for exotic targets). No package needed.

## 4. Proposed index.json schema

Top-level keys:

```json
{
  "store_version": 1,
  "free": { "openrouter": ["nemotron3ultra", "gemma431b"], "deepseek": ["deepseekv4flash"] },
  "versions": {
    "kilo": { "darwin": ["kilo", "--version"], "linux": ["kilo", "--version"], "windows": ["kilo.cmd", "--version"] }
  },
  "recipes": {
    "cline-clinepass-kimik3": { "launch": ["cline", "--auto-approve", "--provider=cline-pass", "--model=cline-pass/kimi-k3", "<prompt>"] },
    "kimicode-minimax-minimaxm3": { "launch": ["kimi", "-p", "<prompt>"] },
    "omp-zenmux-kimik3": { "launch": ["omp", "--model", "zenmux/moonshotai/kimi-k3-free", "<prompt>"] },
    "pi-anthropic-claudesonnet4": {}
  },
  "fixtures": {
    "cline-clinepass-kimik3-darwin": {
      "runner": 12345, "generated_at": 1750000000,
      "harness_version": "3.14.2",
      "available": true, "successful": true,
      "agent_detect_version": "2026.8.11-1",
      "identity": { "generated_at": 1750000000, "hash": "0123…" },
      "capture": { "generated_at": 1750000001, "hash": "4567…" }
    }
  },
  "queue": {
    "cline~clinepass~kimik3~darwin~from-capture~recipes": {
      "harness": "cline", "provider": "clinepass", "model": "kimik3", "platform": "darwin",
      "mode": "from-capture", "scope": "recipes",
      "runner": 12345, "created_at": 1750000000,
      "pending": { "cline-clinepass-kimik3-darwin": { "started_at": 1750000010, "finished_at": null } }
    }
  },
  "invalid": [
    { "fixture_id": "foo-bar-baz-darwin", "agent_id": "foo-bar-baz", "reason": "unknown fixture file", "created_at": 1750000000 }
  ]
}
```

Decisions folded into this shape (rationale per table):

### 4a. `fixtures` — object keyed by fixture_id (dash-joined), dims NOT in rows

- Key = `fixture_id` = `<harness>-<provider>-<model>-<platform>` (the exact
  filename stem of `fixtures/<id>.json`). JSON object-key semantics replace
  the PRIMARY KEY + `fixtures_fixture_id` unique index: duplicates are
  impossible by construction.
- The four dims are **not** repeated inside the row — they are recovered
  from the key via the existing `splitFixtureId`. This deletes the
  `agent_id`/`fixture_id` derived `#`-joined columns (`derivedAgentId`/
  `derivedFixtureId` die; dash-join is the one separator everywhere).
- sqlite 0/1/NULL markers become JSON `true`/`false`/`null` (hand-editable;
  `--available`/`--unavailable`/`--successful`/`--unsuccessful` scopes map
  directly).
- The four per-channel generation columns collapse into two nested objects
  `identity` / `capture` (`generated_at` + `hash` each) — keyed per channel,
  impossible to mismatch by construction.
- Lookups: `fixtureRow(h,p,m,plat)` = key build + `map.get`; `selectFixtures`
  = iterate keys; filters = split key. Scale (177 rows) makes scans free.

### 4b. `queue` — object keyed by the dedupe tuple; `pending` nested inside

- Key = `<h>~<p>~<m>~<plat>~<mode>~<scope-encoding>` (empty slots for unset
  dims; `~` cannot appear in slugs — the existing `tupleKey` contract). This
  key **is** today's `queue_dedupe` unique index; upsert = `map.put` (kills
  the autoincrement `queue_id`, `upsertQueueRow`'s SQL, and dedupe logic).
- Dims stay in the row (queue rows are transient work items a maintainer
  debugs by eye; seeds have null dims that the key renders as empty slots —
  parseable but not human-readable).
- The eight marker columns collapse into one **`scope`** field whose value is
  one of `"recipes"`, `"missing-fixture-file"`, `{"stale_by_minutes": N}`,
  `"stale-by-version"`, `"stale-by-detect"`, `"stale-by-hash"`,
  `"available"`, `"unavailable"`, `"successful"`, `"unsuccessful"` (absent =
  bare seed). The "at most one scope per row" invariant is now structural —
  `validateQueueRow`'s scope-count logic dies (the remaining validation:
  dims are slugs, stale minutes ≥ 1, known scope names).
- `pending` is a per-queue-row object keyed by `fixture_id`
  (`{ "started_at": N, "finished_at": N|null }`). Crash-resume = read the
  queue row, take the first `finished_at == null` entry. Draining = delete
  the queue row. This kills `queueRowById`, `deleteQueueRowById`,
  `insertPendingRow`, `nextUnfinishedPending`, `markPendingStarted`,
  `markPendingFinished`, `pendingDrained`, `clearPendingAndQueueRow`, and
  the `UNIQUE(queue_id, fixture_id)` index — one map manipulation replaces
  them.
- Pop order (from-identity before from-capture, oldest first) = one scan
  comparing `modeRank(mode)` then `created_at`. 692-row scans are free; the
  daemon re-reads the file per poll anyway.

### 4c. `recipes` — object keyed by agent_id; launch as curated payload

**OPEN — placement comparison below (section 5).** This section records the
recommended option (A) in full; the comparison presents B and C.

- Key = `agent_id` = `<harness>-<provider>-<model>` (the existing
  `splitAgentId` contract). Dims not repeated in the row.
- Row payload: `"launch"` (JSON array of strings; the final element is the
  capture prompt string, exactly today's `capture_prompt` constant embedded
  as `"run \`agent-detect-dev fixtures capture\` in the current working
  directory and report the result"` — or, see open item in section 5, the
  prompt could move to a top-level constant instead of repeating 170×) and
  later `"free"` if the free table is per-recipe (section 6 option F3).
- Launch remains **curated, never derived**: implied combos (`kimi -p
  <prompt>` — provider/model come from the harness config), grouped combos
  (`omp --model zenmux/moonshotai/kimi-k3-free` — provider+model fused into
  one service-spec arg), and explicit combos (`pi --provider X --model Y`)
  are all representable because the array is opaque data keyed by agent_id.
- `launch` absent → from-identity-only recipe (today's `launch = null`).
- The 177-recipe Zig table (`recipesForFixtures` + `recipeForAgent`, ~250
  lines incl. comments) is deleted; seed expansion and `--recipes`
  enumeration iterate the JSON `recipes` object. A test replaces the current
  compile-time recipe checks (every recipe key splits 3-way; every dim
  resolves to a rule-table entry; every harness rule has ≥1 recipe; launch
  argv[0] ∈ the harness rule's `binary_names` on the host platform).

### 4d. `versions` — top-level `"<harness_id>"."<platform>"` → argv array

- User-specified shape: `"versions": { "kilo": { "darwin": ["kilo",
  "--version"], "windows": ["kilo.cmd", "--version"] } }`. Full argv
  including argv[0]; per-platform explicit (Windows entries carry the
  `.cmd`/`.ps1` shim name themselves).
- Replaces `spawnVersion`'s hardcoded `name --version` + name cycling:
  availability probe = spawn the version argv, exit 0 ⇒ installed;
  `harnessVersion` = spawn the version argv + `scanVersionToken` on stdout.
  `findBinary` dies; `harnessVersion` loses its
  `harnessRuleForFixtureId`+`binary_names` cycling (kept only for launch
  argv[0], section 4c).
- Missing harness or platform entry ⇒ fail closed (unavailable / no
  version). A test enforces: every harness rule with ≥1 recipe has a
  `versions` entry for the host platform, and `versions[h][host][0]` ∈ the
  rule's `binary_names`. Windows/Linux entries are curated by hand
  (documented in CONTRIBUTING.md — the maintainer fills all three platforms
  when adding a harness; today's per-harness install knowledge already lives
  there).
- Alternative considered and rejected as the default: deriving the version
  argv from `binary_names[0] + "--version"` (zero new data) — rejected
  because the user wants the per-platform table as data, and it frees
  non-`--version` harnesses later (data edit, not code).

### 4e. `free` — comparison in section 6.

### 4f. `invalid` — array of objects, append-only log (unchanged semantics)

- `fixture_id`/`agent_id`/reason/created_at (+ the dim id fields today's
  rows carry, kept for the dev agent's remedy reading). Iteration-only
  consumer; an array is the right shape. Never evaluated by the daemon.

## 5. Launch placement — comparison (OPEN, ask the user)

Data fact driving this: launch argv is curated per (harness, provider,
model) — implied/grouped/explicit combos prove it is never derivable from
the ids (the prior dedup plan's deferred finding #3: "two irreducible data
elements remain — the curated valid-combo set and the per-provider
model-spec strings").

| | A: top-level `recipes` keyed by agent_id (recommended) | B: launch inside fixture rows (keyed by fixture_id) | C: per-platform launch object on recipes |
|---|---|---|---|
| Rows | 177 (one per combo) | 177 × 3 platforms (or fixtures table pre-seeded with uncaptured recipes) | 177 rows × 3 platform arrays inside each |
| Platform handling | argv[0] cycles the rule's `binary_names` (today's ~40-line substitution, kept) | data carries the platform | data carries the platform; argv[0] cycling dies for launch |
| State vs intent | recipes (intent) and fixtures (state) stay separate tables — `--recipes` works for uncaptured platforms | recipes must be pre-seeded into the state table (rows without `generated_at`), muddying "fixtures = captured state" and breaking `--recipes`/`--missing-fixture-file` semantics | separate tables, like A |
| Duplication | none | argv duplicated 3×; uncaptured combos still need a recipe list somewhere | 3× argv per recipe (most identical across platforms); drift risk: edit darwin, forget windows |
| Code impact | smallest (keep one substitution helper) | largest (rewrite `--recipes` enumeration + seed expansion over fixture rows; handle recipe-rows-without-capture) | delete the substitution helper (~40 lines) but add per-platform argv resolution everywhere launch is used |
| Hand-editing | one array per combo | same array, three times | three arrays per combo |
| Consistency with `versions` (explicit per-platform) | versions explicit, launch platform-free + cycling — mild inconsistency, each optimized for its use | consistent (both explicit) | consistent (both explicit) |

Recommendation: **A**. It matches "a json array field" per combo, keeps
recipes as a first-class table (needed for uncaptured platforms), zero
duplication, and reuses the proven argv[0] substitution. C is the runner-up
if the user prefers explicit platform data everywhere (cost: ~3× launch
data). B is rejected (breaks state/intent separation; the recipes table
cannot disappear).

Minor sub-decision riding on A: the capture prompt repeats in ~170 launch
arrays; either keep it inline (self-contained arrays, today's shape) or move
it to a top-level `"capture_prompt"` string and append it at spawn time
(less duplication, one more data dependency at spawn). Recommendation:
top-level `"capture_prompt"` constant — the user's stated goal is reducing
duplication.

## 6. Free table — comparison (OPEN, ask the user)

Free-ness is a (provider, **model-spec**) property, not (provider,
canonical-model-id): `zenmux/moonshotai/kimi-k3-free` is free while the
canonical id `kimik3` alone says nothing about the spec (DESIGN #13: "a
model free on one provider is not assumed free on another").

| | F1: `"free": {"<provider>": ["<model-id>", …]}` (recommended) | F2: flat array `"free": ["<provider>#<model-id>", …]` | F3: per-recipe `"free": true` flag | F4: `"free"` keyed by provider#spec strings |
|---|---|---|---|---|
| Shape | provider → [canonical model ids] | user's literal words | flag on each recipes row | exact spec keys like `zenmux#kimi-k3-free` |
| Normalization | free-ness stated once per provider+model (no per-harness duplication) | same, flat | denormalized across every harness's recipe for the same provider+model (e.g. 4-6 rows for openrouter#nemotron3ultra) | exact, but keys contain `/`, `:` and free/paid tier spellings — ugly to hand-edit |
| Spec collision (provider+model with both free and paid specs) | ambiguous until a second spec appears | same | unambiguous — the recipe pins the spec | unambiguous |
| `--free` scope (deferred flag) | matches provider+model | matches provider+model | enumerates free recipes | matches spec |
| Consistency guarantee | test: every free entry resolves to known provider+model rules, AND every recipe whose (provider, model) is listed must carry a free-signal in its launch spec (`:free`, `-free`, `free/`, `-free` service ids) — a paid-spec recipe of a listed combo fails loudly | same test | test: `free: true` ⇒ free-signal in launch spec | inherent |

Recommendation: **F1** with the free-signal test (the collision is
caught the moment a paid-spec recipe of a listed combo lands). It matches
the user's "table of provider+model ids" intent, avoids per-harness
duplication, and the review-enforced consistency test makes it robust.
F3 is the fallback if unambiguous per-recipe flags are preferred over the
normalized table. Note: the `--free` scope flag itself stays deferred
(prior plan); the table lands now as data + test.

## 7. Migration of the committed index.sqlite3 — comparison (OPEN, ask the user)

The committed DB holds real state: 177 fixtures / 692 queue / 16 invalid
rows (pending: 0). Queue rows ride git across hosts (CONTRIBUTING.md: the
DB is committed per landing as the cross-host work queue).

| | M1: `fixtures migrate` subcommand (recommended) | M2: one-off throwaway conversion, no shipped code | M3: auto-migrate on first dev command |
|---|---|---|---|
| Mechanism | one last read-only `sqlite3 -json` dump (the helper pattern already exists in `core.zig` `kiloSqliteJson`), writes index.json, renames the DB to `fixtures/index.sqlite3.migrated` (gitignored) | implementing agent converts once via `sqlite3` CLI + a throwaway script (e.g. python3/jq), commits index.json, `git rm`s the DB | any dev command sees index.sqlite3 without index.json → converts silently |
| Other hosts | run `fixtures migrate` after pulling (their unsynced local queue rows preserved) | unsynced local queue rows on other hosts are lost (they just pull the new committed index.json) | seamless, but ships both stores indefinitely |
| Code cost | ~80 lines dev-gated, deletable after all hosts migrate | zero | both layers live forever (or until a later version-bump removal) |
| sqlite purge | dev.zig sqlite code shrinks to the single migrate action | complete purge of sqlite from dev.zig | none |

Recommendation: **M1**. It preserves other hosts' local queue state, keeps
the purge honest (the migrate action is one bounded block that can be
deleted in a later sweep), and the exit-12 repurposing below applies to the
migrate error path too.

## 8. Locking + write protocol (recommended, no question)

- Lock file: `fixtures/index.json.lock` (gitignored). Lock the file itself,
  not the data file, so the atomic rename never swaps a locked inode out
  from under a waiter.
- Write cycle (every mutation — queue upsert/delete, fixture upsert, pending
  marks, invalid append): acquire `.exclusive` via `std.Io.File.lock` (or
  `tryLock` in a retry loop with a ~5s budget mirroring today's
  `busy_timeout=5000`; loop on `tryLock == false` + sleep 50ms), read
  index.json (missing/corrupt → empty state + error), mutate the in-memory
  `std.json.Value` object maps, serialize with `whitespace = .indent_2`,
  write `fixtures/index.json.tmp`, rename over `fixtures/index.json`,
  unlock. Temp+rename gives readers atomic visibility (a reader sees the
  old or the new file, never a partial write), so **readers take no lock**
  (daemon poll = plain read; the poll-to-poll write loss risk is the same
  as today's sqlite semantics, where the daemon re-reads per poll).
- Locks are kernel-managed: released on process exit/crash automatically —
  no stale-lock-file heuristic needed (a `.lock` file left behind is empty
  and reusable).
- `fixtures capture` (short-lived process) and `queue`/`dequeue` serialize
  against a running daemon through the same lock — replaces sqlite's
  busy-timeout coordination.
- Failure modes: lock timeout → exit 13 (I/O); unparseable index.json →
  exit 12 (repurposed, section 9); write/rename failure → exit 13.

## 9. Exit code 12 repurposing (recommended, no question)

`EXIT_SQLITE_QUERY` (12) becomes `EXIT_INDEX_STORE` — "index store error"
(`fixtures/index.json` exists but is corrupt/unparseable/unknown
`store_version`). Same code number, new meaning; usage text, DESIGN.md's
registry row, and MSG_ constants updated. (The released binary never hits
it; its sqlite session reads catch their own errors.)

## 10. Code-impact inventory (Option A + F1 + M1 baseline)

**Deleted from dev.zig** (~900 lines):
- sqlite layer: `ensureSchema`, `sqliteRun`, `sqliteQuery`, `sqlQuote`,
  `sqlOptStr`, `sqlOptInt`, `upsertQueueRow`, `upsertFixture`,
  `selectFixtures`, `jsonToFixtures`, `jsonToQueueRows`, `jsonToQueueRow`,
  `fixtureExists`, `fixtureRow`, `popQueueRow`, `queueRowById`,
  `deleteQueueRowById`, `insertPendingRow`, `nextUnfinishedPending`,
  `markPendingStarted`, `markPendingFinished`, `pendingDrained`,
  `clearPendingAndQueueRow`, `insertInvalid`, `deleteQueueRows`,
  `parseJsonCount`, `appendCond`, the dev `sj*` accessors.
- data table: `recipesForFixtures` (177 rows) + `recipeForAgent` +
  `capture_prompt` (moves into index.json).
- probes: `spawnVersion`'s hardcoded `--version`, `findBinary` (replaced by
  versions-table spawn); `harnessVersion`'s binary_names cycling (replaced
  by versions-table argv).
- `derivedAgentId`/`derivedFixtureId` (the `#`-joined forms die).
- `validateQueueRow`'s scope-count half (structural now).

**Added (~200 lines):** `IndexStore` (load/save under lock), key builders
(`fixtureKey`, `recipeKey`, `queueKey`), row accessors over object maps
(get/put/remove fixture, queue, pending, invalid), versions/launch argv
resolvers, `fixtures migrate` (M1), lock-retry helper.

**Kept:** daemon loop + phases, `runOneComboCapture` (minus name cycling if
C, kept if A) + `runOneComboIdentity`, post-checks, staleness conjunction
(`rowMarkersAllFresh` over the new row shapes), `parseFilters`/
`scopeCandidates` (candidate enumeration over maps), `mergeWriteFixture`/
`channelJson`/`generationHash`, `assertNotInAgent`, timeout worker, usage
texts (updated wording).

**Tests:** rewrite the recipe tests in `known_fixtures.test.zig` to read
`fixtures/index.json`; add schema tests (store_version; fixture keys split
4-way + match their filename stem; recipe keys split 3-way + resolve to rule
tables; every harness rule has ≥1 recipe + a host-platform versions entry;
free entries resolve + free-signal consistency; queue keys match row dims +
mode + scope; pending keys are 4-part). Add the released-binary isolation
grep/compile check.

**Docs:** DESIGN.md — rewrite "SQLite state store" → "index.json state
store" (new schema, locking, guarantees), rewrite decision #3 (sqlite via
CLI → JSON store + native locks), update scope section (the `fixtures`
workflow loses its only external runtime dependency — the sqlite3 CLI
requirement disappears; note it), exit-12 row. CONTRIBUTING.md — store
sections, per-platform `versions` curation guidance when adding a harness,
migrate runbook. `.gitignore` — drop the sqlite journal lines; ignore
`fixtures/index.json.lock`, `fixtures/index.json.tmp`,
`fixtures/index.sqlite3*`; index.json is committed. powershell.md/zig.md —
index.json editing + lock/atomic-write pattern notes. AGENTS.md zig bullet —
file list unchanged.

## 11. Rollout path (M1 assumed)

1. Implement the store + rewire all commands; `fixtures migrate` converts
   the committed DB; commit `fixtures/index.json` and `git rm
   fixtures/index.sqlite3` together.
2. Other hosts: pull, run `fixtures migrate` once (their local unsynced
   queue rows convert), done.
3. Later sweep (after all hosts report migrated): delete the migrate action.

## 12. Ordered task list (finalized once 5/6/7 are decided)

1. kilo.md rule addition (section 2) + `.prompts.md` companion for this plan.
2. `IndexStore` + lock/atomic-write layer in dev.zig (no command rewiring yet).
3. Rewire fixtures/queue/pending/invalid accessors onto the store (deleting
   the sqlite layer); keep `fixtures migrate` behind M1.
4. Move `recipesForFixtures` → `fixtures/index.json` `recipes`; populate
   `versions` + `free` + `capture_prompt`; rewrite recipe consumers (seed
   expansion, `--recipes`, launch resolution, probes).
5. Scope-field encoding + queue-key upserts + nested pending (daemon
   protocol change).
6. Exit-12 repurpose + usage text updates.
7. Tests (schema + isolation + ported recipe checks).
8. Docs (.gitignore, DESIGN, CONTRIBUTING, zig.md, powershell.md, AGENTS.md).
9. Run `fixtures migrate`, commit index.json, `git rm` the sqlite DB.
10. Validate (below).

## 13. Validation

- `zig build`, `zig build dev`, `zig build test` green; released binary
  (`zig build dist`) unchanged in size/surface and still rejects
  `fixtures`; grep: no `index.json` reference outside `src/dev/dev.zig`; no
  `sqlite3`/`ensureSchema`/`sqliteQuery` outside `migrate`/core session
  reads.
- `fixtures migrate` on the committed DB → index.json with 177 fixtures /
  692 queue / 16 invalid; `fixtures queue --missing-fixture-entry` and
  `--recipes` behave identically; a `--from-identity` seed runs
  end-to-end through the daemon (or a unit-shape test of pop→pending→drain).
- Concurrent write test: `fixtures queue` racing the daemon's writes does
  not corrupt the file (lock retry, temp+rename).
- `git diff fixtures/index.json` after a daemon run shows clean, reviewable
  JSON changes.

## 14. Open decisions (asked of the user in this session)

1. **Launch placement** — section 5, recommend A.
2. **Free table** — section 6, recommend F1 + free-signal test.
3. **Migration** — section 7, recommend M1.
