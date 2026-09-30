# The quality & doctrine pass — green builds, honest evidence, folded aliases

Written 2026-09-30, on the linux host, on `main`. Session scope: fix the `zig build test`
green-run noise, sweep the zig sources for quality/lint debt, then verify and resolve the four
doctrine/code findings that survived the sweep (reciprocity comment-vs-row pairs, the dashscope
host mapping, goose's evidence attribution, the capture-failure classifier) — plus the
`-latest` alias policy.

## the noise fix

`zig build test` printed a red `failed command:` block on a fully passing run (exit 0, 120/120).
Not host noise: zig 0.16's build runner pipes its test binaries' stderr and re-dumps whatever was
captured under the banner **even for successful steps** — the banner glues the captured head right
after `+- run test` with no separator (the phantom "run test w" was the captured stderr's first
line). The trigger: the fixture-hygiene reminder prints in `known_fixtures.test.zig` (128 WARNING
lines on the ollama→ollamacloud transition) wrote to stderr on a success path. They now gate on
`warningsTerminal()` (stderr is a live terminal), so terminal runs (`zig test`, ptys) keep the
reminders and the build runner's pipe stays empty. The gotcha lives in `zig.md`.

## the sweep (fixed outright)

- Unchecked JSON union accesses panicked on malformed user configs (`detectQwen` / `detectPi` /
  `detectCrushFromCrushJson`) — guarded per the sibling detectors' pattern.
- Zombie children on drain failure now reaped (`kiloSqliteJson`, `gitConfigUsername`); the capture
  daemon no longer leaks its workdir on pre-spawn returns (defer moved to creation) and closes the
  worker-log handle on spawn failure.
- `detectGoose` tracks per-dim evidence sources (decision #11): the shared `src` stamp
  misattributed which channel resolved which dim whenever the two dims came from different
  channels (env + config mixes misattributed both ways).
- `detectHermes`'s bare-model branch credited its provider evidence claim to `HERMES_MODEL` with
  the model's value — now `HERMES_PROVIDER` with the provider value.
- `stderrLinesFor`'s exit-8 branches emitted the bare `unable to detect unspecified agent` prefix;
  the CLI prints the full dims block — unified, the exit_statuses pin updated to the byte-literal.
- `classifyCaptureFailure` probed only the first 512 bytes though its doc promises the full
  combined text — full-length case-insensitive probes now (late-appearing harness error markers
  classified as `.other` and lost their session skip).
- Dead code out: `buildTrailer`, `buildJson`'s three discarded params, the unused license consts,
  the unused kernel32 termination externs + dev aliases, eight unused message/exit aliases.
  `writeReasonsCompact` reuses `reasonCompactLine`; the OOM exit prints its registry message.
- Stale `raw`-action remnants (the help line + comments + DESIGN.md — the action was renamed to
  `found`); `fixtures --help` now lists exits 9/10; `zig fmt` canonical on `build.zig` +
  `rules.zig`; the default `zig build` no longer installs `agent-detect-dev` (the `dev` step does).

## doctrine resolutions (verified, not guessed)

1. **Reciprocity comment-vs-row pairs** — the rows were right; the comments argued from the
   retired "opt-in-by-model" rule. CONTRIBUTING's "Model-intrinsic training (the opt-in-by-model
   successor)" puts model-reachable-only training on the model rules (and names OpenRouter/
   OpenCode as the corrected precedent), while tier-spanning training stays at the provider
   (the google/nvidia precedent) with the billing rule making it `opt-out`. Comments rewritten to
   current doctrine; `mimo-v2.5` gained the zen free-period routing it was missing
   (`open_training = "opt-out"` — informational; the conjunct consumes only the closed axis).
2. **dashscope hosts** — the repo's own doctrine (qwen rule + alibaba rule) splits the surfaces:
   the qwen.ai consumer tier (enforced) rides `portal.qwen.ai`; Model Studio's
   `dashscope.aliyuncs.com/compatible-mode` and the Coding Plan's `coding.dashscope.aliyuncs.com`
   are the never/never alibaba surfaces (endpoint research confirms the three hosts). The
   `providerForBaseUrl` table sent every dashscope host to `qwen` (enforced → exit 10) — now
   `coding.dashscope → alibaba-coding-plan`, `dashscope → alibaba`. The two committed
   `qwen-qwen-*` fixtures were captured against dashscope compatible-mode and keep provider
   `qwen` until the refresh flow re-keys them (the ollama-individuation transition class).
3. **mistral `-latest`** — policy established (CONTRIBUTING "Floating aliases are ephemeral"):
   fold as variations, never rules, with a `known_fixtures` guard failing any `-latest` rule name.
   Executed: `mistral-small-latest` folded into `mistral-small-3` (rule deleted);
   `mistral-large-latest` folded into a new stamped `mistral-large-3`; the providermodel grid's
   columns moved to the canonical dims with the served spellings kept as cell values; the coverage
   test accepts alias spellings as covering the folded rule (no fixture-file churn — the next
   queue sweep re-keys naturally).

## live-system note

The maintainer's `fixtures daemon` was running during the table changes and minted the first
from-identity declarations for the newly feasible mistral combos
(`{cline,opencode,pi,vibe}-mistral-mistralsmall3-linux`); they are committed with the rule change,
and the drain continues outside the session.

## files

- `src/known_fixtures.test.zig` + `zig.md` — the noise fix and its gotcha.
- `src/lib/core.zig`, `src/dev/dev.zig`, `src/main.zig`, `build.zig`, `DESIGN.md`,
  `src/index_store.test.zig`, `src/exit_statuses.test.zig` — the sweep.
- `src/lib/rules.zig`, `fixtures/map-provider-model-providermodel.csv`, `CONTRIBUTING.md`, the
  coverage/enforcement tests, the daemon's minted declarations — the doctrine pass.
- `.plans/1790728695925-quality-doctrine-pass*` — this plan.

## provenance

Every prompt that shaped this plan is recorded verbatim in the companion file
`.plans/1790728695925-quality-doctrine-pass.prompts.md`. Agent model: GLM-5.3 Flash (reported by
the harness).
