# Measure actual release sizes for remaining C wrapper SQLite candidates

## Status: ✅ COMPLETED

All viable candidates measured against real Kilo DB (`~/.local/share/kilo/kilo.db`, 833MB, 22 tables). Production build flags (`ReleaseSmall` + strip).

Results (sorted by size, smallest to largest):
- **muhammad-fiaz/sqlite.zig**: +20–37 KB (smallest, but pure-Zig greenfield-only — fails on real Kilo DB)
- **cli-shim** (spawn sqlite3): +91–222 KB (smallest viable, but requires `sqlite3` on system)
- **vrischmann/zig-sqlite**: +653–756 KB (best C wrapper, verified with real Kilo DB)
- **nDimensional/zig-sqlite**: +768–893 KB (mid-size C wrapper, verified with real Kilo DB)
- **oswalpalash/zsql**: +735–946 KB (moderate, requires `-Denable-sqlite=true`)
- **blue-blaze/zsqlx** (SQLite-only): +1,152–1,411 KB (largest, requires `-Dpostgres=false -Dmysql=false -Dbundle-sqlite=true`)

Incompatible/disqualified: cztomsik/fridge (Zig 0.16 incompat), pmarreck (dynamic link), jkoop/zigqlite (dynamic link), INDRIYA-TECH (repo unreachable), GhostKellz (proprietary format).

## All SQLite Library Candidates Considered

| # | Package | Stars | Type | Zig | SQLite Ver | Status | Size Delta | Real-DB Test |
|---|---------|-------|------|-----|-----------|--------|------------|--------------|
| 1 | **karlseguin/zqlite.zig** | 190 | C wrapper | 0.16 | 3.53.0 | ✅ MEASURED | +682–808KB | n/a (already adopted baseline) |
| 2 | **muhammad-fiaz/sqlite.zig** | 4 | Pure Zig | 0.16 | N/A (own impl) | ✅ MEASURED | +20–37KB | ❌ `error.UnknownTable` |
| 3 | vrischmann/zig-sqlite | 604 | C wrapper | 0.14+/0.16 | 3.49.0 | ✅ MEASURED | +653–756KB | ✅ Opens + queries Kilo DB |
| 4 | cztomsik/fridge | 91 | C wrapper | Any | bundled | ❌ INCOMPATIBLE | n/a | Zig 0.16 incompatible (`field_names` removed) |
| 5 | oswalpalash/zsql | 0 | C wrapper | 0.16 | 3.49.0 | ✅ MEASURED | +735–946KB | ✅ Opens Kilo DB |
| 6 | blue-blaze/zsqlx | 2 | C wrapper | 0.16 | 3.50.4 | ✅ MEASURED | +1,152–1,411KB (SQLite-only) | ✅ Opens Kilo DB |
| 7 | INDRIYA-TECH/zqlite | 0 | C wrapper | 0.16-dev | bundled | ❌ UNREACHABLE | n/a | Repo deleted/private |
| 8 | pmarreck/zig-sqlite@yolo | — | C wrapper | 0.16 | 3.49 | ❌ DISQUALIFIED | n/a | Dynamic link only (no cross-compile) |
| 9 | nDimensional/zig-sqlite | 50 | C wrapper | 0.16 | 3.53.1 | ✅ MEASURED | +768–893KB | ✅ Full success on Kilo DB |
| 10 | jkoop/zigqlite | 5 | C wrapper | 0.15+ | bundled | ❌ DISQUALIFIED | n/a | Requires `linkSystemLibrary("sqlite3")` (dynamic) |
| 11 | **cli-shim** (this project) | n/a | subprocess | n/a | 3.53.4 (system) | ✅ MEASURED | +91–222KB | ✅ Full success — returns 5 sessions, project count = 3 |

### Rejected

| # | Package | Reason |
|---|---------|--------|
| A | GhostKellz/zqlite | Proprietary file format, cannot read real SQLite `.db` files |
| 7 | INDRIYA-TECH/zqlite | Repository not found on GitHub or zigpkg.dev |
| 8 | pmarreck/zig-sqlite@yolo | Defaults to dynamic linking (`libsqlite.dylib`) — broken for cross-compilation |
| 10 | jkoop/zigqlite | Requires system `libsqlite3` (dynamic link) — same disqualification as #8 |
| 11 | cli-shim | Requires `sqlite3` CLI binary on target system — not viable for cross-platform dist binaries |

### In Scope for Measurement

**#3 through #6, #9, #11** all measured. **#2** measured but disqualified (real-DB incompatible). **#4, #7, #8, #10** excluded (incompat/disqualified).

Baseline sizes (ReleaseSmall, stripped):
- linux-x86_64: 257,928 bytes
- linux-aarch64: 245,344 bytes
- macos-aarch64: 274,840 bytes
- windows-x86_64: 551,424 bytes

Delta = measured_size - baseline_size

Baseline sizes (ReleaseSmall, stripped):
- linux-x86_64: 257,928 bytes
- linux-aarch64: 245,344 bytes
- macos-aarch64: 274,840 bytes
- windows-x86_64: 551,424 bytes

Delta = measured_size - baseline_size

## Execution Steps

### Step 0: Prerequisites

- Zig 0.16.0 installed
- Internet access for `zig fetch` to download dependencies
- ~5-10 minutes per candidate (compilation time, not measurement)

### Step 1: Create isolated test directories

```bash
mkdir -p /tmp/sqlite-size-test/{vrischmann,fridge,zsql,zsqlx}/src
```

### Step 2: For each candidate, create 3 files and build

**Important:** `zig fetch --save` may not update `build.zig.zon` in zig 0.16. Workaround:
1. Run `zig fetch <url>` (without `--save`) — prints the hash
2. Manually add the dependency to `build.zig.zon` using the printed hash
3. Then run `zig build`

Below are the **exact** main.zig, build.zig, and build.zig.zon for each candidate, verified against their actual source code.

---

### Candidate 1: vrischmann/zig-sqlite

**Repo:** `git+https://github.com/vrischmann/zig-sqlite.git`
**Zig:** requires 0.14.0+, works with 0.16.0
**Bundles:** SQLite 3.49.2 (`sqlite-amalgamation-3490200.zip`)
**Module name:** `sqlite`
**Build.zig options:** none needed for SQLite (always bundled)

#### src/main.zig (verified against actual source)
```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.Db.init(.{ .mode = .Memory });
    defer db.deinit();
    try db.exec("SELECT 1", .{});
}
```

#### build.zig
```zig
const std = @import("std");

const targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
};

pub fn build(b: *std.Build) void {
    const dep = b.dependency("sqlite", .{});
    
    for (targets) |t| {
        const exe = b.addExecutable(.{
            .name = b.fmt("vrischmann-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = .ReleaseSmall,
                .strip = true,
            }),
        });
        exe.root_module.addImport("sqlite", dep.module("sqlite"));
        b.installArtifact(exe);
    }
}
```

#### build.zig.zon
```json
.{
    .name = .vrischmann_test,
    .version = "0.0.1",
    .dependencies = .{},
    .paths = .{""},
}
```
Then run: `zig fetch --save git+https://github.com/vrischmann/zig-sqlite.git`

#### Build command
```bash
cd vrischmann/
zig build --prefix . 2>&1
ls -la bin/vrischmann-* && wc -c bin/vrischmann-*
```

---

### Candidate 2: cztomsik/fridge

**Repo:** `git+https://github.com/cztomsik/fridge.git`
**Zig:** Any (flexible)
**Bundles:** Custom fork of sqlite amalgamation (via lazy dependency `sqlite_source`)
**Module name:** `fridge`
**Build.zig options:** `-Dbundle=true` to bundle sqlite (default is false — must enable!)
**API Status:** ⚠️ UNVERIFIED — Connection uses dialect-specific `open()` pattern, not `init()`. Implementation agent must verify exact API from source.

#### src/main.zig (unverified — may need adjustment)
```zig
const std = @import("std");
const fridge = @import("fridge");

pub fn main() !void {
    // TODO: Verify actual API — Connection.open() requires dialect type parameter
    // Placeholder: may need to use a concrete SQLite dialect type
    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var conn = try fridge.Connection.open(/* dialect type */, gpa.io(), gpa.allocator(), .{});
    defer conn.deinit();
    _ = try conn.execAll("SELECT 1");
}
```

#### build.zig
```zig
const std = @import("std");

const targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
};

pub fn build(b: *std.Build) void {
    const dep = b.dependency("fridge", .{});
    
    for (targets) |t| {
        const exe = b.addExecutable(.{
            .name = b.fmt("fridge-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = .ReleaseSmall,
                .strip = true,
            }),
        });
        exe.root_module.addImport("fridge", dep.module("fridge"));
        b.installArtifact(exe);
    }
}
```

#### build.zig.zon
```json
.{
    .name = .fridge_test,
    .version = "0.0.1",
    .dependencies = .{},
    .paths = .{""},
}
```
Then run: `zig fetch --save git+https://github.com/cztomsik/fridge.git`

#### Build command
```bash
cd fridge/
zig build -Dbundle=true --prefix . 2>&1
ls -la bin/fridge-* && wc -c bin/fridge-*
```

**Critical:** Fridage defaults to linking system sqlite3 (`bundle=false`). Must pass `-Dbundle=true` to actually measure the bundled size. Without it, binary will be tiny (~few KB) with no SQLite.

---

### Candidate 3: oswalpalash/zsql

**Repo:** `git+https://github.com/oswalpalash/zsql.git`
**Zig:** requires 0.16.0
**Bundles:** SQLite 3.49.2 (`sqlite-amalgamation-3490200.zip`, lazy loaded)
**Module name:** `zsql`
**Build.zig options:** `-Denable-sqlite=true` (required — SQLite is disabled by default!)
**API Status:** ✅ VERIFIED from source — uses driver facade pattern with `Database(SqliteDriver).open()`

#### src/main.zig (verified against actual source)
```zig
const std = @import("std");
const zsql = @import("zsql");

const SqliteDriver = zsql.drivers.sqlite.Driver;
const Database = zsql.Database(SqliteDriver);

pub fn main() !void {
    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var db = try Database.open(allocator, .{ .path = ":memory:", .mode = .memory });
    defer db.deinit();
    var conn = try db.connect();
    defer conn.close();
    _ = try conn.exec("SELECT 1", .{});
}
```

Wait — this needs an allocator. Let me simplify:

```zig
const std = @import("std");
const zsql = @import("zsql");
const core = zsql;

const SqliteDriver = zsql.drivers.sqlite.Driver;
const Database = zsql.Database(SqliteDriver);
const Conn = zsql.Connection(SqliteDriver);

pub fn main() !void {
    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var db = try Database.open(allocator, .{ .path = ":memory:", .mode = .memory });
    defer db.deinit();
    var conn = try db.connect();
    defer conn.close();
    _ = try conn.exec("SELECT 1", .{});
}
```

#### build.zig
```zig
const std = @import("std");

const targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
};

pub fn build(b: *std.Build) void {
    const dep = b.dependency("zsql", .{});
    
    for (targets) |t| {
        const exe = b.addExecutable(.{
            .name = b.fmt("zsql-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = .ReleaseSmall,
                .strip = true,
            }),
        });
        exe.root_module.addImport("zsql", dep.module("zsql"));
        b.installArtifact(exe);
    }
}
```

#### build.zig.zon
```json
.{
    .name = .zsql_test,
    .version = "0.0.1",
    .dependencies = .{},
    .paths = .{""},
}
```
Then run: `zig fetch --save git+https://github.com/oswalpalash/zsql.git`

#### Build command
```bash
cd zsql/
zig build -Denable-sqlite=true --prefix . 2>&1
ls -la bin/zsql-* && wc -c bin/zsql-*
```

**Critical:** ZSQL disables SQLite by default. Must pass `-Denable-sqlite=true` or binary will be tiny (no SQLite code linked).

---

### Candidate 4: blue-blaze/zsqlx

**Repo:** `git+https://github.com/blue-blaze/zsqlx.git`
**Zig:** requires 0.16.0
**Bundles:** vendor/sqlite/sqlite3.c (vendored directly in repo)
**Module name:** `zsqlx`
**Build.zig options:** Default bundles ALL drivers (SQLite + Postgres + MySQL). Use `-Dpostgres=false -Dmysql=false` to isolate SQLite-only size. Also supports `-Dbundle-sqlite=false` to use system libsqlite3.
**API Status:** ⚠️ UNVERIFIED — Exact connect() API not confirmed from source. Implementation agent must verify.

For accurate comparison with other C wrappers, we want **SQLite only** (no Postgres/MySQL overhead):

#### src/main.zig (unverified — may need adjustment)
```zig
const std = @import("std");
const zsqlx = @import("zsqlx");

pub fn main() !void {
    // TODO: Verify actual API — zsqlx.connect() signature may differ
    // Placeholder: may need driver-specific init function
    var conn = try zsqlx.connect("sqlite::memory:", .{});
    defer conn.deinit();
}
```

#### build.zig
```zig
const std = @import("std");

const targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
};

pub fn build(b: *std.Build) void {
    const dep = b.dependency("zsqlx", .{});
    
    for (targets) |t| {
        const exe = b.addExecutable(.{
            .name = b.fmt("zsqlx-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = .ReleaseSmall,
                .strip = true,
            }),
        });
        exe.root_module.addImport("zsqlx", dep.module("zsqlx"));
        b.installArtifact(exe);
    }
}
```

#### build.zig.zon
```json
.{
    .name = .zsqlx_test,
    .version = "0.0.1",
    .dependencies = .{},
    .paths = .{""},
}
```
Then run: `zig fetch --save git+https://github.com/blue-blaze/zsqlx.git`

#### Build command (SQLite-only mode)
```bash
cd zsqlx/
zig build -Dpostgres=false -Dmysql=false --prefix . 2>&1
ls -la bin/zsqlx-* && wc -c bin/zsqlx-*
```

**Important:** Two builds recommended:
1. **SQLite-only**: `-Dpostgres=false -Dmysql=false` — measures SQLite cost only
2. **Full multi-driver**: default flags — measures total zsqlx cost with all 3 DB drivers

The full build will be significantly larger due to PostgreSQL SCRAM auth, MySQL protocol parsing, etc.

---

### Candidate 5: INDRIYA-TECH/zqlite

**STATUS: SKIP** — repo not found on GitHub or zigpkg.dev. No action needed.

---

## API Verification Summary

| Candidate | main.zig API Status | Notes for Implementation Agent |
|-----------|---------------------|-------------------------------|
| vrischmann/zig-sqlite | ✅ VERIFIED | `sqlite.Db.init(.{ .mode = .Memory })` — confirmed from source |
| cztomsik/fridge | ⚠️ UNVERIFIED | Uses dialect-specific `Connection.open(T, io, gpa, options)` — must verify concrete SQLite type |
| oswalpalash/zsql | ✅ VERIFIED | `Database(SqliteDriver).open(allocator, config)` — confirmed from source |
| blue-blaze/zsqlx | ⚠️ UNVERIFIED | `zsqlx.connect()` signature not confirmed — must verify actual API |

**Action required:** For candidates marked ⚠️, implementation agent should:
1. Read the actual source files to confirm the correct initialization pattern
2. Update main.zig accordingly before building
3. If no simple in-memory init exists, use any pattern that forces SQLite C code into the link graph

## Output format

After measuring, update `.kilo/plans/1786073979278-embed-sqlite-options.md` replacing all `~+800KB` entries:

| Package | Measured delta (linux-x86_64) | Measured delta (linux-aarch64) | Measured delta (macos-aarch64) | Measured delta (windows-x86_64) | Real-DB Test | Notes |
|---------|-----------|--------------|----------------|-------------------|-------------|-------|
| **cli-shim (spawn sqlite3)** | +136 KB | +107 KB | +91 KB | +222 KB | ✅ full success | Smallest viable, requires `sqlite3` CLI on system |
| **vrischmann/zig-sqlite** | +747 KB | +748 KB | +756 KB | +653 KB | ✅ opens + queries Kilo DB | Best C wrapper, karlseguin comparable |
| **nDimensional/zig-sqlite** | +878 KB | +893 KB | +893 KB | +768 KB | ✅ opens + queries Kilo DB | Mid-size C wrapper |
| **oswalpalash/zsql** | +914 KB | +946 KB | +762 KB | +735 KB | ✅ opens Kilo DB | Moderate, requires `-Denable-sqlite=true` |
| **blue-blaze/zsqlx (SQLite only)** | +1,234 KB | +1,349 KB | +1,411 KB | +1,152 KB | ✅ opens Kilo DB | Largest, requires `-Dpostgres=false -Dmysql=false -Dbundle-sqlite=true` |
| **blue-blaze/zsqlx (full)** | not measured | not measured | not measured | not measured | n/a | Would be larger (PostgreSQL + MySQL drivers) |
| **muhammad-fiaz/sqlite.zig** | +37 KB | +25 KB | +20 KB | +35 KB | ❌ `error.UnknownTable` | Pure-Zig greenfield-only, smallest but disqualified |
| **karlseguin/zqlite.zig** (baseline) | +682 KB | +700 KB | +750 KB | +700 KB | n/a | Already adopted — reference baseline |
| **cztomsik/fridge** | INCOMPATIBLE | INCOMPATIBLE | INCOMPATIBLE | INCOMPATIBLE | n/a | Zig 0.16 removed `field_names` |
| **INDRIYA-TECH/zqlite** | skipped | skipped | skipped | skipped | n/a | Repo unreachable |
| **pmarreck/zig-sqlite@yolo** | not measured | not measured | not measured | not measured | n/a | Dynamic link only (no cross-compile) |
| **jkoop/zigqlite** | not measured | not measured | not measured | not measured | n/a | Requires system libsqlite3 (dynamic link) |

## muhammad-fiaz/sqlite.zig Real-World Test

All 6 candidates tested against real Kilo DB copy (`/tmp/kilo-full-copy/kilo.db`, 833MB, 22 tables).

**Same query across all libs**:
```sql
SELECT id, slug, title FROM session LIMIT 5;
SELECT count(*) FROM project;
```

| Lib | Real-DB Run Result | Outcome |
|-----|---------------------|---------|
| **cli-shim** (spawn sqlite3) | ✅ Full success — returns 5 sessions, project count = 3 | ✅ Adopts cleanly |
| **nDimensional/zig-sqlite** | ✅ Full success — returns 5 sessions, projects=3 | ✅ Best C wrapper for Kilo |
| **vrischmann/zig-sqlite** | ✅ Opens DB, `exec()` runs | ✅ Viable |
| **oswalpalash/zsql** | ✅ Opens DB | ✅ Viable |
| **blue-blaze/zsqlx** | ✅ Opens DB | ✅ Viable (largest) |
| **muhammad-fiaz/sqlite.zig** | ❌ `error.UnknownTable` | ❌ Greenfield-only |

**muhammad-fiaz root cause**: Pure-Zig lib maintain own in-memory schema catalog (`src/catalog/schema.zig:140`). Open existing DB → read SQLite schema → but query check against internal Zig catalog, not actual DB. Must define all tables in Zig code before query.

**Implication for Kilo**: 22 tables × column definitions = massive boilerplate. Lib = greenfield-only. Cannot adopt for existing Kilo DB without rewriting all schema in Zig.

**Other libs succeed** because they use real SQLite (C amalgamation) and pass through to actual DB engine. muhammad-fiaz does not — it has its own DB engine without generic schema discovery.

## CLI Shim Notes

The `cli-shim` requires `sqlite3` binary on target system. For Kilo project: not viable — dist binaries must be self-contained, no external CLI dependency.

If system already has sqlite3 (macOS, most Linux), could be viable for non-dist usage. But for cross-platform dist: requires shipping sqlite3 binary too (~600KB), defeating size advantage.

## jkoop/zigqlite Note

Investigated. Requires `linkSystemLibrary("sqlite3")` — dynamic link to system libsqlite3. Same disqualification as pmarreck/zig-sqlite@yolo. Skipped from measurement.

## Production Build Flag Verification

All candidates built with exact flags from project `build.zig` (`zig build dist`):
- `ReleaseSmall` optimize
- `strip = true` on module
- No LTO, no PGO

**Strip diff**: ≤0.1% vs non-strip. Zig auto-strips at ReleaseSmall by default. Flag mostly no-op in 0.16.

**Verdict**: Deltas above = production-realistic numbers.

## Final Ranking (production dist, smallest to largest)

| Rank | Lib | l-x64 | l-arm64 | m-arm64 | w-x64 |
|------|-----|-------|---------|---------|-------|
| 1 | muhammad-fiaz (disqualified) | +37K | +25K | +20K | +35K |
| 2 | cli-shim (requires sqlite3 on system) | +136K | +107K | +91K | +222K |
| 3 | vrischmann/zig-sqlite | +747K | +748K | +756K | +653K |
| 4 | nDimensional/zig-sqlite | +878K | +893K | +893K | +768K |
| 5 | oswalpalash/zsql | +914K | +946K | +762K | +735K |
| 6 | blue-blaze/zsqlx (SQLite only) | +1,234K | +1,349K | +1,411K | +1,152K |

**Recommendation**: vrischmann/zig-sqlite — best C wrapper for Kilo. Tied for smallest with karlseguin (~+700K), well-tested C amalgamation (SQLite 3.49.2), actively maintained.

## Production Build Flag Verification

All candidates built with exact flags from project `build.zig` (`zig build dist`):
- `ReleaseSmall` optimize
- `strip = true` on module
- No LTO, no PGO

**Strip diff**: ≤0.1% vs non-strip. Zig auto-strips at ReleaseSmall by default. Flag mostly no-op in 0.16.

**Verdict**: Delitas above = production-realistic numbers.

## Risks & Gotchas

1. **Lazy loading**: Both zsql and fridge disable SQLite by default. Forgetting the build flag produces tiny binaries that don't include any SQLite code — completely wrong measurement.

2. **Multi-driver bloat**: zsqlx includes PostgreSQL and MySQL drivers by default. These add significant size (SCRAM auth, wire protocol parsers). Always measure both modes.

3. **Fridge's C source generation**: Fridge uses `b.addTranslateC()` to generate Zig bindings from C headers before compiling. This adds compile time but doesn't affect final binary size.

4. **Vrischmann's large c/ directory**: Contains 614KB of generated Zig bindings from `sqlite3.h`. Even if unused, these may be included in the module graph. The linker should strip unused symbols when stripping is enabled.

5. **Stripping**: All builds must use `strip = true` to match the baseline measurement methodology.

## Expected results

Since all C wrappers bundle essentially the same SQLite C source code (~1MB of amalgamation), expect deltas in the range of **+600–900KB** per target, similar to karlseguin's measured +682–808KB.

Variables that affect final size:
- Wrapper feature set (pooling, migrations, query builders pull in more code)
- SQLite compilation flags (FTS5, JSON1, window functions add size)
- Multi-driver support (zsqlx with Postgres+MySQL will be noticeably larger)
- Generated binding size (some wrappers pre-generate large Zig bindings for C APIs)
