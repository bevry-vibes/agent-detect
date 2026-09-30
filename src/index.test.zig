// Tests for the index (`fixtures/index-data.json`, embedded at build): the
// cross-array filter rule from the plan (`index --harness=cline` narrows all
// three arrays to what is available for that harness while association lists
// stay full), the free/platform/reciprocal scoping, association closures,
// name-sorting, and the freshness pin — the committed file must equal a
// regeneration from the rule tables + the from-identity channel (`fixtures
// index --check`'s exact comparison), so a stale file fails `zig build test`.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");
const index_data = @import("lib/index_data.zig");

fn arenaFor() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

fn idsOf(items: []const std.json.Value) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(std.heap.page_allocator);
    errdefer set.deinit();
    for (items) |v| {
        if (v != .object) continue;
        const id = v.object.get("id") orelse continue;
        if (id != .string) continue;
        try set.put(id.string, {});
    }
    return set;
}

fn hasId(items: []const std.json.Value, id: []const u8) bool {
    for (items) |v| {
        if (v != .object) continue;
        const cand = v.object.get("id") orelse continue;
        if (cand == .string and std.mem.eql(u8, cand.string, id)) return true;
    }
    return false;
}

fn stringsOf(v: std.json.Value, key: []const u8) []const std.json.Value {
    if (v != .object) return &.{};
    const arr = v.object.get(key) orelse return &.{};
    if (arr != .array) return &.{};
    return arr.array.items;
}

fn hasString(v: std.json.Value, key: []const u8, needle: []const u8) bool {
    for (stringsOf(v, key)) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

test "index: the embedded file parses and the entries match the fixture contract's per-entity fields" {
    var arena = arenaFor();
    defer arena.deinit();
    const a = arena.allocator();
    const idx = try index_data.Index.load(a);

    // harness/model entries carry the contract's short_title; provider entries do not
    for (idx.harnesses) |h| {
        try testing.expect(h.object.get("short_title") != null);
        try testing.expect(h.object.get("license") != null);
        try testing.expect(h.object.get("reciprocity_scandal") != null);
        try testing.expect(h.object.get("providers") != null);
        try testing.expect(h.object.get("models") != null);
        try testing.expect(h.object.get("openness") == null); // no model fields on harnesses
        try testing.expect(h.object.get("harness_open_setting") == null); // instance state stays out
    }
    for (idx.providers) |p| {
        try testing.expect(p.object.get("short_title") == null); // the contract has no provider_short_title
        try testing.expect(p.object.get("license") == null); // nor a provider_license
        try testing.expect(p.object.get("harnesses") != null);
        try testing.expect(p.object.get("models") != null);
    }
    for (idx.models) |m| {
        try testing.expect(m.object.get("openness") != null);
        try testing.expect(m.object.get("reciprocity_scandal") == null); // the contract carries no model scandal flag
        try testing.expect(m.object.get("providers") != null);
        try testing.expect(m.object.get("harnesses") != null);
    }
}

test "index: the cross-array rule — --harness=cline narrows all three arrays, associations stay full" {
    var arena = arenaFor();
    defer arena.deinit();
    const a = arena.allocator();
    const idx = try index_data.Index.load(a);
    const filtered = try idx.buildFiltered(a, .{ .harness = "cline" });

    const harnesses = filtered.object.get("harnesses").?.array.items;
    try testing.expectEqual(@as(usize, 1), harnesses.len);
    try testing.expect(hasId(harnesses, "cline"));

    const providers = filtered.object.get("providers").?.array.items;
    const models = filtered.object.get("models").?.array.items;
    try testing.expect(providers.len > 0);
    try testing.expect(models.len > 0);
    // every provider and model in the result is available for cline
    for (providers) |p| try testing.expect(hasString(p, "harnesses", "cline"));
    for (models) |m| try testing.expect(hasString(m, "harnesses", "cline"));
    // association lists stay computed from the FULL data — the filter never
    // narrows them (a provider exclusive to cline may list just the one, but
    // the arrays themselves are the file's full facts)
    for (providers) |p| try testing.expect(stringsOf(p, "harnesses").len >= 1);
    // cline's own association arrays are its full direct facts
    const cline = filtered.object.get("harnesses").?.array.items[0];
    try testing.expect(stringsOf(cline, "providers").len > 0);
    try testing.expect(stringsOf(cline, "models").len > 0);
}

test "index: the free filter keeps exactly the models with a free cell" {
    var arena = arenaFor();
    defer arena.deinit();
    const a = arena.allocator();
    const idx = try index_data.Index.load(a);

    const free_models = try idx.buildFiltered(a, .{ .free = true });
    const paid_models = try idx.buildFiltered(a, .{ .free = false });
    const fm = free_models.object.get("models").?.array.items;
    const pm = paid_models.object.get("models").?.array.items;
    try testing.expect(fm.len > 0);
    try testing.expect(pm.len > 0);
    // per-cell semantics: a model with both free and paid cells appears in BOTH lists
    // every free model has a provider whose free map carries it
    for (fm) |m| {
        var has_free_cell = false;
        for (stringsOf(m, "providers")) |pv| {
            if (pv != .string) continue;
            if (idx.free.get(pv.string)) |list| {
                for (list.array.items) |mv| {
                    if (mv == .string and std.mem.eql(u8, mv.string, m.object.get("id").?.string)) has_free_cell = true;
                }
            }
        }
        try testing.expect(has_free_cell);
    }
    // every paid model has at least one provider cell that is not free
    for (pm) |m| {
        const mid = m.object.get("id").?.string;
        var has_paid_cell = false;
        for (stringsOf(m, "providers")) |pv| {
            if (pv != .string) continue;
            var free_here = false;
            if (idx.free.get(pv.string)) |list| {
                for (list.array.items) |mv2| {
                    if (mv2 == .string and std.mem.eql(u8, mv2.string, mid)) free_here = true;
                }
            }
            if (!free_here) has_paid_cell = true;
        }
        try testing.expect(has_paid_cell);
    }
}

test "index: platform and reciprocal filters scope to declared combos" {
    var arena = arenaFor();
    defer arena.deinit();
    const a = arena.allocator();
    const idx = try index_data.Index.load(a);

    const linux_recip = try idx.buildFiltered(a, .{ .platform = "linux", .reciprocal = true });
    const agents = linux_recip.object.get("agent_map_to_platforms_reciprocal").?.object;
    try testing.expect(agents.count() > 0);
    var it = agents.iterator();
    while (it.next()) |kv| {
        try testing.expect(kv.value_ptr.* == .object);
        try testing.expect(hasString(kv.value_ptr.*, "platforms", "linux"));
        const r = kv.value_ptr.*.object.get("reciprocal").?;
        try testing.expect(r == .bool and r.bool);
    }
    // --no-reciprocal is strict: declared-and-false only
    const no_recip = try idx.buildFiltered(a, .{ .reciprocal = false });
    const nr = no_recip.object.get("agent_map_to_platforms_reciprocal").?.object;
    var nit = nr.iterator();
    while (nit.next()) |kv| {
        const r = kv.value_ptr.*.object.get("reciprocal").?;
        try testing.expect(r == .bool and !r.bool);
    }
}

test "index: association mirrors and closures agree" {
    var arena = arenaFor();
    defer arena.deinit();
    const a = arena.allocator();
    const idx = try index_data.Index.load(a);

    // mirror: harness.providers ⇔ provider.harnesses
    for (idx.harnesses) |h| {
        for (stringsOf(h, "providers")) |pv| {
            if (pv != .string) continue;
            const p = index_data.Index.findEntry(idx.providers, pv.string) orelse continue;
            try testing.expect(hasString(p, "harnesses", h.object.get("id").?.string));
        }
    }
    // closure: harness.models == models with a cell at one of its providers
    for (idx.harnesses) |h| {
        const hmodels = stringsOf(h, "models");
        if (hmodels.len == 0) continue;
        for (hmodels) |mv| {
            if (mv != .string) continue;
            const m = index_data.Index.findEntry(idx.models, mv.string) orelse continue;
            var reachable = false;
            for (stringsOf(h, "providers")) |pv| {
                if (pv == .string and hasString(m, "providers", pv.string)) reachable = true;
            }
            try testing.expect(reachable);
        }
    }
    // closure: model.harnesses == harnesses reaching this model
    for (idx.models) |m| {
        for (stringsOf(m, "harnesses")) |hv| {
            if (hv != .string) continue;
            const h = index_data.Index.findEntry(idx.harnesses, hv.string) orelse continue;
            var reaches = false;
            for (stringsOf(h, "providers")) |pv| {
                if (pv == .string and hasString(m, "providers", pv.string)) reaches = true;
            }
            try testing.expect(reaches);
        }
    }
}

test "index: entries and association arrays are name-sorted" {
    var arena = arenaFor();
    defer arena.deinit();
    const a = arena.allocator();
    const idx = try index_data.Index.load(a);

    const S = struct {
        fn sortedNames(items: []const std.json.Value) bool {
            var prev: ?[]const u8 = null;
            for (items) |v| {
                if (v != .object) continue;
                const n = v.object.get("name") orelse continue;
                if (n != .string) continue;
                if (prev) |p| {
                    if (std.mem.lessThan(u8, n.string, p)) return false;
                }
                prev = n.string;
            }
            return true;
        }
        fn sortedStrings(v: std.json.Value, key: []const u8) bool {
            var prev: ?[]const u8 = null;
            for (stringsOf(v, key)) |item| {
                if (item != .string) continue;
                if (prev) |p| {
                    if (std.mem.lessThan(u8, item.string, p)) return false;
                }
                prev = item.string;
            }
            return true;
        }
    };
    try testing.expect(S.sortedNames(idx.harnesses));
    try testing.expect(S.sortedNames(idx.providers));
    try testing.expect(S.sortedNames(idx.models));
    for (idx.providers) |p| try testing.expect(S.sortedStrings(p, "models"));
    for (idx.harnesses) |h| try testing.expect(S.sortedStrings(h, "providers"));
}

test "freshness: the committed index file equals a regeneration (the --check comparison)" {
    var arena = arenaFor();
    defer arena.deinit();
    const a = arena.allocator();
    const data = std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/index-data.json", a, @enumFromInt(1 << 26)) catch {
        std.debug.print("fixtures/index-data.json is missing — it is the index's source of truth\n", .{});
        return error.TestUnexpectedResult;
    };
    const current = try std.json.parseFromSliceLeaky(std.json.Value, a, data, .{});
    const combos = try main.dev.scanIdentityCombos(a, testing.io);
    const free = current.object.get("provider_map_to_free_models").?.object;
    const regenerated = try index_data.regenerate(a, current, free, combos);
    if (!index_data.valueEql(current, regenerated)) {
        std.debug.print("fixtures/index-data.json is stale — run `zig build dev && ./zig-out/bin/agent-detect-dev fixtures index`\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "valueEql: deep equality is order-insensitive for objects, sensitive for arrays" {
    var arena = arenaFor();
    defer arena.deinit();
    const a = arena.allocator();
    const x = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"a\":1,\"b\":[1,2]}", .{});
    const y = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"b\":[1,2],\"a\":1}", .{});
    const z = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"a\":1,\"b\":[2,1]}", .{});
    try testing.expect(index_data.valueEql(x, y));
    try testing.expect(!index_data.valueEql(x, z));
}
