// Tail-read tests for the zcode rollout scan (`zcodeRolloutNewestMainRecord`): a session file past the old whole-file 64 MiB cap stays in the newest-record race (the long-session regression the tail read exists for), the winner is the newest completedAt across files regardless of directory order, a window opened mid-record discards the partial head line, and subagent/foreign-named files and non-main records stay out of the race.
// A second block pins both sides of the zcode 3.14 format drift (DESIGN decision #17 — parsing support spans every version released within the staleness window): records before 3.14 carry `model.role` and the `builtin:zai-start-plan` providerId; records since 3.14 carry no role and the renamed coding-plan keys. The provider-key canonicalization (`zcodeProviderCanonical`) is pinned for all three spellings plus the never-guess pass-through.
// Each test owns the arena its scan allocates from and asserts before the deferred deinit — the returned record aliases arena memory.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

const ROOT = "fixtures/.test-zcode-rollout";
const ROLLOUT = ROOT ++ "/.zcode/cli/rollout";

fn setup() !void {
    try std.Io.Dir.cwd().createDirPath(testing.io, ROLLOUT);
}

fn teardown() void {
    std.Io.Dir.cwd().deleteTree(testing.io, ROOT) catch {};
}

fn writeSessionFile(name: []const u8, contents: []const u8) !void {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ROLLOUT ++ "/{s}", .{name});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = contents });
}

/// a >64 MiB sparse session file (setLength fills the head with zero bytes) whose only record sits at the very tail,
/// preceded by a newline boundary like every record separator in a real rollout file.
fn writeGiantSessionFile(name: []const u8, record: []const u8) !void {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ROLLOUT ++ "/{s}", .{name});
    const io = testing.io;
    const giant: u64 = (1 << 26) + 1024; // past the old 64 MiB whole-file cap
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.setLength(io, giant);
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.seekTo(giant - record.len - 1);
    try fw.interface.writeAll("\n");
    try fw.interface.writeAll(record);
    try fw.interface.flush();
}

const record_fmt = "{{\"completedAt\":\"{s}\",\"model\":{{\"providerId\":\"account:zai-individual-coding-plan\",\"modelId\":\"{s}\",\"role\":\"{s}\"}}}}\n";

test "a session file past the old whole-file cap stays in the race" {
    try setup();
    defer teardown();
    var rbuf: [256]u8 = undefined;
    const rec = try std.fmt.bufPrint(&rbuf, record_fmt, .{ "2026-09-23T04:09:35.817Z", "GLM-5.3-Flash", "main" });
    try writeGiantSessionFile("model-io-sess_giant.jsonl", rec);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try main.zcodeRolloutNewestMainRecord(arena.allocator(), testing.io, ROLLOUT);
    try testing.expect(got != null);
    try testing.expectEqualStrings("GLM-5.3-Flash", got.?.model);
    try testing.expectEqualStrings("2026-09-23T04:09:35.817Z", got.?.completed_at);
}

test "the newest completedAt wins regardless of directory order" {
    try setup();
    defer teardown();
    var older_buf: [256]u8 = undefined;
    var newer_buf: [256]u8 = undefined;
    try writeSessionFile("model-io-sess_old.jsonl", try std.fmt.bufPrint(&older_buf, record_fmt, .{ "2026-09-22T05:45:51.415Z", "GLM-5.3", "main" }));
    try writeSessionFile("model-io-sess_new.jsonl", try std.fmt.bufPrint(&newer_buf, record_fmt, .{ "2026-09-23T04:09:35.817Z", "GLM-5.3-Flash", "main" }));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try main.zcodeRolloutNewestMainRecord(arena.allocator(), testing.io, ROLLOUT);
    try testing.expect(got != null);
    try testing.expectEqualStrings("GLM-5.3-Flash", got.?.model);
}

test "a window opened mid-record discards the partial head line" {
    try setup();
    defer teardown();
    // the file must exceed the 256 KiB tail window so it opens inside the padding run (no newlines) — the parseable record sits after the newline that ends the padding
    const padding: usize = 300 * 1024;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    var rbuf: [256]u8 = undefined;
    try body.appendNTimes(testing.allocator, 'x', padding);
    try body.append(testing.allocator, '\n');
    try body.appendSlice(testing.allocator, try std.fmt.bufPrint(&rbuf, record_fmt, .{ "2026-09-23T04:09:35.817Z", "GLM-5.3-Flash", "main" }));
    try writeSessionFile("model-io-sess_pad.jsonl", body.items);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try main.zcodeRolloutNewestMainRecord(arena.allocator(), testing.io, ROLLOUT);
    try testing.expect(got != null);
    try testing.expectEqualStrings("GLM-5.3-Flash", got.?.model);
}

test "a record before the tail window cannot win (bounded read, by design)" {
    try setup();
    defer teardown();
    // head record is NEWER but sits before the window (300 KiB padding > the 256 KiB window) — only the tail record is read
    const padding: usize = 300 * 1024;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    var head_buf: [256]u8 = undefined;
    var tail_buf: [256]u8 = undefined;
    try body.appendSlice(testing.allocator, try std.fmt.bufPrint(&head_buf, record_fmt, .{ "2026-09-24T00:00:00.000Z", "GLM-5.3", "main" }));
    try body.appendNTimes(testing.allocator, 'x', padding);
    try body.append(testing.allocator, '\n');
    try body.appendSlice(testing.allocator, try std.fmt.bufPrint(&tail_buf, record_fmt, .{ "2026-09-23T04:09:35.817Z", "GLM-5.3-Flash", "main" }));
    try writeSessionFile("model-io-sess_deep.jsonl", body.items);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try main.zcodeRolloutNewestMainRecord(arena.allocator(), testing.io, ROLLOUT);
    try testing.expect(got != null);
    try testing.expectEqualStrings("GLM-5.3-Flash", got.?.model);
}

test "subagent files, foreign names, and non-main records stay out of the race" {
    try setup();
    defer teardown();
    var newest_buf: [256]u8 = undefined;
    var main_buf: [256]u8 = undefined;
    var older_buf: [256]u8 = undefined;
    // a subagent file carrying the newest record — skipped by name
    try writeSessionFile("model-io-sess_abc_subagent_1.jsonl", try std.fmt.bufPrint(&newest_buf, record_fmt, .{ "2026-09-23T23:00:00.000Z", "GLM-5.3", "main" }));
    // a foreign name and a wrong suffix — skipped
    try writeSessionFile("notes.jsonl", try std.fmt.bufPrint(&newest_buf, record_fmt, .{ "2026-09-23T23:00:00.000Z", "GLM-5.3", "main" }));
    try writeSessionFile("model-io-sess_abc.jsonl.tmp", try std.fmt.bufPrint(&newest_buf, record_fmt, .{ "2026-09-23T23:00:00.000Z", "GLM-5.3", "main" }));
    // the qualifying file: its newest record is a non-main one, so the scan continues past it to the older main record
    var main_file: std.ArrayList(u8) = .empty;
    defer main_file.deinit(testing.allocator);
    try main_file.appendSlice(testing.allocator, try std.fmt.bufPrint(&main_buf, record_fmt, .{ "2026-09-23T04:09:35.817Z", "GLM-5.3-Flash", "main" }));
    try main_file.appendSlice(testing.allocator, try std.fmt.bufPrint(&older_buf, record_fmt, .{ "2026-09-23T05:00:00.000Z", "GLM-5.3", "subagent" }));
    try writeSessionFile("model-io-sess_main.jsonl", main_file.items);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try main.zcodeRolloutNewestMainRecord(arena.allocator(), testing.io, ROLLOUT);
    try testing.expect(got != null);
    try testing.expectEqualStrings("GLM-5.3-Flash", got.?.model);
    try testing.expectEqualStrings("2026-09-23T04:09:35.817Z", got.?.completed_at);
}

test "both record shapes across the 3.14 drift parse; the newer (role-absent) record wins" {
    try setup();
    defer teardown();
    // pre-3.14 record: role present ("main"), retired providerId — must still parse (decision #17)
    try writeSessionFile("model-io-sess_old.jsonl", "{\"completedAt\":\"2026-09-22T05:45:51.415Z\",\"model\":{\"providerId\":\"builtin:zai-start-plan\",\"modelId\":\"GLM-5.3\",\"role\":\"main\"}}\n");
    // 3.14+ record: no role field at all — must parse too, and its newer completedAt wins
    try writeSessionFile("model-io-sess_new.jsonl", "{\"completedAt\":\"2026-09-23T04:09:35.817Z\",\"model\":{\"providerId\":\"account:zai-individual-coding-plan\",\"modelId\":\"GLM-5.3-Flash\"}}\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try main.zcodeRolloutNewestMainRecord(arena.allocator(), testing.io, ROLLOUT);
    try testing.expect(got != null);
    try testing.expectEqualStrings("GLM-5.3-Flash", got.?.model);
    try testing.expectEqualStrings("account:zai-individual-coding-plan", got.?.provider);
}

test "zcodeProviderCanonical maps every in-window provider-key spelling; unknown keys pass through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // retired pre-3.14 rollout/settings key
    try testing.expectEqualStrings("zcode", try main.zcodeProviderCanonical(a, "builtin:zai-start-plan"));
    // 3.14+ rollout key
    try testing.expectEqualStrings("zcode", try main.zcodeProviderCanonical(a, "account:zai-individual-coding-plan"));
    // 3.14+ settings selected key
    try testing.expectEqualStrings("zcode", try main.zcodeProviderCanonical(a, "coding-plan:builtin:zai-coding-plan"));
    // an opaque custom key is never guessed into the bundled plan
    try testing.expectEqualStrings("builtin:some-custom-provider", try main.zcodeProviderCanonical(a, "builtin:some-custom-provider"));
}
