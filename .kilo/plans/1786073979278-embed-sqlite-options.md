# Embed SQLite: evaluate pure-Zig options vs. C amalgamation

## Status: DECISION-PENDING

The released binary currently shells out to the system `sqlite3` CLI for two use cases:

1. `kiloSqliteJson` (released binary, `src/main.zig:1595`) — reads `~/.local/share/kilo/kilo.db` (real SQLite 3.51 WAL-mode, 717MB, live writer).
2. `dev.sqliteRun` / `sqliteQuery` (dev binary only, `src/main.zig:2358`) — reads/writes `fixtures/index.sqlite3` (our own DB).

Goal: replace the `sqlite3` CLI invocation with an embedded engine so the released binary has zero runtime dependencies.

## Baseline dist sizes (ReleaseSmall, stripped)

| Target | Baseline | +karlseguin | +muhammad |
|---|---|---|---|
| linux-x86_64 | 257,928 | 1,043,304 (+785KB) | 293,960 (+36KB) |
| linux-aarch64 | 245,344 | 1,028,280 (+783KB) | 269,656 (+24KB) |
| macos-aarch64 | 274,840 | 1,083,080 (+808KB) | 294,936 (+20KB) |
| windows-x86_64 | 551,424 | 1,233,920 (+682KB) | 585,728 (+34KB) |
| macos-x86_64 | 231,747 | — | — |
| windows-aarch64 | 493,056 | — | — |

## Full comparison (all 8 candidates)

| Package | Stars | Type | Zig | SQLite ver | Static | Runtime Dep | Size delta | Maintained | Features |
|---------|-------|------|-----|-----------|--------|-------------|-----------|-----------|----------|
| **karlseguin/zqlite.zig** | 190 | C wrapper | 0.16 | 3.53.0 | ✅ bundled | None | +682–808KB | ✅ yesterday | thin wrapper, pool, transactions, prepared stmts |
| **muhammad-fiaz/sqlite.zig** | 4 | Pure Zig | 0.16 | N/A (own impl) | ✅ | None | +20–36KB | ⚠️ v0.0.1 | real SQLite format, WAL, DSL query builder, CTEs, views, triggers |
| vrischmann/zig-sqlite | 604 | C wrapper | 0.14/master | 3.48.0 | ✅ bundled | None | ~+800KB | ⚠️ maintainer on break | thin wrapper, comptime bind checks, user-defined functions |
| cztomsik/fridge | 91 | C wrapper | Any | bundled | ✅ bundled | None | ~+800KB | ✅ 24 days ago | batteries-included, type-safe query builder, pool, migrations |
| oswalpalash/zsql | 0 | C wrapper | 0.16 | bundled | ✅ bundled | None | ~+800KB | ✅ 23 days ago | SQLite + Postgres, pool, migrations, offline query checks |
| blue-blaze/zsqlx | 2 | C wrapper | 0.16 | 3.50.4 | ✅ bundled | None | ~+800KB | ✅ 4 days ago | SQLite + Postgres + MySQL, pool, migrations, build-time checked queries |
| INDRIYA-TECH/zqlite | 0 | C wrapper | 0.16-dev | bundled | ✅ bundled | None | ~+800KB | ✅ 5 days ago | thin wrapper, prepared stmts, BLOB/NULL support |
| pmarreck/zig-sqlite@yolo | — | C wrapper | 0.16 | 3.49 | ❌ dynamic | libsqlite.dylib | 165KB (dynamic) | — | thin wrapper, previously vetted in this repo |

**Runtime dependencies:** All bundled options require zero host libraries. Statically link sqlite3.c via zig cc. Cross-compile works for all targets. Only pmarreck's fork defaults to dynamic link (broken for cross-compile).

### Option A: zqlite (GhostKellz/zqlite) — REJECTED

- Pure Zig, proprietary file format. Cannot read real SQLite files.
- **Blocker**: cannot read `kilo.db`.

### Option B: muhammad-fiaz/sqlite.zig — CANDIDATE, UNVERIFIED

- Pure Zig, real SQLite `.db` file format + WAL.
- zig 0.16.0, cross-platform.
- **Risks**: v0.0.1, 14 commits, 4 stars, "do not use in production". SQL subset unverified (need expression indexes with COALESCE, INSERT OR REPLACE, DELETE rowid subquery, SELECT changes(), PRAGMA busy_timeout). WAL reading against live writer untested.
- **Size**: +20–36KB (measured).

### Option C: karlseguin/zqlite.zig — RECOMMENDED

- C wrapper, bundles SQLite 3.53.0, statically links.
- zig 0.16.0, 190 stars, well-maintained (updated yesterday).
- Proven API: `conn.exec()`, `conn.row()`, `conn.rows()`, `conn.changes()`, `conn.busyTimeout()`.
- **Size**: +682–808KB (measured).
- Supports all SQL needs natively (full SQLite).

### Option D: keep shelling out to sqlite3 CLI — STATUS QUO

- Zero binary growth. Runtime dependency on system `sqlite3`.

## Decision needed

Which option?

- **B (muhammad-fiaz)**: pure Zig, +20–36KB, but v0.0.1, unverified SQL coverage, risky.
- **C (karlseguin)**: C wrapper, +682–808KB, proven, full SQLite, well-maintained.
- **D (status quo)**: zero growth, runtime dep.

## Recommendation

**Option C (karlseguin/zqlite.zig)** — proven, full SQLite, well-maintained, zero runtime deps. Size cost ~700KB is acceptable for removing the CLI dependency.

**Option B (muhammad-fiaz/sqlite.zig)** — if pure Zig + minimal size is critical, proceed with smoke test first (verify SQL subset + WAL reading against real kilo.db). If it fails, fall back to C.

## Open question

**Which path? C (karlseguin, recommended), B (muhammad-fiaz, pure Zig but risky), or D (status quo)?**
