// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");

const targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
    .{ .name = "windows-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu } },
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode") orelse .ReleaseSmall;

    // default: native build into zig-out
    const native_target = b.standardTargetOptions(.{});
    const native_exe = b.addExecutable(.{
        .name = "agent-detection",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = native_target,
            .optimize = optimize,
            .strip = true,
        }),
    });
    b.installArtifact(native_exe);

    // `zig build dist` — cross-compile every target into bin/
    const dist_step = b.step("dist", "cross-compile all platform binaries into bin/");
    for (targets) |t| {
        const exe = b.addExecutable(.{
            .name = b.fmt("agent-detection-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = optimize,
                .strip = true,
            }),
        });
        // run as `zig build dist --prefix .` to emit bin/agent-detection-<os>-<arch>[.exe]
        const install = b.addInstallArtifact(exe, .{});
        dist_step.dependOn(&install.step);
    }
}
