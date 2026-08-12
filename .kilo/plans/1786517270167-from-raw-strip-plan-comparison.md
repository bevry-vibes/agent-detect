# from-raw strip: plan comparison + decision register

Compares `.kilo/plans/1786508422444-strip-from-raw-from-capture-default.md`
(**A**, "committed store") and
`.kilo/plans/1786508661001-strip-from-raw-mode-simplification.md`
(**B**, "mode simplification"), surfaces every divergence, and records
the user's decision on each. The register is now **closed**; the next
step is a consolidated implementation plan (new file) that supersedes
both A and B.

## Provenance

- Agent model: `kimi-k3` (exact model ID `cline-pass/cline-pass/kimi-k3`),
  harness: `kilo`.
- Original prompt (verbatim):

  > Create a new plan, that compares these two plans, surfaces divergences, and prompts me for what to do:
  > .kilo\plans\1786508422444-strip-from-raw-from-capture-default.md
  > .kilo\plans\1786508661001-strip-from-raw-mode-simplification.md
  >
  > Note that reasonix should now now available on this windows host.
  >
  > Note that one plan has:
  >
  > ```
  > ### 8. Replace from-raw's zero-token `detect()` coverage (the main orphan)
  >
  > New `src/detect_ladder.test.zig`: an in-process regression test that
  > exercises the live detection ladder against synthetic state.
  > ```
  >
  > This is an awful idea - as our intire intent of removing from-raw is to remove all such spurious/faux testing of and from synthetic states.
  >
  > Furthermore, one divergene seems to be around successful/available; we want to persist `available` and introduce `successful` into the queue table, not remove them. `queue --(un)available`, `queue --(un)successful`, should just add rows to the queue table, it should not do any evaluation itself.
  >
  > One plan also has:
  >
  > ```
  > - `git rm` the 160 committed fixtures with `origin == "from-raw"`.
  > ```
  >
  > We do not want to remove any fixtures files, even if they were `from-raw`. We just want to queue their regeneration.
  >
  > Finally, is there anything from `.kilo\plans\1786508422444-strip-from-raw-from-capture-default.md` that we actually want to keep, or have overlooked, as it seems to be the one with all the bad ideas?
  >
  > Before we begin, amend our Kimi harness rule in AGENTS.md so that the generated plans include their original and followup prompts, and the agent model that was used.

- Followup prompts (verbatim, in order):
  1. > You didn't amend the plan provenance section to include your questions and my verbatim answers to yours questions - do those amends. Then do a new plan file with the actual final plan for implementation.

### Decision Q&A (questions as posed; answers verbatim)

First round (P1–P8, asked together):

1. **Q:** "P1 — State store: committed to git (Plan A) or per-host
   gitignored (Plan B)? This drives platform-aware popping, cross-device
   queue sync, and migration mechanics."
   **A:** "Committed to git"
2. **Q:** "P2 — Where does agent_detect_version live (the stamp
   --stale-by-detection compares against the running binary)?"
   **A:** "DB column only"
3. **Q:** "P3 — available/successful model: confirm placement and
   naming. (You already decided: persist available, introduce
   successful, queue flags are pure enqueue scopes with no evaluation.)"
   **A:** "Both tables (Recommended)"
4. **Q:** "P4 — The origin key on fixture files: keep it (tightening the
   validator after regeneration) or drop it entirely?"
   **A:** "Drop it from the fixture file. Instead, add a
   identity_generation_at, identity_generation_hash, and
   capture_generation_at, and identity_generation_hash columns. Use md5
   or blake3 or whatever doesn't need a zig package. With this, we can
   see if they cause divergences from each other, or if one missing."
5. **Q:** "P5 — Evidence-claim checks
   (evidenceClaimsValid/valueMatchesDim + daemon gate + zig test): keep
   or remove?"
   **A:** "raw/evidence is purely for human and dev agent review, only
   the dev agent should be checking them to use its intillgence (not
   programming) to deduce if the cooked is deducable from the
   raw/evidence"
6. **Q:** "P6 — Backfill (populating the fixtures table from committed
   files): queue-time, daemon pop-time, or both?"
   **A:** "I need more details. Daemon init itself should not be
   modifying fixtures, nor adding things to the queue; it should only be
   modifying fixtures on queue pops, and removing queue entries on queue
   pops; when encountering a seed entry it should expand that seed entry
   in-memory, doing the agent updates as it goes, then once done
   in-memory tne pop from the queue; or alternative there should be an
   in-progress table, where individual expanded jobs can go (mimicing
   queue). Yeah, lets do this, can call it pending table, so the
   expanded seeds from queue go there, the table columns are queue_id,
   fixture_id (agent_id + platform_id), started_at (nullable),
   finished_at (nullable) - once all are finished, then pending table is
   cleared and the queue_id row is popped; update fixture rows as the
   pending progresses. Add a queue_id (unique-row-id) to queue table;
   add a derived fixture_id and agent_id columns to fitures column to
   make lookups easier (alphanumeric ids separated by a hash)."
7. **Q:** "P7 — Regeneration mode for the 160 darwin fixtures and the
   new windows matrix?"
   **A:** "It will be both, as there {identity,capture}_generated_{at,hash}
   columns will be empty."
8. **Q:** "P8 — Recipes with no launch spec under the from-capture
   default: how should queueing handle them?"
   **A:** "How is from-identity meant to work, for each identity there
   should also be the ability to capture, no? So it should be added to
   an invalid table, with the
   {fixture,agent,harness,provider,model,platform}_id and can be used by
   the dev agent later to remedy, as perhaps later the ids can have
   their support added, or perhaps there was a typo or something. So the
   dev agent should check the invalid table, and nothing else needs to
   read from it, this will allow queues to still be popped, and for
   fixtures and pending tables to only contain correct/known ids."

Second round (backfill followup):

9. **Q:** "Your P6 pending-table design + daemon-purity rule ('daemon
   only modifies fixtures on pops') kills both plans' backfill designs.
   With the committed store (P1), fresh clones receive the fixtures
   table from git, so the bootstrap use-case mostly evaporates. Should
   any backfill (committed file → fixtures row, without a queued job)
   survive?"
   **A:** "No backfill at all, split `--mising-fixture` into
   `--missing-fixture-file` and `--missing-fixture-entry`, drop
   `--missing-fixture`; `--missing-fixture-entry` will be the only thing
   that will scan the fixtures directory for fixture files and check for
   missing fixture entries, in which it will add a fixture entry (but no
   queue) if the ids are valid, if the ids are invalid it will be sent
   to the invalid column, the fixture will will persist, and can be
   purged or whatever by the dev agent and its users discretion when
   they review the invalid table."

## Pre-implementation task (blocked in plan mode)

Amending AGENTS.md is a non-plan-file edit, denied under plan-mode
permissions. Apply this amendment first thing in implementation (it is
the rule this plan's Provenance section already follows). **Corrected
per followup: the rule is a tweak to the sourced `kilo.md` skill, not a
new `kimi` section (kimi was a typo).** Append to the existing kilo.md
bullet:

```md
  …with this project's tweak (to be upstreamed): every plan file the
  agent generates records its provenance at the top of the file — the
  original prompt that initiated the plan, every followup prompt that
  shaped it (verbatim, in order), and the agent model that generated it
  (as reported by the harness).
```

Upstreaming the tweak to bevry-vibes/skills `kilo.md` is post-plan
follow-up, out of scope here.

## Verified shared ground (both plans agree; checked against `src/main.zig` @ 407646d)

- Strip `from-raw` end-to-end: worker `runOneComboResult`, the 14
  `build*Env` fabricators + `EnvSetup`/`WriteSpec` + `resolveHome` +
  `DevProviderMeta*` + `canonical*Name`/`comboDims`, all 177 `.buildEnv =`
  initializers, the sandbox-HOME block + `AGENT_DETECT_FIXTURE_ORIGIN`,
  the `refresh run` alias + usage, mode default `'from-raw'` →
  `'from-capture'`, two-way pop ordering (from-identity < from-capture).
- `from-capture` becomes the default queue mode; `from-identity` stays
  explicit opt-in; "daemon does from-identity unless conditions are met"
  is removed, not reimplemented. (**Superseded by followup 5**: queue
  defaults to enqueueing BOTH modes — one from-identity row and one
  from-capture row per candidate; exactly one mode with exactly one
  `--from-*` flag; both flags rejected.)
- Failure-mark model replaces re-queue / `capture_attempts` 3-cap /
  handoff: failures stamp the fixtures row and consume the work item;
  retry is manual and user-driven.
- `--stale-by-detection` is added as a scope + queue marker + pop-time
  skip term.
- Usage text, DESIGN.md, CONTRIBUTING.md, AGENTS.md harness-config
  section updated; README untouched; historical `.kilo/plans/*` left as
  records.
- Facts: 160 `origin:"from-raw"` + 17 `origin:"from-identity"` committed
  fixtures, **all darwin**, 0 from-capture. `queue` table today has
  `available`; `fixtures` has neither `available` nor `success`.
  reasonix: 3 recipes, only `reasonix-deepseekflash-deepseekv4flash`
  has `.launch` (verified 4524-4526). `build.zig.zon` = `2026.8.11-3`.
  `fixtures/index.sqlite3` exists locally and is gitignored; the local
  `fixtures` table is empty and its 177 queue rows are stale
  (`mode='from-raw'`) — the migration starts clean.

## User-decided (from the original prompt — not open)

1. **No synthetic-state testing, no replacement.** A's task 8
   (`src/detect_ladder.test.zig`, synthetic env/HOME driving `detect()`)
   is rejected outright: the entire intent of the strip is to remove all
   spurious/faux testing of and from synthetic states. Nothing synthetic
   takes from-raw's place; real coverage is from-capture fixtures.
2. **Persist `available`; introduce `successful`; queue never
   evaluates.** Do not remove state columns. `queue --available` /
   `--unavailable` / `--successful` / `--unsuccessful` only add rows to
   the queue table — pure enqueue scopes, no probing or judgment at
   queue time. This rejects B's `queue --available` live probe filter.
3. **No fixture-file deletions.** The 160 `from-raw` files are never
   `git rm`'d; their regeneration is queued and each file is replaced
   only when its regeneration lands.
4. **reasonix is available on this Windows host.** B's "unavailable
   harnesses (e.g. reasonix)" example is stale. A's per-recipe detail is
   verified: only `reasonix-deepseekflash-deepseekv4flash` has a launch
   spec (capturable here); the other two reasonix recipes have no launch
   spec.

## Divergence register (closed)

| # | Topic | A (…422444) | B (…661001) | **Decision** |
|---|-------|-------------|-------------|--------------|
| D1 | SQLite store | Committed to git; cross-host queue sync | Per-host, gitignored | **A: committed to git** (P1) |
| D2 | `agent_detect_version` | Table column; table-universe `--stale-by-detection` | Fixture-file key; recipe-universe scope | **A: DB column only**; no file key (P2) |
| D3 | available/success model | Remove `available`; `fixtures.success` only | Remove queue `available`; fixtures gains both; queue-time probe filter | **Neither — user model**: persist both; both tables; pure-enqueue flags; no queue-time probing (P3) |
| D4 | 160 from-raw files | `git rm`; regen as declared | Keep until sweep replaces | **B-direction, user-stated**: never delete; queue regeneration (original prompt) |
| D5 | `origin` key | Drop entirely | Keep + tighten validator | **Drop from the file** — replaced by per-channel generation columns on the `fixtures` table (P4) |
| D6 | Evidence-claim checks | Remove entirely | Keep (observed-only after sweep) | **Remove entirely**: raw/evidence is for human + dev-agent review; only dev-agent intelligence (never code) deduces cooked from raw/evidence (P5) |
| D7 | Synthetic detect-ladder test | Add | Absent | **Rejected; no replacement** (original prompt) |
| D8 | Backfill / seed expansion | Daemon pop-time backfill + gating fix | Queue-time backfill; daemon backfill deleted | **Neither — pending-table protocol + no backfill at all** (P6 + backfill followup) |
| D9 | Regeneration mode | All from-identity (zero-token) | Capture where possible, identity else | **Both channels run**; per-channel generation columns expose what is missing (P7) |
| D10 | No-launch-spec handling | Queue as from-identity | Skip + warn; daemon guard | **Neither — `invalid` table** (P8) |
| D11 | Platform-aware popping | Required | Unneeded | **Adopted** (follows D1) |
| D12 | DB migration | dequeue-all, drop/alter, commit DB | Delete DB file | **A-shaped, simplified**: local fixtures table is empty and queue rows are stale → clear queue, recreate schema, commit the fresh DB (follows P1/P6) |

## Decisions landed (2026-08-12, verbatim from the interactive prompts)

- **P1 — state store: committed to git.** `fixtures/index.sqlite3`
  leaves `.gitignore` (journal/wal/shm, daemon.log/ctl stay ignored).
  Cross-device queue sync is literal: queue rows carry their platform;
  a row queued on Windows with `platform='darwin'` is popped by the
  macOS daemon after pull. Requires D11 platform-aware popping and the
  single-writer workflow (binary-merge caveat stands).
- **P2 — `agent_detect_version` is a `fixtures` table column only.**
  No fixture-file key. `--stale-by-detection` (renamed
  `--stale-by-detect` in followup 7; marker column `stale_by_detect`)
  enumerates `fixtures` rows (all platforms) whose
  `agent_detect_version` is NULL or differs from the running binary;
  rows are queued with their stored platform. Version-bump contract
  stands (format-affecting changes bump `build.zig.zon`).
- **P3 — both tables carry state; queue never evaluates.**
  - `fixtures` gains `available` (NULL/1/0) and `successful`
    (NULL/1/0), written by the daemon as pending jobs complete.
  - `queue` **keeps** `available` and **gains** `successful` as pure
    scope markers (which scope enqueued the row; both feed
    `queue_dedupe`; `dequeue` filters on them).
  - Flags: `--available` / `--unavailable` enumerate
    `fixtures.available = 1/0`; `--successful` / `--unsuccessful`
    enumerate `fixtures.successful = 1/0`; all four only INSERT queue
    rows. No probing, no evaluation, anywhere in queue/dequeue. The old
    queue-time probe stamps die.
- **P4 — `origin` dropped from the fixture file; replaced by per-channel
  generation columns on `fixtures`:** `identity_generation_at`,
  `identity_generation_hash`, `capture_generation_at`,
  `capture_generation_hash`. Hash via std crypto only (BLAKE3 / SHA-256
  / MD5 — implementer picks; **no external zig package**); recommended
  input: the canonical `cooked`+`raw` bytes (trailer excluded). The
  columns expose per-channel divergence and absence (NULL = channel
  never ran). All `origin` consumers die: file key, post-checks,
  `fixtureFileOriginRank`, the origin zig test. No `origin` table
  column — channel state is the four columns.
- **P5 — all mechanical evidence checks removed.** `evidenceClaimsValid`,
  `valueMatchesDim`, the daemon post-check gate, and the zig test are
  deleted. `raw`/`evidence` is purely for human and dev-agent review;
  only the dev agent — using intelligence, not programming — deduces
  whether cooked is deducible from raw/evidence. Evidence *recording*
  and redaction stay.
- **P6 — pending-table protocol; daemon purity; no backfill.**
  - Daemon init modifies nothing and adds nothing to any table. The
    daemon only: pops queue rows, writes `pending` rows for seed
    expansion, updates `fixtures` rows as pending jobs progress, deletes
    `pending`/`queue` rows on completion.
  - `queue` gains a unique `queue_id`.
  - New `pending` table: `queue_id`, `fixture_id`, `started_at`
    (nullable), `finished_at` (nullable). Popping a seed inserts one
    pending row per expanded job (mode is read from the seed row via
    `queue_id` — the seed lives until its pending rows drain). When all
    pending rows for a `queue_id` have `finished_at`, the pending rows
    are cleared and the seed queue row is deleted.
  - `fixtures` gains derived `agent_id` and `fixture_id` columns for
    lookups: alphanumeric segments joined by `#` —
    `agent_id = harness#provider#model`,
    `fixture_id = agent_id#platform`. (Consolidated plan must pin the
    relationship to the existing dash-joined recipe `agent_id` used in
    filenames — recommendation: derived columns are authoritative for
    DB joins; filename strings unchanged.)
  - **No backfill at all** — see the `--missing-fixture` split below.
- **Backfill followup — `--missing-fixture` split; drop the old flag.**
  - `--missing-fixture-file`: recipes whose fixture **file** is absent
    → enqueue rows (regenerate).
  - `--missing-fixture-entry`: scans the fixtures directory for files
    lacking a `fixtures`-table **entry** → adds the entry (no queue row)
    when the ids are valid; invalid ids go to the `invalid` table, the
    file persists on disk, and the dev agent / user purges at their
    discretion when reviewing the invalid table. This is the only
    command that writes `fixtures` entries outside the daemon, and it
    does no evaluation.
- **P7 — regeneration runs both channels.** Every recipe gets
  from-identity generation (zero-token) and, where a launch spec exists
  and the harness is available, from-capture generation — the four
  generation columns start empty and expose which channel is missing per
  combo. Files are replaced in place as regeneration lands (never
  deleted). Darwin rows are queued with `platform='darwin'` (committed
  queue; popped on macOS); windows rows run on this host;
  `reasonix-deepseekflash-deepseekv4flash` is capturable here.
- **P8 — new `invalid` table; no-launch-spec is invalid, not queued.**
  Premise: every identity should also be capturable; a recipe without a
  launch spec is an anomaly to remedy later (support may be added, or
  the id may be a typo). Columns: `fixture_id`, `agent_id`,
  `harness_id`, `provider_id`, `model_id`, `platform_id` (raw strings as
  discovered — they may be invalid; the consolidated plan may add
  `reason`/`created_at`). **Only the dev agent reads it.** Nothing else
  does. Queue, pending, and fixtures tables contain only correct/known
  ids, so pops never choke. Applies anywhere invalid ids surface:
  no-launch-spec under from-capture, `--missing-fixture-entry`
  discoveries, seed-expansion anomalies.

## Keepers from A (the "bad ideas" plan) — final disposition

1. reasonix availability correction — **adopted** (user-confirmed,
   launch-spec detail verified).
2. Committed store + platform-aware popping — **adopted** (P1/D11).
3. `agent_detect_version` as table column + table-universe
   `--stale-by-detection` — **adopted** (P2).
4. Pop-time staleness conjunction ("skip only when every marker is
   fresh") — **adopted** (later extended with the hash term).
   The `--partial` guard is **moot**: followup 5 removed `--partial`
   entirely (all persisted rows carry defined ids) and replaced it with
   `--stale-by-hash` (named `--divergent-hash` in followup 5, renamed in
   followup 6).
5. "raw is slim" tightening (drop the `raw.harness_version` allowance;
   fixed raw key set) — **adopted** (B had overlooked it).
6. DB-vs-fixture-file duplication map — **superseded** by the P3/P4/P6
   column set; the consolidated plan redraws it.
7. Backfill stale-marker gating fix — **moot** (no backfill at all).
8. Janitorial: `assertNotInAgent` comment fix, AGENTS.md
   harness-config simplification, validation greps, commit grouping —
   **adopted**.
9. Origin-drop — **adopted in modified form** (P4 replaces it with the
   generation columns rather than inferring from `raw.evidence`).

## Rejected from A (for the record)

- D7 synthetic detect-ladder test — user: awful idea; no replacement.
- D3 folding availability into a single `success` column and removing
  `available` — user: persist both, in both tables.
- D4 `git rm` of the 160 fixtures — user: queue regeneration instead.
- D9 all-identity-only regeneration — user: both channels run (P7).

## Consolidated direction (input to the followup implementation plan)

Base = neither plan wholesale; the consolidated plan combines:

- **From A:** committed store, platform-aware popping, table-column
  `agent_detect_version` + table-universe `--stale-by-detection`,
  staleness conjunction + `--partial` guard, raw-is-slim tightening,
  migration shape (commit the recreated DB), janitorial + validation
  greps, commit grouping.
- **From B:** nothing survives unamended except the shared ground and
  the token-heavy capture sweep concept (absorbed into P7's both-channel
  regeneration). B's queue-time probe filter, queue-time backfill,
  file-key version stamp, origin retention, and evidence-check retention
  are all superseded.
- **New from this register (neither plan):** `available` + `successful`
  on both tables with four pure-enqueue flags; the four per-channel
  generation columns; the `pending` table + `queue_id` + daemon-purity
  protocol; derived `agent_id`/`fixture_id` columns; the `invalid`
  table; the `--missing-fixture-file` / `--missing-fixture-entry` split;
  both-channel regeneration with zero deletions.
- **Schema delta vs today:** `queue`: +`queue_id`, +`successful`,
  +`stale_by_detection`, mode default `'from-capture'` (keeps
  `available` as marker). `fixtures`: +`available`, +`successful`,
  +`agent_detect_version`, +`identity_generation_at`,
  +`identity_generation_hash`, +`capture_generation_at`,
  +  `capture_generation_hash`, +`agent_id`, +`fixture_id`. New tables:
  `pending`, `invalid`. Fixture file: no `origin`, no version key, no
  root `trailer` — per followup amends the envelope is reshaped to
  `from-identity` / `from-capture` / `from-capture-raw`, with each
  channel object carrying `identify` + both trailer variants (see the
  consolidated plan's "Fixture file shape" section).
- **Migration:** local queue rows are stale and the fixtures table is
  empty → clear the queue, recreate the schema, commit the fresh DB.

## Validation

- Register closed — no open cells remain.
- The followup consolidated implementation plan must satisfy
  user-decided items 1–4 and every "Decisions landed" entry without
  exception, and must carry a Provenance section per the AGENTS.md
  kilo.md plan-provenance tweak (corrected from "kimi" — see the
  pre-implementation task).
- Implementation-side validation (build/test greps, DB pragma checks,
  behavior checks) is delegated to the consolidated plan; A's task 13
  grep list is the starting point, updated for the new column/flag set
  (e.g. zero `from-raw` matches; `--missing-fixture` gone;
  `successful`/`available` present on both tables; `pending`/`invalid`
  tables present).

## Out of scope

- Implementing the strip itself (this file is comparison + decisions).
- Amending the two compared plans (left as historical records).
- The consolidated implementation plan's task breakdown (next step).
