// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detect — infer the current agent harness, provider, and
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
// binary builds with `dev=false`; the maintainer-only `agent-detect-dev`
// is built with `dev=true`. The `if (dev_build)` blocks below contain
// every dev-only subcommand (the `fixtures` namespace: daemon, agent,
// queue, etc.) and the RecipesForFixtures table that drives
// them. Zig's `comptime` drops the dead code from the released binary
// at link time.
const build_options = @import("build_options");
pub const dev_build = build_options.dev;

// Exit status registry — canonical numbers, one per distinct kind of
// outcome. `1` is NOT a fallback for everything; it is reserved for
// genuinely unexpected/unclassified failures (uncaught zig errors,
// bugs). The full table + per-code examples live in DESIGN.md
// "exit status registry".
pub const EXIT_OK: u8 = 0;
pub const EXIT_UNRECOGNISED_ERROR: u8 = 1;
pub const EXIT_UNRECOGNISED_ARG: u8 = 2;
pub const EXIT_CONFLICTING_ARG: u8 = 3;
pub const EXIT_MISSING_ARG: u8 = 4;
pub const EXIT_ENV_INCOMPATIBLE: u8 = 5;
pub const EXIT_ENV_INCOMPLETE: u8 = 6;
pub const EXIT_MISSING_SPECIFIED_AGENT: u8 = 7;
pub const EXIT_UNABLE_TO_DETECT: u8 = 8;
pub const EXIT_AGENT_DATA_INCOMPLETE: u8 = 9;
pub const EXIT_REQUIREMENT_FAILED: u8 = 10;
pub const EXIT_OUT_OF_MEMORY: u8 = 11;
pub const EXIT_SQLITE_QUERY: u8 = 12;
pub const EXIT_IO: u8 = 13;

// Error-message strings = the exit-status registry names, verbatim.
// STDERR carries the full registry-name message; STDOUT carries the
// concise verdict (determination / data). No repo clause, no prose —
// the repo-update rules live in README.md per use case.
const MSG_UNRECOGNISED_ARG = "unrecognised argument: '";
const MSG_CONFLICTING_ARG = "conflicting argument\n";
const MSG_MISSING_ARG_COMBO = "missing required arguments: --harness= --provider= --model=\n";
const MSG_MISSING_ARG_TRAILER_SUBTYPE = "missing required arguments: trailer subtype (co-author | assisted-by)\n";
const MSG_MISSING_ARG = "missing required arguments\n";
const MSG_ENV_INCOMPATIBLE = "incompatible environment refusing run\n";
const MSG_ENV_INCOMPLETE = "incomplete environment preventing run\n";
const MSG_MISSING_SPECIFIED_AGENT = "missing specified agent (harness, provider, model)\n";
const MSG_UNABLE_TO_DETECT = "unable to detect unspecified agent (harness, provider, model)\n";
const MSG_AGENT_DATA_INCOMPLETE = "agent (harness, provider, model) data incomplete to make a determination\n";
const MSG_REQUIREMENT_FAILED = "agent (harness, provider, model) data complete and requirement failed\n";
const MSG_OUT_OF_MEMORY = "out of memory\n";
const MSG_SQLITE_QUERY = "sqlite query error\n";
const MSG_IO = "filesystem I/O error\n";

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
    harness_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `harness_name` (no separators), e.g. "kimi-code" -> "kimicode" — the only id we constrain; `harness_name` carries whatever the service uses
    harness_version: ?[]const u8 = null, // optional release version, e.g. "1.2.3"
    harness_license: ?[]const u8 = null, // SPDX id, e.g. "Apache-2.0"
    // provider group
    provider_label: ?[]const u8 = null, // e.g. "Cline Pass"
    provider_name: ?[]const u8 = null, // canonical name (whatever casing the service uses to refer to it), e.g. "cline-pass"
    provider_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `provider_name` (no separators), e.g. "cline-pass" -> "clinepass" — the only id we constrain; `provider_name` carries whatever the service uses
    provider_closed_training: ?[]const u8 = null, // "enforced" | "opt-in" | "opt-out" | "never" | null
    provider_open_training: ?[]const u8 = null, // same enum
    // model group
    model_label: ?[]const u8 = null, // e.g. "Kimi K3"
    model_short_title: ?[]const u8 = null, // optional short brand form, e.g. "M3" for "MiniMax M3"; null when no established short form
    model_name: ?[]const u8 = null, // canonical bare slug (whatever casing the service uses canonically), e.g. "kimi-k3"
    model_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `model_name` (no separators), e.g. "kimi-k3" -> "kimik3"
    model_reciprocity: ?[]const u8 = null, // "open-source" | "open-weight" | "closed" | null
    // agent (composed from harness + provider + model)
    agent_id: ?[]const u8 = null, // "<harness_id>-<provider_id>-<model_id>" — the user-visible identity of the agent
    // policy / output
    reciprocal: ?bool = null, // computed from harness_license + model_reciprocity + provider_closed_training
    trailer: ?[]const u8 = null,
    // raw — typed observations; buildRaw converts these to a shapeless
    // JSON object whose top-level keys identify the source of evidence
    raw: RawObservation = .{},
    // the dims this run's detection ladder (or recipe) *could* resolve;
    // a stale per-capture record of what landed in the raw block's
    // `detectable` key. `detected` is derived post-hoc from which
    // canonical dims actually populated `cooked`.
    detectable: []const []const u8 = &.{},
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
const ModelRule = struct {
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
pub const rulesForModels = [_]ModelRule{
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
    // deepseek-v4-pro: open-weight — the larger sibling of
    // deepseek-v4-flash; HF card + MIT LICENSE.
    .{ .name = "deepseek-v4-pro", .label = "DeepSeek V4 Pro", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro", "https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro/blob/main/LICENSE" } },
    // llama-4: open-weight — Llama 4 community license (weights
    // downloadable, custom license, not OSI); Scout is the smallest of
    // the family.
    .{ .name = "llama-4", .label = "Llama 4", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/meta-llama/Llama-4-Scout-17B-16E", "https://huggingface.co/meta-llama/Llama-4-Scout-17B-16E/blob/main/LICENSE" } },
    // qwen3.5: open-weight — Qwen3.5 weights on HF under the Qwen
    // (Apache-2.0) license; the hosted alias is what most combos run.
    .{ .name = "qwen3.5", .label = "Qwen3.5", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/Qwen/Qwen3.5", "https://huggingface.co/Qwen/Qwen3.5/blob/main/LICENSE" } },
    // qwen3: open-weight — the base Qwen3 family (Apache-2.0); used by
    // Cerebras-hosted combos.
    .{ .name = "qwen3", .label = "Qwen3", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/Qwen/Qwen3", "https://huggingface.co/Qwen/Qwen3/blob/main/LICENSE" } },
    // mistral-small-latest: open-weight — Mistral Small's alias;
    // Apache-2.0 weights per the models overview, same as
    // mistral-large-latest.
    .{ .name = "mistral-small-latest", .label = "Mistral Small (latest)", .reciprocity = "open-weight", .sources = &.{ "https://docs.mistral.ai/getting-started/models/models_overview/", "https://docs.mistral.ai/getting-started/models/" } },
    // gemini-3-flash: closed — Google Gemini API-only; no weights.
    .{ .name = "gemini-3-flash", .label = "Gemini 3 Flash", .reciprocity = "closed", .sources = &.{ "https://deepmind.google/technologies/gemini/", "https://ai.google.dev/gemini-api/docs/models" } },
    // gemini-3.1-pro: closed — Google Gemini API-only; no weights.
    .{ .name = "gemini-3.1-pro", .label = "Gemini 3.1 Pro", .reciprocity = "closed", .sources = &.{ "https://deepmind.google/technologies/gemini/", "https://ai.google.dev/gemini-api/docs/models" } },
    // gpt-5-mini: closed — OpenAI API-only; no weights.
    .{ .name = "gpt-5-mini", .label = "GPT-5 mini", .reciprocity = "closed", .sources = &.{ "https://openai.com/index/gpt-5/", "https://platform.openai.com/docs/models" } },
    // gpt-5.5: closed — OpenAI API-only; no weights.
    .{ .name = "gpt-5.5", .label = "GPT-5.5", .reciprocity = "closed", .sources = &.{ "https://openai.com/index/gpt-5/", "https://platform.openai.com/docs/models" } },
    // grok-3-mini: closed — xAI API-only; no weights.
    .{ .name = "grok-3-mini", .label = "Grok 3 mini", .reciprocity = "closed", .sources = &.{ "https://x.ai/grok", "https://docs.x.ai/docs/models" } },
    // grok-4: closed — xAI API-only; no weights.
    .{ .name = "grok-4", .label = "Grok 4", .reciprocity = "closed", .sources = &.{ "https://x.ai/grok", "https://docs.x.ai/docs/models" } },
    // claude-opus-4: closed — API-only; no weights.
    .{ .name = "claude-opus-4", .label = "Claude Opus 4", .reciprocity = "closed", .sources = &.{ "https://www.anthropic.com/claude/opus", "https://docs.anthropic.com/en/docs/about-claude/models" } },
    // claude-haiku-4: closed — API-only; no weights.
    .{ .name = "claude-haiku-4", .label = "Claude Haiku 4", .reciprocity = "closed", .sources = &.{ "https://www.anthropic.com/claude/haiku", "https://docs.anthropic.com/en/docs/about-claude/models" } },
    // step-3.7-flash: unverified — no independent cross-references yet;
    // reciprocity stays null (the policy check reports "unverified")
    // until a maintainer audits StepFun's model card.
    .{ .name = "step-3.7-flash", .label = "Step 3.7 Flash", .reciprocity = null, .sources = &.{} },
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
const ProviderRule = struct {
    name: []const u8,
    label: []const u8,
    closed_training: ?[]const u8,
    open_training: ?[]const u8,
    sources: []const []const u8,
};
pub const rulesForProviders = [_]ProviderRule{
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
    // deepseek: never/never — the direct DeepSeek platform provider
    // (api.deepseek.com, the upstream the openai/anthropic-compatible
    // transport fronts). Same data-handling policy as `deepseek-flash`;
    // mirrors it so the direct provider id resolves the same policies.
    .{ .name = "deepseek", .label = "DeepSeek", .closed_training = "never", .open_training = "never", .sources = &.{ "https://api-docs.deepseek.com/quick_start/pricing", "https://platform.deepseek.com" } },
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
    // openrouter: never/never — a BYO-key aggregator gateway; it does
    // not host or train models on customer traffic (privacy + terms).
    .{ .name = "openrouter", .label = "OpenRouter", .closed_training = "never", .open_training = "never", .sources = &.{ "https://openrouter.ai/privacy", "https://openrouter.ai/terms" } },
    // groq: never/never — Groq is an inference-only LPU cloud; its
    // terms/privacy state customer data is not used for model training.
    .{ .name = "groq", .label = "Groq", .closed_training = "never", .open_training = "never", .sources = &.{ "https://groq.com/privacy", "https://groq.com/terms" } },
    // cerebras: never/never — Cerebras Inference is a hardware
    // inference cloud; customer prompts are not used for training.
    .{ .name = "cerebras", .label = "Cerebras", .closed_training = "never", .open_training = "never", .sources = &.{ "https://www.cerebras.ai/privacy-policy", "https://www.cerebras.ai/terms-of-service" } },
    // zai: null/null — Z.ai (Zhipu AI) trains models itself (the GLM
    // family); API training-policy wording unverified, stays null.
    .{ .name = "zai", .label = "Z.ai", .closed_training = null, .open_training = null, .sources = &.{ "https://www.z.ai/terms-of-service", "https://www.z.ai/privacy-policy" } },
    // moonshot: null/null — Moonshot AI trains models (the Kimi
    // family); API training-policy wording unverified, stays null.
    .{ .name = "moonshot", .label = "Moonshot", .closed_training = null, .open_training = null, .sources = &.{ "https://platform.moonshot.ai/docs/terms", "https://platform.moonshot.ai/docs/privacy" } },
    // kimi: mirrors `moonshot` — the provider key kimi-code configs
    // use (`default_model = "kimi/kimi-k3"`); same underlying Moonshot
    // AI upstream, same unverified policy status.
    .{ .name = "kimi", .label = "Kimi", .closed_training = null, .open_training = null, .sources = &.{ "https://platform.moonshot.ai/docs/terms", "https://platform.moonshot.ai/docs/privacy" } },
    // qwen: null/null — Alibaba Qwen's hosted tier (qwen.ai /
    // DashScope); Qwen trains models itself, API policy unverified.
    .{ .name = "qwen", .label = "Qwen", .closed_training = null, .open_training = null, .sources = &.{ "https://qwen.ai/", "https://qwen.ai/legal" } },
};
/// static metadata the rule declared to the matcher. Useful for auditing
/// when a rule misfires; not a runtime observation.
// Static rule metadata (the harness rule's declared proc names and
// env-marker names) lives in `rulesForHarnesses`; the runtime
// observation story is carried by `raw.env_vars` (matched env-var
// observations) and `raw.process_lineage` (process tree at detection
// time). The raw block intentionally does NOT duplicate that static
// data (see DESIGN.md "18-field canonical fixture contract").

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
/// `agent-detect`, index 1 = its parent, etc.). Full argv is
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

/// One evidence claim: "dim X was resolved from source Y, which is
/// present in raw, and whose value was Z". Decision #11 — every
/// detected dim in an observed fixture must carry a claim so code can
/// mechanically verify the attribution chain (source present + value
/// matches the cooked dim). `source` is one of "env" | "config" |
/// "session" | "lineage":
///   - "env":     `name` is the env-var name (must appear in raw.env)
///   - "config"/"session": `name` is the file path (a top-level raw
///     key after redaction) and `field` the dotted path within it
///   - "lineage": `name` is a process basename (must appear in
///     raw.process_lineage)
/// `value` is the value the detector read (or, for lineage harness
/// claims, the matched proc name). Semantic deducibility is human
/// review; this struct only pins the attribution chain.
pub const EvidenceClaim = struct {
    dim: []const u8, // "harness" | "provider" | "model"
    source: []const u8, // "env" | "config" | "session" | "lineage"
    name: []const u8, // env var / file path / proc name
    field: ?[]const u8 = null, // dotted path for config/session claims
    value: ?[]const u8 = null, // the value read (null = no value seen)
};

/// All unprocessed observations in a typed shape that maps cleanly to
/// the shapeless JSON output emitted by `buildRaw`. Top-level groups:
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
    harness_urls: []const []const u8 = &.{},
    provider_urls: []const []const u8 = &.{},
    model_urls: []const []const u8 = &.{},
    /// decision #11 evidence claims — per detected dim, what source
    /// was read and with what value. Empty for `from-ids` (declared,
    /// not observed) fixtures.
    evidence: []const EvidenceClaim = &.{},
};

pub const HarnessRule = struct {
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
const pi_env = [_][]const u8{ "PI_CODING_AGENT", "PI_PROVIDER", "PI_MODEL" };

// harnesses listed in the user's machine but not yet fully integrated;
// each gets a single, plausibly-shaped env marker that the daemon's
// runner (see CONTRIBUTING.md) sets in the spawned process's env to
// fire detection. Each project's `license`/`license_sources` in
// rulesForHarnesses is filled in from its upstream repo once
// verified — a maintainer records the SPDX id + source URLs there, not
// in the fixtures (fixtures are generated artifacts).
const qwen_env = [_][]const u8{ "QWEN_API_KEY" };
const kilo_env = [_][]const u8{ "KILO_API_KEY", "KILO", "KILO_MODEL" };
const jcode_env = [_][]const u8{ "JCODE_API_KEY" };
const omp_env = [_][]const u8{ "OMP_API_KEY" };
const reasonix_env = [_][]const u8{ "REASONIX_API_KEY" };
const crush_env = [_][]const u8{ "CRUSH_API_KEY" };
const opencode_env = [_][]const u8{ "OPENCODE_API_KEY", "OPENCODE_MODEL" };
const vibe_env = [_][]const u8{ "VIBE_API_KEY", "VIBE_ACTIVE_MODEL", "VIBE_ACTIVE_PROVIDER" };

const cline_procs = [_][]const u8{ "cline.exe", "cline" };
const goose_procs = [_][]const u8{ "goose.exe", "goose", "goosed.exe", "goosed" };
const kimi_procs = [_][]const u8{ "kimi.exe", "kimi", "kimi-code.exe", "kimi-code" };
const kilo_procs = [_][]const u8{ "kilo.exe", "kilo" };
pub const rulesForHarnesses = [_]HarnessRule{
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
    .{ .name = "kilo", .label = "Kilo Code", .license = "MIT", .license_sources = &.{ "https://github.com/Kilo-Org/kilocode", "https://github.com/Kilo-Org/kilocode/blob/main/LICENSE" }, .env_markers = &kilo_env, .proc_names = &kilo_procs },
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
    // launcher-provided model selectors — the values are model ids /
    // provider ids, not secrets, so fixtures can carry the exact value
    // the detector read (evidence-claim value matching needs it).
    "KILO_MODEL", "OPENCODE_MODEL", "VIBE_ACTIVE_MODEL", "VIBE_ACTIVE_PROVIDER",
    "PI_PROVIDER", "PI_MODEL",
    "GOOSE_WORKING_DIR", "GOOSE_TERMINAL", "GOOSE_MODE",
    "USERPROFILE", "HOME", "APPDATA",
};

fn isEnvValueAllowed(name: []const u8) bool {
    for (env_value_allowlist) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

/// append one evidence claim to `d.raw.evidence`. The old slice is
/// leaked (arena-backed) — fine for the short-lived Detection.
fn addEvidenceClaim(a: std.mem.Allocator, d: *Detection, claim: EvidenceClaim) !void {
    const new_len = d.raw.evidence.len + 1;
    const new_slice = try a.alloc(EvidenceClaim, new_len);
    @memcpy(new_slice[0..d.raw.evidence.len], d.raw.evidence);
    new_slice[d.raw.evidence.len] = claim;
    d.raw.evidence = new_slice;
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
    d.model_id = try slugId(a, canonical_name);
    d.model_reciprocity = mi.reciprocity;
    if (mi.sources.len > 0) d.raw.model_urls = mi.sources;
    _ = raw_input; // caller is responsible for recording it in a config_file observation
    // recompute the agent id now that model_id is fixtures —
    // this depends on harness_id and provider_id
    // being set first, which the calling detector is responsible for.
    try setAgentId(a, d);
}

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

/// optional tee target for daemon output; set by `fixtures daemon --write-log`.
var daemon_log_file: ?std.Io.File = null;

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
    for (rulesForModels) |r| {
        if (std.mem.eql(u8, r.name, name))
            return .{ .label = r.label, .short_title = r.short_title, .reciprocity = r.reciprocity, .sources = r.sources };
    }
    // family-prefix fallbacks for fixtures open-weight families
    const families = [_][]const u8{ "kimi", "glm", "minimax" };
    for (families) |fam| {
        if (std.mem.startsWith(u8, name, fam))
            return .{ .label = try titleCase(a, name), .reciprocity = "open-weight" };
    }
    return .{ .label = try titleCase(a, name), .reciprocity = null };
}

fn providerForName(name: []const u8) ?[]const u8 {
    for (rulesForProviders) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.label;
    }
    return null;
}

fn providerMetaForName(name: []const u8) ?ProviderRule {
    for (rulesForProviders) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// map an openai-compatible `base_url` host back to the canonical
/// provider id. Used by `detectQwen` to resolve the upstream service
/// behind qwen's `modelProviders[].baseUrl`, and mirrored by the dev
/// provider metadata the from-raw fabricator writes. Unknown hosts
/// fall back to "minimax" (the well-fixtures endpoint).
fn providerForBaseUrl(base_url: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "minimax.io", "minimax" },
        .{ "deepseek.com", "deepseek" },
        .{ "openrouter.ai", "openrouter" },
        .{ "groq.com", "groq" },
        .{ "cerebras.ai", "cerebras" },
        .{ "z.ai", "zai" },
        .{ "moonshot", "moonshot" },
        .{ "dashscope", "qwen" },
        .{ "qwen.ai", "qwen" },
        .{ "mistral.ai", "mistral" },
        .{ "anthropic.com", "anthropic" },
        .{ "hyper.charm.land", "hyper" },
    };
    for (table) |pair| {
        if (std.mem.indexOf(u8, base_url, pair[0]) != null) return pair[1];
    }
    return "minimax";
}

/// look up a harness rule by its canonical `name` id. Returns the
/// whole rule (label, license, license_sources, env markers, etc.) or
/// null when the id isn't in the harness registry. Used by recipe-mode
/// cooked/trailer resolution — the live ladder matches harnesses via
/// env markers / process ancestry, but recipe mode has only the id.
fn harnessRuleForName(name: []const u8) ?HarnessRule {
    for (rulesForHarnesses) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// does `input` name the rule whose canonical `name` is `rule_name`?
/// Accepts either the canonical spelling (e.g. `kimi-code`) or the
/// strict slug (`kimicode`) — recipe-mode combos are typically given
/// in slug form (as in the `agent_id`/`fixture_id` composites).
fn ruleIdMatches(rule_name: []const u8, input: []const u8) bool {
    if (std.mem.eql(u8, rule_name, input)) return true;
    // slug form: lowercase-alphanumeric of the canonical name
    var i: usize = 0;
    for (rule_name) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (i >= input.len) return false;
        if (std.ascii.toLower(c) != input[i]) return false;
        i += 1;
    }
    return i == input.len;
}

/// apply provider rule metadata (training policies + their cross-reference
/// sources) to `d`. No-op if the provider id is not in the table; this is
/// the single place the four detectors should call to populate `provider_*`
/// and the matching `raw.provider_urls` array. Also sets
/// `provider_id` (the strict-slug form of the canonical name)
/// so detectors that use the three-line `provider_name + label + meta`
/// pattern still keep the slug id in lockstep with the name.
fn applyProviderMeta(a: std.mem.Allocator, d: *Detection, id: []const u8) !void {
    d.provider_id = try slugId(a, id);
    if (providerMetaForName(id)) |meta| {
        d.provider_closed_training = meta.closed_training;
        d.provider_open_training = meta.open_training;
        d.raw.provider_urls = meta.sources;
    }
}

/// set d.provider_label, d.provider_name, and d.provider_id together
/// from a single id. This is the helper detectors should call instead of
/// the old "label + applyProviderMeta" pair — it keeps the
/// slug id in lockstep with the name so consumers can
/// always trust the canonical trio.
fn setProvider(a: std.mem.Allocator, d: *Detection, id: []const u8) !void {
    const display = providerForName(id) orelse try titleCase(a, id);
    d.provider_name = try a.dupe(u8, id);
    d.provider_label = display;
    d.provider_id = try slugId(a, id);
    try applyProviderMeta(a, d, id);
}

/// compose the agent_id from the three sub-ids. Writes
/// `null` if any of the three is null (the agent is not fully
/// identified yet, and a partial id is more misleading than null).
fn setAgentId(a: std.mem.Allocator, d: *Detection) !void {
    const h = d.harness_id orelse return;
    const p = d.provider_id orelse return;
    const m = d.model_id orelse return;
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, h);
    try list.append(a, '-');
    try list.appendSlice(a, p);
    try list.append(a, '-');
    try list.appendSlice(a, m);
    d.agent_id = try list.toOwnedSlice(a);
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
/// per-model / per-agent ids and surfaced as
/// `{harness,model}_id` and `agent_id` in the
/// canonical output so consumers can see exactly where the trailer's
/// email local part came from. The strictness (no separators at all)
/// is what the `_id` suffix advertises.
pub fn slugId(a: std.mem.Allocator, display: []const u8) ![]u8 {
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
// Windows process termination — used by the dev from-capture timeout
// watchdog (`fixtures __timeout`). PROCESS_TERMINATE = 0x0001.
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: c_int, dwProcessId: u32) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn TerminateProcess(hProcess: std.os.windows.HANDLE, uExitCode: u32) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) c_int;

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
                    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = prov_path, .field = "lastUsedProvider", .value = prov });
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
                                                try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = prov_path, .field = dotted, .value = mid });
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
    // decision #11: claims against the source that actually resolved
    // each dim (env vars override the config file).
    if (provider) |p| {
        if (std.mem.eql(u8, src, "env")) {
            try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "GOOSE_PROVIDER", .value = p });
        } else if (active) |act| {
            try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "active_provider", .value = act });
        }
    }
    if (model) |m| {
        if (std.mem.eql(u8, src, "env")) {
            try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "GOOSE_MODEL", .value = m });
        } else if (active) |act| {
            const dotted = try std.fmt.allocPrint(a, "providers.{s}.model", .{act});
            try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = dotted, .value = m });
        }
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
            // decision #11: both dims were read from config.toml's
            // `default_model` = "<provider>/<model>" value.
            try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "default_model", .value = dm });
            try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "default_model", .value = dm });
            break;
        }
    }
}

fn detectMmx(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    var provider: []const u8 = "minimax"; // mmx-cli is MiniMax's CLI; intrinsic default
    var model: []const u8 = "minimax-m3"; // mmx-cli default when no model configured
    var raw_input: []const u8 = "minimax-m3"; // bundle default
    var config_fields: ?[]const FieldObservation = null;
    var config_path: ?[]const u8 = null;
    var config_value: ?[]const u8 = null;
    if (home.len > 0) {
        const cwd_dir = std.Io.Dir.cwd();
        const path = try std.fmt.allocPrint(a, "{s}/.mmx/config.json", .{home});
        if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |cdata| {
            if (std.json.parseFromSlice(std.json.Value, a, cdata, .{}) catch null) |parsed| {
                if (parsed.value == .object) {
                    const o = parsed.value.object;
                    if (jstr(o, "defaultTextModel") orelse jstr(o, "model")) |m| {
                        raw_input = m;
                        config_value = m;
                        // mmx config stores the bare model id; when a
                        // "provider/model" prefix is present it is the
                        // upstream provider (the from-raw fabricator
                        // writes that form to exercise non-minimax
                        // combos). Bare ids keep the intrinsic default.
                        const lower = std.ascii.allocLowerString(a, m) catch m;
                        const slash = std.mem.findScalar(u8, lower, '/');
                        if (slash) |i| {
                            provider = lower[0..i];
                            model = lower[i + 1 ..];
                        } else {
                            model = lower;
                        }
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
    d.provider_name = provider;
    d.provider_label = providerForName(provider) orelse try titleCase(a, provider);
    try applyProviderMeta(a, d, provider);
    try applyModel(a, d, model, raw_input);
    if (config_value) |cv| {
        try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = config_path orelse "", .field = if (config_fields != null) config_fields.?[0].dotted_path else null, .value = cv });
        if (std.mem.indexOfScalar(u8, cv, '/') != null) {
            try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = config_path orelse "", .field = if (config_fields != null) config_fields.?[0].dotted_path else null, .value = cv });
        }
    }
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
// (provider-urls empty + model-urls from rulesForModels).
//
// Each function:
//   - reads the harness's fixtures config file (or env var),
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
    // actual upstream service; the baseUrl host is mapped to the
    // provider id (dev-only provider metadata carries the per-provider
    // base_urls the from-raw fabricator writes). Unknown hosts default
    // to "minimax" (the well-fixtures case: api.minimax.io).
    var provider_name: []const u8 = "minimax";
    var provider_base_url: []const u8 = "";
    if (root.get("modelProviders")) |mps| {
        if (mps.object.get("openai")) |entries| {
            for (entries.array.items) |entry| {
                if (entry.object.get("baseUrl")) |bu| {
                    provider_base_url = bu.string;
                    provider_name = providerForBaseUrl(bu.string);
                    break;
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
    if (provider_base_url.len > 0) {
        try fields.append(a, .{ .dotted_path = "modelProviders.openai[].baseUrl", .value = provider_base_url });
    }
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
    // decision #11: model read from settings.json model.name; provider
    // derived from the modelProviders[].baseUrl host (when present).
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "model.name", .value = model_name });
    if (provider_base_url.len > 0) {
        try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "modelProviders.openai[].baseUrl", .value = provider_base_url });
    }
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
    // decision #11: both dims read from config.yml's
    // `modelRoles.default` = "<provider>/<model>".
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "modelRoles.default", .value = dm });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "modelRoles.default", .value = dm });
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
    // [[providers]] entries' `name` field, then reads that entry's
    // `default` field for the actual model id. When the providers
    // table can't be resolved (e.g. the model id equals the provider
    // name in practice), fall back to using the default_model string as
    // both the provider and model id.
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

    // walk the `[[providers]]` blocks: find the entry whose `name`
    // equals `dm` and read its `default` field for the model id. Both
    // are quoted toml strings on their own lines:
    //   [[providers]]
    //   name = "deepseek-flash"
    //   default = "deepseek-v4-flash"
    const provider_name: []const u8 = dm;
    var model_name: []const u8 = dm;
    var in_providers = false;
    var in_dm = false;
    var lines2 = std.mem.splitScalar(u8, data, '\n');
    while (lines2.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, t, "[[providers]]")) {
            in_providers = true;
            in_dm = false;
            continue;
        }
        if (!in_providers) continue;
        if (std.mem.startsWith(u8, t, "name =")) {
            const eq = std.mem.findScalar(u8, t, '=') orelse continue;
            const val = std.mem.trim(u8, t[eq + 1 ..], " \"\t");
            in_dm = std.mem.eql(u8, val, dm);
            continue;
        }
        if (in_dm and std.mem.startsWith(u8, t, "default =")) {
            const eq = std.mem.findScalar(u8, t, '=') orelse continue;
            const val = std.mem.trim(u8, t[eq + 1 ..], " \"\t");
            if (val.len > 0) model_name = val;
            break;
        }
    }

    d.provider_name = provider_name;
    d.provider_label = providerForName(provider_name) orelse try titleCase(a, provider_name);
    try applyProviderMeta(a, d, provider_name);
    try applyModel(a, d, model_name, dm);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "default_model", .value = dm });
    if (!std.mem.eql(u8, model_name, dm)) {
        try fields.append(a, .{ .dotted_path = "providers[].default", .value = model_name });
    }
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
    // decision #11: the provider is `default_model`; the model is the
    // matched [[providers]] entry's `default` (both from config.toml).
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "default_model", .value = dm });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "providers[].default", .value = model_name });
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
    // decision #11: jcode's session file is the source for both dims.
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "session", .name = path, .field = "provider_key", .value = provider_key });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "session", .name = path, .field = "model", .value = model_name });
}

fn detectCrush(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = env;
    if (home.len == 0) return;
    // crush's `default_large_model_id` is the "current" model — the
    // launcher wrote it into hyper.json from the user's `crush
    // update-providers` run. Format: "<provider>/<model>". The path
    // follows HOME (the from-raw fabricator writes it into the sandboxed
    // HOME, so it must NOT be hardcoded).
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fs.path.join(a, &.{ home, ".local/share/crush/hyper.json" });
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
    // decision #11: both dims read from hyper.json's
    // `default_large_model_id` = "<provider>/<model>".
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "default_large_model_id", .value = dm });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "default_large_model_id", .value = dm });
}

fn detectKilo(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    // Launcher sets KILO_MODEL=<provider>/<model> before capture runs;
    // prefer that (matches the committed-trailer provider naming). Fall
    // back to reading the live Kilo session DB for the `trailer`/`agent`
    // actions run directly under the Kilo CLI, where KILO_MODEL is unset.
    const model_full = env.get("KILO_MODEL") orelse {
        return detectKiloFromDb(a, io, env, home, d);
    };
    if (model_full.len == 0) return detectKiloFromDb(a, io, env, home, d);
    const slash = std.mem.findScalar(u8, model_full, '/');
    if (slash) |i| {
        const prov = model_full[0..i];
        const model_only = model_full[i + 1 ..];
        try setProvider(a, d, prov);
        try applyModel(a, d, model_only, model_full);
    } else {
        try setProvider(a, d, "anthropic");
        try applyModel(a, d, model_full, model_full);
    }
    // kilo has no config file — the KILO_MODEL value lives in
    // raw.env_vars (added by applyModel via the env block), not in
    // a fake config_file entry. Leaving config_files empty keeps the
    // raw block honest. The evidence claims point at the KILO_MODEL
    // env observation, whose value carries "<provider>/<model>".
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "KILO_MODEL", .value = model_full });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "KILO_MODEL", .value = model_full });
}

/// Kilo does not export the active model to child processes, but it
/// records it in the session store `~/.local/share/kilo/kilo.db`
/// (`session.model`, JSON with `id` + `providerID`). Read that read-only
/// via the `sqlite3` CLI: the newest session row whose `directory`
/// matches the current working directory. Partial/absent → no-op (the
/// caller falls back to leaving detection unresolved).
fn detectKiloFromDb(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const dir = env.get("PWD") orelse return;
    if (dir.len == 0) return;
    const db = try std.fs.path.join(a, &.{ home, ".local/share/kilo/kilo.db" });
    defer a.free(db);
    if (std.Io.Dir.cwd().statFile(io, db, .{})) |_| {} else |_| return;

    // quote dir into a SQL string literal (single-quote doubling)
    var dir_lit: std.ArrayList(u8) = .empty;
    defer dir_lit.deinit(a);
    try dir_lit.append(a, '\'');
    for (dir) |c| {
        if (c == '\'') try dir_lit.append(a, '\'');
        try dir_lit.append(a, c);
    }
    try dir_lit.append(a, '\'');
    const sql = try std.fmt.allocPrint(a, "SELECT model FROM session WHERE directory={s} ORDER BY time_updated DESC LIMIT 1", .{dir_lit.items});
    defer a.free(sql);

    const out = kiloSqliteJson(a, io, db, sql) catch return;
    defer a.free(out);
    if (out.len == 0) return;
    const outer = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return;
    if (outer.value != .array or outer.value.array.items.len == 0) return;
    const row = outer.value.array.items[0];
    if (row != .object) return;
    const model_str = switch (row.object.get("model") orelse return) {
        .string => |s| s,
        else => return,
    };
    // model JSON: {"id":"deepseek-v4-flash-0731","providerID":"hyper"}
    const inner = std.json.parseFromSlice(std.json.Value, a, model_str, .{}) catch return;
    const inner_obj = switch (inner.value) {
        .object => |o| o,
        else => return,
    };
    const provider_id = switch (inner_obj.get("providerID") orelse return) {
        .string => |s| s,
        else => return,
    };
    const model_full = switch (inner_obj.get("id") orelse return) {
        .string => |s| s,
        else => return,
    };
    try setProvider(a, d, provider_id);
    try applyModel(a, d, stripBuildStamp(a, model_full), model_full);
    // decision #11: the live session store is the source for both dims —
    // record the db read so a real-session fixture's evidence chain is
    // complete (the env path above already claims KILO_MODEL).
    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "session.model.providerID", .value = provider_id });
    try fields.append(a, .{ .dotted_path = "session.model.id", .value = model_full });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = db, .fields = try fields.toOwnedSlice(a) };
    d.raw.session_files = obs;
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "session", .name = db, .field = "session.model.providerID", .value = provider_id });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "session", .name = db, .field = "session.model.id", .value = model_full });
}

/// spawn `sqlite3 -json <db> <sql>`; return stdout (caller frees).
/// Deliberate mirror of the dev-only `dev.sqliteRun` — this one takes
/// a db-path arg and ships in the released binary (Kilo DB reads);
/// `dev.sqliteRun` is fixed to `fixtures/index.sqlite3` and dev-gated.
fn kiloSqliteJson(a: std.mem.Allocator, io: std.Io, db: []const u8, sql: []const u8) ![]u8 {
    const db_z = try a.dupeZ(u8, db);
    defer a.free(db_z);
    var argv_buf = [_][]const u8{ "sqlite3", "-json", "-batch", db_z, sql };
    var child = std.process.spawn(io, .{
        .argv = &argv_buf,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SqliteSpawnFailed;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.ensureTotalCapacity(a, 2048);
    var buf: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buf);
    while (true) {
        var chunk: [8192]u8 = undefined;
        const n = reader.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try out.appendSlice(a, chunk[0..n]);
    }
    const term = child.wait(io) catch return error.SqliteSpawnFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.SqliteError,
        else => return error.SqliteError,
    }
    return out.toOwnedSlice(a);
}

/// strip a trailing `-NNN` build stamp (e.g. `deepseek-v4-flash-0731` →
/// `deepseek-v4-flash`) so the id matches the model rule. No-op when the
/// last dash-segment isn't 1+ digits.
fn stripBuildStamp(a: std.mem.Allocator, name: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, name, '-') orelse return name;
    const stamp = name[dash + 1 ..];
    if (stamp.len == 0) return name;
    for (stamp) |c| {
        if (!std.ascii.isDigit(c)) return name;
    }
    return a.dupe(u8, name[0..dash]) catch name;
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
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "OPENCODE_MODEL", .value = model_full });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "OPENCODE_MODEL", .value = model_full });
}

fn detectVibe(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = io;
    // vibe's documented override: VIBE_ACTIVE_MODEL=<name> sets the
    // active model without going through the config. Launcher uses
    // this to capture whatever model the user is currently running.
    // Mistral Vibe is a Mistral product, so the underlying provider is
    // Mistral unless the launcher overrides it (VIBE_ACTIVE_PROVIDER) —
    // the from-raw fabricator uses that to exercise non-Mistral combos.
    const model_name = env.get("VIBE_ACTIVE_MODEL") orelse return;
    if (model_name.len == 0) return;
    const provider_id = env.get("VIBE_ACTIVE_PROVIDER") orelse "mistral";
    d.provider_name = provider_id;
    d.provider_label = providerForName(provider_id) orelse "Mistral";
    try applyProviderMeta(a, d, provider_id);
    try applyModel(a, d, model_name, model_name);

    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "VIBE_ACTIVE_PROVIDER", .value = provider_id });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "VIBE_ACTIVE_MODEL", .value = model_name });

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

fn detectPi(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    // pi: harness-only by design for the env path; real pi sessions set
    // no PI_* env vars, so when both are unset we read the real
    // defaults from `~/.pi/agent/settings.json` (`defaultProvider` /
    // `defaultModel`). The env path (both set) is the launcher stand-in
    // and stays unchanged — its evidence claims record exactly what was
    // used, and the raw.env observation shows `present` so a reviewer
    // can tell a launcher-set value from a default.
    const provider_env = env.get("PI_PROVIDER");
    const model_env = env.get("PI_MODEL");
    if (provider_env != null and model_env != null) {
        const provider = provider_env.?;
        const model = model_env.?;
        d.provider_name = provider;
        d.provider_label = providerForName(provider) orelse try titleCase(a, provider);
        try applyProviderMeta(a, d, provider);
        try applyModel(a, d, model, model);
        try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "PI_PROVIDER", .value = provider });
        try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "PI_MODEL", .value = model });
        return;
    }

    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(a, "{s}/.pi/agent/settings.json", .{home});
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value.object;
    const provider = switch (root.get("defaultProvider") orelse return) {
        .string => |s| s,
        else => return,
    };
    const model = switch (root.get("defaultModel") orelse return) {
        .string => |s| s,
        else => return,
    };
    if (provider.len == 0 or model.len == 0) return;

    d.provider_name = provider;
    d.provider_label = providerForName(provider) orelse try titleCase(a, provider);
    try applyProviderMeta(a, d, provider);
    try applyModel(a, d, model, model);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "defaultProvider", .value = provider });
    try fields.append(a, .{ .dotted_path = "defaultModel", .value = model });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "defaultProvider", .value = provider });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "defaultModel", .value = model });
}

/// tri-state reciprocity determination for `d`:
/// - `.unknown` when any of `harness_license` / `model_reciprocity` /
///   `provider_closed_training` is null (unverified status cannot be
///   assumed reciprocal per the AI policy);
/// - otherwise `.reciprocal` iff the current conjunction passes, else
///   `.not_reciprocal`.
pub const Reciprocity = enum { reciprocal, not_reciprocal, unknown };

pub fn reciprocityOf(d: *const Detection) Reciprocity {
    if (d.harness_license == null or d.model_reciprocity == null or d.provider_closed_training == null) return .unknown;
    if (computeReciprocal(d)) return .reciprocal;
    return .not_reciprocal;
}

/// compute the `reciprocal` boolean. Returns `true` only when:
///   - harness_license is non-null (harness is open-source), AND
///   - model_reciprocity is "open-source" or "open-weight", AND
///   - provider_closed_training is one of "never", "opt-in", or "opt-out"
///     (provider does not unilaterally train closed models on customer data).
/// Any null on the three conjuncts makes the result `false`: per the
/// AI Policy, an unverified status cannot be assumed reciprocal.
/// This is the same conjunction `reciprocityOf` uses for its non-null
/// case, so the cooked JSON `reciprocal` field stays a boolean while
/// the tri-state caller gets the full picture.
pub fn computeReciprocal(d: *const Detection) bool {
    if (d.harness_license == null) return false;
    const mr = d.model_reciprocity orelse return false;
    if (!std.mem.eql(u8, mr, "open-source") and !std.mem.eql(u8, mr, "open-weight")) return false;
    const pct = d.provider_closed_training orelse return false;
    return std.mem.eql(u8, pct, "never") or std.mem.eql(u8, pct, "opt-in") or std.mem.eql(u8, pct, "opt-out");
}

/// The detection report is a JSON object assembled from three
/// components:
/// - `buildCooked` — the shape-stable 18-field canonical object,
///   grouped by entity (harness / provider / model / agent).
/// - `buildRaw` — the shapeless raw observations object (dev binary
///   only), whose top-level keys identify source evidence.
/// - `buildTrailer` — the `Co-authored-by` string.
/// The released binary's `cooked` action serializes `buildCooked` at
/// the root; the dev binary's fixture format embeds all three as
/// `{cooked, raw, trailer}`.

/// Extract the user's home directory once so we can redact it from
/// every emitted string — fixtures must be portable across machines.
/// `home` is empty when neither USERPROFILE nor HOME is set, in which
/// case redactHome is a no-op for the literal-path branch.
fn reporterHome(env: *const std.process.Environ.Map) []const u8 {
    return env.get("USERPROFILE") orelse (env.get("HOME") orelse "");
}

/// Build the canonical `cooked` object (18 fields, grouped by entity).
/// Returns a heap-allocated `std.json.Value` the caller owns.
fn buildCooked(a: std.mem.Allocator, d: *const Detection) !std.json.Value {
    const V = std.json.Value;
    // Each canonical field is `?[]const u8` (or `?bool`). Use a small
    // helper to emit `null` when absent so partial-detection fixtures
    // read as `null`, not `""`. The previous shape serialized nulls as
    // empty strings, which made `harness_license: ""`
    // indistinguishable from a project that actually has an
    // empty-string SPDX license.
    var canonical: V = .{ .object = .empty };
    try canonical.object.put(a, "harness_label", optStringValue(a, d.harness_label));
    try canonical.object.put(a, "harness_short_title", optStringValue(a, d.harness_short_title));
    try canonical.object.put(a, "harness_name", optStringValue(a, d.harness_name));
    try canonical.object.put(a, "harness_id", optStringValue(a, d.harness_id));
    try canonical.object.put(a, "harness_license", optStringValue(a, d.harness_license));
    try canonical.object.put(a, "provider_label", optStringValue(a, d.provider_label));
    try canonical.object.put(a, "provider_name", optStringValue(a, d.provider_name));
    try canonical.object.put(a, "provider_id", optStringValue(a, d.provider_id));
    try canonical.object.put(a, "provider_closed_training", optStringValue(a, d.provider_closed_training));
    try canonical.object.put(a, "provider_open_training", optStringValue(a, d.provider_open_training));
    try canonical.object.put(a, "model_label", optStringValue(a, d.model_label));
    try canonical.object.put(a, "model_short_title", optStringValue(a, d.model_short_title));
    try canonical.object.put(a, "model_name", optStringValue(a, d.model_name));
    try canonical.object.put(a, "model_id", optStringValue(a, d.model_id));
    try canonical.object.put(a, "model_reciprocity", optStringValue(a, d.model_reciprocity));
    // agent id is composed of the three sub-ids above; emitted in the
    // model block (after model_id) so the canonical
    // block reads harness → provider → model → agent.
    try canonical.object.put(a, "agent_id", optStringValue(a, d.agent_id));
    // `reciprocal` is `?bool` in Detection but the JSON output uses
    // `null` for "not computed" — V has no `?bool` so we unbox manually.
    if (d.reciprocal) |r| {
        try canonical.object.put(a, "reciprocal", .{ .bool = r });
    } else {
        try canonical.object.put(a, "reciprocal", .null);
    }
    try canonical.object.put(a, "trailer", optStringValue(a, d.trailer));
    return canonical;
}

/// the trailer string for `d`, if one was computed. Delegates to the
/// stored `d.trailer` (set by `detect` / recipe resolution).
pub fn buildTrailer(d: *const Detection) ?[]const u8 {
    return d.trailer;
}

/// Build a commit-trailer line for `d` with the given keyword (e.g.
/// `Co-authored-by` / `Assisted-by`), or `null` when the identity is
/// incomplete (any of harness_label / model_label / agent_id null).
/// Output format: `{keyword}: {harness_label} · {model_label}
/// <{agent_id}@local>` — the `·` is a middle-dot separator, not a
/// hyphen; the email local (machine-readable side) uses `-`.
pub fn buildTrailerLine(a: std.mem.Allocator, d: *const Detection, keyword: []const u8) !?[]u8 {
    if (d.harness_label == null or d.model_label == null or d.agent_id == null) return null;
    return @as(?[]u8, try std.fmt.allocPrint(
        a,
        "{s}: {s} · {s} <{s}@local>",
        .{ keyword, d.harness_label.?, d.model_label.?, d.agent_id.? },
    ));
}

/// emit the slim released JSON report (canonical fields at the root,
/// no `raw` block) into `buf`. The `cooked` action uses this directly.
pub fn buildJson(a: std.mem.Allocator, d: *const Detection, env: *const std.process.Environ.Map, rule: ?HarnessRule, anc: Ancestry, buf: *std.ArrayList(u8)) !void {
    _ = env;
    _ = rule;
    _ = anc;
    const cooked = try buildCooked(a, d);
    const json_bytes = try std.json.Stringify.valueAlloc(a, cooked, .{ .whitespace = .indent_2 });
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
    \\agent-detect — infer the harness, provider, and model of the current agent session
    \\
    \\usage:
    \\  agent-detect <action> [options]
    \\
    \\actions:
    \\  cooked         print the detection report as JSON (harness, provider, model, policy)
    \\  trailer        print a commit trailer — requires a subtype (see `trailer help`)
    \\                   co-author     Co-authored-by: (Bevry commits.md)
    \\                   assisted-by   Assisted-by:   (e.g. GCC AI policy)
    \\  is-reciprocal  check reciprocity compliance with Bevry's AI policy
    \\  help           this help (also --help, -h, or no arguments)
    \\  version        print the version (also --version, -V)
    \\
    \\options:
    \\  --harness=H --provider=P --model=M
    \\                 resolve the action from the rule tables instead of live
    \\                 detection (all three together, or none)
    \\
    \\examples:
    \\  agent-detect cooked
    \\  agent-detect trailer co-author
    \\  agent-detect trailer assisted-by
    \\  agent-detect is-reciprocal
    \\  agent-detect cooked --harness=kilo --provider=deepseek --model=deepseek-v4-flash
    \\
    \\exit codes:
    \\  is-reciprocal: 0 is reciprocal · 10 not reciprocal · 9 undeterminable ·
    \\  8 undetectable · 7 unknown combo; others: 0 ok · 2 unrecognised argument ·
    \\  3 conflicting argument · 4 missing required arguments · 8 undetectable.
    \\  Full registry: DESIGN.md "exit status registry".
    \\
;

/// decision #8 — the dev binary's top-level help: the released usage
/// plus a dev-actions block referencing the fixtures namespace, the
/// three refresh modes, and the daemon pacing/control flags. The
/// released `agent-detect --help` is `usage` alone.
const devUsage = if (dev_build)
    usage ++
    \\
    \\dev actions (maintainer-only binary — `fixtures help` has the full namespace):
    \\  fixtures daemon   long-running queue worker (user-only, never inside an agent);
    \\                    pops rows in order from-ids → from-raw → from-capture with
    \\                    adaptive pacing; pause/resume/stop via fixtures/daemon.ctl
    \\  fixtures capture  capture the current session into fixtures/<id>.json
    \\                    (daemon-spawned, or run by hand inside a harness session)
    \\  fixtures queue    upsert queue rows [scope flags] [--from-ids|--from-raw|--from-capture]
    \\  fixtures dequeue  DELETE matching queue rows [--from-ids|--from-raw|--from-capture]
    \\  fixtures help     the fixtures namespace's full help
    \\  refresh run       internal: the `from-raw` capture worker; agent-detect spawning
    \\                    itself under the daemon-prepared env
    \\  raw               print only the raw observations block
    \\
    \\mode flags (queue stamps rows, dequeue filters them; exactly one; default from-raw):
    \\  --from-ids        resolve cooked from provided ids — declared, not observed,
    \\                    zero tokens, harness binary not required
    \\  --from-raw        (default) fabricate env markers + config files and run the
    \\                    detection ladder via `refresh run` — zero tokens
    \\  --from-capture    launch the real harness so it runs `fixtures capture` in a live
    \\                    model session — token-consuming, user-confirmed only
    \\
    \\daemon flags:
    \\  --write-log                 write daemon output to fixtures/daemon.log
    \\  --poll-seconds=N            base poll interval (default 5)
    \\  --capture-review-seconds=N  pre/post capture pause for from-capture jobs (default 15)
    \\  --capture-timeout-seconds=N from-capture worker timeout (default 600)
    \\
else
    usage;

const trailerUsage =
    \\agent-detect trailer — print a commit trailer for the detected agent
    \\
    \\usage:
    \\  agent-detect trailer <type> [--harness=H --provider=P --model=M]
    \\
    \\types:
    \\  co-author      print the Co-authored-by: trailer (Bevry's commits.md)
    \\  assisted-by    print the Assisted-by: trailer (e.g. GCC AI policy)
    \\
    \\examples:
    \\  git commit --trailer "$(agent-detect trailer co-author)"
    \\  git commit --trailer "$(agent-detect trailer assisted-by)"
    \\
;

// ============================================================================
// detection ladder — single source of truth for what `agent-detect`
// observes in the current session. Called by the `cooked` action (both
// the released JSON report and the dev fixture capture).
//
// Fixtures are real-agent captures, not synthetic assemblies: every
// step reads the actual env / process tree / config files at the
// current instant.
//
// Returns `true` when `harness`, `provider`, and `model` all resolved
// (caller can emit a `trailer`); `false` otherwise.

// Recipe-mode resolution — produce a fully-shaped `Detection` for a
// known `(harness, provider, model)` combo WITHOUT running the live
// detection ladder. Used by `cooked --harness=H --provider=P
// --model=M` and `trailer --harness=H --provider=P --model=M`, which
// must emit output for hard-to-detect agents purely from the rule
// tables (no env markers / config files needed).
//
// Returns `null` when any of the three ids is not a known harness /
// provider / model rule — the combo is not a valid recipe and the
// caller exits 2. The `detectable` list is fully populated (a full
// known combo implies all three dims are resolvable); `detected` is
// derived in buildRaw from whatever landed in the canonical fields.
pub fn resolveRecipe(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8) !?Detection {
    // All three ids must be known rules — an unknown dim is an invalid
    // combo (caller exits 2). Combos may be given in either the
    // canonical spelling or the strict slug form (`cline-pass` vs
    // `clinepass`), so every lookup matches both.
    const harness = harnessRuleForName(h) orelse blk: {
        var found: ?HarnessRule = null;
        for (rulesForHarnesses) |r| {
            if (ruleIdMatches(r.name, h)) {
                found = r;
                break;
            }
        }
        break :blk found orelse return null;
    };
    const provider = providerMetaForName(p) orelse blk: {
        var found: ?ProviderRule = null;
        for (rulesForProviders) |r| {
            if (ruleIdMatches(r.name, p)) {
                found = r;
                break;
            }
        }
        break :blk found orelse return null;
    };
    var model_rule: ?ModelRule = null;
    for (rulesForModels) |r| {
        if (ruleIdMatches(r.name, m)) {
            model_rule = r;
            break;
        }
    }
    const model = model_rule orelse return null;

    var d = Detection{};
    d.harness_label = try a.dupe(u8, harness.label);
    if (harness.short_title) |st| d.harness_short_title = try a.dupe(u8, st);
    d.harness_name = harness.name;
    d.harness_id = try slugId(a, harness.name);
    if (harness.version) |v| d.harness_version = try a.dupe(u8, v);
    d.harness_license = harness.license;
    d.raw.harness_urls = harness.license_sources;
    // A full known recipe implies all three dims are resolvable.
    d.detectable = &.{ "harness", "provider", "model" };
    d.provider_name = provider.name;
    d.provider_label = provider.label;
    d.provider_id = try slugId(a, provider.name);
    d.provider_closed_training = provider.closed_training;
    d.provider_open_training = provider.open_training;
    d.raw.provider_urls = provider.sources;
    d.model_label = try a.dupe(u8, model.label);
    if (model.short_title) |st| d.model_short_title = try a.dupe(u8, st);
    d.model_name = model.name;
    d.model_id = try slugId(a, model.name);
    d.model_reciprocity = model.reciprocity;
    d.raw.model_urls = model.sources;
    try setAgentId(a, &d);
    d.reciprocal = computeReciprocal(&d);
    d.trailer = try buildTrailerLine(a, &d, "Co-authored-by");
    return d;
}

pub fn detect(init: std.process.Init, d: *Detection) !bool {
    const a = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const anc = ancestorInfo(a, io);

    var rule: ?HarnessRule = null;
    var hsrc: []const u8 = "none";
    var hclaim_name: []const u8 = ""; // the matched env marker / proc name
    scan: for (rulesForHarnesses) |r| {
        for (r.env_markers) |m| {
            if (env.get(m) != null) {
                rule = r;
                hsrc = "env";
                hclaim_name = m;
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
            hclaim_name = "";
        }
    }
    if (rule == null) {
        for (rulesForHarnesses) |r| {
            for (r.proc_names) |pn| {
                for (anc.names) |n| {
                    if (std.mem.eql(u8, n, pn)) {
                        rule = r;
                        hsrc = "ancestor";
                        hclaim_name = n;
                    }
                }
            }
        }
    }

    if (rule) |r| {
        d.harness_label = try a.dupe(u8, r.label);
        if (r.short_title) |st| d.harness_short_title = try a.dupe(u8, st);
        d.harness_name = r.name;
        d.harness_id = try slugId(a, r.name);
        if (r.version) |v| d.harness_version = try a.dupe(u8, v);
        d.harness_license = r.license;
        d.raw.harness_urls = r.license_sources;
        // decision #11: the harness dim's evidence claim. The source is
        // the marker var / proc name that actually matched (present in
        // raw.env / raw.process_lineage); the value is the harness's
        // canonical name, which is what the rule links the marker to.
        if (hclaim_name.len > 0) {
            try addEvidenceClaim(a, d, .{
                .dim = "harness",
                .source = if (std.mem.eql(u8, hsrc, "env")) "env" else "lineage",
                .name = hclaim_name,
                .value = r.name,
            });
        }
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
            try detectPi(a, io, env, home, d);
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
    // `agent_id` (harness-provider-model), which now
    // includes the provider so reciprocity on changelogs can be
    // post-verified from the trailer alone. The display name uses
    // `<harness_title> · <model_title>` with a middle-dot separator
    // (rather than `-`) for human readability — the email is the
    // machine-readable side and uses `-`.
    d.trailer = try buildTrailerLine(a, d, "Co-authored-by");
    // `detectable` — the dims this run's ladder *could* resolve (from
    // the env-marker/process-ancestry match + the per-harness config
    // read). `detected` is derived from the canonical fields post-hoc
    // in buildRaw; here we record only the capability.
    var detectable = std.ArrayList([]const u8).empty;
    if (d.harness_id != null) try detectable.append(a, "harness");
    if (d.provider_id != null) try detectable.append(a, "provider");
    if (d.model_id != null) try detectable.append(a, "model");
    d.detectable = try detectable.toOwnedSlice(a);
    return d.harness_label != null and d.provider_label != null and d.model_label != null;
}

// ============================================================================
// fixtures agent — captures the current real session into
// `fixtures/<stem>.json` (single `{cooked, raw, trailer}` file).
// Designed to be invoked by an agent harness
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
// capture path. `fixtures daemon` is the long-running user-side mode: it
// watches the sqlite `queue` table and, for each queue row, spawns
// a child `refresh run` that runs the capture (dev.runFixturesCapture)
// in-process with the environment the daemon prepared. The released
// binary (built with -Ddev=false, the default) has none of this — its
// CLI surface is `cooked` (JSON report), `trailer co-author` /
// `trailer assisted-by`, `is-reciprocal`, `help`, and
// `version`; no arguments shows help.

pub const dev = if (build_options.dev) struct {

    /// usage text for the `fixtures` subcommand namespace — printed by
    /// `fixtures --help`, bare `fixtures`, and `fixtures help`.
    pub const fixturesUsage =
        \\agent-detect fixtures — manage the fixtures-agent fixture store (dev builds)
        \\
        \\usage: agent-detect fixtures <subcommand> [flags]
        \\
        \\state: fixtures/index.sqlite3 holds two tables — `fixtures` (one row
        \\per captured 4-tuple harness/provider/model/platform) and `queue`
        \\(the work queue). fixtures/<id>.json are the generated fixtures
        \\(single file, top-level `cooked`/`raw`/`trailer`/`origin` keys). Queue rows
        \\with missing dims are seeds: the daemon expands them over fixtures
        \\recipes (full combos queued, other seeds warned and kept).
        \\
        \\refresh modes (queue stamps; dequeue filters; exactly one, default
        \\from-raw; two+ together → exit 3; one mode per combo — re-queueing
        \\with a different mode upgrades/downgrades the single row):
        \\  --from-ids        resolve cooked from provided ids — declared, not
        \\                    observed; zero tokens; harness binary not required
        \\  --from-raw        (default) fabricate env markers + config files and
        \\                    run the detection ladder via `refresh run` — zero tokens
        \\  --from-capture    launch the real harness so it runs `fixtures capture`
        \\                    in a live model session — token-consuming,
        \\                    user-confirmed only; one at a time, ~15s pre/post review
        \\
        \\daemon flags:
        \\  --write-log                 tee daemon output to fixtures/daemon.log
        \\  --poll-seconds=N            base poll interval (default 5)
        \\  --capture-review-seconds=N  pre/post capture pause (default 15)
        \\  --capture-timeout-seconds=N from-capture worker timeout (default 600)
        \\
        \\control: write pause/resume/stop to fixtures/daemon.ctl (checked every
        \\~1s; the daemon clears it after acting). Ctrl+C is the graceful stop.
        \\
        \\filters (shared by queue/dequeue; at least one required):
        \\  --fixture=ID  4-part <h>-<p>-<m>-<platform> id (exact)
        \\  --agent=ID    3-part <h>-<p>-<m> id (platform unfiltered)
        \\  --harness=H   constrain harness to H (any of H/P/M/PLAT)
        \\
        \\scope flags (shared by queue/dequeue; exactly one, and they
        \\compose with the dim filters above to narrow the set):
        \\  --all            every fixture row on this platform
        \\  --stale          fixture rows older than the threshold
        \\                   [--stale-by-days=N] [--stale-by-minutes=N]
        \\                   (--stale is an alias for --stale-by-days=7)
        \\  --partial        queue rows with at least one missing dim (seeds)
        \\  --recipes        every known recipe (host platform)
        \\  --missing-fixture recipes whose fixtures/<id>.json is absent
        \\                   from disk
        \\  --available      modifier: probe each candidate's harness and
        \\                   record 1/0 into the available column (unavailable
        \\                   rows stay queued as handoff for another platform;
        \\                   from-ids records but does not gate on it)
        \\  --unavailable    modifier (dequeue only): match available=0 rows
        \\                   (alias --available=0)
        \\
        \\subcommands:
        \\  (none), help, --help, -h   this help
        \\  daemon                     pop queue rows from fixtures/index.sqlite3 and
        \\                              capture (poll ~1s heartbeat; 5s poll base) —
        \\                              run as a user, never inside an agent;
        \\                              --write-log also writes all daemon output
        \\                              to fixtures/daemon.log
        \\  capture                    capture the current session into a single
        \\                              fixtures/<id>.json + a fixtures row
        \\                              (spawned by the daemon; fixtures only)
        \\  queue                      enumerate + upsert queue rows (no
        \\                              evaluation; no scope flag → seed with
        \\                              the positive dims)
        \\  dequeue                    DELETE matching queue rows (filters
        \\                              required; never touches fixtures)
        \\
        \\exit codes: 0 = ok, 2 = unrecognised argument, 3 = conflicting argument,
        \\4 = missing required arguments, 5 = incompatible environment, 6 = incomplete
        \\environment, 8 = unable to detect, 11 = out of memory, 12 = sqlite query error,
        \\13 = filesystem I/O error
        \\
    ;

    /// print the `fixtures` namespace help and exit 0.
    pub fn runFixturesHelp(init: std.process.Init) !u8 {
        const io = init.io;
        writeOut(io, fixturesUsage);
        return 0;
    }

    /// which of the three detection dims actually populated `d`'s
    /// canonical fields (harness_id / provider_id / model_id non-null).
    fn detectedDims(a: std.mem.Allocator, d: *const Detection) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        if (d.harness_id != null) try list.append(a, "harness");
        if (d.provider_id != null) try list.append(a, "provider");
        if (d.model_id != null) try list.append(a, "model");
        return list.toOwnedSlice(a);
    }

    /// build the `raw` observations object (dev binary only). Top-level
    /// keys: `platform_id`, then the `detectable` + `detected` dimension
    /// arrays adjacent to it, then the shapeless runtime observations.
    /// Returns a heap-allocated `std.json.Value`; the caller owns it.
    fn buildRaw(a: std.mem.Allocator, d: *const Detection, env: *const std.process.Environ.Map) !std.json.Value {
        const V = std.json.Value;
        const home = reporterHome(env);
        var raw: V = .{ .object = .empty };
        // platform id (compile-time constant) is emitted as a top-level
        // raw key so a maintainer reading a fixture knows which
        // platform it was captured on, even before they read the
        // canonical `agent_id` (which is also platform-tagged via the
        // `fixture_id` filename).
        try raw.object.put(a, "platform_id", .{ .string = platformId() });
        // `detectable` — the dims this run's ladder/recipe *could*
        // resolve; `detected` — the subset that actually landed in
        // `cooked`. Emitted adjacent to each other so a reader
        // instantly sees what the fixture claims without scanning
        // `cooked`.
        try raw.object.put(a, "detectable", stringListValue(a, d.detectable));
        try raw.object.put(a, "detected", stringListValue(a, try detectedDims(a, d)));
        // The `value` field is only emitted when the var's name is on
        // the secrets allow-list AND the var is present in the
        // environment. Otherwise the entry is `{"present": <bool>}` —
        // absent for vars the harness rule declared but the runtime env
        // didn't have, or redacted-by-default for secret-shaped names
        // not on the allow-list. Keeping `value` only when it's the
        // real on-disk content avoids emitting empty-string
        // placeholders that look like real but-blank values to a
        // maintainer scanning the fixture.
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
        // agent-detect, index 1 = its parent, etc.).
    {
        var lineage: V = .{ .array = std.json.Array.init(a) };
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
        // decision #11 — evidence claims, one per detected dim, pinning
        // the attribution chain (source present in raw + value matching
        // the cooked dim). `from-ids` fixtures carry an empty array.
        {
            var ev_arr: V = .{ .array = std.json.Array.init(a) };
            for (d.raw.evidence) |claim| {
                var c_obj: V = .{ .object = .empty };
                try c_obj.object.put(a, "dim", .{ .string = claim.dim });
                try c_obj.object.put(a, "source", .{ .string = claim.source });
                try c_obj.object.put(a, "name", .{ .string = try redactHome(a, claim.name, home) });
                if (claim.field) |fld| {
                    try c_obj.object.put(a, "field", .{ .string = fld });
                }
                if (claim.value) |val| {
                    try c_obj.object.put(a, "value", .{ .string = try redactHome(a, val, home) });
                }
                try ev_arr.array.append(c_obj);
            }
            try raw.object.put(a, "evidence", ev_arr);
        }
        // harness_version is the matched rule's declared release version
        // (e.g. "1.2.3") when the rule tracks one. Only emitted when
        // the rule declared it — null rules (most currently) skip the
        // field. It is the maintainer-curated version string from the
        // rule, NOT a runtime observation; surfaced under raw so a
        // fixture shows which version the maintainer expected when
        // authoring the rule.
        if (d.harness_version) |v| {
            try raw.object.put(a, "harness_version", .{ .string = v });
        }
        return raw;
    }

    /// dev-only `raw` action — emit only the raw observations block
    /// (standalone, with `detectable` + `detected`). Data-output action:
    /// identity unresolved → exit 8 with no stdout (no sensible data);
    /// identity complete but reciprocity/policy data incomplete → exit 9
    /// with the raw block on stdout + a stderr explainer; full identity →
    /// exit 0.
    pub fn runRawAction(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;
        var d = Detection{};
        const ok = try detect(init, &d);
        const raw_v = try buildRaw(a, &d, init.environ_map);
        const json_bytes = try std.json.Stringify.valueAlloc(a, raw_v, .{ .whitespace = .indent_2 });
        defer a.free(json_bytes);
        if (!ok) {
            writeErr(io, MSG_UNABLE_TO_DETECT);
            return EXIT_UNABLE_TO_DETECT;
        }
        writeOut(io, json_bytes);
        writeOut(io, "\n");
        if (reciprocityOf(&d) == .unknown) {
            writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
            return EXIT_AGENT_DATA_INCOMPLETE;
        }
        return EXIT_OK;
    }

    // ------------------------------------------------------------------
    // SQLite storage via the `sqlite3` CLI (two tables: fixtures + queue)
    // ------------------------------------------------------------------

    /// Writes/reads shell out to the
    /// system `sqlite3` binary (single-file `fixtures/index.sqlite3`).
    const INDEX_DB_PATH = "fixtures/index.sqlite3";

    /// Spawn `sqlite3 -json <db> <sql>` and return its stdout. Empty for
    /// statements that return no rows. Caller owns the returned slice.
    /// Does NOT create the dir or ensure the schema (see `sqliteQuery`).
    /// Deliberate mirror of the released-binary `kiloSqliteJson` — this
    /// one is fixed to `fixtures/index.sqlite3` and compiled out of the
    /// released binary via the dev-gated block.
    fn sqliteRun(a: std.mem.Allocator, io: std.Io, sql: []const u8) ![]u8 {
        var argv_buf = [_][]const u8{ "sqlite3", "-json", "-batch", INDEX_DB_PATH, sql };
        var child = std.process.spawn(io, .{
            .argv = &argv_buf,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.SqliteSpawnFailed;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try out.ensureTotalCapacity(a, 4096);
        var buf: [8192]u8 = undefined;
        var reader = child.stdout.?.reader(io, &buf);
        while (true) {
            var chunk: [8192]u8 = undefined;
            const n = reader.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try out.appendSlice(a, chunk[0..n]);
        }
        const term = child.wait(io) catch return error.SqliteSpawnFailed;
        switch (term) {
            .exited => |code| if (code != 0) return error.SqliteError,
            else => return error.SqliteError,
        }
        return out.toOwnedSlice(a);
    }

    /// Ensure the `fixtures/` dir and the two-table schema exist (idempotent).
    /// Called before every query.
    fn ensureSchema(a: std.mem.Allocator, io: std.Io) !void {
        std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.FilesystemIoError,
        };
        _ = try sqliteRun(a, io,
            \\PRAGMA busy_timeout = 5000;
            \\CREATE TABLE IF NOT EXISTS fixtures (
            \\    harness                 TEXT NOT NULL,
            \\    provider                TEXT NOT NULL,
            \\    model                   TEXT NOT NULL,
            \\    platform                TEXT NOT NULL,
            \\    runner                  INTEGER NOT NULL,
            \\    generated_at            INTEGER NOT NULL,
            \\    PRIMARY KEY (harness, provider, model, platform)
            \\);
            \\CREATE TABLE IF NOT EXISTS queue (
            \\    harness              TEXT,
            \\    provider             TEXT,
            \\    model                TEXT,
            \\    platform             TEXT,
            \\    scope_all            INTEGER,
            \\    scope_partial        INTEGER,
            \\    scope_recipes        INTEGER,
            \\    scope_missing_fixture INTEGER,
            \\    stale_by_days        INTEGER,
            \\    stale_by_minutes     INTEGER,
            \\    available            INTEGER,
            \\    runner               INTEGER NOT NULL,
            \\    created_at           INTEGER NOT NULL,
            \\    mode                 TEXT NOT NULL DEFAULT 'from-raw'
            \\);
            \\CREATE UNIQUE INDEX IF NOT EXISTS queue_dedupe
            \\    ON queue (COALESCE(harness,''), COALESCE(provider,''), COALESCE(model,''),
            \\                COALESCE(platform,''), COALESCE(scope_all,0), COALESCE(scope_partial,0),
            \\                COALESCE(scope_recipes,0), COALESCE(scope_missing_fixture,0),
            \\                COALESCE(stale_by_days,0), COALESCE(stale_by_minutes,0),
            \\                COALESCE(available,0));
            \\
        );
    }

    /// Ensure schema, then run `sql` and return its stdout (JSON for
    /// SELECT). Caller owns the returned slice.
    fn sqliteQuery(a: std.mem.Allocator, io: std.Io, sql: []const u8) ![]u8 {
        try ensureSchema(a, io);
        return sqliteRun(a, io, sql);
    }

    /// One row in the `queue` table. `mode` is the refresh flavour
    /// (`"from-ids" | "from-raw" | "from-capture"`, default `from-raw`)
    /// — stamped by `fixtures queue`, inherited by seed expansions,
    /// and used as the daemon's pop-order + worker selector. Deliberately
    /// NOT part of `queue_dedupe`: one mode per combo, re-queueing with a
    /// different mode flag upgrades/downgrades the single row in place.
    const QueueRow = struct {
        harness: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        model: ?[]const u8 = null,
        platform: ?[]const u8 = null,
        scope_all: ?i64 = null,
        scope_partial: ?i64 = null,
        scope_recipes: ?i64 = null,
        scope_missing_fixture: ?i64 = null,
        stale_by_days: ?i64 = null,
        stale_by_minutes: ?i64 = null,
        available: ?i64 = null,
        runner: i64 = 0,
        created_at: i64 = 0,
        mode: []const u8 = "from-raw",
    };

    /// One row in the `fixtures` state table (always full; platform = host).
    const FixtureRow = struct {
        harness: []const u8,
        provider: []const u8,
        model: []const u8,
        platform: []const u8,
        runner: i64,
        generated_at: i64,
    };

    /// current unix epoch seconds (staleness source / queue order).
    fn unixNow(io: std.Io) i64 {
        const ts = std.Io.Clock.Timestamp.now(io, .real);
        return ts.raw.toSeconds();
    }

    /// SQL-escape a string literal (single-quote doubling). Dims are
    /// alphanumeric so this is mostly defensive.
    fn sqlQuote(a: std.mem.Allocator, s: []const u8) ![]u8 {
        if (std.mem.indexOfScalar(u8, s, '\'') == null) {
            return std.fmt.allocPrint(a, "'{s}'", .{s});
        }
        var out: std.ArrayList(u8) = .empty;
        try out.append(a, '\'');
        for (s) |c| {
            if (c == '\'') try out.append(a, '\'');
            try out.append(a, c);
        }
        try out.append(a, '\'');
        return out.toOwnedSlice(a);
    }

    /// render an optional string as a quoted literal or NULL.
    fn sqlOptStr(a: std.mem.Allocator, opt: ?[]const u8) ![]u8 {
        if (opt) |s| return sqlQuote(a, s);
        return a.dupe(u8, "NULL");
    }

    /// render an optional integer as its value or NULL (allocated).
    fn sqlOptInt(a: std.mem.Allocator, v: ?i64) ![]u8 {
        if (v) |x| return std.fmt.allocPrint(a, "{d}", .{x});
        return a.dupe(u8, "NULL");
    }

    /// `INSERT OR REPLACE INTO queue` — idempotent via `queue_dedupe`.
    fn upsertQueueRow(a: std.mem.Allocator, io: std.Io, row: QueueRow) !void {
        const h = try sqlOptStr(a, row.harness);
        defer a.free(h);
        const p = try sqlOptStr(a, row.provider);
        defer a.free(p);
        const m = try sqlOptStr(a, row.model);
        defer a.free(m);
        const pl = try sqlOptStr(a, row.platform);
        defer a.free(pl);
        const sa = try sqlOptInt(a, row.scope_all);
        defer a.free(sa);
        const sp = try sqlOptInt(a, row.scope_partial);
        defer a.free(sp);
        const sr = try sqlOptInt(a, row.scope_recipes);
        defer a.free(sr);
        const sm = try sqlOptInt(a, row.scope_missing_fixture);
        defer a.free(sm);
        const sd = try sqlOptInt(a, row.stale_by_days);
        defer a.free(sd);
        const smin = try sqlOptInt(a, row.stale_by_minutes);
        defer a.free(smin);
        const av = try sqlOptInt(a, row.available);
        defer a.free(av);
        const sql = try std.fmt.allocPrint(a,
            "INSERT OR REPLACE INTO queue(harness,provider,model,platform,scope_all,scope_partial,scope_recipes,scope_missing_fixture,stale_by_days,stale_by_minutes,available,runner,created_at,mode) VALUES({s},{s},{s},{s},{s},{s},{s},{s},{s},{s},{s},{d},{d},{s})",
            .{ h, p, m, pl, sa, sp, sr, sm, sd, smin, av, row.runner, row.created_at, try sqlQuote(a, row.mode) },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// `INSERT OR REPLACE INTO fixtures` — state, written only by `fixtures
    /// agent` and the daemon. No `available` column.
    fn upsertFixture(a: std.mem.Allocator, io: std.Io, f: FixtureRow) !void {
        const sql = try std.fmt.allocPrint(a,
            "INSERT OR REPLACE INTO fixtures(harness,provider,model,platform,runner,generated_at) VALUES({s},{s},{s},{s},{d},{d})",
            .{
                try sqlQuote(a, f.harness), try sqlQuote(a, f.provider),
                try sqlQuote(a, f.model), try sqlQuote(a, f.platform),
                f.runner, f.generated_at,
            },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// every `fixtures` row (for `--all` / `--stale` enumeration).
    fn selectFixtures(a: std.mem.Allocator, io: std.Io) ![]FixtureRow {
        const out = try sqliteQuery(a, io, "SELECT harness,provider,model,platform,runner,generated_at FROM fixtures");
        defer a.free(out);
        if (out.len == 0) return &.{};
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return &.{};
        return jsonToFixtures(a, parsed.value);
    }

    fn jsonToFixtures(a: std.mem.Allocator, v: std.json.Value) ![]FixtureRow {
        if (v != .array) return &.{};
        var rows: std.ArrayListUnmanaged(FixtureRow) = .empty;
        errdefer rows.deinit(a);
        for (v.array.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            rows.append(a, .{
                .harness = sjstr(o, "harness"),
                .provider = sjstr(o, "provider"),
                .model = sjstr(o, "model"),
                .platform = sjstr(o, "platform"),
                .runner = sjint(o, "runner"),
                .generated_at = sjint(o, "generated_at"),
            }) catch continue;
        }
        return rows.toOwnedSlice(a);
    }

    /// every `queue` row whose dims are all NULL (seeds) — for `--partial`.
    fn selectSeedQueueRows(a: std.mem.Allocator, io: std.Io) ![]QueueRow {
        const out = try sqliteQuery(a, io,
            "SELECT harness,provider,model,platform,scope_all,scope_partial,scope_recipes,scope_missing_fixture,stale_by_days,stale_by_minutes,available,runner,created_at,mode FROM queue WHERE harness IS NULL OR provider IS NULL OR model IS NULL OR platform IS NULL",
        );
        defer a.free(out);
        if (out.len == 0) return &.{};
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return &.{};
        return jsonToQueueRows(a, parsed.value);
    }

    fn jsonToQueueRows(a: std.mem.Allocator, v: std.json.Value) ![]QueueRow {
        if (v != .array) return &.{};
        var rows: std.ArrayListUnmanaged(QueueRow) = .empty;
        errdefer rows.deinit(a);
        for (v.array.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            const row = jsonToQueueRow(o) catch continue;
            try rows.append(a, row);
        }
        return rows.toOwnedSlice(a);
    }

    fn jsonToQueueRow(o: std.json.ObjectMap) !QueueRow {
        return .{
            .harness = sjoptstr(o, "harness"),
            .provider = sjoptstr(o, "provider"),
            .model = sjoptstr(o, "model"),
            .platform = sjoptstr(o, "platform"),
            .scope_all = sjoptint(o, "scope_all"),
            .scope_partial = sjoptint(o, "scope_partial"),
            .scope_recipes = sjoptint(o, "scope_recipes"),
            .scope_missing_fixture = sjoptint(o, "scope_missing_fixture"),
            .stale_by_days = sjoptint(o, "stale_by_days"),
            .stale_by_minutes = sjoptint(o, "stale_by_minutes"),
            .available = sjoptint(o, "available"),
            .runner = sjint(o, "runner"),
            .created_at = sjint(o, "created_at"),
            .mode = sjstr(o, "mode"),
        };
    }

    /// string field; missing → "".
    fn sjstr(o: std.json.ObjectMap, key: []const u8) []const u8 {
        const v = o.get(key) orelse return "";
        return switch (v) {
            .string => |s| s,
            else => "",
        };
    }
    /// int field; missing/non-int → 0.
    fn sjint(o: std.json.ObjectMap, key: []const u8) i64 {
        const v = o.get(key) orelse return 0;
        return switch (v) {
            .integer => |x| x,
            else => 0,
        };
    }
    /// optional string field; null/missing → null.
    fn sjoptstr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = o.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
    fn sjoptint(o: std.json.ObjectMap, key: []const u8) ?i64 {
        const v = o.get(key) orelse return null;
        return switch (v) {
            .integer => |x| x,
            else => null,
        };
    }

    /// true iff a `fixtures` row exists for the given dims.
    fn fixtureExists(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !bool {
        const sql = try std.fmt.allocPrint(a,
            "SELECT COUNT(*) AS c FROM fixtures WHERE harness={s} AND provider={s} AND model={s} AND platform={s}",
            .{ try sqlQuote(a, h), try sqlQuote(a, p), try sqlQuote(a, m), try sqlQuote(a, plat) },
        );
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return false;
        if (parsed.value != .array or parsed.value.array.items.len == 0) return false;
        const o = parsed.value.array.items[0];
        if (o != .object) return false;
        return sjint(o.object, "c") > 0;
    }

    /// the `fixtures` row for the given dims, or null if absent.
    fn fixtureRow(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !?FixtureRow {
        const sql = try std.fmt.allocPrint(a,
            "SELECT harness,provider,model,platform,runner,generated_at FROM fixtures WHERE harness={s} AND provider={s} AND model={s} AND platform={s}",
            .{ try sqlQuote(a, h), try sqlQuote(a, p), try sqlQuote(a, m), try sqlQuote(a, plat) },
        );
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return null;
        const rows = try jsonToFixtures(a, parsed.value);
        if (rows.len == 0) return null;
        return rows[0];
    }

    /// atomically pop the oldest pending queue row. Returns null when empty.
    fn popQueueRow(a: std.mem.Allocator, io: std.Io) !?QueueRow {
        // sweep ordering (decision #9): from-ids, then from-raw, then
        // from-capture — cheaper/declared work always precedes
        // token-consuming captures.
        const out = try sqliteQuery(a, io,
            "SELECT harness,provider,model,platform,scope_all,scope_partial,scope_recipes,scope_missing_fixture,stale_by_days,stale_by_minutes,available,runner,created_at,mode FROM queue ORDER BY CASE mode WHEN 'from-ids' THEN 0 WHEN 'from-raw' THEN 1 ELSE 2 END, created_at,rowid LIMIT 1",
        );
        defer a.free(out);
        var row: ?QueueRow = null;
        if (out.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return null;
            const rows = try jsonToQueueRows(a, parsed.value);
            if (rows.len > 0) row = rows[0];
        }
        // delete the row we just read (single consumer per host; the daemon
        // is the only evaluator). Use generated_at as a tie-break handle.
        if (row) |_| {
            const sql = try std.fmt.allocPrint(a,
                "DELETE FROM queue WHERE rowid = (SELECT rowid FROM queue ORDER BY CASE mode WHEN 'from-ids' THEN 0 WHEN 'from-raw' THEN 1 ELSE 2 END, created_at,rowid LIMIT 1)",
                .{},
            );
            defer a.free(sql);
            _ = try sqliteQuery(a, io, sql);
        }
        return row;
    }

    /// `DELETE FROM queue` matching the filter. Returns rows deleted.
    fn deleteQueueRows(a: std.mem.Allocator, io: std.Io, f: FilterOptions) !usize {
        var where = std.ArrayList(u8).empty;
        defer where.deinit(a);
        try where.appendSlice(a, "WHERE 1=1");
        if (f.harness.len > 0) try where.appendSlice(a, appendCond(a, "harness", f.harness) catch return 0);
        if (f.provider.len > 0) try where.appendSlice(a, appendCond(a, "provider", f.provider) catch return 0);
        if (f.model.len > 0) try where.appendSlice(a, appendCond(a, "model", f.model) catch return 0);
        if (f.platform.len > 0) try where.appendSlice(a, appendCond(a, "platform", f.platform) catch return 0);
        if (f.all) try where.appendSlice(a, " AND scope_all=1");
        if (f.partial) try where.appendSlice(a, " AND scope_partial=1");
        if (f.recipes) try where.appendSlice(a, " AND scope_recipes=1");
        if (f.missing_fixture) try where.appendSlice(a, " AND scope_missing_fixture=1");
        if (f.stale) try where.appendSlice(a, " AND (stale_by_days IS NOT NULL OR stale_by_minutes IS NOT NULL)");
        if (f.available) try where.appendSlice(a, " AND available=1");
        if (f.unavailable) try where.appendSlice(a, " AND available=0");
        if (f.mode.len > 0) try where.appendSlice(a, appendCond(a, "mode", f.mode) catch return 0);
        // DELETE + SELECT changes() in ONE sqlite3 invocation so the count is
        // connection-local (changes() in a fresh process would read 0).
        const sql = try std.fmt.allocPrint(a, "DELETE FROM queue {s}; SELECT changes() AS c;", .{where.items});
        defer a.free(sql);
        const out = try sqliteRun(a, io, sql);
        defer a.free(out);
        return parseJsonCount(a, out) catch 0;
    }

    /// parse the `[{"c":N}]` JSON produced by `SELECT changes() AS c`.
    fn parseJsonCount(a: std.mem.Allocator, json: []const u8) !usize {
        if (json.len == 0) return 0;
        var it = std.mem.splitScalar(u8, json, '\n');
        while (it.next()) |chunk| {
            if (chunk.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, a, chunk, .{}) catch continue;
            if (parsed.value != .array or parsed.value.array.items.len == 0) continue;
            const o = parsed.value.array.items[0];
            if (o != .object) continue;
            return @intCast(@max(sjint(o.object, "c"), 0));
        }
        return 0;
    }

    fn appendCond(a: std.mem.Allocator, col: []const u8, v: []const u8) ![]u8 {
        const q = try sqlQuote(a, v);
        return std.fmt.allocPrint(a, " AND {s}={s}", .{ col, q });
    }

    /// the shared validator — single source of truth for valid filter
    /// combinations. Called by BOTH writer paths and the daemon reader.
    fn validateQueueRow(row: QueueRow) !void {
        const scope_count = @as(usize, @intFromBool(row.scope_all != null and row.scope_all.? == 1)) +
            @as(usize, @intFromBool(row.scope_partial != null and row.scope_partial.? == 1)) +
            @as(usize, @intFromBool(row.scope_recipes != null and row.scope_recipes.? == 1)) +
            @as(usize, @intFromBool(row.scope_missing_fixture != null and row.scope_missing_fixture.? == 1)) +
            @as(usize, @intFromBool(row.stale_by_days != null or row.stale_by_minutes != null));
        if (scope_count > 1) return error.InvalidQueueRow;
        if (row.stale_by_days != null and row.stale_by_minutes != null) return error.InvalidQueueRow;
        if (row.stale_by_days != null and row.stale_by_days.? < 1) return error.InvalidQueueRow;
        if (row.stale_by_minutes != null and row.stale_by_minutes.? < 1) return error.InvalidQueueRow;
        if (row.available != null and (row.available.? != 0 and row.available.? != 1)) return error.InvalidQueueRow;
        if (row.available != null and scope_count == 0) return error.InvalidQueueRow;
        const scopes = [_]?i64{ row.scope_all, row.scope_partial, row.scope_recipes, row.scope_missing_fixture };
        for (scopes) |s| {
            if (s != null and (s.? != 0 and s.? != 1)) return error.InvalidQueueRow;
        }
    }

    /// human-readable description of a queue row for diagnostics.
    fn describeQueueRow(a: std.mem.Allocator, row: QueueRow) ![]u8 {
        const h = row.harness orelse "";
        const p = row.provider orelse "";
        const m = row.model orelse "";
        const plat = row.platform orelse "";
        if (h.len > 0 and p.len > 0 and m.len > 0 and plat.len > 0) {
            return (try fixtureIdFrom(a, h, p, m, plat)) orelse try tupleKey(a, h, p, m, plat);
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

const EnvSetup = struct {
    env: []const [2][]const u8,
    writes: []const WriteSpec = &.{},
    cwd: []const u8,

    const WriteSpec = struct {
        path: []const u8,
        content: []const u8,
    };
};

const RecipesForFixtures = struct {
    /// Stable composite id in the form
    /// "<harness_id>-<provider_id>-<model_id>"
    /// (e.g. "cline-clinepass-kimik3"). The daemon and queue-* commands
    /// key off this; the three sub-ids are recovered via
    /// `splitAgentId` when needed (sub-ids never contain
    /// `-` because `slugId` strips non-alphanumerics). Every
    /// row here is a fully-resolved fixture recipe.
    agent_id: []const u8,
    /// Binary names to probe on PATH for harness-availability checks.
    probeNames: []const []const u8,
    /// Build the env+files a child `refresh run` needs to detect as
    /// this fixture's agent. One parameterized function per harness —
    /// the combo (provider/model) is derived from `combo.agent_id`, so
    /// a new combo is one line in `recipesForFixtures`.
    buildEnv: *const fn (
        a: std.mem.Allocator,
        env_map: *const std.process.Environ.Map,
        io: std.Io,
        combo: *const RecipesForFixtures,
    ) anyerror!EnvSetup,
    /// Headless launch argv for `from-capture` jobs (2g): the harness
    /// binary + args that run `agent-detect-dev fixtures capture` inside
    /// a live model session. `null` = no reliable headless mode → the
    /// recipe is `from-ids`/`from-raw` only. Starter set only.
    launch: ?[]const []const u8 = null,
};

/// Split an `agent_id` into its three sub-ids. Each
/// returned slice is a fresh allocation the caller owns. The
/// `agent` input is never freed by this function. Returns
/// `error.InvalidAgentId` if the input doesn't have
/// exactly three `-`-separated segments.
fn splitAgentId(a: std.mem.Allocator, agent: []const u8) ![3][]u8 {
    var it = std.mem.tokenizeScalar(u8, agent, '-');
    const h = it.next() orelse return error.InvalidAgentId;
    const p = it.next() orelse return error.InvalidAgentId;
    const m = it.next() orelse return error.InvalidAgentId;
    if (it.next() != null) return error.InvalidAgentId;
    return .{
        try a.dupe(u8, h),
        try a.dupe(u8, p),
        try a.dupe(u8, m),
    };
}

/// Split a `fixture_id` (the h-p-m-platform composite) into
/// its four sub-ids. Each returned slice is a fresh allocation the
/// caller owns. Returns `error.InvalidFixtureId` unless the
/// input has exactly four non-empty `-`-separated segments.
fn splitFixtureId(a: std.mem.Allocator, fixtures: []const u8) ![4][]u8 {
    var it = std.mem.tokenizeScalar(u8, fixtures, '-');
    const h = it.next() orelse return error.InvalidFixtureId;
    const p = it.next() orelse return error.InvalidFixtureId;
    const m = it.next() orelse return error.InvalidFixtureId;
    const plat = it.next() orelse return error.InvalidFixtureId;
    if (it.next() != null) return error.InvalidFixtureId;
    if (h.len == 0 or p.len == 0 or m.len == 0 or plat.len == 0) return error.InvalidFixtureId;
    return .{
        try a.dupe(u8, h),
        try a.dupe(u8, p),
        try a.dupe(u8, m),
        try a.dupe(u8, plat),
    };
}

/// Compose an `agent_id` (h-p-m) from the three dims.
/// Returns null when any dim is missing (never a fabricated partial
/// id). Used for fixture naming and messaging only — never stored.
fn agentIdFrom(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8) !?[]u8 {
    if (h.len == 0 or p.len == 0 or m.len == 0) return null;
    return @as(?[]u8, try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ h, p, m }));
}

/// Compose a `fixture_id` (h-p-m-platform) from the four
/// dims. Returns null when any dim is missing (never a fabricated
/// partial id). Used for fixture naming and messaging only — never
/// stored.
fn fixtureIdFrom(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !?[]u8 {
    if (h.len == 0 or p.len == 0 or m.len == 0 or plat.len == 0) return null;
    return @as(?[]u8, try std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}", .{ h, p, m, plat }));
}

/// The canonical row-identity key for the four dims, as `h~p~m~plat`
/// with empty slots for unset dims. The `~` separator cannot appear
/// in alphanumeric ids (`slugId` strips non-alphanumerics),
/// so the joined form is unambiguous even for partial rows. Every
/// upsert/dedupe/lookup operates on this key, not a flattened id.
fn tupleKey(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}~{s}~{s}~{s}", .{ h, p, m, plat });
}

    pub fn resolveHome(env_map: *const std.process.Environ.Map) []const u8 {
    return env_map.get("HOME") orelse env_map.get("USERPROFILE") orelse
        if (builtin.os.tag == .windows) "C:/Users/default" else "/tmp";
}

/// Dev-only provider metadata (2b): the openai-compatible base_url +
/// API-key env var per provider, used by the from-raw fabricator to
/// write plausible harness configs (e.g. qwen's settings.json
/// modelProviders baseUrl + envKey). `providerForBaseUrl` mirrors the
/// base_url hosts back to provider ids so detection resolves the same
/// upstream the fabricator wrote.
const DevProviderMeta = struct {
    provider: []const u8,
    base_url: []const u8,
    key_env: []const u8,
};
const devProviderMeta = [_]DevProviderMeta{
    .{ .provider = "minimax", .base_url = "https://api.minimax.io/v1", .key_env = "MINIMAX_API_KEY" },
    .{ .provider = "minimax-code", .base_url = "https://api.minimax.io/v1", .key_env = "MINIMAX_API_KEY" },
    .{ .provider = "deepseek", .base_url = "https://api.deepseek.com", .key_env = "DEEPSEEK_API_KEY" },
    .{ .provider = "deepseek-flash", .base_url = "https://api.deepseek.com", .key_env = "DEEPSEEK_API_KEY" },
    .{ .provider = "anthropic", .base_url = "https://api.anthropic.com", .key_env = "ANTHROPIC_API_KEY" },
    .{ .provider = "openrouter", .base_url = "https://openrouter.ai/api/v1", .key_env = "OPENROUTER_API_KEY" },
    .{ .provider = "groq", .base_url = "https://api.groq.com/openai/v1", .key_env = "GROQ_API_KEY" },
    .{ .provider = "cerebras", .base_url = "https://api.cerebras.ai/v1", .key_env = "CEREBRAS_API_KEY" },
    .{ .provider = "zai", .base_url = "https://api.z.ai/api/paas/v4", .key_env = "ZAI_API_KEY" },
    .{ .provider = "kimi", .base_url = "https://api.moonshot.ai/v1", .key_env = "MOONSHOT_API_KEY" },
    .{ .provider = "moonshot", .base_url = "https://api.moonshot.ai/v1", .key_env = "MOONSHOT_API_KEY" },
    .{ .provider = "qwen", .base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1", .key_env = "DASHSCOPE_API_KEY" },
    .{ .provider = "mistral", .base_url = "https://api.mistral.ai/v1", .key_env = "MISTRAL_API_KEY" },
    .{ .provider = "hyper", .base_url = "https://hyper.charm.land/api/v1/fantasy", .key_env = "HYPER_API_KEY" },
    .{ .provider = "goose", .base_url = "https://api.anthropic.com", .key_env = "ANTHROPIC_API_KEY" },
    .{ .provider = "cline-pass", .base_url = "https://api.cline.bot", .key_env = "CLINE_API_KEY" },
    .{ .provider = "cline", .base_url = "https://api.cline.bot", .key_env = "CLINE_API_KEY" },
    .{ .provider = "remote", .base_url = "https://api.anthropic.com", .key_env = "ANTHROPIC_API_KEY" },
};

fn devProviderMetaFor(name: []const u8) ?DevProviderMeta {
    for (devProviderMeta) |m| {
        if (std.mem.eql(u8, m.provider, name)) return m;
    }
    return null;
}

/// canonical (dash-spelling) harness rule name for a strict slug.
fn canonicalHarnessName(slug: []const u8) ?[]const u8 {
    for (rulesForHarnesses) |r| {
        if (ruleIdMatches(r.name, slug)) return r.name;
    }
    return null;
}

/// canonical (dash-spelling) provider rule name for a strict slug.
fn canonicalProviderName(slug: []const u8) ?[]const u8 {
    for (rulesForProviders) |r| {
        if (ruleIdMatches(r.name, slug)) return r.name;
    }
    return null;
}

/// canonical (dash-spelling) model rule name for a strict slug.
fn canonicalModelName(slug: []const u8) ?[]const u8 {
    for (rulesForModels) |r| {
        if (ruleIdMatches(r.name, slug)) return r.name;
    }
    return null;
}

/// resolve a combo's `agent_id` (strict slugs) into the three canonical
/// (dash-spelling) names. Caller owns the three returned slices.
fn comboDims(a: std.mem.Allocator, combo: *const RecipesForFixtures) ![3][]u8 {
    const parts = try splitAgentId(a, combo.agent_id);
    defer {
        a.free(parts[0]);
        a.free(parts[1]);
        a.free(parts[2]);
    }
    const h = canonicalHarnessName(parts[0]) orelse return error.InvalidAgentId;
    const p = canonicalProviderName(parts[1]) orelse return error.InvalidAgentId;
    const m = canonicalModelName(parts[2]) orelse return error.InvalidAgentId;
    return .{
        try a.dupe(u8, h),
        try a.dupe(u8, p),
        try a.dupe(u8, m),
    };
}

    pub fn buildClineEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const p = dims[1];
    const m = dims[2];
    const env = [_][2][]const u8{
        .{ "CLINE_BUILD_ENV", "dev" },
        .{ "CLINE_NO_INTERACTIVE", "true" },
        .{ "CLINE_WRAPPER_PATH", "/opt/cline/wrapper" },
        .{ "CLINE_RUN_AS_HUB_DAEMON", "true" },
        .{ "CLINE_CONNECTOR_CLI_LAUNCH", "true" },
        .{ "", "" },
    };
    const providers_path = try std.fs.path.join(a, &.{ home, ".cline/data/settings/providers.json" });
    const json = try std.fmt.allocPrint(a,
        \\{{
        \\  "lastUsedProvider": "{s}",
        \\  "providers": {{
        \\    "{s}": {{
        \\      "updatedAt": "2025-08-01T00:00:00Z",
        \\      "settings": {{ "model": "{s}/{s}" }}
        \\    }}
        \\  }}
        \\}}
        \\
    , .{ p, p, p, m });
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

    pub fn buildKimiEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const dir = try std.fs.path.join(a, &.{ home, ".kimi-code" });
    const env = [_][2][]const u8{
        .{ "KIMI_CODE_HOME", dir },
        .{ "KIMI_BASE_URL", "https://api.example.invalid" },
        .{ "", "" },
    };
    const cfg = try std.fmt.allocPrint(a, "default_model = \"{s}/{s}\"\n", .{ dims[1], dims[2] });
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = try std.fs.path.join(a, &.{ dir, "config.toml" }), .content = cfg },
    };
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    return .{ .env = try a.dupe([2][]const u8, &env), .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildMmxEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const dir = try std.fs.path.join(a, &.{ home, ".mmx" });
    const env = [_][2][]const u8{
        .{ "MMX_CONFIG_DIR", dir },
        .{ "", "" },
    };
    // mmx stores a bare model id natively; the from-raw fabricator writes
    // the "<provider>/<model>" form so `detectMmx` can also resolve a
    // non-default provider (detectMmx falls back to the bare-model
    // intrinsic minimax otherwise).
    const cfg = try std.fmt.allocPrint(a, "{{\"defaultTextModel\":\"{s}/{s}\"}}\n", .{ dims[1], dims[2] });
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = try std.fs.path.join(a, &.{ dir, "config.json" }), .content = cfg },
    };
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    return .{ .env = try a.dupe([2][]const u8, &env), .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildGooseEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, io: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const env = [_][2][]const u8{
        .{ "GOOSE_TERMINAL", "true" },
        .{ "GOOSE_MODE", "auto" },
        .{ "GOOSE_WORKING_DIR", home },
        .{ "", "" },
    };
    const yaml = try std.fmt.allocPrint(a,
        \\active_provider: {s}
        \\providers:
        \\  {s}:
        \\    model: {s}
        \\
    , .{ dims[1], dims[1], dims[2] });
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

    pub fn buildPiEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const env = try a.alloc([2][]const u8, 4);
    env[0] = .{ "PI_CODING_AGENT", "true" };
    env[1] = .{ "PI_PROVIDER", dims[1] };
    env[2] = .{ "PI_MODEL", dims[2] };
    env[3] = .{ "", "" };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &.{}), .cwd = home };
}

    pub fn buildQwenEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const p = dims[1];
    const m = dims[2];
    const meta = devProviderMetaFor(p) orelse devProviderMetaFor("minimax").?;
    const qwen_dir = try std.fs.path.join(a, &.{ home, ".qwen" });
    defer a.free(qwen_dir);
    const settings_path = try std.fs.path.join(a, &.{ qwen_dir, "settings.json" });
    defer a.free(settings_path);
    const settings_body = try std.fmt.allocPrint(a,
        \\{{
        \\  "security": {{ "auth": {{ "selectedType": "openai" }} }},
        \\  "model": {{ "name": "{s}" }},
        \\  "modelProviders": {{
        \\    "openai": [{{
        \\      "id": "{s}",
        \\      "name": "[{s}] {s}",
        \\      "baseUrl": "{s}",
        \\      "envKey": "{s}"
        \\    }}]
        \\  }}
        \\}}
        \\
    , .{ m, m, p, m, meta.base_url, meta.key_env });
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "QWEN_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = settings_path, .content = settings_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildOmpEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const omp_dir = try std.fs.path.join(a, &.{ home, ".omp/agent" });
    defer a.free(omp_dir);
    const config_path = try std.fs.path.join(a, &.{ omp_dir, "config.yml" });
    defer a.free(config_path);
    const config_body = try std.fmt.allocPrint(a,
        \\modelRoles:
        \\  default: {s}/{s}
        \\
    , .{ dims[1], dims[2] });
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "OMP_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = config_path, .content = config_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildReasonixEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const p = dims[1];
    const m = dims[2];
    const meta = devProviderMetaFor(p) orelse devProviderMetaFor("deepseek").?;
    const config_path = try std.fs.path.join(a, &.{ home, ".reasonix/config.toml" });
    defer a.free(config_path);
    const config_body = try std.fmt.allocPrint(a,
        \\default_model = "{s}"
        \\
        \\[[providers]]
        \\name = "{s}"
        \\kind = "openai"
        \\base_url = "{s}"
        \\models = ["{s}"]
        \\default = "{s}"
        \\api_key_env = "{s}"
        \\
    , .{ p, p, meta.base_url, m, m, meta.key_env });
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "REASONIX_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = config_path, .content = config_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildJcodeEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const sessions_dir = try std.fs.path.join(a, &.{ home, ".jcode/sessions" });
    defer a.free(sessions_dir);
    const session_path = try std.fs.path.join(a, &.{ sessions_dir, "session_zoo_9999999999999_refresh_fixtures.json" });
    defer a.free(session_path);
    const session_body = try std.fmt.allocPrint(a,
        \\{{
        \\  "id": "session_zoo_9999999999999_refresh_fixtures",
        \\  "model": "{s}",
        \\  "provider_key": "{s}",
        \\  "route_api_method": "openai-compatible",
        \\  "status": "Closed",
        \\  "saved": false
        \\}}
        \\
    , .{ dims[2], dims[1] });
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "JCODE_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = session_path, .content = session_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildCrushEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const hyper_path = try std.fs.path.join(a, &.{ home, ".local/share/crush/hyper.json" });
    defer a.free(hyper_path);
    const hyper_body = try std.fmt.allocPrint(a,
        \\{{
        \\  "name": "Charm Hyper",
        \\  "id": "hyper",
        \\  "type": "openai-compat",
        \\  "api_endpoint": "https://hyper.charm.land/api/v1/fantasy",
        \\  "default_large_model_id": "{s}/{s}",
        \\  "default_small_model_id": "{s}/{s}"
        \\}}
        \\
    , .{ dims[1], dims[2], dims[1], dims[2] });
    const env = try a.alloc([2][]const u8, 2);
    env[0] = .{ "CRUSH_API_KEY", "fake" };
    env[1] = .{ "", "" };
    const writes = [_]EnvSetup.WriteSpec{
        .{ .path = hyper_path, .content = hyper_body },
    };
    return .{ .env = env, .writes = try a.dupe(EnvSetup.WriteSpec, &writes), .cwd = home };
}

    pub fn buildKiloEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const model_full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dims[1], dims[2] });
    const env = try a.alloc([2][]const u8, 3);
    env[0] = .{ "KILO_API_KEY", "fake" };
    env[1] = .{ "KILO_MODEL", model_full };
    env[2] = .{ "", "" };
    return .{ .env = env, .writes = &.{}, .cwd = home };
}

    pub fn buildOpencodeEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const model_full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dims[1], dims[2] });
    const env = try a.alloc([2][]const u8, 3);
    env[0] = .{ "OPENCODE_API_KEY", "fake" };
    env[1] = .{ "OPENCODE_MODEL", model_full };
    env[2] = .{ "", "" };
    return .{ .env = env, .writes = &.{}, .cwd = home };
}

    pub fn buildVibeEnv(a: std.mem.Allocator, env_map: *const std.process.Environ.Map, _: std.Io, combo: *const RecipesForFixtures) anyerror!EnvSetup {
    const home = resolveHome(env_map);
    const dims = try comboDims(a, combo);
    defer {
        a.free(dims[0]);
        a.free(dims[1]);
        a.free(dims[2]);
    }
    const env = try a.alloc([2][]const u8, 4);
    env[0] = .{ "VIBE_API_KEY", "fake" };
    env[1] = .{ "VIBE_ACTIVE_MODEL", dims[2] };
    env[2] = .{ "VIBE_ACTIVE_PROVIDER", dims[1] };
    env[3] = .{ "", "" };
    return .{ .env = env, .writes = &.{}, .cwd = home };
}

/// the capture prompt the from-capture worker hands a headless harness:
/// the model session runs `agent-detect-dev fixtures capture` in the
/// current working directory and reports the result.
const capture_prompt = "run `agent-detect-dev fixtures capture` in the current working directory and report the result";

pub const recipesForFixtures = [_]RecipesForFixtures{
    // cline — clinepass/kimi-k3 (keep, no launch spec — not in the usable set), deepseek/v4-flash, minimax/m3, openrouter/v4-flash (no launch spec — not in the usable set)
    .{ .agent_id = "cline-clinepass-kimik3", .probeNames = &.{ "cline", "cline.exe" }, .buildEnv = buildClineEnv },
    .{ .agent_id = "cline-deepseek-deepseekv4flash", .probeNames = &.{ "cline", "cline.exe" }, .buildEnv = buildClineEnv, .launch = &.{ "cline", "--auto-approve", "--provider=deepseek", "--model=deepseek-v4-flash", "--thinking", "high", capture_prompt } },
    .{ .agent_id = "cline-minimax-minimaxm3", .probeNames = &.{ "cline", "cline.exe" }, .buildEnv = buildClineEnv, .launch = &.{ "cline", "--auto-approve", "--provider=minimax", "--model=minimax/minimax-m3", capture_prompt } },
    .{ .agent_id = "cline-openrouter-deepseekv4flash", .probeNames = &.{ "cline", "cline.exe" }, .buildEnv = buildClineEnv },
    // cline additions (real usable combos): clinepass/step-3.7-flash and clinepass/free-deepseek-v4-flash
    .{ .agent_id = "cline-clinepass-step37flash", .probeNames = &.{ "cline", "cline.exe" }, .buildEnv = buildClineEnv, .launch = &.{ "cline", "--auto-approve", "--provider=cline-pass", "--model=stepfun/step-3.7-flash", capture_prompt } },
    .{ .agent_id = "cline-clinepass-deepseekv4flash", .probeNames = &.{ "cline", "cline.exe" }, .buildEnv = buildClineEnv, .launch = &.{ "cline", "--auto-approve", "--provider=cline-pass", "--model=free/deepseek-v4-flash", capture_prompt } },
    // goose — goose/claude-sonnet-4 (contributor-scope example, keeps the harness→recipe test green)
    .{ .agent_id = "goose-goose-claudesonnet4", .probeNames = &.{ "goose", "goose.exe", "goosed", "goosed.exe" }, .buildEnv = buildGooseEnv },
    // kimi — minimax/m3 (keep), deepseek/v4-flash, kimi/k3
    .{ .agent_id = "kimicode-minimax-minimaxm3", .probeNames = &.{ "kimi", "kimi-code", "kimi.exe", "kimi-code.exe" }, .buildEnv = buildKimiEnv, .launch = &.{ "kimi", "-p", capture_prompt } },
    .{ .agent_id = "kimicode-deepseek-deepseekv4flash", .probeNames = &.{ "kimi", "kimi-code", "kimi.exe", "kimi-code.exe" }, .buildEnv = buildKimiEnv, .launch = &.{ "kimi", "-p", capture_prompt } },
    .{ .agent_id = "kimicode-kimi-kimik3", .probeNames = &.{ "kimi", "kimi-code", "kimi.exe", "kimi-code.exe" }, .buildEnv = buildKimiEnv, .launch = &.{ "kimi", "-p", capture_prompt } },
    // mmx — minimax/m3 (keep), minimax/m2.7
    .{ .agent_id = "mmx-minimax-minimaxm3", .probeNames = &.{ "mmx", "mmx.exe" }, .buildEnv = buildMmxEnv },
    .{ .agent_id = "mmx-minimax-minimaxm27", .probeNames = &.{ "mmx", "mmx.exe" }, .buildEnv = buildMmxEnv },
    // pi — anthropic/claude-sonnet-4 (keep), deepseek/v4-flash, minimax/m3
    .{ .agent_id = "pi-anthropic-claudesonnet4", .probeNames = &.{ "pi", "pi.exe" }, .buildEnv = buildPiEnv },
    .{ .agent_id = "pi-deepseek-deepseekv4flash", .probeNames = &.{ "pi", "pi.exe" }, .buildEnv = buildPiEnv },
    .{ .agent_id = "pi-minimax-minimaxm3", .probeNames = &.{ "pi", "pi.exe" }, .buildEnv = buildPiEnv },
    // qwen — minimax/m3 (keep), deepseek/v4-flash, qwen/qwen3.8-max
    .{ .agent_id = "qwen-minimax-minimaxm3", .probeNames = &.{ "qwen", "qwen.exe" }, .buildEnv = buildQwenEnv, .launch = &.{ "qwen", "-p", capture_prompt } },
    .{ .agent_id = "qwen-deepseek-deepseekv4flash", .probeNames = &.{ "qwen", "qwen.exe" }, .buildEnv = buildQwenEnv, .launch = &.{ "qwen", "-p", capture_prompt } },
    .{ .agent_id = "qwen-qwen-qwen38max", .probeNames = &.{ "qwen", "qwen.exe" }, .buildEnv = buildQwenEnv, .launch = &.{ "qwen", "-p", capture_prompt } },
    // kilo — anthropic/claude-sonnet-4 (keep), deepseek/v4-flash (keep), minimax/m3, openrouter/v4-flash, zai/glm-5.2
    .{ .agent_id = "kilo-anthropic-claudesonnet4", .probeNames = &.{ "kilo", "kilo.exe" }, .buildEnv = buildKiloEnv, .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
    .{ .agent_id = "kilo-deepseek-deepseekv4flash", .probeNames = &.{ "kilo", "kilo.exe" }, .buildEnv = buildKiloEnv, .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
    .{ .agent_id = "kilo-minimax-minimaxm3", .probeNames = &.{ "kilo", "kilo.exe" }, .buildEnv = buildKiloEnv, .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
    .{ .agent_id = "kilo-openrouter-deepseekv4flash", .probeNames = &.{ "kilo", "kilo.exe" }, .buildEnv = buildKiloEnv, .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
    .{ .agent_id = "kilo-zai-glm52", .probeNames = &.{ "kilo", "kilo.exe" }, .buildEnv = buildKiloEnv, .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
    // jcode — minimax/m2.7 (keep), deepseek/v4-flash, minimax/m3, openrouter/v4-flash
    .{ .agent_id = "jcode-minimax-minimaxm27", .probeNames = &.{ "jcode", "jcode.exe" }, .buildEnv = buildJcodeEnv, .launch = &.{ "jcode", "run", capture_prompt } },
    .{ .agent_id = "jcode-deepseek-deepseekv4flash", .probeNames = &.{ "jcode", "jcode.exe" }, .buildEnv = buildJcodeEnv, .launch = &.{ "jcode", "run", capture_prompt } },
    .{ .agent_id = "jcode-minimax-minimaxm3", .probeNames = &.{ "jcode", "jcode.exe" }, .buildEnv = buildJcodeEnv, .launch = &.{ "jcode", "run", capture_prompt } },
    .{ .agent_id = "jcode-openrouter-deepseekv4flash", .probeNames = &.{ "jcode", "jcode.exe" }, .buildEnv = buildJcodeEnv, .launch = &.{ "jcode", "run", capture_prompt } },
    // omp — minimax-code/m3 (keep), deepseek/v4-flash, openrouter/v4-flash
    .{ .agent_id = "omp-minimaxcode-minimaxm3", .probeNames = &.{ "omp", "omp.exe" }, .buildEnv = buildOmpEnv },
    .{ .agent_id = "omp-deepseek-deepseekv4flash", .probeNames = &.{ "omp", "omp.exe" }, .buildEnv = buildOmpEnv },
    .{ .agent_id = "omp-openrouter-deepseekv4flash", .probeNames = &.{ "omp", "omp.exe" }, .buildEnv = buildOmpEnv },
    // reasonix — deepseek-flash/v4-flash (keep), deepseek/v4-flash, minimax/m3
    .{ .agent_id = "reasonix-deepseekflash-deepseekv4flash", .probeNames = &.{ "reasonix", "reasonix.exe" }, .buildEnv = buildReasonixEnv },
    .{ .agent_id = "reasonix-deepseek-deepseekv4flash", .probeNames = &.{ "reasonix", "reasonix.exe" }, .buildEnv = buildReasonixEnv },
    .{ .agent_id = "reasonix-minimax-minimaxm3", .probeNames = &.{ "reasonix", "reasonix.exe" }, .buildEnv = buildReasonixEnv },
    // crush — hyper/qwen3.7-plus (keep), hyper/v4-flash, minimax/m3, deepseek/v4-flash
    .{ .agent_id = "crush-hyper-qwen37plus", .probeNames = &.{ "crush", "crush.exe" }, .buildEnv = buildCrushEnv },
    .{ .agent_id = "crush-hyper-deepseekv4flash", .probeNames = &.{ "crush", "crush.exe" }, .buildEnv = buildCrushEnv },
    .{ .agent_id = "crush-minimax-minimaxm3", .probeNames = &.{ "crush", "crush.exe" }, .buildEnv = buildCrushEnv },
    .{ .agent_id = "crush-deepseek-deepseekv4flash", .probeNames = &.{ "crush", "crush.exe" }, .buildEnv = buildCrushEnv },
    // opencode — minimax/m3 (keep), deepseek/v4-flash, hyper/v4-flash, groq/llama-4, cerebras/qwen3
    .{ .agent_id = "opencode-minimax-minimaxm3", .probeNames = &.{ "opencode", "opencode.exe" }, .buildEnv = buildOpencodeEnv, .launch = &.{ "opencode", "run", capture_prompt } },
    .{ .agent_id = "opencode-deepseek-deepseekv4flash", .probeNames = &.{ "opencode", "opencode.exe" }, .buildEnv = buildOpencodeEnv, .launch = &.{ "opencode", "run", capture_prompt } },
    .{ .agent_id = "opencode-hyper-deepseekv4flash", .probeNames = &.{ "opencode", "opencode.exe" }, .buildEnv = buildOpencodeEnv, .launch = &.{ "opencode", "run", capture_prompt } },
    .{ .agent_id = "opencode-groq-llama4", .probeNames = &.{ "opencode", "opencode.exe" }, .buildEnv = buildOpencodeEnv, .launch = &.{ "opencode", "run", capture_prompt } },
    .{ .agent_id = "opencode-cerebras-qwen3", .probeNames = &.{ "opencode", "opencode.exe" }, .buildEnv = buildOpencodeEnv, .launch = &.{ "opencode", "run", capture_prompt } },
    // vibe — mistral/mistral-large-latest (keep), mistral/mistral-small-latest, minimax/m3
    .{ .agent_id = "vibe-mistral-mistrallargelatest", .probeNames = &.{ "vibe", "vibe.exe" }, .buildEnv = buildVibeEnv, .launch = &.{ "vibe", "--prompt", capture_prompt } },
    .{ .agent_id = "vibe-mistral-mistralsmalllatest", .probeNames = &.{ "vibe", "vibe.exe" }, .buildEnv = buildVibeEnv, .launch = &.{ "vibe", "--prompt", capture_prompt } },
    .{ .agent_id = "vibe-minimax-minimaxm3", .probeNames = &.{ "vibe", "vibe.exe" }, .buildEnv = buildVibeEnv, .launch = &.{ "vibe", "--prompt", capture_prompt } },
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
    // ----------------------------------------------------------------
    // fixtures fixture subcommands
    // ----------------------------------------------------------------

    /// strictly alphanumeric form of the current platform — just the
    /// OS name, no arch (e.g. `darwin`, `linux`, `windows`). Computed
    /// at compile time from `builtin.target` so it's free. macOS is
    /// remapped to `darwin` to match the conventional platform name
    /// (the `builtin.target.os.tag` is `.macos` but the conventional
    /// name is "darwin" — we want one canonical name for fixtures).
    /// Arch is dropped because the same fixture JSON is valid on all
    /// archs of a given OS; the platform id only differentiates OS.
    pub fn platformId() []const u8 {
        return switch (builtin.target.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => "darwin",
            else => @tagName(builtin.target.os.tag),
        };
    }

    /// assemble a fixture_id from the three sub-ids. Caller
    /// owns the returned slice.
    pub fn fixtureId(a: std.mem.Allocator, agent: []const u8) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        try list.appendSlice(a, agent);
        try list.append(a, '-');
        try list.appendSlice(a, platformId());
        return list.toOwnedSlice(a);
    }

    /// shared filter for `fixtures queue` / `fixtures dequeue`. Four dimension
    /// flags (`--harness=`, `--provider=`, `--model=`, `--platform=`)
    /// constrain their dim to equality; an unmentioned dim is
    /// unconstrained (any value, including null).
    /// `--fixture=` expands to all four dims (h-p-m-platform);
    /// `--agent=` expands to h-p-m, leaving platform unconstrained
    /// unless `--platform=` is also given. `any` is true iff at least
    /// one option was present.
    const FilterOptions = struct {
        harness: []const u8 = "",
        provider: []const u8 = "",
        model: []const u8 = "",
        platform: []const u8 = "",
        fixture: ?[]const u8 = null,
        agent: ?[]const u8 = null,
        /// scope flags: `--all`/`--stale`/`--partial` target index rows;
        /// `--recipes`/`--missing-fixture` target the recipe table.
        /// Exactly one scope flag may be set.
        all: bool = false,
        stale: bool = false,
        partial: bool = false,
        recipes: bool = false,
        missing_fixture: bool = false,
        /// `--available`: probe-and-record harness availability into the
        /// `available` column (1/0). Modifier only (never a scope flag).
        available: bool = false,
        /// `--unavailable` / `--available=0`: dequeue match for available=0
        /// handoff rows. Modifier only.
        unavailable: bool = false,
        /// stale thresholds. `--stale` is an alias for `stale_by_days=7`.
        stale_by_days: ?i64 = null,
        stale_by_minutes: ?i64 = null,
        any: bool = false,
        /// true when `--fixture=` or `--agent=` (the composite ids)
        /// contributed the equality dims — used for the creation path.
        composite: bool = false,
        /// refresh mode: `"from-ids" | "from-raw" | "from-capture"`,
        /// or `""` when no mode flag was given. `queue` stamps it on
        /// rows (default `from-raw`); `dequeue` filters by it.
        mode: []const u8 = "",
    };

    const FilterError = error{
        /// no filter option present at all
        NoFilter,
        /// `--fixture=` not a valid 4-part id
        InvalidFixtureId,
        /// `--agent=` not a valid 3-part id
        InvalidAgentId,
        /// `--stale-by-days=`/`--stale-by-minutes=` not an integer
        InvalidThreshold,
        /// contradictory or disallowed combination
        ConflictingFilters,
        /// allocation failure while expanding composite ids
        OutOfMemory,
    };

    /// parse the shared filter flags from argv (expects argv0, "fixtures",
    /// <subcommand> already consumed). Errors use `FilterError` so the
    /// caller can emit the command-specific message and usage.
    fn parseFilters(init: std.process.Init) FilterError!FilterOptions {
        const a = init.arena.allocator();
        var f: FilterOptions = .{};
        var seen_fixture = false;
        var seen_agent = false;
        var seen_harness = false;
        var seen_provider = false;
        var seen_model = false;
        var seen_platform = false;
        var is_dequeue = false;

        var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return FilterError.NoFilter;
        defer args_it.deinit();
        _ = args_it.skip(); // argv0
        _ = args_it.skip(); // "fixtures"
        if (args_it.next()) |sub| {
            is_dequeue = std.mem.eql(u8, sub, "dequeue");
        } else {
            return FilterError.NoFilter;
        }
        while (args_it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--fixture=")) {
                f.fixture = arg["--fixture=".len..];
                seen_fixture = true;
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
            } else if (std.mem.eql(u8, arg, "--unavailable") or std.mem.eql(u8, arg, "--available=0")) {
                f.unavailable = true;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-days=")) {
                f.stale_by_days = std.fmt.parseInt(i64, arg["--stale-by-days=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-minutes=")) {
                f.stale_by_minutes = std.fmt.parseInt(i64, arg["--stale-by-minutes=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.eql(u8, arg, "--from-ids") or std.mem.eql(u8, arg, "--from-raw") or std.mem.eql(u8, arg, "--from-capture")) {
                // exactly one mode flag (two+ → conflicting). The stored
                // value is the FULL "from-*" string (not the prefix
                // stripped off) so modeRank and the daemon's worker
                // branch can compare it verbatim.
                const m = arg[2..];
                if (f.mode.len > 0 and !std.mem.eql(u8, f.mode, m)) return FilterError.ConflictingFilters;
                f.mode = m;
            }
        }

        // default mode when none given: queue stamps `from-raw`; dequeue
        // leaves "" = "all modes" (filters, does not stamp).
        if (f.mode.len == 0 and !is_dequeue) f.mode = "from-raw";

        // `--stale` is an alias for `--stale-by-days=7`.
        if (f.stale and f.stale_by_days == null and f.stale_by_minutes == null) f.stale_by_days = 7;
        // a stale threshold implies the `--stale` scope.
        if (f.stale_by_days != null or f.stale_by_minutes != null) f.stale = true;
        // only one of days/minutes may be set
        if (f.stale_by_days != null and f.stale_by_minutes != null) return FilterError.ConflictingFilters;
        if ((f.stale_by_days != null and f.stale_by_days.? < 1) or
            (f.stale_by_minutes != null and f.stale_by_minutes.? < 1)) return FilterError.ConflictingFilters;

        // scope flags: exactly one allowed
        const scope_count = @as(usize, @intFromBool(f.all)) + @as(usize, @intFromBool(f.stale)) +
            @as(usize, @intFromBool(f.partial)) + @as(usize, @intFromBool(f.recipes)) +
            @as(usize, @intFromBool(f.missing_fixture));
        if (scope_count > 1) return FilterError.ConflictingFilters;

        // --available / --unavailable are modifiers: require a scope flag
        if ((f.available or f.unavailable) and scope_count == 0) return FilterError.ConflictingFilters;
        if (f.available and f.unavailable) return FilterError.ConflictingFilters;

        f.any = seen_fixture or seen_agent or seen_harness or seen_provider or
            seen_model or seen_platform or scope_count > 0 or f.available or f.unavailable;
        if (!f.any) return FilterError.NoFilter;

        if (seen_fixture) {
            // `--fixture=` supplies all four dims and may not combine
            // with `--agent=` or any `--X=`; `--platform=` is allowed
            // but must be identical to the fixtures id's platform part.
            if (seen_agent or seen_harness or seen_provider or seen_model) return FilterError.ConflictingFilters;
            const parts = splitFixtureId(a, f.fixture.?) catch return FilterError.InvalidFixtureId;
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
            // (identical to `--fixture=` when combined). No `--X=` other
            // than `--platform=` may combine with `--agent=`.
            if (seen_harness or seen_provider or seen_model) return FilterError.ConflictingFilters;
            const parts = splitAgentId(a, f.agent.?) catch return FilterError.InvalidAgentId;
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
        return f;
    }

    /// how many scope flags are set (exactly one is allowed).
    fn scopeCount(f: FilterOptions) usize {
        return @as(usize, @intFromBool(f.all)) + @as(usize, @intFromBool(f.stale)) +
            @as(usize, @intFromBool(f.partial)) + @as(usize, @intFromBool(f.recipes)) +
            @as(usize, @intFromBool(f.missing_fixture));
    }

    /// the scope candidate set for `f`, as queue rows:
    fn scopeCandidates(a: std.mem.Allocator, io: std.Io, f: FilterOptions) !std.ArrayListUnmanaged(QueueRow) {
        var out: std.ArrayListUnmanaged(QueueRow) = .empty;
        const host = platformId();
        const now = unixNow(io);

        if (f.recipes or f.missing_fixture) {
            for (recipesForFixtures) |c| {
                const parts = try splitAgentId(a, c.agent_id);
                defer {
                    a.free(parts[0]);
                    a.free(parts[1]);
                    a.free(parts[2]);
                }
                if (f.harness.len > 0 and !std.mem.eql(u8, f.harness, parts[0])) continue;
                if (f.provider.len > 0 and !std.mem.eql(u8, f.provider, parts[1])) continue;
                if (f.model.len > 0 and !std.mem.eql(u8, f.model, parts[2])) continue;
                if (f.platform.len > 0 and !std.mem.eql(u8, f.platform, host)) continue;
                if (f.missing_fixture) {
                    const fixture_id_v = try fixtureId(a, c.agent_id);
                    defer a.free(fixture_id_v);
                    const json_path = try std.fmt.allocPrint(a, "fixtures/{s}.json", .{fixture_id_v});
                    defer a.free(json_path);
                    var json_exists = false;
                    if (std.Io.Dir.cwd().statFile(io, json_path, .{})) |_| {
                        json_exists = true;
                    } else |_| {}
                    if (json_exists) continue;
                }
                var row: QueueRow = .{
                    .harness = try a.dupe(u8, parts[0]),
                    .provider = try a.dupe(u8, parts[1]),
                    .model = try a.dupe(u8, parts[2]),
                    .platform = try a.dupe(u8, host),
                    .runner = getParentPid(),
                    .created_at = now,
                    .mode = f.mode,
                };
                if (f.recipes) row.scope_recipes = 1;
                if (f.missing_fixture) row.scope_missing_fixture = 1;
                if (f.available) {
                    row.available = if (harnessAvailable(io, c.agent_id)) 1 else 0;
                }
                try validateQueueRow(row);
                try out.append(a, row);
            }
            return out;
        }

        if (f.partial) {
            const seeds = try selectSeedQueueRows(a, io);
            for (seeds) |s| {
                if (f.harness.len > 0 and !std.mem.eql(u8, s.harness orelse "", f.harness)) continue;
                if (f.provider.len > 0 and !std.mem.eql(u8, s.provider orelse "", f.provider)) continue;
                if (f.model.len > 0 and !std.mem.eql(u8, s.model orelse "", f.model)) continue;
                if (f.platform.len > 0 and !std.mem.eql(u8, s.platform orelse "", f.platform)) continue;
                var row = s;
                row.scope_partial = 1;
                row.runner = getParentPid();
                row.created_at = now;
                try validateQueueRow(row);
                try out.append(a, row);
            }
            return out;
        }

        // --all / --stale: enumerate fixtures
        const fixtures = try selectFixtures(a, io);
        for (fixtures) |fx| {
            if (f.harness.len > 0 and !std.mem.eql(u8, f.harness, fx.harness)) continue;
            if (f.provider.len > 0 and !std.mem.eql(u8, f.provider, fx.provider)) continue;
            if (f.model.len > 0 and !std.mem.eql(u8, f.model, fx.model)) continue;
            if (f.platform.len > 0 and !std.mem.eql(u8, f.platform, fx.platform)) continue;
            // --stale: only queue fixtures actually older than the threshold
            // (snapshot at queue time; the daemon re-validates with the stored
            // threshold later).
            if (f.stale) {
                const threshold_minutes = f.stale_by_minutes orelse (f.stale_by_days.? * 24 * 60);
                if (!isStale(io, fx.generated_at, threshold_minutes)) continue;
            }
            var row: QueueRow = .{
                .harness = try a.dupe(u8, fx.harness),
                .provider = try a.dupe(u8, fx.provider),
                .model = try a.dupe(u8, fx.model),
                .platform = try a.dupe(u8, fx.platform),
                .runner = getParentPid(),
                .created_at = now,
                .mode = f.mode,
            };
            if (f.all) row.scope_all = 1;
            if (f.stale) {
                row.stale_by_days = f.stale_by_days;
                row.stale_by_minutes = f.stale_by_minutes;
            }
            if (f.available) {
                const agent = (try agentIdFrom(a, fx.harness, fx.provider, fx.model)) orelse continue;
                row.available = if (harnessAvailable(io, agent)) 1 else 0;
            }
            try validateQueueRow(row);
            try out.append(a, row);
        }
        return out;
    }

    // ----------------------------------------------------------------
    // refresh subcommands
    // ----------------------------------------------------------------

    /// `refresh run` — capture the current session and write the
    /// fixture + upsert the matching fixtures row. Failure semantics:
    /// if the detection ladder fails to resolve harness *or* provider
    /// *or* model, exit 2 with no fixture written and no store change.
    /// Partial detections are bad data and must be fixed, not papered
    /// over. The agent runs this directly; the daemon also runs it as
    /// a child after preparing the env for a target harness.
    ///
    /// **Filename contract** — the fixture is written as a single
    /// `fixtures/<fixture_id>.json` with top-level keys `cooked`, `raw`,
    /// and `trailer`, where `fixture_id = agent_id + "-" + platform_id`
    /// (e.g. `cline-clinepass-kimik3-darwin`). The `-<platform>` suffix
    /// keeps per-platform config paths from churning each other
    /// across CI runs; see DESIGN.md "per-platform fixtures" for the
    /// rationale.
    // Note on partial detection (the seed path): a daemon-spawned
    // child that partially fails on a full combo writes a partial seed
    // with a *different* tuple than the combo row; the combo row stays
    // `refresh:true` (retry) and the seed re-enters expansion on the
    // daemon's next poll — a bounded retry loop surfaced by the daemon
    // warning. No extra bookkeeping is needed.
    pub fn runFixturesCapture(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        var d = Detection{};
        _ = try detect(init, &d);

        const harness_aid = d.harness_id;
        const provider_aid = d.provider_id;
        const model_aid = d.model_id;

        const resolved = (if (harness_aid != null) @as(usize, 1) else 0) +
            (if (provider_aid != null) @as(usize, 1) else 0) +
            (if (model_aid != null) @as(usize, 1) else 0);

        // partial detection (1 or 2 dims): partial is bad data per DESIGN —
        // report + exit 8, NO store change. Seeds are only created via
        // `fixtures queue`. Nothing is written if zero dims resolve.
        if (resolved >= 1 and resolved < 3) {
            writeErr(io, "fixtures capture: partial detection (");
            var n_buf: [16]u8 = undefined;
            writeErr(io, try std.fmt.bufPrint(&n_buf, "{d}", .{resolved}));
            writeErr(io, "/3 dims) — no fixture written, no store change\n");
            return EXIT_UNABLE_TO_DETECT;
        }
        if (resolved == 0) {
            writeErr(io, "fixtures capture: harness/provider/model did not resolve — nothing recorded\n");
            return EXIT_UNABLE_TO_DETECT;
        }

        const agent_aid = d.agent_id orelse {
            writeErr(io, "fixtures capture: agent_id did not compute\n");
            return EXIT_UNABLE_TO_DETECT;
        };

        const fixture_id = try fixtureId(a, agent_aid);

        // assemble the single `{cooked, raw, trailer}` fixture file.
        const cooked = try buildCooked(a, &d);
        const raw = try buildRaw(a, &d, init.environ_map);
        var root = std.json.Value{ .object = .empty };
        try root.object.put(a, "cooked", cooked);
        try root.object.put(a, "raw", raw);
        if (d.trailer) |t| {
            try root.object.put(a, "trailer", .{ .string = t });
        }
        // decision #7 — every fixture carries a top-level `origin`
        // classifying it as observed (`from-raw` when the daemon
        // fabricated the runtime, `from-capture` for a real session)
        // or declared (`from-ids`, written by the from-ids worker, which
        // never reaches this capture path). The daemon sets
        // AGENT_DETECT_FIXTURE_ORIGIN on the `refresh run` child; a hand-run
        // capture is a real session → `from-capture`.
        try root.object.put(a, "origin", .{ .string = init.environ_map.get("AGENT_DETECT_FIXTURE_ORIGIN") orelse "from-capture" });
        const json_bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
        defer a.free(json_bytes);

        // write fixture
        std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                writeErr(io, MSG_IO);
                return EXIT_IO;
            },
        };
        const dir = std.Io.Dir.cwd().openDir(io, "fixtures", .{}) catch {
            writeErr(io, "fixtures capture: cannot open fixtures/ dir\n");
            return EXIT_IO;
        };
        defer dir.close(io);

        const json_name = try std.fmt.allocPrint(a, "{s}.json", .{fixture_id});
        dir.writeFile(io, .{ .sub_path = json_name, .data = json_bytes }) catch {
            writeErr(io, MSG_IO);
            return EXIT_IO;
        };

        // fixtures only: upsert the state row (never touches `queue`).
        try upsertFixture(a, io, .{
            .harness = harness_aid orelse unreachable,
            .provider = provider_aid orelse unreachable,
            .model = model_aid orelse unreachable,
            .platform = platformId(),
            .runner = getParentPid(),
            .generated_at = unixNow(io),
        });

        writeOut(io, "fixtures capture: wrote fixtures/");
        writeOut(io, json_name);
        writeOut(io, "\n");
        return 0;
    }

    /// `fixtures queue [scope] <filters>` — set `refresh:true` on a set of
    /// rows. Without a scope flag, the generic path is create-or-flip:
    /// with the shared dim filters (`--fixture=`, `--agent=`, `--harness=`,
    /// `--provider=`, `--model=`, `--platform=`), if any
    /// existing row matches, flip them all to `refresh:true` (dims and
    /// runner preserved, `generated_at` refreshes). If none match,
    /// create a **seed** row: the positive dims set, the remaining dims
    /// `null`, `refresh:true`. Unknown ids are allowed — that is the
    /// seed path (the daemon expands seeds over fixtures recipes; see
    /// `runFixturesDaemon`).
    ///
    /// With a scope flag (`--all`/`--stale`/`--partial`/`--recipes`/
    /// `--missing-fixture`) the target set is computed instead (see
    /// `scopeCandidates`) and every candidate is queued (recipe-scope
    /// candidates are created as full `refresh:true` rows). `--available`
    /// narrows candidates to harnesses whose binary is available.
    ///
    /// At least one filter option or scope flag is required (else exit
    /// 2). A dimless call is not a valid seed — at least one positive
    /// dim, `--agent=`, or `--fixture=` is required for creation.
    ///
    /// Idempotent: re-running a seed request re-matches the existing
    /// seed and takes the flip path, so no duplicate row is written.
    pub fn runFixturesQueue(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        const f = parseFilters(init) catch |err| {
            switch (err) {
                error.NoFilter => writeErr(io, MSG_MISSING_ARG),
                error.InvalidFixtureId => writeErr(io, "fixtures queue: --fixture=<id> must be a 4-part <harness>-<provider>-<model>-<platform> id\n"),
                error.InvalidAgentId => writeErr(io, "fixtures queue: --agent=<id> must be a 3-part <harness>-<provider>-<model> id\n"),
                error.InvalidThreshold => writeErr(io, "fixtures queue: --stale-by-days=/--stale-by-minutes= must be integers >= 1\n"),
                error.ConflictingFilters => writeErr(io, MSG_CONFLICTING_ARG),
                error.OutOfMemory => writeErr(io, MSG_OUT_OF_MEMORY),
            }
            writeOut(io, fixturesUsage);
            return if (err == error.NoFilter) EXIT_MISSING_ARG else if (err == error.ConflictingFilters) EXIT_CONFLICTING_ARG else if (err == error.OutOfMemory) EXIT_OUT_OF_MEMORY else EXIT_UNRECOGNISED_ARG;
        };

        if (scopeCount(f) > 0) {
            return runFixturesQueueScope(init, f);
        }

        // bare dims / --agent= / --fixture=: create a seed row (no scope).
        const positive = f.harness.len > 0 or f.provider.len > 0 or
            f.model.len > 0 or f.platform.len > 0 or f.composite;
        if (!positive) {
            writeErr(io, MSG_MISSING_ARG);
            writeOut(io, fixturesUsage);
            return EXIT_MISSING_ARG;
        }

        const row: QueueRow = .{
            .harness = if (f.harness.len > 0) f.harness else null,
            .provider = if (f.provider.len > 0) f.provider else null,
            .model = if (f.model.len > 0) f.model else null,
            .platform = if (f.platform.len > 0) f.platform else null,
            .runner = getParentPid(),
            .created_at = unixNow(io),
            .mode = f.mode,
        };
        try validateQueueRow(row);
        try upsertQueueRow(a, io, row);

        writeOut(io, "fixtures queue: queued ");
        writeOut(io, try describeQueueRow(a, row));
        writeOut(io, "\n");
        return 0;
    }

    /// `fixtures queue <scope> [filters]` — enumerate the scope candidate set
    /// (see `scopeCandidates`) and upsert each into `queue`.
    fn runFixturesQueueScope(init: std.process.Init, f: FilterOptions) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        var candidates = try scopeCandidates(a, io, f);
        defer candidates.deinit(a);

        var queued: usize = 0;
        for (candidates.items) |row| {
            try upsertQueueRow(a, io, row);
            queued += 1;
        }

        var n_buf: [16]u8 = undefined;
        writeOut(io, "fixtures queue: queued ");
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

    /// true if the agent's harness binary (per `RecipesForFixtures`)
    /// is installed and runs --version successfully. Looks up the row
    /// by its composite `agent_id` so callers can pass either a
    /// recipe's id or a daemon-split id interchangeably.
    fn harnessAvailable(io: std.Io, agent_id: []const u8) bool {
        var probe_names: []const []const u8 = &.{};
        for (recipesForFixtures) |c| {
            if (std.mem.eql(u8, c.agent_id, agent_id)) {
                probe_names = c.probeNames;
                break;
            }
        }
        if (probe_names.len == 0) return false;
        return probeBinary(io, probe_names);
    }

    /// `fixtures dequeue [scope] <filters>` — **DELETE only; shared validator.**
    /// Builds the WHERE from dims + scope columns (three-valued predicate)
    /// + optional available match and deletes matching `queue` rows. No
    /// staleness/file checks; no fixture mutation. At least one filter or
    /// scope flag is required.
    pub fn runFixturesDequeue(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        const f = parseFilters(init) catch |err| {
            switch (err) {
                error.NoFilter => writeErr(io, MSG_MISSING_ARG),
                error.InvalidFixtureId => writeErr(io, "fixtures dequeue: --fixture=<id> must be a 4-part <harness>-<provider>-<model>-<platform> id\n"),
                error.InvalidAgentId => writeErr(io, "fixtures dequeue: --agent=<id> must be a 3-part <harness>-<provider>-<model> id\n"),
                error.InvalidThreshold => writeErr(io, "fixtures dequeue: --stale-by-days=/--stale-by-minutes= must be integers >= 1\n"),
                error.ConflictingFilters => writeErr(io, MSG_CONFLICTING_ARG),
                error.OutOfMemory => writeErr(io, MSG_OUT_OF_MEMORY),
            }
            writeOut(io, fixturesUsage);
            return if (err == error.NoFilter) EXIT_MISSING_ARG else if (err == error.ConflictingFilters) EXIT_CONFLICTING_ARG else if (err == error.OutOfMemory) EXIT_OUT_OF_MEMORY else EXIT_UNRECOGNISED_ARG;
        };

        const deleted = try deleteQueueRows(a, io, f);

        var n_buf: [16]u8 = undefined;
        writeOut(io, "fixtures dequeue: deleted ");
        writeOut(io, try std.fmt.bufPrint(&n_buf, "{d}", .{deleted}));
        writeOut(io, " action(s)\n");
        return 0;
    }

    /// sweep fixtures for malformed files: delete `fixtures/*.json`
    /// files that don't parse as a JSON object with a `cooked` block
    /// carrying the harness/provider/model names. Single-file format —
    /// no trailer sibling. Returns the count removed.
    fn purgeMalformedFixtures(a: std.mem.Allocator, io: std.Io) usize {
        var fixture_purged: usize = 0;
        var json_path_buf: [4096]u8 = undefined;
        const cwd = std.Io.Dir.cwd();
        var dir_it = cwd.iterate();
        while (dir_it.next(io) catch null) |ent| {
            if (ent.kind != .file) continue;
            const name = ent.name;
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            // skip the sqlite store — it lives beside the fixtures and
            // is not JSON content.
            if (std.mem.endsWith(u8, name, "index.sqlite3")) continue;
            const full_path = std.fmt.bufPrint(&json_path_buf, "fixtures/{s}", .{name}) catch continue;
            const data = std.Io.Dir.cwd().readFileAlloc(io, full_path, a, @enumFromInt(1 << 20)) catch continue;
            defer a.free(data);
            const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch continue;
            defer parsed.deinit();
            var bad = false;
            if (parsed.value != .object) {
                bad = true;
            } else if (parsed.value.object.get("cooked")) |cooked| {
                if (cooked != .object) {
                    bad = true;
                } else {
                    const cob = cooked.object;
                    bad = (cob.get("harness_name") == null) or
                        (cob.get("provider_name") == null) or
                        (cob.get("model_name") == null);
                }
            } else {
                bad = true;
            }
            if (bad) {
                std.Io.Dir.cwd().deleteFile(io, full_path) catch {};
                fixture_purged += 1;
            }
        }
        return fixture_purged;
    }

    /// `fixtures daemon` — long-running. **Owns all evaluation.** Every poll
    /// it atomically pops one pending action, runs the SHARED validator on
    /// it (warn + drop if invalid), then decides by the row's scope columns
    /// + dims + current `fixtures`/filesystem: expand seeds (any NULL dim),
    /// skip-and-complete full rows already freshly captured (unless
    /// `scope_all=1`), re-validate staleness with the row's threshold,
    /// re-probe `available` (never trust the stored value), then spawn
    /// `refresh run`. Success → upsert `fixtures` (action already popped);
    /// failure → re-queue. Idle → `purgeMalformedFixtures` + sleep.
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
    pub fn runFixturesDaemon(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        // parse daemon flags: --write-log, --poll-seconds=N,
        // --capture-review-seconds=N, --capture-timeout-seconds=N.
        var write_log = false;
        var poll_seconds: u64 = 5;
        var review_seconds: u64 = 15;
        var capture_timeout_seconds: u64 = 600;
        {
            var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return EXIT_OUT_OF_MEMORY;
            defer args_it.deinit();
            _ = args_it.skip(); // argv0
            _ = args_it.skip(); // "fixtures"
            _ = args_it.skip(); // "daemon"
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--write-log")) {
                    write_log = true;
                } else if (std.mem.startsWith(u8, arg, "--poll-seconds=")) {
                    poll_seconds = std.fmt.parseInt(u64, arg["--poll-seconds=".len..], 10) catch return EXIT_CONFLICTING_ARG;
                } else if (std.mem.startsWith(u8, arg, "--capture-review-seconds=")) {
                    review_seconds = std.fmt.parseInt(u64, arg["--capture-review-seconds=".len..], 10) catch return EXIT_CONFLICTING_ARG;
                } else if (std.mem.startsWith(u8, arg, "--capture-timeout-seconds=")) {
                    capture_timeout_seconds = std.fmt.parseInt(u64, arg["--capture-timeout-seconds=".len..], 10) catch return EXIT_CONFLICTING_ARG;
                }
            }
        }
        var daemon_log_file_owned: ?std.Io.File = null;
        if (write_log) {
            std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    writeErr(io, MSG_IO);
                    return EXIT_IO;
                },
            };
            const log_file = std.Io.Dir.cwd().createFile(io, "fixtures/daemon.log", .{}) catch |err| {
                daemonWriteErr(io, "daemon: cannot open fixtures/daemon.log: ");
                daemonWriteErr(io, @errorName(err));
                daemonWriteErr(io, "\n");
                return EXIT_IO;
            };
            daemon_log_file = log_file;
            daemon_log_file_owned = log_file;
        }
        defer {
            if (daemon_log_file_owned) |log_file| log_file.close(io);
            daemon_log_file = null;
        }

        try assertNotInAgent(a, init);

        daemonWrite(io, "agent-detect-dev fixtures daemon: running\n");
        {
            var buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(buf[0..], "  poll rate: {d}s (from-capture review: {d}s, timeout: {d}s)\n", .{ poll_seconds, review_seconds, capture_timeout_seconds }) catch "  poll rate: 5s\n";
            daemonWrite(io, m);
        }
        daemonWrite(io, "  index file: fixtures/index.sqlite3\n");
        daemonWrite(io, "  control file: fixtures/daemon.ctl (write pause/resume/stop)\n");
        if (write_log) daemonWrite(io, "  log file: fixtures/daemon.log\n");
        daemonWrite(io, "  press Ctrl+C to stop\n");

        // decision #12 — one cross-platform control mechanism: the
        // daemon checks `fixtures/daemon.ctl` every ~1s heartbeat and
        // acts on pause/resume/stop, clearing the file after acting.
        // The heartbeat also writes the current state to the log every
        // ~1s so a watcher polling at 1s always sees live state,
        // decoupled from the 5s/30s iteration delays. Signals are not
        // relied on beyond terminal Ctrl+C (SIGINT = graceful stop).
        var paused = false;
        var stop_requested = false;
        var phase: enum { idle, pre_capture, post_review } = .idle;
        var pending: ?QueueRow = null;
        var phase_until: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot };
        var next_poll: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot }; // 0 = poll on the first tick
        var capture_attempts = std.StringHashMap(u8).init(a);
        defer capture_attempts.deinit();

        while (true) {
            const now = std.Io.Clock.Timestamp.now(io, .boot);
            const boot_now_ns = now.raw.nanoseconds;

            // --- control check (every tick) ---
            const ctl = readControlAction(a, io);
            if (ctl) |c| {
                if (std.mem.eql(u8, c, "pause") and !paused) {
                    paused = true;
                    daemonWrite(io, "daemon: pause requested — pausing\n");
                } else if (std.mem.eql(u8, c, "resume") and paused) {
                    paused = false;
                    daemonWrite(io, "daemon: resume requested — resuming\n");
                } else if (std.mem.eql(u8, c, "stop")) {
                    stop_requested = true;
                    daemonWrite(io, "daemon: stop requested — finishing in-flight work then exiting\n");
                }
            }

            if (stop_requested and phase == .idle and pending == null) {
                daemonWrite(io, "daemon: stopped\n");
                return EXIT_OK;
            }
            // a stop during the pre-capture window cancels the pending
            // capture (it has consumed no tokens yet).
            if (stop_requested and phase == .pre_capture and pending != null) {
                daemonWrite(io, "daemon: stop during pre-capture review — canceled the pending capture\n");
                pending = null;
                phase = .idle;
                return EXIT_OK;
            }

            if (paused) {
                daemonWrite(io, "daemon: paused\n");
                try std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_s }, .boot);
                continue;
            }

            switch (phase) {
                .pre_capture => {
                    daemonWrite(io, "daemon: pre-capture review — capture starts in ");
                    const remaining = @max(@divTrunc(phase_until.raw.nanoseconds - boot_now_ns, std.time.ns_per_s) + 1, 1);
                    var nb: [32]u8 = undefined;
                    daemonWrite(io, try std.fmt.bufPrint(&nb, "{d}", .{remaining}));
                    daemonWrite(io, "s (write stop to fixtures/daemon.ctl to cancel)\n");
                    if (boot_now_ns >= phase_until.raw.nanoseconds) {
                        const action = pending orelse {
                            phase = .idle;
                            continue;
                        };
                        pending = null;
                        const desc = try describeQueueRow(a, action);
                        daemonWrite(io, "daemon: starting capture for ");
                        daemonWrite(io, desc);
                        daemonWrite(io, "\n");
                        const ok = runOneComboCapture(a, io, init, action, capture_timeout_seconds) catch |err| blk: {
                            daemonWriteErr(io, "daemon: capture worker error: ");
                            daemonWriteErr(io, @errorName(err));
                            daemonWriteErr(io, "\n");
                            break :blk false;
                        };
                        phase = .post_review;
                        phase_until = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, review_seconds) * std.time.ns_per_s }, .clock = .boot });
                        if (ok) {
                            capture_attempts.put(desc, 0) catch {};
                            const h = action.harness.?;
                            const p = action.provider.?;
                            const m_d = action.model.?;
                            const plat = action.platform.?;
                            try upsertFixture(a, io, .{
                                .harness = h,
                                .provider = p,
                                .model = m_d,
                                .platform = plat,
                                .runner = getParentPid(),
                                .generated_at = unixNow(io),
                            });
                            daemonWrite(io, "daemon: captured ");
                            daemonWrite(io, desc);
                            daemonWrite(io, "\n");
                        } else {
                            // token protection: at most 3 attempts, then
                            // dequeue with a warning (decision #12 runbook).
                            const attempts = (capture_attempts.get(desc) orelse 0) + 1;
                            capture_attempts.put(desc, attempts) catch {};
                            if (attempts >= 3) {
                                daemonWriteErr(io, "daemon: from-capture failed ");
                                var nbuf: [16]u8 = undefined;
                                daemonWriteErr(io, try std.fmt.bufPrint(&nbuf, "{d}", .{attempts}));
                                daemonWriteErr(io, " times for ");
                                daemonWriteErr(io, desc);
                                daemonWriteErr(io, " — dequeued with a warning (token protection)\n");
                            } else {
                                daemonWriteErr(io, "daemon: from-capture failed for ");
                                daemonWriteErr(io, desc);
                                daemonWriteErr(io, " — re-queued (attempt ");
                                var nbuf2: [16]u8 = undefined;
                                daemonWriteErr(io, try std.fmt.bufPrint(&nbuf2, "{d}", .{attempts}));
                                daemonWriteErr(io, "/3)\n");
                                try upsertQueueRow(a, io, action);
                            }
                        }
                        daemonWrite(io, "daemon: capture finished — human review window ");
                        var nb2: [32]u8 = undefined;
                        daemonWrite(io, try std.fmt.bufPrint(&nb2, "{d}", .{review_seconds}));
                        daemonWrite(io, "s\n");
                    }
                },
                .post_review => {
                    daemonWrite(io, "daemon: post-capture review\n");
                    if (boot_now_ns >= phase_until.raw.nanoseconds) {
                        phase = .idle;
                        daemonWrite(io, "daemon: review window complete\n");
                    }
                },
                .idle => {
                    if (boot_now_ns < next_poll.raw.nanoseconds) {
                        daemonWrite(io, "daemon: idle\n");
                    } else {
                        const row = try popQueueRow(a, io);
                        // one row per poll (decision #10): schedule the next
                        // poll `poll_seconds` out on EVERY path below, so a
                        // from-ids/from-raw batch processes at ~5s intervals.
                        next_poll = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, poll_seconds) * std.time.ns_per_s }, .clock = .boot });
                        if (row) |action| {
                            const desc = try describeQueueRow(a, action);
                            var msg_buf: [320]u8 = undefined;
                            const m = std.fmt.bufPrint(msg_buf[0..], "daemon: processing {s} [{s}]\n", .{ desc, action.mode }) catch "daemon: processing\n";
                            daemonWrite(io, m);

                            // shared validator: invalid → warn + drop (already popped).
                            validateQueueRow(action) catch {
                                daemonWriteErr(io, "daemon: invalid action row — dropping: ");
                                daemonWriteErr(io, desc);
                                daemonWriteErr(io, "\n");
                                continue;
                            };

                            const full = action.harness != null and action.provider != null and
                                action.model != null and action.platform != null;
                            if (!full) {
                                try expandSeed(a, io, action);
                                continue;
                            }

                            const h = action.harness.?;
                            const p = action.provider.?;
                            const m_d = action.model.?;
                            const plat = action.platform.?;

                            // skip-and-complete if a fresh fixture exists (unless
                            // scope_all=1). `from-capture` rows never skip: they
                            // are token-consuming and user-confirmed, so a
                            // committed fixture must not preempt the real capture.
                            if ((action.scope_all == null or action.scope_all.? != 1) and !std.mem.eql(u8, action.mode, "from-capture")) {
                                // 1. sqlite says a row already exists → nothing to do.
                                if (try fixtureExists(a, io, h, p, m_d, plat)) {
                                    daemonWrite(io, "daemon: fresh fixture exists for ");
                                    daemonWrite(io, desc);
                                    daemonWrite(io, " — completing without re-capture\n");
                                    continue;
                                }
                                // 2. no sqlite row yet, but a valid committed
                                // `fixtures/<id>.json` exists → origin-aware lazy
                                // backfill: only when the existing fixture's
                                // origin ranks ≥ the queued mode (a `from-raw`
                                // row re-captures over a stale `from-ids`
                                // fixture; `from-capture` never backfills).
                                if (try fixtureFileOriginRank(a, io, h, p, m_d, plat)) |rank| {
                                    if (rank >= modeRank(action.mode)) {
                                        try upsertFixture(a, io, .{
                                            .harness = h,
                                            .provider = p,
                                            .model = m_d,
                                            .platform = plat,
                                            .runner = getParentPid(),
                                            .generated_at = unixNow(io),
                                        });
                                        daemonWrite(io, "daemon: committed fixture for ");
                                        daemonWrite(io, desc);
                                        daemonWrite(io, " is valid — backfilled fixtures row without re-capture\n");
                                        continue;
                                    }
                                    daemonWrite(io, "daemon: committed fixture for ");
                                    daemonWrite(io, desc);
                                    daemonWrite(io, " ranks below the queued mode — re-capturing\n");
                                }
                            }

                            // staleness re-validation with the row's stored threshold
                            if (action.stale_by_days != null or action.stale_by_minutes != null) {
                                if (try fixtureRow(a, io, h, p, m_d, plat)) |fx| {
                                    if (!isStale(io, fx.generated_at, action.stale_by_minutes orelse (action.stale_by_days.? * 24 * 60))) {
                                        daemonWrite(io, "daemon: fixture for ");
                                        daemonWrite(io, desc);
                                        daemonWrite(io, " is still fresh by its threshold — completing early\n");
                                        continue;
                                    }
                                }
                            }

                            // --available rows: re-probe LIVE; if unavailable, re-queue as
                            // handoff work (available=0, original created_at), never capture.
                            // `from-ids` records availability but does NOT gate on it.
                            if (action.available != null and !std.mem.eql(u8, action.mode, "from-ids")) {
                                const agent = (try agentIdFrom(a, h, p, m_d)) orelse continue;
                                if (!harnessAvailable(io, agent)) {
                                    daemonWrite(io, "daemon: harness unavailable for ");
                                    daemonWrite(io, desc);
                                    daemonWrite(io, " — re-queued as handoff for the next agent/platform\n");
                                    var requeue = action;
                                    requeue.available = 0;
                                    try upsertQueueRow(a, io, requeue);
                                    continue;
                                }
                            }

                            // branch the worker on the row's mode (decision #7).
                            if (std.mem.eql(u8, action.mode, "from-capture")) {
                                if (pending != null) {
                                    daemonWrite(io, "daemon: already have a pending from-capture job — re-queuing\n");
                                    try upsertQueueRow(a, io, action);
                                } else {
                                    pending = action;
                                    phase = .pre_capture;
                                    phase_until = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, review_seconds) * std.time.ns_per_s }, .clock = .boot });
                                    daemonWrite(io, "daemon: from-capture job — announcing ");
                                    var nb3: [32]u8 = undefined;
                                    daemonWrite(io, try std.fmt.bufPrint(&nb3, "{d}", .{review_seconds}));
                                    daemonWrite(io, "s before capture (write stop to fixtures/daemon.ctl to cancel)\n");
                                }
                                continue;
                            }

                            const captured = try (if (std.mem.eql(u8, action.mode, "from-ids"))
                                runOneComboIds(a, io, action)
                            else
                                runOneComboResult(a, io, init, action));
                            if (captured) {
                                capture_attempts.put(desc, 0) catch {};
                                try upsertFixture(a, io, .{
                                    .harness = h,
                                    .provider = p,
                                    .model = m_d,
                                    .platform = plat,
                                    .runner = getParentPid(),
                                    .generated_at = unixNow(io),
                                });
                            } else {
                                // failure → re-queue (refresh available only for --available rows)
                                var requeue = action;
                                if (action.available != null) {
                                    const agent = (try agentIdFrom(a, h, p, m_d)) orelse continue;
                                    requeue.available = if (harnessAvailable(io, agent)) 1 else 0;
                                }
                                try upsertQueueRow(a, io, requeue);
                            }
                        } else {
                            next_poll = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, poll_seconds) * std.time.ns_per_s }, .clock = .boot });
                            _ = purgeMalformedFixtures(a, io);
                            daemonWrite(io, "daemon: idle, queue empty\n");
                        }
                    }
                },
            }
            // the ~1s tick — also the control-check cadence. Breaking the
            // sleep up this way is what lets a 15s review window stay
            // responsive (a single long sleep could not).
            try std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_s }, .boot);
        }
    }

    /// rank a refresh mode / fixture origin for ordering:
    /// `from-ids` (0) < `from-raw` (1) < `from-capture` (2).
    fn modeRank(mode: []const u8) u8 {
        if (std.mem.eql(u8, mode, "from-ids")) return 0;
        if (std.mem.eql(u8, mode, "from-raw")) return 1;
        return 2;
    }

    /// read `fixtures/daemon.ctl`, clear it, and return the action word
    /// (`pause` / `resume` / `stop`) or null when absent/empty. The
    /// daemon clears the file after acting (decision #12).
    fn readControlAction(a: std.mem.Allocator, io: std.Io) ?[]const u8 {
        const data = std.Io.Dir.cwd().readFileAlloc(io, "fixtures/daemon.ctl", a, @enumFromInt(4096)) catch return null;
        defer a.free(data);
        std.Io.Dir.cwd().deleteFile(io, "fixtures/daemon.ctl") catch {};
        const t = std.mem.trim(u8, data, " \t\r\n");
        if (t.len == 0) return null;
        if (std.mem.eql(u8, t, "pause") or std.mem.eql(u8, t, "resume") or std.mem.eql(u8, t, "stop")) return t;
        return null;
    }

    /// true iff `generated_at` (unix secs) is older than `threshold_minutes`.
    fn isStale(io: std.Io, generated_at: i64, threshold_minutes: i64) bool {
        const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
        return now - generated_at > threshold_minutes * 60;
    }

    /// Origin-aware lazy file-based backfill. Given a full combo
    /// `(h, p, m, plat)`, returns the existing committed
    /// `fixtures/<fixture_id>.json`'s origin rank (0 = from-ids, 1 =
    /// from-raw, 2 = from-capture) when a valid file exists whose
    /// `cooked` block parses AND carries the exact dims; null
    /// otherwise. The daemon backfills only when the rank is ≥ the
    /// queued mode's rank (a `from-raw` row re-captures over a stale
    /// `from-ids` fixture; `from-capture` never backfills).
    fn fixtureFileOriginRank(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !?u8 {
        _ = plat;
        const agent = (agentIdFrom(a, h, p, m) catch return null) orelse return null;
        defer a.free(agent);
        const f_id = fixtureId(a, agent) catch return null;
        defer a.free(f_id);
        const path = std.fmt.allocPrint(a, "fixtures/{s}.json", .{f_id}) catch return null;
        defer a.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return null;
        defer a.free(data);
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const cooked = parsed.value.object.get("cooked") orelse return null;
        if (cooked != .object) return null;
        const cob = cooked.object;
        const ch = sjstr(cob, "harness_id");
        const cp = sjstr(cob, "provider_id");
        const cm = sjstr(cob, "model_id");
        if (!(std.mem.eql(u8, ch, h) and std.mem.eql(u8, cp, p) and std.mem.eql(u8, cm, m))) return null;
        const origin = if (parsed.value.object.get("origin")) |ov| switch (ov) {
            .string => |s| s,
            else => "from-capture", // legacy fixtures predate the origin key
        } else "from-capture";
        return modeRank(origin);
    }

    /// expand a partial (seed) action over the `recipesForFixtures`
    /// recipes. A seed is a queue row: "capture every applicable recipe
    /// matching these dims". Every applicable recipe (set dims equal,
    /// platform empty or host) is queued as a full action, then the seed is
    /// dropped (already popped).
    fn expandSeed(a: std.mem.Allocator, io: std.Io, seed: QueueRow) !void {
        const host = platformId();
        const now = unixNow(io);

        var applicable: std.ArrayListUnmanaged(RecipesForFixtures) = .empty;
        defer applicable.deinit(a);
        for (recipesForFixtures) |c| {
            if (!recipeMatchesAction(seed, c, host)) continue;
            try applicable.append(a, c);
        }

        if (applicable.items.len == 0) {
            daemonWriteErr(io, "daemon: warning: no capture recipe applicable for ");
            daemonWriteErr(io, try describeQueueRow(a, seed));
            daemonWriteErr(io, "\n");
            return;
        }

        for (applicable.items) |c| {
            const parts = try splitAgentId(a, c.agent_id);
            defer {
                a.free(parts[0]);
                a.free(parts[1]);
                a.free(parts[2]);
            }
            var combo: QueueRow = .{
                .harness = parts[0],
                .provider = parts[1],
                .model = parts[2],
                .platform = try a.dupe(u8, host),
                .runner = getParentPid(),
                .created_at = now,
                // each expanded full row inherits the seed's mode.
                .mode = seed.mode,
            };
            if (seed.available != null) {
                combo.available = if (harnessAvailable(io, c.agent_id)) 1 else 0;
            }
            try validateQueueRow(combo);
            try upsertQueueRow(a, io, combo);
        }
    }

    /// does every dim that `seed` has set equal the recipe's dims?
    fn recipeMatchesAction(seed: QueueRow, combo: RecipesForFixtures, host: []const u8) bool {
        const parts = splitAgentId(std.heap.page_allocator, combo.agent_id) catch return false;
        defer {
            std.heap.page_allocator.free(parts[0]);
            std.heap.page_allocator.free(parts[1]);
            std.heap.page_allocator.free(parts[2]);
        }
        if (seed.harness) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, parts[0])) return false;
        }
        if (seed.provider) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, parts[1])) return false;
        }
        if (seed.model) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, parts[2])) return false;
        }
        if (seed.platform) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, host)) return false;
        }
        return true;
    }

    /// spawn `agent-detect-dev refresh run` for a single queued combo
    /// (`from-raw` mode). Returns true on successful capture (child exit
    /// 0 AND the post-check passing). The child inherits the daemon's
    /// env plus the fabricated markers, but its HOME is sandboxed to a
    /// per-fixture cache dir (2a) so `from-raw` captures never touch the
    /// user's real harness config and reruns are idempotent.
    fn runOneComboResult(a: std.mem.Allocator, io: std.Io, init: std.process.Init, action: QueueRow) !bool {
        const h = action.harness orelse return false;
        const p = action.provider orelse return false;
        const m_d = action.model orelse return false;

        // 1. find the recipe for the harness.
        const target_agent_aid = (try agentIdFrom(a, h, p, m_d)) orelse {
            daemonWriteErr(io, "daemon: no recipe applicable for ");
            daemonWriteErr(io, try describeQueueRow(a, action));
            daemonWriteErr(io, " — skipping\n");
            return false;
        };
        var combo: ?RecipesForFixtures = null;
        for (recipesForFixtures) |c| {
            if (std.mem.eql(u8, c.agent_id, target_agent_aid)) {
                combo = c;
                break;
            }
        }
        const c = combo orelse {
            daemonWriteErr(io, "daemon: no RecipesForFixtures recipe for ");
            daemonWriteErr(io, target_agent_aid);
            daemonWriteErr(io, " — skipping\n");
            return false;
        };

        // 2. build env (writes config files, env vars). HOME is
        // sandboxed BEFORE buildEnv runs so the fabricator's config
        // writes land in the per-fixture cache dir, never the real one.
        var env_map = std.process.Environ.Map.init(a);
        defer env_map.deinit();
        var parent_it = init.environ_map.iterator();
        while (parent_it.next()) |kv| {
            try env_map.put(kv.key_ptr.*, kv.value_ptr.*);
        }
        const real_home = init.environ_map.get("HOME") orelse (init.environ_map.get("USERPROFILE") orelse "");
        const xdg_cache = init.environ_map.get("XDG_CACHE_HOME") orelse blk: {
            if (real_home.len == 0) break :blk "";
            break :blk try std.fs.path.join(a, &.{ real_home, ".cache" });
        };
        const sandbox_home = try std.fs.path.join(a, &.{ xdg_cache, "agent-detect/workers", target_agent_aid });
        std.Io.Dir.cwd().createDirPath(io, sandbox_home) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                daemonWriteErr(io, "daemon: cannot create sandbox HOME for from-raw worker: ");
                daemonWriteErr(io, @errorName(err));
                daemonWriteErr(io, "\n");
                return false;
            },
        };
        try env_map.put("HOME", sandbox_home);
        if (builtin.os.tag == .windows) try env_map.put("USERPROFILE", sandbox_home);
        try env_map.put("AGENT_DETECT_FIXTURE_ORIGIN", "from-raw");

        const setup = c.buildEnv(a, &env_map, io, &c) catch |err| {
            daemonWriteErr(io, "daemon: buildEnv failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            return false;
        };
        for (setup.env) |kv| {
            if (kv[0].len == 0) break;
            try env_map.put(kv[0], kv[1]);
        }
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
                        return false;
                    },
                };
            }
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = w.path, .data = w.content }) catch |err| {
                daemonWriteErr(io, "daemon: writeFile failed for ");
                daemonWriteErr(io, w.path);
                daemonWriteErr(io, ": ");
                daemonWriteErr(io, @errorName(err));
                daemonWriteErr(io, "\n");
                return false;
            };
        }

        // 3. spawn the child (`refresh run` / `fixtures agent`)
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_path_len = std.process.executablePath(io, &self_path_buf) catch |err| {
            daemonWriteErr(io, "daemon: executablePath failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            return false;
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
            return false;
        };
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
            return false;
        };
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    daemonWriteErr(io, "daemon: worker failed for ");
                    daemonWriteErr(io, try describeQueueRow(a, action));
                    daemonWriteErr(io, " (exit code ");
                    var n_buf: [16]u8 = undefined;
                    daemonWriteErr(io, try std.fmt.bufPrint(&n_buf, "{d}", .{code}));
                    daemonWriteErr(io, ") — re-queued\n");
                    if (stderr_capture.items.len > 0) {
                        daemonWriteErr(io, "  worker stderr: ");
                        daemonWriteErr(io, stderr_capture.items);
                        if (stderr_capture.items[stderr_capture.items.len - 1] != '\n') daemonWriteErr(io, "\n");
                    }
                    return false;
                }
                // decision #11 post-check: the child wrote
                // `fixtures/<id>.json` and upserted a `fixtures` row.
                // Validate combo-match + evidence claims BEFORE accepting;
                // failure → delete the file AND the row the child
                // upserted, then re-queue.
                if (!(try postCheckComboFixture(a, io, action, "from-raw"))) {
                    deleteFixtureFileAndRow(a, io, h, p, m_d, platformId());
                    return false;
                }
                {
                    var buf2: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(buf2[0..], "daemon: captured {s}\n", .{try describeQueueRow(a, action)}) catch "daemon: captured\n";
                    daemonWrite(io, msg);
                }
                return true;
            },
            else => {
                daemonWriteErr(io, "daemon: child terminated abnormally for ");
                daemonWriteErr(io, try describeQueueRow(a, action));
                daemonWriteErr(io, "\n");
                return false;
            },
        }
    }

    /// decision #11/#12 post-check for an observed fixture produced by a
    /// `from-raw`/`from-capture` worker: parse `fixtures/<id>.json`,
    /// verify the top-level `origin` equals `expected_origin`, verify
    /// combo-match (`cooked.agent_id` == the queued agent), and verify
    /// the evidence claims pass `evidenceClaimsValid`. Returns false on
    /// any failure (the caller deletes the file + fixtures row and
    /// re-queues).
    fn postCheckComboFixture(a: std.mem.Allocator, io: std.Io, action: QueueRow, expected_origin: []const u8) !bool {
        const h = action.harness orelse return false;
        const p = action.provider orelse return false;
        const m_d = action.model orelse return false;
        const agent = (agentIdFrom(a, h, p, m_d) catch return false) orelse return false;
        defer a.free(agent);
        const f_id = fixtureId(a, agent) catch return false;
        defer a.free(f_id);
        const path = std.fmt.allocPrint(a, "fixtures/{s}.json", .{f_id}) catch return false;
        defer a.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch {
            daemonWriteErr(io, "daemon: post-check: fixture file missing: ");
            daemonWriteErr(io, path);
            daemonWriteErr(io, "\n");
            return false;
        };
        defer a.free(data);
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch {
            daemonWriteErr(io, "daemon: post-check: unparsable fixture: ");
            daemonWriteErr(io, path);
            daemonWriteErr(io, "\n");
            return false;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const cooked = parsed.value.object.get("cooked") orelse return false;
        const raw = parsed.value.object.get("raw") orelse return false;
        if (cooked != .object or raw != .object) return false;
        const cooked_agent = sjstr(cooked.object, "agent_id");
        if (!std.mem.eql(u8, cooked_agent, agent)) {
            daemonWriteErr(io, "daemon: post-check: combo mismatch — cooked agent_id '");
            daemonWriteErr(io, cooked_agent);
            daemonWriteErr(io, "' != queued '");
            daemonWriteErr(io, agent);
            daemonWriteErr(io, "'\n");
            return false;
        }
        const origin = if (parsed.value.object.get("origin")) |ov| switch (ov) {
            .string => |s| s,
            else => "from-capture", // legacy fixtures predate the origin key
        } else "from-capture";
        if (!std.mem.eql(u8, origin, expected_origin)) {
            daemonWriteErr(io, "daemon: post-check: origin '");
            daemonWriteErr(io, origin);
            daemonWriteErr(io, "' != expected '");
            daemonWriteErr(io, expected_origin);
            daemonWriteErr(io, "'\n");
            return false;
        }
        if (!evidenceClaimsValid(raw, cooked)) {
            daemonWriteErr(io, "daemon: post-check: evidence claims invalid for ");
            daemonWriteErr(io, agent);
            daemonWriteErr(io, "\n");
            return false;
        }
        return true;
    }

    /// `from-ids` post-check (decision #7): parse the declared fixture,
    /// confirm `origin == "from-ids"` and the cooked identity dims match
    /// the queue row. Declared fixtures carry no evidence, so the
    /// evidence-claim check is skipped.
    fn postCheckDeclaredFixture(a: std.mem.Allocator, io: std.Io, action: QueueRow) !bool {
        const h = action.harness orelse return false;
        const p = action.provider orelse return false;
        const m_d = action.model orelse return false;
        const agent = (agentIdFrom(a, h, p, m_d) catch return false) orelse return false;
        defer a.free(agent);
        const f_id = fixtureId(a, agent) catch return false;
        defer a.free(f_id);
        const path = std.fmt.allocPrint(a, "fixtures/{s}.json", .{f_id}) catch return false;
        defer a.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return false;
        defer a.free(data);
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const origin = if (parsed.value.object.get("origin")) |ov| switch (ov) {
            .string => |s| s,
            else => "",
        } else "";
        if (!std.mem.eql(u8, origin, "from-ids")) return false;
        const cooked = parsed.value.object.get("cooked") orelse return false;
        if (cooked != .object) return false;
        const ch = sjstr(cooked.object, "harness_id");
        const cp = sjstr(cooked.object, "provider_id");
        const cm = sjstr(cooked.object, "model_id");
        return std.mem.eql(u8, ch, h) and std.mem.eql(u8, cp, p) and std.mem.eql(u8, cm, m_d);
    }

    /// delete the `fixtures/<id>.json` file AND the `fixtures` row the
    /// child already upserted (runFixturesCapture upserts before the
    /// daemon's post-check runs) — a failed post-check must not leave
    /// "captured" state behind.
    fn deleteFixtureFileAndRow(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) void {
        const agent = (agentIdFrom(a, h, p, m) catch return) orelse return;
        defer a.free(agent);
        const f_id = fixtureId(a, agent) catch return;
        defer a.free(f_id);
        const path = std.fmt.allocPrint(a, "fixtures/{s}.json", .{f_id}) catch return;
        defer a.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const qh = sqlQuote(a, h) catch return;
        defer a.free(qh);
        const qp = sqlQuote(a, p) catch return;
        defer a.free(qp);
        const qm = sqlQuote(a, m) catch return;
        defer a.free(qm);
        const qplat = sqlQuote(a, plat) catch return;
        defer a.free(qplat);
        const sql = std.fmt.allocPrint(a,
            "DELETE FROM fixtures WHERE harness={s} AND provider={s} AND model={s} AND platform={s}",
            .{ qh, qp, qm, qplat },
        ) catch return;
        defer a.free(sql);
        _ = sqliteQuery(a, io, sql) catch {};
        daemonWriteErr(io, "daemon: post-check failure — deleted ");
        daemonWriteErr(io, path);
        daemonWriteErr(io, " and its fixtures row\n");
    }

    /// decision #11 — mechanical evidence-claim validation. For every
    /// dim in `raw.detected`, at least one `raw.evidence` claim must:
    ///   - have that `dim`,
    ///   - point at a source that is present in raw (env var name in
    ///     raw.env, config/session path+field as a top-level raw key,
    ///     lineage name in raw.process_lineage), and
    ///   - have a `value` that equals/contains the cooked dim's
    ///     canonical name (case-insensitive).
    /// This verifies the attribution chain only — semantic
    /// deducibility is human review. `from-ids` fixtures are excluded
    /// by their origin (declared, not observed).
    pub fn evidenceClaimsValid(raw_v: std.json.Value, cooked_v: std.json.Value) bool {
        if (raw_v != .object or cooked_v != .object) return false;
        const raw = raw_v.object;
        const cooked = cooked_v.object;
        const detected = raw.get("detected") orelse return false;
        const evidence = raw.get("evidence") orelse return false;
        const env = raw.get("env") orelse return false;
        const lineage = raw.get("process_lineage") orelse return false;
        if (detected != .array or evidence != .array) return false;
        outer: for (detected.array.items) |item| {
            if (item != .string) continue;
            const dim = item.string;
            for (evidence.array.items) |ev| {
                if (ev != .object) continue;
                const eo = ev.object;
                const cdim = jstr(eo, "dim") orelse continue;
                if (!std.mem.eql(u8, cdim, dim)) continue;
                const source = jstr(eo, "source") orelse continue;
                const name = jstr(eo, "name") orelse continue;
                // source present in raw?
                var present = false;
                if (std.mem.eql(u8, source, "env")) {
                    present = env.object.contains(name);
                } else if (std.mem.eql(u8, source, "config") or std.mem.eql(u8, source, "session")) {
                    if (raw.get(name)) |cfg| {
                        if (cfg == .object) {
                            if (jstr(eo, "field")) |fld| {
                                present = cfg.object.contains(fld);
                            } else {
                                present = true;
                            }
                        } else {
                            present = true;
                        }
                    }
                } else if (std.mem.eql(u8, source, "lineage")) {
                    for (lineage.array.items) |ent| {
                        if (ent == .object) {
                            const nm = jstr(ent.object, "name") orelse "";
                            if (std.mem.eql(u8, nm, name)) {
                                present = true;
                                break;
                            }
                        }
                    }
                }
                if (!present) continue;
                const value = jstr(eo, "value") orelse "";
                if (valueMatchesDim(value, dim, cooked)) continue :outer;
            }
            return false; // no valid claim for this dim
        }
        return true;
    }

    /// does `value` (the claim's recorded value) equal or contain the
    /// cooked canonical name/id for `dim`? Case-insensitive; the
    /// canonical reference is the `*_name` field (dash-spelled), with
    /// the `*_id` slug as fallback. For provider claims derived from an
    /// openai-compatible base_url (qwen), the value maps to the provider
    /// via `providerForBaseUrl` — the same derivation the detector ran.
    fn valueMatchesDim(value: []const u8, dim: []const u8, cooked: std.json.ObjectMap) bool {
        const names = [_][2][]const u8{
            .{ "harness", "harness_name" },
            .{ "provider", "provider_name" },
            .{ "model", "model_name" },
        };
        for (names) |pair| {
            if (!std.mem.eql(u8, pair[0], dim)) continue;
            const name = jstr(cooked, pair[1]) orelse "";
            if (name.len > 0 and std.ascii.indexOfIgnoreCase(value, name) != null) return true;
            const id_key = if (std.mem.eql(u8, dim, "harness")) "harness_id" else if (std.mem.eql(u8, dim, "provider")) "provider_id" else "model_id";
            const id = jstr(cooked, id_key) orelse "";
            if (id.len > 0 and std.ascii.indexOfIgnoreCase(value, id) != null) return true;
            // base_url-derived provider: the value is the endpoint, and
            // the provider id was derived FROM it.
            if (std.mem.eql(u8, dim, "provider")) {
                const pname = jstr(cooked, "provider_name") orelse "";
                if (pname.len > 0 and std.mem.eql(u8, providerForBaseUrl(value), pname)) return true;
            }
            return false;
        }
        return false;
    }

    /// `from-ids` worker (2f): resolve the combo via `resolveRecipe`
    /// (recipe-mode, no detection, zero tokens, no harness required),
    /// assemble the fixture with `cooked` fully populated, `raw` =
    /// platform_id/detectable/detected/empty-env/real-lineage/
    /// empty-evidence/static *-urls, and top-level `origin: "from-ids"`.
    /// Declared, not observed.
    fn runOneComboIds(a: std.mem.Allocator, io: std.Io, action: QueueRow) !bool {
        const h = action.harness orelse return false;
        const p = action.provider orelse return false;
        const m_d = action.model orelse return false;
        var d = (try resolveRecipe(a, h, p, m_d)) orelse {
            daemonWriteErr(io, "daemon: from-ids: combo not in the rule tables — cannot declare a fixture\n");
            return false;
        };
        // real process lineage (like detect() would emit) so the
        // declared fixture still shows WHERE it was written.
        const anc = ancestorInfo(a, io);
        var lineage = std.ArrayList(Ancestor).empty;
        for (anc.pids, 0..) |pid, i| {
            const name: []const u8 = if (i < anc.names.len) anc.names[i] else "";
            try lineage.append(a, .{ .pid = pid, .name = name });
        }
        d.raw.process_lineage = try lineage.toOwnedSlice(a);
        var empty_env = std.process.Environ.Map.init(a);
        defer empty_env.deinit();
        const cooked = try buildCooked(a, &d);
        const raw = try buildRaw(a, &d, &empty_env);
        var root = std.json.Value{ .object = .empty };
        try root.object.put(a, "cooked", cooked);
        try root.object.put(a, "raw", raw);
        if (d.trailer) |t| {
            try root.object.put(a, "trailer", .{ .string = t });
        }
        try root.object.put(a, "origin", .{ .string = "from-ids" });
        const json_bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
        defer a.free(json_bytes);

        std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return false,
        };
        const dir = std.Io.Dir.cwd().openDir(io, "fixtures", .{}) catch return false;
        defer dir.close(io);
        const agent = (try agentIdFrom(a, h, p, m_d)) orelse return false;
        defer a.free(agent);
        const f_id = fixtureId(a, agent) catch return false;
        defer a.free(f_id);
        const json_name = try std.fmt.allocPrint(a, "{s}.json", .{f_id});
        dir.writeFile(io, .{ .sub_path = json_name, .data = json_bytes }) catch {
            daemonWriteErr(io, "daemon: from-ids: cannot write fixture file\n");
            return false;
        };
        if (!(try postCheckDeclaredFixture(a, io, action))) {
            daemonWriteErr(io, "daemon: from-ids: post-check failed — deleting fixture\n");
            std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ "fixtures", json_name })) catch {};
            return false;
        }
        return true;
    }

    /// `from-capture` worker (2g): launch the real harness headlessly so
    /// it runs `fixtures capture` inside a live model session. Uses the
    /// REAL environment (unsandboxed HOME — real API keys/config are
    /// required); cwd stays the daemon's (the repo root) so the session
    /// writes `fixtures/<id>.json` into the repo. A watchdog subprocess
    /// (`fixtures __timeout`) enforces `--capture-timeout-seconds` so a
    /// hung harness fails out instead of blocking the poll loop forever.
    /// Success = child exit 0 AND the post-check passing; the caller
    /// handles re-queue/cap semantics. Token-consuming — user-confirmed
    /// only.
    fn runOneComboCapture(a: std.mem.Allocator, io: std.Io, init: std.process.Init, action: QueueRow, timeout_seconds: u64) !bool {
        const h = action.harness orelse return false;
        const p = action.provider orelse return false;
        const m_d = action.model orelse return false;
        const agent = (agentIdFrom(a, h, p, m_d) catch return false) orelse return false;
        defer a.free(agent);
        var combo: ?RecipesForFixtures = null;
        for (recipesForFixtures) |c| {
            if (std.mem.eql(u8, c.agent_id, agent)) {
                combo = c;
                break;
            }
        }
        const c = combo orelse {
            daemonWriteErr(io, "daemon: from-capture: no recipe for ");
            daemonWriteErr(io, agent);
            daemonWriteErr(io, "\n");
            return false;
        };
        const launch = c.launch orelse {
            daemonWriteErr(io, "daemon: from-capture: no launch spec for ");
            daemonWriteErr(io, agent);
            daemonWriteErr(io, " — headless capture not supported; use from-ids/from-raw\n");
            return false;
        };

        var child = std.process.spawn(io, .{
            .argv = launch,
            .environ_map = init.environ_map,
            .stdout = .ignore,
            .stderr = .pipe,
        }) catch |err| {
            daemonWriteErr(io, "daemon: from-capture: spawn failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            return false;
        };

        // timeout watchdog — `agent-detect-dev fixtures __timeout <sec> <pid>`.
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_path_len = std.process.executablePath(io, &self_path_buf) catch return false;
        const argv0 = self_path_buf[0..self_path_len];
        const pid_num: u32 = @intCast(child.id orelse 0);
        const pid_str = try std.fmt.allocPrint(a, "{d}", .{pid_num});
        var tbuf: [64]u8 = undefined;
        const sec_str = std.fmt.bufPrint(&tbuf, "{d}", .{timeout_seconds}) catch "";
        var wargv = [_][]const u8{ argv0, "fixtures", "__timeout", sec_str, pid_str };
        _ = std.process.spawn(io, .{ .argv = &wargv, .stdout = .ignore, .stderr = .ignore }) catch {};

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
            daemonWriteErr(io, "daemon: from-capture: child wait failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            return false;
        };
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    daemonWriteErr(io, "daemon: from-capture worker failed for ");
                    daemonWriteErr(io, agent);
                    daemonWriteErr(io, " (exit code ");
                    var n_buf: [16]u8 = undefined;
                    daemonWriteErr(io, try std.fmt.bufPrint(&n_buf, "{d}", .{code}));
                    daemonWriteErr(io, ")\n");
                    if (stderr_capture.items.len > 0) {
                        daemonWriteErr(io, "  worker stderr: ");
                        daemonWriteErr(io, stderr_capture.items);
                        if (stderr_capture.items[stderr_capture.items.len - 1] != '\n') daemonWriteErr(io, "\n");
                    }
                    deleteFixtureFileAndRow(a, io, h, p, m_d, platformId());
                    return false;
                }
                if (!(try postCheckComboFixture(a, io, action, "from-capture"))) {
                    deleteFixtureFileAndRow(a, io, h, p, m_d, platformId());
                    return false;
                }
                return true;
            },
            else => {
                daemonWriteErr(io, "daemon: from-capture child terminated abnormally for ");
                daemonWriteErr(io, agent);
                daemonWriteErr(io, "\n");
                deleteFixtureFileAndRow(a, io, h, p, m_d, platformId());
                return false;
            },
        }
    }

    /// `fixtures __timeout <seconds> <pid>` — internal watchdog used by
    /// the from-capture worker: sleeps N seconds (1s increments), then
    /// sends SIGTERM to the capture child so a hung harness fails out at
    /// `--capture-timeout-seconds` instead of blocking the poll loop.
    /// Fire-and-forget from the daemon's perspective.
    pub fn runTimeoutWorker(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;
        var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return EXIT_OUT_OF_MEMORY;
        defer args_it.deinit();
        _ = args_it.skip(); // argv0
        _ = args_it.skip(); // "fixtures"
        _ = args_it.skip(); // "__timeout"
        const sec_arg = args_it.next() orelse return EXIT_MISSING_ARG;
        const pid_arg = args_it.next() orelse return EXIT_MISSING_ARG;
        const seconds = std.fmt.parseInt(u64, sec_arg, 10) catch return EXIT_CONFLICTING_ARG;
        const pid = std.fmt.parseInt(u32, pid_arg, 10) catch return EXIT_CONFLICTING_ARG;
        var remaining = seconds;
        while (remaining > 0) : (remaining -= 1) {
            std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_s }, .boot) catch return EXIT_OK;
        }
        killPid(pid);
        return EXIT_OK;
    }

    /// send a terminate signal to a pid (the capture child). SIGTERM on
    /// POSIX; TerminateProcess on Windows — the single portable control
    /// surface the from-capture timeout relies on.
    fn killPid(pid: u32) void {
        if (builtin.os.tag == .windows) {
            const handle = OpenProcess(0x0001, 0, pid); // PROCESS_TERMINATE
            if (handle != null) {
                _ = TerminateProcess(handle.?, 1);
                _ = CloseHandle(handle.?);
            }
            return;
        }
        std.posix.kill(@intCast(pid), .TERM) catch {};
    }

    /// refuse to start the daemon if the current process is inside
    /// an agent. Two checks, both fail-closed:
    ///   - env markers: refuse if any of the fixtures agent-marker env
    ///     vars is set
    ///   - process ancestry: refuse if any ancestor's basename
    ///     matches a fixtures agent proc name
    fn assertNotInAgent(a: std.mem.Allocator, init: std.process.Init) !void {
        const io = init.io;
        const env_markers = [_][]const u8{
            "KIMI_CODE_HOME",  "KIMI_API_KEY",      "KIMI_BASE_URL",
            "MMX_CONFIG_DIR",  "MINIMAX_API_KEY",   "PI_CODING_AGENT",
            "GOOSE_TERMINAL",  "GOOSE_MODE",        "GOOSE_WORKING_DIR",
            "CLINE_NO_INTERACTIVE", "QWEN_API_KEY",  "JCODE_API_KEY",
            "OMP_API_KEY",     "REASONIX_API_KEY",  "CRUSH_API_KEY",
            "KILO_API_KEY",    "OPENCODE_API_KEY",  "VIBE_API_KEY",
            // launcher model-selector markers (from-raw/from-capture
            // workers set these in the child env, never the daemon's —
            // but if a stray one reaches a real shell the daemon should
            // still refuse, since it indicates a harness-session env).
            "KILO_MODEL", "OPENCODE_MODEL", "PI_PROVIDER", "PI_MODEL",
            "VIBE_ACTIVE_MODEL", "VIBE_ACTIVE_PROVIDER",
        };
        var it = init.environ_map.iterator();
        while (it.next()) |kv| {
            for (env_markers) |m| {
                if (std.mem.eql(u8, kv.key_ptr.*, m)) {
                    daemonWriteErr(io, "fixtures daemon: refusing to start — env marker ");
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
                    daemonWriteErr(io, "fixtures daemon: refusing to start — ancestor process ");
                    daemonWriteErr(io, n);
                    daemonWriteErr(io, " is a fixtures agent. This command must be run by a user, not inside an agent.\n");
                    return error.RunningInAgent;
                }
            }
        }
    }

} else struct {}; // end pub const dev

// ============================================================================
// main entry

/// is `word` one of the known top-level action words?
fn isKnownAction(word: []const u8) bool {
    return std.mem.eql(u8, word, "cooked") or
        std.mem.eql(u8, word, "trailer") or
        std.mem.eql(u8, word, "is-reciprocal") or
        std.mem.eql(u8, word, "help") or
        std.mem.eql(u8, word, "version");
}

pub fn main(init: std.process.Init) u8 {
    return mainInner(init) catch |err| switch (err) {
        error.OutOfMemory => EXIT_OUT_OF_MEMORY,
        else => blk: {
            // dev-only error kinds — pruned from the released binary.
            // Each writes its registry-name message to stderr (matching
            // the "exact message verbage" scheme) plus its exit code.
            if (dev_build) {
                if (err == error.SqliteSpawnFailed) {
                    writeErr(init.io, MSG_ENV_INCOMPLETE);
                    break :blk EXIT_ENV_INCOMPLETE;
                }
                if (err == error.SqliteError) {
                    writeErr(init.io, MSG_SQLITE_QUERY);
                    break :blk EXIT_SQLITE_QUERY;
                }
                if (err == error.FilesystemIoError) {
                    writeErr(init.io, MSG_IO);
                    break :blk EXIT_IO;
                }
                if (err == error.RunningInAgent) {
                    writeErr(init.io, MSG_ENV_INCOMPATIBLE);
                    break :blk EXIT_ENV_INCOMPATIBLE;
                }
                if (err == error.InvalidQueueRow) {
                    writeErr(init.io, MSG_CONFLICTING_ARG);
                    break :blk EXIT_CONFLICTING_ARG;
                }
            }
            // genuinely unexpected/unclassified (bug) — the only home of exit 1.
            writeErr(init.io, "error: ");
            writeErr(init.io, @errorName(err));
            writeErr(init.io, "\n");
            break :blk EXIT_UNRECOGNISED_ERROR;
        },
    };
}

fn mainInner(init: std.process.Init) anyerror!u8 {
    const a = init.arena.allocator();
    const io = init.io;

    // subcommand dispatch. The dev binary (built with -Ddev=true)
    // accepts a `raw` action (standalone raw block) plus a `fixtures`
    // subcommand namespace: `fixtures --help`, `fixtures daemon`,
    // `fixtures capture`, `fixtures queue [--harness=...]
    // [--provider=...] [--model=...]`, `fixtures queue --recipes`,
    // `fixtures dequeue`, plus `refresh run`. The
    // `raw`/`fixtures`/`refresh` dispatch is compiled out of the
    // released binary (dev_build is false) — the released and dev
    // binaries both run the action parser below: `cooked`, `trailer`,
    // `is-reciprocal`, `help`, `version` (with no arguments showing
    // help).
    if (dev_build) {
        var sub_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return error.OutOfMemory;
        defer sub_iter.deinit();
        _ = sub_iter.skip(); // argv0
        const cmd = sub_iter.next() orelse "";
        const sub = sub_iter.next() orelse "";
        // decision #8 — the dev binary's top-level help (bare no-args,
        // `help`, `--help`, `-h`) shows the FULL dev surface: the
        // released usage plus the dev actions section. `agent-detect
        // --help` (released binary) is unchanged.
        if (std.mem.eql(u8, cmd, "") or
            std.mem.eql(u8, cmd, "help") or
            std.mem.eql(u8, cmd, "--help") or
            std.mem.eql(u8, cmd, "-h"))
        {
            if (std.mem.eql(u8, sub, "trailer")) {
                writeOut(io, trailerUsage);
                return EXIT_OK;
            }
            writeOut(io, devUsage);
            return EXIT_OK;
        }
        if (std.mem.eql(u8, cmd, "fixtures")) {
            if (sub.len == 0 or
                std.mem.eql(u8, sub, "--help") or
                std.mem.eql(u8, sub, "-h") or
                std.mem.eql(u8, sub, "help"))
            {
                return dev.runFixturesHelp(init);
            } else if (std.mem.eql(u8, sub, "daemon")) {
                return dev.runFixturesDaemon(init);
            } else if (std.mem.eql(u8, sub, "capture")) {
                return dev.runFixturesCapture(init);
            } else if (std.mem.eql(u8, sub, "queue")) {
                return dev.runFixturesQueue(init);
            } else if (std.mem.eql(u8, sub, "dequeue")) {
                return dev.runFixturesDequeue(init);
            } else if (std.mem.eql(u8, sub, "__timeout")) {
                // internal watchdog used by the from-capture worker.
                return dev.runTimeoutWorker(init);
            } else {
                writeErr(io, "fixtures: unrecognised argument: '");
                writeErr(io, sub);
                writeErr(io, "'\n");
                writeOut(io, dev.fixturesUsage);
                return EXIT_UNRECOGNISED_ARG;
            }
        } else if (std.mem.eql(u8, cmd, "refresh") and std.mem.eql(u8, sub, "run")) {
            // `refresh run` — invoked by the daemon as a child to
            // capture the current session into a single
            // `fixtures/<fixture_id>.json` and upsert the matching
            // fixtures row. The child inherits the harness env and
            // config files the daemon set up via the
            // `RecipesForFixtures.buildEnv` recipe, so detection should
            // resolve to that harness.
            return dev.runFixturesCapture(init);
        } else if (std.mem.eql(u8, cmd, "raw")) {
            return dev.runRawAction(init);
        }
    }

    // action parser. The canonical spellings are the bare words
    // `cooked`, `trailer` (with a subtype), `is-reciprocal`, `help`,
    // and `version`; the `--help`/`-h` and `--version`/`-V` forms are
    // aliases. No arguments prints help. `cooked`, `trailer <type>`,
    // and `is-reciprocal` accept an optional complete combo
    // (`--harness=H --provider=P --model=M` — all three or none) for
    // recipe-mode output. help/version win over everything: any
    // help/version flag anywhere at top level short-circuits to the
    // relevant usage/version output (exit 0), never a conflict.
    var action: []const u8 = ""; // "", "cooked", "trailer", "is-reciprocal", "help", "version"
    var trailer_type: []const u8 = ""; // "", "co-author", "assisted-by"
    var help_wanted = false;
    var version_wanted = false;
    var help_topic: ?[]const u8 = null; // the word following `help` (`help trailer`)
    var unknown: ?[]const u8 = null; // first unrecognised bare word (no action set yet)
    var conflict: ?[]const u8 = null; // a second, different action/subtype word
    var combo_h: []const u8 = "";
    var combo_p: []const u8 = "";
    var combo_m: []const u8 = "";
    var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return error.OutOfMemory;
    defer args_it.deinit();
    _ = args_it.skip(); // argv0
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_wanted = true;
            if (action.len == 0) action = "help";
        } else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            version_wanted = true;
        } else if (std.mem.eql(u8, arg, "cooked") or std.mem.eql(u8, arg, "trailer") or std.mem.eql(u8, arg, "is-reciprocal")) {
            // an action word. After `help` it is the topic (`help trailer`).
            if (action.len == 0) {
                action = arg;
            } else if (std.mem.eql(u8, action, "help") and help_topic == null) {
                help_topic = arg;
            } else if (!std.mem.eql(u8, action, arg) and conflict == null) {
                conflict = arg;
            }
        } else if (std.mem.eql(u8, arg, "co-author") or std.mem.eql(u8, arg, "assisted-by")) {
            // trailer subtypes; after any other action a bare word is a conflict.
            if (std.mem.eql(u8, action, "trailer") and trailer_type.len == 0) {
                trailer_type = arg;
            } else if (std.mem.eql(u8, action, "help") and help_topic == null) {
                help_topic = arg;
            } else if (action.len == 0) {
                if (unknown == null) unknown = arg;
            } else if (conflict == null) {
                conflict = arg;
            }
        } else if (std.mem.startsWith(u8, arg, "--harness=")) {
            combo_h = arg["--harness=".len..];
        } else if (std.mem.startsWith(u8, arg, "--provider=")) {
            combo_p = arg["--provider=".len..];
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            combo_m = arg["--model=".len..];
        } else {
            // unrecognised bare word / flag.
            if (std.mem.eql(u8, action, "help") and help_topic == null) {
                help_topic = arg; // `help <topic>`
            } else if (action.len == 0) {
                if (unknown == null) unknown = arg;
            } else if (conflict == null) {
                conflict = arg;
            }
        }
    }

    // version wins over everything.
    if (version_wanted) {
        // Version is plumbed in at compile time from
        // `build.zig.zon`'s `.version` field via `build_options`.
        // Same value is baked into the released binary, the dev
        // binary, and every `zig build dist` cross-compile target.
        writeOut(io, "agent-detect ");
        writeOut(io, build_options.version);
        writeOut(io, "\n");
        return EXIT_OK;
    }

    // help wins over everything.
    if (help_wanted) {
        if (std.mem.eql(u8, action, "trailer")) {
            writeOut(io, trailerUsage);
            return EXIT_OK;
        }
        if (help_topic) |topic| {
            if (std.mem.eql(u8, topic, "trailer")) {
                writeOut(io, trailerUsage);
                return EXIT_OK;
            }
            if (isKnownAction(topic)) {
                writeOut(io, usage);
                return EXIT_OK;
            }
            writeErr(io, MSG_UNRECOGNISED_ARG);
            writeErr(io, topic);
            writeErr(io, "'\n");
            writeOut(io, usage);
            return EXIT_UNRECOGNISED_ARG;
        }
        writeOut(io, usage);
        return EXIT_OK;
    }

    // an unrecognised action word (a bare word appeared before any
    // known action, e.g. `foobar`, `--bogus`, `foobar cooked`).
    if (unknown != null) {
        writeErr(io, MSG_UNRECOGNISED_ARG);
        writeErr(io, unknown.?);
        writeErr(io, "'\n");
        writeOut(io, usage);
        return EXIT_UNRECOGNISED_ARG;
    }

    // no arguments (or only option flags, no action) → top usage.
    if (action.len == 0) {
        writeOut(io, usage);
        return EXIT_OK;
    }

    // two distinct action/subtype words → conflicting argument.
    if (conflict != null) {
        writeErr(io, MSG_CONFLICTING_ARG);
        writeOut(io, usage);
        return EXIT_CONFLICTING_ARG;
    }

    // bare `trailer` → missing required arguments (subtype absent).
    if (std.mem.eql(u8, action, "trailer") and trailer_type.len == 0) {
        writeErr(io, MSG_MISSING_ARG_TRAILER_SUBTYPE);
        writeOut(io, trailerUsage);
        return EXIT_MISSING_ARG;
    }

    // recipe mode: a complete combo resolves against the rule tables,
    // skipping live detection. Partial combos are rejected (exit 4);
    // an unknown combo is exit 7.
    const has_combo = combo_h.len > 0 or combo_p.len > 0 or combo_m.len > 0;
    if (has_combo) {
        if (combo_h.len == 0 or combo_p.len == 0 or combo_m.len == 0) {
            writeErr(io, MSG_MISSING_ARG_COMBO);
            writeOut(io, usage);
            return EXIT_MISSING_ARG;
        }
        const d = (try resolveRecipe(a, combo_h, combo_p, combo_m)) orelse {
            writeErr(io, MSG_MISSING_SPECIFIED_AGENT);
            return EXIT_MISSING_SPECIFIED_AGENT;
        };
        return runAction(init, &d, action, trailer_type);
    }

    // live detection.
    var d = Detection{};
    _ = try detect(init, &d);
    return runAction(init, &d, action, trailer_type);
}

/// dispatch the resolved action on a fully-shaped `Detection`. Handles
/// the shared identity-completeness gate (exit 8), the trailer subtypes
/// (co-author / assisted-by), the is-reciprocal tri-state, and the
/// cooked/raw data-output semantics (exit 9 on incomplete policy data).
fn runAction(init: std.process.Init, d: *const Detection, action: []const u8, trailer_type: []const u8) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    // identity incomplete → unable to detect: stderr only, no stdout
    // (no sensible data). Applies to every action.
    if (d.harness_label == null or d.provider_label == null or d.model_label == null) {
        writeErr(io, MSG_UNABLE_TO_DETECT);
        return EXIT_UNABLE_TO_DETECT;
    }

    if (std.mem.eql(u8, action, "trailer")) {
        // stdout only on success; failures are stderr-only.
        const t = if (std.mem.eql(u8, trailer_type, "assisted-by"))
            (try buildTrailerLine(a, d, "Assisted-by")).?
        else
            d.trailer.?; // "co-author" — already built with "Co-authored-by"
        writeOut(io, t);
        writeOut(io, "\n");
        return EXIT_OK;
    }

    if (std.mem.eql(u8, action, "is-reciprocal")) {
        switch (reciprocityOf(d)) {
            .reciprocal => {
                writeOut(io, "is reciprocal\n");
                return EXIT_OK;
            },
            .not_reciprocal => {
                writeOut(io, "not reciprocal\n");
                writeErr(io, MSG_REQUIREMENT_FAILED);
                return EXIT_REQUIREMENT_FAILED;
            },
            .unknown => {
                // identity resolved, policy data missing: stderr only.
                writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
                return EXIT_AGENT_DATA_INCOMPLETE;
            },
        }
    }

    // cooked — the detection report (canonical at root). Data-output
    // action: full report on 0; identity complete but policy data
    // incomplete → the report (with null policy fields) still goes to
    // stdout + a stderr explainer, exit 9.
    var buf: std.ArrayList(u8) = .empty;
    try buildJson(a, d, init.environ_map, null, .{}, &buf);
    writeOut(io, buf.items);
    if (reciprocityOf(d) == .unknown) {
        writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
        return EXIT_AGENT_DATA_INCOMPLETE;
    }
    return EXIT_OK;
}


