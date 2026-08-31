// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detect core — the detection ladder and policy. In the
// least-invasive order, detection reads:
//   1. environment variables        (harness)
//   2. <harness data>/settings      (live provider + model)
//   3. own session via pid ancestry (session snapshot; parallel-safe)
//   4. session messages.json        (generation truth: last modelInfo)
// Never prints or persists secrets (auth tokens are never read into output).
// Depends on lib/rules.zig (data + pure lookups); never imports dev/dev.zig
// — only dev imports core.
//
// Written against zig 0.16 std (std.Io interface; main takes std.process.Init).

const std = @import("std");
const builtin = @import("builtin");
const rules = @import("rules.zig");

const HarnessRule = rules.HarnessRule;
const ProviderRule = rules.ProviderRule;
const ModelRule = rules.ModelRule;
const rulesForHarnesses = rules.rulesForHarnesses;
const rulesForProviders = rules.rulesForProviders;
const rulesForModels = rules.rulesForModels;
const titleCase = rules.titleCase;
const modelForName = rules.modelForName;
const modelRuleForName = rules.modelRuleForName;
const providerForName = rules.providerForName;
const providerMetaForName = rules.providerMetaForName;
const providerForBaseUrl = rules.providerForBaseUrl;
const slugId = rules.slugId;
const canonicalIdFor = rules.canonicalIdFor;
const harnessRuleForName = rules.harnessRuleForName;
const envValueAllowed = rules.envValueAllowed;
const license_none = rules.license_none;
const license_noassertion = rules.license_noassertion;

// Exit status registry — canonical numbers, one per distinct kind of
// outcome. `1` is NOT a fallback for everything; it is reserved for
// genuinely unexpected/unclassified failures (uncaught zig errors,
// bugs). The full table + per-code examples live in DESIGN.md
// "exit status registry".
pub const EXIT_OK: u8 = 0;
pub const EXIT_UNRECOGNISED_ERROR: u8 = 1;
pub const EXIT_UNRECOGNISED_ARG: u8 = 2;
pub const EXIT_CONFLICTING_ARG: u8 = 3;
pub const EXIT_MISSING_ARG: u8 = 4;
pub const EXIT_ENV_INCOMPATIBLE: u8 = 5;
pub const EXIT_ENV_INCOMPLETE: u8 = 6;
pub const EXIT_MISSING_SPECIFIED_AGENT: u8 = 7;
pub const EXIT_UNABLE_TO_DETECT: u8 = 8;
pub const EXIT_AGENT_DATA_INCOMPLETE: u8 = 9;
pub const EXIT_REQUIREMENT_FAILED: u8 = 10;
pub const EXIT_OUT_OF_MEMORY: u8 = 11;
pub const EXIT_INDEX_STORE: u8 = 12;
pub const EXIT_IO: u8 = 13;

// Error-message strings = the exit-status registry names, verbatim.
// STDERR carries the full registry-name message; STDOUT carries the
// concise verdict (determination / data). No repo clause, no prose —
// the repo-update rules live in README.md per use case.
pub const MSG_UNRECOGNISED_ARG = "unrecognised argument: '";
pub const MSG_CONFLICTING_ARG = "conflicting argument\n";
pub const MSG_MISSING_ARG_COMBO = "missing required arguments: --harness= --provider= --model=\n";
pub const MSG_MISSING_ARG_TRAILER_SUBTYPE = "missing required arguments: trailer subtype (co-author | assisted-by)\n";
pub const MSG_MISSING_ARG = "missing required arguments\n";
pub const MSG_ENV_INCOMPATIBLE = "incompatible environment refusing run\n";
pub const MSG_ENV_INCOMPLETE = "incomplete environment preventing run\n";
pub const MSG_AGENT_DATA_INCOMPLETE = "agent (harness, provider, model) data incomplete to make a determination\n";
pub const MSG_REQUIREMENT_FAILED = "agent (harness, provider, model) data complete and requirement failed\n";
pub const MSG_OUT_OF_MEMORY = "out of memory\n";
pub const MSG_INDEX_STORE = "index store error\n";
pub const MSG_IO = "filesystem I/O error\n";

/// exit-7 stderr message for recipe mode, reporting which of the three
/// dims resolved to a known rule (as its strict alphanumeric slug id)
/// and which did not (`null`) — so the user sees at a glance which dim
/// is the unknown one:
/// `missing specified agent (harness = "kilo", provider = null, model = "deepseekv4pro")`
pub fn writeMissingSpecifiedAgent(io: std.Io, h: ?[]const u8, p: ?[]const u8, m: ?[]const u8) void {
    writeErr(io, "missing specified agent (");
    writeAgentDims(io, h, p, m);
    writeErr(io, ")\n");
}

/// exit-8 stderr message for live detection, reporting which of the
/// three dims resolved (as its strict alphanumeric id) and which did
/// not (`null`):
/// `unable to detect unspecified agent (harness = "kilo", provider = null, model = null)`
pub fn writeUnableToDetect(io: std.Io, h: ?[]const u8, p: ?[]const u8, m: ?[]const u8) void {
    writeErr(io, "unable to detect unspecified agent (");
    writeAgentDims(io, h, p, m);
    writeErr(io, ")\n");
}

/// the shared `harness = "<id>", provider = "<id>", model = "<id>"`
/// dims block for the resolved-dims error messages.
fn writeAgentDims(io: std.Io, h: ?[]const u8, p: ?[]const u8, m: ?[]const u8) void {
    writeErr(io, "harness = ");
    writeErrIdOrNull(io, h);
    writeErr(io, ", provider = ");
    writeErrIdOrNull(io, p);
    writeErr(io, ", model = ");
    writeErrIdOrNull(io, m);
}

/// write `"<id>"` when present, bare `null` when absent.
fn writeErrIdOrNull(io: std.Io, id: ?[]const u8) void {
    if (id) |s| {
        writeErr(io, "\"");
        writeErr(io, s);
        writeErr(io, "\"");
    } else {
        writeErr(io, "null");
    }
}

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

pub const Detection = struct {
    // canonical — grouped by entity, in emission order
    // harness group
    harness_label: ?[]const u8 = null, // human-readable display label, e.g. "Kimi Code" (note some have no title-cased form, such as omp, as such retain omp for omp)
    harness_short_title: ?[]const u8 = null, // optional short brand form, e.g. "Kimi" for "Kimi Code"; null when no established short form
    harness_name: ?[]const u8 = null, // canonical name (whatever casing the service uses to refer to it), e.g. "kimi-code"
    harness_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `harness_name` (no separators), e.g. "kimi-code" -> "kimicode" — the only id we constrain; `harness_name` carries whatever the service uses
    harness_version: ?[]const u8 = null, // optional release version, e.g. "1.2.3"
    harness_license: ?[]const u8 = null, // SPDX id, e.g. "Apache-2.0"
    // provider group
    provider_label: ?[]const u8 = null, // e.g. "Cline Pass"
    provider_name: ?[]const u8 = null, // canonical name (whatever casing the service uses to refer to it), e.g. "cline-pass"
    provider_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `provider_name` (no separators), e.g. "cline-pass" -> "clinepass" — the only id we constrain; `provider_name` carries whatever the service uses
    provider_closed_training: ?[]const u8 = null, // "enforced" | "opt-in" | "opt-out" | "never" | null
    provider_open_training: ?[]const u8 = null, // same enum
    // model group
    model_label: ?[]const u8 = null, // e.g. "Kimi K3"
    model_short_title: ?[]const u8 = null, // optional short brand form, e.g. "M3" for "MiniMax M3"; null when no established short form
    model_name: ?[]const u8 = null, // canonical bare slug (whatever casing the service uses canonically), e.g. "kimi-k3"
    model_id: ?[]const u8 = null, // strictly lowercase-alphanumeric form of `model_name` (no separators), e.g. "kimi-k3" -> "kimik3"
    model_reciprocity: ?[]const u8 = null, // "open-source" | "open-weight" | "closed" | null
    model_license: ?[]const u8 = null, // SPDX license id of the model weights (same semantics as harness_license); null when unverified
    // agent (composed from harness + provider + model)
    agent_id: ?[]const u8 = null, // "<harness_id>-<provider_id>-<model_id>" — the user-visible identity of the agent
    // policy / output
    reciprocal: ?bool = null, // computed from harness_license + model_reciprocity + provider_closed_training
    trailer: ?[]const u8 = null,
    // raw — typed observations; buildRaw converts these to a shapeless
    // JSON object whose top-level keys identify the source of evidence
    raw: RawObservation = .{},
    // the dims this run's detection ladder (or recipe) *could* resolve;
    // a stale per-capture record of what landed in the raw block's
    // `detectable` key. `detected` is derived post-hoc from which
    // canonical dims actually populated the canonical fields.
    detectable: []const []const u8 = &.{},
};

/// one env-var observation. `name` is always emitted (env-var names
/// are non-secret). `value` is the env-var's content if `present` and
/// the name is on the `env_value_allowlist`, otherwise the empty string
/// (secrets hygiene — `value=""` + `present=false` means the var was
/// declared by the rule but unset in the environment; `value=""` +
/// `present=true` means the var was present but is on the
/// not-allowed list and got redacted). Every env-marker declared by
/// the matched harness rule gets one entry here, regardless of whether
/// the var was in the runtime environment — a maintainer reading the
/// fixture can see what the rule actually checked.
pub const EnvVarObservation = struct {
    name: []const u8,
    value: []const u8,
    present: bool,
};

/// one process-tree observation: pid + executable basename. Subobjects
/// (not `[pid, name]` tuples) so the convention is explicit in the
/// JSON shape — a reader doesn't need to remember which index is which.
pub const Ancestor = struct {
    pid: u32,
    name: []const u8,
};

/// process-tree observations: the chain of processes at detection
/// time, ordered most-immediate first (index 0 = the running
/// `agent-detect`, index 1 = its parent, etc.). Full argv is
/// deliberately NOT captured — see DESIGN.md for the leak vectors
/// (tokens, paths, positional-secret parsing). Inlined as a direct
/// `[]const Ancestor` field of `RawObservation`.
///
/// one field read from a file: a dotted-path pointer (e.g.
/// "providers.cline-pass.settings.model") + the value observed.
pub const FieldObservation = struct {
    dotted_path: []const u8,
    value: []const u8,
};

/// one file read: the file path + the fields that informed canonical.
/// Used for both provider config files (providers.json, config.toml,
/// config.yaml, config.json) and Cline session files (session.json,
/// messages.json). The path is the raw block's top-level key in the
/// JSON output.
pub const FileObservation = struct {
    path: []const u8,
    fields: []const FieldObservation = &.{},
};

/// One evidence claim: "dim X was resolved from source Y, which is
/// present in raw, and whose value was Z". Decision #11 — every
/// detected dim in an observed fixture must carry a claim so code can
/// mechanically verify the attribution chain (source present + value
/// matches the canonical dim). `source` is one of "env" | "config" |
/// "session" | "lineage":
///   - "env":     `name` is the env-var name (must appear in raw.env)
///   - "config"/"session": `name` is the file path (a top-level raw
///     key after redaction) and `field` the dotted path within it
///   - "lineage": `name` is a process basename (must appear in
///     raw.process_lineage)
/// `value` is the value the detector read (or, for lineage harness
/// claims, the matched proc name). Semantic deducibility is human
/// review; this struct only pins the attribution chain.
pub const EvidenceClaim = struct {
    dim: []const u8, // "harness" | "provider" | "model"
    source: []const u8, // "env" | "config" | "session" | "lineage"
    name: []const u8, // env var / file path / proc name
    field: ?[]const u8 = null, // dotted path for config/session claims
    value: ?[]const u8 = null, // the value read (null = no value seen)
};

/// All unprocessed observations in a typed shape that maps cleanly to
/// the shapeless JSON output emitted by `buildRaw`. Top-level groups:
/// - `env_vars` — env-var observations (one per matched marker)
/// - `process_lineage` — process tree (most-immediate first)
/// - `config_files` — provider config file reads (one per file)
/// - `session_files` — Cline session file reads (one per file)
/// - `harness_urls` / `provider_urls` / `model_urls` — reference URLs
///   that informed the corresponding canonical deductions
pub const RawObservation = struct {
    env_vars: []const EnvVarObservation = &.{},
    process_lineage: []const Ancestor = &.{},
    config_files: []const FileObservation = &.{},
    session_files: []const FileObservation = &.{},
    harness_urls: []const []const u8 = &.{},
    provider_urls: []const []const u8 = &.{},
    model_urls: []const []const u8 = &.{},
    /// decision #11 evidence claims — per detected dim, what source
    /// was read and with what value. Empty for `from-identity` (declared,
    /// not observed) fixtures.
    evidence: []const EvidenceClaim = &.{},
};

/// append one evidence claim to `d.raw.evidence`. The old slice is
/// leaked (arena-backed) — fine for the short-lived Detection.
fn addEvidenceClaim(a: std.mem.Allocator, d: *Detection, claim: EvidenceClaim) !void {
    const new_len = d.raw.evidence.len + 1;
    const new_slice = try a.alloc(EvidenceClaim, new_len);
    @memcpy(new_slice[0..d.raw.evidence.len], d.raw.evidence);
    new_slice[d.raw.evidence.len] = claim;
    d.raw.evidence = new_slice;
}

/// apply a model slug to the detection. `slug` is the bare model id (e.g.
/// "kimi-k3"); it becomes `d.model_name` unchanged. `raw_input` is the
/// original string from the config file (e.g. "cline-pass/kimi-k3" or
/// "minimax/kimi-k3") and is preserved in the corresponding config-file
/// FileObservation under `d.raw.config_files` for the audit trail. The
/// provider prefix on the config value stays out of the canonical model
/// identity.
pub fn applyModel(a: std.mem.Allocator, d: *Detection, name: []const u8, raw_input: []const u8) !void {
    const lower = try std.ascii.allocLowerString(a, name);
    const canonical_name = if (std.mem.findScalar(u8, lower, '/')) |i| lower[i + 1 ..] else lower;
    defer a.free(lower);
    // fold provider-served id spellings (e.g. chutes' TEE-stamped
    // "Qwen3.8-27B-TEE") through the rule's variation aliases before
    // the exact-name lookup — never-guess: an id no variation names
    // keeps the raw passthrough + family/titleCase fallback below.
    const folded_name = canonicalIdFor(a, ModelRule, &rulesForModels, canonical_name);
    const lookup_name = folded_name orelse canonical_name;
    d.model_name = folded_name orelse name;
    const mi = try modelForName(a, lookup_name);
    // display name is emitted verbatim from the rules table — the
    // rules are the source of truth and maintainers edit them
    // directly when adding new harnesses/models.
    d.model_label = try a.dupe(u8, mi.label);
    // short_title is optional — null when the rule didn't declare one.
    // Consumers should fall back to `model_label` (or `model_name`) when this
    // is null.
    if (mi.short_title) |st| d.model_short_title = try a.dupe(u8, st);
    d.model_id = try slugId(a, lookup_name);
    d.model_reciprocity = mi.reciprocity;
    d.model_license = mi.license;
    if (mi.sources.len > 0) d.raw.model_urls = mi.sources;
    _ = raw_input; // caller is responsible for recording it in a config_file observation
    // recompute the agent id now that model_id is fixtures —
    // this depends on harness_id and provider_id
    // being set first, which the calling detector is responsible for.
    try setAgentId(a, d);
}

pub fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

pub fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

/// apply provider rule metadata (training policies + their cross-reference
/// sources) to `d`. No-op if the provider id is not in the table; this is
/// the single place the four detectors should call to populate `provider_*`
/// and the matching `raw.provider_urls` array. Also sets
/// `provider_id` (the strict-slug form of the canonical name)
/// so detectors that use the three-line `provider_name + label + meta`
/// pattern still keep the slug id in lockstep with the name.
fn applyProviderMeta(a: std.mem.Allocator, d: *Detection, id: []const u8) !void {
    // Provider spelling folding, symmetric with applyModel's model
    // fold: an alternate key that resolves to a known provider rule
    // via its alias set (e.g. omp's `minimax-code`, reasonix's
    // `deepseek-flash` config entries) reports the canonical provider
    // the user is engaged with — never the harness's internal routing
    // name. Unknown ids keep today's raw passthrough (never-guess).
    const canonical = canonicalIdFor(a, ProviderRule, &rulesForProviders, id) orelse id;
    if (providerMetaForName(canonical)) |meta| {
        d.provider_name = meta.name;
        d.provider_label = meta.label;
        d.provider_id = try slugId(a, meta.name);
        d.provider_closed_training = meta.closed_training;
        d.provider_open_training = meta.open_training;
        d.raw.provider_urls = meta.sources;
    } else {
        d.provider_id = try slugId(a, canonical);
    }
}

/// set d.provider_label, d.provider_name, and d.provider_id together
/// from a single id. This is the helper detectors should call instead of
/// the old "label + applyProviderMeta" pair — it keeps the
/// slug id in lockstep with the name so consumers can
/// always trust the canonical trio.
fn setProvider(a: std.mem.Allocator, d: *Detection, id: []const u8) !void {
    const display = providerForName(id) orelse try titleCase(a, id);
    d.provider_name = try a.dupe(u8, id);
    d.provider_label = display;
    d.provider_id = try slugId(a, id);
    try applyProviderMeta(a, d, id);
}

/// compose the agent_id from the three sub-ids. Writes
/// `null` if any of the three is null (the agent is not fully
/// identified yet, and a partial id is more misleading than null).
fn setAgentId(a: std.mem.Allocator, d: *Detection) !void {
    const h = d.harness_id orelse return;
    const p = d.provider_id orelse return;
    const m = d.model_id orelse return;
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, h);
    try list.append(a, '-');
    try list.appendSlice(a, p);
    try list.append(a, '-');
    try list.appendSlice(a, m);
    d.agent_id = try list.toOwnedSlice(a);
}

pub fn jstr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn jint(obj: std.json.ObjectMap, key: []const u8) ?i64 {
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
// Windows process termination — used by the dev from-capture timeout
// watchdog (`fixtures __timeout`). PROCESS_TERMINATE = 0x0001.
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: c_int, dwProcessId: u32) callconv(.winapi) ?std.os.windows.HANDLE;
pub extern "kernel32" fn TerminateProcess(hProcess: std.os.windows.HANDLE, uExitCode: u32) callconv(.winapi) c_int;
pub extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) c_int;
pub extern "kernel32" fn GetProcessId(hProcess: std.os.windows.HANDLE) callconv(.winapi) u32;

pub const Ancestry = struct { pids: []const u32 = &.{}, names: []const []const u8 = &.{} };

pub fn ancestorInfo(a: std.mem.Allocator, io: std.Io) Ancestry {
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
    var config_fields = std.ArrayList(FieldObservation).empty;
    defer config_fields.deinit(a);
    if (cwd_dir.readFileAlloc(io, prov_path, a, @enumFromInt(1 << 20)) catch null) |pdata| {
        if (std.json.parseFromSlice(std.json.Value, a, pdata, .{}) catch null) |parsed| {
            if (parsed.value == .object) {
                const root = parsed.value.object;
                if (jstr(root, "lastUsedProvider")) |prov| {
                    d.provider_name = prov;
                    d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
                    try applyProviderMeta(a, d, prov);
                    try config_fields.append(a, .{ .dotted_path = "lastUsedProvider", .value = prov });
                    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = prov_path, .field = "lastUsedProvider", .value = prov });
                    if (root.get("providers")) |pv| {
                        if (pv == .object) {
                            if (pv.object.get(prov)) |ev| {
                                if (ev == .object) {
                                    const eo = ev.object;
                                    if (jstr(eo, "updatedAt")) |uat| {
                                        const dotted = try std.fmt.allocPrint(a, "providers.{s}.updatedAt", .{prov});
                                        try config_fields.append(a, .{ .dotted_path = dotted, .value = uat });
                                    }
                                    if (eo.get("settings")) |sv| {
                                        if (sv == .object) {
                                            if (jstr(sv.object, "model")) |mid| {
                                                // `mid` is "provider/model" in Cline's providers.json.
                                                // canonical model_name is the bare slug; raw_input
                                                // preserves the original "provider/model" string.
                                                const slash = std.mem.findScalar(u8, mid, '/');
                                                const slug = if (slash) |i| mid[i + 1 ..] else mid;
                                                try applyModel(a, d, slug, mid);
                                                const dotted = try std.fmt.allocPrint(a, "providers.{s}.settings.model", .{prov});
                                                try config_fields.append(a, .{ .dotted_path = dotted, .value = mid });
                                                try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = prov_path, .field = dotted, .value = mid });
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

    // assemble config_files FileObservation from accumulated fields
    if (config_fields.items.len > 0) {
        const fields_slice = try config_fields.toOwnedSlice(a);
        const obs_slice = try a.alloc(FileObservation, 1);
        obs_slice[0] = .{ .path = prov_path, .fields = fields_slice };
        d.raw.config_files = obs_slice;
    }

    // step 3: own session (ancestry, then cwd fallback)
    const sessions_root = try std.fmt.allocPrint(a, "{s}/.cline/data/sessions", .{home});
    const found = try findOwnSession(a, io, loadSessions(a, io, sessions_root), anc.pids);
    if (found.s) |s| {
        // build session_file FileObservation for the session.json —
        // emit every field the Session struct carries so the fixture
        // is informative enough to revise architecture decisions from.
        var sess_fields = std.ArrayList(FieldObservation).empty;
        defer sess_fields.deinit(a);
        try sess_fields.append(a, .{ .dotted_path = "id", .value = s.id });
        try sess_fields.append(a, .{ .dotted_path = "status", .value = s.status });
        try sess_fields.append(a, .{ .dotted_path = "started_at", .value = s.started_at });
        try sess_fields.append(a, .{ .dotted_path = "cwd", .value = s.cwd });
        if (s.pid) |p| try sess_fields.append(a, .{ .dotted_path = "pid", .value = try std.fmt.allocPrint(a, "{d}", .{p}) });
        if (s.provider) |p| {
            try sess_fields.append(a, .{ .dotted_path = "provider", .value = p });
        }
        if (s.model) |m| {
            try sess_fields.append(a, .{ .dotted_path = "model", .value = m });
        }
        if (s.messages_path) |mp| {
            try sess_fields.append(a, .{ .dotted_path = "messages_path", .value = mp });
        }
        const sess_fields_slice = try sess_fields.toOwnedSlice(a);
        const sess_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ sessions_root, s.id, s.id });
        const sess_obs = try a.alloc(FileObservation, 1);
        sess_obs[0] = .{ .path = sess_path, .fields = sess_fields_slice };

        // build session_file FileObservation for the messages.json (if present)
        var session_files_list = std.ArrayList(FileObservation).empty;
        try session_files_list.append(a, sess_obs[0]);
        if (s.messages_path) |mp| {
            const lm = lastModelInfo(a, io, mp);
            var msg_fields = std.ArrayList(FieldObservation).empty;
            defer msg_fields.deinit(a);
            if (lm.id) |id| {
                try msg_fields.append(a, .{ .dotted_path = "lastModelInfo.id", .value = id });
            }
            if (lm.provider) |p| {
                try msg_fields.append(a, .{ .dotted_path = "lastModelInfo.provider", .value = p });
            }
            const msg_fields_slice = try msg_fields.toOwnedSlice(a);
            try session_files_list.append(a, .{ .path = mp, .fields = msg_fields_slice });
        }
        d.raw.session_files = try session_files_list.toOwnedSlice(a);
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
    var active: ?[]const u8 = null;
    if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |ydata| {
        // pass 1: active_provider (top-level key)
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
        d.provider_name = p;
        d.provider_label = providerForName(p) orelse try titleCase(a, p);
        try applyProviderMeta(a, d, p);
    }
    if (model) |m| {
        // `m` is the bare model id from config.yaml / GOOSE_MODEL env.
        try applyModel(a, d, m, m);
    }
    // decision #11: claims against the source that actually resolved
    // each dim (env vars override the config file).
    if (provider) |p| {
        if (std.mem.eql(u8, src, "env")) {
            try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "GOOSE_PROVIDER", .value = p });
        } else if (active) |act| {
            try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "active_provider", .value = act });
        }
    }
    if (model) |m| {
        if (std.mem.eql(u8, src, "env")) {
            try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "GOOSE_MODEL", .value = m });
        } else if (active) |act| {
            const dotted = try std.fmt.allocPrint(a, "providers.{s}.model", .{act});
            try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = dotted, .value = m });
        }
    }
    // build config_files FileObservation if a file was read
    if (!std.mem.eql(u8, src, "none") and !std.mem.eql(u8, src, "env")) {
        var fields = std.ArrayList(FieldObservation).empty;
        defer fields.deinit(a);
        if (active) |act| {
            try fields.append(a, .{ .dotted_path = "active_provider", .value = act });
        }
        if (model) |m| {
            if (active) |act| {
                const dotted = try std.fmt.allocPrint(a, "providers.{s}.model", .{act});
                try fields.append(a, .{ .dotted_path = dotted, .value = m });
            }
        }
        if (fields.items.len > 0) {
            const fields_slice = try fields.toOwnedSlice(a);
            const obs = try a.alloc(FileObservation, 1);
            obs[0] = .{ .path = path, .fields = fields_slice };
            d.raw.config_files = obs;
        }
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
            const model_only = if (slash) |i| dm[i + 1 ..] else dm;
            d.provider_name = prov;
            d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
            try applyProviderMeta(a, d, prov);
            // canonical model_name is the bare slug; raw_input preserves the
            // original "provider/model" string from config.toml.
            try applyModel(a, d, model_only, dm);
            // build config_files FileObservation
            var fields = std.ArrayList(FieldObservation).empty;
            defer fields.deinit(a);
            try fields.append(a, .{ .dotted_path = "default_model", .value = dm });
            const fields_slice = try fields.toOwnedSlice(a);
            const obs = try a.alloc(FileObservation, 1);
            obs[0] = .{ .path = path, .fields = fields_slice };
            d.raw.config_files = obs;
            // decision #11: both dims were read from config.toml's
            // `default_model` = "<provider>/<model>" value.
            try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "default_model", .value = dm });
            try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "default_model", .value = dm });
            break;
        }
    }
}

fn detectMmx(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    var provider: []const u8 = "minimax"; // mmx-cli is MiniMax's CLI; intrinsic default
    var model: []const u8 = "minimax-m3"; // mmx-cli default when no model configured
    var raw_input: []const u8 = "minimax-m3"; // bundle default
    var config_fields: ?[]const FieldObservation = null;
    var config_path: ?[]const u8 = null;
    var config_value: ?[]const u8 = null;
    if (home.len > 0) {
        const cwd_dir = std.Io.Dir.cwd();
        const path = try std.fmt.allocPrint(a, "{s}/.mmx/config.json", .{home});
        if (cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch null) |cdata| {
            if (std.json.parseFromSlice(std.json.Value, a, cdata, .{}) catch null) |parsed| {
                if (parsed.value == .object) {
                    const o = parsed.value.object;
                    if (jstr(o, "defaultTextModel") orelse jstr(o, "model")) |m| {
                        raw_input = m;
                        config_value = m;
                        // mmx config stores the bare model id; when a
                        // "provider/model" prefix is present it is the
                        // upstream provider (a "provider/model" form
                        // exercises non-minimax combos). Bare ids keep the
                        // intrinsic default.
                        const lower = std.ascii.allocLowerString(a, m) catch m;
                        const slash = std.mem.findScalar(u8, lower, '/');
                        if (slash) |i| {
                            provider = lower[0..i];
                            model = lower[i + 1 ..];
                        } else {
                            model = lower;
                        }
                        // build config_files FileObservation
                        var fields = std.ArrayList(FieldObservation).empty;
                        defer fields.deinit(a);
                        const key = if (o.get("defaultTextModel") != null) "defaultTextModel" else "model";
                        try fields.append(a, .{ .dotted_path = key, .value = m });
                        config_fields = try fields.toOwnedSlice(a);
                        config_path = path;
                    }
                }
            }
        }
    }
    d.provider_name = provider;
    d.provider_label = providerForName(provider) orelse try titleCase(a, provider);
    try applyProviderMeta(a, d, provider);
    try applyModel(a, d, model, raw_input);
    if (config_value) |cv| {
        try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = config_path orelse "", .field = if (config_fields != null) config_fields.?[0].dotted_path else null, .value = cv });
        if (std.mem.indexOfScalar(u8, cv, '/') != null) {
            try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = config_path orelse "", .field = if (config_fields != null) config_fields.?[0].dotted_path else null, .value = cv });
        }
    }
    if (config_fields) |cf| {
        if (config_path) |cp| {
            const obs = try a.alloc(FileObservation, 1);
            obs[0] = .{ .path = cp, .fields = cf };
            d.raw.config_files = obs;
        }
    }
}

// ----------------------------------------------------------------------------
// partial-coverage harness detectors — the harnesses in the row of the
// DESIGN.md harness table that don't have a `detectHarness_<X>` function
// in this file are not real detectors; their entries below are
// deliberately minimal so a fixture can still be captured, but the model
// detection is a "best effort read of whatever the harness happens to
// keep on disk", and the capture relies on the daemon's runner (see
// CONTRIBUTING.md) to have written plausible config files into the
// harness's data dir when the binary isn't actually running inside that
// harness. Without that bootstrap, these detectors fall through to a
// documented default and the fixture says so in the raw block
// (provider-urls empty + model-urls from rulesForModels).
//
// Each function:
//   - reads the harness's fixtures config file (or env var),
//   - extracts provider + model from it (or the documented default),
//   - attaches a FileObservation under raw.config_files for the
//     config file it actually read,
//   - applies the model + provider metadata (which populates
//     canonical.harness_name / provider_name / model_name / etc).

fn detectQwen(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = env;
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(a, "{s}/.qwen/settings.json", .{home});
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);

    // parse top-level JSON: { "model": { "name": "MiniMax-M3" }, "security": { "auth": { "selectedType": "openai" } } }
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value.object;

    const model_obj = root.get("model") orelse return;
    const model_name = (model_obj.object.get("name") orelse return).string;
    if (model_name.len == 0) return;

    // qwen's auth.selectedType is the route key, not the underlying
    // provider. Look at modelProviders[<key>][*].baseUrl to find the
    // actual upstream service; the baseUrl host is mapped to the
    // provider id (`providerForBaseUrl`). Unknown hosts default
    // to "minimax" (the well-fixtures case: api.minimax.io).
    var provider_name: []const u8 = "minimax";
    var provider_base_url: []const u8 = "";
    if (root.get("modelProviders")) |mps| {
        if (mps.object.get("openai")) |entries| {
            for (entries.array.items) |entry| {
                if (entry.object.get("baseUrl")) |bu| {
                    provider_base_url = bu.string;
                    provider_name = providerForBaseUrl(bu.string);
                    break;
                }
            }
        }
    }

    d.provider_name = provider_name;
    d.provider_label = providerForName(provider_name) orelse try titleCase(a, provider_name);
    try applyProviderMeta(a, d, provider_name);
    try applyModel(a, d, model_name, model_name);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "model.name", .value = model_name });
    if (provider_base_url.len > 0) {
        try fields.append(a, .{ .dotted_path = "modelProviders.openai[].baseUrl", .value = provider_base_url });
    }
    if (root.get("security")) |sec| {
        if (sec.object.get("auth")) |auth| {
            if (auth.object.get("selectedType")) |st| {
                try fields.append(a, .{ .dotted_path = "security.auth.selectedType", .value = st.string });
            }
        }
    }
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
    // decision #11: model read from settings.json model.name; provider
    // derived from the modelProviders[].baseUrl host (when present).
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "model.name", .value = model_name });
    if (provider_base_url.len > 0) {
        try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "modelProviders.openai[].baseUrl", .value = provider_base_url });
    }
}

fn detectOmp(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fs.path.join(a, &.{ home, ".omp/agent/config.yml" });
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);

    // omp's config is YAML where parent + child key can be on
    // separate lines:
    //   modelRoles:
    //     default: minimax-code/MiniMax-M3
    // We accept either form: a single line "modelRoles.default: …"
    // or the multi-line YAML continuation, which is what the on-disk
    // file actually uses. To resolve, walk lines, track whether we
    // just saw a `modelRoles:` line without a value, and pick up
    // the next indented `default:`.
    var lines = std.mem.splitScalar(u8, data, '\n');
    var model_default: ?[]const u8 = null;
    var in_model_roles = false;
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0) continue;
        // single-line form
        if (std.mem.startsWith(u8, t, "modelRoles.default")) {
            const colon = std.mem.findScalar(u8, t, ':') orelse continue;
            const val = std.mem.trim(u8, t[colon + 1 ..], " \"\t");
            if (val.len > 0) model_default = val;
            break;
        }
        // parent-only "modelRoles:" line opens the block
        if (std.mem.eql(u8, t, "modelRoles:") or std.mem.eql(u8, t, "modelRoles: ")) {
            in_model_roles = true;
            continue;
        }
        if (in_model_roles) {
            if (std.mem.startsWith(u8, t, "default:")) {
                const val = std.mem.trim(u8, t["default:".len..], " \"\t");
                if (val.len > 0) model_default = val;
            }
            // any other key closes the block
            break;
        }
    }
    const dm = model_default orelse return;
    const slash = std.mem.findScalar(u8, dm, '/');
    if (slash) |i| {
        const prov = dm[0..i];
        const model_only = dm[i + 1 ..];
        d.provider_name = prov;
        d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
        try applyProviderMeta(a, d, prov);
        try applyModel(a, d, model_only, dm);
    } else {
        d.provider_name = dm;
        d.provider_label = providerForName(dm) orelse try titleCase(a, dm);
        try applyProviderMeta(a, d, dm);
        try applyModel(a, d, dm, dm);
    }

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "modelRoles.default", .value = dm });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
    // decision #11: both dims read from config.yml's
    // `modelRoles.default` = "<provider>/<model>".
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "modelRoles.default", .value = dm });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "modelRoles.default", .value = dm });
}

fn detectReasonix(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = env;
    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fs.path.join(a, &.{ home, ".reasonix/config.toml" });
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);

    // Naive parser: scan top-level lines for `default_model = "<value>"`.
    // The provider resolution matches default_model against the
    // [[providers]] entries' `name` field, then reads that entry's
    // `default` (or first `models = [...]` entry) for the actual model
    // id. Keys are matched by the token before `=` so aligned columns
    // (`name        = "..."`) parse the same as single-space ones; when
    // the providers table can't be resolved (e.g. the model id equals
    // the provider name in practice), fall back to using the
    // default_model string as both the provider and model id.
    var lines = std.mem.splitScalar(u8, data, '\n');
    var default_model: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.findScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t\r");
        if (!std.mem.eql(u8, key, "default_model")) continue;
        const val = std.mem.trim(u8, t[eq + 1 ..], " \"\t");
        if (val.len == 0) continue;
        default_model = val;
        break;
    }
    const dm = default_model orelse return;

    // walk the `[[providers]]` blocks: find the entry whose `name`
    // equals `dm` and read its `default` (or first `models = [...]`
    // entry) for the model id:
    //   [[providers]]
    //   name = "deepseek-flash"
    //   default = "deepseek-v4-flash"
    //   models = ["deepseek-v4-flash"]    (real configs, aligned)
    const provider_name: []const u8 = dm;
    var model_name: []const u8 = dm;
    var model_field: []const u8 = "default_model";
    var in_providers = false;
    var in_dm = false;
    var lines2 = std.mem.splitScalar(u8, data, '\n');
    while (lines2.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, t, "[[providers]]")) {
            in_providers = true;
            in_dm = false;
            continue;
        }
        if (!in_providers) continue;
        const eq = std.mem.findScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t\r");
        const val = std.mem.trim(u8, t[eq + 1 ..], " \"\t");
        if (std.mem.eql(u8, key, "name")) {
            in_dm = std.mem.eql(u8, val, dm);
            continue;
        }
        if (in_dm and std.mem.eql(u8, key, "default")) {
            if (val.len > 0) {
                model_name = val;
                model_field = "providers[].default";
            }
            break;
        }
        if (in_dm and std.mem.eql(u8, key, "models")) {
            const q = std.mem.findScalar(u8, t, '"') orelse continue;
            const rest = t[q + 1 ..];
            const q2 = std.mem.findScalar(u8, rest, '"') orelse continue;
            if (q2 > 0) {
                model_name = rest[0..q2];
                model_field = "providers[].models";
            }
            break;
        }
    }

    d.provider_name = provider_name;
    d.provider_label = providerForName(provider_name) orelse try titleCase(a, provider_name);
    try applyProviderMeta(a, d, provider_name);
    try applyModel(a, d, model_name, dm);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "default_model", .value = dm });
    if (!std.mem.eql(u8, model_name, dm)) {
        try fields.append(a, .{ .dotted_path = model_field, .value = model_name });
    }
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
    // decision #11: the provider is `default_model`; the model is the
    // matched [[providers]] entry's `default`/`models` (both from
    // config.toml).
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "default_model", .value = dm });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = model_field, .value = model_name });
}

fn detectCrush(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = env;
    if (home.len == 0) return;
    // crush's `default_large_model_id` is the "current" model — the
    // launcher wrote it into hyper.json from the user's `crush
    // update-providers` run. Format: "<provider>/<model>". The path
    // follows HOME, so it must NOT be hardcoded.
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fs.path.join(a, &.{ home, ".local/share/crush/hyper.json" });
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    defer parsed.deinit();
    const dm = (parsed.value.object.get("default_large_model_id") orelse return).string;
    if (dm.len == 0) return;

    const slash = std.mem.findScalar(u8, dm, '/');
    if (slash) |i| {
        var prov = dm[0..i];
        const model_only = dm[i + 1 ..];
        // crush's hyper.json routes the user's Charm Hyper subscription;
        // a provider key that is no known provider but IS a known model
        // id (e.g. "qwen3.7-plus/…") is hyper's internal routing alias —
        // the provider the user engages is `hyper`.
        if (providerMetaForName(prov) == null and canonicalIdFor(a, ModelRule, &rulesForModels, prov) != null) prov = "hyper";
        d.provider_name = prov;
        d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
        try applyProviderMeta(a, d, prov);
        try applyModel(a, d, model_only, dm);
    } else {
        var prov = dm;
        if (providerMetaForName(dm) == null and canonicalIdFor(a, ModelRule, &rulesForModels, dm) != null) prov = "hyper";
        d.provider_name = prov;
        d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
        try applyProviderMeta(a, d, prov);
        try applyModel(a, d, dm, dm);
    }

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "default_large_model_id", .value = dm });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
    // decision #11: both dims read from hyper.json's
    // `default_large_model_id` = "<provider>/<model>".
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "default_large_model_id", .value = dm });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "default_large_model_id", .value = dm });
}

/// Resolve the current working directory for session-store lookups.
/// POSIX shells export `PWD` (the logical cwd) — use it for parity
/// with existing behavior. Windows has no `PWD` (and git-bash's MSYS
/// `/c/...` form would never match the session store), so use the OS
/// current directory via `std.process.currentPathAlloc`. The returned
/// slice is either env-owned or arena-owned; both outlive this call.
fn currentDir(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    if (builtin.os.tag != .windows) {
        if (env.get("PWD")) |pwd| {
            if (pwd.len > 0) return pwd;
        }
    }
    return std.process.currentPathAlloc(io, a) catch return null;
}

fn detectKilo(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    // Launcher sets KILO_MODEL=<provider>/<model> before capture runs;
    // prefer that (matches the committed-trailer provider naming). Fall
    // back to reading the live Kilo session DB for the `trailer`/`agent`
    // actions run directly under the Kilo CLI, where KILO_MODEL is unset.
    const model_full = env.get("KILO_MODEL") orelse {
        return detectKiloFromDb(a, io, env, home, d);
    };
    if (model_full.len == 0) return detectKiloFromDb(a, io, env, home, d);
    const slash = std.mem.findScalar(u8, model_full, '/');
    if (slash) |i| {
        const prov = model_full[0..i];
        const model_only = model_full[i + 1 ..];
        try setProvider(a, d, prov);
        try applyModel(a, d, model_only, model_full);
    } else {
        try setProvider(a, d, "anthropic");
        try applyModel(a, d, model_full, model_full);
    }
    // kilo has no config file — the KILO_MODEL value lives in
    // raw.env_vars (added by applyModel via the env block), not in
    // a fake config_file entry. Leaving config_files empty keeps the
    // raw block honest. The evidence claims point at the KILO_MODEL
    // env observation, whose value carries "<provider>/<model>".
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "KILO_MODEL", .value = model_full });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "KILO_MODEL", .value = model_full });
}

/// Kilo does not export the active model to child processes, but it
/// records it in the session store `~/.local/share/kilo/kilo.db`. Read
/// that read-only via the `sqlite3` CLI: resolve the *active* session —
/// the non-archived session whose newest message was written in the
/// current working directory — and read the model from that message's
/// data (carried at creation time), not from the session row's
/// `session.model` column (which kilo writes lazily and which
/// `ORDER BY time_updated DESC` can misattribute to a different
/// window's session). Partial/absent → no-op (the caller falls back to
/// leaving detection unresolved).
fn detectKiloFromDb(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const dir = currentDir(a, io, env) orelse return;
    const db = try std.fs.path.join(a, &.{ home, ".local/share/kilo/kilo.db" });
    defer a.free(db);
    const mm = (try detectActiveSessionModel(a, io, db, dir)) orelse return;
    try setProvider(a, d, mm.provider_id);
    try applyModel(a, d, stripBuildStamp(a, mm.model_full), mm.model_full);
    // decision #11: the live session store is the source for both dims —
    // record the db read so a real-session fixture's evidence chain is
    // complete (the env path above already claims KILO_MODEL).
    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "session.model.providerID", .value = mm.provider_id });
    try fields.append(a, .{ .dotted_path = "session.model.id", .value = mm.model_full });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = db, .fields = try fields.toOwnedSlice(a) };
    d.raw.session_files = obs;
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "session", .name = db, .field = "session.model.providerID", .value = mm.provider_id });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "session", .name = db, .field = "session.model.id", .value = mm.model_full });
}

/// A provider + model resolved from a kilo/opencode session store.
pub const ActiveSessionModel = struct {
    provider_id: []const u8,
    model_full: []const u8,
};

/// Resolve the *active* session's model from a kilo/opencode-format
/// session store (`~/.local/share/kilo/kilo.db` / `~/.local/share/
/// opencode/opencode.db`). Both harnesses use the same schema: a
/// `session` table (with `directory`, `time_archived`, and a
/// lazily-written `model` JSON column) plus a `message` table whose
/// `data` JSON carries the model at message-creation time.
///
/// The active session is the non-archived session in `dir` whose newest
/// `message.time_created` is most recent — real conversational activity,
/// not the session row's `time_updated` (which background syncs, title
/// generation, and compaction bump for any session in the directory,
/// including other windows'). The message data is preferred over
/// `session.model` because it is written at creation time (assistant
/// messages carry flat `modelID`/`providerID`; user messages nest them
/// under `model`), whereas `session.model` can be null for minutes after
/// a session starts. Falls back to `session.model` only when the newest
/// message lacks model info. Partial/absent → null (caller leaves
/// detection unresolved).
fn detectActiveSessionModel(a: std.mem.Allocator, io: std.Io, db: []const u8, dir: []const u8) !?ActiveSessionModel {
    if (db.len == 0 or dir.len == 0) return null;
    if (std.Io.Dir.cwd().statFile(io, db, .{})) |_| {} else |_| return null;

    // quote dir into a SQL string literal (single-quote doubling).
    // Windows stores session directories with forward slashes while
    // `currentPathAlloc` returns backslashes — normalize separators so
    // the exact match finds the active session (POSIX is a no-op).
    var dir_lit: std.ArrayList(u8) = .empty;
    defer dir_lit.deinit(a);
    try dir_lit.append(a, '\'');
    for (dir) |c| {
        if (c == '\'') try dir_lit.append(a, '\'');
        if (builtin.os.tag == .windows and c == '\\') {
            try dir_lit.append(a, '/');
        } else {
            try dir_lit.append(a, c);
        }
    }
    try dir_lit.append(a, '\'');

    // newest message in a non-archived session for `dir` — the session
    // that owns it is the active one. Read its data JSON and the
    // session row's model JSON in one row so the message path can fall
    // back to the (lazily-written) session column.
    const sql = try std.fmt.allocPrint(a,
        \\SELECT m.data, s.model FROM message m JOIN session s ON s.id = m.session_id
        \\WHERE s.directory={s} AND s.time_archived IS NULL
        \\ORDER BY m.time_created DESC LIMIT 1
    , .{dir_lit.items});
    defer a.free(sql);

    const out = kiloSqliteJson(a, io, db, sql) catch return null;
    if (out.len == 0) return null;
    const outer = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return null;
    if (outer.value != .array or outer.value.array.items.len == 0) return null;
    const row = outer.value.array.items[0];
    if (row != .object) return null;

    // message data carries the model at creation time — prefer it.
    // assistant: {"role":"assistant", ..., "modelID":"...", "providerID":"..."}
    // user:      {"role":"user", ..., "model":{"providerID":"...","modelID":"..."}}
    if (row.object.get("data")) |md| {
        if (md == .string and md.string.len > 0) {
            if (try modelFromMessageData(a, md.string)) |mm| return mm;
        }
    }
    // fallback: the session row's model JSON
    // {"id":"deepseek-v4-flash-0731","providerID":"hyper"}
    if (row.object.get("model")) |sm| {
        if (sm == .string and sm.string.len > 0) {
            if (try modelFromSessionRow(a, sm.string)) |mm| return mm;
        }
    }
    return null;
}

/// Extract `providerID` + `modelID` from a kilo/opencode message `data`
/// JSON string. Returns null when the message carries no model info.
pub fn modelFromMessageData(a: std.mem.Allocator, data: []const u8) !?ActiveSessionModel {
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return null;
    const o = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    var provider_id: ?[]const u8 = jstr(o, "providerID");
    var model_full: ?[]const u8 = jstr(o, "modelID");
    // user messages nest the model under `model`
    if (provider_id == null or model_full == null) {
        if (o.get("model")) |mv| {
            if (mv == .object) {
                if (provider_id == null) provider_id = jstr(mv.object, "providerID");
                if (model_full == null) model_full = jstr(mv.object, "modelID");
            }
        }
    }
    if (provider_id == null or model_full == null) return null;
    return .{ .provider_id = provider_id.?, .model_full = model_full.? };
}

/// Extract `providerID` + `id` from a kilo/opencode session-row `model`
/// JSON string (e.g. `{"id":"deepseek-v4-flash-0731","providerID":"hyper"}`).
pub fn modelFromSessionRow(a: std.mem.Allocator, model_str: []const u8) !?ActiveSessionModel {
    const parsed = std.json.parseFromSlice(std.json.Value, a, model_str, .{}) catch return null;
    const o = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const provider_id = jstr(o, "providerID") orelse return null;
    const model_full = jstr(o, "id") orelse return null;
    return .{ .provider_id = provider_id, .model_full = model_full };
}

/// read a spawned child's stdout (`stderr=false`) or stderr
/// (`stderr=true`) to EOF, returning the collected bytes (caller frees).
/// The stderr variant is bounded at 64 KiB — diagnostics are truncated
/// rather than allowed to grow unbounded. The caller still owns
/// `child.wait`.
pub fn readChildOutput(a: std.mem.Allocator, io: std.Io, child: std.process.Child, comptime stderr: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const limit: usize = if (stderr) 1 << 16 else std.math.maxInt(usize);
    var buf: [8192]u8 = undefined;
    var reader = if (stderr) child.stderr.?.reader(io, &buf) else child.stdout.?.reader(io, &buf);
    while (out.items.len < limit) {
        var chunk: [8192]u8 = undefined;
        const n = reader.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try out.appendSlice(a, chunk[0..@min(n, limit - out.items.len)]);
    }
    return out.toOwnedSlice(a);
}

/// spawn `sqlite3 -json <db> <sql>`; return stdout. Caller owns the
/// returned slice — do NOT free it here: the caller's JSON parse
/// aliases into it, and Zig 0.16's arena free-list would reclaim
/// this most-recent allocation into the parse's own allocations
/// (use-after-free clobbering the bytes mid-parse).
/// The dev fixtures store no longer shells out to sqlite — the
/// released binary's read-only session-store reads (kilo/opencode/
/// copilot DBs) are the only sqlite use left.
fn kiloSqliteJson(a: std.mem.Allocator, io: std.Io, db: []const u8, sql: []const u8) ![]u8 {
    const db_z = try a.dupeZ(u8, db);
    defer a.free(db_z);
    var argv_buf = [_][]const u8{ "sqlite3", "-json", "-batch", db_z, sql };
    var child = std.process.spawn(io, .{
        .argv = &argv_buf,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SqliteSpawnFailed;
    const out = readChildOutput(a, io, child, false) catch return error.SqliteSpawnFailed;
    const term = child.wait(io) catch return error.SqliteSpawnFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.SqliteError,
        else => return error.SqliteError,
    }
    return out;
}

/// strip a trailing `-NNN` build stamp (e.g. `deepseek-v4-flash-0731` →
/// `deepseek-v4-flash`) so the id matches the model rule. No-op when the
/// last dash-segment isn't 1+ digits.
fn stripBuildStamp(a: std.mem.Allocator, name: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, name, '-') orelse return name;
    const stamp = name[dash + 1 ..];
    if (stamp.len == 0) return name;
    for (stamp) |c| {
        if (!std.ascii.isDigit(c)) return name;
    }
    return a.dupe(u8, name[0..dash]) catch name;
}

fn detectOpencode(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    // opencode doesn't persist current-model in a config file. The
    // launcher sets OPENCODE_MODEL="<provider>/<model>"; in a real
    // session opencode stores the model in sqlite (`opencode.db`,
    // `session.model` JSON with `providerID`/`id`), so fall back to the
    // latest session when the env var is absent.
    if (env.get("OPENCODE_MODEL")) |model_full| {
        if (model_full.len == 0) return;
        const slash = std.mem.findScalar(u8, model_full, '/');
        if (slash) |i| {
            const prov = model_full[0..i];
            const model_only = model_full[i + 1 ..];
            d.provider_name = prov;
            d.provider_label = providerForName(prov) orelse try titleCase(a, prov);
            try applyProviderMeta(a, d, prov);
            try applyModel(a, d, model_only, model_full);
        } else {
            d.provider_name = "anthropic";
            d.provider_label = "Anthropic";
            try applyProviderMeta(a, d, "anthropic");
            try applyModel(a, d, model_full, model_full);
        }
        // opencode has no config file — the OPENCODE_MODEL value lives
        // in raw.env_vars, not in a fake config_file entry.
        try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "OPENCODE_MODEL", .value = model_full });
        try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "OPENCODE_MODEL", .value = model_full });
        return;
    }

    // real opencode session: the active session's model in the sqlite
    // store (`~/.local/share/opencode/opencode.db`). Same schema as
    // kilo's — active = non-archived session for the cwd with the
    // newest message; model read from that message's data (written at
    // creation time), not the lazily-written session.model column.
    if (home.len == 0) return;
    const dir = currentDir(a, io, env) orelse return;
    const db = try std.fs.path.join(a, &.{ home, ".local/share/opencode/opencode.db" });
    defer a.free(db);
    const mm = (try detectActiveSessionModel(a, io, db, dir)) orelse return;
    try setProvider(a, d, mm.provider_id);
    try applyModel(a, d, stripBuildStamp(a, mm.model_full), mm.model_full);
    // decision #11: the live session store is the source for both dims.
    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "session.model.providerID", .value = mm.provider_id });
    try fields.append(a, .{ .dotted_path = "session.model.id", .value = mm.model_full });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = db, .fields = try fields.toOwnedSlice(a) };
    d.raw.session_files = obs;
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "session", .name = db, .field = "session.model.providerID", .value = mm.provider_id });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "session", .name = db, .field = "session.model.id", .value = mm.model_full });
}

fn detectVibe(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = io;
    // vibe's documented override: VIBE_ACTIVE_MODEL=<name> sets the
    // active model without going through the config. Launcher uses
    // this to capture whatever model the user is currently running.
    // Mistral Vibe is a Mistral product, so the underlying provider is
    // Mistral unless the launcher overrides it (VIBE_ACTIVE_PROVIDER).
    const model_name = env.get("VIBE_ACTIVE_MODEL") orelse return;
    if (model_name.len == 0) return;
    const provider_id = env.get("VIBE_ACTIVE_PROVIDER") orelse "mistral";
    d.provider_name = provider_id;
    d.provider_label = providerForName(provider_id) orelse "Mistral";
    try applyProviderMeta(a, d, provider_id);
    try applyModel(a, d, model_name, model_name);

    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "VIBE_ACTIVE_PROVIDER", .value = provider_id });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "VIBE_ACTIVE_MODEL", .value = model_name });

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "VIBE_ACTIVE_MODEL", .value = model_name });
    if (home.len > 0) {
        const path = try std.fs.path.join(a, &.{ home, ".vibe/config.toml" });
        const obs = try a.alloc(FileObservation, 1);
        obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
        d.raw.config_files = obs;
    }
}

fn detectPi(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    // pi: harness-only by design for the env path; real pi sessions set
    // no PI_* env vars, so when both are unset we read the real
    // defaults from `~/.pi/agent/settings.json` (`defaultProvider` /
    // `defaultModel`). The env path (both set) is the launcher stand-in
    // and stays unchanged — its evidence claims record exactly what was
    // used, and the raw.env observation shows `present` so a reviewer
    // can tell a launcher-set value from a default.
    const provider_env = env.get("PI_PROVIDER");
    const model_env = env.get("PI_MODEL");
    if (provider_env != null and model_env != null) {
        const provider = provider_env.?;
        const model = model_env.?;
        const provider_canon = try piProviderCanonical(a, provider);
        d.provider_name = provider_canon;
        d.provider_label = providerForName(provider_canon) orelse try titleCase(a, provider_canon);
        try applyProviderMeta(a, d, provider_canon);
        try applyModel(a, d, model, model);
        try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "PI_PROVIDER", .value = provider_canon });
        try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "PI_MODEL", .value = model });
        return;
    }

    if (home.len == 0) return;
    const cwd_dir = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(a, "{s}/.pi/agent/settings.json", .{home});
    const data = cwd_dir.readFileAlloc(io, path, a, @enumFromInt(1 << 20)) catch return;
    defer a.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value.object;
    const provider = switch (root.get("defaultProvider") orelse return) {
        .string => |s| s,
        else => return,
    };
    const model = switch (root.get("defaultModel") orelse return) {
        .string => |s| s,
        else => return,
    };
    if (provider.len == 0 or model.len == 0) return;
    const provider_canon = try piProviderCanonical(a, provider);

    d.provider_name = provider_canon;
    d.provider_label = providerForName(provider_canon) orelse try titleCase(a, provider_canon);
    try applyProviderMeta(a, d, provider_canon);
    try applyModel(a, d, model, model);

    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "defaultProvider", .value = provider_canon });
    try fields.append(a, .{ .dotted_path = "defaultModel", .value = model });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = path, .fields = try fields.toOwnedSlice(a) };
    d.raw.config_files = obs;
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "config", .name = path, .field = "defaultProvider", .value = provider_canon });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "config", .name = path, .field = "defaultModel", .value = model });
}

/// map pi's provider names onto agent-detect's canonical provider ids
/// (pi names its Moonshot upstream `moonshotai`; agent-detect calls it
/// `kimi`). Other providers already match (deepseek, minimax, openrouter,
/// groq, cerebras, mistral, xai).
fn piProviderCanonical(a: std.mem.Allocator, provider: []const u8) ![]const u8 {
    if (std.mem.eql(u8, provider, "moonshotai")) return a.dupe(u8, "kimi");
    return provider;
}

fn detectCursor(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    _ = io;
    _ = home;
    // cursor does not persist the current model in a config file — the
    // CLI takes `--model` per run (default `auto`). The launcher sets
    // CURSOR_MODEL="<provider>/<model>" (provider is cursor's first-party
    // router); when unset, detection stays unresolved (no real-session
    // on-disk source yet — a cursor session fixture can be added once a
    // live session records its model).
    const model_full = env.get("CURSOR_MODEL") orelse return;
    if (model_full.len == 0) return;
    const slash = std.mem.findScalar(u8, model_full, '/');
    if (slash) |i| {
        const prov = model_full[0..i];
        const model_only = model_full[i + 1 ..];
        try setProvider(a, d, prov);
        try applyModel(a, d, model_only, model_full);
    } else {
        try setProvider(a, d, "cursor");
        try applyModel(a, d, model_full, model_full);
    }
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "CURSOR_MODEL", .value = model_full });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "CURSOR_MODEL", .value = model_full });
}

fn detectCopilot(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, d: *Detection) !void {
    const model_full = env.get("COPILOT_MODEL") orelse {
        return detectCopilotFromDb(a, io, home, d);
    };
    if (model_full.len == 0) return detectCopilotFromDb(a, io, home, d);
    const slash = std.mem.findScalar(u8, model_full, '/');
    if (slash) |i| {
        const prov = model_full[0..i];
        const model_only = model_full[i + 1 ..];
        try setProvider(a, d, prov);
        try applyModel(a, d, model_only, model_full);
    } else {
        try setProvider(a, d, "github-copilot");
        try applyModel(a, d, model_full, model_full);
    }
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "env", .name = "COPILOT_MODEL", .value = model_full });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "env", .name = "COPILOT_MODEL", .value = model_full });
}

/// Copilot does not export the active model to child processes, but it
/// records it in the session store `~/.copilot/data.db` (`sessions.model`,
/// `sessions.provider_id` referencing `model_providers`). Read that
/// read-only via the `sqlite3` CLI: the newest session row. Partial/absent
/// → no-op (the caller falls back to leaving detection unresolved).
fn detectCopilotFromDb(a: std.mem.Allocator, io: std.Io, home: []const u8, d: *Detection) !void {
    if (home.len == 0) return;
    const db = try std.fs.path.join(a, &.{ home, ".copilot/data.db" });
    defer a.free(db);
    if (std.Io.Dir.cwd().statFile(io, db, .{})) |_| {} else |_| return;
    // Copilot's sessions have no cwd column, so "active" means: not
    // archived and (prefer) currently running — never a closed session
    // that merely updated last. `is_running DESC` keeps the live session
    // ahead of a finished one with a newer updated_at.
    const sql = "SELECT model, provider_id FROM sessions WHERE archived_at IS NULL ORDER BY is_running DESC, updated_at DESC LIMIT 1";
    const out = kiloSqliteJson(a, io, db, sql) catch return;
    defer a.free(out);
    if (out.len == 0) return;
    const outer = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return;
    if (outer.value != .array or outer.value.array.items.len == 0) return;
    const row = outer.value.array.items[0];
    if (row != .object) return;
    const model_str = switch (row.object.get("model") orelse return) {
        .string => |s| s,
        else => return,
    };
    if (model_str.len == 0) return;
    // provider: the sessions.provider_id FK (a `model_providers` id), or
    // the first-party GitHub route when absent/unknown.
    var provider_id: []const u8 = "github-copilot";
    if (row.object.get("provider_id")) |pid| {
        if (pid == .string and pid.string.len > 0 and providerMetaForName(pid.string) != null) {
            provider_id = pid.string;
        }
    }
    try setProvider(a, d, provider_id);
    try applyModel(a, d, model_str, model_str);
    var fields = std.ArrayList(FieldObservation).empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .dotted_path = "session.model", .value = model_str });
    try fields.append(a, .{ .dotted_path = "session.provider_id", .value = provider_id });
    const obs = try a.alloc(FileObservation, 1);
    obs[0] = .{ .path = db, .fields = try fields.toOwnedSlice(a) };
    d.raw.session_files = obs;
    try addEvidenceClaim(a, d, .{ .dim = "provider", .source = "session", .name = db, .field = "session.provider_id", .value = provider_id });
    try addEvidenceClaim(a, d, .{ .dim = "model", .source = "session", .name = db, .field = "session.model", .value = model_str });
}

/// tri-state reciprocity determination for `d`:
/// - `"NONE"` harness_license → `.not_reciprocal` unconditionally (a
///   verified closed harness can never be reciprocal, regardless of
///   the model/provider dims);
/// - `.unknown` when `harness_license` is `null` or `"NOASSERTION"`,
///   or any of `model_reciprocity` / `provider_closed_training` is
///   null (unverified status cannot be assumed reciprocal per the AI
///   policy);
/// - otherwise `.reciprocal` iff the current conjunction passes, else
///   `.not_reciprocal`.
pub const Reciprocity = enum { reciprocal, not_reciprocal, unknown };

pub fn reciprocityOf(d: *const Detection) Reciprocity {
    if (d.harness_license) |hl| {
        if (std.mem.eql(u8, hl, license_none)) return .not_reciprocal;
        if (std.mem.eql(u8, hl, license_noassertion)) return .unknown;
    } else {
        return .unknown;
    }
    if (d.model_reciprocity == null or d.provider_closed_training == null) return .unknown;
    if (computeReciprocal(d)) return .reciprocal;
    return .not_reciprocal;
}

/// compute the `reciprocal` boolean. Returns `true` only when:
///   - harness_license is a real SPDX id (non-null, not `"NONE"`,
///     not `"NOASSERTION"`), AND
///   - model_reciprocity is "open-source" or "open-weight", AND
///   - provider_closed_training is one of "never", "opt-in", or "opt-out"
///     (provider does not unilaterally train closed models on customer data).
/// Any null on the three conjuncts makes the result `false`: per the
/// AI Policy, an unverified status cannot be assumed reciprocal.
/// `"NONE"` and `"NOASSERTION"` both short-circuit to `false` — the
/// former because a verified closed harness is never reciprocal, the
/// latter because it is unverified.
/// This is the same conjunction `reciprocityOf` uses for its non-null
/// case, so the canonical JSON `reciprocal` field stays a boolean while
/// the tri-state caller gets the full picture.
pub fn computeReciprocal(d: *const Detection) bool {
    if (d.harness_license == null) return false;
    if (std.mem.eql(u8, d.harness_license.?, license_none)) return false;
    if (std.mem.eql(u8, d.harness_license.?, license_noassertion)) return false;
    const mr = d.model_reciprocity orelse return false;
    if (!std.mem.eql(u8, mr, "open-source") and !std.mem.eql(u8, mr, "open-weight")) return false;
    const pct = d.provider_closed_training orelse return false;
    return std.mem.eql(u8, pct, "never") or std.mem.eql(u8, pct, "opt-in") or std.mem.eql(u8, pct, "opt-out");
}

/// The detection report is a JSON object assembled from:
/// - `buildCooked` — the shape-stable 18-field canonical object,
///   grouped by entity (harness / provider / model / agent). The
///   `trailer` field was removed so the identify output no longer
///   carries it (fixture channels persist both trailer variants as
///   separate keys).
/// - `buildRaw` — the shapeless raw observations object (dev binary
///   only), whose top-level keys identify source evidence.
/// The released binary's `identify` action serializes `buildCooked` at
/// the root; the dev binary's fixture files embed it as `outputs.identify`
/// alongside the trailer variants and (for captures) the raw block.
/// Extract the user's home directory once so we can redact it from
/// every emitted string — fixtures must be portable across machines.
/// `home` is empty when neither USERPROFILE nor HOME is set, in which
/// case redactHome is a no-op for the literal-path branch.
pub fn reporterHome(env: *const std.process.Environ.Map) []const u8 {
    return env.get("USERPROFILE") orelse (env.get("HOME") orelse "");
}

/// Build the canonical identification object (18 fields, grouped by entity).
/// Returns a heap-allocated `std.json.Value` the caller owns.
pub fn buildCooked(a: std.mem.Allocator, d: *const Detection) !std.json.Value {
    const V = std.json.Value;
    // Each canonical field is `?[]const u8` (or `?bool`). Use a small
    // helper to emit `null` when absent so partial-detection fixtures
    // read as `null`, not `""`. The previous shape serialized nulls as
    // empty strings, which made `harness_license: ""`
    // indistinguishable from a project that actually has an
    // empty-string SPDX license.
    var canonical: V = .{ .object = .empty };
    try canonical.object.put(a, "harness_label", optStringValue(a, d.harness_label));
    try canonical.object.put(a, "harness_short_title", optStringValue(a, d.harness_short_title));
    try canonical.object.put(a, "harness_name", optStringValue(a, d.harness_name));
    try canonical.object.put(a, "harness_id", optStringValue(a, d.harness_id));
    try canonical.object.put(a, "harness_license", optStringValue(a, d.harness_license));
    try canonical.object.put(a, "provider_label", optStringValue(a, d.provider_label));
    try canonical.object.put(a, "provider_name", optStringValue(a, d.provider_name));
    try canonical.object.put(a, "provider_id", optStringValue(a, d.provider_id));
    try canonical.object.put(a, "provider_closed_training", optStringValue(a, d.provider_closed_training));
    try canonical.object.put(a, "provider_open_training", optStringValue(a, d.provider_open_training));
    try canonical.object.put(a, "model_label", optStringValue(a, d.model_label));
    try canonical.object.put(a, "model_short_title", optStringValue(a, d.model_short_title));
    try canonical.object.put(a, "model_name", optStringValue(a, d.model_name));
    try canonical.object.put(a, "model_id", optStringValue(a, d.model_id));
    try canonical.object.put(a, "model_reciprocity", optStringValue(a, d.model_reciprocity));
    try canonical.object.put(a, "model_license", optStringValue(a, d.model_license));
    // agent id is composed of the three sub-ids above; emitted in the
    // model block (after model_id) so the canonical
    // block reads harness → provider → model → agent.
    try canonical.object.put(a, "agent_id", optStringValue(a, d.agent_id));
    // `reciprocal` is `?bool` in Detection but the JSON output uses
    // `null` for "not computed" — V has no `?bool` so we unbox manually.
    if (d.reciprocal) |r| {
        try canonical.object.put(a, "reciprocal", .{ .bool = r });
    } else {
        try canonical.object.put(a, "reciprocal", .null);
    }
    return canonical;
}

/// the trailer string for `d`, if one was computed. Delegates to the
/// stored `d.trailer` (set by `detect` / recipe resolution).
pub fn buildTrailer(d: *const Detection) ?[]const u8 {
    return d.trailer;
}

/// Build a commit-trailer line for `d` with the given keyword (e.g.
/// `Co-authored-by` / `Assisted-by`), or `null` when the identity is
/// incomplete (any of harness_label / model_label / agent_id null).
/// Output format: `{keyword}: {harness_label} · {model_label}
/// <{agent_id}@local>` — the `·` is a middle-dot separator, not a
/// hyphen; the email local (machine-readable side) uses `-`.
pub fn buildTrailerLine(a: std.mem.Allocator, d: *const Detection, keyword: []const u8) !?[]u8 {
    if (d.harness_label == null or d.model_label == null or d.agent_id == null) return null;
    return @as(?[]u8, try std.fmt.allocPrint(
        a,
        "{s}: {s} · {s} <{s}@local>",
        .{ keyword, d.harness_label.?, d.model_label.?, d.agent_id.? },
    ));
}

/// emit the slim released JSON report (canonical fields at the root,
/// no `raw` block) into `buf`. The `identify` action uses this directly.
pub fn buildJson(a: std.mem.Allocator, d: *const Detection, env: *const std.process.Environ.Map, rule: ?HarnessRule, anc: Ancestry, buf: *std.ArrayList(u8)) !void {
    _ = env;
    _ = rule;
    _ = anc;
    const cooked = try buildCooked(a, d);
    const json_bytes = try std.json.Stringify.valueAlloc(a, cooked, .{ .whitespace = .indent_2 });
    defer a.free(json_bytes);
    try buf.appendSlice(a, json_bytes);
    try buf.appendSlice(a, "\n");
}

/// convert `[]const []const u8` into a `std.json.Value` array of strings.
pub fn stringListValue(a: std.mem.Allocator, items: []const []const u8) std.json.Value {
    var arr: std.json.Value = .{ .array = std.json.Array.init(a) };
    errdefer arr.array.deinit();
    for (items) |s| {
        arr.array.append(.{ .string = s }) catch return arr;
    }
    return arr;
}

/// convert `?[]const u8` into a JSON `null` or string. Heap-allocates
/// the inner buffer only when the value is present (null leaves the
/// arena untouched). On out-of-memory, falls back to JSON `null`.
pub fn optStringValue(a: std.mem.Allocator, opt: ?[]const u8) std.json.Value {
    if (opt) |v| {
        if (v.len == 0) return .{ .string = "" };
        const copy = a.dupe(u8, v) catch return .null;
        return .{ .string = copy };
    }
    return .null;
}

/// replace the user's home directory and shell interpolations with
/// `<home>` in a string so fixture output is portable across
/// machines. Handles:
///   - `$HOME` and `${HOME}` (must be followed by non-identifier char)
///   - `~/` and `~` (only at start of string)
///   - the literal home path (`/Users/foo` etc., only when followed
///     by `/` or end-of-string to avoid matching `/Users/fooella`)
/// The input string is left untouched when it contains no home
/// references; otherwise a fresh allocation is returned.
pub fn redactHome(a: std.mem.Allocator, s: []const u8, home: []const u8) ![]const u8 {
    if (s.len == 0) return s;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        // ${HOME} interpolation
        if (i + 7 <= s.len and std.mem.eql(u8, s[i..][0..7], "${HOME}")) {
            try out.appendSlice(a, "<home>");
            i += 7;
            continue;
        }
        // $HOME interpolation — must be followed by non-identifier char
        // (avoids matching $HOMEBREW_REPOSITORY etc.)
        if (i + 5 <= s.len and std.mem.eql(u8, s[i..][0..5], "$HOME")) {
            const after = i + 5;
            const next = if (after < s.len) s[after] else 0;
            const word_boundary = after == s.len or
                (!std.ascii.isAlphanumeric(next) and next != '_');
            if (word_boundary) {
                try out.appendSlice(a, "<home>");
                i = after;
                continue;
            }
        }
        // ~/ at start of string (tilde expansion)
        if (i == 0 and s.len >= 2 and s[0] == '~' and s[1] == '/') {
            try out.appendSlice(a, "<home>");
            i += 1; // consume `~`; the `/` is appended in the next iteration
            continue;
        }
        // ~ alone at start
        if (i == 0 and s.len == 1 and s[0] == '~') {
            try out.appendSlice(a, "<home>");
            i += 1;
            continue;
        }
        // literal home path — followed by `/` or end of string
        if (home.len > 0 and i + home.len <= s.len and
            std.mem.eql(u8, s[i..][0..home.len], home))
        {
            const after = i + home.len;
            const boundary = after == s.len or s[after] == '/';
            if (boundary) {
                try out.appendSlice(a, "<home>");
                i = after;
                continue;
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

// ============================================================================
// output

pub const usage =
    \\agent-detect — infer the harness, provider, and model of the current agent session
    \\
    \\usage:
    \\  agent-detect <action> [options]
    \\
    \\actions:
    \\  identify       print the detection report as JSON (harness, provider, model, policy)
    \\  trailer        print a commit trailer — requires a subtype (see `trailer help`)
    \\                   co-author     Co-authored-by: (Bevry commits.md)
    \\                   assisted-by   Assisted-by:   (e.g. GCC AI policy)
    \\  check-reciprocal  check reciprocity compliance with Bevry's AI policy
    \\  help           this help (also --help, -h, or no arguments)
    \\  version        print the version (also --version, -V)
    \\
    \\options:
    \\  --harness=H --provider=P --model=M
    \\                 resolve the action from the rule tables instead of live
    \\                 detection (all three together, or none)
    \\
    \\examples:
    \\  agent-detect identify
    \\  agent-detect trailer co-author
    \\  agent-detect trailer assisted-by
    \\  agent-detect check-reciprocal
    \\  agent-detect identify --harness=kilo --provider=deepseek --model=deepseek-v4-flash
    \\
    \\exit codes:
    \\  check-reciprocal: 0 is reciprocal · 10 not reciprocal · 9 undeterminable ·
    \\  8 undetectable · 7 unknown combo; others: 0 ok · 2 unrecognised argument ·
    \\  3 conflicting argument · 4 missing required arguments · 8 undetectable.
    \\  Full registry: DESIGN.md "exit status registry".
    \\
;

pub const trailerUsage =
    \\agent-detect trailer — print a commit trailer for the detected agent
    \\
    \\usage:
    \\  agent-detect trailer <type> [--harness=H --provider=P --model=M]
    \\
    \\types:
    \\  co-author      print the Co-authored-by: trailer (Bevry's commits.md)
    \\  assisted-by    print the Assisted-by: trailer (e.g. GCC AI policy)
    \\
    \\examples:
    \\  git commit --trailer "$(agent-detect trailer co-author)"
    \\  git commit --trailer "$(agent-detect trailer assisted-by)"
    \\
;

// ============================================================================
// detection ladder — single source of truth for what `agent-detect`
// observes in the current session. Called by the `identify` action (both
// the released JSON report and the dev fixture capture).
//
// Fixtures are real-agent captures, not synthetic assemblies: every
// step reads the actual env / process tree / config files at the
// current instant.
//
// Returns `true` when `harness`, `provider`, and `model` all resolved
// (caller can emit a `trailer`); `false` otherwise.

// Recipe-mode resolution — produce a fully-shaped `Detection` for a
// known `(harness, provider, model)` combo WITHOUT running the live
// detection ladder. Used by `identify --harness=H --provider=P
// --model=M` and `trailer --harness=H --provider=P --model=M`, which
// must emit output for hard-to-detect agents purely from the rule
// tables (no env markers / config files needed).
//
// Returns `null` when any of the three ids is not a known harness /
// provider / model rule — the combo is not a valid recipe and the
// caller exits 7. The `detectable` list is fully populated (a full
// known combo implies all three dims are resolvable); `detected` is
// derived in buildRaw from whatever landed in the canonical fields.
pub fn resolveRecipe(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8) !?Detection {
    // All three ids must be known rules — an unknown dim is an invalid
    // combo (caller exits 7). Combos may be given in the canonical
    // spelling, the strict slug form (`cline-pass` vs `clinepass`),
    // a label (`Cline Pass`), or any explicit `variations` alias —
    // `canonicalIdFor` normalizes the input and matches the rule's
    // normalized alias set (name, label, short_title, variations).
    const harness_name = canonicalIdFor(a, HarnessRule, &rulesForHarnesses, h) orelse return null;
    const provider_name = canonicalIdFor(a, ProviderRule, &rulesForProviders, p) orelse return null;
    const model_name = canonicalIdFor(a, ModelRule, &rulesForModels, m) orelse return null;
    const harness = harnessRuleForName(harness_name) orelse return null;
    const provider = providerMetaForName(provider_name) orelse return null;
    const model = modelRuleForName(model_name) orelse return null;

    var d = Detection{};
    d.harness_label = try a.dupe(u8, harness.label);
    if (harness.short_title) |st| d.harness_short_title = try a.dupe(u8, st);
    d.harness_name = harness.name;
    d.harness_id = try slugId(a, harness.name);
    if (harness.version) |v| d.harness_version = try a.dupe(u8, v);
    d.harness_license = harness.license;
    d.raw.harness_urls = harness.license_sources;
    // A full known recipe implies all three dims are resolvable.
    d.detectable = &.{ "harness", "provider", "model" };
    d.provider_name = provider.name;
    d.provider_label = provider.label;
    d.provider_id = try slugId(a, provider.name);
    d.provider_closed_training = provider.closed_training;
    d.provider_open_training = provider.open_training;
    d.raw.provider_urls = provider.sources;
    d.model_label = try a.dupe(u8, model.label);
    if (model.short_title) |st| d.model_short_title = try a.dupe(u8, st);
    d.model_name = model.name;
    d.model_id = try slugId(a, model.name);
    d.model_reciprocity = model.reciprocity;
    d.model_license = model.license;
    d.raw.model_urls = model.sources;
    try setAgentId(a, &d);
    d.reciprocal = computeReciprocal(&d);
    d.trailer = try buildTrailerLine(a, &d, "Co-authored-by");
    return d;
}

pub fn detect(init: std.process.Init, d: *Detection) !bool {
    const a = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const anc = ancestorInfo(a, io);

    var rule: ?HarnessRule = null;
    var hsrc: []const u8 = "none";
    var hclaim_name: []const u8 = ""; // the matched env marker / proc name
    scan: for (rulesForHarnesses) |r| {
        for (r.env_markers) |m| {
            if (env.get(m) != null) {
                rule = r;
                hsrc = "env";
                hclaim_name = m;
                break :scan;
            }
        }
    }
    if (rule != null and std.mem.eql(u8, rule.?.name, "pi")) {
        // pi marker requires an explicit true value
        const v = env.get("PI_CODING_AGENT") orelse "";
        if (!std.mem.eql(u8, v, "true")) {
            rule = null;
            hsrc = "none";
            hclaim_name = "";
        }
    }
    if (rule == null) {
        // ancestry scan — note the pre-existing "last match wins"
        // overwrite semantics when two rules match the same ancestor:
        // the loops keep assigning `rule` without breaking. Left
        // unchanged by the binary_names rewiring.
        for (rulesForHarnesses) |r| {
            for (r.binary_names) |pn| {
                for (anc.names) |n| {
                    if (std.mem.eql(u8, n, pn)) {
                        rule = r;
                        hsrc = "ancestor";
                        hclaim_name = n;
                    }
                }
            }
        }
    }

    if (rule) |r| {
        d.harness_label = try a.dupe(u8, r.label);
        if (r.short_title) |st| d.harness_short_title = try a.dupe(u8, st);
        d.harness_name = r.name;
        d.harness_id = try slugId(a, r.name);
        if (r.version) |v| d.harness_version = try a.dupe(u8, v);
        d.harness_license = r.license;
        d.raw.harness_urls = r.license_sources;
        // decision #11: the harness dim's evidence claim. The source is
        // the marker var / proc name that actually matched (present in
        // raw.env / raw.process_lineage); the value is the harness's
        // canonical name, which is what the rule links the marker to.
        if (hclaim_name.len > 0) {
            try addEvidenceClaim(a, d, .{
                .dim = "harness",
                .source = if (std.mem.eql(u8, hsrc, "env")) "env" else "lineage",
                .name = hclaim_name,
                .value = r.name,
            });
        }
        // populate env_vars with one entry per declared env-marker — even
        // when the runtime env didn't have it (`present=false`) so a
        // human reading the fixture can tell which markers the rule
        // checked vs. which were actually present.
        var env_list = std.ArrayList(EnvVarObservation).empty;
        for (r.env_markers) |m| {
            if (env.get(m)) |v| {
                const value: []const u8 = if (envValueAllowed(m)) v else "";
                try env_list.append(a, .{ .name = m, .value = value, .present = true });
            } else {
                try env_list.append(a, .{ .name = m, .value = "", .present = false });
            }
        }
        d.raw.env_vars = try env_list.toOwnedSlice(a);
        // populate process lineage from anc. The full chain is
        // emitted verbatim regardless of which harness was detected
        // and whether detection ran via env marker or proc ancestry.
        // `canonical.harness_name` identifies the matched harness; the
        // lineage is independent runtime provenance — it tells the
        // maintainer WHERE the fixture was actually captured (e.g.
        // inside a `<harness-id>` session vs. a fresh bash), which
        // is useful audit info and never contradicts the canonical
        // id. The launcher's `setsid` + per-harness shim (see
        // DESIGN.md "platform invocation") guarantees the lineage
        // contains the harness being tested without inheriting the
        // dev harness's session.
        var lineage = std.ArrayList(Ancestor).empty;
        for (anc.pids, 0..) |pid, i| {
            const name: []const u8 = if (i < anc.names.len) anc.names[i] else "";
            try lineage.append(a, .{ .pid = pid, .name = name });
        }
        d.raw.process_lineage = try lineage.toOwnedSlice(a);
        const home = env.get("USERPROFILE") orelse (env.get("HOME") orelse "");
        if (std.mem.eql(u8, r.name, "cline")) {
            try detectCline(a, io, anc, home, d);
        } else if (std.mem.eql(u8, r.name, "goose")) {
            try detectGoose(a, io, env, env.get("APPDATA") orelse "", home, d);
        } else if (std.mem.eql(u8, r.name, "kimi-code")) {
            try detectKimi(a, io, home, d);
        } else if (std.mem.eql(u8, r.name, "mmx")) {
            try detectMmx(a, io, home, d);
        } else if (std.mem.eql(u8, r.name, "pi")) {
            try detectPi(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "qwen")) {
            try detectQwen(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "kilo")) {
            try detectKilo(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "omp")) {
            try detectOmp(a, io, home, d);
        } else if (std.mem.eql(u8, r.name, "reasonix")) {
            try detectReasonix(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "crush")) {
            try detectCrush(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "opencode")) {
            try detectOpencode(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "vibe")) {
            try detectVibe(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "cursor")) {
            try detectCursor(a, io, env, home, d);
        } else if (std.mem.eql(u8, r.name, "copilot")) {
            try detectCopilot(a, io, env, home, d);
        }
    }
    // compute reciprocity from the three policy fields
    d.reciprocal = computeReciprocal(d);
    // co-author trailer (commits.md format). The email local is the
    // `agent_id` (harness-provider-model), which now
    // includes the provider so reciprocity on changelogs can be
    // post-verified from the trailer alone. The display name uses
    // `<harness_title> · <model_title>` with a middle-dot separator
    // (rather than `-`) for human readability — the email is the
    // machine-readable side and uses `-`.
    d.trailer = try buildTrailerLine(a, d, "Co-authored-by");
    // `detectable` — the dims this run's ladder *could* resolve (from
    // the env-marker/process-ancestry match + the per-harness config
    // read). `detected` is derived from the canonical fields post-hoc
    // in buildRaw; here we record only the capability.
    var detectable = std.ArrayList([]const u8).empty;
    if (d.harness_id != null) try detectable.append(a, "harness");
    if (d.provider_id != null) try detectable.append(a, "provider");
    if (d.model_id != null) try detectable.append(a, "model");
    d.detectable = try detectable.toOwnedSlice(a);
    return d.harness_label != null and d.provider_label != null and d.model_label != null;
}
