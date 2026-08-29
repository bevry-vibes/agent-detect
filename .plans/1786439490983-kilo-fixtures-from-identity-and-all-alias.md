# Kilo fixtures via from-identity: `--all` default scope + always re-capture

## context

- `HarnessRule.short_title = "Kilo"` was added to kilo's rule (this session's
  earlier work). The committed kilo fixtures still carried
  `harness_short_title: null`, so they needed regeneration.
- `from-ids` was renamed to `from-identity` earlier this session
  (working tree, uncommitted). `runOneComboIdentity` uses `resolveRecipe`,
  which reads `harness.short_title`, so a `from-identity` re-capture writes
  `harness_short_title: "Kilo"` — cheap (zero tokens, no harness binary).
- The plain queue path did NOT refresh: `queue --harness=kilo --from-identity`
  → seed → daemon expands to full rows → **lazy-backfill skip**
  ("fresh fixture exists — completing without re-capture") because the store
  rows already exist. Only `--all` (which stamps `scope_all=1`) bypassed the
  skip, and only partially — the daemon log shows interleaved sequences and 8
  kilo fixtures remain `from-raw` origin (leftover from-raw queue rows), while
  9 were re-captured as `from-identity`. All 17 kilo fixtures now carry
  `harness_short_title: "Kilo"` (verified), but via the `--all` workaround.
- User instruction: re-capture must NOT require `scope_all = 1`. Per user
  Q&A + follow-up notes:
  1. **Always re-capture** queued full combos (drop the "fresh fixture
     exists" skip). `from-identity`/`from-raw` are zero-token; `from-capture`
     already never skips. `--stale-by-*` markers remain the only skip.
  2. **`--all` is the explicit default scope**, NOT a no-op:
     `(de)queue` with no flags → "missing required arguments" (need filters);
     `(de)queue --all` → do all (every fixture row);
     `(de)queue --all --available` ≡ `(de)queue --available` — so
     `--available`/`--unavailable` imply the `--all` default scope when no
     other scope flag is given.
  3. **Keep** the origin-aware lazy file-based backfill for the no-store-row
     case (decision #6 store population on fresh clones).
- **Help-text duplication** (user note): the three usage blocks each describe
  `--all` twice — in the intro paragraph AND in its own flag line. Fix:
  describe `--all` once per block (as the default scope; drop the intro
  paragraph's repetition).
- Working tree state (uncommitted, from this session's prior work): the
  `from-ids → from-identity` rename (CONTRIBUTING.md, DESIGN.md,
  src/known_fixtures.test.zig, src/main.zig), the active-session detection fix
  (kilo/opencode/copilot), the kilo `short_title = "Kilo"` rule, 4 new unit
  tests, DESIGN.md decision-#4 rewrite, and 17 regenerated kilo fixtures
  (mixed `from-identity` / `from-raw` origins, all with the new short_title).
- Daemon is running via launchctl (`com.agent-detect.fixtures`, PID 91048),
  queue empty. Plan uses it for the final regeneration validation; the
  implementing agent must rebuild first, then `bootout` + `bootstrap` the
  LaunchAgent to load the new binary.

## decisions

- `--all` stays the explicit default scope: `(de)queue --all` enumerates every
  fixture row. Plain `(de)queue` with no flags/filters still errors
  "missing required arguments" (unchanged `NoFilter` behavior).
- `--available` / `--unavailable` are modifiers that **imply `--all`**: when
  they are the only scope-ish flags present, treat them as `--all` so
  `--all --available` ≡ `--available` (and same for `--unavailable`). This
  removes the "available requires a scope flag" conflict (parseFilters
  line ~4947) by substituting `f.all = true` instead of erroring.
- The `scope_all` column/flag is **removed entirely** (schema, `QueueRow`,
  upsert/select/parse SQL, dedupe index, `validateQueueRow`,
  `scopeCandidates` stamping, daemon gate).
- The daemon's "fresh fixture exists → completing without re-capture" skip
  (currently gated on `scope_all != 1`) is **dropped**. The origin-aware lazy
  file-based backfill stays, but only for the no-store-row-yet case.
- `--stale-by-*` markers keep their existing pop-time skip behavior
  (unchanged).
- Commits follow AGENTS.md: co-author trailer generated fresh via
  `./zig-out/bin/agent-detect trailer co-author`, attached with
  `git commit --trailer "$(...)"`; never guess/cache. This plan file is
  committed with the work it drives.

## task list

### A. code — `--all` default scope + `--available` implies `--all`

> Working-tree state: a partial/incorrect edit is already applied — `f.all`
> was removed from `scope_count` (parseFilters ~4944) and from the
> `scopeCount` fn (~5028), and `all_effective` + the `scope_all` stamping
> were removed. REVERT the two `f.all`-removal hunks (restore `--all` as a
> scope flag) and KEEP the `all_effective`/stamping removal (that part is
> correct). The help text was also edited to the wrong "no-op alias" wording —
> fix to the wording below.

1. `src/main.zig` `parseFilters` (line ~4942): restore `f.all` in the
   `scope_count` computation (it stays a scope flag — the default scope).
   Also restore the `f.all` term in the `scopeCount` fn (~5022).
2. `--available` / `--unavailable` imply `--all`: in `parseFilters`, replace
   the "require a scope flag" conflict (line ~4947
   `if (f.available or f.unavailable) and scope_count == 0 → ConflictingFilters`)
   with `f.all = true;` substitution, so `--all --available` ≡ `--available`
   (and `--unavailable`). The existing
   `if (f.available and f.unavailable)` conflict stays.
3. Keep the removed `all_effective` (line ~5059) and
   `if (all_effective) row.scope_all = 1;` (line ~5155) — already gone in the
   working tree; confirm. The fixtures-table enumeration branch in
   `scopeCandidates` (line ~5140) stays reachable via `--all` / `--stale-by-*`.

### B. code — remove `scope_all`

5. Schema DDL (line ~3453): drop `scope_all INTEGER,`; drop
   `COALESCE(scope_all,0)` from `queue_dedupe` (line ~3466).
6. `QueueRow` struct (line ~3498): drop `scope_all: ?i64 = null,`.
7. `upsertQueueRow` (line ~3568 + INSERT column list ~3583): drop the `sa`
   binding and column.
8. `selectSeedQueueRows` (line ~3639), `jsonToQueueRow` (line ~3666),
   `popQueueRow` (line ~3748): drop `scope_all` from the SELECT columns and
   the parsed row.
9. `validateQueueRow` (lines ~3821 and ~3834): drop `scope_all` from the
   scope-count and the `scopes` array.

### C. code — daemon always re-captures queued full combos

10. `runFixturesDaemon` pop loop (line ~5752–5789): replace the
    `(scope_all == null or != 1)` gate. New structure:

    ```zig
    // queued full combos always re-capture; from-capture never skips.
    // The only skip mechanisms are the --stale-by-* markers below.
    if (!std.mem.eql(u8, action.mode, "from-capture")) {
        // decision #6 lazy backfill: no store row yet, but a valid committed
        // fixture file exists with origin rank ≥ the queued mode → populate
        // the store row from the file without re-capturing (fresh-clone
        // store population). Once a store row exists, re-capture.
        if (!(try fixtureExists(a, io, h, p, m_d, plat))) {
            if (try fixtureFileOriginRank(a, io, h, p, m_d, plat)) |rank| {
                if (rank >= modeRank(action.mode)) {
                    // upsert fixture row from file + "backfilled ... without re-capture"
                    continue;
                }
                // "ranks below the queued mode — re-capturing"
            }
        }
    }
    ```
    Remove the old `if (try fixtureExists(...)) { …continue; }` skip block.

### D. help text + docs

> Working-tree state: the three usage blocks were already edited to the wrong
> "no-op alias" wording (and each still mentions `--all` twice — intro
> paragraph + flag line). Fix to the wording below so `--all` is described
> exactly once per block (in the flag line; the intro paragraph stays generic
> about scope-flag AND-composition and the stale-by-* conflict).

11. Three usage strings in `src/main.zig` — no duplicated help text:
    - `devUsage` (the dev top-level `--help`): the "dev actions" block now
      points at `fixtures help` for the refresh-mode/scope/daemon flags
      instead of repeating them (the mode/scope/daemon sections were removed).
    - `fixturesUsage` (the `fixtures help` namespace overview): lists the
      state, daemon flags, control, subcommands, and exit codes, and points
      at each subcommand's `--help` for the shared modes/filters/scope flags
      (its own duplicated copies were removed).
    - `queueDequeueFlags` is the single source for refresh modes, filters, and
      scope flags; `queueUsage`/`dequeueUsage` compose it. `--all` is described
      once: `--all  the default scope made explicit (every fixture row);
      absorbed by any other scope flag`. **Never mention `--all` with any
      other flag** (user note) — no "implies --all" or "alias"
      cross-references on the `--available`/`--unavailable` lines.
      `--unavailable` is described by what it does, not as the opposite of
      `--available`: "modifier (dequeue only): match rows whose harness is
      unavailable (available=0)". Internal details are stripped from the
      human-facing text (no "stored as minutes", "age column",
      "fixtures.harness_version", "no age pre-filter" — the stale-by-* lines
      say just "age threshold in days/hours/minutes").
12. `DESIGN.md`:
    - "lazy file-based backfill" section (~line 138): clarify it now applies
      only when no store row exists; queued full combos with an existing
      store row always re-capture.
    - Scope-flags paragraph (~line 166): `--all` is the default scope made
      explicit; `--available`/`--unavailable` imply `--all`.
13. `CONTRIBUTING.md`: lines ~63–65 (`--all` description), ~110
    (`fixtures queue --all` re-queues every fixture row), ~123–128
    (`--all` = every fixture row in `fixtures/index.sqlite3`; `--available`
    implies `--all`).

### E. build + tests

14. `zig build` and `zig build test` (incl. `--test-filter modelFrom` for the
    4 new tests). `known_fixtures.test.zig` has no `scope_all` references;
    the origin test (line ~514) already accepts `from-identity`.

### F. regenerate kilo fixtures via the plain path (validates the fix)

15. Rebuild the dev binary, then reload the LaunchAgent to pick it up:
    `launchctl bootout "gui/$(id -u)"/com.agent-detect.fixtures`, then
    `launchctl bootstrap "gui/$(id -u)" <plist>`.
16. Run the plain seed (no `--all`):
    `./zig-out/bin/agent-detect-dev fixtures queue --harness=kilo --from-identity`
    → daemon expands the seed over the 17 kilo recipes and re-captures every
    one as `from-identity` (previously the 8 leftover-`from-raw` ones would
    have been skipped; now they re-capture too).
17. Verify all 17 `fixtures/kilo-*.json`:
    `harness_short_title == "Kilo"`, `origin == "from-identity"`, and the
    `evidence` array is empty (declared fixtures).
18. Stop the daemon: `launchctl bootout "gui/$(id -u)"/com.agent-detect.fixtures`.

### G. commit + push

19. Stage + commit (one or more logical commits; the working tree also carries
    this session's prior uncommitted work — the from-identity rename, the
    active-session detection fix, the kilo short_title rule, the 4 unit tests,
    and the regenerated kilo fixtures). Suggested grouping:
    - commit 1: detection fix + kilo short_title + tests + DESIGN.md (the
      earlier work),
    - commit 2: `from-ids → from-identity` rename + docs,
    - commit 3: `--all` default scope + `--available` implies `--all` +
      always re-capture + removed `scope_all` + regenerated kilo fixtures +
      this plan file.
    Attach the generated co-author trailer to every commit.
20. `git push`.

## validation

- `(de)queue` with no flags/filters → "missing required arguments"
  (need for filters).
- `queue --all` and `queue --available` both enumerate every fixture row;
  `queue --all --available` and `queue --available` are equivalent.
- `./zig-out/bin/agent-detect-dev fixtures queue --help` shows `--all`
  described ONCE per usage block (no intro/flag-line duplication), and
  `--all` is never mentioned on any other flag line (`--available` /
  `--unavailable` describe themselves).
- Plain `queue --harness=kilo --from-identity` + daemon re-captures all 17
  kilo fixtures as `from-identity` with `harness_short_title: "Kilo"`
  (fixtures test at src/known_fixtures.test.zig:514 passes — empty evidence on
  declared fixtures).
- `zig build test` green (origin tests + the 4 `modelFrom*` unit tests).
- No `scope_all` remains: `rg -n "scope_all" src/main.zig` → no matches.
- `git status` clean in agent-detect after push; all commits carry the
  `Co-authored-by:` trailer; this plan file is committed alongside the work.

## out of scope

- `--stale-by-*` behavior (unchanged).
- `from-capture` path (unchanged — already never skips).
- Consumer projects and skills-repo changes (policy.md/kilo.md work already
  committed in the prior task).
