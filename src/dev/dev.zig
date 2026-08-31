// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detect-dev — the maintainer-only fixtures surface: the `fixtures`
// namespace (daemon, capture, queue, dequeue, status) plus the standalone
// `raw` action. Compiled into the binary only when built with `-Ddev=true`;
// `pub const dev` below is the comptime-gated struct, so the released
// binary never links this surface.
//
// The fixtures state is split two ways. `fixtures/.index.json` holds only
// the non-derivable state — `queue` (work intent), `backlog` (unresolvable
// dims / missing curation), and `known_but_failed` (retryable failure
// messages). Everything else about a fixture lives in the fixture files
// themselves: `fixtures/from-identity/<id>.json` (declared identifications)
// and `fixtures/from-capture/<id>.json` (live captures and curated
// meta-only stubs), each a self-contained `{ outputs, meta }` envelope
// owned exclusively by its writer — see fixtures/fixture.d.ts and
// fixtures/.index.d.ts for the normative schemas. `fixtures capture` runs
// inside a real agent session (spawned by the daemon via the file's
// curated `meta.prompt_launch` argv, or by hand) and writes the whole
// from-capture file atomically; no merge-write, no store row.
//
// `fixtures daemon` is the long-running user-side mode: it watches the
// `queue` array of `fixtures/.index.json` and, per poll, expands one
// queue entry into its candidate set (resolvable dims ∧ (fixtured ∨
// feasible-unfixtured per the reference grids) ∧ the entry's staleness
// criteria) and works ONE remaining host-platform candidate
// (runFixturesCapture runs in-process in the session the daemon
// launched). The released binary (built with -Ddev=false, the default)
// has none of this — its CLI surface is `identify` (JSON report),
// `trailer co-author` / `trailer assisted-by`, `check-reciprocal`,
// `help`, and `version`; no arguments shows help.


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
        \\state: fixtures/.index.json is the committed JSON store, holding only
        \\the non-derivable state: `queue` (filter entries the daemon expands),
        \\`backlog` (actionable gaps: unknown_harnesses / unknown_providers /
        \\unknown_models / needs_curation), and `known_but_failed` (retryable
        \\failure messages). The fixtures themselves are self-contained files:
        \\fixtures/from-identity/<id>.json (declared identifications) and
        \\fixtures/from-capture/<id>.json (live captures and curated meta-only
        \\stubs), each a `{ outputs, meta }` envelope — see fixtures/fixture.d.ts.
        \\The free axis is sourced from fixtures/.providers_freemodels.csv;
        \\feasibility from fixtures/.harnesses_providers.csv and
        \\fixtures/.providers_models.csv. Store writers take an exclusive lock
        \\on fixtures/.index.json.lock and write atomically (temp + rename);
        \\each fixture file is owned exclusively by its channel's writer.
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
        \\staleness, and filters are shared and documented once):
        \\  (none), help, --help, -h   this help
        \\  daemon                     expand the queue-entry array (identity
        \\                              entries: declared generation; capture
        \\                              entries: real harness session), one
        \\                              candidate per poll — run as a user,
        \\                              never inside an agent; --write-log also
        \\                              writes all daemon output to
        \\                              fixtures/.daemon.log
        \\  capture                    capture the current session into
        \\                              fixtures/from-capture/<id>.json (spawned
        \\                              by the daemon; fixtures only)
        \\  queue                      upsert one queue entry per refresh mode
        \\                              from the given dims/staleness flags (no
        \\                              evaluation; the daemon expands);
        \\                              --repair pops the backlog
        \\  dequeue                    DELETE matching queue entries (filters
        \\                              required; never touches fixtures)
        \\  status                     print the derived snapshot: fixtured
        \\                              counts, backlog sets, feasible-unfixtured
        \\                              totals, stale/fresh breakdowns (also
        \\                              maintains the backlog table)
        \\
        \\exit codes: 0 = ok, 2 = unrecognised argument, 3 = conflicting argument,
        \\4 = missing required arguments, 5 = incompatible environment, 6 = incomplete
        \\environment, 8 = unable to detect, 11 = out of memory, 12 = index store error,
        \\13 = filesystem I/O error
        \\
    ;

    /// flags shared by `fixtures queue` and `fixtures dequeue` (modes,
    /// staleness, filters). Referenced by both subcommand usages so
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
        \\staleness (a queue entry carries a SET of criteria; a candidate is
        \\stale iff ANY carried criterion says stale; absent evidence ⇒ stale):
        \\  --stale                 the composite: output-drift OR age 27 days OR
        \\                    harness-version OR detect-version — the default
        \\                    when no staleness flag is given
        \\  --stale-by-output-drift    the two channel files' outputs.identify are
        \\                    not both present and deep-equal (missing = stale)
        \\  --stale-by-days=N      mode-scoped age of meta.updated_at, in days
        \\  --stale-by-hours=N     ditto, in hours
        \\  --stale-by-minutes=N   ditto, in minutes — the daemon skips only
        \\                   when the file is still age-fresh
        \\  --stale-by-harness-version  meta.harness_version differs from a live
        \\                   version_launch probe
        \\  --stale-by-detect-version   meta.agent_detect_version is absent or
        \\                   differs from this binary's version
        \\  --refresh         carry NO criteria — every candidate is worked
        \\                   regardless of freshness. Conflicts with --stale and
        \\                   every --stale-* (exit 3). `--stale` together with an
        \\                   explicit --stale-* keeps the composite and lets the
        \\                   explicit flag overwrite just that component.
        \\
        \\other:
        \\  --repair          (queue only) pop the backlog and re-queue the
        \\                   now-actionable items against the current rule
        \\                   tables and grids; unresolvable / still-uncurated
        \\                   items stay in the backlog
        \\  --free / --paid   membership in .providers_freemodels.csv
        \\
    ;

    /// usage for `fixtures queue` — printed by `fixtures queue --help`
    /// and on queue argument errors. Subcommand-scoped so an error never
    /// dumps the whole namespace help.
    pub const queueUsage =
        \\agent-detect fixtures queue — upsert queue entries (no evaluation)
        \\
        \\usage: agent-detect fixtures queue [staleness] [filters] [mode]
        \\
        \\One queue entry per selected mode is upserted from the given dims and
        \\staleness criteria (no mode flag → both `--from-identity` and
        \\`--from-capture` entries). With no staleness flag the full `--stale`
        \\composite is stamped; an explicit `--stale-*` forms the criteria set
        \\alone; `--stale` plus an explicit `--stale-*` overwrites just that
        \\composite component; `--refresh` stamps no criteria. The daemon
        \\expands entries — queue never evaluates. A re-assert of an existing
        \\(dims, mode, criteria, free) tuple replaces the entry in place and
        \\resets its `started_at` (a fresh sweep). At least one filter or
        \\staleness flag is required (or `--repair`).
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
        \\usage: agent-detect fixtures dequeue [staleness] [filters] [mode]
        \\
        \\Deletes every `queue` entry matching the filters. Filters are
        \\required; no evaluation happens, nothing is captured. Dequeue
        \\defaulting mirrors queue, so a bare filter matches exactly the entry
        \\a bare upsert created; `--refresh` matches criteria-less entries.
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
    // index.json state store (queue + backlog + known_but_failed)
    // ------------------------------------------------------------------

    const INDEX_PATH = "fixtures/.index.json";
    const INDEX_LOCK_PATH = "fixtures/.index.json.lock";
    const INDEX_TMP_PATH = "fixtures/.index.json.tmp";
    const INDEX_STORE_VERSION: i64 = 2;
    const INDEX_LOCK_BUDGET_MS: u64 = 5000;
    const INDEX_LOCK_RETRY_MS: u64 = 50;

    /// the fixtures directory every scanner/writer roots at. Production
    /// code uses the repo's `fixtures/`; the store tests re-root it at a
    /// throwaway tree via `setFixturesRootForTests`.
    var fixtures_root: []const u8 = "fixtures";

    /// test hook: point the channel-folder scanners at a throwaway tree
    /// (a directory containing `from-identity/` / `from-capture/`).
    pub fn setFixturesRootForTests(path: []const u8) void {
        fixtures_root = path;
    }

    /// the two per-channel folder names. The directory IS the channel —
    /// no channel key prefixes inside files.
    const IDENTITY_DIR = "from-identity";
    const CAPTURE_DIR = "from-capture";

    /// the canonical platforms of the fixtures universe.
    const platforms_all = [_][]const u8{ "darwin", "linux", "windows" };

    fn modeFolder(mode: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, mode, "from-identity")) return IDENTITY_DIR;
        if (std.mem.eql(u8, mode, "from-capture")) return CAPTURE_DIR;
        return null;
    }

    /// `fixtures/<folder>/<stem>.json` — a channel file's path. Caller owns.
    fn channelPath(a: std.mem.Allocator, folder: []const u8, stem: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ fixtures_root, folder, stem });
    }

    /// current unix epoch seconds (staleness source / ledger stamps).
    fn unixNow(io: std.Io) i64 {
        const ts = std.Io.Clock.Timestamp.now(io, .real);
        return ts.raw.toSeconds();
    }

    /// fresh default store root (missing index.json → this).
    fn emptyRoot(a: std.mem.Allocator) !std.json.Value {
        var root: std.json.Value = .{ .object = .empty };
        try root.object.put(a, "store_version", .{ .integer = INDEX_STORE_VERSION });
        try root.object.put(a, "queue", .{ .array = std.json.Array.init(a) });
        try root.object.put(a, "backlog", .{ .object = .empty });
        try root.object.put(a, "known_but_failed", .{ .object = .empty });
        return root;
    }

    /// acquire the exclusive lock on `fixtures/.index.json.lock` (creating
    /// it when missing). Retries with `tryLock` on a ~5s budget, sleeping
    /// 50ms between attempts. Kernel-managed locks release on exit/crash —
    /// no stale-lock heuristics. Caller owns the returned file; closing it
    /// unlocks.
    fn acquireIndexLock(io: std.Io) !std.Io.File {
        std.Io.Dir.cwd().createDirPath(io, fixtures_root) catch |err| switch (err) {
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
    /// temp+rename write protocol makes visibility atomic). The legacy
    /// store v1 tables (`fixtures` map + `errors` ledger — both superseded
    /// by the per-channel fixture files, and the free axis' original
    /// table) are dropped on load and never re-serialized: back-compat by
    /// drop, not dual-read.
    fn indexLoad(io: std.Io, a: std.mem.Allocator) !std.json.Value {
        const data = std.Io.Dir.cwd().readFileAlloc(io, INDEX_PATH, a, @enumFromInt(1 << 26)) catch |err| switch (err) {
            error.FileNotFound => return emptyRoot(a),
            else => return error.IndexStoreError,
        };
        var parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return error.IndexStoreError;
        if (parsed.value != .object) return error.IndexStoreError;
        const sv = parsed.value.object.get("store_version") orelse return error.IndexStoreError;
        if (sv != .integer or sv.integer != INDEX_STORE_VERSION) return error.IndexStoreError;
        _ = parsed.value.object.orderedRemove("fixtures");
        _ = parsed.value.object.orderedRemove("errors");
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

    /// One entry in the `queue` array — a filter tuple, never a concrete
    /// work item (only the daemon expands). Dims are nullable filters.
    /// The entry carries a SET of staleness criteria (a candidate is
    /// stale iff ANY carried criterion says stale); all four absent =
    /// a `--refresh` entry (every candidate is worked). `free` is a
    /// nullable affirmative boolean (null = unset). `started_at` is
    /// stamped by the daemon on first work of the entry — the pop
    /// protocol's comparison anchor; there is no `finished_at`
    /// (fully-satisfied entries are purged). `runner` records the
    /// enqueueing pid (provenance lives here only — fixture files carry
    /// no runner).
    pub const QueueEntry = struct {
        harness: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        model: ?[]const u8 = null,
        platform: ?[]const u8 = null,
        mode: []const u8 = "",
        stale_by_output_drift: bool = false,
        stale_by_minutes: ?i64 = null,
        stale_by_harness_version: bool = false,
        stale_by_detect_version: bool = false,
        free: ?bool = null,
        runner: i64 = 0,
        started_at: ?i64 = null,
    };

    /// the staleness criteria a queue entry carries, as stamped from the
    /// CLI flags. A candidate is stale iff ANY carried criterion says
    /// stale (OR, short-circuit per candidate); no criteria carried =
    /// a `--refresh` entry (everything is worked).
    pub const StaleCriteria = struct {
        output_drift: bool = false,
        minutes: ?i64 = null,
        harness_version: bool = false,
        detect_version: bool = false,

        /// the `--stale` composite: output-drift OR age 27 days OR
        /// harness-version OR detect-version. This is what a queue
        /// upsert carries when no staleness flag is given — idle
        /// re-queues only pick genuinely stale combos, and `--refresh`
        /// is the one explicit opt back into full re-evaluation.
        pub const composite: StaleCriteria = .{
            .output_drift = true,
            .minutes = 27 * 24 * 60,
            .harness_version = true,
            .detect_version = true,
        };

        pub fn isNone(self: StaleCriteria) bool {
            return !self.output_drift and self.minutes == null and
                !self.harness_version and !self.detect_version;
        }

        pub fn eql(x: StaleCriteria, y: StaleCriteria) bool {
            return x.output_drift == y.output_drift and x.minutes == y.minutes and
                x.harness_version == y.harness_version and x.detect_version == y.detect_version;
        }
    };

    /// one channel file loaded from `fixtures/<folder>/<stem>.json` —
    /// the dims come from the stem (the filename is the only channel
    /// key); `identify` is `outputs.identify`; the meta fields are the
    /// ledger + curation stamps. `exists == false` for absent/unparseable
    /// files (the caller treats absent evidence as stale).
    pub const ChannelFile = struct {
        stem: []const u8 = "",
        harness: []const u8 = "",
        provider: []const u8 = "",
        model: []const u8 = "",
        platform: []const u8 = "",
        valid_stem: bool = false,
        exists: bool = false,
        identify: ?std.json.Value = null,
        updated_at: ?i64 = null,
        agent_detect_version: ?[]const u8 = null,
        harness_version: ?[]const u8 = null,
        prompt_launch: ?[]const []const u8 = null,
        version_launch: ?[]const []const u8 = null,
    };

    /// load `fixtures/<folder>/<stem>.json` into a `ChannelFile`. Missing
    /// or unparseable → the zero file with `exists = false` (no error —
    /// absence is a staleness input, not a fault).
    pub fn loadChannelFile(io: std.Io, a: std.mem.Allocator, folder: []const u8, stem: []const u8) !ChannelFile {
        var cf = ChannelFile{ .stem = stem };
        if (splitFixtureId(a, stem)) |parts| {
            cf.harness = parts[0];
            cf.provider = parts[1];
            cf.model = parts[2];
            cf.platform = parts[3];
            cf.valid_stem = true;
        } else |_| {}
        const path = try channelPath(a, folder, stem);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 24)) catch return cf;
        // no `a.free(data)` — the returned Value aliases the parsed
        // buffer (see zig.md: freeing an aliased arena slice clobbers it).
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return cf;
        if (parsed.value != .object) return cf;
        cf.exists = true;
        if (parsed.value.object.get("outputs")) |outputs| {
            if (outputs == .object) {
                cf.identify = outputs.object.get("identify");
                if (cf.identify != null and cf.identify.? != .object) cf.identify = null;
            }
        }
        if (parsed.value.object.get("meta")) |meta| {
            if (meta == .object) {
                const mo = meta.object;
                cf.updated_at = jint(mo, "updated_at");
                cf.agent_detect_version = jstr(mo, "agent_detect_version");
                cf.harness_version = jstr(mo, "harness_version");
                cf.prompt_launch = stringArrayFromValue(a, mo.get("prompt_launch"));
                cf.version_launch = stringArrayFromValue(a, mo.get("version_launch"));
            }
        }
        return cf;
    }

    /// write a whole channel file atomically (temp + rename) — the
    /// writer owns the file; no merge, no store row. The directory is
    /// created on demand (the fixture root exists by lock-file grace).
    fn writeChannelFile(a: std.mem.Allocator, io: std.Io, folder: []const u8, stem: []const u8, root: std.json.Value) !void {
        const json_bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
        const dir_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ fixtures_root, folder });
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.FilesystemIoError,
        };
        const path = try channelPath(a, folder, stem);
        const tmp_path = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json_bytes }) catch return error.FilesystemIoError;
        std.Io.Dir.rename(std.Io.Dir.cwd(), tmp_path, std.Io.Dir.cwd(), path, io) catch return error.FilesystemIoError;
    }

    /// deep equality of two `outputs.identify` objects — the
    /// `--stale-by-output-drift` criterion. Order-independent structural
    /// comparison: the two channels are written by different workers, so
    /// key order is not meaningful.
    pub fn identifyEqual(x: std.json.Value, y: std.json.Value) bool {
        switch (x) {
            .null => return y == .null,
            .bool => |b| return y == .bool and y.bool == b,
            .integer => |i| return y == .integer and y.integer == i,
            .float => |f| return y == .float and y.float == f,
            .number_string => |s| return y == .number_string and std.mem.eql(u8, y.number_string, s),
            .string => |s| return y == .string and std.mem.eql(u8, y.string, s),
            .array => |arr| {
                if (y != .array or y.array.items.len != arr.items.len) return false;
                for (arr.items, y.array.items) |xi, yi| {
                    if (!identifyEqual(xi, yi)) return false;
                }
                return true;
            },
            .object => |obj| {
                if (y != .object or y.object.count() != obj.count()) return false;
                var it = obj.iterator();
                while (it.next()) |kv| {
                    const yv = y.object.get(kv.key_ptr.*) orelse return false;
                    if (!identifyEqual(kv.value_ptr.*, yv)) return false;
                }
                return true;
            },
        }
    }

    /// the feasibility grids — the reference CSVs become load-bearing:
    /// `.harnesses_providers.csv` (harness → provider cells) and
    /// `.providers_models.csv` (provider → model-id cells). A pair is
    /// feasible iff its cell is present and not `-`; feasible-unfixtured
    /// combos are the from-identity backlog universe (impossible combos
    /// never become candidates). A missing file loads as the empty set.
    pub const FeasibilityGrids = struct {
        harness_provider: std.StringHashMap(void),
        provider_model: std.StringHashMap(void),

        pub fn empty(a: std.mem.Allocator) FeasibilityGrids {
            return .{
                .harness_provider = std.StringHashMap(void).init(a),
                .provider_model = std.StringHashMap(void).init(a),
            };
        }

        pub fn putHarnessProvider(self: *FeasibilityGrids, a: std.mem.Allocator, h: []const u8, p: []const u8) !void {
            try self.harness_provider.put(try std.fmt.allocPrint(a, "{s}|{s}", .{ h, p }), {});
        }

        pub fn putProviderModel(self: *FeasibilityGrids, a: std.mem.Allocator, p: []const u8, m: []const u8) !void {
            try self.provider_model.put(try std.fmt.allocPrint(a, "{s}|{s}", .{ p, m }), {});
        }

        pub fn hpHas(self: *const FeasibilityGrids, h: []const u8, p: []const u8) bool {
            var buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ h, p }) catch return false;
            return self.harness_provider.contains(key);
        }

        pub fn pmHas(self: *const FeasibilityGrids, p: []const u8, m: []const u8) bool {
            var buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ p, m }) catch return false;
            return self.provider_model.contains(key);
        }

        /// load both reference grids. Header row = column dims; each data
        /// row's first cell = the row dim; a non-`-` cell marks the pair
        /// feasible (the cell value itself is the provider's spelling of
        /// the model-id — not read here).
        pub fn load(io: std.Io, a: std.mem.Allocator) !FeasibilityGrids {
            var self = empty(a);
            try loadPairGrid(io, a, "fixtures/.harnesses_providers.csv", &self.harness_provider);
            try loadPairGrid(io, a, "fixtures/.providers_models.csv", &self.provider_model);
            return self;
        }
    };

    /// the shared pair-grid reader (row-dim|col-dim keys for every
    /// non-`-` cell).
    fn loadPairGrid(io: std.Io, a: std.mem.Allocator, path: []const u8, set: *std.StringHashMap(void)) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(1 << 22)) catch return;
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        const header = lines.next() orelse return;
        var cols: std.ArrayList([]const u8) = .empty;
        var hc = std.mem.tokenizeScalar(u8, header, ',');
        _ = hc.next(); // the row-dim label cell
        while (hc.next()) |c| try cols.append(a, std.mem.trim(u8, c, " \r\t"));
        while (lines.next()) |line| {
            var cells = std.mem.tokenizeScalar(u8, line, ',');
            const row_dim = std.mem.trim(u8, cells.next() orelse continue, " \r\t");
            var idx: usize = 0;
            while (cells.next()) |cell| : (idx += 1) {
                if (idx >= cols.items.len) break;
                const v = std.mem.trim(u8, cell, " \r\t");
                if (v.len == 0 or std.mem.eql(u8, v, "-")) continue;
                try set.put(try std.fmt.allocPrint(a, "{s}|{s}", .{ row_dim, cols.items[idx] }), {});
            }
        }
    }

    // ------------------------------------------------------------------
    // backlog (actionable gaps) + known_but_failed (failure memory)
    // ------------------------------------------------------------------

    /// the backlog sets, in store order. The three unknown_* sets hold
    /// unique dim slugs from unresolvable stems; `needs_curation` holds
    /// fixture ids of fixtured from-capture files whose meta lacks
    /// prompt_launch. Never null/empty strings; a stem that can't split
    /// 4-way attributes no dim and lands in no set (the envelope test
    /// flags the file).
    const backlog_sets = [_][]const u8{ "unknown_harnesses", "unknown_providers", "unknown_models", "needs_curation" };

    fn strLess(_: void, x: []const u8, y: []const u8) bool {
        return std.mem.lessThan(u8, x, y);
    }

    /// the stored items of one backlog set (strings, as stored). Caller
    /// owns the returned slice (`a.free` it).
    pub fn backlogItems(a: std.mem.Allocator, root: *const std.json.Value, set: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (root.* != .object) return out.toOwnedSlice(a);
        const bl = root.object.get("backlog") orelse return out.toOwnedSlice(a);
        if (bl != .object) return out.toOwnedSlice(a);
        const arr = bl.object.get(set) orelse return out.toOwnedSlice(a);
        if (arr != .array) return out.toOwnedSlice(a);
        for (arr.array.items) |item| {
            if (item == .string) try out.append(a, item.string);
        }
        return out.toOwnedSlice(a);
    }

    /// idempotent union of `items` into backlog set `set` (sorted, unique).
    pub fn backlogUnionPure(a: std.mem.Allocator, root: *std.json.Value, set: []const u8, items: []const []const u8) !void {
        const bl = try getOrPutObject(a, root, "backlog");
        var merged: std.ArrayList([]const u8) = .empty;
        if (bl.getPtr(set)) |arr_v| {
            if (arr_v.* == .array) {
                for (arr_v.array.items) |item| {
                    if (item == .string) try merged.append(a, item.string);
                }
            }
        }
        outer: for (items) |item| {
            for (merged.items) |m| {
                if (std.mem.eql(u8, m, item)) continue :outer;
            }
            try merged.append(a, item);
        }
        std.mem.sort([]const u8, merged.items, {}, strLess);
        var arr: std.json.Array = std.json.Array.init(a);
        for (merged.items) |m| try arr.append(.{ .string = m });
        try bl.put(a, set, .{ .array = arr });
    }

    /// remove one item from a backlog set (no-op when absent). Mutates
    /// through `getPtr` — a by-value copy would dangle (see zig.md).
    pub fn backlogRemovePure(root: *std.json.Value, set: []const u8, item: []const u8) void {
        if (root.* != .object) return;
        const bl = root.object.getPtr("backlog") orelse return;
        if (bl.* != .object) return;
        const arr_v = bl.object.getPtr(set) orelse return;
        if (arr_v.* != .array) return;
        var kept: std.json.Array = std.json.Array.init(std.heap.page_allocator);
        for (arr_v.array.items) |entry| {
            if (entry == .string and std.mem.eql(u8, entry.string, item)) continue;
            kept.append(entry) catch return;
        }
        arr_v.* = .{ .array = kept };
    }

    /// the longest message a `known_but_failed` entry stores.
    const KNOWN_BUT_FAILED_MAX = 400;

    /// put (or overwrite — last failure wins) a `known_but_failed`
    /// message for a fixture id. The message is home-path redacted,
    /// key-shaped strings elided, and truncated before it touches the
    /// committed store. Informational only — pops never gate on it.
    pub fn knownButFailedPutPure(a: std.mem.Allocator, root: *std.json.Value, fixture_id: []const u8, message: []const u8, home: []const u8) !void {
        const kb = try getOrPutObject(a, root, "known_but_failed");
        try kb.put(a, fixture_id, .{ .string = try redactMessage(a, message, home) });
    }

    /// remove a `known_but_failed` entry (any channel of the combo
    /// succeeded — the fixture file is the success memory).
    pub fn knownButFailedClearPure(root: *std.json.Value, fixture_id: []const u8) void {
        if (root.* != .object) return;
        const kb = root.object.getPtr("known_but_failed") orelse return;
        if (kb.* != .object) return;
        _ = kb.object.swapRemove(fixture_id);
    }

    /// the failure message for a fixture id, or null.
    pub fn knownButFailedFor(root: *const std.json.Value, fixture_id: []const u8) ?[]const u8 {
        if (root.* != .object) return null;
        const kb = root.object.get("known_but_failed") orelse return null;
        if (kb != .object) return null;
        const v = kb.object.get(fixture_id) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    fn isTokenChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
    }

    /// redact home paths + key-shaped strings and truncate to
    /// `KNOWN_BUT_FAILED_MAX` chars.
    fn redactMessage(a: std.mem.Allocator, message: []const u8, home: []const u8) ![]u8 {
        const red = try redactHome(a, message, home);
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < red.len) {
            if (std.mem.startsWith(u8, red[i..], "sk-") and
                i + 3 < red.len and isTokenChar(red[i + 3]) and
                (i == 0 or !isTokenChar(red[i - 1])))
            {
                try out.appendSlice(a, "<redacted>");
                i += 3;
                while (i < red.len and isTokenChar(red[i])) i += 1;
            } else if (std.mem.startsWith(u8, red[i..], "Bearer ")) {
                try out.appendSlice(a, "Bearer <redacted>");
                i += 7;
                while (i < red.len and isTokenChar(red[i])) i += 1;
            } else {
                try out.append(a, red[i]);
                i += 1;
            }
        }
        if (out.items.len > KNOWN_BUT_FAILED_MAX) {
            return std.fmt.allocPrint(a, "{s}…", .{out.items[0..KNOWN_BUT_FAILED_MAX]});
        }
        return out.toOwnedSlice(a);
    }

    /// scan one channel folder for fixture-file stems (dot-files skipped —
    /// the grids, store, and log coexist at the fixture root; subfolders
    /// are scanned only as their own universes).
    pub fn scanFolderStems(io: std.Io, a: std.mem.Allocator, folder: []const u8) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const dir_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ fixtures_root, folder });
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out.toOwnedSlice(a);
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |ent| {
            if (ent.kind != .file) continue;
            const name = ent.name;
            if (name.len <= ".json".len or !std.mem.endsWith(u8, name, ".json")) continue;
            const stem = name[0 .. name.len - ".json".len];
            if (stem.len == 0 or stem[0] == '.') continue;
            // dupe: `ent.name` is only valid until the next iteration
            try out.append(a, try a.dupe(u8, stem));
        }
        return out.toOwnedSlice(a);
    }

    /// refresh the backlog table from a full folder scan: union in the
    /// gaps the scan finds, remove the items that have resolved (a dim
    /// now covered by a rule; a from-capture file that now carries
    /// prompt_launch). Idempotent; called under the store lock by the
    /// daemon's pick and `fixtures status`.
    pub fn refreshBacklogPure(io: std.Io, a: std.mem.Allocator, root: *std.json.Value) !void {
        var unk_h: std.ArrayList([]const u8) = .empty;
        var unk_p: std.ArrayList([]const u8) = .empty;
        var unk_m: std.ArrayList([]const u8) = .empty;
        var needs_cur: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ IDENTITY_DIR, CAPTURE_DIR }) |folder| {
            const stems = try scanFolderStems(io, a, folder);
            for (stems) |stem| {
                const parts = splitFixtureId(a, stem) catch continue; // malformed stems flag in the envelope test
                const h_ok = canonicalIdFor(a, HarnessRule, &rulesForHarnesses, parts[0]) != null;
                const p_ok = canonicalIdFor(a, ProviderRule, &rulesForProviders, parts[1]) != null;
                const m_ok = canonicalIdFor(a, ModelRule, &rulesForModels, parts[2]) != null;
                if (!h_ok) try unk_h.append(a, parts[0]);
                if (!p_ok) try unk_p.append(a, parts[1]);
                if (!m_ok) try unk_m.append(a, parts[2]);
                if (std.mem.eql(u8, folder, CAPTURE_DIR)) {
                    const cf = try loadChannelFile(io, a, folder, stem);
                    if (cf.prompt_launch == null) try needs_cur.append(a, stem);
                }
            }
        }
        try backlogUnionPure(a, root, "unknown_harnesses", unk_h.items);
        try backlogUnionPure(a, root, "unknown_providers", unk_p.items);
        try backlogUnionPure(a, root, "unknown_models", unk_m.items);
        try backlogUnionPure(a, root, "needs_curation", needs_cur.items);
        // removals — an item that resolves leaves the backlog.
        for (backlog_sets, 0..) |set, si| {
            const items = try backlogItems(a, root, set);
            for (items) |item| {
                const resolved = switch (si) {
                    0 => canonicalIdFor(a, HarnessRule, &rulesForHarnesses, item) != null,
                    1 => canonicalIdFor(a, ProviderRule, &rulesForProviders, item) != null,
                    2 => canonicalIdFor(a, ModelRule, &rulesForModels, item) != null,
                    else => blk: {
                        const cf = loadChannelFile(io, a, CAPTURE_DIR, item) catch break :blk false;
                        break :blk cf.prompt_launch != null;
                    },
                };
                if (resolved) backlogRemovePure(root, set, item);
            }
        }
    }

    // ------------------------------------------------------------------
    // queue entry (de)serialization + pure ops
    // ------------------------------------------------------------------

    /// serialize a queue entry. Null-as-absent: unset optional fields are
    /// omitted from the store (the reader treats missing as null), keeping
    /// the committed JSON free of `: null` bloat. Structure source of
    /// truth: `fixtures/.index.d.ts`.
    fn queueEntryValue(a: std.mem.Allocator, e: QueueEntry) !std.json.Value {
        var o: std.json.Value = .{ .object = .empty };
        if (e.harness) |v| try o.object.put(a, "harness", .{ .string = v });
        if (e.provider) |v| try o.object.put(a, "provider", .{ .string = v });
        if (e.model) |v| try o.object.put(a, "model", .{ .string = v });
        if (e.platform) |v| try o.object.put(a, "platform", .{ .string = v });
        try o.object.put(a, "mode", .{ .string = e.mode });
        if (e.stale_by_output_drift) try o.object.put(a, "stale_by_output_drift", .{ .bool = true });
        if (e.stale_by_minutes) |v| try o.object.put(a, "stale_by_minutes", .{ .integer = v });
        if (e.stale_by_harness_version) try o.object.put(a, "stale_by_harness_version", .{ .bool = true });
        if (e.stale_by_detect_version) try o.object.put(a, "stale_by_detect_version", .{ .bool = true });
        if (e.free) |v| try o.object.put(a, "free", .{ .bool = v });
        try o.object.put(a, "runner", .{ .integer = e.runner });
        if (e.started_at) |v| try o.object.put(a, "started_at", .{ .integer = v });
        return o;
    }

    fn queueEntryFromValue(v: std.json.Value) !QueueEntry {
        if (v != .object) return error.IndexStoreError;
        const o = v.object;
        return .{
            .harness = jstr(o, "harness"),
            .provider = jstr(o, "provider"),
            .model = jstr(o, "model"),
            .platform = jstr(o, "platform"),
            .mode = sjstr(o, "mode"),
            .stale_by_output_drift = jbool(o, "stale_by_output_drift") orelse false,
            .stale_by_minutes = jint(o, "stale_by_minutes"),
            .stale_by_harness_version = jbool(o, "stale_by_harness_version") orelse false,
            .stale_by_detect_version = jbool(o, "stale_by_detect_version") orelse false,
            .free = jbool(o, "free"),
            .runner = sjint(o, "runner"),
            .started_at = jint(o, "started_at"),
        };
    }

    /// the shared validator — single source of truth for valid queue
    /// entries. Called by BOTH the queue writer and the daemon reader.
    /// The mode is one of the two refresh flavours; a carried age
    /// threshold is ≥ 0 (0 = "older than now" — everything age-stale).
    pub fn validateQueueEntry(e: QueueEntry) !void {
        if (!std.mem.eql(u8, e.mode, "from-identity") and !std.mem.eql(u8, e.mode, "from-capture")) return error.InvalidQueueRow;
        if (e.stale_by_minutes) |mins| {
            if (mins < 0) return error.InvalidQueueRow;
        }
    }

    /// the dedupe tuple: dims + mode + the staleness criteria set + free
    /// (everything except `runner`/`started_at` — a re-assert must repeat
    /// the SAME flag set or it lands as a second, differently-defaulting
    /// entry).
    fn queueEntryTupleEqual(x: QueueEntry, y: QueueEntry) bool {
        return optStrEq(x.harness, y.harness) and
            optStrEq(x.provider, y.provider) and
            optStrEq(x.model, y.model) and
            optStrEq(x.platform, y.platform) and
            std.mem.eql(u8, x.mode, y.mode) and
            x.stale_by_output_drift == y.stale_by_output_drift and
            x.stale_by_minutes == y.stale_by_minutes and
            x.stale_by_harness_version == y.stale_by_harness_version and
            x.stale_by_detect_version == y.stale_by_detect_version and
            x.free == y.free;
    }

    /// upsert a queue entry: a re-assert of an existing tuple replaces
    /// the entry in place (fresh `started_at` = null — a fresh sweep);
    /// otherwise the entry is appended.
    pub fn queueUpsertPure(a: std.mem.Allocator, root: *std.json.Value, entry: QueueEntry) !void {
        const q = try getOrPutArray(a, root, "queue");
        const value = try queueEntryValue(a, entry);
        for (q.items, 0..) |item, i| {
            const existing = queueEntryFromValue(item) catch continue;
            if (queueEntryTupleEqual(entry, existing)) {
                q.items[i] = value;
                return;
            }
        }
        try q.append(value);
    }

    /// stamp the staleness criteria for a queue upsert from the CLI
    /// flags (§ staleness defaulting):
    /// - `--refresh` → no criteria (every candidate worked);
    /// - `--stale` → the composite, with any explicit `--stale-*`
    ///   overwriting just that component;
    /// - explicit `--stale-*` alone → exactly those criteria;
    /// - nothing → the composite (the default; churn prevention).
    pub fn stampCriteria(f: FilterOptions) StaleCriteria {
        if (f.refresh) return .{};
        const minutes = staleMinutes(f);
        if (f.stale) {
            return .{
                .output_drift = true,
                .minutes = minutes orelse StaleCriteria.composite.minutes,
                .harness_version = true,
                .detect_version = true,
            };
        }
        const explicit = StaleCriteria{
            .output_drift = f.stale_by_output_drift,
            .minutes = minutes,
            .harness_version = f.stale_by_harness_version,
            .detect_version = f.stale_by_detect_version,
        };
        if (!explicit.isNone()) return explicit;
        return StaleCriteria.composite;
    }

    /// does a stored queue entry match the dequeue filter? Dims/mode
    /// constrain to equality when set; the staleness criteria must equal
    /// the filter's stamped criteria (a bare dequeue filter matches
    /// exactly the entry a bare upsert created; `--refresh` matches
    /// criteria-less entries); `free` matches when set.
    pub fn dequeueMatches(f: FilterOptions, e: QueueEntry) bool {
        if (f.harness.len > 0 and !optStrEq(e.harness, f.harness)) return false;
        if (f.provider.len > 0 and !optStrEq(e.provider, f.provider)) return false;
        if (f.model.len > 0 and !optStrEq(e.model, f.model)) return false;
        if (f.platform.len > 0 and !optStrEq(e.platform, f.platform)) return false;
        if (f.mode.len > 0 and !std.mem.eql(u8, e.mode, f.mode)) return false;
        const exp = stampCriteria(f);
        if (e.stale_by_output_drift != exp.output_drift) return false;
        if ((e.stale_by_minutes == null) != (exp.minutes == null)) return false;
        if (e.stale_by_minutes != null and e.stale_by_minutes.? != exp.minutes.?) return false;
        if (e.stale_by_harness_version != exp.harness_version) return false;
        if (e.stale_by_detect_version != exp.detect_version) return false;
        if (f.free != null and e.free != f.free) return false;
        return true;
    }

    // ------------------------------------------------------------------
    // store I/O wrappers (lock → reload → mutate → atomic save → unlock)
    // ------------------------------------------------------------------

    /// upsert a queue entry under the store lock.
    fn upsertQueueEntry(io: std.Io, a: std.mem.Allocator, entry: QueueEntry) !void {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try queueUpsertPure(a, &root, entry);
        try indexSave(io, a, root);
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
            const entry = queueEntryFromValue(q.items[i]) catch continue;
            if (!dequeueMatches(f, entry)) continue;
            _ = q.orderedRemove(i);
            deleted += 1;
        }
        try indexSave(io, a, root);
        return deleted;
    }

    /// record a `known_but_failed` message under the store lock (the
    /// workers' failure memory; informational only).
    fn recordKnownButFailed(io: std.Io, a: std.mem.Allocator, fixture_id: []const u8, message: []const u8, env: *const std.process.Environ.Map) !void {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try knownButFailedPutPure(a, &root, fixture_id, message, reporterHome(env));
        try indexSave(io, a, root);
    }

    /// clear a `known_but_failed` entry under the store lock (a channel
    /// of the combo succeeded). No-op when absent.
    fn clearKnownButFailed(io: std.Io, a: std.mem.Allocator, fixture_id: []const u8) !void {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        if (knownButFailedFor(&root, fixture_id) == null) return;
        knownButFailedClearPure(&root, fixture_id);
        try indexSave(io, a, root);
    }

    /// union a fixture id into a backlog set under the store lock.
    fn markBacklog(io: std.Io, a: std.mem.Allocator, set: []const u8, item: []const u8) !void {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try backlogUnionPure(a, &root, set, &.{item});
        try indexSave(io, a, root);
    }

    // ------------------------------------------------------------------
    // the pop protocol — expansion (only the daemon expands)
    // ------------------------------------------------------------------

    fn candidateLess(_: void, x: Candidate, y: Candidate) bool {
        return std.mem.lessThan(u8, x.fixture_id, y.fixture_id);
    }

    /// expand one queue entry into its remaining candidate set. The
    /// universe is one — resolvable dims ∧ (fixtured ∨ feasible-unfixtured
    /// per the reference grids; from-identity only — a from-capture
    /// candidate must carry meta.prompt_launch) — filtered by the entry's
    /// dims, platform, staleness criteria, and the free flag. A candidate
    /// is DONE when the mode's success `meta.updated_at` is present AND
    /// ≥ the entry's `started_at` (a never-worked entry has no done
    /// candidates); candidates this daemon session already failed are
    /// damped out. Absent evidence ⇒ every carried criterion says stale.
    pub fn expandEntry(io: std.Io, a: std.mem.Allocator, free: *const FreeGrid, grids: *const FeasibilityGrids, entry: QueueEntry, host: []const u8, damped: ?*const std.StringHashMap(void)) !ExpandResult {
        const platforms: []const []const u8 = if (entry.platform) |p| &.{p} else &platforms_all;
        var host_list: std.ArrayListUnmanaged(Candidate) = .empty;
        var remaining: usize = 0;
        for (platforms) |plat| {
            const list = try expandForPlatform(io, a, free, grids, entry, plat, damped);
            remaining += list.len;
            if (std.mem.eql(u8, plat, host)) {
                for (list) |c| try host_list.append(a, c);
            }
        }
        std.mem.sort(Candidate, host_list.items, {}, candidateLess);
        return .{ .host_candidates = try host_list.toOwnedSlice(a), .remaining_anywhere = remaining };
    }

    fn expandForPlatform(io: std.Io, a: std.mem.Allocator, free: *const FreeGrid, grids: *const FeasibilityGrids, entry: QueueEntry, plat: []const u8, damped: ?*const std.StringHashMap(void)) ![]Candidate {
        const folder = modeFolder(entry.mode) orelse return &.{};
        var out: std.ArrayListUnmanaged(Candidate) = .empty;
        var fixtured: std.StringHashMap(void) = .init(a);
        const stems = try scanFolderStems(io, a, folder);
        for (stems) |stem| try fixtured.put(stem, {});
        // fixtured universe — the folder's files (capture candidates must
        // carry meta.prompt_launch; argv-less files are backlog
        // needs_curation, never candidates).
        for (stems) |stem| {
            const parts = splitFixtureId(a, stem) catch continue; // unresolvable stems land in the backlog, never expand
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
            if (!dimsResolvable(a, parts)) continue;
            if (entry.free) |fr| {
                if (fr != free.has(parts[1], parts[2])) continue;
            }
            const cf = try loadChannelFile(io, a, folder, stem);
            if (std.mem.eql(u8, folder, CAPTURE_DIR) and cf.prompt_launch == null) continue;
            if (damped) |dm| {
                if (dm.contains(stem)) continue;
            }
            if (!(try entryStale(io, a, entry, cf))) continue;
            // completion-timestamp done rule (only once the entry started)
            if (entry.started_at) |started| {
                if (cf.updated_at) |t| {
                    if (t >= started) continue;
                }
            }
            try out.append(a, .{ .fixture_id = stem, .harness = parts[0], .provider = parts[1], .model = parts[2], .platform = parts[3] });
        }
        // feasible-unfixtured universe — from-identity only: the
        // grid-filtered cross-product minus the fixtured stems, so
        // impossible combos never become candidates and from-identity can
        // never mint them. (From-capture candidates without a file have
        // no prompt_launch — they are curation work, not capture work.)
        if (std.mem.eql(u8, entry.mode, "from-identity")) {
            var hit = grids.harness_provider.keyIterator();
            while (hit.next()) |hk| {
                const hp = hk.*;
                const bar = std.mem.indexOfScalar(u8, hp, '|') orelse continue;
                const h = hp[0..bar];
                const p = hp[bar + 1 ..];
                if (entry.harness) |v| {
                    if (!std.mem.eql(u8, h, v)) continue;
                }
                if (entry.provider) |v| {
                    if (!std.mem.eql(u8, p, v)) continue;
                }
                var mit = grids.provider_model.keyIterator();
                while (mit.next()) |mk| {
                    const pm = mk.*;
                    const bar2 = std.mem.indexOfScalar(u8, pm, '|') orelse continue;
                    const p2 = pm[0..bar2];
                    const m = pm[bar2 + 1 ..];
                    if (!std.mem.eql(u8, p2, p)) continue;
                    if (entry.model) |v| {
                        if (!std.mem.eql(u8, m, v)) continue;
                    }
                    const stem = (try fixtureIdFrom(a, h, p, m, plat)) orelse continue;
                    if (fixtured.contains(stem)) continue;
                    if (!dimsResolvable(a, .{ h, p, m, plat })) continue;
                    if (entry.free) |fr| {
                        if (fr != free.has(p, m)) continue;
                    }
                    if (damped) |dm| {
                        if (dm.contains(stem)) continue;
                    }
                    // no file ⇒ absent evidence ⇒ any carried criterion
                    // (and a criteria-less --refresh entry) says stale.
                    try out.append(a, .{ .fixture_id = stem, .harness = h, .provider = p, .model = m, .platform = plat });
                }
            }
        }
        std.mem.sort(Candidate, out.items, {}, candidateLess);
        return out.toOwnedSlice(a);
    }

    /// do the three dims of a split fixture id resolve against the
    /// current rule tables? Unresolvable stems are backlog, not candidates.
    fn dimsResolvable(a: std.mem.Allocator, parts: [4][]const u8) bool {
        return canonicalIdFor(a, HarnessRule, &rulesForHarnesses, parts[0]) != null and
            canonicalIdFor(a, ProviderRule, &rulesForProviders, parts[1]) != null and
            canonicalIdFor(a, ModelRule, &rulesForModels, parts[2]) != null;
    }

    /// evaluate the entry's carried criteria for one candidate — true
    /// when ANY carried criterion says stale (work needed); all fresh ⇒
    /// false; no criteria carried (a `--refresh` entry) ⇒ true. Reads
    /// only local state (the channel files and — for
    /// `stale_by_harness_version` — a zero-token `version_launch` probe).
    fn entryStale(io: std.Io, a: std.mem.Allocator, entry: QueueEntry, cf: ?ChannelFile) !bool {
        const carried = entry.stale_by_output_drift or entry.stale_by_minutes != null or
            entry.stale_by_harness_version or entry.stale_by_detect_version;
        if (!carried) return true; // --refresh: everything is worked
        const file = cf orelse return true; // absent evidence ⇒ stale
        if (entry.stale_by_output_drift) {
            // stale iff the two channel files' outputs.identify are not
            // both present and deep-equal (a missing channel counts stale).
            var drift = true;
            if (file.identify != null) {
                const other_folder: []const u8 = if (std.mem.eql(u8, entry.mode, "from-identity")) CAPTURE_DIR else IDENTITY_DIR;
                const other = try loadChannelFile(io, a, other_folder, file.stem);
                if (other.identify != null and identifyEqual(file.identify.?, other.identify.?)) drift = false;
            }
            if (drift) return true;
        }
        if (entry.stale_by_minutes) |mins| {
            const ts = file.updated_at orelse return true;
            if (isStale(io, ts, mins)) return true;
        }
        if (entry.stale_by_harness_version) {
            var fresh = false;
            if (file.harness_version) |stored| {
                if (file.version_launch) |vl| {
                    if (launchVersion(io, a, vl)) |live| {
                        if (std.mem.eql(u8, live, stored)) fresh = true;
                    }
                }
            }
            if (!fresh) return true;
        }
        if (entry.stale_by_detect_version) {
            const v = file.agent_detect_version orelse return true;
            if (!std.mem.eql(u8, v, build_options.version)) return true;
        }
        return false;
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
    /// unconstrained unless `--platform=` is also given. The staleness
    /// family stamps the entry's criteria set (`--stale` composite with
    /// component overwrite, explicit `--stale-*` alone, `--refresh` =
    /// none); `--free`/`--paid` are a nullable affirmative boolean;
    /// `any` is true iff at least one option was present.
    pub const FilterOptions = struct {
        harness: []const u8 = "",
        provider: []const u8 = "",
        model: []const u8 = "",
        platform: []const u8 = "",
        fixture: ?[]const u8 = null,
        agent: ?[]const u8 = null,
        /// staleness — `--stale` and the `--stale-*` family, plus
        /// `--refresh` (conflicts with both; validateFilters).
        stale: bool = false,
        stale_by_output_drift: bool = false,
        /// age thresholds. Each is the same criterion at a different
        /// unit; at most one may be set. The queued entry always stores
        /// the age in MINUTES in `stale_by_minutes` (days/hours convert
        /// at stamp time).
        stale_by_days: ?i64 = null,
        stale_by_hours: ?i64 = null,
        stale_by_minutes: ?i64 = null,
        stale_by_harness_version: bool = false,
        stale_by_detect_version: bool = false,
        refresh: bool = false,
        /// (queue only) pop the backlog and re-queue actionable items;
        /// dequeue rejects it (conflict, exit 3).
        repair: bool = false,
        /// free axis: `--free` → true, `--paid` → false, unset → null.
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
        /// `--stale-by-days=`/`--stale-by-minutes=` not an integer ≥ 0
        InvalidThreshold,
        /// contradictory or disallowed combination
        ConflictingFilters,
        /// allocation failure while expanding composite ids
        OutOfMemory,
    };

    /// the shared filter validator — the conflict matrix:
    /// - at most one age threshold, each ≥ 0
    /// - `--refresh` conflicts with `--stale` and every `--stale-*`
    ///   (refresh already means "everything is stale"; OR-combining
    ///   explicit criteria would be a no-op)
    /// The `--free`/`--paid` XOR is enforced at parse time; the stored
    /// entry keeps a nullable boolean.
    pub fn validateFilters(f: FilterOptions) FilterError!void {
        const age_scopes = @as(usize, @intFromBool(f.stale_by_days != null)) +
            @as(usize, @intFromBool(f.stale_by_hours != null)) +
            @as(usize, @intFromBool(f.stale_by_minutes != null));
        if (age_scopes > 1) return FilterError.ConflictingFilters;
        if ((f.stale_by_days orelse 0) < 0 or
            (f.stale_by_hours orelse 0) < 0 or
            (f.stale_by_minutes orelse 0) < 0) return FilterError.ConflictingFilters;
        if (f.refresh and (f.stale or f.stale_by_output_drift or age_scopes > 0 or
            f.stale_by_harness_version or f.stale_by_detect_version)) return FilterError.ConflictingFilters;
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
            } else if (std.mem.eql(u8, arg, "--stale")) {
                f.stale = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-output-drift")) {
                f.stale_by_output_drift = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-harness-version")) {
                f.stale_by_harness_version = true;
            } else if (std.mem.eql(u8, arg, "--stale-by-detect-version")) {
                f.stale_by_detect_version = true;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-days=")) {
                f.stale_by_days = std.fmt.parseInt(i64, arg["--stale-by-days=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-hours=")) {
                f.stale_by_hours = std.fmt.parseInt(i64, arg["--stale-by-hours=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.startsWith(u8, arg, "--stale-by-minutes=")) {
                f.stale_by_minutes = std.fmt.parseInt(i64, arg["--stale-by-minutes=".len..], 10) catch return FilterError.InvalidThreshold;
            } else if (std.mem.eql(u8, arg, "--refresh")) {
                f.refresh = true;
            } else if (std.mem.eql(u8, arg, "--repair")) {
                f.repair = true;
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
            // dupe: `parts` are freed on return; the filter outlives it
            f.harness = a.dupe(u8, parts[0]) catch return FilterError.OutOfMemory;
            f.provider = a.dupe(u8, parts[1]) catch return FilterError.OutOfMemory;
            f.model = a.dupe(u8, parts[2]) catch return FilterError.OutOfMemory;
            f.composite = true;
        }

        // canonicalize the h/p/m filter dims to the store's slug-id form
        // when they resolve to a known rule (the store dims use
        // `slugId(canonicalName)` — e.g. `kimicode`, never
        // `kimi-code`), so label forms (`Kilo Code`), canonical
        // spellings (`kimi-code`), slug forms (`kimicode`), and case
        // variants (`KILO`) all match the same rows. Unknown dims pass
        // through raw — the repair path intentionally allows unknown ids.
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

        const staleness_count = @as(usize, @intFromBool(f.stale)) +
            @as(usize, @intFromBool(f.stale_by_output_drift)) +
            @as(usize, @intFromBool(f.stale_by_days != null)) +
            @as(usize, @intFromBool(f.stale_by_hours != null)) +
            @as(usize, @intFromBool(f.stale_by_minutes != null)) +
            @as(usize, @intFromBool(f.stale_by_harness_version)) +
            @as(usize, @intFromBool(f.stale_by_detect_version)) +
            @as(usize, @intFromBool(f.refresh)) +
            @as(usize, @intFromBool(f.repair));
        const axis_count = @as(usize, @intFromBool(f.free != null));

        f.any = seen_fixture or seen_agent or seen_harness or seen_provider or
            seen_model or seen_platform or staleness_count > 0 or axis_count > 0;
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
    /// `fixtures/from-capture/<id>.json` (the whole `{ outputs, meta }`
    /// envelope, written atomically; the writer owns the file). Failure
    /// semantics: if the detection ladder fails to resolve harness *or*
    /// provider *or* model, exit 8 with no file written (partial
    /// detection is bad data per DESIGN). The daemon spawns this via the
    /// file's `meta.prompt_launch` argv inside a live model session; a
    /// hand-run capture is a real session too.
    ///
    /// **Filename contract** — the fixture is written as a single
    /// `fixtures/from-capture/<fixture_id>.json`, where
    /// `fixture_id = agent_id + "-" + platform_id` (e.g.
    /// `cline-clinepass-kimik3-darwin`). The `-<platform>` suffix keeps
    /// per-platform config paths from churning each other across CI
    /// runs; see DESIGN.md "per-platform fixtures" for the rationale.
    ///
    /// **Writer rule for `meta`** — the curation of record persists: any
    /// `meta.prompt_launch` / `meta.version_launch` in the file being
    /// replaced is carried over untouched, and `updated_at` /
    /// `agent_detect_version` / `harness_version` are stamped fresh. A
    /// capture with no curated argv writes `meta` without the launch
    /// fields (the combo then sits in backlog needs_curation).
    pub fn runFixturesCapture(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        var d = Detection{};
        _ = try detect(init, &d);

        const resolved = (if (d.harness_id != null) @as(usize, 1) else 0) +
            (if (d.provider_id != null) @as(usize, 1) else 0) +
            (if (d.model_id != null) @as(usize, 1) else 0);

        // partial detection (1 or 2 dims): partial is bad data per DESIGN —
        // report + exit 8, NO file written. Nothing is written if zero
        // dims resolve.
        if (resolved >= 1 and resolved < 3) {
            writeErr(io, "fixtures capture: partial detection (");
            writeErrCount(io, resolved);
            writeErr(io, "/3 dims) — no fixture written\n");
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

        // from-capture outputs: identify from the live detection, both
        // trailer variants from spawning the current binary's `trailer`
        // action in the session env (bare — session-env detection).
        const cooked = try buildCooked(a, &d);
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_path = selfPath(io, &self_path_buf);
        const co = if (self_path) |sp| try spawnTrailerLine(a, io, sp, "co-author", "", "", "") else null;
        const ab = if (self_path) |sp| try spawnTrailerLine(a, io, sp, "assisted-by", "", "", "") else null;

        // live harness version snapshot via the file's curated
        // `version_launch` (absent ⇒ "not yet knowable" — the raw block
        // carries the null too).
        const existing = try loadChannelFile(io, a, CAPTURE_DIR, fixture_id);
        const hver: ?[]const u8 = if (existing.version_launch) |vl| launchVersion(io, a, vl) else null;

        const raw = try buildRaw(a, &d, init.environ_map, hver, true);

        var outputs: std.json.Value = .{ .object = .empty };
        try outputs.object.put(a, "identify", cooked);
        try outputs.object.put(a, "trailer co-author", optStringValue(a, co));
        try outputs.object.put(a, "trailer assisted-by", optStringValue(a, ab));
        try outputs.object.put(a, "raw", raw);

        // meta — the curation of record persists; the ledger stamps fresh.
        var meta: std.json.Value = .{ .object = .empty };
        try meta.object.put(a, "updated_at", .{ .integer = unixNow(io) });
        try meta.object.put(a, "agent_detect_version", .{ .string = build_options.version });
        if (hver) |v| try meta.object.put(a, "harness_version", .{ .string = v });
        if (existing.prompt_launch) |pl| try meta.object.put(a, "prompt_launch", stringListValue(a, pl));
        if (existing.version_launch) |vl| try meta.object.put(a, "version_launch", stringListValue(a, vl));

        var root: std.json.Value = .{ .object = .empty };
        try root.object.put(a, "outputs", outputs);
        try root.object.put(a, "meta", meta);
        try writeChannelFile(a, io, CAPTURE_DIR, fixture_id, root);

        // success memory: any channel of this combo succeeding clears
        // its known_but_failed entry.
        try clearKnownButFailed(io, a, fixture_id);

        writeOut(io, "fixtures capture: wrote fixtures/from-capture/");
        writeOut(io, fixture_id);
        writeOut(io, ".json\n");
        return 0;
    }

    /// `fixtures queue [staleness] [filters] [mode]` — upsert queue
    /// entries (pure enqueue; no evaluation — the daemon expands). One
    /// entry per selected mode carries the dims and the stamped
    /// staleness criteria verbatim; at least one filter/staleness flag
    /// is required (else exit 4). Idempotent per (dims, mode, criteria,
    /// free) tuple: a re-assert replaces the entry in place and resets
    /// `started_at` (a fresh sweep). `--repair` replaces the upsert with
    /// the backlog-pop flow (runRepair).
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
                error.InvalidThreshold => writeErr(io, "fixtures queue: --stale-by-days=/--stale-by-hours=/--stale-by-minutes= must be integers >= 0\n"),
                error.ConflictingFilters => writeErr(io, MSG_CONFLICTING_ARG),
                error.OutOfMemory => writeErr(io, MSG_OUT_OF_MEMORY),
            }
            writeOut(io, queueUsage);
            return if (err == error.NoFilter) EXIT_MISSING_ARG else if (err == error.ConflictingFilters) EXIT_CONFLICTING_ARG else if (err == error.OutOfMemory) EXIT_OUT_OF_MEMORY else EXIT_UNRECOGNISED_ARG;
        };

        if (f.repair) return runRepair(init, f);

        const crit = stampCriteria(f);
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
                .stale_by_output_drift = crit.output_drift,
                .stale_by_minutes = crit.minutes,
                .stale_by_harness_version = crit.harness_version,
                .stale_by_detect_version = crit.detect_version,
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

    /// `fixtures dequeue [staleness] [filters] [mode]` — **DELETE only;
    /// pure entry filters.** Matches stored entries by dims + the
    /// stamped staleness criteria + optional mode and deletes them. No
    /// evaluation, no fixture mutation. At least one filter/staleness
    /// flag is required.
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
                error.InvalidThreshold => writeErr(io, "fixtures dequeue: --stale-by-days=/--stale-by-hours=/--stale-by-minutes= must be integers >= 0\n"),
                error.ConflictingFilters => writeErr(io, MSG_CONFLICTING_ARG),
                error.OutOfMemory => writeErr(io, MSG_OUT_OF_MEMORY),
            }
            writeOut(io, dequeueUsage);
            return if (err == error.NoFilter) EXIT_MISSING_ARG else if (err == error.ConflictingFilters) EXIT_CONFLICTING_ARG else if (err == error.OutOfMemory) EXIT_OUT_OF_MEMORY else EXIT_UNRECOGNISED_ARG;
        };

        if (f.repair) {
            writeErr(io, "fixtures dequeue: --repair applies to fixtures queue only\n");
            writeOut(io, dequeueUsage);
            return EXIT_CONFLICTING_ARG;
        }

        const deleted = try deleteQueueEntries(io, a, f);

        writeOut(io, "fixtures dequeue: deleted ");
        writeCount(io, deleted);
        writeOut(io, " entry/entries\n");
        return 0;
    }

    /// the `--repair` flow (on `fixtures queue`): pop the backlog,
    /// re-evaluate each item against the CURRENT binary's rule tables and
    /// grids, and re-queue the now-actionable items:
    /// - an unknown_harnesses/providers/models item now resolvable →
    ///   removed from the backlog; one from-identity queue entry per item
    ///   filtered on that dim (one entry covers all of the item's combos);
    /// - a needs_curation item whose from-capture file NOW carries
    ///   meta.prompt_launch → removed; a `--fixture=<id>` from-capture
    ///   entry upserted;
    /// - the unfixtured (derived from grids − fixtured, never a stored
    ///   list) → one from-identity entry over the feasible universe,
    ///   honoring the dims filters.
    /// Items still unresolvable / still argv-less stay in the backlog;
    /// repair logs them.
    fn runRepair(init: std.process.Init, f: FilterOptions) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try refreshBacklogPure(io, a, &root);

        const crit = stampCriteria(f);
        var queued: usize = 0;

        // unknown dims — one from-identity entry per now-resolvable item,
        // filtered on that dim.
        const dim_specs = [_]struct { set: []const u8, dim: usize }{
            .{ .set = "unknown_harnesses", .dim = 0 },
            .{ .set = "unknown_providers", .dim = 1 },
            .{ .set = "unknown_models", .dim = 2 },
        };
        const dim_flags = [_][]const u8{ "harness", "provider", "model" };
        for (dim_specs) |spec| {
            const items = try backlogItems(a, &root, spec.set);
            for (items) |slug| {
                const resolvable = switch (spec.dim) {
                    0 => canonicalIdFor(a, HarnessRule, &rulesForHarnesses, slug) != null,
                    1 => canonicalIdFor(a, ProviderRule, &rulesForProviders, slug) != null,
                    else => canonicalIdFor(a, ModelRule, &rulesForModels, slug) != null,
                };
                if (!resolvable) {
                    daemonWriteErr(io, "repair: ");
                    daemonWriteErr(io, slug);
                    daemonWriteErr(io, " is still unresolvable — left in backlog ");
                    daemonWriteErr(io, spec.set);
                    daemonWriteErr(io, "\n");
                    continue;
                }
                backlogRemovePure(&root, spec.set, slug);
                var dims: [3]?[]const u8 = .{
                    if (f.harness.len > 0) f.harness else null,
                    if (f.provider.len > 0) f.provider else null,
                    if (f.model.len > 0) f.model else null,
                };
                dims[spec.dim] = slug;
                try queueUpsertPure(a, &root, .{
                    .harness = dims[0],
                    .provider = dims[1],
                    .model = dims[2],
                    .platform = if (f.platform.len > 0) f.platform else null,
                    .mode = "from-identity",
                    .stale_by_output_drift = crit.output_drift,
                    .stale_by_minutes = crit.minutes,
                    .stale_by_harness_version = crit.harness_version,
                    .stale_by_detect_version = crit.detect_version,
                    .free = f.free,
                    .runner = getParentPid(),
                });
                queued += 1;
                daemonWrite(io, "repair: ");
                daemonWrite(io, slug);
                daemonWrite(io, " is now resolvable — queued from-identity --");
                daemonWrite(io, dim_flags[spec.dim]);
                daemonWrite(io, "=");
                daemonWrite(io, slug);
                daemonWrite(io, "\n");
            }
        }

        // needs_curation — a from-capture file that now carries
        // meta.prompt_launch re-queues as a targeted from-capture entry.
        {
            const items = try backlogItems(a, &root, "needs_curation");
            for (items) |id| {
                const cf = try loadChannelFile(io, a, CAPTURE_DIR, id);
                if (cf.prompt_launch == null) {
                    daemonWriteErr(io, "repair: ");
                    daemonWriteErr(io, id);
                    daemonWriteErr(io, " still has no meta.prompt_launch — left in backlog needs_curation\n");
                    continue;
                }
                backlogRemovePure(&root, "needs_curation", id);
                try queueUpsertPure(a, &root, .{
                    .harness = if (cf.valid_stem) cf.harness else null,
                    .provider = if (cf.valid_stem) cf.provider else null,
                    .model = if (cf.valid_stem) cf.model else null,
                    .platform = if (cf.valid_stem) cf.platform else null,
                    .mode = "from-capture",
                    .stale_by_output_drift = crit.output_drift,
                    .stale_by_minutes = crit.minutes,
                    .stale_by_harness_version = crit.harness_version,
                    .stale_by_detect_version = crit.detect_version,
                    .free = f.free,
                    .runner = getParentPid(),
                });
                queued += 1;
                daemonWrite(io, "repair: ");
                daemonWrite(io, id);
                daemonWrite(io, " is now curated — queued from-capture --fixture=");
                daemonWrite(io, id);
                daemonWrite(io, "\n");
            }
        }

        // the unfixtured — never a stored list; one from-identity entry
        // over the feasible universe (the daemon's feasible-unfixtured
        // expansion derives the candidates), honoring the dims filters.
        try queueUpsertPure(a, &root, .{
            .harness = if (f.harness.len > 0) f.harness else null,
            .provider = if (f.provider.len > 0) f.provider else null,
            .model = if (f.model.len > 0) f.model else null,
            .platform = if (f.platform.len > 0) f.platform else null,
            .mode = "from-identity",
            .stale_by_output_drift = crit.output_drift,
            .stale_by_minutes = crit.minutes,
            .stale_by_harness_version = crit.harness_version,
            .stale_by_detect_version = crit.detect_version,
            .free = f.free,
            .runner = getParentPid(),
        });
        queued += 1;

        try indexSave(io, a, root);

        writeOut(io, "fixtures queue --repair: queued ");
        writeCount(io, queued);
        writeOut(io, " entry/entries\n");
        return 0;
    }

    /// `fixtures status` — the derived snapshot: fixtured counts per
    /// folder, the backlog sets (maintained: union-in the scan's gaps,
    /// remove resolved items), feasible-unfixtured totals, and the
    /// stale/fresh breakdown under the `--stale` composite. The dev
    /// agent's discernment surface — the log is the timeline, status is
    /// the now.
    pub fn runFixturesStatus(init: std.process.Init) !u8 {
        const a = init.arena.allocator();
        const io = init.io;

        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try refreshBacklogPure(io, a, &root);
        try indexSave(io, a, root);

        const id_stems = try scanFolderStems(io, a, IDENTITY_DIR);
        const cap_stems = try scanFolderStems(io, a, CAPTURE_DIR);
        const grids = try FeasibilityGrids.load(io, a);

        // feasible-unfixtured (from-identity): the grid-filtered
        // cross-product minus the fixtured identity stems, over all
        // platforms and on this host.
        var fixtured_ids: std.StringHashMap(void) = .init(a);
        for (id_stems) |stem| try fixtured_ids.put(stem, {});
        var feasible_unfixtured: usize = 0;
        var feasible_unfixtured_host: usize = 0;
        for (platforms_all) |plat| {
            var hit = grids.harness_provider.keyIterator();
            while (hit.next()) |hk| {
                const hp = hk.*;
                const bar = std.mem.indexOfScalar(u8, hp, '|') orelse continue;
                const h = hp[0..bar];
                const p = hp[bar + 1 ..];
                var mit = grids.provider_model.keyIterator();
                while (mit.next()) |mk| {
                    const pm = mk.*;
                    const bar2 = std.mem.indexOfScalar(u8, pm, '|') orelse continue;
                    if (!std.mem.eql(u8, pm[0..bar2], p)) continue;
                    const stem = (try fixtureIdFrom(a, h, p, pm[bar2 + 1 ..], plat)) orelse continue;
                    if (fixtured_ids.contains(stem)) continue;
                    if (!dimsResolvable(a, .{ h, p, pm[bar2 + 1 ..], plat })) continue;
                    feasible_unfixtured += 1;
                    if (std.mem.eql(u8, plat, platformId())) feasible_unfixtured_host += 1;
                }
            }
        }

        // stale/fresh breakdown under the `--stale` composite.
        const composite_entry: QueueEntry = .{
            .mode = "",
            .stale_by_output_drift = StaleCriteria.composite.output_drift,
            .stale_by_minutes = StaleCriteria.composite.minutes,
            .stale_by_harness_version = StaleCriteria.composite.harness_version,
            .stale_by_detect_version = StaleCriteria.composite.detect_version,
        };
        var stale_id: usize = 0;
        for (id_stems) |stem| {
            const cf = try loadChannelFile(io, a, IDENTITY_DIR, stem);
            var e = composite_entry;
            e.mode = "from-identity";
            if (try entryStale(io, a, e, cf)) stale_id += 1;
        }
        var stale_cap: usize = 0;
        for (cap_stems) |stem| {
            const cf = try loadChannelFile(io, a, CAPTURE_DIR, stem);
            var e = composite_entry;
            e.mode = "from-capture";
            if (try entryStale(io, a, e, cf)) stale_cap += 1;
        }

        writeOut(io, "fixtures status\n");
        writeOut(io, "  fixtured: from-identity ");
        writeCount(io, id_stems.len);
        writeOut(io, ", from-capture ");
        writeCount(io, cap_stems.len);
        writeOut(io, "\n");
        writeOut(io, "  backlog:\n");
        for (backlog_sets) |set| {
            const items = try backlogItems(a, &root, set);
            writeOut(io, "    ");
            writeOut(io, set);
            writeOut(io, " (");
            writeCount(io, items.len);
            writeOut(io, ")");
            if (items.len > 0) {
                writeOut(io, ": ");
                for (items, 0..) |item, i| {
                    if (i > 0) writeOut(io, ", ");
                    writeOut(io, item);
                }
            }
            writeOut(io, "\n");
        }
        {
            const failed = root.object.get("known_but_failed");
            var count: usize = 0;
            if (failed != null and failed.? == .object) count = failed.?.object.count();
            writeOut(io, "  known_but_failed (");
            writeCount(io, count);
            writeOut(io, ")\n");
        }
        writeOut(io, "  feasible-unfixtured (from-identity): ");
        writeCount(io, feasible_unfixtured);
        writeOut(io, " total, ");
        writeCount(io, feasible_unfixtured_host);
        writeOut(io, " on this platform\n");
        writeOut(io, "  staleness (--stale composite): from-identity ");
        writeCount(io, stale_id);
        writeOut(io, "/");
        writeCount(io, id_stems.len);
        writeOut(io, " stale, from-capture ");
        writeCount(io, stale_cap);
        writeOut(io, "/");
        writeCount(io, cap_stems.len);
        writeOut(io, " stale\n");
        return 0;
    }

    /// post-check for a captured fixture: parse the from-capture file,
    /// verify combo-match — `outputs.identify`'s harness/provider/model
    /// ids equal the queued dims. Returns false on any failure (the
    /// caller records known_but_failed; the committed file is left
    /// intact).
    fn postCheckComboFixture(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !bool {
        const f_id = (try fixtureIdFrom(a, h, p, m, plat)) orelse return false;
        const cf = try loadChannelFile(io, a, CAPTURE_DIR, f_id);
        const identify = cf.identify orelse {
            daemonWriteErr(io, "daemon: post-check: missing from-capture outputs.identify: ");
            daemonWriteErr(io, f_id);
            daemonWriteErr(io, "\n");
            return false;
        };
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
    /// `outputs.identify`'s dims match the queue entry. Declared fixtures
    /// carry no evidence, so no evidence check applies.
    fn postCheckDeclaredFixture(a: std.mem.Allocator, io: std.Io, h: []const u8, p: []const u8, m: []const u8, plat: []const u8) !bool {
        const f_id = (try fixtureIdFrom(a, h, p, m, plat)) orelse return false;
        const cf = try loadChannelFile(io, a, IDENTITY_DIR, f_id);
        const identify = cf.identify orelse return false;
        const cob = identify.object;
        return std.mem.eql(u8, sjstr(cob, "harness_id"), h) and
            std.mem.eql(u8, sjstr(cob, "provider_id"), p) and
            std.mem.eql(u8, sjstr(cob, "model_id"), m);
    }

    /// `from-identity` worker: resolve the combo via `resolveRecipe`
    /// (recipe-mode, no detection, zero tokens, no harness required),
    /// assemble the from-identity file (`outputs` = identify + both
    /// trailer variants; `meta` = updated_at + agent_detect_version),
    /// and write it whole (atomically). Declared, not observed.
    /// Failures land in known_but_failed and damp this daemon session;
    /// a success clears the combo's known_but_failed entry.
    fn runOneComboIdentity(a: std.mem.Allocator, io: std.Io, init: std.process.Init, damped: *std.StringHashMap(void), fixture_id: []const u8) !bool {
        const parts = try splitFixtureId(a, fixture_id);
        const h = parts[0];
        const p = parts[1];
        const m_d = parts[2];
        const plat = parts[3];
        var d = (try resolveRecipe(a, h, p, m_d)) orelse {
            daemonWriteErr(io, "daemon: from-identity: combo not in the rule tables — cannot declare a fixture\n");
            try recordKnownButFailed(io, a, fixture_id, "combo not in the rule tables — cannot declare a fixture", init.environ_map);
            damped.put(fixture_id, {}) catch {};
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

        var outputs: std.json.Value = .{ .object = .empty };
        try outputs.object.put(a, "identify", cooked);
        try outputs.object.put(a, "trailer co-author", optStringValue(a, co));
        try outputs.object.put(a, "trailer assisted-by", optStringValue(a, ab));
        var meta: std.json.Value = .{ .object = .empty };
        try meta.object.put(a, "updated_at", .{ .integer = unixNow(io) });
        try meta.object.put(a, "agent_detect_version", .{ .string = build_options.version });
        var root: std.json.Value = .{ .object = .empty };
        try root.object.put(a, "outputs", outputs);
        try root.object.put(a, "meta", meta);
        try writeChannelFile(a, io, IDENTITY_DIR, fixture_id, root);

        if (!(try postCheckDeclaredFixture(a, io, h, p, m_d, plat))) {
            daemonWriteErr(io, "daemon: from-identity: post-check failed — recording failure\n");
            try recordKnownButFailed(io, a, fixture_id, "post-check mismatch", init.environ_map);
            damped.put(fixture_id, {}) catch {};
            return false;
        }

        try clearKnownButFailed(io, a, fixture_id);
        return true;
    }

    /// `from-capture` worker: launch the real harness headlessly so it
    /// runs `fixtures capture` inside a live model session. The launch
    /// argv is the fixture file's curated `meta.prompt_launch`, read
    /// verbatim (no argv[0] substitution — the file names the concrete
    /// per-platform binary); availability is probed via the file's
    /// `meta.version_launch` (exit 0 ⇒ installed). Uses the REAL
    /// environment (real API keys/config are required); cwd stays the
    /// daemon's (the repo root) so the session writes
    /// `fixtures/from-capture/<id>.json` into the repo. A watchdog
    /// subprocess (`fixtures __timeout`) enforces
    /// `--capture-timeout-seconds` so a hung harness fails out instead of
    /// blocking the poll loop forever. Success = child exit 0 AND the
    /// post-check passing; failures land in known_but_failed (truncated +
    /// redacted) and damp this daemon session — retry via
    /// `fixtures queue --refresh`. A successful capture clears the
    /// combo's known_but_failed entry. Token-consuming — user-confirmed
    /// only.
    fn runOneComboCapture(a: std.mem.Allocator, io: std.Io, init: std.process.Init, damped: *std.StringHashMap(void), fixture_id: []const u8, timeout_seconds: u64) !bool {
        const parts = try splitFixtureId(a, fixture_id);
        const h = parts[0];
        const p = parts[1];
        const m_d = parts[2];
        const plat = parts[3];

        const cf = try loadChannelFile(io, a, CAPTURE_DIR, fixture_id);
        // launch-spec backstop guard: no prompt_launch → backlog
        // needs_curation, no capture. (Expansion normally excludes
        // argv-less files — this only fires on a race.)
        const launch = cf.prompt_launch orelse {
            daemonWriteErr(io, "daemon: from-capture: no meta.prompt_launch for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, " — recording needs_curation\n");
            try markBacklog(io, a, "needs_curation", fixture_id);
            damped.put(fixture_id, {}) catch {};
            return false;
        };
        // availability probe via the file's version_launch (absent ⇒ the
        // probe fails closed → unavailable).
        const version_launch = cf.version_launch orelse {
            daemonWriteErr(io, "daemon: from-capture: harness unavailable for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, " — no meta.version_launch\n");
            try recordKnownButFailed(io, a, fixture_id, "harness unavailable — no meta.version_launch", init.environ_map);
            damped.put(fixture_id, {}) catch {};
            return false;
        };
        if (!launchExitZero(io, a, version_launch)) {
            daemonWriteErr(io, "daemon: from-capture: harness unavailable for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, "\n");
            try recordKnownButFailed(io, a, fixture_id, "harness unavailable — version probe failed", init.environ_map);
            damped.put(fixture_id, {}) catch {};
            return false;
        }

        // spawn the curated prompt_launch verbatim — the file's argv[0] IS
        // the concrete binary for this platform, so there is no name
        // cycling (a failed spawn is an artifact failure, not a name
        // miss).
        var argv_buf: [32][]const u8 = undefined;
        if (launch.len == 0 or launch.len > argv_buf.len) {
            daemonWriteErr(io, "daemon: from-capture: malformed meta.prompt_launch for ");
            daemonWriteErr(io, fixture_id);
            daemonWriteErr(io, "\n");
            try recordKnownButFailed(io, a, fixture_id, "capture failed — malformed meta.prompt_launch", init.environ_map);
            damped.put(fixture_id, {}) catch {};
            return false;
        }
        for (launch, 0..) |arg, idx| {
            // the file saves the `"<prompt>"` placeholder; the daemon
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
            try recordKnownButFailed(io, a, fixture_id, "capture failed — spawn error", init.environ_map);
            damped.put(fixture_id, {}) catch {};
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
            try recordKnownButFailed(io, a, fixture_id, "capture failed — child wait error", init.environ_map);
            damped.put(fixture_id, {}) catch {};
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
                    // failed attempt → damped this session, retried next.
                    var msg: std.ArrayList(u8) = .empty;
                    try msg.appendSlice(a, "capture failed");
                    if (code != 0) {
                        var nbuf: [32]u8 = undefined;
                        const cs = std.fmt.bufPrint(&nbuf, " (exit {d})", .{code}) catch "";
                        try msg.appendSlice(a, cs);
                    }
                    if (stderr_capture.len > 0) {
                        try msg.appendSlice(a, ": ");
                        const tail_start = if (stderr_capture.len > 400) stderr_capture.len - 400 else 0;
                        try msg.appendSlice(a, stderr_capture[tail_start..]);
                    }
                    try recordKnownButFailed(io, a, fixture_id, msg.items, init.environ_map);
                    damped.put(fixture_id, {}) catch {};
                    return false;
                }
                if (!(try postCheckComboFixture(a, io, h, p, m_d, plat))) {
                    // the worker already wrote its file; the combo mismatch
                    // is a failure of the queued dims, not the session.
                    try recordKnownButFailed(io, a, fixture_id, "post-check mismatch", init.environ_map);
                    damped.put(fixture_id, {}) catch {};
                    return false;
                }
                try clearKnownButFailed(io, a, fixture_id);
                return true;
            },
            else => {
                daemonWriteErr(io, "daemon: from-capture child terminated abnormally for ");
                daemonWriteErr(io, fixture_id);
                daemonWriteErr(io, "\n");
                try recordKnownButFailed(io, a, fixture_id, "capture failed — child terminated abnormally", init.environ_map);
                damped.put(fixture_id, {}) catch {};
                return false;
            },
        }
    }

    /// the daemon's per-poll pick: refresh the backlog table, then scan
    /// the queue-entry array in mode-rank order (from-identity first,
    /// then array order), deleting fully-satisfied entries (no remaining
    /// candidates anywhere) and malformed entries (logged + dropped — the
    /// errors ledger is gone; `.daemon.log` is the dev agent's record),
    /// stamp `started_at` on the first entry with remaining host work,
    /// re-expand it, and return ONE candidate. All under one store lock
    /// cycle so the refresh + stamp + expansion + save are atomic against
    /// other writers.
    fn daemonPick(io: std.Io, a: std.mem.Allocator, damped: *std.StringHashMap(void)) !?DaemonPick {
        const lock_file = try acquireIndexLock(io);
        defer lock_file.close(io);
        var root = try indexLoad(io, a);
        try refreshBacklogPure(io, a, &root);
        const free_grid = try FreeGrid.load(io, a);
        const grids = try FeasibilityGrids.load(io, a);
        const q = try getOrPutArray(a, &root, "queue");
        const host = platformId();
        var dirty = false;
        var pick: ?DaemonPick = null;
        for ([_][]const u8{ "from-identity", "from-capture" }) |want_mode| {
            var i: usize = 0;
            while (i < q.items.len) {
                var entry = queueEntryFromValue(q.items[i]) catch {
                    daemonWriteErr(io, "daemon: malformed queue entry — dropping (see .daemon.log)\n");
                    _ = q.orderedRemove(i);
                    dirty = true;
                    continue;
                };
                validateQueueEntry(entry) catch {
                    daemonWriteErr(io, "daemon: invalid queue entry — dropping (see .daemon.log)\n");
                    _ = q.orderedRemove(i);
                    dirty = true;
                    continue;
                };
                if (!std.mem.eql(u8, entry.mode, want_mode)) {
                    i += 1;
                    continue;
                }
                const exp = try expandEntry(io, a, &free_grid, &grids, entry, host, damped);
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
                const exp2 = try expandEntry(io, a, &free_grid, &grids, entry, host, damped);
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
    /// poll it refreshes the backlog table, scans the queue-entry array
    /// in mode-rank order (from-identity first, then array order),
    /// purges entries with no remaining candidates anywhere, expands the
    /// first entry with remaining host-platform work (stamping
    /// `started_at` on its first work), and processes ONE candidate.
    /// from-identity jobs resolve the declared channel (zero tokens);
    /// from-capture jobs probe availability via the file's
    /// `meta.version_launch` then launch the real harness session via
    /// `meta.prompt_launch` (with a pre-capture review window,
    /// token-consuming, user-confirmed only). A candidate's completion
    /// timestamp (the mode's success `meta.updated_at`) ≥ the entry's
    /// `started_at` makes it done; a candidate this daemon session
    /// already failed is damped (one attempt per candidate per run) —
    /// crash-resume derives from the fixture files, so a capture that
    /// died with the daemon left no channel write and simply re-runs.
    /// Failures also persist as `known_but_failed` message rows plus
    /// `.daemon.log` for the dev agent to discern; pops never gate on
    /// failure state. **The daemon never writes fixture files outside
    /// pop processing and never inserts queue entries.**
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

        // session-scoped failure damping — one attempt per candidate per
        // daemon run (in-memory; the fixture files + known_but_failed are
        // the durable memory).
        var damped = std.StringHashMap(void).init(a);

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
                        const ok = runOneComboCapture(a, io, init, &damped, job.candidate.fixture_id, capture_timeout_seconds) catch |err| blk: {
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
                            daemonWriteErr(io, " — attempt damped this session; see known_but_failed / .daemon.log; retry via `fixtures queue --refresh`\n");
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
                        const pick = daemonPick(io, a, &damped) catch |err| blk: {
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

                            const ok = runOneComboIdentity(a, io, init, &damped, p.candidate.fixture_id) catch |err| blk: {
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
                                daemonWriteErr(io, " — attempt damped this session; see known_but_failed / .daemon.log\n");
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
