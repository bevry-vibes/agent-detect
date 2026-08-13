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
// watches the sqlite `queue` table and, for each queue row, materializes
// `pending` rows it processes (runFixturesCapture runs in-process in
// the session the daemon launched). The released
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
const EXIT_SQLITE_QUERY = core.EXIT_SQLITE_QUERY;
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
const MSG_SQLITE_QUERY = core.MSG_SQLITE_QUERY;
const MSG_IO = core.MSG_IO;
const writeUnableToDetect = core.writeUnableToDetect;

const HarnessRule = rules.HarnessRule;
const ProviderRule = rules.ProviderRule;
const ModelRule = rules.ModelRule;
const rulesForHarnesses = rules.rulesForHarnesses;
const rulesForProviders = rules.rulesForProviders;
const rulesForModels = rules.rulesForModels;
const canonicalIdFor = rules.canonicalIdFor;
const harnessRuleForName = rules.harnessRuleForName;
const canonicalFilterDim = rules.canonicalFilterDim;
const envValueAllowed = rules.envValueAllowed;
const harnessRuleForFixtureId = rules.harnessRuleForFixtureId;

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
        \\state: fixtures/index.sqlite3 holds four tables — `fixtures` (one row
        \\per captured 4-tuple harness/provider/model/platform, carrying the
        \\available/successful markers, the capturing `agent_detect_version`, and
        \\per-channel generation columns), `queue` (the work queue), `pending`
        \\(per-job work items under a popped queue row; crash-resume safe), and
        \\`invalid` (bad-id rows for dev-agent remedy). fixtures/<id>.json are the
        \\generated fixtures — top-level per-channel keys `from-identity` /
        \\`from-capture` / `from-capture-raw`, each channel object carrying
        \\`identify` + both trailer variants (the root `trailer`/`origin` keys are
        \\gone). Queue rows with missing dims are seeds: the daemon expands them
        \\into `pending` rows over fixtures recipes (full combos), never a scope.
        \\
        \\daemon flags:
        \\  --write-log                 tee daemon output to fixtures/daemon.log
        \\  --poll-seconds=N            base poll interval (default 5)
        \\  --capture-review-seconds=N  pre/post capture pause (default 15)
        \\  --capture-timeout-seconds=N from-capture worker timeout (default 600)
        \\
        \\control: write pause/resume/stop to fixtures/daemon.ctl (checked every
        \\~1s; the daemon clears it after acting). Ctrl+C is the graceful stop.
        \\
        \\subcommands (see each subcommand's `--help` for its flags — modes,
        \\filters, and scope flags are shared and documented once):
        \\  (none), help, --help, -h   this help
        \\  daemon                     pop host-platform queue rows from
        \\                              fixtures/index.sqlite3, materialize `pending`
        \\                              rows, and evaluate them (identity: declared
        \\                              generation; capture: real harness session) —
        \\                              run as a user, never inside an agent;
        \\                              --write-log also writes all daemon output
        \\                              to fixtures/daemon.log
        \\  capture                    capture the current session into a single
        \\                              fixtures/<id>.json + a fixtures row
        \\                              (spawned by the daemon; fixtures only)
        \\  queue                      enumerate + upsert queue rows (no
        \\                              evaluation; no scope flag → seed with
        \\                              the positive dims)
        \\  dequeue                    DELETE matching queue rows (filters
        \\                              required; never touches fixtures)
        \\
        \\exit codes: 0 = ok, 2 = unrecognised argument, 3 = conflicting argument,
        \\4 = missing required arguments, 5 = incompatible environment, 6 = incomplete
        \\environment, 8 = unable to detect, 11 = out of memory, 12 = sqlite query error,
        \\13 = filesystem I/O error
        \\
    ;

    /// flags shared by `fixtures queue` and `fixtures dequeue` (modes,
    /// filters, scope flags). Referenced by both subcommand usages so
    /// the common surface is documented once.
    pub const queueDequeueFlags =
        \\refresh modes (queue stamps rows, dequeue filters them; both together
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
        \\scope flags (each selects a candidate set that is enqueued per selected
        \\mode; compose with the dim filters above; dequeue matches the stored
        \\marker instead):
        \\  --all            every fixtures row (the default scope made explicit)
        \\  --stale-by-days=N      age threshold in days
        \\  --stale-by-hours=N     age threshold in hours
        \\  --stale-by-minutes=N   age threshold in minutes — the daemon skips
        \\                   only when the fixture is still age-fresh
        \\  --stale-by-version  version-marker scope: re-capture when the live
        \\                   harness version differs from the captured one
        \\  --stale-by-detect  re-capture when the fixture's `agent_detect_version`
        \\                   is NULL or differs from this binary's version
        \\  --stale-by-hash   re-capture when the stored per-channel generation
        \\                   hash is NULL or differs from the current fixture
        \\                   file's channel object (mode flags pick the channel;
        \\                   no mode flag checks both, one row per stale channel)
        \\  --recipes        every known recipe (host platform)
        \\  --missing-fixture-file  recipes whose fixtures/<id>.json is absent
        \\  --available      enqueue fixtures rows whose available marker is 1
        \\  --unavailable    enqueue fixtures rows whose available marker is 0
        \\  --successful     enqueue fixtures rows whose successful marker is 1
        \\  --unsuccessful   enqueue fixtures rows whose successful marker is 0
        \\                   (the designated vector for captures whose detection
        \\                   was partial — valid ids, last attempt failed)
        \\
    ;

    /// usage for `fixtures queue` — printed by `fixtures queue --help`
    /// and on queue argument errors. Subcommand-scoped so an error never
    /// dumps the whole namespace help.
    pub const queueUsage =
        \\agent-detect fixtures queue — enumerate + upsert queue rows (no evaluation)
        \\
        \\usage: agent-detect fixtures queue [scope] [filters] [mode]
        \\
        \\With a scope flag, every candidate is upserted into `queue` per selected
        \\mode (no mode flag → both `--from-identity` and `--from-capture` rows).
        \\Without one, a seed row is created from the positive dims (`--harness=`/
        \\`--provider=`/`--model=`/`--platform=` or the composite `--agent=`/
        \\`--fixture=`) with the rest `null` — the daemon expands seeds over
        \\the known recipes.
        \\
    ++ queueDequeueFlags ++
        \\exit codes: 0 = ok, 2 = unrecognised argument, 3 = conflicting argument,
        \\4 = missing required arguments, 11 = out of memory, 12 = sqlite query error,
        \\13 = filesystem I/O error
        \\
    ;

    /// usage for `fixtures dequeue` — printed by `fixtures dequeue --help`
    /// and on dequeue argument errors.
    pub const dequeueUsage =
        \\agent-detect fixtures dequeue — DELETE matching queue rows (never touches fixtures)
        \\
        \\usage: agent-detect fixtures dequeue [scope] [filters] [mode]
        \\
        \\Deletes every `queue` row matching the filters/scope. Filters are
        \\required; no evaluation happens, nothing is captured. Scope flags match
        \\the stored markers the queue command stamped; no mode flag matches all
        \\modes.
        \\
    ++ queueDequeueFlags ++
        \\exit codes: 0 = ok, 2 = unrecognised argument, 3 = conflicting argument,
        \\4 = missing required arguments, 11 = out of memory, 12 = sqlite query error,
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
    /// keys: `platform_id`, then the `detectable` + `detected` dimension
    /// arrays adjacent to it, then the shapeless runtime observations.
    /// Returns a heap-allocated `std.json.Value`; the caller owns it.
    fn buildRaw(a: std.mem.Allocator, d: *const Detection, env: *const std.process.Environ.Map) !std.json.Value {
        const V = std.json.Value;
        const home = reporterHome(env);
        var raw: V = .{ .object = .empty };
        // platform id (compile-time constant) is emitted as a top-level
        // raw key so a maintainer reading a fixture knows which
        // platform it was captured on, even before they read the
        // canonical `agent_id` (which is also platform-tagged via the
        // `fixture_id` filename).
        try raw.object.put(a, "platform_id", .{ .string = platformId() });
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
        // harness_version is the matched rule's declared release version
        // (e.g. "1.2.3") when the rule tracks one. Only emitted when
        // the rule declared it — null rules (most currently) skip the
        // field. It is the maintainer-curated version string from the
        // rule, NOT a runtime observation; surfaced under raw so a
        // fixture shows which version the maintainer expected when
        // authoring the rule.
        if (d.harness_version) |v| {
            try raw.object.put(a, "harness_version", .{ .string = v });
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
        const raw_v = try buildRaw(a, &d, init.environ_map);
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
    // SQLite storage via the `sqlite3` CLI (two tables: fixtures + queue)
    // ------------------------------------------------------------------

    /// Writes/reads shell out to the
    /// system `sqlite3` binary (single-file `fixtures/index.sqlite3`).
    const INDEX_DB_PATH = "fixtures/index.sqlite3";

    /// Spawn `sqlite3 -json <db> <sql>` and return its stdout. Empty for
    /// statements that return no rows. Caller owns the returned slice —
    /// do NOT free it here (Zig 0.16 arena free-list: freeing this
    /// most-recent allocation lets the caller's next allocations reclaim
    /// and clobber the bytes mid-parse).
    /// Does NOT create the dir or ensure the schema (see `sqliteQuery`).
    /// Deliberate mirror of the released-binary `kiloSqliteJson` — this
    /// one is fixed to `fixtures/index.sqlite3` and compiled out of the
    /// released binary via the dev-gated block.
    fn sqliteRun(a: std.mem.Allocator, io: std.Io, sql: []const u8) ![]u8 {
        var argv_buf = [_][]const u8{ "sqlite3", "-json", "-batch", INDEX_DB_PATH, sql };
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

    /// Ensure the `fixtures/` dir and the four-table schema exist (idempotent).
    /// Called before every query.
    fn ensureSchema(a: std.mem.Allocator, io: std.Io) !void {
        std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.FilesystemIoError,
        };
        _ = try sqliteRun(a, io,
            \\PRAGMA busy_timeout = 5000;
            \\CREATE TABLE IF NOT EXISTS fixtures (
            \\    harness                 TEXT NOT NULL,
            \\    provider                TEXT NOT NULL,
            \\    model                   TEXT NOT NULL,
            \\    platform                TEXT NOT NULL,
            \\    runner                  INTEGER NOT NULL,
            \\    generated_at            INTEGER NOT NULL,
            \\    harness_version         TEXT,
            \\    available               INTEGER,
            \\    successful              INTEGER,
            \\    agent_detect_version    TEXT,
            \\    identity_generation_at  INTEGER,
            \\    identity_generation_hash TEXT,
            \\    capture_generation_at   INTEGER,
            \\    capture_generation_hash TEXT,
            \\    agent_id                TEXT,
            \\    fixture_id              TEXT,
            \\    PRIMARY KEY (harness, provider, model, platform)
            \\);
            \\CREATE UNIQUE INDEX IF NOT EXISTS fixtures_fixture_id ON fixtures (fixture_id);
            \\CREATE TABLE IF NOT EXISTS queue (
            \\    queue_id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    harness                   TEXT,
            \\    provider                  TEXT,
            \\    model                     TEXT,
            \\    platform                  TEXT,
            \\    scope_recipes             INTEGER,
            \\    scope_missing_fixture_file INTEGER,
            \\    stale_by_minutes          INTEGER,
            \\    stale_by_version          INTEGER,
            \\    stale_by_detect           INTEGER,
            \\    stale_by_hash             INTEGER,
            \\    available                 INTEGER,
            \\    successful                INTEGER,
            \\    runner                    INTEGER NOT NULL,
            \\    created_at                INTEGER NOT NULL,
            \\    mode                      TEXT NOT NULL
            \\);
            \\CREATE UNIQUE INDEX IF NOT EXISTS queue_dedupe
            \\    ON queue (COALESCE(harness,''), COALESCE(provider,''), COALESCE(model,''),
            \\                COALESCE(platform,''), COALESCE(scope_recipes,0),
            \\                COALESCE(scope_missing_fixture_file,0),
            \\                COALESCE(stale_by_minutes,0),
            \\                COALESCE(stale_by_version,0),
            \\                COALESCE(stale_by_detect,0),
            \\                COALESCE(stale_by_hash,0),
            \\                COALESCE(available,0), COALESCE(successful,0), mode);
            \\CREATE TABLE IF NOT EXISTS pending (
            \\    queue_id    INTEGER NOT NULL,
            \\    fixture_id  TEXT NOT NULL,
            \\    started_at  INTEGER,
            \\    finished_at INTEGER,
            \\    UNIQUE (queue_id, fixture_id)
            \\);
            \\CREATE TABLE IF NOT EXISTS invalid (
            \\    fixture_id  TEXT,
            \\    agent_id    TEXT,
            \\    harness_id  TEXT,
            \\    provider_id TEXT,
            \\    model_id    TEXT,
            \\    platform_id TEXT,
            \\    reason      TEXT,
            \\    created_at  INTEGER
            \\);
            \\
        );
    }

    /// Ensure schema, then run `sql` and return its stdout (JSON for
    /// SELECT). Caller owns the returned slice.
    fn sqliteQuery(a: std.mem.Allocator, io: std.Io, sql: []const u8) ![]u8 {
        try ensureSchema(a, io);
        return sqliteRun(a, io, sql);
    }

    /// One row in the `queue` table. `mode` is the refresh flavour
    /// (`"from-identity" | "from-capture"`) — always stamped explicitly by
    /// `fixtures queue` (no default), used as the daemon's pop-order +
    /// worker selector, and part of `queue_dedupe` so identity and
    /// capture rows for the same candidate coexist. `stale_by_minutes`
    /// is the single age marker (days/hours flags convert to minutes at
    /// stamp time); `stale_by_version` / `stale_by_detect` /
    /// `stale_by_hash` mark the other staleness vectors; `available` /
    /// `successful` are pure scope markers. `queue_id` is the row's
    /// autoincrement key (excluded from `queue_dedupe`).
    const QueueRow = struct {
        queue_id: i64 = 0,
        harness: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        model: ?[]const u8 = null,
        platform: ?[]const u8 = null,
        scope_recipes: ?i64 = null,
        scope_missing_fixture_file: ?i64 = null,
        stale_by_minutes: ?i64 = null,
        stale_by_version: ?i64 = null,
        stale_by_detect: ?i64 = null,
        stale_by_hash: ?i64 = null,
        available: ?i64 = null,
        successful: ?i64 = null,
        runner: i64 = 0,
        created_at: i64 = 0,
        mode: []const u8 = "",
    };

    /// One row in the `fixtures` state table (always full dims; platform
    /// may be any recorded platform). `harness_version` is the version
    /// captured by a live `--version` call during the capture; null when
    /// the version couldn't be read or the row was declared
    /// (`from-identity`). `available`/`successful` are daemon-written
    /// outcome markers; `agent_detect_version` is the capturing binary's
    /// version (NULL = stale / never captured); the four generation
    /// columns track per-channel (`from-identity` / `from-capture`)
    /// write times + BLAKE3 hashes; `agent_id`/`fixture_id` are the
    /// derived `#`-joined ids, written by every upsert.
    const FixtureRow = struct {
        harness: []const u8,
        provider: []const u8,
        model: []const u8,
        platform: []const u8,
        runner: i64,
        generated_at: i64,
        harness_version: ?[]const u8 = null,
        available: ?i64 = null,
        successful: ?i64 = null,
        agent_detect_version: ?[]const u8 = null,
        identity_generation_at: ?i64 = null,
        identity_generation_hash: ?[]const u8 = null,
        capture_generation_at: ?i64 = null,
        capture_generation_hash: ?[]const u8 = null,
    };

    /// One row in the `pending` table — a single work item under a
    /// popped `queue` row (`queue_id` + a concrete `fixture_id`).
    /// `started_at`/`finished_at` make crash-resume safe; the
    /// `UNIQUE(queue_id, fixture_id)` index keeps re-materialization
    /// idempotent.
    const PendingRow = struct {
        queue_id: i64,
        fixture_id: []const u8,
        started_at: ?i64 = null,
        finished_at: ?i64 = null,
    };

    /// One row in the `invalid` table — a bad-id row (unknown fixture
    /// file, no-launch from-capture candidate, malformed seed) that the
    /// dev agent reads for remedy. Written by queue time, seed
    /// expansion, and `--missing-fixture-entry`; never evaluated.
    const InvalidRow = struct {
        fixture_id: ?[]const u8 = null,
        agent_id: ?[]const u8 = null,
        harness_id: ?[]const u8 = null,
        provider_id: ?[]const u8 = null,
        model_id: ?[]const u8 = null,
        platform_id: ?[]const u8 = null,
        reason: []const u8,
        created_at: i64 = 0,
    };

    /// current unix epoch seconds (staleness source / queue order).
    fn unixNow(io: std.Io) i64 {
        const ts = std.Io.Clock.Timestamp.now(io, .real);
        return ts.raw.toSeconds();
    }

    /// SQL-escape a string literal (single-quote doubling). Dims are
    /// alphanumeric so this is mostly defensive.
    fn sqlQuote(a: std.mem.Allocator, s: []const u8) ![]u8 {
        if (std.mem.indexOfScalar(u8, s, '\'') == null) {
            return std.fmt.allocPrint(a, "'{s}'", .{s});
        }
        var out: std.ArrayList(u8) = .empty;
        try out.append(a, '\'');
        for (s) |c| {
            if (c == '\'') try out.append(a, '\'');
            try out.append(a, c);
        }
        try out.append(a, '\'');
        return out.toOwnedSlice(a);
    }

    /// render an optional string as a quoted literal or NULL.
    fn sqlOptStr(a: std.mem.Allocator, opt: ?[]const u8) ![]u8 {
        if (opt) |s| return sqlQuote(a, s);
        return a.dupe(u8, "NULL");
    }

    /// render an optional integer as its value or NULL (allocated).
    fn sqlOptInt(a: std.mem.Allocator, v: ?i64) ![]u8 {
        if (v) |x| return std.fmt.allocPrint(a, "{d}", .{x});
        return a.dupe(u8, "NULL");
    }

    /// `INSERT OR REPLACE INTO queue` — idempotent via `queue_dedupe`.
    /// `queue_id` is autoincrement; never set by callers.
    fn upsertQueueRow(a: std.mem.Allocator, io: std.Io, row: QueueRow) !void {
        const h = try sqlOptStr(a, row.harness);
        defer a.free(h);
        const p = try sqlOptStr(a, row.provider);
        defer a.free(p);
        const m = try sqlOptStr(a, row.model);
        defer a.free(m);
        const pl = try sqlOptStr(a, row.platform);
        defer a.free(pl);
        const sr = try sqlOptInt(a, row.scope_recipes);
        defer a.free(sr);
        const smf = try sqlOptInt(a, row.scope_missing_fixture_file);
        defer a.free(smf);
        const sd = try sqlOptInt(a, row.stale_by_minutes);
        defer a.free(sd);
        const sv = try sqlOptInt(a, row.stale_by_version);
        defer a.free(sv);
        const sdet = try sqlOptInt(a, row.stale_by_detect);
        defer a.free(sdet);
        const shash = try sqlOptInt(a, row.stale_by_hash);
        defer a.free(shash);
        const av = try sqlOptInt(a, row.available);
        defer a.free(av);
        const succ = try sqlOptInt(a, row.successful);
        defer a.free(succ);
        const sql = try std.fmt.allocPrint(
            a,
            "INSERT OR REPLACE INTO queue(harness,provider,model,platform,scope_recipes,scope_missing_fixture_file,stale_by_minutes,stale_by_version,stale_by_detect,stale_by_hash,available,successful,runner,created_at,mode) VALUES({s},{s},{s},{s},{s},{s},{s},{s},{s},{s},{s},{s},{d},{d},{s})",
            .{ h, p, m, pl, sr, smf, sd, sv, sdet, shash, av, succ, row.runner, row.created_at, try sqlQuote(a, row.mode) },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// `INSERT OR REPLACE INTO fixtures` — state, written only by
    /// `fixtures capture`, the identity worker, and the daemon. Derived
    /// `agent_id`/`fixture_id` are maintained here (authoritative for DB
    /// joins; filenames keep the dash-joined form).
    fn upsertFixture(a: std.mem.Allocator, io: std.Io, f: FixtureRow) !void {
        const agent_id = try derivedAgentId(a, f.harness, f.provider, f.model);
        defer a.free(agent_id);
        const fixture_id = try derivedFixtureId(a, f.harness, f.provider, f.model, f.platform);
        defer a.free(fixture_id);
        const sql = try std.fmt.allocPrint(
            a,
            "INSERT OR REPLACE INTO fixtures(harness,provider,model,platform,runner,generated_at,harness_version,available,successful,agent_detect_version,identity_generation_at,identity_generation_hash,capture_generation_at,capture_generation_hash,agent_id,fixture_id) VALUES({s},{s},{s},{s},{d},{d},{s},{s},{s},{s},{s},{s},{s},{s},{s},{s})",
            .{
                try sqlQuote(a, f.harness),                 try sqlQuote(a, f.provider),
                try sqlQuote(a, f.model),                   try sqlQuote(a, f.platform),
                f.runner,                                   f.generated_at,
                try sqlOptStr(a, f.harness_version),        try sqlOptInt(a, f.available),
                try sqlOptInt(a, f.successful),             try sqlOptStr(a, f.agent_detect_version),
                try sqlOptInt(a, f.identity_generation_at), try sqlOptStr(a, f.identity_generation_hash),
                try sqlOptInt(a, f.capture_generation_at),  try sqlOptStr(a, f.capture_generation_hash),
                try sqlQuote(a, agent_id),                  try sqlQuote(a, fixture_id),
            },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// every `fixtures` row (for `--all` / stale-scope enumeration).
    fn selectFixtures(a: std.mem.Allocator, io: std.Io) ![]FixtureRow {
        const out = try sqliteQuery(a, io, "SELECT harness,provider,model,platform,runner,generated_at,harness_version,available,successful,agent_detect_version,identity_generation_at,identity_generation_hash,capture_generation_at,capture_generation_hash FROM fixtures");
        defer a.free(out);
        if (out.len == 0) return &.{};
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return &.{};
        return jsonToFixtures(a, parsed.value);
    }

    fn jsonToFixtures(a: std.mem.Allocator, v: std.json.Value) ![]FixtureRow {
        if (v != .array) return &.{};
        var rows: std.ArrayListUnmanaged(FixtureRow) = .empty;
        errdefer rows.deinit(a);
        for (v.array.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            rows.append(a, .{
                .harness = sjstr(o, "harness"),
                .provider = sjstr(o, "provider"),
                .model = sjstr(o, "model"),
                .platform = sjstr(o, "platform"),
                .runner = sjint(o, "runner"),
                .generated_at = sjint(o, "generated_at"),
                .harness_version = jstr(o, "harness_version"),
                .available = jint(o, "available"),
                .successful = jint(o, "successful"),
                .agent_detect_version = jstr(o, "agent_detect_version"),
                .identity_generation_at = jint(o, "identity_generation_at"),
                .identity_generation_hash = jstr(o, "identity_generation_hash"),
                .capture_generation_at = jint(o, "capture_generation_at"),
                .capture_generation_hash = jstr(o, "capture_generation_hash"),
            }) catch continue;
        }
        return rows.toOwnedSlice(a);
    }

    fn jsonToQueueRows(a: std.mem.Allocator, v: std.json.Value) ![]QueueRow {
        if (v != .array) return &.{};
        var rows: std.ArrayListUnmanaged(QueueRow) = .empty;
        errdefer rows.deinit(a);
        for (v.array.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            const row = jsonToQueueRow(o) catch continue;
            try rows.append(a, row);
        }
        return rows.toOwnedSlice(a);
    }

    fn jsonToQueueRow(o: std.json.ObjectMap) !QueueRow {
        return .{
            .queue_id = sjint(o, "queue_id"),
            .harness = jstr(o, "harness"),
            .provider = jstr(o, "provider"),
            .model = jstr(o, "model"),
            .platform = jstr(o, "platform"),
            .scope_recipes = jint(o, "scope_recipes"),
            .scope_missing_fixture_file = jint(o, "scope_missing_fixture_file"),
            .stale_by_minutes = jint(o, "stale_by_minutes"),
            .stale_by_version = jint(o, "stale_by_version"),
            .stale_by_detect = jint(o, "stale_by_detect"),
            .stale_by_hash = jint(o, "stale_by_hash"),
            .available = jint(o, "available"),
            .successful = jint(o, "successful"),
            .runner = sjint(o, "runner"),
            .created_at = sjint(o, "created_at"),
            .mode = sjstr(o, "mode"),
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

    /// true iff a `fixtures` row exists for the given dims.
    fn fixtureExists(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            a,
            "SELECT COUNT(*) AS c FROM fixtures WHERE harness={s} AND provider={s} AND model={s} AND platform={s}",
            .{ try sqlQuote(a, h), try sqlQuote(a, p), try sqlQuote(a, m), try sqlQuote(a, plat) },
        );
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return false;
        if (parsed.value != .array or parsed.value.array.items.len == 0) return false;
        const o = parsed.value.array.items[0];
        if (o != .object) return false;
        return sjint(o.object, "c") > 0;
    }

    /// the `fixtures` row for the given dims, or null if absent.
    fn fixtureRow(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !?FixtureRow {
        const sql = try std.fmt.allocPrint(
            a,
            "SELECT harness,provider,model,platform,runner,generated_at,harness_version,available,successful,agent_detect_version,identity_generation_at,identity_generation_hash,capture_generation_at,capture_generation_hash FROM fixtures WHERE harness={s} AND provider={s} AND model={s} AND platform={s}",
            .{ try sqlQuote(a, h), try sqlQuote(a, p), try sqlQuote(a, m), try sqlQuote(a, plat) },
        );
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return null;
        const rows = try jsonToFixtures(a, parsed.value);
        if (rows.len == 0) return null;
        return rows[0];
    }

    /// read the oldest platform-eligible queue row (SELECT only — the row
    /// stays queued until its `pending` rows drain; see `runFixturesDaemon`).
    /// Returns null when empty. Non-host-platform rows are never selected.
    fn popQueueRow(a: std.mem.Allocator, io: std.Io) !?QueueRow {
        // sweep ordering: from-identity, then from-capture — cheaper/declared
        // work always precedes token-consuming captures.
        const host = platformId();
        const sql = try std.fmt.allocPrint(
            a,
            "SELECT queue_id,harness,provider,model,platform,scope_recipes,scope_missing_fixture_file,stale_by_minutes,stale_by_version,stale_by_detect,stale_by_hash,available,successful,runner,created_at,mode FROM queue WHERE platform IS NULL OR platform = {s} ORDER BY CASE mode WHEN 'from-identity' THEN 0 ELSE 1 END, created_at,rowid LIMIT 1",
            .{try sqlQuote(a, host)},
        );
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        if (out.len == 0) return null;
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return null;
        const rows = try jsonToQueueRows(a, parsed.value);
        if (rows.len == 0) return null;
        return rows[0];
    }

    /// the `queue` row for a `queue_id`, or null if absent (the pending
    /// protocol reads the row's mode during crash-resume).
    fn queueRowById(a: std.mem.Allocator, io: std.Io, queue_id: i64) !?QueueRow {
        const sql = try std.fmt.allocPrint(
            a,
            "SELECT queue_id,harness,provider,model,platform,scope_recipes,scope_missing_fixture_file,stale_by_minutes,stale_by_version,stale_by_detect,stale_by_hash,available,successful,runner,created_at,mode FROM queue WHERE queue_id={d}",
            .{queue_id},
        );
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        if (out.len == 0) return null;
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return null;
        const rows = try jsonToQueueRows(a, parsed.value);
        if (rows.len == 0) return null;
        return rows[0];
    }

    /// delete a queue row by its `queue_id` (used when its pending rows
    /// drain or when validation fails at pop).
    fn deleteQueueRowById(a: std.mem.Allocator, io: std.Io, queue_id: i64) !void {
        const sql = try std.fmt.allocPrint(a, "DELETE FROM queue WHERE queue_id={d}", .{queue_id});
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// `INSERT OR IGNORE INTO pending` — materialize work items for a
    /// popped queue row. The `UNIQUE(queue_id, fixture_id)` index makes
    /// re-materialization (and crash-resume) idempotent.
    fn insertPendingRow(a: std.mem.Allocator, io: std.Io, queue_id: i64, fixture_id: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            a,
            "INSERT OR IGNORE INTO pending(queue_id,fixture_id) VALUES({d},{s})",
            .{ queue_id, try sqlQuote(a, fixture_id) },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// the oldest unfinished pending row for a `queue_id`, or null when
    /// drained (all finished).
    fn nextUnfinishedPending(a: std.mem.Allocator, io: std.Io, queue_id: i64) !?PendingRow {
        const sql = try std.fmt.allocPrint(
            a,
            "SELECT queue_id,fixture_id,started_at,finished_at FROM pending WHERE queue_id={d} AND finished_at IS NULL ORDER BY fixture_id,rowid LIMIT 1",
            .{queue_id},
        );
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        if (out.len == 0) return null;
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return null;
        if (parsed.value != .array or parsed.value.array.items.len == 0) return null;
        const o = parsed.value.array.items[0];
        if (o != .object) return null;
        return .{
            .queue_id = sjint(o.object, "queue_id"),
            .fixture_id = sjstr(o.object, "fixture_id"),
            .started_at = jint(o.object, "started_at"),
            .finished_at = jint(o.object, "finished_at"),
        };
    }

    /// mark a pending row started (crash-resume signal).
    fn markPendingStarted(a: std.mem.Allocator, io: std.Io, queue_id: i64, fixture_id: []const u8, started_at: i64) !void {
        const sql = try std.fmt.allocPrint(
            a,
            "UPDATE pending SET started_at={d} WHERE queue_id={d} AND fixture_id={s}",
            .{ started_at, queue_id, try sqlQuote(a, fixture_id) },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// mark a pending row finished.
    fn markPendingFinished(a: std.mem.Allocator, io: std.Io, queue_id: i64, fixture_id: []const u8, finished_at: i64) !void {
        const sql = try std.fmt.allocPrint(
            a,
            "UPDATE pending SET finished_at={d} WHERE queue_id={d} AND fixture_id={s}",
            .{ finished_at, queue_id, try sqlQuote(a, fixture_id) },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// true when every pending row for `queue_id` is finished.
    fn pendingDrained(a: std.mem.Allocator, io: std.Io, queue_id: i64) !bool {
        const sql = try std.fmt.allocPrint(
            a,
            "SELECT COUNT(*) AS c FROM pending WHERE queue_id={d} AND finished_at IS NULL",
            .{queue_id},
        );
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        const parsed = std.json.parseFromSlice(std.json.Value, a, out, .{}) catch return true;
        if (parsed.value != .array or parsed.value.array.items.len == 0) return true;
        const o = parsed.value.array.items[0];
        if (o != .object) return true;
        return sjint(o.object, "c") == 0;
    }

    /// delete a drained queue row's pending rows and the queue row itself.
    fn clearPendingAndQueueRow(a: std.mem.Allocator, io: std.Io, queue_id: i64) !void {
        const sql = try std.fmt.allocPrint(
            a,
            "DELETE FROM pending WHERE queue_id={d}; DELETE FROM queue WHERE queue_id={d};",
            .{ queue_id, queue_id },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// `INSERT INTO invalid` — a bad-id row for dev-agent remedy.
    fn insertInvalid(a: std.mem.Allocator, io: std.Io, row: InvalidRow) !void {
        const sql = try std.fmt.allocPrint(
            a,
            "INSERT INTO invalid(fixture_id,agent_id,harness_id,provider_id,model_id,platform_id,reason,created_at) VALUES({s},{s},{s},{s},{s},{s},{s},{d})",
            .{
                try sqlOptStr(a, row.fixture_id), try sqlOptStr(a, row.agent_id),
                try sqlOptStr(a, row.harness_id), try sqlOptStr(a, row.provider_id),
                try sqlOptStr(a, row.model_id),   try sqlOptStr(a, row.platform_id),
                try sqlQuote(a, row.reason),      row.created_at,
            },
        );
        defer a.free(sql);
        _ = try sqliteQuery(a, io, sql);
    }

    /// `DELETE FROM queue` matching the filter. Returns rows deleted.
    fn deleteQueueRows(a: std.mem.Allocator, io: std.Io, f: FilterOptions) !usize {
        var where = std.ArrayList(u8).empty;
        defer where.deinit(a);
        try where.appendSlice(a, "WHERE 1=1");
        if (f.harness.len > 0) try where.appendSlice(a, appendCond(a, "harness", f.harness) catch return 0);
        if (f.provider.len > 0) try where.appendSlice(a, appendCond(a, "provider", f.provider) catch return 0);
        if (f.model.len > 0) try where.appendSlice(a, appendCond(a, "model", f.model) catch return 0);
        if (f.platform.len > 0) try where.appendSlice(a, appendCond(a, "platform", f.platform) catch return 0);
        // `--all` is the explicit default scope — it adds no constraint
        // of its own.
        if (f.recipes) try where.appendSlice(a, " AND scope_recipes=1");
        if (f.missing_fixture_file) try where.appendSlice(a, " AND scope_missing_fixture_file=1");
        if (f.stale_by_days != null or f.stale_by_hours != null or f.stale_by_minutes != null) try where.appendSlice(a, " AND stale_by_minutes IS NOT NULL");
        if (f.stale_by_version) try where.appendSlice(a, " AND stale_by_version=1");
        if (f.stale_by_detect) try where.appendSlice(a, " AND stale_by_detect=1");
        if (f.stale_by_hash) try where.appendSlice(a, " AND stale_by_hash=1");
        if (f.available) try where.appendSlice(a, " AND available=1");
        if (f.unavailable) try where.appendSlice(a, " AND available=0");
        if (f.successful) try where.appendSlice(a, " AND successful=1");
        if (f.unsuccessful) try where.appendSlice(a, " AND successful=0");
        if (f.mode.len > 0) try where.appendSlice(a, appendCond(a, "mode", f.mode) catch return 0);
        // DELETE + SELECT changes() in ONE sqlite3 invocation so the count is
        // connection-local (changes() in a fresh process would read 0).
        // Via sqliteQuery so the schema is ensured (dequeue works on a
        // freshly-recreated store).
        const sql = try std.fmt.allocPrint(a, "DELETE FROM queue {s}; SELECT changes() AS c;", .{where.items});
        defer a.free(sql);
        const out = try sqliteQuery(a, io, sql);
        defer a.free(out);
        return parseJsonCount(a, out) catch 0;
    }

    /// parse the `[{"c":N}]` JSON produced by `SELECT changes() AS c`.
    fn parseJsonCount(a: std.mem.Allocator, json: []const u8) !usize {
        if (json.len == 0) return 0;
        var it = std.mem.splitScalar(u8, json, '\n');
        while (it.next()) |chunk| {
            if (chunk.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, a, chunk, .{}) catch continue;
            if (parsed.value != .array or parsed.value.array.items.len == 0) continue;
            const o = parsed.value.array.items[0];
            if (o != .object) continue;
            return @intCast(@max(sjint(o.object, "c"), 0));
        }
        return 0;
    }

    fn appendCond(a: std.mem.Allocator, col: []const u8, v: []const u8) ![]u8 {
        const q = try sqlQuote(a, v);
        return std.fmt.allocPrint(a, " AND {s}={s}", .{ col, q });
    }

    /// the shared validator — single source of truth for valid queue
    /// rows. Called by BOTH writer paths and the daemon reader. A row
    /// carries at most one scope marker: a recipe/missing-fixture-file
    /// scope, one staleness unit (age OR version OR detection OR hash),
    /// an available marker, or a successful marker.
    fn validateQueueRow(row: QueueRow) !void {
        const staleness = @as(usize, @intFromBool(row.stale_by_minutes != null or
            (row.stale_by_version != null and row.stale_by_version.? == 1) or
            (row.stale_by_detect != null and row.stale_by_detect.? == 1) or
            (row.stale_by_hash != null and row.stale_by_hash.? == 1)));
        const scope_count = @as(usize, @intFromBool(row.scope_recipes != null and row.scope_recipes.? == 1)) +
            @as(usize, @intFromBool(row.scope_missing_fixture_file != null and row.scope_missing_fixture_file.? == 1)) +
            staleness +
            @as(usize, @intFromBool(row.available != null)) +
            @as(usize, @intFromBool(row.successful != null));
        if (scope_count > 1) return error.InvalidQueueRow;
        if (row.stale_by_minutes != null and row.stale_by_minutes.? < 1) return error.InvalidQueueRow;
        const flags = [_]?i64{
            row.scope_recipes,    row.scope_missing_fixture_file,
            row.stale_by_version, row.stale_by_detect,
            row.stale_by_hash,    row.available,
            row.successful,
        };
        for (flags) |s| {
            if (s != null and (s.? != 0 and s.? != 1)) return error.InvalidQueueRow;
        }
    }

    /// human-readable description of a queue row for diagnostics.
    fn describeQueueRow(a: std.mem.Allocator, row: QueueRow) ![]u8 {
        const h = row.harness orelse "";
        const p = row.provider orelse "";
        const m = row.model orelse "";
        const plat = row.platform orelse "";
        if (h.len > 0 and p.len > 0 and m.len > 0 and plat.len > 0) {
            return (try fixtureIdFrom(a, h, p, m, plat)) orelse try tupleKey(a, h, p, m, plat);
        }
        var list: std.ArrayList(u8) = .empty;
        try list.appendSlice(a, "seed");
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

    const RecipesForFixtures = struct {
        /// Stable composite id in the form
        /// "<harness_id>-<provider_id>-<model_id>"
        /// (e.g. "cline-clinepass-kimik3"). The daemon and queue-* commands
        /// key off this; the three sub-ids are recovered via
        /// `splitAgentId` when needed (sub-ids never contain
        /// `-` because `slugId` strips non-alphanumerics). Every
        /// row here is a fully-resolved fixture recipe.
        agent_id: []const u8,
        /// Headless launch argv for `from-capture` jobs: the harness
        /// binary + args that run `agent-detect-dev fixtures capture` inside
        /// a live model session. `null` = no reliable headless mode → the
        /// recipe is `from-identity` only (from-capture candidates without a
        /// launch spec route to the `invalid` table at queue/expansion time).
        launch: ?[]const []const u8 = null,
    };

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

    /// The canonical row-identity key for the four dims, as `h~p~m~plat`
    /// with empty slots for unset dims. The `~` separator cannot appear
    /// in alphanumeric ids (`slugId` strips non-alphanumerics),
    /// so the joined form is unambiguous even for partial rows. Every
    /// upsert/dedupe/lookup operates on this key, not a flattened id.
    fn tupleKey(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) ![]u8 {
        return joinId(a, "~", &.{ h, p, m, plat });
    }

    /// derived `agent_id` — `harness#provider#model` (`#`-joined so the
    /// stored id is unambiguous; the dash-joined form is reserved for
    /// fixture filenames). Caller owns the returned slice.
    fn derivedAgentId(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8) ![]u8 {
        return joinId(a, "#", &.{ h, p, m });
    }

    /// derived `fixture_id` — `harness#provider#model#platform`. Caller
    /// owns the returned slice.
    fn derivedFixtureId(a: std.mem.Allocator, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) ![]u8 {
        return joinId(a, "#", &.{ h, p, m, plat });
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
    /// generation hash, so the two can never diverge. Caller owns.
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
    fn mergeWriteFixture(a: std.mem.Allocator, io: std.Io, f_id: []const u8, keys: []const []const u8, values: []const std.json.Value) !void {
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
        defer a.free(json_bytes);
        std.Io.Dir.cwd().createDirPath(io, "fixtures") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.FilesystemIoError,
        };
        const tmp_path = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
        defer a.free(tmp_path);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json_bytes }) catch return error.FilesystemIoError;
        std.Io.Dir.rename(std.Io.Dir.cwd(), tmp_path, std.Io.Dir.cwd(), path, io) catch return error.FilesystemIoError;
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
    /// the capture prompt the from-capture worker hands a headless harness:
    /// the model session runs `agent-detect-dev fixtures capture` in the
    /// current working directory and reports the result.
    const capture_prompt = "run `agent-detect-dev fixtures capture` in the current working directory and report the result";

    pub const recipesForFixtures = [_]RecipesForFixtures{
        // cline — clinepass/kimi-k3 (keep, no launch spec — not in the usable set), deepseek/v4-flash, minimax/m3, openrouter/v4-flash (no launch spec — not in the usable set)
        .{ .agent_id = "cline-clinepass-kimik3", .launch = &.{ "cline", "--auto-approve", "--provider=cline-pass", "--model=cline-pass/kimi-k3", capture_prompt } },
        .{ .agent_id = "cline-deepseek-deepseekv4flash", .launch = &.{ "cline", "--auto-approve", "--provider=deepseek", "--model=deepseek-v4-flash", "--thinking", "high", capture_prompt } },
        .{ .agent_id = "cline-minimax-minimaxm3", .launch = &.{ "cline", "--auto-approve", "--provider=minimax", "--model=minimax/minimax-m3", capture_prompt } },
        .{ .agent_id = "cline-openrouter-deepseekv4flash", .launch = &.{ "cline", "--auto-approve", "--provider=openrouter", "--model=openrouter/deepseek-v4-flash", capture_prompt } },
        // cline additions (real usable combos): clinepass/step-3.7-flash and clinepass/free-deepseek-v4-flash
        .{ .agent_id = "cline-clinepass-step37flash", .launch = &.{ "cline", "--auto-approve", "--provider=cline-pass", "--model=stepfun/step-3.7-flash", capture_prompt } },
        .{ .agent_id = "cline-clinepass-deepseekv4flash", .launch = &.{ "cline", "--auto-approve", "--provider=cline-pass", "--model=free/deepseek-v4-flash", capture_prompt } },
        // goose — goose/claude-sonnet-4 (contributor-scope example, keeps the harness→recipe test green)
        .{ .agent_id = "goose-goose-claudesonnet4", .launch = &.{ "goose", "run", "-t", capture_prompt } },
        // kimi — minimax/m3 (keep), deepseek/v4-flash, kimi/k3
        .{ .agent_id = "kimicode-minimax-minimaxm3", .launch = &.{ "kimi", "-p", capture_prompt } },
        .{ .agent_id = "kimicode-deepseek-deepseekv4flash", .launch = &.{ "kimi", "-p", capture_prompt } },
        .{ .agent_id = "kimicode-kimi-kimik3", .launch = &.{ "kimi", "-p", capture_prompt } },
        // kimi catalog inference (2026-08-11, `kimi provider catalog list`,
        // models.dev): per the ordering spec — all-providers-free step
        // (openrouter `:free` models that clear the evergreen top-100) —
        // then minimax all-models (M2.7) and deepseek all-models (v4-pro)
        // steps. All provider/model rules already exist; `buildKimiEnv`
        // writes `default_model = "<provider>/<model>"` for each.
        .{ .agent_id = "kimicode-openrouter-gemma431b", .launch = &.{ "kimi", "-p", capture_prompt } },
        .{ .agent_id = "kimicode-openrouter-nemotron3ultra", .launch = &.{ "kimi", "-p", capture_prompt } },
        .{ .agent_id = "kimicode-openrouter-nemotron3super", .launch = &.{ "kimi", "-p", capture_prompt } },
        .{ .agent_id = "kimicode-openrouter-nemotron3nano", .launch = &.{ "kimi", "-p", capture_prompt } },
        .{ .agent_id = "kimicode-minimax-minimaxm27", .launch = &.{ "kimi", "-p", capture_prompt } },
        .{ .agent_id = "kimicode-deepseek-deepseekv4pro", .launch = &.{ "kimi", "-p", capture_prompt } },
        // mmx — minimax/m3 (keep), minimax/m2.7
        .{ .agent_id = "mmx-minimax-minimaxm3", .launch = &.{ "mmx", "text", "chat", "--message", capture_prompt, "--non-interactive" } },
        .{ .agent_id = "mmx-minimax-minimaxm27", .launch = &.{ "mmx", "text", "chat", "--message", capture_prompt, "--non-interactive" } },
        // pi — anthropic/claude-sonnet-4 (keep), deepseek/v4-flash, minimax/m3
        .{ .agent_id = "pi-anthropic-claudesonnet4" },
        .{ .agent_id = "pi-deepseek-deepseekv4flash", .launch = &.{ "pi", "--provider", "deepseek", "--model", "deepseek-v4-flash", "-p", capture_prompt } },
        .{ .agent_id = "pi-minimax-minimaxm3", .launch = &.{ "pi", "--provider", "minimax", "--model", "MiniMax-M3", "-p", capture_prompt } },
        // pi additions (pi authed with these providers 2026-08-11). The
        // groq/cerebras/xai/moonshot recipes have no launch spec: this
        // account's groq key 404s llama-4, cerebras 404s every catalog id,
        // xai reports no credits (403), moonshot is rate-limited (429) —
        // from-identity still covers them.
        .{ .agent_id = "pi-openrouter-deepseekv4flash", .launch = &.{ "pi", "--provider", "openrouter", "--model", "deepseek/deepseek-v4-flash", "-p", capture_prompt } },
        .{ .agent_id = "pi-groq-llama4" },
        // cerebras free-trial models (verified working 2026-08-11):
        // gpt-oss-120b (production) and gemma-4-31b (preview).
        .{ .agent_id = "pi-cerebras-gptoss120b", .launch = &.{ "pi", "--provider", "cerebras", "--model", "gpt-oss-120b", "-p", capture_prompt } },
        .{ .agent_id = "pi-cerebras-gemma431b", .launch = &.{ "pi", "--provider", "cerebras", "--model", "gemma-4-31b", "-p", capture_prompt } },
        .{ .agent_id = "pi-cerebras-zaiglm47", .launch = &.{ "pi", "--provider", "cerebras", "--model", "zai-glm-4.7", "-p", capture_prompt } },
        .{ .agent_id = "pi-mistral-mistrallargelatest", .launch = &.{ "pi", "--provider", "mistral", "--model", "mistral-large-latest", "-p", capture_prompt } },
        .{ .agent_id = "pi-xai-grok4" },
        .{ .agent_id = "pi-kimi-kimik3" },
        // pi batch 2 (2026-08-11, catalog inference): free-tier openrouter
        // `:free` models + groq free-tier models (evergreen-clearing, per
        // the ordering spec's "all providers' free models" step), then
        // minimax/deepseek all-models steps (their named-provider override
        // bypasses the evergreen gate). Groq has no launch spec — this
        // account's groq key 404s (see the batch-1 comment).
        .{ .agent_id = "pi-openrouter-gemma431b", .launch = &.{ "pi", "--provider", "openrouter", "--model", "google/gemma-4-31b-it:free", "-p", capture_prompt } },
        .{ .agent_id = "pi-openrouter-nemotron3ultra", .launch = &.{ "pi", "--provider", "openrouter", "--model", "nvidia/nemotron-3-ultra-550b-a55b:free", "-p", capture_prompt } },
        .{ .agent_id = "pi-openrouter-nemotron3super", .launch = &.{ "pi", "--provider", "openrouter", "--model", "nvidia/nemotron-3-super-120b-a12b:free", "-p", capture_prompt } },
        .{ .agent_id = "pi-openrouter-nemotron3nano", .launch = &.{ "pi", "--provider", "openrouter", "--model", "nvidia/nemotron-3-nano-30b-a3b:free", "-p", capture_prompt } },
        .{ .agent_id = "pi-groq-llama3370b" },
        .{ .agent_id = "pi-groq-llama318b" },
        .{ .agent_id = "pi-minimax-minimaxm27", .launch = &.{ "pi", "--provider", "minimax", "--model", "MiniMax-M2.7", "-p", capture_prompt } },
        .{ .agent_id = "pi-deepseek-deepseekv4pro", .launch = &.{ "pi", "--provider", "deepseek", "--model", "deepseek-v4-pro", "-p", capture_prompt } },
        // qwen — minimax/m3 (keep), deepseek/v4-flash, qwen/qwen3.8-max
        .{ .agent_id = "qwen-minimax-minimaxm3", .launch = &.{ "qwen", "-p", capture_prompt } },
        .{ .agent_id = "qwen-deepseek-deepseekv4flash", .launch = &.{ "qwen", "-p", capture_prompt } },
        .{ .agent_id = "qwen-qwen-qwen38max", .launch = &.{ "qwen", "-p", capture_prompt } },
        // qwen catalog inference (2026-08-11, `~/.qwen/settings.json`
        // `modelProviders`): minimax/deepseek all-models steps per the
        // ordering spec, then evergreen-clearing xai/requesty/dashscope
        // combos. baseUrl hosts map via `providerForBaseUrl` (requesty and
        // x.ai added to the table this batch).
        .{ .agent_id = "qwen-minimax-minimaxm25", .launch = &.{ "qwen", "-p", capture_prompt } },
        .{ .agent_id = "qwen-minimax-minimaxm27", .launch = &.{ "qwen", "-p", capture_prompt } },
        .{ .agent_id = "qwen-deepseek-deepseekv4pro", .launch = &.{ "qwen", "-p", capture_prompt } },
        .{ .agent_id = "qwen-xai-grok45", .launch = &.{ "qwen", "-p", capture_prompt } },
        .{ .agent_id = "qwen-xai-grok420", .launch = &.{ "qwen", "-p", capture_prompt } },
        .{ .agent_id = "qwen-openai-gpt4o", .launch = &.{ "qwen", "-p", capture_prompt } },
        .{ .agent_id = "qwen-qwen-deepseekv4flash", .launch = &.{ "qwen", "-p", capture_prompt } },
        // kilo — anthropic/claude-sonnet-4 (keep), deepseek/v4-flash (keep), minimax/m3, openrouter/v4-flash, zai/glm-5.2
        .{ .agent_id = "kilo-anthropic-claudesonnet4", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-deepseek-deepseekv4flash", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-minimax-minimaxm3", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-openrouter-deepseekv4flash", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-zai-glm52", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        // kilo catalog inference (2026-08-11, `kilo models`, 481 models):
        // free-tier `~*-latest` router aliases that clear the evergreen
        // top-100 (provider `kilo`), then minimax/clinepass/deepseek
        // all-models steps per the ordering spec, then evergreen-clearing
        // hyper/ollama-cloud/fireworks-ai combos. Scoped to kilo's authed
        // providers.
        .{ .agent_id = "kilo-kilo-gemini35flash", .launch = &.{ "kilo", "run", "--auto", "--model", "kilo/~google/gemini-flash-latest", capture_prompt } },
        .{ .agent_id = "kilo-kilo-grok45", .launch = &.{ "kilo", "run", "--auto", "--model", "kilo/~x-ai/grok-latest", capture_prompt } },
        .{ .agent_id = "kilo-kilo-kimik3", .launch = &.{ "kilo", "run", "--auto", "--model", "kilo/~moonshotai/kimi-latest", capture_prompt } },
        .{ .agent_id = "kilo-minimax-minimaxm27", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-clinepass-glm52", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-clinepass-kimik27code", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-deepseek-deepseekv4pro", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-hyper-glm52", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-hyper-kimik3", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-ollamacloud-glm52", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-ollamacloud-kimik25", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        .{ .agent_id = "kilo-fireworksai-glm52", .launch = &.{ "kilo", "run", "--auto", capture_prompt } },
        // omp — minimax-code/m3 (keep), deepseek/v4-flash, openrouter/v4-flash
        .{ .agent_id = "omp-minimaxcode-minimaxm3", .launch = &.{ "omp", "--model", "minimax-code/MiniMax-M3", capture_prompt } },
        .{ .agent_id = "omp-deepseek-deepseekv4flash", .launch = &.{ "omp", "--model", "deepseek/deepseek-v4-flash", capture_prompt } },
        .{ .agent_id = "omp-openrouter-deepseekv4flash", .launch = &.{ "omp", "--model", "openrouter/deepseek-v4-flash", capture_prompt } },
        // omp evergreen+free additions (2026-08-11): free models on the
        // newly-added providers, constrained to the evergreen top-100 set.
        // Service ids carry a -free suffix (e.g. zenmux "kimi-k3-free");
        // the recipe stores the coalesced canonical model, the -free is the
        // free-tier variation on that provider.
        .{ .agent_id = "omp-zenmux-deepseekv4flash", .launch = &.{ "omp", "--model", "zenmux/deepseek/deepseek-v4-flash-free", capture_prompt } },
        .{ .agent_id = "omp-zenmux-kimik3", .launch = &.{ "omp", "--model", "zenmux/moonshotai/kimi-k3-free", capture_prompt } },
        .{ .agent_id = "omp-zenmux-step37flash", .launch = &.{ "omp", "--model", "zenmux/stepfun/step-3.7-flash-free", capture_prompt } },
        .{ .agent_id = "omp-zenmux-grok45", .launch = &.{ "omp", "--model", "zenmux/x-ai/grok-4.5-free", capture_prompt } },
        .{ .agent_id = "omp-zenmux-gemini35flash", .launch = &.{ "omp", "--model", "zenmux/google/gemini-3.5-flash-free", capture_prompt } },
        .{ .agent_id = "omp-zenmux-glm47flash", .launch = &.{ "omp", "--model", "zenmux/z-ai/glm-4.7-flash-free", capture_prompt } },
        .{ .agent_id = "omp-siliconflow-minimaxm3", .launch = &.{ "omp", "--model", "siliconflow/MiniMaxAI/MiniMax-M3", capture_prompt } },
        .{ .agent_id = "omp-siliconflow-kimik3", .launch = &.{ "omp", "--model", "siliconflow/moonshotai/Kimi-K3", capture_prompt } },
        .{ .agent_id = "omp-siliconflow-deepseekv4flash", .launch = &.{ "omp", "--model", "siliconflow/deepseek-ai/DeepSeek-V4-Flash-0731", capture_prompt } },
        .{ .agent_id = "omp-sakana-fuguultrav11", .launch = &.{ "omp", "--model", "sakana/fugu-ultra-v1.1", capture_prompt } },
        // omp batch 2 (evergreen+free): ollama-cloud, kimi-code, meta, google-antigravity
        .{ .agent_id = "omp-ollamacloud-deepseekv4flash", .launch = &.{ "omp", "--model", "ollama-cloud/deepseek-v4-flash", capture_prompt } },
        .{ .agent_id = "omp-ollamacloud-deepseekv32", .launch = &.{ "omp", "--model", "ollama-cloud/deepseek-v3.2", capture_prompt } },
        .{ .agent_id = "omp-ollamacloud-glm52", .launch = &.{ "omp", "--model", "ollama-cloud/glm-5.2", capture_prompt } },
        .{ .agent_id = "omp-ollamacloud-kimik3", .launch = &.{ "omp", "--model", "ollama-cloud/kimi-k3", capture_prompt } },
        .{ .agent_id = "omp-ollamacloud-minimaxm3", .launch = &.{ "omp", "--model", "ollama-cloud/minimax-m3", capture_prompt } },
        .{ .agent_id = "omp-ollamacloud-minimaxm27", .launch = &.{ "omp", "--model", "ollama-cloud/minimax-m2.7", capture_prompt } },
        .{ .agent_id = "omp-ollamacloud-qwen3coder", .launch = &.{ "omp", "--model", "ollama-cloud/qwen3-coder", capture_prompt } },
        .{ .agent_id = "omp-ollamacloud-nemotron3ultra", .launch = &.{ "omp", "--model", "ollama-cloud/nemotron-3-ultra", capture_prompt } },
        .{ .agent_id = "omp-kimicode-kimik3", .launch = &.{ "omp", "--model", "kimi-code/k3", capture_prompt } },
        .{ .agent_id = "omp-meta-musespark12", .launch = &.{ "omp", "--model", "meta/muse-spark-1.2", capture_prompt } },
        .{ .agent_id = "omp-googleantigravity-gptoss120b", .launch = &.{ "omp", "--model", "google-antigravity/gpt-oss-120b", capture_prompt } },
        // omp batch 3 (evergreen+free): gmi-cloud, nanogpt, huggingface, cursor
        .{ .agent_id = "omp-gmicloud-gpt4o", .launch = &.{ "omp", "--model", "gmi-cloud/openai/gpt-4o", capture_prompt } },
        .{ .agent_id = "omp-gmicloud-grok45", .launch = &.{ "omp", "--model", "gmi-cloud/x-ai/grok-4.5", capture_prompt } },
        .{ .agent_id = "omp-gmicloud-kimik2", .launch = &.{ "omp", "--model", "gmi-cloud/moonshotai/kimi-k2", capture_prompt } },
        .{ .agent_id = "omp-gmicloud-nemotron3ultra", .launch = &.{ "omp", "--model", "gmi-cloud/nvidia/nemotron-3-ultra", capture_prompt } },
        .{ .agent_id = "omp-gmicloud-glm47", .launch = &.{ "omp", "--model", "gmi-cloud/zai-org/glm-4.7", capture_prompt } },
        .{ .agent_id = "omp-gmicloud-deepseekr1", .launch = &.{ "omp", "--model", "gmi-cloud/deepseek-ai/deepseek-r1", capture_prompt } },
        .{ .agent_id = "omp-gmicloud-gemini3flash", .launch = &.{ "omp", "--model", "gmi-cloud/google/gemini-3-flash", capture_prompt } },
        .{ .agent_id = "omp-gmicloud-claudefable5", .launch = &.{ "omp", "--model", "gmi-cloud/anthropic/claude-fable-5", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-deepseekr1", .launch = &.{ "omp", "--model", "nanogpt/deepseek-ai/deepseek-r1", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-gpt4o", .launch = &.{ "omp", "--model", "nanogpt/openai/chatgpt-4o", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-grok3", .launch = &.{ "omp", "--model", "nanogpt/grok-3", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-kimik2", .launch = &.{ "omp", "--model", "nanogpt/baseten/kimi-k2", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-nemotron3ultra", .launch = &.{ "omp", "--model", "nanogpt/nvidia/nemotron-3-ultra", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-phi4mini", .launch = &.{ "omp", "--model", "nanogpt/phi-4-mini", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-olmo332bthink", .launch = &.{ "omp", "--model", "nanogpt/allenai/olmo-3-32b-think", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-ling30flash", .launch = &.{ "omp", "--model", "nanogpt/inclusionai/ling-3.0-flash", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-doubaoseed21", .launch = &.{ "omp", "--model", "nanogpt/bytedance/doubao-seed-2.1", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-ernie45", .launch = &.{ "omp", "--model", "nanogpt/baidu/ernie-4.5", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-hunyuant1", .launch = &.{ "omp", "--model", "nanogpt/hunyuan-t1", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-gptoss120b", .launch = &.{ "omp", "--model", "nanogpt/TEE/gpt-oss-120b", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-gemma327b", .launch = &.{ "omp", "--model", "nanogpt/gemma-3-27b", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-mistralsmall3", .launch = &.{ "omp", "--model", "nanogpt/mistral-small-3", capture_prompt } },
        .{ .agent_id = "omp-nanogpt-qwen36", .launch = &.{ "omp", "--model", "nanogpt/alibaba/qwen3.6", capture_prompt } },
        .{ .agent_id = "omp-huggingface-phi4", .launch = &.{ "omp", "--model", "huggingface/microsoft/phi-4", capture_prompt } },
        .{ .agent_id = "omp-huggingface-glm47flash", .launch = &.{ "omp", "--model", "huggingface/zai-org/glm-4.7-flash", capture_prompt } },
        .{ .agent_id = "omp-huggingface-nemotron3ultra", .launch = &.{ "omp", "--model", "huggingface/nvidia/nemotron-3-ultra", capture_prompt } },
        .{ .agent_id = "omp-huggingface-llama318b", .launch = &.{ "omp", "--model", "huggingface/meta-llama/llama-3.1-8b", capture_prompt } },
        .{ .agent_id = "omp-huggingface-ling261t", .launch = &.{ "omp", "--model", "huggingface/inclusionai/ling-2.6-1t", capture_prompt } },
        .{ .agent_id = "omp-huggingface-cogito21", .launch = &.{ "omp", "--model", "huggingface/deepcogito/cogito-2.1", capture_prompt } },
        .{ .agent_id = "omp-huggingface-gptoss120b", .launch = &.{ "omp", "--model", "huggingface/openai/gpt-oss-120b", capture_prompt } },
        .{ .agent_id = "omp-huggingface-commanda", .launch = &.{ "omp", "--model", "huggingface/cohere/command-a", capture_prompt } },
        .{ .agent_id = "omp-cursor-gpt5mini", .launch = &.{ "omp", "--model", "cursor/gpt-5-mini", capture_prompt } },
        .{ .agent_id = "omp-cursor-gemini3flash", .launch = &.{ "omp", "--model", "cursor/gemini-3-flash", capture_prompt } },
        .{ .agent_id = "omp-cursor-glm52", .launch = &.{ "omp", "--model", "cursor/glm-5.2", capture_prompt } },
        .{ .agent_id = "omp-cursor-claudefable5", .launch = &.{ "omp", "--model", "cursor/claude-fable-5", capture_prompt } },
        .{ .agent_id = "omp-cursor-kimik25", .launch = &.{ "omp", "--model", "cursor/kimi-k2.5", capture_prompt } },
        // omp batch 4 (evergreen+free): github-copilot
        .{ .agent_id = "omp-githubcopilot-gpt4o", .launch = &.{ "omp", "--model", "github-copilot/gpt-4o", capture_prompt } },
        .{ .agent_id = "omp-githubcopilot-gemini3pro", .launch = &.{ "omp", "--model", "github-copilot/gemini-3-pro", capture_prompt } },
        .{ .agent_id = "omp-githubcopilot-gpt5mini", .launch = &.{ "omp", "--model", "github-copilot/gpt-5-mini", capture_prompt } },
        // reasonix — deepseek-flash/v4-flash (keep), deepseek/v4-flash, minimax/m3
        .{ .agent_id = "reasonix-deepseekflash-deepseekv4flash", .launch = &.{ "reasonix", "run", "--permission-mode", "bypassPermissions", capture_prompt } },
        .{ .agent_id = "reasonix-deepseek-deepseekv4flash" },
        .{ .agent_id = "reasonix-minimax-minimaxm3" },
        // crush — hyper/qwen3.7-plus (keep), hyper/v4-flash, minimax/m3, deepseek/v4-flash
        .{ .agent_id = "crush-hyper-qwen37plus", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-deepseekv4flash", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-minimax-minimaxm3", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-deepseek-deepseekv4flash", .launch = &.{ "crush", "run", capture_prompt } },
        // crush catalog inference (2026-08-11): `crush models` lists the
        // full models.dev catalog (1435 entries) but the runtime provider is
        // hyper only — confirmed from `~/.local/share/crush/hyper.json`
        // (the runnable set). Adds hyper-provider models that clear the
        // evergreen top-100; no recipes for catalog providers crush cannot
        // actually run.
        .{ .agent_id = "crush-hyper-deepseekv4pro", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-glm52", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-kimik25", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-kimik27code", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-kimik3", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-llama3370b", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-llama4maverick", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-minimaxm27", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-qwen36max", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-qwen37flash", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-qwen38max", .launch = &.{ "crush", "run", capture_prompt } },
        .{ .agent_id = "crush-hyper-qwen3coder", .launch = &.{ "crush", "run", capture_prompt } },
        // opencode — minimax/m3 (keep), deepseek/v4-flash, hyper/v4-flash, groq/llama-4, cerebras/qwen3
        .{ .agent_id = "opencode-minimax-minimaxm3", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-deepseek-deepseekv4flash", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-hyper-deepseekv4flash", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-groq-llama4", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-cerebras-qwen3", .launch = &.{ "opencode", "run", capture_prompt } },
        // opencode's built-in free tier (opencode router, no API key needed)
        .{ .agent_id = "opencode-opencode-deepseekv4flashfree", .launch = &.{ "opencode", "run", "--model", "opencode/deepseek-v4-flash-free", capture_prompt } },
        // opencode catalog inference (2026-08-11, `opencode models`, 83
        // models): free-tier router model that clears the evergreen top-100
        // (nemotron-3-ultra), then minimax/clinepass/deepseek all-models
        // steps per the ordering spec, then evergreen-clearing alibaba
        // combos. scoped to opencode's authed providers.
        .{ .agent_id = "opencode-opencode-nemotron3ultra", .launch = &.{ "opencode", "run", "--model", "opencode/nemotron-3-ultra-free", capture_prompt } },
        .{ .agent_id = "opencode-minimax-minimaxm25", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-minimax-minimaxm27", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-clinepass-glm52", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-clinepass-kimik27code", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-clinepass-minimaxm3", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-clinepass-deepseekv4pro", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-deepseek-deepseekv4pro", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-alibaba-glm52", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-alibaba-qwen3coder", .launch = &.{ "opencode", "run", capture_prompt } },
        .{ .agent_id = "opencode-alibaba-qwen38max", .launch = &.{ "opencode", "run", capture_prompt } },
        // vibe — mistral/mistral-large-latest (keep), mistral/mistral-small-latest, minimax/m3
        .{ .agent_id = "vibe-mistral-mistrallargelatest", .launch = &.{ "vibe", "--prompt", capture_prompt } },
        .{ .agent_id = "vibe-mistral-mistralsmalllatest", .launch = &.{ "vibe", "--prompt", capture_prompt } },
        .{ .agent_id = "vibe-minimax-minimaxm3", .launch = &.{ "vibe", "--prompt", capture_prompt } },
        // cursor (2026-08-11, installed `cursor-agent` from brew
        // `cursor-cli`, authed). Cursor's CLI takes `--model` per run over
        // its first-party router; recipes are evergreen-clearing catalog
        // models (flat subscription — no per-model free/paid split).
        .{ .agent_id = "cursor-cursor-claudefable5", .launch = &.{ "cursor-agent", "-p", "--model", "claude-fable-5-thinking-high", capture_prompt } },
        .{ .agent_id = "cursor-cursor-claudesonnet5", .launch = &.{ "cursor-agent", "-p", "--model", "claude-sonnet-5-thinking-high", capture_prompt } },
        .{ .agent_id = "cursor-cursor-claudeopus5", .launch = &.{ "cursor-agent", "-p", "--model", "claude-opus-5-thinking-high", capture_prompt } },
        .{ .agent_id = "cursor-cursor-gpt56sol", .launch = &.{ "cursor-agent", "-p", "--model", "gpt-5.6-sol-high", capture_prompt } },
        .{ .agent_id = "cursor-cursor-gpt56luna", .launch = &.{ "cursor-agent", "-p", "--model", "gpt-5.6-luna-high", capture_prompt } },
        .{ .agent_id = "cursor-cursor-gpt52", .launch = &.{ "cursor-agent", "-p", "--model", "gpt-5.2", capture_prompt } },
        .{ .agent_id = "cursor-cursor-grok45", .launch = &.{ "cursor-agent", "-p", "--model", "cursor-grok-4.5-high", capture_prompt } },
        // copilot (2026-08-11, installed `copilot` from brew `copilot-cli`,
        // authed). Copilot routes GitHub-hosted models; recipes are
        // evergreen-clearing models its CLI exposes (`-p` headless verified;
        // the `gpt-5-mini` session model was confirmed live).
        .{ .agent_id = "copilot-githubcopilot-gpt52", .launch = &.{ "copilot", "-p", "--allow-all", "--model", "gpt-5.2", capture_prompt } },
        .{ .agent_id = "copilot-githubcopilot-gemini25pro", .launch = &.{ "copilot", "-p", "--allow-all", "--model", "gemini-2.5-pro", capture_prompt } },
        .{ .agent_id = "copilot-githubcopilot-grok45", .launch = &.{ "copilot", "-p", "--allow-all", "--model", "grok-4.5", capture_prompt } },
        .{ .agent_id = "copilot-githubcopilot-claudesonnet5", .launch = &.{ "copilot", "-p", "--allow-all", "--model", "claude-sonnet-5", capture_prompt } },
    };

    // ----------------------------------------------------------------------------
    // probe + utility helpers (dev-only)
    // ----------------------------------------------------------------------------

    /// spawn `name --version` and return its raw stdout on exit 0,
    /// null otherwise (spawn failure or nonzero exit). Caller owns the
    /// returned slice.
    fn spawnVersion(a: std.mem.Allocator, io: std.Io, name: []const u8) ?[]u8 {
        var argv_buf = [_][]const u8{ name, "--version" };
        var child = std.process.spawn(io, .{
            .argv = &argv_buf,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return null;
        const out = readChildOutput(a, io, child, false) catch return null;
        const term = child.wait(io) catch return null;
        if (term != .exited or term.exited != 0) return null;
        return out;
    }

    /// first binary name in `names` that runs `--version` successfully
    /// (exit 0), or null when none work — the availability probe.
    fn findBinary(a: std.mem.Allocator, io: std.Io, names: []const []const u8) ?[]const u8 {
        for (names) |n| {
            const out = spawnVersion(a, io, n) orelse continue;
            a.free(out);
            return n;
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

    /// run the recipe's harness `--version` and return the extracted
    /// version token (first match of the generic scanner), or null when
    /// nothing runs or no token matches. Names come from the harness
    /// rule's `binary_names` (via `harnessRuleForFixtureId`), cycling
    /// until a spawn exits 0 AND `scanVersionToken` parses. Zero-token:
    /// version calls invoke the harness binary directly, they never
    /// touch a model API.
    fn harnessVersion(a: std.mem.Allocator, io: std.Io, agent_id: []const u8) ?[]const u8 {
        const rule = harnessRuleForFixtureId(a, agent_id) orelse return null;
        for (rule.binary_names) |n| {
            const out = spawnVersion(a, io, n) orelse continue;
            defer a.free(out);
            if (scanVersionToken(out)) |tok| {
                return a.dupe(u8, tok) catch null;
            }
        }
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

    /// shared filter for `fixtures queue` / `fixtures dequeue`. Four dimension
    /// flags (`--harness=`, `--provider=`, `--model=`, `--platform=`)
    /// constrain their dim to equality; an unmentioned dim is
    /// unconstrained (any value, including null).
    /// `--fixture=` expands to all four dims (h-p-m-platform);
    /// `--agent=` expands to h-p-m, leaving platform unconstrained
    /// unless `--platform=` is also given. `any` is true iff at least
    /// one option was present.
    const FilterOptions = struct {
        harness: []const u8 = "",
        provider: []const u8 = "",
        model: []const u8 = "",
        platform: []const u8 = "",
        fixture: ?[]const u8 = null,
        agent: ?[]const u8 = null,
        /// scope flags: `--all`/`--stale-by-*` target the fixtures table;
        /// `--recipes`/`--missing-fixture-file` target the recipe table;
        /// `--available`/`--unavailable`/`--successful`/`--unsuccessful`
        /// target fixtures rows by their stored markers.
        all: bool = false,
        recipes: bool = false,
        missing_fixture_file: bool = false,
        missing_fixture_entry: bool = false,
        /// `--available`/`--unavailable` (`fixtures.available` 1/0) and
        /// `--successful`/`--unsuccessful` (`fixtures.successful` 1/0):
        /// pure scope markers — enqueue/dequeue by stored state, never a
        /// probe.
        available: bool = false,
        unavailable: bool = false,
        successful: bool = false,
        unsuccessful: bool = false,
        /// age thresholds. Each is a scope flag by itself; at most one of
        /// the three may be set. The queued row always stores the age in
        /// MINUTES in the `stale_by_minutes` column (days/hours convert at
        /// stamp time) so the table has a single age column.
        stale_by_days: ?i64 = null,
        stale_by_hours: ?i64 = null,
        stale_by_minutes: ?i64 = null,
        /// `--stale-by-version`: version-marker staleness. The daemon
        /// compares a live `--version` call against the fixture's
        /// captured `harness_version`.
        stale_by_version: bool = false,
        /// `--stale-by-detect`: re-capture when the fixture's
        /// `agent_detect_version` is NULL or differs from this binary's.
        stale_by_detect: bool = false,
        /// `--stale-by-hash`: re-capture when the stored per-channel
        /// generation hash is NULL or differs from the current fixture
        /// file's channel object. Mode flags pick the channel; no mode
        /// flag checks both.
        stale_by_hash: bool = false,
        any: bool = false,
        /// true when `--fixture=` or `--agent=` (the composite ids)
        /// contributed the equality dims — used for the creation path.
        composite: bool = false,
        /// refresh mode: `"from-identity" | "from-capture"`, or `""`
        /// when no mode flag was given. `queue` stamps one row per
        /// selected mode per candidate (no flag → both); `dequeue`
        /// filters by it (no flag → all modes).
        mode: []const u8 = "",
    };

    const FilterError = error{
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
            } else if (std.mem.eql(u8, arg, "--all")) {
                f.all = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-version")) {
                f.stale_by_version = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-detect")) {
                f.stale_by_detect = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-hash")) {
                f.stale_by_hash = true;
            } else if (std.mem.eql(u8, arg, "--recipes")) {
                f.recipes = true;
            } else if (std.mem.eql(u8, arg, "--missing-fixture-file")) {
                f.missing_fixture_file = true;
            } else if (std.mem.eql(u8, arg, "--missing-fixture-entry")) {
                f.missing_fixture_entry = true;
            } else if (std.mem.eql(u8, arg, "--available")) {
                f.available = true;
            } else if (std.mem.eql(u8, arg, "--unavailable") or std.mem.eql(u8, arg, "--available=0")) {
                f.unavailable = true;
            } else if (std.mem.eql(u8, arg, "--successful")) {
                f.successful = true;
            } else if (std.mem.eql(u8, arg, "--unsuccessful") or std.mem.eql(u8, arg, "--successful=0")) {
                f.unsuccessful = true;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-days=")) {
                f.stale_by_days = std.fmt.parseInt(i64, arg["--stale-by-days=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-hours=")) {
                f.stale_by_hours = std.fmt.parseInt(i64, arg["--stale-by-hours=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-minutes=")) {
                f.stale_by_minutes = std.fmt.parseInt(i64, arg["--stale-by-minutes=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.eql(u8, arg, "--from-identity") or std.mem.eql(u8, arg, "--from-capture")) {
                // exactly one mode flag (both → conflicting). No flag means
                // both modes are queued per candidate. The stored value is
                // the FULL "from-*" string so modeRank and the daemon's
                // worker branch can compare it verbatim.
                const m = arg[2..];
                if (f.mode.len > 0 and !std.mem.eql(u8, f.mode, m)) return FilterError.ConflictingFilters;
                f.mode = m;
            }
        }

        // stale-by-* age scopes: at most one of days/hours/minutes may be
        // set, and the value must be a positive integer.
        const age_scopes = @as(usize, @intFromBool(f.stale_by_days != null)) +
            @as(usize, @intFromBool(f.stale_by_hours != null)) +
            @as(usize, @intFromBool(f.stale_by_minutes != null));
        if (age_scopes > 1) return FilterError.ConflictingFilters;
        if ((f.stale_by_days != null and f.stale_by_days.? < 1) or
            (f.stale_by_hours != null and f.stale_by_hours.? < 1) or
            (f.stale_by_minutes != null and f.stale_by_minutes.? < 1)) return FilterError.ConflictingFilters;

        // scope flags combine (AND); scope_count is a "has any scope" probe.
        const scope_count = @as(usize, @intFromBool(f.all)) + age_scopes +
            @as(usize, @intFromBool(f.stale_by_version)) +
            @as(usize, @intFromBool(f.stale_by_detect)) +
            @as(usize, @intFromBool(f.stale_by_hash)) +
            @as(usize, @intFromBool(f.recipes)) +
            @as(usize, @intFromBool(f.missing_fixture_file)) +
            @as(usize, @intFromBool(f.missing_fixture_entry)) +
            @as(usize, @intFromBool(f.available)) +
            @as(usize, @intFromBool(f.unavailable)) +
            @as(usize, @intFromBool(f.successful)) +
            @as(usize, @intFromBool(f.unsuccessful));

        // `--missing-fixture-entry` is its own filesystem scope — the
        // handler ignores every other filter (no queue rows are written).
        if (f.missing_fixture_entry) {
            f.any = true;
            return f;
        }

        f.any = seen_fixture or seen_agent or seen_harness or seen_provider or
            seen_model or seen_platform or scope_count > 0;
        if (!f.any) return FilterError.NoFilter;

        if (seen_fixture) {
            // `--fixture=` supplies all four dims and may not combine
            // with `--agent=` or any `--X=`; `--platform=` is allowed
            // but must be identical to the fixtures id's platform part.
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
        // when they resolve to a known rule (the queue/fixtures tables
        // store `slugId(canonicalName)` — e.g. `kimicode`, never
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
        return f;
    }

    /// the set of modes to emit for a queue request: no mode flag → both
    /// (`from-identity` first); one flag → that mode only.
    fn queueModes(f: FilterOptions) [2]?[]const u8 {
        if (f.mode.len > 0) return .{ f.mode, null };
        return .{ "from-identity", "from-capture" };
    }

    /// find the recipe for a dash-joined `agent_id`, or null.
    fn recipeForAgent(agent: []const u8) ?RecipesForFixtures {
        for (recipesForFixtures) |c| {
            if (std.mem.eql(u8, c.agent_id, agent)) return c;
        }
        return null;
    }

    /// how many scope flags are set (a "has any scope" probe for
    /// `fixtures queue`'s scope-path dispatch). `--all` is the explicit
    /// default scope (every fixture row), so it counts as a scope flag.
    fn scopeCount(f: FilterOptions) usize {
        const age_scopes = @as(usize, @intFromBool(f.stale_by_days != null)) +
            @as(usize, @intFromBool(f.stale_by_hours != null)) +
            @as(usize, @intFromBool(f.stale_by_minutes != null));
        return @as(usize, @intFromBool(f.all)) + age_scopes +
            @as(usize, @intFromBool(f.stale_by_version)) +
            @as(usize, @intFromBool(f.stale_by_detect)) +
            @as(usize, @intFromBool(f.stale_by_hash)) +
            @as(usize, @intFromBool(f.recipes)) +
            @as(usize, @intFromBool(f.missing_fixture_file)) +
            @as(usize, @intFromBool(f.missing_fixture_entry)) +
            @as(usize, @intFromBool(f.available)) +
            @as(usize, @intFromBool(f.unavailable)) +
            @as(usize, @intFromBool(f.successful)) +
            @as(usize, @intFromBool(f.unsuccessful));
    }

    /// the scope candidate set for `f`, as queue rows. Every scope only
    /// INSERTs queue rows (plus the sanctioned `invalid`-table routing for
    /// no-launch from-capture candidates) — no evaluation, no probing.
    /// Candidates come from one of two universes:
    ///  - the recipe table (`--recipes`/`--missing-fixture-file`, host
    ///    platform)
    ///  - the fixtures table (`--all`/`--stale-by-*`/`--available`/
    ///    `--unavailable`/`--successful`/`--unsuccessful`; rows keep
    ///    their stored platform)
    /// Each candidate yields one row per selected mode; `--stale-by-hash`
    /// constrains the channel via the mode flags.
    fn scopeCandidates(a: std.mem.Allocator, io: std.Io, f: FilterOptions) !std.ArrayListUnmanaged(QueueRow) {
        var out: std.ArrayListUnmanaged(QueueRow) = .empty;
        const host = platformId();
        const now = unixNow(io);
        // the age threshold in MINUTES (days/hours convert at stamp time —
        // the table has a single `stale_by_minutes` age column).
        const stale_min = if (f.stale_by_minutes != null)
            f.stale_by_minutes
        else if (f.stale_by_hours != null)
            @as(?i64, f.stale_by_hours.? * 60)
        else if (f.stale_by_days != null)
            @as(?i64, f.stale_by_days.? * 24 * 60)
        else
            null;

        // recipe-table candidates (`--recipes` / `--missing-fixture-file`).
        // `--missing-fixture-file` absorbs `--recipes` (missing ∩ recipes =
        // missing). Stale/marker scopes do not apply to the recipe universe.
        if (f.recipes or f.missing_fixture_file) {
            const modes = queueModes(f);
            for (recipesForFixtures) |c| {
                const parts = try splitAgentId(a, c.agent_id);
                defer {
                    a.free(parts[0]);
                    a.free(parts[1]);
                    a.free(parts[2]);
                }
                if (f.harness.len > 0 and !std.mem.eql(u8, f.harness, parts[0])) continue;
                if (f.provider.len > 0 and !std.mem.eql(u8, f.provider, parts[1])) continue;
                if (f.model.len > 0 and !std.mem.eql(u8, f.model, parts[2])) continue;
                if (f.platform.len > 0 and !std.mem.eql(u8, f.platform, host)) continue;
                if (f.missing_fixture_file) {
                    const fixture_id_v = try fixtureId(a, c.agent_id);
                    defer a.free(fixture_id_v);
                    const json_path = try std.fmt.allocPrint(a, "fixtures/{s}.json", .{fixture_id_v});
                    defer a.free(json_path);
                    var json_exists = false;
                    if (std.Io.Dir.cwd().statFile(io, json_path, .{})) |_| {
                        json_exists = true;
                    } else |_| {}
                    if (json_exists) continue;
                }
                for (modes) |mode_opt| {
                    const mode = mode_opt orelse continue;
                    // no-launch recipes under from-capture → invalid, not
                    // queued (a warning suggests --from-identity).
                    if (std.mem.eql(u8, mode, "from-capture") and c.launch == null) {
                        try insertInvalid(a, io, .{
                            .fixture_id = try fixtureId(a, c.agent_id),
                            .agent_id = try a.dupe(u8, c.agent_id),
                            .harness_id = try a.dupe(u8, parts[0]),
                            .provider_id = try a.dupe(u8, parts[1]),
                            .model_id = try a.dupe(u8, parts[2]),
                            .platform_id = try a.dupe(u8, host),
                            .reason = "no launch spec",
                            .created_at = now,
                        });
                        writeOut(io, "fixtures queue: warning: ");
                        writeOut(io, c.agent_id);
                        writeOut(io, " has no launch spec — capture side suppressed; use --from-identity for it\n");
                        continue;
                    }
                    var row: QueueRow = .{
                        .harness = try a.dupe(u8, parts[0]),
                        .provider = try a.dupe(u8, parts[1]),
                        .model = try a.dupe(u8, parts[2]),
                        .platform = try a.dupe(u8, host),
                        .runner = getParentPid(),
                        .created_at = now,
                        .mode = try a.dupe(u8, mode),
                    };
                    if (f.missing_fixture_file) {
                        row.scope_missing_fixture_file = 1;
                    } else {
                        row.scope_recipes = 1;
                    }
                    try validateQueueRow(row);
                    try out.append(a, row);
                }
            }
            return out;
        }

        // fixtures-table candidates (`--all` / `--stale-by-*` /
        // `--available`/`--unavailable`/`--successful`/`--unsuccessful`).
        // Staleness is NOT pre-filtered at queue time: every candidate
        // row is queued with the marker the flag requested and the daemon
        // evaluates it at pop. Fixtures rows keep their stored platform.
        const fixtures = try selectFixtures(a, io);
        for (fixtures) |fx| {
            if (f.harness.len > 0 and !std.mem.eql(u8, f.harness, fx.harness)) continue;
            if (f.provider.len > 0 and !std.mem.eql(u8, f.provider, fx.provider)) continue;
            if (f.model.len > 0 and !std.mem.eql(u8, f.model, fx.model)) continue;
            if (f.platform.len > 0 and !std.mem.eql(u8, f.platform, fx.platform)) continue;
            if (f.available and !(fx.available != null and fx.available.? == 1)) continue;
            if (f.unavailable and !(fx.available != null and fx.available.? == 0)) continue;
            if (f.successful and !(fx.successful != null and fx.successful.? == 1)) continue;
            if (f.unsuccessful and !(fx.successful != null and fx.successful.? == 0)) continue;

            const modes = queueModes(f);
            for (modes) |mode_opt| {
                const mode = mode_opt orelse continue;
                if (f.stale_by_hash) {
                    const channel = if (std.mem.eql(u8, mode, "from-identity")) "from-identity" else "from-capture";
                    if (!(try channelStaleByHash(a, io, fx, channel))) continue;
                }
                // no-launch recipes under from-capture → invalid, not queued.
                if (std.mem.eql(u8, mode, "from-capture")) {
                    const agent = (try agentIdFrom(a, fx.harness, fx.provider, fx.model)) orelse continue;
                    const combo = recipeForAgent(agent);
                    if (combo == null or combo.?.launch == null) {
                        try insertInvalid(a, io, .{
                            .fixture_id = (try fixtureIdFrom(a, fx.harness, fx.provider, fx.model, fx.platform)) orelse null,
                            .agent_id = agent,
                            .harness_id = fx.harness,
                            .provider_id = fx.provider,
                            .model_id = fx.model,
                            .platform_id = fx.platform,
                            .reason = "no launch spec",
                            .created_at = now,
                        });
                        continue;
                    }
                }
                var row: QueueRow = .{
                    .harness = try a.dupe(u8, fx.harness),
                    .provider = try a.dupe(u8, fx.provider),
                    .model = try a.dupe(u8, fx.model),
                    .platform = try a.dupe(u8, fx.platform),
                    .runner = getParentPid(),
                    .created_at = now,
                    .mode = try a.dupe(u8, mode),
                };
                if (stale_min != null) row.stale_by_minutes = stale_min;
                if (f.stale_by_version) row.stale_by_version = 1;
                if (f.stale_by_detect) row.stale_by_detect = 1;
                if (f.stale_by_hash) row.stale_by_hash = 1;
                if (f.available) row.available = 1;
                if (f.unavailable) row.available = 0;
                if (f.successful) row.successful = 1;
                if (f.unsuccessful) row.successful = 0;
                try validateQueueRow(row);
                try out.append(a, row);
            }
        }
        return out;
    }

    /// true when the fixture row's channel generation hash is stale: the
    /// stored hash IS NULL OR differs from the BLAKE3 of the current
    /// fixture file's channel object (missing file or missing channel
    /// object = stale).
    fn channelStaleByHash(a: std.mem.Allocator, io: std.Io, fx: FixtureRow, channel: []const u8) !bool {
        const f_id = (try fixtureIdFrom(a, fx.harness, fx.provider, fx.model, fx.platform)) orelse return true;
        defer a.free(f_id);
        const ch = (try readChannelObject(a, io, f_id, channel)) orelse return true;
        const bytes = try std.json.Stringify.valueAlloc(a, ch, .{ .whitespace = .indent_2 });
        defer a.free(bytes);
        const cur = try generationHash(a, bytes);
        defer a.free(cur);
        const stored = if (std.mem.eql(u8, channel, "from-identity")) fx.identity_generation_hash else fx.capture_generation_hash;
        if (stored) |s| {
            if (std.mem.eql(u8, s, cur)) return false;
        }
        return true;
    }

    // ----------------------------------------------------------------
    // refresh subcommands
    // ----------------------------------------------------------------

    /// `fixtures capture` — capture the current real session into
    /// `fixtures/<id>.json` (top-level `from-capture` + `from-capture-raw`
    /// channel keys; any existing `from-identity` channel preserved) and
    /// upsert the matching `fixtures` row. Failure semantics: if the
    /// detection ladder fails to resolve harness *or* provider *or* model,
    /// exit 8 with no fixture written and no store change (partial
    /// detection is bad data per DESIGN). The daemon spawns this via the
    /// recipe's launch argv inside a live model session; a hand-run
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
        defer a.free(channel);
        const ch_v = try std.json.parseFromSlice(std.json.Value, a, channel, .{});
        const raw = try buildRaw(a, &d, init.environ_map);
        try mergeWriteFixture(a, io, fixture_id, &.{ "from-capture", "from-capture-raw" }, &.{ ch_v.value, raw });

        // fixtures only: upsert the state row (never touches `queue`).
        // Stamp the live harness `--version` snapshot so a later
        // `--stale-by-version` sweep can compare against it.
        const hver = harnessVersion(a, io, agent_aid);
        const now = unixNow(io);
        const hash = try generationHash(a, channel);
        defer a.free(hash);
        try upsertFixture(a, io, .{
            .harness = harness_aid orelse unreachable,
            .provider = provider_aid orelse unreachable,
            .model = model_aid orelse unreachable,
            .platform = platformId(),
            .runner = getParentPid(),
            .generated_at = now,
            .harness_version = hver,
            .available = 1,
            .successful = 1,
            .agent_detect_version = build_options.version,
            .capture_generation_at = now,
            .capture_generation_hash = hash,
        });

        writeOut(io, "fixtures capture: wrote fixtures/");
        writeOut(io, fixture_id);
        writeOut(io, ".json\n");
        return 0;
    }

    /// `fixtures queue [scope] <filters>` — enumerate + upsert queue rows
    /// (pure enqueue; no evaluation). Without a scope flag, a **seed** row
    /// is created per selected mode from the positive dims (`--harness=`,
    /// `--provider=`, `--model=`, `--platform=` or the composite
    /// `--agent=`/`--fixture=`) with the rest `null`; the daemon expands
    /// seeds over the recipes. With a scope flag (`--all`/`--stale-by-*`/
    /// `--recipes`/`--missing-fixture-file`/`--available`/`--unavailable`/
    /// `--successful`/`--unsuccessful`) the candidate set is computed (see
    /// `scopeCandidates`) and every candidate is queued per selected mode.
    /// `--missing-fixture-entry` re-registers orphaned fixture files
    /// instead of queuing. At least one filter option or scope flag is
    /// required (else exit 4). Idempotent via `queue_dedupe`.
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

        if (f.missing_fixture_entry) {
            return runMissingFixtureEntry(init);
        }

        if (scopeCount(f) > 0) {
            return runFixturesQueueScope(init, f);
        }

        // bare dims / --agent= / --fixture=: create a seed row per selected
        // mode (no scope).
        const positive = f.harness.len > 0 or f.provider.len > 0 or
            f.model.len > 0 or f.platform.len > 0 or f.composite;
        if (!positive) {
            writeErr(io, MSG_MISSING_ARG);
            writeOut(io, queueUsage);
            return EXIT_MISSING_ARG;
        }

        var queued: usize = 0;
        const modes = queueModes(f);
        for (modes) |mode_opt| {
            const mode = mode_opt orelse continue;
            const row: QueueRow = .{
                .harness = if (f.harness.len > 0) f.harness else null,
                .provider = if (f.provider.len > 0) f.provider else null,
                .model = if (f.model.len > 0) f.model else null,
                .platform = if (f.platform.len > 0) f.platform else null,
                .runner = getParentPid(),
                .created_at = unixNow(io),
                .mode = mode,
            };
            try validateQueueRow(row);
            try upsertQueueRow(a, io, row);
            queued += 1;
        }

        writeOut(io, "fixtures queue: queued ");
        writeCount(io, queued);
        writeOut(io, " seed(s)\n");
        return 0;
    }

    /// `fixtures queue --missing-fixture-entry` — scan every
    /// `fixtures/*.json`; files with no `fixtures` row are re-registered:
    /// valid ids (known rule dims + filename platform) → INSERT a
    /// `fixtures` entry (`successful=1`, `harness_version`/`available`/
    /// `agent_detect_version`/generation columns NULL, derived ids) — no
    /// queue row; invalid ids → `invalid` row (reason `unknown fixture
    /// file`); the file always persists.
    fn runMissingFixtureEntry(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;
        const now = unixNow(io);
        var entered: usize = 0;
        var invalid_count: usize = 0;
        var fixtures_dir = std.Io.Dir.cwd().openDir(io, "fixtures", .{ .iterate = true }) catch |err| {
            writeErr(io, MSG_IO);
            writeErr(io, @errorName(err));
            writeErr(io, "\n");
            return EXIT_IO;
        };
        defer fixtures_dir.close(io);
        var dir_it = fixtures_dir.iterate();
        while (dir_it.next(io) catch null) |ent| {
            if (ent.kind != .file) continue;
            const name = ent.name;
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            if (std.mem.endsWith(u8, name, "index.sqlite3")) continue;
            const stem = name[0 .. name.len - ".json".len];
            const parts = splitFixtureId(a, stem) catch {
                try insertInvalid(a, io, .{ .fixture_id = try a.dupe(u8, stem), .reason = "unknown fixture file", .created_at = now });
                invalid_count += 1;
                continue;
            };
            defer {
                a.free(parts[0]);
                a.free(parts[1]);
                a.free(parts[2]);
                a.free(parts[3]);
            }
            if (canonicalIdFor(a, HarnessRule, &rulesForHarnesses, parts[0]) == null or
                canonicalIdFor(a, ProviderRule, &rulesForProviders, parts[1]) == null or
                canonicalIdFor(a, ModelRule, &rulesForModels, parts[2]) == null)
            {
                try insertInvalid(a, io, .{
                    .fixture_id = try a.dupe(u8, stem),
                    .agent_id = (try agentIdFrom(a, parts[0], parts[1], parts[2])) orelse null,
                    .harness_id = try a.dupe(u8, parts[0]),
                    .provider_id = try a.dupe(u8, parts[1]),
                    .model_id = try a.dupe(u8, parts[2]),
                    .platform_id = try a.dupe(u8, parts[3]),
                    .reason = "unknown fixture file",
                    .created_at = now,
                });
                invalid_count += 1;
                continue;
            }
            if (try fixtureExists(a, io, parts[0], parts[1], parts[2], parts[3])) continue;
            try upsertFixture(a, io, .{
                .harness = try a.dupe(u8, parts[0]),
                .provider = try a.dupe(u8, parts[1]),
                .model = try a.dupe(u8, parts[2]),
                .platform = try a.dupe(u8, parts[3]),
                .runner = getParentPid(),
                .generated_at = now,
                .successful = 1,
            });
            entered += 1;
        }
        writeOut(io, "fixtures queue: --missing-fixture-entry — entered ");
        writeCount(io, entered);
        writeOut(io, " fixture row(s), recorded ");
        writeCount(io, invalid_count);
        writeOut(io, " invalid file(s)\n");
        return 0;
    }

    /// `fixtures queue <scope> [filters]` — enumerate the scope candidate set
    /// (see `scopeCandidates`) and upsert each into `queue`.
    fn runFixturesQueueScope(init: std.process.Init, f: FilterOptions) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        var candidates = try scopeCandidates(a, io, f);
        defer candidates.deinit(a);

        var queued: usize = 0;
        for (candidates.items) |row| {
            try upsertQueueRow(a, io, row);
            queued += 1;
        }

        writeOut(io, "fixtures queue: queued ");
        writeCount(io, queued);
        writeOut(io, "\n");
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

    /// true if the agent's harness binary is installed and runs
    /// `--version` successfully. The name list comes from the harness
    /// rule's `binary_names` (resolved from the composite `agent_id`),
    /// so recipe ids and daemon-split ids work interchangeably.
    fn harnessAvailable(a: std.mem.Allocator, io: std.Io, agent_id: []const u8) bool {
        const rule = harnessRuleForFixtureId(a, agent_id) orelse return false;
        return findBinary(a, io, rule.binary_names) != null;
    }

    /// `fixtures dequeue [scope] <filters>` — **DELETE only; pure row
    /// filters.** Builds the WHERE from dims + stored scope/marker columns
    /// + optional mode and deletes matching `queue` rows. No evaluation,
    /// no fixture mutation. At least one filter or scope flag is required.
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

        const deleted = try deleteQueueRows(a, io, f);

        writeOut(io, "fixtures dequeue: deleted ");
        writeCount(io, deleted);
        writeOut(io, " action(s)\n");
        return 0;
    }

    /// `fixtures daemon` — long-running. **Owns all evaluation.** Every
    /// poll it reads the oldest host-platform queue row (SELECT only),
    /// materializes `pending` work items for it, and processes one
    /// unfinished pending row. from-identity jobs resolve the declared
    /// channel (zero tokens); from-capture jobs probe availability then
    /// launch the real harness session (with a pre-capture review window,
    /// token-consuming, user-confirmed only). Pending rows are marked
    /// started/finished around each job; when a queue row's pending rows
    /// all finish, the pending rows and the queue row are deleted. The
    /// queue row is never deleted at pop — it is the crash-resume anchor
    /// (unfinished pending rows resume on the next run). Non-host-platform
    /// rows are never selected. **The daemon never writes `fixtures`
    /// outside pop processing and never inserts queue rows.**
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
            const log_file = std.Io.Dir.cwd().createFile(io, "fixtures/daemon.log", .{}) catch |err| {
                daemonWriteErr(io, "daemon: cannot open fixtures/daemon.log: ");
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
        daemonWrite(io, "  index file: fixtures/index.sqlite3\n");
        daemonWrite(io, "  control file: fixtures/daemon.ctl (write pause/resume/stop)\n");
        if (write_log) daemonWrite(io, "  log file: fixtures/daemon.log\n");
        daemonWrite(io, "  press Ctrl+C to stop\n");

        // decision #12 — one cross-platform control mechanism: the
        // daemon checks `fixtures/daemon.ctl` every ~1s heartbeat and
        // acts on pause/resume/stop, clearing the file after acting.
        var paused = false;
        var stop_requested = false;
        var phase: enum { idle, pre_capture, post_review } = .idle;
        var pending_capture: ?PendingRow = null;
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
                    daemonWrite(io, "s (write stop to fixtures/daemon.ctl to cancel)\n");
                    if (boot_now_ns >= phase_until.raw.nanoseconds) {
                        const job = pending_capture orelse {
                            phase = .idle;
                            continue;
                        };
                        pending_capture = null;
                        daemonWrite(io, "daemon: starting capture for ");
                        daemonWrite(io, job.fixture_id);
                        daemonWrite(io, "\n");
                        const ok = runOneComboCapture(a, io, init, job.fixture_id, capture_timeout_seconds) catch |err| blk: {
                            daemonWriteErr(io, "daemon: capture worker error: ");
                            daemonWriteErr(io, @errorName(err));
                            daemonWriteErr(io, "\n");
                            break :blk false;
                        };
                        try markPendingFinished(a, io, job.queue_id, job.fixture_id, unixNow(io));
                        if (try pendingDrained(a, io, job.queue_id)) {
                            try clearPendingAndQueueRow(a, io, job.queue_id);
                        }
                        phase = .post_review;
                        phase_until = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, review_seconds) * std.time.ns_per_s }, .clock = .boot });
                        if (ok) {
                            daemonWrite(io, "daemon: captured ");
                            daemonWrite(io, job.fixture_id);
                            daemonWrite(io, "\n");
                        } else {
                            daemonWriteErr(io, "daemon: from-capture failed for ");
                            daemonWriteErr(io, job.fixture_id);
                            daemonWriteErr(io, " — item consumed; retry via `fixtures queue --unsuccessful`\n");
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
                        // one row per poll (decision #10): schedule the next
                        // poll `poll_seconds` out on EVERY path below.
                        next_poll = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, poll_seconds) * std.time.ns_per_s }, .clock = .boot });
                        const row = try popQueueRow(a, io);
                        if (row) |action| {
                            const desc = try describeQueueRow(a, action);
                            var msg_buf: [320]u8 = undefined;
                            const m = std.fmt.bufPrint(msg_buf[0..], "daemon: processing {s} [{s}]\n", .{ desc, action.mode }) catch "daemon: processing\n";
                            daemonWrite(io, m);

                            // shared validator: invalid → warn + drop.
                            validateQueueRow(action) catch {
                                daemonWriteErr(io, "daemon: invalid action row — dropping: ");
                                daemonWriteErr(io, desc);
                                daemonWriteErr(io, "\n");
                                try deleteQueueRowById(a, io, action.queue_id);
                                continue;
                            };

                            const qid = action.queue_id;
                            // materialize pending rows (INSERT OR IGNORE —
                            // crash-resume safe; a full row → one pending
                            // row, a seed → one per applicable recipe).
                            const full = action.harness != null and action.provider != null and
                                action.model != null and action.platform != null;
                            if (!full) {
                                try materializeSeedPending(a, io, action);
                            } else {
                                const f_id = (try fixtureIdFrom(a, action.harness.?, action.provider.?, action.model.?, action.platform.?)) orelse {
                                    // empty-string dim on a full row: malformed — drop.
                                    try insertInvalid(a, io, .{ .reason = "malformed queue row", .created_at = unixNow(io) });
                                    try deleteQueueRowById(a, io, qid);
                                    continue;
                                };
                                try insertPendingRow(a, io, qid, f_id);
                            }

                            const job = (try nextUnfinishedPending(a, io, qid)) orelse {
                                // already drained (e.g. empty seed expansion).
                                try clearPendingAndQueueRow(a, io, qid);
                                continue;
                            };
                            const parts = splitFixtureId(a, job.fixture_id) catch {
                                try insertInvalid(a, io, .{ .fixture_id = try a.dupe(u8, job.fixture_id), .reason = "malformed fixture id", .created_at = unixNow(io) });
                                try markPendingFinished(a, io, qid, job.fixture_id, unixNow(io));
                                continue;
                            };
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

                            // staleness conjunction: a row skips only when
                            // every marker it carries is fresh.
                            if (action.stale_by_minutes != null or
                                (action.stale_by_version != null and action.stale_by_version.? == 1) or
                                (action.stale_by_detect != null and action.stale_by_detect.? == 1) or
                                (action.stale_by_hash != null and action.stale_by_hash.? == 1))
                            {
                                if (try rowMarkersAllFresh(a, io, action, job.fixture_id)) {
                                    daemonWrite(io, "daemon: fixture for ");
                                    daemonWrite(io, job.fixture_id);
                                    daemonWrite(io, " is still fresh by its markers — completing early\n");
                                    try markPendingFinished(a, io, qid, job.fixture_id, unixNow(io));
                                    if (try pendingDrained(a, io, qid)) {
                                        try clearPendingAndQueueRow(a, io, qid);
                                    }
                                    continue;
                                }
                            }

                            try markPendingStarted(a, io, qid, job.fixture_id, unixNow(io));

                            if (std.mem.eql(u8, action.mode, "from-capture")) {
                                if (pending_capture != null) {
                                    daemonWrite(io, "daemon: already have a pending from-capture job — skipping\n");
                                    continue;
                                }
                                pending_capture = job;
                                phase = .pre_capture;
                                phase_until = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @as(i96, review_seconds) * std.time.ns_per_s }, .clock = .boot });
                                daemonWrite(io, "daemon: from-capture job — announcing ");
                                daemonWriteCount(io, review_seconds);
                                daemonWrite(io, "s before capture (write stop to fixtures/daemon.ctl to cancel)\n");
                                continue;
                            }

                            const ok = runOneComboIdentity(a, io, h, p, m_d, plat) catch |err| blk: {
                                daemonWriteErr(io, "daemon: identity worker error: ");
                                daemonWriteErr(io, @errorName(err));
                                daemonWriteErr(io, "\n");
                                break :blk false;
                            };
                            if (ok) {
                                var buf2: [256]u8 = undefined;
                                const msg = std.fmt.bufPrint(buf2[0..], "daemon: declared {s}\n", .{job.fixture_id}) catch "daemon: declared\n";
                                daemonWrite(io, msg);
                            } else {
                                daemonWriteErr(io, "daemon: from-identity failed for ");
                                daemonWriteErr(io, job.fixture_id);
                                daemonWriteErr(io, "\n");
                            }
                            try markPendingFinished(a, io, qid, job.fixture_id, unixNow(io));
                            if (try pendingDrained(a, io, qid)) {
                                try clearPendingAndQueueRow(a, io, qid);
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

    /// rank a refresh mode for ordering: `from-identity` (0) <
    /// `from-capture` (1). Declared work precedes token-consuming
    /// captures.
    fn modeRank(mode: []const u8) u8 {
        if (std.mem.eql(u8, mode, "from-identity")) return 0;
        return 1;
    }

    /// true when every staleness marker a queue row carries says the
    /// fixture is still fresh (the daemon skips such rows early). A row
    /// with no staleness markers returns false (never skip).
    fn rowMarkersAllFresh(a: std.mem.Allocator, io: std.Io, action: QueueRow, f_id: []const u8) !bool {
        const fx = if (action.harness != null and action.provider != null and action.model != null and action.platform != null)
            try fixtureRow(a, io, action.harness.?, action.provider.?, action.model.?, action.platform.?)
        else
            null;
        var any: bool = false;
        if (action.stale_by_minutes != null) {
            any = true;
            if (fx) |f| {
                if (isStale(io, f.generated_at, action.stale_by_minutes.?)) return false;
            } else return false; // no fixture row → age-stale
        }
        if (action.stale_by_version != null and action.stale_by_version.? == 1) {
            any = true;
            if (fx) |f| {
                if (f.harness_version) |stored_v| {
                    const h = action.harness orelse return false;
                    const p = action.provider orelse return false;
                    const m = action.model orelse return false;
                    const agent = (try agentIdFrom(a, h, p, m)) orelse return false;
                    if (harnessVersion(a, io, agent)) |live_v| {
                        if (!std.mem.eql(u8, live_v, stored_v)) return false;
                    } else return false; // uninstalled → not version-equal → stale
                } else return false; // no stored version → stale
            } else return false; // no fixture row → stale
        }
        if (action.stale_by_detect != null and action.stale_by_detect.? == 1) {
            any = true;
            if (fx) |f| {
                if (f.agent_detect_version) |v| {
                    if (!std.mem.eql(u8, v, build_options.version)) return false;
                } else return false; // NULL → not fresh
            } else return false; // no fixture row → stale
        }
        if (action.stale_by_hash != null and action.stale_by_hash.? == 1) {
            any = true;
            const channel = if (std.mem.eql(u8, action.mode, "from-identity")) "from-identity" else "from-capture";
            const ch = (try readChannelObject(a, io, f_id, channel)) orelse return false;
            const bytes = try std.json.Stringify.valueAlloc(a, ch, .{ .whitespace = .indent_2 });
            defer a.free(bytes);
            const cur = try generationHash(a, bytes);
            defer a.free(cur);
            const stored = if (fx) |f| (if (std.mem.eql(u8, channel, "from-identity")) f.identity_generation_hash else f.capture_generation_hash) else null;
            if (stored) |s| {
                if (!std.mem.eql(u8, s, cur)) return false;
            } else return false; // no stored hash → stale
        }
        return any;
    }

    /// read `fixtures/daemon.ctl`, clear it, and return the action word
    /// (`pause` / `resume` / `stop`) or null when absent/empty. The
    /// daemon clears the file after acting (decision #12).
    fn readControlAction(a: std.mem.Allocator, io: std.Io) ?[]const u8 {
        const data = std.Io.Dir.cwd().readFileAlloc(io, "fixtures/daemon.ctl", a, @enumFromInt(4096)) catch return null;
        // no `a.free(data)` — the returned word aliases `data` (Zig 0.16
        // arena free-list would reclaim it into the daemon's next
        // allocations, clobbering the action word mid-use).
        std.Io.Dir.cwd().deleteFile(io, "fixtures/daemon.ctl") catch {};
        const t = std.mem.trim(u8, data, " \t\r\n");
        if (t.len == 0) return null;
        if (std.mem.eql(u8, t, "pause") or std.mem.eql(u8, t, "resume") or std.mem.eql(u8, t, "stop")) return t;
        return null;
    }

    /// true iff `generated_at` (unix secs) is older than `threshold_minutes`.
    fn isStale(io: std.Io, generated_at: i64, threshold_minutes: i64) bool {
        const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
        return now - generated_at > threshold_minutes * 60;
    }

    /// expand a partial (seed) action into `pending` rows. A seed is a
    /// queue row: "capture every applicable recipe matching these dims".
    /// Every applicable recipe (set dims equal, platform empty or host)
    /// gets one pending row on the host platform; no-launch recipes under
    /// from-capture → `invalid`, excluded. INSERT OR IGNORE keeps
    /// crash-resume re-materialization idempotent.
    fn materializeSeedPending(a: std.mem.Allocator, io: std.Io, seed: QueueRow) !void {
        const host = platformId();
        var any: bool = false;
        for (recipesForFixtures) |c| {
            if (!recipeMatchesAction(seed, c, host)) continue;
            const f_id = try fixtureId(a, c.agent_id);
            defer a.free(f_id);
            if (std.mem.eql(u8, seed.mode, "from-capture") and c.launch == null) {
                const parts = try splitAgentId(a, c.agent_id);
                defer {
                    a.free(parts[0]);
                    a.free(parts[1]);
                    a.free(parts[2]);
                }
                try insertInvalid(a, io, .{
                    .fixture_id = try a.dupe(u8, f_id),
                    .agent_id = try a.dupe(u8, c.agent_id),
                    .harness_id = try a.dupe(u8, parts[0]),
                    .provider_id = try a.dupe(u8, parts[1]),
                    .model_id = try a.dupe(u8, parts[2]),
                    .platform_id = try a.dupe(u8, host),
                    .reason = "no launch spec",
                    .created_at = unixNow(io),
                });
                continue;
            }
            try insertPendingRow(a, io, seed.queue_id, f_id);
            any = true;
        }
        if (!any) {
            daemonWriteErr(io, "daemon: warning: no capture recipe applicable for ");
            daemonWriteErr(io, try describeQueueRow(a, seed));
            daemonWriteErr(io, "\n");
        }
    }

    /// does every dim that `seed` has set equal the recipe's dims?
    fn recipeMatchesAction(seed: QueueRow, combo: RecipesForFixtures, host: []const u8) bool {
        const parts = splitAgentId(std.heap.page_allocator, combo.agent_id) catch return false;
        defer {
            std.heap.page_allocator.free(parts[0]);
            std.heap.page_allocator.free(parts[1]);
            std.heap.page_allocator.free(parts[2]);
        }
        if (seed.harness) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, parts[0])) return false;
        }
        if (seed.provider) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, parts[1])) return false;
        }
        if (seed.model) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, parts[2])) return false;
        }
        if (seed.platform) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, host)) return false;
        }
        return true;
    }

    /// post-check for a captured fixture: parse `fixtures/<id>.json`,
    /// verify combo-match — the `from-capture.identify` object's
    /// harness/provider/model ids equal the queued dims. Returns false on
    /// any failure (the caller stamps `successful=0`; the committed file
    /// is left intact).
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
    /// the `from-identity.identify` dims match the queue row. Declared
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
    /// assemble the `from-identity` channel (`identify` = the 17-field
    /// buildCooked object; `trailer co-author`/`trailer assisted-by` from
    /// spawning the real CLI with the combo flags), merge-write it into
    /// `fixtures/<id>.json` (preserving `from-capture`/`from-capture-raw`),
    /// and upsert the fixtures row with the identity generation columns.
    /// Declared, not observed. Returns success; failure stamps
    /// `successful=0` with `generated_at=now`.
    fn runOneComboIdentity(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !bool {
        var d = (try resolveRecipe(a, h, p, m)) orelse {
            daemonWriteErr(io, "daemon: from-identity: combo not in the rule tables — cannot declare a fixture\n");
            try markCaptureOutcome(a, io, h, p, m, plat, null, 0);
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
        const co = if (self_path) |sp| try spawnTrailerLine(a, io, sp, "co-author", h, p, m) else null;
        const ab = if (self_path) |sp| try spawnTrailerLine(a, io, sp, "assisted-by", h, p, m) else null;

        const channel = try channelJson(a, cooked, co, ab);
        defer a.free(channel);
        const ch_v = try std.json.parseFromSlice(std.json.Value, a, channel, .{});
        const f_id = (try fixtureIdFrom(a, h, p, m, plat)) orelse return false;
        defer a.free(f_id);
        try mergeWriteFixture(a, io, f_id, &.{"from-identity"}, &.{ch_v.value});

        if (!(try postCheckDeclaredFixture(a, io, h, p, m, plat))) {
            daemonWriteErr(io, "daemon: from-identity: post-check failed — marking unsuccessful\n");
            try markCaptureOutcome(a, io, h, p, m, plat, null, 0);
            return false;
        }

        const now = unixNow(io);
        const hash = try generationHash(a, channel);
        defer a.free(hash);
        try upsertFixture(a, io, .{
            .harness = h,
            .provider = p,
            .model = m,
            .platform = plat,
            .runner = getParentPid(),
            .generated_at = now,
            .successful = 1,
            .agent_detect_version = build_options.version,
            .identity_generation_at = now,
            .identity_generation_hash = hash,
        });
        return true;
    }

    /// stamp the shared daemon outcome markers (`available` /
    /// `successful`) for a capture attempt. The repeated `upsertFixture`
    /// dances in the capture workers call this — one shape, one place.
    fn markCaptureOutcome(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8, available: ?i64, successful: ?i64) !void {
        try upsertFixture(a, io, .{
            .harness = h,
            .provider = p,
            .model = m,
            .platform = plat,
            .runner = getParentPid(),
            .generated_at = unixNow(io),
            .available = available,
            .successful = successful,
        });
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

    /// `from-capture` worker: launch the real harness headlessly so it
    /// runs `fixtures capture` inside a live model session. Uses the
    /// REAL environment (real API keys/config are required); cwd stays
    /// the daemon's (the repo root) so the session writes
    /// `fixtures/<id>.json` into the repo. A watchdog subprocess
    /// (`fixtures __timeout`) enforces `--capture-timeout-seconds` so a
    /// hung harness fails out instead of blocking the poll loop forever.
    /// Success = child exit 0 AND the post-check passing. Failures
    /// consume the item: launch-spec/availability/spawn/nonzero/
    /// post-check failures stamp the appropriate `available`/`successful`
    /// markers (never re-queue, never delete the committed file).
    /// Token-consuming — user-confirmed only.
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
        const agent = (try agentIdFrom(a, h, p, m_d)) orelse return false;
        defer a.free(agent);
        const combo = recipeForAgent(agent);
        const c = combo orelse {
            daemonWriteErr(io, "daemon: from-capture: no recipe for ");
            daemonWriteErr(io, agent);
            daemonWriteErr(io, "\n");
            try markCaptureOutcome(a, io, h, p, m_d, plat, 1, 0);
            return false;
        };
        // launch-spec backstop guard: no launch → invalid, no fixtures
        // write.
        const launch = c.launch orelse {
            try insertInvalid(a, io, .{
                .fixture_id = try a.dupe(u8, fixture_id),
                .agent_id = try a.dupe(u8, agent),
                .harness_id = try a.dupe(u8, h),
                .provider_id = try a.dupe(u8, p),
                .model_id = try a.dupe(u8, m_d),
                .platform_id = try a.dupe(u8, plat),
                .reason = "no launch spec",
                .created_at = unixNow(io),
            });
            return false;
        };
        // availability probe: uninstalled harness → available=0,
        // successful=0, consumed.
        if (!harnessAvailable(a, io, agent)) {
            daemonWriteErr(io, "daemon: from-capture: harness unavailable for ");
            daemonWriteErr(io, agent);
            daemonWriteErr(io, " — available=0, successful=0\n");
            try markCaptureOutcome(a, io, h, p, m_d, plat, 0, 0);
            return false;
        }

        // launch argv[0] substitution — cycle the harness rule's
        // `binary_names` as argv[0] over the recipe's `launch` template
        // until `std.process.spawn` succeeds. After a successful spawn
        // there is no re-cycle on runtime failure: a failed real launch
        // is an artifact failure, not a name miss (retrying burns
        // tokens twice).
        var child: ?std.process.Child = null;
        var spawn_err: ?anyerror = null;
        if (harnessRuleForFixtureId(a, agent)) |rule| {
            var argv_storage: [32][]const u8 = undefined;
            for (rule.binary_names) |name| {
                var argc: usize = 0;
                argv_storage[argc] = name;
                argc += 1;
                for (launch[1..]) |arg| {
                    if (argc >= argv_storage.len) break;
                    argv_storage[argc] = arg;
                    argc += 1;
                }
                if (std.process.spawn(io, .{
                    .argv = argv_storage[0..argc],
                    .environ_map = init.environ_map,
                    .stdout = .ignore,
                    .stderr = .pipe,
                })) |spawned| {
                    child = spawned;
                    break;
                } else |err| {
                    spawn_err = err;
                }
            }
        }
        const child_v = child orelse {
            daemonWriteErr(io, "daemon: from-capture: spawn failed");
            if (spawn_err) |err| {
                daemonWriteErr(io, ": ");
                daemonWriteErr(io, @errorName(err));
            }
            daemonWriteErr(io, "\n");
            try markCaptureOutcome(a, io, h, p, m_d, plat, 1, 0);
            return false;
        };

        // timeout watchdog — `agent-detect-dev fixtures __timeout <sec> <pid>`.
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const argv0 = selfPath(io, &self_path_buf) orelse return false;
        const pid_num: u32 = if (builtin.os.tag == .windows)
            GetProcessId(child_v.id orelse return false)
        else
            @intCast(child_v.id orelse return false);
        const pid_str = try std.fmt.allocPrint(a, "{d}", .{pid_num});
        var tbuf: [64]u8 = undefined;
        const sec_str = std.fmt.bufPrint(&tbuf, "{d}", .{timeout_seconds}) catch "";
        var wargv = [_][]const u8{ argv0, "fixtures", "__timeout", sec_str, pid_str };
        _ = std.process.spawn(io, .{ .argv = &wargv, .stdout = .ignore, .stderr = .ignore }) catch {};

        const stderr_capture = readChildOutput(a, io, child_v, true) catch "";
        defer if (stderr_capture.len > 0) a.free(stderr_capture);
        var child_mut = child_v;
        const term = child_mut.wait(io) catch |err| {
            daemonWriteErr(io, "daemon: from-capture: child wait failed: ");
            daemonWriteErr(io, @errorName(err));
            daemonWriteErr(io, "\n");
            try markCaptureOutcome(a, io, h, p, m_d, plat, 1, 0);
            return false;
        };
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    daemonWriteErr(io, "daemon: from-capture worker failed for ");
                    daemonWriteErr(io, agent);
                    daemonWriteErr(io, " (exit code ");
                    daemonWriteErrCount(io, code);
                    daemonWriteErr(io, ")\n");
                    if (stderr_capture.len > 0) {
                        daemonWriteErr(io, "  worker stderr: ");
                        daemonWriteErr(io, stderr_capture);
                        if (stderr_capture[stderr_capture.len - 1] != '\n') daemonWriteErr(io, "\n");
                    }
                    // detection-partial (exit 8) lands here too — valid ids,
                    // failed attempt → successful=0, retried via --unsuccessful.
                    try markCaptureOutcome(a, io, h, p, m_d, plat, 1, 0);
                    return false;
                }
                if (!(try postCheckComboFixture(a, io, h, p, m_d, plat))) {
                    // override the row the session wrote (it stamped
                    // successful=1); the committed file is left intact.
                    try markCaptureOutcome(a, io, h, p, m_d, plat, 1, 0);
                    return false;
                }
                return true;
            },
            else => {
                daemonWriteErr(io, "daemon: from-capture child terminated abnormally for ");
                daemonWriteErr(io, agent);
                daemonWriteErr(io, "\n");
                try markCaptureOutcome(a, io, h, p, m_d, plat, 1, 0);
                return false;
            },
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
