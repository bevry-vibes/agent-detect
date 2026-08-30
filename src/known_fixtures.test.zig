// Schema/shape tests for the fixtures under `fixtures/` and the
// committed `fixtures/.index.json` state store. See DESIGN.md
// for the fixture lifecycle (daemon + capture + .index.json store) and
// CONTRIBUTING.md for adding agents to the rule registry.
//
// The suite validates committed-file shape only. Regeneration
// completeness is the envelope test below: legacy `cooked`-shaped files
// (still on disk until their queued regeneration lands on their
// platform's host) fail it — that failure is the regen signal, not a
// code bug. Channel-scoped tests skip files that lack the channel they
// inspect. The .index.json tests skip when the store is absent (it is
// committed by the store-conversion commit).

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

/// Discover every `fixtures/<stem>.json` fixture, returning the stems.
fn discoverStems(a: std.mem.Allocator) ![][]u8 {
    var stems: std.ArrayList([]u8) = .empty;

    var dir = std.Io.Dir.cwd().openDir(std.testing.io, "fixtures", .{ .iterate = true }) catch return stems.toOwnedSlice(a) catch &.{};
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (it.next(std.testing.io) catch null) |ent| {
        if (ent.kind != .file) continue;
        const name = ent.name;
        const suffix = ".json";
        if (name.len <= suffix.len) continue;
        if (std.mem.endsWith(u8, name, suffix)) {
            // filter to *.json fixture files so the .index.json store and
            // any non-fixture files are ignored (skip any dot-file)
            const stem = name[0 .. name.len - suffix.len];
            if (stem.len > 0 and stem[0] == '.') continue;
            try stems.append(a, try a.dupe(u8, stem));
        }
    }
    return stems.toOwnedSlice(a);
}

/// Load a fixture as a parsed JSON value, or return null if the file
/// is missing (callers should skip such fixtures gracefully).
fn readFixtureParsed(a: std.mem.Allocator, stem: []const u8) !?std.json.Parsed(std.json.Value) {
    const path = try std.fmt.allocPrint(a, "fixtures/{s}.json", .{stem});
    defer a.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, @enumFromInt(1 << 20)) catch return null;
    defer a.free(data);
    return try std.json.parseFromSlice(std.json.Value, a, data, .{});
}

/// Load the committed `fixtures/.index.json` store as a parsed JSON
/// value, or null when the store is absent (the store tests then skip).
fn readIndexParsed(a: std.mem.Allocator) !?std.json.Parsed(std.json.Value) {
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/.index.json", a, @enumFromInt(1 << 26)) catch return null;
    defer a.free(data);
    return try std.json.parseFromSlice(std.json.Value, a, data, .{});
}

/// BLAKE3 hex of `bytes` (lowercase), mirroring the store's hashes.
fn blake3Hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
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

/// split a `-`-separated id into exactly three non-empty parts, or null.
fn split3(agent: []const u8) ?[3][]const u8 {
    var it = std.mem.tokenizeScalar(u8, agent, '-');
    const h = it.next() orelse return null;
    const p = it.next() orelse return null;
    const m = it.next() orelse return null;
    if (it.next() != null) return null;
    if (h.len == 0 or p.len == 0 or m.len == 0) return null;
    return .{ h, p, m };
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
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    // If this fails, capture new fixtures with `agent-detect-dev
    // fixtures capture` inside each harness session you're targeting,
    // then commit the resulting fixture files under `fixtures/`.
    try testing.expect(stems.len >= 1);
}

test "fixtures: envelope shape — top-level keys ⊆ {from-identity, from-capture, from-capture-raw}" {
    // The fixture file's top-level keys are the per-channel channel
    // objects. `from-identity` is required on every fixture; legacy
    // `cooked`-shaped files (still on disk until their queued
    // regeneration lands) fail this — that is the regen-completeness
    // signal now that `origin` is gone. No root `trailer`/`cooked`/
    // `raw`/`origin` keys are allowed.
    const allowed = [_][]const u8{ "from-identity", "from-capture", "from-capture-raw" };
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    var new_shape: usize = 0;
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidFixtureShape;
        const root = parsed.value.object;
        // from-identity required.
        const ident = root.get("from-identity") orelse {
            std.debug.print("fixture {s} has no from-identity channel (legacy shape? regenerate per CONTRIBUTING.md)\n", .{stem});
            return error.MissingIdentityChannel;
        };
        if (ident != .object) return error.InvalidFixtureShape;
        for (root.keys()) |key| {
            var known = false;
            for (allowed) |a| {
                if (std.mem.eql(u8, key, a)) known = true;
            }
            if (!known) {
                std.debug.print("fixture {s} has disallowed top-level key '{s}'\n", .{ stem, key });
                return error.UnexpectedRootKey;
            }
        }
        // each channel object present carries identify + both trailer
        // variants.
        for ([_][]const u8{ "from-identity", "from-capture" }) |channel| {
            const ch = root.get(channel) orelse continue;
            if (ch != .object) return error.InvalidFixtureShape;
            const cob = ch.object;
            try testing.expect(cob.get("identify") != null);
            try testing.expect(cob.get("identify").? == .object);
            try testing.expect(cob.get("trailer co-author") != null);
            try testing.expect(cob.get("trailer assisted-by") != null);
        }
        const raw_ch = root.get("from-capture-raw") orelse continue;
        try testing.expect(raw_ch == .object);
        new_shape += 1;
    }
    // at least one committed fixture must be new-shaped (the envelope
    // contract is not vacuous).
    try testing.expect(new_shape >= 1);
}

test "fixtures: identify has all 18 grouped keys in emission order, no trailer key" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ident = parsed.value.object.get("from-identity") orelse continue;
        if (ident != .object) continue;
        const identify = ident.object.get("identify") orelse continue;
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

test "fixtures: from-capture-raw is a shapeless object — no fixed schema, just source keys" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const raw = parsed.value.object.get("from-capture-raw") orelse continue;
        try testing.expect(raw == .object);
        const raw_o = raw.object;
        // forbidden legacy block: the source-grouped shape replaced it
        try testing.expect(!raw_o.contains("detection"));
        try testing.expect(!raw_o.contains("session"));
        try testing.expect(!raw_o.contains("sources"));
        try testing.expect(!raw_o.contains("rule"));
    }
}

test "fixtures: from-capture-raw carries platform_id, detectable, and detected adjacent at the top" {
    // Every committed fixture is a full capture, so `detectable` and
    // `detected` both equal `["harness","provider","model"]`, and
    // `platform_id` precedes them at the top of the raw block.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const raw = parsed.value.object.get("from-capture-raw") orelse continue;
        if (raw != .object) continue;
        const raw_o = raw.object;
        try testing.expect(raw_o.get("platform_id").? == .string);
        try testing.expect(raw_o.get("platform_id").?.string.len > 0);
        const detectable = raw_o.get("detectable").?.array;
        const detected = raw_o.get("detected").?.array;
        try testing.expect(detectable.items.len == 3);
        try testing.expect(detected.items.len == 3);
        inline for ([_][]const u8{ "harness", "provider", "model" }) |dim| {
            var found_detectable = false;
            for (detectable.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, dim)) found_detectable = true;
            }
            var found_detected = false;
            for (detected.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, dim)) found_detected = true;
            }
            try testing.expect(found_detectable);
            try testing.expect(found_detected);
        }
    }
}

test "fixtures: from-capture-raw.process_lineage is always present" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const raw = parsed.value.object.get("from-capture-raw") orelse continue;
        if (raw != .object) continue;
        const raw_o = raw.object;
        const process_lineage = raw_o.get("process_lineage").?.array;
        try testing.expect(process_lineage.items.len >= 1); // at least agent-detect
    }
}

test "fixtures: from-capture-raw.process_lineage entries are subobjects with pid + name" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const raw = parsed.value.object.get("from-capture-raw") orelse continue;
        if (raw != .object) continue;
        const lineage = raw.object.get("process_lineage").?.array;
        try testing.expect(lineage.items.len >= 1); // at least agent-detect
        for (lineage.items) |entry| {
            const obj = entry.object;
            try testing.expect(obj.get("pid") != null);
            try testing.expect(obj.get("name") != null);
            try testing.expect(obj.get("name").? == .string);
            try testing.expect(obj.get("pid").? == .integer);
        }
    }
}

test "fixtures: from-capture-raw matches the dev-raw schema — exactly the raw output keys" {
    // The `from-capture-raw` channel is the dev `raw` output verbatim:
    // platform_id, harness_version (DESIGN: headed by platform_id, then
    // the live version snapshot), detectable, detected, process_lineage,
    // *-urls, evidence. No env/file objects; secret env evidence is
    // `<redacted>`. Pre-keyset-growth fixtures may carry fewer keys —
    // the check is "no unexpected keys", and the queued regen sweeps
    // bring older files up to the full set.
    const fixed_keys = [_][]const u8{
        "platform_id",  "harness_version", "detectable",    "detected",
        "process_lineage", "harness-urls", "provider-urls", "model-urls",
        "evidence",
    };
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const raw = parsed.value.object.get("from-capture-raw") orelse continue;
        if (raw != .object) continue;
        const raw_o = raw.object;
        try testing.expect(!raw_o.contains("env"));
        for (raw_o.keys()) |key| {
            var known = false;
            for (fixed_keys) |fk| {
                if (std.mem.eql(u8, key, fk)) known = true;
            }
            if (!known) {
                std.debug.print("fixture {s} has unexpected from-capture-raw top-level key '{s}'\n", .{ stem, key });
                return error.UnexpectedRawKey;
            }
        }
        // evidence claims: env-source on non-allowlisted names → `<redacted>`.
        const evidence = raw_o.get("evidence").?.array;
        for (evidence.items) |ev| {
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

test "fixtures: from-capture-raw has no harness-env-markers / harness-proc-names (static rule data, not runtime evidence)" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const raw = parsed.value.object.get("from-capture-raw") orelse continue;
        if (raw != .object) continue;
        const raw_o = raw.object;
        try testing.expect(!raw_o.contains("harness-env-markers"));
        try testing.expect(!raw_o.contains("harness-proc-names"));
    }
}

test "fixtures: from-capture-raw harness-urls / provider-urls / model-urls are arrays of https:// URLs" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const raw = parsed.value.object.get("from-capture-raw") orelse continue;
        if (raw != .object) continue;
        const raw_o = raw.object;
        inline for ([_][]const u8{ "harness-urls", "provider-urls", "model-urls" }) |key| {
            const arr = raw_o.get(key).?.array;
            for (arr.items) |item| {
                try testing.expect(item == .string);
                try testing.expect(std.mem.startsWith(u8, item.string, "https://"));
            }
        }
    }
}

test "fixtures: every fixture's identify has all 8 identity fields populated" {
    // The capture refuses to write a fixture with null provider or
    // null model, so every committed fixture has the harness+provider
    // +model triad populated. The four policy fields — harness_license,
    // model_reciprocity, provider_closed_training, provider_open_training
    // — may legitimately be `null` per the schema. The required set here
    // is therefore just the identity fields (+ reciprocal); nulls on the
    // policy fields are validated by their own type-checks above.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    const required_non_null = [_][]const u8{
        "harness_label",  "harness_name",
        "provider_label", "provider_name",
        "model_label",    "model_name",
        "reciprocal",
    };
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ident = parsed.value.object.get("from-identity") orelse continue;
        if (ident != .object) continue;
        const identify = ident.object.get("identify") orelse continue;
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
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    const id_fields = [_][]const u8{ "harness_name", "provider_name", "model_name" };
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ident = parsed.value.object.get("from-identity") orelse continue;
        if (ident != .object) continue;
        const identify = ident.object.get("identify") orelse continue;
        if (identify != .object) continue;
        const cooked = identify.object;
        for (id_fields) |field| {
            const v = cooked.get(field) orelse continue;
            try testing.expect(v == .string);
            try testing.expect(v.string.len > 0);
        }
    }
}

test "fixtures: fixture JSON is pretty-printed (identify expanded, channels present, no cooked/raw/env)" {
    // The pretty JSON emitter expands identify fields, process
    // ancestors, and *-urls arrays onto their own lines. The `env`
    // object is absent (raw slimming), and the legacy `cooked`/`raw`/
    // `trailer` top-level keys are gone.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const path = try std.fmt.allocPrint(testing.allocator, "fixtures/{s}.json", .{stem});
        defer testing.allocator.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, testing.allocator, @enumFromInt(1 << 20)) catch continue;
        defer testing.allocator.free(data);

        // legacy `cooked`-shaped files are skipped here — the envelope
        // test above is the regeneration-completeness gate for them.
        if (std.mem.indexOf(u8, data, "\"from-identity\":") == null) continue;

        // 1. from-identity channel present; identify field per line.
        try testing.expect(std.mem.indexOf(u8, data, "\"from-identity\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "    \"harness_label\"") != null);

        // 2. both trailer variants present in the channel.
        try testing.expect(std.mem.indexOf(u8, data, "\"trailer co-author\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"trailer assisted-by\":") != null);

        // 3. no env block, no legacy cooked/raw/trailer top-level keys.
        try testing.expect(std.mem.indexOf(u8, data, "\"env\":") == null);
        try testing.expect(std.mem.indexOf(u8, data, "\"cooked\":") == null);

        // 4. process_lineage section: at least one pid+name entry.
        try testing.expect(std.mem.indexOf(u8, data, "\"process_lineage\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"pid\":") != null);

        // 5. *-urls arrays: each present (may be empty for closed-source)
        try testing.expect(std.mem.indexOf(u8, data, "\"harness-urls\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"provider-urls\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"model-urls\":") != null);
    }
}

test "fixtures: warn on null / NOASSERTION harness_license (dev should fill in from upstream)" {
    // Decision #1 — the license tri-state: `null` (no data) and
    // `NOASSERTION` (attempted, inconclusive) warn; `NONE` (concluded:
    // verified proprietary/closed) is a deliberate, valid value and must
    // NOT warn.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    var warnings: usize = 0;
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ident = parsed.value.object.get("from-identity") orelse continue;
        if (ident != .object) continue;
        const identify = ident.object.get("identify") orelse continue;
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

test "fixtures: envelope combo-match — from-identity.identify ids equal the filename's dims" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parts = (split4(stem)) orelse {
            std.debug.print("fixture stem {s} is not a 4-part <h>-<p>-<m>-<platform> id\n", .{stem});
            return error.MalformedStem;
        };
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ident = parsed.value.object.get("from-identity") orelse continue;
        if (ident != .object) continue;
        const identify = ident.object.get("identify") orelse continue;
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

test "index.json: prompt_launch carries exactly one <prompt> placeholder; version_launch is [<binary>, --version]" {
    // The store saves the literal `"<prompt>"` placeholder in place of
    // the launch prompt (the daemon interpolates the real prompt at
    // spawn time) — usually the last element, but not always (e.g. mmx
    // places it mid-argv). version_launch is always the same binary plus
    // `--version`.
    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const fixtures = parsed.value.object.get("fixtures") orelse return;
    if (fixtures != .object) return;
    var it = fixtures.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const o = kv.value_ptr.object;
        const launch = o.get("prompt_launch") orelse continue;
        if (launch != .array or launch.array.items.len == 0) return error.InvalidLaunchArgv;
        var placeholders: usize = 0;
        for (launch.array.items) |arg| {
            if (arg == .string and std.mem.eql(u8, arg.string, "<prompt>")) placeholders += 1;
        }
        if (placeholders != 1) {
            std.debug.print("index.json row {s} prompt_launch has {d} <prompt> placeholders (want 1)\n", .{ kv.key_ptr.*, placeholders });
            return error.InvalidPromptPlaceholder;
        }
        const vl = o.get("version_launch") orelse continue;
        if (vl != .array or vl.array.items.len != 2) return error.InvalidVersionLaunch;
        const v0 = vl.array.items[0];
        const v1 = vl.array.items[1];
        if (v0 != .string or v1 != .string or !std.mem.eql(u8, v1.string, "--version")) return error.InvalidVersionLaunch;
        if (launch.array.items[0] != .string or !std.mem.eql(u8, launch.array.items[0].string, v0.string)) {
            std.debug.print("index.json row {s} version_launch argv[0] != prompt_launch argv[0]\n", .{kv.key_ptr.*});
            return error.InvalidVersionLaunch;
        }
    }
}

test "index.json: store_version is 1" {
    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const sv = parsed.value.object.get("store_version") orelse return error.MissingStoreVersion;
    try testing.expect(sv == .integer);
    try testing.expectEqual(@as(i64, 1), sv.integer);
}

test "index.json: fixture keys split 4-way; dims resolve to rules; every harness has ≥1 row per platform; every provider/model rule appears in ≥1 row" {
    // The seeding guard: the fixtures map is the known universe, so its
    // rows must reference known rule dims, and every rule must appear —
    // harnesses on all three platforms (the `--unknown` seeding workflow
    // declares one row per platform), providers/models at least once.
    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const fixtures = parsed.value.object.get("fixtures") orelse return error.MissingFixtures;
    try testing.expect(fixtures == .object);

    var harness_platforms = std.StringHashMap(u8).init(testing.allocator);
    defer harness_platforms.deinit();
    var providers_seen = std.StringHashMap(void).init(testing.allocator);
    defer providers_seen.deinit();
    var models_seen = std.StringHashMap(void).init(testing.allocator);
    defer models_seen.deinit();

    var it = fixtures.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const parts = (split4(key)) orelse {
            std.debug.print("index.json fixture key {s} is not a 4-part <h>-<p>-<m>-<platform> id\n", .{key});
            return error.MalformedFixtureKey;
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
            std.debug.print("index.json fixture key {s} references an unknown dim (h:{}, p:{}, m:{})\n", .{ key, h_ok, p_ok, m_ok });
            return error.UnknownFixtureDim;
        }
        var plat_ok = false;
        for ([_][]const u8{ "darwin", "linux", "windows" }) |plat| {
            if (std.mem.eql(u8, plat, parts[3])) plat_ok = true;
        }
        if (!plat_ok) {
            std.debug.print("index.json fixture key {s} has an unknown platform {s}\n", .{ key, parts[3] });
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
        const slug = try main.slugId(testing.allocator, rr.name);
        defer testing.allocator.free(slug);
        const mask = harness_platforms.get(slug) orelse {
            std.debug.print("harness rule {s} has no rows in index.json fixtures\n", .{rr.name});
            return error.HarnessWithoutRows;
        };
        // bit0 = darwin, bit1 = linux, bit2 = windows
        if (mask != 0b111) {
            std.debug.print("harness rule {s} is missing a platform's rows (mask 0b{b})\n", .{ rr.name, mask });
            return error.HarnessMissingPlatform;
        }
    }
    // Rule-only entries — detection-coverage rules no recipe combo uses
    // yet (a provider alias/mirror, or a model registered for detection
    // without a curated launch). The guard still fires for any NEW rule
    // that lands without rows; these are the pre-existing exemptions.
    const rule_only_providers = [_][]const u8{ "cline", "google", "moonshot" };
    const rule_only_models = [_][]const u8{
        "claude-haiku-4", "claude-opus-4", "devstral-2", "gemini-3.1-pro",
        "glm-4.6",        "gpt-5.5",       "grok-3-mini", "qwen3.5",
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
            std.debug.print("provider rule {s} appears in no index.json fixture rows\n", .{rr.name});
            return error.ProviderWithoutRows;
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
            std.debug.print("model rule {s} appears in no index.json fixture rows\n", .{rr.name});
            return error.ModelWithoutRows;
        }
    }
}

test "index.json: prompt_launch/version_launch argv[0] ∈ the harness rule's binary_names (host platform)" {
    // The curated argv must name a real binary for the platform the row
    // targets. Only the rows for the platform this test runs on are
    // checked — the other platforms' name lists differ at compile time.
    const host = main.dev.platformId();
    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const fixtures = parsed.value.object.get("fixtures") orelse return;
    if (fixtures != .object) return;
    var it = fixtures.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const parts = (split4(key)) orelse continue;
        if (!std.mem.eql(u8, parts[3], host)) continue;
        if (kv.value_ptr.* != .object) continue;
        const o = kv.value_ptr.object;
        const rule = main.harnessRuleForFixtureId(testing.allocator, key) orelse continue;
        for ([_][]const u8{ "prompt_launch", "version_launch" }) |field| {
            const arr_v = o.get(field) orelse continue;
            if (arr_v != .array or arr_v.array.items.len == 0) continue;
            const argv0 = arr_v.array.items[0];
            if (argv0 != .string) return error.InvalidLaunchArgv;
            var found = false;
            for (rule.binary_names) |name| {
                if (std.mem.eql(u8, name, argv0.string)) found = true;
            }
            if (!found) {
                std.debug.print("index.json row {s} {s} argv[0] {s} is not in the harness rule's binary_names\n", .{ key, field, argv0.string });
                return error.UnknownLaunchBinary;
            }
        }
    }
}

test "index.json: fixture_hash equals the BLAKE3 of the whole fixture file" {
    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const fixtures = parsed.value.object.get("fixtures") orelse return;
    if (fixtures != .object) return;
    var it = fixtures.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (kv.value_ptr.* != .object) continue;
        const stored = kv.value_ptr.object.get("fixture_hash") orelse continue;
        if (stored != .string) continue;
        const path = try std.fmt.allocPrint(testing.allocator, "fixtures/{s}.json", .{key});
        defer testing.allocator.free(path);
        const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, testing.allocator, @enumFromInt(1 << 24)) catch continue;
        defer testing.allocator.free(file_bytes);
        const cur = try blake3Hex(testing.allocator, file_bytes);
        defer testing.allocator.free(cur);
        if (!std.mem.eql(u8, stored.string, cur)) {
            std.debug.print("index.json row {s} fixture_hash does not match the committed file\n", .{key});
            return error.FixtureHashMismatch;
        }
    }
}

test "index.json: channel_hash equals the BLAKE3 of the whole channel object in the file" {
    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const fixtures = parsed.value.object.get("fixtures") orelse return;
    if (fixtures != .object) return;
    var it = fixtures.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (kv.value_ptr.* != .object) continue;
        const o = kv.value_ptr.object;
        for ([_][]const u8{ "identity", "capture" }) |ledger| {
            const ledger_v = o.get(ledger) orelse continue;
            if (ledger_v != .object) continue;
            const stored = ledger_v.object.get("channel_hash") orelse continue;
            if (stored != .string) continue;
            const channel = if (std.mem.eql(u8, ledger, "identity")) "from-identity" else "from-capture";
            const path = try std.fmt.allocPrint(testing.allocator, "fixtures/{s}.json", .{key});
            defer testing.allocator.free(path);
            const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, testing.allocator, @enumFromInt(1 << 24)) catch continue;
            defer testing.allocator.free(file_bytes);
            const file_parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, file_bytes, .{}) catch continue;
            defer file_parsed.deinit();
            if (file_parsed.value != .object) continue;
            const ch = file_parsed.value.object.get(channel) orelse continue;
            if (ch != .object) continue;
            const ch_bytes = try std.json.Stringify.valueAlloc(testing.allocator, ch, .{ .whitespace = .indent_2 });
            defer testing.allocator.free(ch_bytes);
            const cur = try blake3Hex(testing.allocator, ch_bytes);
            defer testing.allocator.free(cur);
            if (!std.mem.eql(u8, stored.string, cur)) {
                std.debug.print("index.json row {s} {s}.channel_hash does not match the file's channel object\n", .{ key, ledger });
                return error.ChannelHashMismatch;
            }
        }
    }
}

/// Minimal parse of the free-grid CSV: header model slugs + (provider,
/// cells) rows. Cells are `-` or the provider's free model-id; ids
/// contain no commas, so naive splitting is sufficient.
const FreeGridFile = struct {
    cols: []const []const u8,
    providers: []const []const u8,
    cells: []const []const []const u8,
};

fn parseFreeGrid(a: std.mem.Allocator, data: []const u8) !FreeGridFile {
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var cols: std.ArrayList([]const u8) = .empty;
    var providers: std.ArrayList([]const u8) = .empty;
    var cells: std.ArrayList([]const []const u8) = .empty;
    const header = lines.next() orelse return error.InvalidFreeGrid;
    var hc = std.mem.tokenizeScalar(u8, header, ',');
    _ = hc.next(); // the "provider" label cell
    while (hc.next()) |c| try cols.append(a, std.mem.trim(u8, c, " \r\t"));
    while (lines.next()) |line| {
        var rc = std.mem.tokenizeScalar(u8, line, ',');
        const p = rc.next() orelse continue;
        try providers.append(a, std.mem.trim(u8, p, " \r\t"));
        var row: std.ArrayList([]const u8) = .empty;
        while (rc.next()) |c| try row.append(a, std.mem.trim(u8, c, " \r\t"));
        if (row.items.len != cols.items.len) return error.InvalidFreeGrid;
        try cells.append(a, row.items);
    }
    return .{ .cols = cols.items, .providers = providers.items, .cells = cells.items };
}

fn freeGridListed(grid: FreeGridFile, provider: []const u8, model: []const u8) bool {
    for (grid.providers, grid.cells) |p, row| {
        if (!std.mem.eql(u8, p, provider)) continue;
        for (row, grid.cols) |cell, col| {
            if (std.mem.eql(u8, col, model) and cell.len > 0 and !std.mem.eql(u8, cell, "-")) return true;
        }
    }
    return false;
}

fn freeCell(cell: []const u8) bool {
    return cell.len > 0 and !std.mem.eql(u8, cell, "-");
}

test "providers_freemodels.csv: free-grid entries resolve to known rules, stay sparse, and listed rows carry a free-signal in their launch model spec" {
    // The grid is the free-axis source of truth (replacing the legacy
    // free_provider_to_model store table): rows only for providers with
    // ≥1 free model, columns only for models free somewhere, cells the
    // provider's free model-id or `-`. Every listed (provider, model)
    // row in the store must carry a free signal (`:free`, `-free`,
    // `free/`) in its prompt_launch model spec — rows whose launch
    // implies the model via harness config are exempt.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/.providers_freemodels.csv", a, @enumFromInt(1 << 20)) catch {
        std.debug.print("fixtures/.providers_freemodels.csv is missing — it is the free-axis source of truth\n", .{});
        return error.MissingFreeGrid;
    };
    const grid = try parseFreeGrid(a, data);
    if (grid.cols.len == 0 or grid.providers.len == 0) return error.InvalidFreeGrid;

    for (grid.cols) |col| {
        var m_ok = false;
        for (main.rulesForModels) |rr| {
            if (slugifyMatches(rr.name, col)) m_ok = true;
        }
        if (!m_ok) {
            std.debug.print("free grid column {s} resolves to no model rule\n", .{col});
            return error.UnknownFreeModel;
        }
    }
    for (grid.providers, 0..) |p, ri| {
        var p_ok = false;
        for (main.rulesForProviders) |rr| {
            if (slugifyMatches(rr.name, p)) p_ok = true;
        }
        if (!p_ok) {
            std.debug.print("free grid provider {s} resolves to no rule\n", .{p});
            return error.UnknownFreeProvider;
        }
        var any = false;
        for (grid.cells[ri]) |cell| {
            if (freeCell(cell)) any = true;
        }
        if (!any) {
            std.debug.print("free grid row {s} has no free model — sparse grid violation\n", .{p});
            return error.NonSparseFreeRow;
        }
    }
    for (grid.cols, 0..) |col, ci| {
        var any = false;
        for (grid.cells) |row| {
            if (freeCell(row[ci])) any = true;
        }
        if (!any) {
            std.debug.print("free grid column {s} has no free provider — sparse grid violation\n", .{col});
            return error.NonSparseFreeColumn;
        }
    }

    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    // the store must no longer carry the legacy table
    if (parsed.value.object.get("free_provider_to_model") != null) {
        std.debug.print("index.json still carries free_provider_to_model — the CSV is the source of truth\n", .{});
        return error.LegacyFreeTablePresent;
    }
    const fixtures = parsed.value.object.get("fixtures") orelse return;
    if (fixtures != .object) return;
    var it = fixtures.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const parts = (split4(key)) orelse continue;
        if (kv.value_ptr.* != .object) continue;
        const o = kv.value_ptr.object;
        if (!freeGridListed(grid, parts[1], parts[2])) continue;
        const launch_v = o.get("prompt_launch") orelse continue;
        if (launch_v != .array) continue;
        var has_model_spec = false;
        var has_free_signal = false;
        for (launch_v.array.items) |arg| {
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
            std.debug.print("index.json row {s} is free-listed but its prompt_launch carries no free signal\n", .{key});
            return error.MissingFreeSignal;
        }
    }
}

test "index.json: queue entries match their field invariants" {
    // mode ∈ {from-identity, from-capture}; at most one flat marker;
    // markers true|absent; stale_by_minutes ≥ 1 when set; the axes are
    // optional booleans (absent — null-as-absent per
    // fixtures/.index.d.ts — | false | true; a literal null is read as
    // absent for legacy files).
    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const queue = parsed.value.object.get("queue") orelse return;
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
        const markers = [_][]const u8{
            "stale_by_missing_entry",   "stale_by_missing_fixture",
            "stale_by_harness_version", "stale_by_detect_version",
            "stale_by_fixture_hash",    "stale_by_channel_hash",
        };
        var marker_count: usize = 0;
        for (markers) |m| {
            const v = o.get(m) orelse continue;
            if (v == .bool) {
                if (!v.bool) return error.InvalidQueueMarker;
                marker_count += 1;
            } else if (v == .null) {
                // unset — fine
            } else return error.InvalidQueueMarker;
        }
        if (o.get("stale_by_minutes")) |mins| {
            if (mins == .integer) {
                if (mins.integer < 1) return error.InvalidQueueMarker;
                marker_count += 1;
            } else if (mins != .null) return error.InvalidQueueMarker;
        }
        if (marker_count > 1) return error.TooManyMarkers;
        for ([_][]const u8{ "known", "valid", "successful", "free" }) |axis| {
            const v = o.get(axis) orelse continue;
            if (v != .bool and v != .null) return error.InvalidQueueAxis;
        }
    }
}

test "index.json: errors keys are dims tuples; values are {reason ∈ closed set, failed_at}" {
    const parsed = (try readIndexParsed(testing.allocator)) orelse return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const errors = parsed.value.object.get("errors") orelse return;
    if (errors != .object) return error.InvalidErrors;
    const closed_reasons = [_][]const u8{
        "capture failed",   "unavailable",         "post-check mismatch",
        "no launch spec",   "unknown fixture file", "malformed fixture id",
        "malformed queue row",
    };
    var it = errors.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        var kit = std.mem.tokenizeScalar(u8, key, '-');
        var parts: usize = 0;
        while (kit.next()) |part| {
            if (part.len == 0) return error.InvalidErrorKey;
            if (!std.mem.eql(u8, part, "null")) {
                for (part) |c| {
                    if (!std.ascii.isAlphanumeric(c)) return error.InvalidErrorKey;
                }
            }
            parts += 1;
        }
        if (parts != 4) {
            std.debug.print("errors key {s} is not a 4-part dims tuple\n", .{key});
            return error.InvalidErrorKey;
        }
        if (kv.value_ptr.* != .object) return error.InvalidErrorEntry;
        const o = kv.value_ptr.object;
        const reason = o.get("reason") orelse return error.InvalidErrorEntry;
        if (reason != .string) return error.InvalidErrorEntry;
        var known = false;
        for (closed_reasons) |r| {
            if (std.mem.eql(u8, r, reason.string)) known = true;
        }
        if (!known) {
            std.debug.print("errors entry {s} has an unknown reason {s}\n", .{ key, reason.string });
            return error.UnknownErrorReason;
        }
        const failed_at = o.get("failed_at") orelse return error.InvalidErrorEntry;
        if (failed_at != .integer) return error.InvalidErrorEntry;
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
