# contributing

How to maintain `agent-detect` as an agent or human. Read this when
you need to *do* something — refresh a fixture, add a harness rule, add
a model or provider rule, cut a release. For the *why* behind the
design, see [DESIGN.md](./DESIGN.md).

## refresh a fixture

A fixture is a single `fixtures/<fixture_id>.json` file whose top-level
keys are per-channel **channel objects**: `from-identity` (required —
the declared identification), `from-capture` (the live session's
identification), and `from-capture-raw` (the live session's raw
observations). Each `from-*` channel object carries `identify` (the
17-field canonical object) plus `"trailer co-author"` and
`"trailer assisted-by"` (the two trailer variants, spawned from the
real CLI — the old root `trailer`/`cooked`/`origin` keys are gone).
`fixture_id` encodes `<harness>-<provider>-<model>` and is suffixed
with `-<platform>` (e.g. `cline-clinepass-kimik3-darwin`). The binary
is the only thing that writes fixtures — agents never hand-author them.

`fixtures/index.sqlite3` is the state store (a single SQLite database
read and written via the system `sqlite3` CLI). It has **four** tables:
`fixtures` (one row per captured 4-tuple `(harness, provider, model,
platform)`, carrying `available`/`successful` outcome markers, the
capturing `agent_detect_version`, the per-channel generation columns
`identity_generation_at/hash` + `capture_generation_at/hash`, and the
derived `agent_id`/`fixture_id`), `queue` (the work queue: dims + scope
markers + `mode`), `pending` (one row per work item under a popped
queue row — `started_at`/`finished_at` make crash-resume safe), and
`invalid` (bad-id rows — unknown fixture files, no-launch from-capture
candidates — for dev-agent remedy; purging files is user discretion).
Queue rows with missing dims are **seeds**: the daemon expands them over
the known recipes (`recipesForFixtures`) into `pending` rows, one per
applicable full combo on the host platform.

**Tooling note:** the `fixtures` workflow requires the system `sqlite3`
CLI on PATH (every OS ships one); the *released* binary has zero
runtime dependencies — sqlite3 is only a maintainer-tooling
requirement.

The refresh flow uses three binaries/actions with strict role
separation:

- **`agent-detect-dev fixtures daemon`** — only the *user* runs this,
  never the agent (it refuses to start inside an agent; see
  DESIGN.md "user-only daemon"). It is **pure**: it pops one host-platform
  queue row per poll, materializes its `pending` rows, evaluates each
  (`from-identity`: declared generation, zero tokens; `from-capture`:
  probe then launch the real harness session), stamps `fixtures`, and
  drains the row's pending rows. It never writes `fixtures` outside pop
  processing and never inserts queue rows. The queue row itself stays
  queued until its pending rows all finish — it is the crash-resume
  anchor, so a daemon crash mid-seed simply resumes on the next run.
- **`agent-detect-dev fixtures capture`** — runs *inside an agent*
  session; captures the current session into `fixtures/<id>.json`
  (merge-writes `from-capture` + `from-capture-raw`, preserving any
  existing `from-identity`) and upserts a `fixtures` row. **Fixtures
  only** — a partial detection exits 8 with no store change (never
  writes `queue`).
- **`agent-detect-dev fixtures queue`** — **enumerate + upsert only,
  no evaluation.** With a scope flag it upserts each candidate per
  selected mode into `queue`; without one it creates a seed row with
  the positive dims (`--harness=`, `--provider=`, `--model=`,
  `--platform=`, or the composite `--agent=`/`--fixture=`) and the rest
  `null`.
- **`agent-detect-dev fixtures dequeue`** — **DELETE only.** Deletes
  the matching `queue` rows (by dims + stored markers); never touches
  `fixtures`.

The shared filters (at least one required for `queue`/`dequeue`):
`--harness=H`, `--provider=P`, `--model=M`, `--platform=PLAT` constrain
their dim to equality; `--fixture=<h>-<p>-<m>-<plat>` is an exact
4-part id; `--agent=<h>-<p>-<m>` sets h-p-m (platform may be added
with `--platform=`). Dim filters compose (AND) with the scope flags
below. (There are no `--no-*` flags — an unset dim is expressed by
simply omitting it.)

The **refresh modes** (`--from-identity` / `--from-capture`) select the
worker. No mode flag → **both** rows are queued per candidate (the
declared pass first, then the capture upgrade). Both flags together →
exit 3. `dequeue` filters by the stored mode the same way (no flag →
all modes).

The scope flags (shared by `queue`/`dequeue`) select a candidate set
instead of a dim filter; each is **pure enqueue** (or pure row filter
for dequeue — stored markers, never a probe):
- `--all` — the default scope made explicit: every `fixtures` row.
- `--stale-by-days=N`, `--stale-by-hours=N`, `--stale-by-minutes=N` —
  age-threshold scopes. The queued row always stores the age in
  **minutes** (`stale_by_minutes`); days/hours convert at stamp time.
  The daemon skips only when the fixture is still age-fresh.
- `--stale-by-version` — version-marker scope. The daemon compares a
  live `--version` call against the fixture's captured
  `harness_version` (a `fixtures` column stamped at capture time;
  `from-identity` rows carry null).
- `--stale-by-detect` — re-capture when the fixture's
  `agent_detect_version` is NULL or differs from this binary's version
  (the designated sweep after a version bump; also enumerates
  `--missing-fixture-entry` rows, whose version is NULL).
- `--stale-by-hash` — re-capture when the stored per-channel generation
  hash is NULL or differs from the current fixture file's channel
  object (BLAKE3 over the channel). The mode flags pick the channel;
  no mode flag checks both, one row per stale channel's mode.
- `--recipes` — every known recipe (`recipesForFixtures`, host
  platform).
- `--missing-fixture-file` — recipes whose `fixtures/<id>.json` is
  absent from disk (absorbs `--recipes`).
- `--available` / `--unavailable` — enqueue fixtures rows whose
  `available` marker is 1/0; `--successful` / `--unsuccessful` — the
  same for the `successful` marker. `--unsuccessful` is the designated
  catch vector for captures whose detection was partial: valid ids,
  last attempt failed. No probing happens anywhere.
- `--missing-fixture-entry` — (queue only) scan `fixtures/*.json`;
  files with no `fixtures` row are re-registered (valid ids → a
  `fixtures` entry with generation columns NULL; invalid ids →
  `invalid` row); **the file persists**.

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
3. The daemon pops the queue row, materializes `pending` rows, and
   evaluates each: the `from-identity` pass merge-writes the declared
   `from-identity` channel (zero tokens), and the `from-capture` pass
   launches the harness headlessly so it runs `fixtures capture` inside
   a live model session (token-consuming — announce with the
   pre-capture review window and confirm with the user first).

For batch refreshes: `fixtures queue --recipes` queues the whole matrix
(both modes per recipe; no-launch recipes get their `from-identity` row
plus an `invalid` entry for the suppressed capture side), `fixtures
queue --stale-by-detect` re-queues everything whose
`agent_detect_version` drifted, `fixtures queue --stale-by-hash` re-
queues combos whose file channel diverged from its stored hash, and
`fixtures queue --unsuccessful` re-queues the valid-id failures. Failed
jobs are **consumed** — there is no auto-retry; retry explicitly via
`--unsuccessful` / `--unavailable`.

### common expected failures when refreshing

Queue jobs run in two modes with different failure surfaces. The
`from-identity` worker resolves declared identification from provided
ids — a failure there is a **rule-table bug** (unknown dims, malformed
combo), surfaced as `daemon: from-identity failed for <combo>` with the
row stamped `successful=0` and consumed. Fix the rules and re-queue.

Account-level failures — **credits depleted** (insufficient balance /
credits error in the worker stderr), **rate limit encountered**
(`429` / "too many requests" — back off, do not retry in a tight loop),
**upgraded plan required** (`401`/`403`, "upgrade your plan") — are
only reachable on `from-capture` jobs (the real harness session talks
to the provider). Treat those as **environment-level failures**, not
detection bugs: resolve the account condition and re-queue with
`fixtures queue --unsuccessful`, or skip the combo. A `from-capture`
failure (timeout / nonzero exit / post-check fail / detection-partial
exit 8) stamps `successful=0` (`available=1` if the probe passed) and
**consumes the item** — no re-queue, no spin. An uninstalled harness
probe failure stamps `available=0, successful=0`. Retry manually:
`fixtures queue --unsuccessful` (valid ids, failed attempt) or
`fixtures queue --unavailable` (harness missing).

### cross-device runbook

Queue rows and fixtures sync across hosts via the committed DB +
fixture files. Only the matching platform's daemon pops a row
(`AND (platform IS NULL OR platform = '<host>')`), so a
`platform='darwin'` row is never popped on Windows:

1. On host A (e.g. macOS): run the daemon, let the platform's rows
   drain, then commit the DB + fixtures (single-writer workflow — pull
   before daemon, commit after).
2. On host B (e.g. Windows): `git pull`, `zig build dev`, run the
   daemon — it pops only the host-platform rows that remain queued.
3. Failed rows retry via `fixtures queue --unsuccessful` /
   `--unavailable` on the host that can reach the harness.

### committed-store hygiene

`fixtures/index.sqlite3` is **committed** with each landing (it is the
cross-host work queue + state). Never commit `index.sqlite3-journal` /
`-wal` / `-shm` or the daemon files (`daemon.log`, `daemon.ctl`) — they
are gitignored. The DB dirties on every upsert; commit when work lands.
The dev agent reads the `invalid` table and the generation columns to
review regeneration completeness; purging fixture files is user
discretion.

## test matrix: harnesses, providers, models

The committed fixtures double as the integration test of the detection
ladder (see DESIGN.md "test matrix" for the policy). The matrix is the
`recipesForFixtures` table — one recipe per `agent_id` — expanded by
`fixtures queue --recipes` and captured by the daemon. Scope: the 13
coding harnesses (`cline`, `kimi`, `mmx`, `pi`, `qwen`, `kilo`,
`omp`, `reasonix`, `crush`, `opencode`, `vibe`, `cursor`, `copilot`)
plus the `goose` contributor-scope example.

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

### probing scope + runbook

The maintainer probes the free combos + the MiniMax subscription:

```sh
zig build dev
./zig-out/bin/agent-detect-dev fixtures queue --recipes   # both modes per recipe; pure enqueue, zero tokens
./zig-out/bin/agent-detect-dev fixtures daemon --write-log
```

The daemon pops rows in order `from-identity` → `from-capture`
(declared work first, capture upgrades after) and captures each recipe
to `fixtures/<id>-<platform>.json`. Review each fixture's evidence
claims as they land. Contributors add other combos (rules → recipes →
captures on their platform):

- `--from-identity` — declared-only population: the harness is not installed
  or won't run. Zero tokens; the fixture is declared, not observed.
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
another. Query free/paid from the harness's own model catalog first
(e.g. omp's `~/.omp/agent/models.db` per-provider `cost`: input==0 →
free); OpenRouter's `/api/v1/models` (explicit `:free` ids + `pricing`)
and artificialanalysis.ai (per-model price) are good cross-checks.
arena.ai (LMArena) and HF trending are not free/paid sources — they
report rankings and published weights, not serving prices. Name
variations across services (`:free` vs `-free`, release stamps like
`-0731`, reasoning-effort suffixes) are coalesced into one canonical
model per family and recorded as variations on the recipe — never added
as duplicates. This documented convention is mirrored at the code level
by each rule's `variations` field (see "add a new model or provider
rule" below): `--model=`/`--provider=`/`--harness=` CLI flags resolve
any alias that is the rule's `name`, `label`, `short_title`, or a
`variations` entry, normalized to a strict slug. Reference cache:
`docs/evergreen-top50-models.txt`
(the tracked coalesced evergreen top-50 set that bulk additions must clear;
a harness's own model catalog intersects it per provider to decide free
launch/capture attachment).

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

Queue jobs run in two modes. `from-identity` resolves cooked from provided
ids — zero tokens, no harness, declared-not-observed fixtures.
`from-capture` launches the real harness headlessly so it runs
`fixtures capture` inside a live model session — that session consumes
tokens (free-tier quota or subscription) and must be confirmed with the
user first. A `fixtures capture` run by hand inside an agent session
consumes that session's tokens.

### global-settings rule

Never change a global harness/provider/model setting to make a fixture
pass — use env/arg/scope flags only. `agent-detect` reads harness
configs read-only and performs no config writes (nothing lands in a
sandboxed HOME or anywhere else); flag any needed global change
instead.

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
or `CLINE_PASS` all work) — each is normalized (lowercase + strip
non-alphanumeric, whole-string) and matched against the rule's alias
set (canonical `name`, `label`, `short_title`, and `variations`), with
exact-name precedence (so `cline` always means `cline`, never
`cline-pass`). An alias matching two rules is rejected by the
alias-uniqueness test; the resolver itself is deterministic
(first rule in array order wins). This is how a harness whose
provider/model can't be auto-detected still gets a report and
trailer.

## add a new harness rule

Add a `HarnessRule` entry to the `rulesForHarnesses` array in
`src/main.zig`. Required fields:

| field             | how to fill                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------- |
| `name`            | strictly lowercase alphanumeric — what the harness calls itself canonically (e.g. `kimi-code`)              |
| `label`           | the human-readable brand form (e.g. `Kimi Code`); used to derive `harness_id`                              |
| `license`         | SPDX keyword per the table below                                                                           |
| `license_sources` | two URLs: the project page + the LICENSE file linked from it. `null`/`NOASSERTION` license keeps this empty |
| `env_markers`     | env-var names unique to this harness (one or more). Run the harness' `--help` and inspect its config to discover |
| `proc_names`      | lowercase exe names matched against the process ancestry. Many node-based harnesses use generic exes — leave empty |
| `variations`      | optional extra alias display-strings not covered by `name`/`label`/`short_title` (e.g. `"Kilo Code CLI"`). Keep minimal — see the alias conventions below |

`license` semantics (per SPDX spec):

| value            | meaning                                                    | reciprocity            |
| ---------------- | ---------------------------------------------------------- | ---------------------- |
| `null`           | no data available                                          | `.unknown` (exit 9)    |
| `"NOASSERTION"`  | attempted, inconclusive                                    | `.unknown` (exit 9)    |
| `"NONE"`         | concluded: no license present (verified proprietary/closed) | `.not_reciprocal` (exit 10) |
| SPDX id (`MIT`, `Apache-2.0`, …) | open license                                | computed as today      |

`"NONE"` forces `.not_reciprocal` even when the model/provider dims
are null. Example: `cursor` and `copilot` are closed-source harnesses
verified as no-license, so their rules carry `license = "NONE"` with
their project/terms URLs as `license_sources`.

After adding the rule:

1. Build the dev binary: `zig build dev`.
2. Capture the first fixture following the "refresh a fixture" flow.
3. Commit the new fixture alongside the rule.

If the harness is closed-source and you can't verify the SPDX license,
leave `license: null` and `license_sources: &.{}` — a maintainer fills
them in once verified. If the harness' provider/model can't be
auto-detected at all, the rule alone is enough for recipe-mode
`identify`/`trailer` (see above) — you don't need a live capture.

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
added, remember the daemon's recipe table (`recipesForFixtures`) must
contain the harness before seed expansion will queue captures for it.

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

### catalog-inference verdicts (recorded so they aren't re-litigated)

Per-harness result of Part-1 catalog inference (2026-08-11): **pi**,
**opencode**, **kilo**, **crush**, **qwen**, **kimi** are inferable
(recipes added from their local catalogs / the models.dev catalog via
`kimi provider catalog list`); **reasonix** is partial (only the
configured `[[providers]]`, currently deepseek-flash); **goose**,
**mmx**, **vibe** are **not inferable** (no enumerable local model
catalog — goose is local-inference only, mmx is oauth-only, vibe
exposes only `active_model`).
