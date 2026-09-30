// URL-builder tests for the registry/index actions' pure core: the registry's
// three url shapes (homepage / filtered registry with the `#registry` anchor /
// the `--agent` result page), the new query filters (email, platform,
// free, reciprocal), and the index's `#index` anchor. The exit-code and
// conflict behavior lives in exit_statuses.test.zig; the opener spawn
// (`core.openURL`) is platform I/O — exercised by hand, not here.

const std = @import("std");
const testing = std.testing;
const core = @import("lib/core.zig");

fn expectRegistryUrl(expected: []const u8, q: core.RegistryQuery) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const url = try core.buildRegistryUrl(arena.allocator(), q);
    try testing.expectEqualStrings(expected, url);
}

fn expectIndexUrl(expected: []const u8, h: []const u8, p: []const u8, m: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const url = try core.buildIndexUrl(arena.allocator(), h, p, m);
    try testing.expectEqualStrings(expected, url);
}

test "registry url: no filters is the bare homepage" {
    try expectRegistryUrl(core.siteUrl ++ "/", .{});
}

test "registry url: any partial set filters the registry at the #registry anchor" {
    try expectRegistryUrl(core.siteUrl ++ "/?harness=kimicode#registry", .{ .harness = "kimicode" });
    try expectRegistryUrl(core.siteUrl ++ "/?harness=kimicode&model=glm52#registry", .{ .harness = "kimicode", .model = "glm52" });
    try expectRegistryUrl(core.siteUrl ++ "/?provider=chutes&model=glm52#registry", .{ .provider = "chutes", .model = "glm52" });
}

test "registry url: the complete combo is the agent result page, not a filter" {
    try expectRegistryUrl(core.siteUrl ++ "/?agent=kimicode-chutes-glm52", .{ .harness = "kimicode", .provider = "chutes", .model = "glm52" });
    try expectRegistryUrl(core.siteUrl ++ "/?agent=cline-chutes-kimik3", .{ .agent = "cline-chutes-kimik3" });
    // the platform param is a registry filter now — it never lands on a result page
    try expectRegistryUrl(core.siteUrl ++ "/?agent=cline-chutes-kimik3", .{ .agent = "cline-chutes-kimik3", .platform = "linux" });
}

test "registry url: the combo-level filters compose into the query" {
    try expectRegistryUrl(core.siteUrl ++ "/?email=a@b&platform=linux&free=true&reciprocal=false#registry", .{
        .email = "a@b",
        .platform = "linux",
        .free = true,
        .reciprocal = false,
    });
    try expectRegistryUrl(core.siteUrl ++ "/?harness=kimicode&reciprocal=true#registry", .{ .harness = "kimicode", .reciprocal = true });
}

test "index url: the dim filters anchor at #index" {
    try expectIndexUrl(core.siteUrl ++ "/#index", "", "", "");
    try expectIndexUrl(core.siteUrl ++ "/?harness=cline#index", "cline", "", "");
    try expectIndexUrl(core.siteUrl ++ "/?provider=chutes&model=glm52#index", "", "chutes", "glm52");
}
