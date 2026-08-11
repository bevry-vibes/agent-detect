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
