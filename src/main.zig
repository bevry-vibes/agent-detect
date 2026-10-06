// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detect — thin entry point + re-exports.
// The released CLI surface (identify / trailer / check-reciprocal / help / version) dispatches into lib/core.zig; the dev binary additionally exposes dev/dev.zig's `fixtures` namespace when built with `-Ddev=true`.
// The re-exported aliases below keep the test files compiling through `main.*` unchanged.

const std = @import("std");
const build_options = @import("build_options");
const core = @import("lib/core.zig");
const rules = @import("lib/rules.zig");
const index_data = @import("lib/index_data.zig");
const devmod = @import("dev/dev.zig");

pub const dev_build = build_options.dev;
pub const dev = devmod.dev;

const writeOut = core.writeOut;
const writeErr = core.writeErr;
const usage = core.usage;
const trailerUsage = core.trailerUsage;
const indexUsage = core.indexUsage;

const resolveRecipe = core.resolveRecipe;
const detect = core.detect;
const buildJson = core.buildJson;
const buildIndexSearchUrl = core.buildIndexSearchUrl;
const buildEntityUrl = core.buildEntityUrl;
const IndexQuery = core.IndexQuery;
const openURL = core.openURL;

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
const EXIT_FOUND_FILTERED = core.EXIT_FOUND_FILTERED;

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

// --- re-exports (tests compile through `main.*`)

pub const Detection = core.Detection;
pub const Reciprocity = core.Reciprocity;
pub const ReasonEntity = core.ReasonEntity;
pub const ReasonCode = core.ReasonCode;
pub const Reason = core.Reason;
pub const ActionKind = core.ActionKind;
pub const Action = core.Action;
pub const HarnessRule = rules.HarnessRule;
pub const rulesForHarnesses = rules.rulesForHarnesses;
pub const rulesForProviders = rules.rulesForProviders;
pub const rulesForModels = rules.rulesForModels;

pub fn slugId(a: std.mem.Allocator, display: []const u8) ![]u8 {
    return rules.slugId(a, display);
}

pub fn canonicalIdFor(a: std.mem.Allocator, comptime Rules: type, ruleset: []const Rules, input: []const u8) ?[]const u8 {
    return rules.canonicalIdFor(a, Rules, ruleset, input);
}

pub fn harnessRuleForFixtureId(a: std.mem.Allocator, agent_id: []const u8) ?HarnessRule {
    return rules.harnessRuleForFixtureId(a, agent_id);
}

pub fn reciprocityOf(d: *const Detection) Reciprocity {
    return core.reciprocityOf(d);
}

pub fn harnessReciprocityOf(d: *const Detection) ?bool {
    return core.harnessReciprocityOf(d);
}

pub fn providerReciprocityOf(d: *const Detection) ?bool {
    return core.providerReciprocityOf(d);
}

pub fn modelReciprocityOf(d: *const Detection) ?bool {
    return core.modelReciprocityOf(d);
}

pub fn computeReciprocal(d: *const Detection) bool {
    return core.computeReciprocal(d);
}

pub fn reasonsFor(a: std.mem.Allocator, d: *const Detection) ![]Reason {
    return core.reasonsFor(a, d);
}

pub const checkReciprocalVerdict = core.checkReciprocalVerdict;

pub fn applyHarnessTraining(d: *Detection, rule: HarnessRule) void {
    return core.applyHarnessTraining(d, rule);
}

pub fn buildTrailerLine(a: std.mem.Allocator, d: *const Detection, keyword: []const u8) !?[]u8 {
    return core.buildTrailerLine(a, d, keyword);
}

pub fn applyModel(a: std.mem.Allocator, d: *Detection, name: []const u8, raw_input: []const u8) !void {
    return core.applyModel(a, d, name, raw_input);
}

pub fn modelFromMessageData(a: std.mem.Allocator, data: []const u8) !?core.ActiveSessionModel {
    return core.modelFromMessageData(a, data);
}

pub fn modelFromSessionRow(a: std.mem.Allocator, model_str: []const u8) !?core.ActiveSessionModel {
    return core.modelFromSessionRow(a, model_str);
}

pub const zcodeRolloutNewestMainRecord = core.zcodeRolloutNewestMainRecord;
pub const zcodeProviderCanonical = core.zcodeProviderCanonical;

/// decision #8 — the dev binary's top-level help: the released usage plus a dev-actions block referencing the fixtures namespace, the two refresh modes, and the daemon pacing/control flags.
/// The released `agent-detect --help` is `usage` alone.
const devUsage = if (dev_build)
    usage ++
        \\
        \\dev actions (maintainer-only binary — `fixtures help` has the full namespace,
        \\including the refresh-mode, scope, and daemon flags):
        \\  fixtures daemon   long-running queue worker (user-only, never inside an agent);
        \\                    pops rows in order from-identity → from-capture with
        \\                    adaptive pacing; pause/resume/stop via fixtures/daemon.ctl
        \\  fixtures capture  capture the current session into fixtures/<id>.json
        \\                    (daemon-spawned, or run by hand inside a harness session)
        \\  fixtures queue    upsert queue entries [staleness] [filters] [--repair]
        \\  fixtures dequeue  DELETE matching queue entries [staleness] [filters]
        \\  fixtures status   print the derived snapshot (fixtured counts, backlog,
        \\                    feasible-unfixtured totals, stale/fresh breakdowns)
        \\  fixtures prompt   print the capture prompt (what a harness session
        \\                    is asked to run)
        \\  fixtures help     the fixtures namespace's full help
        \\
else
    usage;

// ============================================================================ main entry

/// is `word` one of the known top-level action words? (`web` — the retired
/// `registry` spelling — resolves through the help-topic branch above.)
fn isKnownAction(word: []const u8) bool {
    return std.mem.eql(u8, word, "identify") or
        std.mem.eql(u8, word, "found") or
        std.mem.eql(u8, word, "explain") or
        std.mem.eql(u8, word, "trailer") or
        std.mem.eql(u8, word, "check-reciprocal") or
        std.mem.eql(u8, word, "index") or
        std.mem.eql(u8, word, "help") or
        std.mem.eql(u8, word, "version");
}

pub fn main(init: std.process.Init) u8 {
    if (@import("builtin").os.tag == .windows) {
        // CP_UTF8 (65001): the default OEM console code page (cp437/850/1252) mangles the UTF-8 output (em dash, middle dot). Failure ignored: daemonized runs have no console.
        _ = core.SetConsoleOutputCP(65001);
        _ = core.SetConsoleCP(65001);
    }
    return mainInner(init) catch |err| switch (err) {
        error.OutOfMemory => blk: {
            // writeErr's static write does not allocate, so this stays safe mid-OOM.
            writeErr(init.io, MSG_OUT_OF_MEMORY);
            break :blk EXIT_OUT_OF_MEMORY;
        },
        else => blk: {
            // the optional `sqlite3` CLI is absent while a live session-store read needed it (kilo/opencode/copilot/crush/hermes) — the harness is known, detection cannot finish: exit 6, not a misleading exit 8.
            if (err == error.SqliteUnavailable) {
                writeErr(init.io, MSG_ENV_INCOMPLETE);
                writeErr(init.io, "  - the optional sqlite3 CLI is absent from PATH — install it, then re-run\n");
                break :blk EXIT_ENV_INCOMPLETE;
            }
            // dev-only error kinds — pruned from the released binary. Each writes its registry-name message to stderr (matching the "exact message verbage" scheme) plus its exit code.
            if (dev_build) {
                if (err == error.IndexStoreError) {
                    writeErr(init.io, MSG_INDEX_STORE);
                    break :blk EXIT_INDEX_STORE;
                }
                if (err == error.IndexStoreLockTimeout) {
                    writeErr(init.io, MSG_IO);
                    break :blk EXIT_IO;
                }
                if (err == error.FilesystemIoError) {
                    writeErr(init.io, MSG_IO);
                    break :blk EXIT_IO;
                }
                if (err == error.RunningInAgent) {
                    writeErr(init.io, MSG_ENV_INCOMPATIBLE);
                    break :blk EXIT_ENV_INCOMPATIBLE;
                }
                if (err == error.InvalidQueueRow) {
                    writeErr(init.io, MSG_CONFLICTING_ARG);
                    break :blk EXIT_CONFLICTING_ARG;
                }
            }
            // genuinely unexpected/unclassified (bug) — the only home of exit 1.
            writeErr(init.io, "error: ");
            writeErr(init.io, @errorName(err));
            writeErr(init.io, "\n");
            break :blk EXIT_UNRECOGNISED_ERROR;
        },
    };
}

fn mainInner(init: std.process.Init) anyerror!u8 {
    const a = init.arena.allocator();
    const io = init.io;

    // subcommand dispatch.
    // The dev binary (built with -Ddev=true) accepts a `fixtures` subcommand namespace: `fixtures --help`, `fixtures daemon`, `fixtures capture`, `fixtures queue [--harness=...] [--provider=...] [--model=...]`, `fixtures queue --recipes`, `fixtures dequeue`.
    // The `fixtures` dispatch is compiled out of the released binary (dev_build is false) — the released and dev binaries both run the action parser below: `identify`, `found`, `explain`, `trailer`, `check-reciprocal`, `help`, `version` (with no arguments showing help).
    if (dev_build) {
        var sub_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return error.OutOfMemory;
        defer sub_iter.deinit();
        _ = sub_iter.skip(); // argv0
        const cmd = sub_iter.next() orelse "";
        const sub = sub_iter.next() orelse "";
        // decision #8 — the dev binary's top-level help (bare no-args, `help`, `--help`, `-h`) shows the FULL dev surface: the released usage plus the dev actions section.
        // `agent-detect --help` (released binary) is unchanged.
        if (std.mem.eql(u8, cmd, "") or
            std.mem.eql(u8, cmd, "help") or
            std.mem.eql(u8, cmd, "--help") or
            std.mem.eql(u8, cmd, "-h"))
        {
            if (std.mem.eql(u8, sub, "trailer")) {
                writeOut(io, trailerUsage);
                return EXIT_OK;
            }
            writeOut(io, devUsage);
            return EXIT_OK;
        }
        if (std.mem.eql(u8, cmd, "fixtures")) {
            // the daemon's from-capture workers run in a throwaway cwd and may be re-parented by the harness, so the store root is re-pointed from the env var, the cwd, or the binary's own location — in that order.
            dev.applyFixturesRootEnv(io, init.environ_map);
            if (sub.len == 0 or
                std.mem.eql(u8, sub, "--help") or
                std.mem.eql(u8, sub, "-h") or
                std.mem.eql(u8, sub, "help"))
            {
                return dev.runFixturesHelp(init);
            } else if (std.mem.eql(u8, sub, "daemon")) {
                return dev.runFixturesDaemon(init);
            } else if (std.mem.eql(u8, sub, "capture")) {
                return dev.runFixturesCapture(init);
            } else if (std.mem.eql(u8, sub, "queue")) {
                return dev.runFixturesQueue(init);
            } else if (std.mem.eql(u8, sub, "dequeue")) {
                return dev.runFixturesDequeue(init);
            } else if (std.mem.eql(u8, sub, "status")) {
                return dev.runFixturesStatus(init);
            } else if (std.mem.eql(u8, sub, "index")) {
                return dev.runFixturesIndex(init);
            } else if (std.mem.eql(u8, sub, "identity")) {
                return dev.runFixturesIdentity(init);
            } else if (std.mem.eql(u8, sub, "prompt")) {
                return dev.runFixturesPrompt(init);
            } else if (std.mem.eql(u8, sub, "__timeout")) {
                // internal watchdog used by the from-capture worker.
                return dev.runTimeoutWorker(init);
            } else {
                writeErr(io, "fixtures: unrecognised argument: '");
                writeErr(io, sub);
                writeErr(io, "'\n");
                writeOut(io, dev.fixturesUsage);
                return EXIT_UNRECOGNISED_ARG;
            }
        }
    }

    // action parser.
    // The canonical spellings are the bare words `identify`, `found`, `explain`, `trailer` (with a subtype), `check-reciprocal`, `help`, and `version`; the `--help`/`-h` and `--version`/`-V` forms are aliases.
    // No arguments prints help.
    // `identify`, `found`, `explain`, `trailer <type>`, and `check-reciprocal` accept an optional complete combo (`--harness=H --provider=P --model=M` — all three or none) for recipe-mode output.
    // help/version win over everything: any help/version flag anywhere at top level short-circuits to the relevant usage/version output (exit 0), never a conflict.
    var action: []const u8 = ""; // "", "identify", "found", "explain", "trailer", "check-reciprocal", "index", "registry" (retired), "help", "version"
    var web_alias = false; // the action word was `web` — the twice-retired spelling (`web` → `registry` → `index`)
    var trailer_type: []const u8 = ""; // "", "co-author", "assisted-by"
    var help_wanted = false;
    var version_wanted = false;
    var help_topic: ?[]const u8 = null; // the word following `help` (`help trailer`)
    var unknown: ?[]const u8 = null; // first unrecognised bare word (no action set yet)
    var conflict: ?[]const u8 = null; // a second, different action/subtype word
    var combo_h: []const u8 = "";
    var combo_p: []const u8 = "";
    var combo_m: []const u8 = "";
    var agent_id: []const u8 = ""; // the --agent= value (index: the agent entity form)
    var email: []const u8 = ""; // the --email= value (index filter)
    var search_filter: []const u8 = ""; // the --search= value (index: site-side free-text)
    var web_platform: []const u8 = ""; // the --platform= value (index filter)
    var entity_kind: []const u8 = ""; // the positional entity word after `index`: agent|harness|provider|model
    var entity_id: []const u8 = ""; // the positional id after the entity word
    var free_filter: ?bool = null; // --free / --no-free / --free=true|false
    var reciprocal_filter: ?bool = null; // --reciprocal / --no-reciprocal / --reciprocal=true|false
    var want_web = false; // --web (registry/index: also open the site)
    var no_web = false; // --no-web (explicit default)
    var want_json = false; // --json (explicit default)
    var no_json = false; // --no-json (suppress stdout — exit status only)
    var no_open_gone = false; // --no-open — retired with the web→registry rename
    var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return error.OutOfMemory;
    defer args_it.deinit();
    _ = args_it.skip(); // argv0
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_wanted = true;
            if (action.len == 0) action = "help";
        } else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            version_wanted = true;
        } else if (std.mem.eql(u8, arg, "identify") or std.mem.eql(u8, arg, "found") or std.mem.eql(u8, arg, "explain") or std.mem.eql(u8, arg, "trailer") or std.mem.eql(u8, arg, "check-reciprocal") or std.mem.eql(u8, arg, "registry") or std.mem.eql(u8, arg, "index") or std.mem.eql(u8, arg, "web")) {
            // an action word (`web` is the retired spelling of `registry`, kept
            // dispatching quietly for scripts born with 2026.9.30-1). After `help`
            // it is the topic (`help trailer`).
            if (action.len == 0) {
                web_alias = std.mem.eql(u8, arg, "web");
                action = if (web_alias) "registry" else arg;
            } else if (std.mem.eql(u8, action, "help") and help_topic == null) {
                help_topic = arg;
            } else if (!std.mem.eql(u8, action, arg) and conflict == null) {
                conflict = arg;
            }
        } else if (std.mem.eql(u8, action, "index") and (std.mem.eql(u8, arg, "agent") or std.mem.eql(u8, arg, "harness") or std.mem.eql(u8, arg, "provider") or std.mem.eql(u8, arg, "model"))) {
            // the positional entity view: `index agent <id>` — the kind word, then the id
            if (entity_kind.len == 0) {
                entity_kind = arg;
            } else if (entity_id.len == 0) {
                entity_id = arg;
            } else if (conflict == null) {
                conflict = arg;
            }
        } else if (std.mem.eql(u8, arg, "co-author") or std.mem.eql(u8, arg, "assisted-by")) {
            // trailer subtypes; after any other action a bare word is a conflict.
            if (std.mem.eql(u8, action, "trailer") and trailer_type.len == 0) {
                trailer_type = arg;
            } else if (std.mem.eql(u8, action, "help") and help_topic == null) {
                help_topic = arg;
            } else if (action.len == 0) {
                if (unknown == null) unknown = arg;
            } else if (conflict == null) {
                conflict = arg;
            }
        } else if (std.mem.startsWith(u8, arg, "--harness=")) {
            combo_h = arg["--harness=".len..];
        } else if (std.mem.startsWith(u8, arg, "--provider=")) {
            combo_p = arg["--provider=".len..];
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            combo_m = arg["--model=".len..];
        } else if (std.mem.startsWith(u8, arg, "--agent=")) {
            agent_id = arg["--agent=".len..];
        } else if (std.mem.startsWith(u8, arg, "--email=")) {
            email = arg["--email=".len..];
        } else if (std.mem.startsWith(u8, arg, "--platform=")) {
            web_platform = arg["--platform=".len..];
        } else if (std.mem.startsWith(u8, arg, "--search=")) {
            search_filter = arg["--search=".len..];
        } else if (std.mem.eql(u8, arg, "--free") or std.mem.eql(u8, arg, "--free=true")) {
            free_filter = true;
        } else if (std.mem.eql(u8, arg, "--no-free") or std.mem.eql(u8, arg, "--free=false")) {
            free_filter = false;
        } else if (std.mem.eql(u8, arg, "--reciprocal") or std.mem.eql(u8, arg, "--reciprocal=true")) {
            reciprocal_filter = true;
        } else if (std.mem.eql(u8, arg, "--no-reciprocal") or std.mem.eql(u8, arg, "--reciprocal=false")) {
            reciprocal_filter = false;
        } else if (std.mem.eql(u8, arg, "--web")) {
            want_web = true;
        } else if (std.mem.eql(u8, arg, "--no-web")) {
            no_web = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            want_json = true;
        } else if (std.mem.eql(u8, arg, "--no-json")) {
            no_json = true;
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            no_open_gone = true;
        } else {
            // unrecognised bare word / flag.
            if (std.mem.eql(u8, action, "help") and help_topic == null) {
                help_topic = arg; // `help <topic>`
            } else if (std.mem.eql(u8, action, "index") and entity_kind.len > 0 and entity_id.len == 0 and arg.len > 0 and arg[0] != '-') {
                entity_id = arg; // `index agent <id>` — the id
            } else if (action.len == 0) {
                if (unknown == null) unknown = arg;
            } else if (conflict == null) {
                conflict = arg;
            }
        }
    }

    // version wins over everything.
    if (version_wanted) {
        // Version is plumbed in at compile time from `build.zig.zon`'s `.version` field via `build_options`.
        // Same value is baked into the released binary, the dev binary, and every `zig build dist` cross-compile target.
        writeOut(io, "agent-detect ");
        writeOut(io, build_options.version);
        writeOut(io, "\n");
        return EXIT_OK;
    }

    // help wins over everything.
    if (help_wanted) {
        if (std.mem.eql(u8, action, "trailer")) {
            writeOut(io, trailerUsage);
            return EXIT_OK;
        }
        if (std.mem.eql(u8, action, "index")) {
            writeOut(io, indexUsage);
            return EXIT_OK;
        }
        if (help_topic) |topic| {
            if (std.mem.eql(u8, topic, "trailer")) {
                writeOut(io, trailerUsage);
                return EXIT_OK;
            }
            if (std.mem.eql(u8, topic, "registry") or std.mem.eql(u8, topic, "web")) {
                writeErr(io, "registry is gone — one command: agent-detect index (see `index --help`)\n");
                writeOut(io, indexUsage);
                return EXIT_UNRECOGNISED_ARG;
            }
            if (std.mem.eql(u8, topic, "index")) {
                writeOut(io, indexUsage);
                return EXIT_OK;
            }
            if (isKnownAction(topic)) {
                writeOut(io, usage);
                return EXIT_OK;
            }
            writeErr(io, MSG_UNRECOGNISED_ARG);
            writeErr(io, topic);
            writeErr(io, "'\n");
            writeOut(io, usage);
            return EXIT_UNRECOGNISED_ARG;
        }
        writeOut(io, usage);
        return EXIT_OK;
    }

    // an unrecognised action word (a bare word appeared before any known action, e.g. `foobar`, `--bogus`, `foobar identify`).
    if (unknown != null) {
        writeErr(io, MSG_UNRECOGNISED_ARG);
        writeErr(io, unknown.?);
        writeErr(io, "'\n");
        writeOut(io, usage);
        return EXIT_UNRECOGNISED_ARG;
    }

    // no arguments (or only option flags, no action) → top usage.
    if (action.len == 0) {
        writeOut(io, usage);
        return EXIT_OK;
    }

    // two distinct action/subtype words → conflicting argument.
    if (conflict != null) {
        writeErr(io, MSG_CONFLICTING_ARG);
        writeOut(io, usage);
        return EXIT_CONFLICTING_ARG;
    }

    // the index flags on any other action (or no action) → conflicting
    // argument: the filters deep-link the site, the output flags shape the JSON —
    // neither means anything to identify/trailer/check-reciprocal.
    const index_action = std.mem.eql(u8, action, "index");
    if ((web_platform.len > 0 or agent_id.len > 0 or email.len > 0 or search_filter.len > 0 or free_filter != null or reciprocal_filter != null or want_web or no_web or want_json or no_json) and !index_action) {
        writeErr(io, MSG_CONFLICTING_ARG);
        writeOut(io, usage);
        return EXIT_CONFLICTING_ARG;
    }

    // --no-open is gone — index opening is opt-in via --web (elsewhere it was
    // already a conflict, caught above).
    if (no_open_gone) {
        writeErr(io, MSG_UNRECOGNISED_ARG);
        writeErr(io, "--no-open' — it is gone: index opens the site only with --web\n");
        writeOut(io, if (index_action) indexUsage else usage);
        return EXIT_UNRECOGNISED_ARG;
    }

    // `registry` (and its own retired spelling `web`) — dropped: one command.
    if (std.mem.eql(u8, action, "registry")) {
        writeErr(io, "registry is gone — one command: agent-detect index\n");
        writeErr(io, "  - `index` (no entity) is the search view; `index agent|harness|provider|model <id>` the entity views\n");
        writeErr(io, "  - the filters work exactly as before, and --web still opens the site\n");
        writeOut(io, indexUsage);
        return EXIT_UNRECOGNISED_ARG;
    }

    // `index` — the search view and the entity views.
    if (std.mem.eql(u8, action, "index")) {
        return runIndex(init, .{ .web = want_web, .no_web = no_web, .json = want_json, .no_json = no_json }, entity_kind, entity_id, combo_h, combo_p, combo_m, agent_id, email, search_filter, web_platform, free_filter, reciprocal_filter);
    }

    // bare `trailer` → missing required arguments (subtype absent).
    // The compact decision guidance follows the stable registry line — the agent reads the menu and re-invokes with the subtype (the CLI stays non-interactive: agents call one-shot, so a menu + re-invoke is the agent-native prompt).
    if (std.mem.eql(u8, action, "trailer") and trailer_type.len == 0) {
        writeErr(io, MSG_MISSING_ARG_TRAILER_SUBTYPE);
        writeErr(io, "choose one, never both — git commits: co-author · issue-tracker posts (issues, PRs, discussions, comments): assisted-by\n");
        writeErr(io, "your org's or harness's instructions take precedence when they name one\n");
        writeOut(io, trailerUsage);
        return EXIT_MISSING_ARG;
    }

    // recipe mode: a complete combo resolves against the rule tables, skipping live detection. Partial combos are rejected (exit 4); an unknown combo is exit 7.
    const has_combo = combo_h.len > 0 or combo_p.len > 0 or combo_m.len > 0;
    if (has_combo) {
        if (combo_h.len == 0 or combo_p.len == 0 or combo_m.len == 0) {
            writeErr(io, MSG_MISSING_ARG_COMBO);
            writeOut(io, usage);
            return EXIT_MISSING_ARG;
        }
        const d = (try resolveRecipe(a, combo_h, combo_p, combo_m)) orelse {
            // report which dims resolved (strict slug id) and which did not (null) so the unknown dim is visible at a glance.
            core.writeMissingSpecifiedAgent(io, rules.canonicalFilterDim(a, rules.HarnessRule, &rules.rulesForHarnesses, combo_h), rules.canonicalFilterDim(a, rules.ProviderRule, &rules.rulesForProviders, combo_p), rules.canonicalFilterDim(a, rules.ModelRule, &rules.rulesForModels, combo_m));
            return EXIT_MISSING_SPECIFIED_AGENT;
        };
        return runAction(init, &d, action, trailer_type, true);
    }

    // live detection.
    var d = Detection{};
    _ = try detect(init, &d);
    return runAction(init, &d, action, trailer_type, false);
}

// ============================================================================ web

/// the `--platform=` value → the fixture platform ids the site uses
/// (darwin / linux / windows); the common shell names alias in.
fn canonicalWebPlatform(v: []const u8) ?[]const u8 {
    const rows = [_]struct { canon: []const u8, aliases: []const []const u8 }{
        .{ .canon = "darwin", .aliases = &.{ "macos", "mac" } },
        .{ .canon = "linux", .aliases = &.{} },
        .{ .canon = "windows", .aliases = &.{"win"} },
    };
    for (rows) |row| {
        if (std.mem.eql(u8, row.canon, v)) return row.canon;
        for (row.aliases) |alias| {
            if (std.mem.eql(u8, alias, v)) return row.canon;
        }
    }
    return null;
}

/// the shared `--web`/`--json` output options (both sites of the flag family are
/// accepted so an explicit default reads the same as its absence).
const OutputOpts = struct {
    web: bool = false,
    no_web: bool = false,
    json: bool = false,
    no_json: bool = false,
};

/// open `url` unless suppressed — the shared --web path. The caller has already
/// printed its JSON, so a failed opener is just the exit-6 note on stderr.
fn openIfWanted(io: std.Io, a: std.mem.Allocator, url: []const u8, opts: OutputOpts) !u8 {
    if (!opts.web) return EXIT_OK;
    openURL(a, io, url) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            writeErr(io, MSG_ENV_INCOMPLETE);
            writeErr(io, "  - the platform url opener is absent or failed — install it (xdg-open on linux, open on macos)\n");
            return EXIT_ENV_INCOMPLETE;
        },
    };
    return EXIT_OK;
}

/// the `index` action — the search view and the entity views (D10's collapse):
/// no entity → the filtered rule index (the embedded fixtures/index-data.json);
/// `agent|harness|provider|model <id>` → that entity's view, mapping onto the
/// site's routes. Dim flags address entities (one flag names that entity, all
/// three name the agent, two conflict); on an entity view every filter is a
/// PREDICATE, never a slice — the payload is unchanged, and a filter that
/// excludes the entity fails with exit 14, the per-filter match states on
/// stderr (the human report) and the structured match report on stdout (unless
/// --no-json). Unknown agents/dims exit 7.
fn runIndex(
    init: std.process.Init,
    opts: OutputOpts,
    entity_kind: []const u8,
    entity_id: []const u8,
    h: []const u8,
    p: []const u8,
    m: []const u8,
    agent_flag: []const u8,
    email: []const u8,
    search: []const u8,
    platform: []const u8,
    free_filter: ?bool,
    reciprocal_filter: ?bool,
) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    const cp: []const u8 = if (platform.len > 0) blk: {
        const canon = canonicalWebPlatform(platform) orelse {
            writeErr(io, MSG_UNRECOGNISED_ARG);
            writeErr(io, "--platform=");
            writeErr(io, platform);
            writeErr(io, "' — one of darwin (macos), linux, windows\n");
            writeOut(io, indexUsage);
            return EXIT_UNRECOGNISED_ARG;
        };
        break :blk canon;
    } else "";

    const trimmed_email_raw = std.mem.trim(u8, email, " \t");
    if (email.len > 0 and trimmed_email_raw.len == 0) {
        writeErr(io, MSG_MISSING_ARG);
        writeErr(io, "  - --email= requires the trailer email to filter by\n");
        writeOut(io, indexUsage);
        return EXIT_MISSING_ARG;
    }
    const trimmed_email = try std.ascii.allocLowerString(a, trimmed_email_raw);
    const trimmed_search = std.mem.trim(u8, search, " \t");

    // resolve the view: the positional entity word wins, then the flag forms.
    const EntityKind = enum { none, agent, harness, provider, model };
    var kind: EntityKind = .none;
    var id_input: []const u8 = "";
    if (entity_kind.len > 0) {
        kind = blk: {
            if (std.mem.eql(u8, entity_kind, "agent")) break :blk EntityKind.agent;
            if (std.mem.eql(u8, entity_kind, "harness")) break :blk EntityKind.harness;
            if (std.mem.eql(u8, entity_kind, "provider")) break :blk EntityKind.provider;
            break :blk EntityKind.model;
        };
        if (entity_id.len == 0) {
            writeErr(io, MSG_MISSING_ARG);
            writeErr(io, "  - index ");
            writeErr(io, entity_kind);
            writeErr(io, " requires the <id> — `index ");
            writeErr(io, entity_kind);
            writeErr(io, " <id>`\n");
            writeOut(io, indexUsage);
            return EXIT_MISSING_ARG;
        }
        // double-naming: the positional kind and its own flag are a conflict
        // (they may disagree); the OTHER dims are predicates on the view.
        const own_flag = switch (kind) {
            .agent => agent_flag.len > 0,
            .harness => h.len > 0,
            .provider => p.len > 0,
            .model => m.len > 0,
            .none => false,
        };
        if (own_flag) {
            writeErr(io, MSG_CONFLICTING_ARG);
            writeErr(io, "  - the entity is named twice — pass the id once (positional or flag)\n");
            writeOut(io, indexUsage);
            return EXIT_CONFLICTING_ARG;
        }
        id_input = entity_id;
    } else if (agent_flag.len > 0) {
        kind = .agent;
        id_input = agent_flag;
    } else {
        const dims: usize = (if (h.len > 0) @as(usize, 1) else 0) +
            (if (p.len > 0) @as(usize, 1) else 0) + (if (m.len > 0) @as(usize, 1) else 0);
        if (dims == 3) {
            // all three dim flags name the AGENT — the resolved slugs compose the id
            const rh = rules.canonicalFilterDim(a, rules.HarnessRule, &rules.rulesForHarnesses, h) orelse {
                core.writeMissingSpecifiedAgent(io, null, null, null);
                return EXIT_MISSING_SPECIFIED_AGENT;
            };
            const rp = rules.canonicalFilterDim(a, rules.ProviderRule, &rules.rulesForProviders, p) orelse {
                core.writeMissingSpecifiedAgent(io, null, null, null);
                return EXIT_MISSING_SPECIFIED_AGENT;
            };
            const rm = rules.canonicalFilterDim(a, rules.ModelRule, &rules.rulesForModels, m) orelse {
                core.writeMissingSpecifiedAgent(io, null, null, null);
                return EXIT_MISSING_SPECIFIED_AGENT;
            };
            kind = .agent;
            id_input = try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ rh, rp, rm });
        } else if (dims == 1) {
            kind = if (h.len > 0) EntityKind.harness else if (p.len > 0) EntityKind.provider else EntityKind.model;
            id_input = if (h.len > 0) h else if (p.len > 0) p else m;
        } else if (dims == 2) {
            writeErr(io, MSG_CONFLICTING_ARG);
            writeErr(io, "  - one dim flag names that entity; all three name the agent; two name nothing\n");
            writeOut(io, indexUsage);
            return EXIT_CONFLICTING_ARG;
        }
    }

    const idx = index_data.Index.load(a) catch return error.IndexDataInvalid;

    // ------------------------- the search view -------------------------
    if (kind == .none) {
        const value = try idx.buildFiltered(a, .{
            .platform = if (cp.len > 0) cp else null,
            .free = free_filter,
            .reciprocal = reciprocal_filter,
        });
        if (!opts.no_json) {
            const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
            writeOut(io, bytes);
            writeOut(io, "\n");
        }
        const url = try buildIndexSearchUrl(a, .{
            .email = trimmed_email,
            .platform = cp,
            .search = trimmed_search,
            .free = free_filter,
            .reciprocal = reciprocal_filter,
        });
        return openIfWanted(io, a, url, opts);
    }

    // ------------------------- the entity views -------------------------
    // resolve the canonical id — dims resolve like the recipe flags; the agent
    // id matches exactly after trim + lowercase + the @local strip.
    const kind_name: []const u8 = switch (kind) {
        .agent => "agent",
        .harness => "harness",
        .provider => "provider",
        .model => "model",
        .none => unreachable,
    };
    var canonical: []const u8 = "";
    if (kind == .agent) {
        const lowered = try std.ascii.allocLowerString(a, std.mem.trim(u8, id_input, " \t"));
        const stripped = if (std.mem.endsWith(u8, lowered, "@local")) lowered[0 .. lowered.len - "@local".len] else lowered;
        // shape: exactly 3 dash-separated alphanumeric segments (the 4-part
        // fixture id is gone with the platform dim)
        var segs: usize = 0;
        var ok = stripped.len > 0;
        var sit = std.mem.splitScalar(u8, stripped, '-');
        while (sit.next()) |seg| {
            if (seg.len == 0) {
                ok = false;
                break;
            }
            for (seg) |c| {
                if (!std.ascii.isAlphanumeric(c)) ok = false;
            }
            segs += 1;
        }
        if (!ok or segs != 3) {
            writeErr(io, "unknown agent: ");
            writeErr(io, id_input);
            writeErr(io, "' — expected the 3-part <harness>-<provider>-<model> id (or its <id>@local email form)\n");
            return EXIT_MISSING_SPECIFIED_AGENT;
        }
        if (idx.agentFacts(a, stripped) == null) {
            writeErr(io, "unknown agent: ");
            writeErr(io, stripped);
            writeErr(io, " — see the site's /index.json for the valid agent_ids\n");
            return EXIT_MISSING_SPECIFIED_AGENT;
        }
        canonical = stripped;
    } else {
        const resolver = switch (kind) {
            .harness => rules.canonicalFilterDim(a, rules.HarnessRule, &rules.rulesForHarnesses, id_input),
            .provider => rules.canonicalFilterDim(a, rules.ProviderRule, &rules.rulesForProviders, id_input),
            .model => rules.canonicalFilterDim(a, rules.ModelRule, &rules.rulesForModels, id_input),
            else => unreachable,
        };
        canonical = resolver orelse {
            writeErr(io, "unknown ");
            writeErr(io, kind_name);
            writeErr(io, ": ");
            writeErr(io, id_input);
            writeErr(io, "' — names, labels, and aliases resolve (see /registry.json)\n");
            return EXIT_MISSING_SPECIFIED_AGENT;
        };
    }

    // the dim predicate values resolve up front (an unresolvable dim input is
    // exit 7 — the registry convention, knowable before any evaluation)
    const rh: ?[]const u8 = if (h.len > 0) rules.canonicalFilterDim(a, rules.HarnessRule, &rules.rulesForHarnesses, h) else null;
    const rp: ?[]const u8 = if (p.len > 0) rules.canonicalFilterDim(a, rules.ProviderRule, &rules.rulesForProviders, p) else null;
    const rm: ?[]const u8 = if (m.len > 0) rules.canonicalFilterDim(a, rules.ModelRule, &rules.rulesForModels, m) else null;
    if ((h.len > 0 and rh == null) or (p.len > 0 and rp == null) or (m.len > 0 and rm == null)) {
        core.writeMissingSpecifiedAgent(io, rh, rp, rm);
        return EXIT_MISSING_SPECIFIED_AGENT;
    }

    // one filter's verdict against the entity
    const FilterMatch = struct {
        flag: []const u8,
        value: []const u8,
        matched: bool,
        /// the fact that decided it — printed on the stderr explanation
        fact: []const u8 = "",
        /// the RESOLVED value the deep link carries (the canonical slug, the
        /// true/false form) — the violating filters stay out of the link
        qvalue: []const u8 = "",
        qname: []const u8 = "",
    };
    var checks: std.ArrayList(FilterMatch) = .empty;

    // the agent id's dash-separated segment (0 = harness, 1 = provider, 2 = model)
    const agentSegment = struct {
        fn get(agent: []const u8, seg: usize) []const u8 {
            var it = std.mem.splitScalar(u8, agent, '-');
            var i: usize = 0;
            while (it.next()) |s| : (i += 1) {
                if (i == seg) return s;
            }
            return "";
        }
    }.get;

    // the view's own segment (the dim the entity names)
    const view_seg: usize = switch (kind) {
        .harness => 0,
        .provider => 1,
        .model => 2,
        else => unreachable,
    };

    var all_matched = true;

    if (kind == .agent) {
        const facts = idx.agentFacts(a, canonical).?;
        const seg_h = agentSegment(canonical, 0);
        const seg_p = agentSegment(canonical, 1);
        const seg_m = agentSegment(canonical, 2);
        if (h.len > 0) checks.append(a, .{ .flag = "--harness", .value = h, .matched = std.mem.eql(u8, rh.?, seg_h), .qname = "harness", .qvalue = rh.? }) catch return error.OutOfMemory;
        if (p.len > 0) checks.append(a, .{ .flag = "--provider", .value = p, .matched = std.mem.eql(u8, rp.?, seg_p), .qname = "provider", .qvalue = rp.? }) catch return error.OutOfMemory;
        if (m.len > 0) checks.append(a, .{ .flag = "--model", .value = m, .matched = std.mem.eql(u8, rm.?, seg_m), .qname = "model", .qvalue = rm.? }) catch return error.OutOfMemory;
        if (free_filter) |want| {
            const has = idx.freeHas(seg_p, seg_m);
            checks.append(a, .{ .flag = if (want) "--free" else "--no-free", .value = "", .matched = has == want, .fact = if (has) "the cell is free" else "the cell is not free", .qname = "free", .qvalue = if (want) "true" else "false" }) catch return error.OutOfMemory;
        }
        if (reciprocal_filter) |want| {
            checks.append(a, .{ .flag = if (want) "--reciprocal" else "--no-reciprocal", .value = "", .matched = facts.reciprocal == want, .fact = if (facts.reciprocal) "the reciprocity of record is true" else "the reciprocity of record is false", .qname = "reciprocal", .qvalue = if (want) "true" else "false" }) catch return error.OutOfMemory;
        }
        if (cp.len > 0) {
            var has = false;
            var plats: std.ArrayList(u8) = .empty;
            for (facts.platforms) |plat| {
                if (plats.items.len > 0) plats.appendSlice(a, ", ") catch return error.OutOfMemory;
                plats.appendSlice(a, plat) catch return error.OutOfMemory;
                if (std.mem.eql(u8, plat, cp)) has = true;
            }
            checks.append(a, .{ .flag = "--platform", .value = cp, .matched = has, .fact = if (plats.items.len > 0) try std.fmt.allocPrint(a, "captured on: {s}", .{plats.items}) else "no captures", .qname = "platform", .qvalue = cp }) catch return error.OutOfMemory;
        }
        if (trimmed_email.len > 0) {
            const record = try std.fmt.allocPrint(a, "{s}@local", .{canonical});
            checks.append(a, .{ .flag = "--email", .value = trimmed_email, .matched = std.mem.eql(u8, trimmed_email, record), .fact = try std.fmt.allocPrint(a, "the email of record is {s}", .{record}), .qname = "email", .qvalue = record }) catch return error.OutOfMemory;
        }
    } else {
        // dim entity views — participation: each filter is matched iff the
        // entity participates in ≥1 combo (agent) satisfying it
        if (free_filter) |want| {
            var found = false;
            var it = idx.agents.iterator();
            while (it.next()) |kv| {
                if (!std.mem.eql(u8, agentSegment(kv.key_ptr.*, view_seg), canonical)) continue;
                if (idx.freeHas(agentSegment(kv.key_ptr.*, 1), agentSegment(kv.key_ptr.*, 2))) found = true;
            }
            checks.append(a, .{ .flag = if (want) "--free" else "--no-free", .value = "", .matched = found, .fact = if (found) "a combo's cell matches" else "no combo's cell matches", .qname = "free", .qvalue = if (want) "true" else "false" }) catch return error.OutOfMemory;
        }
        if (reciprocal_filter) |want| {
            var found = false;
            var it = idx.agents.iterator();
            while (it.next()) |kv| {
                if (!std.mem.eql(u8, agentSegment(kv.key_ptr.*, view_seg), canonical)) continue;
                const entry_v = kv.value_ptr.*;
                if (entry_v != .object) continue;
                const recip = if (entry_v.object.get("reciprocal")) |r| (r == .bool and r.bool) else false;
                if (recip == want) found = true;
            }
            checks.append(a, .{ .flag = if (want) "--reciprocal" else "--no-reciprocal", .value = "", .matched = found, .fact = if (found) "a combo's reciprocity of record matches" else "no combo's reciprocity of record matches", .qname = "reciprocal", .qvalue = if (want) "true" else "false" }) catch return error.OutOfMemory;
        }
        if (cp.len > 0) {
            var found = false;
            var it = idx.agents.iterator();
            while (it.next()) |kv| {
                if (!std.mem.eql(u8, agentSegment(kv.key_ptr.*, view_seg), canonical)) continue;
                const entry_v = kv.value_ptr.*;
                if (entry_v != .object) continue;
                const plats_v = entry_v.object.get("platforms") orelse continue;
                if (plats_v != .array) continue;
                for (plats_v.array.items) |plat| {
                    if (plat == .string and std.mem.eql(u8, plat.string, cp)) found = true;
                }
            }
            checks.append(a, .{ .flag = "--platform", .value = cp, .matched = found, .fact = if (found) "a combo was captured on it" else "no combo was captured on it", .qname = "platform", .qvalue = cp }) catch return error.OutOfMemory;
        }
        if (trimmed_email.len > 0) {
            // an email names ONE agent — its local part is the agent id
            var stripped = trimmed_email;
            if (std.mem.endsWith(u8, stripped, "@local")) stripped = stripped[0 .. stripped.len - "@local".len];
            const entry = idx.agents.get(stripped);
            const has = entry != null and std.mem.eql(u8, agentSegment(stripped, view_seg), canonical);
            checks.append(a, .{ .flag = "--email", .value = trimmed_email, .matched = has, .fact = if (has) "the email's agent carries this dim" else "the email's agent does not carry this dim", .qname = "email", .qvalue = stripped }) catch return error.OutOfMemory;
        }
        // the cross-dim flags: participation in ≥1 combo with that dim
        if (h.len > 0 and kind != .harness) {
            var found = false;
            var it = idx.agents.iterator();
            while (it.next()) |kv| {
                if (!std.mem.eql(u8, agentSegment(kv.key_ptr.*, view_seg), canonical)) continue;
                if (std.mem.eql(u8, agentSegment(kv.key_ptr.*, 0), rh.?)) found = true;
            }
            checks.append(a, .{ .flag = "--harness", .value = h, .matched = found, .fact = if (found) "a combo carries it" else "no combo carries it", .qname = "harness", .qvalue = rh.? }) catch return error.OutOfMemory;
        }
        if (p.len > 0 and kind != .provider) {
            var found = false;
            var it = idx.agents.iterator();
            while (it.next()) |kv| {
                if (!std.mem.eql(u8, agentSegment(kv.key_ptr.*, view_seg), canonical)) continue;
                if (std.mem.eql(u8, agentSegment(kv.key_ptr.*, 1), rp.?)) found = true;
            }
            checks.append(a, .{ .flag = "--provider", .value = p, .matched = found, .fact = if (found) "a combo carries it" else "no combo carries it", .qname = "provider", .qvalue = rp.? }) catch return error.OutOfMemory;
        }
        if (m.len > 0 and kind != .model) {
            var found = false;
            var it = idx.agents.iterator();
            while (it.next()) |kv| {
                if (!std.mem.eql(u8, agentSegment(kv.key_ptr.*, view_seg), canonical)) continue;
                if (std.mem.eql(u8, agentSegment(kv.key_ptr.*, 2), rm.?)) found = true;
            }
            checks.append(a, .{ .flag = "--model", .value = m, .matched = found, .fact = if (found) "a combo carries it" else "no combo carries it", .qname = "model", .qvalue = rm.? }) catch return error.OutOfMemory;
        }
        // the view's own dim flag on a positional view is already a conflict —
        // a matching dim flag here is the flag FORM of the same view, handled above
    }

    for (checks.items) |c| {
        if (!c.matched) all_matched = false;
    }

    if (!all_matched) {
        // stderr — the human report: the resolution, then every filter's state
        writeErr(io, "index: ");
        writeErr(io, id_input);
        writeErr(io, " resolved to ");
        writeErr(io, kind_name);
        writeErr(io, " ");
        writeErr(io, canonical);
        writeErr(io, " — but:\n");
        for (checks.items) |c| {
            writeErr(io, if (c.matched) "  matched " else "  did not match ");
            writeErr(io, c.flag);
            if (c.value.len > 0) {
                writeErr(io, "=");
                writeErr(io, c.value);
            }
            if (c.fact.len > 0) {
                writeErr(io, " (");
                writeErr(io, c.fact);
                writeErr(io, ")");
            }
            writeErr(io, "\n");
        }
        // stdout — the structured match report (the web's 422 body), unless --no-json
        if (!opts.no_json) {
            const q = try entityQueryUrl(a, kind_name, canonical, checks.items);
            const report_root: std.json.Value = .{ .object = blk: {
                var o: std.json.ObjectMap = .empty;
                try o.put(a, "error", .{ .string = "filtered-out" });
                try o.put(a, "entity", .{ .string = kind_name });
                try o.put(a, "input", .{ .string = id_input });
                try o.put(a, "id", .{ .string = canonical });
                var filters: std.json.Array = .init(a);
                for (checks.items) |c| {
                    var f: std.json.ObjectMap = .empty;
                    try f.put(a, "filter", .{ .string = c.flag });
                    try f.put(a, "value", .{ .string = c.value });
                    try f.put(a, "matched", .{ .bool = c.matched });
                    if (c.fact.len > 0) try f.put(a, "fact", .{ .string = c.fact });
                    try filters.append(.{ .object = f });
                }
                try o.put(a, "filters", .{ .array = filters });
                try o.put(a, "unfiltered_url", .{ .string = q });
                break :blk o;
            } };
            const bytes = try std.json.Stringify.valueAlloc(a, report_root, .{ .whitespace = .indent_2 });
            writeOut(io, bytes);
            writeOut(io, "\n");
        }
        return EXIT_FOUND_FILTERED;
    }

    // success — the payload: an agent view prints the agent's facts (the
    // embedded index's projection); a dim view prints the entity's index entry.
    if (!opts.no_json) {
        switch (kind) {
            .agent => {
                const facts = idx.agentFacts(a, canonical).?;
                const seg_h = agentSegment(canonical, 0);
                const seg_p = agentSegment(canonical, 1);
                const seg_m = agentSegment(canonical, 2);
                var o: std.json.ObjectMap = .empty;
                try o.put(a, "agent_id", .{ .string = canonical });
                try o.put(a, "harness", .{ .string = seg_h });
                try o.put(a, "provider", .{ .string = seg_p });
                try o.put(a, "model", .{ .string = seg_m });
                try o.put(a, "email", .{ .string = try std.fmt.allocPrint(a, "{s}@local", .{canonical}) });
                var plats: std.json.Array = .init(a);
                for (facts.platforms) |plat| try plats.append(.{ .string = plat });
                try o.put(a, "platforms", .{ .array = plats });
                try o.put(a, "reciprocal", .{ .bool = facts.reciprocal });
                try o.put(a, "free", .{ .bool = idx.freeHas(seg_p, seg_m) });
                const root: std.json.Value = .{ .object = o };
                const bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
                writeOut(io, bytes);
                writeOut(io, "\n");
            },
            else => {
                const arr = switch (kind) {
                    .harness => idx.harnesses,
                    .provider => idx.providers,
                    .model => idx.models,
                    else => unreachable,
                };
                const entry = index_data.Index.findEntry(arr, canonical) orelse {
                    writeErr(io, "unknown ");
                    writeErr(io, kind_name);
                    writeErr(io, ": ");
                    writeErr(io, canonical);
                    writeErr(io, "\n");
                    return EXIT_MISSING_SPECIFIED_AGENT;
                };
                const bytes = try std.json.Stringify.valueAlloc(a, entry, .{ .whitespace = .indent_2 });
                writeOut(io, bytes);
                writeOut(io, "\n");
            },
        }
    }

    const q = try entityQueryUrl(a, kind_name, canonical, checks.items);
    return openIfWanted(io, a, q, opts);
}

/// the entity view's deep link — the site route `/{kind}/{id}` carrying the
/// MATCHED filters' resolved values (the violating filters stay out: it is the
/// view without them); on success every given filter matched, so all appear.
fn entityQueryUrl(
    a: std.mem.Allocator,
    kind_name: []const u8,
    canonical: []const u8,
    checks: anytype,
) ![]const u8 {
    var q: core.IndexQuery = .{};
    for (checks) |c| {
        if (!c.matched or c.qname.len == 0) continue;
        if (std.mem.eql(u8, c.qname, "harness")) {
            q.harness = c.qvalue;
        } else if (std.mem.eql(u8, c.qname, "provider")) {
            q.provider = c.qvalue;
        } else if (std.mem.eql(u8, c.qname, "model")) {
            q.model = c.qvalue;
        } else if (std.mem.eql(u8, c.qname, "email")) {
            q.email = c.qvalue;
        } else if (std.mem.eql(u8, c.qname, "platform")) {
            q.platform = c.qvalue;
        } else if (std.mem.eql(u8, c.qname, "free")) {
            q.free = std.mem.eql(u8, c.qvalue, "true");
        } else if (std.mem.eql(u8, c.qname, "reciprocal")) {
            q.reciprocal = std.mem.eql(u8, c.qvalue, "true");
        }
    }
    return buildEntityUrl(a, kind_name, canonical, q);
}

/// dispatch the resolved action on a fully-shaped `Detection`.
/// Handles the shared identity-completeness gate (exit 8), the trailer subtypes (co-author / assisted-by), the check-reciprocal tri-state, and the identify data-output semantics (exit 9 on incomplete policy data).
/// The introspection actions are the deliberate exception to the gate: `found` and `explain` emit their payload even when identity is incomplete — observations and reasons are most wanted exactly when detection failed.
fn runAction(init: std.process.Init, d: *const Detection, action: []const u8, trailer_type: []const u8, from_recipe: bool) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    // found — the observation layer: what the ladder saw on this machine (live) or what the rules assert (recipe mode, the declared shape the from-identity fixtures carry).
    // Always emits the block; the exit mirrors the state (8 undetectable / 9 unknown / 0) so wrappers gate on it identically to identify.
    if (std.mem.eql(u8, action, "found")) {
        const raw_v = if (from_recipe) try core.buildDeclaredRaw(a, d) else try core.buildRaw(a, io, d, init.environ_map, d.harness_version, false);
        const json_bytes = try std.json.Stringify.valueAlloc(a, raw_v, .{ .whitespace = .indent_2 });
        writeOut(io, json_bytes);
        writeOut(io, "\n");
        if (d.harness_label == null or d.provider_label == null or d.model_label == null) {
            core.writeUnableToDetect(io, d.harness_id, d.provider_id, d.model_id);
            return EXIT_UNABLE_TO_DETECT;
        }
        if (reciprocityOf(d) == .unknown) {
            writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
            return EXIT_AGENT_DATA_INCOMPLETE;
        }
        return EXIT_OK;
    }

    // explain — the interpretation layer: why the determination resolved as it did, with the remediation actions.
    // Never gated on identity completeness (exit-8 states yield the unmatched/unreadable reasons); the exit mirrors the state (0 / 8 / 9 / 10).
    if (std.mem.eql(u8, action, "explain")) {
        const reasons = try core.reasonsFor(a, d);
        const explain_v = try core.buildExplain(a, d, reasons);
        const json_bytes = try std.json.Stringify.valueAlloc(a, explain_v, .{ .whitespace = .indent_2 });
        writeOut(io, json_bytes);
        writeOut(io, "\n");
        switch (core.explainStateOf(d)) {
            .reciprocal => return EXIT_OK,
            .unknown => {
                writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
                return EXIT_AGENT_DATA_INCOMPLETE;
            },
            .not_reciprocal => {
                writeErr(io, MSG_REQUIREMENT_FAILED);
                return EXIT_REQUIREMENT_FAILED;
            },
            .undetectable => {
                core.writeUnableToDetect(io, d.harness_id, d.provider_id, d.model_id);
                return EXIT_UNABLE_TO_DETECT;
            },
        }
    }

    // identity incomplete → unable to detect: stderr only, no stdout (no sensible data). Applies to every data action.
    // The compact reason lines follow the registry line — which dim stalled and where to look next (`agent-detect explain` carries the full remediation).
    if (d.harness_label == null or d.provider_label == null or d.model_label == null) {
        core.writeUnableToDetect(io, d.harness_id, d.provider_id, d.model_id);
        try core.writeReasonsCompact(a, io, try core.reasonsFor(a, d));
        return EXIT_UNABLE_TO_DETECT;
    }

    if (std.mem.eql(u8, action, "trailer")) {
        // stdout only on success; failures are stderr-only.
        const t = if (std.mem.eql(u8, trailer_type, "assisted-by"))
            (try buildTrailerLine(a, d, "Assisted-by")).?
        else
            d.trailer.?; // "co-author" — already built with "Co-authored-by"
        writeOut(io, t);
        writeOut(io, "\n");
        return EXIT_OK;
    }

    if (std.mem.eql(u8, action, "check-reciprocal")) {
        switch (reciprocityOf(d)) {
            .reciprocal => {
                writeOut(io, core.checkReciprocalVerdict(d).?);
                writeOut(io, "\n");
                return EXIT_OK;
            },
            .not_reciprocal => {
                writeOut(io, "not reciprocal\n");
                writeErr(io, MSG_REQUIREMENT_FAILED);
                try core.writeReasonsCompact(a, io, try core.reasonsFor(a, d));
                return EXIT_REQUIREMENT_FAILED;
            },
            .unknown => {
                // identity resolved, policy data missing: stderr only.
                writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
                try core.writeReasonsCompact(a, io, try core.reasonsFor(a, d));
                return EXIT_AGENT_DATA_INCOMPLETE;
            },
        }
    }

    // identify — the detection report (canonical at root).
    // Data-output action: full report on 0; identity complete but policy data incomplete → the report (with null policy fields) still goes to stdout + a stderr explainer, exit 9.
    var buf: std.ArrayList(u8) = .empty;
    try buildJson(a, d, &buf);
    writeOut(io, buf.items);
    if (reciprocityOf(d) == .unknown) {
        writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
        try core.writeReasonsCompact(a, io, try core.reasonsFor(a, d));
        return EXIT_AGENT_DATA_INCOMPLETE;
    }
    return EXIT_OK;
}
