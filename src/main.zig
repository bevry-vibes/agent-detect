// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detection — infer the current agent harness, provider, and
// model from the environment and harness data files, least-invasive first:
//   1. environment variables        (harness)
//   2. <harness data>/settings      (live provider + model)
//   3. own session via pid ancestry (session snapshot; parallel-safe)
//   4. session messages.json        (generation truth: last modelInfo)
// Never prints or persists secrets (auth tokens are never read into output).
//
// Written against zig 0.16 std (std.Io interface; main takes std.process.Init).

const std = @import("std");
const builtin = @import("builtin");

// macOS process walking (libproc + sysctl). zig 0.16 std has no darwin.zig,
// so the headers are pulled in directly. `<libproc.h>` is *not* imported
// via @cInclude because it transitively drags in `<mach/*.h>` opaque types
// that trip zig's generated static size asserts — those two functions are
// declared as externs below instead. Available on native macOS builds
// (which link libSystem by default). Cross-builds still fall through to
// the empty-ancestry path because the cross-built executable cannot call libc.
const os = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
});
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: c_uint) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: c_ulong, buffer: [*]u8, buffersize: c_int) c_int;

const Detection = struct {
    harness: ?[]const u8 = null, // display name, e.g. "Cline"
    harness_id: ?[]const u8 = null, // e.g. "cline"
    harness_source: []const u8 = "none", // "env" | "ancestor" | "none"
    harness_env: bool = false, // harness env vars present
    model_source: []const u8 = "none", // "providers.json" | "config.yaml" | "config.toml" | "config.json" | "bundle-default" | "env"
    provider_id: ?[]const u8 = null, // e.g. "cline-pass"
    provider: ?[]const u8 = null, // e.g. "Cline Pass"
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

const ProviderRule = struct { id: []const u8, display: []const u8 };
const provider_rules = [_]ProviderRule{
    .{ .id = "cline-pass", .display = "Cline Pass" },
    .{ .id = "cline", .display = "Cline" },
    .{ .id = "minimax", .display = "MiniMax" },
};

const HarnessRule = struct {
    id: []const u8,
    display: []const u8,
    env_markers: []const []const u8,
    proc_names: []const []const u8, // lowercase exe names matched against process ancestry
};
const cline_env = [_][]const u8{ "CLINE_WRAPPER_PATH", "CLINE_BUILD_ENV", "CLINE_NO_INTERACTIVE", "CLINE_RUN_AS_HUB_DAEMON", "CLINE_CONNECTOR_CLI_LAUNCH" };
const goose_env = [_][]const u8{ "GOOSE_WORKING_DIR", "GOOSE_PROVIDER", "GOOSE_MODEL", "GOOSE_TERMINAL", "GOOSE_MODE" };
const kimi_env = [_][]const u8{ "KIMI_CODE_HOME", "KIMI_API_KEY", "KIMI_BASE_URL" };
const mmx_env = [_][]const u8{ "MMX_CONFIG_DIR", "MINIMAX_API_KEY" };
const pi_env = [_][]const u8{"PI_CODING_AGENT"};
const cline_procs = [_][]const u8{ "cline.exe", "cline" };
const goose_procs = [_][]const u8{ "goose.exe", "goose", "goosed.exe", "goosed" };
const kimi_procs = [_][]const u8{ "kimi.exe", "kimi", "kimi-code.exe", "kimi-code" };
const harness_rules = [_]HarnessRule{
    .{ .id = "cline", .display = "Cline", .env_markers = &cline_env, .proc_names = &cline_procs },
    .{ .id = "goose", .display = "Goose", .env_markers = &goose_env, .proc_names = &goose_procs },
    .{ .id = "kimi", .display = "Kimi Code CLI", .env_markers = &kimi_env, .proc_names = &kimi_procs },
    .{ .id = "mmx", .display = "MiniMax Code", .env_markers = &mmx_env, .proc_names = &.{} }, // node-based; exe name is generic
    .{ .id = "pi", .display = "pi", .env_markers = &pi_env, .proc_names = &.{} },
};

/// normalize model id into display name + open-weight flag
fn applyModel(a: std.mem.Allocator, d: *Detection, model_id: []const u8) !void {
    d.model_id = model_id;
    const lower = try std.ascii.allocLowerString(a, model_id);
    const slash = std.mem.findScalarLast(u8, lower, '/');
    const slug = if (slash) |i| lower[i + 1 ..] else lower;
    const mi = try modelForSlug(a, slug);
    d.model = mi.display;
    d.open_weight = mi.open;
}

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

fn providerForId(id: []const u8) ?[]const u8 {
    for (provider_rules) |r| {
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

const Ancestry = struct { pids: []const u32 = &.{}, names: []const []const u8 = &.{} };

fn ancestorInfo(a: std.mem.Allocator, io: std.Io) Ancestry {
    if (builtin.os.tag == .windows) return ancestorsWindows(a) catch .{};
    if (builtin.os.tag == .linux) return ancestorsLinux(a, io) catch .{};
    if (builtin.os.tag == .macos) return ancestorsMacos(a) catch .{};
    return .{};
}

/// utf16 exe name -> lowercase ascii (lossy for non-ascii, which is fine for matching)
fn exeName16(a: std.mem.Allocator, buf: *const [260]u16) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (buf) |c| {
        if (c == 0) break;
        try list.append(a, if (c < 128) std.ascii.toLower(@as(u8, @intCast(c))) else '?');
    }
    return list.toOwnedSlice(a);
}

const ProcPair = struct { pid: u32, ppid: u32, name: []const u8 };

fn ancestorsWindows(a: std.mem.Allocator) !Ancestry {
    if (builtin.os.tag != .windows) return .{};
    const w = std.os.windows;
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    const invalid: w.HANDLE = @ptrFromInt(std.math.maxInt(usize));
    if (snap == invalid) return error.SnapshotFailed;
    defer w.CloseHandle(snap);
    var procs: std.ArrayList(ProcPair) = .empty;
    var entry: PROCESSENTRY32W = .{};
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) != 0) {
        while (true) {
            try procs.append(a, .{
                .pid = entry.th32ProcessID,
                .ppid = entry.th32ParentProcessID,
                .name = try exeName16(a, &entry.szExeFile),
            });
            if (Process32NextW(snap, &entry) == 0) break;
        }
    }
    var pids: std.ArrayList(u32) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var pid: u32 = w.GetCurrentProcessId();
    while (pid != 0) {
        try pids.append(a, pid);
        var name: []const u8 = "";
        var next: u32 = 0;
        for (procs.items) |p| {
            if (p.pid == pid) {
                next = p.ppid;
                name = p.name;
                break;
            }
        }
        try names.append(a, name);
        pid = next;
    }
    return .{ .pids = try pids.toOwnedSlice(a), .names = try names.toOwnedSlice(a) };
}

fn ancestorsLinux(a: std.mem.Allocator, io: std.Io) !Ancestry {
    if (builtin.os.tag != .linux) return .{};
    const cwd_dir = std.Io.Dir.cwd();
    var pids: std.ArrayList(u32) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var pid: u32 = @intCast(std.os.linux.getpid());
    while (pid > 1) {
        try pids.append(a, pid);
        const comm_path = try std.fmt.allocPrint(a, "/proc/{d}/comm", .{pid});
        const comm = cwd_dir.readFileAlloc(io, comm_path, a, @enumFromInt(4096)) catch "";
        try names.append(a, try std.ascii.allocLowerString(a, std.mem.trim(u8, comm, " \r\n")));
        const path = try std.fmt.allocPrint(a, "/proc/{d}/stat", .{pid});
        const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch break;
        const close = std.mem.findScalarLast(u8, data, ')') orelse break;
        var tok = std.mem.tokenizeScalar(u8, data[close + 2 ..], ' ');
        _ = tok.next(); // state
        const ppid = tok.next() orelse break;
        pid = std.fmt.parseInt(u32, ppid, 10) catch break;
    }
    return .{ .pids = try pids.toOwnedSlice(a), .names = try names.toOwnedSlice(a) };
}

/// Walk process ancestors on macOS. For each pid, reads the executable
/// basename via `proc_pidpath`, and uses `proc_pidinfo` with
/// `PROC_PIDT_SHORTBSDINFO` (a small fixed-layout struct that begins
/// with `pid_t pbsi_pid, pbsi_ppid`) to fetch the immediate parent pid.
/// Stops when the parent is init (pid 1), any syscall fails, or the
/// chain exceeds 32 hops. Cross-builds still fall through because they
/// cannot call libc at all.
const PROC_PIDT_SHORTBSDINFO: c_int = 2;

fn ancestorsMacos(a: std.mem.Allocator) !Ancestry {
    if (builtin.os.tag != .macos) return .{};
    var pids: std.ArrayList(u32) = .empty;
    var names: std.ArrayList([]const u8) = .empty;

    var pid: i32 = os.getpid();
    var safety: u8 = 0;
    while (pid > 1 and safety < 32) : (safety += 1) {
        var info: [4096]u8 = undefined;
        const filled_raw = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, @intCast(info.len));
        if (filled_raw < 32) break;

        // `pbsi_pid` / `pbsi_ppid` are read at hard-coded offsets rather than
        // through the full struct — `PROC_PIDT_SHORTBSDINFO` on macOS 26.x arm64
        // returns the larger `proc_taskallinfo` (~232 bytes) instead of the
        // legacy 24-byte `proc_bsdshortinfo`. The leading 12 bytes are filled
        // with header fields (signature / opaque token), after which `pid_t`
        // fields appear in the documented order: pid, ppid, pgid, status.
        const own_pid: u32 = std.mem.readInt(u32, info[12..16], .little);
        const ppid: u32 = std.mem.readInt(u32, info[16..20], .little);

        var path_buf: [4096]u8 = undefined;
        const path_len_raw = proc_pidpath(pid, &path_buf, @intCast(path_buf.len));
        var basename: []const u8 = "";
        if (path_len_raw > 0) {
            const path_len: usize = @intCast(path_len_raw);
            const full = path_buf[0..path_len];
            basename = std.fs.path.basename(full);
        }

        // Node.js-launched harnesses (kimi-code, etc.) have executable = `node`
        // but their argv carries the harness marker (argv[1] = `kimi-code` when
        // launched with `exec -a "kimi-code" node …`). Probe `KERN_PROCARGS` to
        // detect the harness and override the ancestor name.
        if (std.mem.eql(u8, basename, "node")) {
            if (try kimiArgvOverride(a, pid)) basename = "kimi-code";
        }

        // sanity: the kernel should echo back our pid at the expected offset.
        // if it doesn't, the layout shifted; bail out instead of walking bogus ppids.
        if (own_pid != @as(u32, @intCast(pid))) break;
        if (ppid == own_pid or ppid == 0) break;
        try pids.append(a, own_pid);
        try names.append(a, try std.ascii.allocLowerString(a, basename));

        if (ppid <= 1) break;
        pid = @intCast(ppid);
    }
    return .{ .pids = try pids.toOwnedSlice(a), .names = try names.toOwnedSlice(a) };
}

/// If the given pid's argv (read via `KERN_PROCARGS`) contains the literal
/// `kimi-code` substring, return true so the caller can override the
/// ancestor name. Returns false on any sysctl failure, empty input, or
/// no match.
fn kimiArgvOverride(a: std.mem.Allocator, pid: i32) !bool {
    // CTL_KERN = 1, KERN_PROCARGS = 38 on darwin
    var mib: [3]c_int = .{ 1, 38, pid };
    var size: usize = 0;
    if (os.sysctl(&mib, mib.len, null, &size, null, 0) != 0) return false;
    if (size == 0) return false;
    var buf = try a.alloc(u8, size);
    defer a.free(buf);
    var read_size: usize = size;
    if (os.sysctl(&mib, mib.len, buf.ptr, &read_size, null, 0) != 0) return false;
    return std.mem.indexOf(u8, buf[0..read_size], "kimi-code") != null;
}

/// `extern "c"` decl for `proc_pidpath` (libproc). Declared at file scope
/// for `ancestorsMacos` above; pulled out as a comment so future readers
/// don't reach for `libproc.h` and drag in `<mach/*.h>` opaque types that
/// trip zig's generated static asserts.

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
// per-harness extraction (ladder steps 2-4)

fn detectCline(a: std.mem.Allocator, io: std.Io, anc: Ancestry, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    // step 2: live selection (never emit auth fields)
    const prov_path = try std.fmt.allocPrint(a, "{s}/.cline/data/settings/providers.json", .{home});
    if (cwd_dir.readFileAlloc(io, prov_path, a, @enumFromInt(1 << 20)) catch null) |pdata| {
        if (std.json.parseFromSlice(std.json.Value, a, pdata, .{}) catch null) |parsed| {
            if (parsed.value == .object) {
                const root = parsed.value.object;
                if (jstr(root, "lastUsedProvider")) |prov| {
                    d.provider_id = prov;
                    d.provider = providerForId(prov) orelse try titleCase(a, prov);
                    if (root.get("providers")) |pv| {
                        if (pv == .object) {
                            if (pv.object.get(prov)) |ev| {
                                if (ev == .object) {
                                    const eo = ev.object;
                                    d.model_updated_at = jstr(eo, "updatedAt");
                                    if (eo.get("settings")) |sv| {
                                        if (sv == .object) {
                                            if (jstr(sv.object, "model")) |mid| {
                                                try applyModel(a, d, mid);
                                                d.model_source = "providers.json";
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
    const found = try findOwnSession(a, io, loadSessions(a, io, sessions_root), anc.pids);
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

fn detectGoose(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, appdata: []const u8, home: []const u8, d: *Detection) !void {
    const cwd_dir = std.Io.Dir.cwd();
    // goose: env vars override the config file
    var provider: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var src: []const u8 = "none";
    if (env.get("GOOSE_PROVIDER")) |v| {
        provider = v;
        src = "env";
    }
    if (env.get("GOOSE_MODEL")) |v| {
        model = v;
        src = "env";
    }
    const path = if (builtin.os.tag == .windows and appdata.len > 0)
        try std.fmt.allocPrint(a, "{s}/Block/goose/config/config.yaml", .{appdata})
    else if (home.len > 0)
        try std.fmt.allocPrint(a, "{s}/.config/goose/config.yaml", .{home})
    else
        return;
    if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |ydata| {
        // pass 1: active_provider (top-level key)
        var active: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, ydata, '\n');
        while (lines.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, t, "active_provider:")) {
                const v = std.mem.trim(u8, t["active_provider:".len..], " ");
                if (v.len > 0) active = v;
            }
        }
        // pass 2: providers.<active>.model (indent-tracked)
        if (active) |act| {
            var in_providers = false;
            var in_active = false;
            var lines2 = std.mem.splitScalar(u8, ydata, '\n');
            while (lines2.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                const t = std.mem.trim(u8, line, " \t");
                if (t.len == 0 or t[0] == '#') continue;
                const indent = line.len - std.mem.trimStart(u8, line, " ").len;
                if (indent == 0) {
                    in_providers = std.mem.startsWith(u8, t, "providers:");
                    in_active = false;
                    continue;
                }
                if (!in_providers) continue;
                if (indent == 2) {
                    const name = std.mem.trimEnd(u8, t, ":");
                    in_active = std.mem.eql(u8, name, act);
                    continue;
                }
                if (in_active and indent >= 4 and std.mem.startsWith(u8, t, "model:")) {
                    if (model == null) {
                        const v = std.mem.trim(u8, t["model:".len..], " ");
                        if (v.len > 0) {
                            model = v;
                            src = "config.yaml";
                        }
                    }
                    break;
                }
            }
        }
        if (provider == null and active != null) {
            provider = active;
            if (std.mem.eql(u8, src, "none")) src = "config.yaml";
        }
    }
    if (provider) |p| {
        d.provider_id = p;
        d.provider = providerForId(p) orelse try titleCase(a, p);
    }
    if (model) |m| {
        try applyModel(a, d, m);
        d.model_source = src;
    }
}

fn detectKimi(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(a, "{s}/.kimi-code/config.toml", .{home});
    if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |data| {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, t, "default_model")) continue;
            const q1 = std.mem.findScalar(u8, t, '"') orelse continue;
            const q2 = std.mem.findScalarPos(u8, t, q1 + 1, '"') orelse continue;
            const dm = t[q1 + 1 .. q2]; // "<provider>/<model-id>"
            const slash = std.mem.findScalar(u8, dm, '/');
            const prov = if (slash) |i| dm[0..i] else dm;
            d.provider_id = prov;
            d.provider = providerForId(prov) orelse try titleCase(a, prov);
            try applyModel(a, d, if (slash) |i| dm[i + 1 ..] else dm);
            d.model_source = "config.toml";
            break;
        }
    }
}

fn detectMmx(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    d.provider_id = "minimax";
    d.provider = "MiniMax";
    var model: []const u8 = "MiniMax-M3"; // mmx-cli default when no model configured
    var src: []const u8 = "bundle-default";
    if (home.len > 0) {
        const cwd_dir = std.Io.Dir.cwd();
        const path = try std.fmt.allocPrint(a, "{s}/.mmx/config.json", .{home});
        if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |cdata| {
            if (std.json.parseFromSlice(std.json.Value, a, cdata, .{}) catch null) |parsed| {
                if (parsed.value == .object) {
                    const o = parsed.value.object;
                    if (jstr(o, "defaultTextModel") orelse jstr(o, "model")) |m| {
                        model = m;
                        src = "config.json";
                    }
                }
            }
        }
    }
    try applyModel(a, d, model);
    d.model_source = src;
}

// ============================================================================
// output

const usage =
    \\agent-detection — infer harness, provider, and model of the current agent session
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

    // ladder step 1: harness — env markers first, then ancestor process names
    const env = init.environ_map;
    const anc = ancestorInfo(a, io);
    var rule: ?HarnessRule = null;
    var hsrc: []const u8 = "none";
    scan: for (harness_rules) |r| {
        for (r.env_markers) |m| {
            if (env.get(m) != null) {
                rule = r;
                hsrc = "env";
                break :scan;
            }
        }
    }
    if (rule != null and std.mem.eql(u8, rule.?.id, "pi")) {
        // pi marker requires an explicit true value
        const v = env.get("PI_CODING_AGENT") orelse "";
        if (!std.mem.eql(u8, v, "true")) {
            rule = null;
            hsrc = "none";
        }
    }
    if (rule == null) {
        for (harness_rules) |r| {
            for (r.proc_names) |pn| {
                for (anc.names) |n| {
                    if (std.mem.eql(u8, n, pn)) {
                        rule = r;
                        hsrc = "ancestor";
                    }
                }
            }
        }
    }

    if (rule) |r| {
        d.harness = r.display;
        d.harness_id = r.id;
        d.harness_env = std.mem.eql(u8, hsrc, "env");
        d.harness_source = hsrc;
        const home = env.get("USERPROFILE") orelse (env.get("HOME") orelse "");
        if (std.mem.eql(u8, r.id, "cline")) {
            try detectCline(a, io, anc, home, &d);
        } else if (std.mem.eql(u8, r.id, "goose")) {
            try detectGoose(a, io, env, env.get("APPDATA") orelse "", home, &d);
        } else if (std.mem.eql(u8, r.id, "kimi")) {
            try detectKimi(a, io, home, &d);
        } else if (std.mem.eql(u8, r.id, "mmx")) {
            try detectMmx(a, io, home, &d);
        }
        // pi: model detection not yet implemented (sessions model_change metadata)
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
        try fieldJson(a, &buf, "harness_id", d.harness_id, false);
        try fieldJson(a, &buf, "harness_source", d.harness_source, false);
        try fieldJson(a, &buf, "harness_env", if (d.harness_env) "true" else "false", false);
        try fieldJson(a, &buf, "provider", d.provider, false);
        try fieldJson(a, &buf, "provider_id", d.provider_id, false);
        try fieldJson(a, &buf, "model", d.model, false);
        try fieldJson(a, &buf, "model_id", d.model_id, false);
        try fieldJson(a, &buf, "model_source", d.model_source, false);
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
        try fieldText(a, &buf, "harness_id", d.harness_id);
        try fieldText(a, &buf, "harness_source", d.harness_source);
        try fieldText(a, &buf, "harness_env", if (d.harness_env) "true" else "false");
        try fieldText(a, &buf, "provider", d.provider);
        try fieldText(a, &buf, "provider_id", d.provider_id);
        try fieldText(a, &buf, "model", d.model);
        try fieldText(a, &buf, "model_id", d.model_id);
        try fieldText(a, &buf, "model_source", d.model_source);
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
