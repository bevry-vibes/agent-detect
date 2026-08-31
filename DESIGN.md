# design

## problem

AI agents working on Bevry projects must identify their **harness**,
**provider**, and **model** before working, and must credit commits
with an accurate `Co-authored-by` trailer (see
[policy.md](https://github.com/bevry-vibes/skills/blob/main/policy.md) and
[commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md)).
Hard-coded answers rot; manual per-harness techniques go unread. This
repo provides a single small native binary, `agent-detect`, that
infers the identity from live evidence at runtime — and, in recipe
mode, from the curated rule tables alone.

## why these design choices

### least-invasive-first detection ladder

We'd rather detect from a single env var than spawn a subprocess to
read a harness's config file. The detection ladder therefore reads in
this order: env markers → ancestor process names → per-harness config
files → the running session → the last model in the session log. The
implementation and the ladder's exact steps live in the doc block
above `pub fn detect` in `src/lib/core.zig`.

### two-binary split (released + dev-only)

The released binary must stay minimal — no raw dump, no subcommands,
no fixtures — so it ships as a single static file with no surprises.
Its CLI surface is `identify`, `trailer co-author`, `trailer assisted-by`,
`check-reciprocal`, `help`, `version`. The dev
binary (`agent-detect-dev`) carries the maintainer's full toolkit: the
standalone `raw` action (raw observations block) and the `fixtures`
subcommand namespace (capture / daemon / queue / dequeue / status). The split
is enforced at compile time via the `dev` flag in `build.zig` and the
`pub const dev = if (build_options.dev) struct { ... } else struct {};`
block in `src/dev/dev.zig`. The released binary cannot accidentally
include dev code paths.

The split is about **code**, not portability: the `fixtures` workflow
is cross-platform. The state store is the local `fixtures/index.json`
(read/written with Zig-native file locks — no external tools), so
`fixtures` runs anywhere the released binary does. `zig build dist`
emits only the released binary — no dev variants are produced.

### no `argv` capture (token + path leak)

The process lineage carries the basename of each ancestor process and
**no argv**. argv is omitted because it routinely contains tokens,
absolute paths to private files, and positional-secret arguments —
committing it to a fixture would leak those into git history. The
basename-only contract is what makes the fixture safe to commit; the
exact mechanics and the Ancestor struct definition live in the
`RawObservation.process_lineage` doc comment in `src/lib/core.zig`.

### per-platform fixtures (no churn across platforms)

Harness config locations differ per platform (macOS uses
`~/Library/Application Support/...`, Linux uses `~/.config/...`,
Windows uses `%APPDATA%\...`). The fixture filename includes the
`platform_id` so a CI run on one platform never invalidates another
platform's committed files. Each platform's fixture id
(`<harness>-<provider>-<model>-<platform>`) names two per-channel
files, each a whole self-contained `{ outputs, meta }` envelope
(normative schema: `fixtures/fixture.d.ts`):

- `fixtures/from-identity/<id>.json` — the declared identification
  channel, written by the from-identity worker (zero tokens):
  `outputs` = `identify` (the 18-field canonical object:
  `harness_id`, `provider_id`, `model_id`, `agent_id`, policy fields)
  plus `"trailer co-author"` and `"trailer assisted-by"`; `meta` =
  `updated_at` + `agent_detect_version`.
- `fixtures/from-capture/<id>.json` — the live-capture channel,
  written by `fixtures capture` on success only (authored invocations
  for not-yet-captured combos live in the store's `invocations` table):
  `outputs` = identify + trailers + `raw` (the slimmed shapeless
  runtime observations, headed by `platform_id`, then
  `harness_version` (the live version snapshot — null when the
  agent's version is not yet knowable), then `detectable` and
  `detected`, then `process_lineage`, the `*-urls` reference arrays,
  and the `evidence` claims — the dev `raw` output verbatim); `meta` =
  `updated_at` + `agent_detect_version` (+ `harness_version`, + the
  invocation of record — `prompt_invocation`/`version_invocation`).
  The raw block
  deliberately does NOT duplicate the env vars / config files /
  session files verbatim (decision #4 — raw slimming): the `evidence`
  section documents the source that informed each canonical
  deduction. Env-source evidence claims on non-allowlisted env vars
  carry the literal `"<redacted>"` value so secrets never reach disk
  while the attribution chain stays audit-trailable.

The legacy single-file layout (top-level `cooked`/`raw`/`trailer`/
`origin`, then the `from-identity`/`from-capture`/`from-capture-raw`
channel keys) is gone — the envelope replaced it, which is what makes
the trailer-variations coverage and per-channel ownership possible.

The `-<platform>` suffix keeps per-platform config paths from churning
each other across CI runs. The filename contract is defined on the
`fixtures capture` command (`dev.runFixturesCapture`) in `src/dev/dev.zig`.

### the `detectable` / `detected` raw fields

Both live at the top of the from-capture file's `outputs.raw` block,
adjacent to each
other and right after `platform_id`:

- `detectable` — the dims (`harness` / `provider` / `model`) this run
  *could* resolve: what the detection ladder reached (live mode) or
  what the recipe implies (recipe mode; up to all three).
- `detected` — the dims that actually landed in the `identify` block
  this run (a subset of, usually equal to, `detectable`).

A reader can instantly see what a fixture claims without scanning the
`identify` block.

### the state split: store + per-channel fixture files (cross-process coordination)

The fixture state lives in two places, split by derivability:

- **`fixtures/index.json`** — the committed state store, holding only
  the **non-derivable** state: `queue` (work intent), `invocations`
  (the authored launch argv — the dev agent's signal for what should
  capture), and `backlog` (actionable gaps + the `known_but_failed`
  failure memory). The legacy store v1 `fixtures` map and `errors`
  ledger, and the v2 top-level `known_but_failed`, are dropped on load
  and never re-serialized — back-compat by drop, not dual-read.
- **The fixture files themselves** — `fixtures/from-identity/<id>.json`
  (declared identifications) and `fixtures/from-capture/<id>.json`
  (live captures — **written only on success**, so a from-capture file
  always carries `outputs`), each a whole self-contained
  `{ outputs, meta }` envelope. The **directory IS the
  channel** — no channel key prefixes inside files. Channel presence =
  file existence — no JSON parse needed. A stem present in both folders
  has both channels. The normative shapes are declared in TypeScript at
  **`fixtures/fixture.d.ts`** (the envelope) and
  **`fixtures/index.d.ts`** (the store): the schema files are the
  source of truth for structure and this section documents only the
  semantics. (The zig program never imports TypeScript.) **Null-as-
  absent:** unset optional fields are omitted entirely — never
  serialized as `null` — and the schema's `?:` optionality is exactly
  that contract (readers treat a missing field as unset).

**Per-channel file ownership.** Each channel is owned exclusively by
its writer: a writer serializes the entire file and atomically replaces
it (temp + rename); there is no merge-write, no store row, and no
writer contention (declaration and capture never touch the same bytes).
Git semantics: identity churn and capture churn isolate per file; PR
review sees exactly which channel changed; a torn write damages only
one channel. The writer of a from-capture file records the **invocation
of record** into its `meta` (`prompt_invocation` / `version_invocation`
— the store's `invocations` table entry first, else whatever the
replaced file recorded) and stamps `updated_at` /
`agent_detect_version` / `harness_version` fresh. There are **no
meta-only stub files**: an authored invocation for a not-yet-captured
combo lives in the store's `invocations` table, and the capture file
appears only when a capture succeeds. Curation is a signal to the dev
agent (rules/argv needed for a successful capture); zig reads
invocations only to handle pop and `--repair`.

Store tables (semantics only — shapes in the schemas):

- `queue` — the work **queue**: an array of **filter entries**, never
  concrete work items (only the daemon expands). Each entry carries a
  **set** of staleness criteria (a candidate is stale iff ANY carried
  criterion says stale; all absent = a `--refresh` entry); `free` is an
  affirmative boolean whose absent state takes the expansion default
  (unset = no filter); `started_at` is stamped by the daemon on the
  entry's first work and anchors the pop protocol's done rule. There is
  **no `finished_at`**: fully-satisfied entries are purged (deleted —
  the fixture files are the sweep record).
- `invocations` — the authored invocations, keyed by fixture id:
  `{ "prompt_invocation": [...], "version_invocation": [...] }`. The
  dev agent authors these (a signal for rules/etc needed for a
  successful capture); zig reads them only to handle **pop** (the
  launch argv + version probe — the table entry wins over the file's
  recorded meta as "the latest") and **`--repair`** (an
  `unknown_invocations` item that gains an entry re-queues as a
  targeted from-capture entry). A successful capture records the
  invocation it ran under into the fixture file's own `meta`; the
  table entry persists as the re-capture source.
- `backlog` — the actionable gaps + the failure memory:
  `unknown_harnesses` / `unknown_providers` / `unknown_models` (unique
  dim slugs from unresolvable stems — folder stems and
  invocations-table ids alike; a fix, adding a rule, is addressable per
  dim), `unknown_invocations` (fixture ids of from-capture files with
  no invocation of record anywhere), and `known_but_failed` (see
  below). Derived from folder scans; maintained (idempotent union on
  write, removed when resolved) by the daemon's pick and
  `fixtures status`. The unfixtured — the feasible-unfixtured universe
  derived from the grids minus the fixtured stems — is **never a stored
  list** (it is hundreds of ids).
- `backlog.known_but_failed` — retryable operational failures, flat and
  informational: `known_but_failed[<fixture-id>] = "<message>"` — the
  fixture id maps directly to the failure output (stderr tail or the
  worker's diagnostic), truncated and redacted (home paths,
  key-shaped strings) before it touches the committed store. No
  timestamps, no schema depth. Written by the workers on operational
  failure (capture exit ≠ 0, unavailable version probe, post-check
  mismatch); last-failure-wins across modes; removed when any channel
  of that combo succeeds (the fixture file is the success memory, this
  is the failure memory). Pops never gate on failure state; the dev
  agent reads the message and handles it. `--repair` upserts
  `--fixture=<id>` entries so the dev agent can force a targeted
  re-queue after fixing the cause; clearing an entry by hand is always
  safe.

- The free axis lives in **`fixtures/providers-freemodels.csv`** — a
  sparse provider×model grid (rows only for providers with ≥1 free
  model, columns only for models free somewhere, cell = the
  provider's free model-id or `-`). Source of truth for free models.
- The **reference grids** — `fixtures/harnesses-providers.csv`
  (harness → provider cells) and `fixtures/providers-models.csv`
  (provider → model-id cells) — are load-bearing (a doctrine change:
  they were hand-maintained, zig-unread): a pair is feasible iff its
  cell is present and not `-`. The feasible-unfixtured universe
  (grid-filtered cross-product − fixtured) is the from-identity
  backlog universe, so impossible combos never become candidates and
  from-identity can never mint them.

Store writers take an exclusive lock on `fixtures/index.json.lock` (a
gitignored lock file; kernel locks release on exit/crash — no
stale-lock heuristics) and write atomically (serialize →
`index.json.tmp` → rename). Readers take no lock — the temp+rename
protocol makes visibility atomic. Fixture-file writers take no store
lock (each owns its file). Failure modes: lock timeout → exit 13;
corrupt/unparseable/unknown-`store_version` index.json → exit 12;
write/rename failure → exit 13.

Idempotency on `queue` is by tuple: a queue-command re-assert of an
existing (dims, mode, stale-set, `free`) tuple replaces the entry in
place and resets `started_at` to absent (a fresh sweep); the daemon's
own writes preserve it. A re-assert must repeat the SAME flag set
(defaults included) or it lands as a second, differently-defaulting
entry.

The **pop protocol** (the daemon's per-poll expansion):
1. Refresh the `backlog` from a folder scan, then scan entries in
   mode-rank order (from-identity first), then array order; delete
   entries with no remaining candidates anywhere and malformed entries
   (logged + dropped — the errors ledger is gone; `daemon.log` is the
   dev agent's record).
2. Expand the entry's universe — **one universe**: resolvable dims ∧
   (fixtured ∨ feasible-unfixtured per the grids for from-identity;
   invocation-known for from-capture — the `invocations` table ∪
   capture files carrying `meta.prompt_invocation`; files without any
   invocation are backlog unknown_invocations, never candidates) —
   filtered by dims, platform (the entry's, or the host's per platform
   in the loop), the staleness criteria, and the free flag.
3. A candidate is DONE when the mode's success `meta.updated_at` is
   present AND ≥ the entry's `started_at` (a never-worked entry has no
   done candidates); else if this daemon session already failed it
   (in-memory damping — one attempt per candidate per run) it is
   skipped; else it is a candidate. Stamp `started_at` on first work.
4. Work ONE remaining host-platform candidate per poll (adaptive
   pacing unchanged).
5. Candidates remain but none for this host: keep the entry, move on
   (another host's portion). Cross-host, the completion ledger rides
   git — an entry finishes on whichever host pops it after the last
   result lands.

Crash-resume derives from the fixture files: a capture that died with
the daemon left no channel write, so its candidate re-runs.

The daemon is **pure**: it never writes fixture files outside pop
processing and never inserts queue entries.

### the staleness model — `--stale`, `--refresh`, `--repair`

A queue entry carries a **set** of criteria; a candidate is stale iff
ANY carried criterion says stale (OR; short-circuit per candidate).
Absent evidence ⇒ stale, so unfixtured and backlog candidates (no
files, no meta) fire the composite naturally; nothing is exempt from
staleness evaluation. One candidate remains per folder stem; a
candidate is stale iff ANY carried criterion says stale:

- **`--stale-by-output`** — stale iff the two channel files'
  `outputs.identify` objects are not both present and deep-equal (a
  missing channel file counts stale).
- **`--stale-by-minutes=N` / `--stale-by-hours=N` /
  `--stale-by-days=N`** — mode-scoped age of `meta.updated_at`
  (`from-identity/<id>.json` for from-identity,
  `from-capture/<id>.json` for from-capture); stored in minutes.
- **`--stale-by-harness-version`** — the capture file's
  `meta.harness_version` vs a live `version_invocation` probe
  (zero-token).
- **`--stale-by-detect-version`** — the channel file's
  `meta.agent_detect_version` absent or ≠ this binary's version (the
  designated sweep after a `build.zig.zon` bump).
- **`--stale-by-invocation`** — the capture file's recorded
  `meta.prompt_invocation` is missing or differs from the latest one
  in index.json's `invocations` table (an updated invocation
  re-captures; a from-identity entry skips this criterion — declared
  files carry no invocation).

**`--stale`** ≡ output OR days=27 OR harness-version OR detect-version
OR invocation — the composite. **Defaulting:** `--stale` is defaulted
to true — a queue upsert with no staleness flags carries the full
composite. Exceptions: any explicit `--stale-*` ⇒ `--stale` is NOT
defaulted (the explicit flags alone form the entry's set); `--refresh`
⇒ the entry carries NO criteria, so every candidate is worked
regardless of freshness (the explicit opt-back-in to full
re-evaluation). **Component overwrite:** `--stale` provided together
with an explicit `--stale-*` ⇒ the explicit value overwrites the
composite's default for that component only (`--stale --stale-by-days=0`
= output + days=0 + harness-version + detect-version + invocation;
`--stale --stale-by-days=999999999` effectively disables the age
component). **Conflicts (exit 3):** `--refresh` with `--stale` or any
`--stale-*`. **Uniform default rule:** a queue item with no `--stale-*`
and no `--refresh*` pops with the same `--stale` default. **Why:**
churn prevention — with `--stale` defaulted, idle re-queues only pick
genuinely stale combos.

**`--repair`** (the one action flag; on `fixtures queue`): pops the
backlog, re-evaluates each item against the CURRENT binary's rule
tables and grids, and re-queues the now-actionable items — unknown_*
dim item now resolvable → removed from the backlog + one from-identity
entry per item filtered on that dim; unknown_invocations item that now
has an invocation of record → removed + a `--fixture=<id>`
from-capture entry; the unfixtured → one from-identity entry over the
feasible universe, honoring dims filters. Items still unresolvable /
still invocation-less stay in the backlog; repair logs them.

**`fixtures status`** — the derived snapshot: fixtured counts per
folder, the backlog sets (maintained), feasible-unfixtured totals,
stale/fresh breakdowns under the composite. The dev agent's
discernment surface; the log is the timeline, status is the now.

### user-only daemon (not the agent)

The user — not the agent — runs `fixtures daemon`. The daemon's
agent-detect guard refuses to start if it's running inside an
agent (env-marker + ancestry check). If the agent's workflow stalls
because the daemon isn't running, the correct action is for the
agent to surface the command and the directory the user should run
it in. The agent never runs the daemon. The exact guard and what it
checks is documented on `runFixturesDaemon` in `src/dev/dev.zig`.
A user run from a terminal is the baseline; on macOS the same clean
user context can be achieved without a terminal via the per-user
LaunchAgent bootstrap (no sudo, launchd-parented), which is documented
in CONTRIBUTING.md "daemon launch: macOS LaunchAgent bootstrap".

### recipe-mode identify/trailer (hard-to-detect agents)

Some harnesses are hard or impossible to detect live (they don't run
inside their own session, or leave no reliable markers). For those, a
maintainer adds the harness/provider/model to the rule tables and
`identify`/`trailer co-author`/`trailer assisted-by`/`check-reciprocal`
accept a complete combo
(`--harness=H --provider=P --model=M`) that resolves against the
rules without live detection. All three dims are required (or none);
a partial combo exits 4 and an unknown id exits 7. `detectable` in
recipe mode
reflects the recipe (up to all three dims).

## scope

- **Multi-harness, multi-OS, multi-arch.** Per-platform native
  binaries via `zig build dist`. Universal/fat formats rejected —
  see [README.md](./README.md) for the per-platform binary table.
- **Zero runtime dependencies.** The *released* binary is one file,
  no shared libraries, no runtime. The maintainer `fixtures` workflow
  reads and writes the local `fixtures/index.json` with Zig-native
  file locks — no external tools are required.
- **Never guess.** When detection can't fully resolve harness +
  provider + model, the binary exits 8 (unable to detect) with a
  single-line error
  and writes no fixture. A partial detection is bad data, not a
  placeholder. The test suite (`src/known_fixtures.test.zig`)
  enforces the 18-field identify contract (and that every committed
  fixture carries a `from-identity` channel), so a "backfill to make
  tests pass" approach can't slip in.

## exit status registry

The canonical exit-status registry. Each distinct kind of outcome has
its own number — `1` is **not** a fallback for everything; it is
reserved strictly for genuinely unexpected/unclassified failures
(uncaught zig errors, bugs). Every known error kind has its own status
(2–13). The registry lives here; the CLI `--help` text only points at
this section (plus brief per-action exit codes in context), and
README.md mentions exit codes contextually per example only.

| code | name | meaning |
| ---- | ---- | ------- |
| 0 | success | action completed; also explicitly-requested help/version |
| 1 | unrecognised error | unexpected/unclassified (uncaught zig error, bug) |
| 2 | unrecognised argument | unknown action / flag / subcommand |
| 3 | conflicting argument | recognised but incompatible combination |
| 4 | missing required arguments | required arg(s) absent |
| 5 | incompatible environment refusing run | env present but incompatible → tool refuses |
| 6 | incomplete environment preventing run | env missing required dependency → can't run |
| 7 | missing specified agent | user-named combo not in rule tables |
| 8 | unable to detect unspecified agent | live detection identity unresolvable |
| 9 | agent data incomplete to make a determination | identity resolved, policy data missing |
| 10 | agent data complete and requirement failed | determination definitive + negative (e.g. not reciprocal) |
| 11 | out of memory | allocation failed (released + dev) |
| 12 | index store error | fixtures/index.json corrupt/unparseable/unknown store_version (dev) |
| 13 | filesystem I/O error | read/write/dir/lock op failed (dev capture/daemon) |

Examples per group:

- **0** — `identify` (identified) → JSON; `trailer co-author` →
  `Co-authored-by: ...`; `trailer assisted-by` → `Assisted-by: ...`;
  `check-reciprocal` → `is reciprocal`; `version` → `agent-detect
  <version>`; `help`/`--help`/`-h`/no args/`trailer help`/`help
  trailer` → usage.
- **1** — uncaught error → `error: <name>` + trace.
- **2** — `agent-detect foobar` → `unrecognised argument: 'foobar'` +
  usage; `--bogus`; dev `fixtures frobnicate`.
- **3** — `agent-detect identify trailer` → `conflicting argument` +
  usage; dev `fixtures queue --refresh --stale-by-minutes=30`.
- **4** — `identify --harness=cline` (partial combo); bare
  `agent-detect trailer`; dev `fixtures queue` without filter.
- **5** — dev `fixtures daemon` inside an agent → `incompatible
  environment refusing run`.
- **6** — reserved; the released binary reports env-level failure
  before the dev surface runs. (The sqlite3-CLI dependency this code
  once described is gone — the dev store is a local JSON file.)
- **7** — `identify`/`trailer co-author`/`check-reciprocal`
  `--harness=foo --provider=bar --model=baz` → `missing specified
  agent (harness = "<resolved>", provider = "<resolved>", model = null)`
  — each dim reports its resolved strict-slug id or `null`.
- **8** — `identify`/`trailer co-author`/`check-reciprocal` when live
  detection resolves nothing (plain shell); dev `fixtures capture`
  partial → `unable to detect unspecified agent (harness = "<resolved>",
  provider = "<resolved>", model = null)` — each dim reports its
  resolved strict-slug id or `null`.
- **9** — `check-reciprocal` with identity resolved but
  `harness_license`/`model_reciprocity`/`provider_closed_training`
  null (e.g. crush/hyper/qwen3.7-plus), or `harness_license` is
  `"NOASSERTION"` (attempted, inconclusive) → `agent (harness,
  provider, model) data incomplete to make a determination`.
- **10** — `check-reciprocal` for kilo/anthropic/claude-sonnet-4 (closed
  model), or any harness whose `harness_license` is `"NONE"` (verified
  proprietary/closed, e.g. cursor/copilot) → stderr `agent (harness,
  provider, model) data complete and requirement failed`, stdout
  `not reciprocal`. `NONE` forces `.not_reciprocal` even when the
  model/provider dims are unverified.
- **11** — allocation failure anywhere (`try a.dupe`/`allocPrint` etc.)
  → `error.OutOfMemory`.
- **12** — dev `fixtures *` where `fixtures/index.json` is corrupt or
  carries an unknown `store_version` → `index store error`. Released
  `kiloSqliteJson` catches its own, so hard store errors are dev-only.
- **13** — dev capture/daemon `createDirPath`/`openDir`/`writeFile`/
  log-`createFile` failures → filesystem I/O error.

**stdout/stderr discipline.** `check-reciprocal` writes its determination
to stdout only (`is reciprocal` on 0, `not reciprocal` on 10); exits
7/8/9 are stderr-only. `identify`/`raw` are data-output actions: exit 8
(identity unresolved) writes **no stdout** (no sensible data), exit 9
(identity complete, policy data missing) writes the partial report to
stdout plus a stderr explainer, exit 0 writes the full report. `trailer`
writes to stdout only on success; 4/7/8 are stderr-only. Usage errors
(2/3/4) dump the relevant usage text.

## evergreen decisions

Recorded so a future maintainer doesn't re-litigate them. Each item
names the shipped behavior and why it was chosen.

1. **Never guess.** Partial detection exits 8 (unable to detect) and
   writes nothing to
   the fixture files — the fixtures-only approach means every committed
   `fixtures/from-*/*.json` is a real capture (or a rule-derived recipe
   report), never an assembly.
2. **Queue entries are filters, never work items.** A `queue` entry
   means "re-evaluate every known row matching my dims/markers/axes",
   not "fill missing combos" — the daemon expands the entry into its
   candidate set and works one per poll. Only the daemon expands.
3. **index.json via Zig-native locks, not sqlite.** The single committed
   `fixtures/index.json` gives cross-process coordination (an exclusive
   lock on a lock file + temp/rename atomic writes) and
   git-friendly, hand-editable storage with zero new dependencies in
   the released binary — and zero runtime dependencies in the
   `fixtures` workflow either. The store holds only the non-derivable
   state (queue / backlog / invocations): the fixture files
   themselves carry the saved outputs and the meta (ledger dates,
   writer version, and the invocation of record (`prompt_invocation`/
   `version_invocation`) — not Zig); the free and feasibility axes live
   in grid CSVs
   (`providers-freemodels.csv`, `harnesses-providers.csv`,
   `providers-models.csv`).
4. **Kilo live-DB fallback.** Live identity inference falls back
   env marker → `KILO_MODEL` → a direct read of the live
   `~/.local/share/kilo/kilo.db`. The *active* session is the
   non-archived session whose newest `message` was written in the cwd
   (real conversational activity, not the session row's `time_updated`,
   which background syncs/compaction bump — and not the lazily-written
   `session.model` column). Opencode uses the same schema/query via
   `~/.local/share/opencode/opencode.db`; copilot prefers its running
   non-archived session. Production stays SQLite-free except for these
   read-only session-store reads.
5. **No `--no-*` flags.** Fixture ids always carry all four dims;
   an unconstrained dim is an absent filter field on a queue entry
   only. There is no "explicit null" CLI spelling.
6. **No auto-reconcile.** Committed fixture files are authoritative;
   the store holds no fixture rows to reconcile — the known universe
   is the union of the two channel folders' filename stems, read at
   expansion time, and the backlog is refreshed from folder scans.
   Reconciliation work is explicit: `--repair` re-queues actionable
   gaps, staleness criteria re-work stale channels.
7. **Daemon is user-only.** The agent never runs the daemon; the
   env-marker + ancestry guard fails closed (`runFixturesDaemon`).
8. **Released binary stays minimal.** No index.json store, no `fixtures`, no raw
   dump in the released artifact — the `dev` module
   (comptime-gated) in `src/dev/dev.zig` drops that code at
    compile time. Released actions: `identify`, `trailer co-author`,
    `trailer assisted-by`, `check-reciprocal`, `help`, `version`.
9. **The 18-field canonical identify contract.** Test-enforced
   (see `src/known_fixtures.test.zig`); the raw block is shapeless
   (source-grouped keys, embedded as the from-capture file's `outputs.raw`),
   and harness rule *static* data
   (env-marker/binary-name lists) is intentionally NOT re-emitted in
   raw.
10. **`fixtures dequeue` = DELETE, `fixtures capture` = fixtures-only.**
    Dequeue never mutates fixtures; capture never touches queue; the
    daemon never writes `fixtures` outside pop processing and never
    inserts queue rows (purity).
11. **Recipe-mode `identify`.** A harness whose provider/model can't be
    auto-detected is a warning for a later dev agent, not a hard
    failure: `identify`/`trailer co-author`/`trailer assisted-by`/
    `check-reciprocal` accept a full
    `--harness= --provider= --model=` combo resolved from the rule
    tables.
 12. **`*_id` fields are strict slugs.** `harness_id`, `provider_id`,
     `model_id`, `agent_id`, `platform_id`, and the derived `fixture_id`
     are strictly lowercase-alphanumeric slugs of the canonical `*_name`
     (no separators). `*_name` carries the service's own spelling; the
     ids are what machine matching and fixture filenames use.
 13. **Bulk model additions are constrained to the evergreen model set.**
     When models are added en masse (maintenance sweeps, expanding a
     harness across a batch of providers, free-catalog imports), every
     new model — paid or free, on any provider — must clear the coalesced
     evergreen model set (top 100 weekly models from OpenRouter's models
     API, filtered to models that support tool calling: `supported_parameters` contains `tools`).
     The gate is on additions only — a supported model is dropped when the
     harness or provider whose addition made it supported no longer offers
     it, never merely because it fell out of the set (an added dim is
     something someone is using agent-detect for). Observed-but-unadded
     provider catalog ids are recorded in the
     `fixtures/providers-models.csv` reference grid.
     The tracked set is regenerated from OpenRouter alone (one
     authenticated call, see below) as part of maintenance; it is not
     maintained by hand and there is no CI task for it.
     Dropped alternatives — how the set used to be sourced, kept for
     information only:
     - [artificialanalysis.ai](https://artificialanalysis.ai)
       (Intelligence Index leaders),
     - [lmarena.ai / arena.ai](https://arena.ai) (LMArena leaderboard),
     - [llm-stats.com](https://llm-stats.com),
     - [huggingface.co/models](https://huggingface.co/models) (trending
       base-weights, finetunes/GGUF/image/audio models excluded),
     - [openrouter.ai/models?order=top-weekly](https://openrouter.ai/models?order=top-weekly)
       (the website, superseded by the `/api/v1/models` call below).
     This guard is for bulk/maintenance work
     only and does NOT apply retroactively to models already in the
     matrix, and it does NOT apply to an individual addition a user
     explicitly needs (a one-off `--harness= --provider= --model=` combo
     added on request is always allowed). "Free on that provider" only decides whether a free launch/capture
     is attached — a model free on one provider is not assumed free on
     another. Source of truth for free-vs-paid: a harness's own model
     catalog (omp's `models.db` per-provider `cost`) is the best
     harness-local source because it's the exact catalog the harness
     resolves against; OpenRouter's `/api/v1/models` is the best
     cross-provider source (explicit `:free` model ids + per-model
     `pricing`); artificialanalysis.ai lists per-model price and its
     cheapest/free models. arena.ai (LMArena) and HF trending are NOT
     free/paid sources — rankings and published weights respectively,
     not serving prices. The rank set (which models qualify) and the
     free/paid determination are separate concerns. Name variations
     across services (e.g. `gpt-5.6-sol` vs
     `gpt-5.6-luna`, `claude-opus-4.7/4.8/5`, `qwen3.5/3.6`, the
     `:free` vs `-free` vs `-0731` stamps) are coalesced into one
     canonical model per family, and the service-specific spellings are
     recorded as variations on the recipe, never added as duplicates.
     Provider serving-environment stamps (Chutes' TEE suffix) and
     endpoint/tier variants fold the same way; folding never crosses
     `model_license` or param-size differences, and ids carry a size
     distinction only where competing claims on the non-distinct name
     make it necessary to discern the model (official-claim naming;
     `model_license`, the 18th canonical field, keeps the license
     dimension explicit in every report).
     The tracked set is a direct snapshot of OpenRouter's own ranking —
     the raw `data` array of
     `GET /api/v1/models?sort=top-weekly&limit=100`, jq-filtered to
     models whose `supported_parameters` includes `tools`
     (`fixtures/evergreen-models.json`), regenerable with one
     authenticated call. The available-providers snapshot is
     `fixtures/evergreen-providers.json` (the raw `data` array of
     `GET /api/v1/providers`), regenerated the same way. The harness
     target set is `fixtures/evergreen-harnesses.txt` (top 50
     programming/code agents, curated from the two agent directories
     referenced in its header; see CONTRIBUTING.md "harness quality
     filters"). See CONTRIBUTING.md
     "probing scope + runbook" (evergreen model set).
 14. **`binary_names` is the single name origin.** Each harness rule
     carries one hand-maintained list of executable names
     (`HarnessRule.binary_names`, written inline as a platform ternary:
     bare stems first, then platform extensions — `.cmd`/`.ps1` only for
     the npm-shimmed harnesses). The detection ancestry scan, the
     availability probe, the `--version` probe, launch argv[0]
     substitution, and the daemon guard all read that one list, so they
     can never drift. Per-recipe name lists no longer exist;
     `harnessRuleForFixtureId` slug-resolves a recipe's first `agent_id`
     segment through `canonicalIdFor` (`kimicode` → the `kimi-code`
     rule). The guard additionally covers `pending_binary_names` (the
     not-yet-ruled harnesses). Adding a harness rule therefore means
     filling in one field, not five lists.

## test matrix: harnesses, providers, models

The committed fixture suite doubles as the integration test of the
detection ladder. This section pins the matrix policy — what gets a
rule, a recipe, and a fixture — so contributors extend it without
re-litigating scope.

- **Harness scope (coding harnesses only):** `cline`, `kimi`, `mmx`,
  `pi`, `qwen`, `kilo`, `omp`, `reasonix`, `crush`, `opencode`,
  `vibe`, `cursor`, `copilot`. Claw / machine-control agents are out of
  scope. `goose` remains as a contributor-scope example fixture (kept,
  not extended). The remaining maintained CLIs (`claude`, `codex`,
  `grok`, `gemini`, `amp`, `roo`, `qoder`, `openhands`, `devin`,
  `droid`, `zencoder`, `kimchi`, `firebender`) are logged follow-ups in
  CONTRIBUTING.md's pending list, not in-scope until a contributor
  adds their rules.
- **Model policy:** open-weight/open-source models are preferred; free
  closed and popular closed models also get rules (detection must
  exceed the preferred set). `reciprocity` is `open-source` |
  `open-weight` | `closed`, sourced from the HF card + LICENSE (or the
  provider's model page for closed models).
- **Provider policy:** zero-training or reciprocal-training providers
  are preferred. Maintainer probing covers free combos of those plus the
  paid MiniMax subscription; anything beyond that is contributor scope
  via CONTRIBUTING.md. New free providers: OpenRouter, Groq, Cerebras,
  Z.ai, Kimi/Moonshot (training policies null until verified).
- **Paid default:** MiniMax subscription. Subscriptions are preferred
  over pay-as-you-go (DeepSeek paid API is secondary; DeepSeek free
  combos use the free tier).
- **Global-settings rule:** never change a global harness/provider/model
  setting to make a fixture pass — use env/arg/scope flags only.
  `agent-detect` reads harness configs read-only and performs no config
  writes (nothing lands in a sandboxed HOME or anywhere else). Flag any
  needed global change instead.
- **Evidence-attribution rule:** raw/evidence are **review artifacts** —
  the mechanical evidence check was removed. Every detected dim's
  attribution is human + dev-agent review (capture review window +
  commit review of `outputs.raw`); the code no longer gates on it.
  Sources that can't serialize into a claim (custom database formats,
  e.g. kilo's sqlite session store) are logged follow-ups, never faked.
  Declared fixtures carry no evidence at all.
- **Cross-platform daemon control principle (decision #12):** one
  `fixtures/daemon.ctl` protocol for `pause`/`resume`/`stop` across
  macOS/Linux/Windows — no per-platform signal doubles. Ctrl+C stays
  the terminal graceful-stop shortcut; the daemon clears the control
  file after acting.
- **Refresh flavours:** every queue entry runs in one of two modes —
  `from-identity` (resolve the declared identification from provided
  ids; declared, not observed; zero tokens; harness not required) and
  `from-capture` (launch the real harness so it runs `fixtures capture`
  in a live model session; token-consuming, user-confirmed only).
  **No mode flag → both entries are queued per candidate** (declared first
  by mode rank, capture upgrade after); exactly one flag → that mode
  only; both flags → exit 3. The fixture envelope is the per-channel
  object shape defined above ("per-platform fixtures"). See
  CONTRIBUTING.md for installs and the probing runbook.
