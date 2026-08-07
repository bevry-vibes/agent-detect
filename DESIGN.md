# design

## problem

AI agents working on Bevry projects must identify their **harness**,
**provider**, and **model** before working, and must credit commits
with an accurate `Co-authored-by` trailer (see
[policy.md](https://github.com/bevry-labs/skills/blob/main/policy.md) and
[commits.md](https://github.com/bevry-labs/skills/blob/main/commits.md)).
Hard-coded answers rot; manual per-harness techniques go unread. This
repo provides a single small native binary, `agent-detection`, that
infers the identity from live evidence at runtime.

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
The dev binary carries the maintainer's full toolkit (raw dump,
`known` subcommand namespace, fixtures). The split is enforced at
compile time via the `dev` flag in `build.zig` and the
`pub const dev = if (build_options.dev) struct { ... } else struct {};`
block in `src/main.zig`. The released binary cannot accidentally
include dev code paths.

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
`platform_alphanumeric_id` so a CI run on one platform never
invalidates another platform's committed files. Each platform has
its own `known/<id>.{agent.json,.trailer.txt}` — the `.agent.json`
suffix mirrors the `.trailer.txt` sibling so fixtures are distinct
from the `known/index.sqlite3` queue tracker (the SQLite state store) and
any non-fixture JSON.
The filename contract is defined on the `known agent` capture
(`dev.runKnownAgent`) in `src/main.zig`.

### SQLite state store (cross-process coordination)

The store is a single SQLite database, `known/index.sqlite3`, accessed
by shelling out to the system `sqlite3` CLI. It has **two tables**:

- `fixtures` — one row per captured 4-tuple
  `(harness, provider, model, platform)`, all four dims NOT NULL,
  with `platform` always the host platform. This is **state**: what has
  been captured and when (`generated_at`). Written only by `known agent`
  and the daemon.
- `actions` — the work **queue**: "capture <these dims> [under this
  scope]". Dims are nullable (NULL = unset seed); each scope filter is
  its own three-valued column (`1` active / `0` explicit-off / `NULL`
  undeclared); `stale_by_days`/`stale_by_minutes` carry a staleness
  threshold; `available` is a three-valued probe-status column (`1`
  probed available, `0` probed unavailable — a queued handoff for the
  next agent/platform, `NULL` not probed). Written by `known queue`.

The derived `known_alphanumeric_id`/`agent_alphanumeric_id` are *not*
stored; they're recomputed per use (`knownIdFrom`/`agentIdFrom`) for
fixture naming and messaging, so a queue row stays a pure
dims+scope instruction. Idempotency on `actions` is enforced by the
`actions_dedupe` unique index (create-or-flip without a key string).

Rows with one or more missing dims are **seeds** — queue/agent
placeholders that say "capture something matching these dims". The
daemon expands seeds over the `knownFixturesForKnownAgents` recipes:
every recipe whose set dims match is queued as a full action, then the
seed is dropped. Seeds with no applicable recipe (unknown ids) are
**warned once per run and kept**, so a bad seed is visible in logs
without spinning. `known agent` never touches `actions`; it only writes
a `fixtures` row (partial detection exits 2 with no store change per
the "never guess" rule). `known dequeue` is a pure **DELETE** of
matching `actions` rows — it never mutates `fixtures`.

### user-only daemon (not the agent)

The user — not the agent — runs `known daemon`. The daemon's
agent-detection guard refuses to start if it's running inside an
agent (env-marker + ancestry check). If the agent's workflow stalls
because the daemon isn't running, the correct action is for the
agent to surface the command and the directory the user should run
it in. The agent never runs the daemon. The exact guard and what it
checks is documented on `runKnownDaemon` in `src/main.zig`.

## scope

- **Multi-harness, multi-OS, multi-arch.** Per-platform native
  binaries via `zig build dist`. Universal/fat formats rejected —
  see [README.md](./README.md) for the per-platform binary table.
- **Zero runtime dependencies.** The released binary is one file,
  no shared libraries, no runtime.
- **Never guess.** When detection can't fully resolve harness +
  provider + model, the binary exits 2 with a single-line error
  and writes no fixture. A partial detection is bad data, not a
  placeholder. The test suite (`src/known_fixtures.test.zig`)
  enforces that every committed fixture has all 18 canonical fields
  non-null, so a "backfill to make tests pass" approach can't slip
  in.