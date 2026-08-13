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

`fixtures/index.json` is the committed state store — its four tables
(`fixtures` the known universe, `errors` the failure ledger, `queue`
the filter-entry array, `free_provider_to_model` the free axis) and
the row shapes are specified in DESIGN.md "index.json state store".
Queue entries are **filter tuples** (dims, mode, at most one marker,
the known/valid/successful/free axes) — only the daemon expands them
into concrete candidates, one per poll.

The refresh flow uses three binaries/actions with strict role
separation:

- **`agent-detect-dev fixtures daemon`** — only the *user* runs this,
  never the agent (it refuses to start inside an agent; see
  DESIGN.md "user-only daemon"). It is **pure**: every poll it scans
  the queue-entry array (from-identity entries first), purges entries
  whose expansion has no remaining candidates anywhere, expands the
  first entry with remaining host-platform work (stamping `started_at`
  on its first work), and evaluates ONE candidate (`from-identity`:
  declared generation, zero tokens; `from-capture`: probe
  `version_launch` then launch the real harness session via
  `prompt_launch`). It never writes `fixtures` outside pop processing
  and never inserts queue entries. Crash-resume derives from the
  completion ledger (channel dates + errors `failed_at` vs the entry's
  `started_at`) — a capture that died with the daemon simply re-runs.
- **`agent-detect-dev fixtures capture`** — runs *inside an agent*
  session; captures the current session into `fixtures/<id>.json`
  (merge-writes `from-capture` + `from-capture-raw`, preserving any
  existing `from-identity`) and merge-writes the row's capture ledger
  (captured_at + channel_hash + harness_version + fixture_hash),
  purging any errors entry. **Fixtures only** — a partial detection
  exits 8 with no store change (never writes `queue`).
- **`agent-detect-dev fixtures queue`** — **upsert only, no
  evaluation.** One queue entry per selected mode is stamped from the
  given dims, markers, and axes; the daemon expands.
- **`agent-detect-dev fixtures dequeue`** — **DELETE only.** Deletes
  the matching `queue` entries (by dims + stored markers/axes); never
  touches `fixtures`.

The shared filters (at least one required for `queue`/`dequeue`):
`--harness=H`, `--provider=P`, `--model=M`, `--platform=PLAT` constrain
their dim to equality; `--fixture=<h>-<p>-<m>-<plat>` is an exact
4-part id; `--agent=<h>-<p>-<m>` sets h-p-m (platform may be added
with `--platform=`). Dim filters compose (AND) with the markers and
axes below. (There are no `--no-*` flags — an unset dim is expressed by
simply omitting it.)

The **refresh modes** (`--from-identity` / `--from-capture`) select the
worker. No mode flag → **both** entries are queued per candidate (the
declared pass first, then the capture upgrade). Both flags together →
exit 3. `dequeue` filters by the stored mode the same way (no flag →
all modes).

The **markers** (shared by `queue`/`dequeue`; at most one; each selects
the stale candidates at the daemon's expansion; marker sweeps require
`--known`) are **pure enqueue** (or pure row filter for dequeue —
stored fields, never a probe):
- `--stale-by-missing-entry` — fixture files with no store entry: the
  daemon's expansion for it is the registration pass (valid ids → a
  `fixtures` entry with `fixture_hash` + per-channel hashes from the
  committed file; invalid ids → `errors`; **the file persists**).
- `--stale-by-missing-fixture` — store entries whose fixture file is
  absent.
- `--stale-by-days=N`, `--stale-by-hours=N`, `--stale-by-minutes=N` —
  mode-scoped age thresholds (the entry stores MINUTES): a
  `from-identity` entry checks `identity.declared_at`, a
  `from-capture` entry checks `capture.captured_at`; missing/older →
  stale.
- `--stale-by-harness-version` — the row's `capture.harness_version`
  differs from a live `version_launch` probe (a harness upgrade
  re-captures without waiting for an age threshold).
- `--stale-by-detect-version` — the row's `agent_detect_version` is
  null or differs from this binary's version (the designated sweep
  after a `build.zig.zon` bump).
- `--stale-by-fixture-hash` — the row's `fixture_hash` differs from
  the committed file's BLAKE3 (hand edits and git merges included).
- `--stale-by-channel-hash` — `identity.channel_hash` and
  `capture.channel_hash` missing or diverged from each other.

The **axes** (shared; stored as nullable booleans; the pairs are XOR;
defaults applied at expansion: known=true, valid=true, successful/free
unset):
- `--known` / `--unknown` — the `fixtures` map vs the rule
  cross-product minus the known maps (the discovery sweep; see
  "adding a rule" below).
- `--valid` / `--invalid` — invalid-class error entries are excluded
  (default) or re-evaluated as candidates.
- `--successful` / `--unsuccessful` — only no-error candidates vs only
  unsuccessful-class error entries (`--unsuccessful` is the designated
  catch vector for captures whose detection was partial: valid ids,
  last attempt failed). No probing happens anywhere.
- `--free` / `--paid` — `free_provider_to_model` membership.

Conflicts (exit 3): the XOR axis pairs, two age thresholds, two
markers, and `--unknown` with any marker or a non-default
`successful` axis.

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
3. The daemon expands the queue entry and evaluates candidates one per
   poll: the `from-identity` pass merge-writes the declared
   `from-identity` channel (zero tokens), and the `from-capture` pass
   launches the harness headlessly via the row's `prompt_launch` so it
   runs `fixtures capture` inside a live model session
   (token-consuming — announce with the pre-capture review window and
   confirm with the user first).

For batch refreshes: `fixtures queue --stale-by-detect-version`
re-queues everything whose `agent_detect_version` drifted, `fixtures
queue --stale-by-fixture-hash` re-queues combos whose file hash
diverged, and `fixtures queue --unsuccessful` re-queues the valid-id
failures. A bare dims-only queue command (`fixtures queue
--harness=cline --from-identity`) sweeps every known row matching those
dims. Failed jobs are **consumed** — the errors entry's `failed_at` is
the completion timestamp, so there is no auto-retry; retry explicitly
via `--unsuccessful` (or re-assert the same queue entry for a fresh
sweep).

### common expected failures when refreshing

Queue jobs run in two modes with different failure surfaces. The
`from-identity` worker resolves declared identification from provided
ids — a failure there is a **rule-table bug** (unknown dims, malformed
combo), surfaced as `daemon: from-identity failed for <combo>` with an
errors entry stamped and consumed. Fix the rules and re-queue.

Account-level failures — **credits depleted** (insufficient balance /
credits error in the worker stderr), **rate limit encountered**
(`429` / "too many requests" — back off, do not retry in a tight loop),
**upgraded plan required** (`401`/`403`, "upgrade your plan") — are
only reachable on `from-capture` jobs (the real harness session talks
to the provider). Treat those as **environment-level failures**, not
detection bugs: resolve the account condition and re-queue with
`fixtures queue --unsuccessful`, or skip the combo. A `from-capture`
failure (timeout / nonzero exit / post-check fail / detection-partial
exit 8) stamps an errors entry (`capture failed` / `post-check
mismatch`) and **consumes the item** — no re-queue, no spin. An
uninstalled harness (no `version_launch` or the probe exits nonzero)
stamps `unavailable`. Retry manually: `fixtures queue --unsuccessful`
(valid ids, failed attempt). A `from-capture` job launches a real model
session and consumes tokens (free-tier quota or subscription) —
confirm with the user first; a hand-run `fixtures capture` consumes
that session's tokens.

### cross-device runbook

Queue entries, the fixtures map, and the errors ledger sync across
hosts via the committed index.json + fixture files. Only the matching
platform's daemon expands a candidate (`platform = the entry's or the
host's`), so a `platform='darwin'` entry is never worked on Windows —
the entry simply stays queued there until a darwin daemon finishes it:

1. On host A (e.g. macOS): run the daemon, let the platform's work
   drain, then commit index.json + fixtures (single-writer workflow —
   pull before daemon, commit after).
2. On host B (e.g. Windows): `git pull`, `zig build dev`, run the
   daemon — it works only the host-platform candidates that remain.
3. Failed candidates retry via `fixtures queue --unsuccessful` on the
   host that can reach the harness.

### committed-store hygiene

`fixtures/index.json` is **committed** with each landing (it is the
cross-host fixtures map + errors ledger + work queue). Never commit
`index.json.lock` / `index.json.tmp` or the daemon files
(`daemon.log`, `daemon.ctl`) — they are gitignored. The store dirties
on every mutation; commit when work lands. The dev agent reads the
`errors` ledger and the channel ledgers to review regeneration
completeness; purging fixture files is user discretion.

## test matrix: harnesses, providers, models

The committed fixtures double as the integration test of the detection
ladder. The matrix **policy** — harness scope, model/provider policy,
the paid default, the global-settings rule, evidence attribution —
lives in DESIGN.md "test matrix"; the install table below is the
what-to-do side. The matrix itself is the `fixtures` map of
`fixtures/index.json` — one row per `agent_id`-per-platform, carrying
the curated `prompt_launch`/`version_launch` argv — expanded by the
daemon from queue entries and captured per platform.

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
./zig-out/bin/agent-detect-dev fixtures queue --known   # both modes, every known row; pure enqueue, zero tokens
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
clears the evergreen top-100 rank set — the policy is DESIGN.md decision
#13 and the tracked coalesced set is
`fixtures/evergreen-top100-models.txt`. This does not apply
retroactively to models already in the matrix, and it does not apply to
an individual addition a user explicitly needs. Free-vs-paid only
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
2. Seed the rule's store rows — the discovery sweep generates every
   harness × provider × model × platform combination with no store
   entry, declared into `fixtures/`:
   ```sh
   # every new combo the rule participates in (both modes per combo):
   ./zig-out/bin/agent-detect-dev fixtures queue --unknown --harness=<harness_id> --from-identity
   ./zig-out/bin/agent-detect-dev fixtures daemon
   ```
3. Curate the rows that should capture: set `prompt_launch` (the launch
   argv that runs `fixtures capture` inside a live session — argv[0] is
   the concrete per-platform binary, the last element is the capture
   prompt) and `version_launch` (`[<binary>, "--version"]`) on each
   platform's row in `fixtures/index.json`, then
   `fixtures queue --from-capture --harness=<harness_id>` and run the
   daemon again (token-consuming, user-confirmed).
4. Commit the new rules, the declared fixtures, and the store.

If the harness is closed-source and you can't verify the SPDX license,
leave `license: null` and `license_sources: &.{}` — a maintainer fills
them in once verified. If the harness' provider/model can't be
auto-detected at all, the rule alone is enough for recipe-mode
`identify`/`trailer` (see above) — you don't need a live capture.

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
added, seed its rows with `fixtures queue --unknown --from-identity`
(the discovery sweep — see "adding a rule" below) and curate
`prompt_launch`/`version_launch` on the rows that should capture.

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
