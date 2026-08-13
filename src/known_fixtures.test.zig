// Schema/shape tests for the fixtures under `fixtures/`. See DESIGN.md
// for the fixture lifecycle (daemon + capture + sqlite queue) and
// CONTRIBUTING.md for adding agents to the rule registry.
//
// The suite validates committed-file shape only. Regeneration
// completeness is the envelope test below: legacy `cooked`-shaped files
// (still on disk until their queued regeneration lands on their
// platform's host) fail it — that failure is the regen signal, not a
// code bug. Channel-scoped tests skip files that lack the channel they
// inspect.

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
            // filter to *.json so the sqlite store (`index.sqlite3`) and any non-fixture files are ignored
            try stems.append(a, try a.dupe(u8, name[0 .. name.len - suffix.len]));
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

/// The 17 canonical `identify` fields, in emission order. No `trailer`
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

test "fixtures: identify has all 17 grouped keys in emission order, no trailer key" {
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
    // platform_id, detectable, detected, process_lineage, *-urls,
    // evidence. No env/file objects; secret env evidence is `<redacted>`.
    const fixed_keys = [_][]const u8{
        "platform_id",  "detectable",    "detected",   "process_lineage",
        "harness-urls", "provider-urls", "model-urls", "evidence",
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

test "fixtures: every recipe agent_id splits into rule-table harness/provider/model; every harness rule has ≥1 recipe" {
    // Decision #1/2d — the matrix recipes must only reference known
    // rules (an unknown dim is a typo that would silently fail the
    // identity/capture sweep), and every harness in scope must have at
    // least one recipe so `fixtures queue --recipes` covers the matrix.
    for (main.dev.recipesForFixtures) |r| {
        const parts = split3(r.agent_id) orelse {
            std.debug.print("recipe {s} has a malformed agent_id\n", .{r.agent_id});
            return error.MalformedRecipeId;
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
            std.debug.print("recipe {s} references an unknown dim (h:{}, p:{}, m:{})\n", .{ r.agent_id, h_ok, p_ok, m_ok });
            return error.UnknownRecipeDim;
        }
    }
    for (main.rulesForHarnesses) |rr| {
        var found = false;
        for (main.dev.recipesForFixtures) |r| {
            const parts = split3(r.agent_id) orelse continue;
            if (slugifyMatches(rr.name, parts[0])) found = true;
        }
        if (!found) {
            std.debug.print("harness rule {s} has no recipe in recipesForFixtures\n", .{rr.name});
            return error.HarnessWithoutRecipe;
        }
    }
}

test "fixtures: every recipe's harness segment resolves to a harness rule" {
    // The recipes' per-row probeNames were deleted — probe/launch names
    // now come from the harness rules via `harnessRuleForFixtureId`. A
    // recipe whose first `agent_id` segment doesn't resolve would be
    // silently unprobable/unlaunchable.
    for (main.dev.recipesForFixtures) |r| {
        if (main.harnessRuleForFixtureId(testing.allocator, r.agent_id) == null) {
            std.debug.print("recipe {s} harness segment does not resolve to a harness rule\n", .{r.agent_id});
            return error.UnresolvedHarnessSegment;
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
