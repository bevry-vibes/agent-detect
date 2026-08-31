# contributing

How to maintain `agent-detect` as an agent or human. Read this when
you need to *do* something — refresh a fixture, add a harness rule, add
a model or provider rule, cut a release. For the *why* behind the
design, see [DESIGN.md](./DESIGN.md).

## refresh a fixture

A fixture's state is split across per-channel files under
`fixtures/from-identity/` and `fixtures/from-capture/` — each a whole
self-contained `{ outputs, meta }` envelope (normative schema:
`fixtures/fixture.d.ts`). The **directory IS the channel**: the
filename stem is the `<harness>-<provider>-<model>-<platform>` fixture
id (e.g. `cline-clinepass-kimik3-darwin`), and `outputs` carries
`identify` (the 18-field canonical object) plus `"trailer co-author"`
and `"trailer assisted-by"` — for from-capture also `raw`. `meta`
carries the ledger (`updated_at`, and for captures `harness_version`)
and the invocation of record
(`prompt_invocation`/`version_invocation`). The binary is the only
thing that writes fixtures — agents never hand-author them — and a
from-capture file is written **only on a successful capture**: no
meta-only stubs exist. A stem present in both folders has both
channels; channel presence = file existence.

`fixtures/index.json` is the committed state store — it holds only the
**non-derivable** state (`queue` the filter-entry array, `invocations`
the authored launch argv, `backlog` the actionable gaps + the
`known_but_failed` failure memory), declared normatively in TypeScript
at `fixtures/index.d.ts` (the source of truth for structure — unset
optionals are omitted, never serialized as `null`), with the semantics
in DESIGN.md "the state split". **Invocations are the dev agent's
signal** — authoring one says "rules/argv are ready for this combo to
capture"; zig reads them only to handle pop and `--repair`. Queue
entries are **filter tuples** (dims, mode, the staleness criteria set,
`free`) — only the daemon expands them into concrete candidates, one
per poll.

The refresh flow uses three binaries/actions with strict role
separation:

- **`agent-detect-dev fixtures daemon`** — only the *user* runs this,
  never the agent (it refuses to start inside an agent; see
  DESIGN.md "user-only daemon"). It is **pure**: every poll it
  refreshes the backlog from a folder scan, scans the queue-entry
  array (from-identity entries first), purges entries whose expansion
  has no remaining candidates anywhere, expands the first entry with
  remaining host-platform work (stamping `started_at` on its first
  work), and evaluates ONE candidate (`from-identity`: declared
  generation, zero tokens; `from-capture`: probe the invocation's
  `version_invocation` then launch the real harness session via its
  `prompt_invocation`). It never writes fixture files outside pop
  processing and never inserts queue entries. Crash-resume derives
  from the fixture files — a capture that died with the daemon simply
  re-runs. Failed candidates damp for the daemon run (one attempt per
  candidate per run) and persist their redacted message in
  `known_but_failed` + `daemon.log`; pops never gate on failure.
- **`agent-detect-dev fixtures capture`** — runs *inside an agent*
  session; captures the current session into
  `fixtures/from-capture/<id>.json` (whole-file atomic write, written
  only on success; the invocation of record persists, the ledger
  stamps fresh) and clears the combo's `backlog.known_but_failed`
  entry. **Fixtures only** — a partial detection exits 8 with no file
  written (never writes `queue`).
- **`agent-detect-dev fixtures prompt`** — prints the capture prompt
  (what a harness session is asked to run). The daemon interpolates it
  into an invocation's `<prompt>` placeholder; a hand-run capture
  composes its launch around it:
  `pi --provider chutes --model X -p "$(agent-detect-dev fixtures prompt)"`.
- **`agent-detect-dev fixtures queue`** — **upsert only, no
  evaluation.** One queue entry per selected mode is stamped from the
  given dims and staleness flags; the daemon expands. `--repair` pops
  the backlog instead (see below).
- **`agent-detect-dev fixtures dequeue`** — **DELETE only.** Deletes
  the matching `queue` entries (by dims + the stamped staleness
  criteria); never touches fixture files.
- **`agent-detect-dev fixtures status`** — the derived snapshot:
  fixtured counts per folder, the backlog sets (it maintains them),
  feasible-unfixtured totals, stale/fresh breakdowns under the
  `--stale` composite. Run it whenever you need to discern what the
  fixture universe needs next.

The shared filters (at least one required for `queue`/`dequeue`):
`--harness=H`, `--provider=P`, `--model=M`, `--platform=PLAT` constrain
their dim to equality; `--fixture=<h>-<p>-<m>-<plat>` is an exact
4-part id; `--agent=<h>-<p>-<m>` sets h-p-m (platform may be added
with `--platform=`). Dim filters compose (AND) with the staleness
flags and `--free`/`--paid` below. (There are no `--no-*` flags — an
unset dim is expressed by simply omitting it.)

The **refresh modes** (`--from-identity` / `--from-capture`) select the
worker. No mode flag → **both** entries are queued per candidate (the
declared pass first, then the capture upgrade). Both flags together →
exit 3. `dequeue` filters by the stored mode the same way (no flag →
all modes).

The **staleness family** (shared by `queue`/`dequeue`) is **pure
enqueue** (or pure row filter for dequeue — a criteria-set comparison,
never a probe at queue time). An entry carries a **set** of criteria;
a candidate is stale iff ANY carried criterion says stale; absent
evidence ⇒ stale:
- `--stale-by-output` — the two channel files' `outputs.identify` are
  not both present and deep-equal (a missing channel counts stale).
- `--stale-by-days=N` / `--stale-by-hours=N` / `--stale-by-minutes=N` —
  mode-scoped age of `meta.updated_at` (the entry stores MINUTES).
- `--stale-by-harness-version` — the capture file's
  `meta.harness_version` differs from a live `version_invocation` probe
  (a harness upgrade re-captures without waiting for an age threshold).
- `--stale-by-invocation` — the capture file's recorded
  `meta.prompt_invocation` is missing or differs from the latest one in
  index.json's `invocations` table (an updated invocation re-captures).
- `--stale` — the composite: output OR days=27 OR
  harness-version OR detect-version OR invocation. **Defaulted on**: a
  queue upsert
  with no staleness flags carries the full composite. An explicit
  `--stale-*` forms the criteria set alone; `--stale` plus an explicit
  `--stale-*` overwrites just that composite component (`--stale
  --stale-by-days=0`, `--stale --stale-by-days=999999999`).
- `--refresh` — carry NO criteria: every candidate is worked regardless
  of freshness. Conflicts with `--stale` and every `--stale-*` (exit 3).
- `--free` / `--paid` — membership in the free-models grid
  `fixtures/map-provider-model-freeprovidermodel.csv` (the source of truth for free
  models; the zig store code reads this grid at expansion time, along
  with the feasibility grids `map-harness-provider-harnessprovider.csv` and
  `map-provider-model-providermodel.csv`).

Dequeue defaulting mirrors queue: a bare dims-only dequeue matches
exactly the entry a bare upsert created (the composite); `--refresh`
matches criteria-less entries.

**`--repair`** (on `fixtures queue`) pops the backlog and re-queues the
now-actionable items against the current rule tables and grids: an
`unknown_invocations` id that now has an invocation of record (a store
table entry or the file's own `meta.prompt_invocation`) → removed + a
targeted `--fixture=<id>`
from-capture entry; an unknown harness/provider/model slug that a new
rule made resolvable → removed + a from-identity entry filtered on
that dim; the unfixtured (feasible grid combos with no fixture) → one
from-identity entry over the feasible universe, honoring dims filters.
Items still unresolvable or still invocation-less stay in the backlog;
run `fixtures status` to see what remains and why.

To refresh one fixture end-to-end:

1. The user starts the daemon in a separate terminal:
   ```sh
   ./zig-out/bin/agent-detect-dev fixtures daemon
   ```
2. Queue the work (from the user's terminal or an agent session —
   enqueue is pure):
   ```sh
   ./zig-out/bin/agent-detect-dev fixtures queue \
     --harness=<harness_id> \
     --provider=<provider_id> \
     --model=<model_id> \
     --platform=darwin
   ```
   With no staleness flag this carries the full `--stale` composite;
   re-assert the SAME flags when refreshing (the criteria set is part
   of the dedupe identity).
3. The daemon expands the queue entry and evaluates candidates one per
   poll: the `from-identity` pass writes the declared
   `from-identity/<id>.json` (zero tokens), and the `from-capture`
   pass launches the harness headlessly via the file's
   `prompt_invocation` so it runs `fixtures capture` inside a live
   model session (token-consuming — announce with the pre-capture
   review window and confirm with the user first).

For batch refreshes: `fixtures queue --stale-by-days=0` re-queues
everything past its declared date (date staleness covers binary
drift); `fixtures queue --refresh` re-evaluates a whole filter
unconditionally.
A bare dims-only queue command (`fixtures queue --harness=cline
--from-identity`) sweeps every fixtured-or-feasible combo matching
those dims under the composite criteria. Failed candidates are damped
for the daemon run and remembered in `backlog.known_but_failed` — pops never
gate on failure, so a re-assert of the entry (or `--repair`) retries
them; fix the cause first and the next success clears the entry.

### common expected failures when refreshing

Queue jobs run in two modes with different failure surfaces. The
`from-identity` worker resolves declared identification from provided
ids — a failure there is a **rule-table bug** (unknown dims, malformed
combo), surfaced as `daemon: from-identity failed for <combo>` with the
failure remembered in `backlog.known_but_failed` + `daemon.log`. Fix
the rules and re-queue.

Account-level failures — **credits depleted** (insufficient balance /
credits error in the worker stderr), **rate limit encountered**
(`429` / "too many requests" — back off, do not retry in a tight loop),
**upgraded plan required** (`401`/`403`, "upgrade your plan") — are
only reachable on `from-capture` jobs (the real harness session talks
to the provider). Treat those as **environment-level failures**, not
detection bugs: resolve the account condition, then re-assert the
queue entry (or `fixtures queue --refresh` for a forced pass). A
`from-capture` failure (timeout / nonzero exit / post-check fail /
detection-partial exit 8) records a redacted message in
`backlog.known_but_failed` and damps the candidate for that daemon
run — no spin. An uninstalled harness (no `version_invocation` or the probe
exits nonzero) records "harness unavailable". A `from-capture` job
launches a real model session and consumes tokens (free-tier quota or
subscription) — confirm with the user first; a hand-run
`fixtures capture` consumes that session's tokens.

### cross-device runbook

The store and the fixture files sync across hosts via git. Only the
matching platform's daemon expands a candidate (`platform = the
entry's or the host's`), so a `platform='darwin'` entry is never
worked on Windows — the entry simply stays queued there until a darwin
daemon finishes it:

1. On host A (e.g. macOS): run the daemon, let the platform's work
   drain, then commit index.json + fixture files (single-writer
   workflow — pull before daemon, commit after).
2. On host B (e.g. Windows): `git pull`, `zig build dev`, run the
   daemon — it works only the host-platform candidates that remain.
3. Failed candidates retry on the host that can reach the harness
   (re-assert the entry or use `--repair`).

### committed-store hygiene

`fixtures/index.json` is **committed** with each landing (it is the
cross-host work queue + failure memory). Never commit
`index.json.lock` / `index.json.tmp` or the daemon files
(`daemon.log`, `daemon.ctl`) — they are gitignored. The store is quiet
by design — the per-channel fixture files carry the fixture state, so
the store only changes when the queue/backlog/failure tables change.
The dev agent reads `backlog.known_but_failed` + `daemon.log` +
`fixtures status` to review regeneration completeness; purging fixture
files is user discretion.

## minimal invocation (authored invocations)

Authored `prompt_invocation` entries carry only the arguments
**necessary** to pin harness + provider + model and run the capture
prompt. Extra flags that merely alter runtime behaviour (e.g. cline's
`--thinking <level>`) are **dropped unless documented as necessary**
by the harness for the invocation to work headlessly. Permission /
approval flags (`--auto-approve`, `--auto`, `--allow-all`,
`--permission-mode bypassPermissions`, `--non-interactive`) are
necessary — a headless session cannot answer interactive prompts.
Prompt-passing flags (`-p`, `--prompt`, `--message`, `run`/`text`
subcommands) are the invocation's spine. When you author an
invocation, audit it against this policy; `fixtures status` +
`git diff fixtures/` keeps the drift visible.

## test matrix: harnesses, providers, models

The committed fixtures double as the integration test of the detection
ladder. The matrix **policy** — harness scope, model/provider policy,
the paid default, the global-settings rule, evidence attribution —
lives in DESIGN.md "test matrix"; the install table below is the
what-to-do side. The matrix itself is the union of the two channel folders' filename
stems (`fixtures/from-identity/` + `fixtures/from-capture/`) — one
fixture id per `agent_id`-per-platform, the capture files carrying the
invocation of record (`meta.prompt_invocation`/`meta.version_invocation`)
— expanded by the daemon from queue entries and captured per platform,
plus the authored `invocations` table.

### per-harness install table

Confirm every install with the user; prefer homebrew / npm / uv / scoop
over web scripts.

| harness   | macOS / Linux (homebrew)                          | cross-platform (npm / uv)                                      | Windows (install → binary location)                                                                           |
| --------- | ------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| cline     | —                                                 | `npm i -g cline`                                                 | `npm i -g cline` → `~\scoop\apps\nodejs\current\bin\cline{,.cmd,.ps1}`                                        |
| kimi-code | —                                                 | `npm i -g @moonshot-ai/kimi-code`                                | `npm i -g @moonshot-ai/kimi-code` → `~\.kimi-code\bin\kimi.exe`                                               |
| mmx       | —                                                 | `npm i -g mmx-cli`                                               | `npm i -g mmx-cli` → `~\scoop\apps\nodejs\current\bin\mmx{,.cmd,.ps1}`                                        |
| pi        | —                                                 | `npm i -g @earendil-works/pi-coding-agent`                       | `scoop install pi-coding-agent` → `~\scoop\shims\pi.exe`                                                      |
| qwen      | `brew install qwen-code`                          | `npm i -g @qwen-code/qwen-code`                                  | `npm i -g @qwen-code/qwen-code` → `~\scoop\apps\nodejs\current\bin\qwen{,.cmd,.ps1}`                          |
| kilo      | `brew install Kilo-Org/tap/kilo`                  | `npm i -g @kilocode/cli`                                         | `npm i -g @kilocode/cli` → `~\scoop\apps\nodejs\current\bin\kilo{,.cmd,.ps1}`                                 |
| omp       | `brew install can1357/tap/omp`                    | `bun i -g @oh-my-pi/pi-coding-agent`                             | `scoop install oh-my-pi` → `~\scoop\shims\omp.exe`                                                            |
| reasonix  | `brew install esengine/reasonix/reasonix`         | `npm i -g reasonix`                                              | `scoop install reasonix` → `~\scoop\shims\reasonix.exe`                                                       |
| crush     | `brew install charmbracelet/tap/crush`            | `npm i -g @charmland/crush`                                      | `winget install charmbracelet.crush` → winget package dir (alias on PATH)                                     |
| opencode  | `brew install anomalyco/tap/opencode`             | `npm i -g opencode-ai`                                           | `scoop install opencode` → `~\scoop\shims\opencode.exe`                                                       |
| vibe      | —                                                 | `uv tool install mistral-vibe`                                   | `uv tool install mistral-vibe` → `~\scoop\persist\uv\tools\shims\vibe.exe`                                    |
| cursor    | `brew install cursor-cli`                         | — (binaries: `cursor-agent`)                                    | `irm 'https://cursor.com/install?win32=true' \| iex` → `%LOCALAPPDATA%\cursor-agent\cursor-agent{,.cmd,.ps1}` |
| copilot   | `brew install copilot-cli`                        | — (binaries: `copilot`)                                         | `scoop install copilot-cli` → `~\scoop\shims\copilot.exe`                                                     |
| goose     | —                                                  | — (contributor-scope example)                               | `scoop install goose-cli` → `~\scoop\shims\goose.exe` (contributor-scope example)                             |

### provider model discovery (three sources)

When adding a new provider, enumerate its models from three sources
and record the outcome in the reference grids (see "committed-store
hygiene"):

1. **Provider's own API** — OpenAI-compatible endpoints generally
   expose `GET {base_url}/models` unauthenticated, e.g.
   `curl -s https://llm.chutes.ai/v1/models | jq -r '.data[].id'`
   (14 TEE-stamped ids) or
   `curl -s https://opencode.ai/zen/go/v1/models | jq -r '.data[].id'`
   (33 ids).
2. **OpenRouter** — `GET /api/v1/models` (`hugging_face_id` +
   `supported_parameters`), and for per-provider availability
   `GET /api/v1/models/<id>/endpoints`, which lists the serving
   providers of a model (e.g. `qwen/qwen3.8-27b` → Chutes, AkashML,
   Phala, …).
3. **Harness surface** — the harness's own provider/model commands
   and config: `kimi provider list [--json]`, the
   `[models."<provider>/<id>"]` sections of
   `~/.kimi-code/config.toml`, `kimi provider catalog` (models.dev
   registry import).

Keep only models suitable for coding — the evergreen set's
tool-calling constraint (`supported_parameters` contains `tools`) is
the documented filter.

### probing the grids before a daemon batch (dev agent runbook)

The grids define the feasible universe — everything the daemon will
declare and capture. Stale grids send the daemon at dead combos (or
miss new ones), so **refresh both grids before queueing a large
batch**. Both probes are zero-token local work:

1. **Providers per harness** → `map-harness-provider-harnessprovider.csv`
   (one row per harness; a non-`-` cell means the harness can reach
   that provider). For each harness rule's binary, enumerate its
   provider catalog with the harness's own discovery surface — e.g.
   `pi auth list` / `pi --list-providers`, `omp`'s per-provider
   `models.db`, `opencode`'s config, `kimi`/`cline`/`crush` config
   files, `goose config`, `qwen`/`copilot`/`cursor-agent` auth state.
   Record every provider the harness can actually reach on this host
   AND the providers documented by the harness itself (a provider the
   harness supports but this host has no account for is still
   feasible — the capture failure is the account signal, not a
   feasibility signal). Remove cells for providers the harness no
   longer supports (e.g. an extension was uninstalled).
2. **Models per harness-provider pair** →
   `map-provider-model-providermodel.csv` (cell = that provider's
   served model-id string, as the harness spells it). For each
   (harness, provider) pair from step 1, enumerate the model catalog —
   `pi --provider <p> --list-models`, the harness's models command, or
   its config/catalog files. The cell must be the exact string the
   invocation's `--model`/config expects (the capture post-check pins
   the combo, so a wrong spelling surfaces as a known_but_failed
   mismatch).
3. **Cross-check** the free axis (`map-provider-model-freeprovidermodel.csv`)
   against the refreshed model catalog (free ids still free; new free
   ids added), and the evergreen snapshots (see below).
4. **Commit the grids, then** queue the batch (`fixtures queue`) and
   start the daemon. `fixtures status` before and after: the
   feasible-unfixtured total is the batch size you are about to create.

Harness catalog commands drift between versions — verify each
harness's discovery surface against `--help` before trusting a
scripted probe, and prefer the harness's own output over web catalogs.

The maintainer probes the free combos + the MiniMax subscription:

```sh
zig build dev
./zig-out/bin/agent-detect-dev fixtures queue   # both modes, the whole default universe; pure enqueue, zero tokens
./zig-out/bin/agent-detect-dev fixtures daemon --write-log
```

The daemon scans entries in order `from-identity` → `from-capture`
(declared work first, capture upgrades after) and captures each
candidate to `fixtures/<id>-<platform>.json`. Review each fixture's
evidence claims as they land. Contributors add other combos (rules →
store rows → captures on their platform):

- `--from-identity` — declared-only population: the harness is not installed
  or won't run. Zero tokens; the fixture is declared, not observed.
- `--from-capture` — real re-captures only (token-consuming,
  user-confirmed).

A bulk/maintenance model addition (a sweep, expanding a harness across a
batch of providers, or a free-catalog import) adds a model only when it
clears the evergreen model set (top 100 weekly models from OpenRouter's models API, filtered to models that support tool calling: `supported_parameters` contains `tools`) — the policy is DESIGN.md decision
#13 and the tracked set is
`fixtures/evergreen-models.json`, regenerated from OpenRouter alone as
part of maintenance (no CI task; see DESIGN.md #13 for the dropped
alternative sources). This does not apply
retroactively to models already in the matrix, and it does not apply to
an individual addition a user explicitly needs. The gate is on
additions only — a supported model is dropped when the harness or
provider whose addition made it supported no longer offers it, never
merely because it fell out of the evergreen set (someone is using
agent-detect for the added dim). Observed-but-unadded ids (the
non-evergreen remainder of a provider catalog) are recorded in
`fixtures/map-provider-model-providermodel.csv`. Free-vs-paid only
decides whether a free launch/capture is attached — query the
harness's own model catalog first (e.g. omp's
`~/.omp/agent/models.db` per-provider `cost`: input==0 → free);
OpenRouter's `/api/v1/models` (explicit `:free` ids + `pricing`) and
artificialanalysis.ai (per-model price) are the cross-checks. Name
variations across services (`:free` vs `-free`, release stamps like
`-0731`, reasoning-effort suffixes) are coalesced into one canonical
model per family and recorded as variations on the recipe — never
added as duplicates (the CLI-side alias resolution is the "alias
conventions" section below).

As part of maintenance, regenerate the tracked evergreen snapshots
from OpenRouter (top 100 weekly tool-calling-capable models, and the
available providers) with authenticated calls:

```sh
curl -s -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  "https://openrouter.ai/api/v1/models?sort=top-weekly&limit=100" \
  | jq '[.data[] | select((.supported_parameters // []) | index("tools"))]' \
  > fixtures/evergreen-models.json

curl -s -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  "https://openrouter.ai/api/v1/providers" \
  | jq '.data' \
  > fixtures/evergreen-providers.json
```

(The authenticated calls above are canonical; an unauthenticated
request returns the same public ranking when no key is available.)

Three reference grids complement the snapshots, all read by the zig
program at expansion time. The two **feasibility grids** are
load-bearing: a pair is feasible iff its cell is present and not `-`,
and the feasible-unfixtured universe (grid cross-product minus the
fixtured stems) is what from-identity can declare — so keep them in
sync with the fixture universe (append the provider's row alongside
each catalog enumeration; `fixtures status` + the migration audit flag
drift): `fixtures/map-provider-model-providermodel.csv` (rows = provider alphanumeric
ids, columns = model alphanumeric ids, cell = that provider's served
model-id string or `-`) and `fixtures/map-harness-provider-harnessprovider.csv`
(rows = harness ids, columns = provider ids, cell = the harness's
provider-id string or `-`). The third is the free axis:
`fixtures/map-provider-model-freeprovidermodel.csv` — the SOURCE OF TRUTH for free
models (replacing the retired `free_provider_to_model` store table).
It is SPARSE: rows only for providers with ≥1 free model, columns
only for models that are free at some provider, cell = that
provider's free model-id string, `-` otherwise.

### monitoring + control runbook

Run the daemon with `fixtures daemon --write-log` (log:
`fixtures/daemon.log`) and poll that log at ~1s — the daemon writes a
status heartbeat every ~1s, faster than the iteration delays.
Pacing: `from-identity` jobs process at ~5s intervals
(`--poll-seconds=N`); each `from-capture` is announced ~15s ahead
(`--capture-review-seconds=N`, cancellable) and followed by a ~15s
review pause. Control is the same on macOS/Linux/Windows:

```sh
printf 'pause\n'  > fixtures/daemon.ctl   # pause: finish in-flight, then no new pops
printf 'resume\n' > fixtures/daemon.ctl   # resume
printf 'stop\n'   > fixtures/daemon.ctl   # stop after the in-flight job
```

The daemon checks the file every ~1s and clears it after acting; Ctrl+C
in the daemon terminal is the graceful-stop shortcut.

### daemon launch: macOS LaunchAgent bootstrap (macOS-only, no sudo)

The daemon is user-only: it refuses to start when an ancestor process
matches a harness agent, so it must run as a plain user process with a
clean ancestry. A terminal run is the universal baseline; on macOS the
daemon can instead be registered per-user via `launchctl bootstrap`
(no sudo, survives the terminal closing, respawns on crash). Save this
plist and bootstrap it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.agent-detect.fixtures</string>
  <key>ProgramArguments</key>
  <array>
    <string>/abs/path/to/zig-out/bin/agent-detect-dev</string>
    <string>fixtures</string>
    <string>daemon</string>
    <string>--write-log</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/abs/path/to/harness/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>WorkingDirectory</key><string>/abs/path/to/repo</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
```

`EnvironmentVariables.PATH` is **required** for `from-capture` jobs:
launchd does not inherit your shell PATH, and the daemon spawns harness
binaries by bare name (e.g. `cline`), so without it every real capture
fails with `spawn failed: FileNotFound`. Include the directories holding
your harness binaries (homebrew `/opt/homebrew/bin`, npm/uv shims, etc.).

```sh
launchctl bootstrap "gui/$(id -u)" /path/to/agent-detect.fixtures.plist   # start
launchctl bootout  "gui/$(id -u)"/com.agent-detect.fixtures               # stop + unload
launchctl list | rg com.agent-detect.fixtures                             # status
```

Headless `ssh` sessions can't `bootstrap` (not attached to the GUI
session — use `tmux`/`screen` there). The sudo-free equivalents are
`systemd --user` on Linux and Task Scheduler / NSSM on Windows.

### global-settings rule

Never change a global harness/provider/model setting to make a fixture
pass — use env/arg/scope flags only (policy + rationale: DESIGN.md
"test matrix", global-settings rule).

## recipe-mode identify / trailer (hard-to-detect agents)

`identify`, `trailer co-author`, `trailer assisted-by`, and
`check-reciprocal` accept a complete combo to emit a report
without live detection:

```sh
./zig-out/bin/agent-detect identify --harness=cline --provider=clinepass --model=kimik3
./zig-out/bin/agent-detect trailer co-author --harness=cline --provider=clinepass --model=kimik3
```

All three of `--harness=`, `--provider=`, `--model=` are required (or
none — then live detection runs). A partial combo exits 4; an id not
in the rule tables exits 7. Ids may be given in canonical, strict-slug,
label, or case-variation form (`cline-pass`, `clinepass`, `Cline Pass`,
or `CLINE_PASS` all work) — resolution follows the "alias conventions"
section below. This is how a harness whose
provider/model can't be auto-detected still gets a report and
trailer.

## add a new harness rule

Add a `HarnessRule` entry to the `rulesForHarnesses` array in
`src/lib/rules.zig`. Required fields:

| field             | how to fill                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------- |
| `name`            | strictly lowercase alphanumeric — what the harness calls itself canonically (e.g. `kimi-code`)              |
| `label`           | the human-readable brand form (e.g. `Kimi Code`); used to derive `harness_id`                              |
| `license`         | SPDX keyword per the table below                                                                           |
| `license_sources` | two URLs: the project page + the LICENSE file linked from it. `null`/`NOASSERTION` license keeps this empty |
| `env_markers`     | env-var names unique to this harness (one or more). Run the harness' `--help` and inspect its config to discover |
| `binary_names`    | the executable names for ancestry matching, probing, launching, and the daemon guard — written inline as a platform ternary: bare stems first, then platform extensions (`.cmd`/`.ps1` only for npm-shimmed harnesses; `.exe`-only otherwise) |
| `variations`      | optional extra alias display-strings not covered by `name`/`label`/`short_title` (e.g. `"Kilo Code CLI"`). Keep minimal — see the alias conventions below |

`license` semantics (per SPDX spec) — the reciprocity consequences of
each value (exit 9/10) are DESIGN.md's exit-status registry:

| value            | meaning                                                    |
| ---------------- | ---------------------------------------------------------- |
| `null`           | no data available                                          |
| `"NOASSERTION"`  | attempted, inconclusive                                    |
| `"NONE"`         | concluded: no license present (verified proprietary/closed) |
| SPDX id (`MIT`, `Apache-2.0`, …) | open license                                |

Example: `cursor` and `copilot` are closed-source harnesses verified as
no-license, so their rules carry `license = "NONE"` with their
project/terms URLs as `license_sources`.

After adding the rule:

1. Build the dev binary: `zig build dev`.
2. Declare the rule's combos — the feasible-unfixtured universe (the
   grid-filtered cross-product minus the fixtured stems) expands
   automatically once the harness/provider/model pairs are feasible per
   the reference grids (`map-harness-provider-harnessprovider.csv` /
   `map-provider-model-providermodel.csv` — add the cells if the pairs are new):
   ```sh
   ./zig-out/bin/agent-detect-dev fixtures queue --harness=<harness_id> --from-identity
   ./zig-out/bin/agent-detect-dev fixtures daemon
   ```
   (Any dim the new rule makes resolvable that was sitting in the
   backlog's unknown_* sets clears via `fixtures queue --repair`.)
3. Author the invocations for the combos that should capture: add an
   entry to the `invocations` table in `fixtures/index.json` keyed by
   the fixture id, with `prompt_invocation` (the launch argv that runs
   `fixtures capture` inside a live session — argv[0] is the concrete
   per-platform binary, the last element is the capture prompt
   placeholder `<prompt>`) and `version_invocation`
   (`[<binary>, "--version"]`), per the minimal-invocation policy
   above, then `fixtures queue --from-capture --harness=<harness_id>`
   and run the daemon again (token-consuming, user-confirmed). A
   successful capture records the invocation into the fixture file's
   own meta.
4. Commit the new rules, the grids, the declared fixtures, the
   invocations, and the store.

If the harness is closed-source and you can't verify the SPDX license,
leave `license: null` and `license_sources: &.{}` — a maintainer fills
them in once verified. If the harness' provider/model can't be
auto-detected at all, the rule alone is enough for recipe-mode
`identify`/`trailer` (see above) — you don't need a live capture.

### harness quality filters

Bulk/maintenance harness additions must clear the tracked evergreen
harness set — `fixtures/evergreen-harnesses.txt`, the top 50
programming/code agents curated from the two agent directories
referenced in that file's header (deepseek-ai/awesome-deepseek-agent
and vercel-labs/skills). The quality filters the dev agent applies
when regenerating it:

- **code-focused** — the agent is a programming/coding agent (terminal,
  editor, or IDE-embedded); general chat assistants, desktop clients,
  and skill-only runners are excluded.
- **active/maintained** — the project has recent commits and releases,
  an open issue tracker, and an actively-maintained integration guide
  (DeepSeek guide + agent-skills support are the two directory signals
  used as a proxy).
- **high-quality** — credible ecosystem footprint: multi-model support,
  agent-skills (SKILL.md) support, and editor+CLI reach.
- **canonical id** — the entry's id is the harness rule's `name` in
  `rulesForHarnesses` once the rule exists; otherwise the id appears as
  a "pending harnesses" bullet until a contributor adds the rule.

This guard is for bulk/maintenance work only — a rule for an individual
agent a user explicitly needs is always allowed, and an agent that
stalls (unmaintained, archived) is dropped on regeneration.

## add a new model or provider rule

Model and provider rules live alongside the harness rules in
`src/lib/rules.zig` as `rulesForModels` and `rulesForProviders` arrays.
Their structs are `ModelRule` and `ProviderRule`.

**Model rule fields:**

| field        | how to fill                                                                                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `name`       | the bare model id (e.g. `kimi-k3`); stripped of any `provider/` prefix by `applyModel`                                          |
| `label`      | the canonical display label (e.g. `Kimi K3`)                                                                                    |
| `short_title`| optional shorter brand form (e.g. `M3` for `MiniMax M3`); `null` when there's no established short form                       |
| `reciprocity`| one of `open-source`, `open-weight`, or `closed`                                                                                |
| `license`    | SPDX id of the model weights (`Apache-2.0`, `MIT`), `NOASSERTION` when a custom non-SPDX license exists, `NONE` for a verified closed model with no license granted, or `null` when unverified — same semantics as the harness license table. Emitted as `model_license` in the canonical output |
| `sources`    | independent cross-references that informed the reciprocity decision — typically the HF model page + its LICENSE file           |
| `variations` | optional extra alias display-strings not covered by `name`/`label`/`short_title` (default `&.{}`)                              |

**Provider rule fields:**

| field               | how to fill                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------ |
| `name`              | the provider id used by harness configs (e.g. `cline-pass`, `anthropic`)                                     |
| `label`             | the human-readable provider name (e.g. `Cline Pass`, `Anthropic`)                                           |
| `short_title`       | optional short brand form (e.g. `M3`); `null` when there's no established short form (most providers omit it) |
| `closed_training`   | one of `enforced`, `opt-in`, `opt-out`, `never`, or `null` (unverified). Reflects whether the provider trains closed models on customer data |
| `open_training`     | same enum. Reflects whether the provider trains open-weight/open-source models on customer data                |
| `sources`           | two independent same-provider policy documents (typically privacy policy + terms of service) that informed both training values |
| `variations`        | optional extra alias display-strings not covered by `name`/`label`/`short_title` (default `&.{}`)            |

Reciprocity and training values are *derived from public docs*, not
guessed. If you can't verify a value, leave it `null` — a maintainer
fills it in once verified.

**Opt-in-by-model (hard rule).** A provider whose catalog includes
models that train on user data — reachable only by *choosing* those
models (contributor tiers, free-period tiers, and the like) — must
NOT record `never` on the axis those models span: closed models that
train → `closed_training` becomes at least `opt-in`; open-weight /
open-source models that train → `open_training` becomes at least
`opt-in`. Values already at `opt-out` or `enforced` capture training
and need no change. `never` is reserved for providers where **no**
served model trains. When cataloging a new provider, audit its
`map-provider-model-providermodel.csv` row for tier spellings (`:free`, `-free`,
`-contributor`, free-period exceptions named in its policy docs)
before writing any `never` — this is exactly the slip that made
OpenRouter's contributor tiers and OpenCode's free-period models
first land as `never`.

### model rule identity & family folding

Rule identity is model version × param size × license, with naming by
**official claim** and distinction by **discernment need**:

- Name a model as the service officially names it. A distinction
  (param size, `-pro`, template suffix) belongs in the id only where
  it's needed to discern the model from a competing claim on the
  non-distinct name. A version known officially as `blah-version`
  keeps the plain id even where the line has other sizes (`qwen3.5` —
  `Qwen/Qwen3.5` holds the bare name as an official claim); a version
  released in multiple param sizes with no official (or competing)
  claim on the non-distinct name gets one size-bearing rule per size
  (`qwen3.8-27b`, `qwen3.8-2.4t-a95b` — both official spellings; bare
  "Qwen3.8" is contested collection-level); a single-size release has
  no contest, so its id omits the size (`nemotron-3-nano-omni`,
  `minimax-m3`).
- Provider serving spellings — secure-environment stamps (Chutes'
  `-TEE` suffix), endpoint/tier variants (`-vision-exp`,
  `-contributor`), release stamps (`-0731`, `-2507`), quantizations,
  and `provider/model` namespaces — fold into the size's rule as
  `variations`, and only for ids actually observed (never
  speculative).
- Never fold spellings that differ in `model_license` or param size;
  `model_license` is emitted in the canonical output precisely so
  the license dimension stays visible in every report.
- Closed derivatives keep their own rules (`qwen3.8-max` is the
  closed version based on the open `Qwen3.8-2.4T-A95B` — its own
  rule, `license NONE`).
- **Phantom-provider guard:** provider rules mirror provider SURFACES
  the user configures (`minimax-code`, `deepseek-flash`, `kimi-code`,
  `cline-pass` — a harness's own named entry, each with its own
  policy surface). Never mint a provider rule whose name is a model
  id: crush's hyper.json key `qwen3.7-plus/…` is hyper's internal
  routing alias, and the real identity is `crush-hyper-qwen37plus`
  (detector + rule comments carry the fold; the phantom
  `qwen3.7-plus` provider rule was removed 2026-08-29). When a
  harness's config nests models under a router, the router is the
  provider.
- Grandfathered splits retired 2026-08-29: `deepseek-v4-flash-free`
  and `zai-glm-4.7` folded into their parents as tier/prefix
  spellings (option B of
  `.plans/1787978000867-retroactive-folding-options.md`); no
  same-model split remains, and the non-retroactivity clause covers
  everything else.
- Hugging Face collections bound families: `qwen38` and
  `qwen38-flash-next` are distinct families despite the shared name
  prefix. See a family via the collection page,
  `GET https://huggingface.co/api/collections/<owner>/<slug>` (the
  `.items` array), a card's "Model tree" link, or
  `GET /api/models?author=<org>&search=<name>`.

### alias conventions (harness / provider / model rules)

Every rule's CLI alias set is `name` + `label` + `short_title` (if
present) + `variations`, all normalized to a strict slug: lowercase +
strip non-alphanumeric, **whole-string** (no word stripping — removing
suffixes like `-code`/`cli`/`pass` would wrongly conflate `kimi-code`↔
`kimi` and `cline-pass`↔`cline`). Resolution is **exact-name-first**
(`--harness=cline` always means the `cline` rule, never `cline-pass`),
then first-rule-in-array-order over the normalized alias set. Add
`variations` only where a real-world alias is nowhere in
`name`/`label`/`short_title` (e.g. `kilo`'s full product name
`Kilo Code CLI`); label/short_title matching covers the common forms.
A slug that would match two rules in the same table fails the
alias-uniqueness test — keep every rule's alias set globally distinct
within its table (same-name labels across *different* tables are fine).
Provider-served id forms carrying a serving-environment suffix (e.g.
Chutes' TEE-stamped `Kimi-K3-TEE` / `moonshotai/Kimi-K3-TEE`) are
recorded as `variations` on the base model rule when observed —
never trimmed programmatically, never added speculatively.

## cut a release

Versions follow the calver format `<year>.<month>.<day>-<revision>`
(e.g. `2026.8.6-1`). The date is always UTC so devs in different
timezones produce the same string. The revision resets to `1` each
day and increments per release within the same day. The tag name
equals the version string exactly (no `v` prefix), so
`git tag 2026.8.6-1` produces a tag that matches the
`tags: ['*.*.*-*']` filter in `.github/workflows/build.yml`.

Maintainer runbook:

```sh
# 1. Compute today's UTC date and the next revision for that day.
today=$(date -u +%Y.%-m.%-d)        # GNU & macOS alike with %-
rev=$(git tag --list "${today}-*" | wc -l | tr -d ' ')
new_version="${today}-$((rev + 1))"

# 2. Bump `build.zig.zon` `.version` to the new string, commit on main
#    with the generated co-author trailer (see AGENTS.md).
sed -i.bak "s/\.version = \".*\"/.version = \"${new_version}\"/" build.zig.zon && rm build.zig.zon.bak
git add build.zig.zon
git commit -m "release: ${new_version}" --trailer "$(./zig-out/bin/agent-detect trailer co-author)"

# 3. Tag with the same string (no v prefix) and push — the `release`
#    job in build.yml picks it up, cross-compiles, and marks the
#    release as `latest: true`.
git tag "${new_version}"
git push origin main "${new_version}"
```

After the runbook, verify locally that the freshly built binary prints
the expected version:

```sh
zig build && ./zig-out/bin/agent-detect --version
# → agent-detect <new_version>
```

### release channels

| channel   | URL                                             | updated on                   | marked as      |
| --------- | ----------------------------------------------- | ---------------------------- | -------------- |
| `latest`  | `releases/latest/download/<asset>`              | push of a calver-shaped tag  | `latest:true`  |
| `nightly` | `releases/tag/nightly/download/<asset>`         | every push to `main`         | `prerelease`   |

`latest` is reserved for tagged releases — pushes to `main` only ever
touch the `nightly` channel, which is marked `prerelease: true` and
`latest: false` so it cannot accidentally become the stable channel.

## pending harnesses

The list of harnesses we want this binary to support. Append a
markdown task-list bullet here when a new harness is wanted. The
binary itself won't act on it (the `harness_name` must be in
`rulesForHarnesses` for the daemon to recognize), but the bullet is the
maintainer's next-session list. When a pending harness gets its rule
added, queue its from-identity pass
(`fixtures queue --harness=<harness_id> --from-identity` — see
"adding a rule" below) and author invocations
(`prompt_invocation`/`version_invocation`) for the combos that should
capture.

The maintainer (Benjamin Lupton) added `cursor` + `copilot` (2026-08-11)
and scoped the rest below as follow-ups for other contributors to pick
up — he won't use them, so their rules land only when someone else
maintains them.

- [ ] **claude** — Claude Code CLI (`claude -p <prompt>` headless;
  env `ANTHROPIC_MODEL`/`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` +
  `CLAUDE_CODE_*`; config `~/.claude/settings.json` + `~/.claude.json`;
  sessions `~/.claude/projects/`; proc `claude`). Native binary broken
  on the maintainer's machine (npm postinstall) — rules/from-identity land
  regardless of install.
- [ ] **codex** — OpenAI Codex CLI (`codex exec <prompt>`; config
  `~/.codex/config.toml` `model`/`model_provider`; sessions
  `~/.codex/sessions/`; proc `codex`).
- [ ] **grok** — Grok CLI (`grok --always-approve <prompt>`; config
  `~/.grok/config.toml` + models `~/.grok/models_cache.json`; sessions
  `~/.grok/sessions/` + `worktrees.db`; proc `grok`).
- [ ] **gemini** — Gemini CLI (`gemini -p <prompt>`; config
  `~/.gemini/settings.json`; proc `gemini`).
- [ ] **amp / roo / qoder / openhands** — maintained CLIs (Replit/Anvil,
  Roo Code, Alibaba, OpenHands); not installed on the maintainer's
  machine; rules + from-identity fixtures when a contributor picks them up.
- [ ] **devin / droid / zencoder / kimchi / firebender** — declared-only
  (from-identity) Tier-2 harnesses; config dirs `~/.config/devin/`,
  `~/.factory/`, `~/.zencoder/`, `~/.config/kimchi/harness/`,
  `~/.firebender/`; rules + recipes when a contributor picks them up.
- [ ] **continue / cody / windsurf** — other VS Code-embedded agents
  (need a different ladder step to detect extension-host children).
- [ ] **trae / junie / augment / codebuddy** — IDE-native agents (Trae,
  JetBrains Junie, Augment Code, Tencent CodeBuddy) from the evergreen
  harness set; rules + from-identity fixtures when a contributor picks
  them up.
- [ ] **aider-desk / antigravity / kiro / zed** — additional evergreen
  harness set entries (AiderDesk, Google Antigravity, Kiro CLI, Zed);
  rules + recipes when a contributor picks them up.

### catalog-inference verdicts (recorded so they aren't re-litigated)

Per-harness result of Part-1 catalog inference (2026-08-11): **pi**,
**opencode**, **kilo**, **crush**, **qwen**, **kimi** are inferable
(recipes added from their local catalogs / the models.dev catalog via
`kimi provider catalog list`); **reasonix** is partial (only the
configured `[[providers]]`, currently deepseek-flash); **goose**,
**mmx**, **vibe** are **not inferable** (no enumerable local model
catalog — goose is local-inference only, mmx is oauth-only, vibe
exposes only `active_model`).

Provider catalog verdicts (2026-08-29, kimi-code host): **chutes** is
inferable from all three sources (provider API unauthenticated = 14
TEE-stamped ids, agreeing with the kimi-code config surface and
OpenRouter's `…/endpoints` listing); the two non-evergreen ids
(`Qwen/Qwen3-32B-TEE`, `Qwen/Qwen3.6-27B-TEE`) are grid-recorded, not
ruled. **opencode-go** (OpenCode Zen's Go subscription,
`https://opencode.ai/zen/go/v1`) is inferable from its unauthenticated
`/v1/models` (33 ids); the evergreen subset got rules, the
non-evergreen remainder (`longcat-2.0`, `qwen3.7-max`,
`qwen3.6-plus`, `qwen3.5-plus`, `mimo-v2-pro`, `mimo-v2-omni`,
`hy3-preview`) is grid-recorded. The live-combo alias
`qwen3.8-flash` has its own rule with reciprocity/license `null`
pending a backing audit (no `Qwen/Qwen3.8-Flash` HF repo; the 3.8
flash open line is the separate `qwen38-flash-next` collection).
