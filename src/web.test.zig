// URL-builder tests for the merged `index` action's pure core: the search
// view's url shapes (homepage / filtered registry with the `#registry` anchor)
// and the entity views' route urls (/{agent,harness,provider,model}/{id},
// carrying the filters that gate them — the violating filters stay out, which
// is runIndex's own logic, not the builders'). The exit-code and gating
// behavior is pinned by the runIndex wiring and the site's routes.

const std = @import("std");
const testing = std.testing;
const core = @import("lib/core.zig");

fn expectSearchUrl(expected: []const u8, q: core.IndexQuery) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const url = try core.buildIndexSearchUrl(arena.allocator(), q);
    try testing.expectEqualStrings(expected, url);
}

fn expectEntityUrl(expected: []const u8, kind: []const u8, id: []const u8, q: core.IndexQuery) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const url = try core.buildEntityUrl(arena.allocator(), kind, id, q);
    try testing.expectEqualStrings(expected, url);
}

test "search url: no filters is the bare homepage" {
    try expectSearchUrl(core.siteUrl ++ "/", .{});
}

test "search url: any filter anchors the registry at #registry" {
    try expectSearchUrl(core.siteUrl ++ "/?platform=linux#registry", .{ .platform = "linux" });
    try expectSearchUrl(core.siteUrl ++ "/?email=a@b&free=false#registry", .{ .email = "a@b", .free = false });
    try expectSearchUrl(
        core.siteUrl ++ "/?platform=linux&search=kimi&free=true&reciprocal=false#registry",
        .{ .platform = "linux", .search = "kimi", .free = true, .reciprocal = false },
    );
}

test "entity url: the bare route carries no query" {
    try expectEntityUrl(core.siteUrl ++ "/agent/cline-chutes-glm51", "agent", "cline-chutes-glm51", .{});
    try expectEntityUrl(core.siteUrl ++ "/harness/cline", "harness", "cline", .{});
    try expectEntityUrl(core.siteUrl ++ "/model/glm52", "model", "glm52", .{});
}

test "entity url: the gating filters ride the route" {
    try expectEntityUrl(
        core.siteUrl ++ "/agent/cline-chutes-glm51?platform=darwin&reciprocal=true",
        "agent",
        "cline-chutes-glm51",
        .{ .platform = "darwin", .reciprocal = true },
    );
    try expectEntityUrl(
        core.siteUrl ++ "/provider/chutes?free=true",
        "provider",
        "chutes",
        .{ .free = true },
    );
}
