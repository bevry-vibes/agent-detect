# zig.md

Zig 0.16 working notes for this repo (installed via scoop); AGENTS.md
points here. Everything here is verified against the stdlib shipped
with `zig 0.16.0`.

## Build / test loop

- `zig build` — released binary (`zig-out/bin/agent-detect.exe`,
  `dev=false`).
- `zig build dev` — maintainer binary (`zig-out/bin/agent-detect-dev.exe`,
  `dev=true`, `fixtures` namespace + `raw` action).
- `zig build test` — runs every `src/*_test.zig` / `src/*test*.zig`
  file listed in `build.zig`.
- `zig env` → dumps the environment; `std_dir` gives the stdlib path to
  grep for APIs (e.g. `Get-Content ...\lib\std\Io\Dir.zig | findstr /n
  "fn rename"`).

## APIs that differ from older Zig — verified in 0.16

- **No `std.fmt.fmtSliceHexLower`.** Use
  `std.fmt.bytesToHex(bytes, .lower)` (returns `[len*2]u8`; `.upper`
  also exists).
- **No `std.fs.path.absolute`.** `std.fs.path.resolve` and friends exist;
  for a replace-existing rename use `std.Io.Dir.rename` with relative
  sub-paths (no absolute paths needed):
  ```zig
  std.Io.Dir.rename(std.Io.Dir.cwd(), tmp_sub, std.Io.Dir.cwd(), final_sub, io) catch return error.FilesystemIoError;
  ```
  `Dir.renameAbsolute` requires absolute paths on both sides. The docs
  guarantee rename **replaces an existing target** — that's the atomic
  temp-write + rename pattern for fixture files.
- **`std.Io.Dir.cwd().readFileAlloc(io, sub, a, @enumFromInt(1 << 24))`**
  — the max-bytes argument is an `enum` in 0.16 (`@enumFromInt(...)`),
  not an integer.
- **`std.process.executablePath(io, &buf)`** — takes a
  `std.fs.max_path_bytes` buffer and returns the length (0 on failure),
  not the slice.
- **`std.process.spawn(io, .{ .argv = ..., .environ_map = ...,
  .stdout = .pipe, .stderr = .pipe })`** — child's stdout/stderr are
  `?Io.File`; wire a reader with `file.reader(io, &buf)`. Spawn's argv
  wants a slice of `[]const u8`, not a sentinel-terminated pointer.
- **`std.Io.sleep(io, .{ .nanoseconds = ... }, .boot)`** — sleep takes a
  clock (use `.boot` for elapsed-time semantics).
- **Timestamps:** `std.Io.Clock.Timestamp.now(io, .boot)` /
  `.real`; `ts.raw.nanoseconds` (i96) or `ts.raw.toSeconds()`.
  `Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = ... }, .clock =
  .boot })` builds future deadlines. `std.time.ns_per_s` is the handy
  scalar.
- **`std.crypto.hash.Blake3.hash(bytes, &digest, .{})`** — `digest` is
  `[32]u8`; no packages needed.
- **`std.json.Stringify.valueAlloc(a, value, .{ .whitespace =
  .indent_2 })`** — deterministic pretty serialization. std.json
  **preserves object key insertion order** on parse, so
  re-serializing a parsed object reproduces canonical bytes — which is
  what keeps committed-store diffs stable across writers.
- **Doc comments (`///`) must immediately precede a declaration.**
  A stray `///` where a statement is expected ("expected statement,
  found 'a document comment'") usually means the comment got orphaned
  after a splice/insert.
- **`inline for` cannot contain runtime `continue`.** "comptime control
  flow inside runtime block" — if you need `orelse continue` inside an
  `inline for`, switch to a plain `for`.
- **`Dir.iterate()` iterates that dir's immediate children only.** To
  walk a subdirectory you must open it first:
  `std.Io.Dir.cwd().openDir(io, "fixtures", .{ .iterate = true })` and
  iterate *that*; `cwd().iterate()` will never yield
  `fixtures/*.json` entries.
- **Shelling out to `sqlite3 -json -batch <db> <sql>`** — still used by
  the *released* binary's read-only session-store reads
  (`core.kiloSqliteJson`, kilo/opencode/copilot session DBs only).
  Every result row returns as a JSON array line (even a scalar `PRAGMA`
  setter emits `[{"timeout":N}]`, discardable). The dev fixtures store
  no longer uses sqlite at all — it is the local `fixtures/index.json`.
- **`std.Io.File.lock` / `tryLock`** — `file.lock(io, .exclusive)` /
  `file.tryLock(io, .exclusive)` (returns `bool`; `LockError`).
  Kernel-managed: the lock releases when the process exits/crashes —
  no stale-lock heuristics. The dev store locks
  `fixtures/index.json.lock` (lock the lock file, never the data file),
  retries `tryLock` every 50ms on a ~5s budget, then mutates the
  parsed tree and writes atomically (serialize → `index.json.tmp` →
  `rename` over `index.json` — rename replaces an existing target).
  Readers take no lock: temp+rename makes visibility atomic.

## Patterns this repo uses

- `optStringValue(a, opt)` — render optional strings as a JSON string or
  `null`.
- `jstr`/`jint` (core) pull typed fields out of a `std.json.ObjectMap`
  without panicking (return `?[]const u8` / `?i64`); dev's
  `sjstr`/`sjint` are thin wrappers over them (missing → `""`/`0`),
  and dev's `jbool` does the same for booleans.
- `@intFromBool`, `@as(usize, ...)`, `@intCast` — the usual coercions;
  optional fields read as `row.x.?` after a `!= null` guard.
- The index.json store: `std.json.Value` trees, loaded with
  `std.json.parseFromSlice` and written with
  `std.json.Stringify.valueAlloc(a, value, .{ .whitespace =
  .indent_2 })`. Hand-editing `fixtures/index.json` is fine — the
  shape tests re-verify it (`zig build test`); the fixture-file
  envelope tests scan the per-channel folders.
- Windows process control uses direct `pub extern "kernel32"` declarations
  (`GetProcessId`, `OpenProcess`, `TerminateProcess`, `CloseHandle`) at
  the top of `src/lib/core.zig` — dev aliases them via `core.*`.
- The split is a strict import DAG with no cycles:
  `src/lib/rules.zig` (rule tables + pure name resolution; imports only
  `std`/`builtin`) ← `src/lib/core.zig` (ladder + policy) ←
  `src/dev/dev.zig` (the `pub const dev =
  if (build_options.dev) struct {...} else struct {}` gate lives here —
  compiled out of released builds at the type level; it is the ONLY
  file that may reference `fixtures/index.json`) ← `src/main.zig`
  (thin entry + `main.*` re-exports the test-facing names).
- `readChildOutput(a, io, child, comptime stderr)` — the one
  child-stdout/stderr drain loop (stderr bounded at 64 KiB); callers
  still own `child.wait`.

## Gotchas

- Building the dev binary needs its own `build_options` module with
  `dev=true` hardcoded (`build.zig`), separate from the CLI `-Ddev`
  flag plumbing.
- Tests run in `ReleaseSmall` (see `build.zig`) — a test that only
  passes in Debug modes will bite you; keep asserts structural
  (expect/print), not timing-based.
- **Never free an arena slice that a returned value aliases.** The
  arena free-list only recycles the most-recent allocation; freeing a
  slice that a returned `std.json.Value` (or a `?[]const u8` view into
  the parsed tree) aliases lets the caller's next allocations reclaim
  and clobber the bytes mid-use. `readChannelObject` / `indexLoad`
  callers must not free the parsed buffer while derived values live.
- **Mutate `std.json` maps through pointers, not copies.** `ObjectMap`
  stores its internal header pointer by value — `map.get(key)` returns
  a *copy*. Mutating that copy (e.g. `swapRemove`) updates the copy's
  pointer field while the stored map still points at the freed header
  (dangling read on the next `get`). Use `getPtr(key)` for mutations
  (see `errorsClearPure` in `src/dev/dev.zig`).
