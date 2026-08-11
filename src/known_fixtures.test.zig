// Schema/shape tests for the fixtures under `fixtures/`. See DESIGN.md
// for the fixture lifecycle (daemon + capture + sqlite queue) and
// CONTRIBUTING.md for adding agents to the rule registry.

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

test "fixtures: raw is slim — no env/file objects; secret env evidence is <redacted>" {
    // Decision #4 (raw slimming): the raw block drops the `env` object
    // and the per-file config/session objects — the `evidence` section
    // documents the sources that informed each canonical deduction. The
    // remaining top-level keys are the fixed set (+ the optional static
    // `harness_version`). Env-source evidence claims on non-allowlisted
    // names carry the literal `<redacted>` value; allowlisted names keep
    // the value the detector read.
    const fixed_keys = [_][]const u8{
        "platform_id", "detectable", "detected", "process_lineage",
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
        const raw = parsed.value.object.get("raw").?.object;
        try testing.expect(!raw.contains("env"));
        for (raw.keys()) |key| {
            var known = false;
            for (fixed_keys) |fk| {
                if (std.mem.eql(u8, key, fk)) known = true;
            }
            // the optional static rule-declared version is allowed.
            if (std.mem.eql(u8, key, "harness_version")) known = true;
            if (!known) {
                std.debug.print("fixture {s} has unexpected raw top-level key '{s}'\n", .{ stem, key });
                return error.UnexpectedRawKey;
            }
        }
        // evidence claims: env-source on non-allowlisted names → `<redacted>`.
        const evidence = raw.get("evidence").?.array;
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

test "fixtures: raw JSON is pretty-printed (cooked indented, no env block, process/*-urls present)" {
    // The pretty JSON emitter expands cooked fields, process
    // ancestors, and *-urls arrays onto their own lines so a human can
    // read the fixture end-to-end. Empty arrays render as `[]` on a
    // single line — that's std.json.Stringify's default and is
    // acceptable; the test only asserts the keys exist, not that every
    // array is non-empty. The `env` object is absent (raw slimming,
    // decision #4).
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

        // 2. no `env` block in the slimmed raw shape.
        try testing.expect(std.mem.indexOf(u8, data, "\"env\":") == null);

        // 3. process_lineage section: at least one pid+name entry.
        try testing.expect(std.mem.indexOf(u8, data, "\"process_lineage\":") != null);
        try testing.expect(std.mem.indexOf(u8, data, "\"pid\":") != null);

        // 4. *-urls arrays: each present (may be empty for closed-source)
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
        const cooked = parsed.value.object.get("cooked").?.object;
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

test "fixtures: every recipe agent_id splits into rule-table harness/provider/model; every harness rule has ≥1 recipe" {
    // Decision #1/2d — the matrix recipes must only reference known
    // rules (an unknown dim is a typo that would silently fail the
    // from-raw sweep), and every harness in scope must have at least
    // one recipe so `fixtures queue --recipes` covers the matrix.
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

test "fixtures: every fixture carries a valid origin; from-ids fixtures carry empty evidence" {
    // Decision #7 — the top-level `origin` key classifies every fixture
    // as declared (`from-ids`) or observed (`from-raw`/`from-capture`).
    // Declared fixtures carry an empty `raw.evidence` array (nothing was
    // observed); observed fixtures carry one claim per detected dim.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const root = parsed.value.object;
        const origin = if (root.get("origin")) |o| (if (o == .string) o.string else "") else "";
        const valid_origin = std.mem.eql(u8, origin, "from-ids") or
            std.mem.eql(u8, origin, "from-raw") or
            std.mem.eql(u8, origin, "from-capture");
        if (!valid_origin) {
            std.debug.print("fixture {s} has invalid origin '{s}'\n", .{ stem, origin });
            return error.InvalidOrigin;
        }
        const raw = root.get("raw").?.object;
        const evidence = raw.get("evidence") orelse {
            std.debug.print("fixture {s} raw has no evidence key\n", .{stem});
            return error.MissingEvidence;
        };
        try testing.expect(evidence == .array);
        if (std.mem.eql(u8, origin, "from-ids")) {
            try testing.expect(evidence.array.items.len == 0);
        }
    }
}

test "fixtures: observed (from-raw/from-capture) fixtures pass the evidence-claim check" {
    // Decision #11 — every detected dim in an observed fixture must be
    // attributed to a source present in raw whose value matches the
    // cooked dim. The mechanical check cannot judge semantic
    // deducibility — that is human review — but it catches "no
    // evidence" and "evidence contradicts cooked". `from-ids` fixtures
    // are declared, not observed, so they are excluded by origin.
    const stems = try discoverStems(testing.allocator);
    defer {
        for (stems) |s| testing.allocator.free(s);
        testing.allocator.free(stems);
    }
    var tested: usize = 0;
    for (stems) |stem| {
        const parsed = (try readFixtureParsed(testing.allocator, stem)) orelse continue;
        defer parsed.deinit();
        const root = parsed.value.object;
        const origin = if (root.get("origin")) |o| (if (o == .string) o.string else "") else "";
        if (std.mem.eql(u8, origin, "from-ids")) continue;
        tested += 1;
        const raw = root.get("raw").?;
        const cooked = root.get("cooked").?;
        if (!main.dev.evidenceClaimsValid(raw, cooked)) {
            std.debug.print("fixture {s} failed the evidence-claim check\n", .{stem});
            return error.EvidenceClaimsInvalid;
        }
    }
    try testing.expect(tested >= 1);
}
