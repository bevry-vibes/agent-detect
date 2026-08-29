# Build timestamp via `build_options` (dev-only), semver `+<sec>.<ms>` metadata

## Context

`agent-detection` uses **CalVer**: `build.zig.zon` `.version = "<year>.<month>.<day>-<revision>"` (e.g. `2026.8.6-1`). Read once by `readVersionFromZon` (`build.zig:145`, uses `b.graph.io`), injected as `build_options.version` (`[]const u8`) via a shared options module:

- native default `zig build` — shared `build_options` (`build.zig:49-51`)
- `zig build dev` — its **own** `dev_options` module (`build.zig:77-79`)
- `zig build dist` — shared `build_options` (`build.zig:122-137`); `test` too (`build.zig:114`)

`version` outputs at `src/main.zig:4330-4339`; daemon startup "intro" banner at `src/main.zig:3853-3857` (`known daemon`, dev-only).

**Release invariant (must keep):** pushed tag == `build.zig.zon` `.version` == GitHub release name, matching `tags: ['*.*.*-*']` in `.github/workflows/build.yml:10`. `release` job (`build.yml:74-108`) uses `${{ github.ref_name }}`. `nightly` uses a fixed tag. So `dist` (the release artifacts) must print exactly the clean CalVer.

Timestamps in this codebase: daemon log prefix is `[{sec}.{ms}]` via `std.Io.Clock.Timestamp.now(io, .real)` (`main.zig:464-467`), where `Io.Timestamp = { nanoseconds: i96 }` with `toSeconds()/toMilliseconds()`.

## Goal

Surface a per-build UTC timestamp (epoch `<sec>.<ms>`) with `--version` and in the daemon header, **without** polluting the version number. Decided design: keep `version` clean CalVer everywhere; add a **separate** `build_timestamp` build option; display as semver build metadata `2026.8.7-1+1786047083.463`.

## Decisions

1. **Mechanism:** `build_options.version` stays `""`-clean CalVer in **all** targets (never polluted). Add a second, independent option `build_options.build_timestamp` (`i64`, epoch **nanoseconds**).
2. **Where the timestamp comes from:** `build.zig` samples the wall clock at configure time with **the same call the daemon uses** — `std.Io.Clock.Timestamp.now(b.graph.io, .real)` — once, and bakes it via the options module. No subprocess, no `date`, pure UTC, real ms. (Comptime can't do this: `builtin` carries only deterministic toolchain metadata; a wall clock is non-reproducible, so it must be build-injected. `build_options` is Zig's idiomatic injection mechanism.)
3. **Scope — dev only (forced by the release invariant).** Only the dev binary carries a nonzero `build_timestamp`. Because `dist` must print the exact tag-matching CalVer, it and native `test` use a module with `build_timestamp = 0`. Native default `zig build` also keeps `0` so it stays cached, reproducible, and clean. Only `zig build dev` recompiles per build (timestamp varies → cache-key change) — this is the accepted trade-off and matches the dev-only daemon.
4. **Display format (chosen):** semver build metadata — append `+<sec>.<ms>` to the version: `2026.8.7-1+1786047083.463`. In `--version` and the daemon header. When `build_timestamp == 0` (native/dist/test), print just `2026.8.7-1`.

## Implementation

`zig build` states:
- `build_options` (clean): `version = <zon>`, `build_timestamp = 0` → native, dist, test. Unchanged value; stable/cached.
- `dev_options`: `version = <zon>`, `build_timestamp = <epoch-ns>` → dev only.

Tasks:

1. **`build.zig` — add timestamp helper:**
   ```zig
   fn buildTimestampNs(b: *std.Build) i64 {
       const ts = std.Io.Clock.Timestamp.now(b.graph.io, .real);
       return @intCast(ts.raw.nanoseconds); // i96→i64; epoch-ns fits until ~2262
   }
   ```
2. **`build.zig` — options wiring:** add `build_timestamp` to both modules:
   - `build_options.addOption(i64, "build_timestamp", 0);` (clean; used by native, dist, test)
   - `dev_options.addOption(i64, "build_timestamp", buildTimestampNs(b));` (dev)
   - Keep `version` (clean CalVer) identical in both.
3. **`src/main.zig` — expose + format in `version` action (`~4330-4339`):**
   - Read `build_options.build_timestamp`.
   - If `!= 0`: `sec = ns / std.time.ns_per_s; ms = (ns % std.time.ns_per_s) / std.time.ns_per_ms;` then print `agent-detection <version>+<sec>.<ms>`.
   - Else: print `agent-detection <version>` (unchanged).
   - (sec/ms math mirrors daemon `main.zig:465-466`.)
4. **`src/main.zig` — daemon intro (`~3853-3857`):** add a build line showing version + timestamp, e.g. `daemonWrite(io, "  build: <version>+<sec>.<ms>\n");` (no build timestamp when device is 0 / dev always has it).
5. **`src/main.zig` — update comment at `:4331-4334`**: dev appends a build timestamp while native/dist print clean CalVer.
6. **`CONTRIBUTING.md`** release-channels/runbook: note `zig build dev` self-identifies with `+<sec>.<ms>` build metadata; `zig build`/`zig build dist`/tags/`latest`/`nightly` print clean CalVer and are unaffected.

## Validation

- `zig build dist --prefix . && ./bin/agent-detection-linux-x86_64 --version` → clean `agent-detection <zon>` (unchanged; tag-matching).
- `zig build` (native) → clean `agent-detection <zon>`; repeated builds stay cached (no rebuild), `--version` unchanged.
- `zig build dev` → `agent-detection <zon>+<sec>.<ms>`; run twice → different suffix; dev recompiles each build (accepted).
- `zig build dev known daemon` → daemon intro shows the `build:` line with version `+<sec>.<ms>`; each log prefix still `[{sec}.{ms}]`.
- Push a `*.*.*-*` tag → `release` job matches; tag == dist `--version` (invariant holds).
- `zig build test` passes.

## Risks / open decisions

- **Dev recompiles every `zig build dev`** (time-varying value in the options-module cache key). Accepted; scoped to dev so native/dist/test caching is preserved.
- **`i64` epoch-ns range** is fine until ~2262; adequate for the foreseeable future.
- **Sub-ms collision:** two dev builds within the same wall-clock nanosecond share a suffix — negligible at ms resolution.
- **Zon date vs build moment mismatch:** version base is the zon CalVer; the `+<sec>` suffix is the actual dev build instant. Near midnight these differ by a day. Harmless (identity, not ordering).
- **No comptime/builtin alternative:** `builtin` exposes only deterministic toolchain metadata; wall-clock must be build-injected. Confirmed `build_options` is the idiomatic way; `@embedFile`-of-generated-file is an equivalent alternative not chosen (more manual, same cache cost).
- **Scope is dev-only.** If the maintainer later wants the timestamp on the native default `zig build` too, set its `build_timestamp` at `build.zig:51` from `buildTimestampNs(b)`; cost is native recompile-per-build and a non-tag-matching local version.
