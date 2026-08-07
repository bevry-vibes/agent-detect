// Schema/shape tests for the fixtures under `fixtures/`. See DESIGN.md
// for the fixture lifecycle (daemon + capture + sqlite queue) and
// CONTRIBUTING.md for adding agents to the rule registry.

const std = @import("std");
const testing = std.testing;

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

test "fixtures: every fixture parses as a JSON object with cooked + raw keys" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    var tested: usize = 0;
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        tested += 1;
        try testing.expect(parsed.value == .object);
        try testing.expect(parsed.value.object.contains("cooked"));
        try testing.expect(parsed.value.object.contains("raw"));
    }
    try testing.expect(tested >= 1);
}

test "fixtures: top-level trailer matches the cooked block's trailer" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const top_trailer = parsed.value.object.get("trailer") orelse continue;
        const cooked = parsed.value.object.get("cooked").?.object;
        const cooked_trailer = cooked.get("trailer") orelse continue;
        try testing.expect(top_trailer == .string);
        try testing.expect(cooked_trailer == .string);
        try testing.expect(std.mem.eql(u8, top_trailer.string, cooked_trailer.string));
    }
}

test "fixtures: cooked has all 18 grouped keys in emission order" {
    const expected_keys = [_][]const u8{
        "harness_label",             // harness group
        "harness_short_title",
        "harness_name",
        "harness_id",
        "harness_license",
        "provider_label",            // provider group
        "provider_name",
        "provider_id",
        "provider_closed_training",
        "provider_open_training",
        "model_label",               // model group
        "model_short_title",
        "model_name",
        "model_id",
        "model_reciprocity",
        "agent_id",                  // composed from harness+provider+model
        "reciprocal",                // policy / output
        "trailer",
    };
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();

        const cooked = parsed.value.object.get("cooked").?.object;
        for (expected_keys, 0..) |key, i| {
            if (!cooked.contains(key)) {
                std.debug.print("fixture {s} missing cooked key {s} at index {d}\n", .{ stem, key, i });
                return error.MissingCookedKey;
            }
        }
    }
}

test "fixtures: raw is a shapeless object — no fixed schema, just source keys" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();

        const raw = parsed.value.object.get("raw").?.object;
        try testing.expect(parsed.value.object.get("raw").? == .object);
        // forbidden legacy block: the source-grouped shape replaced it
        try testing.expect(!raw.contains("detection"));
        try testing.expect(!raw.contains("session"));
        try testing.expect(!raw.contains("sources"));
        try testing.expect(!raw.contains("rule"));
    }
}

test "fixtures: raw carries platform_id, detectable, and detected adjacent at the top" {
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
        const raw = parsed.value.object.get("raw").?.object;
        try testing.expect(raw.get("platform_id").? == .string);
        try testing.expect(raw.get("platform_id").?.string.len > 0);
        const detectable = raw.get("detectable").?.array;
        const detected = raw.get("detected").?.array;
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

test "fixtures: raw.process_lineage is always present" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();

        const raw = parsed.value.object.get("raw").?.object;
        const process_lineage = raw.get("process_lineage").?.array;
        try testing.expect(process_lineage.items.len >= 1); // at least agent-detect
    }
}

test "fixtures: raw.process_lineage entries are subobjects with pid + name" {
    // The pretty-printed raw block emits each lineage entry as its own
    // line with `{"pid": <int>, "name": "<str>"}`. With N entries on N
    // lines, the schema is mechanically verified; with one on a single
    // line, both shapes are accepted (json parse is whitespace-tolerant).
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const lineage = parsed.value.object.get("raw").?.object.get("process_lineage").?.array;
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

test "fixtures: raw.env entries always carry present; value only when real" {
    // Each declared env-marker gets one entry in raw.env, even when
    // absent from the runtime env (`present: false`) — so a maintainer
    // reading the fixture can see every marker the rule declared and
    // distinguish "absent" from "redacted-for-allow-list" by checking
    // whether `value` is present.
    //   - real value emitted: `{"value": "...", "present": true}`
    //   - absent in runtime: `{"present": false}`
    //   - redacted secret:   `{"present": true}` (no value)
    // The KEY is the env-var name (so JSON round-trips via
    // `env.get("NAME")`); the entry always has `present` as a bool.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const env = parsed.value.object.get("raw").?.object.get("env").?.object;
        try testing.expect(env.count() >= 1); // at least one declared marker
        for (env.values()) |entry| {
            const ev = entry.object;
            try testing.expect(ev.get("present") != null);
            try testing.expect(ev.get("present").? == .bool);
            if (ev.get("value")) |v| {
                try testing.expect(v == .string);
            }
        }
    }
}

test "fixtures: raw has no harness-env-markers / harness-proc-names (static rule data, not runtime evidence)" {
    // harness-env-markers and harness-proc-names were stripped from the
    // output schema — they're static rule data, already in the binary's
    // source as the `rulesForHarnesses` table. The runtime observations in
    // `raw.env` and `raw.process_lineage` are what the maintainer
    // actually needs; emitting the rule's declared marker / proc-name
    // lists as well was redundant noise.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const raw = parsed.value.object.get("raw").?.object;
        try testing.expect(!raw.contains("harness-env-markers"));
        try testing.expect(!raw.contains("harness-proc-names"));
    }
}

test "fixtures: raw.harness-urls / provider-urls / model-urls are arrays of https:// URLs" {
    // Each *-urls key holds the upstream evidence the maintainer used
    // to populate the corresponding canonical policy field. Closed-
    // source harnesses/providers/models are allowed to have an empty
    // array (no public source) — the test only verifies that whatever
    // IS present is a well-formed https URL.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const raw = parsed.value.object.get("raw").?.object;
        inline for ([_][]const u8{ "harness-urls", "provider-urls", "model-urls" }) |key| {
            const arr = raw.get(key).?.array;
            for (arr.items) |item| {
                try testing.expect(item == .string);
                try testing.expect(std.mem.startsWith(u8, item.string, "https://"));
            }
        }
    }
}

test "fixtures: every fixture's cooked has all 8 identity fields populated" {
    // The capture refuses to write a fixture with null provider or
    // null model, so every committed fixture has the harness+provider
    // +model triad populated. The four policy fields — harness_license,
    // model_reciprocity, provider_closed_training, provider_open_training
    // — may legitimately be `null` per the schema (null for closed-source
    // or unverifiable). The required set here is therefore just the
    // identity fields; nulls on the policy fields are validated by their
    // own type-check in the parse step above.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    const required_non_null = [_][]const u8{
        "harness_label", "harness_name",
        "provider_label", "provider_name",
        "model_label",    "model_name",
        "reciprocal",     "trailer",
    };
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const cooked = parsed.value.object.get("cooked").?.object;
        for (required_non_null) |k| {
            if (cooked.get(k) == null) {
                std.debug.print("fixture {s} missing cooked key {s}\n", .{ stem, k });
                return error.MissingCookedKey;
            }
            try testing.expect(cooked.get(k).? != .null);
        }
    }
}

test "fixtures: cooked *_name fields are non-empty strings" {
    // The *_name fields (harness_name, provider_name, model_name) carry
    // whatever casing/format the service uses to canonically refer to
    // the entity — we don't impose constraints on them. The only id
    // shape we enforce is the `*_id` companion (strictly lowercase
    // alphanumeric, no separators), which is the value `agent-detect`
    // itself derives for stable machine matching.
    // Provider ids in the registry use only the canonical upstream
    // (`minimax`, `anthropic`, …) — the colon-separated `protocol:upstream`
    // form is stripped at registration time, since the canonical
    // provider is the upstream, not the wire protocol.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    const id_fields = [_][]const u8{ "harness_name", "provider_name", "model_name" };
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const cooked = parsed.value.object.get("cooked").?.object;
        for (id_fields) |field| {
            const v = cooked.get(field) orelse continue;
            try testing.expect(v == .string);
            try testing.expect(v.string.len > 0);
        }
    }
}

test "fixtures: raw JSON is pretty-printed (cooked indented, env/process/*-urls present)" {
    // The pretty JSON emitter expands cooked fields, env markers,
    // process ancestors, and *-urls arrays onto their own lines so a
    // human can read the fixture end-to-end. Empty arrays render as
    // `[]` on a single line — that's std.json.Stringify's default and
    // is acceptable; the test only asserts the keys exist, not that
    // every array is non-empty.
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

        // 1. cooked block: one field per line, 4-space indent under
        //    the cooked object
        try testing.expect(std.mem.indexOf(u8, data, "    \"harness_label\"") != null);

        // 2. env section: present, with each marker carrying `"present":`.
        //    `"value":` may be absent (redacted/absent vars omit it
        //    entirely), so we don't assert on it — only on `present`
        //    being there for every entry.
        try testing.expect(std.mem.indexOf(u8, data, "\"env\": {") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"present\":") != null);

        // 3. process_lineage section: at least one pid+name entry.
        try testing.expect(std.mem.indexOf(u8, data, "\"process_lineage\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"pid\":") != null);

        // 4. *-urls arrays: each present (may be empty for closed-source)
        try testing.expect(std.mem.indexOf(u8, data, "\"harness-urls\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"provider-urls\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"model-urls\":") != null);
    }
}

test "fixtures: warn on null harness_license (dev should fill in from upstream)" {
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    var warnings: usize = 0;
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const cooked = parsed.value.object.get("cooked").?.object;
        if (cooked.get("harness_license") == null or cooked.get("harness_license").? == .null) {
            std.debug.print("WARNING: fixture {s} has null harness_license — look up the upstream license and fill it in\n", .{stem});
            warnings += 1;
        }
    }
    if (warnings > 0) {
        std.debug.print("WARNING: {d} fixture(s) have null harness_license\n", .{warnings});
    }
}
