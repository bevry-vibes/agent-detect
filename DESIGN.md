# design

## problem

AI agents working on Bevry projects must identify their **harness**,
**provider**, and **model** before working, and must credit commits
with an accurate `Co-authored-by` trailer (see
[policy.md](https://github.com/bevry-labs/skills/blob/main/policy.md) and
[commits.md](https://github.com/bevry-labs/skills/blob/main/commits.md)).
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
above `pub fn detect` in `src/main.zig`.

### two-binary split (released + dev-only)

The released binary must stay minimal — no raw dump, no subcommands,
no fixtures — so it ships as a single static file with no surprises.
Its CLI surface is `cooked`, `trailer`, `help`, `version`. The dev
binary (`agent-detect-dev`) carries the maintainer's full toolkit: the
standalone `raw` action (raw observations block) and the `fixtures`
subcommand namespace (capture / daemon / queue / dequeue). The split
is enforced at compile time via the `dev` flag in `build.zig` and the
`pub const dev = if (build_options.dev) struct { ... } else struct {};`
block in `src/main.zig`. The released binary cannot accidentally
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
`RawObservation.process_lineage` doc comment in `src/main.zig`.

### per-platform fixtures (no churn across platforms)

Harness config locations differ per platform (macOS uses
`~/Library/Application Support/...`, Linux uses `~/.config/...`,
Windows uses `%APPDATA%\...`). The fixture filename includes the
`platform_id` so a CI run on one platform never invalidates another
platform's committed files. Each platform has its own
`fixtures/<fixture_id>.json`, a single file with three top-level keys:

- `cooked` — the 18-field canonical object (`harness_id`,
  `provider_id`, `model_id`, `agent_id`, policy fields, trailer).
- `raw` — the shapeless runtime observations, headed by `platform_id`,
  `detectable`, and `detected`.
- `trailer` — the `Co-authored-by` string (duplicates
  `cooked.trailer`; the top-level key is the canonical one).

The `-<platform>` suffix keeps per-platform config paths from churning
each other across CI runs. The filename contract is defined on the
`fixtures capture` command (`dev.runFixturesCapture`) in `src/main.zig`.

### the `detectable` / `detected` raw fields

Both live at the top of the `raw` block, adjacent to each other and
right after `platform_id`:

- `detectable` — the dims (`harness` / `provider` / `model`) this run
  *could* resolve: what the detection ladder reached (live mode) or
  what the recipe implies (recipe mode; up to all three).
- `detected` — the dims that actually landed in the `cooked` block
  this run (a subset of, usually equal to, `detectable`).

A reader can instantly see what a fixture claims without scanning the
`cooked` block.

### SQLite state store (cross-process coordination)

The store is a single SQLite database, `fixtures/index.sqlite3`,
accessed by shelling out to the system `sqlite3` CLI. It has **two
tables**:

- `fixtures` — one row per captured 4-tuple
  `(harness, provider, model, platform)`, all four dims NOT NULL,
  with `platform` always the host platform. This is **state**: what has
  been captured and when (`generated_at`). Written only by
  `fixtures capture`, the daemon, and the lazy file-based backfill.
- `queue` — the work **queue**: "capture <these dims> [under this
  scope]". Dims are nullable (NULL = unset seed); each scope filter is
  its own three-valued column (`1` active / `0` explicit-off / `NULL`
  undeclared); `stale_by_days`/`stale_by_minutes` carry a staleness
  threshold; `available` is a three-valued probe-status column (`1`
  probed available, `0` probed unavailable — a queued handoff for the
  next agent/platform, `NULL` not probed). Written by `fixtures queue`.

The derived `fixture_id`/`agent_id` are *not* stored; they're
recomputed per use (`fixtureIdFrom`/`agentIdFrom`) for fixture naming
and messaging, so a queue row stays a pure dims+scope instruction.
Idempotency on `queue` is enforced by the `queue_dedupe` unique index
(create-or-flip without a key string).

Rows with one or more missing dims are **seeds** — queue placeholders
that say "capture something matching these dims". The daemon expands
seeds over the `recipesForFixtures` recipes: every recipe whose set
dims match is queued as a full action, then the seed is dropped. Seeds
with no applicable recipe (unknown ids) are **warned once per run and
kept**, so a bad seed is visible in logs without spinning.
`fixtures capture` never touches `queue`; it only writes a `fixtures`
row (partial detection exits 2 with no store change per the "never
guess" rule). `fixtures dequeue` is a pure **DELETE** of matching
`queue` rows — it never mutates `fixtures`.

### lazy file-based backfill (replaces the old JSONL migration)

The store is **not** backfilled at init. Instead, when the daemon
processes a full queue row with `refresh:false` semantics (no
`scope_all`) and a valid committed `fixtures/<fixture_id>.json` exists
for the combo — the file parses and its `cooked` block carries the
exact dims — the daemon upserts the `fixtures` row from the file and
completes without spawning a capture. Fixture files carry no
timestamps, so the row records `runner = getParentPid()` and
`generated_at = unixNow()`. This is the "already captured, don't
re-capture" behavior.

### user-only daemon (not the agent)

The user — not the agent — runs `fixtures daemon`. The daemon's
agent-detect guard refuses to start if it's running inside an
agent (env-marker + ancestry check). If the agent's workflow stalls
because the daemon isn't running, the correct action is for the
agent to surface the command and the directory the user should run
it in. The agent never runs the daemon. The exact guard and what it
checks is documented on `runFixturesDaemon` in `src/main.zig`.

### recipe-mode cooked/trailer (hard-to-detect agents)

Some harnesses are hard or impossible to detect live (they don't run
inside their own session, or leave no reliable markers). For those, a
maintainer adds the harness/provider/model to the rule tables and
`cooked`/`trailer` accept a complete combo
(`--harness=H --provider=P --model=M`) that resolves against the
rules without live detection. All three dims are required (or none);
a partial combo or an unknown id exits 2. `detectable` in recipe mode
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
  provider + model, the binary exits 2 with a single-line error
  and writes no fixture. A partial detection is bad data, not a
  placeholder. The test suite (`src/known_fixtures.test.zig`)
  enforces that every committed fixture has all 18 canonical fields
  non-null, so a "backfill to make tests pass" approach can't slip
  in.

## evergreen decisions

Recorded so a future maintainer doesn't re-litigate them. Each item
names the shipped behavior and why it was chosen.

1. **Never guess.** Partial detection exits 2 and writes nothing to
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
   `~/.local/share/kilo/kilo.db` (newest session row for the cwd).
   Production stays SQLite-free except for this read-only Kilo store.
5. **No `--no-*` flags.** A `fixtures` row always has all four
   dims NOT NULL; an unset dim is expressed as a NULL seed dim in
   `queue` only. There is no "explicit null" CLI spelling.
6. **No auto-reconcile.** Committed `fixtures/*.json` are
   authoritative; `--missing-fixture` keys off the filesystem and
   option B (reconcile-on-read) was rejected. The store is populated
   lazily from committed files (see "lazy file-based backfill").
7. **Daemon is user-only.** The agent never runs the daemon; the
   env-marker + ancestry guard fails closed (`runFixturesDaemon`).
8. **Released binary stays minimal.** No SQLite, no `fixtures`, no raw
   dump in the released artifact — the `dev` modular
   (comptime-gated) block in `src/main.zig` drops that code at
   compile time. Released actions: `cooked`, `trailer`, `help`,
   `version`.
9. **The 18-field canonical fixture contract.** Test-enforced
   (see `src/known_fixtures.test.zig`); the raw block is shapeless
   (source-grouped keys), and harness rule *static* data
   (env-marker/proc-name lists) is intentionally NOT re-emitted in
   raw.
10. **`fixtures dequeue` = DELETE, `fixtures capture` = fixtures-only.**
    Dequeue never mutates fixtures; capture never touches queue; the
    malformed-fixtures sweep `purgeMalformedFixtures` runs as a daemon
    idle-loop step.
11. **Recipe-mode `cooked`.** A harness whose provider/model can't be
    auto-detected is a warning for a later dev agent, not a hard
    failure: `cooked`/`trailer` accept a full
    `--harness= --provider= --model=` combo resolved from the rule
    tables.
12. **`*_id` fields are strict slugs.** `harness_id`, `provider_id`,
    `model_id`, `agent_id`, `platform_id`, and the derived `fixture_id`
    are strictly lowercase-alphanumeric slugs of the canonical `*_name`
    (no separators). `*_name` carries the service's own spelling; the
    ids are what machine matching and fixture filenames use.
