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
subcommand namespace (capture / daemon / queue / dequeue). The split
is enforced at compile time via the `dev` flag in `build.zig` and the
`pub const dev = if (build_options.dev) struct { ... } else struct {};`
block in `src/dev/dev.zig`. The released binary cannot accidentally
include dev code paths.

The split is about **code**, not portability: the `fixtures` workflow
is cross-platform. The state store is the local `fixtures/.index.json`
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
platform's committed files. Each platform has its own
`fixtures/<fixture_id>.json`, a single file whose top-level keys are
per-channel objects:

- `from-identity` (required) — the declared identification channel:
  `identify` (the 18-field canonical object: `harness_id`,
  `provider_id`, `model_id`, `agent_id`, policy fields, no `trailer`)
  plus `"trailer co-author"` and `"trailer assisted-by"`.
- `from-capture` — the live session's identification channel (same
  shape as `from-identity`, written by a real capture).
- `from-capture-raw` — the slimmed shapeless runtime observations,
  headed by `platform_id`, then `harness_version` (the live version
  snapshot — null when the agent's version is not yet knowable), then
  `detectable`, and `detected`, then
  `process_lineage`, the `*-urls` reference arrays, and the `evidence`
  claims — the dev `raw` output verbatim. The block deliberately does
  NOT duplicate the env vars / config files / session files verbatim
  (decision #4 — raw slimming): the `evidence` section documents the
  source that informed each canonical deduction. Env-source evidence
  claims on non-allowlisted env vars carry the literal `"<redacted>"`
  value so secrets never reach disk while the attribution chain stays
  audit-trailable.

The old top-level `cooked`/`raw`/`trailer`/`origin` keys are gone; the
root `trailer` no longer exists (the trailer variants live per-channel,
which is what makes the trailer-variations coverage possible).

The `-<platform>` suffix keeps per-platform config paths from churning
each other across CI runs. The filename contract is defined on the
`fixtures capture` command (`dev.runFixturesCapture`) in `src/dev/dev.zig`.

### the `detectable` / `detected` raw fields

Both live at the top of the `from-capture-raw` block, adjacent to each
other and right after `platform_id`:

- `detectable` — the dims (`harness` / `provider` / `model`) this run
  *could* resolve: what the detection ladder reached (live mode) or
  what the recipe implies (recipe mode; up to all three).
- `detected` — the dims that actually landed in the `identify` block
  this run (a subset of, usually equal to, `detectable`).

A reader can instantly see what a fixture claims without scanning the
`identify` block.

### index.json state store (cross-process coordination)

The store is a single committed JSON document, `fixtures/.index.json`,
with **three tables** (`fixtures` the known universe, `errors` the
failure ledger, `queue` the filter-entry array; the free axis is
declared by `fixtures/.providers_freemodels.csv`, not the store). The
normative shapes — field
names, types, key formats, optionality — are declared in TypeScript at
**`fixtures/.index.d.ts`**: the schema file is the source of truth for
structure and this section documents only the semantics. (The zig
program never imports TypeScript; the schema exists so the docs stop
re-describing the shape in prose.) **Null-as-absent:** unset optional
fields are omitted from the store entirely — never serialized as
`null` — and the schema's `?:` optionality is exactly that contract
(readers treat a missing field as unset).

- `fixtures` — the known universe: one row per 4-tuple
  `(harness, provider, model, platform)`, keyed by the dash-joined
  fixture id (== the fixture filename stem; dims are never repeated
  inside the row). A row's `identity`/`capture` ledgers date the
  channels and carry `channel_hash` = BLAKE3 of the whole channel
  object as written into the fixture file; `capture.harness_version`
  is the version a live `version_launch` probe reported, and
  `agent_detect_version` is the capturing binary's version. There is
  **no row-level timestamp** — age checks are mode-scoped on the
  channel dates, and there are **no `available`/`successful`
  markers** — failures live in `errors`. An absent `version_launch`
  means the version probe fails closed; absent launch argv marks a
  from-identity-only row. Written by `fixtures capture`, the daemon's
  identity worker, and the `--stale-by-missing-entry` registration
  pass.
- `errors` — the failure ledger keyed by dash-joined dims with the
  literal `null` for each unknown dim (`cline-null-null-windows`;
  all-unknown entries share `null-null-null-null`). The value is
  `{ "reason", "failed_at" }` from a closed reason set partitioned by
  class: `unsuccessful` ("capture failed", "unavailable",
  "post-check mismatch" — the combo has a fixture row, last evaluation
  failed) and `invalid` ("no launch spec", "unknown fixture file",
  "malformed fixture id", "malformed queue row" — structural breakage,
  error-only). **An entry exists only while the combo is failed — a
  successful capture/declaration purges it** (entry presence is the
  outcome signal). `failed_at` is the completion timestamp the pop
  protocol and the filter axes compare against.
- `queue` — the work **queue**: an array of **filter entries**, never
  concrete work items (only the daemon expands). Semantics: at most
  one `stale_by_*` marker set; the `known`/`valid`/`successful`/`free`
  axes are affirmative booleans whose absent state takes the
  expansion defaults (known=true, valid=true, successful/free
  unset); `started_at` is stamped by the daemon on the entry's first
  work and anchors the pop protocol's done rule. There is **no
  `finished_at`**: fully-satisfied entries are
  purged (deleted — the fixtures/errors ledger is the sweep record).
- The free axis lives in **`fixtures/.providers_freemodels.csv`** — a
  sparse provider×model grid (rows only for providers with ≥1 free
  model, columns only for models free somewhere, cell = the
  provider's free model-id or `-`). It is the source of truth for
  free models: the zig store code reads it at expansion time (the
  one grid it does read — the other two stay pure dev reference), and
  the retired `free_provider_to_model` store table is dropped on load
  and never re-serialized.

Writers take an exclusive lock on `fixtures/.index.json.lock` (a
gitignored lock file; kernel locks release on exit/crash — no
stale-lock heuristics) and write atomically (serialize →
`.index.json.tmp` → rename). Readers take no lock — the temp+rename
protocol makes visibility atomic. Failure modes: lock timeout → exit
13; corrupt/unparseable/unknown-`store_version` index.json → exit 12;
write/rename failure → exit 13.

Idempotency on `queue` is by tuple: a queue-command re-assert of an
existing (dims, mode, markers, axes) tuple replaces the entry in place
and resets `started_at` to absent (a fresh sweep); the daemon's own
writes preserve it.

The **pop protocol** (the daemon's per-poll expansion):
1. Scan entries in mode-rank order (from-identity first), then array
   order; delete entries with no remaining candidates anywhere and
   malformed entries (errors ledger + drop).
2. Expand the entry's universe — the `fixtures` map (known=true, the
   default) or the rule cross-product minus the known maps
   (known=false, the discovery sweep) — filtered by dims, platform
   (the entry's, or the host's per platform in the loop), the marker
   evaluations, and the filter axes.
3. A candidate is DONE when its completion timestamp (the entry's
   mode-scoped channel date, else `errors.<key>.failed_at`) is present
   AND ≥ the entry's `started_at`; stamp `started_at` on first work.
4. Work ONE remaining host-platform candidate per poll (adaptive
   pacing unchanged).
5. Candidates remain but none for this host: keep the entry, move on
   (another host's portion). Cross-host, the completion ledger rides
   git — an entry finishes on whichever host pops it after the last
   result lands.

Crash-resume derives from the completion ledger: a capture that died
with the daemon left no channel write, so its candidate re-runs.

The daemon is **pure**: it never writes `fixtures` outside pop
processing and never inserts queue entries.

### the four filter axes — `known`, `valid`, `successful`, `free`

Stored on queue entries as nullable affirmative booleans (null =
unset); the daemon applies defaults at expansion: **known=true,
valid=true, successful=unset, free=unset**.

- **`known`** selects the expansion universe:
  - true (default): the `fixtures` map (rows matching dims, platform =
    the entry's or the host's) — `--known` replaces `--all`/
    `--recipes`.
  - false: the rule cross-product (harness-rule × provider-rule ×
    model-rule × platform) minus the `fixtures` map and (with the
    default valid=true) the `errors` ledger — the discovery sweep:
    `--unknown --from-identity` declares the generated combos into
    `fixtures/` (the new-rule seeding workflow);
    `--unknown --from-capture` routes everything to errors ("no launch
    spec") — allowed, near-useless, documented.
- **`valid`** selects error-entry participation by class:
  - true (default): `invalid`-class entries are excluded from the
    universe.
  - false: `invalid`-class error entries become candidates again
    (re-evaluated): for known they join the fixtures rows; for unknown
    they stop being subtracted from the generated set. A successful
    re-attempt deletes the entry (purge-on-success).
- **`successful`** filters the known universe by entry presence:
  - null (default): no filter (the bare sweep re-evaluates everything
    known, mirroring `--all`).
  - true: only candidates with no error entry (purge-on-success makes
    "no entry" the successful signal).
  - false: only candidates with an `unsuccessful`-class error entry
    (replaces `--unsuccessful`/`--unavailable` sweeps).
- **`free`** filters candidates by the free table:
  - null (default): no filter.
  - true (`--free`): only candidates whose (provider, model) is listed
    (non-`-` cell) in `fixtures/.providers_freemodels.csv`.
  - false (`--paid`): only candidates whose (provider, model) is NOT
    listed. Unlike the marker fields, free-ness is derivable for
    generated combos too (dims are known from the cross-product), so
    `--unknown --free` is allowed.

XOR/conflicts (exit 3): `--known`+`--unknown`, `--valid`+`--invalid`,
`--successful`+`--unsuccessful`, `--free`+`--paid`, `--unknown` + any
marker (`--stale-by-*` — incl. `--stale-by-missing-entry` and
`--stale-by-missing-fixture`) or a non-default `successful` axis
(generated combos have no markers/outcomes to filter on).

### `--stale-by-missing-entry` (replaces the lazy file-based backfill)

The store is **not** backfilled at init and the daemon no longer
backfills from files at pop. Instead, `fixtures queue
--stale-by-missing-entry` queues an entry whose expansion is the
**registration pass**: every `fixtures/*.json` with no store entry is
re-registered — valid ids (known rule dims + filename platform) get a
`fixtures` entry (`fixture_hash` + the per-channel hashes from the
committed file; the channel dates stay absent, so age checks treat the
channels as stale until they are re-written; **no queue row**); invalid
ids go to the `errors` ledger (reason `unknown fixture file`). **The
file persists** either way — nothing is ever deleted. The pass is
idempotent: the entry is purged when no unregistered files remain.

### harness-version tracking + the staleness markers

A captured fixture records the harness's live version snapshot in
`capture.harness_version` (stamped by `fixtures capture` / the daemon
via the row's `version_launch` — a zero-token probe; declared
`from-identity` rows carry no version). The seven flat markers select
the stale candidates at expansion:

- `--stale-by-missing-entry` / `--stale-by-missing-fixture` — fixture
  files with no store entry (the registration pass) / store entries
  whose fixture file is absent.
- `--stale-by-days=N`, `--stale-by-hours=N`, `--stale-by-minutes=N` —
  mode-scoped age thresholds (always stored as MINUTES): a
  `from-identity` entry is age-stale iff `identity.declared_at` is
  missing or older than the threshold; a `from-capture` entry iff
  `capture.captured_at` is.
- `--stale-by-harness-version` — the captured version differs from a
  live `version_launch` probe.
- `--stale-by-detect-version` — `agent_detect_version` is null or
  differs from this binary's version (the designated sweep after a
  `build.zig.zon` bump).
- `--stale-by-fixture-hash` — `fixture_hash` differs from the
  committed file's BLAKE3 (missing file/hash = stale; detects any
  unrecorded file change, hand edits and git merges included).
- `--stale-by-channel-hash` — stale iff `identity.channel_hash` and
  `capture.channel_hash` are NOT both present and equal (divergence —
  the capture channel no longer matches the declared one — or nulls —
  channels not yet written — both count stale).

Markers are **pure enqueue** (or pure row filter for dequeue) — no
probing happens at queue time; the daemon evaluates them at expansion.
Marker sweeps require `known: true`.

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
  reads and writes the local `fixtures/.index.json` with Zig-native
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
| 12 | index store error | fixtures/.index.json corrupt/unparseable/unknown store_version (dev) |
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
  usage; dev `fixtures queue --stale-by-days=7 --stale-by-minutes=30`.
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
- **12** — dev `fixtures *` where `fixtures/.index.json` is corrupt or
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
   the store — the fixtures-only approach means every committed
   `fixtures/*.json` is a real capture (or a rule-derived recipe
   report), never an assembly.
2. **Queue entries are filters, never work items.** A `queue` entry
   means "re-evaluate every known row matching my dims/markers/axes",
   not "fill missing combos" — the daemon expands the entry into its
   candidate set and works one per poll. Only the daemon expands.
3. **index.json via Zig-native locks, not sqlite.** The single committed
   `fixtures/.index.json` gives cross-process coordination (an exclusive
   lock on a lock file + temp/rename atomic writes) and
   git-friendly, hand-editable storage with zero new dependencies in
   the released binary — and zero runtime dependencies in the
   `fixtures` workflow either. Curated data (the per-platform
   `prompt_launch`/`version_launch` argv) lives in the store, not in
   Zig; the free axis lives in its own grid CSV
   (`fixtures/.providers_freemodels.csv`).
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
5. **No `--no-*` flags.** A `fixtures` row always has all four
   dims NOT NULL; an unset dim is expressed as a NULL seed dim in
   `queue` only. There is no "explicit null" CLI spelling.
6. **No auto-reconcile.** Committed `fixtures/*.json` are
   authoritative; `--stale-by-missing-entry` re-registers files that
   have no store entry (valid ids → entry, invalid ids → `errors`) and
   option B (reconcile-on-read) was rejected. The store is populated
   explicitly, never lazily at daemon pop.
7. **Daemon is user-only.** The agent never runs the daemon; the
   env-marker + ancestry guard fails closed (`runFixturesDaemon`).
8. **Released binary stays minimal.** No index.json store, no `fixtures`, no raw
   dump in the released artifact — the `dev` module
   (comptime-gated) in `src/dev/dev.zig` drops that code at
    compile time. Released actions: `identify`, `trailer co-author`,
    `trailer assisted-by`, `check-reciprocal`, `help`, `version`.
9. **The 18-field canonical identify contract.** Test-enforced
   (see `src/known_fixtures.test.zig`); the raw block is shapeless
   (source-grouped keys, embedded as the `from-capture-raw` channel),
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
     `fixtures/.providers_models.csv` reference grid.
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
     (`fixtures/.evergreen-models.json`), regenerable with one
     authenticated call. The available-providers snapshot is
     `fixtures/.evergreen-providers.json` (the raw `data` array of
     `GET /api/v1/providers`), regenerated the same way. The harness
     target set is `fixtures/.evergreen-harnesses.txt` (top 50
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
  commit review of `from-capture-raw`); the code no longer gates on it.
  Sources that can't serialize into a claim (custom database formats,
  e.g. kilo's sqlite session store) are logged follow-ups, never faked.
  Declared fixtures carry no evidence at all.
- **Cross-platform daemon control principle (decision #12):** one
  `fixtures/.daemon.ctl` protocol for `pause`/`resume`/`stop` across
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
