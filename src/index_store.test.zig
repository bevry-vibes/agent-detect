// Unit-shape tests for the index.json store's pure operations and the
// daemon's pop protocol (§4b/§4e): expansion (known rows vs the unknown
// cross-product-minus-maps), the completion-timestamp done rule against
// started_at/declared_at/captured_at/failed_at, skip/delete/keep
// signals, the conflict matrix, purge-on-success, the channel-hash
// divergence check, and queue-entry upsert dedupe. All operations are
// pure (in-memory `std.json.Value` trees) — the tests never touch the
// committed store or fixture files.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

const dev = main.dev;
const QueueEntry = dev.QueueEntry;
const FixtureUpdate = dev.FixtureUpdate;

/// build an in-memory store root with the four top-level tables.
fn emptyStoreRoot(a: std.mem.Allocator) !std.json.Value {
    var root: std.json.Value = .{ .object = .empty };
    try root.object.put(a, "store_version", .{ .integer = 1 });
    try root.object.put(a, "free_provider_to_model", .{ .object = .empty });
    try root.object.put(a, "fixtures", .{ .object = .empty });
    try root.object.put(a, "errors", .{ .object = .empty });
    try root.object.put(a, "queue", .{ .array = std.json.Array.init(a) });
    return root;
}

/// put a known fixture row with the given ledgers.
fn putRow(a: std.mem.Allocator, root: *std.json.Value, key: []const u8, declared_at: ?i64, captured_at: ?i64) !void {
    const update: FixtureUpdate = if (declared_at) |t|
        .{ .identity = .{ .runner = 1, .agent_detect_version = "2026.8.11-1", .declared_at = t, .channel_hash = "identity-hash", .fixture_hash = "fixture-hash" } }
    else
        .{ .capture = .{ .runner = 1, .agent_detect_version = "2026.8.11-1", .captured_at = captured_at orelse 1, .channel_hash = "capture-hash", .harness_version = null, .fixture_hash = "fixture-hash" } };
    try dev.fixtureRowUpdatePure(a, root, key, update);
}

/// expand helper with a host parameter.
fn expand(a: std.mem.Allocator, root: *const std.json.Value, entry: QueueEntry, host: []const u8) !dev.ExpandResult {
    return dev.expandEntry(std.testing.io, a, root, entry, host);
}

test "expandEntry: known universe — fresh entry lists every matching row (started_at null ⇒ no done rule)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    try putRow(a, &root, "cline-clinepass-kimik3-darwin", 100, null);
    try putRow(a, &root, "cline-clinepass-kimik3-linux", null, 200);
    try putRow(a, &root, "kilo-deepseek-deepseekv4pro-darwin", 300, null);

    const entry: QueueEntry = .{ .mode = "from-identity" };
    const result = try expand(a, &root, entry, "darwin");
    try testing.expectEqual(@as(usize, 2), result.host_candidates.len);
    try testing.expectEqual(@as(usize, 3), result.remaining_anywhere);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", result.host_candidates[0].fixture_id);
    try testing.expectEqualStrings("kilo-deepseek-deepseekv4pro-darwin", result.host_candidates[1].fixture_id);
}

test "expandEntry: dims filter the known universe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    try putRow(a, &root, "cline-clinepass-kimik3-darwin", 100, null);
    try putRow(a, &root, "kilo-deepseek-deepseekv4pro-darwin", 300, null);

    const entry: QueueEntry = .{ .harness = "kilo", .mode = "from-identity" };
    const result = try expand(a, &root, entry, "darwin");
    try testing.expectEqual(@as(usize, 1), result.host_candidates.len);
    try testing.expectEqualStrings("kilo-deepseek-deepseekv4pro-darwin", result.host_candidates[0].fixture_id);
}

test "expandEntry: done rule — timestamps ≥ started_at drop out; failures (failed_at) count as done" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    try putRow(a, &root, "cline-clinepass-kimik3-darwin", 100, null); // old — remaining
    try putRow(a, &root, "kilo-deepseek-deepseekv4pro-darwin", 300, null); // ≥ started_at — done
    try putRow(a, &root, "pi-anthropic-claudesonnet4-darwin", null, 400); // no declared_at — remaining
    // a failed row: errors entry with failed_at ≥ started_at — done
    try dev.errorsPutPure(a, &root, "opencode", "deepseek", "deepseekv4flash", "darwin", "capture failed", 350);

    const entry: QueueEntry = .{ .mode = "from-identity", .started_at = 200 };
    const result = try expand(a, &root, entry, "darwin");
    try testing.expectEqual(@as(usize, 2), result.host_candidates.len);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", result.host_candidates[0].fixture_id);
    try testing.expectEqualStrings("pi-anthropic-claudesonnet4-darwin", result.host_candidates[1].fixture_id);
}

test "expandEntry: keep vs delete — another host's portion keeps the entry, empty everywhere deletes it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    try putRow(a, &root, "cline-clinepass-kimik3-windows", 100, null);

    // darwin host, windows-only row: no host work, work remains elsewhere
    const entry: QueueEntry = .{ .mode = "from-identity", .started_at = 200 };
    const keep_result = try expand(a, &root, entry, "darwin");
    try testing.expectEqual(@as(usize, 0), keep_result.host_candidates.len);
    try testing.expectEqual(@as(usize, 1), keep_result.remaining_anywhere);

    // the windows host sees the work; once declared_at ≥ started_at, gone
    const win_entry: QueueEntry = .{ .mode = "from-identity", .started_at = 50 };
    const win_result = try expand(a, &root, win_entry, "windows");
    try testing.expectEqual(@as(usize, 0), win_result.host_candidates.len);
    try testing.expectEqual(@as(usize, 0), win_result.remaining_anywhere); // delete signal
}

test "expandEntry: unknown universe — rule cross-product minus the maps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);

    // filtered cross-product: exactly one combo per platform
    const entry: QueueEntry = .{ .harness = "cline", .provider = "clinepass", .model = "kimik3", .known = false, .mode = "from-identity", .platform = "darwin" };
    const result = try expand(a, &root, entry, "darwin");
    try testing.expectEqual(@as(usize, 1), result.host_candidates.len);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", result.host_candidates[0].fixture_id);

    // subtract a known row → nothing left
    try putRow(a, &root, "cline-clinepass-kimik3-darwin", 100, null);
    const result2 = try expand(a, &root, entry, "darwin");
    try testing.expectEqual(@as(usize, 0), result2.host_candidates.len);
    try testing.expectEqual(@as(usize, 0), result2.remaining_anywhere);
}

test "expandEntry: valid axis — invalid-class errors exclude by default, re-evaluated with --invalid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    try putRow(a, &root, "cline-clinepass-kimik3-darwin", 100, null);
    try dev.errorsPutPure(a, &root, "cline", "clinepass", "kimik3", "darwin", "no launch spec", 90);

    const default_entry: QueueEntry = .{ .mode = "from-identity" };
    const default_result = try expand(a, &root, default_entry, "darwin");
    try testing.expectEqual(@as(usize, 0), default_result.host_candidates.len);

    const invalid_entry: QueueEntry = .{ .mode = "from-identity", .valid = false };
    const invalid_result = try expand(a, &root, invalid_entry, "darwin");
    try testing.expectEqual(@as(usize, 1), invalid_result.host_candidates.len);
}

test "expandEntry: successful axis — true keeps no-error rows, false keeps unsuccessful-class failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    try putRow(a, &root, "cline-clinepass-kimik3-darwin", 100, null); // clean
    try putRow(a, &root, "kilo-deepseek-deepseekv4pro-darwin", 300, null); // failed
    try dev.errorsPutPure(a, &root, "kilo", "deepseek", "deepseekv4pro", "darwin", "capture failed", 90);

    const succ_entry: QueueEntry = .{ .mode = "from-identity", .successful = true };
    const succ = try expand(a, &root, succ_entry, "darwin");
    try testing.expectEqual(@as(usize, 1), succ.host_candidates.len);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", succ.host_candidates[0].fixture_id);

    const fail_entry: QueueEntry = .{ .mode = "from-identity", .successful = false };
    const fail = try expand(a, &root, fail_entry, "darwin");
    try testing.expectEqual(@as(usize, 1), fail.host_candidates.len);
    try testing.expectEqualStrings("kilo-deepseek-deepseekv4pro-darwin", fail.host_candidates[0].fixture_id);
}

test "expandEntry: free axis filters by free_provider_to_model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    try putRow(a, &root, "pi-openrouter-nemotron3ultra-darwin", 100, null);
    try putRow(a, &root, "pi-openrouter-deepseekv4flash-darwin", 100, null);
    var free_map: std.json.Value = .{ .object = .empty };
    var models: std.json.Value = .{ .array = std.json.Array.init(a) };
    try models.array.append(.{ .string = "nemotron3ultra" });
    try free_map.object.put(a, "openrouter", models);
    try root.object.put(a, "free_provider_to_model", free_map);

    const free_entry: QueueEntry = .{ .mode = "from-identity", .free = true };
    const free_result = try expand(a, &root, free_entry, "darwin");
    try testing.expectEqual(@as(usize, 1), free_result.host_candidates.len);
    try testing.expectEqualStrings("pi-openrouter-nemotron3ultra-darwin", free_result.host_candidates[0].fixture_id);

    const paid_entry: QueueEntry = .{ .mode = "from-identity", .free = false };
    const paid_result = try expand(a, &root, paid_entry, "darwin");
    try testing.expectEqual(@as(usize, 1), paid_result.host_candidates.len);
    try testing.expectEqualStrings("pi-openrouter-deepseekv4flash-darwin", paid_result.host_candidates[0].fixture_id);
}

test "expandEntry: stale_by_detect_version — agent_detect_version null or differing is stale" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    // no agent_detect_version → stale
    try dev.fixtureRowUpdatePure(a, &root, "cline-clinepass-kimik3-darwin", .{ .registration = .{
        .runner = 1, .fixture_hash = "fh", .identity_channel_hash = null, .capture_channel_hash = null,
    } });
    const entry: QueueEntry = .{ .mode = "from-identity", .stale_by_detect_version = true };
    const result = try expand(a, &root, entry, "darwin");
    try testing.expectEqual(@as(usize, 1), result.host_candidates.len);
}

test "errors ledger: purge-on-success deletes the entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    try dev.errorsPutPure(a, &root, "cline", "clinepass", "kimik3", "darwin", "unavailable", 100);
    try testing.expect(root.object.get("errors").?.object.get("cline-clinepass-kimik3-darwin") != null);
    try dev.errorsClearPure(a, &root, "cline", "clinepass", "kimik3", "darwin");
    try testing.expect(root.object.get("errors").?.object.get("cline-clinepass-kimik3-darwin") == null);
    // partial dims key with null slots
    try dev.errorsPutPure(a, &root, null, null, null, null, "malformed queue row", 200);
    try testing.expect(root.object.get("errors").?.object.get("null-null-null-null") != null);
}

test "channelHashDivergent: both null / one null / unequal → stale; equal → fresh" {
    try testing.expect(dev.channelHashDivergent(null, null));
    try testing.expect(dev.channelHashDivergent("aaa", null));
    try testing.expect(dev.channelHashDivergent(null, "bbb"));
    try testing.expect(dev.channelHashDivergent("aaa", "bbb"));
    try testing.expect(!dev.channelHashDivergent("aaa", "aaa"));
}

test "errorReasonClass: the closed set partitions into unsuccessful / invalid" {
    try testing.expectEqual(dev.ErrorClass.unsuccessful, dev.errorReasonClass("capture failed"));
    try testing.expectEqual(dev.ErrorClass.unsuccessful, dev.errorReasonClass("unavailable"));
    try testing.expectEqual(dev.ErrorClass.unsuccessful, dev.errorReasonClass("post-check mismatch"));
    try testing.expectEqual(dev.ErrorClass.invalid, dev.errorReasonClass("no launch spec"));
    try testing.expectEqual(dev.ErrorClass.invalid, dev.errorReasonClass("unknown fixture file"));
    try testing.expectEqual(dev.ErrorClass.invalid, dev.errorReasonClass("malformed fixture id"));
    try testing.expectEqual(dev.ErrorClass.invalid, dev.errorReasonClass("malformed queue row"));
    // unknown reasons (hand-edited store) classify as invalid — excluded
    // by the default valid=true axis
    try testing.expectEqual(dev.ErrorClass.invalid, dev.errorReasonClass("hand-edited reason"));
}

test "validateQueueEntry: at most one marker; markers true|null; mode constrained" {
    const good: QueueEntry = .{ .mode = "from-identity", .stale_by_minutes = 7 };
    try dev.validateQueueEntry(good);
    const two_markers: QueueEntry = .{ .mode = "from-identity", .stale_by_minutes = 7, .stale_by_detect_version = true };
    try testing.expectError(error.InvalidQueueRow, dev.validateQueueEntry(two_markers));
    const bad_mins: QueueEntry = .{ .mode = "from-capture", .stale_by_minutes = 0 };
    try testing.expectError(error.InvalidQueueRow, dev.validateQueueEntry(bad_mins));
    const bad_mode: QueueEntry = .{ .mode = "bogus" };
    try testing.expectError(error.InvalidQueueRow, dev.validateQueueEntry(bad_mode));
    const false_marker: QueueEntry = .{ .mode = "from-identity", .stale_by_fixture_hash = false };
    try testing.expectError(error.InvalidQueueRow, dev.validateQueueEntry(false_marker));
}

test "validateFilters: the conflict matrix" {
    const f = dev.FilterOptions;
    // two age thresholds
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .stale_by_days = 7, .stale_by_minutes = 30 }));
    // marker + age threshold
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .stale_by_minutes = 30, .stale_by_fixture_hash = true }));
    // non-positive threshold
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .stale_by_days = 0 }));
    // --unknown + marker (marker sweeps require known)
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .known = false, .stale_by_minutes = 30 }));
    // --unknown + non-default successful
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .known = false, .successful = false }));
    // allowed shapes
    try dev.validateFilters(.{ .stale_by_minutes = 30 });
    try dev.validateFilters(.{ .known = false, .free = true });
    try dev.validateFilters(.{ .successful = true, .valid = false });
    _ = f;
}

test "queueUpsertPure: re-assert replaces the tuple in place and resets started_at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try emptyStoreRoot(a);
    const first: QueueEntry = .{ .harness = "kilo", .mode = "from-identity", .stale_by_minutes = 7, .runner = 1, .started_at = 123 };
    try dev.queueUpsertPure(a, &root, first);
    const second: QueueEntry = .{ .harness = "kilo", .mode = "from-identity", .stale_by_minutes = 7, .runner = 2, .started_at = null };
    try dev.queueUpsertPure(a, &root, second);
    // a different tuple appends
    const other: QueueEntry = .{ .harness = "kilo", .mode = "from-capture", .stale_by_minutes = 7 };
    try dev.queueUpsertPure(a, &root, other);
    // re-fetch after the appends (the Value copy captured earlier would
    // hold a stale items slice)
    const queue = root.object.get("queue").?;
    try testing.expectEqual(@as(usize, 2), queue.array.items.len);
    const entry = queue.array.items[0].object;
    try testing.expectEqual(@as(i64, 2), entry.get("runner").?.integer);
    try testing.expect(entry.get("started_at").? == .null);
}
