// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

// agent-detect — thin entry point + re-exports. The released CLI surface
// (identify / trailer / check-reciprocal / help / version) dispatches into
// lib/core.zig; the dev binary additionally exposes dev/dev.zig's `fixtures`
// namespace + `raw` action when built with `-Ddev=true`. The re-exported
// aliases below keep the test files compiling through `main.*` unchanged.

const std = @import("std");
const build_options = @import("build_options");
const core = @import("lib/core.zig");
const rules = @import("lib/rules.zig");
const devmod = @import("dev/dev.zig");

pub const dev_build = build_options.dev;
pub const dev = devmod.dev;

const writeOut = core.writeOut;
const writeErr = core.writeErr;
const usage = core.usage;
const trailerUsage = core.trailerUsage;

const resolveRecipe = core.resolveRecipe;
const detect = core.detect;
const buildJson = core.buildJson;

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

// --- re-exports (tests compile through `main.*`)

pub const Detection = core.Detection;
pub const Reciprocity = core.Reciprocity;
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

pub fn buildTrailerLine(a: std.mem.Allocator, d: *const Detection, keyword: []const u8) !?[]u8 {
    return core.buildTrailerLine(a, d, keyword);
}

pub fn modelFromMessageData(a: std.mem.Allocator, data: []const u8) !?core.ActiveSessionModel {
    return core.modelFromMessageData(a, data);
}

pub fn modelFromSessionRow(a: std.mem.Allocator, model_str: []const u8) !?core.ActiveSessionModel {
    return core.modelFromSessionRow(a, model_str);
}

/// decision #8 — the dev binary's top-level help: the released usage
/// plus a dev-actions block referencing the fixtures namespace, the
/// two refresh modes, and the daemon pacing/control flags. The
/// released `agent-detect --help` is `usage` alone.
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
        \\  fixtures queue    upsert queue rows [scope flags] [--from-identity|--from-capture]
        \\  fixtures dequeue  DELETE matching queue rows [--from-identity|--from-capture]
        \\  fixtures help     the fixtures namespace's full help
        \\  raw               print only the raw observations block
        \\
else
    usage;

// ============================================================================
// main entry

/// is `word` one of the known top-level action words?
fn isKnownAction(word: []const u8) bool {
    return std.mem.eql(u8, word, "identify") or
        std.mem.eql(u8, word, "trailer") or
        std.mem.eql(u8, word, "check-reciprocal") or
        std.mem.eql(u8, word, "help") or
        std.mem.eql(u8, word, "version");
}

pub fn main(init: std.process.Init) u8 {
    return mainInner(init) catch |err| switch (err) {
        error.OutOfMemory => EXIT_OUT_OF_MEMORY,
        else => blk: {
            // dev-only error kinds — pruned from the released binary.
            // Each writes its registry-name message to stderr (matching
            // the "exact message verbage" scheme) plus its exit code.
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

    // subcommand dispatch. The dev binary (built with -Ddev=true)
    // accepts a `raw` action (standalone raw block) plus a `fixtures`
    // subcommand namespace: `fixtures --help`, `fixtures daemon`,
    // `fixtures capture`, `fixtures queue [--harness=...]
    // [--provider=...] [--model=...]`, `fixtures queue --recipes`,
    // `fixtures dequeue`. The
    // `raw`/`fixtures` dispatch is compiled out of the
    // released binary (dev_build is false) — the released and dev
    // binaries both run the action parser below: `identify`, `trailer`,
    // `check-reciprocal`, `help`, `version` (with no arguments showing
    // help).
    if (dev_build) {
        var sub_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return error.OutOfMemory;
        defer sub_iter.deinit();
        _ = sub_iter.skip(); // argv0
        const cmd = sub_iter.next() orelse "";
        const sub = sub_iter.next() orelse "";
        // decision #8 — the dev binary's top-level help (bare no-args,
        // `help`, `--help`, `-h`) shows the FULL dev surface: the
        // released usage plus the dev actions section. `agent-detect
        // --help` (released binary) is unchanged.
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
        } else if (std.mem.eql(u8, cmd, "raw")) {
            return dev.runRawAction(init);
        }
    }

    // action parser. The canonical spellings are the bare words
    // `identify`, `trailer` (with a subtype), `check-reciprocal`, `help`,
    // and `version`; the `--help`/`-h` and `--version`/`-V` forms are
    // aliases. No arguments prints help. `identify`, `trailer <type>`,
    // and `check-reciprocal` accept an optional complete combo
    // (`--harness=H --provider=P --model=M` — all three or none) for
    // recipe-mode output. help/version win over everything: any
    // help/version flag anywhere at top level short-circuits to the
    // relevant usage/version output (exit 0), never a conflict.
    var action: []const u8 = ""; // "", "identify", "trailer", "check-reciprocal", "help", "version"
    var trailer_type: []const u8 = ""; // "", "co-author", "assisted-by"
    var help_wanted = false;
    var version_wanted = false;
    var help_topic: ?[]const u8 = null; // the word following `help` (`help trailer`)
    var unknown: ?[]const u8 = null; // first unrecognised bare word (no action set yet)
    var conflict: ?[]const u8 = null; // a second, different action/subtype word
    var combo_h: []const u8 = "";
    var combo_p: []const u8 = "";
    var combo_m: []const u8 = "";
    var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return error.OutOfMemory;
    defer args_it.deinit();
    _ = args_it.skip(); // argv0
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_wanted = true;
            if (action.len == 0) action = "help";
        } else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            version_wanted = true;
        } else if (std.mem.eql(u8, arg, "identify") or std.mem.eql(u8, arg, "trailer") or std.mem.eql(u8, arg, "check-reciprocal")) {
            // an action word. After `help` it is the topic (`help trailer`).
            if (action.len == 0) {
                action = arg;
            } else if (std.mem.eql(u8, action, "help") and help_topic == null) {
                help_topic = arg;
            } else if (!std.mem.eql(u8, action, arg) and conflict == null) {
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
        } else {
            // unrecognised bare word / flag.
            if (std.mem.eql(u8, action, "help") and help_topic == null) {
                help_topic = arg; // `help <topic>`
            } else if (action.len == 0) {
                if (unknown == null) unknown = arg;
            } else if (conflict == null) {
                conflict = arg;
            }
        }
    }

    // version wins over everything.
    if (version_wanted) {
        // Version is plumbed in at compile time from
        // `build.zig.zon`'s `.version` field via `build_options`.
        // Same value is baked into the released binary, the dev
        // binary, and every `zig build dist` cross-compile target.
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
        if (help_topic) |topic| {
            if (std.mem.eql(u8, topic, "trailer")) {
                writeOut(io, trailerUsage);
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

    // an unrecognised action word (a bare word appeared before any
    // known action, e.g. `foobar`, `--bogus`, `foobar identify`).
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

    // bare `trailer` → missing required arguments (subtype absent).
    if (std.mem.eql(u8, action, "trailer") and trailer_type.len == 0) {
        writeErr(io, MSG_MISSING_ARG_TRAILER_SUBTYPE);
        writeOut(io, trailerUsage);
        return EXIT_MISSING_ARG;
    }

    // recipe mode: a complete combo resolves against the rule tables,
    // skipping live detection. Partial combos are rejected (exit 4);
    // an unknown combo is exit 7.
    const has_combo = combo_h.len > 0 or combo_p.len > 0 or combo_m.len > 0;
    if (has_combo) {
        if (combo_h.len == 0 or combo_p.len == 0 or combo_m.len == 0) {
            writeErr(io, MSG_MISSING_ARG_COMBO);
            writeOut(io, usage);
            return EXIT_MISSING_ARG;
        }
        const d = (try resolveRecipe(a, combo_h, combo_p, combo_m)) orelse {
            // report which dims resolved (strict slug id) and which did
            // not (null) so the unknown dim is visible at a glance.
            core.writeMissingSpecifiedAgent(io, rules.canonicalFilterDim(a, rules.HarnessRule, &rules.rulesForHarnesses, combo_h), rules.canonicalFilterDim(a, rules.ProviderRule, &rules.rulesForProviders, combo_p), rules.canonicalFilterDim(a, rules.ModelRule, &rules.rulesForModels, combo_m));
            return EXIT_MISSING_SPECIFIED_AGENT;
        };
        return runAction(init, &d, action, trailer_type);
    }

    // live detection.
    var d = Detection{};
    _ = try detect(init, &d);
    return runAction(init, &d, action, trailer_type);
}

/// dispatch the resolved action on a fully-shaped `Detection`. Handles
/// the shared identity-completeness gate (exit 8), the trailer subtypes
/// (co-author / assisted-by), the check-reciprocal tri-state, and the
/// identify/raw data-output semantics (exit 9 on incomplete policy data).
fn runAction(init: std.process.Init, d: *const Detection, action: []const u8, trailer_type: []const u8) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    // identity incomplete → unable to detect: stderr only, no stdout
    // (no sensible data). Applies to every action.
    if (d.harness_label == null or d.provider_label == null or d.model_label == null) {
        core.writeUnableToDetect(io, d.harness_id, d.provider_id, d.model_id);
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
                writeOut(io, "is reciprocal\n");
                return EXIT_OK;
            },
            .not_reciprocal => {
                writeOut(io, "not reciprocal\n");
                writeErr(io, MSG_REQUIREMENT_FAILED);
                return EXIT_REQUIREMENT_FAILED;
            },
            .unknown => {
                // identity resolved, policy data missing: stderr only.
                writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
                return EXIT_AGENT_DATA_INCOMPLETE;
            },
        }
    }

    // identify — the detection report (canonical at root). Data-output
    // action: full report on 0; identity complete but policy data
    // incomplete → the report (with null policy fields) still goes to
    // stdout + a stderr explainer, exit 9.
    var buf: std.ArrayList(u8) = .empty;
    try buildJson(a, d, init.environ_map, null, .{}, &buf);
    writeOut(io, buf.items);
    if (reciprocityOf(d) == .unknown) {
        writeErr(io, MSG_AGENT_DATA_INCOMPLETE);
        return EXIT_AGENT_DATA_INCOMPLETE;
    }
    return EXIT_OK;
}
