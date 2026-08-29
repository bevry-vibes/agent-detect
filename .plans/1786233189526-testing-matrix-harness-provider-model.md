# Testing matrix: harnesses, providers, models — full agent test pass

## Goal

All `zig build test` tests pass; every coding harness detects correctly. The matrix policy lives in DESIGN.md, the runbook + installs in CONTRIBUTING.md, and the token restraint in AGENTS.md.

## Current state (2026-08-11)

**Shipped and committed** (in order; `zig build test` green at every checkpoint, tree clean):

1. **Full matrix implemented:** 110 recipes, 11 coding harnesses (jcode **dropped** 2026-08-11 — too unreliable), all three queue modes, origin-aware backfill, evidence claims + combo-match post-checks, daemon pacing + `fixtures/daemon.ctl` control (pause/resume/stop), adaptive `--poll-seconds`/`--capture-review-seconds`/`--capture-timeout-seconds`, `from-ids`/`from-raw`/`from-capture` workers.
2. **Mode-value bug fixed:** queue stores the full `from-*` string (was prefix-stripped → from-ids rows ran the from-raw worker). Verified end-to-end via a launchd-launched daemon.
3. **Daemon launchpath (macOS):** `launchctl bootstrap gui/$(id -u)` with a LaunchAgent plist runs the user-only daemon with a clean launchd ancestry (passes `assertNotInAgent`), no sudo/TCC. Documented in CONTRIBUTING.md, including the **required `EnvironmentVariables.PATH`** (launchd doesn't inherit the shell PATH → harness spawns fail `FileNotFound` without it).
4. **Real `from-capture` fixtures (user-confirmed, token-consuming):**
   - cline: `cline-clinepass-step37flash`, `cline-clinepass-deepseekv4flash`, `cline-minimax-minimaxm3`, `cline-deepseek-deepseekv4flash`
   - reasonix: `reasonix-deepseekflash-deepseekv4flash` (launch uses `--permission-mode bypassPermissions`; reasonix defaults to interactive tool approval)
   - pi: `pi-deepseek-deepseekv4flash`, `pi-minimax-minimaxm3`, `pi-openrouter-deepseekv4flash`, `pi-mistral-mistrallargelatest`, `pi-cerebras-gptoss120b`, `pi-cerebras-gemma431b`, `pi-cerebras-zaiglm47`
   - opencode: `opencode-opencode-deepseekv4flashfree`
   - Every fixture's lineage passes through the live harness; evidence + combo-match post-checks pass.
5. **Live-detection fixes discovered by real captures:**
   - reasonix: empty `proc_names` (no lineage detection) + a config parser using `startsWith("name =")` that fails on aligned TOML columns (`name        = "..."`); now key-matches before `=` and reads `models = [...]` in addition to `default =`.
   - pi: empty `proc_names`; pi exports `PI_CODING_AGENT`/`PI_PROVIDER`/`PI_MODEL` to tool subprocesses (env path works live); added `moonshotai → kimi` provider-name mapping.
   - opencode: empty `proc_names`; doesn't export `OPENCODE_MODEL`; stores sessions in sqlite (`opencode.db`, `session.model` JSON) → `detectOpencode` gained a session-db fallback (mirrors kilo.db), with session-source evidence claims. Unlocked the whole `opencode/*` free tier.
   - kilo.db: `detectKiloFromDb` now records session observations + evidence claims (the "kilo live-session evidence" follow-up is **done**).
6. **Evergreen top-50 bulk-add constraint (design, DESIGN.md decision #13 + CONTRIBUTING.md):** bulk/maintenance model additions must clear a coalesced evergreen top-50 rank set (artificialanalysis / arena / llm-stats / HF trending base-weights / openrouter top-weekly); does NOT apply retroactively to existing models, NOT limited to free models, and does NOT gate an individual user-needed addition. Name variations coalesce to canonical models and are recorded on the recipe. Free/paid source-of-truth: harness's own catalog first (omp `models.db` `cost`), OpenRouter `/api/v1/models` (`:free` + `pricing`) and artificialanalysis as cross-checks; arena/HF are not price sources. Tracked cache: `docs/evergreen-top50-models.txt`. Note: the leaderboards are JS-rendered; the coalesced set is curated from accessible signals, not scraped.
7. **No docker isolation** (decision recorded) — containers can't produce genuine macOS/Windows captures.
8. **omp evergreen+free expansion (4 batches):** 63 omp recipes covering all providers that expose evergreen+free models — zenmux, siliconflow, sakana, ollama-cloud, kimi-code, meta, google-antigravity, gmi-cloud, nanogpt, huggingface, cursor, github-copilot (devin/moonshot skipped: no evergreen models). 9 new provider rules, ~30 new model rules, 53 real from-raw fixtures (0 failures). All harnesses now have launch specs (crush/goose/mmx/omp added; only account-blocked pi providers and config-mismatched reasonix combos remain launch-less by design).

**Recipe count per harness:** cline 6, crush 4, goose 1, kilo 5, kimicode 3, mmx 2, omp 63, opencode 6, pi 11, qwen 3, reasonix 3, vibe 3 (110 total).

**Current blockers / next-step constraints:**
- **Cross-harness provider expansion is blocked by provider configuration:** the free evergreen providers (zenmux, siliconflow, ollama-cloud, gmi-cloud, nanogpt, huggingface, cursor, github-copilot, sakana) are configured **only on omp**. kilo/kimi/qwen/mmx/crush/vibe/cline/pi/opencode/goose aren't authed against them, so recipes for those would be non-runnable (speculative) — violating the real-captures contract. Continuing requires the providers to be added to each harness, then the same evergreen+free batch pattern.
- **Account-blocked providers:** groq (org 413 request-too-large on every model), xai (403 no credits), moonshot (429/insufficient balance) — recipes carry no launch spec; free-model exploration found cerebras (`gpt-oss-120b`, `gemma-4-31b`, `zai-glm-4.7`) and opencode's own free router as the working free sources.
- **`from-capture` remains user-confirmed** per job (token-consuming); the daemon caps failures at 3 attempts then dequeues with a warning.

## Terminology: the three refresh flavours (all are queue modes)

The term "synthetic" is dropped as ambiguous. All three flavours are first-class `fixtures queue`/`dequeue` modes (flags `--from-ids` / `--from-raw` / `--from-capture`):

- **`refresh-cooked-from-ids`** — resolve the cooked block straight from provided ids (recipe-mode resolution, `resolveRecipe`). Writes a fixture whose `raw` carries `origin: "from-ids"` and **no runtime evidence** (nothing was observed). Zero tokens; the harness binary is not required. Also exposed as the CLI recipe-mode `cooked --harness=H --provider=P --model=M`.
- **`refresh-cooked-from-raw`** — `buildEnv` fabricates a runtime (env markers + config files), then `refresh run` runs the *live detection ladder* over that fabricated raw and commits the fixture. Deduces from **raw** (fabricated origin, real detection mechanism). Zero tokens. Default mode.
- **`refresh-from-capture`** — the daemon launches the real harness headlessly so it runs `fixtures capture` inside a live session; token-consuming. Deduces from **raw** (real origin).

**Artifact classes:** `from-ids` fixtures are *declared* (not observed); `from-raw`/`from-capture` fixtures are *observed*. Every fixture carries a top-level `origin` key (`"from-ids" | "from-raw" | "from-capture"`) so readers and the test suite know the class.

## Decisions (confirmed)

1. **Harness scope:** coding harnesses only — `cline`, `kimi`, `mmx`, `pi`, `qwen`, `kilo`, `omp`, `reasonix`, `crush`, `opencode`, `vibe`. Claw / machine-control agents out of scope. `jcode` was in the original scope but **dropped (2026-08-11)** — too unreliable.
2. **Models:** open-weight/open-source preferred; free closed and popular closed models also get rules (detection must exceed the preferred set).
3. **Providers:** zero-training or reciprocal-training preferred. Maintainer probing = free combos of those + paid MiniMax. New free providers added during this run: OpenRouter, Groq, Cerebras, Z.AI, Kimi/Moonshot (provider rules), plus the omp-provided evergreen+free set (zenmux, siliconflow, ollama-cloud, gmi-cloud, nanogpt, huggingface, cursor, github-copilot, sakana, meta, google-antigravity, kimi-code).
4. **Paid default:** MiniMax subscription. Subscriptions preferred over pay-as-you-go (DeepSeek paid API is secondary; DeepSeek free combos use the free tier).
5. **Existing closed/paid fixtures** (goose/pi/kilo × anthropic/claude-sonnet-4): keep as contributor-scope examples.
6. **Recipe refactor:** one parameterized `buildEnv` per harness, not one per combo.
7. **Queue job modes:** every queue job carries `mode` = `from-ids` | `from-raw` (default) | `from-capture`. Flags `--from-ids` / `--from-raw` / `--from-capture`, exactly one, default `from-raw`, two+ together → exit 3. **One mode per combo:** `mode` is NOT part of the `queue_dedupe` unique index, so re-queueing the same combo with a different mode flag upgrades/downgrades that single row (the fixture file name is per-combo, so modes are mutually exclusive per combo).
8. **Dev help surface:** `agent-detect-dev --help` (and bare no-args) must show the full dev CLI surface (`fixtures daemon/capture/queue/dequeue/help`, `refresh run`, `raw`) in addition to the released actions; `agent-detect --help` stays the released help. This also documents what `<argv0> refresh run` is: agent-detect spawning itself under the daemon-prepared env.
9. **Sweeps, cheapest first:** mass refreshes run as sweeps in ascending evidence quality — `from-ids`, then `from-raw`, then `from-capture`. The daemon pops rows in that order (a higher-quality mode never runs while lower-quality work remains), so generation bugs are fixed before any real-capture tokens are spent.
10. **Adaptive pacing:** `from-ids`/`from-raw` jobs process in batch at ~5s intervals (zero-cost, no review needed). `from-capture` jobs run one at a time (never batched) with a ~15s pause **before** each capture (announced + cancellable, so no tokens are spent without a chance to abort) and a ~15s pause **after** (human review) — ~30s between capture iterations. Flags: `--poll-seconds` (base, default 5), `--capture-review-seconds` (default 15).
11. **Evidence attribution is the success criterion (critical):** every detected dim in a `from-raw`/`from-capture` fixture must carry an **evidence claim** — the detector itself records, per dim, which source it read (env var, config/session file+field, process-lineage name) and the value it read. Code mechanically verifies the claim chain: each dim has ≥1 claim whose source is present in `raw` and whose value matches the cooked dim. **Code cannot judge semantic deducibility — that is human review** (the capture-review window for `from-capture`, and commit review for everything). Where a deduction's source cannot be serialized into a claim (custom database formats, e.g. kilo's sqlite, main.zig:1581), that is logged as a follow-up task, never silently accepted. `from-ids` fixtures are declared, not observed — excluded from the check by `origin`.
12. **Daemon control — one cross-platform mechanism (no per-platform doubling):** the daemon checks a control file `fixtures/daemon.ctl` every heartbeat (~1s) and acts on one of `pause` / `resume` / `stop` (the writer writes the word; the daemon clears the file after acting). Works identically on macOS, Linux, and Windows — signals are not relied on beyond terminal Ctrl+C (SIGINT = graceful stop), since SIGUSR1/SIGUSR2 don't exist on Windows. `stop` = finish the in-flight job then exit gracefully; `pause` = finish in-flight then idle with no new pops; `resume` = continue. The daemon writes a ~1s **status heartbeat** to `fixtures/daemon.log` (`--write-log`) so a watcher polling the log every second always sees current state, decoupled from the 5s/30s iteration delays. **Design principle to record in DESIGN.md: one cross-platform control interface for pause/resume/stop, not per-platform signal doubles.**

## Code facts (verified)

- `agent-detect` has **no HTTP client**; detection reads only local state (env, process ancestry, config/session files, kilo.db). The binary consumes no tokens.
- **Daemon spawns itself, not the harness.** On a `from-raw` job the worker spawns `<argv0> refresh run` (main.zig:4372), where argv0 is agent-detect's own executable; `refresh run` dispatches to the same `runFixturesCapture` as the `fixtures capture` CLI (main.zig:4585). The env markers + config files were fabricated by `buildEnv`, so `detect()` resolves from that fabricated raw. The harness binary is **never executed** — zero tokens. The only place the daemon runs a harness binary is `probeBinary` for `--available` (`<name> --version`, a version check).
- **Live `fixtures capture` run by hand inside a real agent session:** same `detect()`, capture adds no tokens — but the session hosting it is a real model conversation, and that session consumes tokens.
- **Current daemon has no real-capture path and no from-ids path (the flaw decision #7 fixes):** every queued job takes the `from-raw` branch. The queue schema has no mode column — `mode` must be added (store is gitignored, no migration needed).
- **Evidence gap (the flaw decision #11 fixes):** `raw.env` observations come only from declared harness markers (main.zig:2145); detectors that resolve provider/model from env vars they read — `KILO_MODEL` (main.zig:1555), `OPENCODE_MODEL` (main.zig:1680), `PI_PROVIDER`/`PI_MODEL` placeholders (main.zig:1734) — never record a claim in raw, so the committed kilo-deepseek, kilo-anthropic, and pi-anthropic fixtures lack provider/model evidence. Config-file detectors (kimi/cline/goose/qwen/omp/reasonix/jcode/crush/mmx/vibe) already surface provider+model via config observations.
- **Custom evidence sources:** kilo's live path reads `~/.local/share/kilo/kilo.db` (a custom sqlite session store) via `sqlite3` (main.zig:1581) — no claim shape yet; follow-up. The `from-raw` launcher (2b) sets `KILO_MODEL` so `from-raw` kilo fixtures are fine after 2h.
- **Deduction source — three paths, do not conflate:** `from-ids` deduces from **provided ids** (no observation); `from-raw` deduces from **raw** of a *fabricated* runtime; `from-capture` deduces from **raw** of the *real* runtime.
- **Daemon pacing + control:** the poll loop sleeps a fixed 5s (main.zig:4183) and processes one row per iteration — becomes adaptive (5s batch for `from-ids`/`from-raw`, 15s pre + 15s post around each `from-capture`; decision #10). No control file, pid file, or status heartbeat exists today (decision #12). The daemon log is `fixtures/daemon.log` via `--write-log` (main.zig:4032).
- CONTRIBUTING.md "common expected failures" (credits depleted / rate limit / upgraded plan) describes a model-invoking capture the `from-raw` worker cannot produce — it only becomes reachable via `from-capture` jobs; rewrite the section accordingly.

## Resolved: keep `refresh-cooked-from-raw` (for now)

It is the only zero-cost automated exercise of `detect()` end-to-end (the fixture suite is the sole integration test of the detection ladder; recipe mode never calls `detect()`), it gives zero-token breadth across the ~40–120 combo matrix, and its raw is honest ("runtime X resolves to cooked Y"). Overhead collapses to one parameterized `buildEnv` per harness (2b).

**Trade-offs acknowledged (for the removal follow-up, not decided now):** fabricated evidence vs the "real captures, not synthetic assemblies" contract (main.zig:2013); the machinery overhead (2a/2b/2h) serves only this path; `from-capture` + contributor captures are the authoritative real fixtures; stripping would simplify to `from-ids` + `from-capture`, delete 2a, collapse 2b, drop 2h and the `refresh run` child + worker branch, and require a new in-process `detect()` regression test.

## Data flow: queue lifecycle

- `fixtures queue [scope] [--from-ids|--from-raw|--from-capture]` upserts queue rows. The mode flag **stamps** rows on `queue` (default `from-raw`; two mode flags together → exit 3). On `dequeue` the mode flag is a **filter** (default: all modes).
- **One mode per combo:** `mode` is a column but not in `queue_dedupe`; re-queueing a combo with a different mode flag `INSERT OR REPLACE`s the single row's mode (upgrade/downgrade). The fixture file name is per-combo, so no two modes ever write the same combo concurrently.
- Seeds (rows with missing dims) expand over `recipesForFixtures` on the daemon's next poll; each expanded full row **inherits the seed's mode**.
- Daemon pop order: `from-ids`, then `from-raw`, then `from-capture`; one row per poll. **Adaptive pacing:** base poll ~5s (`--poll-seconds=N`) for `from-ids`/`from-raw` (batch); a `from-capture` row gets ~15s pre-capture pause (announced, cancellable) + ~15s post-capture review pause (`--capture-review-seconds=N`), so ~30s between captures (decision #10).
- **Control + observability (decision #12):** `fixtures/daemon.ctl` checked every ~1s heartbeat — `pause` / `resume` / `stop`, cleared after acting; Ctrl+C remains the terminal graceful-stop shortcut; a ~1s status heartbeat goes to `fixtures/daemon.log` during idle/pause/review so watchers polling at 1s see current state. One mechanism across macOS/Linux/Windows — no signal doubling.
- **Lazy backfill is origin-aware** (skip-and-complete from a valid committed `fixtures/<id>.json`, main.zig:4199): it completes only when the existing fixture's `origin` ranks **≥** the queued mode (rank: `from-ids` < `from-raw` < `from-capture`). So `from-raw` re-captures over a stale `from-ids` fixture, and `from-capture` never backfills.
- **Post-check (2i)** runs after a `from-raw`/`from-capture` job produces `fixtures/<id>.json`: (a) evidence-claim completeness per dim; (b) **combo-match** — `cooked.agent_id` == queued `agent_id`. Failure → delete the file **and the `fixtures` row the child already upserted** (runFixturesCapture upserts at main.zig:3794 before the daemon validates), log, and re-queue: `from-raw` re-queues freely (zero cost), `from-capture` re-queues at most 3 times then dequeues with a warning (token protection). `from-ids` post-check is just parse + `origin` + cooked-schema.
- **`from-capture` worker timeout:** default 600s, `--capture-timeout-seconds=N`, so a hung headless harness fails out instead of blocking the poll loop forever.

## Work items

### 1. Docs

**1a. AGENTS.md — append two sections**

```markdown
## splat naming

Never refer to a to-be-defined name with `X`, `Xxx`, or `XXX`.
Use an asterisk splat (`build*Env`) or the interpolated form matching
the language's conventions — `build<Harness>Env` (camelCase),
`build<HARNESS>_ENV` (UPPER_SNAKE), `build{Harness}Env` /
`build${HARNESS}Env` as the syntax dictates. Always a real, greppable
pattern — never `X`.

## token cost

`agent-detect` consumes no model tokens: detection reads only local
state (env markers, process ancestry, harness config/session files, the
local Kilo DB) and performs no network I/O. Token cost arises only from
the session hosting it — e.g. a live `fixtures capture` runs inside a
real agent session, and that session is a model conversation.
```

**1b. DESIGN.md — new section `## test matrix: harnesses, providers, models`** with these bullets:
- Harness scope (coding only; list).
- Model policy (open-weight/open-source preferred + free closed + popular closed).
- Provider policy (zero-training / reciprocal-training preferred; maintainer probing = free combos + MiniMax; beyond that is contributor scope via CONTRIBUTING.md).
- Paid default (MiniMax subscription; subscriptions over pay-as-you-go).
- Global-settings rule (never change global harness/provider/model settings; only env/arg/scope flags; worker captures run in a sandboxed HOME; flag any needed global change).
- Evidence-attribution rule (every detected dim in observed fixtures carries a claim to a present, value-matching source; semantic deducibility is human review; custom-db sources are logged follow-ups, never faked; `from-ids` fixtures are declared, not observed).
- Cross-platform daemon control principle (single `fixtures/daemon.ctl` protocol for pause/resume/stop across macOS/Linux/Windows — no per-platform signal doubles; Ctrl+C stays the terminal graceful-stop).
- **No docker isolation (decision, 2026-08-11):** harness installs/runs are never containerized. A container (overwhelmingly Linux-based) would not produce genuine macOS/Windows captures — platform evidence (config paths, env markers, process lineage, harness session behavior) must come from the harness running on the actual host platform, and dockerized runs would paper over exactly the portability the matrix exists to test. Isolation is instead handled by the sandboxed worker HOME (2a) and the user-only daemon rule; new/untrusted harnesses are vetted via the CONTRIBUTING.md install-confirmation rule.
- Refresh flavours (`refresh-cooked-from-ids` / `refresh-cooked-from-raw` / `refresh-from-capture`), the `origin` key, and pointer to CONTRIBUTING.md for installs + probing runbook. No token-cost text here.

**1c. CONTRIBUTING.md — add:**
- **Per-harness install table** (macOS/Linux/Windows × package manager): cline `npm i -g cline`; kimi-code `npm i -g @moonshot-ai/kimi-code`; mmx `npm i -g mmx-cli`; pi `npm i -g @earendil-works/pi-coding-agent`; qwen `brew install qwen-code` | `npm i -g @qwen-code/qwen-code`; kilo `brew install Kilo-Org/tap/kilo` | `npm i -g @kilocode/cli`; jcode `brew tap 1jehuang/jcode && brew install jcode`; omp `brew install can1357/tap/omp` | `bun i -g @oh-my-pi/pi-coding-agent`; reasonix `brew install esengine/reasonix/reasonix` | `npm i -g reasonix`; crush `brew install charmbracelet/tap/crush` | `npm i -g @charmland/crush`; opencode `brew install anomalyco/tap/opencode` | `npm i -g opencode-ai`; vibe `uv tool install mistral-vibe`. Rule: prefer homebrew/npm/uv/scoop over web scripts; **confirm every install with the user**.
- **Probing scope + runbook:** maintainer = `fixtures queue --recipes --available` (default `from-raw`) then daemon; contributors add other combos (rules → recipes → captures on their platform). `--from-ids` for declared-only population (harness not installed / won't run), `--from-capture` for real recaptures only.
- **Monitoring + control runbook:** run the daemon with `fixtures daemon --write-log` (log: `fixtures/daemon.log`) and poll that log at ~1s (faster than the iteration delays). Pacing: `from-ids`/`from-raw` process at ~5s intervals; each `from-capture` is announced ~15s ahead (cancellable) and followed by a ~15s review pause. Control (same on macOS/Linux/Windows): `printf 'pause\n' > fixtures/daemon.ctl` pauses, `printf 'resume\n' > ...` resumes, `printf 'stop\n' > ...` stops gracefully after the in-flight job (the daemon clears the file after acting); Ctrl+C in the daemon terminal is the graceful-stop shortcut.
- **Refresh/token warning** (mode-aware, accurate per Code facts):
  > Queue jobs run in three modes. `from-ids` resolves cooked from provided ids — zero tokens, no harness, declared-not-observed fixtures. `from-raw` (default) fabricates env markers + config files and runs the detection ladder via `refresh run` — zero tokens, no harness session. `from-capture` launches the real harness headlessly so it runs `fixtures capture` inside a live model session — that session consumes tokens (free-tier quota or subscription) and must be confirmed with the user first. A `fixtures capture` run by hand inside an agent session consumes that session's tokens.
- **Global-settings rule:** same as DESIGN.md; `from-raw` captures write config under a sandboxed HOME, never the user's real harness config.
- **Rewrite** the "common expected failures" section as: `from-raw` detection failures (unresolved detection, missing harness) vs `from-capture` account failures (credits depleted / rate limit / upgraded plan) — the latter only reachable on `from-capture` jobs.

**1d. Dev help surface:** make `agent-detect-dev --help` (and bare dev no-args) print the released usage plus a **dev actions** section listing `fixtures daemon` / `fixtures capture` / `fixtures queue` / `fixtures dequeue` / `fixtures help`, `refresh run` ("internal: the `from-raw` capture worker; agent-detect spawning itself under the daemon-prepared env"), and `raw`. `agent-detect --help` is unchanged. The dev binary already has `fixturesUsage` (main.zig:2252) — compose a top-level dev usage that references it (and the three mode flags, `--poll-seconds`, `--capture-review-seconds`, `--capture-timeout-seconds`, `--write-log`) rather than duplicating it.

### 2. Code

- **2a. Sandbox worker HOME** (daemon worker, ~main.zig:4323): set `HOME` (+ `USERPROFILE` on Windows) to a per-fixture cache dir (e.g. `${XDG_CACHE_HOME:-$HOME/.cache}/agent-detect/workers/<fixture_id>`, created if absent) before spawning `refresh run`. Prevents `from-raw` captures from overwriting real harness config; makes reruns idempotent.
- **2b. Recipe refactor** (dev block): replace per-combo `build<Harness>Env` functions with one `buildEnvForHarness(h)` per harness that derives provider/model via `splitAgentId(combo.agent_id)` and writes the harness's native config shape (cline providers.json; kimi config.toml + `KIMI_CODE_HOME`; mmx config.json + `MMX_CONFIG_DIR`; goose config.yaml; pi `PI_CODING_AGENT` + model; qwen settings.json; kilo `KILO_MODEL`; jcode session JSON; omp config.yml; reasonix config.toml; crush hyper.json; opencode `OPENCODE_MODEL`; vibe `VIBE_ACTIVE_MODEL`). Add dev-only provider metadata (openai-compat base_url + key env var). `RecipesForFixtures` keeps `agent_id` + `probeNames`; a new combo is one line.
- **2c. Rule tables:** add providers `openrouter`, `groq`, `cerebras`, `zai`, `moonshot` (+ `qwen` if verifiable) with verified `closed_training`/`open_training` + two-source URLs (null until verified). Add models `deepseek-v4-pro`, `llama-4`, `qwen3.5`, `mistral-small-latest` (open-weight/source) and `gemini-3-flash`, `gpt-5-mini`, `grok-3-mini`, `claude-opus-4`, `claude-haiku-4`, `gpt-5.5`, `gemini-3.1-pro`, `grok-4` (closed), each with reciprocity + sources.
- **2d. Matrix recipes** (agent_id + probeNames; starter set, expand freely):
  cline: clinepass/kimi-k3 (keep), deepseek/deepseek-v4-flash, minimax/minimax-m3, openrouter/deepseek-v4-flash · kimi: minimax/m3 (keep), deepseek/v4-flash, kimi/kimi-k3 · mmx: minimax/m3 (keep), minimax/m2.7 · pi: anthropic/claude-sonnet-4 (keep), deepseek/v4-flash, minimax/m3 · qwen: minimax/m3 (keep), deepseek/v4-flash, qwen/qwen3.8-max · kilo: anthropic/claude-sonnet-4 (keep), deepseek/v4-flash (keep), minimax/m3, openrouter/v4-flash, zai/glm-5.2 · jcode: minimax/m2.7 (keep), deepseek/v4-flash, minimax/m3, openrouter/v4-flash · omp: minimax-code/m3 (keep), deepseek/v4-flash, openrouter/v4-flash · reasonix: deepseek-flash/v4-flash (keep), deepseek/v4-flash, minimax/m3 · crush: hyper/qwen3.7-plus (keep), hyper/v4-flash, minimax/m3, deepseek/v4-flash · opencode: minimax/m3 (keep), deepseek/v4-flash, hyper/v4-flash, groq/llama-4, cerebras/qwen3 · vibe: mistral/mistral-large-latest (keep), mistral/mistral-small-latest, minimax/m3.

- **2e. Queue job mode (schema + CLI + daemon plumb):**
  - `queue` schema (main.zig:2506): add `mode TEXT NOT NULL DEFAULT 'from-raw'`; **do not** add it to `queue_dedupe` (main.zig:2521) — one mode per combo, re-queue upgrades/downgrades. Store is gitignored — delete `fixtures/index.sqlite3` to recreate, no migration code.
  - `QueueRow` (main.zig:2539) gains `mode: []const u8 = "from-raw"`.
  - `fixtures queue`/`dequeue`: add `--from-ids` / `--from-raw` / `--from-capture` (exactly one; default `from-raw`; two+ → exit 3). Scope flags (`--all`, `--recipes`, `--missing-fixture`, `--stale`, `--partial`) stamp the mode. Semantics per Data flow: `queue` stamps, `dequeue` filters (default all modes), seeds inherit the mode at expansion.
  - Daemon (`runFixturesDaemon`): branch the worker on `action.mode` — `from-ids` → new worker (2f); `from-raw` → existing `runOneComboResult`; `from-capture` → capture worker (2g). **Sweep ordering:** pop `from-ids` before `from-raw` before `from-capture` (decision #9). **Pacing:** base poll ~5s (main.zig:4183) with `--poll-seconds=N`; `from-capture` rows add `--capture-review-seconds=N` (default 15) before and after (decision #10). **Control + observability (decision #12):** run a ~1s heartbeat loop that checks `fixtures/daemon.ctl` (`pause` / `resume` / `stop`, cleared after acting) and writes a status heartbeat to the log during idle/pause/review; keep Ctrl+C as the terminal graceful-stop shortcut. One cross-platform mechanism — no SIGUSR/SIGHUP/Windows-fallback doubling. **Origin-aware backfill** per Data flow. The `--available` probe behaves the same for all modes (`from-ids` records it but does not require availability).
  - `fixturesUsage` (main.zig:2252): document the three modes + flags.

- **2f. `from-ids` worker (declared fixtures):**
  - For a `from-ids` row: resolve the combo via `resolveRecipe(a, h, p, m)` (recipe-mode resolution, no detection), assemble the fixture with `cooked` fully populated, `raw` = `platform_id`, `detectable`/`detected`, empty `env`, real `process_lineage`, empty `evidence`, static `*-urls`, and top-level `origin: "from-ids"`. No harness, no sandbox, no tokens.
  - Post-check: parse the file, confirm `origin == "from-ids"` and the cooked schema is valid; no evidence requirements (declared, not observed).
  - `--available` still probes (informational), but an unavailable harness does not block a `from-ids` job.

- **2g. Capture-mode worker (`refresh-from-capture`, opt-in):**
  - `RecipesForFixtures` gains an optional `launch: ?[]const []const u8` (headless argv) + a capture prompt const, e.g. kilo → `{"kilo", "run", "--auto", "<prompt>"}`, opencode → `{"opencode", "run", "<prompt>"}`, kimi → `{"kimi", "-p", "<prompt>"}`, qwen → `{"qwen", "-p", "<prompt>"}`, jcode → `{"jcode", "run", "<prompt>"}`, vibe → `{"vibe", "--prompt", "<prompt>"}` where `<prompt>` instructs: "run `agent-detect-dev fixtures capture` in the current working directory and report the result". Harnesses without a reliable headless mode (e.g. mmx, crush) get no `launch` → `from-ids`/`from-raw` only; a `from-capture` queue row for them exits with a clear "no launch spec" error instead of silently failing.
  - Worker for `from-capture` rows: spawn the launch argv with the **real** environment (unsandboxed HOME — real API keys/config are required), cwd = the row's platform home, wait for exit (600s timeout, `--capture-timeout-seconds=N`), then treat success as the **post-check passing** (evidence claims + combo-match, per Data flow) on the produced `fixtures/<id>.json`; otherwise delete the file and re-queue — at most 3 attempts, then dequeue with a warning. Never backfills. Reuse the existing daemon re-queue + stderr-capture plumbing.
  - Starter launch specs only (kilo, opencode, kimi, qwen, jcode, vibe); the rest are follow-ups. **Never run a `--from-capture` job without user confirmation** — it consumes tokens. Capture jobs run one at a time (one per poll), each result human-reviewed during the ~15s post-capture pause.

- **2h. Evidence-claim surfacing (fix decision #11 in the detectors):** detectors record, per detected dim, an explicit claim of *what they read*. Add `d.raw.evidence: []EvidenceClaim` with `{ dim, source: "env"|"config"|"session"|"lineage", name, field?, value }`:
  - Audit each of the 12 detectors (`detect*`, main.zig:976-1740): every dim it resolves must produce a claim pointing at a source raw actually carries (env var present, config/session file+field present, lineage name present) whose value matches the dim. For any dim sourced from something raw doesn't yet carry, hunt the real env/field/config where the harness stores it; if it only exists in a custom database (kilo.db), log it in Follow-ups — never fabricate a claim.
  - `detectKilo` (main.zig:1550) and `detectOpencode` (main.zig:1675): record claims against `KILO_MODEL` / `OPENCODE_MODEL` (env observations with values; add both names to `env_value_allowlist`, main.zig:439 — model ids are not secrets). Result: `raw.env` carries `{"KILO_MODEL": {"value": "deepseek/deepseek-v4-flash", "present": true}}` and an `evidence` claim `{dim: "provider"|"model", source: "env", name: "KILO_MODEL", value: "deepseek/deepseek-v4-flash"}`. The `detectKiloFromDb` fallback (main.zig:1581) stays a Follow-up — `from-raw` captures never hit it (2b sets `KILO_MODEL`).
  - `detectPi` (main.zig:1726): harness-only with placeholder defaults — record claims against `PI_PROVIDER` / `PI_MODEL` env observations (allowlist both) so raw shows exactly what was assumed; keep the "model detection TODO" note in DESIGN.md and Follow-ups.
  - Config-file detectors (kimi/cline/goose/qwen/omp/reasonix/jcode/crush/mmx/vibe) claim against their config/session observations (vibe already records one at main.zig:1717) — convert those observations into claims.

- **2i. Evidence validation (mechanical, not semantic):** implement `evidenceClaimsValid(raw, cooked)`:
  - For each dim in `detected` (from-raw/from-capture fixtures only): ≥1 claim with that `dim` whose source is present in raw (env name in `raw.env`, config/session path+field present, lineage name present) **and** whose `value` matches the cooked dim (equals or contains the canonical id/name). The static `*-urls` arrays are not evidence.
  - `from-ids` fixtures skip this check by `origin` (declared, not observed).
  - **Code verifies the attribution chain only; semantic deducibility is human review** (capture review window + commit review). The check catches "no evidence" and "evidence contradicts cooked" mechanically.
  - Apply in: the test suite (section 3) and the daemon worker post-check (combo-match too, per Data flow).

### 3. Tests

Add to `known_fixtures.test.zig` (or a new test file):
- Every `recipesForFixtures.agent_id` splits into a harness/provider/model present in the rule tables; every `rulesForHarnesses` entry has ≥1 recipe.
- **Evidence-claims (decision #11):** every `from-raw`/`from-capture` fixture must pass `evidenceClaimsValid` — each detected dim attributed to a present, value-matching source. Existing kilo-deepseek, kilo-anthropic, and pi-anthropic fixtures fail until 2h lands + re-capture. `from-ids` fixtures are validated for cooked-schema + `origin` only (reduced schema: empty `env` allowed).
- **Origin contract:** every fixture carries a valid `origin`; `from-ids` fixtures carry empty `evidence`.

### 4. Run

1. `zig build dev`
2. `agent-detect-dev --help` → shows the full dev surface (released + `fixtures`/`refresh run`/`raw`); `agent-detect --help` → released only.
3. **Sweep 1 — from-raw:** start from a clean slate — `rm -f fixtures/*.sqlite3* fixtures/*.json` (store gitignored; everything from-raw-regenerable; deleting avoids origin-aware backfill so every fixture, including the evidence-changed kilo/pi ones, re-captures). Run `fixtures daemon --write-log` in a terminal (poll `fixtures/daemon.log` at ~1s). Then `./zig-out/bin/agent-detect-dev fixtures queue --recipes --available` (default `from-raw`, zero tokens) → the daemon captures every recipe to `fixtures/<id>-darwin.json` at ~5s intervals. Review each fixture's evidence claims as they land.
4. **Fix any `from-raw` failures** (missing/partial detection, or evidence claims missing/contradictory — the worker re-queues these) and re-run until the sweep is clean.
5. `zig build test` → all fixture schema + evidence-claims tests pass. (Re-captures the kilo/pi fixtures fixed by 2h.)
6. Recipe-mode smoke: `cooked --harness= --provider= --model=` for a new free combo (exit 0) and `is-reciprocal` for a closed combo (`not reciprocal`, exit 10).
7. `git status` review; commit rules + recipes + fixtures (AGENTS.md commits policy incl. co-author trailer).

**Optional pre-sweep — from-ids (declared population, zero tokens):** `fixtures queue --recipes --from-ids` before sweep 1 when you want a committed fixture for every recipe without running anything; the later `from-raw` sweep upgrades each row's mode and overwrites with observed fixtures. `from-ids` is also how contributors add combos whose harness they won't/can't run.

**Sweep 2 — from-capture (not part of this run; user-confirmed follow-up):** `fixtures queue --recipes --from-capture` only after sweep 1 is clean; each capture is announced ~15s ahead (cancellable via `printf 'stop\n' > fixtures/daemon.ctl`) and followed by a ~15s review pause; each result's evidence claims are checked before the next. Optional single smoke (e.g. kilo × minimax/minimax-m3 on the MiniMax subscription).

## Validation

- `zig build test` green after fixtures land, **including the evidence-claims test** (kilo/pi fixtures re-captured via 2h before they pass).
- `fixtures queue --recipes --available` → 12/12 harnesses available.
- Mode plumbing: `fixtures queue --from-capture --agent=kilo-minimax-minimaxm3` then `--from-raw` → one row whose mode flips `from-capture` → `from-raw` (upgrade/downgrade, queryable via sqlite3); `--from-raw --from-capture` together exits 3; `fixtures dequeue --from-capture` filters by mode.
- **Sweep ordering:** with `from-ids`, `from-raw`, and `from-capture` rows queued, the daemon completes them in that order (observable in daemon logs).
- **Pacing:** `from-ids`/`from-raw` items process at ~5s intervals; a `from-capture` row shows ~15s pre-capture pause + ~15s post-capture pause in daemon-log timestamps (`--poll-seconds` / `--capture-review-seconds` respected).
- **Control file + heartbeat (all platforms):** `printf 'pause\n' > fixtures/daemon.ctl` pauses (finishes in-flight, then no new pops; heartbeat continues), `resume` resumes, `stop` stops gracefully after the in-flight job; the file is cleared after acting; the log shows a status line at least every ~1s during idle/pause/review. No platform-specific signal behavior.
- **Origin-aware backfill:** a `from-raw` row whose committed fixture is `from-ids` re-captures (does not backfill); one whose fixture is `from-raw`/`from-capture` backfills. A `from-capture` row never backfills.
- **Evidence + combo-match:** an evidence-stripped or contradictory fixture fails the test; the daemon worker re-queues (no `fixtures` row upsert) when claims are missing or `cooked.agent_id` ≠ queued `agent_id`.
- **Capture pacing/bounds:** `from-capture` worker respects `--capture-timeout-seconds`; a repeatedly failing row dequeues with a warning after 3 attempts.
- Real harness configs unmutated: `git diff` empty under `$HOME/.kimi-code`, `$HOME/.cline`, `$HOME/.qwen`, `$HOME/.config/goose`, `$HOME/.reasonix`, `$HOME/.omp`, `$HOME/.mmx`, `$HOME/.jcode` after a `from-raw` daemon run.
- `agent-detect-dev --help` differs from `agent-detect --help` (dev surface present); dev help documents `refresh run` and the three mode flags.
- DESIGN.md + CONTRIBUTING.md render with the new sections; AGENTS.md contains both new sections.

## Risks

- New-provider training policies unverified → leave `null` until sourced (drives `is-reciprocal`).
- CONTRIBUTING.md failure-docs mismatch (see Code facts) — resolve during the 1c edit.
- Fixture count grows 15 → ~40+; schema tests scale automatically.
- **Evidence rule breaks existing fixtures** (kilo-deepseek, kilo-anthropic, pi-anthropic) — expected; fixed by 2h + re-capture in sweep 1.
- **Evidence claims are a mechanical proxy:** they verify the attribution chain, not semantic deducibility — human review remains the authority (capture review window, commit review). A detector could record a technically-true but misleading claim (e.g. wrong value) that passes the check.
- **pi provider/model detection is a placeholder** (`PI_PROVIDER`/`PI_MODEL` defaults, model detection TODO) — claims surface it honestly but real pi model detection is a follow-up.
- **`from-capture` is fragile and token-consuming:** depends on the harness running headless AND the model executing the capture command; a hang (600s timeout) or refusal re-queues and spends tokens — capped at 3 attempts then dequeue + warn. `from-raw`/`from-ids` are the safe defaults; capture jobs require user confirmation.
- **`from-raw` overhead is a live trade-off:** its machinery (2a/2b/2h) exists only to serve this path; removal is deliberately deferred to a full-impact follow-up.
- **Control is uniform across platforms:** the `fixtures/daemon.ctl` protocol (`pause` / `resume` / `stop`) is the single mechanism on macOS/Linux/Windows; signals are not relied on beyond terminal Ctrl+C. The ctl write must be a small, atomic-enough single write for the 1s poll (daemon clears after reading); the file lives in `fixtures/` (gitignored, alongside `daemon.log`).

## Follow-ups (logged, not faked)

- ~~**kilo live-session evidence:**~~ **DONE (2026-08-11)** — `detectKiloFromDb` now records session observations + evidence claims for the provider/model resolved from `~/.local/share/kilo/kilo.db`.
- ~~**pi real model detection:**~~ **DONE (2026-08-11)** — `detectPi` reads the real `~/.pi/agent/settings.json` (`defaultProvider`/`defaultModel`) when `PI_PROVIDER`/`PI_MODEL` are unset, plus the `moonshotai → kimi` provider mapping; verified via sandboxed captures.
- **Any other custom evidence source** the detector audit turns up gets the same treatment: claimed if it maps to env/config/session shapes, logged here if it does not. (opencode.db session-db fallback added 2026-08-11.)
- **Consider removing `refresh-cooked-from-raw`:** still deferred to a full-impact follow-up. Weigh: fabricated evidence vs the "real captures, not synthetic assemblies" contract (main.zig:2013); the machinery overhead (2a/2b/2h) serving only this path; the loss of the only zero-token automated `detect()` integration coverage and what replaces it (in-process `detect()` regression test); whether `from-ids` + `from-capture` + contributor captures can cover the matrix.
- **Docker isolation for harness installs/runs — explicitly NOT adopted (2026-08-11):** containers would not give genuine macOS/Windows captures (platform evidence must come from the real host run); the sandboxed worker HOME + user-only daemon already isolate runs from host config. Recorded so the idea is not re-raised without revisiting this rationale.
- **Evergreen top-50 cache maintenance:** `docs/evergreen-top50-models.txt` is a curated snapshot of the coalesced evergreen set; refresh it when the leaderboards shift materially (it gates future bulk additions).
- **Cross-harness provider expansion:** the free evergreen providers are configured on omp only; expanding kilo/kimi/qwen/mmx/crush/vibe/cline/pi/opencode/goose requires the user to add those providers to each harness first (then the identical batch pattern applies).
- **Real `from-capture` for the remaining capturable combos** (kilo, kimi, qwen, mmx, crush, vibe, goose, opencode free-tier extras): user-confirmed, token-consuming; run via the launchd daemon when the user green-lights them.

## Out of scope

- Claw / pending harnesses (claude, continue/cody/windsurf, grok).
- Removing or re-capturing existing closed-model fixtures.
- Running `--from-capture` jobs (token-consuming) as part of the matrix build — infra + launch specs are in (every harness has one now); real capture-mode sweeps are user-confirmed follow-ups.
- Expanding the free evergreen providers (zenmux, siliconflow, etc.) onto harnesses other than omp until those harnesses are configured with them.
- `jcode` (dropped 2026-08-11).
