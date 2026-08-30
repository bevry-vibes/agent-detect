// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detect rules — the curated rule tables (model / provider / harness)
// and pure name resolution. Data-only: imports std/builtin exclusively and
// never imports core.zig or dev.zig (the import DAG is rules <- core <-
// dev <- main, no cycles). `binary_names` on each harness rule is the single
// hand-maintained list of executable names (bare stems first, then platform
// extensions) shared by the detection ancestry scan, the availability
// probe, the `--version` probe, launch argv[0] substitution, and the
// daemon guard.

const std = @import("std");
const builtin = @import("builtin");

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
pub const ModelRule = struct {
    name: []const u8,
    label: []const u8,
    /// optional shorter brand form used in casual references. e.g.
    /// "MiniMax M3" -> "M3". `null` means no established short form;
    /// the canonical output emits `null` and consumers fall back to
    /// `label` (or `model_name` if `label` is also unavailable).
    short_title: ?[]const u8 = null,
    reciprocity: ?[]const u8,
    /// SPDX license id of the model's weights, mirroring the harness
    /// license semantics (CONTRIBUTING "add a new harness rule"):
    /// an SPDX id (`"Apache-2.0"`, `"MIT"`), `"NOASSERTION"` when a
    /// license exists but is custom/non-SPDX, `"NONE"` for a verified
    /// closed model with no license granted, or `null` when
    /// unverified/undisclosed. Emitted as `model_license` in the
    /// canonical output.
    license: ?[]const u8 = null,
    sources: []const []const u8,
    /// extra alias display-strings not covered by `name`/`label`/
    /// `short_title` (e.g. the full product name). Each entry joins
    /// the rule's normalized alias set (lowercase + strip
    /// non-alphanumeric, whole-string) used by CLI flag resolution —
    /// see `canonicalIdFor`. Keep entries minimal: name/label/
    /// short_title already cover the common forms; add a variation
    /// only when a real-world alias is nowhere in those.
    variations: []const []const u8 = &.{},
};
pub const rulesForModels = [_]ModelRule{
    // kimi-k3: open-weight — Moonshot's HF card self-describes
    // "open-weight"; its LICENSE is the custom "Kimi K3 License"
    // (MIT-style with a large-scale commercial carve-out), not OSI
    // → NOASSERTION. variations: Chutes stamps secure-enclave served
    // ids with "-TEE" (observed: chutes/moonshotai/Kimi-K3-TEE).
    .{ .name = "kimi-k3", .label = "Kimi K3", .reciprocity = "open-weight", .license = "NOASSERTION", .sources = &.{ "https://huggingface.co/moonshotai/Kimi-K3", "https://huggingface.co/moonshotai/Kimi-K3/blob/main/LICENSE" }, .variations = &.{ "Kimi-K3-TEE", "moonshotai/Kimi-K3-TEE" } },
    // glm-5.2: open-source — zai-org's card tags it "Pure Open: MIT";
    // MIT is OSI-approved, and the OSAID 1.0 definition is linked as
    // concurrence for the open-source tier. variations: Chutes TEE
    // spelling (observed: chutes/zai-org/GLM-5.2-TEE).
    .{ .name = "glm-5.2", .label = "GLM 5.2", .reciprocity = "open-source", .license = "MIT", .sources = &.{ "https://huggingface.co/zai-org/GLM-5.2", "https://huggingface.co/zai-org/GLM-5.2/blob/main/LICENSE", "https://opensource.org/ai/open-source-ai-definition" }, .variations = &.{ "GLM-5.2-TEE", "zai-org/GLM-5.2-TEE" } },
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
    // brand home (blog id = the model's announcement page). Per the
    // Qwen3.8-2.4T-A95B card + qwencloud.com, Max is the official
    // version based on Qwen3.8-2.4T-A95B (the open MoE size of the
    // same generation) — a closed derivative, so it keeps its own
    // rule; no weights, no license granted → NONE.
    .{ .name = "qwen3.8-max", .label = "Qwen3.8-Max", .reciprocity = "closed", .license = "NONE", .sources = &.{ "https://qwen.ai/", "https://qwen.ai/blog?id=qwen3.8-max", "https://huggingface.co/Qwen/Qwen3.8-2.4T-A95B" } },
    // qwen3.8-27b: open-weight — the 27B dense size of the Qwen3.8
    // open-model family; HF card + LICENSE (Apache-2.0). The official
    // spellings carry the size (27B vs 2.4T-A95B) and bare "Qwen3.8"
    // has no uncontested official claim (it names the collection), so
    // each size keeps its own size-bearing rule; 2.4T gets its own
    // once observed. Qwen3.8-Flash-Next is a separate HF collection
    // (`qwen38-flash-next`) = separate family.
    // variations: Chutes stamps secure-enclave serving ids with
    // "-TEE" (same model, TEE mode); the observed id
    // `chutes/Qwen/Qwen3.8-27B-TEE` canonicalizes to `qwen3.8-27b-tee`
    // after applyModel's first-segment provider-prefix strip
    // (kimi-code's `default_model`), or to the namespaced form when a
    // 3-segment id reaches applyModel unstripped, so both forms are
    // recorded.
    .{ .name = "qwen3.8-27b", .label = "Qwen3.8 27B", .reciprocity = "open-weight", .license = "Apache-2.0", .sources = &.{ "https://huggingface.co/Qwen/Qwen3.8-27B", "https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/LICENSE" }, .variations = &.{ "Qwen3.8-27B-TEE", "Qwen/Qwen3.8-27B-TEE" } },
    // deepseek-v4-flash: open-weight — HF card + MIT LICENSE; the
    // weights are downloadable (MIT is OSI, but open-weight is the
    // conservative tier for the hosted API alias). variations: opencode's
    // free-tier alias `deepseek-v4-flash-free` (folded from its own rule
    // 2026-08-29 — same weights, tier spellings are variations per
    // DESIGN #13); Chutes serves the 0731 release stamp with its TEE
    // suffix (observed: chutes/deepseek-ai/DeepSeek-V4-Flash-0731-TEE) —
    // stamp/endpoint spellings coalesce into this model per DESIGN #13.
    .{ .name = "deepseek-v4-flash", .label = "DeepSeek V4 Flash", .reciprocity = "open-weight", .license = "MIT", .sources = &.{ "https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash", "https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash/blob/main/LICENSE" }, .variations = &.{ "DeepSeek-V4-Flash-0731-TEE", "deepseek-ai/DeepSeek-V4-Flash-0731-TEE", "deepseek-v4-flash-vision-exp", "deepseek-v4-flash-free" } },
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
    // gpt-oss-120b: open-weight — OpenAI's GPT-OSS flagship; HF card
    // + LICENSE (Apache-2.0).
    .{ .name = "gpt-oss-120b", .label = "GPT-OSS 120B", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/openai/gpt-oss-120b", "https://huggingface.co/openai/gpt-oss-120b/blob/main/LICENSE" } },
    // gemma-4-31b: open-weight — Google Gemma 4 family; HF card +
    // LICENSE (Apache-2.0 per the HF tag). variations: Chutes serves
    // this as a "-turbo" TEE spelling (observed:
    // chutes/google/gemma-4-31B-turbo-TEE); no `turbo` repo exists
    // on HF — the official 31B is `gemma-4-31B-it`, so the spelling
    // is a serving variant, folded per DESIGN #13.
    .{ .name = "gemma-4-31b", .label = "Gemma 4 31B", .reciprocity = "open-weight", .license = "Apache-2.0", .sources = &.{ "https://huggingface.co/google/gemma-4-31b-it", "https://huggingface.co/google/gemma-4-31b-it/blob/main/LICENSE" }, .variations = &.{ "gemma-4-31B-turbo-TEE", "google/gemma-4-31B-turbo-TEE" } },
    // gemini-3.5-flash: closed — Google Gemini 3.5 Flash; API-only, no
    // weights.
    .{ .name = "gemini-3.5-flash", .label = "Gemini 3.5 Flash", .reciprocity = "closed", .sources = &.{ "https://deepmind.google/models/", "https://ai.google.dev/gemini-api/docs/models" } },
    // grok-4.5: closed — xAI Grok 4.5; API-only, no weights.
    .{ .name = "grok-4.5", .label = "Grok 4.5", .reciprocity = "closed", .sources = &.{ "https://x.ai/grok", "https://docs.x.ai/docs/models" } },
    // glm-4.7-flash: open-weight — Z.ai GLM 4.7 Flash; HF card +
    // LICENSE.
    .{ .name = "glm-4.7-flash", .label = "Z.ai GLM 4.7 Flash", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/zai-org/GLM-4.7-Flash", "https://huggingface.co/zai-org/GLM-4.7-Flash/blob/main/LICENSE" } },
    // fugu-ultra-v1.1: open-weight — Sakana AI Fugu Ultra v1.1
    // (Japanese MoE); HF card.
    .{ .name = "fugu-ultra-v1.1", .label = "Fugu Ultra v1.1", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/sakana-ai/fugu-ultra-v1.1", "https://huggingface.co/sakana-ai/fugu-ultra-v1.1/blob/main/LICENSE" } },
    // deepseek-v3.2: open-weight — DeepSeek V3.2; HF card + MIT
    // LICENSE. variations: Chutes TEE spelling (observed:
    // chutes/deepseek-ai/DeepSeek-V3.2-TEE).
    .{ .name = "deepseek-v3.2", .label = "DeepSeek V3.2", .reciprocity = "open-weight", .license = "MIT", .sources = &.{ "https://huggingface.co/deepseek-ai/DeepSeek-V3.2", "https://huggingface.co/deepseek-ai/DeepSeek-V3.2/blob/main/LICENSE" }, .variations = &.{ "DeepSeek-V3.2-TEE", "deepseek-ai/DeepSeek-V3.2-TEE" } },
    // glm-4.6: open-weight — Z.ai GLM 4.6; HF card + LICENSE.
    .{ .name = "glm-4.6", .label = "Z.ai GLM 4.6", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/zai-org/GLM-4.6", "https://huggingface.co/zai-org/GLM-4.6/blob/main/LICENSE" } },
    // kimi-k2.5: open-weight — Moonshot Kimi K2.5; HF card + LICENSE.
    .{ .name = "kimi-k2.5", .label = "Kimi K2.5", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/moonshotai/Kimi-K2.5", "https://huggingface.co/moonshotai/Kimi-K2.5/blob/main/LICENSE" } },
    // kimi-k2: open-weight — Moonshot Kimi K2; HF card + LICENSE.
    .{ .name = "kimi-k2", .label = "Kimi K2", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/moonshotai/Kimi-K2", "https://huggingface.co/moonshotai/Kimi-K2/blob/main/LICENSE" } },
    // devstral-2: open-weight — Mistral Devstral 2 coding model; HF
    // card + LICENSE.
    .{ .name = "devstral-2", .label = "Devstral 2", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/mistralai/Devstral-2", "https://huggingface.co/mistralai/Devstral-2/blob/main/LICENSE" } },
    // nemotron-3-ultra: open-weight — NVIDIA Nemotron 3 Ultra; HF card
    // + LICENSE.
    .{ .name = "nemotron-3-ultra", .label = "Nemotron 3 Ultra", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/nvidia/Nemotron-3-Ultra-550B-A55B", "https://huggingface.co/nvidia/Nemotron-3-Ultra-550B-A55B/blob/main/LICENSE" } },
    // qwen3-coder: open-weight — Alibaba Qwen3 Coder; HF card +
    // LICENSE.
    .{ .name = "qwen3-coder", .label = "Qwen3 Coder", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/Qwen/Qwen3-Coder", "https://huggingface.co/Qwen/Qwen3-Coder/blob/main/LICENSE" } },
    // cogito-2.1: open-weight — DeepCogito Cogito 2.1 671B; HF card.
    .{ .name = "cogito-2.1", .label = "Cogito 2.1", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/deepcogito/cogito-2.1-671b", "https://huggingface.co/deepcogito/cogito-2.1-671b/blob/main/LICENSE" } },
    // muse-spark-1.2: Meta Muse Spark 1.2; reciprocity unverified.
    // variations: "-contributor" is OpenRouter's contributor-tier
    // listing of the same model name (observed on OR + opencode-go).
    .{ .name = "muse-spark-1.2", .label = "Muse Spark 1.2", .reciprocity = null, .sources = &.{}, .variations = &.{ "muse-spark-1.2-contributor" } },
    // claude-fable-5: closed — Anthropic Claude Fable 5; API-only, no
    // weights.
    .{ .name = "claude-fable-5", .label = "Claude Fable 5", .reciprocity = "closed", .sources = &.{ "https://www.anthropic.com/claude", "https://docs.anthropic.com/en/docs/about-claude/models" } },
    // gpt-4o: closed — OpenAI GPT-4o; API-only, no weights.
    .{ .name = "gpt-4o", .label = "GPT-4o", .reciprocity = "closed", .sources = &.{ "https://openai.com/api/pricing/", "https://platform.openai.com/docs/models" } },
    // grok-3: closed — xAI Grok 3; API-only, no weights.
    .{ .name = "grok-3", .label = "Grok 3", .reciprocity = "closed", .sources = &.{ "https://x.ai/grok", "https://docs.x.ai/docs/models" } },
    // glm-4.7: open-weight — Z.ai GLM 4.7; HF card + LICENSE.
    // variations: `zai-glm-4.7` (folded from its own rule 2026-08-29 —
    // same zai-org weights on the Cerebras-hosted free trial; the old
    // rule's "Z.ai GLM 4.7" label shares the spelling's slug, so one
    // variation covers both).
    .{ .name = "glm-4.7", .label = "GLM 4.7", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/zai-org/GLM-4.7", "https://huggingface.co/zai-org/GLM-4.7/blob/main/LICENSE" }, .variations = &.{ "zai-glm-4.7" } },
    // deepseek-r1: open-weight — DeepSeek R1; HF card + LICENSE.
    .{ .name = "deepseek-r1", .label = "DeepSeek R1", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/deepseek-ai/DeepSeek-R1", "https://huggingface.co/deepseek-ai/DeepSeek-R1/blob/main/LICENSE" } },
    // gemini-3-pro: closed — Google Gemini 3 Pro; API-only, no weights.
    .{ .name = "gemini-3-pro", .label = "Gemini 3 Pro", .reciprocity = "closed", .sources = &.{ "https://deepmind.google/models/", "https://ai.google.dev/gemini-api/docs/models" } },
    // gemma-3-27b: open-weight — Google Gemma 3 27B; HF card + LICENSE.
    .{ .name = "gemma-3-27b", .label = "Gemma 3 27B", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/google/gemma-3-27b-it", "https://huggingface.co/google/gemma-3-27b-it/blob/main/LICENSE" } },
    // phi-4: open-weight — Microsoft Phi-4; HF card + LICENSE.
    .{ .name = "phi-4", .label = "Phi-4", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/microsoft/phi-4", "https://huggingface.co/microsoft/phi-4/blob/main/LICENSE" } },
    // phi-4-mini: open-weight — Microsoft Phi-4 Mini; HF card + LICENSE.
    .{ .name = "phi-4-mini", .label = "Phi-4 Mini", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/microsoft/phi-4-mini-instruct", "https://huggingface.co/microsoft/phi-4-mini-instruct/blob/main/LICENSE" } },
    // command-a: open-weight — Cohere Command A; HF card + LICENSE.
    .{ .name = "command-a", .label = "Command A", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/CohereForAI/c4ai-command-a-03-2025", "https://huggingface.co/CohereForAI/c4ai-command-a-03-2025/blob/main/LICENSE" } },
    // ling-3.0-flash: open-weight — InclusionAI Ling 3.0 Flash; HF card.
    .{ .name = "ling-3.0-flash", .label = "Ling 3.0 Flash", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/inclusionai/Ling-3.0-Flash", "https://huggingface.co/inclusionai/Ling-3.0-Flash/blob/main/LICENSE" } },
    // ling-2.6-1t: open-weight — InclusionAI Ling 2.6 1T; HF card.
    .{ .name = "ling-2.6-1t", .label = "Ling 2.6 1T", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/inclusionai/Ling-2.6-1T", "https://huggingface.co/inclusionai/Ling-2.6-1T/blob/main/LICENSE" } },
    // olmo-3-32b-think: open-weight — Ai2 OLMo 3 32B Think; HF card +
    // LICENSE.
    .{ .name = "olmo-3-32b-think", .label = "OLMo 3 32B Think", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/allenai/OLMo-3-32B-Think", "https://huggingface.co/allenai/OLMo-3-32B-Think/blob/main/LICENSE" } },
    // doubao-seed-2.1: ByteDance Doubao Seed 2.1; reciprocity unverified.
    .{ .name = "doubao-seed-2.1", .label = "Doubao Seed 2.1", .reciprocity = null, .sources = &.{} },
    // ernie-4.5: Baidu ERNIE 4.5; reciprocity unverified.
    .{ .name = "ernie-4.5", .label = "ERNIE 4.5", .reciprocity = null, .sources = &.{} },
    // hunyuan-t1: open-weight — Tencent Hunyuan T1; HF card + LICENSE.
    .{ .name = "hunyuan-t1", .label = "Hunyuan T1", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/Tencent-Hunyuan/Hunyuan-T1", "https://huggingface.co/Tencent-Hunyuan/Hunyuan-T1/blob/main/LICENSE" } },
    // mistral-small-3: open-weight — Mistral Small 3; HF card + LICENSE.
    .{ .name = "mistral-small-3", .label = "Mistral Small 3", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/mistralai/Mistral-Small-3", "https://huggingface.co/mistralai/Mistral-Small-3/blob/main/LICENSE" } },
    // qwen3.6: open-weight — Alibaba Qwen3.6; HF card + LICENSE.
    .{ .name = "qwen3.6", .label = "Qwen3.6", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/Qwen/Qwen3.6", "https://huggingface.co/Qwen/Qwen3.6/blob/main/LICENSE" } },
    // llama-3.1-8b: open-weight — Meta Llama 3.1 8B; HF card + LICENSE.
    .{ .name = "llama-3.1-8b", .label = "Llama 3.1 8B", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/meta-llama/Llama-3.1-8B", "https://huggingface.co/meta-llama/Llama-3.1-8B/blob/main/LICENSE" } },
    // nemotron-3-super: open-weight — NVIDIA Nemotron 3 Super; HF card
    // + LICENSE.
    .{ .name = "nemotron-3-super", .label = "Nemotron 3 Super", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/nvidia/Nemotron-3-Super-120B-A12B", "https://huggingface.co/nvidia/Nemotron-3-Super-120B-A12B/blob/main/LICENSE" } },
    // nemotron-3-nano: open-weight — NVIDIA Nemotron 3 Nano; HF card +
    // LICENSE.
    .{ .name = "nemotron-3-nano", .label = "Nemotron 3 Nano", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/nvidia/Nemotron-3-Nano-30B-A3B", "https://huggingface.co/nvidia/Nemotron-3-Nano-30B-A3B/blob/main/LICENSE" } },
    // llama-3.3-70b: open-weight — Meta Llama 3.3 70B; HF card +
    // LICENSE.
    .{ .name = "llama-3.3-70b", .label = "Llama 3.3 70B", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct", "https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct/blob/main/LICENSE" } },
    // llama-4-maverick: open-weight — Meta Llama 4 Maverick; HF card +
    // LICENSE.
    .{ .name = "llama-4-maverick", .label = "Llama 4 Maverick", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/meta-llama/Llama-4-Maverick-17B-128E-Instruct", "https://huggingface.co/meta-llama/Llama-4-Maverick-17B-128E-Instruct/blob/main/LICENSE" } },
    // kimi-k2.7-code: open-weight — Moonshot Kimi K2.7 Code; HF card +
    // LICENSE.
    .{ .name = "kimi-k2.7-code", .label = "Kimi K2.7 Code", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/moonshotai/Kimi-K2.7-Code", "https://huggingface.co/moonshotai/Kimi-K2.7-Code/blob/main/LICENSE" } },
    // grok-4.20: closed — xAI Grok 4.20; API-only, no weights.
    .{ .name = "grok-4.20", .label = "Grok 4.20", .reciprocity = "closed", .sources = &.{ "https://x.ai/grok", "https://docs.x.ai/docs/models" } },
    // minimax-m2.5: open-weight — MiniMax M2.5; HF card + LICENSE.
    .{ .name = "minimax-m2.5", .label = "MiniMax M2.5", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/MiniMaxAI/MiniMax-M2.5", "https://huggingface.co/MiniMaxAI/MiniMax-M2.5/blob/main/LICENSE" } },
    // qwen3.6-max: closed — Alibaba Qwen3.6 Max; hosted flagship,
    // API-only, no weights.
    .{ .name = "qwen3.6-max", .label = "Qwen3.6-Max", .reciprocity = "closed", .sources = &.{ "https://qwen.ai/", "https://qwen.ai/blog?id=qwen3.6-max" } },
    // qwen3.7-flash: open-weight — Alibaba Qwen3.7 Flash; HF card +
    // LICENSE.
    .{ .name = "qwen3.7-flash", .label = "Qwen3.7-Flash", .reciprocity = "open-weight", .sources = &.{ "https://huggingface.co/Qwen/Qwen3.7-Flash", "https://huggingface.co/Qwen/Qwen3.7-Flash/blob/main/LICENSE" } },
    // gpt-5.2: closed — OpenAI GPT-5.2; API-only, no weights.
    .{ .name = "gpt-5.2", .label = "GPT-5.2", .reciprocity = "closed", .sources = &.{ "https://openai.com/index/gpt-5/", "https://platform.openai.com/docs/models" } },
    // gpt-5.6-sol: closed — OpenAI GPT-5.6 Sol; API-only, no weights.
    .{ .name = "gpt-5.6-sol", .label = "GPT-5.6 Sol", .reciprocity = "closed", .sources = &.{ "https://openai.com/index/gpt-5/", "https://platform.openai.com/docs/models" } },
    // gpt-5.6-luna: closed — OpenAI GPT-5.6 Luna; API-only, no weights.
    .{ .name = "gpt-5.6-luna", .label = "GPT-5.6 Luna", .reciprocity = "closed", .sources = &.{ "https://openai.com/index/gpt-5/", "https://platform.openai.com/docs/models" } },
    // claude-sonnet-5: closed — Anthropic Claude Sonnet 5; API-only,
    // no weights.
    .{ .name = "claude-sonnet-5", .label = "Claude Sonnet 5", .reciprocity = "closed", .sources = &.{ "https://www.anthropic.com/claude/sonnet", "https://docs.anthropic.com/en/docs/about-claude/models" } },
    // claude-opus-5: closed — Anthropic Claude Opus 5; API-only, no
    // weights.
    .{ .name = "claude-opus-5", .label = "Claude Opus 5", .reciprocity = "closed", .sources = &.{ "https://www.anthropic.com/claude/opus", "https://docs.anthropic.com/en/docs/about-claude/models" } },
    // gemini-2.5-pro: closed — Google Gemini 2.5 Pro; API-only, no
    // weights.
    .{ .name = "gemini-2.5-pro", .label = "Gemini 2.5 Pro", .reciprocity = "closed", .sources = &.{ "https://deepmind.google/models/", "https://ai.google.dev/gemini-api/docs/models" } },
    // qwen3.5-397b-a17b: open-weight — the MoE flagship of the Qwen3.5
    // open line (Apache-2.0 per HF tag); the official spelling carries
    // the size, and the bare 3.5 name is claimed by `Qwen/Qwen3.5` —
    // held by the `qwen3.5` hosted-alias rule — so this release is its
    // own size-bearing rule. variations: Chutes TEE spelling (observed:
    // chutes/Qwen/Qwen3.5-397B-A17B-TEE).
    .{ .name = "qwen3.5-397b-a17b", .label = "Qwen3.5 397B A17B", .reciprocity = "open-weight", .license = "Apache-2.0", .sources = &.{ "https://huggingface.co/Qwen/Qwen3.5-397B-A17B", "https://huggingface.co/Qwen/Qwen3.5-397B-A17B/blob/main/LICENSE" }, .variations = &.{ "Qwen3.5-397B-A17B-TEE", "Qwen/Qwen3.5-397B-A17B-TEE" } },
    // qwen3-235b-a22b: open-weight — the MoE flagship size of the
    // base Qwen3 line (Apache-2.0; the 2507 refresh ships Instruct
    // and Thinking template variants of the same weights, stamp/
    // template spellings coalesced per DESIGN #13). variations:
    // Chutes TEE spelling (observed: chutes/Qwen/
    // Qwen3-235B-A22B-Thinking-2507-TEE).
    .{ .name = "qwen3-235b-a22b", .label = "Qwen3 235B A22B", .reciprocity = "open-weight", .license = "Apache-2.0", .sources = &.{ "https://huggingface.co/Qwen/Qwen3-235B-A22B-Thinking-2507", "https://huggingface.co/Qwen/Qwen3-235B-A22B-Thinking-2507/blob/main/LICENSE" }, .variations = &.{ "Qwen3-235B-A22B-Thinking-2507-TEE", "Qwen/Qwen3-235B-A22B-Thinking-2507-TEE" } },
    // kimi-k2.6: open-weight — Moonshot Kimi K2.6; LICENSE is a
    // custom "Modified MIT License" (© 2026 Moonshot; not plain MIT,
    // not SPDX → NOASSERTION). variations: Chutes TEE spelling
    // (observed: chutes/moonshotai/Kimi-K2.6-TEE).
    .{ .name = "kimi-k2.6", .label = "Kimi K2.6", .reciprocity = "open-weight", .license = "NOASSERTION", .sources = &.{ "https://huggingface.co/moonshotai/Kimi-K2.6", "https://huggingface.co/moonshotai/Kimi-K2.6/blob/main/LICENSE" }, .variations = &.{ "Kimi-K2.6-TEE", "moonshotai/Kimi-K2.6-TEE" } },
    // glm-5.1: open-weight — Z.ai GLM 5.1; LICENSE is plain MIT
    // (© 2026 Zhipu AI) but the card carries no "Pure Open"/OSAID
    // claim (unlike GLM-5.2), so it keeps the conservative
    // open-weight tier. variations: Chutes TEE spelling (observed:
    // chutes/zai-org/GLM-5.1-TEE).
    .{ .name = "glm-5.1", .label = "GLM 5.1", .reciprocity = "open-weight", .license = "MIT", .sources = &.{ "https://huggingface.co/zai-org/GLM-5.1", "https://huggingface.co/zai-org/GLM-5.1/blob/main/LICENSE" }, .variations = &.{ "GLM-5.1-TEE", "zai-org/GLM-5.1-TEE" } },
    // mistral-nemo-instruct-2407: open-weight — Mistral Nemo
    // (Apache-2.0 per the HF license tag; the repo ships no LICENSE
    // file, so the license text URL is the second source). Single
    // size, so the id carries the 2407 stamp, not a param size.
    // variations: Chutes TEE spelling (observed: chutes/unsloth/
    // Mistral-Nemo-Instruct-2407-TEE — unsloth namespace, official
    // weights).
    .{ .name = "mistral-nemo-instruct-2407", .label = "Mistral Nemo Instruct 2407", .reciprocity = "open-weight", .license = "Apache-2.0", .sources = &.{ "https://huggingface.co/mistralai/Mistral-Nemo-Instruct-2407", "https://www.apache.org/licenses/LICENSE-2.0" }, .variations = &.{ "Mistral-Nemo-Instruct-2407-TEE", "unsloth/Mistral-Nemo-Instruct-2407-TEE" } },
    // nemotron-3-nano-omni: open-weight — NVIDIA Nemotron 3 Nano
    // Omni (multimodal line of the nano tier; official HF repos are
    // the A3B-Reasoning quantizations, single size so the id omits
    // it, per the `nemotron-3-nano` convention). LICENSE: HF tag
    // `other` (custom NVIDIA terms; no LICENSE file in the repos) →
    // NOASSERTION; card is the only independent doc. variations:
    // Chutes TEE spelling (observed bare: chutes/Nemotron-3-Nano-
    // Omni-30B-TEE — no namespace, so the bare form suffices).
    .{ .name = "nemotron-3-nano-omni", .label = "Nemotron 3 Nano Omni", .reciprocity = "open-weight", .license = "NOASSERTION", .sources = &.{"https://huggingface.co/nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16"}, .variations = &.{ "Nemotron-3-Nano-Omni-30B-TEE" } },
    // glm-5: open-weight — Z.ai GLM 5; HF card + MIT LICENSE. No
    // "Pure Open" claim on the card (like glm-5.1), so the
    // conservative open-weight tier. Observed on opencode-go (bare
    // id, evergreen z-ai/glm-5) — no serving-variant spellings yet.
    .{ .name = "glm-5", .label = "GLM 5", .reciprocity = "open-weight", .license = "MIT", .sources = &.{ "https://huggingface.co/zai-org/GLM-5", "https://huggingface.co/zai-org/GLM-5/blob/main/LICENSE" } },
    // glm-5.3: open-weight — Z.ai GLM 5.3; LICENSE is a custom
    // "GLM-5.3 License" (© 2026 Z.AI; not plain MIT, not SPDX →
    // NOASSERTION). Observed on opencode-go (bare id).
    .{ .name = "glm-5.3", .label = "GLM 5.3", .reciprocity = "open-weight", .license = "NOASSERTION", .sources = &.{ "https://huggingface.co/zai-org/GLM-5.3", "https://huggingface.co/zai-org/GLM-5.3/blob/main/LICENSE" } },
    // glm-5.3-flash: open-weight — Z.ai GLM 5.3 Flash; HF card + MIT
    // LICENSE. Observed on opencode-go (bare id).
    .{ .name = "glm-5.3-flash", .label = "GLM 5.3 Flash", .reciprocity = "open-weight", .license = "MIT", .sources = &.{ "https://huggingface.co/zai-org/GLM-5.3-Flash", "https://huggingface.co/zai-org/GLM-5.3-Flash/blob/main/LICENSE" } },
    // mimo-v2.5: open-weight — Xiaomi MiMo V2.5; HF card + MIT
    // LICENSE. Single-size version, stamp not a param size. Observed
    // on opencode-go (bare id).
    .{ .name = "mimo-v2.5", .label = "MiMo V2.5", .reciprocity = "open-weight", .license = "MIT", .sources = &.{ "https://huggingface.co/XiaomiMiMo/MiMo-V2.5", "https://huggingface.co/XiaomiMiMo/MiMo-V2.5/blob/main/LICENSE" } },
    // mimo-v2.5-pro: open-weight — Xiaomi MiMo V2.5 Pro (the pro
    // size-class of the V2.5 line, so it keeps its own rule); HF card
    // + MIT LICENSE. Observed on opencode-go (bare id).
    .{ .name = "mimo-v2.5-pro", .label = "MiMo V2.5 Pro", .reciprocity = "open-weight", .license = "MIT", .sources = &.{ "https://huggingface.co/XiaomiMiMo/MiMo-V2.5-Pro", "https://huggingface.co/XiaomiMiMo/MiMo-V2.5-Pro/blob/main/LICENSE" } },
    // hy3: open-weight — Tencent Hy3; HF card + Apache-2.0 LICENSE
    // (repo is `tencent/Hy3`, the line's official spelling). Observed
    // on opencode-go (bare id).
    .{ .name = "hy3", .label = "Hy3", .reciprocity = "open-weight", .license = "Apache-2.0", .sources = &.{ "https://huggingface.co/tencent/Hy3", "https://huggingface.co/tencent/Hy3/blob/main/LICENSE" } },
    // hy4-preview: open-weight — Tencent Hy4 preview; HF card +
    // Apache-2.0 LICENSE (preview stage is part of the release name,
    // not a param size). Observed on opencode-go (bare id).
    .{ .name = "hy4-preview", .label = "Hy4 Preview", .reciprocity = "open-weight", .license = "Apache-2.0", .sources = &.{ "https://huggingface.co/tencent/Hy4-preview", "https://huggingface.co/tencent/Hy4-preview/blob/main/LICENSE" } },
    // grok-4.6: closed — xAI Grok 4.6; API-only, no weights → NONE
    // (same source set as the grok-4.5 rule). Observed on
    // opencode-go (bare id).
    .{ .name = "grok-4.6", .label = "Grok 4.6", .reciprocity = "closed", .license = "NONE", .sources = &.{ "https://x.ai/grok", "https://docs.x.ai/docs/models" } },
    // qwen3.8-flash: unverified — served as `qwen3.8-flash` by
    // opencode-go and listed by OpenRouter with no hugging_face_id
    // mapping; no `Qwen/Qwen3.8-Flash` repo exists on HF (the 3.8
    // flash line's open repos are `Qwen3.8-Flash-Next[ -FP8]`, a
    // separate HF collection from `qwen38`). Whether the hosted alias
    // is the Flash-Next serving form is unverified, so reciprocity
    // and license stay null (never-guess) pending a maintainer audit.
    .{ .name = "qwen3.8-flash", .label = "Qwen3.8 Flash", .reciprocity = null, .sources = &.{} },
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
pub const ProviderRule = struct {
    name: []const u8,
    label: []const u8,
    /// optional short brand form for casual references. `null` when no
    /// established short form; kept on the generic resolver so the
    /// normalized alias set (name + label + short_title + variations)
    /// is uniform across the three rule tables (see `canonicalIdFor`).
    short_title: ?[]const u8 = null,
    closed_training: ?[]const u8,
    open_training: ?[]const u8,
    sources: []const []const u8,
    /// extra alias display-strings not covered by `name`/`label`/
    /// `short_title`; joins the normalized alias set — see the field
    /// doc on `ModelRule.variations`.
    variations: []const []const u8 = &.{},
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
    // NOTE — phantom-provider guard: crush's hyper.json routes the
    // user's Charm Hyper subscription, and a provider key there that is
    // actually a model id (observed: "qwen3.7-plus/…") is hyper's
    // internal routing alias, not a provider surface — detectCrush
    // folds such keys to `hyper` (the real identity rows already live
    // as crush-hyper-<model>). A provider rule mirrors a provider
    // SURFACE the user configures (minimax-code, deepseek-flash,
    // kimi-code, cline-pass): never mint provider rules whose name is a
    // model id.
    // openrouter: never/opt-in — a BYO-key aggregator gateway; it does
    // not host or train models on customer traffic by default (privacy
    // + terms). But its contributor-tier listings (e.g.
    // `meta/muse-spark-1.2-contributor`) DO train — reachable only by
    // selecting those models, so per the opt-in-by-model rule
    // (CONTRIBUTING) open_training is `opt-in`: the contributor tiers
    // observed are open-weight labs' models; closed_training stays
    // `never` absent a documented closed trainer.
    .{ .name = "openrouter", .label = "OpenRouter", .closed_training = "never", .open_training = "opt-in", .sources = &.{ "https://openrouter.ai/privacy", "https://openrouter.ai/terms" } },
    // opencode: null/null — opencode's first-party router (its built-in
    // free tier: `opencode/deepseek-v4-flash-free` etc.). As an
    // inference router it doesn't train on traffic, but the first-party
    // upstreams are varied; training-policy wording unverified, null.
    .{ .name = "opencode", .label = "OpenCode", .closed_training = null, .open_training = null, .sources = &.{"https://github.com/anomalyco/opencode"} },
    // opencode-go: opt-in/opt-in — OpenCode Zen's "Go" subscription
    // tier (base https://opencode.ai/zen/go/v1). Zen docs: "Our
    // providers follow a zero-retention policy and do not use your
    // data for model training" — but with named exceptions whose
    // free periods DO train (Big Pickle; MiMo-V2.5 Free). Per the
    // opt-in-by-model rule (CONTRIBUTING), training reachable only
    // by selecting specific models/tiers is `opt-in`, never `never`:
    // MiMo-V2.5 is open-weight (MIT) → open_training opt-in; Big
    // Pickle's openness is unverified → closed_training flips to
    // opt-in too, downgradable to never if a maintainer confirms it
    // open. opencode.ai/privacy and /terms return 404, so docs/zen
    // is the only policy doc. catalog (unauth, 33 ids, 2026-08-29)
    // recorded in fixtures/.providers_models.csv.
    .{ .name = "opencode-go", .label = "OpenCode Go", .closed_training = "opt-in", .open_training = "opt-in", .sources = &.{"https://opencode.ai/docs/zen"} },
    // groq: never/never — Groq is an inference-only LPU cloud; its
    // terms/privacy state customer data is not used for model training.
    .{ .name = "groq", .label = "Groq", .closed_training = "never", .open_training = "never", .sources = &.{ "https://groq.com/privacy", "https://groq.com/terms" } },
    // cerebras: never/never — Cerebras Inference is a hardware
    // inference cloud; customer prompts are not used for training.
    .{ .name = "cerebras", .label = "Cerebras", .closed_training = "never", .open_training = "never", .sources = &.{ "https://www.cerebras.ai/privacy-policy", "https://www.cerebras.ai/terms-of-service" } },
    // chutes: never/never — Chutes ToS states "We do not use your API
    // requests, responses, or application content to train AI models";
    // the privacy policy states public-API content is never logged,
    // stored, or persisted (zero content logging; TEE/E2E modes), and
    // app content "is not used for model training". Catalog: 14 TEE-
    // stamped models via GET https://llm.chutes.ai/v1/models
    // (unauthenticated, 2026-08-29) — full spellings in
    // fixtures/.providers_models.csv; non-evergreen ids
    // (Qwen/Qwen3-32B-TEE, Qwen/Qwen3.6-27B-TEE) intentionally
    // unruled.
    .{ .name = "chutes", .label = "Chutes", .closed_training = "never", .open_training = "never", .sources = &.{ "https://chutes.ai/privacy", "https://chutes.ai/tos" } },
    // zai: null/null — Z.ai (Zhipu AI) trains models itself (the GLM
    // family); API training-policy wording unverified, stays null.
    .{ .name = "zai", .label = "Z.ai", .closed_training = null, .open_training = null, .sources = &.{ "https://www.z.ai/terms-of-service", "https://www.z.ai/privacy-policy" } },
    // xai: null/null — xAI trains the Grok family itself; API
    // training-policy wording unverified, stays null (same source set
    // as the grok model rules).
    .{ .name = "xai", .label = "xAI", .closed_training = null, .open_training = null, .sources = &.{ "https://x.ai/grok", "https://docs.x.ai/docs/models" } },
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
    // zenmux: null/null — an aggregator/API gateway exposing many
    // upstreams (`provider/id` models, several `-free`); training-policy
    // wording unverified, stays null.
    .{ .name = "zenmux", .label = "ZenMux", .closed_training = null, .open_training = null, .sources = &.{"https://zenmux.ai/"} },
    // siliconflow: null/null — Baidu SiliconFlow hosts many open
    // open-weight models on a free/per-token tier; API policy unverified.
    .{ .name = "siliconflow", .label = "SiliconFlow", .closed_training = null, .open_training = null, .sources = &.{ "https://siliconflow.cn/", "https://docs.siliconflow.cn/" } },
    // sakana: null/null — Sakana AI trains the Fugu/Namazu families
    // (Japanese LLMs); API policy unverified, stays null.
    .{ .name = "sakana", .label = "Sakana AI", .closed_training = null, .open_training = null, .sources = &.{"https://sakana.ai/"} },
    // ollama-cloud: null/null — Ollama's cloud inference tier serving
    // many open-weight models (`deepseek-v3.2`, `glm-5.2`, ...);
    // policy unverified, stays null.
    .{ .name = "ollama-cloud", .label = "Ollama Cloud", .closed_training = null, .open_training = null, .sources = &.{"https://ollama.com/"} },
    // meta: null/null — Meta's hosted tier for its open-weight families
    // (Llama, Muse); policy unverified, stays null.
    .{ .name = "meta", .label = "Meta", .closed_training = null, .open_training = null, .sources = &.{"https://ai.meta.com/"} },
    // google-antigravity: null/null — Google Antigravity's hosted tier;
    // policy unverified, stays null.
    .{ .name = "google-antigravity", .label = "Google Antigravity", .closed_training = null, .open_training = null, .sources = &.{"https://antigravity.google/"} },
    // kimi-code: mirrors `kimi`/`moonshot` — the kimi-code CLI's own
    // provider key (`k3` models); same Moonshot upstream, unverified.
    .{ .name = "kimi-code", .label = "Kimi Code", .closed_training = null, .open_training = null, .sources = &.{ "https://platform.moonshot.ai/docs/terms", "https://platform.moonshot.ai/docs/privacy" } },
    // gmi-cloud: null/null — a multimodal gateway exposing many
    // upstreams at zero tracked cost; policy unverified, stays null.
    .{ .name = "gmi-cloud", .label = "GMI Cloud", .closed_training = null, .open_training = null, .sources = &.{"https://gmi.cloud/"} },
    // nanogpt: null/null — an aggregator exposing many open models
    // (zero tracked cost in omp's catalog); policy unverified.
    .{ .name = "nanogpt", .label = "NanoGPT", .closed_training = null, .open_training = null, .sources = &.{"https://nanogpt.ai/"} },
    // huggingface: null/null — HF Serverless Inference for open-weight
    // models (free tier); each model's weights are the real license.
    .{ .name = "huggingface", .label = "Hugging Face", .closed_training = null, .open_training = null, .sources = &.{"https://huggingface.co/docs/inference-providers"} },
    // cursor: null/null — Cursor's first-party model routing (flat
    // subscription, no per-call price tracked); policy unverified.
    .{ .name = "cursor", .label = "Cursor", .closed_training = null, .open_training = null, .sources = &.{"https://cursor.com/"} },
    // github-copilot: null/null — GitHub Copilot's model routing
    // (subscription-included, no per-call price tracked); unverified.
    .{ .name = "github-copilot", .label = "GitHub Copilot", .closed_training = null, .open_training = null, .sources = &.{"https://github.com/features/copilot"} },
    // alibaba: null/null — Alibaba's hosted Qwen/DashScope tier (the
    // `alibaba/...` provider key opencode/kilo catalogs use for the
    // qwen models; same upstream as `qwen`); policy unverified.
    .{ .name = "alibaba", .label = "Alibaba", .closed_training = null, .open_training = null, .sources = &.{ "https://qwen.ai/", "https://qwen.ai/legal" } },
    // openai: opt-in/opt-in — OpenAI's platform tier (also the provider
    // id for requesty-routed openai-compatible combos, e.g. qwen's
    // `router.requesty.ai` upstream). API inputs/outputs are not used
    // for training by default; customers may opt in for their API data
    // to be used (per OpenAI's data-usage policy).
    .{ .name = "openai", .label = "OpenAI", .closed_training = "opt-in", .open_training = "opt-in", .sources = &.{ "https://openai.com/policies/data-usage-policy/", "https://openai.com/policies/business-terms/" } },
    // fireworks-ai: never/never — Fireworks AI's hosted tier (the
    // `fireworks-ai/...` provider key kilo catalogs). Fireworks is an
    // inference-only cloud; its terms/privacy state customer prompts are
    // not used to train models.
    .{ .name = "fireworks-ai", .label = "Fireworks AI", .closed_training = "never", .open_training = "never", .sources = &.{ "https://fireworks.ai/privacy", "https://fireworks.ai/terms" } },
    // google: null/null — Google's Gemini platform tier (the `google`
    // provider key for Gemini CLI / gemini-api combos); policy unverified.
    .{ .name = "google", .label = "Google", .closed_training = null, .open_training = null, .sources = &.{ "https://ai.google.dev/gemini-api/terms", "https://ai.google.dev/gemini-api/docs" } },
    // kilo: null/null — the Kilo Code CLI's first-party router provider
    // (its `kilo/~*-latest` alias tier); an inference router, but the
    // first-party upstreams are varied, so policy stays unverified.
    .{ .name = "kilo", .label = "Kilo", .closed_training = null, .open_training = null, .sources = &.{"https://github.com/Kilo-Org/kilocode"} },
};

/// static metadata the rule declared to the matcher. Useful for auditing
/// when a rule misfires; not a runtime observation.
// Static rule metadata (the harness rule's declared binary names and
// env-marker names) lives in `rulesForHarnesses`; the runtime
// observation story is carried by `raw.env_vars` (matched env-var
// observations) and `raw.process_lineage` (process tree at detection
// time). The raw block intentionally does NOT duplicate that static
// data (see DESIGN.md "18-field canonical fixture contract").

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
    /// SPDX license keyword for the harness. Semantics per the license
    /// table in CONTRIBUTING.md "add a new harness rule":
    ///   - `null` — no data available (`.unknown`)
    ///   - `"NOASSERTION"` — attempted, inconclusive (`.unknown`)
    ///   - `"NONE"` — concluded: no license present (verified
    ///     proprietary/closed; `.not_reciprocal`)
    ///   - any real SPDX id (`"Apache-2.0"`, `"MIT"`, …) — open
    ///     license, drives the `harness_license` canonical field and
    ///     the `reciprocal` computation.
    license: ?[]const u8,
    /// Array of independent cross-references that informed the `license`
    /// value (URL 1 = project page; URL 2 = the actual LICENSE file
    /// linked from that page). Each URL is a distinct location with
    /// distinct content; neither is a variation of the other. Surfaced
    /// under `raw["harness-urls"]` so a maintainer can audit the
    /// deduction from multiple angles.
    license_sources: []const []const u8,
    env_markers: []const []const u8,
    binary_names: []const []const u8, // executable names for ancestry matching, probing, launching, and the daemon guard (bare stems first, then platform extensions)
    /// extra alias display-strings not covered by `name`/`label`/
    /// `short_title`; joins the normalized alias set — see the field
    /// doc on `ModelRule.variations`.
    variations: []const []const u8 = &.{},
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
const qwen_env = [_][]const u8{"QWEN_API_KEY"};
const kilo_env = [_][]const u8{ "KILO_API_KEY", "KILO", "KILO_MODEL" };
const omp_env = [_][]const u8{"OMP_API_KEY"};
const reasonix_env = [_][]const u8{"REASONIX_API_KEY"};
const crush_env = [_][]const u8{"CRUSH_API_KEY"};
const opencode_env = [_][]const u8{ "OPENCODE_API_KEY", "OPENCODE_MODEL" };
const vibe_env = [_][]const u8{ "VIBE_API_KEY", "VIBE_ACTIVE_MODEL", "VIBE_ACTIVE_PROVIDER" };
const cursor_env = [_][]const u8{ "CURSOR_API_KEY", "CURSOR_API_ENDPOINT", "CURSOR_MODEL" };
const copilot_env = [_][]const u8{ "COPILOT_ALLOW_ALL", "COPILOT_MODEL" };

pub const rulesForHarnesses = [_]HarnessRule{
    // cline: Apache-2.0 — https://github.com/cline/cline ships an
    // Apache-2.0 LICENSE (Cline Bot Inc.'s open-source VS Code /
    // JetBrains agent).
    .{ .name = "cline", .label = "Cline", .license = "Apache-2.0", .license_sources = &.{ "https://github.com/cline/cline", "https://github.com/cline/cline/blob/main/LICENSE" }, .env_markers = &cline_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cline", "cline.exe", "cline.cmd", "cline.ps1" }
    else
        &[_][]const u8{"cline"} },
    // goose: Apache-2.0 — upstream is https://github.com/block/goose
    // (aaif-goose/goose was a mirror); Apache-2.0 per the repo LICENSE
    // (Copyright Block, Inc.).
    .{ .name = "goose", .label = "Goose", .license = "Apache-2.0", .license_sources = &.{ "https://github.com/block/goose", "https://github.com/block/goose/blob/main/LICENSE" }, .env_markers = &goose_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "goose", "goose.exe", "goosed", "goosed.exe" }
    else
        &[_][]const u8{ "goose", "goosed" } },
    // kimi-code: MIT — https://github.com/MoonshotAI/kimi-code ships a
    // MIT LICENSE (Copyright Moonshot AI; the Kimi Code CLI).
    .{ .name = "kimi-code", .label = "Kimi Code", .license = "MIT", .license_sources = &.{ "https://github.com/MoonshotAI/kimi-code", "https://github.com/MoonshotAI/kimi-code/blob/main/LICENSE" }, .env_markers = &kimi_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "kimi", "kimi-code", "kimi.exe", "kimi-code.exe" }
    else
        &[_][]const u8{ "kimi", "kimi-code" } },
    // mmx: MIT — https://github.com/MiniMax-AI/cli (npm `mmx-cli`)
    // declares MIT via its README badge + npm page; the repo has no
    // LICENSE file committed yet, so the npm page is the second
    // cross-reference rather than a LICENSE blob.
    .{ .name = "mmx", .label = "MiniMax CLI", .license = "MIT", .license_sources = &.{ "https://github.com/MiniMax-AI/cli", "https://www.npmjs.com/package/mmx-cli" }, .env_markers = &mmx_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "mmx", "mmx.exe", "mmx.cmd", "mmx.ps1" }
    else
        &[_][]const u8{"mmx"} },
    // pi: MIT — https://github.com/earendil-works/pi ships a MIT
    // LICENSE (Copyright Mario Zechner; the Rust terminal coding agent).
    .{ .name = "pi", .label = "Pi", .license = "MIT", .license_sources = &.{ "https://github.com/earendil-works/pi", "https://github.com/earendil-works/pi/blob/main/LICENSE" }, .env_markers = &pi_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "pi", "pi.exe" }
    else
        &[_][]const u8{"pi"} },
    // qwen: Apache-2.0 — https://github.com/QwenLM/qwen-code (the Qwen
    // Code CLI, formerly Apollo) ships an Apache-2.0 LICENSE.
    .{ .name = "qwen", .label = "Qwen Code", .license = "Apache-2.0", .license_sources = &.{ "https://github.com/QwenLM/qwen-code", "https://github.com/QwenLM/qwen-code/blob/main/LICENSE" }, .env_markers = &qwen_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "qwen", "qwen.exe", "qwen.cmd", "qwen.ps1" }
    else
        &[_][]const u8{"qwen"} },
    // kilo: MIT — https://github.com/Kilo-Org/kilocode ships a MIT
    // LICENSE (Kilo Code CLI).
    .{ .name = "kilo", .label = "Kilo Code", .short_title = "Kilo", .license = "MIT", .license_sources = &.{ "https://github.com/Kilo-Org/kilocode", "https://github.com/Kilo-Org/kilocode/blob/main/LICENSE" }, .env_markers = &kilo_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "kilo", "kilo.exe", "kilo.cmd", "kilo.ps1" }
    else
        &[_][]const u8{"kilo"}, .variations = &.{"Kilo Code CLI"} },
    // omp: MIT — https://github.com/can1357/oh-my-pi (omp is the CLI
    // distribution name of oh-my-pi) ships a MIT LICENSE; verified
    // from the repo's license badge and the LICENSE file linked from it.
    .{ .name = "omp", .label = "omp", .license = "MIT", .license_sources = &.{ "https://github.com/can1357/oh-my-pi", "https://github.com/can1357/oh-my-pi/blob/main/LICENSE" }, .env_markers = &omp_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "omp", "omp.exe" }
    else
        &[_][]const u8{"omp"} },
    // reasonix: MIT — https://github.com/esengine/DeepSeek-Reasonix
    // ships a MIT LICENSE (default branch `main-v2`); verified from
    // the repo's license badge and the LICENSE file linked from it.
    .{ .name = "reasonix", .label = "Reasonix", .license = "MIT", .license_sources = &.{ "https://github.com/esengine/DeepSeek-Reasonix", "https://github.com/esengine/DeepSeek-Reasonix/blob/main-v2/LICENSE" }, .env_markers = &reasonix_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "reasonix", "reasonix.exe" }
    else
        &[_][]const u8{"reasonix"} },
    // crush: FSL-1.1-MIT (Functional Source License) —
    // https://github.com/charmbracelet/crush links its LICENSE.md from
    // the README's License section; that is the upstream SPDX id.
    // Not OSI-approved open source, but the license id is non-null, so
    // `reciprocal` is governed by the model/provider conjuncts rather
    // than being force-closed by the harness side.
    .{ .name = "crush", .label = "Crush", .license = "FSL-1.1-MIT", .license_sources = &.{ "https://github.com/charmbracelet/crush", "https://github.com/charmbracelet/crush/blob/main/LICENSE.md" }, .env_markers = &crush_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "crush", "crush.exe" }
    else
        &[_][]const u8{"crush"} },
    // opencode: MIT — https://github.com/anomalyco/opencode (formerly
    // sst/opencode) ships a MIT LICENSE; default branch is `dev`, so
    // the LICENSE blob URL is branch-qualified.
    .{ .name = "opencode", .label = "OpenCode", .license = "MIT", .license_sources = &.{ "https://github.com/anomalyco/opencode", "https://github.com/anomalyco/opencode/blob/dev/LICENSE" }, .env_markers = &opencode_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "opencode", "opencode.exe" }
    else
        &[_][]const u8{"opencode"} },
    // vibe: Apache-2.0 — https://github.com/mistralai/mistral-vibe ships
    // an Apache-2.0 LICENSE (the Vibe CLI for Mistral models).
    .{ .name = "vibe", .label = "Vibe", .license = "Apache-2.0", .license_sources = &.{ "https://github.com/mistralai/mistral-vibe", "https://github.com/mistralai/mistral-vibe/blob/main/LICENSE" }, .env_markers = &vibe_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "vibe", "vibe.exe" }
    else
        &[_][]const u8{"vibe"} },
    // cursor: NONE — the Cursor Agent CLI (cursor-agent, brew
    // `cursor-cli`) is closed-source; verified from the project page
    // and its Terms of Service (no open license), so `license` is
    // `"NONE"` (concluded no-license), not null.
    .{ .name = "cursor", .label = "Cursor", .license = "NONE", .license_sources = &.{ "https://cursor.com/", "https://www.cursor.com/en-US/terms-of-service" }, .env_markers = &cursor_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cursor-agent", "cursor-agent.exe", "cursor-agent.cmd", "cursor-agent.ps1" }
    else
        &[_][]const u8{"cursor-agent"} },
    // copilot: NONE — the GitHub Copilot CLI (brew `copilot-cli`) is
    // closed-source; verified from the feature page and the GitHub
    // Terms of Service (no open license), so `license` is `"NONE"`.
    .{ .name = "copilot", .label = "GitHub Copilot CLI", .license = "NONE", .license_sources = &.{ "https://github.com/features/copilot", "https://docs.github.com/en/site-policy/github-terms/github-terms-of-service" }, .env_markers = &copilot_env, .binary_names = if (builtin.os.tag == .windows)
        &[_][]const u8{ "copilot", "copilot.exe" }
    else
        &[_][]const u8{"copilot"} },
};

/// env-var names whose values are safe to emit in raw.env_vars. Names NOT
/// on this list emit an empty string for the value slot — secrets like
/// `KIMI_API_KEY` and `MINIMAX_API_KEY` are redacted by default. Maintainers
/// add names here when they have decided the value is safe to write to disk.
const env_value_allowlist = [_][]const u8{
    "CLINE_BUILD_ENV",         "CLINE_NO_INTERACTIVE",       "CLINE_WRAPPER_PATH",
    "CLINE_RUN_AS_HUB_DAEMON", "CLINE_CONNECTOR_CLI_LAUNCH", "KIMI_CODE_HOME",
    "MMX_CONFIG_DIR",          "PI_CODING_AGENT",
    // launcher-provided model selectors — the values are model ids /
    // provider ids, not secrets, so fixtures can carry the exact value
    // the detector read (evidence-claim value matching needs it).
               "KILO_MODEL",
    "OPENCODE_MODEL",          "VIBE_ACTIVE_MODEL",          "VIBE_ACTIVE_PROVIDER",
    "PI_PROVIDER",             "PI_MODEL",                   "CURSOR_MODEL",
    "COPILOT_MODEL",           "GOOSE_WORKING_DIR",          "GOOSE_TERMINAL",
    "GOOSE_MODE",              "USERPROFILE",                "HOME",
    "APPDATA",
};

pub fn envValueAllowed(name: []const u8) bool {
    for (env_value_allowlist) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

/// SPDX license keywords with special reciprocity semantics (see the
/// license table in CONTRIBUTING.md "add a new harness rule"):
///   - `"NONE"` — concluded: no license present (verified
///     proprietary/closed). Forces `.not_reciprocal` even when the
///     model/provider dims are null.
///   - `"NOASSERTION"` — attempted, inconclusive. Treated like `null`
///     (`.unknown`).
pub const license_none = "NONE";
pub const license_noassertion = "NOASSERTION";

/// capitalize the first letter of each dash-separated token, join with spaces
pub fn titleCase(a: std.mem.Allocator, slug: []const u8) ![]u8 {
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

pub const ModelOut = struct {
    label: []const u8,
    short_title: ?[]const u8 = null,
    reciprocity: ?[]const u8,
    license: ?[]const u8 = null,
    sources: []const []const u8 = &.{},
};

pub fn modelForName(a: std.mem.Allocator, name: []const u8) !ModelOut {
    for (rulesForModels) |r| {
        if (std.mem.eql(u8, r.name, name))
            return .{ .label = r.label, .short_title = r.short_title, .reciprocity = r.reciprocity, .license = r.license, .sources = r.sources };
    }
    // family-prefix fallbacks for fixtures open-weight families
    const families = [_][]const u8{ "kimi", "glm", "minimax" };
    for (families) |fam| {
        if (std.mem.startsWith(u8, name, fam))
            return .{ .label = try titleCase(a, name), .reciprocity = "open-weight" };
    }
    return .{ .label = try titleCase(a, name), .reciprocity = null };
}

pub fn providerForName(name: []const u8) ?[]const u8 {
    return (providerMetaForName(name) orelse return null).label;
}

pub fn providerMetaForName(name: []const u8) ?ProviderRule {
    for (rulesForProviders) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// map an openai-compatible `base_url` host back to the canonical
/// provider id. Used by `detectQwen` to resolve the upstream service
/// behind qwen's `modelProviders[].baseUrl`. Unknown hosts
/// fall back to "minimax" (the well-fixtures endpoint).
pub fn providerForBaseUrl(base_url: []const u8) []const u8 {
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
        .{ "x.ai", "xai" },
        .{ "requesty.ai", "openai" },
        .{ "openai.com", "openai" },
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
pub fn harnessRuleForName(name: []const u8) ?HarnessRule {
    for (rulesForHarnesses) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// look up a model rule by its canonical `name` id, or null when the
/// id isn't in the model registry. The recipe-resolution path uses this
/// instead of re-scanning the table inline.
pub fn modelRuleForName(name: []const u8) ?ModelRule {
    for (rulesForModels) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// resolve the harness rule a recipe's `agent_id` maps to. The first
/// `-`-separated segment is the harness dim in strict-slug form (e.g.
/// "kimicode"); `canonicalIdFor`'s name/label normalization resolves it
/// against the harness registry (so `kimicode` hits the `kimi-code`
/// rule). Unknown segment -> null — callers treat it as unavailable and
/// take the existing invalid/skip paths.
pub fn harnessRuleForFixtureId(a: std.mem.Allocator, agent_id: []const u8) ?HarnessRule {
    const dash = std.mem.indexOfScalar(u8, agent_id, '-') orelse return null;
    const segment = agent_id[0..dash];
    const name = canonicalIdFor(a, HarnessRule, &rulesForHarnesses, segment) orelse return null;
    return harnessRuleForName(name);
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

/// does the strict slug (lowercase + non-alphanumerics stripped,
/// whole-string) of `display` equal `slug`? `slug` is a value produced
/// by `slugId`; this is the allocation-free comparison half of the same
/// normalization, used to match rule aliases against a pre-normalized
/// CLI input.
pub fn slugEquals(display: []const u8, slug: []const u8) bool {
    var i: usize = 0;
    for (display) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (i >= slug.len) return false;
        if (std.ascii.toLower(c) != slug[i]) return false;
        i += 1;
    }
    return i == slug.len;
}

/// resolve a CLI-provided harness / provider / model id to its
/// canonical rule `name`. Exact canonical-name equality takes
/// precedence (so `cline` resolves to `cline`, never aliasing into
/// `cline-pass`); otherwise `input` is normalized via `slugId`
/// (lowercase + strip non-alphanumeric, whole-string) and the first
/// rule in array order whose normalized alias set — canonical `name`,
/// `label`, `short_title` (if present), and each explicit `variations`
/// entry — contains it wins. Deterministic first-rule-in-array-order;
/// the alias-uniqueness test guards against a slug matching two rules.
/// Returns `null` when nothing matches (the caller decides: exit 7 in
/// recipe mode, raw pass-through in the fixtures seed path).
/// Empty/whitespace-only input normalizes to the empty slug and never
/// matches. Non-ASCII characters strip out via `std.ascii` (lossy — an
/// input whose remaining ASCII slug matches a rule still resolves).
pub fn canonicalIdFor(a: std.mem.Allocator, comptime Rules: type, rules: []const Rules, input: []const u8) ?[]const u8 {
    for (rules) |r| {
        if (std.mem.eql(u8, r.name, input)) return r.name;
    }
    const slug = slugId(a, input) catch return null;
    defer a.free(slug);
    if (slug.len == 0) return null;
    for (rules) |r| {
        if (slugEquals(r.name, slug)) return r.name;
        if (slugEquals(r.label, slug)) return r.name;
        if (r.short_title) |st| {
            if (slugEquals(st, slug)) return r.name;
        }
        for (r.variations) |v| {
            if (slugEquals(v, slug)) return r.name;
        }
    }
    return null;
}

/// canonicalize a h/p/m filter dim to the strict-slug id of the rule it
/// resolves to (`slugId` of the canonical `name`) — the exact form the
/// fixtures queue/fixtures store rows use for their dim columns. Returns
/// null when the dim doesn't resolve to a known rule (the fixtures seed
/// path passes unknown dims through raw).
pub fn canonicalFilterDim(a: std.mem.Allocator, comptime Rules: type, rules: []const Rules, dim: []const u8) ?[]const u8 {
    const name = canonicalIdFor(a, Rules, rules, dim) orelse return null;
    return slugId(a, name) catch null;
}
