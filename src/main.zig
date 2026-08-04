// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detection — infer the current agent harness, interface/provider, and
// model from the environment and harness data files, least-invasive first:
//   1. environment variables        (harness)
//   2. <harness data>/settings      (live interface + model)
//   3. own session via pid ancestry (session snapshot; parallel-safe)
//   4. session messages.json        (generation truth: last modelInfo)
// Never prints or persists secrets (auth tokens are never read into output).
//
// Written against zig 0.16 std (std.Io interface; main takes std.process.Init).

const std = @import("std");
const builtin = @import("builtin");

const Detection = struct {
    harness: ?[]const u8 = null, // display name, e.g. "Cline"
    harness_env: bool = false, // harness env vars present
    interface_id: ?[]const u8 = null, // e.g. "cline-pass"
    interface: ?[]const u8 = null, // e.g. "Cline Pass"
    model_id: ?[]const u8 = null, // e.g. "cline-pass/kimi-k3"
    model: ?[]const u8 = null, // e.g. "Kimi K3"
    model_updated_at: ?[]const u8 = null,
    open_weight: []const u8 = "unknown", // "true" | "false" | "unknown"
    session_id: ?[]const u8 = null,
    session_provider: ?[]const u8 = null,
    session_model: ?[]const u8 = null,
    session_resolution: []const u8 = "none", // "ancestry" | "fallback-cwd" | "none"
    last_msg_model: ?[]const u8 = null,
    last_msg_provider: ?[]const u8 = null,
    trailer: ?[]const u8 = null,
};

const ModelRule = struct { slug: []const u8, display: []const u8, open: ?bool };
const model_rules = [_]ModelRule{
    .{ .slug = "kimi-k3", .display = "Kimi K3", .open = true },
    .{ .slug = "glm-5.2", .display = "GLM 5.2", .open = true },
    .{ .slug = "minimax-m3", .display = "MiniMax-M3", .open = true },
    .{ .slug = "qwen3.8-max", .display = "Qwen3.8-Max", .open = false }, // closed until its open-weight release lands
};

const InterfaceRule = struct { id: []const u8, display: []const u8 };
const interface_rules = [_]InterfaceRule{
    .{ .id = "cline-pass", .display = "Cline Pass" },
    .{ .id = "cline", .display = "Cline" },
};

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

/// capitalize the first letter of each dash-separated token, join with spaces
fn titleCase(a: std.mem.Allocator, slug: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, slug, '-');
    var first = true;
    while (it.next()) |tok| {
        if (!first) try list.append(a, ' ');
        first = false;
        if (tok.len > 0) {
            try list.append(a, std.ascii.toUpper(tok[0]));
            try list.appendSlice(a, tok[1..]);
        }
    }
    return list.toOwnedSlice(a);
}

const ModelOut = struct { display: []const u8, open: []const u8 };

fn modelForSlug(a: std.mem.Allocator, slug: []const u8) !ModelOut {
    for (model_rules) |r| {
        if (std.mem.eql(u8, r.slug, slug))
            return .{ .display = r.display, .open = if (r.open orelse false) "true" else "false" };
    }
    // family-prefix fallbacks for known open-weight families
    const families = [_][]const u8{ "kimi", "glm", "minimax" };
    for (families) |fam| {
        if (std.mem.startsWith(u8, slug, fam))
            return .{ .display = try titleCase(a, slug), .open = "true" };
    }
    return .{ .display = try titleCase(a, slug), .open = "unknown" };
}

fn interfaceForId(id: []const u8) ?[]const u8 {
    for (interface_rules) |r| {
        if (std.mem.eql(u8, r.id, id)) return r.display;
    }
    return null;
}

fn jstr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jint(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// extract the string value of `key` appearing at/after byte offset `from`
/// (scan-after-position parse; used on the last modelInfo block only)
fn extractAfter(raw: []const u8, from: usize, key: []const u8) ?[]const u8 {
    const k = std.mem.findPos(u8, raw, from, key) orelse return null;
    const colon = std.mem.findScalarPos(u8, raw, k + key.len, ':') orelse return null;
    const q1 = std.mem.findScalarPos(u8, raw, colon, '"') orelse return null;
    const q2 = std.mem.findScalarPos(u8, raw, q1 + 1, '"') orelse return null;
    return raw[q1 + 1 .. q2];
}

/// lowercase-alphanumeric email local part, e.g. ("Cline","Kimi K3") -> "cline-kimik3@local"
fn trailerEmail(a: std.mem.Allocator, harness: []const u8, model: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    for (harness) |c| {
        if (std.ascii.isAlphanumeric(c)) try list.append(a, std.ascii.toLower(c));
    }
    try list.append(a, '-');
    for (model) |c| {
        if (std.ascii.isAlphanumeric(c)) try list.append(a, std.ascii.toLower(c));
    }
    try list.appendSlice(a, "@local");
    return list.toOwnedSlice(a);
}

fn jsonEscape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(a, "\\\""),
            '\\' => try list.appendSlice(a, "\\\\"),
            else => try list.append(a, c),
        }
    }
    return list.toOwnedSlice(a);
}

// ============================================================================
// ladder step 3: process ancestry (own session identification)

// toolhelp32 (removed from zig 0.16 std.os.windows; declared here)
const TH32CS_SNAPPROCESS: u32 = 2;
const PROCESSENTRY32W = extern struct {
    dwSize: u32 = 0,
    cntUsage: u32 = 0,
    th32ProcessID: u32 = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: u32 = 0,
    cntThreads: u32 = 0,
    th32ParentProcessID: u32 = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: u32 = 0,
    szExeFile: [260]u16 = [_]u16{0} ** 260,
};
extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: std.os.windows.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) c_int;
extern "kernel32" fn Process32NextW(hSnapshot: std.os.windows.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) c_int;

fn ancestorPids(a: std.mem.Allocator, io: std.Io) []const u32 {
    if (builtin.os.tag == .windows) return ancestorsWindows(a) catch &.{};
    if (builtin.os.tag == .linux) return ancestorsLinux(a, io) catch &.{};
    // macOS cross-builds have no libc; process walking unsupported -> cwd fallback
    return &.{};
}

fn ancestorsWindows(a: std.mem.Allocator) ![]const u32 {
    if (builtin.os.tag != .windows) return &.{};
    const w = std.os.windows;
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    const invalid: w.HANDLE = @ptrFromInt(std.math.maxInt(usize));
    if (snap == invalid) return error.SnapshotFailed;
    defer w.CloseHandle(snap);
    const ProcPair = struct { pid: u32, ppid: u32 };
    var procs: std.ArrayList(ProcPair) = .empty;
    var entry: PROCESSENTRY32W = .{};
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) != 0) {
        while (true) {
            try procs.append(a, .{ .pid = entry.th32ProcessID, .ppid = entry.th32ParentProcessID });
            if (Process32NextW(snap, &entry) == 0) break;
        }
    }
    var list: std.ArrayList(u32) = .empty;
    var pid: u32 = w.GetCurrentProcessId();
    while (pid != 0) {
        try list.append(a, pid);
        var next: u32 = 0;
        for (procs.items) |p| {
            if (p.pid == pid) {
                next = p.ppid;
                break;
            }
        }
        pid = next;
    }
    return list.toOwnedSlice(a);
}

fn ancestorsLinux(a: std.mem.Allocator, io: std.Io) ![]const u32 {
    if (builtin.os.tag != .linux) return &.{};
    var list: std.ArrayList(u32) = .empty;
    var pid: u32 = @intCast(std.os.linux.getpid());
    while (pid > 1) {
        try list.append(a, pid);
        const path = try std.fmt.allocPrint(a, "/proc/{d}/stat", .{pid});
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch break;
        const close = std.mem.findScalarLast(u8, data, ')') orelse break;
        var tok = std.mem.tokenizeScalar(u8, data[close + 2 ..], ' ');
        _ = tok.next(); // state
        const ppid = tok.next() orelse break;
        pid = std.fmt.parseInt(u32, ppid, 10) catch break;
    }
    return list.toOwnedSlice(a);
}

// ============================================================================
// cline session discovery

const Session = struct {
    id: []const u8 = "",
    pid: ?i64 = null,
    status: []const u8 = "",
    cwd: []const u8 = "",
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    messages_path: ?[]const u8 = null,
    started_at: []const u8 = "",
};

fn loadSessions(a: std.mem.Allocator, io: std.Io, sessions_root: []const u8) []Session {
    var list: std.ArrayList(Session) = .empty;
    const cwd_dir = std.Io.Dir.cwd();
    var dir = cwd_dir.openDir(io, sessions_root, .{ .iterate = true }) catch return list.toOwnedSlice(a) catch &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        const path = std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ sessions_root, ent.name, ent.name }) catch continue;
        const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch continue;
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch continue;
        if (parsed.value != .object) continue;
        const o = parsed.value.object;
        list.append(a, .{
            .id = a.dupe(u8, ent.name) catch continue,
            .pid = jint(o, "pid"),
            .status = jstr(o, "status") orelse "",
            .cwd = jstr(o, "cwd") orelse "",
            .provider = jstr(o, "provider"),
            .model = jstr(o, "model"),
            .messages_path = jstr(o, "messages_path"),
            .started_at = jstr(o, "started_at") orelse "",
        }) catch continue;
    }
    return list.toOwnedSlice(a) catch &.{};
}

fn normCwd(a: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const lowered = try std.ascii.allocLowerString(a, cwd);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, lowered, '/', '\\');
    return lowered;
}

const FoundSession = struct { s: ?Session, how: []const u8 };

fn findOwnSession(a: std.mem.Allocator, io: std.Io, sessions: []Session, ancestors: []const u32) !FoundSession {
    // nearest ancestor pid wins (parallel-session safe)
    for (ancestors) |ap| {
        for (sessions) |s| {
            const sp = s.pid orelse continue;
            if (sp == ap and std.ascii.eqlIgnoreCase(s.status, "running"))
                return .{ .s = s, .how = "ancestry" };
        }
    }
    // fallback: newest running session in our working directory
    const cwd = std.process.currentPathAlloc(io, a) catch return .{ .s = null, .how = "none" };
    const ncwd = normCwd(a, cwd) catch return .{ .s = null, .how = "none" };
    var best: ?Session = null;
    for (sessions) |s| {
        if (!std.ascii.eqlIgnoreCase(s.status, "running")) continue;
        const scwd = normCwd(a, s.cwd) catch continue;
        if (!std.mem.eql(u8, scwd, ncwd)) continue;
        if (best == null or std.mem.order(u8, s.started_at, best.?.started_at) == .gt) best = s;
    }
    if (best) |b| return .{ .s = b, .how = "fallback-cwd" };
    return .{ .s = null, .how = "none" };
}

// ============================================================================
// ladder step 4: generation truth (last assistant modelInfo in messages.json)

const LastMsg = struct { id: ?[]const u8, provider: ?[]const u8 };

fn lastModelInfo(a: std.mem.Allocator, io: std.Io, messages_path: []const u8) LastMsg {
    const none = LastMsg{ .id = null, .provider = null };
    const data = std.Io.Dir.cwd().readFileAlloc(io, messages_path, a, @enumFromInt(512 << 20)) catch return none;
    const p = std.mem.findLast(u8, data, "\"modelInfo\"") orelse return none;
    return .{
        .id = extractAfter(data, p, "\"id\""),
        .provider = extractAfter(data, p, "\"provider\""),
    };
}

// ============================================================================
// output

const usage =
    \\agent-detection — infer harness, interface, and model of the current agent session
    \\
    \\usage: agent-detection [--json] [--trailer]
    \\
    \\  (default)    human-readable detection report
    \\  --json       machine-readable detection report
    \\  --trailer    print only the Co-authored-by trailer (for git commits)
    \\  --help       this help
    \\
    \\exit codes: 0 = identified, 2 = unable to identify (stop and inform the user)
    \\
;

fn fieldText(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, val: ?[]const u8) !void {
    try buf.appendSlice(a, try std.fmt.allocPrint(a, "{s}: {s}\n", .{ key, val orelse "unknown" }));
}

fn fieldJson(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, val: ?[]const u8, last: bool) !void {
    if (val) |v| {
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "  \"{s}\": \"{s}\"", .{ key, try jsonEscape(a, v) }));
    } else {
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "  \"{s}\": null", .{key}));
    }
    try buf.appendSlice(a, if (last) "\n" else ",\n");
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    var as_json = false;
    var trailer_only = false;
    var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return 1;
    defer args_it.deinit();
    _ = args_it.skip(); // argv0
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, arg, "--trailer")) {
            trailer_only = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeOut(io, usage);
            return 0;
        } else {
            writeErr(io, "unknown argument\n");
            writeOut(io, usage);
            return 2;
        }
    }

    var d = Detection{};

    // ladder step 1: environment variables -> harness
    const env = init.environ_map;
    const cline_markers = [_][]const u8{
        "CLINE_WRAPPER_PATH",      "CLINE_BUILD_ENV",            "CLINE_NO_INTERACTIVE",
        "CLINE_RUN_AS_HUB_DAEMON", "CLINE_CONNECTOR_CLI_LAUNCH",
    };
    for (cline_markers) |m| {
        if (env.get(m) != null) {
            d.harness_env = true;
            break;
        }
    }
    if (d.harness_env) d.harness = "Cline";
    if (d.harness == null) {
        if (env.get("PI_CODING_AGENT")) |v| {
            if (std.mem.eql(u8, v, "true")) {
                d.harness = "pi";
                d.harness_env = true;
            }
        }
    }

    const home = env.get("USERPROFILE") orelse (env.get("HOME") orelse "");
    const cwd_dir = std.Io.Dir.cwd();

    // cline: ladder steps 2-4
    if (d.harness != null and std.mem.eql(u8, d.harness.?, "Cline") and home.len > 0) {
        // step 2: live selection (never emit auth fields)
        const prov_path = try std.fmt.allocPrint(a, "{s}/.cline/data/settings/providers.json", .{home});
        if (cwd_dir.readFileAlloc(io, prov_path, a, @enumFromInt(1 << 20)) catch null) |pdata| {
            if (std.json.parseFromSlice(std.json.Value, a, pdata, .{}) catch null) |parsed| {
                if (parsed.value == .object) {
                    const root = parsed.value.object;
                    if (jstr(root, "lastUsedProvider")) |iface| {
                        d.interface_id = iface;
                        d.interface = interfaceForId(iface) orelse try titleCase(a, iface);
                        if (root.get("providers")) |pv| {
                            if (pv == .object) {
                                if (pv.object.get(iface)) |ev| {
                                    if (ev == .object) {
                                        const eo = ev.object;
                                        d.model_updated_at = jstr(eo, "updatedAt");
                                        if (eo.get("settings")) |sv| {
                                            if (sv == .object) {
                                                if (jstr(sv.object, "model")) |mid| {
                                                    d.model_id = mid;
                                                    const slash = std.mem.findScalar(u8, mid, '/');
                                                    const slug = if (slash) |i| mid[i + 1 ..] else mid;
                                                    const mi = try modelForSlug(a, slug);
                                                    d.model = mi.display;
                                                    d.open_weight = mi.open;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // step 3: own session (ancestry, then cwd fallback)
        const sessions_root = try std.fmt.allocPrint(a, "{s}/.cline/data/sessions", .{home});
        const found = try findOwnSession(a, io, loadSessions(a, io, sessions_root), ancestorPids(a, io));
        d.session_resolution = found.how;
        if (found.s) |s| {
            d.session_id = s.id;
            d.session_provider = s.provider;
            d.session_model = s.model;
            // step 4: generation truth
            if (s.messages_path) |mp| {
                const lm = lastModelInfo(a, io, mp);
                d.last_msg_model = lm.id;
                d.last_msg_provider = lm.provider;
            }
        }
    }

    // co-author trailer (commits.md format)
    if (d.harness != null and d.model != null) {
        const email = try trailerEmail(a, d.harness.?, d.model.?);
        d.trailer = try std.fmt.allocPrint(a, "Co-authored-by: {s} - {s} <{s}>", .{ d.harness.?, d.model.?, email });
    }

    if (trailer_only) {
        if (d.trailer) |t| {
            writeOut(io, t);
            writeOut(io, "\n");
            return 0;
        }
        writeErr(io, "unable to determine trailer (harness/model unidentified) — stop and inform the user\n");
        return 2;
    }

    var buf: std.ArrayList(u8) = .empty;
    if (as_json) {
        try buf.appendSlice(a, "{\n");
        try fieldJson(a, &buf, "harness", d.harness, false);
        try fieldJson(a, &buf, "harness_env", if (d.harness_env) "true" else "false", false);
        try fieldJson(a, &buf, "interface", d.interface, false);
        try fieldJson(a, &buf, "interface_id", d.interface_id, false);
        try fieldJson(a, &buf, "model", d.model, false);
        try fieldJson(a, &buf, "model_id", d.model_id, false);
        try fieldJson(a, &buf, "open_weight", d.open_weight, false);
        try fieldJson(a, &buf, "model_updated_at", d.model_updated_at, false);
        try fieldJson(a, &buf, "session_id", d.session_id, false);
        try fieldJson(a, &buf, "session_resolution", d.session_resolution, false);
        try fieldJson(a, &buf, "session_provider", d.session_provider, false);
        try fieldJson(a, &buf, "session_model", d.session_model, false);
        try fieldJson(a, &buf, "last_msg_provider", d.last_msg_provider, false);
        try fieldJson(a, &buf, "last_msg_model", d.last_msg_model, false);
        try fieldJson(a, &buf, "trailer", d.trailer, true);
        try buf.appendSlice(a, "}\n");
    } else {
        try fieldText(a, &buf, "harness", d.harness);
        try fieldText(a, &buf, "harness_env", if (d.harness_env) "true" else "false");
        try fieldText(a, &buf, "interface", d.interface);
        try fieldText(a, &buf, "interface_id", d.interface_id);
        try fieldText(a, &buf, "model", d.model);
        try fieldText(a, &buf, "model_id", d.model_id);
        try fieldText(a, &buf, "open_weight", d.open_weight);
        try fieldText(a, &buf, "model_updated_at", d.model_updated_at);
        try fieldText(a, &buf, "session_id", d.session_id);
        try fieldText(a, &buf, "session_resolution", d.session_resolution);
        try fieldText(a, &buf, "session_provider", d.session_provider);
        try fieldText(a, &buf, "session_model", d.session_model);
        try fieldText(a, &buf, "last_msg_provider", d.last_msg_provider);
        try fieldText(a, &buf, "last_msg_model", d.last_msg_model);
        try fieldText(a, &buf, "trailer", d.trailer);
    }
    writeOut(io, buf.items);

    const ok = d.harness != null and d.model != null;
    if (!ok) writeErr(io, "unable to fully identify harness/model — stop and inform the user (per policy)\n");
    return if (ok) 0 else 2;
}
