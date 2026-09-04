# zig.md

Local application of the bevry-vibes skills [zig.md](https://github.com/bevry-vibes/skills/blob/main/zig.md) —
see the upstream [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

## this project's tweaks

### Build / test loop

- `zig build` — released binary (`zig-out/bin/agent-detect`,
  `dev=false`).
- `zig build dev` — maintainer binary (`zig-out/bin/agent-detect-dev`,
  `dev=true`, `fixtures` namespace + `raw` action).
- `zig build test` — runs every `src/*_test.zig` / `src/*test*.zig`
  file listed in `build.zig`.
- The released binary still shells out to `sqlite3 -json -batch` for
  its read-only session-store reads (`core.kiloSqliteJson`,
  kilo/opencode/copilot session DBs only); the CLI behavior patterns
  live in the upstream powershell skill. The dev fixtures store is the
  local `fixtures/index.json` — no sqlite.

### Patterns this repo uses

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

### Gotchas

- Building the dev binary needs its own `build_options` module with
  `dev=true` hardcoded (`build.zig`), separate from the CLI `-Ddev`
  flag plumbing.
- Tests run in `ReleaseSmall` (see `build.zig`) — keep asserts
  structural (expect/print), not timing-based.
- The `/proc` pseudo-file read rule lives upstream; this repo's
  implementation is `readProcFile` in `src/lib/core.zig` (buffered
  reader, `readSliceShort`).
- The arena-aliasing free rule lives upstream; here it bites
  `readChannelObject` / `indexLoad` callers — do not free the parsed
  buffer while derived values live.
- The json-map `getPtr` mutation rule lives upstream; see
  `errorsClearPure` in `src/dev/dev.zig` for this repo's use.
