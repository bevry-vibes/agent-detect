const std = @import("std");
const testing = std.testing;
const root = @import("main.zig");

test "harness: Kimi Code CLI strips to Kimi Code" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Kimi Code CLI", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Kimi Code", result);
    try testing.expectEqual(@as(u8, 1), summary.iterations);
    try testing.expectEqualStrings("CLI", summary.stripped_suffix.?);
}

test "harness: Foo TUI strips to Foo" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Foo TUI", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Foo", result);
}

test "harness: Bar GUI strips to Bar" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Bar GUI", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Bar", result);
}

test "harness: Baz Desktop strips to Baz" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Baz Desktop", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Baz", result);
}

test "harness: recursive Kimi Code CLI Preview -> Kimi Code" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Kimi Code CLI Preview", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Kimi Code", result);
    try testing.expectEqual(@as(u8, 2), summary.iterations);
}

test "harness: recursive Foo CLI Beta -> Foo" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Foo CLI Beta", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Foo", result);
    try testing.expectEqual(@as(u8, 2), summary.iterations);
}

test "harness: hyphen separator works" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Kimi-CLI", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Kimi", result);
}

test "harness: case-insensitive on suffix word" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "kimi code cli", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("kimi code", result);
}

test "harness: no-op on bare name" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "Cline", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Cline", result);
    try testing.expectEqual(@as(u8, 0), summary.iterations);
    try testing.expectEqual(@as(?[]const u8, null), summary.stripped_suffix);
}

test "harness: mid-string suffix word not matched" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "KimiCLI", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("KimiCLI", result);
    try testing.expectEqual(@as(u8, 0), summary.iterations);
}

test "harness: prefix-only substring not matched" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "CodeCLI", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("CodeCLI", result);
}

test "harness: mixed-case suffix" {
    var summary: root.TrimField = .{};
    const result = try root.trimDisplaySuffix(testing.allocator, "MyTool Cli", &summary);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("MyTool", result);
}
