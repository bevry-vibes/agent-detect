# contributing

How to maintain `agent-detection` as an agent or human. Read this when
you need to *do* something — refresh a fixture, add a harness rule, add
a model or provider rule, cut a release. For the *why* behind the
design, see [DESIGN.md](./DESIGN.md).

## refresh a fixture

A fixture is `known/<known_alphanumeric_id>.agent.json` plus its matching
`known/<known_alphanumeric_id>.trailer.txt`, where the id encodes
`<harness>-<provider>-<model>` and is suffixed with `-<platform>`
(e.g. `cline-clinepass-kimik3-darwin`). The binary is the only thing
that writes fixtures — agents never hand-author them.

`known/index.jsonl` is a state store: exactly one event per 4-tuple
`(harness, provider, model, platform)`, each dim nullable, with the
derived `known_/agent_alphanumeric_id` *not* stored. Rows with missing
dims are **seeds**: the daemon expands them over the known recipes
(`knownFixturesForKnownAgents`), ensuring each applicable full combo is
queued as `refresh: true` and removing the seed. Rows the daemon cannot
expand are warned once per run and left unchanged.

The refresh flow uses two binaries with strict role separation:

- **`agent-detection-dev known daemon`** — only the *user* runs this,
  never the agent. It polls `known/index.jsonl` every few seconds and
  spawns captures for entries with `refresh: true`, expanding seeds
  over known recipes first.
- **`agent-detection-dev known agent`** — runs *inside an agent*
  session; captures the current session into a fixture and upserts a
  `refresh: false` event for it in the index. A partial detection
  records a `refresh: true` seed instead of a fixture and exits 2.
- **`agent-detection-dev known queue`** — create-or-flip: existing rows
  matching the shared filters flip to `refresh: true`; if none match, a
  seed row is created with the positive dims (`--harness=`, `--provider=`,
  `--model=`, `--platform=`, or the composite `--agent=`/`--known=`)
  and the rest `null`.
- **`agent-detection-dev known dequeue`** — sets `refresh: false` on
  every row matching the shared filters (does not remove them).
- **`agent-detection-dev known purge`** — deletes the matching rows.

The shared filters (at least one required for `queue`/`dequeue`/`purge`):
`--harness=H`, `--provider=P`, `--model=M`, `--platform=PLAT` constrain
their dim to equality; `--no-harness`, `--no-provider`, `--no-model`,
`--no-platform` constrain it to null; `--known=<h>-<p>-<m>-<plat>` is an
exact 4-part id; `--agent=<h>-<p>-<m>` sets h-p-m (platform may be
added with `--platform=`). Dim filters compose (AND) with the scope
flags below.

The scope flags (exactly one per call, shared by `queue`/`dequeue`/
`purge`) select a candidate set instead of a dim filter:
- `--all` — every index row on this platform.
- `--stale` — rows whose runner died or whose `generated_at` is older
  than the threshold (`--older-than-days=N`, `--older-than-hours=N`;
  default 7 days).
- `--partial` — rows with at least one missing dim (seeds).
- `--recipes` — every known recipe (`knownFixturesForKnownAgents`,
  host platform).
- `--missing-fixture` — recipes whose `known/<id>.agent.json` and/or
  `.trailer.txt` are absent from disk.
`queue` creates/flips `refresh:true` rows for the candidates,
`dequeue` sets `refresh:false` on existing candidates, and `purge`
deletes them. By default nothing is gated on harness availability;
`--available` (a modifier, combinable with any single scope flag)
narrows candidates to harnesses whose binary is installed and answers
`--version`.

To refresh one fixture end-to-end:

1. The user starts the daemon in a separate terminal:
   ```sh
   ./zig-out/bin/agent-detection-dev known daemon
   ```
2. From inside an agent session for the harness to capture:
   ```sh
   ./zig-out/bin/agent-detection-dev known queue \
     --harness=<harness_alphanumeric_id> \
     --provider=<provider_alphanumeric_id> \
     --model=<model_alphanumeric_id> \
     --platform=darwin
   ```
3. The daemon polls the index, sees `refresh: true`, spawns
   `known agent`, which writes the fixture file and appends a
   `refresh: false` event.

For batch refreshes: `known queue --all` re-queues every entry in
`known/index.jsonl`, `known queue --stale [--older-than-days=N]
[--older-than-hours=N]` queues entries older than the threshold,
`known queue --recipes` re-queues every committed recipe, and
`known queue --missing-fixture` queues recipes whose fixture files are
missing. Add `--available` to skip harnesses that aren't installed.

## add a new harness rule

Add a `KnownRuleForKnownAgent` entry to the
`knownRulesForKnownAgents` array in `src/main.zig`. Required fields:

| field             | how to fill                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------- |
| `name`            | strictly lowercase alphanumeric — what the harness calls itself canonically (e.g. `kimi-code`)              |
| `label`           | the human-readable brand form (e.g. `Kimi Code`); used to derive `harness_alphanumeric_id`                 |
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
them in once verified.

## add a new model or provider rule

Model and provider rules live alongside the harness rules in
`src/main.zig` as `knownRulesForKnownModels` and
`knownRulesForKnownProviders` arrays. Their structs are
`KnownRuleForKnownModel` and `KnownRuleForKnownProvider`.

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
zig build && ./zig-out/bin/agent-detection --version
# → agent-detection <new_version>
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
`knownRulesForKnownAgents` for the daemon to recognize), but the
bullet is the maintainer's next-session list.

- [ ] **claude** — VS Code-embedded Claude Code agent.
- [ ] **continue / cody / windsurf** — other VS Code-embedded agents
  (need a different ladder step to detect extension-host children).
- [ ] **grok** — Grok Build / Grok CLI.