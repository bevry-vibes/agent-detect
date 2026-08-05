const std = @import("std");
const testing = std.testing;
const root = @import("main.zig");

test "model: Kimi K3 (no suffix) unchanged" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Kimi K3", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Kimi K3", result);
    try testing.expectEqual(@as(u8, 0), summary.iterations);
}

test "model: GLM 5.2 unchanged" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "GLM 5.2", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("GLM 5.2", result);
    try testing.expectEqual(@as(u8, 0), summary.iterations);
}

test "model: MiniMax-M3 unchanged (no space-separated suffix)" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "MiniMax-M3", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("MiniMax-M3", result);
    try testing.expectEqual(@as(u8, 0), summary.iterations);
}

test "model: Qwen3.8-Max unchanged (hyphen, but no suffix word after)" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Qwen3.8-Max", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Qwen3.8-Max", result);
    try testing.expectEqual(@as(u8, 0), summary.iterations);
}

test "model: hypothetical Kimi K4 Preview strips to Kimi K4" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Kimi K4 Preview", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Kimi K4", result);
    // trailing whitespace cleanup does not count as a suffix iteration;
    // only the "Preview" strip is counted.
    try testing.expectEqual(@as(u8, 1), summary.iterations);
    try testing.expectEqualStrings("Preview", summary.stripped_suffix.?);
}

test "model: hypothetical GLM 5.3 RC strips to GLM 5.3" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "GLM 5.3 RC", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("GLM 5.3", result);
}

test "model: hypothetical GLM 5.3 Beta strips to GLM 5.3" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "GLM 5.3 Beta", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("GLM 5.3", result);
}

test "model: recursive Kimi K3 Preview Beta -> Kimi K3" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Kimi K3 Preview Beta", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Kimi K3", result);
    // two suffix strips (Beta then Preview); trailing-whitespace cleanup
    // is bookkeeping only and is not counted in `iterations`.
    try testing.expectEqual(@as(u8, 2), summary.iterations);
    // summary.stripped_suffix records the LAST suffix that fired — for a
    // multi-tag display that's the inner one, which in this input is
    // "Preview" (Beta was stripped on the first pass, Preview on the second).
    try testing.expectEqualStrings("Preview", summary.stripped_suffix.?);
}

test "model: hyphen separator Kimi-K3 stays as-is (no suffix word after dash)" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Kimi-K3", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Kimi-K3", result);
    try testing.expectEqual(@as(u8, 0), summary.iterations);
}

test "model: mid-string Preview-Kimi not matched" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Preview-Kimi", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Preview-Kimi", result);
    try testing.expectEqual(@as(u8, 0), summary.iterations);
}

test "model: lowercase 'preview' not matched (case-sensitive)" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "preview", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("preview", result);
}
