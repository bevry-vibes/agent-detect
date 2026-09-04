Assisted-by: ZCode · GLM 5.3 <zcode-zcode-glm53@local>
(provenance companion: [upstream-skill-customisations.prompts.md](./upstream-skill-customisations.prompts.md))

# Upstream the generic skill customisations from agent-detect to bevry-vibes/skills

Two repos change, upstream first (so the remote URLs agent-detect references actually resolve):
**A)** `bevry-vibes/skills` gains three new skills (plans, powershell, zig), a splat-naming section in conventions.md, a README update, and loses `kilo.md`.
**B)** `agent-detect` shrinks its local copies to true per-repo tweaks per the meta.md pattern, and deletes `meta.md` (pattern moves to the upstream README).

Harness-config rule stays in AGENTS.md unchanged (your call), as does the token-cost section.

---

## Part A — bevry-vibes/skills (local checkout at `~/Projects/vibes/skills`)

### A0. Repair the stale checkout
- Remote still points at `bevry-vibe` (singular). Set it to `bevry-vibes/skills` via `gh auth token` HTTPS transport (SSH agent fails in this harness): `git remote set-url origin https://x-access-token:$(gh auth token)@github.com/bevry-vibes/skills.git`, then fetch/pull `main` to pick up `c99f0be` (upstream release-notes flow).
- Every commit below uses the system git identity + agent-detect co-author trailer (build agent-detect first: `zig build` in the agent-detect repo, then `./zig-out/bin/agent-detect trailer co-author`). Style: `<area>: subject`, one logical change per commit. Push direct to `main` (matches repo history).

### A1. New `plans.md` — commit `feat: add plans skill`
Generic form of agent-detect's plans.md, opening with the standard "Use agent-detect for agent identification" line:
- **where plans live** — `.plans/<epoch-ms>-<slug>.md` at repo root, never a harness-private dir; one chronological space shared across harnesses.
- **provenance companion** — `<plan>.prompts.md` alongside every plan: initiating + followup prompts verbatim/untruncated/in order, timestamps only where observable, agent model as the harness reports it; the plan links, never inlines.
- **no condensed proposals** — non-trivial design changes get a real proposal/comparison doc (options, examples, trade-offs, code-impact inventory) before any decision question; multi-choice questions alone are insufficient.
- **commit the plan before plan_exit** — plan + companion committed with normal commit discipline (build first, trailer) so plan history is traceable.
- **plan introductions carry the Assisted-by line** — generated with `agent-detect trailer assisted-by`, per the skill library's standard agent-detect usage (same treatment as commits.md's co-author mandate): never guessed or cached; if generation fails, fix it rather than proceed without it.
- **session summaries at handoff** — on context exhaustion/handoff, persist every compaction summary into `.plans/`. Includes the crush specifics, generalized: `.crush/crush.db` schema (`sessions`/`messages`; schema-comment-claims-ms-but-stores-epoch-seconds gotcha; main session = largest `message_count`), extraction (`is_summary_message = 1` ordered by `created_at`; body = concatenated `text` parts of the `parts` JSON; user prompts = user-role rows with a text part, excluding `function_call_response`-only rows), file naming `<created_at × 1000>-session-summary-<n>-of-<count>.md`, `WriteAllText` with LF joins (never `Set-Content`), the pitfalls list (mvdan/sh `$[0]` single-quote expansion, `[long]($obj.Prop)` parenthesization, nested-array `-join`, backtick escapes in double quotes, no `head`/`tail`/`ls -t` in mvdan/sh), and "`.crush/` is gitignored; never commit the DB".

### A2. Delete `kilo.md` — commit `kilo: retire in favour of plans`
Its only rule (commit `.kilo/plans/*.md` alongside the work) is subsumed by plans.md's commit-before-plan_exit, harness-agnostically. README reference removed in A5.

### A3. New `powershell.md` — commit `feat: add powershell skill`
- **7.6+ mandate** — `#Requires -Version 7.6`; prefer modern syntax: `&&`/`||`, ternary/null-coalescing (`?:` `??` `??=`), switch expressions, `ForEach-Object -Parallel`, typed classes, native `2>&1` capture.
- **Set-Content traps** — `-NoNewline` concatenates arrays back-to-back; plain `Set-Content` rewrites LF as CRLF (and `* -text` gitattributes means git won't fix it).
- **Targeted edits** — `Get-Content -Raw` + literal `.Replace` + `[System.IO.File]::WriteAllText` (UTF8 no BOM); `[regex]::Escape` needles when regex is unavoidable; verify `git diff --stat` stayed small.
- **IndexOf slicing over regex Replace** for large-block surgery (`RegexMatchTimeoutException` on big strings); anchor+slice helper pattern.
- **Stale line numbers** — anchor splices on unique content, not line numbers; re-verify boundaries after each splice.
- **LF/CRLF byte-count check** loop.
- **Generic sqlite3 CLI patterns** — `-json -batch` emits one JSON array line per row (even `PRAGMA` setters); `SELECT changes()` is connection-local so run it in the same invocation as the DML; fresh-store DML needs schema-ensuring first.

### A4. New `zig.md` — commit `feat: add zig skill`
Verified-against-0.16.0 facts only, de-projectified (no agent-detect paths/commands):
- `zig env` → `std_dir` stdlib grep tip.
- API deltas: `std.fmt.bytesToHex`; `std.Io.Dir.rename` (replaces existing target — atomic temp+rename pattern) vs `renameAbsolute`; `readFileAlloc` max-bytes is an enum (`@enumFromInt`); `/proc` pseudo-files read empty via `readFileAlloc` (`st_size = 0` → immediate EOF) — read through an explicitly buffered reader; `executablePath(io, &buf)` returns length; `std.process.spawn` `?Io.File` pipes + argv as `[][]const u8`; `std.Io.sleep` takes a clock; `Timestamp.now/fromNow` + `raw.nanoseconds`; Blake3 digest `[32]u8`; `std.json.Stringify.valueAlloc` + insertion-order-preserved round-trips; doc comments must precede declarations; no runtime `continue` inside `inline for`; `Dir.iterate()` yields immediate children only; `file.lock/tryLock` kernel-managed; lock-a-separate-lockfile + temp+rename so readers need no lock.
- Gotchas: never free an arena slice a returned value aliases (free-list recycles most-recent only); mutate `std.json` maps via `getPtr`, never a `get` copy (dangling header pointer); keep test asserts structural, not timing-based.
- Written clean (skips the duplicated line and superseded store-architecture relics the local file carries).

### A5. `conventions.md` + `README.md` — two commits: `conventions: add splat naming`, `readme: document the skills and the local tweaks pattern`
- conventions.md gains the splat-naming section verbatim from AGENTS.md (never `X`/`Xxx`/`XXX`; `build*Env`, `build<Harness>Env`, `build${HARNESS}Env` per language convention).
- README: list plans/powershell/zig in the reference flow, drop kilo.md, and add a "local tweaks pattern" section documenting what meta.md documents today (AGENTS.md is a pointer; a skill applying *with tweaks* gets a local `<name>.md` that references the remote URL and lists tweaks beneath; no-tweak skills stay plain remote bullets; non-application decisions stay AGENTS.md bullets with rationale).

---

## Part B — agent-detect (one commit: `docs: consume the upstreamed skills, keep local tweaks`)

### B1. `commits.md`
Delete the `## release notes` steps now duplicated by upstream c99f0be (gh run watch / gh release edit, draft-from-git-log never-invent, themed sections + compare link, delete artifact, verify with gh release view). Keep as tweaks: the CONTRIBUTING.md "cut a release" runbook pointer, and the workflow specifics (fixed body = stable-release pointer + `releases/latest/download/<asset>` note; `latest` set by workflow `make_latest: true`). Zig build targets + trailer command tweaks stay.

### B2. `plans.md`
Header becomes the standard upstream-reference line (replacing "bevry-vibes/skills has no plans.md skill yet…"). Keep only tweaks: the `.kilo/plans/` migration sentence, and the repo-path instantiation of the Assisted-by generator (`./zig-out/bin/agent-detect trailer assisted-by` — upstream now mandates the generic `agent-detect trailer assisted-by` form), plus the commits.md cross-ref.

### B3. `powershell.md`
Header gains the upstream reference. Remove the generic sections (Set-Content/line-endings, targeted edits, IndexOf slicing, stale line numbers, byte check, generic sqlite3 patterns). Keep: Tooling on this host (Kilo grep/glob broken, no rg, findstr fallback), the `.gitattributes * -text` repo fact, cleanup scoping (`fixtures dequeue --platform=`), reading test failures (177 legacy-fixtures regeneration signal), store-specific sqlite checks (`fixtures/index.sqlite3`, `queue` table).

### B4. `zig.md`
Header gains the upstream reference. Remove the generic API-delta list and generic gotchas (they now live upstream; keep one-line pointers where a repo cross-ref is useful, e.g. `readProcFile`). Keep: build/test loop targets, Patterns-this-repo-uses (import DAG, dev gate, `jstr`/`jint`, kernel32 externs, `readChildOutput`), repo gotchas (dev `build_options`, `ReleaseSmall` tests). Fix the duplicated "Never free an arena slice" line; prune superseded store-architecture relics while in there.

### B5. `AGENTS.md`
- Add a `conventions.md` remote bullet (applies — now carries splat naming); delete the `## splat naming` section.
- `## powershell`: drop the generic 7.6-mandate paragraph; keep the pointer to local powershell.md.
- `## zig`: keep the four-file-split paragraph + pointer to local zig.md.
- `## harness configuration` and `## token cost`: unchanged. commits/plans/minimax/policy bullets unchanged.
- Preamble "this process is documented in meta.md" line repointed at the upstream README section.

### B6. Delete `meta.md` (pattern now lives in the upstream README)

DESIGN.md's upstream commits.md URL stays valid (no change). The 5 historical `.plans/` files that mention these names are left untouched (plans are historical records). Commit after `zig build && zig build test` per the local commits tweak; push via gh-token HTTPS.

---

## Verification
- Upstream: `gh api repos/bevry-vibes/skills/contents` shows plans/powershell/zig present and kilo.md gone; fetch each new raw URL to confirm 200.
- agent-detect: `zig build test` green; grep confirms no local file still inlines upstreamed generic text; every remote URL referenced by AGENTS.md and the local pointer files resolves.