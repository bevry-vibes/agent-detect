# `known daemon --agent-observe` — tee daemon output to `known/daemon.log`

## Context

The `known daemon` (dev-only) writes all diagnostics through two module-level helpers, `daemonWrite` (stdout) and `daemonWriteErr` (stderr), each prefixing a `[{sec}.{ms}] ` timestamp (src/main.zig:451-469). Every daemon log line flows through these two functions: the startup banner, poll/idle lines, seed-expansion results, warn-and-keep warnings, recipe warnings, `buildEnv`/spawn/child errors, and the captured child stderr. The released binary never calls them (they are already unreferenced there and compile fine).

Goal: `agent-detection-dev known daemon --write-log` runs the daemon unchanged but also appends every stdout+stderr line to `known/daemon.log`, so an agent (or user) can `Read`/`tail -f` the file instead of the user copy-pasting terminal output. Semantics: equivalent to `known daemon |& tee known/daemon.log` (console + file, file truncated at start of each run). The `--write-log` flag does **not** bypass `assertNotInAgent` — the daemon stays user-only; write-log just records its output for later inspection.

## Decisions

1. **Tee at the two write helpers**, not an `Io` swap or process redirection: a module-level `var daemon_log_file: ?std.Io.File = null;` that `daemonWrite`/`daemonWriteErr` also write `prefix + bytes` to when set. Minimal, captures all existing call sites (no signature churn), and matches "pipe stdout and stderr" since both helpers tee to the same file.
2. **Truncate per run** (not append): `createFile(io, "known/daemon.log", .{})` uses the default `truncate = true` (std/Io/Dir.zig:586-591), matching `tee` (no `-a`). Each daemon start begins a fresh log.
3. **Open the log before `assertNotInAgent`** so even a guard refusal is observable in the file; a failed open (missing `known/`, permissions) is an error → stderr message + exit 2, daemon does not start unobserved.
4. **File path** is fixed: `known/daemon.log` (cwd-relative, same as `known/index.jsonl`). Already covered by `**/*.log` in `.gitignore` — no gitignore change.
5. **Flag name** is `--write-log` (no `--agent-observe` alias). It does **not** bypass the user-only guard; no other behavioral change to the daemon loop, `expandSeed`, `runOneCombo`, `enqueuePending`, or `assertNotInAgent`.

## Tasks

### Task 1 — module-level log handle + tee in the two helpers
Near src/main.zig:449 (just above `fn daemonWrite`), add:

```zig
/// optional tee target for daemon output; set by `known daemon --write-log`.
var daemon_log_file: ?std.Io.File = null;
```

In `daemonWrite` (line 451): after building `prefix` and writing to stdout, write `prefix` then `bytes` to `daemon_log_file` when non-null:

```zig
if (daemon_log_file) |f| {
    f.writeStreamingAll(io, prefix) catch {};
    f.writeStreamingAll(io, bytes) catch {};
}
```

Mirror the identical block in `daemonWriteErr` (line 461). Both builds compile this var/block; the released build never sets it so it is a no-op there (same pattern as the pre-existing unreferenced helpers).

### Task 2 — parse `--write-log` and open the log in `runKnownDaemon`
In `runKnownDaemon` (src/main.zig:~3726):

1. Before `assertNotInAgent(a, init)`, scan argv:
   ```zig
   var write_log = false;
   var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return 1;
   defer args_it.deinit();
   _ = args_it.skip(); // argv0
   _ = args_it.skip(); // "known"
   _ = args_it.skip(); // "daemon"
   while (args_it.next()) |arg| {
       if (std.mem.eql(u8, arg, "--write-log")) write_log = true;
   }
   ```
   Unknown extra args are ignored (consistent with the rest of the `known` namespace).
2. If `write_log`:
   - `std.Io.Dir.cwd().createDirPath(io, "known") catch |err| switch (err) { error.PathAlreadyExists => {}, else => return err, };` (same pattern as `runKnownAgent` line ~3036).
   - `const log_file = std.Io.Dir.cwd().createFile(io, "known/daemon.log", .{}) catch |err| { daemonWriteErr(io, "daemon: cannot open known/daemon.log: "); daemonWriteErr(io, @errorName(err)); daemonWriteErr(io, "\n"); return 2; };`
   - `daemon_log_file = log_file;`
   - `defer { daemon_log_file.?.close(io); daemon_log_file = null; }` (place this defer right after assignment so the file closes on any exit, including Ctrl+C signal path).
3. Optionally add one banner line after the existing startup block (line 3737) when observing: `daemonWrite(io, "  log file: known/daemon.log\n");` — rendered by `daemonWrite`, so it lands in the log too.

### Task 3 — usage text
In `dev.knownUsage` (src/main.zig:~2027), update the daemon subcommand line:

```
  daemon                     watch known/index.jsonl and capture
                              refresh:true events (poll 5s) — run
                              as a user, never inside an agent;
                              --write-log also writes all daemon
                              output to known/daemon.log
```

## Validation

1. `zig build dev` and `zig build` (released) both green; `zig build test` still green.
2. Manual (user terminal, since the daemon refuses to run inside an agent):
   - `./zig-out/bin/agent-detection-dev known daemon --write-log`
   - Confirm `known/daemon.log` exists, starts with the timestamped banner, and gains lines each 5s poll (`daemon: idle, queue empty, sleeping 5s`) and on queue/seed activity.
   - Confirm the terminal still shows the same output (console telemetry preserved — tee, not redirect).
   - For the observability win: have the observing agent `Read` `known/daemon.log` (e.g. during a seed-expansion test with `known queue --harness=crush --no-...`), without the user pasting terminal text.
   - Restart the daemon and confirm the log is truncated (not appended).
   - `known daemon` (no flag) writes no log file / leaves any existing file untouched.
3. Confirm `git status` shows `known/daemon.log` untracked-ignored (no change to `.gitignore`).

## Status: IMPLEMENTED + VALIDATED

- Tasks 1-3 done; `zig build`, `zig build dev`, `zig build test` all green.
- Bug found + fixed during validation: the original `defer { daemon_log_file.?.close(io); daemon_log_file = null; }` was placed INSIDE the `if (write_log) {}` block, so it ran at the end of that block — closing the file and nulling the global before `assertNotInAgent` ever wrote the refusal (log stayed 0 bytes). Fix: hoist an owned-handle var (`var daemon_log_file_owned: ?std.Io.File`), assign it alongside the global, and put a function-scope `defer { if (daemon_log_file_owned) |f| f.close(io); daemon_log_file = null; }` after the `if` block. Diagnosed via a zig 0.16 probe showing `writeStreamingAll`+close works on its own and a `std.debug.print` pair proving global-null at refusal time.
- Guard-refusal validation (agent env): `./agent-detection-dev known daemon --write-log` → refusal text (184 bytes) now lands in `known/daemon.log`; stderr unchanged. Restart truncates (still 184 bytes, not doubled). No-flag run leaves an existing `known/daemon.log` untouched (mtime/size preserved). `git check-ignore` confirms `known/daemon.log` ignored (explicit rule also added to `.gitignore` at line ~64, matches `**/*.log`).
- Remaining: user-side run of a live daemon with `--write-log` (agent guard prevents executing it here) to confirm banner + per-poll lines accumulate in the file over a real session.

## Notes / risks

- The module-level `var` is safe single-threaded: `runKnownDaemon` is the only concurrent writer of these helpers, and it holds the single file handle for its lifetime.
- If the log open fails, the daemon refuses to start (exit 2) rather than running unobserved — by design.
- Truncate-per-run means history is intentionally lost between restarts; if accumulation is ever wanted, switch `createFile(..., .{ .truncate = false })` — out of scope.
