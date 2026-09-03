// Exit-status / policy-semantics tests for the released binary's core
// logic: the tri-state `reciprocityOf` determination (incl. the
// `"NONE"` / `"NOASSERTION"` license keywords, decision #1), the
// `buildTrailerLine` trailer strings, and the `scanVersionToken`
// `--version` format coverage (decision #6).

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

test "reciprocityOf: null license → unknown" {
    var d = main.Detection{};
    try testing.expect(main.reciprocityOf(&d) == .unknown);
}

test "reciprocityOf: NOASSERTION → unknown" {
    var d = main.Detection{ .harness_license = "NOASSERTION" };
    try testing.expect(main.reciprocityOf(&d) == .unknown);
}

test "reciprocityOf: NONE forces not_reciprocal even with null dims" {
    // A verified closed harness is never reciprocal, regardless of the
    // model/provider dims being unverified.
    var d = main.Detection{ .harness_license = "NONE" };
    try testing.expect(main.reciprocityOf(&d) == .not_reciprocal);
}

test "reciprocityOf: NONE + open dims still not_reciprocal" {
    var d = main.Detection{
        .harness_license = "NONE",
        .model_reciprocity = "open-weight",
        .provider_closed_training = "never",
    };
    try testing.expect(main.reciprocityOf(&d) == .not_reciprocal);
}

test "reciprocityOf: SPDX + open-weight + opt-in → reciprocal" {
    var d = main.Detection{
        .harness_license = "MIT",
        .model_reciprocity = "open-weight",
        .provider_closed_training = "opt-in",
    };
    try testing.expect(main.reciprocityOf(&d) == .reciprocal);
}

test "reciprocityOf: closed model → not_reciprocal" {
    var d = main.Detection{
        .harness_license = "MIT",
        .model_reciprocity = "closed",
        .provider_closed_training = "never",
    };
    try testing.expect(main.reciprocityOf(&d) == .not_reciprocal);
}

test "reciprocityOf: enforced provider → not_reciprocal" {
    var d = main.Detection{
        .harness_license = "Apache-2.0",
        .model_reciprocity = "open-source",
        .provider_closed_training = "enforced",
    };
    try testing.expect(main.reciprocityOf(&d) == .not_reciprocal);
}

test "buildTrailerLine: exact Co-authored-by string" {
    var d = main.Detection{
        .harness_label = "Cline",
        .model_label = "Kimi K3",
        .agent_id = "cline-clinepass-kimik3",
    };
    const line = (try main.buildTrailerLine(testing.allocator, &d, "Co-authored-by")).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("Co-authored-by: Cline · Kimi K3 <cline-clinepass-kimik3@local>", line);
}

test "buildTrailerLine: exact Assisted-by string" {
    var d = main.Detection{
        .harness_label = "Cursor",
        .model_label = "GPT-5.2",
        .agent_id = "cursor-cursor-gpt52",
    };
    const line = (try main.buildTrailerLine(testing.allocator, &d, "Assisted-by")).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("Assisted-by: Cursor · GPT-5.2 <cursor-cursor-gpt52@local>", line);
}

test "buildTrailerLine: null on missing identity" {
    var d = main.Detection{ .harness_label = "Cline" };
    try testing.expect((try main.buildTrailerLine(testing.allocator, &d, "Co-authored-by")) == null);
    var d2 = main.Detection{ .model_label = "Kimi K3" };
    try testing.expect((try main.buildTrailerLine(testing.allocator, &d2, "Assisted-by")) == null);
}

test "scanVersionToken: bare semver" {
    try testing.expectEqualStrings("3.0.52", main.dev.scanVersionToken("3.0.52\n").?);
}

test "scanVersionToken: leading whitespace" {
    try testing.expectEqualStrings("1.45.0", main.dev.scanVersionToken(" 1.45.0\n").?);
}

test "scanVersionToken: label-prefixed" {
    try testing.expectEqualStrings("1.0.19", main.dev.scanVersionToken("mmx 1.0.19\n").?);
}

test "scanVersionToken: slash-separated" {
    try testing.expectEqualStrings("17.2.11", main.dev.scanVersionToken("omp/17.2.11\n").?);
}

test "scanVersionToken: v-prefixed after word" {
    try testing.expectEqualStrings("1.23.0", main.dev.scanVersionToken("reasonix v1.23.0\n").?);
}

test "scanVersionToken: version-word + v-prefixed" {
    try testing.expectEqualStrings("0.88.1", main.dev.scanVersionToken("crush version v0.88.1\n").?);
}

test "scanVersionToken: calver + hash" {
    try testing.expectEqualStrings("2026.08.04-aaa8809", main.dev.scanVersionToken("2026.08.04-aaa8809\n").?);
}

test "scanVersionToken: multi-line with trailing prose" {
    try testing.expectEqualStrings("1.0.79", main.dev.scanVersionToken("GitHub Copilot CLI 1.0.79.\nRun 'copilot update' to check for updates.\n").?);
}

test "scanVersionToken: pre-release suffix" {
    try testing.expectEqualStrings("1.2.3-beta.1", main.dev.scanVersionToken("1.2.3-beta.1\n").?);
}

test "scanVersionToken: null on no dotted version" {
    try testing.expect(main.dev.scanVersionToken("no version here\n") == null);
    try testing.expect(main.dev.scanVersionToken("2026-08-11\n") == null);
}

// ============================================================================
// alias / case-variation resolution for --harness=/--provider=/--model=
// ============================================================================

const HarnessRule = main.HarnessRule;
const ProviderRule = @TypeOf(main.rulesForProviders[0]);
const ModelRule = @TypeOf(main.rulesForModels[0]);

/// register `slug` against the per-table map, failing if a different
/// rule already claimed it. Returns the map entry's owner rule name.
fn registerSlug(map: *std.StringHashMap([]const u8), r: anytype, slug: []const u8) !void {
    const gop = try map.getOrPut(slug);
    if (gop.found_existing) {
        try testing.expectEqualStrings(gop.value_ptr.*, r.name);
    } else {
        gop.value_ptr.* = r.name;
    }
}

fn checkTableAliasUniqueness(a: std.mem.Allocator, rules: anytype) !void {
    // slug -> rule name it resolves to (first rule in array order wins)
    var map = std.StringHashMap([]const u8).init(a);
    defer map.deinit();
    for (rules) |r| {
        // base surfaces: name + label (+ short_title). Their slugs may
        // naturally coincide within one rule (short ids where name ==
        // label, e.g. `omp`/`omp`); that is harmless because both map
        // to the same rule.
        var base = std.StringHashMap(void).init(a);
        defer base.deinit();
        for ([_][]const u8{ r.name, r.label }) |d| {
            try base.put(try main.slugId(a, d), {});
        }
        if (r.short_title) |st| {
            try base.put(try main.slugId(a, st), {});
        }
        // a variation must not duplicate an existing alias surface or
        // another variation of the same rule (a pointless variation is
        // a data smell the test should catch).
        var seen_variation = std.StringHashMap(void).init(a);
        defer seen_variation.deinit();
        for (r.variations) |v| {
            const slug = try main.slugId(a, v);
            try testing.expect(base.get(slug) == null);
            try testing.expect(seen_variation.get(slug) == null);
            try seen_variation.put(slug, {});
        }
        // cross-rule uniqueness over the full alias set: a slug claimed
        // by two different rules would make the deterministic resolver
        // silently pick the wrong one.
        for ([_][]const u8{ r.name, r.label }) |d| {
            try registerSlug(&map, r, try main.slugId(a, d));
        }
        if (r.short_title) |st| {
            try registerSlug(&map, r, try main.slugId(a, st));
        }
        for (r.variations) |v| {
            try registerSlug(&map, r, try main.slugId(a, v));
        }
    }
}

test "alias sets: no normalized slug maps to two rules within a table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try checkTableAliasUniqueness(a, &main.rulesForHarnesses);
    try checkTableAliasUniqueness(a, &main.rulesForProviders);
    try checkTableAliasUniqueness(a, &main.rulesForModels);
}

test "canonicalIdFor: harness kilo resolves every alias form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forms = [_][]const u8{ "kilo", "kilo-code", "Kilo Code", "Kilo Code CLI", "KILO", "kilocode" };
    for (forms) |f| {
        const got = main.canonicalIdFor(a, HarnessRule, &main.rulesForHarnesses, f) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("kilo", got);
    }
}

test "canonicalIdFor: cline stays cline; cline-pass wins its aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = main.canonicalIdFor(a, ProviderRule, &main.rulesForProviders, "cline") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("cline", got);
    const pass_forms = [_][]const u8{ "clinepass", "cline-pass", "Cline Pass", "CLINE_PASS" };
    for (pass_forms) |f| {
        const g2 = main.canonicalIdFor(a, ProviderRule, &main.rulesForProviders, f) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("cline-pass", g2);
    }
}

test "canonicalIdFor: minimax-m3 aliases; deepseek-v4-flash free tier folds to the model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m3_forms = [_][]const u8{ "minimax-m3", "MiniMax M3", "minimaxm3", "M3" };
    for (m3_forms) |f| {
        const got = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, f) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("minimax-m3", got);
    }
    const got = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "deepseek-v4-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-v4-flash", got);
    const got2 = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "DeepSeek V4 Flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-v4-flash", got2);
    // the free-tier alias is a serving spelling of the same weights —
    // folded into the model rule as a variation (2026-08-29, option B
    // of .plans/1787978000867-retroactive-folding-options.md)
    const got3 = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "deepseek-v4-flash-free") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-v4-flash", got3);
    const got4 = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "deepseekv4flashfree") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-v4-flash", got4);
    // the folded zai- spelling resolves to the canonical glm-4.7 rule
    const got5 = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "zai-glm-4.7") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("glm-4.7", got5);
}

test "canonicalIdFor: empty/unknown input resolves null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(main.canonicalIdFor(a, HarnessRule, &main.rulesForHarnesses, "") == null);
    try testing.expect(main.canonicalIdFor(a, HarnessRule, &main.rulesForHarnesses, "   ") == null);
    try testing.expect(main.canonicalIdFor(a, HarnessRule, &main.rulesForHarnesses, "devin") == null);
    // non-ASCII chars strip out (std.ascii), so an all-non-ASCII input
    // normalizes to the empty slug and never matches...
    try testing.expect(main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "ΩΩΩ") == null);
    // ...while a non-ASCII input whose ASCII remainder matches a rule
    // still resolves (the strip is lossy, documented behavior).
    const got = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "M3Ω") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("minimax-m3", got);
}

test "modelFromMessageData: assistant flat form resolves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = "{\"role\":\"assistant\",\"agent\":\"code\",\"modelID\":\"deepseek-v4-flash\",\"providerID\":\"deepseek\"}";
    const mm = (try main.modelFromMessageData(a, data)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-v4-flash", mm.model_full);
    try testing.expectEqualStrings("deepseek", mm.provider_id);
}

test "modelFromMessageData: user nested form resolves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = "{\"role\":\"user\",\"agent\":\"code\",\"model\":{\"providerID\":\"deepseek\",\"modelID\":\"deepseek-v4-flash\",\"variant\":\"high\"}}";
    const mm = (try main.modelFromMessageData(a, data)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-v4-flash", mm.model_full);
    try testing.expectEqualStrings("deepseek", mm.provider_id);
}

test "modelFromMessageData: no model info resolves null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = "{\"role\":\"assistant\",\"agent\":\"code\"}";
    try testing.expect((try main.modelFromMessageData(a, data)) == null);
}

test "modelFromSessionRow: id + providerID resolve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const model = "{\"id\":\"deepseek-v4-flash-0731\",\"providerID\":\"hyper\"}";
    const mm = (try main.modelFromSessionRow(a, model)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-v4-flash-0731", mm.model_full);
    try testing.expectEqualStrings("hyper", mm.provider_id);
}

// ============================================================================
// provider-served id folding (chutes TEE stamps, endpoint/tier spellings)
// ============================================================================

test "canonicalIdFor: qwen3.8-27b aliases incl. chutes TEE forms; max stays distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forms = [_][]const u8{
        "qwen3.8-27b", "Qwen3.8 27B", "qwen3827b",
        "Qwen3.8-27B-TEE", "qwen3.8-27b-tee", "QWEN3.8-27B-TEE",
        "Qwen/Qwen3.8-27B-TEE",
    };
    for (forms) |f| {
        const got = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, f) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("qwen3.8-27b", got);
    }
    // the closed flagship is never folded into the open size rule
    const max = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "qwen3.8-max") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("qwen3.8-max", max);
}

test "canonicalIdFor: providers chutes and opencode-go resolve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "chutes", "Chutes", "CHUTES" }) |f| {
        const got = main.canonicalIdFor(a, ProviderRule, &main.rulesForProviders, f) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("chutes", got);
    }
    for ([_][]const u8{ "opencode-go", "OpenCode Go", "opencodego" }) |f| {
        const got = main.canonicalIdFor(a, ProviderRule, &main.rulesForProviders, f) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("opencode-go", got);
    }
    // whole-string slugs: `opencode` never resolves to `opencode-go`
    const oc = main.canonicalIdFor(a, ProviderRule, &main.rulesForProviders, "opencode") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("opencode", oc);
}

test "canonicalIdFor: catalog spellings fold to their canonical rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folds = [_][2][]const u8{
        .{ "Kimi-K3-TEE", "kimi-k3" },
        .{ "moonshotai/Kimi-K3-TEE", "kimi-k3" },
        .{ "zai-org/GLM-5.2-TEE", "glm-5.2" },
        .{ "GLM-5.1-TEE", "glm-5.1" },
        .{ "deepseek-ai/DeepSeek-V4-Flash-0731-TEE", "deepseek-v4-flash" },
        .{ "deepseek-v4-flash-vision-exp", "deepseek-v4-flash" },
        // release-date stamps (MMDD, appended by DeepSeek and Qwen) are
        // variations of the undated model, never their own rule:
        // `:`-separated on ollama-cloud, `-` in the kilo/opencode
        // session stores, and org-namespaced in the catalogs. The
        // strict slug makes the `:` and `-` spellings one alias.
        .{ "deepseek-v4-flash:0731", "deepseek-v4-flash" },
        .{ "deepseek-v4-flash-0731", "deepseek-v4-flash" },
        .{ "deepseekv4flash0731", "deepseek-v4-flash" },
        .{ "deepseek-ai/DeepSeek-V4-Flash-0731", "deepseek-v4-flash" },
        .{ "siliconflow/deepseek-ai/DeepSeek-V4-Flash-0731", "deepseek-v4-flash" },
        .{ "deepseek/deepseek-v4-pro-0813", "deepseek-v4-pro" },
        .{ "deepseek-v4-pro:0813", "deepseek-v4-pro" },
        .{ "deepseek-ai/DeepSeek-V4-Pro-0813", "deepseek-v4-pro" },
        // 2407 is part of Mistral Nemo's official HF name, not a stamp
        // on an undated sibling — it stays in the canonical id.
        .{ "unsloth/Mistral-Nemo-Instruct-2407", "mistral-nemo-instruct-2407" },
        .{ "qwen/qwen3-235b-a22b-2507", "qwen3-235b-a22b" },
        .{ "Qwen/Qwen3-235B-A22B-Instruct-2507", "qwen3-235b-a22b" },
        .{ "Qwen/Qwen3-235B-A22B-Thinking-2507-TEE", "qwen3-235b-a22b" },
        .{ "Qwen/Qwen3.5-397B-A17B-TEE", "qwen3.5-397b-a17b" },
        .{ "google/gemma-4-31B-turbo-TEE", "gemma-4-31b" },
        .{ "unsloth/Mistral-Nemo-Instruct-2407-TEE", "mistral-nemo-instruct-2407" },
        .{ "Nemotron-3-Nano-Omni-30B-TEE", "nemotron-3-nano-omni" },
        .{ "muse-spark-1.2-contributor", "muse-spark-1.2" },
        .{ "qwen3.8-flash", "qwen3.8-flash" },
        .{ "Qwen3.8 Flash", "qwen3.8-flash" },
    };
    for (folds) |pair| {
        const got = main.canonicalIdFor(a, ModelRule, &main.rulesForModels, pair[0]) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(pair[1], got);
    }
}

test "canonicalIdFor: unobserved tee ids stay null (never-guess)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "foo-tee") == null);
    try testing.expect(main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "Qwen3.9-27B-TEE") == null);
    try testing.expect(main.canonicalIdFor(a, ModelRule, &main.rulesForModels, "qwen3.8-2.4t-a95b-tee") == null);
}

test "applyModel: chutes TEE-stamped id folds to the canonical model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // kimi-code's `default_model` = "chutes/Qwen/Qwen3.8-27B-TEE":
    // detectKimi strips the first segment before calling applyModel.
    var d = main.Detection{};
    try main.applyModel(a, &d, "Qwen/Qwen3.8-27B-TEE", "chutes/Qwen/Qwen3.8-27B-TEE");
    try testing.expectEqualStrings("qwen3.8-27b", d.model_name.?);
    try testing.expectEqualStrings("Qwen3.8 27B", d.model_label.?);
    try testing.expectEqualStrings("qwen3827b", d.model_id.?);
    try testing.expectEqualStrings("open-weight", d.model_reciprocity.?);
    try testing.expectEqualStrings("Apache-2.0", d.model_license.?);
    // a detector that passes the full 3-segment id unstripped folds
    // through the namespaced variation.
    var d2 = main.Detection{};
    try main.applyModel(a, &d2, "chutes/Qwen/Qwen3.8-27B-TEE", "chutes/Qwen/Qwen3.8-27B-TEE");
    try testing.expectEqualStrings("qwen3.8-27b", d2.model_name.?);
    try testing.expectEqualStrings("qwen3827b", d2.model_id.?);
}

test "applyModel: unknown id keeps raw passthrough (never-guess)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = main.Detection{};
    try main.applyModel(a, &d, "foo-tee", "foo/foo-tee");
    try testing.expectEqualStrings("foo-tee", d.model_name.?);
    try testing.expectEqualStrings("Foo Tee", d.model_label.?);
    try testing.expectEqualStrings("footee", d.model_id.?);
    try testing.expect(d.model_reciprocity == null);
    try testing.expect(d.model_license == null);
}

test "buildTrailerLine: kimi-code chutes and opencode-go combos" {
    var d = main.Detection{
        .harness_label = "Kimi Code",
        .model_label = "Qwen3.8 27B",
        .agent_id = "kimicode-chutes-qwen3827b",
    };
    const line = (try main.buildTrailerLine(testing.allocator, &d, "Co-authored-by")).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("Co-authored-by: Kimi Code · Qwen3.8 27B <kimicode-chutes-qwen3827b@local>", line);
    var d2 = main.Detection{
        .harness_label = "Kimi Code",
        .model_label = "Qwen3.8 Flash",
        .agent_id = "kimicode-opencodego-qwen38flash",
    };
    const line2 = (try main.buildTrailerLine(testing.allocator, &d2, "Assisted-by")).?;
    defer testing.allocator.free(line2);
    try testing.expectEqualStrings("Assisted-by: Kimi Code · Qwen3.8 Flash <kimicode-opencodego-qwen38flash@local>", line2);
}
