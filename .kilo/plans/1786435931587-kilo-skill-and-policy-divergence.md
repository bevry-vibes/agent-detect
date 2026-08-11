# Move kilo plans into bevry-vibes/skills `kilo.md` + fix ai-policy.md/policy.md divergence

## context

- `agent-detect/AGENTS.md` inlines a `## kilo plans` section (lines 41–47). It must move into the skills repo as `kilo.md`, structured like `minimax.md` — **heading/intro structure only, no reference to minimax inside kilo.md** (user-confirmed).
- Skills repo pulled to latest: `88c90b6` changed minimax's intro from "for agent detection" to "for agent identification" (`agent-detect cooked` → `agent-detect identify`). `kilo.md` must use the same intro line.
- Divergence: `agent-detect/AGENTS.md` and `DESIGN.md` reference `ai-policy.md`, but the skills repo file is `policy.md`. **User-confirmed: `policy.md` is canonical (it is what the skills repo uses); `ai-policy.md` is the typo.** This supersedes the contrary decision recorded in prior plan `1786226348740-rename-reciprocity-trailers-help.md` line 59. The `ai-policy.md` URL in AGENTS.md is currently a dead link and must be corrected to `policy.md`.

## decisions

- `kilo.md` lives at `/Users/balupton/Projects/vibes/skills/kilo.md` with minimax's heading/intro structure:
  - `# Kilo` + intro line + `##` subsection gated on harness + `###` rule gated on harness.
- Intro line matches minimax.md after pull: `Use [agent-detect](https://github.com/bevry-vibes/agent-detect) for agent identification (harness, provider, model).`
- Rule body stays verbatim from AGENTS.md lines 43–47.
- `agent-detect/AGENTS.md`: remove the inline `## kilo plans` section, add a URL-only `kilo.md` reference bullet in the same pattern as the minimax bullet.
- Divergence fix direction: **no skills-repo rename.** Align agent-detect's references to `policy.md`:
  - `AGENTS.md` policy bullet URL + prose `ai-policy.md` → `policy.md`.
  - `DESIGN.md` line 8 link `ai-policy.md` → `policy.md`.
  - Skills `README.md` already references `@./policy.md` correctly — untouched.
- Skills README gains a `kilo.md` line (precedent: the "add minimax tweaks" commit `723f078` updated README when minimax.md was added).
- Commits: one logical commit per repo, co-author trailer generated via `./zig-out/bin/agent-detect trailer co-author` and attached with `git commit --trailer "$(...)"` (never guess/cache). The agent-detect "kilo plans" commit includes this plan file. Push both repos so the AGENTS.md URLs resolve.

## task list

### A. skills repo — add `kilo.md`

1. Create `/Users/balupton/Projects/vibes/skills/kilo.md`:

```md
# Kilo

Use [agent-detect](https://github.com/bevry-vibes/agent-detect) for agent identification (harness, provider, model).

## Kilo plans

Unless your harness is `kilo`, ignore these rules.

### Commit plan files alongside the work they drive

Unless your harness is `kilo`, ignore this rule.

When the running harness is `kilo`, commit the session's
`.kilo/plans/*.md` plan file(s) alongside the work they drive — a plan
is part of the change it plans, not scratch. Stage and commit them in
the same logical unit as the implementation, with the same co-author
trailer.
```

2. `skills/README.md`: after the minimax line (line 18) add
   `- @./kilo.md our instructions for Kilo plan handling`

### B. agent-detect repo — kilo plans reference

3. `AGENTS.md`: delete the `## kilo plans` section (lines 41–47). After the minimax bullet (line 20) add:

```md
- https://github.com/bevry-vibes/skills/blob/main/kilo.md —
  **applies** when the running harness is `kilo` (its rules gate
  themselves on harness).
```

### C. agent-detect repo — policy divergence fix (`ai-policy.md` → `policy.md`)

4. `AGENTS.md` line 6: URL `.../blob/main/ai-policy.md` → `.../blob/main/policy.md`; line 8 prose `ai-policy.md delegates to` → `policy.md delegates to`.
5. `DESIGN.md` line 8: `[ai-policy.md](https://github.com/bevry-vibes/skills/blob/main/ai-policy.md)` → `[policy.md](https://github.com/bevry-vibes/skills/blob/main/policy.md)`.

### D. commits + push (each commit with the generated co-author trailer)

6. skills repo, one commit: `kilo.md` + README kilo line (message like `feat: add kilo plan handling skill`).
7. agent-detect, commit 1 (kilo plans move): `AGENTS.md` kilo changes + this plan file (`.kilo/plans/1786435931587-kilo-skill-and-policy-divergence.md`), staged together.
8. agent-detect, commit 2 (divergence fix): `AGENTS.md` policy bullet + `DESIGN.md` policy link.
9. Push both repos (`git push`).

## validation

- `rg -n "ai-policy" /Users/balupton/Projects/vibes/agent-detect --glob '!**/.kilo/**'` → no matches (AGENTS.md + DESIGN.md clean).
- `rg -n "policy\.md" /Users/balupton/Projects/vibes/skills/README.md` → the two existing `@./policy.md` lines, unchanged.
- `agent-detect/AGENTS.md` contains exactly one `kilo.md` bullet and no `## kilo plans` section; all skill URLs follow `bevry-vibes/skills/blob/main/...`.
- `kilo.md` mirrors minimax.md's heading/intro/gating structure and contains no minimax reference.
- Every referenced URL exists: `bevry-vibes/skills/blob/main/{policy,commits,minimax,kilo}.md`.
- Trailer generated fresh via `./zig-out/bin/agent-detect trailer co-author` for every commit; `git log --format='%(trailers)'` shows it.
- `git status` clean in both repos after push.

## out of scope

- Any skills-repo policy rename (canonical name stays `policy.md`).
- Broader `bevry-labs` org / `agent-detection` name / `blob/master` staleness in consumer repos (icon-maker-*, kagi-assistant-client, zig-sqlite-compare) — separate cleanup.
- Content changes to `policy.md`/`minimax.md` prose.
- Updating the now-superseded decision note inside historical plan `1786226348740-...` (plans are historical, leave unchanged).
