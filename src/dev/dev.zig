// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detect-dev — the maintainer-only fixtures surface: the `fixtures`
// namespace (daemon, capture, queue, dequeue) plus the standalone `raw`
// action. Compiled into the binary only when built with `-Ddev=true`;
// `pub const dev` below is the comptime-gated struct, so the released
// binary never links this surface.
//
// The fixtures agent captures the current real session into
// `fixtures/<stem>.json` (top-level `from-capture` + `from-capture-raw`
// channel keys). Designed to be invoked by an agent harness
// from inside its own environment: the daemon (see CONTRIBUTING.md)
// drives per-harness launches that call this via `fixtures capture`.
//
// Contract: a fixture only exists when the current session fully
// identified harness + provider + model. Anything less (one of them
// null) is a failure — the binary exits 8 and writes no file. Such a
// fixture would not be "evidence of what the session produced", it
// would be a backfill the maintainer would have to justify. Detection
// code that can't resolve provider or model should be fixed rather
// than papered over.
//
// `fixtures daemon` is the long-running user-side mode: it
// watches the `queue` array of `fixtures/.index.json` and, per poll,
// expands one queue entry's filter tuple into its candidate set
// (marker evaluations + the known/valid/successful/free axes) and
// works ONE remaining host-platform candidate (runFixturesCapture
// runs in-process in the session the daemon launched). The released
// binary (built with -Ddev=false, the default) has none of this — its
// CLI surface is `identify` (JSON report), `trailer co-author` /
// `trailer assisted-by`, `check-reciprocal`, `help`, and
// `version`; no arguments shows help.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const core = @import("../lib/core.zig");
const rules = @import("../lib/rules.zig");

const writeOut = core.writeOut;
const writeErr = core.writeErr;
const Detection = core.Detection;
const Ancestor = core.Ancestor;
const detect = core.detect;
const resolveRecipe = core.resolveRecipe;
const buildCooked = core.buildCooked;
const ancestorInfo = core.ancestorInfo;
const reporterHome = core.reporterHome;
const stringListValue = core.stringListValue;
const optStringValue = core.optStringValue;
const redactHome = core.redactHome;
const jstr = core.jstr;
const jint = core.jint;
const reciprocityOf = core.reciprocityOf;
const readChildOutput = core.readChildOutput;
const OpenProcess = core.OpenProcess;
const TerminateProcess = core.TerminateProcess;
const CloseHandle = core.CloseHandle;
const GetProcessId = core.GetProcessId;

const EXIT_OK = core.EXIT_OK;
const EXIT_UNRECOGNISED_ERROR = core.EXIT_UNRECOGNISED_ERROR;
const EXIT_UNRECOGNISED_ARG = core.EXIT_UNRECOGNISED_ARG;
const EXIT_CONFLICTING_ARG = core.EXIT_CONFLICTING_ARG;
const EXIT_MISSING_ARG = core.EXIT_MISSING_ARG;
const EXIT_ENV_INCOMPATIBLE = core.EXIT_ENV_INCOMPATIBLE;
const EXIT_ENV_INCOMPLETE = core.EXIT_ENV_INCOMPLETE;
const EXIT_MISSING_SPECIFIED_AGENT = core.EXIT_MISSING_SPECIFIED_AGENT;
const EXIT_UNABLE_TO_DETECT = core.EXIT_UNABLE_TO_DETECT;
const EXIT_AGENT_DATA_INCOMPLETE = core.EXIT_AGENT_DATA_INCOMPLETE;
const EXIT_REQUIREMENT_FAILED = core.EXIT_REQUIREMENT_FAILED;
const EXIT_OUT_OF_MEMORY = core.EXIT_OUT_OF_MEMORY;
const EXIT_INDEX_STORE = core.EXIT_INDEX_STORE;
const EXIT_IO = core.EXIT_IO;

const MSG_UNRECOGNISED_ARG = core.MSG_UNRECOGNISED_ARG;
const MSG_CONFLICTING_ARG = core.MSG_CONFLICTING_ARG;
const MSG_MISSING_ARG_COMBO = core.MSG_MISSING_ARG_COMBO;
const MSG_MISSING_ARG_TRAILER_SUBTYPE = core.MSG_MISSING_ARG_TRAILER_SUBTYPE;
const MSG_MISSING_ARG = core.MSG_MISSING_ARG;
const MSG_ENV_INCOMPATIBLE = core.MSG_ENV_INCOMPATIBLE;
const MSG_ENV_INCOMPLETE = core.MSG_ENV_INCOMPLETE;
const MSG_AGENT_DATA_INCOMPLETE = core.MSG_AGENT_DATA_INCOMPLETE;
const MSG_REQUIREMENT_FAILED = core.MSG_REQUIREMENT_FAILED;
const MSG_OUT_OF_MEMORY = core.MSG_OUT_OF_MEMORY;
const MSG_INDEX_STORE = core.MSG_INDEX_STORE;
const MSG_IO = core.MSG_IO;
const writeUnableToDetect = core.writeUnableToDetect;

const HarnessRule = rules.HarnessRule;
const ProviderRule = rules.ProviderRule;
const ModelRule = rules.ModelRule;
const rulesForHarnesses = rules.rulesForHarnesses;
const rulesForProviders = rules.rulesForProviders;
const rulesForModels = rules.rulesForModels;
const canonicalIdFor = rules.canonicalIdFor;
const canonicalFilterDim = rules.canonicalFilterDim;
const envValueAllowed = rules.envValueAllowed;
const slugId = rules.slugId;

/// optional tee target for daemon output; set by `fixtures daemon --write-log`.
var daemon_log_file: ?std.Io.File = null;

/// true when the last daemon stdout write ended in a newline (or no
/// write has happened), so a continuation segment does not repeat the
/// `[sec.ms]` prefix mid-line.
var daemon_log_out_nl: bool = true;
var daemon_log_err_nl: bool = true;

fn daemonWriteTo(io: std.Io, bytes: []const u8, comptime err: bool) void {
    var buf: [64]u8 = undefined;
    const nl = if (err) &daemon_log_err_nl else &daemon_log_out_nl;
    const stream = if (err) std.Io.File.stderr() else std.Io.File.stdout();
    if (nl.*) {
        const ts = std.Io.Clock.Timestamp.now(io, .real);
        const sec = ts.raw.toSeconds();
        const ms = ts.raw.toMilliseconds() - sec * 1000;
        const prefix = std.fmt.bufPrint(buf[0..], "[{d}.{d:0>3}] ", .{ sec, ms }) catch return;
        stream.writeStreamingAll(io, prefix) catch {};
        if (daemon_log_file) |f| f.writeStreamingAll(io, prefix) catch {};
    }
    stream.writeStreamingAll(io, bytes) catch {};
    if (daemon_log_file) |f| f.writeStreamingAll(io, bytes) catch {};
    nl.* = bytes.len == 0 or bytes[bytes.len - 1] == '\n';
}

fn daemonWrite(io: std.Io, bytes: []const u8) void {
    daemonWriteTo(io, bytes, false);
}

fn daemonWriteErr(io: std.Io, bytes: []const u8) void {
    daemonWriteTo(io, bytes, true);
}

/// executable names for harnesses that don't have a rule yet — the
/// daemon guard also refuses to run inside their sessions. Same inline
/// platform-ternary style as the rule values (`+ .exe` on Windows).
const pending_binary_names = if (builtin.os.tag == .windows)
    [_][]const u8{ "claude", "claude.exe", "codex", "codex.exe", "grok", "grok.exe", "gemini", "gemini.exe" }
else
    [_][]const u8{ "claude", "codex", "grok", "gemini" };

/// the launch prompt the daemon interpolates into a row's `prompt_launch`
/// in place of the `"<prompt>"` placeholder (the store saves the
/// placeholder, never the verbatim instruction, so the instruction can
/// evolve without rewriting every row).
const capture_prompt = "run `agent-detect-dev fixtures capture` in the current working directory and report the result";

pub const dev = if (build_options.dev) struct {
    /// dev-struct exposure of the env-value allow-list check so tests
    /// can assert the evidence-redaction decision (the implementation
    /// is the file-level `envValueAllowed`).
    pub fn isEnvValueAllowed(name: []const u8) bool {
        return envValueAllowed(name);
    }

    /// usage text for the `fixtures` subcommand namespace — printed by
    /// `fixtures --help`, bare `fixtures`, and `fixtures help`.
    pub const fixturesUsage =
        \\agent-detect fixtures — manage the fixtures-agent fixture store (dev builds)
        \\
        \\usage: agent-detect fixtures <subcommand> [flags]
        \\
        \\state: fixtures/.index.json is the single committed JSON store —
        \\`fixtures` (the known universe: one object per 4-tuple
        \\harness/provider/model/platform, keyed by the dash-joined fixture id,
        \\carrying the per-platform `prompt_launch`/`version_launch` argv, the
        \\`identity`/`capture` channel ledgers, and the whole-file `fixture_hash`),
        \\`errors` (the failure ledger keyed by dims tuples — an entry exists only
        \\while a combo is failed; success purges it), and `queue` (an array of
        \\filter entries the daemon expands — it never holds concrete work
        \\items). The free axis is sourced from
        \\fixtures/.providers_freemodels.csv (the free-models source of truth).
        \\fixtures/<id>.json are the
        \\generated fixtures — top-level per-channel keys `from-identity` /
        \\`from-capture` / `from-capture-raw`. Writers take an exclusive lock on
        \\fixtures/.index.json.lock and write atomically (temp + rename).
        \\
        \\daemon flags:
        \\  --write-log                 tee daemon output to fixtures/.daemon.log
        \\  --poll-seconds=N            base poll interval (default 5)
        \\  --capture-review-seconds=N  pre/post capture pause (default 15)
        \\  --capture-timeout-seconds=N from-capture worker timeout (default 600)
        \\
        \\control: write pause/resume/stop to fixtures/.daemon.ctl (checked every
        \\~1s; the daemon clears it after acting). Ctrl+C is the graceful stop.
        \\
        \\subcommands (see each subcommand's `--help` for its flags — modes,
        \\markers, and axes are shared and documented once):
        \\  (none), help, --help, -h   this help
        \\  daemon                     expand the queue-entry array (identity
        \\                              entries: declared generation; capture
        \\                              entries: real harness session), one
        \\                              candidate per poll — run as a user,
        \\                              never inside an agent; --write-log also
        \\                              writes all daemon output to
        \\                              fixtures/.daemon.log
        \\  capture                    capture the current session into a single
        \\                              fixtures/<id>.json + its fixtures entry
        \\                              (spawned by the daemon; fixtures only)
        \\  queue                      upsert one queue entry per refresh mode
        \\                              from the given dims/markers/axes (no
        \\                              evaluation; the daemon expands)
        \\  dequeue                    DELETE matching queue entries (filters
        \\                              required; never touches fixtures)
        \\
        \\exit codes: 0 = ok, 2 = unrecognised argument, 3 = conflicting argument,
        \\4 = missing required arguments, 5 = incompatible environment, 6 = incomplete
        \\environment, 8 = unable to detect, 11 = out of memory, 12 = index store error,
        \\13 = filesystem I/O error
        \\
    ;

    /// flags shared by `fixtures queue` and `fixtures dequeue` (modes,
    /// markers, axes). Referenced by both subcommand usages so
    /// the common surface is documented once.
    pub const queueDequeueFlags =
        \\refresh modes (queue stamps entries, dequeue filters them; both together
        \\→ exit 3; no flag → BOTH modes are queued per candidate):
        \\  --from-identity        resolve the declared identification from provided ids —
        \\                    observed; zero tokens; harness binary not required
        \\  --from-capture    launch the real harness so it runs `fixtures capture`
        \\                    in a live model session — token-consuming,
        \\                    user-confirmed only
        \\
        \\filters (at least one required for queue/dequeue):
        \\  --fixture=ID  4-part <h>-<p>-<m>-<platform> id (exact)
        \\  --agent=ID    3-part <h>-<p>-<m> id (platform unfiltered)
        \\  --harness=H   constrain harness to H (any of H/P/M/PLAT)
        \\
        \\markers (at most one; each selects the stale candidates at the daemon's
        \\expansion; marker sweeps require --known):
        \\  --stale-by-missing-entry   fixture files with no store entry — the daemon
        \\                   re-registers them (idempotent)
        \\  --stale-by-missing-fixture store entries whose fixture file is absent
        \\  --stale-by-days=N      mode-scoped age threshold in days
        \\  --stale-by-hours=N     mode-scoped age threshold in hours
        \\  --stale-by-minutes=N   mode-scoped age threshold in minutes — the daemon
        \\                   skips only when the fixture is still age-fresh
        \\  --stale-by-harness-version  capture.harness_version differs from a live
        \\                   version_launch probe
        \\  --stale-by-detect-version   agent_detect_version is NULL or differs from
        \\                   this binary's version
        \\  --stale-by-fixture-hash     fixture_hash differs from the committed
        \\                   file's BLAKE3 (missing = stale)
        \\  --stale-by-channel-hash     identity/capture channel_hash missing or
        \\                   diverged from each other
        \\
        \\axes (stored on the entry as nullable booleans; the pairs are XOR; the
        \\daemon applies defaults at expansion: known=true, valid=true,
        \\successful/free unset):
        \\  --known / --unknown  the fixtures map vs the rule cross-product minus the
        \\                   known maps (the discovery sweep)
        \\  --valid / --invalid  invalid-class error entries are excluded (default)
        \\                   or re-evaluated as candidates
        \\  --successful / --unsuccessful  only no-error candidates vs only
        \\                   unsuccessful-class error entries
        \\  --free / --paid     membership in .providers_freemodels.csv
        \\
    ;

    /// usage for `fixtures queue` — printed by `fixtures queue --help`
    /// and on queue argument errors. Subcommand-scoped so an error never
    /// dumps the whole namespace help.
    pub const queueUsage =
        \\agent-detect fixtures queue — upsert queue entries (no evaluation)
        \\
        \\usage: agent-detect fixtures queue [markers] [axes] [filters] [mode]
        \\
        \\One queue entry per selected mode is upserted from the given dims,
        \\markers, and axes (no mode flag → both `--from-identity` and
        \\`--from-capture` entries). The daemon expands entries — queue never
        \\evaluates. A re-assert of an existing (dims, mode, markers, axes)
        \\tuple replaces the entry in place and resets its `started_at` (a
        \\fresh sweep). At least one filter/marker/axis is required.
        \\
    ++ queueDequeueFlags ++
        \\exit codes: 0 = ok, 2 = unrecognised argument, 3 = conflicting argument,
        \\4 = missing required arguments, 11 = out of memory, 12 = index store error,
        \\13 = filesystem I/O error
        \\
    ;

    /// usage for `fixtures dequeue` — printed by `fixtures dequeue --help`
    /// and on dequeue argument errors.
    pub const dequeueUsage =
        \\agent-detect fixtures dequeue — DELETE matching queue entries (never touches fixtures)
        \\
        \\usage: agent-detect fixtures dequeue [markers] [axes] [filters] [mode]
        \\
        \\Deletes every `queue` entry matching the filters/markers/axes. Filters
        \\are required; no evaluation happens, nothing is captured. Markers/axes
        \\match the stored fields the queue command stamped; no mode flag matches
        \\all modes.
        \\
    ++ queueDequeueFlags ++
        \\exit codes: 0 = ok, 2 = unrecognised argument, 3 = conflicting argument,
        \\4 = missing required arguments, 11 = out of memory, 12 = index store error,
        \\13 = filesystem I/O error
        \\
    ;

    /// true when the args after a `fixtures` subcommand contain a help
    /// flag (`help`, `--help`, `-h`) — lets `fixtures queue --help`
    /// print the subcommand usage instead of an argument error.
    pub fn subcommandWantsHelp(init: std.process.Init) bool {
        const a = init.arena.allocator();
        var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return false;
        defer args_it.deinit();
        _ = args_it.skip(); // argv0
        _ = args_it.skip(); // "fixtures"
        _ = args_it.skip(); // subcommand
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) return true;
        }
        return false;
    }

    /// print the `fixtures` namespace help and exit 0.
    pub fn runFixturesHelp(init: std.process.Init) !u8 {
        const io = init.io;
        writeOut(io, fixturesUsage);
        return 0;
    }

    /// which of the three detection dims actually populated `d`'s
    /// canonical fields (harness_id / provider_id / model_id non-null).
    fn detectedDims(a: std.mem.Allocator, d: *const Detection) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        if (d.harness_id != null) try list.append(a, "harness");
        if (d.provider_id != null) try list.append(a, "provider");
        if (d.model_id != null) try list.append(a, "model");
        return list.toOwnedSlice(a);
    }

    /// build the `raw` observations object (dev binary only). Top-level
    /// keys: `platform_id`, then `harness_version` (the live version
    /// snapshot — null when not yet knowable; only emitted for the
    /// capture path or when a value is present), then the `detectable` +
    /// `detected` dimension arrays adjacent to it, then the shapeless
    /// runtime observations. Returns a heap-allocated `std.json.Value`;
    /// the caller owns it.
    fn buildRaw(a: std.mem.Allocator, d: *const Detection, env: *const std.process.Environ.Map, hver: ?[]const u8, comptime emit_hver_always: bool) !std.json.Value {
        const V = std.json.Value;
        const home = reporterHome(env);
        var raw: V = .{ .object = .empty };
        // platform id (compile-time constant) is emitted as a top-level
        // raw key so a maintainer reading a fixture knows which
        // platform it was captured on, even before they read the
        // canonical `agent_id` (which is also platform-tagged via the
        // `fixture_id` filename).
        try raw.object.put(a, "platform_id", .{ .string = platformId() });
        // harness_version — the live version snapshot of the agent, right
        // after platform_id. The capture path always emits it (null when
        // the agent's version is not yet knowable); the standalone `raw`
        // action only emits it when a value is present.
        if (emit_hver_always or hver != null) {
            try raw.object.put(a, "harness_version", optStringValue(a, hver));
        }
        // `detectable` — the dims this run's ladder/recipe *could*
        // resolve; `detected` — the subset that actually landed in
        // the canonical fields. Emitted adjacent to each other so a reader
        // instantly sees what the fixture claims without scanning
        // the canonical fields.
        try raw.object.put(a, "detectable", stringListValue(a, d.detectable));
        try raw.object.put(a, "detected", stringListValue(a, try detectedDims(a, d)));
        // The `env` object and per-file config/session objects were
        // dropped from the raw block (decision #4 — raw slimming): the
        // evidence section below documents the sources that informed
        // each canonical deduction, so the raw observations are not
        // duplicated verbatim. `RawObservation.env_vars` /
        // `config_files` / `session_files` are still populated internally
        // (detection + the redaction decision in the evidence block rely
        // on them); they just never reach the JSON.

        // process_lineage — always present so a maintainer reading the
        // fixture sees "no process info" rather than absence. The array
        // is ordered most-immediate first (index 0 = the running
        // agent-detect, index 1 = its parent, etc.).
        {
            var lineage: V = .{ .array = std.json.Array.init(a) };
            for (d.raw.process_lineage) |entry_obs| {
                var entry: V = .{ .object = .empty };
                try entry.object.put(a, "pid", .{ .integer = entry_obs.pid });
                try entry.object.put(a, "name", .{ .string = entry_obs.name });
                try lineage.array.append(entry);
            }
            try raw.object.put(a, "process_lineage", lineage);
        }

        // *-urls arrays + static rule declarations
        try raw.object.put(a, "harness-urls", stringListValue(a, d.raw.harness_urls));
        try raw.object.put(a, "provider-urls", stringListValue(a, d.raw.provider_urls));
        try raw.object.put(a, "model-urls", stringListValue(a, d.raw.model_urls));
        // decision #11 — evidence claims, one per detected dim, pinning
        // the attribution chain (source present in raw + value matching
        // the canonical dim). `from-identity` fixtures carry an empty array.
        // Env-source claims on non-allowlisted env vars emit the
        // literal `"<redacted>"` for `value` (decision #3) — the value
        // the detector read was secret-shaped and must not be written to
        // disk; the claim still records the dim/source/name so the
        // attribution chain stays audit-trailable.
        {
            var ev_arr: V = .{ .array = std.json.Array.init(a) };
            for (d.raw.evidence) |claim| {
                var c_obj: V = .{ .object = .empty };
                try c_obj.object.put(a, "dim", .{ .string = claim.dim });
                try c_obj.object.put(a, "source", .{ .string = claim.source });
                try c_obj.object.put(a, "name", .{ .string = try redactHome(a, claim.name, home) });
                if (claim.field) |fld| {
                    try c_obj.object.put(a, "field", .{ .string = fld });
                }
                if (claim.value) |val| {
                    const emitted = if (std.mem.eql(u8, claim.source, "env") and !envValueAllowed(claim.name))
                        "<redacted>"
                    else
                        try redactHome(a, val, home);
                    try c_obj.object.put(a, "value", .{ .string = emitted });
                }
                try ev_arr.array.append(c_obj);
            }
            try raw.object.put(a, "evidence", ev_arr);
        }
        return raw;
    }

    /// dev-only `raw` action — emit only the raw observations block
    /// (standalone, with `detectable` + `detected`). Data-output action:
    /// identity unresolved → exit 8 with no stdout (no sensible data);
    /// identity complete but reciprocity/policy data incomplete → exit 9
    /// with the raw block on stdout + a stderr explainer; full identity →
    /// exit 0.
    pub fn runRawAction(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;
        var d = Detection{};
        const ok = try detect(init, &d);
        const raw_v = try buildRaw(a, &d, init.environ_map, d.harness_version, false);
        const json_bytes = try std.json.Stringify.valueAlloc(a, raw_v, .{ .whitespace = .indent_2 });
        defer a.free(json_bytes);
        if (!ok) {
            writeUnableToDetect(io, d.harness_id, d.provider_id, d.model_id);
            return EXIT_UNABLE_TO_DETECT;
        }
        writeOut(io, json_bytes);
        writeOut(io, "\n");
        if (reciprocityOf(&d) == .unknown) {
            writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
            return EXIT_AGENT_DATA_INCOMPLETE;
        }
        return EXIT_OK;
    }

    // ------------------------------------------------------------------
    // index.json state store (fixtures map + errors ledger + queue array)
    // ------------------------------------------------------------------

    const INDEX_PATH = "fixtures/.index.json";
    const INDEX_LOCK_PATH = "fixtures/.index.json.lock";
    const INDEX_TMP_PATH = "fixtures/.index.json.tmp";
    const INDEX_STORE_VERSION: i64 = 1;
    const INDEX_LOCK_BUDGET_MS: u64 = 5000;
    const INDEX_LOCK_RETRY_MS: u64 = 50;

    /// the canonical platforms of the fixtures universe.
    const platforms_all = [_][]const u8{ "darwin", "linux", "windows" };

    /// current unix epoch seconds (staleness source / ledger stamps).
    fn unixNow(io: std.Io) i64 {
        const ts = std.Io.Clock.Timestamp.now(io, .real);
        return ts.raw.toSeconds();
    }

    /// fresh default store root (missing index.json → this).
    fn emptyRoot(a: std.mem.Allocator) !std.json.Value {
        var root: std.json.Value = .{ .object = .empty };
        try root.object.put(a, "store_version", .{ .integer = INDEX_STORE_VERSION });
        try root.object.put(a, "fixtures", .{ .object = .empty });
        try root.object.put(a, "errors", .{ .object = .empty });
        try root.object.put(a, "queue", .{ .array = std.json.Array.init(a) });
        return root;
    }

    /// acquire the exclusive lock on `fixtures/.index.json.lock` (creating
    /// it when missing). Retries with `tryLock` on a ~5s budget (the
    /// busy-timeout the old store shelled out to), sleeping 50ms between
    /// attempts. Kernel-managed locks release on exit/crash — no
    /// stale-lock heuristics. Caller owns the returned file; closing it
    /// unlocks.
    fn acquireIndexLock(io: std.Io) !std.Io.File {
        std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.FilesystemIoError,
        };
        const lock_file = std.Io.Dir.cwd().createFile(io, INDEX_LOCK_PATH, .{}) catch return error.FilesystemIoError;
        errdefer lock_file.close(io);
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, INDEX_LOCK_BUDGET_MS) * std.time.ns_per_ms }, .clock = .boot });
        while (true) {
            if (lock_file.tryLock(io, .exclusive) catch return error.FilesystemIoError) break;
            const now = std.Io.Clock.Timestamp.now(io, .boot);
            if (now.raw.nanoseconds >= deadline.raw.nanoseconds) return error.IndexStoreLockTimeout;
            std.Io.sleep(io, .{ .nanoseconds = INDEX_LOCK_RETRY_MS * std.time.ns_per_ms }, .boot) catch return error.IndexStoreLockTimeout;
        }
        return lock_file;
    }

    /// parse `fixtures/.index.json` into a `std.json.Value` tree. Missing
    /// file → the empty store; corrupt/unparseable/unknown `store_version`
    /// → `error.IndexStoreError` (exit 12). Readers take no lock (the
    /// temp+rename write protocol makes visibility atomic).
    fn indexLoad(io: std.Io, a: std.mem.Allocator) !std.json.Value {
        const data = std.Io.Dir.cwd().readFileAlloc(io, INDEX_PATH, a, @enumFromInt(1 << 26)) catch |err| switch (err) {
            error.FileNotFound => return emptyRoot(a),
            else => return error.IndexStoreError,
        };
        var parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return error.IndexStoreError;
        if (parsed.value != .object) return error.IndexStoreError;
        const sv = parsed.value.object.get("store_version") orelse return error.IndexStoreError;
        if (sv != .integer or sv.integer != INDEX_STORE_VERSION) return error.IndexStoreError;
        // The free axis moved to fixtures/.providers_freemodels.csv —
        // drop the legacy table so it never re-serializes.
        _ = parsed.value.object.orderedRemove("free_provider_to_model");
        return parsed.value;
    }

    /// serialize `root` and atomically write it over `fixtures/.index.json`
    /// (temp + rename). Called while holding the exclusive lock.
    fn indexSave(io: std.Io, a: std.mem.Allocator, root: std.json.Value) !void {
        const json_bytes = std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 }) catch return error.IndexStoreError;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = INDEX_TMP_PATH, .data = json_bytes }) catch return error.FilesystemIoError;
        std.Io.Dir.rename(std.Io.Dir.cwd(), INDEX_TMP_PATH, std.Io.Dir.cwd(), INDEX_PATH, io) catch return error.FilesystemIoError;
    }

    /// get-or-create the object under `root[key]`.
    fn getOrPutObject(a: std.mem.Allocator, root: *std.json.Value, key: []const u8) !*std.json.ObjectMap {
        if (root.* != .object) return error.IndexStoreError;
        const gop = try root.object.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .object = .empty };
        if (gop.value_ptr.* != .object) return error.IndexStoreError;
        return &gop.value_ptr.object;
    }

    /// get-or-create the array under `root[key]`.
    fn getOrPutArray(a: std.mem.Allocator, root: *std.json.Value, key: []const u8) !*std.json.Array {
        if (root.* != .object) return error.IndexStoreError;
        const gop = try root.object.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .array = std.json.Array.init(a) };
        if (gop.value_ptr.* != .array) return error.IndexStoreError;
        return &gop.value_ptr.array;
    }

    // ------------------------------------------------------------------
    // store data shapes
    // ------------------------------------------------------------------

    /// One entry in the `fixtures` map — a 4-tuple row. The map key IS
    /// the dash-joined fixture id (`h-p-m-platform`, == the filename
    /// stem); dims are never repeated inside the row. `identity` /
    /// `capture` are the per-channel ledgers (written by the channel's
    /// writer); `prompt_launch`/`version_launch` are the curated argv
    /// (absent ⇒ from-identity-only / no version probe); `fixture_hash`
    /// is the BLAKE3 of the whole fixture file, stamped by every file
    /// writer. There is no row-level timestamp — age checks are
    /// mode-scoped on the channel dates.
    pub const FixtureRow = struct {
        key: []const u8 = "",
        harness: []const u8 = "",
        provider: []const u8 = "",
        model: []const u8 = "",
        platform: []const u8 = "",
        runner: i64 = 0,
        agent_detect_version: ?[]const u8 = null,
        declared_at: ?i64 = null, // identity.declared_at
        identity_channel_hash: ?[]const u8 = null,
        captured_at: ?i64 = null, // capture.captured_at
        capture_channel_hash: ?[]const u8 = null,
        harness_version: ?[]const u8 = null, // capture.harness_version
        fixture_hash: ?[]const u8 = null,
        prompt_launch: ?[]const []const u8 = null,
        version_launch: ?[]const []const u8 = null,
    };

    /// One entry in the `queue` array — a filter tuple, never a concrete
    /// work item (only the daemon expands). Dims are nullable filters.
    /// The seven flat marker fields are mutually exclusive ("at most one
    /// set" — enforced by `validateQueueEntry`); `known`/`valid`/
    /// `successful`/`free` are nullable affirmative booleans (null =
    /// unset; the daemon applies defaults at expansion). `started_at` is
    /// stamped by the daemon on first work of the entry — the pop
    /// protocol's comparison anchor; there is no `finished_at`
    /// (fully-satisfied entries are purged).
    pub const QueueEntry = struct {
        harness: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        model: ?[]const u8 = null,
        platform: ?[]const u8 = null,
        mode: []const u8 = "",
        stale_by_missing_entry: ?bool = null,
        stale_by_missing_fixture: ?bool = null,
        stale_by_minutes: ?i64 = null,
        stale_by_harness_version: ?bool = null,
        stale_by_detect_version: ?bool = null,
        stale_by_fixture_hash: ?bool = null,
        stale_by_channel_hash: ?bool = null,
        known: ?bool = null,
        valid: ?bool = null,
        successful: ?bool = null,
        free: ?bool = null,
        runner: i64 = 0,
        started_at: ?i64 = null,
    };

    /// One entry in the `errors` ledger — the failure record. An entry
    /// exists only while the combo is failed/broken; a successful
    /// capture/declaration purges it (entry presence is the outcome
    /// signal). `reason` is from the closed set partitioned by class
    /// (see `errorReasonClass`); `failed_at` is the completion timestamp
    /// the pop protocol and the filter axes compare against.
    pub const ErrorEntry = struct {
        reason: []const u8,
        failed_at: i64,
    };

    /// the two error classes the filter axes classify on.
    pub const ErrorClass = enum { unsuccessful, invalid };

    /// the errors ledger's closed reason set, partitioned by class:
    /// - `unsuccessful` — the combo has a fixture row, last evaluation
    ///   failed: "capture failed", "unavailable", "post-check mismatch"
    /// - `invalid` — structural breakage, error-only: "no launch spec",
    ///   "unknown fixture file", "malformed fixture id",
    ///   "malformed queue row"
    /// Unknown reasons (hand-edited store) classify as `invalid` — they
    /// are excluded by the default `valid=true` axis and only re-evaluated
    /// with `--invalid`.
    pub fn errorReasonClass(reason: []const u8) ErrorClass {
        if (std.mem.eql(u8, reason, "capture failed") or
            std.mem.eql(u8, reason, "unavailable") or
            std.mem.eql(u8, reason, "post-check mismatch")) return .unsuccessful;
        return .invalid;
    }

    /// one expanded candidate for a queue entry (a concrete 4-tuple).
    /// Unknown dims (`""`) only appear for invalid-stem files under
    /// `--stale-by-missing-entry`.
    pub const Candidate = struct {
        fixture_id: []const u8,
        harness: []const u8 = "",
        provider: []const u8 = "",
        model: []const u8 = "",
        platform: []const u8 = "",
    };

    /// the expansion outcome for one queue entry: the remaining
    /// host-platform candidates (sorted by fixture id) plus the count of
    /// remaining candidates across ALL platforms (`remaining_anywhere ==
    /// 0` ⇒ delete the entry; host candidates empty but others remaining
    /// ⇒ keep the entry — another host's portion).
    pub const ExpandResult = struct {
        host_candidates: []Candidate,
        remaining_anywhere: usize,
    };

    /// a picked daemon job: the queue entry's index, the candidate to
    /// work, and the entry itself (mode + description).
    const DaemonPick = struct {
        queue_index: usize,
        candidate: Candidate,
        entry: QueueEntry,
    };

    /// the field-set updates a fixture-row writer may apply (capture /
    /// identity channel writes, and the missing-entry registration pass).
    pub const FixtureUpdate = union(enum) {
        capture: struct {
            runner: i64,
            agent_detect_version: ?[]const u8,
            captured_at: i64,
            channel_hash: []const u8,
            harness_version: ?[]const u8,
            fixture_hash: []const u8,
        },
        identity: struct {
            runner: i64,
            agent_detect_version: ?[]const u8,
            declared_at: i64,
            channel_hash: []const u8,
            fixture_hash: []const u8,
        },
        registration: struct {
            runner: i64,
            fixture_hash: []const u8,
            identity_channel_hash: ?[]const u8,
            capture_channel_hash: ?[]const u8,
        },
    };

    /// bool field; missing/non-bool → null.
    fn jbool(o: std.json.ObjectMap, key: []const u8) ?bool {
        const v = o.get(key) orelse return null;
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }

    /// string field; missing → "".
    fn sjstr(o: std.json.ObjectMap, key: []const u8) []const u8 {
        const v = o.get(key) orelse return "";
        return switch (v) {
            .string => |s| s,
            else => "",
        };
    }

    /// int field; missing/non-int → 0.
    fn sjint(o: std.json.ObjectMap, key: []const u8) i64 {
        return jint(o, key) orelse 0;
    }

    fn optBoolValue(v: ?bool) std.json.Value {
        if (v) |b| return .{ .bool = b };
        return .null;
    }

    fn optStrEq(x: ?[]const u8, y: ?[]const u8) bool {
        if (x == null or y == null) return x == null and y == null;
        return std.mem.eql(u8, x.?, y.?);
    }

    /// optional string-array field; missing/non-array → null.
    fn stringArrayFromValue(a: std.mem.Allocator, v: ?std.json.Value) ?[]const []const u8 {
        const arr = (v orelse return null);
        if (arr != .array) return null;
        const out = a.alloc([]const u8, arr.array.items.len) catch return null;
        for (arr.array.items, 0..) |item, i| {
            if (item != .string) return null;
            out[i] = item.string;
        }
        return out;
    }

    /// the errors-ledger key for a dims tuple: dash-joined with the
    /// literal `null` for each unknown dim (e.g. `cline-null-null-windows`,
    /// all-unknown → `null-null-null-null`).
    fn errorKey(a: std.mem.Allocator, h: ?[]const u8, p: ?[]const u8, m: ?[]const u8, plat: ?[]const u8) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        const dims = [_]?[]const u8{ h, p, m, plat };
        for (dims, 0..) |d, i| {
            if (i > 0) try list.append(a, '-');
            if (d) |v| {
                if (v.len > 0) try list.appendSlice(a, v) else try list.appendSlice(a, "null");
            } else try list.appendSlice(a, "null");
        }
        return list.toOwnedSlice(a);
    }

    /// the errors entry for a dims-tuple key (a full-dims fixture id is
    /// its own key), or null.
    fn errorEntryFor(root: *const std.json.Value, key: []const u8) ?ErrorEntry {
        if (root.* != .object) return null;
        const errors = root.object.get("errors") orelse return null;
        if (errors != .object) return null;
        const v = errors.object.get(key) orelse return null;
        if (v != .object) return null;
        return .{ .reason = sjstr(v.object, "reason"), .failed_at = sjint(v.object, "failed_at") };
    }

    fn fixturesHas(root: *const std.json.Value, key: []const u8) bool {
        if (root.* != .object) return false;
        const fx = root.object.get("fixtures") orelse return false;
        if (fx != .object) return false;
        return fx.object.contains(key);
    }

    /// Free-model membership, sourced from
    /// `fixtures/.providers_freemodels.csv` — the source of truth for
    /// free models (replacing the
    /// legacy `free_provider_to_model` store table, which is dropped at
    /// load and never re-serialized). Sparse grid: header
    /// `provider,<model-slug>...`, rows only for providers with ≥1 free
    /// model, columns only for models free somewhere, cells the
    /// provider's free model-id string, `-` where not offered. A missing
    /// file loads as the empty set.
    pub const FreeGrid = struct {
        set: std.StringHashMap(void),

        pub fn empty(a: std.mem.Allocator) FreeGrid {
            return .{ .set = std.StringHashMap(void).init(a) };
        }

        pub fn put(self: *FreeGrid, a: std.mem.Allocator, provider: []const u8, model: []const u8) !void {
            try self.set.put(try std.fmt.allocPrint(a, "{s}|{s}", .{ provider, model }), {});
        }

        pub fn has(self: *const FreeGrid, provider: []const u8, model: []const u8) bool {
            var buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ provider, model }) catch return false;
            return self.set.contains(key);
        }

        pub fn load(io: std.Io, a: std.mem.Allocator) !FreeGrid {
            var self = empty(a);
            const data = std.Io.Dir.cwd().readFileAlloc(io, "fixtures/.providers_freemodels.csv", a, @enumFromInt(1 << 20)) catch return self;
            var lines = std.mem.tokenizeScalar(u8, data, '\n');
            const header = lines.next() orelse return self;
            var cols = std.mem.tokenizeScalar(u8, header, ',');
            _ = cols.next(); // the "provider" label cell
            var names: std.ArrayList([]const u8) = .empty;
            while (cols.next()) |c| try names.append(a, std.mem.trim(u8, c, " \r\t"));
            while (lines.next()) |line| {
                var cells = std.mem.tokenizeScalar(u8, line, ',');
                const provider = std.mem.trim(u8, cells.next() orelse continue, " \r\t");
                var idx: usize = 0;
                while (cells.next()) |cell| : (idx += 1) {
                    if (idx >= names.items.len) break;
                    const v = std.mem.trim(u8, cell, " \r\t");
                    if (v.len == 0 or std.mem.eql(u8, v, "-")) continue;
                    try self.put(a, provider, names.items[idx]);
                }
            }
            return self;
        }
    };

    // ------------------------------------------------------------------
    // id splitting / joining
    // ------------------------------------------------------------------

    /// Split a `-`-separated composite id into exactly `n` non-empty
    /// segments. Each returned slice is a fresh allocation the caller
    /// owns. Returns `error.InvalidSegmentCount` on any malformed
    /// input — the typed wrappers below re-map it so call sites keep
    /// distinguishing `error.InvalidAgentId` (3-part) from
    /// `error.InvalidFixtureId` (4-part) in their messages.
    fn splitId(a: std.mem.Allocator, id: []const u8, comptime n: usize) ![n][]u8 {
        var it = std.mem.tokenizeScalar(u8, id, '-');
        var parts: [n][]u8 = undefined;
        for (0..n) |i| {
            const seg = it.next() orelse return error.InvalidSegmentCount;
            if (seg.len == 0) return error.InvalidSegmentCount;
            parts[i] = try a.dupe(u8, seg);
        }
        if (it.next() != null) return error.InvalidSegmentCount;
        return parts;
    }

    /// Split an `agent_id` into its three sub-ids.
    fn splitAgentId(a: std.mem.Allocator, agent: []const u8) ![3][]u8 {
        return splitId(a, agent, 3) catch return error.InvalidAgentId;
    }

    /// Split a `fixture_id` (the h-p-m-platform composite) into
    /// its four sub-ids.
    fn splitFixtureId(a: std.mem.Allocator, fixtures: []const u8) ![4][]u8 {
        return splitId(a, fixtures, 4) catch return error.InvalidFixtureId;
    }

    /// join `parts` with `sep` into one allocated string. Caller owns.
    fn joinId(a: std.mem.Allocator, sep: []const u8, parts: []const []const u8) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        for (parts, 0..) |p, i| {
            if (i > 0) try list.appendSlice(a, sep);
            try list.appendSlice(a, p);
        }
        return list.toOwnedSlice(a);
    }

    /// Compose an `agent_id` (h-p-m) from the three dims.
    /// Returns null when any dim is missing (never a fabricated partial
    /// id). Used for fixture naming and messaging only — never stored.
    fn agentIdFrom(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8) !?[]u8 {
        if (h.len == 0 or p.len == 0 or m.len == 0) return null;
        return @as(?[]u8, try joinId(a, "-", &.{ h, p, m }));
    }

    /// Compose a `fixture_id` (h-p-m-platform) from the four
    /// dims. Returns null when any dim is missing (never a fabricated
    /// partial id). Used for fixture naming and messaging only — never
    /// stored.
    fn fixtureIdFrom(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !?[]u8 {
        if (h.len == 0 or p.len == 0 or m.len == 0 or plat.len == 0) return null;
        return @as(?[]u8, try joinId(a, "-", &.{ h, p, m, plat }));
    }

    /// BLAKE3 (std-only, no package) of the given bytes, hex-lowercase
    /// (64 chars). Caller owns the returned slice.
    fn generationHash(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(bytes, &digest, .{});
        return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    }

    /// canonical serialization of a per-channel object (`identify` +
    /// both trailer variants) — the single source of truth for BOTH
    /// writing a channel into a fixture file AND computing its
    /// channel hash, so the two can never diverge. Caller owns.
    fn channelJson(a: std.mem.Allocator, identify: std.json.Value, co_author: ?[]const u8, assisted_by: ?[]const u8) ![]u8 {
        var ch: std.json.Value = .{ .object = .empty };
        try ch.object.put(a, "identify", identify);
        try ch.object.put(a, "trailer co-author", optStringValue(a, co_author));
        try ch.object.put(a, "trailer assisted-by", optStringValue(a, assisted_by));
        return std.json.Stringify.valueAlloc(a, ch, .{ .whitespace = .indent_2 });
    }

    /// spawn the current executable's `trailer <subtype>` action and
    /// return its stdout, trimmed (single-line string). Empty `combo_h`
    /// = bare run (session-env detection); non-empty = recipe-mode combo
    /// flags. Returns null on any failure.
    fn spawnTrailerLine(a: std.mem.Allocator, io: std.Io, self_path: []const u8, subtype: []const u8, combo_h: []const u8, combo_p: []const u8, combo_m: []const u8) !?[]const u8 {
        var argv_buf: [8][]const u8 = undefined;
        var n: usize = 0;
        argv_buf[n] = self_path;
        n += 1;
        argv_buf[n] = "trailer";
        n += 1;
        argv_buf[n] = subtype;
        n += 1;
        if (combo_h.len > 0) {
            argv_buf[n] = try std.fmt.allocPrint(a, "--harness={s}", .{combo_h});
            n += 1;
            argv_buf[n] = try std.fmt.allocPrint(a, "--provider={s}", .{combo_p});
            n += 1;
            argv_buf[n] = try std.fmt.allocPrint(a, "--model={s}", .{combo_m});
            n += 1;
        }
        const argv = argv_buf[0..n];
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return null;
        const out = readChildOutput(a, io, child, false) catch return null;
        defer a.free(out);
        const term = child.wait(io) catch return null;
        if (term != .exited or term.exited != 0) return null;
        const t = std.mem.trim(u8, out, " \t\r\n");
        if (t.len == 0) return null;
        return @as(?[]const u8, try a.dupe(u8, t));
    }

    /// merge-write channels into `fixtures/<f_id>.json`: load the
    /// existing root object (when present + parseable), replace only the
    /// given top-level keys, and atomically replace the file
    /// (temp + rename). On any failure the previous file is untouched.
    /// Returns the serialized root bytes (the exact file contents
    /// written) so callers can stamp `fixture_hash` from them. Caller
    /// owns the returned slice.
    fn mergeWriteFixture(a: std.mem.Allocator, io: std.Io, f_id: []const u8, keys: []const []const u8, values: []const std.json.Value) ![]u8 {
        const path = try std.fmt.allocPrint(a, "fixtures/{s}.json", .{f_id});
        defer a.free(path);
        var root: std.json.Value = .{ .object = .empty };
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 24)) catch null;
        if (data) |d| {
            defer a.free(d);
            const parsed = std.json.parseFromSlice(std.json.Value, a, d, .{}) catch null;
            if (parsed) |p| {
                if (p.value == .object) root = p.value;
            }
        }
        for (keys, values) |k, v| {
            try root.object.put(a, k, v);
        }
        const json_bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
        std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.FilesystemIoError,
        };
        const tmp_path = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
        defer a.free(tmp_path);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json_bytes }) catch return error.FilesystemIoError;
        std.Io.Dir.rename(std.Io.Dir.cwd(), tmp_path, std.Io.Dir.cwd(), path, io) catch return error.FilesystemIoError;
        return json_bytes;
    }

    /// parse a channel object (`from-identity` / `from-capture`) out of
    /// a fixture file, or null when the file or channel key is missing.
    fn readChannelObject(a: std.mem.Allocator, io: std.Io, f_id: []const u8, channel: []const u8) !?std.json.Value {
        const path = try std.fmt.allocPrint(a, "fixtures/{s}.json", .{f_id});
        defer a.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 24)) catch return null;
        // no `a.free(data)` — the returned channel Value aliases `data`
        // (Zig 0.16 arena free-list would reclaim it into the caller's
        // next allocations, clobbering the channel mid-use).
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return null;
        if (parsed.value != .object) return null;
        const ch = parsed.value.object.get(channel) orelse return null;
        if (ch != .object) return null;
        return ch;
    }

    /// the whole `fixtures/<f_id>.json` bytes, or null when the file is
    /// absent/unreadable.
    fn fixtureFileBytes(io: std.Io, a: std.mem.Allocator, f_id: []const u8) ?[]u8 {
        const path = std.fmt.allocPrint(a, "fixtures/{s}.json", .{f_id}) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 24)) catch null;
    }

    // ------------------------------------------------------------------
    // launch / version probe helpers
    // ------------------------------------------------------------------

    /// spawn `launch` verbatim (curated per-row argv) and return whether
    /// it exits 0 — the availability probe.
    fn launchExitZero(io: std.Io, a: std.mem.Allocator, launch: []const []const u8) bool {
        var child = std.process.spawn(io, .{
            .argv = launch,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return false;
        const out = readChildOutput(a, io, child, false) catch return false;
        a.free(out);
        const term = child.wait(io) catch return false;
        return term == .exited and term.exited == 0;
    }

    /// run the row's `version_launch` and return the first version token
    /// its stdout yields, or null when it doesn't run or no token
    /// matches. Zero-token: version calls invoke the harness binary
    /// directly, they never touch a model API.
    fn launchVersion(io: std.Io, a: std.mem.Allocator, launch: []const []const u8) ?[]const u8 {
        var child = std.process.spawn(io, .{
            .argv = launch,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return null;
        const out = readChildOutput(a, io, child, false) catch return null;
        defer a.free(out);
        const term = child.wait(io) catch return null;
        if (term != .exited or term.exited != 0) return null;
        if (scanVersionToken(out)) |tok| {
            return a.dupe(u8, tok) catch null;
        }
        return null;
    }

    /// extract the first version token from a `--version` stdout capture.
    /// The scanner matches `\d+(\.\d+)+([-+][0-9A-Za-z.-]+)?` — verified
    /// against every harness's `--version` format (bare semver, `v`-prefixed,
    /// `/`-separated, multi-line, calver+hash). Returns null when no token
    /// matches.
    pub fn scanVersionToken(s: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < s.len) {
            if (!std.ascii.isDigit(s[i])) {
                i += 1;
                continue;
            }
            const start = i;
            i += 1;
            var groups: usize = 1;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            while (i < s.len and s[i] == '.' and i + 1 < s.len and std.ascii.isDigit(s[i + 1])) {
                groups += 1;
                i += 2;
                while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            }
            if (groups >= 2) {
                if (i < s.len and (s[i] == '-' or s[i] == '+')) {
                    i += 1;
                    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '.' or s[i] == '-')) i += 1;
                }
                return s[start..i];
            }
        }
        return null;
    }

    // ------------------------------------------------------------------
    // store pure operations (value shaping — no I/O)
    // ------------------------------------------------------------------

    fn queueEntryValue(a: std.mem.Allocator, e: QueueEntry) !std.json.Value {
        // Null-as-absent: unset optional fields are omitted from the
        // store (the reader treats missing as null), keeping the
        // committed JSON free of `: null` bloat. Structure source of
        // truth: `fixtures/.index.d.ts`.
        var o: std.json.Value = .{ .object = .empty };
        if (e.harness) |v| try o.object.put(a, "harness", .{ .string = v });
        if (e.provider) |v| try o.object.put(a, "provider", .{ .string = v });
        if (e.model) |v| try o.object.put(a, "model", .{ .string = v });
        if (e.platform) |v| try o.object.put(a, "platform", .{ .string = v });
        try o.object.put(a, "mode", .{ .string = e.mode });
        if (e.stale_by_missing_entry) |v| try o.object.put(a, "stale_by_missing_entry", .{ .bool = v });
        if (e.stale_by_missing_fixture) |v| try o.object.put(a, "stale_by_missing_fixture", .{ .bool = v });
        if (e.stale_by_minutes) |v| try o.object.put(a, "stale_by_minutes", .{ .integer = v });
        if (e.stale_by_harness_version) |v| try o.object.put(a, "stale_by_harness_version", .{ .bool = v });
        if (e.stale_by_detect_version) |v| try o.object.put(a, "stale_by_detect_version", .{ .bool = v });
        if (e.stale_by_fixture_hash) |v| try o.object.put(a, "stale_by_fixture_hash", .{ .bool = v });
        if (e.stale_by_channel_hash) |v| try o.object.put(a, "stale_by_channel_hash", .{ .bool = v });
        if (e.known) |v| try o.object.put(a, "known", .{ .bool = v });
        if (e.valid) |v| try o.object.put(a, "valid", .{ .bool = v });
        if (e.successful) |v| try o.object.put(a, "successful", .{ .bool = v });
        if (e.free) |v| try o.object.put(a, "free", .{ .bool = v });
        try o.object.put(a, "runner", .{ .integer = e.runner });
        if (e.started_at) |v| try o.object.put(a, "started_at", .{ .integer = v });
        return o;
    }

    fn queueEntryFromValue(a: std.mem.Allocator, v: std.json.Value) !QueueEntry {
        _ = a;
        if (v != .object) return error.IndexStoreError;
        const o = v.object;
        return .{
            .harness = jstr(o, "harness"),
            .provider = jstr(o, "provider"),
            .model = jstr(o, "model"),
            .platform = jstr(o, "platform"),
            .mode = sjstr(o, "mode"),
            .stale_by_missing_entry = jbool(o, "stale_by_missing_entry"),
            .stale_by_missing_fixture = jbool(o, "stale_by_missing_fixture"),
            .stale_by_minutes = jint(o, "stale_by_minutes"),
            .stale_by_harness_version = jbool(o, "stale_by_harness_version"),
            .stale_by_detect_version = jbool(o, "stale_by_detect_version"),
            .stale_by_fixture_hash = jbool(o, "stale_by_fixture_hash"),
            .stale_by_channel_hash = jbool(o, "stale_by_channel_hash"),
            .known = jbool(o, "known"),
            .valid = jbool(o, "valid"),
            .successful = jbool(o, "successful"),
            .free = jbool(o, "free"),
            .runner = sjint(o, "runner"),
            .started_at = jint(o, "started_at"),
        };
    }

    /// the shared validator — single source of truth for valid queue
    /// entries. Called by BOTH the queue writer and the daemon reader.
    /// An entry carries at most one flat marker (missing-entry /
    /// missing-fixture / one staleness unit), markers are true|null,
    /// `stale_by_minutes` (when set) is ≥ 1, and the mode is one of the
    /// two refresh flavours. The axis values are nullable booleans —
    /// the XOR pairs are a CLI-level conflict (exit 3), not a stored
    /// shape.
    pub fn validateQueueEntry(e: QueueEntry) !void {
        if (!std.mem.eql(u8, e.mode, "from-identity") and !std.mem.eql(u8, e.mode, "from-capture")) return error.InvalidQueueRow;
        const marker_count = @as(usize, @intFromBool(e.stale_by_missing_entry == true)) +
            @as(usize, @intFromBool(e.stale_by_missing_fixture == true)) +
            @as(usize, @intFromBool(e.stale_by_minutes != null)) +
            @as(usize, @intFromBool(e.stale_by_harness_version == true)) +
            @as(usize, @intFromBool(e.stale_by_detect_version == true)) +
            @as(usize, @intFromBool(e.stale_by_fixture_hash == true)) +
            @as(usize, @intFromBool(e.stale_by_channel_hash == true));
        if (marker_count > 1) return error.InvalidQueueRow;
        if (e.stale_by_minutes != null and e.stale_by_minutes.? < 1) return error.InvalidQueueRow;
        const flags = [_]?bool{
            e.stale_by_missing_entry,   e.stale_by_missing_fixture,
            e.stale_by_harness_version, e.stale_by_detect_version,
            e.stale_by_fixture_hash,    e.stale_by_channel_hash,
        };
        for (flags) |s| {
            if (s != null and !s.?) return error.InvalidQueueRow;
        }
    }

    /// the dedupe tuple: everything except `runner`/`started_at`.
    fn queueEntryTupleEqual(x: QueueEntry, y: QueueEntry) bool {
        return optStrEq(x.harness, y.harness) and
            optStrEq(x.provider, y.provider) and
            optStrEq(x.model, y.model) and
            optStrEq(x.platform, y.platform) and
            std.mem.eql(u8, x.mode, y.mode) and
            x.stale_by_missing_entry == y.stale_by_missing_entry and
            x.stale_by_missing_fixture == y.stale_by_missing_fixture and
            x.stale_by_minutes == y.stale_by_minutes and
            x.stale_by_harness_version == y.stale_by_harness_version and
            x.stale_by_detect_version == y.stale_by_detect_version and
            x.stale_by_fixture_hash == y.stale_by_fixture_hash and
            x.stale_by_channel_hash == y.stale_by_channel_hash and
            x.known == y.known and
            x.valid == y.valid and
            x.successful == y.successful and
            x.free == y.free;
    }

    /// upsert a queue entry: a re-assert of an existing tuple replaces
    /// the entry in place (fresh `started_at` = null — a fresh sweep);
    /// otherwise the entry is appended.
    pub fn queueUpsertPure(a: std.mem.Allocator, root: *std.json.Value, entry: QueueEntry) !void {
        const q = try getOrPutArray(a, root, "queue");
        const value = try queueEntryValue(a, entry);
        for (q.items, 0..) |item, i| {
            const existing = queueEntryFromValue(a, item) catch continue;
            if (queueEntryTupleEqual(entry, existing)) {
                q.items[i] = value;
                return;
            }
        }
        try q.append(value);
    }

    /// parse a `fixtures`-map value into a `FixtureRow` view (the dims
    /// come from the key; the row never repeats them).
    fn fixtureRowFromMap(a: std.mem.Allocator, key: []const u8, v: std.json.Value) !?FixtureRow {
        if (v != .object) return null;
        const parts = splitFixtureId(a, key) catch return null;
        const o = v.object;
        var row = FixtureRow{
            .key = key,
            .harness = parts[0],
            .provider = parts[1],
            .model = parts[2],
            .platform = parts[3],
            .runner = sjint(o, "runner"),
            .agent_detect_version = jstr(o, "agent_detect_version"),
            .fixture_hash = jstr(o, "fixture_hash"),
            .prompt_launch = stringArrayFromValue(a, o.get("prompt_launch")),
            .version_launch = stringArrayFromValue(a, o.get("version_launch")),
        };
        const identity = o.get("identity");
        if (identity != null and identity.? == .object) {
            row.declared_at = jint(identity.?.object, "declared_at");
            row.identity_channel_hash = jstr(identity.?.object, "channel_hash");
        }
        const capture = o.get("capture");
        if (capture != null and capture.? == .object) {
            row.captured_at = jint(capture.?.object, "captured_at");
            row.capture_channel_hash = jstr(capture.?.object, "channel_hash");
            row.harness_version = jstr(capture.?.object, "harness_version");
        }
        return row;
    }

    /// serialize a `FixtureRow` into its map value (absent ledger
    /// fields are omitted; `runner` 0 = never written).
    fn fixtureRowValue(a: std.mem.Allocator, row: FixtureRow) !std.json.Value {
        var o: std.json.Value = .{ .object = .empty };
        if (row.runner != 0) try o.object.put(a, "runner", .{ .integer = row.runner });
        if (row.agent_detect_version) |v| try o.object.put(a, "agent_detect_version", .{ .string = v });
        if (row.declared_at != null or row.identity_channel_hash != null) {
            var ident: std.json.Value = .{ .object = .empty };
            if (row.declared_at) |t| try ident.object.put(a, "declared_at", .{ .integer = t });
            if (row.identity_channel_hash) |hsh| try ident.object.put(a, "channel_hash", .{ .string = hsh });
            try o.object.put(a, "identity", ident);
        }
        if (row.captured_at != null or row.capture_channel_hash != null or row.harness_version != null) {
            var cap: std.json.Value = .{ .object = .empty };
            if (row.captured_at) |t| try cap.object.put(a, "captured_at", .{ .integer = t });
            if (row.capture_channel_hash) |hsh| try cap.object.put(a, "channel_hash", .{ .string = hsh });
            if (row.harness_version) |hv| try cap.object.put(a, "harness_version", .{ .string = hv });
            try o.object.put(a, "capture", cap);
        }
        if (row.fixture_hash) |hsh| try o.object.put(a, "fixture_hash", .{ .string = hsh });
        if (row.prompt_launch) |pl| try o.object.put(a, "prompt_launch", stringListValue(a, pl));
        if (row.version_launch) |vl| try o.object.put(a, "version_launch", stringListValue(a, vl));
        return o;
    }

    /// the empty row for a key (dims recovered from the key).
    fn defaultRow(a: std.mem.Allocator, key: []const u8) FixtureRow {
        const parts = splitFixtureId(a, key) catch return .{ .key = key };
        return .{ .key = key, .harness = parts[0], .provider = parts[1], .model = parts[2], .platform = parts[3] };
    }

    /// merge-write a fixture-row update into the store root: load the
    /// existing row (or the empty default), apply the channel/registration
    /// field set, and put it back — preserving the curated launch/version
    /// argv and the other channel's ledger.
    pub fn fixtureRowUpdatePure(a: std.mem.Allocator, root: *std.json.Value, key: []const u8, update: FixtureUpdate) !void {
        const fx = try getOrPutObject(a, root, "fixtures");
        const existing = fx.get(key);
        var row = if (existing) |v| (try fixtureRowFromMap(a, key, v)) orelse defaultRow(a, key) else defaultRow(a, key);
        switch (update) {
            .capture => |u| {
                row.runner = u.runner;
                row.agent_detect_version = u.agent_detect_version;
                row.captured_at = u.captured_at;
                row.capture_channel_hash = u.channel_hash;
                row.harness_version = u.harness_version;
                row.fixture_hash = u.fixture_hash;
            },
            .identity => |u| {
                row.runner = u.runner;
                row.agent_detect_version = u.agent_detect_version;
                row.declared_at = u.declared_at;
                row.identity_channel_hash = u.channel_hash;
                row.fixture_hash = u.fixture_hash;
            },
            .registration => |u| {
                row.runner = u.runner;
                row.fixture_hash = u.fixture_hash;
                row.identity_channel_hash = u.identity_channel_hash;
                row.capture_channel_hash = u.capture_channel_hash;
            },
        }
        try fx.put(a, key, try fixtureRowValue(a, row));
    }

    /// upsert an errors-ledger entry (re-inserts overwrite with a fresh
    /// `failed_at`).
    pub fn errorsPutPure(a: std.mem.Allocator, root: *std.json.Value, h: ?[]const u8, p: ?[]const u8, m: ?[]const u8, plat: ?[]const u8, reason: []const u8, failed_at: i64) !void {
        const errors = try getOrPutObject(a, root, "errors");
        const key = try errorKey(a, h, p, m, plat);
        var o: std.json.Value = .{ .object = .empty };
        try o.object.put(a, "reason", .{ .string = reason });
        try o.object.put(a, "failed_at", .{ .integer = failed_at });
        try errors.put(a, key, o);
    }

    /// delete an errors-ledger entry (purge-on-success). Mutates the
    /// map in place via `getPtr` — a by-value `get` copy would leave the
    /// stored map's internal header pointer dangling after swapRemove.
    pub fn errorsClearPure(a: std.mem.Allocator, root: *std.json.Value, h: ?[]const u8, p: ?[]const u8, m: ?[]const u8, plat: ?[]const u8) !void {
        if (root.* != .object) return;
        const ev_ptr = root.object.getPtr("errors") orelse return;
        if (ev_ptr.* != .object) return;
        const key = try errorKey(a, h, p, m, plat);
        _ = ev_ptr.object.swapRemove(key);
    }

    /// the `--stale-by-channel-hash` divergence check: stale iff the two
    /// channel hashes are NOT both present and equal (divergence — the
    /// capture channel no longer matches the declared one — or nulls —
    /// channels not yet written — both count stale).
    pub fn channelHashDivergent(identity: ?[]const u8, capture: ?[]const u8) bool {
        if (identity == null or capture == null) return true;
        return !std.mem.eql(u8, identity.?, capture.?);
    }

    // ------------------------------------------------------------------
    // store I/O wrappers (lock → reload → mutate → atomic save → unlock)
    // ------------------------------------------------------------------

    /// merge-write a fixture-row update under the store lock.
    fn withFixtureRowUpdate(io: std.Io, a: std.mem.Allocator, key: []const u8, update: FixtureUpdate) !void {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try fixtureRowUpdatePure(a, &root, key, update);
        try indexSave(io, a, root);
    }

    /// upsert a queue entry under the store lock.
    fn upsertQueueEntry(io: std.Io, a: std.mem.Allocator, entry: QueueEntry) !void {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try queueUpsertPure(a, &root, entry);
        try indexSave(io, a, root);
    }

    /// write an errors-ledger entry under the store lock.
    fn putErrorEntry(io: std.Io, a: std.mem.Allocator, h: ?[]const u8, p: ?[]const u8, m: ?[]const u8, plat: ?[]const u8, reason: []const u8, failed_at: i64) !void {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try errorsPutPure(a, &root, h, p, m, plat, reason, failed_at);
        try indexSave(io, a, root);
    }

    /// purge an errors-ledger entry under the store lock (success).
    fn clearErrorEntry(io: std.Io, a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !void {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try errorsClearPure(a, &root, h, p, m, plat);
        try indexSave(io, a, root);
    }

    /// the `fixtures`-map row for a dash-joined fixture id, or null.
    fn fixtureRowByKey(io: std.Io, a: std.mem.Allocator, key: []const u8) !?FixtureRow {
        const root = try indexLoad(io, a);
        const fx = root.object.get("fixtures") orelse return null;
        if (fx != .object) return null;
        const v = fx.object.get(key) orelse return null;
        return fixtureRowFromMap(a, key, v);
    }

    /// DELETE matching queue entries (dequeue). Returns entries deleted.
    fn deleteQueueEntries(io: std.Io, a: std.mem.Allocator, f: FilterOptions) !usize {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        const q = try getOrPutArray(a, &root, "queue");
        var deleted: usize = 0;
        var i: usize = q.items.len;
        while (i > 0) {
            i -= 1;
            const entry = queueEntryFromValue(a, q.items[i]) catch continue;
            if (!dequeueMatches(f, entry)) continue;
            _ = q.orderedRemove(i);
            deleted += 1;
        }
        try indexSave(io, a, root);
        return deleted;
    }

    // ------------------------------------------------------------------
    // the pop protocol — expansion (only the daemon expands)
    // ------------------------------------------------------------------

    fn candidateLess(_: void, x: Candidate, y: Candidate) bool {
        return std.mem.lessThan(u8, x.fixture_id, y.fixture_id);
    }

    /// expand one queue entry into its remaining candidate set. The
    /// universe is the `fixtures` map (known=true, the default) or the
    /// rule cross-product minus the known maps (known=false), filtered
    /// by the entry's dims, platform (the entry's or the host's per
    /// platform in the loop), the marker evaluations, and the filter
    /// axes. A candidate is DONE when its completion timestamp
    /// (mode-scoped channel date, else `errors.<key>.failed_at`) is
    /// present AND ≥ the entry's `started_at`; an entry never worked
    /// (started_at null) has no done candidates (the fresh sweep
    /// re-evaluates everything).
    pub fn expandEntry(io: std.Io, a: std.mem.Allocator, root: *const std.json.Value, free: *const FreeGrid, entry: QueueEntry, host: []const u8) !ExpandResult {
        const platforms: []const []const u8 = if (entry.platform) |p| &.{p} else &platforms_all;
        var host_list: std.ArrayListUnmanaged(Candidate) = .empty;
        var remaining: usize = 0;
        for (platforms) |plat| {
            const list = try expandForPlatform(io, a, root, free, entry, plat);
            remaining += list.len;
            if (std.mem.eql(u8, plat, host)) {
                for (list) |c| try host_list.append(a, c);
            }
        }
        std.mem.sort(Candidate, host_list.items, {}, candidateLess);
        return .{ .host_candidates = try host_list.toOwnedSlice(a), .remaining_anywhere = remaining };
    }

    fn expandForPlatform(io: std.Io, a: std.mem.Allocator, root: *const std.json.Value, free: *const FreeGrid, entry: QueueEntry, plat: []const u8) ![]Candidate {
        if (entry.stale_by_missing_entry == true) return expandMissingEntryPlatform(io, a, root, entry, plat);
        const known = entry.known orelse true;
        if (known) return expandKnownPlatform(io, a, root, free, entry, plat);
        return expandUnknownPlatform(io, a, root, free, entry, plat);
    }

    /// the known universe: the `fixtures` map rows matching the entry's
    /// dims + platform, surviving the axes, marker evaluations, and the
    /// completion-timestamp done rule.
    fn expandKnownPlatform(io: std.Io, a: std.mem.Allocator, root: *const std.json.Value, free: *const FreeGrid, entry: QueueEntry, plat: []const u8) ![]Candidate {
        var out: std.ArrayListUnmanaged(Candidate) = .empty;
        if (root.* != .object) return &.{};
        const fx_v = root.object.get("fixtures") orelse return &.{};
        if (fx_v != .object) return &.{};
        var it = fx_v.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const parts = splitFixtureId(a, key) catch continue;
            if (!std.mem.eql(u8, parts[3], plat)) continue;
            if (entry.harness) |v| {
                if (!std.mem.eql(u8, parts[0], v)) continue;
            }
            if (entry.provider) |v| {
                if (!std.mem.eql(u8, parts[1], v)) continue;
            }
            if (entry.model) |v| {
                if (!std.mem.eql(u8, parts[2], v)) continue;
            }
            const row = (try fixtureRowFromMap(a, key, kv.value_ptr.*)) orelse continue;
            // the filter axes
            const err = errorEntryFor(root, key);
            const err_cls: ?ErrorClass = if (err) |e| errorReasonClass(e.reason) else null;
            if ((entry.valid orelse true) and err_cls == .invalid) continue;
            if (entry.successful) |s| {
                if (s) {
                    if (err != null) continue;
                } else {
                    if (err == null or err_cls != .unsuccessful) continue;
                }
            }
            if (entry.free) |fr| {
                if (fr != free.has(parts[1], parts[2])) continue;
            }
            // marker evaluation — fresh ⇒ not a candidate
            if (!(try entryMarkerStale(io, a, entry, row, key))) continue;
            // completion-timestamp done rule (only once the entry started)
            if (entry.started_at != null) {
                if (completionTimestamp(root, entry, row, key)) |ts| {
                    if (ts >= entry.started_at.?) continue;
                }
            }
            try out.append(a, .{ .fixture_id = key, .harness = parts[0], .provider = parts[1], .model = parts[2], .platform = parts[3] });
        }
        return out.toOwnedSlice(a);
    }

    /// the unknown universe: the rule cross-product minus the fixtures
    /// map and (with the default valid=true) the errors ledger — the
    /// discovery sweep. Generated combos have no launch/version argv and
    /// no outcomes, so markers and the successful axis never combine with
    /// `--unknown` (CLI conflict).
    fn expandUnknownPlatform(io: std.Io, a: std.mem.Allocator, root: *const std.json.Value, free: *const FreeGrid, entry: QueueEntry, plat: []const u8) ![]Candidate {
        _ = io;
        var out: std.ArrayListUnmanaged(Candidate) = .empty;
        for (rulesForHarnesses) |hr| {
            const hs = slugId(a, hr.name) catch continue;
            if (entry.harness) |v| {
                if (!std.mem.eql(u8, hs, v)) continue;
            }
            for (rulesForProviders) |pr| {
                const ps = slugId(a, pr.name) catch continue;
                if (entry.provider) |v| {
                    if (!std.mem.eql(u8, ps, v)) continue;
                }
                for (rulesForModels) |mr| {
                    const ms = slugId(a, mr.name) catch continue;
                    if (entry.model) |v| {
                        if (!std.mem.eql(u8, ms, v)) continue;
                    }
                    const key = try joinId(a, "-", &.{ hs, ps, ms, plat });
                    if (fixturesHas(root, key)) continue;
                    if (errorEntryFor(root, key)) |e| {
                        const cls = errorReasonClass(e.reason);
                        // valid=true (default) subtracts all error entries;
                        // valid=false stops subtracting invalid-class ones
                        if ((entry.valid orelse true) or cls == .unsuccessful) continue;
                    }
                    if (entry.free) |fr| {
                        if (fr != free.has(ps, ms)) continue;
                    }
                    try out.append(a, .{ .fixture_id = key, .harness = hs, .provider = ps, .model = ms, .platform = plat });
                }
            }
        }
        return out.toOwnedSlice(a);
    }

    /// the `--stale-by-missing-entry` universe: fixture FILES with no
    /// store entry (the daemon's expansion for it is the registration
    /// pass — idempotent, purged when no unregistered files remain).
    /// Invalid stems carry no dims — they are candidates only for
    /// unfiltered entries (their failures share the all-null errors
    /// key, which is what makes them done).
    fn expandMissingEntryPlatform(io: std.Io, a: std.mem.Allocator, root: *const std.json.Value, entry: QueueEntry, plat: []const u8) ![]Candidate {
        var out: std.ArrayListUnmanaged(Candidate) = .empty;
        var dir = std.Io.Dir.cwd().openDir(io, "fixtures", .{ .iterate = true }) catch return &.{};
        defer dir.close(io);
        var dir_it = dir.iterate();
        while (dir_it.next(io) catch null) |ent| {
            if (ent.kind != .file) continue;
            const name = ent.name;
            if (name.len <= ".json".len or !std.mem.endsWith(u8, name, ".json")) continue;
            const stem = name[0 .. name.len - ".json".len];
            if (fixturesHas(root, stem)) continue;
            const parts = splitFixtureId(a, stem) catch {
                // unknown dims — only for unfiltered entries; done via the
                // all-null errors key once recorded.
                if (entry.platform != null) continue;
                if (entry.harness != null or entry.provider != null or entry.model != null) continue;
                if (entry.started_at != null) {
                    if (errorEntryFor(root, "null-null-null-null")) |e| {
                        if (e.failed_at >= entry.started_at.?) continue;
                    }
                }
                try out.append(a, .{ .fixture_id = stem });
                continue;
            };
            if (!std.mem.eql(u8, parts[3], plat)) continue;
            if (entry.harness) |v| {
                if (!std.mem.eql(u8, parts[0], v)) continue;
            }
            if (entry.provider) |v| {
                if (!std.mem.eql(u8, parts[1], v)) continue;
            }
            if (entry.model) |v| {
                if (!std.mem.eql(u8, parts[2], v)) continue;
            }
            if (entry.started_at != null) {
                if (errorEntryFor(root, stem)) |e| {
                    if (e.failed_at >= entry.started_at.?) continue;
                }
            }
            try out.append(a, .{ .fixture_id = stem, .harness = parts[0], .provider = parts[1], .model = parts[2], .platform = parts[3] });
        }
        return out.toOwnedSlice(a);
    }

    /// evaluate the entry's marker for one candidate — true when the
    /// marker says the candidate is stale (work needed). Entries without
    /// markers are always stale-by-default (the bare sweep re-evaluates
    /// everything). Markers read only local state (dates, hashes, the
    /// committed file, and — for `stale_by_harness_version` — a
    /// zero-token `version_launch` probe).
    fn entryMarkerStale(io: std.Io, a: std.mem.Allocator, entry: QueueEntry, row: FixtureRow, key: []const u8) !bool {
        if (entry.stale_by_missing_fixture == true) {
            return fixtureFileBytes(io, a, key) == null;
        }
        if (entry.stale_by_minutes) |mins| {
            const ts = if (std.mem.eql(u8, entry.mode, "from-identity")) row.declared_at else row.captured_at;
            if (ts) |t| {
                if (!isStale(io, t, mins)) return false;
            }
            return true;
        }
        if (entry.stale_by_harness_version == true) {
            if (row.version_launch) |vl| {
                if (row.harness_version) |stored| {
                    if (launchVersion(io, a, vl)) |live| {
                        if (std.mem.eql(u8, live, stored)) return false;
                    }
                }
            }
            return true; // absent launch/version or probe mismatch → stale
        }
        if (entry.stale_by_detect_version == true) {
            if (row.agent_detect_version) |v| {
                if (std.mem.eql(u8, v, build_options.version)) return false;
            }
            return true;
        }
        if (entry.stale_by_fixture_hash == true) {
            if (row.fixture_hash) |stored| {
                if (fixtureFileBytes(io, a, key)) |bytes| {
                    const cur = try generationHash(a, bytes);
                    defer a.free(cur);
                    if (std.mem.eql(u8, stored, cur)) return false;
                }
            }
            return true;
        }
        if (entry.stale_by_channel_hash == true) {
            return channelHashDivergent(row.identity_channel_hash, row.capture_channel_hash);
        }
        return true; // no marker → candidate
    }

    /// the candidate's completion timestamp: the entry's mode-scoped
    /// channel date, else the errors-ledger `failed_at`.
    fn completionTimestamp(root: *const std.json.Value, entry: QueueEntry, row: FixtureRow, key: []const u8) ?i64 {
        if (std.mem.eql(u8, entry.mode, "from-identity")) {
            if (row.declared_at) |t| return t;
        } else {
            if (row.captured_at) |t| return t;
        }
        if (errorEntryFor(root, key)) |e| return e.failed_at;
        return null;
    }

    // ----------------------------------------------------------------
    // fixtures fixture subcommands
    // ----------------------------------------------------------------

    /// strictly alphanumeric form of the current platform — just the
    /// OS name, no arch (e.g. `darwin`, `linux`, `windows`). Computed
    /// at compile time from `builtin.target` so it's free. macOS is
    /// remapped to `darwin` to match the conventional platform name
    /// (the `builtin.target.os.tag` is `.macos` but the conventional
    /// name is "darwin" — we want one canonical name for fixtures).
    /// Arch is dropped because the same fixture JSON is valid on all
    /// archs of a given OS; the platform id only differentiates OS.
    pub fn platformId() []const u8 {
        return switch (builtin.target.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => "darwin",
            else => @tagName(builtin.target.os.tag),
        };
    }

    /// assemble a fixture_id from the three sub-ids. Caller
    /// owns the returned slice.
    pub fn fixtureId(a: std.mem.Allocator, agent: []const u8) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        try list.appendSlice(a, agent);
        try list.append(a, '-');
        try list.appendSlice(a, platformId());
        return list.toOwnedSlice(a);
    }

    /// shared filter for `fixtures queue` / `fixtures dequeue`. Four
    /// dimension flags (`--harness=`, `--provider=`, `--model=`,
    /// `--platform=`) constrain their dim to equality; an unmentioned
    /// dim is unconstrained. `--fixture=` expands to all four dims
    /// (h-p-m-platform); `--agent=` expands to h-p-m, leaving platform
    /// unconstrained unless `--platform=` is also given. The markers
    /// and axes are stored on the queue entry as flat fields /
    /// nullable booleans; `any` is true iff at least one option was
    /// present.
    pub const FilterOptions = struct {
        harness: []const u8 = "",
        provider: []const u8 = "",
        model: []const u8 = "",
        platform: []const u8 = "",
        fixture: ?[]const u8 = null,
        agent: ?[]const u8 = null,
        /// markers — at most one may be set (validateFilters).
        stale_by_missing_entry: bool = false,
        stale_by_missing_fixture: bool = false,
        /// age thresholds. Each is a marker by itself; at most one of
        /// the three may be set. The queued entry always stores the age
        /// in MINUTES in `stale_by_minutes` (days/hours convert at
        /// stamp time).
        stale_by_days: ?i64 = null,
        stale_by_hours: ?i64 = null,
        stale_by_minutes: ?i64 = null,
        stale_by_harness_version: bool = false,
        stale_by_detect_version: bool = false,
        stale_by_fixture_hash: bool = false,
        stale_by_channel_hash: bool = false,
        /// axes — nullable booleans (--known → true, --unknown → false,
        /// etc.); the pairs are XOR (validateFilters).
        known: ?bool = null,
        valid: ?bool = null,
        successful: ?bool = null,
        free: ?bool = null,
        /// refresh mode: `"from-identity" | "from-capture"`, or `""`
        /// when no mode flag was given. `queue` stamps one entry per
        /// selected mode (no flag → both); `dequeue` filters by it
        /// (no flag → all modes).
        mode: []const u8 = "",
        any: bool = false,
        /// true when `--fixture=` or `--agent=` (the composite ids)
        /// contributed the equality dims — used for the creation path.
        composite: bool = false,
    };

    pub const FilterError = error{
        /// no filter option present at all
        NoFilter,
        /// `--fixture=` not a valid 4-part id
        InvalidFixtureId,
        /// `--agent=` not a valid 3-part id
        InvalidAgentId,
        /// `--stale-by-days=`/`--stale-by-minutes=` not an integer
        InvalidThreshold,
        /// contradictory or disallowed combination
        ConflictingFilters,
        /// allocation failure while expanding composite ids
        OutOfMemory,
    };

    /// the shared filter validator — the conflict matrix (§4e):
    /// - at most one age threshold, each ≥ 1
    /// - at most one marker overall (missing-entry / missing-fixture /
    ///   one staleness unit)
    /// - `--unknown` + any marker or a non-default `successful` axis →
    ///   conflict (generated combos have no markers/outcomes to filter
    ///   on; marker sweeps require `known: true`)
    /// The XOR axis pairs (`--known`/`--unknown`, `--valid`/`--invalid`,
    /// `--successful`/`--unsuccessful`, `--free`/`--paid`) are enforced
    /// at parse time; the stored entries keep nullable booleans.
    pub fn validateFilters(f: FilterOptions) FilterError!void {
        const age_scopes = @as(usize, @intFromBool(f.stale_by_days != null)) +
            @as(usize, @intFromBool(f.stale_by_hours != null)) +
            @as(usize, @intFromBool(f.stale_by_minutes != null));
        if (age_scopes > 1) return FilterError.ConflictingFilters;
        if ((f.stale_by_days != null and f.stale_by_days.? < 1) or
            (f.stale_by_hours != null and f.stale_by_hours.? < 1) or
            (f.stale_by_minutes != null and f.stale_by_minutes.? < 1)) return FilterError.ConflictingFilters;
        const marker_count = @as(usize, @intFromBool(f.stale_by_missing_entry)) +
            @as(usize, @intFromBool(f.stale_by_missing_fixture)) +
            age_scopes +
            @as(usize, @intFromBool(f.stale_by_harness_version)) +
            @as(usize, @intFromBool(f.stale_by_detect_version)) +
            @as(usize, @intFromBool(f.stale_by_fixture_hash)) +
            @as(usize, @intFromBool(f.stale_by_channel_hash));
        if (marker_count > 1) return FilterError.ConflictingFilters;
        if (f.known == false and (marker_count > 0 or f.successful != null)) return FilterError.ConflictingFilters;
    }

    /// parse the shared filter flags from argv (expects argv0, "fixtures",
    /// <subcommand> already consumed). Errors use `FilterError` so the
    /// caller can emit the command-specific message and usage.
    fn parseFilters(init: std.process.Init) FilterError!FilterOptions {
        const a = init.arena.allocator();
        var f: FilterOptions = .{};
        var seen_fixture = false;
        var seen_agent = false;
        var seen_harness = false;
        var seen_provider = false;
        var seen_model = false;
        var seen_platform = false;

        var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return FilterError.NoFilter;
        defer args_it.deinit();
        _ = args_it.skip(); // argv0
        _ = args_it.skip(); // "fixtures"
        _ = args_it.next() orelse return FilterError.NoFilter; // <subcommand>
        while (args_it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--fixture=")) {
                f.fixture = arg["--fixture=".len..];
                seen_fixture = true;
            } else if (std.mem.startsWith(u8, arg, "--agent=")) {
                f.agent = arg["--agent=".len..];
                seen_agent = true;
            } else if (std.mem.startsWith(u8, arg, "--harness=")) {
                f.harness = arg["--harness=".len..];
                seen_harness = true;
            } else if (std.mem.startsWith(u8, arg, "--provider=")) {
                f.provider = arg["--provider=".len..];
                seen_provider = true;
            } else if (std.mem.startsWith(u8, arg, "--model=")) {
                f.model = arg["--model=".len..];
                seen_model = true;
            } else if (std.mem.startsWith(u8, arg, "--platform=")) {
                f.platform = arg["--platform=".len..];
                seen_platform = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-missing-entry")) {
                f.stale_by_missing_entry = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-missing-fixture")) {
                f.stale_by_missing_fixture = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-harness-version")) {
                f.stale_by_harness_version = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-detect-version")) {
                f.stale_by_detect_version = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-fixture-hash")) {
                f.stale_by_fixture_hash = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-channel-hash")) {
                f.stale_by_channel_hash = true;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-days=")) {
                f.stale_by_days = std.fmt.parseInt(i64, arg["--stale-by-days=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-hours=")) {
                f.stale_by_hours = std.fmt.parseInt(i64, arg["--stale-by-hours=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-minutes=")) {
                f.stale_by_minutes = std.fmt.parseInt(i64, arg["--stale-by-minutes=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.eql(u8, arg, "--known")) {
                if (f.known != null and f.known.? != true) return FilterError.ConflictingFilters;
                f.known = true;
            } else if (std.mem.eql(u8, arg, "--unknown")) {
                if (f.known != null and f.known.? != false) return FilterError.ConflictingFilters;
                f.known = false;
            } else if (std.mem.eql(u8, arg, "--valid")) {
                if (f.valid != null and f.valid.? != true) return FilterError.ConflictingFilters;
                f.valid = true;
            } else if (std.mem.eql(u8, arg, "--invalid")) {
                if (f.valid != null and f.valid.? != false) return FilterError.ConflictingFilters;
                f.valid = false;
            } else if (std.mem.eql(u8, arg, "--successful")) {
                if (f.successful != null and f.successful.? != true) return FilterError.ConflictingFilters;
                f.successful = true;
            } else if (std.mem.eql(u8, arg, "--unsuccessful")) {
                if (f.successful != null and f.successful.? != false) return FilterError.ConflictingFilters;
                f.successful = false;
            } else if (std.mem.eql(u8, arg, "--free")) {
                if (f.free != null and f.free.? != true) return FilterError.ConflictingFilters;
                f.free = true;
            } else if (std.mem.eql(u8, arg, "--paid")) {
                if (f.free != null and f.free.? != false) return FilterError.ConflictingFilters;
                f.free = false;
            } else if (std.mem.eql(u8, arg, "--from-identity") or std.mem.eql(u8, arg, "--from-capture")) {
                // exactly one mode flag (both → conflicting). No flag means
                // both modes are queued per candidate. The stored value is
                // the FULL "from-*" string so the daemon's worker branch
                // can compare it verbatim.
                const m = arg[2..];
                if (f.mode.len > 0 and !std.mem.eql(u8, f.mode, m)) return FilterError.ConflictingFilters;
                f.mode = m;
            }
        }

        try validateFilters(f);

        // `--fixture=` supplies all four dims and may not combine
        // with `--agent=` or any `--X=`; `--platform=` is allowed
        // but must be identical to the fixtures id's platform part.
        if (seen_fixture) {
            if (seen_agent or seen_harness or seen_provider or seen_model) return FilterError.ConflictingFilters;
            const parts = splitFixtureId(a, f.fixture.?) catch return FilterError.InvalidFixtureId;
            defer {
                a.free(parts[0]);
                a.free(parts[1]);
                a.free(parts[2]);
                a.free(parts[3]);
            }
            // dupe: `parts` are freed on return, but the filter must
            // outlive parseFilters (it's returned to the caller)
            f.harness = a.dupe(u8, parts[0]) catch return FilterError.OutOfMemory;
            f.provider = a.dupe(u8, parts[1]) catch return FilterError.OutOfMemory;
            f.model = a.dupe(u8, parts[2]) catch return FilterError.OutOfMemory;
            if (seen_platform and !std.mem.eql(u8, f.platform, parts[3])) return FilterError.ConflictingFilters;
            f.platform = a.dupe(u8, parts[3]) catch return FilterError.OutOfMemory;
            f.composite = true;
        } else if (seen_agent) {
            // `--agent=` supplies h-p-m; `--platform=` may supplement it
            // (identical to `--fixture=` when combined). No `--X=` other
            // than `--platform=` may combine with `--agent=`.
            if (seen_harness or seen_provider or seen_model) return FilterError.ConflictingFilters;
            const parts = splitAgentId(a, f.agent.?) catch return FilterError.InvalidAgentId;
            defer {
                a.free(parts[0]);
                a.free(parts[1]);
                a.free(parts[2]);
            }
            // dupe: `parts` are freed on return; the filter outlives it
            f.harness = a.dupe(u8, parts[0]) catch return FilterError.OutOfMemory;
            f.provider = a.dupe(u8, parts[1]) catch return FilterError.OutOfMemory;
            f.model = a.dupe(u8, parts[2]) catch return FilterError.OutOfMemory;
            f.composite = true;
        }

        // canonicalize the h/p/m filter dims to the store's slug-id form
        // when they resolve to a known rule (the store rows use
        // `slugId(canonicalName)` — e.g. `kimicode`, never
        // `kimi-code`), so label forms (`Kilo Code`), canonical
        // spellings (`kimi-code`), slug forms (`kimicode`), and case
        // variants (`KILO`) all match the same rows. Unknown dims pass
        // through raw — the seed path intentionally allows unknown ids.
        // The platform dim is never canonicalized.
        if (f.harness.len > 0) {
            if (canonicalFilterDim(a, HarnessRule, &rulesForHarnesses, f.harness)) |canon| {
                f.harness = a.dupe(u8, canon) catch return FilterError.OutOfMemory;
            }
        }
        if (f.provider.len > 0) {
            if (canonicalFilterDim(a, ProviderRule, &rulesForProviders, f.provider)) |canon| {
                f.provider = a.dupe(u8, canon) catch return FilterError.OutOfMemory;
            }
        }
        if (f.model.len > 0) {
            if (canonicalFilterDim(a, ModelRule, &rulesForModels, f.model)) |canon| {
                f.model = a.dupe(u8, canon) catch return FilterError.OutOfMemory;
            }
        }

        const scope_count = @as(usize, @intFromBool(f.stale_by_missing_entry)) +
            @as(usize, @intFromBool(f.stale_by_missing_fixture)) +
            @as(usize, @intFromBool(f.stale_by_days != null)) +
            @as(usize, @intFromBool(f.stale_by_hours != null)) +
            @as(usize, @intFromBool(f.stale_by_minutes != null)) +
            @as(usize, @intFromBool(f.stale_by_harness_version)) +
            @as(usize, @intFromBool(f.stale_by_detect_version)) +
            @as(usize, @intFromBool(f.stale_by_fixture_hash)) +
            @as(usize, @intFromBool(f.stale_by_channel_hash));
        const axis_count = @as(usize, @intFromBool(f.known != null)) +
            @as(usize, @intFromBool(f.valid != null)) +
            @as(usize, @intFromBool(f.successful != null)) +
            @as(usize, @intFromBool(f.free != null));

        f.any = seen_fixture or seen_agent or seen_harness or seen_provider or
            seen_model or seen_platform or scope_count > 0 or axis_count > 0;
        if (!f.any) return FilterError.NoFilter;
        return f;
    }

    /// the set of modes to emit for a queue request: no mode flag → both
    /// (`from-identity` first); one flag → that mode only.
    fn queueModes(f: FilterOptions) [2]?[]const u8 {
        if (f.mode.len > 0) return .{ f.mode, null };
        return .{ "from-identity", "from-capture" };
    }

    /// the age threshold in MINUTES (days/hours convert at stamp time —
    /// the entry has a single `stale_by_minutes` age field).
    fn staleMinutes(f: FilterOptions) ?i64 {
        if (f.stale_by_minutes != null) return f.stale_by_minutes;
        if (f.stale_by_hours != null) return @as(?i64, f.stale_by_hours.? * 60);
        if (f.stale_by_days != null) return @as(?i64, f.stale_by_days.? * 24 * 60);
        return null;
    }

    /// does a stored queue entry match the dequeue filter? Dims/mode
    /// constrain to equality when set; markers/axes match the stored
    /// fields (an age threshold matches any stored `stale_by_minutes`).
    fn dequeueMatches(f: FilterOptions, e: QueueEntry) bool {
        if (f.harness.len > 0 and !optStrEq(e.harness, f.harness)) return false;
        if (f.provider.len > 0 and !optStrEq(e.provider, f.provider)) return false;
        if (f.model.len > 0 and !optStrEq(e.model, f.model)) return false;
        if (f.platform.len > 0 and !optStrEq(e.platform, f.platform)) return false;
        if (f.mode.len > 0 and !std.mem.eql(u8, e.mode, f.mode)) return false;
        if (f.stale_by_missing_entry and e.stale_by_missing_entry != true) return false;
        if (f.stale_by_missing_fixture and e.stale_by_missing_fixture != true) return false;
        if (f.stale_by_days != null or f.stale_by_hours != null or f.stale_by_minutes != null) {
            if (e.stale_by_minutes == null) return false;
        }
        if (f.stale_by_harness_version and e.stale_by_harness_version != true) return false;
        if (f.stale_by_detect_version and e.stale_by_detect_version != true) return false;
        if (f.stale_by_fixture_hash and e.stale_by_fixture_hash != true) return false;
        if (f.stale_by_channel_hash and e.stale_by_channel_hash != true) return false;
        if (f.known != null and e.known != f.known) return false;
        if (f.valid != null and e.valid != f.valid) return false;
        if (f.successful != null and e.successful != f.successful) return false;
        if (f.free != null and e.free != f.free) return false;
        return true;
    }

    /// human-readable description of a queue entry for diagnostics.
    fn describeQueueEntry(a: std.mem.Allocator, e: QueueEntry) ![]u8 {
        const h = e.harness orelse "";
        const p = e.provider orelse "";
        const m = e.model orelse "";
        const plat = e.platform orelse "";
        if (h.len > 0 and p.len > 0 and m.len > 0 and plat.len > 0) {
            return (try fixtureIdFrom(a, h, p, m, plat)) orelse try a.dupe(u8, "sweep");
        }
        var list: std.ArrayList(u8) = .empty;
        try list.appendSlice(a, "sweep");
        const dims = [_][2][]const u8{
            .{ "harness", h },
            .{ "provider", p },
            .{ "model", m },
            .{ "platform", plat },
        };
        for (dims) |d| {
            if (d[1].len > 0) {
                try list.append(a, ' ');
                try list.appendSlice(a, d[0]);
                try list.append(a, ':');
                try list.appendSlice(a, d[1]);
            }
        }
        return list.toOwnedSlice(a);
    }

    /// `fixtures capture` — capture the current real session into
    /// `fixtures/<id>.json` (top-level `from-capture` + `from-capture-raw`
    /// channel keys; any existing `from-identity` channel preserved) and
    /// merge-write the matching `fixtures` entry's capture ledger
    /// (captured_at + channel_hash + harness_version + fixture_hash) —
    /// purging any errors entry on success. Failure semantics: if the
    /// detection ladder fails to resolve harness *or* provider *or* model,
    /// exit 8 with no fixture written and no store change (partial
    /// detection is bad data per DESIGN). The daemon spawns this via the
    /// row's `prompt_launch` argv inside a live model session; a hand-run
    /// capture is a real session too.
    ///
    /// **Filename contract** — the fixture is written as a single
    /// `fixtures/<fixture_id>.json`, where `fixture_id = agent_id + "-" +
    /// platform_id` (e.g. `cline-clinepass-kimik3-darwin`). The
    /// `-<platform>` suffix keeps per-platform config paths from churning
    /// each other across CI runs; see DESIGN.md "per-platform fixtures"
    /// for the rationale.
    pub fn runFixturesCapture(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        var d = Detection{};
        _ = try detect(init, &d);

        const harness_aid = d.harness_id;
        const provider_aid = d.provider_id;
        const model_aid = d.model_id;

        const resolved = (if (harness_aid != null) @as(usize, 1) else 0) +
            (if (provider_aid != null) @as(usize, 1) else 0) +
            (if (model_aid != null) @as(usize, 1) else 0);

        // partial detection (1 or 2 dims): partial is bad data per DESIGN —
        // report + exit 8, NO store change. Nothing is written if zero
        // dims resolve.
        if (resolved >= 1 and resolved < 3) {
            writeErr(io, "fixtures capture: partial detection (");
            writeErrCount(io, resolved);
            writeErr(io, "/3 dims) — no fixture written, no store change\n");
            return EXIT_UNABLE_TO_DETECT;
        }
        if (resolved == 0) {
            writeErr(io, "fixtures capture: harness/provider/model did not resolve — nothing recorded\n");
            return EXIT_UNABLE_TO_DETECT;
        }

        const agent_aid = d.agent_id orelse {
            writeErr(io, "fixtures capture: agent_id did not compute\n");
            return EXIT_UNABLE_TO_DETECT;
        };

        const fixture_id = try fixtureId(a, agent_aid);

        // from-capture channel: identify from the live detection, both
        // trailer variants from spawning the current binary's `trailer`
        // action in the session env (bare — session-env detection).
        const cooked = try buildCooked(a, &d);
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_path = selfPath(io, &self_path_buf);
        const co = if (self_path) |sp| try spawnTrailerLine(a, io, sp, "co-author", "", "", "") else null;
        const ab = if (self_path) |sp| try spawnTrailerLine(a, io, sp, "assisted-by", "", "", "") else null;
        const channel = try channelJson(a, cooked, co, ab);
        const ch_v = try std.json.parseFromSlice(std.json.Value, a, channel, .{});

        // live harness version snapshot via the row's `version_launch`
        // (null when the row or its version probe is absent — "not yet
        // knowable").
        const row = try fixtureRowByKey(io, a, fixture_id);
        const hver = if (row) |r| (if (r.version_launch) |vl| launchVersion(io, a, vl) else null) else null;

        const raw = try buildRaw(a, &d, init.environ_map, hver, true);
        const bytes = try mergeWriteFixture(a, io, fixture_id, &.{ "from-capture", "from-capture-raw" }, &.{ ch_v.value, raw });

        // stamp the row's capture ledger (preserving the curated
        // launch/version argv + the identity ledger) and purge any
        // errors entry.
        const now = unixNow(io);
        const ch_hash = try generationHash(a, channel);
        const f_hash = try generationHash(a, bytes);
        try withFixtureRowUpdate(io, a, fixture_id, .{ .capture = .{
            .runner = getParentPid(),
            .agent_detect_version = build_options.version,
            .captured_at = now,
            .channel_hash = ch_hash,
            .harness_version = hver,
            .fixture_hash = f_hash,
        } });
        try clearErrorEntry(io, a, harness_aid orelse unreachable, provider_aid orelse unreachable, model_aid orelse unreachable, platformId());

        writeOut(io, "fixtures capture: wrote fixtures/");
        writeOut(io, fixture_id);
        writeOut(io, ".json\n");
        return 0;
    }

    /// `fixtures queue [markers] [axes] <filters>` — upsert queue entries
    /// (pure enqueue; no evaluation — the daemon expands). One entry per
    /// selected mode carries the dims, the one marker, and the axes
    /// verbatim; at least one filter/marker/axis is required (else exit
    /// 4). Idempotent per (dims, mode, markers, axes) tuple: a re-assert
    /// replaces the entry in place and resets `started_at` (a fresh
    /// sweep).
    pub fn runFixturesQueue(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        if (subcommandWantsHelp(init)) {
            writeOut(io, queueUsage);
            return EXIT_OK;
        }

        const f = parseFilters(init) catch |err| {
            switch (err) {
                error.NoFilter => writeErr(io, MSG_MISSING_ARG),
                error.InvalidFixtureId => writeErr(io, "fixtures queue: --fixture=<id> must be a 4-part <harness>-<provider>-<model>-<platform> id\n"),
                error.InvalidAgentId => writeErr(io, "fixtures queue: --agent=<id> must be a 3-part <harness>-<provider>-<model> id\n"),
                error.InvalidThreshold => writeErr(io, "fixtures queue: --stale-by-days=/--stale-by-hours=/--stale-by-minutes= must be integers >= 1\n"),
                error.ConflictingFilters => writeErr(io, MSG_CONFLICTING_ARG),
                error.OutOfMemory => writeErr(io, MSG_OUT_OF_MEMORY),
            }
            writeOut(io, queueUsage);
            return if (err == error.NoFilter) EXIT_MISSING_ARG else if (err == error.ConflictingFilters) EXIT_CONFLICTING_ARG else if (err == error.OutOfMemory) EXIT_OUT_OF_MEMORY else EXIT_UNRECOGNISED_ARG;
        };

        var queued: usize = 0;
        const modes = queueModes(f);
        for (modes) |mode_opt| {
            const mode = mode_opt orelse continue;
            const entry: QueueEntry = .{
                .harness = if (f.harness.len > 0) f.harness else null,
                .provider = if (f.provider.len > 0) f.provider else null,
                .model = if (f.model.len > 0) f.model else null,
                .platform = if (f.platform.len > 0) f.platform else null,
                .mode = mode,
                .stale_by_missing_entry = if (f.stale_by_missing_entry) true else null,
                .stale_by_missing_fixture = if (f.stale_by_missing_fixture) true else null,
                .stale_by_minutes = staleMinutes(f),
                .stale_by_harness_version = if (f.stale_by_harness_version) true else null,
                .stale_by_detect_version = if (f.stale_by_detect_version) true else null,
                .stale_by_fixture_hash = if (f.stale_by_fixture_hash) true else null,
                .stale_by_channel_hash = if (f.stale_by_channel_hash) true else null,
                .known = f.known,
                .valid = f.valid,
                .successful = f.successful,
                .free = f.free,
                .runner = getParentPid(),
                .started_at = null,
            };
            try validateQueueEntry(entry);
            try upsertQueueEntry(io, a, entry);
            queued += 1;
        }

        writeOut(io, "fixtures queue: queued ");
        writeCount(io, queued);
        writeOut(io, " entry/entries\n");
        return 0;
    }

    /// portable getppid. POSIX has `getppid(2)`; Windows uses
    /// `GetCurrentProcessId` (note: that returns *our* pid, not the
    /// parent's — for the runner field we accept either, the field
    /// is "the writer's identity" and the daemon uses liveness checks
    /// rather than the parent link).
    fn getParentPid() i64 {
        if (builtin.os.tag == .windows) {
            // No portable getppid on Windows in Zig 0.16 stdlib. The
            // daemon's liveness probe only needs the writer pid to be
            // *some* pid, not specifically the parent. Use our own
            // pid as a stand-in — the runner field is informational.
            return @intCast(std.os.windows.GetCurrentProcessId());
        }
        return @intCast(std.c.getppid());
    }

    /// `fixtures dequeue [markers] [axes] <filters>` — **DELETE only;
    /// pure entry filters.** Matches stored entries by dims + markers +
    /// axes + optional mode and deletes them. No evaluation, no fixture
    /// mutation. At least one filter/marker/axis is required.
    pub fn runFixturesDequeue(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        if (subcommandWantsHelp(init)) {
            writeOut(io, dequeueUsage);
            return EXIT_OK;
        }

        const f = parseFilters(init) catch |err| {
            switch (err) {
                error.NoFilter => writeErr(io, MSG_MISSING_ARG),
                error.InvalidFixtureId => writeErr(io, "fixtures dequeue: --fixture=<id> must be a 4-part <harness>-<provider>-<model>-<platform> id\n"),
                error.InvalidAgentId => writeErr(io, "fixtures dequeue: --agent=<id> must be a 3-part <harness>-<provider>-<model> id\n"),
                error.InvalidThreshold => writeErr(io, "fixtures dequeue: --stale-by-days=/--stale-by-hours=/--stale-by-minutes= must be integers >= 1\n"),
                error.ConflictingFilters => writeErr(io, MSG_CONFLICTING_ARG),
                error.OutOfMemory => writeErr(io, MSG_OUT_OF_MEMORY),
            }
            writeOut(io, dequeueUsage);
            return if (err == error.NoFilter) EXIT_MISSING_ARG else if (err == error.ConflictingFilters) EXIT_CONFLICTING_ARG else if (err == error.OutOfMemory) EXIT_OUT_OF_MEMORY else EXIT_UNRECOGNISED_ARG;
        };

        const deleted = try deleteQueueEntries(io, a, f);

        writeOut(io, "fixtures dequeue: deleted ");
        writeCount(io, deleted);
        writeOut(io, " entry/entries\n");
        return 0;
    }

    /// the registration pass behind `--stale-by-missing-entry`: a
    /// fixture file with no store entry gets one (fixture_hash + the
    /// per-channel hashes from the committed file; the channel dates
    /// stay absent — age checks treat them as stale until the channels
    /// are re-written). Invalid ids (malformed stem or unknown rule
    /// dims) land in the errors ledger (`unknown fixture file`); the
    /// file persists either way.
    fn runMissingEntryRegistration(io: std.Io, a: std.mem.Allocator, candidate: Candidate) !void {
        const now = unixNow(io);
        const parts = splitFixtureId(a, candidate.fixture_id) catch {
            try putErrorEntry(io, a, null, null, null, null, "unknown fixture file", now);
            return;
        };
        if (canonicalIdFor(a, HarnessRule, &rulesForHarnesses, parts[0]) == null or
            canonicalIdFor(a, ProviderRule, &rulesForProviders, parts[1]) == null or
            canonicalIdFor(a, ModelRule, &rulesForModels, parts[2]) == null)
        {
            try putErrorEntry(io, a, parts[0], parts[1], parts[2], parts[3], "unknown fixture file", now);
            return;
        }
        const bytes = fixtureFileBytes(io, a, candidate.fixture_id) orelse {
            // the file vanished between expansion and work — re-evaluated
            // next poll.
            return;
        };
        const f_hash = try generationHash(a, bytes);
        var identity_ch: ?[]const u8 = null;
        var capture_ch: ?[]const u8 = null;
        for ([_][]const u8{ "from-identity", "from-capture" }) |channel| {
            const ch = (try readChannelObject(a, io, candidate.fixture_id, channel)) orelse continue;
            const ch_bytes = try std.json.Stringify.valueAlloc(a, ch, .{ .whitespace = .indent_2 });
            const ch_hash = try generationHash(a, ch_bytes);
            if (std.mem.eql(u8, channel, "from-identity")) {
                identity_ch = ch_hash;
            } else {
                capture_ch = ch_hash;
            }
        }
        try withFixtureRowUpdate(io, a, candidate.fixture_id, .{ .registration = .{
            .runner = getParentPid(),
            .fixture_hash = f_hash,
            .identity_channel_hash = identity_ch,
            .capture_channel_hash = capture_ch,
        } });
    }

    /// post-check for a captured fixture: parse `fixtures/<id>.json`,
    /// verify combo-match — the `from-capture.identify` object's
    /// harness/provider/model ids equal the queued dims. Returns false on
    /// any failure (the caller stamps the errors ledger; the committed
    /// file is left intact).
    fn postCheckComboFixture(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !bool {
        const f_id = (try fixtureIdFrom(a, h, p, m, plat)) orelse return false;
        defer a.free(f_id);
        const ch = (try readChannelObject(a, io, f_id, "from-capture")) orelse {
            daemonWriteErr(io, "daemon: post-check: missing from-capture channel: ");
            daemonWriteErr(io, f_id);
            daemonWriteErr(io, "\n");
            return false;
        };
        const identify = ch.object.get("identify") orelse return false;
        if (identify != .object) return false;
        const cob = identify.object;
        const ch_id = sjstr(cob, "harness_id");
        const cp = sjstr(cob, "provider_id");
        const cm = sjstr(cob, "model_id");
        if (!(std.mem.eql(u8, ch_id, h) and std.mem.eql(u8, cp, p) and std.mem.eql(u8, cm, m))) {
            daemonWriteErr(io, "daemon: post-check: combo mismatch — from-capture identify ids '");
            daemonWriteErr(io, ch_id);
            daemonWriteErr(io, "/");
            daemonWriteErr(io, cp);
            daemonWriteErr(io, "/");
            daemonWriteErr(io, cm);
            daemonWriteErr(io, "' != queued '");
            daemonWriteErr(io, h);
            daemonWriteErr(io, "/");
            daemonWriteErr(io, p);
            daemonWriteErr(io, "/");
            daemonWriteErr(io, m);
            daemonWriteErr(io, "'\n");
            return false;
        }
        return true;
    }

    /// `from-identity` post-check: parse the declared fixture and confirm
    /// the `from-identity.identify` dims match the queue entry. Declared
    /// fixtures carry no evidence, so no evidence check applies.
    fn postCheckDeclaredFixture(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !bool {
        const f_id = (try fixtureIdFrom(a, h, p, m, plat)) orelse return false;
        defer a.free(f_id);
        const ch = (try readChannelObject(a, io, f_id, "from-identity")) orelse return false;
        const identify = ch.object.get("identify") orelse return false;
        if (identify != .object) return false;
        const cob = identify.object;
        const ch_id = sjstr(cob, "harness_id");
        const cp = sjstr(cob, "provider_id");
        const cm = sjstr(cob, "model_id");
        return std.mem.eql(u8, ch_id, h) and std.mem.eql(u8, cp, p) and std.mem.eql(u8, cm, m);
    }

    /// `from-identity` worker: resolve the combo via `resolveRecipe`
    /// (recipe-mode, no detection, zero tokens, no harness required),
    /// assemble the `from-identity` channel (`identify` = the 18-field
    /// buildCooked object; `trailer co-author`/`trailer assisted-by` from
    /// spawning the real CLI with the combo flags), merge-write it into
    /// `fixtures/<id>.json` (preserving `from-capture`/`from-capture-raw`),
    /// and stamp the row's identity ledger (declared_at + channel_hash +
    /// fixture_hash) — purging any errors entry on success. Declared, not
    /// observed. Failures land in the errors ledger and return false.
    fn runOneComboIdentity(a: std.mem.Allocator, io: std.Io, fixture_id: []const u8) !bool {
        const parts = try splitFixtureId(a, fixture_id);
        defer {
            a.free(parts[0]);
            a.free(parts[1]);
            a.free(parts[2]);
            a.free(parts[3]);
        }
        const h = parts[0];
        const p = parts[1];
        const m_d = parts[2];
        const plat = parts[3];
        var d = (try resolveRecipe(a, h, p, m_d)) orelse {
            daemonWriteErr(io, "daemon: from-identity: combo not in the rule tables — cannot declare a fixture\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "capture failed", unixNow(io));
            return false;
        };
        // real process lineage (like detect() would emit) so the
        // declared fixture still shows WHERE it was written.
        const anc = ancestorInfo(a, io);
        var lineage = std.ArrayList(Ancestor).empty;
        for (anc.pids, 0..) |pid, i| {
            const name: []const u8 = if (i < anc.names.len) anc.names[i] else "";
            try lineage.append(a, .{ .pid = pid, .name = name });
        }
        d.raw.process_lineage = try lineage.toOwnedSlice(a);
        var empty_env = std.process.Environ.Map.init(a);
        defer empty_env.deinit();
        const cooked = try buildCooked(a, &d);

        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_path = selfPath(io, &self_path_buf);
        const co = if (self_path) |sp| try spawnTrailerLine(a, io, sp, "co-author", h, p, m_d) else null;
        const ab = if (self_path) |sp| try spawnTrailerLine(a, io, sp, "assisted-by", h, p, m_d) else null;

        const channel = try channelJson(a, cooked, co, ab);
        const ch_v = try std.json.parseFromSlice(std.json.Value, a, channel, .{});
        const bytes = try mergeWriteFixture(a, io, fixture_id, &.{"from-identity"}, &.{ch_v.value});

        if (!(try postCheckDeclaredFixture(a, io, h, p, m_d, plat))) {
            daemonWriteErr(io, "daemon: from-identity: post-check failed — recording failure\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "post-check mismatch", unixNow(io));
            return false;
        }

        const now = unixNow(io);
        const ch_hash = try generationHash(a, channel);
        const f_hash = try generationHash(a, bytes);
        try withFixtureRowUpdate(io, a, fixture_id, .{ .identity = .{
            .runner = getParentPid(),
            .agent_detect_version = build_options.version,
            .declared_at = now,
            .channel_hash = ch_hash,
            .fixture_hash = f_hash,
        } });
        try clearErrorEntry(io, a, h, p, m_d, plat);
        return true;
    }

    /// `from-capture` worker: launch the real harness headlessly so it
    /// runs `fixtures capture` inside a live model session. The launch
    /// argv is the row's curated `prompt_launch`, read verbatim (no
    /// argv[0] substitution — the row names the concrete per-platform
    /// binary); availability is probed via the row's `version_launch`
    /// (exit 0 ⇒ installed). Uses the REAL environment (real API
    /// keys/config are required); cwd stays the daemon's (the repo root)
    /// so the session writes `fixtures/<id>.json` into the repo. A
    /// watchdog subprocess (`fixtures __timeout`) enforces
    /// `--capture-timeout-seconds` so a hung harness fails out instead of
    /// blocking the poll loop forever. Success = child exit 0 AND the
    /// post-check passing; failures land in the errors ledger
    /// (unavailable / capture failed / post-check mismatch) and consume
    /// the item — retry via `fixtures queue --unsuccessful`. A successful
    /// capture purges the combo's errors entry. Token-consuming —
    /// user-confirmed only.
    fn runOneComboCapture(a: std.mem.Allocator, io: std.Io, init: std.process.Init, fixture_id: []const u8, timeout_seconds: u64) !bool {
        const parts = try splitFixtureId(a, fixture_id);
        defer {
            a.free(parts[0]);
            a.free(parts[1]);
            a.free(parts[2]);
            a.free(parts[3]);
        }
        const h = parts[0];
        const p = parts[1];
        const m_d = parts[2];
        const plat = parts[3];
        const now = unixNow(io);

        const row = (try fixtureRowByKey(io, a, fixture_id)) orelse {
            daemonWriteErr(io, "daemon: from-capture: no fixture entry for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, "\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "no launch spec", now);
            return false;
        };
        // launch-spec backstop guard: no prompt_launch → errors, no
        // fixtures write.
        const launch = row.prompt_launch orelse {
            daemonWriteErr(io, "daemon: from-capture: no prompt_launch for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, "\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "no launch spec", now);
            return false;
        };
        // availability probe via the row's version_launch (absent ⇒ the
        // probe fails closed → unavailable).
        const version_launch = row.version_launch orelse {
            daemonWriteErr(io, "daemon: from-capture: harness unavailable for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, " — no version_launch\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "unavailable", now);
            return false;
        };
        if (!launchExitZero(io, a, version_launch)) {
            daemonWriteErr(io, "daemon: from-capture: harness unavailable for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, "\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "unavailable", now);
            return false;
        }

        // spawn the curated prompt_launch verbatim — the row's argv[0] IS
        // the concrete binary for this platform, so there is no name
        // cycling (a failed spawn is an artifact failure, not a name
        // miss).
        var argv_buf: [32][]const u8 = undefined;
        if (launch.len == 0 or launch.len > argv_buf.len) {
            daemonWriteErr(io, "daemon: from-capture: malformed prompt_launch for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, "\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "capture failed", now);
            return false;
        }
        for (launch, 0..) |arg, idx| {
            // the store saves the `"<prompt>"` placeholder; the daemon
            // interpolates the real launch prompt at spawn time.
            argv_buf[idx] = if (std.mem.eql(u8, arg, "<prompt>")) capture_prompt else arg;
        }
        const child = std.process.spawn(io, .{
            .argv = argv_buf[0..launch.len],
            .environ_map = init.environ_map,
            .stdout = .ignore,
            .stderr = .pipe,
        }) catch |err| {
            daemonWriteErr(io, "daemon: from-capture: spawn failed");
            daemonWriteErr(io, ": ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "capture failed", now);
            return false;
        };

        // timeout watchdog — `agent-detect-dev fixtures __timeout <sec> <pid>`.
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const argv0 = selfPath(io, &self_path_buf) orelse return false;
        const pid_num: u32 = if (builtin.os.tag == .windows)
            GetProcessId(child.id orelse return false)
        else
            @intCast(child.id orelse return false);
        const pid_str = try std.fmt.allocPrint(a, "{d}", .{pid_num});
        var tbuf: [64]u8 = undefined;
        const sec_str = std.fmt.bufPrint(&tbuf, "{d}", .{timeout_seconds}) catch "";
        var wargv = [_][]const u8{ argv0, "fixtures", "__timeout", sec_str, pid_str };
        _ = std.process.spawn(io, .{ .argv = &wargv, .stdout = .ignore, .stderr = .ignore }) catch {};

        const stderr_capture = readChildOutput(a, io, child, true) catch "";
        defer if (stderr_capture.len > 0) a.free(stderr_capture);
        var child_mut = child;
        const term = child_mut.wait(io) catch |err| {
            daemonWriteErr(io, "daemon: from-capture: child wait failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            try putErrorEntry(io, a, h, p, m_d, plat, "capture failed", now);
            return false;
        };
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    daemonWriteErr(io, "daemon: from-capture worker failed for ");
                    daemonWriteErr(io, fixture_id);
                    daemonWriteErr(io, " (exit code ");
                    daemonWriteErrCount(io, code);
                    daemonWriteErr(io, ")\n");
                    if (stderr_capture.len > 0) {
                        daemonWriteErr(io, "  worker stderr: ");
                        daemonWriteErr(io, stderr_capture);
                        if (stderr_capture[stderr_capture.len - 1] != '\n') daemonWriteErr(io, "\n");
                    }
                    // detection-partial (exit 8) lands here too — valid ids,
                    // failed attempt → retried via --unsuccessful.
                    try putErrorEntry(io, a, h, p, m_d, plat, "capture failed", now);
                    return false;
                }
                if (!(try postCheckComboFixture(a, io, h, p, m_d, plat))) {
                    // override the ledger the session wrote; the committed
                    // file is left intact.
                    try putErrorEntry(io, a, h, p, m_d, plat, "post-check mismatch", now);
                    return false;
                }
                try clearErrorEntry(io, a, h, p, m_d, plat);
                return true;
            },
            else => {
                daemonWriteErr(io, "daemon: from-capture child terminated abnormally for ");
                daemonWriteErr(io, fixture_id);
                daemonWriteErr(io, "\n");
                try putErrorEntry(io, a, h, p, m_d, plat, "capture failed", now);
                return false;
            },
        }
    }

    /// the daemon's per-poll pick: scan the queue-entry array in
    /// mode-rank order (from-identity first, then array order), deleting
    /// fully-satisfied entries (no remaining candidates anywhere) and
    /// malformed entries (errors ledger + drop), stamp `started_at` on
    /// the first entry with remaining host work, re-expand it, and
    /// return ONE candidate. All under one store lock cycle so the
    /// stamp + expansion + save are atomic against other writers.
    fn daemonPick(io: std.Io, a: std.mem.Allocator) !?DaemonPick {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        const free_grid = try FreeGrid.load(io, a);
        const q = try getOrPutArray(a, &root, "queue");
        const host = platformId();
        var dirty = false;
        var pick: ?DaemonPick = null;
        for ([_][]const u8{ "from-identity", "from-capture" }) |want_mode| {
            var i: usize = 0;
            while (i < q.items.len) {
                var entry = queueEntryFromValue(a, q.items[i]) catch {
                    daemonWriteErr(io, "daemon: malformed queue entry — recording + dropping\n");
                    try errorsPutPure(a, &root, null, null, null, null, "malformed queue row", unixNow(io));
                    _ = q.orderedRemove(i);
                    dirty = true;
                    continue;
                };
                validateQueueEntry(entry) catch {
                    daemonWriteErr(io, "daemon: invalid queue entry — recording + dropping\n");
                    try errorsPutPure(a, &root, null, null, null, null, "malformed queue row", unixNow(io));
                    _ = q.orderedRemove(i);
                    dirty = true;
                    continue;
                };
                if (!std.mem.eql(u8, entry.mode, want_mode)) {
                    i += 1;
                    continue;
                }
                const exp = try expandEntry(io, a, &root, &free_grid, entry, host);
                if (exp.remaining_anywhere == 0) {
                    _ = q.orderedRemove(i);
                    dirty = true;
                    continue;
                }
                if (exp.host_candidates.len == 0) {
                    // another host's portion — keep the entry, move on.
                    i += 1;
                    continue;
                }
                // first work: stamp started_at, then re-expand with the
                // completion-timestamp done rule live.
                entry.started_at = unixNow(io);
                q.items[i] = try queueEntryValue(a, entry);
                const exp2 = try expandEntry(io, a, &root, &free_grid, entry, host);
                if (exp2.host_candidates.len > 0) {
                    pick = .{ .queue_index = i, .candidate = exp2.host_candidates[0], .entry = entry };
                }
                dirty = true;
                break;
            }
            if (pick != null) break;
        }
        if (dirty) try indexSave(io, a, root);
        return pick;
    }

    /// `fixtures daemon` — long-running. **Owns all evaluation.** Every
    /// poll it scans the queue-entry array in mode-rank order
    /// (from-identity first, then array order), purges entries with no
    /// remaining candidates anywhere, expands the first entry with
    /// remaining host-platform work (stamping `started_at` on its first
    /// work), and processes ONE candidate. from-identity jobs resolve
    /// the declared channel (zero tokens); from-capture jobs probe
    /// availability via `version_launch` then launch the real harness
    /// session via `prompt_launch` (with a pre-capture review window,
    /// token-consuming, user-confirmed only). A candidate's completion
    /// timestamp (channel date or errors `failed_at`) ≥ the entry's
    /// `started_at` makes it done — crash-resume derives from the
    /// completion ledger, so a capture that died with the daemon left
    /// no channel write and simply re-runs. **The daemon never writes
    /// `fixtures` outside pop processing and never inserts queue
    /// entries.**
    ///
    /// **USER-ONLY**: refuses to start if running inside an agent
    /// (see `assertNotInAgent`). The agent must never run the daemon
    /// — its process tree would pollute the captured
    /// `raw.process_lineage`, and its env vars would contaminate the
    /// capture. See DESIGN.md "user-only daemon" for the rationale and
    /// CONTRIBUTING.md "refresh a fixture" for the correct role split.
    pub fn runFixturesDaemon(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        // parse daemon flags: --write-log, --poll-seconds=N,
        // --capture-review-seconds=N, --capture-timeout-seconds=N.
        var write_log = false;
        var poll_seconds: u64 = 5;
        var review_seconds: u64 = 15;
        var capture_timeout_seconds: u64 = 600;
        {
            var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return EXIT_OUT_OF_MEMORY;
            defer args_it.deinit();
            _ = args_it.skip(); // argv0
            _ = args_it.skip(); // "fixtures"
            _ = args_it.skip(); // "daemon"
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--write-log")) {
                    write_log = true;
                } else if (std.mem.startsWith(u8, arg, "--poll-seconds=")) {
                    poll_seconds = std.fmt.parseInt(u64, arg["--poll-seconds=".len..], 10) catch return EXIT_CONFLICTING_ARG;
                } else if (std.mem.startsWith(u8, arg, "--capture-review-seconds=")) {
                    review_seconds = std.fmt.parseInt(u64, arg["--capture-review-seconds=".len..], 10) catch return EXIT_CONFLICTING_ARG;
                } else if (std.mem.startsWith(u8, arg, "--capture-timeout-seconds=")) {
                    capture_timeout_seconds = std.fmt.parseInt(u64, arg["--capture-timeout-seconds=".len..], 10) catch return EXIT_CONFLICTING_ARG;
                }
            }
        }
        var daemon_log_file_owned: ?std.Io.File = null;
        if (write_log) {
            std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    writeErr(io, MSG_IO);
                    return EXIT_IO;
                },
            };
            const log_file = std.Io.Dir.cwd().createFile(io, "fixtures/.daemon.log", .{}) catch |err| {
                daemonWriteErr(io, "daemon: cannot open fixtures/.daemon.log: ");
                daemonWriteErr(io, @errorName(err));
                daemonWriteErr(io, "\n");
                return EXIT_IO;
            };
            daemon_log_file = log_file;
            daemon_log_file_owned = log_file;
        }
        defer {
            if (daemon_log_file_owned) |log_file| log_file.close(io);
            daemon_log_file = null;
        }

        try assertNotInAgent(a, init);

        daemonWrite(io, "agent-detect-dev fixtures daemon: running\n");
        {
            var buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(buf[0..], "  poll rate: {d}s (from-capture review: {d}s, timeout: {d}s)\n", .{ poll_seconds, review_seconds, capture_timeout_seconds }) catch "  poll rate: 5s\n";
            daemonWrite(io, m);
        }
        daemonWrite(io, "  index file: fixtures/.index.json\n");
        daemonWrite(io, "  control file: fixtures/.daemon.ctl (write pause/resume/stop)\n");
        if (write_log) daemonWrite(io, "  log file: fixtures/.daemon.log\n");
        daemonWrite(io, "  press Ctrl+C to stop\n");

        // decision #12 — one cross-platform control mechanism: the
        // daemon checks `fixtures/.daemon.ctl` every ~1s heartbeat and
        // acts on pause/resume/stop, clearing the file after acting.
        var paused = false;
        var stop_requested = false;
        var phase: enum { idle, pre_capture, post_review } = .idle;
        var pending_capture: ?DaemonPick = null;
        var phase_until: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot };
        var next_poll: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot };

        while (true) {
            const now = std.Io.Clock.Timestamp.now(io, .boot);
            const boot_now_ns = now.raw.nanoseconds;

            // --- control check (every tick) ---
            const ctl = readControlAction(a, io);
            if (ctl) |c| {
                if (std.mem.eql(u8, c, "pause") and !paused) {
                    paused = true;
                    daemonWrite(io, "daemon: pause requested — pausing\n");
                } else if (std.mem.eql(u8, c, "resume") and paused) {
                    paused = false;
                    daemonWrite(io, "daemon: resume requested — resuming\n");
                } else if (std.mem.eql(u8, c, "stop")) {
                    stop_requested = true;
                    daemonWrite(io, "daemon: stop requested — finishing in-flight work then exiting\n");
                }
            }

            if (stop_requested and phase == .idle and pending_capture == null) {
                daemonWrite(io, "daemon: stopped\n");
                return EXIT_OK;
            }
            // a stop during the pre-capture window cancels the pending
            // capture (it has consumed no tokens yet).
            if (stop_requested and phase == .pre_capture and pending_capture != null) {
                daemonWrite(io, "daemon: stop during pre-capture review — canceled the pending capture\n");
                pending_capture = null;
                phase = .idle;
                return EXIT_OK;
            }

            if (paused) {
                daemonWrite(io, "daemon: paused\n");
                try std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_s }, .boot);
                continue;
            }

            switch (phase) {
                .pre_capture => {
                    daemonWrite(io, "daemon: pre-capture review — capture starts in ");
                    const remaining = @max(@divTrunc(phase_until.raw.nanoseconds - boot_now_ns, std.time.ns_per_s) + 1, 1);
                    daemonWriteCount(io, remaining);
                    daemonWrite(io, "s (write stop to fixtures/.daemon.ctl to cancel)\n");
                    if (boot_now_ns >= phase_until.raw.nanoseconds) {
                        const job = pending_capture orelse {
                            phase = .idle;
                            continue;
                        };
                        pending_capture = null;
                        daemonWrite(io, "daemon: starting capture for ");
                        daemonWrite(io, job.candidate.fixture_id);
                        daemonWrite(io, "\n");
                        const ok = runOneComboCapture(a, io, init, job.candidate.fixture_id, capture_timeout_seconds) catch |err| blk: {
                            daemonWriteErr(io, "daemon: capture worker error: ");
                            daemonWriteErr(io, @errorName(err));
                            daemonWriteErr(io, "\n");
                            break :blk false;
                        };
                        phase = .post_review;
                        phase_until = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, review_seconds) * std.time.ns_per_s }, .clock = .boot });
                        if (ok) {
                            daemonWrite(io, "daemon: captured ");
                            daemonWrite(io, job.candidate.fixture_id);
                            daemonWrite(io, "\n");
                        } else {
                            daemonWriteErr(io, "daemon: from-capture failed for ");
                            daemonWriteErr(io, job.candidate.fixture_id);
                            daemonWriteErr(io, " — attempt recorded; retry via `fixtures queue --unsuccessful`\n");
                        }
                        daemonWrite(io, "daemon: capture finished — human review window ");
                        daemonWriteCount(io, review_seconds);
                        daemonWrite(io, "s\n");
                    }
                },
                .post_review => {
                    daemonWrite(io, "daemon: post-capture review\n");
                    if (boot_now_ns >= phase_until.raw.nanoseconds) {
                        phase = .idle;
                        daemonWrite(io, "daemon: review window complete\n");
                    }
                },
                .idle => {
                    if (boot_now_ns < next_poll.raw.nanoseconds) {
                        daemonWrite(io, "daemon: idle\n");
                    } else {
                        // one candidate per poll (decision #10): schedule
                        // the next poll `poll_seconds` out on EVERY path
                        // below.
                        next_poll = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, poll_seconds) * std.time.ns_per_s }, .clock = .boot });
                        const pick = daemonPick(io, a) catch |err| blk: {
                            daemonWriteErr(io, "daemon: pick error: ");
                            daemonWriteErr(io, @errorName(err));
                            daemonWriteErr(io, "\n");
                            break :blk null;
                        };
                        if (pick) |p| {
                            const desc = try describeQueueEntry(a, p.entry);
                            var msg_buf: [320]u8 = undefined;
                            const m = std.fmt.bufPrint(msg_buf[0..], "daemon: processing {s} [{s}]\n", .{ desc, p.entry.mode }) catch "daemon: processing\n";
                            daemonWrite(io, m);

                            if (p.entry.stale_by_missing_entry == true) {
                                try runMissingEntryRegistration(io, a, p.candidate);
                                daemonWrite(io, "daemon: registered ");
                                daemonWrite(io, p.candidate.fixture_id);
                                daemonWrite(io, "\n");
                                continue;
                            }

                            if (std.mem.eql(u8, p.entry.mode, "from-capture")) {
                                if (pending_capture != null) {
                                    daemonWrite(io, "daemon: already have a pending from-capture job — skipping\n");
                                    continue;
                                }
                                pending_capture = p;
                                phase = .pre_capture;
                                phase_until = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, review_seconds) * std.time.ns_per_s }, .clock = .boot });
                                daemonWrite(io, "daemon: from-capture job — announcing ");
                                daemonWriteCount(io, review_seconds);
                                daemonWrite(io, "s before capture (write stop to fixtures/.daemon.ctl to cancel)\n");
                                continue;
                            }

                            const ok = runOneComboIdentity(a, io, p.candidate.fixture_id) catch |err| blk: {
                                daemonWriteErr(io, "daemon: identity worker error: ");
                                daemonWriteErr(io, @errorName(err));
                                daemonWriteErr(io, "\n");
                                break :blk false;
                            };
                            if (ok) {
                                var buf2: [256]u8 = undefined;
                                const msg = std.fmt.bufPrint(buf2[0..], "daemon: declared {s}\n", .{p.candidate.fixture_id}) catch "daemon: declared\n";
                                daemonWrite(io, msg);
                            } else {
                                daemonWriteErr(io, "daemon: from-identity failed for ");
                                daemonWriteErr(io, p.candidate.fixture_id);
                                daemonWriteErr(io, "\n");
                            }
                        } else {
                            next_poll = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, poll_seconds) * std.time.ns_per_s }, .clock = .boot });
                            daemonWrite(io, "daemon: idle, queue empty\n");
                        }
                    }
                },
            }
            // the ~1s tick — also the control-check cadence.
            try std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_s }, .boot);
        }
    }

    /// `fixtures __timeout <seconds> <pid>` — internal watchdog used by
    /// the from-capture worker: sleeps N seconds (1s increments), then
    /// sends SIGTERM to the capture child so a hung harness fails out at
    /// `--capture-timeout-seconds` instead of blocking the poll loop.
    /// Fire-and-forget from the daemon's perspective.
    pub fn runTimeoutWorker(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;
        var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return EXIT_OUT_OF_MEMORY;
        defer args_it.deinit();
        _ = args_it.skip(); // argv0
        _ = args_it.skip(); // "fixtures"
        _ = args_it.skip(); // "__timeout"
        const sec_arg = args_it.next() orelse return EXIT_MISSING_ARG;
        const pid_arg = args_it.next() orelse return EXIT_MISSING_ARG;
        const seconds = std.fmt.parseInt(u64, sec_arg, 10) catch return EXIT_CONFLICTING_ARG;
        const pid = std.fmt.parseInt(u32, pid_arg, 10) catch return EXIT_CONFLICTING_ARG;
        var remaining = seconds;
        while (remaining > 0) : (remaining -= 1) {
            std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_s }, .boot) catch return EXIT_OK;
        }
        killPid(pid);
        return EXIT_OK;
    }

    /// send a terminate signal to a pid (the capture child). SIGTERM on
    /// POSIX; TerminateProcess on Windows — the single portable control
    /// surface the from-capture timeout relies on.
    fn killPid(pid: u32) void {
        if (builtin.os.tag == .windows) {
            const handle = OpenProcess(0x0001, 0, pid); // PROCESS_TERMINATE
            if (handle != null) {
                _ = TerminateProcess(handle.?, 1);
                _ = CloseHandle(handle.?);
            }
            return;
        }
        std.posix.kill(@intCast(pid), .TERM) catch {};
    }

    /// the current executable's path in a fixed buffer, or null on
    /// failure (`std.process.executablePath` returns the length).
    fn selfPath(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
        const len = std.process.executablePath(io, buf) catch return null;
        if (len == 0) return null;
        return buf[0..len];
    }

    /// emit a decimal count on stdout (one allocation-free write).
    fn writeCount(io: std.Io, n: anytype) void {
        var buf: [32]u8 = undefined;
        writeOut(io, std.fmt.bufPrint(&buf, "{d}", .{n}) catch return);
    }

    /// emit a decimal count on stderr (one allocation-free write).
    fn writeErrCount(io: std.Io, n: anytype) void {
        var buf: [32]u8 = undefined;
        writeErr(io, std.fmt.bufPrint(&buf, "{d}", .{n}) catch return);
    }

    /// emit a decimal count through the daemon stdout log.
    fn daemonWriteCount(io: std.Io, n: anytype) void {
        var buf: [32]u8 = undefined;
        daemonWrite(io, std.fmt.bufPrint(&buf, "{d}", .{n}) catch return);
    }

    /// emit a decimal count through the daemon stderr log.
    fn daemonWriteErrCount(io: std.Io, n: anytype) void {
        var buf: [32]u8 = undefined;
        daemonWriteErr(io, std.fmt.bufPrint(&buf, "{d}", .{n}) catch return);
    }

    /// read `fixtures/.daemon.ctl`, clear it, and return the action word
    /// (`pause` / `resume` / `stop`) or null when absent/empty. The
    /// daemon clears the file after acting (decision #12).
    fn readControlAction(a: std.mem.Allocator, io: std.Io) ?[]const u8 {
        const data = std.Io.Dir.cwd().readFileAlloc(io, "fixtures/.daemon.ctl", a, @enumFromInt(4096)) catch return null;
        // no `a.free(data)` — the returned word aliases `data` (Zig 0.16
        // arena free-list would reclaim it into the daemon's next
        // allocations, clobbering the action word mid-use).
        std.Io.Dir.cwd().deleteFile(io, "fixtures/.daemon.ctl") catch {};
        const t = std.mem.trim(u8, data, " \t\r\n");
        if (t.len == 0) return null;
        if (std.mem.eql(u8, t, "pause") or std.mem.eql(u8, t, "resume") or std.mem.eql(u8, t, "stop")) return t;
        return null;
    }

    /// true iff the timestamp (unix secs) is older than
    /// `threshold_minutes`.
    fn isStale(io: std.Io, ts: i64, threshold_minutes: i64) bool {
        const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
        return now - ts > threshold_minutes * 60;
    }

    /// refuse to start the daemon if the current process is inside
    /// an agent. Two checks, both fail-closed:
    ///   - env markers: refuse if any of the fixtures agent-marker env
    ///     vars is set
    ///   - process ancestry: refuse if any ancestor's basename
    ///     matches a fixtures agent proc name
    fn assertNotInAgent(a: std.mem.Allocator, init: std.process.Init) !void {
        const io = init.io;
        // env markers — every marker declared by the harness rules (the
        // launcher model-selector markers included) refuses the daemon.
        var it = init.environ_map.iterator();
        while (it.next()) |kv| {
            for (rulesForHarnesses) |r| {
                for (r.env_markers) |m| {
                    if (std.mem.eql(u8, kv.key_ptr.*, m)) {
                        daemonWriteErr(io, "fixtures daemon: refusing to start — env marker ");
                        daemonWriteErr(io, m);
                        daemonWriteErr(io, " is set. This command must be run by a user, not inside an agent.\n");
                        return error.RunningInAgent;
                    }
                }
            }
        }

        // process ancestry — the rules' `binary_names` plus the pending
        // harnesses without a rule yet.
        const anc = ancestorInfo(a, io);
        for (anc.names) |n| {
            for (rulesForHarnesses) |r| {
                for (r.binary_names) |p| {
                    if (std.mem.eql(u8, n, p)) {
                        daemonWriteErr(io, "fixtures daemon: refusing to start — ancestor process ");
                        daemonWriteErr(io, n);
                        daemonWriteErr(io, " is a fixtures agent. This command must be run by a user, not inside an agent.\n");
                        return error.RunningInAgent;
                    }
                }
            }
            for (pending_binary_names) |p| {
                if (std.mem.eql(u8, n, p)) {
                    daemonWriteErr(io, "fixtures daemon: refusing to start — ancestor process ");
                    daemonWriteErr(io, n);
                    daemonWriteErr(io, " is a fixtures agent. This command must be run by a user, not inside an agent.\n");
                    return error.RunningInAgent;
                }
            }
        }
    }
} else struct {}; // end pub const dev
