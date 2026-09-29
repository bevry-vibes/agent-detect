// URL-builder tests for the `web` action's pure core (`core.buildWebUrl`): the
// three url shapes (homepage / filtered registry with the `#registry` anchor /
// the combo result page), the platform pin landing only on the result page,
// and the strict-slug composition matching the site's `?agent=` ids.
// The opener spawn (`core.openURL`) is platform I/O — exercised by hand, not here.

const std = @import("std");
const testing = std.testing;
const core = @import("lib/core.zig");

fn expectUrl(expected: []const u8, h: []const u8, p: []const u8, m: []const u8, platform: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const url = try core.buildWebUrl(arena.allocator(), h, p, m, platform);
    try testing.expectEqualStrings(expected, url);
}

test "web url: no dims is the bare homepage" {
    try expectUrl(core.siteUrl ++ "/", "", "", "", "");
}

test "web url: any partial set filters the registry at the #registry anchor" {
    try expectUrl(core.siteUrl ++ "/?harness=kimicode#registry", "kimicode", "", "", "");
    try expectUrl(core.siteUrl ++ "/?harness=kimicode&model=glm52#registry", "kimicode", "", "glm52", "");
    try expectUrl(core.siteUrl ++ "/?provider=chutes&model=glm52#registry", "", "chutes", "glm52", "");
}

test "web url: the complete combo is the result page, not a filter" {
    try expectUrl(core.siteUrl ++ "/?agent=kimicode-chutes-glm52", "kimicode", "chutes", "glm52", "");
}

test "web url: the platform pin lands only on the result page" {
    try expectUrl(core.siteUrl ++ "/?agent=kimicode-chutes-glm52&platform=linux", "kimicode", "chutes", "glm52", "linux");
    // on a partial set the pin is meaningless (the index ignores ?platform=) —
    // runWeb rejects it before building; the builder itself just ignores it
    try expectUrl(core.siteUrl ++ "/?harness=kimicode#registry", "kimicode", "", "", "linux");
}
