// Unit-shape tests for the index.json store's pure operations and the
// daemon's pop protocol: the one-universe expansion (fixtured folder
// files ∨ feasible-unfixtured per the reference grids), the OR-ed
// staleness criteria set against the channel files' `meta`, the
// completion-timestamp done rule, session damping, the staleness
// defaulting matrix (--stale composite / explicit --stale-* /
// --refresh), queue-entry upsert dedupe, the backlog table, and
// known_but_failed. Pure operations run in-memory; the folder scans
// run against a throwaway universe under fixtures/.test-universe.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

const dev = main.dev;
const QueueEntry = dev.QueueEntry;

const UNIVERSE = "fixtures/.test-universe";

/// a throwaway fixtures tree: `UNIVERSE/from-identity` +
/// `UNIVERSE/from-capture`, rooted at via dev.setFixturesRootForTests.
const Universe = struct {
    fn setup() !void {
        const io = testing.io;
        var d: [64]u8 = undefined;
        const id_dir = try std.fmt.bufPrint(&d, UNIVERSE ++ "/from-identity", .{});
        std.Io.Dir.cwd().createDirPath(io, id_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var d2: [64]u8 = undefined;
        const cap_dir = try std.fmt.bufPrint(&d2, UNIVERSE ++ "/from-capture", .{});
        std.Io.Dir.cwd().createDirPath(io, cap_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        dev.setFixturesRootForTests(UNIVERSE);
    }

    fn teardown() !void {
        const io = testing.io;
        std.Io.Dir.cwd().deleteTree(io, UNIVERSE) catch {};
        dev.setFixturesRootForTests("fixtures");
    }

    /// write a whole channel file (raw text).
    fn write(folder: []const u8, stem: []const u8, contents: []const u8) !void {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, UNIVERSE ++ "/{s}/{s}.json", .{ folder, stem });
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = contents });
    }

    /// an identity channel file with the given updated_at and an
    /// identify block whose ids are the stem's dims.
    fn writeIdentity(stem: []const u8, updated_at: i64) !void {
        var buf: [1024]u8 = undefined;
        var it = std.mem.tokenizeScalar(u8, stem, '-');
        const h = it.next().?;
        const p = it.next().?;
        const m = it.next().?;
        const body = try std.fmt.bufPrint(&buf, "{{\"outputs\":{{\"identify\":{{\"harness_id\":\"{s}\",\"provider_id\":\"{s}\",\"model_id\":\"{s}\"}},\"trailer co-author\":\"Co-authored-by: x\",\"trailer assisted-by\":\"Assisted-by: x\"}},\"meta\":{{\"updated_at\":{d},\"agent_detect_version\":\"test-version\"}}}}", .{ h, p, m, updated_at });
        try write("from-identity", stem, body);
    }

    /// a capture channel file with meta.launch argv (and optional
    /// identify parity with the identity file).
    fn writeCapture(stem: []const u8, updated_at: ?i64, with_argv: bool) !void {
        var buf: [1024]u8 = undefined;
        var meta: std.ArrayList(u8) = .empty;
        if (updated_at) |t| {
            try meta.appendSlice(testing.allocator, try std.fmt.bufPrint(&buf, "\"updated_at\":{d},\"agent_detect_version\":\"test-version\",\"harness_version\":\"1.2.3\"", .{t}));
        }
        if (with_argv) {
            if (meta.items.len > 0) try meta.append(testing.allocator, ',');
            try meta.appendSlice(testing.allocator, "\"prompt_launch\":[\"someharness\",\"-p\",\"<prompt>\"],\"version_launch\":[\"someharness\",\"--version\"]");
        }
        defer meta.deinit(testing.allocator);
        var it = std.mem.tokenizeScalar(u8, stem, '-');
        const h = it.next().?;
        const p = it.next().?;
        const m = it.next().?;
        const body = try std.fmt.bufPrint(&buf, "{{\"outputs\":{{\"identify\":{{\"harness_id\":\"{s}\",\"provider_id\":\"{s}\",\"model_id\":\"{s}\"}},\"trailer co-author\":\"Co-authored-by: x\",\"trailer assisted-by\":\"Assisted-by: x\",\"raw\":{{\"platform_id\":\"darwin\"}}}},\"meta\":{{{s}}}}}", .{ h, p, m, meta.items });
        try write("from-capture", stem, body);
    }
};

/// build an in-memory store root with the v2 tables.
fn emptyStoreRoot(a: std.mem.Allocator) !std.json.Value {
    var root: std.json.Value = .{ .object = .empty };
    try root.object.put(a, "store_version", .{ .integer = 2 });
    try root.object.put(a, "queue", .{ .array = std.json.Array.init(a) });
    try root.object.put(a, "backlog", .{ .object = .empty });
    try root.object.put(a, "known_but_failed", .{ .object = .empty });
    return root;
}

/// expand helper with a host parameter (empty free grid + grids, no
/// damping).
fn expand(a: std.mem.Allocator, entry: QueueEntry, host: []const u8) !dev.ExpandResult {
    var fg = dev.FreeGrid.empty(a);
    var grids = dev.FeasibilityGrids.empty(a);
    return dev.expandEntry(testing.io, a, &fg, &grids, entry, host, null);
}

// ---------------------------------------------------------------------------
// staleness defaulting (§ --stale composite)
// ---------------------------------------------------------------------------

test "stampCriteria: no flags → the full --stale composite" {
    const crit = dev.stampCriteria(.{});
    try testing.expect(crit.output_drift);
    try testing.expectEqual(dev.StaleCriteria.composite.minutes.?, crit.minutes.?);
    try testing.expect(crit.harness_version);
    try testing.expect(crit.detect_version);
    try testing.expectEqual(@as(i64, 27 * 24 * 60), crit.minutes.?);
}

test "stampCriteria: any explicit --stale-* forms the set alone" {
    const crit = dev.stampCriteria(.{ .stale_by_detect_version = true });
    try testing.expect(!crit.output_drift);
    try testing.expect(crit.minutes == null);
    try testing.expect(!crit.harness_version);
    try testing.expect(crit.detect_version);
}

test "stampCriteria: --stale plus an explicit flag overwrites just that component" {
    const crit = dev.stampCriteria(.{ .stale = true, .stale_by_days = 0 });
    try testing.expect(crit.output_drift);
    try testing.expectEqual(@as(i64, 0), crit.minutes.?);
    try testing.expect(crit.harness_version);
    try testing.expect(crit.detect_version);
}

test "stampCriteria: --stale-by-days=999999999 effectively disables the age component" {
    const crit = dev.stampCriteria(.{ .stale = true, .stale_by_days = 999999999 });
    try testing.expect(crit.output_drift);
    try testing.expect(crit.harness_version);
    try testing.expect(crit.detect_version);
}

test "stampCriteria: --refresh carries no criteria" {
    const crit = dev.stampCriteria(.{ .refresh = true });
    try testing.expect(crit.isNone());
}

test "validateFilters: the conflict matrix" {
    // --refresh conflicts with --stale and every --stale-*
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .refresh = true, .stale = true }));
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .refresh = true, .stale_by_detect_version = true }));
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .refresh = true, .stale_by_minutes = 30 }));
    // two age thresholds
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .stale_by_days = 7, .stale_by_minutes = 30 }));
    // negative threshold
    try testing.expectError(error.ConflictingFilters, dev.validateFilters(.{ .stale_by_days = -1 }));
    // zero thresholds are allowed (everything age-stale)
    try dev.validateFilters(.{ .stale = true, .stale_by_days = 0 });
    // allowed shapes
    try dev.validateFilters(.{ .stale_by_minutes = 30 });
    try dev.validateFilters(.{ .refresh = true });
    try dev.validateFilters(.{ .stale = true, .free = true });
}

test "validateQueueEntry: mode constrained; age threshold >= 0" {
    try dev.validateQueueEntry(.{ .mode = "from-identity", .stale_by_minutes = 0 });
    try testing.expectError(error.InvalidQueueRow, dev.validateQueueEntry(.{ .mode = "bogus" }));
    try testing.expectError(error.InvalidQueueRow, dev.validateQueueEntry(.{ .mode = "from-capture", .stale_by_minutes = -1 }));
}

test "queueUpsertPure: re-assert replaces the tuple in place and resets started_at" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var root = try emptyStoreRoot(aa);
    const first: QueueEntry = .{ .harness = "kilo", .mode = "from-identity", .stale_by_minutes = 7, .runner = 1, .started_at = 123 };
    try dev.queueUpsertPure(aa, &root, first);
    const second: QueueEntry = .{ .harness = "kilo", .mode = "from-identity", .stale_by_minutes = 7, .runner = 2 };
    try dev.queueUpsertPure(aa, &root, second);
    // a different tuple (different criteria) appends — a re-assert must
    // repeat the SAME flag set or it lands as a second entry.
    const other: QueueEntry = .{ .harness = "kilo", .mode = "from-identity", .stale_by_minutes = 7, .stale_by_detect_version = true };
    try dev.queueUpsertPure(aa, &root, other);
    const queue = root.object.get("queue").?;
    try testing.expectEqual(@as(usize, 2), queue.array.items.len);
    const entry = queue.array.items[0].object;
    try testing.expectEqual(@as(i64, 2), entry.get("runner").?.integer);
    try testing.expect(entry.get("started_at") == null);
}

// ---------------------------------------------------------------------------
// identify deep-compare
// ---------------------------------------------------------------------------

test "identifyEqual: structural, order-independent deep equality" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const parse = struct {
        fn f(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
            const p = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
            return p.value;
        }
    }.f;
    const x = try parse(aa, "{\"harness_id\":\"pi\",\"provider_id\":\"chutes\",\"model_id\":\"glm53flash\",\"reciprocal\":true,\"nested\":{\"a\":[1,2]}}");
    const y = try parse(aa, "{\"model_id\":\"glm53flash\",\"reciprocal\":true,\"nested\":{\"a\":[1,2]},\"harness_id\":\"pi\",\"provider_id\":\"chutes\"}");
    const z = try parse(aa, "{\"harness_id\":\"pi\",\"provider_id\":\"chutes\",\"model_id\":\"other\"}");
    try testing.expect(dev.identifyEqual(x, y));
    try testing.expect(!dev.identifyEqual(x, z));
    try testing.expect(!dev.identifyEqual(x, .null));
}

// ---------------------------------------------------------------------------
// backlog + known_but_failed
// ---------------------------------------------------------------------------

test "backlogUnionPure: idempotent union, sorted unique; backlogRemovePure removes" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var root = try emptyStoreRoot(aa);
    try dev.backlogUnionPure(aa, &root, "unknown_harnesses", &.{ "zeta", "alpha" });
    try dev.backlogUnionPure(aa, &root, "unknown_harnesses", &.{"alpha"}); // idempotent
    try dev.backlogUnionPure(aa, &root, "unknown_harnesses", &.{"mid"});
    const items = try dev.backlogItems(aa, &root, "unknown_harnesses");
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("alpha", items[0]);
    try testing.expectEqualStrings("mid", items[1]);
    try testing.expectEqualStrings("zeta", items[2]);
    dev.backlogRemovePure(&root, "unknown_harnesses", "mid");
    const after = try dev.backlogItems(aa, &root, "unknown_harnesses");
    try testing.expectEqual(@as(usize, 2), after.len);
    dev.backlogRemovePure(&root, "unknown_harnesses", "absent"); // no-op
}

test "knownButFailedPutPure: redacts home paths + key-shaped strings, truncates; clear removes" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var root = try emptyStoreRoot(aa);
    try dev.knownButFailedPutPure(aa, &root, "pi-chutes-kimik3-darwin", "failed: can't read /Users/balupton/.pi/auth.json with key sk-abc123def456ghi789 and Bearer tok1234567890", "/Users/balupton");
    const msg = dev.knownButFailedFor(&root, "pi-chutes-kimik3-darwin").?;
    try testing.expect(std.mem.indexOf(u8, msg, "/Users/balupton") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "sk-abc123") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "Bearer tok1234567890") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "<redacted>") != null);
    // a very long message truncates to a bounded size
    const long = "x" ** 5000;
    try dev.knownButFailedPutPure(aa, &root, "a-b-c-darwin", long, "");
    const short = dev.knownButFailedFor(&root, "a-b-c-darwin").?;
    try testing.expect(short.len <= 403); // 400 chars + ellipsis
    // last failure wins
    try dev.knownButFailedPutPure(aa, &root, "pi-chutes-kimik3-darwin", "second failure", "");
    try testing.expectEqualStrings("second failure", dev.knownButFailedFor(&root, "pi-chutes-kimik3-darwin").?);
    dev.knownButFailedClearPure(&root, "pi-chutes-kimik3-darwin");
    try testing.expect(dev.knownButFailedFor(&root, "pi-chutes-kimik3-darwin") == null);
}

// ---------------------------------------------------------------------------
// expansion (the pop protocol)
// ---------------------------------------------------------------------------

test "expandEntry: fixtured universe — the from-identity folder's files, dims-filtered" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try Universe.writeIdentity("kilo-deepseek-deepseekv4pro-darwin", 100);
    try Universe.writeIdentity("cline-clinepass-kimik3-darwin", 200);

    // no criteria = --refresh entry: every fixtured candidate is worked
    const result = try expand(aa, .{ .mode = "from-identity" }, "darwin");
    try testing.expectEqual(@as(usize, 2), result.host_candidates.len);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", result.host_candidates[0].fixture_id);

    const filtered = try expand(aa, .{ .harness = "kilo", .mode = "from-identity" }, "darwin");
    try testing.expectEqual(@as(usize, 1), filtered.host_candidates.len);
    try testing.expectEqualStrings("kilo-deepseek-deepseekv4pro-darwin", filtered.host_candidates[0].fixture_id);
}

test "expandEntry: done rule — meta.updated_at >= started_at drops out" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try Universe.writeIdentity("kilo-deepseek-deepseekv4pro-darwin", 300); // fresh — done
    try Universe.writeIdentity("cline-clinepass-kimik3-darwin", 100); // old — remaining

    const entry: QueueEntry = .{ .mode = "from-identity", .started_at = 200 };
    const result = try expand(aa, entry, "darwin");
    try testing.expectEqual(@as(usize, 1), result.host_candidates.len);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", result.host_candidates[0].fixture_id);
}

test "expandEntry: keep vs delete — another host's portion keeps the entry" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try Universe.writeIdentity("kilo-deepseek-deepseekv4pro-windows", 100);

    const entry: QueueEntry = .{ .mode = "from-identity" };
    const darwin = try expand(aa, entry, "darwin");
    try testing.expectEqual(@as(usize, 0), darwin.host_candidates.len);
    try testing.expectEqual(@as(usize, 1), darwin.remaining_anywhere);
    const windows = try expand(aa, entry, "windows");
    try testing.expectEqual(@as(usize, 1), windows.host_candidates.len);
    try testing.expectEqual(@as(usize, 1), windows.remaining_anywhere);
}

test "expandEntry: staleness — age-fresh skips, age-stale lists; absent evidence is stale" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = testing.io;
    const now: i64 = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    try Universe.writeIdentity("kilo-deepseek-deepseekv4pro-darwin", now - 60); // 1 min old
    try Universe.writeIdentity("cline-clinepass-kimik3-darwin", now - 10 * 60); // 10 min old

    // 30-min age criterion: both fresh → no candidates
    const fresh = try expand(aa, .{ .mode = "from-identity", .stale_by_minutes = 30 }, "darwin");
    try testing.expectEqual(@as(usize, 0), fresh.host_candidates.len);
    // 5-min age criterion: only the 10-min-old file is stale
    const stale = try expand(aa, .{ .mode = "from-identity", .stale_by_minutes = 5 }, "darwin");
    try testing.expectEqual(@as(usize, 1), stale.host_candidates.len);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", stale.host_candidates[0].fixture_id);
    // minutes=0: everything age-stale
    const zero = try expand(aa, .{ .mode = "from-identity", .stale_by_minutes = 0 }, "darwin");
    try testing.expectEqual(@as(usize, 2), zero.host_candidates.len);
    // a file with no updated_at (meta-only capture stub) is age-stale
    try Universe.writeCapture("kilo-kilo-glm52-darwin", null, true);
    const stub = try expand(aa, .{ .mode = "from-capture", .stale_by_minutes = 30 }, "darwin");
    try testing.expectEqual(@as(usize, 1), stub.host_candidates.len);
}

test "expandEntry: --stale-by-output-drift — both channels present and equal ⇒ fresh; missing channel ⇒ stale" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // identity + capture with identical identify objects → fresh
    try Universe.writeIdentity("kilo-deepseek-deepseekv4pro-darwin", 100);
    try Universe.writeCapture("kilo-deepseek-deepseekv4pro-darwin", 100, true);
    // identity only → the missing capture channel counts stale
    try Universe.writeIdentity("cline-clinepass-kimik3-darwin", 100);

    const entry: QueueEntry = .{ .mode = "from-identity", .stale_by_output_drift = true };
    const result = try expand(aa, entry, "darwin");
    try testing.expectEqual(@as(usize, 1), result.host_candidates.len);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", result.host_candidates[0].fixture_id);
    // the drift criterion also applies to from-capture entries
    const cap_entry: QueueEntry = .{ .mode = "from-capture", .stale_by_output_drift = true };
    const cap_result = try expand(aa, cap_entry, "darwin");
    try testing.expectEqual(@as(usize, 0), cap_result.host_candidates.len);
}

test "expandEntry: from-capture requires meta.prompt_launch — argv-less files are backlog, not candidates" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try Universe.writeCapture("kilo-kilo-glm52-darwin", null, false); // no argv
    try Universe.writeCapture("kilo-kilo-kimik3-darwin", null, true); // curated

    const entry: QueueEntry = .{ .mode = "from-capture" };
    const result = try expand(aa, entry, "darwin");
    try testing.expectEqual(@as(usize, 1), result.host_candidates.len);
    try testing.expectEqualStrings("kilo-kilo-kimik3-darwin", result.host_candidates[0].fixture_id);
}

test "expandEntry: feasible-unfixtured — grid pairs minus the fixtured stems (from-identity only)" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try Universe.writeIdentity("kilo-deepseek-deepseekv4pro-darwin", 300);

    var grids = dev.FeasibilityGrids.empty(aa);
    try grids.putHarnessProvider(aa, "kilo", "deepseek");
    try grids.putProviderModel(aa, "deepseek", "deepseekv4pro");
    try grids.putProviderModel(aa, "deepseek", "deepseekv4flash");
    var fg = dev.FreeGrid.empty(aa);

    // two feasible pairs for (kilo, deepseek) on darwin; one is fixtured
    // (and done under this started_at — a no-criteria entry works
    // everything, so the done rule must retire the fixtured one)
    const entry: QueueEntry = .{ .mode = "from-identity", .started_at = 200 };
    const result = try dev.expandEntry(testing.io, aa, &fg, &grids, entry, "darwin", null);
    try testing.expectEqual(@as(usize, 1), result.host_candidates.len);
    try testing.expectEqualStrings("kilo-deepseek-deepseekv4flash-darwin", result.host_candidates[0].fixture_id);
    // dims filter applies
    const filtered = try dev.expandEntry(testing.io, aa, &fg, &grids, .{ .mode = "from-identity", .model = "deepseekv4pro", .started_at = 200 }, "darwin", null);
    try testing.expectEqual(@as(usize, 0), filtered.host_candidates.len);
    // from-capture never expands unfixtured combos (no argv to launch)
    const cap = try dev.expandEntry(testing.io, aa, &fg, &grids, .{ .mode = "from-capture" }, "darwin", null);
    try testing.expectEqual(@as(usize, 0), cap.host_candidates.len);
}

test "expandEntry: free axis filters by .providers_freemodels.csv membership (FreeGrid)" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try Universe.writeIdentity("pi-openrouter-nemotron3ultra-darwin", 100);
    try Universe.writeIdentity("pi-openrouter-deepseekv4flash-darwin", 100);

    var fg = dev.FreeGrid.empty(aa);
    try fg.put(aa, "openrouter", "nemotron3ultra");
    var grids = dev.FeasibilityGrids.empty(aa);
    const free_result = try dev.expandEntry(testing.io, aa, &fg, &grids, .{ .mode = "from-identity", .free = true }, "darwin", null);
    try testing.expectEqual(@as(usize, 1), free_result.host_candidates.len);
    try testing.expectEqualStrings("pi-openrouter-nemotron3ultra-darwin", free_result.host_candidates[0].fixture_id);
    const paid_result = try dev.expandEntry(testing.io, aa, &fg, &grids, .{ .mode = "from-identity", .free = false }, "darwin", null);
    try testing.expectEqual(@as(usize, 1), paid_result.host_candidates.len);
    try testing.expectEqualStrings("pi-openrouter-deepseekv4flash-darwin", paid_result.host_candidates[0].fixture_id);
}

test "expandEntry: session damping — failed candidates are excluded" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try Universe.writeIdentity("kilo-deepseek-deepseekv4pro-darwin", 100);
    try Universe.writeIdentity("cline-clinepass-kimik3-darwin", 100);
    var damped = std.StringHashMap(void).init(aa);
    try damped.put("kilo-deepseek-deepseekv4pro-darwin", {});

    var fg = dev.FreeGrid.empty(aa);
    var grids = dev.FeasibilityGrids.empty(aa);
    const result = try dev.expandEntry(testing.io, aa, &fg, &grids, .{ .mode = "from-identity" }, "darwin", &damped);
    try testing.expectEqual(@as(usize, 1), result.host_candidates.len);
    try testing.expectEqualStrings("cline-clinepass-kimik3-darwin", result.host_candidates[0].fixture_id);
}

test "expandEntry: stale_by_harness_version + stale_by_detect_version read the capture meta" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // harness_version "1.2.3" in meta; the version probe would have to
    // run the (absent) `someharness` binary — probe failure ⇒ stale.
    try Universe.writeCapture("kilo-kilo-kimik3-darwin", 100, true);

    const hv = try expand(aa, .{ .mode = "from-capture", .stale_by_harness_version = true }, "darwin");
    try testing.expectEqual(@as(usize, 1), hv.host_candidates.len);
    // detect-version: meta says "test-version", this binary differs ⇒ stale
    const dv = try expand(aa, .{ .mode = "from-capture", .stale_by_detect_version = true }, "darwin");
    try testing.expectEqual(@as(usize, 1), dv.host_candidates.len);
}

// ---------------------------------------------------------------------------
// backlog refresh (folder scan)
// ---------------------------------------------------------------------------

test "refreshBacklogPure: unknown dims union in; resolved dims removed; needs_curation tracks argv" {
    try Universe.setup();
    defer Universe.teardown() catch {};
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try Universe.writeIdentity("zzz-unknownh-unknownp-darwin", 100); // unknown harness + provider
    try Universe.writeCapture("kilo-kilo-glm52-darwin", null, false); // no argv → needs_curation
    try Universe.writeCapture("kilo-kilo-kimik3-darwin", null, true); // curated

    var root = try emptyStoreRoot(aa);
    try dev.refreshBacklogPure(testing.io, aa, &root);

    const uh = try dev.backlogItems(aa, &root, "unknown_harnesses");
    try testing.expectEqual(@as(usize, 1), uh.len);
    try testing.expectEqualStrings("zzz", uh[0]);
    const up = try dev.backlogItems(aa, &root, "unknown_providers");
    try testing.expectEqual(@as(usize, 1), up.len);
    try testing.expectEqualStrings("unknownh", up[0]);
    const um = try dev.backlogItems(aa, &root, "unknown_models");
    try testing.expectEqual(@as(usize, 1), um.len);
    try testing.expectEqualStrings("unknownp", um[0]);
    const nc = try dev.backlogItems(aa, &root, "needs_curation");
    try testing.expectEqual(@as(usize, 1), nc.len);
    try testing.expectEqualStrings("kilo-kilo-glm52-darwin", nc[0]);

    // a resolvable slug pre-seeded into unknown_harnesses is removed;
    // a needs_curation id whose file now carries argv is removed.
    try dev.backlogUnionPure(aa, &root, "unknown_harnesses", &.{"kilo"});
    try dev.backlogUnionPure(aa, &root, "needs_curation", &.{"kilo-kilo-kimik3-darwin"});
    try dev.refreshBacklogPure(testing.io, aa, &root);
    const uh2 = try dev.backlogItems(aa, &root, "unknown_harnesses");
    try testing.expectEqual(@as(usize, 1), uh2.len); // kilo removed, zzz stays
    const nc2 = try dev.backlogItems(aa, &root, "needs_curation");
    try testing.expectEqual(@as(usize, 1), nc2.len);
}

// ---------------------------------------------------------------------------
// dequeue matching (mirror defaulting)
// ---------------------------------------------------------------------------

test "dequeueMatches: bare filter matches the composite entry; --refresh matches criteria-less" {
    const composite_entry: QueueEntry = .{ .harness = "kilo", .mode = "from-identity", .stale_by_output_drift = true, .stale_by_minutes = 27 * 24 * 60, .stale_by_harness_version = true, .stale_by_detect_version = true };
    const refresh_entry: QueueEntry = .{ .harness = "kilo", .mode = "from-identity" };
    const explicit_entry: QueueEntry = .{ .harness = "kilo", .mode = "from-identity", .stale_by_detect_version = true };

    // a bare dequeue filter stamps the composite → matches the bare upsert
    try testing.expect(dev.dequeueMatches(.{ .harness = "kilo" }, composite_entry));
    try testing.expect(!dev.dequeueMatches(.{ .harness = "kilo" }, refresh_entry));
    // --refresh on dequeue matches criteria-less entries
    try testing.expect(dev.dequeueMatches(.{ .harness = "kilo", .refresh = true }, refresh_entry));
    try testing.expect(!dev.dequeueMatches(.{ .harness = "kilo", .refresh = true }, composite_entry));
    // explicit flags match entries carrying exactly those criteria
    try testing.expect(dev.dequeueMatches(.{ .harness = "kilo", .stale_by_detect_version = true }, explicit_entry));
    try testing.expect(!dev.dequeueMatches(.{ .harness = "kilo", .stale_by_detect_version = true }, composite_entry));
    // dims constrain
    try testing.expect(!dev.dequeueMatches(.{ .harness = "cline" }, composite_entry));
    // free matches when set
    try testing.expect(dev.dequeueMatches(.{ .harness = "kilo", .free = true }, .{ .harness = "kilo", .mode = "from-identity", .free = true, .stale_by_output_drift = true, .stale_by_minutes = 27 * 24 * 60, .stale_by_harness_version = true, .stale_by_detect_version = true }));
}
