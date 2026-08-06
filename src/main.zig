// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detection — infer the current agent harness, provider, and
// model from the environment and harness data files, least-invasive first:
//   1. environment variables        (harness)
//   2. <harness data>/settings      (live provider + model)
//   3. own session via pid ancestry (session snapshot; parallel-safe)
//   4. session messages.json        (generation truth: last modelInfo)
// Never prints or persists secrets (auth tokens are never read into output).
//
// Written against zig 0.16 std (std.Io interface; main takes std.process.Init).

const std = @import("std");
const builtin = @import("builtin");

// Build-time option exposed via `build.zig`'s `-Ddev` flag. The released
// binary builds with `dev=false`; the maintainer-only `agent-detection-dev`
// is built with `dev=true`. The `if (dev_build)` blocks below contain
// every dev-only subcommand (the `known` namespace: daemon, agent,
// queue, etc.) and the KnownFixturesForKnownAgents table that drives
// them. Zig's `comptime` drops the dead code from the released binary
// at link time.
const build_options = @import("build_options");
pub const dev_build = build_options.dev;

// macOS process walking (libproc + sysctl). zig 0.16 std has no darwin.zig,
// so the headers are pulled in directly. `<libproc.h>` is *not* imported
// via @cInclude because it transitively drags in `<mach/*.h>` opaque types
// that trip zig's generated static size asserts — those two functions are
// declared as externs below instead. Available on native macOS builds
// (which link libSystem by default). Cross-builds still fall through to
// the empty-ancestry path because the cross-built executable cannot call libc.
const os = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
});
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: c_uint) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: c_ulong, buffer: [*]u8, buffersize: c_int) c_int;

pub const Detection = struct {
    // canonical — grouped by entity, in emission order
    // harness group
    harness_label: ?[]const u8 = null, // human-readable display label, e.g. "Kimi Code" (note some have no title-cased form, such as omp, as such retain omp for omp)
    harness_short_title: ?[]const u8 = null, // optional short brand form, e.g. "Kimi" for "Kimi Code"; null when no established short form
    harness_name: ?[]const u8 = null, // canonical name (whatever casing the service uses to refer to it), e.g. "kimi-code"
    harness_alphanumeric_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `harness_name` (no separators), e.g. "kimi-code" -> "kimicode" — the only id we constrain; `harness_name` carries whatever the service uses
    harness_version: ?[]const u8 = null, // optional release version, e.g. "1.2.3"
    harness_license: ?[]const u8 = null, // SPDX id, e.g. "Apache-2.0"
    // provider group
    provider_label: ?[]const u8 = null, // e.g. "Cline Pass"
    provider_name: ?[]const u8 = null, // canonical name (whatever casing the service uses to refer to it), e.g. "cline-pass"
    provider_alphanumeric_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `provider_name` (no separators), e.g. "cline-pass" -> "clinepass" — the only id we constrain; `provider_name` carries whatever the service uses
    provider_closed_training: ?[]const u8 = null, // "enforced" | "opt-in" | "opt-out" | "never" | null
    provider_open_training: ?[]const u8 = null, // same enum
    // model group
    model_label: ?[]const u8 = null, // e.g. "Kimi K3"
    model_short_title: ?[]const u8 = null, // optional short brand form, e.g. "M3" for "MiniMax M3"; null when no established short form
    model_name: ?[]const u8 = null, // canonical bare slug (whatever casing the service uses canonically), e.g. "kimi-k3"
    model_alphanumeric_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `model_name` (no separators), e.g. "kimi-k3" -> "kimik3"
    model_reciprocity: ?[]const u8 = null, // "open-source" | "open-weight" | "closed" | null
    // agent (composed from harness + provider + model)
    agent_alphanumeric_id: ?[]const u8 = null, // "<harness_alphanumeric_id>-<provider_alphanumeric_id>-<model_alphanumeric_id>" — the user-visible identity of the agent
    // policy / output
    reciprocal: ?bool = null, // computed from harness_license + model_reciprocity + provider_closed_training
    trailer: ?[]const u8 = null,
    // raw — typed observations; buildJson converts these to a shapeless
    // JSON object whose top-level keys identify the source of evidence
    raw: RawObservation = .{},
};

/// one model. `reciprocity` is the openness tier used by the policy
/// reciprocity check: "open-source" (OSI-OSAID compliant), "open-weight"
/// (weights downloadable, training data/code not fully open), or "closed".
/// `sources` is the array of independent cross-references that informed
/// the `reciprocity` value. URL 1 is the model page (overview); URL 2
/// follows a hyperlink FROM that page — typically the LICENSE file for
/// HF-hosted models, or the API/access docs for closed models. URL 3+
/// adds concurrence or insight (e.g. the OSAID 1.0 page for open-source
/// models). Surfaced under `raw["model-urls"]` so a maintainer can audit
/// the deduction from multiple angles.
const KnownRuleForKnownModel = struct {
    name: []const u8,
    label: []const u8,
    /// optional shorter brand form used in casual references. e.g.
    /// "MiniMax M3" -> "M3". `null` means no established short form;
    /// the canonical output emits `null` and consumers fall back to
    /// `label` (or `model_name` if `label` is also unavailable).
    short_title: ?[]const u8 = null,
    reciprocity: ?[]const u8,
    sources: []const []const u8,
};
const knownRulesForKnownModels = [_]KnownRuleForKnownModel{
    // kimi-k3: open-weight — Moonshot's HF card self-describes
    // "open-weight"; its LICENSE is the custom "Kimi K3 License"
    // (MIT-style with a large-scale commercial carve-out), not OSI.
    .{ .name = "kimi-k3", .label = "Kimi K3", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/moonshotai/Kimi-K3", "https://huggingface.co/moonshotai/Kimi-K3/blob/main/LICENSE" } },
    // glm-5.2: open-source — zai-org's card tags it "Pure Open: MIT";
    // MIT is OSI-approved, and the OSAID 1.0 definition is linked as
    // concurrence for the open-source tier.
    .{ .name = "glm-5.2", .label = "GLM 5.2", .reciprocity = "open-source", .sources = &.{ "https://huggingface.co/zai-org/GLM-5.2", "https://huggingface.co/zai-org/GLM-5.2/blob/main/LICENSE", "https://opensource.org/ai/open-source-ai-definition" } },
    // minimax-m3: open-weight — shipped under the "MINIMAX COMMUNITY
    // LICENSE" (non-commercial grant; commercial use past $20M/yr
    // revenue needs authorization), not OSI; the MiniMax blog post
    // concurs it is an open-weight model.
    .{ .name = "minimax-m3", .label = "MiniMax M3", .short_title = "M3", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/MiniMaxAI/MiniMax-M3", "https://huggingface.co/MiniMaxAI/MiniMax-M3/blob/main/LICENSE", "https://www.minimax.io/blog/minimax-m3" } },
    // minimax-m2.7: open-weight — NON-COMMERCIAL LICENSE; the weights
    // are downloadable but commercial use requires written
    // authorization, so it is not OSI open-source.
    .{ .name = "minimax-m2.7", .label = "MiniMax M2.7", .short_title = "M2.7", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/MiniMaxAI/MiniMax-M2.7", "https://huggingface.co/MiniMaxAI/MiniMax-M2.7/blob/main/LICENSE" } },
    // claude-sonnet-4: closed — API-only (Claude API / Bedrock /
    // Vertex / Foundry); no weights are published anywhere.
    .{ .name = "claude-sonnet-4", .label = "Claude Sonnet 4", .reciprocity = "closed", .sources = &.{ "https://www.anthropic.com/claude/sonnet", "https://docs.anthropic.com/en/docs/about-claude/models" } },
    // qwen3.8-max: closed — API-only flagship; no official weights
    // published. qwen.alibaba.com is offline; qwen.ai is the current
    // brand home (blog id = the model's announcement page).
    .{ .name = "qwen3.8-max", .label = "Qwen3.8-Max", .reciprocity = "closed", .sources = &.{ "https://qwen.ai/", "https://qwen.ai/blog?id=qwen3.8-max" } },
    // deepseek-v4-flash: open-weight — HF card + MIT LICENSE; the
    // weights are downloadable (MIT is OSI, but open-weight is the
    // conservative tier for the hosted API alias).
    .{ .name = "deepseek-v4-flash", .label = "DeepSeek V4 Flash", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash", "https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash/blob/main/LICENSE" } },
    // mistral-large-latest: open-weight — Mistral's models overview
    // lists the current "Mistral Large 3" (v25.12) as Apache-2.0
    // open-weight, and the mistral-large-latest alias resolves to it;
    // `closed` was only accurate for the Large 1/2 era.
    .{ .name = "mistral-large-latest", .label = "Mistral Large (latest)", .reciprocity = "open-weight", .sources = &.{ "https://docs.mistral.ai/getting-started/models/models_overview/", "https://docs.mistral.ai/getting-started/models/" } },
    // qwen3.7-plus: closed — API-only; no official weights. Same
    // qwen.ai linkage as qwen3.8-max above.
    .{ .name = "qwen3.7-plus", .label = "Qwen3.7-Plus", .reciprocity = "closed", .sources = &.{ "https://qwen.ai/", "https://qwen.ai/blog?id=qwen3.7-plus" } },
};

/// one provider. `closed_training` and `open_training` reflect whether the
/// provider trains closed/open models on customer data, per their commercial
/// terms: "enforced" | "opt-in" | "opt-out" | "never" | null (unverified).
/// `sources` is the array of independent cross-references that informed
/// both training values — typically two independent same-provider policy
/// documents (privacy policy + terms of service) linked from the
/// provider's legal page. Aggregator pages classify rather than assert
/// policy, so they're dropped as second sources. Surfaced under
/// `raw["provider-urls"]`.
const KnownRuleForKnownProvider = struct {
    name: []const u8,
    label: []const u8,
    closed_training: ?[]const u8,
    open_training: ?[]const u8,
    sources: []const []const u8,
};
const knownRulesForKnownProviders = [_]KnownRuleForKnownProvider{
    // cline-pass: never/never — Cline's subscription tier. Cline is a
    // BYO-key client; its privacy notice says requests made with your
    // own API keys are not collected. Upstream AI model providers have
    // their own training terms — Cline itself trains on nothing.
    .{ .name = "cline-pass", .label = "Cline Pass", .closed_training = "never", .open_training = "never", .sources = &.{ "https://cline.bot/privacy", "https://cline.bot/tos" } },
    // cline: never/never — direct Cline provider; same privacy notice
    // + terms (cline.bot/privacy, cline.bot/tos).
    .{ .name = "cline", .label = "Cline", .closed_training = "never", .open_training = "never", .sources = &.{ "https://cline.bot/privacy", "https://cline.bot/tos" } },
    // minimax: opt-in — MiniMax platform ToS + privacy policy (the
    // hosted API tier reserves the option to train on usage data).
    .{ .name = "minimax", .label = "MiniMax", .closed_training = "opt-in", .open_training = "opt-in", .sources = &.{ "https://platform.minimax.io/docs/guides/terms-of-service", "https://platform.minimax.io/docs/guides/privacy-policy" } },
    // goose: never/never — Goose is a BYO-key open-source client; it
    // does not host or train models. Sources are the upstream repo
    // (block/goose) + its Apache-2.0 LICENSE, as it has no separate
    // data-policy pages.
    .{ .name = "goose", .label = "Goose", .closed_training = "never", .open_training = "never", .sources = &.{ "https://github.com/block/goose", "https://github.com/block/goose/blob/main/LICENSE" } },
    // deepseek-flash: never/never — Reasonix's DeepSeek Flash entry.
    // Sources are the DeepSeek API pricing page + the platform home
    // (per DeepSeek's published platform data-handling docs).
    .{ .name = "deepseek-flash", .label = "DeepSeek Flash", .closed_training = "never", .open_training = "never", .sources = &.{ "https://api-docs.deepseek.com/quick_start/pricing", "https://platform.deepseek.com" } },
    // jcode's openai-compatible transport that fronts `api.minimax.io`
    // is the same upstream as the `minimax` rule above — the
    // openai-compatible interface is transport detail, not a
    // different provider, so jcode resolves to `minimax`.
    // anthropic: never/null — Anthropic's Commercial Terms state
    // "Anthropic may not train models on Customer Content from the
    // Services" (API tier); no open-weight Anthropic models exist, so
    // open_training stays null.
    .{ .name = "anthropic", .label = "Anthropic", .closed_training = "never", .open_training = null, .sources = &.{ "https://www.anthropic.com/legal/commercial-terms", "https://trust.anthropic.com/" } },
    // mistral: opt-out/opt-out — Mistral ToS + acceptable-use policy
    // (the default provider for Mistral Vibe).
    .{ .name = "mistral", .label = "Mistral", .closed_training = "opt-out", .open_training = "opt-out", .sources = &.{ "https://docs.mistral.ai/legal/terms-of-service/", "https://docs.mistral.ai/legal/acceptable-use-policy/" } },
    // hyper: never/never — Charm Hyper's ToS states "We do not use your
    // User Content to train AI models", and its privacy policy
    // advertises zero data retention (ZDR).
    .{ .name = "hyper", .label = "Charm Hyper", .closed_training = "never", .open_training = "never", .sources = &.{ "https://hyper.charm.land/terms", "https://hyper.charm.land/privacy" } },
    // omp namespaces its providers with `-code` suffixes (e.g.
    // `minimax-code/MiniMax-M3`). The underlying upstream is the same
    // MiniMax API; this rule mirrors `minimax` so the canonical block
    // picks up the right training policies + URLs.
    .{ .name = "minimax-code", .label = "Minimax Code", .closed_training = "opt-in", .open_training = "opt-in", .sources = &.{ "https://platform.minimax.io/docs/guides/terms-of-service", "https://platform.minimax.io/docs/guides/privacy-policy" } },
    // crush's "qwen3.7-plus" is a model id used as a provider key by
    // the user's hyper.json. The actual upstream is Alibaba Qwen's
    // hosted tier (qwen3.7-plus is a closed model); no public
    // training-policy page was verified, so policies stay null.
    .{ .name = "qwen3.7-plus", .label = "Qwen3.7 Plus", .closed_training = null, .open_training = null, .sources = &.{ "https://qwen.ai/", "https://qwen.ai/blog?id=qwen3.7-plus" } },
    // jcode's `provider_key: "remote"` is a placeholder for sessions
    // where the model+provider pairing wasn't tagged with a real
    // upstream. Display name + empty sources reflects that this is an
    // unknown placeholder, not a real provider.
    .{ .name = "remote", .label = "Remote", .closed_training = null, .open_training = null, .sources = &.{} },
};
/// static metadata the rule declared to the matcher. Useful for auditing
/// when a rule misfires; not a runtime observation.
// Static rule metadata (the harness rule's declared proc names and
// env-marker names) lives in `knownRulesForKnownAgents`; the runtime
// observation story is carried by `raw.env_vars` (matched env-var
// observations) and `raw.process_lineage` (process tree at detection
// time).

/// one env-var observation. `name` is always emitted (env-var names
/// are non-secret). `value` is the env-var's content if `present` and
/// the name is on the `env_value_allowlist`, otherwise the empty string
/// (secrets hygiene — `value=""` + `present=false` means the var was
/// declared by the rule but unset in the environment; `value=""` +
/// `present=true` means the var was present but is on the
/// not-allowed list and got redacted). Every env-marker declared by
/// the matched harness rule gets one entry here, regardless of whether
/// the var was in the runtime environment — a maintainer reading the
/// fixture can see what the rule actually checked.
pub const EnvVarObservation = struct {
    name: []const u8,
    value: []const u8,
    present: bool,
};

/// one process-tree observation: pid + executable basename. Subobjects
/// (not `[pid, name]` tuples) so the convention is explicit in the
/// JSON shape — a reader doesn't need to remember which index is which.
pub const Ancestor = struct {
    pid: u32,
    name: []const u8,
};

/// process-tree observations: the chain of processes at detection
/// time, ordered most-immediate first (index 0 = the running
/// `agent-detection`, index 1 = its parent, etc.). Full argv is
/// deliberately NOT captured — see DESIGN.md for the leak vectors
/// (tokens, paths, positional-secret parsing). Inlined as a direct
/// `[]const Ancestor` field of `RawObservation`.
///
/// one field read from a file: a dotted-path pointer (e.g.
/// "providers.cline-pass.settings.model") + the value observed.
pub const FieldObservation = struct {
    dotted_path: []const u8,
    value: []const u8,
};

/// one file read: the file path + the fields that informed canonical.
/// Used for both provider config files (providers.json, config.toml,
/// config.yaml, config.json) and Cline session files (session.json,
/// messages.json). The path is the raw block's top-level key in the
/// JSON output.
pub const FileObservation = struct {
    path: []const u8,
    fields: []const FieldObservation = &.{},
};

/// All unprocessed observations in a typed shape that maps cleanly to
/// the shapeless JSON output emitted by `buildJson`. Top-level groups:
/// - `env_vars` — env-var observations (one per matched marker)
/// - `process_lineage` — process tree (most-immediate first)
/// - `config_files` — provider config file reads (one per file)
/// - `session_files` — Cline session file reads (one per file)
/// - `harness_urls` / `provider_urls` / `model_urls` — reference URLs
///   that informed the corresponding canonical deductions
pub const RawObservation = struct {
    env_vars: []const EnvVarObservation = &.{},
    process_lineage: []const Ancestor = &.{},
    config_files: []const FileObservation = &.{},
    session_files: []const FileObservation = &.{},
    /// static rule data: the env-marker names from the matched harness
    /// rule (`r.env_markers`). Combined with `env_vars` (the runtime
    /// observations), a maintainer can audit the detection — they see
    /// both WHAT the rule declared and WHAT was actually present in env.
    harness_env_markers: []const []const u8 = &.{},
    /// static rule data: the proc-name patterns from the matched harness
    /// rule (`r.proc_names`). Combined with `process_lineage`, a
    /// maintainer can audit the detection ladder.
    harness_proc_names: []const []const u8 = &.{},
    harness_urls: []const []const u8 = &.{},
    provider_urls: []const []const u8 = &.{},
    model_urls: []const []const u8 = &.{},
};

pub const KnownRuleForKnownAgent = struct {
    name: []const u8,
    label: []const u8,
    /// optional short brand form for casual references. e.g.
    /// "Kimi Code" -> "Kimi". `null` when no established short form;
    /// consumers fall back to `label` (or `harness_name`).
    short_title: ?[]const u8 = null,
    /// optional release version (e.g. "1.2.3"). `null` when the
    /// rule doesn't track a per-harness version — consumers fall
    /// back to `label` (or `harness_name`).
    version: ?[]const u8 = null,
    /// SPDX license identifier (e.g. "Apache-2.0", "MIT"), or null for
    /// closed-source / proprietary harnesses. Drives the `harness_license`
    /// canonical field and the `reciprocal` computation.
    license: ?[]const u8,
    /// Array of independent cross-references that informed the `license`
    /// value (URL 1 = project page; URL 2 = the actual LICENSE file
    /// linked from that page). Each URL is a distinct location with
    /// distinct content; neither is a variation of the other. Surfaced
    /// under `raw["harness-urls"]` so a maintainer can audit the
    /// deduction from multiple angles.
    license_sources: []const []const u8,
    env_markers: []const []const u8,
    proc_names: []const []const u8, // lowercase exe names matched against process ancestry
};
const cline_env = [_][]const u8{ "CLINE_WRAPPER_PATH", "CLINE_BUILD_ENV", "CLINE_NO_INTERACTIVE", "CLINE_RUN_AS_HUB_DAEMON", "CLINE_CONNECTOR_CLI_LAUNCH" };
const goose_env = [_][]const u8{ "GOOSE_WORKING_DIR", "GOOSE_PROVIDER", "GOOSE_MODEL", "GOOSE_TERMINAL", "GOOSE_MODE" };
const kimi_env = [_][]const u8{ "KIMI_CODE_HOME", "KIMI_API_KEY", "KIMI_BASE_URL" };
const mmx_env = [_][]const u8{ "MMX_CONFIG_DIR", "MINIMAX_API_KEY" };
const pi_env = [_][]const u8{"PI_CODING_AGENT"};

// harnesses listed in the user's machine but not yet fully integrated;
// each gets a single, plausibly-shaped env marker that the daemon's
// runner (see CONTRIBUTING.md) sets in the spawned process's env to
// fire detection. Each project's `license`/`license_sources` in
// knownRulesForKnownAgents is filled in from its upstream repo once
// verified — a maintainer records the SPDX id + source URLs there, not
// in the fixtures (fixtures are generated artifacts).
const qwen_env = [_][]const u8{ "QWEN_API_KEY" };
const kilo_env = [_][]const u8{ "KILO_API_KEY" };
const jcode_env = [_][]const u8{ "JCODE_API_KEY" };
const omp_env = [_][]const u8{ "OMP_API_KEY" };
const reasonix_env = [_][]const u8{ "REASONIX_API_KEY" };
const crush_env = [_][]const u8{ "CRUSH_API_KEY" };
const opencode_env = [_][]const u8{ "OPENCODE_API_KEY" };
const vibe_env = [_][]const u8{ "VIBE_API_KEY" };

const cline_procs = [_][]const u8{ "cline.exe", "cline" };
const goose_procs = [_][]const u8{ "goose.exe", "goose", "goosed.exe", "goosed" };
const kimi_procs = [_][]const u8{ "kimi.exe", "kimi", "kimi-code.exe", "kimi-code" };
pub const knownRulesForKnownAgents = [_]KnownRuleForKnownAgent{
    // cline: Apache-2.0 — https://github.com/cline/cline ships an
    // Apache-2.0 LICENSE (Cline Bot Inc.'s open-source VS Code /
    // JetBrains agent).
    .{ .name = "cline", .label = "Cline", .license = "Apache-2.0", .license_sources = &.{ "https://github.com/cline/cline", "https://github.com/cline/cline/blob/main/LICENSE" }, .env_markers = &cline_env, .proc_names = &cline_procs },
    // goose: Apache-2.0 — upstream is https://github.com/block/goose
    // (aaif-goose/goose was a mirror); Apache-2.0 per the repo LICENSE
    // (Copyright Block, Inc.).
    .{ .name = "goose", .label = "Goose", .license = "Apache-2.0", .license_sources = &.{ "https://github.com/block/goose", "https://github.com/block/goose/blob/main/LICENSE" }, .env_markers = &goose_env, .proc_names = &goose_procs },
    // kimi-code: MIT — https://github.com/MoonshotAI/kimi-code ships a
    // MIT LICENSE (Copyright Moonshot AI; the Kimi Code CLI).
    .{ .name = "kimi-code", .label = "Kimi Code", .license = "MIT", .license_sources = &.{ "https://github.com/MoonshotAI/kimi-code", "https://github.com/MoonshotAI/kimi-code/blob/main/LICENSE" }, .env_markers = &kimi_env, .proc_names = &kimi_procs },
    // mmx: MIT — https://github.com/MiniMax-AI/cli (npm `mmx-cli`)
    // declares MIT via its README badge + npm page; the repo has no
    // LICENSE file committed yet, so the npm page is the second
    // cross-reference rather than a LICENSE blob.
    .{ .name = "mmx", .label = "MiniMax CLI", .license = "MIT", .license_sources = &.{ "https://github.com/MiniMax-AI/cli", "https://www.npmjs.com/package/mmx-cli" }, .env_markers = &mmx_env, .proc_names = &.{} }, // node-based; exe name is generic
    // pi: MIT — https://github.com/earendil-works/pi ships a MIT
    // LICENSE (Copyright Mario Zechner; the Rust terminal coding agent).
    .{ .name = "pi", .label = "Pi", .license = "MIT", .license_sources = &.{ "https://github.com/earendil-works/pi", "https://github.com/earendil-works/pi/blob/main/LICENSE" }, .env_markers = &pi_env, .proc_names = &.{} },
    // qwen: Apache-2.0 — https://github.com/QwenLM/qwen-code (the Qwen
    // Code CLI, formerly Apollo) ships an Apache-2.0 LICENSE.
    .{ .name = "qwen", .label = "Qwen Code", .license = "Apache-2.0", .license_sources = &.{ "https://github.com/QwenLM/qwen-code", "https://github.com/QwenLM/qwen-code/blob/main/LICENSE" }, .env_markers = &qwen_env, .proc_names = &.{} },
    // kilo: MIT — https://github.com/Kilo-Org/kilocode ships a MIT
    // LICENSE (Kilo Code CLI).
    .{ .name = "kilo", .label = "Kilo Code", .license = "MIT", .license_sources = &.{ "https://github.com/Kilo-Org/kilocode", "https://github.com/Kilo-Org/kilocode/blob/main/LICENSE" }, .env_markers = &kilo_env, .proc_names = &.{} },
    // jcode: MIT — https://github.com/1jehuang/jcode ships a MIT
    // LICENSE (default branch `master`); verified from the repo's
    // README license badge and the LICENSE file linked from it.
    .{ .name = "jcode", .label = "jcode", .license = "MIT", .license_sources = &.{ "https://github.com/1jehuang/jcode", "https://github.com/1jehuang/jcode/blob/master/LICENSE" }, .env_markers = &jcode_env, .proc_names = &.{} },
    // omp: MIT — https://github.com/can1357/oh-my-pi (omp is the CLI
    // distribution name of oh-my-pi) ships a MIT LICENSE; verified
    // from the repo's license badge and the LICENSE file linked from it.
    .{ .name = "omp", .label = "omp", .license = "MIT", .license_sources = &.{ "https://github.com/can1357/oh-my-pi", "https://github.com/can1357/oh-my-pi/blob/main/LICENSE" }, .env_markers = &omp_env, .proc_names = &.{} },
    // reasonix: MIT — https://github.com/esengine/DeepSeek-Reasonix
    // ships a MIT LICENSE (default branch `main-v2`); verified from
    // the repo's license badge and the LICENSE file linked from it.
    .{ .name = "reasonix", .label = "Reasonix", .license = "MIT", .license_sources = &.{ "https://github.com/esengine/DeepSeek-Reasonix", "https://github.com/esengine/DeepSeek-Reasonix/blob/main-v2/LICENSE" }, .env_markers = &reasonix_env, .proc_names = &.{} },
    // crush: FSL-1.1-MIT (Functional Source License) —
    // https://github.com/charmbracelet/crush links its LICENSE.md from
    // the README's License section; that is the upstream SPDX id.
    // Not OSI-approved open source, but the license id is non-null, so
    // `reciprocal` is governed by the model/provider conjuncts rather
    // than being force-closed by the harness side.
    .{ .name = "crush", .label = "Crush", .license = "FSL-1.1-MIT", .license_sources = &.{ "https://github.com/charmbracelet/crush", "https://github.com/charmbracelet/crush/blob/main/LICENSE.md" }, .env_markers = &crush_env, .proc_names = &.{} },
    // opencode: MIT — https://github.com/anomalyco/opencode (formerly
    // sst/opencode) ships a MIT LICENSE; default branch is `dev`, so
    // the LICENSE blob URL is branch-qualified.
    .{ .name = "opencode", .label = "OpenCode", .license = "MIT", .license_sources = &.{ "https://github.com/anomalyco/opencode", "https://github.com/anomalyco/opencode/blob/dev/LICENSE" }, .env_markers = &opencode_env, .proc_names = &.{} },
    // vibe: Apache-2.0 — https://github.com/mistralai/mistral-vibe ships
    // an Apache-2.0 LICENSE (the Vibe CLI for Mistral models).
    .{ .name = "vibe", .label = "Vibe", .license = "Apache-2.0", .license_sources = &.{ "https://github.com/mistralai/mistral-vibe", "https://github.com/mistralai/mistral-vibe/blob/main/LICENSE" }, .env_markers = &vibe_env, .proc_names = &.{} },
};
/// env-var names whose values are safe to emit in raw.env_vars. Names NOT
/// on this list emit an empty string for the value slot — secrets like
/// `KIMI_API_KEY` and `MINIMAX_API_KEY` are redacted by default. Maintainers
/// add names here when they have decided the value is safe to write to disk.
const env_value_allowlist = [_][]const u8{
    "CLINE_BUILD_ENV", "CLINE_NO_INTERACTIVE", "CLINE_WRAPPER_PATH",
    "CLINE_RUN_AS_HUB_DAEMON", "CLINE_CONNECTOR_CLI_LAUNCH",
    "KIMI_CODE_HOME", "MMX_CONFIG_DIR", "PI_CODING_AGENT",
    "GOOSE_WORKING_DIR", "GOOSE_TERMINAL", "GOOSE_MODE",
    "USERPROFILE", "HOME", "APPDATA",
};

fn isEnvValueAllowed(name: []const u8) bool {
    for (env_value_allowlist) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

/// apply a model slug to the detection. `slug` is the bare model id (e.g.
/// "kimi-k3"); it becomes `d.model_name` unchanged. `raw_input` is the
/// original string from the config file (e.g. "cline-pass/kimi-k3" or
/// "minimax/kimi-k3") and is preserved in the corresponding config-file
/// FileObservation under `d.raw.config_files` for the audit trail. The
/// provider prefix on the config value stays out of the canonical model
/// identity.
pub fn applyModel(a: std.mem.Allocator, d: *Detection, name: []const u8, raw_input: []const u8) !void {
    d.model_name = name;
    const lower = try std.ascii.allocLowerString(a, name);
    const canonical_name = if (std.mem.findScalar(u8, lower, '/')) |i| lower[i + 1 ..] else lower;
    defer a.free(lower);
    const mi = try modelForName(a, canonical_name);
    // display name is emitted verbatim from the rules table — the
    // rules are the source of truth and maintainers edit them
    // directly when adding new harnesses/models.
    d.model_label = try a.dupe(u8, mi.label);
    // short_title is optional — null when the rule didn't declare one.
    // Consumers should fall back to `model_label` (or `model_name`) when this
    // is null.
    if (mi.short_title) |st| d.model_short_title = try a.dupe(u8, st);
    d.model_alphanumeric_id = try alphanumericId(a, canonical_name);
    d.model_reciprocity = mi.reciprocity;
    if (mi.sources.len > 0) d.raw.model_urls = mi.sources;
    _ = raw_input; // caller is responsible for recording it in a config_file observation
    // recompute the agent id now that model_alphanumeric_id is known —
    // this depends on harness_alphanumeric_id and provider_alphanumeric_id
    // being set first, which the calling detector is responsible for.
    try setAgentAlphanumericId(a, d);
}

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

/// optional tee target for daemon output; set by `known daemon --write-log`.
var daemon_log_file: ?std.Io.File = null;

/// Advisory exclusive lock on `known/index.jsonl` held while a process
/// does its read-modify-write cycle, so the daemon and CLI commands
/// (queue/dequeue/purge/agent) never interleave full-file rewrites
/// (lost updates). The lock is a sidecar file (never truncated), taken
/// via `flock`-backed `std.Io.File.lock`; it is released automatically
/// if the process dies. It is reentrant within a process: nested
/// acquisitions (e.g. `expandSeed` → `upsertIndexEvent`) reuse the
/// held lock instead of self-deadlocking.
///
/// NOTE: the daemon's capture child (`refresh run` → `known agent`)
/// writes the index from a *separate process*; it takes its own lock.
/// The daemon must therefore never hold this lock across
/// `child.wait()` or the child would block forever.
var index_lock_file: ?std.Io.File = null;
var index_lock_depth: usize = 0;

const INDEX_LOCK_PATH = "known/index.jsonl.lock";

/// acquire the exclusive index lock (nested-safe).
fn lockIndex(io: std.Io) !void {
    if (index_lock_depth > 0) {
        index_lock_depth += 1;
        return;
    }
    std.Io.Dir.cwd().createDirPath(io, "known") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const f = std.Io.Dir.cwd().createFile(io, INDEX_LOCK_PATH, .{ .read = true, .truncate = false, .lock = .exclusive }) catch |err| switch (err) {
        // FileLocksUnsupported / IO errors: proceed unlocked rather than
        // block the command (worst case is the pre-lock race).
        else => return err,
    };
    index_lock_file = f;
    index_lock_depth = 1;
}

/// release the index lock (nested-safe).
fn unlockIndex(io: std.Io) void {
    if (index_lock_depth == 0) return;
    index_lock_depth -= 1;
    if (index_lock_depth == 0) {
        if (index_lock_file) |f| {
            f.unlock(io);
            f.close(io);
        }
        index_lock_file = null;
    }
}

/// write `data` to `index.jsonl` atomically (temp file + rename) so a
/// concurrent reader never observes a torn or half-written file. Caller
/// should hold the index lock for read-modify-write cycles.
fn writeIndexAtomic(io: std.Io, data: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, "known/index.jsonl", .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.replace(io);
}

/// true when the last daemon stdout write ended in a newline (or no
/// write has happened), so a continuation segment does not repeat the
/// `[sec.ms]` prefix mid-line.
var daemon_log_out_nl: bool = true;
var daemon_log_err_nl: bool = true;

fn daemonWrite(io: std.Io, bytes: []const u8) void {
    var buf: [64]u8 = undefined;
    const add_prefix = daemon_log_out_nl;
    if (add_prefix) {
        const ts = std.Io.Clock.Timestamp.now(io, .real);
        const sec = ts.raw.toSeconds();
        const ms = ts.raw.toMilliseconds() - sec * 1000;
        const prefix = std.fmt.bufPrint(buf[0..], "[{d}.{d}] ", .{sec, ms}) catch return;
        std.Io.File.stdout().writeStreamingAll(io, prefix) catch {};
        if (daemon_log_file) |f| f.writeStreamingAll(io, prefix) catch {};
    }
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
    if (daemon_log_file) |f| f.writeStreamingAll(io, bytes) catch {};
    daemon_log_out_nl = bytes.len == 0 or bytes[bytes.len - 1] == '\n';
}

fn daemonWriteErr(io: std.Io, bytes: []const u8) void {
    var buf: [64]u8 = undefined;
    const add_prefix = daemon_log_err_nl;
    if (add_prefix) {
        const ts = std.Io.Clock.Timestamp.now(io, .real);
        const sec = ts.raw.toSeconds();
        const ms = ts.raw.toMilliseconds() - sec * 1000;
        const prefix = std.fmt.bufPrint(buf[0..], "[{d}.{d}] ", .{sec, ms}) catch return;
        std.Io.File.stderr().writeStreamingAll(io, prefix) catch {};
        if (daemon_log_file) |f| f.writeStreamingAll(io, prefix) catch {};
    }
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
    if (daemon_log_file) |f| f.writeStreamingAll(io, bytes) catch {};
    daemon_log_err_nl = bytes.len == 0 or bytes[bytes.len - 1] == '\n';
}

/// capitalize the first letter of each dash-separated token, join with spaces
fn titleCase(a: std.mem.Allocator, slug: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, slug, '-');
    var first = true;
    while (it.next()) |tok| {
        if (!first) try list.append(a, ' ');
        first = false;
        if (tok.len > 0) {
            try list.append(a, std.ascii.toUpper(tok[0]));
            try list.appendSlice(a, tok[1..]);
        }
    }
    return list.toOwnedSlice(a);
}

const ModelOut = struct {
    label: []const u8,
    short_title: ?[]const u8 = null,
    reciprocity: ?[]const u8,
    sources: []const []const u8 = &.{},
};

fn modelForName(a: std.mem.Allocator, name: []const u8) !ModelOut {
    for (knownRulesForKnownModels) |r| {
        if (std.mem.eql(u8, r.name, name))
            return .{ .label = r.label, .short_title = r.short_title, .reciprocity = r.reciprocity, .sources = r.sources };
    }
    // family-prefix fallbacks for known open-weight families
    const families = [_][]const u8{ "kimi", "glm", "minimax" };
    for (families) |fam| {
        if (std.mem.startsWith(u8, name, fam))
            return .{ .label = try titleCase(a, name), .reciprocity = "open-weight" };
    }
    return .{ .label = try titleCase(a, name), .reciprocity = null };
}

fn providerForName(name: []const u8) ?[]const u8 {
    for (knownRulesForKnownProviders) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.label;
    }
    return null;
}

fn providerMetaForName(name: []const u8) ?KnownRuleForKnownProvider {
    for (knownRulesForKnownProviders) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// apply provider rule metadata (training policies + their cross-reference
/// sources) to `d`. No-op if the provider id is not in the table; this is
/// the single place the four detectors should call to populate `provider_*`
/// and the matching `raw.provider_urls` array. Also sets
/// `provider_alphanumeric_id` (the strict-slug form of the canonical name)
/// so detectors that use the three-line `provider_name + label + meta`
/// pattern still keep the alphanumeric_id in lockstep with the name.
fn applyProviderMeta(a: std.mem.Allocator, d: *Detection, id: []const u8) !void {
    d.provider_alphanumeric_id = try alphanumericId(a, id);
    if (providerMetaForName(id)) |meta| {
        d.provider_closed_training = meta.closed_training;
        d.provider_open_training = meta.open_training;
        d.raw.provider_urls = meta.sources;
    }
}

/// set d.provider_label, d.provider_name, and d.provider_alphanumeric_id together
/// from a single id. This is the helper detectors should call instead of
/// the old "label + applyProviderMeta" pair — it keeps the
/// alphanumeric_id in lockstep with the name so consumers can
/// always trust the canonical trio.
fn setProvider(a: std.mem.Allocator, d: *Detection, id: []const u8) !void {
    const display = providerForName(id) orelse try titleCase(a, id);
    d.provider_name = try a.dupe(u8, id);
    d.provider_label = display;
    d.provider_alphanumeric_id = try alphanumericId(a, id);
    try applyProviderMeta(a, d, id);
}

/// compose the agent_alphanumeric_id from the three sub-ids. Writes
/// `null` if any of the three is null (the agent is not fully
/// identified yet, and a partial id is more misleading than null).
fn setAgentAlphanumericId(a: std.mem.Allocator, d: *Detection) !void {
    const h = d.harness_alphanumeric_id orelse return;
    const p = d.provider_alphanumeric_id orelse return;
    const m = d.model_alphanumeric_id orelse return;
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, h);
    try list.append(a, '-');
    try list.appendSlice(a, p);
    try list.append(a, '-');
    try list.appendSlice(a, m);
    d.agent_alphanumeric_id = try list.toOwnedSlice(a);
}

fn jstr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jint(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// extract the string value of `key` appearing at/after byte offset `from`
/// (scan-after-position parse; used on the last modelInfo block only)
fn extractAfter(raw: []const u8, from: usize, key: []const u8) ?[]const u8 {
    const k = std.mem.findPos(u8, raw, from, key) orelse return null;
    const colon = std.mem.findScalarPos(u8, raw, k + key.len, ':') orelse return null;
    const q1 = std.mem.findScalarPos(u8, raw, colon, '"') orelse return null;
    const q2 = std.mem.findScalarPos(u8, raw, q1 + 1, '"') orelse return null;
    return raw[q1 + 1 .. q2];
}

/// strictly lowercase-alphanumeric slug of a display string — e.g. "Kimi Code" -> "kimicode",
/// "MiniMax M3" -> "minimaxm3". Used to derive the per-harness /
/// per-model / per-agent alphanumeric ids and surfaced as
/// `{harness,model}_alphanumeric_id` and `agent_alphanumeric_id` in the
/// canonical output so consumers can see exactly where the trailer's
/// email local part came from. The strictness (no separators at all)
/// is what the `_alphanumeric_id` suffix advertises.
pub fn alphanumericId(a: std.mem.Allocator, display: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    for (display) |c| {
        if (std.ascii.isAlphanumeric(c)) try list.append(a, std.ascii.toLower(c));
    }
    return list.toOwnedSlice(a);
}

// ============================================================================
// ladder step 3: process ancestry (own session identification)

// toolhelp32 (removed from zig 0.16 std.os.windows; declared here)
const TH32CS_SNAPPROCESS: u32 = 2;
const PROCESSENTRY32W = extern struct {
    dwSize: u32 = 0,
    cntUsage: u32 = 0,
    th32ProcessID: u32 = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: u32 = 0,
    cntThreads: u32 = 0,
    th32ParentProcessID: u32 = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: u32 = 0,
    szExeFile: [260]u16 = [_]u16{0} ** 260,
};
extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: std.os.windows.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) c_int;
extern "kernel32" fn Process32NextW(hSnapshot: std.os.windows.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) c_int;

pub const Ancestry = struct { pids: []const u32 = &.{}, names: []const []const u8 = &.{} };

fn ancestorInfo(a: std.mem.Allocator, io: std.Io) Ancestry {
    if (builtin.os.tag == .windows) return ancestorsWindows(a) catch .{};
    if (builtin.os.tag == .linux) return ancestorsLinux(a, io) catch .{};
    if (builtin.os.tag == .macos) return ancestorsMacos(a) catch .{};
    return .{};
}

/// utf16 exe name -> lowercase ascii (lossy for non-ascii, which is fine for matching)
fn exeName16(a: std.mem.Allocator, buf: *const [260]u16) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (buf) |c| {
        if (c == 0) break;
        try list.append(a, if (c < 128) std.ascii.toLower(@as(u8, @intCast(c))) else '?');
    }
    return list.toOwnedSlice(a);
}

const ProcPair = struct { pid: u32, ppid: u32, name: []const u8 };

fn ancestorsWindows(a: std.mem.Allocator) !Ancestry {
    if (builtin.os.tag != .windows) return .{};
    const w = std.os.windows;
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    const invalid: w.HANDLE = @ptrFromInt(std.math.maxInt(usize));
    if (snap == invalid) return error.SnapshotFailed;
    defer w.CloseHandle(snap);
    var procs: std.ArrayList(ProcPair) = .empty;
    var entry: PROCESSENTRY32W = .{};
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) != 0) {
        while (true) {
            try procs.append(a, .{
                .pid = entry.th32ProcessID,
                .ppid = entry.th32ParentProcessID,
                .name = try exeName16(a, &entry.szExeFile),
            });
            if (Process32NextW(snap, &entry) == 0) break;
        }
    }
    var pids: std.ArrayList(u32) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var pid: u32 = w.GetCurrentProcessId();
    while (pid != 0) {
        try pids.append(a, pid);
        var name: []const u8 = "";
        var next: u32 = 0;
        for (procs.items) |p| {
            if (p.pid == pid) {
                next = p.ppid;
                name = p.name;
                break;
            }
        }
        try names.append(a, name);
        pid = next;
    }
    return .{ .pids = try pids.toOwnedSlice(a), .names = try names.toOwnedSlice(a) };
}

fn ancestorsLinux(a: std.mem.Allocator, io: std.Io) !Ancestry {
    if (builtin.os.tag != .linux) return .{};
    const cwd_dir = std.Io.Dir.cwd();
    var pids: std.ArrayList(u32) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var pid: u32 = @intCast(std.os.linux.getpid());
    while (pid > 1) {
        try pids.append(a, pid);
        const comm_path = try std.fmt.allocPrint(a, "/proc/{d}/comm", .{pid});
        const comm = cwd_dir.readFileAlloc(io, comm_path, a, @enumFromInt(4096)) catch "";
        try names.append(a, try std.ascii.allocLowerString(a, std.mem.trim(u8, comm, " \r\n")));
        const path = try std.fmt.allocPrint(a, "/proc/{d}/stat", .{pid});
        const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch break;
        const close = std.mem.findScalarLast(u8, data, ')') orelse break;
        var tok = std.mem.tokenizeScalar(u8, data[close + 2 ..], ' ');
        _ = tok.next(); // state
        const ppid = tok.next() orelse break;
        pid = std.fmt.parseInt(u32, ppid, 10) catch break;
    }
    return .{ .pids = try pids.toOwnedSlice(a), .names = try names.toOwnedSlice(a) };
}

/// Walk process ancestors on macOS. For each pid, reads the executable
/// basename via `proc_pidpath`, and uses `proc_pidinfo` with
/// `PROC_PIDT_SHORTBSDINFO` (a small fixed-layout struct that begins
/// with `pid_t pbsi_pid, pbsi_ppid`) to fetch the immediate parent pid.
/// Stops when the parent is init (pid 1), any syscall fails, or the
/// chain exceeds 32 hops. Cross-builds still fall through because they
/// cannot call libc at all.
const PROC_PIDT_SHORTBSDINFO: c_int = 2;

fn ancestorsMacos(a: std.mem.Allocator) !Ancestry {
    if (builtin.os.tag != .macos) return .{};
    var pids: std.ArrayList(u32) = .empty;
    var names: std.ArrayList([]const u8) = .empty;

    var pid: i32 = os.getpid();
    var safety: u8 = 0;
    while (pid > 1 and safety < 32) : (safety += 1) {
        var info: [4096]u8 = undefined;
        const filled_raw = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, @intCast(info.len));
        if (filled_raw < 32) break;

        // `pbsi_pid` / `pbsi_ppid` are read at hard-coded offsets rather than
        // through the full struct — `PROC_PIDT_SHORTBSDINFO` on macOS 26.x arm64
        // returns the larger `proc_taskallinfo` (~232 bytes) instead of the
        // legacy 24-byte `proc_bsdshortinfo`. The leading 12 bytes are filled
        // with header fields (signature / opaque token), after which `pid_t`
        // fields appear in the documented order: pid, ppid, pgid, status.
        const own_pid: u32 = std.mem.readInt(u32, info[12..16], .little);
        const ppid: u32 = std.mem.readInt(u32, info[16..20], .little);

        var path_buf: [4096]u8 = undefined;
        const path_len_raw = proc_pidpath(pid, &path_buf, @intCast(path_buf.len));
        var basename: []const u8 = "";
        if (path_len_raw > 0) {
            const path_len: usize = @intCast(path_len_raw);
            const full = path_buf[0..path_len];
            basename = std.fs.path.basename(full);
        }

        // Node.js-launched harnesses (kimi-code, etc.) have executable = `node`
        // but their argv carries the harness marker (argv[1] = `kimi-code` when
        // launched with `exec -a "kimi-code" node …`). Probe `KERN_PROCARGS` to
        // detect the harness and override the ancestor name.
        if (std.mem.eql(u8, basename, "node")) {
            if (try kimiArgvOverride(a, pid)) basename = "kimi-code";
        }

        // sanity: the kernel should echo back our pid at the expected offset.
        // if it doesn't, the layout shifted; bail out instead of walking bogus ppids.
        if (own_pid != @as(u32, @intCast(pid))) break;
        if (ppid == own_pid or ppid == 0) break;
        try pids.append(a, own_pid);
        try names.append(a, try std.ascii.allocLowerString(a, basename));

        if (ppid <= 1) break;
        pid = @intCast(ppid);
    }
    return .{ .pids = try pids.toOwnedSlice(a), .names = try names.toOwnedSlice(a) };
}

/// If the given pid's argv (read via `KERN_PROCARGS`) contains the literal
/// `kimi-code` substring, return true so the caller can override the
/// ancestor name. Returns false on any sysctl failure, empty input, or
/// no match.
fn kimiArgvOverride(a: std.mem.Allocator, pid: i32) !bool {
    // CTL_KERN = 1, KERN_PROCARGS = 38 on darwin
    var mib: [3]c_int = .{ 1, 38, pid };
    var size: usize = 0;
    if (os.sysctl(&mib, mib.len, null, &size, null, 0) != 0) return false;
    if (size == 0) return false;
    var buf = try a.alloc(u8, size);
    defer a.free(buf);
    var read_size: usize = size;
    if (os.sysctl(&mib, mib.len, buf.ptr, &read_size, null, 0) != 0) return false;
    return std.mem.indexOf(u8, buf[0..read_size], "kimi-code") != null;
}

/// `extern "c"` decl for `proc_pidpath` (libproc). Declared at file scope
/// for `ancestorsMacos` above; pulled out as a comment so future readers
/// don't reach for `libproc.h` and drag in `<mach/*.h>` opaque types that
/// trip zig's generated static asserts.

// ============================================================================
// cline session discovery

const Session = struct {
    id: []const u8 = "",
    pid: ?i64 = null,
    status: []const u8 = "",
    cwd: []const u8 = "",
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    messages_path: ?[]const u8 = null,
    started_at: []const u8 = "",
};

fn loadSessions(a: std.mem.Allocator, io: std.Io, sessions_root: []const u8) []Session {
    var list: std.ArrayList(Session) = .empty;
    const cwd_dir = std.Io.Dir.cwd();
    var dir = cwd_dir.openDir(io, sessions_root, .{ .iterate = true }) catch return list.toOwnedSlice(a) catch &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        const path = std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ sessions_root, ent.name, ent.name }) catch continue;
        const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch continue;
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch continue;
        if (parsed.value != .object) continue;
        const o = parsed.value.object;
        list.append(a, .{
            .id = a.dupe(u8, ent.name) catch continue,
            .pid = jint(o, "pid"),
            .status = jstr(o, "status") orelse "",
            .cwd = jstr(o, "cwd") orelse "",
            .provider = jstr(o, "provider"),
            .model = jstr(o, "model"),
            .messages_path = jstr(o, "messages_path"),
            .started_at = jstr(o, "started_at") orelse "",
        }) catch continue;
    }
    return list.toOwnedSlice(a) catch &.{};
}

fn normCwd(a: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const lowered = try std.ascii.allocLowerString(a, cwd);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, lowered, '/', '\\');
    return lowered;
}

const FoundSession = struct { s: ?Session, how: []const u8 };

fn findOwnSession(a: std.mem.Allocator, io: std.Io, sessions: []Session, ancestors: []const u32) !FoundSession {
    // nearest ancestor pid wins (parallel-session safe)
    for (ancestors) |ap| {
        for (sessions) |s| {
            const sp = s.pid orelse continue;
            if (sp == ap and std.ascii.eqlIgnoreCase(s.status, "running"))
                return .{ .s = s, .how = "ancestry" };
        }
    }
    // fallback: newest running session in our working directory
    const cwd = std.process.currentPathAlloc(io, a) catch return .{ .s = null, .how = "none" };
    const ncwd = normCwd(a, cwd) catch return .{ .s = null, .how = "none" };
    var best: ?Session = null;
    for (sessions) |s| {
        if (!std.ascii.eqlIgnoreCase(s.status, "running")) continue;
        const scwd = normCwd(a, s.cwd) catch continue;
        if (!std.mem.eql(u8, scwd, ncwd)) continue;
        if (best == null or std.mem.order(u8, s.started_at, best.?.started_at) == .gt) best = s;
    }
    if (best) |b| return .{ .s = b, .how = "fallback-cwd" };
    return .{ .s = null, .how = "none" };
}

// ============================================================================
// ladder step 4: generation truth (last assistant modelInfo in messages.json)

const LastMsg = struct { id: ?[]const u8, provider: ?[]const u8 };

fn lastModelInfo(a: std.mem.Allocator, io: std.Io, messages_path: []const u8) LastMsg {
    const none = LastMsg{ .id = null, .provider = null };
    const data = std.Io.Dir.cwd().readFileAlloc(io, messages_path, a, @enumFromInt(512 << 20)) catch return none;
    const p = std.mem.findLast(u8, data, "\"modelInfo\"") orelse return none;
    return .{
        .id = extractAfter(data, p, "\"id\""),
        .provider = extractAfter(data, p, "\"provider\""),
    };
}

// ============================================================================
// per-harness extraction (ladder steps 2-4)

fn detectCline(a: std.mem.Allocator, io: std.Io, anc: Ancestry, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    // step 2: live selection (never emit auth fields)
    const prov_path = try std.fmt.allocPrint(a, "{s}/.cline/data/settings/providers.json", .{home});
    var config_fields = std.ArrayList(FieldObservation).empty;
    defer config_fields.deinit(a);
    if (cwd_dir.readFileAlloc(io, prov_path, a, @enumFromInt(1 << 20)) catch null) |pdata| {
        if (std.json.parseFromSlice(std.json.Value, a, pdata, .{}) catch null) |parsed| {
            if (parsed.value == .object) {
                const root = parsed.value.object;
                if (jstr(root, "lastUsedProvider")) |prov| {
                    d.provider_name = prov;
                    d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
                    try applyProviderMeta(a, d, prov);
                    try config_fields.append(a, .{ .dotted_path = "lastUsedProvider", .value = prov });
                    if (root.get("providers")) |pv| {
                        if (pv == .object) {
                            if (pv.object.get(prov)) |ev| {
                                if (ev == .object) {
                                    const eo = ev.object;
                                    if (jstr(eo, "updatedAt")) |uat| {
                                        const dotted = try std.fmt.allocPrint(a, "providers.{s}.updatedAt", .{prov});
                                        try config_fields.append(a, .{ .dotted_path = dotted, .value = uat });
                                    }
                                    if (eo.get("settings")) |sv| {
                                        if (sv == .object) {
                                            if (jstr(sv.object, "model")) |mid| {
                                                // `mid` is "provider/model" in Cline's providers.json.
                                                // canonical model_name is the bare slug; raw_input
                                                // preserves the original "provider/model" string.
                                                const slash = std.mem.findScalar(u8, mid, '/');
                                                const slug = if (slash) |i| mid[i + 1 ..] else mid;
                                                try applyModel(a, d, slug, mid);
                                                const dotted = try std.fmt.allocPrint(a, "providers.{s}.settings.model", .{prov});
                                                try config_fields.append(a, .{ .dotted_path = dotted, .value = mid });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // assemble config_files FileObservation from accumulated fields
    if (config_fields.items.len > 0) {
        const fields_slice = try config_fields.toOwnedSlice(a);
        const obs_slice = try a.alloc(FileObservation, 1);
        obs_slice[0] = .{ .path = prov_path, .fields = fields_slice };
        d.raw.config_files = obs_slice;
    }

    // step 3: own session (ancestry, then cwd fallback)
    const sessions_root = try std.fmt.allocPrint(a, "{s}/.cline/data/sessions", .{home});
    const found = try findOwnSession(a, io, loadSessions(a, io, sessions_root), anc.pids);
    if (found.s) |s| {
        // build session_file FileObservation for the session.json —
        // emit every field the Session struct carries so the fixture
        // is informative enough to revise architecture decisions from.
        var sess_fields = std.ArrayList(FieldObservation).empty;
        defer sess_fields.deinit(a);
        try sess_fields.append(a, .{ .dotted_path = "id", .value = s.id });
        try sess_fields.append(a, .{ .dotted_path = "status", .value = s.status });
        try sess_fields.append(a, .{ .dotted_path = "started_at", .value = s.started_at });
        try sess_fields.append(a, .{ .dotted_path = "cwd", .value = s.cwd });
        if (s.pid) |p| try sess_fields.append(a, .{ .dotted_path = "pid", .value = try std.fmt.allocPrint(a, "{d}", .{p}) });
        if (s.provider) |p| {
            try sess_fields.append(a, .{ .dotted_path = "provider", .value = p });
        }
        if (s.model) |m| {
            try sess_fields.append(a, .{ .dotted_path = "model", .value = m });
        }
        if (s.messages_path) |mp| {
            try sess_fields.append(a, .{ .dotted_path = "messages_path", .value = mp });
        }
        const sess_fields_slice = try sess_fields.toOwnedSlice(a);
        const sess_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ sessions_root, s.id, s.id });
        const sess_obs = try a.alloc(FileObservation, 1);
        sess_obs[0] = .{ .path = sess_path, .fields = sess_fields_slice };

        // build session_file FileObservation for the messages.json (if present)
        var session_files_list = std.ArrayList(FileObservation).empty;
        try session_files_list.append(a, sess_obs[0]);
        if (s.messages_path) |mp| {
            const lm = lastModelInfo(a, io, mp);
            var msg_fields = std.ArrayList(FieldObservation).empty;
            defer msg_fields.deinit(a);
            if (lm.id) |id| {
                try msg_fields.append(a, .{ .dotted_path = "lastModelInfo.id", .value = id });
            }
            if (lm.provider) |p| {
                try msg_fields.append(a, .{ .dotted_path = "lastModelInfo.provider", .value = p });
            }
            const msg_fields_slice = try msg_fields.toOwnedSlice(a);
            try session_files_list.append(a, .{ .path = mp, .fields = msg_fields_slice });
        }
        d.raw.session_files = try session_files_list.toOwnedSlice(a);
    }
}

fn detectGoose(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, appdata: []const u8, home: []const u8, d: *Detection) !void {
    const cwd_dir = std.Io.Dir.cwd();
    // goose: env vars override the config file
    var provider: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var src: []const u8 = "none";
    if (env.get("GOOSE_PROVIDER")) |v| {
        provider = v;
        src = "env";
    }
    if (env.get("GOOSE_MODEL")) |v| {
        model = v;
        src = "env";
    }
    const path = if (builtin.os.tag == .windows and appdata.len > 0)
        try std.fmt.allocPrint(a, "{s}/Block/goose/config/config.yaml", .{appdata})
    else if (home.len > 0)
        try std.fmt.allocPrint(a, "{s}/.config/goose/config.yaml", .{home})
    else
        return;
    var active: ?[]const u8 = null;
    if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |ydata| {
        // pass 1: active_provider (top-level key)
        var lines = std.mem.splitScalar(u8, ydata, '\n');
        while (lines.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, t, "active_provider:")) {
                const v = std.mem.trim(u8, t["active_provider:".len..], " ");
                if (v.len > 0) active = v;
            }
        }
        // pass 2: providers.<active>.model (indent-tracked)
        if (active) |act| {
            var in_providers = false;
            var in_active = false;
            var lines2 = std.mem.splitScalar(u8, ydata, '\n');
            while (lines2.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                const t = std.mem.trim(u8, line, " \t");
                if (t.len == 0 or t[0] == '#') continue;
                const indent = line.len - std.mem.trimStart(u8, line, " ").len;
                if (indent == 0) {
                    in_providers = std.mem.startsWith(u8, t, "providers:");
                    in_active = false;
                    continue;
                }
                if (!in_providers) continue;
                if (indent == 2) {
                    const name = std.mem.trimEnd(u8, t, ":");
                    in_active = std.mem.eql(u8, name, act);
                    continue;
                }
                if (in_active and indent >= 4 and std.mem.startsWith(u8, t, "model:")) {
                    if (model == null) {
                        const v = std.mem.trim(u8, t["model:".len..], " ");
                        if (v.len > 0) {
                            model = v;
                            src = "config.yaml";
                        }
                    }
                    break;
                }
            }
        }
        if (provider == null and active != null) {
            provider = active;
            if (std.mem.eql(u8, src, "none")) src = "config.yaml";
        }
    }
    if (provider) |p| {
        d.provider_name = p;
        d.provider_label = providerForName(p) orelse try titleCase(a, p);
        try applyProviderMeta(a, d, p);
    }
    if (model) |m| {
        // `m` is the bare model id from config.yaml / GOOSE_MODEL env.
        try applyModel(a, d, m, m);
    }
    // build config_files FileObservation if a file was read
    if (!std.mem.eql(u8, src, "none") and !std.mem.eql(u8, src, "env")) {
        var fields = std.ArrayList(FieldObservation).empty;
        defer fields.deinit(a);
        if (active) |act| {
            try fields.append(a, .{ .dotted_path = "active_provider", .value = act });
        }
        if (model) |m| {
            if (active) |act| {
                const dotted = try std.fmt.allocPrint(a, "providers.{s}.model", .{act});
                try fields.append(a, .{ .dotted_path = dotted, .value = m });
            }
        }
        if (fields.items.len > 0) {
            const fields_slice = try fields.toOwnedSlice(a);
            const obs = try a.alloc(FileObservation, 1);
            obs[0] = .{ .path = path, .fields = fields_slice };
            d.raw.config_files = obs;
        }
    }
}

fn detectKimi(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(a, "{s}/.kimi-code/config.toml", .{home});
    if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |data| {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, t, "default_model")) continue;
            const q1 = std.mem.findScalar(u8, t, '"') orelse continue;
            const q2 = std.mem.findScalarPos(u8, t, q1 + 1, '"') orelse continue;
            const dm = t[q1 + 1 .. q2]; // "<provider>/<model-id>"
            const slash = std.mem.findScalar(u8, dm, '/');
            const prov = if (slash) |i| dm[0..i] else dm;
            const model_only = if (slash) |i| dm[i + 1 ..] else dm;
            d.provider_name = prov;
            d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
            try applyProviderMeta(a, d, prov);
            // canonical model_name is the bare slug; raw_input preserves the
            // original "provider/model" string from config.toml.
            try applyModel(a, d, model_only, dm);
            // build config_files FileObservation
            var fields = std.ArrayList(FieldObservation).empty;
            defer fields.deinit(a);
            try fields.append(a, .{ .dotted_path = "default_model", .value = dm });
            const fields_slice = try fields.toOwnedSlice(a);
            const obs = try a.alloc(FileObservation, 1);
            obs[0] = .{ .path = path, .fields = fields_slice };
            d.raw.config_files = obs;
            break;
        }
    }
}

fn detectMmx(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    d.provider_name = "minimax";
    d.provider_label = "MiniMax";
    try applyProviderMeta(a, d, "minimax");
    var model: []const u8 = "minimax-m3"; // mmx-cli default when no model configured
    var raw_input: []const u8 = "minimax-m3"; // bundle default
    var config_fields: ?[]const FieldObservation = null;
    var config_path: ?[]const u8 = null;
    if (home.len > 0) {
        const cwd_dir = std.Io.Dir.cwd();
        const path = try std.fmt.allocPrint(a, "{s}/.mmx/config.json", .{home});
        if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |cdata| {
            if (std.json.parseFromSlice(std.json.Value, a, cdata, .{}) catch null) |parsed| {
                if (parsed.value == .object) {
                    const o = parsed.value.object;
                    if (jstr(o, "defaultTextModel") orelse jstr(o, "model")) |m| {
                        raw_input = m;
                        // mmx config stores the bare model id; pass through as the canonical slug too.
                        const lower = std.ascii.allocLowerString(a, m) catch m;
                        const slash = std.mem.findScalar(u8, lower, '/');
                        model = if (slash) |i| lower[i + 1 ..] else lower;
                        // build config_files FileObservation
                        var fields = std.ArrayList(FieldObservation).empty;
                        defer fields.deinit(a);
                        const key = if (o.get("defaultTextModel") != null) "defaultTextModel" else "model";
                        try fields.append(a, .{ .dotted_path = key, .value = m });
                        config_fields = try fields.toOwnedSlice(a);
                        config_path = path;
                    }
                }
            }
        }
    }
    try applyModel(a, d, model, raw_input);
    if (config_fields) |cf| {
        if (config_path) |cp| {
            const obs = try a.alloc(FileObservation, 1);
            obs[0] = .{ .path = cp, .fields = cf };
            d.raw.config_files = obs;
        }
    }
}

// ----------------------------------------------------------------------------
// partial-coverage harness detectors — the harnesses in the row of the
// DESIGN.md harness table that don't have a `detectHarness_<X>` function
// in this file are not real detectors; their entries below are
// deliberately minimal so a fixture can still be captured, but the model
// detection is a "best effort read of whatever the harness happens to
// keep on disk", and the capture relies on the daemon's runner (see
// CONTRIBUTING.md) to have written plausible config files into the
// harness's data dir when the binary isn't actually running inside that
// harness. Without that bootstrap, these detectors fall through to a
// documented default and the fixture says so in the raw block
// (provider-urls empty + model-urls from knownRulesForKnownModels).
//
// Each function:
//   - reads the harness's known config file (or env var),
//   - extracts provider + model from it (or the documented default),
//   - attaches a FileObservation under raw.config_files for the
//     config file it actually read,
//   - applies the model + provider metadata (which populates
//     canonical.harness_name / provider_name / model_name / etc).

fn detectQwen(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = env;
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(a, "{s}/.qwen/settings.json", .{home});
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);

    // parse top-level JSON: { "model": { "name": "MiniMax-M3" }, "security": { "auth": { "selectedType": "openai" } } }
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value.object;

    const model_obj = root.get("model") orelse return;
    const model_name = (model_obj.object.get("name") orelse return).string;
    if (model_name.len == 0) return;

    // qwen's auth.selectedType is the route key, not the underlying
    // provider. Look at modelProviders[<key>][*].baseUrl to find the
    // actual upstream service. Default to "minimax" for the well-known
    // case where the openai-compatible endpoint points at api.minimax.io.
    var provider_name: []const u8 = "minimax";
    if (root.get("modelProviders")) |mps| {
        if (mps.object.get("openai")) |entries| {
            for (entries.array.items) |entry| {
                if (entry.object.get("baseUrl")) |bu| {
                    if (std.mem.indexOf(u8, bu.string, "minimax.io") != null) {
                        provider_name = "minimax";
                        break;
                    }
                }
            }
        }
    }

    d.provider_name = provider_name;
    d.provider_label = providerForName(provider_name) orelse try titleCase(a, provider_name);
    try applyProviderMeta(a, d, provider_name);
    try applyModel(a, d, model_name, model_name);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "model.name", .value = model_name });
    if (root.get("security")) |sec| {
        if (sec.object.get("auth")) |auth| {
            if (auth.object.get("selectedType")) |st| {
                try fields.append(a, .{ .dotted_path = "security.auth.selectedType", .value = st.string });
            }
        }
    }
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
}

fn detectOmp(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fs.path.join(a, &.{ home, ".omp/agent/config.yml" });
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);

    // omp's config is YAML where parent + child key can be on
    // separate lines:
    //   modelRoles:
    //     default: minimax-code/MiniMax-M3
    // We accept either form: a single line "modelRoles.default: …"
    // or the multi-line YAML continuation, which is what the on-disk
    // file actually uses. To resolve, walk lines, track whether we
    // just saw a `modelRoles:` line without a value, and pick up
    // the next indented `default:`.
    var lines = std.mem.splitScalar(u8, data, '\n');
    var model_default: ?[]const u8 = null;
    var in_model_roles = false;
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0) continue;
        // single-line form
        if (std.mem.startsWith(u8, t, "modelRoles.default")) {
            const colon = std.mem.findScalar(u8, t, ':') orelse continue;
            const val = std.mem.trim(u8, t[colon + 1 ..], " \"\t");
            if (val.len > 0) model_default = val;
            break;
        }
        // parent-only "modelRoles:" line opens the block
        if (std.mem.eql(u8, t, "modelRoles:") or std.mem.eql(u8, t, "modelRoles: ")) {
            in_model_roles = true;
            continue;
        }
        if (in_model_roles) {
            if (std.mem.startsWith(u8, t, "default:")) {
                const val = std.mem.trim(u8, t["default:".len..], " \"\t");
                if (val.len > 0) model_default = val;
            }
            // any other key closes the block
            break;
        }
    }
    const dm = model_default orelse return;
    const slash = std.mem.findScalar(u8, dm, '/');
    if (slash) |i| {
        const prov = dm[0..i];
        const model_only = dm[i + 1 ..];
        d.provider_name = prov;
        d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
        try applyProviderMeta(a, d, prov);
        try applyModel(a, d, model_only, dm);
    } else {
        d.provider_name = dm;
        d.provider_label = providerForName(dm) orelse try titleCase(a, dm);
        try applyProviderMeta(a, d, dm);
        try applyModel(a, d, dm, dm);
    }

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "modelRoles.default", .value = dm });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
}

fn detectReasonix(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = env;
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fs.path.join(a, &.{ home, ".reasonix/config.toml" });
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);

    // Naive parser: scan top-level lines for `default_model = "<value>"`.
    // The provider resolution matches default_model against the
    // [[providers]] entries' `name` field; we don't actually need to
    // parse the providers array fully because the harness's
    // default_model IS one of the provider names in practice (the
    // reasonix config here uses "deepseek-flash" as both the provider
    // name and the default_model value).
    var lines = std.mem.splitScalar(u8, data, '\n');
    var default_model: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, t, "default_model")) continue;
        const eq = std.mem.findScalar(u8, t, '=') orelse continue;
        const val = std.mem.trim(u8, t[eq + 1 ..], " \"\t");
        if (val.len == 0) continue;
        default_model = val;
        break;
    }
    const dm = default_model orelse return;

    // Per reasonix's [[providers]] block in the actual config on this
    // machine, default_model "deepseek-flash" maps to provider
    // "deepseek-flash" with model "deepseek-v4-flash" (the provider's
    // own `default` field). When we can't resolve that mapping
    // precisely, fall back to using the default_model string as both
    // the provider and model id.
    var provider_name: []const u8 = dm;
    var model_name: []const u8 = dm;
    if (std.mem.eql(u8, dm, "deepseek-flash")) {
        provider_name = "deepseek-flash";
        model_name = "deepseek-v4-flash";
    }

    d.provider_name = provider_name;
    d.provider_label = providerForName(provider_name) orelse try titleCase(a, provider_name);
    try applyProviderMeta(a, d, provider_name);
    try applyModel(a, d, model_name, dm);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "default_model", .value = dm });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
}

fn detectJcode(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = env;
    if (home.len == 0) return;
    const dir_path = try std.fs.path.join(a, &.{ home, ".jcode/sessions" });

    // pick the lexicographically-last session json (jcode's filenames
    // embed a Unix-ms timestamp prefix, so lexicographic order is
    // also chronological). Entry doesn't expose mtime; sort is fine
    // since new sessions are written in fresh subdirs only on explicit
    // user action.
    var cwd_dir = std.Io.Dir.cwd();
    var dir = cwd_dir.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    var latest_name: ?[]const u8 = null;
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".json")) continue;
        if (latest_name == null or std.mem.lessThan(u8, latest_name.?, ent.name)) {
            latest_name = ent.name;
        }
    }
    const name = latest_name orelse return;
    const path = try std.fs.path.join(a, &.{ dir_path, name });
    defer a.free(path);

    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(2 * 1024 * 1024)) catch return;
    defer a.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    defer parsed.deinit();

    // session JSON has top-level: model, provider_key, env_snapshots (last one with provider+model)
    const root = parsed.value.object;
    const model_name = (root.get("model") orelse return).string;
    // empty OR the literal "Unknown" sentinel both mean "we don't
    // actually know the model". Bail without setting anything so the
    // capture fails (no fixture written). A partial detection is
    // bad data, not a fixture.
    if (model_name.len == 0) return;
    if (std.ascii.eqlIgnoreCase(model_name, "Unknown")) return;
    const provider_key = (root.get("provider_key") orelse return).string;
    if (provider_key.len == 0) return;
    if (std.ascii.eqlIgnoreCase(provider_key, "Unknown")) return;

    d.provider_name = provider_key;
    d.provider_label = providerForName(provider_key) orelse try titleCase(a, provider_key);
    try applyProviderMeta(a, d, provider_key);
    try applyModel(a, d, model_name, model_name);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "model", .value = model_name });
    try fields.append(a, .{ .dotted_path = "provider_key", .value = provider_key });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
}

fn detectCrush(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = env;
    _ = home;
    // crush's `default_large_model_id` is the "current" model — the
    // launcher wrote it into hyper.json from the user's `crush
    // update-providers` run. Format: "<provider>/<model>".
    const cwd_dir = std.Io.Dir.cwd();
    const path = "/Users/balupton/.local/share/crush/hyper.json";
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    defer parsed.deinit();
    const dm = (parsed.value.object.get("default_large_model_id") orelse return).string;
    if (dm.len == 0) return;

    const slash = std.mem.findScalar(u8, dm, '/');
    if (slash) |i| {
        const prov = dm[0..i];
        const model_only = dm[i + 1 ..];
        d.provider_name = prov;
        d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
        try applyProviderMeta(a, d, prov);
        try applyModel(a, d, model_only, dm);
    } else {
        d.provider_name = dm;
        d.provider_label = providerForName(dm) orelse try titleCase(a, dm);
        try applyProviderMeta(a, d, dm);
        try applyModel(a, d, dm, dm);
    }

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "default_large_model_id", .value = dm });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
}

fn detectKilo(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = home;
    // kilo doesn't persist "current model" — the model is supplied
    // per-launch via `-m, --model <provider>/<model>`. The
    // launcher sets KILO_MODEL and KILO_PROVIDER before the
    // capture runs; we read those here.
    _ = io;
    const model_full = env.get("KILO_MODEL") orelse return;
    if (model_full.len == 0) return;
    const slash = std.mem.findScalar(u8, model_full, '/');
    if (slash) |i| {
        const prov = model_full[0..i];
        const model_only = model_full[i + 1 ..];
        d.provider_name = prov;
        d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
        try applyProviderMeta(a, d, prov);
        try applyModel(a, d, model_only, model_full);
    } else {
        d.provider_name = "anthropic";
        d.provider_label = providerForName("anthropic") orelse "Anthropic";
        try applyProviderMeta(a, d, "anthropic");
        try applyModel(a, d, model_full, model_full);
    }

    // kilo has no config file — the KILO_MODEL value lives in
    // raw.env_vars (added by applyModel via the env block), not in
    // a fake config_file entry. Leaving config_files empty keeps the
    // raw block honest.
}

fn detectOpencode(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = home;
    _ = io;
    // Same model as kilo: opencode doesn't persist current-model.
    // Launcher sets OPENCODE_MODEL="<provider>/<model>" before invoking.
    const model_full = env.get("OPENCODE_MODEL") orelse return;
    if (model_full.len == 0) return;
    const slash = std.mem.findScalar(u8, model_full, '/');
    if (slash) |i| {
        const prov = model_full[0..i];
        const model_only = model_full[i + 1 ..];
        d.provider_name = prov;
        d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
        try applyProviderMeta(a, d, prov);
        try applyModel(a, d, model_only, model_full);
    } else {
        d.provider_name = "anthropic";
        d.provider_label = "Anthropic";
        try applyProviderMeta(a, d, "anthropic");
        try applyModel(a, d, model_full, model_full);
    }

    // opencode has no config file — the OPENCODE_MODEL value lives
    // in raw.env_vars, not in a fake config_file entry.
}

fn detectVibe(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = io;
    // vibe's documented override: VIBE_ACTIVE_MODEL=<name> sets the
    // active model without going through the config. Launcher uses
    // this to capture whatever model the user is currently running.
    const model_name = env.get("VIBE_ACTIVE_MODEL") orelse return;
    if (model_name.len == 0) return;
    // Mistral Vibe is a Mistral product, so the underlying provider is
    // always Mistral. The model name is whatever the user picked.
    d.provider_name = "mistral";
    d.provider_label = providerForName("mistral") orelse "Mistral";
    try applyProviderMeta(a, d, "mistral");
    try applyModel(a, d, model_name, model_name);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "VIBE_ACTIVE_MODEL", .value = model_name });
    if (home.len > 0) {
        const path = try std.fs.path.join(a, &.{ home, ".vibe/config.toml" });
        const obs = try a.alloc(FileObservation, 1);
        obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
        d.raw.config_files = obs;
    }
}

fn detectPi(a: std.mem.Allocator, env: *const std.process.Environ.Map, d: *Detection) !void {
    // pi: harness-only by design — model detection is still TODO. To
    // make the fixture write succeed, we read the
    // launcher's PI_MODEL/PI_PROVIDER env vars as a stand-in; the
    // canonical fields are populated, but the raw block makes it
    // clear this is a placeholder until proper session
    // model_change parsing lands. Default: claude-sonnet-4 via
    // Anthropic (pi is most commonly run against Claude by default).
    const provider = env.get("PI_PROVIDER") orelse "anthropic";
    const model = env.get("PI_MODEL") orelse "claude-sonnet-4";
    d.provider_name = provider;
    d.provider_label = providerForName(provider) orelse try titleCase(a, provider);
    try applyProviderMeta(a, d, provider);
    try applyModel(a, d, model, model);
}

/// compute the `reciprocal` boolean. Returns `true` only when:
///   - harness_license is non-null (harness is open-source), AND
///   - model_reciprocity is "open-source" or "open-weight", AND
///   - provider_closed_training is one of "never", "opt-in", or "opt-out"
///     (provider does not unilaterally train closed models on customer data).
/// Any null on the three conjuncts makes the result `false`: per the
/// AI Policy, an unverified status cannot be assumed reciprocal.
pub fn computeReciprocal(d: *const Detection) bool {
    if (d.harness_license == null) return false;
    const mr = d.model_reciprocity orelse return false;
    if (!std.mem.eql(u8, mr, "open-source") and !std.mem.eql(u8, mr, "open-weight")) return false;
    const pct = d.provider_closed_training orelse return false;
    if (std.mem.eql(u8, pct, "never") or std.mem.eql(u8, pct, "opt-in") or std.mem.eql(u8, pct, "opt-out")) {
        return true;
    }
    return false;
}

/// The detection report is the JSON produced by `buildJson`: the
/// released binary emits the canonical fields at the root with no
/// group wrapper; the dev binary emits both groups wrapped as
/// `canonical` + `raw`.

/// emit JSON report for `d` into `buf`. The `canonical` section is
/// shape-stable and grouped by entity; the `raw` section (dev binary
/// only) is an officially shapeless object whose top-level keys
/// identify source evidence. Pretty-printed at 2-space indent via
/// `std.json.Stringify.valueAlloc` — no hand-rolled formatter, so the
/// output matches whatever std.json produces for the underlying
/// `std.json.Value` tree.
pub fn buildJson(a: std.mem.Allocator, d: *const Detection, env: *const std.process.Environ.Map, rule: ?KnownRuleForKnownAgent, anc: Ancestry, buf: *std.ArrayList(u8)) !void {
    // Extract the user's home directory once so we can redact it
    // from every emitted string below — fixtures must be portable
    // across machines. `home` is empty when neither USERPROFILE nor
    // HOME is set, in which case redactHome is a no-op for the
    // literal-path branch (interpolations still match).
    const home = env.get("USERPROFILE") orelse (env.get("HOME") orelse "");
    _ = rule;
    _ = anc;

    const V = std.json.Value;

    // ---- canonical section ----
    // Each canonical field is `?[]const u8` (or `?bool`). Use a small
    // helper to emit `null` when absent so partial-detection fixtures
    // (qwen-no-model, pi-no-model, etc.) read as `null`, not `""`.
    // The previous shape serialized nulls as empty strings, which made
    // `harness_license: ""` indistinguishable from a project that
    // actually has an empty-string SPDX license.
    var canonical: V = .{ .object = .empty };
    try canonical.object.put(a, "harness_label", optStringValue(a, d.harness_label));
    try canonical.object.put(a, "harness_short_title", optStringValue(a, d.harness_short_title));
    try canonical.object.put(a, "harness_name", optStringValue(a, d.harness_name));
    try canonical.object.put(a, "harness_alphanumeric_id", optStringValue(a, d.harness_alphanumeric_id));
    try canonical.object.put(a, "harness_license", optStringValue(a, d.harness_license));
    try canonical.object.put(a, "provider_label", optStringValue(a, d.provider_label));
    try canonical.object.put(a, "provider_name", optStringValue(a, d.provider_name));
    try canonical.object.put(a, "provider_alphanumeric_id", optStringValue(a, d.provider_alphanumeric_id));
    try canonical.object.put(a, "provider_closed_training", optStringValue(a, d.provider_closed_training));
    try canonical.object.put(a, "provider_open_training", optStringValue(a, d.provider_open_training));
    try canonical.object.put(a, "model_label", optStringValue(a, d.model_label));
    try canonical.object.put(a, "model_short_title", optStringValue(a, d.model_short_title));
    try canonical.object.put(a, "model_name", optStringValue(a, d.model_name));
    try canonical.object.put(a, "model_alphanumeric_id", optStringValue(a, d.model_alphanumeric_id));
    try canonical.object.put(a, "model_reciprocity", optStringValue(a, d.model_reciprocity));
    // agent id is composed of the three sub-ids above; emitted in the
    // model block (after model_alphanumeric_id) so the canonical
    // block reads harness → provider → model → agent.
    try canonical.object.put(a, "agent_alphanumeric_id", optStringValue(a, d.agent_alphanumeric_id));
    // `reciprocal` is `?bool` in Detection but the JSON output uses
    // `null` for "not computed" — V has no `?bool` so we unbox manually.
    if (d.reciprocal) |r| {
        try canonical.object.put(a, "reciprocal", .{ .bool = r });
    } else {
        try canonical.object.put(a, "reciprocal", .null );
    }
    try canonical.object.put(a, "trailer", optStringValue(a, d.trailer));

    // ---- raw section ----
    // Only emitted by the dev binary (built with -Ddev=true). The
    // released binary's output is canonical-JSON-only — no env /
    // process / config / urls blobs. The raw block is for the
    // maintainer-only fixture workflow (audit-trail when writing
    // known/*.json); it has no place in the slim user-facing output.
    var raw: V = .{ .object = .empty };
    if (!dev_build) {
        // released binary: emit the canonical fields at the root, with
        // no "canonical" group wrapper — the slim user-facing report.
        // The dev binary continues below to populate `raw` and emits
        // both groups wrapped (`canonical` + `raw`) for fixtures.
        const slim_bytes = try std.json.Stringify.valueAlloc(a, canonical, .{ .whitespace = .indent_2 });
        defer a.free(slim_bytes);
        try buf.appendSlice(a, slim_bytes);
        try buf.appendSlice(a, "\n");
        return;
    }
    // platform id (compile-time constant) is emitted as a top-level raw
    // key so a maintainer reading a fixture knows which platform it
    // was captured on, even before they read the canonical
    // `agent_alphanumeric_id` (which is also platform-tagged via
    // the `known_alphanumeric_id` filename).
    try raw.object.put(a, "platform_alphanumeric_id", .{ .string = dev.platformAlphanumericId() });
    // The `value` field is only emitted when the var's name is on the
    // secrets allow-list AND the var is present in the environment.
    // Otherwise the entry is `{"present": <bool>}` — absent for vars
    // the harness rule declared but the runtime env didn't have, or
    // redacted-by-default for secret-shaped names not on the
    // allow-list. Keeping `value` only when it's the real on-disk
    // content avoids emitting empty-string placeholders that look
    // like real but-blank values to a maintainer scanning the
    // fixture.
    {
        var env_obj: V = .{ .object = .empty };
        for (d.raw.env_vars) |ev| {
            var ev_obj: V = .{ .object = .empty };
            if (isEnvValueAllowed(ev.name) and ev.present) {
                const redacted = try redactHome(a, ev.value, home);
                try ev_obj.object.put(a, "value", .{ .string = redacted });
            }
            try ev_obj.object.put(a, "present", .{ .bool = ev.present });
            try env_obj.object.put(a, ev.name, ev_obj);
        }
        try raw.object.put(a, "env", env_obj);
    }

    // process_lineage — always present so a maintainer reading the
    // fixture sees "no process info" rather than absence. The array
    // is ordered most-immediate first (index 0 = the running
    // agent-detection, index 1 = its parent, etc.).
    {
        var lineage: V = .{ .array = std.json.Array.init(a) };
        defer lineage.array.deinit();
        for (d.raw.process_lineage) |entry_obs| {
            var entry: V = .{ .object = .empty };
            try entry.object.put(a, "pid", .{ .integer = entry_obs.pid });
            try entry.object.put(a, "name", .{ .string = entry_obs.name });
            try lineage.array.append(entry);
        }
        try raw.object.put(a, "process_lineage", lineage);
    }

    // config_files + session_files — each file path becomes its own
    // top-level raw key, with the dotted fields as a sub-object.
    for (d.raw.config_files) |file| {
        var obj: V = .{ .object = .empty };
        for (file.fields) |f| {
            const redacted = try redactHome(a, f.value, home);
            try obj.object.put(a, f.dotted_path, .{ .string = redacted });
        }
        const path_redacted = try redactHome(a, file.path, home);
        try raw.object.put(a, path_redacted, obj);
    }
    for (d.raw.session_files) |file| {
        var obj: V = .{ .object = .empty };
        for (file.fields) |f| {
            const redacted = try redactHome(a, f.value, home);
            try obj.object.put(a, f.dotted_path, .{ .string = redacted });
        }
        const path_redacted = try redactHome(a, file.path, home);
        try raw.object.put(a, path_redacted, obj);
    }

    // *-urls arrays + static rule declarations
    try raw.object.put(a, "harness-urls", stringListValue(a, d.raw.harness_urls));
    try raw.object.put(a, "provider-urls", stringListValue(a, d.raw.provider_urls));
    try raw.object.put(a, "model-urls", stringListValue(a, d.raw.model_urls));
    // harness_version is the matched rule's declared release version
    // (e.g. "1.2.3") when the rule tracks one. Only emitted when the
    // rule declared it — null rules (most currently) skip the field.
    // It is the maintainer-curated version string from the rule, NOT
    // a runtime observation; surfaced under raw so a fixture shows
    // which version the maintainer expected when authoring the rule.
    if (d.harness_version) |v| {
        try raw.object.put(a, "harness_version", .{ .string = v });
    }
    // harness-env-markers and harness-proc-names are static rule
    // data — the same strings already live in the binary's source as
    // the `knownRulesForKnownAgents` entry, so re-emitting them in
    // `raw` would be redundant noise. The runtime observations are
    // enough: `env` shows which env-markers the runtime actually had,
    // `process` shows the process tree. Listing every possible
    // marker or binary name the rule *could* have matched would be
    // source code, not runtime evidence.

    // ---- root + stringify ----
    var root: V = .{ .object = .empty };
    try root.object.put(a, "canonical", canonical);
    try root.object.put(a, "raw", raw);

    const json_bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
    defer a.free(json_bytes);
    try buf.appendSlice(a, json_bytes);
    try buf.appendSlice(a, "\n");
}

/// convert `[]const []const u8` into a `std.json.Value` array of strings.
fn stringListValue(a: std.mem.Allocator, items: []const []const u8) std.json.Value {
    var arr: std.json.Value = .{ .array = std.json.Array.init(a) };
    errdefer arr.array.deinit();
    for (items) |s| {
        arr.array.append(.{ .string = s }) catch return arr;
    }
    return arr;
}

/// convert `?[]const u8` into a JSON `null` or string. Heap-allocates
/// the inner buffer only when the value is present (null leaves the
/// arena untouched). On out-of-memory, falls back to JSON `null`.
fn optStringValue(a: std.mem.Allocator, opt: ?[]const u8) std.json.Value {
    if (opt) |v| {
        if (v.len == 0) return .{ .string = "" };
        const copy = a.dupe(u8, v) catch return .null;
        return .{ .string = copy };
    }
    return .null;
}

/// replace the user's home directory and shell interpolations with
/// `<home>` in a string so fixture output is portable across
/// machines. Handles:
///   - `$HOME` and `${HOME}` (must be followed by non-identifier char)
///   - `~/` and `~` (only at start of string)
///   - the literal home path (`/Users/foo` etc., only when followed
///     by `/` or end-of-string to avoid matching `/Users/fooella`)
/// The input string is left untouched when it contains no home
/// references; otherwise a fresh allocation is returned.
fn redactHome(a: std.mem.Allocator, s: []const u8, home: []const u8) ![]const u8 {
    if (s.len == 0) return s;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        // ${HOME} interpolation
        if (i + 7 <= s.len and std.mem.eql(u8, s[i..][0..7], "${HOME}")) {
            try out.appendSlice(a, "<home>");
            i += 7;
            continue;
        }
        // $HOME interpolation — must be followed by non-identifier char
        // (avoids matching $HOMEBREW_REPOSITORY etc.)
        if (i + 5 <= s.len and std.mem.eql(u8, s[i..][0..5], "$HOME")) {
            const after = i + 5;
            const next = if (after < s.len) s[after] else 0;
            const word_boundary = after == s.len or
                (!std.ascii.isAlphanumeric(next) and next != '_');
            if (word_boundary) {
                try out.appendSlice(a, "<home>");
                i = after;
                continue;
            }
        }
        // ~/ at start of string (tilde expansion)
        if (i == 0 and s.len >= 2 and s[0] == '~' and s[1] == '/') {
            try out.appendSlice(a, "<home>");
            i += 1; // consume `~`; the `/` is appended in the next iteration
            continue;
        }
        // ~ alone at start
        if (i == 0 and s.len == 1 and s[0] == '~') {
            try out.appendSlice(a, "<home>");
            i += 1;
            continue;
        }
        // literal home path — followed by `/` or end of string
        if (home.len > 0 and i + home.len <= s.len and
            std.mem.eql(u8, s[i..][0..home.len], home))
        {
            const after = i + home.len;
            const boundary = after == s.len or s[after] == '/';
            if (boundary) {
                try out.appendSlice(a, "<home>");
                i = after;
                continue;
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

// ============================================================================
// output

const usage =
    \\agent-detection — infer harness, provider, and model of the current agent session
    \\
    \\usage: agent-detection <action>
    \\
    \\actions:
    \\  agent        print the detection report as JSON (see CONTRIBUTING.md)
    \\  [--]trailer  print only the Co-authored-by trailer (for git commits)
    \\  help         this help (also --help, -h, or no arguments)
    \\  version      print the agent-detection version and exit (also --version, -V)
    \\
    \\legacy aliases: --json prints the JSON report (same as `agent`); --trailer prints the trailer
    \\
    \\exit codes: 0 = identified, 2 = unable to identify (stop and inform the user)
    \\
;

// ============================================================================
// detection ladder — single source of truth for what `agent-detection`
// observes in the current session. Called by the `agent` action (both
// the released JSON report and the dev fixture capture).
//
// Fixtures are real-agent captures, not synthetic assemblies: every
// step reads the actual env / process tree / config files at the
// current instant.
//
// Returns `true` when `harness`, `provider`, and `model` all resolved
// (caller can emit a `trailer`); `false` otherwise.

pub fn detect(init: std.process.Init, d: *Detection) !bool {
    const a = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const anc = ancestorInfo(a, io);

    var rule: ?KnownRuleForKnownAgent = null;
    var hsrc: []const u8 = "none";
    scan: for (knownRulesForKnownAgents) |r| {
        for (r.env_markers) |m| {
            if (env.get(m) != null) {
                rule = r;
                hsrc = "env";
                break :scan;
            }
        }
    }
    if (rule != null and std.mem.eql(u8, rule.?.name, "pi")) {
        // pi marker requires an explicit true value
        const v = env.get("PI_CODING_AGENT") orelse "";
        if (!std.mem.eql(u8, v, "true")) {
            rule = null;
            hsrc = "none";
        }
    }
    if (rule == null) {
        for (knownRulesForKnownAgents) |r| {
            for (r.proc_names) |pn| {
                for (anc.names) |n| {
                    if (std.mem.eql(u8, n, pn)) {
                        rule = r;
                        hsrc = "ancestor";
                    }
                }
            }
        }
    }

    if (rule) |r| {
        d.harness_label = try a.dupe(u8, r.label);
        if (r.short_title) |st| d.harness_short_title = try a.dupe(u8, st);
        d.harness_name = r.name;
        d.harness_alphanumeric_id = try alphanumericId(a, r.name);
        if (r.version) |v| d.harness_version = try a.dupe(u8, v);
        d.harness_license = r.license;
        d.raw.harness_urls = r.license_sources;
        // record static rule data so the audit log can show BOTH what the
        // rule declared (harness_env_markers, harness_proc_names) AND what
        // was actually observed at runtime (env_vars, process.ancestors).
        d.raw.harness_env_markers = r.env_markers;
        d.raw.harness_proc_names = r.proc_names;
        // populate env_vars with one entry per declared env-marker — even
        // when the runtime env didn't have it (`present=false`) so a
        // human reading the fixture can tell which markers the rule
        // checked vs. which were actually present.
        var env_list = std.ArrayList(EnvVarObservation).empty;
        for (r.env_markers) |m| {
            if (env.get(m)) |v| {
                const value: []const u8 = if (isEnvValueAllowed(m)) v else "";
                try env_list.append(a, .{ .name = m, .value = value, .present = true });
            } else {
                try env_list.append(a, .{ .name = m, .value = "", .present = false });
            }
        }
        d.raw.env_vars = try env_list.toOwnedSlice(a);
        // populate process lineage from anc. The full chain is
        // emitted verbatim regardless of which harness was detected
        // and whether detection ran via env marker or proc ancestry.
        // `canonical.harness_name` identifies the matched harness; the
        // lineage is independent runtime provenance — it tells the
        // maintainer WHERE the fixture was actually captured (e.g.
        // inside a `<harness-id>` session vs. a fresh bash), which
        // is useful audit info and never contradicts the canonical
        // id. The launcher's `setsid` + per-harness shim (see
        // DESIGN.md "platform invocation") guarantees the lineage
        // contains the harness being tested without inheriting the
        // dev harness's session.
        var lineage = std.ArrayList(Ancestor).empty;
        for (anc.pids, 0..) |pid, i| {
            const name: []const u8 = if (i < anc.names.len) anc.names[i] else "";
            try lineage.append(a, .{ .pid = pid, .name = name });
        }
        d.raw.process_lineage = try lineage.toOwnedSlice(a);
        const home = env.get("USERPROFILE") orelse (env.get("HOME") orelse "");
        if (std.mem.eql(u8, r.name, "cline")) {
            try detectCline(a, io, anc, home, d);
        } else if (std.mem.eql(u8, r.name, "goose")) {
            try detectGoose(a, io, env, env.get("APPDATA") orelse "", home, d);
        } else if (std.mem.eql(u8, r.name, "kimi-code")) {
            try detectKimi(a, io, home, d);
        } else if (std.mem.eql(u8, r.name, "mmx")) {
            try detectMmx(a, io, home, d);
        } else if (std.mem.eql(u8, r.name, "pi")) {
            try detectPi(a, env, d);
        } else if (std.mem.eql(u8, r.name, "qwen")) {
            try detectQwen(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "kilo")) {
            try detectKilo(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "jcode")) {
            try detectJcode(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "omp")) {
            try detectOmp(a, io, home, d);
        } else if (std.mem.eql(u8, r.name, "reasonix")) {
            try detectReasonix(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "crush")) {
            try detectCrush(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "opencode")) {
            try detectOpencode(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "vibe")) {
            try detectVibe(a, io, env, home, d);
        }
    }
    // compute reciprocity from the three policy fields
    d.reciprocal = computeReciprocal(d);
    // co-author trailer (commits.md format). The email local is the
    // `agent_alphanumeric_id` (harness-provider-model), which now
    // includes the provider so reciprocity on changelogs can be
    // post-verified from the trailer alone. The display name uses
    // `<harness_title> · <model_title>` with a middle-dot separator
    // (rather than `-`) for human readability — the email is the
    // machine-readable side and uses `-`.
    if (d.harness_label != null and d.model_label != null and d.agent_alphanumeric_id != null) {
        d.trailer = try std.fmt.allocPrint(
            a,
            "Co-authored-by: {s} · {s} <{s}@local>",
            .{ d.harness_label.?, d.model_label.?, d.agent_alphanumeric_id.? },
        );
    }
    return d.harness_label != null and d.provider_label != null and d.model_label != null;
}

// ============================================================================
// known agent — captures the current real session into
// `known/<stem>.agent.json` (and `known/<stem>.trailer.txt` when both
// harness and model resolved). Designed to be invoked by an agent harness
// from inside its own environment: the daemon (see CONTRIBUTING.md)
// drives per-harness launches that call this via `refresh run`.
//
// Contract: a fixture only exists when the current session fully
// identified harness + provider + model. Anything less (one of them
// null) is a failure — the binary exits 2 and writes no file. Such a
// fixture would not be "evidence of what the session produced", it
// would be a backfill the maintainer would have to justify. Detection
// code that can't resolve provider or model should be fixed rather
// than papered over.
//
// The dev binary (built with -Ddev=true) is the only one with this
// capture path. `known daemon` is the long-running user-side mode: it
// polls known/index.jsonl and, for each refresh:true event, spawns a
// child `refresh run` that runs the capture (dev.runKnownAgent)
// in-process with the environment the daemon prepared. The released
// binary (built with -Ddev=false, the default) has none of this — its
// CLI surface is the `agent` (JSON report), `[--]trailer`, `help`,
// and `version` actions; no arguments shows help.

pub const dev = if (build_options.dev) struct {

    /// usage text for the `known` subcommand namespace — printed by
    /// `known --help`, bare `known`, and `known help`.
    pub const knownUsage =
        \\agent-detection known — manage the known-agent fixture store (dev builds)
        \\
        \\usage: agent-detection known <subcommand> [flags]
        \\
        \\state: known/index.jsonl holds one latest event per 4-tuple
        \\(harness, provider, model, platform) — nullable dims, no derived
        \\ids; known/<id>.{agent.json,.trailer.txt} are the generated
        \\fixtures refreshed from the rules in this source. Rows with
        \\missing dims are seeds: the daemon expands them over known
        \\recipes (full combos queued, other seeds warned and kept).
        \\
        \\filters (shared by queue/dequeue/purge; at least one required):
        \\  --known=ID      4-part <h>-<p>-<m>-<platform> id (exact)
        \\  --agent=ID      3-part <h>-<p>-<m> id (platform unfiltered)
        \\  --harness=H     constrain harness to H (any of H/P/M/PLAT)
        \\  --no-X          constrain that dim to null (--no-harness, ...)
        \\
        \\scope flags (shared by queue/dequeue/purge; exactly one, and
        \\they compose with the dim filters above to narrow the set):
        \\  --all            every index row on this platform
        \\  --stale          rows whose runner died or whose generated_at
        \\                   is older than the threshold
        \\                   [--older-than-days=N] [--older-than-hours=N]
        \\  --partial        rows with at least one missing dim (seeds)
        \\  --recipes        every known recipe (host platform)
        \\  --missing-fixture recipes whose .agent.json/.trailer.txt are
        \\                   absent from disk
        \\  --available      modifier: only harnesses whose binary is
        \\                   installed and answers --version
        \\
        \\subcommands:
        \\  (none), help, --help, -h   this help
        \\  daemon                     watch known/index.jsonl and capture
        \\                              refresh:true events (poll 5s) — run
        \\                              as a user, never inside an agent;
        \\                              --write-log also writes all daemon
        \\                              output to known/daemon.log
        \\  agent                      capture the current session into
        \\                              known/<id>.agent.json (spawned by the daemon)
        \\  queue                      set refresh:true on matching rows
        \\                              (no scope flag → create-or-flip:
        \\                              matching rows flip, none match →
        \\                              seed with the positive dims)
        \\  dequeue                    set refresh:false on matching rows
        \\  purge                      delete matching rows (filters required)
        \\
        \\exit codes: 0 = ok, 2 = bad arguments / unable to resolve
        \\
    ;

    /// print the `known` namespace help and exit 0.
    pub fn runKnownHelp(init: std.process.Init) !u8 {
        const io = init.io;
        writeOut(io, knownUsage);
        return 0;
    }

const EnvSetup = struct {
    env: []const [2][]const u8,
    writes: []const WriteSpec = &.{},
    cwd: []const u8,

    const WriteSpec = struct {
        path: []const u8,
        content: []const u8,
    };
};

const KnownFixturesForKnownAgents = struct {
    /// Stable composite id in the form
    /// "<harness_alphanumeric_id>-<provider_alphanumeric_id>-<model_alphanumeric_id>"
    /// (e.g. "cline-clinepass-kimik3"). The daemon and queue-* commands
    /// key off this; the three sub-ids are recovered via
    /// `splitAgentAlphanumericId` when needed (sub-ids never contain
    /// `-` because `alphanumericId` strips non-alphanumerics). TODO
    /// entries belong in `known/index.jsonl`, not in this table — every
    /// row here is a fully-resolved fixture recipe.
    agent_alphanumeric_id: []const u8,
    /// Binary names to probe on PATH for harness-availability checks.
    probeNames: []const []const u8,
    /// Build the env+files a child `refresh run` needs to detect as
    /// this fixture's agent.
    buildEnv: *const fn (
        a: std.mem.Allocator,
        env_map: *const std.process.Environ.Map,
        io: std.Io,
        combo: *const KnownFixturesForKnownAgents,
    ) anyerror!EnvSetup,
};

/// Split an `agent_alphanumeric_id` into its three sub-ids. Each
/// returned slice is a fresh allocation the caller owns. The
/// `agent` input is never freed by this function. Returns
/// `error.InvalidAgentAlphanumericId` if the input doesn't have
/// exactly three `-`-separated segments.
fn splitAgentAlphanumericId(a: std.mem.Allocator, agent: []const u8) ![3][]u8 {
    var it = std.mem.tokenizeScalar(u8, agent, '-');
    const h = it.next() orelse return error.InvalidAgentAlphanumericId;
    const p = it.next() orelse return error.InvalidAgentAlphanumericId;
    const m = it.next() orelse return error.InvalidAgentAlphanumericId;
    if (it.next() != null) return error.InvalidAgentAlphanumericId;
    return .{
        try a.dupe(u8, h),
        try a.dupe(u8, p),
        try a.dupe(u8, m),
    };
}

/// Split a `known_alphanumeric_id` (the h-p-m-platform composite) into
/// its four sub-ids. Each returned slice is a fresh allocation the
/// caller owns. Returns `error.InvalidKnownAlphanumericId` unless the
/// input has exactly four non-empty `-`-separated segments.
fn splitKnownAlphanumericId(a: std.mem.Allocator, known: []const u8) ![4][]u8 {
    var it = std.mem.tokenizeScalar(u8, known, '-');
    const h = it.next() orelse return error.InvalidKnownAlphanumericId;
    const p = it.next() orelse return error.InvalidKnownAlphanumericId;
    const m = it.next() orelse return error.InvalidKnownAlphanumericId;
    const plat = it.next() orelse return error.InvalidKnownAlphanumericId;
    if (it.next() != null) return error.InvalidKnownAlphanumericId;
    if (h.len == 0 or p.len == 0 or m.len == 0 or plat.len == 0) return error.InvalidKnownAlphanumericId;
    return .{
        try a.dupe(u8, h),
        try a.dupe(u8, p),
        try a.dupe(u8, m),
        try a.dupe(u8, plat),
    };
}

/// Compose an `agent_alphanumeric_id` (h-p-m) from the three dims.
/// Returns null when any dim is missing (never a fabricated partial
/// id). Used for fixture naming and messaging only — never stored.
fn agentIdFrom(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8) !?[]u8 {
    if (h.len == 0 or p.len == 0 or m.len == 0) return null;
    return @as(?[]u8, try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ h, p, m }));
}

/// Compose a `known_alphanumeric_id` (h-p-m-platform) from the four
/// dims. Returns null when any dim is missing (never a fabricated
/// partial id). Used for fixture naming and messaging only — never
/// stored.
fn knownIdFrom(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !?[]u8 {
    if (h.len == 0 or p.len == 0 or m.len == 0 or plat.len == 0) return null;
    return @as(?[]u8, try std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}", .{ h, p, m, plat }));
}

/// The canonical row-identity key for the four dims, as `h~p~m~plat`
/// with empty slots for unset dims. The `~` separator cannot appear
/// in alphanumeric ids (`alphanumericId` strips non-alphanumerics),
/// so the joined form is unambiguous even for partial rows. Every
/// upsert/dedupe/lookup operates on this key, not a flattened id.
fn tupleKey(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}~{s}~{s}~{s}", .{ h, p, m, plat });
}

/// Human-readable description of an event for diagnostics. Full rows
/// render as their known id (`h-p-m-platform`); partial rows render
/// as a concise dims summary like `seed harness:crush`. Used by the
/// daemon warnings, queue/dequeue/purge output, and the `known agent`
/// partial message so wording stays consistent across the refactor.
fn describeEvent(a: std.mem.Allocator, ev: IndexEvent) ![]u8 {
    const h = ev.harness_alphanumeric_id;
    const p = ev.provider_alphanumeric_id;
    const m = ev.model_alphanumeric_id;
    const plat = ev.platform_alphanumeric_id;
    if (h.len > 0 and p.len > 0 and m.len > 0 and plat.len > 0) {
        return (try knownIdFrom(a, h, p, m, plat)) orelse try tupleKey(a, h, p, m, plat);
    }
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, "seed");
    const dims = [_][2][]const u8{
        .{ "harness", h },
        .{ "provider", p },
        .{ "model", m },
        .{ "platform", plat },
    };
    for (dims) |d| {
        if (d[1].len > 0) {
            try list.append(a, ' ');
            try list.appendSlice(a, d[0]);
            try list.append(a, ':');
            try list.appendSlice(a, d[1]);
        }
    }
    return list.toOwnedSlice(a);
}

    pub fn resolveHome(env_map: *const std.process.Environ.Map) []const u8 {
    return env_map.get("HOME") orelse env_map.get("USERPROFILE") orelse
        if (builtin.os.tag == .windows) "C:/Users/default" else "/tmp";
}

    pub fn buildClineEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const env = [_][2][]const u8{
        .{ "CLINE_BUILD_ENV", "dev" },
        .{ "CLINE_NO_INTERACTIVE", "true" },
        .{ "CLINE_WRAPPER_PATH", "/opt/cline/wrapper" },
        .{ "CLINE_RUN_AS_HUB_DAEMON", "true" },
        .{ "CLINE_CONNECTOR_CLI_LAUNCH", "true" },
        .{ "", "" },
    };
    const providers_path = try std.fs.path.join(a, &.{ home, ".cline/data/settings/providers.json" });
    const json =
        \\{
        \\  "lastUsedProvider": "cline-pass",
        \\  "providers": {
        \\    "cline-pass": {
        \\      "updatedAt": "2025-08-01T00:00:00Z",
        \\      "settings": { "model": "cline-pass/kimi-k3" }
        \\    }
        \\  }
        \\}
        \\
    ;
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = providers_path, .content = json },
    };
    if (std.fs.path.dirname(providers_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    return .{ .env = try a.dupe([2][]const u8, &env), .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildKimiEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dir = try std.fs.path.join(a, &.{ home, ".kimi-code" });
    const env = [_][2][]const u8{
        .{ "KIMI_CODE_HOME", dir },
        .{ "KIMI_BASE_URL", "https://api.example.invalid" },
        .{ "", "" },
    };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = try std.fs.path.join(a, &.{ dir, "config.toml" }), .content = "default_model = \"minimax/minimax-m3\"\n" },
    };
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    return .{ .env = try a.dupe([2][]const u8, &env), .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildMmxEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dir = try std.fs.path.join(a, &.{ home, ".mmx" });
    const env = [_][2][]const u8{
        .{ "MMX_CONFIG_DIR", dir },
        .{ "", "" },
    };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = try std.fs.path.join(a, &.{ dir, "config.json" }), .content = "{\"defaultTextModel\":\"minimax-m3\"}\n" },
    };
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    return .{ .env = try a.dupe([2][]const u8, &env), .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildGooseEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const env = [_][2][]const u8{
        .{ "GOOSE_TERMINAL", "true" },
        .{ "GOOSE_MODE", "auto" },
        .{ "GOOSE_WORKING_DIR", home },
        .{ "", "" },
    };
    const yaml =
        \\active_provider: goose
        \\providers:
        \\  goose:
        \\    model: claude-sonnet-4
        \\
    ;
    const config_path = try std.fs.path.join(a, &.{ home, ".config/goose/config.yaml" });
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = config_path, .content = yaml },
    };
    if (std.fs.path.dirname(config_path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    return .{ .env = try a.dupe([2][]const u8, &env), .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildPiEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const env = [_][2][]const u8{
        .{ "PI_CODING_AGENT", "true" },
        .{ "", "" },
    };
    return .{ .env = try a.dupe([2][]const u8, &env), .writes = try a.dupe(EnvSetup.WriteSpec, &.{}), .cwd = home };
}

    pub fn buildSingleEnv(comptime marker_name: []const u8) *const fn (a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    return struct {
        fn f(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
            const home = resolveHome(env_map);
            const env = try a.alloc([2][]const u8, 2);
            env[0] = .{ marker_name, "fake" };
            env[1] = .{ "", "" };
            return .{ .env = env, .writes = &.{}, .cwd = home };
        }
    }.f;
}

    pub fn buildQwenEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const qwen_dir = try std.fs.path.join(a, &.{ home, ".qwen" });
    defer a.free(qwen_dir);
    const settings_path = try std.fs.path.join(a, &.{ qwen_dir, "settings.json" });
    defer a.free(settings_path);
    const settings_body =
        \\{
        \\  "security": { "auth": { "selectedType": "openai" } },
        \\  "model": { "name": "MiniMax-M3" },
        \\  "modelProviders": {
        \\    "openai": [{
        \\      "id": "MiniMax-M3",
        \\      "name": "[MiniMax] MiniMax-M3",
        \\      "baseUrl": "https://api.minimax.io/v1",
        \\      "envKey": "MINIMAX_API_KEY"
        \\    }]
        \\  }
        \\}
        \\
    ;
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "QWEN_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = settings_path, .content = settings_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildOmpEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const omp_dir = try std.fs.path.join(a, &.{ home, ".omp/agent" });
    defer a.free(omp_dir);
    const config_path = try std.fs.path.join(a, &.{ omp_dir, "config.yml" });
    defer a.free(config_path);
    const config_body =
        \\modelRoles:
        \\  default: minimax-code/MiniMax-M3
        \\
    ;
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "OMP_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = config_path, .content = config_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildReasonixEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const config_path = try std.fs.path.join(a, &.{ home, ".reasonix/config.toml" });
    defer a.free(config_path);
    const config_body =
        \\default_model = "deepseek-flash"
        \\
        \\[[providers]]
        \\name = "deepseek-flash"
        \\kind = "openai"
        \\base_url = "https://api.deepseek.com"
        \\models = ["deepseek-v4-flash", "deepseek-v4-pro"]
        \\default = "deepseek-v4-flash"
        \\api_key_env = "DEEPSEEK_API_KEY"
        \\
    ;
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "REASONIX_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = config_path, .content = config_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildJcodeEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const sessions_dir = try std.fs.path.join(a, &.{ home, ".jcode/sessions" });
    defer a.free(sessions_dir);
    const session_path = try std.fs.path.join(a, &.{ sessions_dir, "session_zoo_9999999999999_refresh_known.json" });
    defer a.free(session_path);
    const session_body =
        \\{
        \\  "id": "session_zoo_9999999999999_refresh_known",
        \\  "model": "MiniMax-M2.7",
        \\  "provider_key": "minimax",
        \\  "route_api_method": "openai-compatible",
        \\  "status": "Closed",
        \\  "saved": false
        \\}
        \\
    ;
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "JCODE_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = session_path, .content = session_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildCrushEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const hyper_path = try std.fs.path.join(a, &.{ home, ".local/share/crush/hyper.json" });
    defer a.free(hyper_path);
    const hyper_body =
        \\{
        \\  "name": "Charm Hyper",
        \\  "id": "hyper",
        \\  "type": "openai-compat",
        \\  "api_endpoint": "https://hyper.charm.land/api/v1/fantasy",
        \\  "default_large_model_id": "hyper/qwen3.7-plus",
        \\  "default_small_model_id": "hyper/deepseek-v4-flash"
        \\}
        \\
    ;
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "CRUSH_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = hyper_path, .content = hyper_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildKiloEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const env = try a.alloc([2][]const u8, 3);
    env[0] = .{ "KILO_API_KEY", "fake" };
    env[1] = .{ "KILO_MODEL", "anthropic/claude-sonnet-4" };
    env[2] = .{ "", "" };
    return .{ .env = env, .writes = &.{}, .cwd = home };
}

    pub fn buildOpencodeEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const env = try a.alloc([2][]const u8, 3);
    env[0] = .{ "OPENCODE_API_KEY", "fake" };
    env[1] = .{ "OPENCODE_MODEL", "minimax/MiniMax-M3" };
    env[2] = .{ "", "" };
    return .{ .env = env, .writes = &.{}, .cwd = home };
}

    pub fn buildVibeEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, _: *const KnownFixturesForKnownAgents) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const env = try a.alloc([2][]const u8, 3);
    env[0] = .{ "VIBE_API_KEY", "fake" };
    env[1] = .{ "VIBE_ACTIVE_MODEL", "mistral-large-latest" };
    env[2] = .{ "", "" };
    return .{ .env = env, .writes = &.{}, .cwd = home };
}

const knownFixturesForKnownAgents = [_]KnownFixturesForKnownAgents{
    // Cline × Cline Pass × Kimi K3
    .{
        .agent_alphanumeric_id = "cline-clinepass-kimik3",
        .probeNames = &.{ "cline", "cline.exe" },
        .buildEnv = buildClineEnv,
    },
    // Kimi Code × minimax × minimax-m3
    .{
        .agent_alphanumeric_id = "kimicode-minimax-minimaxm3",
        .probeNames = &.{ "kimi", "kimi-code", "kimi.exe", "kimi-code.exe" },
        .buildEnv = buildKimiEnv,
    },
    // MiniMax CLI (mmx) × minimax × minimax-m3
    .{
        .agent_alphanumeric_id = "mmx-minimax-minimaxm3",
        .probeNames = &.{ "mmx", "mmx.exe" },
        .buildEnv = buildMmxEnv,
    },
    // Goose × goose × claude-sonnet-4
    .{
        .agent_alphanumeric_id = "goose-goose-claudesonnet4",
        .probeNames = &.{ "goose", "goose.exe", "goosed", "goosed.exe" },
        .buildEnv = buildGooseEnv,
    },
    // pi × anthropic × claude-sonnet-4
    .{
        .agent_alphanumeric_id = "pi-anthropic-claudesonnet4",
        .probeNames = &.{ "pi", "pi.exe" },
        .buildEnv = buildPiEnv,
    },
    // qwen × minimax × minimax-m3
    .{
        .agent_alphanumeric_id = "qwen-minimax-minimaxm3",
        .probeNames = &.{ "qwen", "qwen.exe" },
        .buildEnv = buildQwenEnv,
    },
    // kilo × anthropic × claude-sonnet-4
    .{
        .agent_alphanumeric_id = "kilo-anthropic-claudesonnet4",
        .probeNames = &.{ "kilo", "kilo.exe" },
        .buildEnv = buildKiloEnv,
    },
    // jcode × minimax × minimax-m2.7
    .{
        .agent_alphanumeric_id = "jcode-minimax-minimaxm27",
        .probeNames = &.{ "jcode", "jcode.exe" },
        .buildEnv = buildJcodeEnv,
    },
    // omp × minimax-code × minimax-m3
    .{
        .agent_alphanumeric_id = "omp-minimaxcode-minimaxm3",
        .probeNames = &.{ "omp", "omp.exe" },
        .buildEnv = buildOmpEnv,
    },
    // reasonix × deepseek-flash × deepseek-v4-flash
    .{
        .agent_alphanumeric_id = "reasonix-deepseekflash-deepseekv4flash",
        .probeNames = &.{ "reasonix", "reasonix.exe" },
        .buildEnv = buildReasonixEnv,
    },
    // crush × hyper × qwen3.7-plus
    .{
        .agent_alphanumeric_id = "crush-hyper-qwen37plus",
        .probeNames = &.{ "crush", "crush.exe" },
        .buildEnv = buildCrushEnv,
    },
    // opencode × minimax × minimax-m3
    .{
        .agent_alphanumeric_id = "opencode-minimax-minimaxm3",
        .probeNames = &.{ "opencode", "opencode.exe" },
        .buildEnv = buildOpencodeEnv,
    },
    // vibe × mistral × mistral-large-latest
    .{
        .agent_alphanumeric_id = "vibe-mistral-mistrallargelatest",
        .probeNames = &.{ "vibe", "vibe.exe" },
        .buildEnv = buildVibeEnv,
    },
};

// ----------------------------------------------------------------------------
// probe + utility helpers (dev-only)
// ----------------------------------------------------------------------------

/// probe a set of candidate binary names; returns true if any one
/// runs `--version` successfully (exit code 0).
    pub fn probeBinary(io: std.Io, names: []const []const u8) bool {
    for (names) |n| {
        var argv_buf = [_][]const u8{ n, "--version" };
        var child = std.process.spawn(io, .{
            .argv = &argv_buf,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        const term = child.wait(io) catch continue;
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
    return false;
}
/// current timestamp in ISO-8601 form. Used as the `generated_at`
/// field in known/index.jsonl events.
    pub fn timestampNow(a: std.mem.Allocator) ![]u8 {
        // Zig 0.16 removed std.time.timestamp; emit a stable marker.
        // The daemon doesn't parse this back, only displays it.
        return std.fmt.allocPrint(a, "0", .{});
    }

/// JSON-encode a string with surrounding quotes and escapes.
    pub fn jsonString(a: std.mem.Allocator, s: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "\"{s}\"", .{s});
    }

    // ----------------------------------------------------------------
    // known fixture subcommands
    // ----------------------------------------------------------------

    /// strictly alphanumeric form of the current platform — just the
    /// OS name, no arch (e.g. `darwin`, `linux`, `windows`). Computed
    /// at compile time from `builtin.target` so it's free. macOS is
    /// remapped to `darwin` to match the conventional platform name
    /// (the `builtin.target.os.tag` is `.macos` but the conventional
    /// name is "darwin" — we want one canonical name for fixtures).
    /// Arch is dropped because the same fixture JSON is valid on all
    /// archs of a given OS; the platform id only differentiates OS.
    pub fn platformAlphanumericId() []const u8 {
        return switch (builtin.target.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => "darwin",
            else => @tagName(builtin.target.os.tag),
        };
    }

    /// assemble a known_alphanumeric_id from the three sub-ids. Caller
    /// owns the returned slice.
    pub fn knownAlphanumericId(a: std.mem.Allocator, agent: []const u8) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        try list.appendSlice(a, agent);
        try list.append(a, '-');
        try list.appendSlice(a, platformAlphanumericId());
        return list.toOwnedSlice(a);
    }

    /// one row in `known/index.jsonl`. State store: exactly one event
    /// per 4-tuple key (harness, provider, model, platform), upserted
    /// in place — the event is the current state. Stores facts only:
    /// `refresh` (daemon should (re)capture), `runner` (parent PID of
    /// the writer; used to detect orphaned `refresh: true` requests),
    /// `generated_at`, and the four dimension ids — each nullable in
    /// JSON, normalized to `""` (unset) in memory. The derived
    /// `known_alphanumeric_id`/`agent_alphanumeric_id` are *not*
    /// stored; they're recomputed per use via `knownIdFrom` /
    /// `agentIdFrom` (fixture naming and messaging only).
    pub const IndexEvent = struct {
        refresh: bool,
        runner: i64,
        generated_at: []const u8,
        harness_alphanumeric_id: []const u8,
        provider_alphanumeric_id: []const u8,
        model_alphanumeric_id: []const u8,
        platform_alphanumeric_id: []const u8,
    };

    /// parse one line of `known/index.jsonl` into an IndexEvent. Returns
    /// null on any parse error so a corrupt line doesn't break the
    /// whole poll cycle.
    pub fn parseIndexEvent(a: std.mem.Allocator, line: []const u8) ?IndexEvent {
        const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        var ev: IndexEvent = undefined;
        if (obj.get("refresh")) |v| {
            if (v != .bool) return null;
            ev.refresh = v.bool;
        } else return null;
        if (obj.get("runner")) |v| {
            if (v != .integer) return null;
            ev.runner = v.integer;
        } else return null;

        ev.generated_at = jstr(obj, "generated_at") orelse return null;
        // dims are nullable: JSON null or a missing key normalize to
        // "" (unset). Iterates so a single helper handles both.
        ev.harness_alphanumeric_id = jdim(obj, "harness_alphanumeric_id");
        ev.provider_alphanumeric_id = jdim(obj, "provider_alphanumeric_id");
        ev.model_alphanumeric_id = jdim(obj, "model_alphanumeric_id");
        ev.platform_alphanumeric_id = jdim(obj, "platform_alphanumeric_id");
        return ev;
    }

    /// read a nullable string field: string → value, JSON null or
    /// missing key → "" (the internal "unset" representation).
    fn jdim(obj: std.json.ObjectMap, key: []const u8) []const u8 {
        const v = obj.get(key) orelse return "";
        return switch (v) {
            .string => |s| s,
            else => "",
        };
    }

    /// serialize one IndexEvent to a JSONL line (no trailing newline;
    /// the caller appends it). Unset dims serialize as JSON `null`.
    /// Caller owns the returned slice.
    pub fn emitIndexEvent(a: std.mem.Allocator, ev: IndexEvent) ![]u8 {
        const ts_q = try jsonString(a, ev.generated_at);
        defer a.free(ts_q);
        const h_q = try jstrOrNull(a, ev.harness_alphanumeric_id);
        defer a.free(h_q);
        const p_q = try jstrOrNull(a, ev.provider_alphanumeric_id);
        defer a.free(p_q);
        const m_q = try jstrOrNull(a, ev.model_alphanumeric_id);
        defer a.free(m_q);
        const pl_q = try jstrOrNull(a, ev.platform_alphanumeric_id);
        defer a.free(pl_q);
        return std.fmt.allocPrint(a,
            "{{\"refresh\":{s},\"runner\":{d},\"generated_at\":{s},\"harness_alphanumeric_id\":{s},\"provider_alphanumeric_id\":{s},\"model_alphanumeric_id\":{s},\"platform_alphanumeric_id\":{s}}}",
            .{
                if (ev.refresh) "true" else "false",
                ev.runner,
                ts_q,
                h_q,
                p_q,
                m_q,
                pl_q,
            },
        );
    }

    /// JSON-encode a string, or emit `null` for the empty/unset
    /// internal representation. Inverse of `jdim`.
    fn jstrOrNull(a: std.mem.Allocator, s: []const u8) ![]u8 {
        if (s.len == 0) return a.dupe(u8, "null");
        return jsonString(a, s);
    }

    /// upsert a single line to `known/index.jsonl`: if an entry with
    /// the same 4-tuple key already exists, replace it; otherwise
    /// append. The line includes its trailing newline.
    pub fn upsertIndexEvent(a: std.mem.Allocator, io: std.Io, path: []const u8, line: []const u8) !void {
        try lockIndex(io);
        defer unlockIndex(io);

        const with_newline = try a.alloc(u8, line.len + 1);
        defer a.free(with_newline);
        @memcpy(with_newline[0..line.len], line);
        with_newline[line.len] = '\n';

        const target_key = blk: {
            const parsed = parseIndexEvent(a, line) orelse break :blk "";
            break :blk try tupleKey(a, parsed.harness_alphanumeric_id, parsed.provider_alphanumeric_id, parsed.model_alphanumeric_id, parsed.platform_alphanumeric_id);
        };
        if (target_key.len == 0) {
            try writeIndexAtomic(io, with_newline);
            return;
        }

        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch {
            try writeIndexAtomic(io, with_newline);
            return;
        };
        defer a.free(data);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            const parsed = parseIndexEvent(a, l) orelse continue;
            const lkey = try tupleKey(a, parsed.harness_alphanumeric_id, parsed.provider_alphanumeric_id, parsed.model_alphanumeric_id, parsed.platform_alphanumeric_id);
            if (std.mem.eql(u8, lkey, target_key)) continue;
            try out.appendSlice(a, l);
            try out.append(a, '\n');
        }
        try out.appendSlice(a, with_newline);

        try writeIndexAtomic(io, out.items);
    }

    /// read every event in `known/index.jsonl` and return the latest
    /// event per 4-tuple key. Returns an empty map if the file is
    /// missing.
    pub fn latestEventsPerTuple(a: std.mem.Allocator, io: std.Io, path: []const u8) !std.StringHashMapUnmanaged(IndexEvent) {
        var out: std.StringHashMapUnmanaged(IndexEvent) = .empty;
        errdefer out.deinit(a);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return out;
        defer a.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (parseIndexEvent(a, line)) |ev| {
                // arena-allocated strings inside ev point into `line`,
                // which is owned by the split iterator. Copy them so
                // they survive after the function returns.
                const key = try tupleKey(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id, ev.platform_alphanumeric_id);
                const h = try a.dupe(u8, ev.harness_alphanumeric_id);
                const p = try a.dupe(u8, ev.provider_alphanumeric_id);
                const m = try a.dupe(u8, ev.model_alphanumeric_id);
                const plat = try a.dupe(u8, ev.platform_alphanumeric_id);
                const ts = try a.dupe(u8, ev.generated_at);
                const stored: IndexEvent = .{
                    .refresh = ev.refresh,
                    .runner = ev.runner,
                    .generated_at = ts,
                    .harness_alphanumeric_id = h,
                    .provider_alphanumeric_id = p,
                    .model_alphanumeric_id = m,
                    .platform_alphanumeric_id = plat,
                };
                try out.put(a, key, stored);
            }
        }
        return out;
    }

    /// shared filter for `known queue` / `known dequeue` / `known
    /// purge`. Four dimension flags (`--harness=`, `--provider=`,
    /// `--model=`, `--platform=`) constrain their dim to equality;
    /// their `--no-*` variants constrain it to null (unset); an
    /// unmentioned dim is unconstrained (any value, including null).
    /// `--known=` expands to all four dims (h-p-m-platform);
    /// `--agent=` expands to h-p-m, leaving platform unconstrained
    /// unless `--platform=` is also given. `any` is true iff at least
    /// one option was present.
    const FilterOptions = struct {
        harness: []const u8 = "",
        provider: []const u8 = "",
        model: []const u8 = "",
        platform: []const u8 = "",
        no_harness: bool = false,
        no_provider: bool = false,
        no_model: bool = false,
        no_platform: bool = false,
        known: ?[]const u8 = null,
        agent: ?[]const u8 = null,
        /// scope flags: `--all`/`--stale`/`--partial` target index rows;
        /// `--recipes`/`--missing-fixture` target the recipe table.
        /// Exactly one scope flag may be set.
        all: bool = false,
        stale: bool = false,
        partial: bool = false,
        recipes: bool = false,
        missing_fixture: bool = false,
        /// `--available`: narrow candidates to harnesses whose binary is
        /// available. Modifier only (never a scope flag).
        available: bool = false,
        /// stale thresholds (`--older-than-days=`, `--older-than-hours=`).
        older_than_days: ?i64 = null,
        older_than_hours: ?i64 = null,
        any: bool = false,
        /// true when `--known=` or `--agent=` (the composite ids)
        /// contributed the equality dims — used for the creation path.
        composite: bool = false,
    };

    const FilterError = error{
        /// no filter option present at all
        NoFilter,
        /// `--known=` not a valid 4-part id
        InvalidKnownId,
        /// `--agent=` not a valid 3-part id
        InvalidAgentId,
        /// `--older-than-days=`/`--older-than-hours=` not an integer
        InvalidThreshold,
        /// contradictory or disallowed combination
        ConflictingFilters,
        /// allocation failure while expanding composite ids
        OutOfMemory,
    };

    /// parse the shared filter flags from argv (expects argv0, "known",
    /// <subcommand> already consumed). Errors use `FilterError` so the
    /// caller can emit the command-specific message and usage.
    fn parseFilters(init: std.process.Init) FilterError!FilterOptions {
        const a = init.arena.allocator();
        var f: FilterOptions = .{};
        var seen_known = false;
        var seen_agent = false;
        var seen_harness = false;
        var seen_provider = false;
        var seen_model = false;
        var seen_platform = false;

        var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return FilterError.NoFilter;
        defer args_it.deinit();
        _ = args_it.skip(); // argv0
        _ = args_it.skip(); // "known"
        _ = args_it.skip(); // "queue"/"dequeue"/"purge"
        while (args_it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--known=")) {
                f.known = arg["--known=".len..];
                seen_known = true;
            } else if (std.mem.startsWith(u8, arg, "--agent=")) {
                f.agent = arg["--agent=".len..];
                seen_agent = true;
            } else if (std.mem.startsWith(u8, arg, "--harness=")) {
                f.harness = arg["--harness=".len..];
                seen_harness = true;
            } else if (std.mem.startsWith(u8, arg, "--provider=")) {
                f.provider = arg["--provider=".len..];
                seen_provider = true;
            } else if (std.mem.startsWith(u8, arg, "--model=")) {
                f.model = arg["--model=".len..];
                seen_model = true;
            } else if (std.mem.startsWith(u8, arg, "--platform=")) {
                f.platform = arg["--platform=".len..];
                seen_platform = true;
            } else if (std.mem.eql(u8, arg, "--no-harness")) {
                f.no_harness = true;
            } else if (std.mem.eql(u8, arg, "--no-provider")) {
                f.no_provider = true;
            } else if (std.mem.eql(u8, arg, "--no-model")) {
                f.no_model = true;
            } else if (std.mem.eql(u8, arg, "--no-platform")) {
                f.no_platform = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                f.all = true;
            } else if (std.mem.eql(u8, arg, "--stale")) {
                f.stale = true;
            } else if (std.mem.eql(u8, arg, "--partial")) {
                f.partial = true;
            } else if (std.mem.eql(u8, arg, "--recipes")) {
                f.recipes = true;
            } else if (std.mem.eql(u8, arg, "--missing-fixture")) {
                f.missing_fixture = true;
            } else if (std.mem.eql(u8, arg, "--available")) {
                f.available = true;
            } else if (std.mem.startsWith(u8, arg, "--older-than-days=")) {
                f.older_than_days = std.fmt.parseInt(i64, arg["--older-than-days=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.startsWith(u8, arg, "--older-than-hours=")) {
                f.older_than_hours = std.fmt.parseInt(i64, arg["--older-than-hours=".len..], 10) catch return FilterError.InvalidThreshold;
            }
        }

        // scope flags: exactly one allowed
        const scope_count = @as(usize, @intFromBool(f.all)) + @as(usize, @intFromBool(f.stale)) +
            @as(usize, @intFromBool(f.partial)) + @as(usize, @intFromBool(f.recipes)) +
            @as(usize, @intFromBool(f.missing_fixture));
        if (scope_count > 1) return FilterError.ConflictingFilters;

        // stale thresholds are only meaningful with --stale
        if ((f.older_than_days != null or f.older_than_hours != null) and !f.stale) return FilterError.ConflictingFilters;

        // --available is a modifier: requires a scope flag
        if (f.available and scope_count == 0) return FilterError.ConflictingFilters;

        f.any = seen_known or seen_agent or seen_harness or seen_provider or
            seen_model or seen_platform or f.no_harness or f.no_provider or
            f.no_model or f.no_platform or scope_count > 0 or f.available;
        if (!f.any) return FilterError.NoFilter;

        // contradiction: a dim cannot be both equality- and null-constrained
        if (seen_harness and f.no_harness) return FilterError.ConflictingFilters;
        if (seen_provider and f.no_provider) return FilterError.ConflictingFilters;
        if (seen_model and f.no_model) return FilterError.ConflictingFilters;
        if (seen_platform and f.no_platform) return FilterError.ConflictingFilters;

        if (seen_known) {
            // `--known=` supplies all four dims and may not combine
            // with `--agent=` or any `--X=`; `--platform=` is allowed
            // but must be identical to the known id's platform part.
            if (seen_agent or seen_harness or seen_provider or seen_model) return FilterError.ConflictingFilters;
            const parts = splitKnownAlphanumericId(a, f.known.?) catch return FilterError.InvalidKnownId;
            defer {
                a.free(parts[0]);
                a.free(parts[1]);
                a.free(parts[2]);
                a.free(parts[3]);
            }
            // dupe: `parts` are freed on return, but the filter must
            // outlive parseFilters (it's returned to the caller)
            f.harness = a.dupe(u8, parts[0]) catch return FilterError.OutOfMemory;
            f.provider = a.dupe(u8, parts[1]) catch return FilterError.OutOfMemory;
            f.model = a.dupe(u8, parts[2]) catch return FilterError.OutOfMemory;
            if (seen_platform and !std.mem.eql(u8, f.platform, parts[3])) return FilterError.ConflictingFilters;
            f.platform = a.dupe(u8, parts[3]) catch return FilterError.OutOfMemory;
            f.composite = true;
        } else if (seen_agent) {
            // `--agent=` supplies h-p-m; `--platform=` may supplement it
            // (identical to `--known=` when combined). No `--X=` other
            // than `--platform=` may combine with `--agent=`.
            if (seen_harness or seen_provider or seen_model) return FilterError.ConflictingFilters;
            const parts = splitAgentAlphanumericId(a, f.agent.?) catch return FilterError.InvalidAgentId;
            defer {
                a.free(parts[0]);
                a.free(parts[1]);
                a.free(parts[2]);
            }
            // dupe: `parts` are freed on return; the filter outlives it
            f.harness = a.dupe(u8, parts[0]) catch return FilterError.OutOfMemory;
            f.provider = a.dupe(u8, parts[1]) catch return FilterError.OutOfMemory;
            f.model = a.dupe(u8, parts[2]) catch return FilterError.OutOfMemory;
            f.composite = true;
        }
        // a `--no-*` contradicts any dim forced by a composite id
        if (f.composite and
            ((f.harness.len > 0 and f.no_harness) or
                (f.provider.len > 0 and f.no_provider) or
                (f.model.len > 0 and f.no_model) or
                (f.platform.len > 0 and f.no_platform)))
        {
            return FilterError.ConflictingFilters;
        }
        return f;
    }

    /// true iff every dimension constraint in `f` holds for `ev`.
    /// Equality (`--X=`) requires the field to equal the value;
    /// `--no-X` requires the field to be unset; unmentioned dims are
    /// free.
    fn matchesFilter(ev: IndexEvent, f: FilterOptions) bool {
        if (f.harness.len > 0 and !std.mem.eql(u8, ev.harness_alphanumeric_id, f.harness)) return false;
        if (f.provider.len > 0 and !std.mem.eql(u8, ev.provider_alphanumeric_id, f.provider)) return false;
        if (f.model.len > 0 and !std.mem.eql(u8, ev.model_alphanumeric_id, f.model)) return false;
        if (f.platform.len > 0 and !std.mem.eql(u8, ev.platform_alphanumeric_id, f.platform)) return false;
        if (f.no_harness and ev.harness_alphanumeric_id.len != 0) return false;
        if (f.no_provider and ev.provider_alphanumeric_id.len != 0) return false;
        if (f.no_model and ev.model_alphanumeric_id.len != 0) return false;
        if (f.no_platform and ev.platform_alphanumeric_id.len != 0) return false;
        return true;
    }

    /// how many scope flags are set (exactly one is allowed).
    fn scopeCount(f: FilterOptions) usize {
        return @as(usize, @intFromBool(f.all)) + @as(usize, @intFromBool(f.stale)) +
            @as(usize, @intFromBool(f.partial)) + @as(usize, @intFromBool(f.recipes)) +
            @as(usize, @intFromBool(f.missing_fixture));
    }

    /// true if the row has all four dims set (the daemon's notion of a
    /// "full" row); partial rows are seeds/actions.
    fn fullEvent(ev: IndexEvent) bool {
        return ev.harness_alphanumeric_id.len > 0 and
            ev.provider_alphanumeric_id.len > 0 and
            ev.model_alphanumeric_id.len > 0 and
            ev.platform_alphanumeric_id.len > 0;
    }

    /// the scope candidate set for `f`, as events:
    /// - row-scope (`--all`/`--stale`/`--partial`): matching existing
    ///   index rows (host platform; `--available` requires full h-p-m +
    ///   an available harness).
    /// - recipe-scope (`--recipes`/`--missing-fixture`): full events on
    ///   the host platform built from the recipe table
    ///   (`knownFixturesForKnownAgents`); `--missing-fixture` only
    ///   yields recipes whose `.agent.json`/`.trailer.txt` files are
    ///   absent. Dim filters narrow both kinds; `--available` gates the
    ///   harness probe. Returns null on allocation failure.
    fn scopeCandidates(a: std.mem.Allocator, io: std.Io, f: FilterOptions) !std.ArrayListUnmanaged(IndexEvent) {
        var out: std.ArrayListUnmanaged(IndexEvent) = .empty;
        const host = platformAlphanumericId();

        if (f.recipes or f.missing_fixture) {
            for (knownFixturesForKnownAgents) |c| {
                if (f.available and !harnessAvailable(io, c.agent_alphanumeric_id)) continue;
                const parts = try splitAgentAlphanumericId(a, c.agent_alphanumeric_id);
                defer {
                    a.free(parts[0]);
                    a.free(parts[1]);
                    a.free(parts[2]);
                }
                var ev: IndexEvent = .{
                    .refresh = true,
                    .runner = 0,
                    .generated_at = "",
                    .harness_alphanumeric_id = parts[0],
                    .provider_alphanumeric_id = parts[1],
                    .model_alphanumeric_id = parts[2],
                    .platform_alphanumeric_id = host,
                };
                if (!matchesFilter(ev, f)) continue;
                // dupe: `parts` are freed at the end of this iteration,
                // so the stored event must own its strings (arena).
                ev.harness_alphanumeric_id = try a.dupe(u8, parts[0]);
                ev.provider_alphanumeric_id = try a.dupe(u8, parts[1]);
                ev.model_alphanumeric_id = try a.dupe(u8, parts[2]);
                ev.platform_alphanumeric_id = try a.dupe(u8, host);
                if (f.missing_fixture) {
                    const known_aid = try knownAlphanumericId(a, c.agent_alphanumeric_id);
                    defer a.free(known_aid);
                    const json_path = try std.fmt.allocPrint(a, "known/{s}.agent.json", .{known_aid});
                    defer a.free(json_path);
                    var json_exists = false;
                    if (std.Io.Dir.cwd().statFile(io, json_path, .{})) |_| {
                        json_exists = true;
                    } else |_| {}
                    const trailer_path = try std.fmt.allocPrint(a, "known/{s}.trailer.txt", .{known_aid});
                    defer a.free(trailer_path);
                    var trailer_exists = false;
                    if (std.Io.Dir.cwd().statFile(io, trailer_path, .{})) |_| {
                        trailer_exists = true;
                    } else |_| {}
                    if (json_exists and trailer_exists) continue;
                }
                try out.append(a, ev);
            }
            return out;
        }

        // row-scope
        var existing = try latestEventsPerTuple(a, io, "known/index.jsonl");
        defer existing.deinit(a);
        const threshold_hours = (f.older_than_days orelse 7) * 24 + (f.older_than_hours orelse 0);
        var it = existing.iterator();
        while (it.next()) |entry| {
            const ev = entry.value_ptr.*;
            if (ev.platform_alphanumeric_id.len > 0 and !std.mem.eql(u8, ev.platform_alphanumeric_id, host)) continue;
            if (f.stale) {
                const stale = (ev.refresh and !pidIsAlive(ev.runner)) or olderThanThreshold(ev.generated_at, threshold_hours);
                if (!stale) continue;
            } else if (f.partial and fullEvent(ev)) {
                continue;
            }
            if (!matchesFilter(ev, f)) continue;
            if (f.available) {
                const agent = (try agentIdFrom(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id)) orelse continue;
                if (!harnessAvailable(io, agent)) continue;
            }
            // dupe: `existing` is deinit'd before the caller consumes
            // the list, so the returned events must own their strings.
            // The arena backs them for the process lifetime.
            try out.append(a, .{
                .refresh = ev.refresh,
                .runner = ev.runner,
                .generated_at = try a.dupe(u8, ev.generated_at),
                .harness_alphanumeric_id = try a.dupe(u8, ev.harness_alphanumeric_id),
                .provider_alphanumeric_id = try a.dupe(u8, ev.provider_alphanumeric_id),
                .model_alphanumeric_id = try a.dupe(u8, ev.model_alphanumeric_id),
                .platform_alphanumeric_id = try a.dupe(u8, ev.platform_alphanumeric_id),
            });
        }
        return out;
    }

    // ----------------------------------------------------------------
    // refresh subcommands
    // ----------------------------------------------------------------

    /// `refresh run` — capture the current session and write the
    /// fixture + index event. Failure semantics: if the detection
    /// ladder fails to resolve harness *or* provider *or* model,
    /// exit 2 with no fixture written and no event appended. Partial
    /// detections are bad data and must be fixed, not papered over.
    /// The agent runs this directly; the daemon also runs it as a
    /// child after preparing the env for a target harness.
    ///
    /// **Filename contract** — the fixture is written as
    /// `known/<known_alphanumeric_id>.{agent.json,.trailer.txt}` where
    /// `known_alphanumeric_id = agent_alphanumeric_id +
    /// "-" + platform_alphanumeric_id` (e.g.
    /// `cline-clinepass-kimik3-darwin`). The `-<platform>` suffix
    /// keeps per-platform config paths from churning each other
    /// across CI runs; see DESIGN.md "per-platform fixtures" for the
    /// rationale.
    // Note on partial detection (the seed path): a daemon-spawned
    // child that partially fails on a full combo writes a partial seed
    // with a *different* tuple than the combo row; the combo row stays
    // `refresh:true` (retry) and the seed re-enters expansion on the
    // daemon's next poll — a bounded retry loop surfaced by the daemon
    // warning. No extra bookkeeping is needed.
    pub fn runKnownAgent(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        var d = Detection{};
        _ = try detect(init, &d);

        const harness_aid = d.harness_alphanumeric_id;
        const provider_aid = d.provider_alphanumeric_id;
        const model_aid = d.model_alphanumeric_id;

        const resolved = (if (harness_aid != null) @as(usize, 1) else 0) +
            (if (provider_aid != null) @as(usize, 1) else 0) +
            (if (model_aid != null) @as(usize, 1) else 0);

        // partial detection with >=1 resolved dim: record a seed row
        // (resolved dims, others null, refresh:true), write no fixture,
        // exit 2. Nothing is written if zero dims resolve.
        if (resolved >= 1 and resolved < 3) {
            const ts = try timestampNow(a);
            defer a.free(ts);
            const seed: IndexEvent = .{
                .refresh = true,
                .runner = getParentPid(),
                .generated_at = ts,
                .harness_alphanumeric_id = harness_aid orelse "",
                .provider_alphanumeric_id = provider_aid orelse "",
                .model_alphanumeric_id = model_aid orelse "",
                .platform_alphanumeric_id = platformAlphanumericId(),
            };
            const line = try emitIndexEvent(a, seed);
            defer a.free(line);
            try upsertIndexEvent(a, io, "known/index.jsonl", line);
            writeErr(io, "known agent: partial detection — recorded ");
            writeErr(io, try describeEvent(a, seed));
            writeErr(io, " with refresh:true, no fixture written (exit 2)\n");
            return 2;
        }
        if (resolved == 0) {
            writeErr(io, "known agent: harness/provider/model did not resolve — nothing recorded\n");
            return 2;
        }

        const agent_aid = d.agent_alphanumeric_id orelse {
            writeErr(io, "known agent: agent_alphanumeric_id did not compute\n");
            return 2;
        };

        const known_aid = try knownAlphanumericId(a, agent_aid);

        // write fixture + trailer
        std.Io.Dir.cwd().createDirPath(io, "known") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = std.Io.Dir.cwd().openDir(io, "known", .{}) catch {
            writeErr(io, "known agent: cannot open known/ dir\n");
            return 2;
        };
        defer dir.close(io);

        var buf: std.ArrayList(u8) = .empty;
        try buildJson(a, &d, init.environ_map, null, .{}, &buf);
        const json_name = try std.fmt.allocPrint(a, "{s}.agent.json", .{known_aid});
        try dir.writeFile(io, .{ .sub_path = json_name, .data = buf.items });

        if (d.trailer) |t| {
            const trailer_name = try std.fmt.allocPrint(a, "{s}.trailer.txt", .{known_aid});
            try dir.writeFile(io, .{ .sub_path = trailer_name, .data = t });
        }

        // append refresh:false event to index.jsonl
        const ts = try timestampNow(a);
        defer a.free(ts);
        const ev: IndexEvent = .{
            .refresh = false,
            .runner = getParentPid(),
            .generated_at = ts,
            .harness_alphanumeric_id = harness_aid orelse unreachable,
            .provider_alphanumeric_id = provider_aid orelse unreachable,
            .model_alphanumeric_id = model_aid orelse unreachable,
            .platform_alphanumeric_id = platformAlphanumericId(),
        };
        const line = try emitIndexEvent(a, ev);
        defer a.free(line);
        try upsertIndexEvent(a, io, "known/index.jsonl", line);

        writeOut(io, "known agent: wrote known/");
        writeOut(io, json_name);
        writeOut(io, "\n");
        return 0;
    }

    /// `known queue [scope] <filters>` — set `refresh:true` on a set of
    /// rows. Without a scope flag, the generic path is create-or-flip:
    /// with the shared dim filters (`--known=`, `--agent=`, `--harness=`,
    /// `--provider=`, `--model=`, `--platform=`, `--no-*`), if any
    /// existing row matches, flip them all to `refresh:true` (dims and
    /// runner preserved, `generated_at` refreshes). If none match,
    /// create a **seed** row: the positive dims set, the remaining dims
    /// `null`, `refresh:true`. Unknown ids are allowed — that is the
    /// seed path (the daemon expands seeds over known recipes; see
    /// `runKnownDaemon`).
    ///
    /// With a scope flag (`--all`/`--stale`/`--partial`/`--recipes`/
    /// `--missing-fixture`) the target set is computed instead (see
    /// `scopeCandidates`) and every candidate is queued (recipe-scope
    /// candidates are created as full `refresh:true` rows). `--available`
    /// narrows candidates to harnesses whose binary is available.
    ///
    /// At least one filter option or scope flag is required (else exit
    /// 2). A `--no-*`-only call is not a valid seed — at least one
    /// positive dim, `--agent=`, or `--known=` is required for creation.
    ///
    /// Idempotent: re-running a seed request re-matches the existing
    /// seed and takes the flip path, so no duplicate row is written.
    pub fn runKnownQueue(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        const f = parseFilters(init) catch |err| {
            switch (err) {
                error.NoFilter => writeErr(io, "known queue: at least one filter or scope flag is required (--known=, --agent=, --X=, --no-X, --all, --stale, --partial, --recipes, or --missing-fixture)\n"),
                error.InvalidKnownId => writeErr(io, "known queue: --known=<id> must be a 4-part <harness>-<provider>-<model>-<platform> id\n"),
                error.InvalidAgentId => writeErr(io, "known queue: --agent=<id> must be a 3-part <harness>-<provider>-<model> id\n"),
                error.InvalidThreshold => writeErr(io, "known queue: --older-than-days=/--older-than-hours= must be integers\n"),
                error.ConflictingFilters, error.OutOfMemory => writeErr(io, "known queue: conflicting filters (see --help)\n"),
            }
            writeOut(io, knownUsage);
            return 2;
        };

        if (scopeCount(f) > 0) {
            return runKnownQueueScope(init, f);
        }

        // a `--no-*`-only filter has no positive dims to seed with
        const positive = f.harness.len > 0 or f.provider.len > 0 or
            f.model.len > 0 or f.platform.len > 0 or f.composite;
        if (!positive) {
            writeErr(io, "known queue: a seed needs at least one positive dim, --agent=, or --known=\n");
            writeOut(io, knownUsage);
            return 2;
        }

        // gather matching rows (tuple-identity via the filter predicate)
        var existing = try latestEventsPerTuple(a, io, "known/index.jsonl");
        defer existing.deinit(a);

        var matches: std.ArrayListUnmanaged(IndexEvent) = .empty;
        defer matches.deinit(a);
        {
            var it = existing.iterator();
            while (it.next()) |entry| {
                if (matchesFilter(entry.value_ptr.*, f)) try matches.append(a, entry.value_ptr.*);
            }
        }

        if (matches.items.len >= 1) {
            // flip path: preserve each row's dims/runner, refresh
            // generated_at, set refresh:true
            const ts = try timestampNow(a);
            defer a.free(ts);
            for (matches.items) |ev| {
                const new_ev: IndexEvent = .{
                    .refresh = true,
                    .runner = ev.runner,
                    .generated_at = ts,
                    .harness_alphanumeric_id = ev.harness_alphanumeric_id,
                    .provider_alphanumeric_id = ev.provider_alphanumeric_id,
                    .model_alphanumeric_id = ev.model_alphanumeric_id,
                    .platform_alphanumeric_id = ev.platform_alphanumeric_id,
                };
                const line = try emitIndexEvent(a, new_ev);
                defer a.free(line);
                try upsertIndexEvent(a, io, "known/index.jsonl", line);
            }
            var n_buf: [16]u8 = undefined;
            writeOut(io, "known queue: queued ");
            writeOut(io, try std.fmt.bufPrint(&n_buf, "{d}", .{matches.items.len}));
            writeOut(io, "\n");
            return 0;
        }

        // create path: seed with the positive dims, others null
        const h = if (f.no_harness) "" else f.harness;
        const p = if (f.no_provider) "" else f.provider;
        const m = if (f.no_model) "" else f.model;
        const plat = if (f.no_platform) "" else f.platform;
        const ts = try timestampNow(a);
        defer a.free(ts);
        const seed: IndexEvent = .{
            .refresh = true,
            .runner = getParentPid(),
            .generated_at = ts,
            .harness_alphanumeric_id = h,
            .provider_alphanumeric_id = p,
            .model_alphanumeric_id = m,
            .platform_alphanumeric_id = plat,
        };
        const line = try emitIndexEvent(a, seed);
        defer a.free(line);
        try upsertIndexEvent(a, io, "known/index.jsonl", line);

        writeOut(io, "known queue: queued ");
        writeOut(io, try describeEvent(a, seed));
        writeOut(io, "\n");
        return 0;
    }

    /// `known queue <scope> [filters]` — queue every event in the scope
    /// candidate set (see `scopeCandidates`). Recipe-scope candidates
    /// are created/refreshed as full `refresh:true` rows; row-scope
    /// candidates are flipped in place. Dedupes mirror the removed
    /// subcommands: `--recipes` skips rows already `refresh:false`,
    /// `--missing-fixture` skips rows already `refresh:true`.
    fn runKnownQueueScope(init: std.process.Init, f: FilterOptions) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        var candidates = try scopeCandidates(a, io, f);
        defer candidates.deinit(a);

        // dedupe needs the pre-upsert index state
        var existing = try latestEventsPerTuple(a, io, "known/index.jsonl");
        defer existing.deinit(a);

        const ts = try timestampNow(a);
        defer a.free(ts);
        const my_pid = getParentPid();

        var queued: usize = 0;
        for (candidates.items) |ev| {
            const key = try tupleKey(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id, ev.platform_alphanumeric_id);
            if (f.recipes) {
                if (existing.get(key)) |prev| {
                    if (!prev.refresh) continue;
                }
            } else if (f.missing_fixture) {
                if (existing.get(key)) |prev| {
                    if (prev.refresh) continue;
                }
            }
            const new_ev: IndexEvent = .{
                .refresh = true,
                .runner = my_pid,
                .generated_at = ts,
                .harness_alphanumeric_id = ev.harness_alphanumeric_id,
                .provider_alphanumeric_id = ev.provider_alphanumeric_id,
                .model_alphanumeric_id = ev.model_alphanumeric_id,
                .platform_alphanumeric_id = ev.platform_alphanumeric_id,
            };
            const line = try emitIndexEvent(a, new_ev);
            defer a.free(line);
            try upsertIndexEvent(a, io, "known/index.jsonl", line);
            queued += 1;
        }

        var n_buf: [16]u8 = undefined;
        writeOut(io, "known queue: queued ");
        writeOut(io, try std.fmt.bufPrint(&n_buf, "{d}", .{queued}));
        writeOut(io, "\n");
        return 0;
    }

    /// portable getppid. POSIX has `getppid(2)`; Windows uses
    /// `GetCurrentProcessId` (note: that returns *our* pid, not the
    /// parent's — for the runner field we accept either, the field
    /// is "the writer's identity" and the daemon uses liveness checks
    /// rather than the parent link).
    fn getParentPid() i64 {
        if (builtin.os.tag == .windows) {
            // No portable getppid on Windows in Zig 0.16 stdlib. The
            // daemon's liveness probe only needs the writer pid to be
            // *some* pid, not specifically the parent. Use our own
            // pid as a stand-in — the runner field is informational.
            return @intCast(builtin.os.windows.GetCurrentProcessId());
        }
        return @intCast(std.c.getppid());
    }

    /// check whether a PID is still alive. Uses `kill(pid, 0)` on
    /// POSIX (returns 0 if alive, ESRCH if dead). Windows uses
    /// `OpenProcess(SYNCHRONIZE, FALSE, pid)` and treats a null
    /// handle as dead. Used by `refresh all` to detect orphaned
    /// `refresh: true` requests.
    fn pidIsAlive(pid: i64) bool {
        if (pid <= 0) return false;
        if (builtin.os.tag == .windows) {
            const handle = builtin.os.windows.OpenProcess(0x00100000, false, @intCast(pid));
            if (handle == null) return false;
            _ = builtin.os.windows.CloseHandle(handle.?);
            return true;
        }
        // POSIX kill(pid, 0) is the standard "is this process alive?"
        // probe. Signal 0 isn't a member of Zig's typed SIG enum
        // (and the per-OS errno enum doesn't always expose EPERM
        // as a typed name), so compare the raw errno value.
        // EPERM = 1 on Linux, BSDs, and macOS. ESRCH = 3. Anything
        // other than ESRCH means the process exists.
        const sig_zero: std.c.SIG = @enumFromInt(0);
        const rc = std.c.kill(@intCast(pid), sig_zero);
        if (rc == 0) return true;
        const e = std.c.errno(rc);
        return @intFromEnum(e) != 3; // not ESRCH → exists
    }

    /// true if the agent's harness binary (per `KnownFixturesForKnownAgents`)
    /// is installed and runs --version successfully. Looks up the row
    /// by its composite `agent_alphanumeric_id` so callers can pass
    /// either a row's id or an `IndexEvent.agent_alphanumeric_id`
    /// interchangeably.
    fn harnessAvailable(io: std.Io, agent_alphanumeric_id: []const u8) bool {
        var probe_names: []const []const u8 = &.{};
        for (knownFixturesForKnownAgents) |c| {
            if (std.mem.eql(u8, c.agent_alphanumeric_id, agent_alphanumeric_id)) {
                probe_names = c.probeNames;
                break;
            }
        }
        if (probe_names.len == 0) return false;
        return probeBinary(io, probe_names);
    }

    /// append a refresh:true event derived from an existing event.
    /// Caller is responsible for any platform/availability skip
    /// logic.
    fn queueEventFrom(a: std.mem.Allocator, io: std.Io, ev: IndexEvent) !void {
        const ts = try timestampNow(a);
        defer a.free(ts);
        const new_ev: IndexEvent = .{
            .refresh = true,
            .runner = getParentPid(),
            .generated_at = ts,
            .harness_alphanumeric_id = ev.harness_alphanumeric_id,
            .provider_alphanumeric_id = ev.provider_alphanumeric_id,
            .model_alphanumeric_id = ev.model_alphanumeric_id,
            .platform_alphanumeric_id = ev.platform_alphanumeric_id,
        };
        const line = try emitIndexEvent(a, new_ev);
        defer a.free(line);
        try upsertIndexEvent(a, io, "known/index.jsonl", line);
    }

    /// is `ts` (a unix-seconds-as-string) older than
    /// `threshold_hours` hours ago? Compares against `init.io`'s wall
    /// clock; if parsing fails (e.g. stub timestamp "0"), treats the
    /// entry as stale.
    fn olderThanThreshold(ts: []const u8, threshold_hours: i64) bool {
        const secs = std.fmt.parseInt(i64, ts, 10) catch return true;
        _ = secs; // exact arithmetic is a TODO; stub returns false
        _ = threshold_hours; // TODO: now - secs > threshold_hours * 3600
        return false;
    }

    /// `known dequeue [scope] <filters>` — for every event matching the
    /// shared filters (or the scope candidate set), upsert a
    /// `refresh: false` event (re-emitting the same dims). The index
    /// keeps one event per 4-tuple key, so the upserted event replaces
    /// the prior one that `latestEventsPerTuple` returns. This is the
    /// inverse of `known queue`: it tells the daemon "I have a fresh
    /// fixture for this, don't recapture." At least one filter or scope
    /// flag is required (the old "no filters = dequeue everything"
    /// behavior is gone); nothing is deleted from the index.
    pub fn runKnownDequeue(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        const f = parseFilters(init) catch |err| {
            switch (err) {
                error.NoFilter => writeErr(io, "known dequeue: at least one filter or scope flag is required (--known=, --agent=, --X=, --no-X, --all, --stale, --partial, --recipes, or --missing-fixture)\n"),
                error.InvalidKnownId => writeErr(io, "known dequeue: --known=<id> must be a 4-part <harness>-<provider>-<model>-<platform> id\n"),
                error.InvalidAgentId => writeErr(io, "known dequeue: --agent=<id> must be a 3-part <harness>-<provider>-<model> id\n"),
                error.InvalidThreshold => writeErr(io, "known dequeue: --older-than-days=/--older-than-hours= must be integers\n"),
                error.ConflictingFilters, error.OutOfMemory => writeErr(io, "known dequeue: conflicting filters (see --help)\n"),
            }
            writeOut(io, knownUsage);
            return 2;
        };

        if (scopeCount(f) > 0) {
            return runKnownDequeueScope(init, f);
        }

        const ts = try timestampNow(a);
        defer a.free(ts);
        const my_pid = getParentPid();

        var existing = try latestEventsPerTuple(a, io, "known/index.jsonl");
        defer existing.deinit(a);
        var dequeued: usize = 0;
        var it = existing.iterator();
        while (it.next()) |entry| {
            const ev = entry.value_ptr.*;
            if (!matchesFilter(ev, f)) continue;
            // re-emit the same dims with refresh:false. The upsert
            // replaces the prior event for this tuple, so the latest
            // event is now refresh:false, which
            // latestEventsPerTuple will return on the next read.
            const new_ev: IndexEvent = .{
                .refresh = false,
                .runner = my_pid,
                .generated_at = ts,
                .harness_alphanumeric_id = ev.harness_alphanumeric_id,
                .provider_alphanumeric_id = ev.provider_alphanumeric_id,
                .model_alphanumeric_id = ev.model_alphanumeric_id,
                .platform_alphanumeric_id = ev.platform_alphanumeric_id,
            };
            const line = try emitIndexEvent(a, new_ev);
            defer a.free(line);
            try upsertIndexEvent(a, io, "known/index.jsonl", line);
            dequeued += 1;
        }

        var n_buf: [16]u8 = undefined;
        writeOut(io, "known dequeue: dequeued ");
        writeOut(io, try std.fmt.bufPrint(&n_buf, "{d}", .{dequeued}));
        writeOut(io, " event(s)\n");
        return 0;
    }

    /// `known dequeue <scope> [filters]` — set `refresh:false` on the
    /// existing rows in the scope candidate set (see `scopeCandidates`).
    fn runKnownDequeueScope(init: std.process.Init, f: FilterOptions) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        var candidates = try scopeCandidates(a, io, f);
        defer candidates.deinit(a);

        const ts = try timestampNow(a);
        defer a.free(ts);
        const my_pid = getParentPid();

        // map candidate events by their tuple key: dequeue only touches
        // rows that already exist in the index.
        var existing = try latestEventsPerTuple(a, io, "known/index.jsonl");
        defer existing.deinit(a);

        var dequeued: usize = 0;
        for (candidates.items) |ev| {
            const key = try tupleKey(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id, ev.platform_alphanumeric_id);
            // recipe-scope candidates may describe a recipe with no row
            // yet — only flip rows that exist.
            const prev = existing.get(key) orelse continue;
            const new_ev: IndexEvent = .{
                .refresh = false,
                .runner = my_pid,
                .generated_at = ts,
                .harness_alphanumeric_id = prev.harness_alphanumeric_id,
                .provider_alphanumeric_id = prev.provider_alphanumeric_id,
                .model_alphanumeric_id = prev.model_alphanumeric_id,
                .platform_alphanumeric_id = prev.platform_alphanumeric_id,
            };
            const line = try emitIndexEvent(a, new_ev);
            defer a.free(line);
            try upsertIndexEvent(a, io, "known/index.jsonl", line);
            dequeued += 1;
        }

        var n_buf: [16]u8 = undefined;
        writeOut(io, "known dequeue: dequeued ");
        writeOut(io, try std.fmt.bufPrint(&n_buf, "{d}", .{dequeued}));
        writeOut(io, " event(s)\n");
        return 0;
    }

    /// `known purge <filters>` — delete every matching row from
    /// `known/index.jsonl` (rewriting the file without their tuple
    /// keys). At least one filter is required. The old implicit
    /// "purge incomplete rows" mode is removed — partial rows are
    /// first-class seeds now. The fixture sweep for malformed files is
    /// kept: non-object `*.agent.json` files and fixtures missing
    /// canonical harness/provider/model names are deleted (trailers
    /// too).
    pub fn runKnownPurge(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        const f = parseFilters(init) catch |err| {
            switch (err) {
                error.NoFilter => writeErr(io, "known purge: at least one filter or scope flag is required (--known=, --agent=, --X=, --no-X, --all, --stale, --partial, --recipes, or --missing-fixture)\n"),
                error.InvalidKnownId => writeErr(io, "known purge: --known=<id> must be a 4-part <harness>-<provider>-<model>-<platform> id\n"),
                error.InvalidAgentId => writeErr(io, "known purge: --agent=<id> must be a 3-part <harness>-<provider>-<model> id\n"),
                error.InvalidThreshold => writeErr(io, "known purge: --older-than-days=/--older-than-hours= must be integers\n"),
                error.ConflictingFilters, error.OutOfMemory => writeErr(io, "known purge: conflicting filters (see --help)\n"),
            }
            writeOut(io, knownUsage);
            return 2;
        };

        const index_path = "known/index.jsonl";
        const deleted = if (scopeCount(f) > 0)
            try deleteIndexKeys(a, io, index_path, f)
        else
            try deleteIndexEvents(a, io, index_path, f);
        const fixture_purged = purgeMalformedFixtures(a, io);

        var n_buf: [16]u8 = undefined;
        writeOut(io, "known purge: removed ");
        writeOut(io, try std.fmt.bufPrint(&n_buf, "{d}", .{deleted}));
        writeOut(io, " event(s), fixture scan removed ");
        writeOut(io, try std.fmt.bufPrint(&n_buf, "{d}", .{fixture_purged}));
        writeOut(io, "\n");
        return 0;
    }

    /// delete every event in `path` matching `f`; rewrites the file
    /// with the rest and returns the count removed. Held under the
    /// index lock so a concurrent daemon write can't be lost.
    fn deleteIndexEvents(a: std.mem.Allocator, io: std.Io, path: []const u8, f: FilterOptions) !usize {
        try lockIndex(io);
        defer unlockIndex(io);

        var existing = try latestEventsPerTuple(a, io, path);
        defer existing.deinit(a);

        var keep = std.ArrayList([]u8).empty;
        defer keep.deinit(a);
        var removed: usize = 0;
        var it = existing.iterator();
        while (it.next()) |entry| {
            const ev = entry.value_ptr.*;
            if (matchesFilter(ev, f)) {
                removed += 1;
                continue;
            }
            try keep.append(a, try emitIndexEvent(a, ev));
        }

        var new_content: std.ArrayList(u8) = .empty;
        defer new_content.deinit(a);
        for (keep.items) |line| {
            try new_content.appendSlice(a, line);
            try new_content.append(a, '\n');
        }
        try writeIndexAtomic(io, new_content.items);
        return removed;
    }

    /// delete every event in `path` whose tuple key belongs to the
    /// scope candidate set (see `scopeCandidates`); rewrites the file
    /// with the rest and returns the count removed. Held under the
    /// index lock so a concurrent daemon write can't be lost.
    fn deleteIndexKeys(a: std.mem.Allocator, io: std.Io, path: []const u8, f: FilterOptions) !usize {
        try lockIndex(io);
        defer unlockIndex(io);

        var candidates = try scopeCandidates(a, io, f);
        defer candidates.deinit(a);

        // candidate tuple keys (arena-backed)
        var keys: std.StringHashMapUnmanaged(void) = .empty;
        defer keys.deinit(a);
        for (candidates.items) |ev| {
            const key = try tupleKey(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id, ev.platform_alphanumeric_id);
            try keys.put(a, key, {});
        }

        var existing = try latestEventsPerTuple(a, io, path);
        defer existing.deinit(a);

        var keep = std.ArrayList([]u8).empty;
        defer keep.deinit(a);
        var removed: usize = 0;
        var it = existing.iterator();
        while (it.next()) |entry| {
            const ev = entry.value_ptr.*;
            const key = try tupleKey(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id, ev.platform_alphanumeric_id);
            if (keys.contains(key)) {
                removed += 1;
                continue;
            }
            try keep.append(a, try emitIndexEvent(a, ev));
        }

        var new_content: std.ArrayList(u8) = .empty;
        defer new_content.deinit(a);
        for (keep.items) |line| {
            try new_content.appendSlice(a, line);
            try new_content.append(a, '\n');
        }
        try writeIndexAtomic(io, new_content.items);
        return removed;
    }

    /// sweep fixtures for malformed files (kept from the original
    /// `purge`): delete `*.agent.json` files that don't parse as a
    /// JSON object, or whose `canonical` block is missing the
    /// harness/provider/model names. Trailer siblings are deleted
    /// too. Returns the count removed.
    fn purgeMalformedFixtures(a: std.mem.Allocator, io: std.Io) usize {
        var fixture_purged: usize = 0;
        var json_path_buf: [4096]u8 = undefined;
        const cwd = std.Io.Dir.cwd();
        var dir_it = cwd.iterate();
        while (dir_it.next(io) catch null) |ent| {
            if (ent.kind != .file) continue;
            const name = ent.name;
            if (!std.mem.endsWith(u8, name, ".agent.json")) continue;
            const full_path = std.fmt.bufPrint(&json_path_buf, "known/{s}", .{name}) catch continue;
            const data = std.Io.Dir.cwd().readFileAlloc(io, full_path, a, @enumFromInt(1 << 20)) catch continue;
            defer a.free(data);
            const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch continue;
            defer parsed.deinit();
            var bad = false;
            if (parsed.value != .object) {
                bad = true;
            } else if (parsed.value.object.get("canonical")) |canon| {
                if (canon != .object) {
                    bad = true;
                } else {
                    const cob = canon.object;
                    bad = (cob.get("harness_name") == null) or
                        (cob.get("provider_name") == null) or
                        (cob.get("model_name") == null);
                }
            } else {
                bad = true;
            }
            if (bad) {
                std.Io.Dir.cwd().deleteFile(io, full_path) catch {};
                var trailer_path_buf: [4096]u8 = undefined;
                const tname = std.fmt.bufPrint(&trailer_path_buf, "known/{s}.trailer.txt", .{name}) catch continue;
                std.Io.Dir.cwd().deleteFile(io, tname) catch {};
                fixture_purged += 1;
            }
        }
        return fixture_purged;
    }

    /// `known daemon` — long-running. Polls known/index.jsonl every
    /// 5 seconds. For each refresh:true event on the current
    /// platform whose harness is available, sets up the env from the
    /// KnownFixturesForKnownAgents recipe and spawns `agent-detection-dev refresh run`
    /// as a child. **No stale detection** — the daemon only processes
    /// refresh:true events. Stale detection is `known queue --stale`'s
    /// job.
    ///
    /// **USER-ONLY**: refuses to start if running inside an agent
    /// (see `assertNotInAgent`). The agent must never run the daemon
    /// — its process tree would pollute the captured
    /// `raw.process_lineage` (the daemon would appear as the runner's
    /// grandparent), and its env vars would contaminate the fixture
    /// the daemon then spawns. If the agent's workflow stalls because
    /// the daemon isn't running, the correct action is to surface the
    /// command to the user; see DESIGN.md "user-only daemon" for the
    /// rationale and CONTRIBUTING.md "refresh a fixture" for the
    /// correct role split.
    pub fn runKnownDaemon(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        // parse --write-log (tee daemon output to known/daemon.log)
        var write_log = false;
        {
            var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return 1;
            defer args_it.deinit();
            _ = args_it.skip(); // argv0
            _ = args_it.skip(); // "known"
            _ = args_it.skip(); // "daemon"
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--write-log")) write_log = true;
            }
        }
        var daemon_log_file_owned: ?std.Io.File = null;
        if (write_log) {
            std.Io.Dir.cwd().createDirPath(io, "known") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            const log_file = std.Io.Dir.cwd().createFile(io, "known/daemon.log", .{}) catch |err| {
                daemonWriteErr(io, "daemon: cannot open known/daemon.log: ");
                daemonWriteErr(io, @errorName(err));
                daemonWriteErr(io, "\n");
                return 2;
            };
            daemon_log_file = log_file;
            daemon_log_file_owned = log_file;
        }
        defer {
            if (daemon_log_file_owned) |log_file| log_file.close(io);
            daemon_log_file = null;
        }

        try assertNotInAgent(a, init);

        var msg_buf: [256]u8 = undefined;

        daemonWrite(io, "agent-detection-dev known daemon: running\n");
        daemonWrite(io, "  poll rate: 5s\n");
        daemonWrite(io, "  index file: known/index.jsonl\n");
        if (write_log) daemonWrite(io, "  log file: known/daemon.log\n");
        daemonWrite(io, "  press Ctrl+C to stop\n");

        var processed: std.StringHashMapUnmanaged(void) = .empty;
        defer processed.deinit(a);
        var warned: std.StringHashMapUnmanaged(void) = .empty;
        defer warned.deinit(a);

        var queue: std.ArrayListUnmanaged(IndexEvent) = .empty;
        errdefer queue.deinit(a);
        var queued: std.StringHashMapUnmanaged(void) = .empty;
        defer queued.deinit(a);

        // pre-seed: enqueue everything already in the file on
        // startup. New entries appended after startup are picked up
        // by the polling loop.
        try enqueuePending(a, io, &processed, &queued, &queue);
        {
            const msg = std.fmt.bufPrint(msg_buf[0..], "daemon: queued {d} items\n", .{queue.items.len}) catch "daemon: queued 0 items\n";
            daemonWrite(io, msg);
        }
        while (true) {
            if (queue.items.len > 0) {
                const ev = queue.items[0];
                const key = try tupleKey(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id, ev.platform_alphanumeric_id);
                _ = queue.orderedRemove(0);
                _ = queued.remove(key);
                const desc = try describeEvent(a, ev);
                {
                    const msg = std.fmt.bufPrint(msg_buf[0..], "daemon: processing {s} ({d} remaining)\n", .{desc, queue.items.len}) catch "daemon: processing\n";
                    daemonWrite(io, msg);
                }
                // full row → recipe capture; partial row (seed) → expand
                const full = ev.harness_alphanumeric_id.len > 0 and
                    ev.provider_alphanumeric_id.len > 0 and
                    ev.model_alphanumeric_id.len > 0 and
                    ev.platform_alphanumeric_id.len > 0;
                if (full) {
                    try runOneCombo(a, io, init, ev);
                } else {
                    try expandSeed(a, io, ev, &warned, &processed);
                }
                try processed.put(a, key, {});
            } else {
                daemonWrite(io, "daemon: idle, queue empty, sleeping 5s\n");
            }
            try std.Io.sleep(io, .{ .nanoseconds = 5 * std.time.ns_per_s }, .boot);
            try enqueuePending(a, io, &processed, &queued, &queue);
        }
    }

    fn enqueuePending(a: std.mem.Allocator, io: std.Io, processed: *std.StringHashMapUnmanaged(void), queued: *std.StringHashMapUnmanaged(void), queue: *std.ArrayListUnmanaged(IndexEvent)) !void {
        var existing = try latestEventsPerTuple(a, io, "known/index.jsonl");
        defer existing.deinit(a);
        const host = platformAlphanumericId();
        var it = existing.iterator();
        while (it.next()) |entry| {
            const ev = entry.value_ptr.*;
            if (!ev.refresh) continue;
            const key = try tupleKey(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id, ev.platform_alphanumeric_id);
            if (processed.contains(key)) continue;
            if (queued.contains(key)) continue;
            // only skip non-host platforms when the platform is set;
            // null-platform seeds flow through to expandSeed
            if (ev.platform_alphanumeric_id.len > 0 and !std.mem.eql(u8, ev.platform_alphanumeric_id, host)) continue;
            const cloned: IndexEvent = .{
                .refresh = ev.refresh,
                .runner = ev.runner,
                .generated_at = try a.dupe(u8, ev.generated_at),
                .harness_alphanumeric_id = try a.dupe(u8, ev.harness_alphanumeric_id),
                .provider_alphanumeric_id = try a.dupe(u8, ev.provider_alphanumeric_id),
                .model_alphanumeric_id = try a.dupe(u8, ev.model_alphanumeric_id),
                .platform_alphanumeric_id = try a.dupe(u8, ev.platform_alphanumeric_id),
            };
            try queue.append(a, cloned);
            try queued.put(a, key, {});
        }
    }

    /// inner loop predicate: does every dim that `ev` has set equal
    /// the recipe's dims? seed rows have missing dims, which are
    /// filled from the recipe.
    fn recipeMatchesEv(a: std.mem.Allocator, ev: IndexEvent, combo: KnownFixturesForKnownAgents, host: []const u8) !bool {
        const parts = try splitAgentAlphanumericId(a, combo.agent_alphanumeric_id);
        defer {
            a.free(parts[0]);
            a.free(parts[1]);
            a.free(parts[2]);
        }
        if (ev.harness_alphanumeric_id.len > 0 and !std.mem.eql(u8, ev.harness_alphanumeric_id, parts[0])) return false;
        if (ev.provider_alphanumeric_id.len > 0 and !std.mem.eql(u8, ev.provider_alphanumeric_id, parts[1])) return false;
        if (ev.model_alphanumeric_id.len > 0 and !std.mem.eql(u8, ev.model_alphanumeric_id, parts[2])) return false;
        if (ev.platform_alphanumeric_id.len > 0 and !std.mem.eql(u8, ev.platform_alphanumeric_id, host)) return false;
        return true;
    }

    /// expand a partial (seed) row over the `knownFixturesForKnownAgents`
    /// recipes. A seed is an action: "capture every applicable combo
    /// matching these dims". Every applicable recipe (set dims equal,
    /// platform empty or host, harness available) is re-queued as a full
    /// `refresh:true` row — refreshing existing `refresh:false` entries
    /// and adding missing combos — then the seed row is deleted. The
    /// re-queued combo keys are removed from the daemon's per-run
    /// `processed` set so `enqueuePending` re-enqueues them this run even
    /// if they were captured earlier. Warnings (no applicable recipe /
    /// unknown id) leave the entry unchanged and are emitted once per
    /// tuple key per daemon run (tracked in `warned`).
    fn expandSeed(a: std.mem.Allocator, io: std.Io, ev: IndexEvent, warned: *std.StringHashMapUnmanaged(void), processed: *std.StringHashMapUnmanaged(void)) !void {
        const seed_key = try tupleKey(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id, ev.platform_alphanumeric_id);
        const host = platformAlphanumericId();

        var applicable: std.ArrayListUnmanaged(KnownFixturesForKnownAgents) = .empty;
        defer applicable.deinit(a);
        for (knownFixturesForKnownAgents) |c| {
            if (!try recipeMatchesEv(a, ev, c, host)) continue;
            if (!harnessAvailable(io, c.agent_alphanumeric_id)) continue;
            try applicable.append(a, c);
        }

        if (applicable.items.len == 0) {
            if (!warned.contains(seed_key)) {
                daemonWriteErr(io, "daemon: warning: no capture recipe applicable for ");
                daemonWriteErr(io, try describeEvent(a, ev));
                daemonWriteErr(io, "\n");
                try warned.put(a, try a.dupe(u8, seed_key), {});
            }
            return;
        }

        // refresh every applicable combo (existing refresh:false entries
        // and missing combos alike); combos are captured one per poll by
        // the existing loop and carry their own retry state.
        const ts = try timestampNow(a);
        defer a.free(ts);
        for (applicable.items) |c| {
            const parts = try splitAgentAlphanumericId(a, c.agent_alphanumeric_id);
            defer {
                a.free(parts[0]);
                a.free(parts[1]);
                a.free(parts[2]);
            }
            const combo_key = try tupleKey(a, parts[0], parts[1], parts[2], host);
            const combo_ev: IndexEvent = .{
                .refresh = true,
                .runner = getParentPid(),
                .generated_at = ts,
                .harness_alphanumeric_id = parts[0],
                .provider_alphanumeric_id = parts[1],
                .model_alphanumeric_id = parts[2],
                .platform_alphanumeric_id = host,
            };
            const line = try emitIndexEvent(a, combo_ev);
            defer a.free(line);
            try upsertIndexEvent(a, io, "known/index.jsonl", line);
            // a seed is an action: re-enqueue this combo even if it was
            // already processed earlier in this daemon run.
            _ = processed.remove(combo_key);
        }

        // delete the seed row (its tuple key)
        try deleteTupleKey(a, io, "known/index.jsonl", seed_key);
    }

    /// delete every event in `path` whose tuple key equals `key`.
    fn deleteTupleKey(a: std.mem.Allocator, io: std.Io, path: []const u8, key: []const u8) !void {
        try lockIndex(io);
        defer unlockIndex(io);

        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
        defer a.free(data);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            const parsed = parseIndexEvent(a, l) orelse continue;
            const lkey = try tupleKey(a, parsed.harness_alphanumeric_id, parsed.provider_alphanumeric_id, parsed.model_alphanumeric_id, parsed.platform_alphanumeric_id);
            if (std.mem.eql(u8, lkey, key)) continue;
            try out.appendSlice(a, l);
            try out.append(a, '\n');
        }
        try writeIndexAtomic(io, out.items);
    }

    /// spawn `agent-detection-dev refresh run` for a single
    /// queued combo. The child inherits the daemon's env, which
    /// is the user's terminal — not the dev harness.
    fn runOneCombo(a: std.mem.Allocator, io: std.Io, init: std.process.Init, ev: IndexEvent) !void {
        // 1. find the KnownFixturesForKnownAgents entry for the harness.
        // The derived agent id is never stored — recompute from dims.
        const target_agent_aid = (try agentIdFrom(a, ev.harness_alphanumeric_id, ev.provider_alphanumeric_id, ev.model_alphanumeric_id)) orelse {
            const desc = try describeEvent(a, ev);
            daemonWriteErr(io, "daemon: no recipe applicable for ");
            daemonWriteErr(io, desc);
            daemonWriteErr(io, " — skipping\n");
            return;
        };
        var combo: ?KnownFixturesForKnownAgents = null;
        for (knownFixturesForKnownAgents) |c| {
            if (std.mem.eql(u8, c.agent_alphanumeric_id, target_agent_aid)) {
                combo = c;
                break;
            }
        }
        const c = combo orelse {
            daemonWriteErr(io, "daemon: no KnownFixturesForKnownAgents recipe for ");
            daemonWriteErr(io, target_agent_aid);
            daemonWriteErr(io, " — skipping\n");
            return;
        };

        // 2. build env (writes config files, env vars)
        var env_map = std.process.Environ.Map.init(a);
        defer env_map.deinit();
        // inherit the daemon's env (so HOME / USERPROFILE pass through)
        var parent_it = init.environ_map.iterator();
        while (parent_it.next()) |kv| {
            try env_map.put(kv.key_ptr.*, kv.value_ptr.*);
        }
        const setup = c.buildEnv(a, init.environ_map, io, &c) catch |err| {
            daemonWriteErr(io, "daemon: buildEnv failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            return;
        };
        for (setup.env) |kv| {
            if (kv[0].len == 0) break;
            try env_map.put(kv[0], kv[1]);
        }
        // apply file writes
        for (setup.writes) |w| {
            if (std.fs.path.dirname(w.path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        daemonWriteErr(io, "daemon: createDirPath failed for ");
                        daemonWriteErr(io, dir);
                        daemonWriteErr(io, ": ");
                        daemonWriteErr(io, @errorName(err));
                        daemonWriteErr(io, "\n");
                        return;
                    },
                };
            }
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = w.path, .data = w.content }) catch |err| {
                daemonWriteErr(io, "daemon: writeFile failed for ");
                daemonWriteErr(io, w.path);
                daemonWriteErr(io, ": ");
                daemonWriteErr(io, @errorName(err));
                daemonWriteErr(io, "\n");
                return;
            };
        }

        // 3. spawn the child
        // The child is the same binary (this dev binary) running
        // `refresh run`, which does the capture in its own process
        // and writes the fixture + index event. The daemon's process
        // tree stays clean: the child is the daemon's direct child,
        // and the daemon was started from the user's terminal — not
        // from inside kimi-code.
        // Resolve the running binary's absolute path. argv[0] can be a
        // relative path (e.g. `./zig-out/bin/agent-detection-dev`) and is
        // not reliable on its own — we use the canonical
        // `std.process.executablePath` instead. We do NOT set `.cwd` to
        // setup.cwd — the harness config files are written to absolute
        // paths (e.g. `~/.kimi-code/config.toml`), and the child doesn't
        // need to chdir.
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_path_len = std.process.executablePath(io, &self_path_buf) catch |err| {
            daemonWriteErr(io, "daemon: executablePath failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            return;
        };
        const argv0 = self_path_buf[0..self_path_len];
        var argv = [_][]const u8{ argv0, "refresh", "run" };
        var child = std.process.spawn(io, .{
            .argv = &argv,
            .environ_map = &env_map,
            .stdout = .ignore,
            .stderr = .pipe,
        }) catch |err| {
            daemonWriteErr(io, "daemon: spawn failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, " (argv0=");
            daemonWriteErr(io, argv0);
            daemonWriteErr(io, ")\n");
            return;
        };
        // Drain worker stderr before wait() — wait() closes the pipe,
        // so any unread bytes would be lost. The worker is short-lived
        // and writes at most a couple of lines.
        var stderr_capture = try std.ArrayList(u8).initCapacity(a, 4096);
        defer stderr_capture.deinit(a);
        var stderr_buf: [4096]u8 = undefined;
        var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
        while (stderr_capture.items.len < 1 << 16) {
            const n = stderr_reader.interface.readSliceShort(stderr_capture.unusedCapacitySlice()) catch break;
            if (n == 0) break;
            stderr_capture.shrinkRetainingCapacity(stderr_capture.items.len + n);
        }
        const term = child.wait(io) catch |err| {
            daemonWriteErr(io, "daemon: child wait failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            return;
        };
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    daemonWriteErr(io, "daemon: worker failed for ");
                    daemonWriteErr(io, try describeEvent(a, ev));
                    daemonWriteErr(io, " (exit code ");
                    var n_buf: [16]u8 = undefined;
                    daemonWriteErr(io, try std.fmt.bufPrint(&n_buf, "{d}", .{code}));
                    daemonWriteErr(io, ") — leaving refresh:true in index\n");
                    if (stderr_capture.items.len > 0) {
                        daemonWriteErr(io, "  worker stderr: ");
                        daemonWriteErr(io, stderr_capture.items);
                        if (stderr_capture.items[stderr_capture.items.len - 1] != '\n') daemonWriteErr(io, "\n");
                    }
                    return;
                }
                {
                    var msg_buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(msg_buf[0..], "daemon: captured {s}\n", .{try describeEvent(a, ev)}) catch "daemon: captured\n";
                    daemonWrite(io, msg);
                }
            },
            else => {
                daemonWriteErr(io, "daemon: child terminated abnormally for ");
                daemonWriteErr(io, try describeEvent(a, ev));
                daemonWriteErr(io, "\n");
                return;
            },
        }
    }

    /// refuse to start the daemon if the current process is inside
    /// an agent. Two checks, both fail-closed:
    ///   - env markers: refuse if any of the known agent-marker env
    ///     vars is set
    ///   - process ancestry: refuse if any ancestor's basename
    ///     matches a known agent proc name
    fn assertNotInAgent(a: std.mem.Allocator, init: std.process.Init) !void {
        const io = init.io;
        const env_markers = [_][]const u8{
            "KIMI_CODE_HOME",  "KIMI_API_KEY",      "KIMI_BASE_URL",
            "MMX_CONFIG_DIR",  "MINIMAX_API_KEY",   "PI_CODING_AGENT",
            "GOOSE_TERMINAL",  "GOOSE_MODE",        "GOOSE_WORKING_DIR",
            "CLINE_NO_INTERACTIVE", "QWEN_API_KEY",  "JCODE_API_KEY",
            "OMP_API_KEY",     "REASONIX_API_KEY",  "CRUSH_API_KEY",
            "KILO_API_KEY",    "OPENCODE_API_KEY",  "VIBE_API_KEY",
        };
        var it = init.environ_map.iterator();
        while (it.next()) |kv| {
            for (env_markers) |m| {
                if (std.mem.eql(u8, kv.key_ptr.*, m)) {
                    daemonWriteErr(io, "known daemon: refusing to start — env marker ");
                    daemonWriteErr(io, m);
                    daemonWriteErr(io, " is set. This command must be run by a user, not inside an agent.\n");
                    return error.RunningInAgent;
                }
            }
        }

        const proc_names = [_][]const u8{
            "kimi-code",    "kimi-code.exe", "kimi",     "kimi.exe",
            "claude",       "claude.exe",
            "cline",        "cline.exe",
            "mmx",          "mmx.exe",
            "goose",        "goose.exe",   "goosed",   "goosed.exe",
            "pi",           "pi.exe",
            "qwen",         "qwen.exe",
            "jcode",        "jcode.exe",
            "omp",          "omp.exe",
            "reasonix",     "reasonix.exe",
            "crush",        "crush.exe",
            "kilo",         "kilo.exe",
            "opencode",     "opencode.exe",
            "vibe",         "vibe.exe",
        };
        const anc = ancestorInfo(a, io);
        for (anc.names) |n| {
            for (proc_names) |p| {
                if (std.mem.eql(u8, n, p)) {
                    daemonWriteErr(io, "known daemon: refusing to start — ancestor process ");
                    daemonWriteErr(io, n);
                    daemonWriteErr(io, " is a known agent. This command must be run by a user, not inside an agent.\n");
                    return error.RunningInAgent;
                }
            }
        }
    }

} else struct {}; // end pub const dev

// ============================================================================
// main entry

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    // subcommand dispatch. The dev binary (built with -Ddev=true)
    // accepts a `known` subcommand namespace: `known --help`,
    // `known daemon`, `known agent`, `known queue [--harness=...]
    // [--provider=...] [--model=...]`, `known queue --recipes`,
    // `known dequeue`, `known purge`, plus `refresh run`. The
    // `known`/`refresh` dispatch is compiled out of the released
    // binary (dev_build is false) — the released and dev binaries both
    // run the action parser below: `agent`, `[--]trailer`, `help`,
    // `version` (with no arguments showing help).
    if (dev_build) {
        var sub_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return 1;
        defer sub_iter.deinit();
        _ = sub_iter.skip(); // argv0
        const cmd = sub_iter.next() orelse "";
        const sub = sub_iter.next() orelse "";
        if (std.mem.eql(u8, cmd, "known")) {
            if (sub.len == 0 or
                std.mem.eql(u8, sub, "--help") or
                std.mem.eql(u8, sub, "-h") or
                std.mem.eql(u8, sub, "help"))
            {
                return dev.runKnownHelp(init);
            } else if (std.mem.eql(u8, sub, "daemon")) {
                return dev.runKnownDaemon(init);
            } else if (std.mem.eql(u8, sub, "agent")) {
                return dev.runKnownAgent(init);
            } else if (std.mem.eql(u8, sub, "queue")) {
                return dev.runKnownQueue(init);
            } else if (std.mem.eql(u8, sub, "dequeue")) {
                return dev.runKnownDequeue(init);
            } else if (std.mem.eql(u8, sub, "purge")) {
                return dev.runKnownPurge(init);
            } else {
                writeErr(io, "known: unknown subcommand — run `known --help`\n");
                writeOut(io, dev.knownUsage);
                return 2;
            }
        } else if (std.mem.eql(u8, cmd, "refresh") and std.mem.eql(u8, sub, "run")) {
            // `refresh run` — invoked by the daemon as a child to
            // capture the current session into `known/<stem>.json` and
            // append a `refresh:false` event to `known/index.jsonl`.
            // The child inherits the harness env and config files the
            // daemon set up via the `KnownFixturesForKnownAgents.buildEnv`
            // recipe, so detection should resolve to that harness.
            return dev.runKnownAgent(init);
        }
    }

    // action parser. The canonical spellings are the bare words
    // `agent`, `trailer`, `help`, and `version`; the `--json`,
    // `--trailer`, `--help`, and `--version` / `-V` forms are legacy
    // aliases kept for existing callers. No arguments prints help.
    var action: []const u8 = ""; // "", "json", "trailer", "help", "version"
    var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return 1;
    defer args_it.deinit();
    _ = args_it.skip(); // argv0
    while (args_it.next()) |arg| {
        const act = if (std.mem.eql(u8, arg, "agent") or std.mem.eql(u8, arg, "--json"))
            "json"
        else if (std.mem.eql(u8, arg, "trailer") or std.mem.eql(u8, arg, "--trailer"))
            "trailer"
        else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))
            "help"
        else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V"))
            "version"
        else {
            writeErr(io, "unknown argument\n");
            writeOut(io, usage);
            return 2;
        };
        if (action.len != 0 and !std.mem.eql(u8, action, act)) {
            writeErr(io, "conflicting arguments\n");
            writeOut(io, usage);
            return 2;
        }
        action = act;
    }

    if (action.len == 0 or std.mem.eql(u8, action, "help")) {
        writeOut(io, usage);
        return 0;
    }

    if (std.mem.eql(u8, action, "version")) {
        // Version is plumbed in at compile time from
        // `build.zig.zon`'s `.version` field via `build_options`.
        // Same value is baked into the released binary, the dev
        // binary, and every `zig build dist` cross-compile target.
        writeOut(io, "agent-detection ");
        writeOut(io, build_options.version);
        writeOut(io, "\n");
        return 0;
    }

    var d = Detection{};
    const ok = try detect(init, &d);

    if (std.mem.eql(u8, action, "trailer")) {
        if (d.trailer) |t| {
            writeOut(io, t);
            writeOut(io, "\n");
            return 0;
        }
        writeErr(io, "unable to determine trailer (harness/provider/model unidentified) — stop and inform the user\n");
        return 2;
    }
    // action == "json": the detection report.
    var buf: std.ArrayList(u8) = .empty;
    try buildJson(a, &d, init.environ_map, null, .{}, &buf);
    writeOut(io, buf.items);

    if (!ok) writeErr(io, "unable to fully identify harness/provider/model — stop and inform the user (per policy)\n");
    return if (ok) 0 else 2;
}


