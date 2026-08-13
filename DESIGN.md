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
is cross-platform. The state store is reached by shelling out to the
system `sqlite3` CLI, which ships with every OS the released binary
targets, so `fixtures` runs anywhere the released binary does. `zig
build dist` emits only the released binary — no dev variants are
produced.

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
  `identify` (the 17-field canonical object: `harness_id`,
  `provider_id`, `model_id`, `agent_id`, policy fields, no `trailer`)
  plus `"trailer co-author"` and `"trailer assisted-by"`.
- `from-capture` — the live session's identification channel (same
  shape as `from-identity`, written by a real capture).
- `from-capture-raw` — the slimmed shapeless runtime observations,
  headed by `platform_id`, `detectable`, and `detected`, then
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

### SQLite state store (cross-process coordination)

The store is a single SQLite database, `fixtures/index.sqlite3`,
accessed by shelling out to the system `sqlite3` CLI. It is
**committed** — it is the cross-host work queue + state. It has **four
tables**:

- `fixtures` — one row per 4-tuple
  `(harness, provider, model, platform)`, all four dims NOT NULL.
  This is **state**: what has been captured and when (`generated_at`),
  the `harness_version` captured by a live `--version` call during the
  capture (decision #6; null for declared `from-identity` rows), the
  `available`/`successful` outcome markers written by the daemon, the
  capturing `agent_detect_version` (NULL = stale / never captured), the
  four per-channel generation columns
  (`identity_generation_at`/`identity_generation_hash` +
  `capture_generation_at`/`capture_generation_hash`, hashes = BLAKE3
  over the channel object), and the derived `agent_id`/`fixture_id`
  (`#`-joined, maintained by every upsert). Written only by `fixtures
  capture`, the daemon (during pop processing), and
  `--missing-fixture-entry`.
- `queue` — the work **queue**: "capture <these dims> [under this
  scope]". Dims are nullable (NULL = unset seed); each scope filter is
  its own marker column (`scope_recipes`,
  `scope_missing_fixture_file`, `stale_by_minutes`,
  `stale_by_version`, `stale_by_detect`, `stale_by_hash`,
  `available`, `successful`); `mode` is the refresh flavour
  (`"from-identity" | "from-capture"`), always stamped explicitly and
  part of `queue_dedupe` so both rows for a candidate coexist. Written
  by `fixtures queue` only — the daemon never inserts queue rows.
- `pending` — one row per work item under a popped queue row
  (`queue_id` + a concrete `fixture_id`), with
  `started_at`/`finished_at`. The `UNIQUE(queue_id, fixture_id)` index
  makes crash-resume safe: re-materialization is `INSERT OR IGNORE`.
- `invalid` — bad-id rows (unknown fixture files, no-launch
  from-capture candidates, malformed seeds) for dev-agent remedy;
  never evaluated. Written by queue time, seed expansion, and
  `--missing-fixture-entry`.

Idempotency on `queue` is enforced by the `queue_dedupe` unique index
(create-or-flip without a key string), which includes `mode` (and the
staleness/hash markers) so the both-modes default can hold two rows per
candidate.

Rows with one or more missing dims are **seeds** — queue placeholders
that say "capture something matching these dims". The daemon expands
seeds into `pending` rows over the `recipesForFixtures` recipes: one
per recipe whose set dims match, on the host platform (no-launch
recipes under `from-capture` → `invalid`, excluded). Seeds are never a
scope (`--partial` is gone): every persisted row is either full-dim or
a NULL-dim seed expanded into defined `pending` rows.
`fixtures capture` never touches `queue`; it only writes a `fixtures`
row (partial detection exits 8 with no store change per the "never
guess" rule). `fixtures dequeue` is a pure **DELETE** of matching
`queue` rows — it never mutates `fixtures`.

The daemon is **pure**: popping any queue row materializes its `pending`
rows and evaluates them (from-identity: declared generation; from-capture:
probe + real harness session), stamps `fixtures`, and drains the row's
pending rows. **Platform-aware popping**: `AND (platform IS NULL OR
platform = '<host>')` — non-host rows stay queued, so darwin rows ride
the committed queue to a macOS daemon. The queue row stays queued until
its pending rows drain — it is the crash-resume anchor.

### `--missing-fixture-entry` (replaces the lazy file-based backfill)

The store is **not** backfilled at init and the daemon no longer
backfills from files at pop. Instead, `fixtures queue
--missing-fixture-entry` scans every `fixtures/*.json`: a file with no
`fixtures` row is re-registered — valid ids (known rule dims + filename
platform) get a `fixtures` entry (`successful=1`,
`generated_at=now`, `harness_version=NULL`, `available=NULL`,
`agent_detect_version=NULL`, generation columns NULL, derived ids; **no
queue row**); invalid ids go to the `invalid` table (reason `unknown
fixture file`). **The file persists** either way — nothing is ever
deleted. This is the fresh-clone store-population path (decision #6).

### harness-version tracking + staleness conjunction

A captured fixture records the harness's live `--version` snapshot in
`fixtures.harness_version` (stamped by `fixtures capture` / the daemon
via a zero-token `--version` call; declared `from-identity` rows carry
null). The `--stale-by-version` scope queues rows whose live
`--version` differs from the stored value, so a harness upgrade re-
captures its fixtures without waiting for an age threshold. The
`--stale-by-detect` scope queues rows whose `fixtures.agent_detect_version`
is NULL or differs from this binary's version (the designated sweep
after a `build.zig.zon` bump). The `--stale-by-hash` scope queues rows
whose stored per-channel generation hash is NULL or differs from the
BLAKE3 of the current fixture file's channel object (mode flags pick
the channel; no flag checks both, one row per stale channel's mode) —
pure file read + hash, no evaluation.

The daemon evaluates staleness at pop as a **conjunction**: a row skips
only when every marker it carries is fresh — age (`generated_at` within
the threshold) AND harness-version (live `--version` equal to the
stored value) AND detection (`fixtures.agent_detect_version ==
build_options.version`; NULL/missing → not fresh) AND hash (recomputed
file channel hash == stored generation hash for the row's mode channel;
missing file/channel → not fresh). A different version is stale even
when the fixture is age-fresh; an uninstalled harness is inconclusive
(proceeds to capture). Version comparison is exact-string mismatch; a
semver/calver "newer-than" comparator is a future refinement.

Scope flags compose (AND) with the dim filters; each scope flag is
**pure enqueue** (or pure row filter for dequeue) — no probing happens
anywhere. The only conflicting combination is two `--stale-by-*` age
thresholds (`--stale-by-days=`, `--stale-by-hours=`,
`--stale-by-minutes=`), which all store their threshold as MINUTES in
the single `stale_by_minutes` column. The standalone `--stale` flag was
dropped in favour of the explicit markers (see the fixtures help for the
current surface).

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
  additionally needs the system `sqlite3` CLI (preinstalled on every
  supported OS) to reach the state store.
- **Never guess.** When detection can't fully resolve harness +
  provider + model, the binary exits 8 (unable to detect) with a
  single-line error
  and writes no fixture. A partial detection is bad data, not a
  placeholder. The test suite (`src/known_fixtures.test.zig`)
  enforces the 17-field identify contract (and that every committed
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
| 12 | sqlite query error | sqlite3 ran but failed; bad SQL / corrupt store (dev) |
| 13 | filesystem I/O error | read/write/dir op failed (dev capture/daemon) |

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
- **6** — dev `fixtures *` with no `sqlite3` on PATH → `incomplete
  environment preventing run`.
- **7** — `identify`/`trailer co-author`/`check-reciprocal`
  `--harness=foo --provider=bar --model=baz` → `missing specified
  agent (harness, provider, model)`.
- **8** — `identify`/`trailer co-author`/`check-reciprocal` when live
  detection resolves nothing (plain shell); dev `fixtures capture`
  partial → `unable to detect unspecified agent (harness, provider,
  model)`.
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
- **12** — dev `fixtures *` where sqlite3 runs but query fails (corrupt
  `fixtures/index.sqlite3`, bad SQL) → `error.SqliteError`. Released
  `kiloSqliteJson` catches its own, so hard sqlite errors are dev-only.
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
2. **Seeds are actions.** A partial `queue` row means "re-run every
   recipe matching my set dims", not just "fill missing combos" —
   the daemon expands a seed into full combos and runs them all.
3. **SQLite via the `sqlite3` CLI, not a binding.** The single-file
   `fixtures/index.sqlite3` gives cross-process coordination and
   cross-platform storage with zero new dependencies in the released
   binary. The system `sqlite3` CLI is a runtime requirement of the
   `fixtures` workflow only (documented in CONTRIBUTING.md).
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
   authoritative; `--missing-fixture-entry` re-registers files that
   have no `fixtures` row (valid ids → entry, invalid ids → `invalid`
   table) and option B (reconcile-on-read) was rejected. The store is
   populated explicitly, never lazily at daemon pop.
7. **Daemon is user-only.** The agent never runs the daemon; the
   env-marker + ancestry guard fails closed (`runFixturesDaemon`).
8. **Released binary stays minimal.** No SQLite, no `fixtures`, no raw
   dump in the released artifact — the `dev` module
   (comptime-gated) in `src/dev/dev.zig` drops that code at
    compile time. Released actions: `identify`, `trailer co-author`,
    `trailer assisted-by`, `check-reciprocal`, `help`, `version`.
9. **The 17-field canonical identify contract.** Test-enforced
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
 13. **Bulk model additions are constrained to the evergreen top 100.**
     When models are added en masse (maintenance sweeps, expanding a
     harness across a batch of providers, free-catalog imports), every
     new model — paid or free, on any provider — must clear the coalesced
     evergreen top-100 rank set. This guard is for bulk/maintenance work
     only and does NOT apply retroactively to models already in the
     matrix, and it does NOT apply to an individual addition a user
     explicitly needs (a one-off `--harness= --provider= --model=` combo
     added on request is always allowed). The rank set is the union of
     what perennially clears the top-100 leaderboards of:
     - [artificialanalysis.ai](https://artificialanalysis.ai)
       (Intelligence Index leaders),
     - [lmarena.ai / arena.ai](https://arena.ai) (LMArena leaderboard),
     - [llm-stats.com](https://llm-stats.com),
     - [huggingface.co/models](https://huggingface.co/models) (trending
       base-weights, finetunes/GGUF/image/audio models excluded),
     - [openrouter.ai/models?order=top-weekly](https://openrouter.ai/models?order=top-weekly).
     "Free on that provider" only decides whether a free launch/capture
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
     Note: these leaderboards are JS-rendered and mostly lack public rank
     APIs, so the coalesced set is curated from the accessible signals
     (the artificialanalysis page + OpenRouter/HF model catalogs) rather
     than scraped. The tracked set is
     `fixtures/evergreen-top100-models.txt`. See CONTRIBUTING.md
     "probing scope + runbook" (evergreen top 100).
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
  `fixtures/daemon.ctl` protocol for `pause`/`resume`/`stop` across
  macOS/Linux/Windows — no per-platform signal doubles. Ctrl+C stays
  the terminal graceful-stop shortcut; the daemon clears the control
  file after acting.
- **Refresh flavours:** every queue job runs in one of two modes —
  `from-identity` (resolve the declared identification from provided
  ids; declared, not observed; zero tokens; harness not required) and
  `from-capture` (launch the real harness so it runs `fixtures capture`
  in a live model session; token-consuming, user-confirmed only).
  **No mode flag → both rows are queued per candidate** (declared first
  by mode rank, capture upgrade after); exactly one flag → that mode
  only; both flags → exit 3. The fixture envelope is the per-channel
  object shape defined above ("per-platform fixtures"). See
  CONTRIBUTING.md for installs and the probing runbook.
