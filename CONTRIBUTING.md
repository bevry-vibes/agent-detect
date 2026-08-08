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

A capture (or a harness-availability probe) requires the target
harness to actually run the target model. When the account or
environment can't do that, the daemon reports
`daemon: worker failed for <combo> (exit code N) — re-queued` together
with the worker's stderr, and the row stays queued for another
attempt/platform. These are **expected, environment-level failures** —
not detection-code bugs — and should be treated as such when triaging:

- **credits depleted** — the account has no remaining credits for the
  model; the provider refuses with an insufficient-balance / credits
  error in the worker stderr. Top up and re-queue.
- **rate limit encountered** — the provider throttles the harness /
  model API (e.g. `429`, "too many requests"); the probe or capture is
  refused. Back off and re-queue later — do not retry in a tight loop.
- **upgraded plan required** — the model is paid or gated and the
  current plan does not include it (e.g. `401`/`403`, "upgrade your
  plan", "model not included in your tier"). The capture cannot proceed
  until the plan is upgraded; leave the row queued as handoff for a
  platform/account that has access.

When a refresh fails for one of these reasons, do not treat it as a
rule/detection defect (don't patch the rule tables or file a detection
bug); resolve the account condition and re-queue, or skip the combo.

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
