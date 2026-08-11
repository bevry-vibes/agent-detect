# contributing

How to maintain `agent-detect` as an agent or human. Read this when
you need to *do* something — refresh a fixture, add a harness rule, add
a model or provider rule, cut a release. For the *why* behind the
design, see [DESIGN.md](./DESIGN.md).

## refresh a fixture

A fixture is a single `fixtures/<fixture_id>.json` file with three
top-level keys: `cooked` (the 18-field canonical object), `raw` (the
runtime observations), and `trailer` (the `Co-authored-by` string).
`fixture_id` encodes `<harness>-<provider>-<model>` and is suffixed
with `-<platform>` (e.g. `cline-clinepass-kimik3-darwin`). The binary
is the only thing that writes fixtures — agents never hand-author them.

`fixtures/index.sqlite3` is the state store (a single SQLite database
read and written via the system `sqlite3` CLI). It has two tables:
`fixtures` (one row per captured 4-tuple `(harness, provider, model,
platform)`, `platform` always the host) and `queue` (the work queue:
dims + scope columns + `available` probe status). Rows in `queue`
with missing dims are **seeds**: the daemon expands them over the known
recipes (`recipesForFixtures`), queuing each applicable full combo.
Rows the daemon cannot expand are warned once per run and left
unchanged.

**Tooling note:** the `fixtures` workflow requires the system `sqlite3`
CLI on PATH (every OS ships one); the *released* binary has zero
runtime dependencies — sqlite3 is only a maintainer-tooling
requirement.

The refresh flow uses two binaries with strict role separation:

- **`agent-detect-dev fixtures daemon`** — only the *user* runs this,
  never the agent. It pops one `queue` row per poll, expands seeds
  over known recipes first, lazily backfills the `fixtures` row from
  any valid committed `fixtures/<id>.json`, then spawns captures for
  full combos that still need them.
- **`agent-detect-dev fixtures capture`** — runs *inside an agent*
  session; captures the current session into a single
  `fixtures/<id>.json` and upserts a `fixtures` row. **Fixtures
  only** — a partial detection exits 8 with no store change (never
  writes `queue`).
- **`agent-detect-dev fixtures queue`** — **enumerate + upsert only,
  no evaluation.** With a scope flag it upserts each candidate into
  `queue`; without one it creates a seed row with the positive dims
  (`--harness=`, `--provider=`, `--model=`, `--platform=`, or the
  composite `--agent=`/`--fixture=`) and the rest `null`.
- **`agent-detect-dev fixtures dequeue`** — **DELETE only.** Deletes
  the matching `queue` rows; never touches `fixtures`.

The shared filters (at least one required for `queue`/`dequeue`):
`--harness=H`, `--provider=P`, `--model=M`, `--platform=PLAT` constrain
their dim to equality; `--fixture=<h>-<p>-<m>-<plat>` is an exact
4-part id; `--agent=<h>-<p>-<m>` sets h-p-m (platform may be added
with `--platform=`). Dim filters compose (AND) with the scope flags
below. (There are no `--no-*` flags — an unset dim is expressed by
simply omitting it.)

The scope flags (exactly one per call, shared by `queue`/`dequeue`)
select a candidate set instead of a dim filter:
- `--all` — every `fixtures` row on this platform.
- `--stale` — `fixtures` rows older than the threshold
  (`--stale-by-days=N`, `--stale-by-minutes=N`; `--stale` is an alias
  for `--stale-by-days=7`).
- `--partial` — `queue` rows with at least one missing dim (seeds).
- `--recipes` — every known recipe (`recipesForFixtures`,
  host platform).
- `--missing-fixture` — recipes whose `fixtures/<id>.json` is absent
  from disk.
`queue` upserts the candidates into `queue`; `dequeue` deletes them.
By default nothing is gated on harness availability; `--available` (a
modifier, combinable with any single scope flag) probes each
candidate's harness and records `1` (available) or `0` (unavailable)
into the `available` column. Unavailable rows are **kept queued** as
handoff work for the next agent/platform; `--unavailable` (dequeue
only, alias `--available=0`) matches those `available=0` rows.

To refresh one fixture end-to-end:

1. The user starts the daemon in a separate terminal:
   ```sh
   ./zig-out/bin/agent-detect-dev fixtures daemon
   ```
2. From inside an agent session for the harness to capture:
   ```sh
   ./zig-out/bin/agent-detect-dev fixtures queue \
     --harness=<harness_id> \
     --provider=<provider_id> \
     --model=<model_id> \
     --platform=darwin
   ```
3. The daemon pops the queue row, spawns `fixtures capture`, which
   writes the single `fixtures/<id>.json` and upserts the matching
   `fixtures` row. If a valid committed `fixtures/<id>.json` already
   exists, the daemon backfills the row from it instead of
   re-capturing.

For batch refreshes: `fixtures queue --all` re-queues every row in
`fixtures`, `fixtures queue --stale [--stale-by-days=N]
[--stale-by-minutes=N]` queues only rows older than the threshold,
`fixtures queue --recipes` re-queues every committed recipe, and
`fixtures queue --missing-fixture` queues recipes whose fixture files
are missing. Add `--available` to probe-and-record harness
availability instead of dropping unavailable harnesses.

`--all` means every known agent recorded in `fixtures/index.sqlite3`
(the `fixtures` table), filtered by the other filters
(`--harness=`, `--provider=`, `--model=`, `--platform=`).
`--all --available` means all of those, each probed and recorded with
its harness availability (`available` 1/0); unavailable rows stay
queued as handoff work for the next agent/platform.

### common expected failures when refreshing

Queue jobs run in three modes with different failure surfaces. The
`from-raw` worker (default) never invokes a model — a failed `from-raw`
capture is a **detection-code bug** (unresolved detection, missing
config read, contradictory evidence claim), surfaced as
`daemon: worker failed for <combo> (exit code N) — re-queued` with the
worker stderr, and the row stays queued. Fix the detection/rule and let
the daemon re-run.

Account-level failures — **credits depleted** (insufficient balance /
credits error in the worker stderr), **rate limit encountered**
(`429` / "too many requests" — back off, do not retry in a tight loop),
**upgraded plan required** (`401`/`403`, "upgrade your plan") — are
only reachable on `from-capture` jobs (a `from-raw` capture fabricates
the runtime and never talks to a provider). Treat those as
**environment-level failures**, not detection bugs: resolve the account
condition and re-queue, or skip the combo. A `from-capture` row
re-queues at most 3 times, then dequeues with a warning (token
protection).

## test matrix: harnesses, providers, models

The committed fixtures double as the integration test of the detection
ladder (see DESIGN.md "test matrix" for the policy). The matrix is the
`recipesForFixtures` table — one recipe per `agent_id` — expanded by
`fixtures queue --recipes` and captured by the daemon. Scope: the 11
coding harnesses (`cline`, `kimi`, `mmx`, `pi`, `qwen`, `kilo`,
`omp`, `reasonix`, `crush`, `opencode`, `vibe`) plus the
`goose` contributor-scope example.

### per-harness install table

Confirm every install with the user; prefer homebrew / npm / uv / scoop
over web scripts.

| harness   | macOS / Linux (homebrew)                          | cross-platform (npm / uv)                                      |
| --------- | ------------------------------------------------- | -------------------------------------------------------------- |
| cline     | —                                                 | `npm i -g cline`                                               |
| kimi-code | —                                                 | `npm i -g @moonshot-ai/kimi-code`                              |
| mmx       | —                                                 | `npm i -g mmx-cli`                                             |
| pi        | —                                                 | `npm i -g @earendil-works/pi-coding-agent`                     |
| qwen      | `brew install qwen-code`                          | `npm i -g @qwen-code/qwen-code`                                |
| kilo      | `brew install Kilo-Org/tap/kilo`                  | `npm i -g @kilocode/cli`                                       |
| omp       | `brew install can1357/tap/omp`                    | `bun i -g @oh-my-pi/pi-coding-agent`                           |
| reasonix  | `brew install esengine/reasonix/reasonix`         | `npm i -g reasonix`                                            |
| crush     | `brew install charmbracelet/tap/crush`            | `npm i -g @charmland/crush`                                    |
| opencode  | `brew install anomalyco/tap/opencode`             | `npm i -g opencode-ai`                                         |
| vibe      | —                                                 | `uv tool install mistral-vibe`                                 |

### probing scope + runbook

The maintainer probes the free combos + the MiniMax subscription:

```sh
zig build dev
./zig-out/bin/agent-detect-dev fixtures queue --recipes --available   # default from-raw, zero tokens
./zig-out/bin/agent-detect-dev fixtures daemon --write-log
```

The daemon pops rows in order `from-ids` → `from-raw` → `from-capture`
and captures each recipe to `fixtures/<id>-<platform>.json`. Review each
fixture's evidence claims as they land. Contributors add other combos
(rules → recipes → captures on their platform):

- `--from-ids` — declared-only population: the harness is not installed
  or won't run. Zero tokens; the fixture is declared, not observed.
- `--from-raw` (default) — fabricated runtime + live detection ladder.
  Zero tokens.
- `--from-capture` — real re-captures only (token-consuming,
  user-confirmed).

A bulk/maintenance model addition (a sweep, expanding a harness across a
batch of providers, or a free-catalog import) adds a model only when it
is in the evergreen top-50 rank set (see DESIGN.md "bulk model additions
are constrained to the evergreen top 50") — regardless of whether it is
paid or free, or which provider serves it. This does not apply
retroactively to models already in the matrix, and it does not apply to
an individual addition a user explicitly needs (a one-off
`--harness= --provider= --model=` combo added on request is always
allowed). Whether a model is free on a given provider only decides if a
free launch/capture is attached — free on one provider is not free on
another. Name variations across services (`:free` vs `-free`, release
stamps like `-0731`, reasoning-effort suffixes) are coalesced into one
canonical model per family and recorded as variations on the recipe —
never added as duplicates. Reference cache: `docs/evergreen-top50-models.txt`
(the tracked coalesced evergreen top-50 set that bulk additions must clear;
a harness's own model catalog intersects it per provider to decide free
launch/capture attachment).

### monitoring + control runbook

Run the daemon with `fixtures daemon --write-log` (log:
`fixtures/daemon.log`) and poll that log at ~1s — the daemon writes a
status heartbeat every ~1s, faster than the iteration delays.
Pacing: `from-ids`/`from-raw` jobs process at ~5s intervals
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

The daemon is user-only (`assertNotInAgent`): it refuses to start when
an ancestor process matches a harness agent (e.g. `kilo`), so it must
run as a plain user process with a clean ancestry and environment. A
terminal is the baseline way to do that on every platform.

On macOS the daemon can instead be registered with the per-user
LaunchAgent domain via `launchctl bootstrap`, which needs **no sudo and
no permission dialogs**: `gui/$(id -u)` is your own launchd adopting
your own agent, so no privilege escalation or TCC prompt is involved.
The job then survives the terminal closing, and launchd respawns it on
crash. The plist may live anywhere — `bootstrap` takes a path, not just
`~/Library/LaunchAgents`:

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
The daemon restarts pick it up on the next `bootstrap`.

```sh
launchctl bootstrap "gui/$(id -u)" /path/to/agent-detect.fixtures.plist   # start
launchctl bootout  "gui/$(id -u)"/com.agent-detect.fixtures               # stop + unload
launchctl list | rg com.agent-detect.fixtures                             # status
```

Because launchd parents the job directly, the daemon's environment and
`process_lineage` are clean — the same user context the guard requires,
so a fixture captured this way is indistinguishable from one captured
from a terminal. Only the `system/` domain (root `LaunchDaemon`s) needs
sudo; per-user `gui/` jobs never do.

Limitations: the caller must already be inside the user's GUI session
(a terminal or app) — headless `ssh` sessions are not attached to it,
so `bootstrap` fails there; use `tmux`/`screen` instead. This is
macOS-only; the sudo-free equivalents elsewhere are `systemd --user`
(`systemctl --user enable --now <unit>`) on Linux and Task Scheduler /
NSSM on Windows. The plain terminal run stays the universal baseline.

### refresh / token warning

Queue jobs run in three modes. `from-ids` resolves cooked from provided
ids — zero tokens, no harness, declared-not-observed fixtures.
`from-raw` (default) fabricates env markers + config files and runs the
detection ladder via `refresh run` — zero tokens, no harness session.
`from-capture` launches the real harness headlessly so it runs
`fixtures capture` inside a live model session — that session consumes
tokens (free-tier quota or subscription) and must be confirmed with the
user first. A `fixtures capture` run by hand inside an agent session
consumes that session's tokens.

### global-settings rule

Never change a global harness/provider/model setting to make a fixture
pass — use env/arg/scope flags only. `from-raw` captures write config
under a sandboxed HOME (per-fixture cache dir), never the user's real
harness config; flag any needed global change instead.

## recipe-mode cooked / trailer (hard-to-detect agents)

`cooked`, `trailer co-author`, `trailer assisted-by`, and
`is-reciprocal` accept a complete combo to emit a report
without live detection:

```sh
./zig-out/bin/agent-detect cooked --harness=cline --provider=clinepass --model=kimik3
./zig-out/bin/agent-detect trailer co-author --harness=cline --provider=clinepass --model=kimik3
```

All three of `--harness=`, `--provider=`, `--model=` are required (or
none — then live detection runs). A partial combo exits 4; an id not
in the rule tables exits 7. Ids may be given in canonical or strict-slug form
(`cline-pass` or `clinepass`). This is how a harness whose
provider/model can't be auto-detected still gets a cooked report and
trailer.

## add a new harness rule

Add a `HarnessRule` entry to the `rulesForHarnesses` array in
`src/main.zig`. Required fields:

| field             | how to fill                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------- |
| `name`            | strictly lowercase alphanumeric — what the harness calls itself canonically (e.g. `kimi-code`)              |
| `label`           | the human-readable brand form (e.g. `Kimi Code`); used to derive `harness_id`                              |
| `license`         | SPDX id (e.g. `Apache-2.0`, `MIT`), or `null` for closed-source harnesses                                  |
| `license_sources` | two URLs: the project page + the LICENSE file linked from it. `null` license keeps this empty              |
| `env_markers`     | env-var names unique to this harness (one or more). Run the harness' `--help` and inspect its config to discover |
| `proc_names`      | lowercase exe names matched against the process ancestry. Many node-based harnesses use generic exes — leave empty |

After adding the rule:

1. Build the dev binary: `zig build dev`.
2. Capture the first fixture following the "refresh a fixture" flow.
3. Commit the new fixture alongside the rule.

If the harness is closed-source and you can't verify the SPDX license,
leave `license: null` and `license_sources: &.{}` — a maintainer fills
them in once verified. If the harness' provider/model can't be
auto-detected at all, the rule alone is enough for recipe-mode
`cooked`/`trailer` (see above) — you don't need a live capture.

## add a new model or provider rule

Model and provider rules live alongside the harness rules in
`src/main.zig` as `rulesForModels` and `rulesForProviders` arrays.
Their structs are `ModelRule` and `ProviderRule`.

**Model rule fields:**

| field        | how to fill                                                                                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `name`       | the bare model id (e.g. `kimi-k3`); stripped of any `provider/` prefix by `applyModel`                                          |
| `label`      | the canonical display label (e.g. `Kimi K3`)                                                                                    |
| `short_title`| optional shorter brand form (e.g. `M3` for `MiniMax M3`); `null` when there's no established short form                       |
| `reciprocity`| one of `open-source`, `open-weight`, or `closed`                                                                                |
| `sources`    | independent cross-references that informed the reciprocity decision — typically the HF model page + its LICENSE file           |

**Provider rule fields:**

| field               | how to fill                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------ |
| `name`              | the provider id used by harness configs (e.g. `cline-pass`, `anthropic`)                                     |
| `label`             | the human-readable provider name (e.g. `Cline Pass`, `Anthropic`)                                           |
| `closed_training`   | one of `enforced`, `opt-in`, `opt-out`, `never`, or `null` (unverified). Reflects whether the provider trains closed models on customer data |
| `open_training`     | same enum. Reflects whether the provider trains open-weight/open-source models on customer data                |
| `sources`           | two independent same-provider policy documents (typically privacy policy + terms of service) that informed both training values |

Reciprocity and training values are *derived from public docs*, not
guessed. If you can't verify a value, leave it `null` — a maintainer
fills it in once verified.

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

# 2. Bump `build.zig.zon` `.version` to the new string, commit on main.
sed -i.bak "s/\.version = \".*\"/.version = \"${new_version}\"/" build.zig.zon && rm build.zig.zon.bak
git add build.zig.zon
git commit -m "release: ${new_version}"

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
added, remember the daemon's recipe table (`recipesForFixtures`) must
contain the harness before seed expansion will queue captures for it.

- [ ] **claude** — VS Code-embedded Claude Code agent.
- [ ] **continue / cody / windsurf** — other VS Code-embedded agents
  (need a different ladder step to detect extension-host children).
- [ ] **grok** — Grok Build / Grok CLI.
