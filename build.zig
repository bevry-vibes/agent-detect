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

    // `--dev` enables the dev-only subcommands (the `known` namespace:
    // daemon, agent, queue, dequeue, purge) and the larger code path
    // that gathers raw observations. Default is `false` for the
    // released binary; `zig build dev` flips it to `true` for the
    // maintainer-only `agent-detection-dev` binary. The dev binary is
    // NOT cross-compiled; `zig build dist` only emits the released
    // binary.
    const dev = b.option(bool, "dev", "include dev-only subcommands (known namespace, etc.)") orelse false;

    // Read the project version out of `build.zig.zon` so the binary's
    // `--version` output reflects the actual release tag. The format is
    // calver: `<year>.<month>.<day>-<revision>` (e.g. `2026.8.6-1`).
    // Bumped at cut-time by the maintainer runbook documented in
    // DESIGN.md under "distribution / versioned releases".
    const version = readVersionFromZon(b);

    // `--dev` is required when building the dev binary (never read by
    // the released binary target — that one always builds with
    // `dev=false`). Confusing the two would emit a binary whose dev
    // subcommands exist in the released artifact, which is exactly
    // what we're trying to avoid.
    //
    // Build options are exposed to the source via a `build_options`
    // module; main.zig reads `build_options.dev` and
    // `build_options.version` to gate the blocks / print the version.
    const build_options = b.addOptions();
    build_options.addOption(bool, "dev", dev);
    build_options.addOption([]const u8, "version", version);

    // default: native build into zig-out — the released binary
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
    native_exe.root_module.addImport("build_options", build_options.createModule());
    b.installArtifact(native_exe);

    // `zig build dev` — builds the maintainer-only dev binary with
    // `-Ddev=true`. Same source as the released binary, but the
    // dev-only subcommands (the `known` namespace + `refresh run`)
    // and the KnownFixturesForKnownAgents table are linked in. The
    // released binary is unaffected (built with dev=false).
    //
    // The dev binary needs its own `build_options` with `dev=true`,
    // so we build a fresh options module here rather than reusing
    // the `dev` bool (which is the value of the option flag, not a
    // hardcoded `true`).
    const dev_options = b.addOptions();
    dev_options.addOption(bool, "dev", true);
    dev_options.addOption([]const u8, "version", version);
    const dev_exe = b.addExecutable(.{
        .name = "agent-detection-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = native_target,
            .optimize = optimize,
            .strip = true,
        }),
    });
    dev_exe.root_module.addImport("build_options", dev_options.createModule());
    b.installArtifact(dev_exe);

    // `zig build dev` step — install the dev binary into zig-out/bin
    // (so it's available alongside the released binary). Doesn't
    // RUN the binary: the maintainer invokes it from their own
    // terminal to avoid process-tree pollution from this dev
    // environment.
    const dev_step = b.step("dev", "install agent-detection-dev (maintainer-only, with dev subcommands)");
    dev_step.dependOn(&b.addInstallArtifact(dev_exe, .{}).step);

    // `zig build test` — runs every `src/*_test.zig` / `src/*test*.zig` file.
    // Each test file imports `src/main.zig` to reach `buildJson`, etc.
    const test_step = b.step("test", "run zig tests");
    const test_files = [_][]const u8{
        "src/known_fixtures.test.zig",
    };
    inline for (test_files) |file| {
        const test_exe = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = native_target,
                .optimize = optimize,
            }),
        });
        test_exe.root_module.addImport("build_options", build_options.createModule());
        const run = b.addRunArtifact(test_exe);
        test_step.dependOn(&run.step);
    }

    // `zig build dist` — cross-compile every target into bin/. Only
    // the released binary is emitted; `agent-detection-dev` is not
    // distributed.
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
        exe.root_module.addImport("build_options", build_options.createModule());
        // run as `zig build dist --prefix .` to emit bin/agent-detection-<os>-<arch>[.exe]
        const install = b.addInstallArtifact(exe, .{});
        dist_step.dependOn(&install.step);
    }
}

/// Read `.version = "..."` out of `build.zig.zon` at configure time so
/// the binary's `--version` flag reflects the release tag without
/// hardcoding it in two places. Single source of truth: the zon file.
/// A minimal string-slice loader is enough — we only need the
/// substring between the first `.version = "` and the closing `"`.
fn readVersionFromZon(b: *std.Build) []const u8 {
    const allocator = b.allocator;
    const zon_text = b.build_root.handle.readFileAlloc(
        b.graph.io, "build.zig.zon", allocator, .limited(4096),
    ) catch {
        std.log.err("could not read build.zig.zon", .{});
        std.process.exit(1);
    };
    defer allocator.free(zon_text);
    const key = ".version = \"";
    const kv_start = (std.mem.indexOf(u8, zon_text, key) orelse {
        std.log.err("build.zig.zon missing {s}", .{key});
        std.process.exit(1);
    }) + key.len;
    const kv_end = std.mem.indexOfPos(u8, zon_text, kv_start, "\"") orelse {
        std.log.err("build.zig.zon .version not terminated", .{});
        std.process.exit(1);
    };
    return allocator.dupe(u8, zon_text[kv_start..kv_end]) catch {
        std.log.err("oom duplicating version", .{});
        std.process.exit(1);
    };
}
