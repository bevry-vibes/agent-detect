// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

//! The index — `fixtures/index-data.json`, embedded at build time, is the single
//! association + property source for the `index` action (and, dev-side, the
//! feasibility grids and the free axis). One shape everywhere: the committed
//! file, this action's output, and the website's `data/index.json`.
//!
//! Entry fields are the from-identity fixture's per-entity `identify` slice
//! (unprefixed), minus the instance state declared fixtures do not carry (the
//! `*_setting` fields, the per-entity `*_reciprocity` deductions, and the
//! combo-level `agent_id`/`reciprocal`), plus `variations`. Associations are
//! plain canonical-id arrays: direct facts are hand-maintained (harness
//! `providers`, provider `models`), every other direction is derived.
//! `provider_map_to_free_models` is the free axis;
//! `agent_map_to_platforms_reciprocal` carries the per-combo fixture facts the
//! released binary cannot know at runtime (captured platforms from the
//! from-capture stems + the declared reciprocity of record from the
//! from-identity channel, refreshed by the dev `fixtures index` action).

const std = @import("std");
const build_options = @import("build_options");
const rules = @import("rules.zig");

/// the filters every index flag maps onto — `null` = unconstrained.
/// Each filter is a predicate over feasible combos; given filters AND together.
pub const Filters = struct {
    harness: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// captured platform the combo must carry (platforms with captures)
    platform: ?[]const u8 = null,
    /// membership in `provider_map_to_free_models`
    free: ?bool = null,
    /// the combo's reciprocity of record (declared combos only)
    reciprocal: ?bool = null,
};

pub const ComboFacts = struct {
    platforms: []const []const u8,
    reciprocal: bool,
};

pub const Index = struct {
    harnesses: []const std.json.Value,
    providers: []const std.json.Value,
    models: []const std.json.Value,
    free: std.json.ObjectMap,
    agents: std.json.ObjectMap,

    pub fn load(a: std.mem.Allocator) !Index {
        return parse(a, build_options.index_data);
    }

    pub fn parse(a: std.mem.Allocator, data: []const u8) !Index {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return error.IndexDataInvalid;
        if (parsed != .object) return error.IndexDataInvalid;
        const obj = parsed.object;
        const free_v = obj.get("provider_map_to_free_models") orelse return error.IndexDataInvalid;
        const agents_v = obj.get("agent_map_to_platforms_reciprocal") orelse return error.IndexDataInvalid;
        if (free_v != .object or agents_v != .object) return error.IndexDataInvalid;
        return .{
            .harnesses = try valuesOf(obj, "harnesses"),
            .providers = try valuesOf(obj, "providers"),
            .models = try valuesOf(obj, "models"),
            .free = free_v.object,
            .agents = agents_v.object,
        };
    }

    fn valuesOf(obj: std.json.ObjectMap, key: []const u8) ![]const std.json.Value {
        const arr = obj.get(key) orelse return error.IndexDataInvalid;
        if (arr != .array) return error.IndexDataInvalid;
        return arr.array.items;
    }

    fn entryId(v: std.json.Value) ?[]const u8 {
        if (v != .object) return null;
        const id = v.object.get("id") orelse return null;
        if (id != .string) return null;
        return id.string;
    }

    /// the entry in `items` whose `id` matches, or null
    pub fn findEntry(items: []const std.json.Value, id: []const u8) ?std.json.Value {
        for (items) |v| {
            const cand = entryId(v) orelse continue;
            if (std.mem.eql(u8, cand, id)) return v;
        }
        return null;
    }

    /// `provider_map_to_free_models` membership
    pub fn freeHas(self: *const Index, provider: []const u8, model: []const u8) bool {
        const list = self.free.get(provider) orelse return false;
        if (list != .array) return false;
        for (list.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, model)) return true;
        }
        return false;
    }

    /// `agent_map_to_platforms_reciprocal` lookup
    pub fn agentFacts(self: *const Index, a: std.mem.Allocator, agent: []const u8) ?ComboFacts {
        const v = self.agents.get(agent) orelse return null;
        if (v != .object) return null;
        const platforms = v.object.get("platforms") orelse return null;
        if (platforms != .array) return null;
        var out: std.ArrayList([]const u8) = .empty;
        for (platforms.array.items) |item| {
            if (item == .string) out.append(a, item.string) catch return null;
        }
        const reciprocal = if (v.object.get("reciprocal")) |r| (r == .bool and r.bool) else false;
        return .{ .platforms = out.items, .reciprocal = reciprocal };
    }

    /// does the (harness, provider, model) combo satisfy every given filter?
    pub fn comboQualifies(self: *const Index, a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, f: Filters) bool {
        if (f.harness) |v| {
            if (!std.mem.eql(u8, h, v)) return false;
        }
        if (f.provider) |v| {
            if (!std.mem.eql(u8, p, v)) return false;
        }
        if (f.model) |v| {
            if (!std.mem.eql(u8, m, v)) return false;
        }
        if (f.platform != null or f.reciprocal != null) {
            var buf: [256]u8 = undefined;
            const agent = std.fmt.bufPrint(&buf, "{s}-{s}-{s}", .{ h, p, m }) catch return false;
            const facts = self.agentFacts(a, agent) orelse return false;
            if (f.platform) |plat| {
                var hit = false;
                for (facts.platforms) |cand| {
                    if (std.mem.eql(u8, cand, plat)) {
                        hit = true;
                        break;
                    }
                }
                if (!hit) return false;
            }
            if (f.reciprocal) |want| {
                if (facts.reciprocal != want) return false;
            }
        }
        if (f.free) |want| {
            if (self.freeHas(p, m) != want) return false;
        }
        return true;
    }

    const Participation = struct {
        harnesses: std.StringHashMap(void),
        providers: std.StringHashMap(void),
        models: std.StringHashMap(void),
        agents: std.json.ObjectMap,
    };

    /// walk the feasible universe (harness pairs × provider cells), collecting the
    /// combos that satisfy every filter and the entries participating in one.
    fn participation(self: *const Index, a: std.mem.Allocator, f: Filters) !Participation {
        var out: Participation = .{
            .harnesses = std.StringHashMap(void).init(a),
            .providers = std.StringHashMap(void).init(a),
            .models = std.StringHashMap(void).init(a),
            .agents = .empty,
        };
        for (self.harnesses) |hv| {
            const h = entryId(hv) orelse continue;
            if (hv != .object) continue;
            const hprov = hv.object.get("providers") orelse continue;
            if (hprov != .array) continue;
            for (hprov.array.items) |pv| {
                if (pv != .string) continue;
                const p = pv.string;
                const pent = findEntry(self.providers, p) orelse continue;
                if (pent != .object) continue;
                const pmodels = pent.object.get("models") orelse continue;
                if (pmodels != .array) continue;
                for (pmodels.array.items) |mv| {
                    if (mv != .string) continue;
                    const m = mv.string;
                    if (!self.comboQualifies(a, h, p, m, f)) continue;
                    try out.harnesses.put(h, {});
                    try out.providers.put(p, {});
                    try out.models.put(m, {});
                    var buf: [256]u8 = undefined;
                    const agent = std.fmt.bufPrint(&buf, "{s}-{s}-{s}", .{ h, p, m }) catch continue;
                    if (self.agents.get(agent)) |facts| {
                        try out.agents.put(a, try a.dupe(u8, agent), facts);
                    } else {
                        // a qualifying combo with no recorded facts: impossible under
                        // platform/reciprocal filters, ordinary without them
                        var empty: std.json.ObjectMap = .empty;
                        try empty.put(a, "platforms", .{ .array = std.json.Array.init(a) });
                        try empty.put(a, "reciprocal", .{ .bool = false });
                        try out.agents.put(a, try a.dupe(u8, agent), .{ .object = empty });
                    }
                }
            }
        }
        return out;
    }

    /// the filtered index — same `IndexFile` shape; the three arrays keep the
    /// entries participating in ≥1 qualifying combo, `agent_map_to_platforms_reciprocal`
    /// keeps the qualifying combos, and the association arrays stay full.
    pub fn buildFiltered(self: *const Index, a: std.mem.Allocator, f: Filters) !std.json.Value {
        const part = try self.participation(a, f);
        var root: std.json.ObjectMap = .empty;
        try root.put(a, "harnesses", try filteredArray(a, self.harnesses, &part.harnesses));
        try root.put(a, "providers", try filteredArray(a, self.providers, &part.providers));
        try root.put(a, "models", try filteredArray(a, self.models, &part.models));
        try root.put(a, "provider_map_to_free_models", .{ .object = self.free });
        try root.put(a, "agent_map_to_platforms_reciprocal", .{ .object = part.agents });
        return .{ .object = root };
    }
};

fn filteredArray(a: std.mem.Allocator, items: []const std.json.Value, keep: *const std.StringHashMap(void)) !std.json.Value {
    var out = std.json.Array.init(a);
    for (items) |v| {
        if (v != .object) continue;
        const id = v.object.get("id") orelse continue;
        if (id != .string) continue;
        if (keep.contains(id.string)) try out.append(v);
    }
    return .{ .array = out };
}

/// deep, order-insensitive-for-objects equality of two parsed JSON values —
/// `fixtures index --check` compares the committed file against a regeneration.
pub fn valueEql(x: std.json.Value, y: std.json.Value) bool {
    switch (x) {
        .null => return y == .null,
        .bool => |b| return y == .bool and y.bool == b,
        .integer => |i| {
            if (y == .integer) return y.integer == i;
            if (y == .float) return y.float == @as(f64, @floatFromInt(i));
            return false;
        },
        .float => |fl| {
            if (y == .integer) return fl == @as(f64, @floatFromInt(y.integer));
            return y == .float and y.float == fl;
        },
        .number_string => |s| return y == .number_string and std.mem.eql(u8, y.number_string, s),
        .string => |s| return y == .string and std.mem.eql(u8, y.string, s),
        .array => |arr| {
            if (y != .array or y.array.items.len != arr.items.len) return false;
            for (arr.items, y.array.items) |xi, yi| {
                if (!valueEql(xi, yi)) return false;
            }
            return true;
        },
        .object => |obj| {
            if (y != .object or y.object.count() != obj.count()) return false;
            var it = obj.iterator();
            while (it.next()) |kv| {
                const yv = y.object.get(kv.key_ptr.*) orelse return false;
                if (!valueEql(kv.value_ptr.*, yv)) return false;
            }
            return true;
        },
    }
}

// ============================================================================
// regeneration — the dev `fixtures index` action rebuilds the file in place:
// the hand-maintained direct facts survive (harness `providers`, provider
// `models`, `provider_map_to_free_models`), everything else derives from the
// rule tables and the caller's freshly scanned identity facts.

fn lessThanStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// ordered id set — accumulates, then finalizes byte-sorted (the same order the
/// migration and the website produce, so regeneration reproduces the file)
const IdSet = struct {
    set: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn add(self: *IdSet, a: std.mem.Allocator, id: []const u8) !void {
        try self.set.put(a, id, {});
    }
    fn value(self: *const IdSet, a: std.mem.Allocator) !std.json.Value {
        var list: std.ArrayList([]const u8) = .empty;
        var it = self.set.iterator();
        while (it.next()) |kv| try list.append(a, kv.key_ptr.*);
        std.mem.sort([]const u8, list.items, {}, lessThanStr);
        var arr = std.json.Array.init(a);
        for (list.items) |item| try arr.append(.{ .string = item });
        return .{ .array = arr };
    }
};

fn stringArrayValue(a: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var arr = std.json.Array.init(a);
    for (items) |item| try arr.append(.{ .string = item });
    return .{ .array = arr };
}

/// the entity fields for one entry from its rule — the from-identity fixture's
/// per-entity `identify` slice (unprefixed), minus instance state, plus
/// `variations`. The contract carries `short_title` for harnesses and models
/// only (there is no `provider_short_title`), `license` for harnesses and
/// models only, and `openness` for models only.
fn putEntityFields(a: std.mem.Allocator, obj: *std.json.ObjectMap, comptime T: type, rule: T) !void {
    try obj.put(a, "label", .{ .string = rule.label });
    if (T != rules.ProviderRule) {
        try obj.put(a, "short_title", if (rule.short_title) |s| .{ .string = s } else .null);
    }
    try obj.put(a, "name", .{ .string = rule.name });
    try obj.put(a, "id", .{ .string = try rules.slugId(a, rule.name) });
    if (@hasField(T, "openness")) {
        try obj.put(a, "openness", if (rule.openness) |s| .{ .string = s } else .null);
    }
    if (@hasField(T, "license")) {
        try obj.put(a, "license", if (rule.license) |s| .{ .string = s } else .null);
    }
    try obj.put(a, "open_training", if (rule.open_training) |s| .{ .string = s } else .null);
    try obj.put(a, "closed_training", if (rule.closed_training) |s| .{ .string = s } else .null);
    if (@hasField(T, "reciprocity_scandal")) {
        try obj.put(a, "reciprocity_scandal", .{ .bool = rule.reciprocity_scandal });
    }
    try obj.put(a, "variations", try stringArrayValue(a, rule.variations));
}

/// regenerate the full index value from the rule tables + the caller's direct
/// facts. `current` is the parsed on-disk file (its direct arrays may carry
/// unresolvable ids — they are preserved verbatim and simply never mirror or
/// close); `combos` is the freshly scanned `agent_map_to_platforms_reciprocal`
/// object; `free` is the hand-maintained free axis.
pub fn regenerate(
    a: std.mem.Allocator,
    current: ?std.json.Value,
    free: std.json.ObjectMap,
    combos: std.json.ObjectMap,
) !std.json.Value {
    // the two hand-maintained directions, entry-id keyed, stored order preserved
    var direct_harness_providers: std.StringArrayHashMapUnmanaged(std.json.Array) = .empty;
    var direct_provider_models: std.StringArrayHashMapUnmanaged(std.json.Array) = .empty;
    if (current) |cv| {
        if (cv == .object) {
            if (cv.object.get("harnesses")) |arr| {
                if (arr == .array) {
                    for (arr.array.items) |entry| {
                        if (entry != .object) continue;
                        const id = entry.object.get("id") orelse continue;
                        if (id != .string) continue;
                        const prov = entry.object.get("providers") orelse continue;
                        if (prov != .array) continue;
                        try direct_harness_providers.put(a, id.string, prov.array);
                    }
                }
            }
            if (cv.object.get("providers")) |arr| {
                if (arr == .array) {
                    for (arr.array.items) |entry| {
                        if (entry != .object) continue;
                        const id = entry.object.get("id") orelse continue;
                        if (id != .string) continue;
                        const mods = entry.object.get("models") orelse continue;
                        if (mods != .array) continue;
                        try direct_provider_models.put(a, id.string, mods.array);
                    }
                }
            }
        }
    }

    // derived accumulators (finalized sorted)
    var provider_harnesses: std.StringArrayHashMapUnmanaged(IdSet) = .empty; // mirror of harness providers
    var model_providers: std.StringArrayHashMapUnmanaged(IdSet) = .empty; // mirror of provider models
    var harness_models: std.StringArrayHashMapUnmanaged(IdSet) = .empty; // closure over its providers' cells
    var model_harnesses: std.StringArrayHashMapUnmanaged(IdSet) = .empty; // closure over its providers' harnesses

    var harnesses_arr = std.json.Array.init(a);
    for (rules.rulesForHarnesses) |rule| {
        const id = try rules.slugId(a, rule.name);
        var obj: std.json.ObjectMap = .empty;
        try putEntityFields(a, &obj, rules.HarnessRule, rule);
        if (direct_harness_providers.get(id)) |direct| {
            for (direct.items) |pv| {
                if (pv != .string) continue;
                const gop = try provider_harnesses.getOrPut(a, pv.string);
                if (!gop.found_existing) gop.value_ptr.* = IdSet{};
                try gop.value_ptr.add(a, id);
            }
            try obj.put(a, "providers", .{ .array = direct });
        } else {
            try obj.put(a, "providers", .{ .array = std.json.Array.init(a) });
        }
        try harnesses_arr.append(.{ .object = obj });
    }

    var providers_arr = std.json.Array.init(a);
    for (rules.rulesForProviders) |rule| {
        const id = try rules.slugId(a, rule.name);
        var obj: std.json.ObjectMap = .empty;
        try putEntityFields(a, &obj, rules.ProviderRule, rule);
        if (direct_provider_models.get(id)) |direct| {
            for (direct.items) |mv| {
                if (mv != .string) continue;
                const gop = try model_providers.getOrPut(a, mv.string);
                if (!gop.found_existing) gop.value_ptr.* = IdSet{};
                try gop.value_ptr.add(a, id);
            }
            try obj.put(a, "models", .{ .array = direct });
        } else {
            try obj.put(a, "models", .{ .array = std.json.Array.init(a) });
        }
        try providers_arr.append(.{ .object = obj });
    }

    var models_arr = std.json.Array.init(a);
    for (rules.rulesForModels) |rule| {
        var obj: std.json.ObjectMap = .empty;
        try putEntityFields(a, &obj, rules.ModelRule, rule);
        try models_arr.append(.{ .object = obj });
    }

    // pass 2: the derived directions. Iterating the freshly built entries keeps
    // the id sources authoritative (the rule tables), while the mirrors collect
    // every rule-referencing fact.
    for (harnesses_arr.items) |*hv| {
        const id = hv.object.get("id").?.string;
        var closure = IdSet{};
        const direct = direct_harness_providers.get(id);
        if (direct) |providers| {
            for (providers.items) |pv| {
                if (pv != .string) continue;
                const pent = Index.findEntry(providers_arr.items, pv.string) orelse continue;
                if (pent.object.get("models")) |cells| {
                    if (cells != .array) continue;
                    for (cells.array.items) |mv| {
                        if (mv == .string) try closure.add(a, mv.string);
                    }
                }
            }
        }
        try harness_models.put(a, id, closure);
    }
    for (providers_arr.items) |*pv| {
        const id = pv.object.get("id").?.string;
        if (provider_harnesses.getPtr(id)) |mirror| {
            try pv.object.put(a, "harnesses", try mirror.value(a));
        } else {
            try pv.object.put(a, "harnesses", .{ .array = std.json.Array.init(a) });
        }
    }
    for (models_arr.items) |*mv| {
        const id = mv.object.get("id").?.string;
        var closure = IdSet{};
        if (model_providers.getPtr(id)) |mirror| {
            try mv.object.put(a, "providers", try mirror.value(a));
            var it = mirror.set.iterator();
            while (it.next()) |kv| {
                const pent = Index.findEntry(providers_arr.items, kv.key_ptr.*) orelse continue;
                const hlist = pent.object.get("harnesses") orelse continue;
                if (hlist != .array) continue;
                for (hlist.array.items) |hv| {
                    if (hv == .string) try closure.add(a, hv.string);
                }
            }
        } else {
            try mv.object.put(a, "providers", .{ .array = std.json.Array.init(a) });
        }
        try model_harnesses.put(a, id, closure);
    }
    for (harnesses_arr.items) |*hv| {
        const id = hv.object.get("id").?.string;
        try hv.object.put(a, "models", try harness_models.getPtr(id).?.value(a));
    }
    for (models_arr.items) |*mv| {
        const id = mv.object.get("id").?.string;
        try mv.object.put(a, "harnesses", try model_harnesses.getPtr(id).?.value(a));
    }

    var root: std.json.ObjectMap = .empty;
    try root.put(a, "harnesses", try sortEntriesByName(a, harnesses_arr));
    try root.put(a, "providers", try sortEntriesByName(a, providers_arr));
    try root.put(a, "models", try sortEntriesByName(a, models_arr));
    try root.put(a, "provider_map_to_free_models", .{ .object = free });
    try root.put(a, "agent_map_to_platforms_reciprocal", .{ .object = combos });
    return .{ .object = root };
}

fn sortEntriesByName(a: std.mem.Allocator, arr: std.json.Array) !std.json.Value {
    var list: std.ArrayList(std.json.Value) = .empty;
    try list.appendSlice(a, arr.items);
    const Ctx = struct {
        fn nameOf(v: std.json.Value) []const u8 {
            if (v != .object) return "";
            const n = v.object.get("name") orelse return "";
            if (n != .string) return "";
            return n.string;
        }
        fn lessThan(_: void, x: std.json.Value, y: std.json.Value) bool {
            return std.mem.lessThan(u8, nameOf(x), nameOf(y));
        }
    };
    std.mem.sort(std.json.Value, list.items, {}, Ctx.lessThan);
    var out = std.json.Array.init(a);
    try out.appendSlice(list.items);
    return .{ .array = out };
}
