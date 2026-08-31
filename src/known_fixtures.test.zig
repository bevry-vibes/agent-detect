// Schema/shape tests for the fixture files under `fixtures/from-identity/`
// and `fixtures/from-capture/` (the `{ outputs, meta }` envelope — see
// fixtures/fixture.d.ts) and the committed `fixtures/.index.json` state
// store (see fixtures/.index.d.ts). See DESIGN.md for the fixture
// lifecycle (daemon + capture + .index.json store) and CONTRIBUTING.md
// for adding agents to the rule registry.
//
// The suite validates committed-file shape only. The per-folder universe
// is the union of the two folders' filename stems; channel presence =
// file existence — no JSON parse needed. Dot-files (the grids, the
// store, the log) are skipped; the subfolders are scanned only as their
// own universes.
//
// Pre-migration gate: until the store-v2 migration lands (per-channel
// folders + the slimmed store), the folder/store tests skip gracefully —
// the legacy flat-layout tree cannot satisfy them.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

const identity_dir = "fixtures/from-identity";
const capture_dir = "fixtures/from-capture";

/// Discover every `<stem>.json` fixture file in one channel folder,
/// returning the stems (sorted for deterministic iteration).
fn discoverFolderStems(a: std.mem.Allocator, folder: []const u8) ![][]u8 {
    var stems: std.ArrayList([]u8) = .empty;

    var dir = std.Io.Dir.cwd().openDir(testing.io, folder, .{ .iterate = true }) catch return stems.toOwnedSlice(a) catch &.{};
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (it.next(testing.io) catch null) |ent| {
        if (ent.kind != .file) continue;
        const name = ent.name;
        const suffix = ".json";
        if (name.len <= suffix.len or !std.mem.endsWith(u8, name, suffix)) continue;
        const stem = name[0 .. name.len - suffix.len];
        if (stem.len == 0 or stem[0] == '.') continue; // temp files, nothing else
        try stems.append(a, try a.dupe(u8, stem));
    }
    const out = try stems.toOwnedSlice(a);
    std.mem.sort([]u8, out, {}, struct {
        fn less(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return out;
}

/// both folders' stems (the known universe). Caller frees.
fn discoverStems(a: std.mem.Allocator) ![][]u8 {
    var stems: std.ArrayList([]u8) = .empty;
    for ([_][]const u8{ identity_dir, capture_dir }) |folder| {
        const add = try discoverFolderStems(a, folder);
        defer {
            for (add) |s| a.free(s);
            a.free(add);
        }
        outer: for (add) |s| {
            for (stems.items) |have| {
                if (std.mem.eql(u8, have, s)) continue :outer;
            }
            try stems.append(a, try a.dupe(u8, s));
        }
    }
    return stems.toOwnedSlice(a);
}

/// true when the store-v2 layout is on disk (per-channel folders exist).
fn newLayoutPresent(a: std.mem.Allocator) bool {
    for ([_][]const u8{ identity_dir, capture_dir }) |folder| {
        var buf: [128]u8 = undefined;
        const marker = std.fmt.bufPrint(&buf, "{s}/.layout", .{folder}) catch return false;
        _ = marker;
        // probe: openDir on the folder itself
        var dir = std.Io.Dir.cwd().openDir(testing.io, folder, .{}) catch return false;
        dir.close(testing.io);
    }
    _ = a;
    return true;
}

/// Load a channel file as a parsed JSON value, or null if the file is
/// missing/unparseable (callers skip such fixtures gracefully — except
/// where the envelope test flags them).
fn readChannelParsed(a: std.mem.Allocator, folder: []const u8, stem: []const u8) !?std.json.Value {
    const path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ folder, stem });
    const data = std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, @enumFromInt(1 << 20)) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return null;
    return parsed.value;
}

/// Load the committed `fixtures/.index.json` store, or null when the
/// store is absent or not yet migrated to store_version 2 (the store
/// tests then skip).
fn readIndexParsed(a: std.mem.Allocator) !?std.json.Value {
    const data = std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/.index.json", a, @enumFromInt(1 << 26)) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return null;
    if (parsed.value != .object) return null;
    const sv = parsed.value.object.get("store_version") orelse return null;
    if (sv != .integer or sv.integer != 2) return null;
    return parsed.value;
}

/// The 18 canonical `identify` fields, in emission order. No `trailer`
/// key (the root trailer and the cooked trailer are gone).
const identify_keys = [_][]const u8{
    "harness_label", // harness group
    "harness_short_title",
    "harness_name",
    "harness_id",
    "harness_license",
    "provider_label", // provider group
    "provider_name",
    "provider_id",
    "provider_closed_training",
    "provider_open_training",
    "model_label", // model group
    "model_short_title",
    "model_name",
    "model_id",
    "model_reciprocity",
    "model_license",
    "agent_id", // composed from harness+provider+model
    "reciprocal", // policy / output
};

/// strict-slug equality: is `name`'s lowercase-alphanumeric slug equal
/// to `slug`? Mirrors `main.slugId` without allocating.
fn slugifyMatches(name: []const u8, slug: []const u8) bool {
    var i: usize = 0;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (i >= slug.len) return false;
        if (std.ascii.toLower(c) != slug[i]) return false;
        i += 1;
    }
    return i == slug.len;
}

/// split a `-`-separated fixture stem into exactly four non-empty parts.
fn split4(stem: []const u8) ?[4][]const u8 {
    var it = std.mem.tokenizeScalar(u8, stem, '-');
    const h = it.next() orelse return null;
    const p = it.next() orelse return null;
    const m = it.next() orelse return null;
    const plat = it.next() orelse return null;
    if (it.next() != null) return null;
    if (h.len == 0 or p.len == 0 or m.len == 0 or plat.len == 0) return null;
    return .{ h, p, m, plat };
}

test "fixtures: at least one fixture is committed" {
    if (!newLayoutPresent(testing.allocator)) return; // pre-migration
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const stems = try discoverStems(arena.allocator());
    // If this fails, capture new fixtures with `agent-detect-dev
    // fixtures capture` inside each harness session you're targeting,
    // then commit the resulting fixture files under `fixtures/from-capture/`.
    try testing.expect(stems.len >= 1);
}

test "fixtures: envelope shape — every channel file is exactly { outputs, meta }" {
    // from-identity files always carry `outputs` (identify + both
    // trailers); from-capture files carry `outputs` (…+ raw) OR are
    // curated meta-only stubs (`meta` with the launch argv, no
    // `outputs`). No other top-level keys exist — the directory IS the
    // channel.
    if (!newLayoutPresent(testing.allocator)) return; // pre-migration
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    for ([_][]const u8{ identity_dir, capture_dir }) |folder| {
        const stems = try discoverFolderStems(aa, folder);
        for (stems) |stem| {
            const root = (try readChannelParsed(aa, folder, stem)) orelse {
                std.debug.print("fixture {s}/{s}.json is unparseable\n", .{ folder, stem });
                return error.InvalidFixtureShape;
            };
            if (root != .object) return error.InvalidFixtureShape;
            const o = root.object;
            for (o.keys()) |key| {
                if (std.mem.eql(u8, key, "outputs") or std.mem.eql(u8, key, "meta")) continue;
                std.debug.print("fixture {s}/{s}.json has disallowed top-level key '{s}'\n", .{ folder, stem, key });
                return error.UnexpectedRootKey;
            }
            const outputs = o.get("outputs");
            const meta = o.get("meta") orelse {
                std.debug.print("fixture {s}/{s}.json has no meta object\n", .{ folder, stem });
                return error.MissingMeta;
            };
            if (meta != .object) return error.InvalidFixtureShape;
            const mo = meta.object;
            if (outputs) |out| {
                // output-bearing file: identify + both trailers, and the
                // full ledger meta.
                if (out != .object) return error.InvalidFixtureShape;
                const oo = out.object;
                const identify = oo.get("identify") orelse return error.MissingIdentify;
                if (identify != .object) return error.InvalidFixtureShape;
                try testing.expect(oo.get("trailer co-author") != null);
                try testing.expect(oo.get("trailer assisted-by") != null);
                if (std.mem.eql(u8, folder, identity_dir)) {
                    // from-identity outputs are exactly identify + trailers
                    try testing.expectEqual(@as(usize, 3), oo.count());
                    // meta: updated_at + agent_detect_version, nothing else
                    try testing.expectEqual(@as(usize, 2), mo.count());
                    try testing.expect(mo.get("updated_at") != null);
                    try testing.expect(mo.get("agent_detect_version") != null);
                } else {
                    // from-capture outputs may additionally carry raw
                    for (oo.keys()) |k| {
                        if (std.mem.eql(u8, k, "identify") or
                            std.mem.eql(u8, k, "trailer co-author") or
                            std.mem.eql(u8, k, "trailer assisted-by") or
                            std.mem.eql(u8, k, "raw")) continue;
                        std.debug.print("fixture {s}/{s}.json has unexpected outputs key '{s}'\n", .{ folder, stem, k });
                        return error.UnexpectedOutputKey;
                    }
                    // meta: updated_at + agent_detect_version (+ optional
                    // harness_version and launch argv — null-as-absent)
                    try testing.expect(mo.get("updated_at") != null);
                    try testing.expect(mo.get("agent_detect_version") != null);
                }
            } else {
                // meta-only curated stub: no outputs, meta carries the
                // launch argv (the curation of record) — nothing else.
                try testing.expect(std.mem.eql(u8, folder, capture_dir));
                for (mo.keys()) |k| {
                    if (std.mem.eql(u8, k, "prompt_launch") or std.mem.eql(u8, k, "version_launch")) continue;
                    std.debug.print("fixture {s}/{s}.json meta-only stub has unexpected meta key '{s}'\n", .{ folder, stem, k });
                    return error.UnexpectedStubMetaKey;
                }
                try testing.expect(mo.get("prompt_launch") != null);
            }
        }
    }
}

test "fixtures: identify has all 18 grouped keys in emission order, no trailer key" {
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const stems = try discoverStems(aa);
    for (stems) |stem| {
        const root = (try readChannelParsed(aa, identity_dir, stem)) orelse continue;
        const outputs = root.object.get("outputs") orelse continue;
        if (outputs != .object) continue;
        const identify = outputs.object.get("identify") orelse continue;
        if (identify != .object) continue;
        const cooked = identify.object;
        for (identify_keys, 0..) |key, i| {
            if (!cooked.contains(key)) {
                std.debug.print("fixture {s} missing identify key {s} at index {d}\n", .{ stem, key, i });
                return error.MissingCookedKey;
            }
        }
        try testing.expect(!cooked.contains("trailer"));
    }
}

test "fixtures: outputs.raw is the dev-raw schema — exactly the raw output keys" {
    // The from-capture `outputs.raw` block is the dev `raw` output
    // verbatim: platform_id, harness_version (null when not yet
    // knowable), detectable, detected, process_lineage, *-urls, evidence.
    // No env/file objects; secret env evidence is `<redacted>`. Pre-
    // keyset-growth fixtures may carry fewer keys — the check is "no
    // unexpected keys", and the queued regen sweeps bring older files up
    // to the full set.
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const fixed_keys = [_][]const u8{
        "platform_id",     "harness_version", "detectable",    "detected",
        "process_lineage", "harness-urls",    "provider-urls", "model-urls",
        "evidence",
    };
    const stems = try discoverFolderStems(aa, capture_dir);
    for (stems) |stem| {
        const root = (try readChannelParsed(aa, capture_dir, stem)) orelse continue;
        const outputs = root.object.get("outputs") orelse continue;
        if (outputs != .object) continue;
        const raw = outputs.object.get("raw") orelse continue;
        if (raw != .object) continue;
        const raw_o = raw.object;
        try testing.expect(!raw_o.contains("env"));
        try testing.expect(!raw_o.contains("detection"));
        try testing.expect(!raw_o.contains("session"));
        try testing.expect(!raw_o.contains("sources"));
        try testing.expect(!raw_o.contains("rule"));
        try testing.expect(!raw_o.contains("harness-env-markers"));
        try testing.expect(!raw_o.contains("harness-proc-names"));
        for (raw_o.keys()) |key| {
            var known = false;
            for (fixed_keys) |fk| {
                if (std.mem.eql(u8, key, fk)) known = true;
            }
            if (!known) {
                std.debug.print("fixture {s} has unexpected outputs.raw top-level key '{s}'\n", .{ stem, key });
                return error.UnexpectedRawKey;
            }
        }
        if (raw_o.get("platform_id")) |pid| try testing.expect(pid == .string and pid.string.len > 0);
        // evidence claims: env-source on non-allowlisted names → `<redacted>`.
        const evidence = raw_o.get("evidence") orelse continue;
        if (evidence != .array) continue;
        for (evidence.array.items) |ev| {
            if (ev != .object) continue;
            const eo = ev.object;
            const source = eo.get("source") orelse continue;
            if (source != .string or !std.mem.eql(u8, source.string, "env")) continue;
            const name = eo.get("name") orelse continue;
            if (name != .string) continue;
            const value = eo.get("value") orelse continue;
            try testing.expect(value == .string);
            if (!main.dev.isEnvValueAllowed(name.string)) {
                try testing.expectEqualStrings("<redacted>", value.string);
            } else {
                try testing.expect(!std.mem.eql(u8, value.string, "<redacted>"));
            }
        }
    }
}

test "fixtures: outputs.raw carries detectable + detected, process_lineage, and https *-urls" {
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const stems = try discoverFolderStems(aa, capture_dir);
    for (stems) |stem| {
        const root = (try readChannelParsed(aa, capture_dir, stem)) orelse continue;
        const outputs = root.object.get("outputs") orelse continue;
        if (outputs != .object) continue;
        const raw = outputs.object.get("raw") orelse continue;
        if (raw != .object) continue;
        const raw_o = raw.object;
        // process_lineage always present (at least agent-detect), entries
        // are subobjects with pid + name.
        if (raw_o.get("process_lineage")) |pl| {
            try testing.expect(pl == .array);
            try testing.expect(pl.array.items.len >= 1);
            for (pl.array.items) |entry| {
                const obj = entry.object;
                try testing.expect(obj.get("pid") != null);
                try testing.expect(obj.get("name") != null);
                try testing.expect(obj.get("name").? == .string);
                try testing.expect(obj.get("pid").? == .integer);
            }
        }
        // detectable/detected carry the three dims when present.
        if (raw_o.get("detectable")) |det| {
            try testing.expect(det == .array);
            try testing.expect(det.array.items.len == 3);
        }
        if (raw_o.get("detected")) |det| {
            try testing.expect(det == .array);
            try testing.expect(det.array.items.len == 3);
        }
        // *-urls arrays are arrays of https:// URLs (may be empty for
        // closed-source).
        inline for ([_][]const u8{ "harness-urls", "provider-urls", "model-urls" }) |key| {
            if (raw_o.get(key)) |arr| {
                try testing.expect(arr == .array);
                for (arr.array.items) |item| {
                    try testing.expect(item == .string);
                    try testing.expect(std.mem.startsWith(u8, item.string, "https://"));
                }
            }
        }
    }
}

test "fixtures: every fixture's identify has all 8 identity fields populated" {
    // The capture refuses to write a fixture with null provider or
    // null model, so every committed fixture has the harness+provider
    // +model triad populated. The four policy fields — harness_license,
    // model_reciprocity, provider_closed_training, provider_open_training
    // — may legitimately be `null` per the schema.
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const required_non_null = [_][]const u8{
        "harness_label",  "harness_name",
        "provider_label", "provider_name",
        "model_label",    "model_name",
        "reciprocal",
    };
    const stems = try discoverStems(aa);
    for (stems) |stem| {
        const root = (try readChannelParsed(aa, identity_dir, stem)) orelse continue;
        const outputs = root.object.get("outputs") orelse continue;
        if (outputs != .object) continue;
        const identify = outputs.object.get("identify") orelse continue;
        if (identify != .object) continue;
        const cooked = identify.object;
        for (required_non_null) |k| {
            if (cooked.get(k) == null) {
                std.debug.print("fixture {s} missing identify key {s}\n", .{ stem, k });
                return error.MissingCookedKey;
            }
            try testing.expect(cooked.get(k).? != .null);
        }
    }
}

test "fixtures: identify *_name fields are non-empty strings" {
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const id_fields = [_][]const u8{ "harness_name", "provider_name", "model_name" };
    const stems = try discoverStems(aa);
    for (stems) |stem| {
        const root = (try readChannelParsed(aa, identity_dir, stem)) orelse continue;
        const outputs = root.object.get("outputs") orelse continue;
        if (outputs != .object) continue;
        const identify = outputs.object.get("identify") orelse continue;
        if (identify != .object) continue;
        const cooked = identify.object;
        for (id_fields) |field| {
            const v = cooked.get(field) orelse continue;
            try testing.expect(v == .string);
            try testing.expect(v.string.len > 0);
        }
    }
}

test "fixtures: fixture JSON is pretty-printed (outputs/meta envelope, identify expanded)" {
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const stems = try discoverFolderStems(aa, identity_dir);
    for (stems) |stem| {
        const path = try std.fmt.allocPrint(aa, "{s}/{s}.json", .{ identity_dir, stem });
        const data = std.Io.Dir.cwd().readFileAlloc(testing.io, path, aa, @enumFromInt(1 << 20)) catch continue;

        // 1. the envelope objects; identify field per line.
        try testing.expect(std.mem.indexOf(u8, data, "\"outputs\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"meta\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "    \"harness_label\"") != null);

        // 2. both trailer variants present.
        try testing.expect(std.mem.indexOf(u8, data, "\"trailer co-author\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"trailer assisted-by\":") != null);

        // 3. no env block, no legacy cooked/raw/trailer top-level keys.
        try testing.expect(std.mem.indexOf(u8, data, "\"env\":") == null);
        try testing.expect(std.mem.indexOf(u8, data, "\"cooked\":") == null);
        try testing.expect(std.mem.indexOf(u8, data, "\"from-identity\":") == null);
        try testing.expect(std.mem.indexOf(u8, data, "\"from-capture\":") == null);
    }
}

test "fixtures: warn on null / NOASSERTION harness_license (dev should fill in from upstream)" {
    // Decision #1 — the license tri-state: `null` (no data) and
    // `NOASSERTION` (attempted, inconclusive) warn; `NONE` (concluded:
    // verified proprietary/closed) is a deliberate, valid value and must
    // NOT warn.
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var warnings: usize = 0;
    const stems = try discoverStems(aa);
    for (stems) |stem| {
        const root = (try readChannelParsed(aa, identity_dir, stem)) orelse continue;
        const outputs = root.object.get("outputs") orelse continue;
        if (outputs != .object) continue;
        const identify = outputs.object.get("identify") orelse continue;
        if (identify != .object) continue;
        const cooked = identify.object;
        const hl = cooked.get("harness_license");
        const is_unverified = hl == null or hl.? == .null or
            (hl.? == .string and std.mem.eql(u8, hl.?.string, "NOASSERTION"));
        if (is_unverified) {
            std.debug.print("WARNING: fixture {s} has unverified harness_license ({s}) — look up the upstream license and fill it in\n", .{ stem, if (hl == null or hl.? == .null) "null" else hl.?.string });
            warnings += 1;
        }
    }
    if (warnings > 0) {
        std.debug.print("WARNING: {d} fixture(s) have an unverified harness_license\n", .{warnings});
    }
}

test "fixtures: envelope combo-match — each folder's identify ids equal the filename's dims" {
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    for ([_][]const u8{ identity_dir, capture_dir }) |folder| {
        const stems = try discoverFolderStems(aa, folder);
        for (stems) |stem| {
            const parts = (split4(stem)) orelse {
                std.debug.print("fixture stem {s}/{s} is not a 4-part <h>-<p>-<m>-<platform> id\n", .{ folder, stem });
                return error.MalformedStem;
            };
            const root = (try readChannelParsed(aa, folder, stem)) orelse continue;
            const outputs = root.object.get("outputs") orelse continue;
            if (outputs != .object) continue;
            const identify = outputs.object.get("identify") orelse continue;
            if (identify != .object) continue;
            const cooked = identify.object;
            const h = cooked.get("harness_id") orelse {
                std.debug.print("fixture {s} identify lacks harness_id\n", .{stem});
                return error.MissingId;
            };
            const p = cooked.get("provider_id") orelse {
                std.debug.print("fixture {s} identify lacks provider_id\n", .{stem});
                return error.MissingId;
            };
            const m = cooked.get("model_id") orelse {
                std.debug.print("fixture {s} identify lacks model_id\n", .{stem});
                return error.MissingId;
            };
            if (h != .string or p != .string or m != .string) return error.InvalidId;
            if (!std.mem.eql(u8, h.string, parts[0]) or
                !std.mem.eql(u8, p.string, parts[1]) or
                !std.mem.eql(u8, m.string, parts[2]))
            {
                std.debug.print("fixture {s}: identify ids '{s}/{s}/{s}' do not match the filename '{s}/{s}/{s}'\n", .{ stem, h.string, p.string, m.string, parts[0], parts[1], parts[2] });
                return error.IdMismatch;
            }
        }
    }
}

test "fixtures: meta.launch argv — exactly one <prompt> placeholder; version_launch is [<binary>, --version]" {
    // The from-capture file saves the literal `"<prompt>"` placeholder in
    // place of the launch prompt (the daemon interpolates the real prompt
    // at spawn time). version_launch is always the same binary plus
    // `--version` (minimal invocation: only the args necessary to pin
    // harness + provider + model and run the capture prompt).
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const stems = try discoverFolderStems(aa, capture_dir);
    for (stems) |stem| {
        const root = (try readChannelParsed(aa, capture_dir, stem)) orelse continue;
        const meta = root.object.get("meta") orelse continue;
        if (meta != .object) continue;
        const launch = meta.object.get("prompt_launch") orelse continue;
        if (launch != .array or launch.array.items.len == 0) return error.InvalidLaunchArgv;
        var placeholders: usize = 0;
        for (launch.array.items) |arg| {
            if (arg == .string and std.mem.eql(u8, arg.string, "<prompt>")) placeholders += 1;
        }
        if (placeholders != 1) {
            std.debug.print("fixture {s} meta.prompt_launch has {d} <prompt> placeholders (want 1)\n", .{ stem, placeholders });
            return error.InvalidPromptPlaceholder;
        }
        const vl = meta.object.get("version_launch") orelse continue;
        if (vl != .array or vl.array.items.len != 2) return error.InvalidVersionLaunch;
        const v0 = vl.array.items[0];
        const v1 = vl.array.items[1];
        if (v0 != .string or v1 != .string or !std.mem.eql(u8, v1.string, "--version")) return error.InvalidVersionLaunch;
        if (launch.array.items[0] != .string or !std.mem.eql(u8, launch.array.items[0].string, v0.string)) {
            std.debug.print("fixture {s} version_launch argv[0] != prompt_launch argv[0]\n", .{stem});
            return error.InvalidVersionLaunch;
        }
    }
}

test "fixtures: meta.launch argv[0] ∈ the harness rule's binary_names (host platform)" {
    // The curated argv must name a real binary for the platform the file
    // targets. Only the files for the platform this test runs on are
    // checked — the other platforms' name lists differ at compile time.
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const host = main.dev.platformId();
    const stems = try discoverFolderStems(aa, capture_dir);
    for (stems) |stem| {
        const parts = (split4(stem)) orelse continue;
        if (!std.mem.eql(u8, parts[3], host)) continue;
        const root = (try readChannelParsed(aa, capture_dir, stem)) orelse continue;
        const meta = root.object.get("meta") orelse continue;
        if (meta != .object) continue;
        const rule = main.harnessRuleForFixtureId(aa, stem) orelse continue;
        for ([_][]const u8{ "prompt_launch", "version_launch" }) |field| {
            const arr_v = meta.object.get(field) orelse continue;
            if (arr_v != .array or arr_v.array.items.len == 0) continue;
            const argv0 = arr_v.array.items[0];
            if (argv0 != .string) return error.InvalidLaunchArgv;
            var found = false;
            for (rule.binary_names) |name| {
                if (std.mem.eql(u8, name, argv0.string)) found = true;
            }
            if (!found) {
                std.debug.print("fixture {s} {s} argv[0] {s} is not in the harness rule's binary_names\n", .{ stem, field, argv0.string });
                return error.UnknownLaunchBinary;
            }
        }
    }
}

test "index.json: store_version is 2 and the tables are exactly queue + backlog + known_but_failed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = (try readIndexParsed(arena.allocator())) orelse return; // pre-migration
    for (root.object.keys()) |key| {
        if (std.mem.eql(u8, key, "store_version") or
            std.mem.eql(u8, key, "queue") or
            std.mem.eql(u8, key, "backlog") or
            std.mem.eql(u8, key, "known_but_failed")) continue;
        std.debug.print("index.json has unexpected top-level key '{s}' — the fixture state lives in the fixture files now\n", .{key});
        return error.UnexpectedStoreKey;
    }
}

test "index.json: backlog sets are unique sorted slug/id string arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = (try readIndexParsed(arena.allocator())) orelse return;
    const backlog = root.object.get("backlog") orelse return;
    if (backlog != .object) return error.InvalidBacklog;
    const sets = [_][]const u8{ "unknown_harnesses", "unknown_providers", "unknown_models", "needs_curation" };
    for (sets) |set| {
        const arr = backlog.object.get(set) orelse continue;
        if (arr != .array) return error.InvalidBacklogSet;
        var prev: ?[]const u8 = null;
        for (arr.array.items) |item| {
            if (item != .string or item.string.len == 0) return error.InvalidBacklogItem;
            for (item.string) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidBacklogItem;
            }
            if (prev) |p| {
                try testing.expect(std.mem.lessThan(u8, p, item.string)); // sorted, unique
            }
            prev = item.string;
        }
    }
}

test "index.json: needs_curation ids are fixtured from-capture files without meta.prompt_launch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const root = (try readIndexParsed(aa)) orelse return;
    const backlog = root.object.get("backlog") orelse return;
    if (backlog != .object) return;
    const arr = backlog.object.get("needs_curation") orelse return;
    if (arr != .array) return;
    for (arr.array.items) |item| {
        if (item != .string) return error.InvalidBacklogItem;
        const root_v = (try readChannelParsed(aa, capture_dir, item.string)) orelse {
            std.debug.print("needs_curation id {s} has no from-capture file\n", .{item.string});
            return error.NeedsCurationWithoutFile;
        };
        const meta = root_v.object.get("meta") orelse return error.InvalidFixtureShape;
        if (meta != .object) return error.InvalidFixtureShape;
        try testing.expect(meta.object.get("prompt_launch") == null);
    }
}

test "index.json: known_but_failed is a flat id → message string map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = (try readIndexParsed(arena.allocator())) orelse return;
    const kb = root.object.get("known_but_failed") orelse return;
    if (kb != .object) return error.InvalidKnownButFailed;
    var it = kb.object.iterator();
    while (it.next()) |kv| {
        _ = (split4(kv.key_ptr.*)) orelse return error.InvalidKnownButFailedKey;
        if (kv.value_ptr.* != .string or kv.value_ptr.string.len == 0) return error.InvalidKnownButFailedMessage;
        // messages are home-path redacted
        if (std.mem.indexOf(u8, kv.value_ptr.string, "/Users/") != null or
            std.mem.indexOf(u8, kv.value_ptr.string, "/home/") != null)
        {
            std.debug.print("known_but_failed[{s}] leaks a home path\n", .{kv.key_ptr.*});
            return error.UnredactedFailureMessage;
        }
    }
}

test "index.json: queue entries match their field invariants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = (try readIndexParsed(arena.allocator())) orelse return;
    // mode ∈ {from-identity, from-capture}; the criteria set is booleans
    // (true|absent) + an age threshold in minutes ≥ 0; `free` is an
    // optional boolean.
    const queue = root.object.get("queue") orelse return;
    if (queue != .array) return error.InvalidQueue;
    for (queue.array.items) |item| {
        if (item != .object) return error.InvalidQueueEntry;
        const o = item.object;
        const mode = o.get("mode") orelse return error.InvalidQueueEntry;
        if (mode != .string or
            (!std.mem.eql(u8, mode.string, "from-identity") and !std.mem.eql(u8, mode.string, "from-capture")))
        {
            return error.InvalidQueueMode;
        }
        for ([_][]const u8{ "stale_by_output_drift", "stale_by_harness_version", "stale_by_detect_version", "free" }) |flag| {
            const v = o.get(flag) orelse continue;
            if (v != .bool) return error.InvalidQueueFlag;
        }
        if (o.get("stale_by_minutes")) |mins| {
            if (mins != .integer or mins.integer < 0) return error.InvalidQueueFlag;
        }
    }
}

test "coverage: every provider/model rule appears in ≥1 fixture stem; every harness rule on ≥1 stem per platform" {
    // The known universe is the union of the two folders' filename
    // stems, so coverage scans the folders (not the store). Harnesses
    // must appear on all three platforms (the declaration workflow
    // covers one row per platform); providers/models at least once.
    if (!newLayoutPresent(testing.allocator)) return;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const stems = try discoverStems(aa);
    try testing.expect(stems.len >= 1);

    var harness_platforms = std.StringHashMap(u8).init(aa);
    var providers_seen = std.StringHashMap(void).init(aa);
    var models_seen = std.StringHashMap(void).init(aa);

    for (stems) |stem| {
        const parts = (split4(stem)) orelse {
            std.debug.print("fixture stem {s} is not a 4-part <h>-<p>-<m>-<platform> id\n", .{stem});
            return error.MalformedStem;
        };
        var h_ok = false;
        for (main.rulesForHarnesses) |rr| {
            if (slugifyMatches(rr.name, parts[0])) h_ok = true;
        }
        var p_ok = false;
        for (main.rulesForProviders) |rr| {
            if (slugifyMatches(rr.name, parts[1])) p_ok = true;
        }
        var m_ok = false;
        for (main.rulesForModels) |rr| {
            if (slugifyMatches(rr.name, parts[2])) m_ok = true;
        }
        if (!h_ok or !p_ok or !m_ok) {
            // unresolvable dims are backlog items (unknown_* sets), not a
            // failure — but the store scan must have recorded them.
            const bl = (try readIndexParsed(aa)) orelse return error.MissingStore;
            const backlog = bl.object.get("backlog") orelse return error.MissingBacklog;
            const set: []const u8 = if (!h_ok) "unknown_harnesses" else if (!p_ok) "unknown_providers" else "unknown_models";
            const dim: []const u8 = if (!h_ok) parts[0] else if (!p_ok) parts[1] else parts[2];
            const arr = backlog.object.get(set) orelse {
                std.debug.print("fixture stem {s} references an unknown {s} dim '{s}' and backlog.{s} is empty\n", .{ stem, set, dim, set });
                return error.UnknownFixtureDim;
            };
            var recorded = false;
            for (arr.array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, dim)) recorded = true;
            }
            if (!recorded) {
                std.debug.print("fixture stem {s} references an unknown {s} dim '{s}' not recorded in backlog.{s}\n", .{ stem, set, dim, set });
                return error.UnknownFixtureDim;
            }
            std.debug.print("NOTE: fixture stem {s} references an unknown {s} dim '{s}' — recorded in backlog.{s} (add a rule to resolve)\n", .{ stem, set, dim, set });
            continue;
        }
        var plat_ok = false;
        for ([_][]const u8{ "darwin", "linux", "windows" }) |plat| {
            if (std.mem.eql(u8, plat, parts[3])) plat_ok = true;
        }
        if (!plat_ok) {
            std.debug.print("fixture stem {s} has an unknown platform {s}\n", .{ stem, parts[3] });
            return error.UnknownPlatform;
        }
        const gop = try harness_platforms.getOrPut(parts[0]);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* |= if (std.mem.eql(u8, parts[3], "darwin"))
            @as(u8, 0b001)
        else if (std.mem.eql(u8, parts[3], "linux"))
            @as(u8, 0b010)
        else
            @as(u8, 0b100);
        try providers_seen.put(parts[1], {});
        try models_seen.put(parts[2], {});
    }

    for (main.rulesForHarnesses) |rr| {
        const slug = try main.slugId(aa, rr.name);
        const mask = harness_platforms.get(slug) orelse {
            std.debug.print("harness rule {s} has no fixture stems\n", .{rr.name});
            return error.HarnessWithoutStems;
        };
        // bit0 = darwin, bit1 = linux, bit2 = windows
        if (mask != 0b111) {
            std.debug.print("harness rule {s} is missing a platform's stems (mask 0b{b})\n", .{ rr.name, mask });
            return error.HarnessMissingPlatform;
        }
    }
    // Rule-only entries — detection-coverage rules no fixture combo uses
    // yet (a provider alias/mirror, or a model registered for detection
    // without a curated launch). The guard still fires for any NEW rule
    // that lands without stems; these are the pre-existing exemptions.
    const rule_only_providers = [_][]const u8{ "cline", "google", "moonshot" };
    const rule_only_models = [_][]const u8{
        "claude-haiku-4",  "claude-opus-4", "devstral-2",   "gemini-3.1-pro",
        "glm-4.6",         "glm-5",         "glm-5.3",      "gpt-5.5",
        "grok-3-mini",     "grok-4.6",      "hy3",          "hy4-preview",
        "mimo-v2.5",       "mimo-v2.5-pro", "qwen3.5",
    };
    for (main.rulesForProviders) |rr| {
        var exempt = false;
        for (rule_only_providers) |name| {
            if (std.mem.eql(u8, rr.name, name)) exempt = true;
        }
        if (exempt) continue;
        var found = false;
        var it2 = providers_seen.iterator();
        while (it2.next()) |kv| {
            if (slugifyMatches(rr.name, kv.key_ptr.*)) found = true;
        }
        if (!found) {
            std.debug.print("provider rule {s} appears in no fixture stems\n", .{rr.name});
            return error.ProviderWithoutStems;
        }
    }
    for (main.rulesForModels) |rr| {
        var exempt = false;
        for (rule_only_models) |name| {
            if (std.mem.eql(u8, rr.name, name)) exempt = true;
        }
        if (exempt) continue;
        var found = false;
        var it2 = models_seen.iterator();
        while (it2.next()) |kv| {
            if (slugifyMatches(rr.name, kv.key_ptr.*)) found = true;
        }
        if (!found) {
            std.debug.print("model rule {s} appears in no fixture stems\n", .{rr.name});
            return error.ModelWithoutStems;
        }
    }
}

test "providers_freemodels.csv: free-grid entries resolve to known rules, stay sparse, and curated capture files carry a free-signal in their launch model spec" {
    // The grid is the free-axis source of truth: rows only for providers
    // with ≥1 free model, columns only for models free somewhere, cells
    // the provider's free model-id or `-`. Every fixtured (provider,
    // model) row that is free-listed must carry a free signal (`:free`,
    // `-free`, `free/`) in its meta.prompt_launch model spec — files
    // whose launch implies the model via harness config are exempt.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/.providers_freemodels.csv", a, @enumFromInt(1 << 20)) catch {
        std.debug.print("fixtures/.providers_freemodels.csv is missing — it is the free-axis source of truth\n", .{});
        return error.MissingFreeGrid;
    };
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    const header = lines.next() orelse return error.InvalidFreeGrid;
    var cols: std.ArrayList([]const u8) = .empty;
    var hc = std.mem.tokenizeScalar(u8, header, ',');
    _ = hc.next(); // the "provider" label cell
    while (hc.next()) |c| try cols.append(a, std.mem.trim(u8, c, " \r\t"));
    if (cols.items.len == 0) return error.InvalidFreeGrid;

    for (cols.items) |col| {
        var m_ok = false;
        for (main.rulesForModels) |rr| {
            if (slugifyMatches(rr.name, col)) m_ok = true;
        }
        if (!m_ok) {
            std.debug.print("free grid column {s} resolves to no model rule\n", .{col});
            return error.UnknownFreeModel;
        }
    }
    while (lines.next()) |line| {
        var cells = std.mem.tokenizeScalar(u8, line, ',');
        const provider = std.mem.trim(u8, cells.next() orelse continue, " \r\t");
        var p_ok = false;
        for (main.rulesForProviders) |rr| {
            if (slugifyMatches(rr.name, provider)) p_ok = true;
        }
        if (!p_ok) {
            std.debug.print("free grid provider {s} resolves to no rule\n", .{provider});
            return error.UnknownFreeProvider;
        }
        var any = false;
        var idx: usize = 0;
        while (cells.next()) |cell| : (idx += 1) {
            const v = std.mem.trim(u8, cell, " \r\t");
            if (v.len == 0 or std.mem.eql(u8, v, "-")) continue;
            any = true;
            if (idx >= cols.items.len) continue;
            // free-signal cross-check against the from-capture files' argv
            if (!newLayoutPresent(a)) continue;
            const stems = try discoverFolderStems(a, capture_dir);
            for (stems) |stem| {
                const parts = (split4(stem)) orelse continue;
                if (!std.mem.eql(u8, parts[1], provider) or !std.mem.eql(u8, parts[2], cols.items[idx])) continue;
                const root_v = (try readChannelParsed(a, capture_dir, stem)) orelse continue;
                const meta = root_v.object.get("meta") orelse continue;
                if (meta != .object) continue;
                const launch = meta.object.get("prompt_launch") orelse continue;
                if (launch != .array) continue;
                var has_model_spec = false;
                var has_free_signal = false;
                for (launch.array.items) |arg| {
                    if (arg != .string) continue;
                    if (std.mem.startsWith(u8, arg.string, "--model") or
                        std.mem.indexOfScalar(u8, arg.string, '/') != null or
                        std.mem.indexOfScalar(u8, arg.string, ':') != null)
                    {
                        has_model_spec = true;
                    }
                    if (std.mem.indexOf(u8, arg.string, ":free") != null or
                        std.mem.indexOf(u8, arg.string, "-free") != null or
                        std.mem.indexOf(u8, arg.string, "free/") != null)
                    {
                        has_free_signal = true;
                    }
                }
                if (has_model_spec and !has_free_signal) {
                    std.debug.print("fixture {s} is free-listed but its meta.prompt_launch carries no free signal\n", .{stem});
                    return error.MissingFreeSignal;
                }
            }
        }
        if (!any) {
            std.debug.print("free grid row {s} has no free model — sparse grid violation\n", .{provider});
            return error.NonSparseFreeRow;
        }
    }
    for (cols.items, 0..) |col, ci| {
        var any = false;
        var lines2 = std.mem.tokenizeScalar(u8, data, '\n');
        _ = lines2.next();
        while (lines2.next()) |line| {
            var cells = std.mem.tokenizeScalar(u8, line, ',');
            _ = cells.next();
            var idx: usize = 0;
            while (cells.next()) |cell| : (idx += 1) {
                if (idx != ci) continue;
                const v = std.mem.trim(u8, cell, " \r\t");
                if (v.len > 0 and !std.mem.eql(u8, v, "-")) any = true;
            }
        }
        if (!any) {
            std.debug.print("free grid column {s} has no free provider — sparse grid violation\n", .{col});
            return error.NonSparseFreeColumn;
        }
    }
}

test "fixtures: every harness rule's binary_names is non-empty, lowercase, and Windows-complete" {
    // binary_names is the single hand-maintained name list (probe,
    // launch, ancestry, daemon guard). Contract: non-empty; only
    // lowercase letters/digits/./-; and on Windows every bare stem
    // (no `.` extension) has its `<stem>.exe` twin so the .exe-first
    // process ancestry and .cmd-shim launching both find their name.
    const builtin = @import("builtin");
    for (main.rulesForHarnesses) |rule| {
        try testing.expect(rule.binary_names.len >= 1);
        for (rule.binary_names) |name| {
            for (name) |c| {
                if (std.ascii.isAlphabetic(c)) try testing.expect(std.ascii.isLower(c));
            }
            if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, name, '.') == null) {
                const exe = try std.fmt.allocPrint(testing.allocator, "{s}.exe", .{name});
                defer testing.allocator.free(exe);
                var found = false;
                for (rule.binary_names) |other| {
                    if (std.mem.eql(u8, other, exe)) found = true;
                }
                if (!found) {
                    std.debug.print("harness rule {s}: bare stem {s} has no {s} twin\n", .{ rule.name, name, exe });
                    return error.MissingExeTwin;
                }
            }
        }
    }
}
