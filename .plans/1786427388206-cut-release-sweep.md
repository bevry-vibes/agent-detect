# Cut release `2026.8.11-1` — fixes, todos, release

## Decisions (resolved with user)

**1. License semantics — SPDX keywords (user-directed, per spdx.github.io/spdx-spec/v2.3):**

| `harness_license` | meaning | reciprocity |
| --- | --- | --- |
| `null` | no data available | `.unknown` (check-reciprocal exit 9) |
| `"NOASSERTION"` | attempted, inconclusive | `.unknown` (exit 9) |
| `"NONE"` | concluded: no license present (verified proprietary/closed) | `.not_reciprocal` (exit 10) |
| SPDX id (`MIT`, `Apache-2.0`, …) | open license | computed as today |

`NONE` forces `.not_reciprocal` even when model/provider dims are null.

**2. cursor + copilot**: `license = "NONE"` + sourced URLs (web-verifiable, no harness
runs). Cursor sources confirmed: `https://cursor.com/` +
`https://www.cursor.com/en-US/terms-of-service`.

**3. Evidence redaction — `<redacted>` literal (user chose option B)**:
env-source evidence claims on non-allowlisted env vars carry `value: "<redacted>"`.
With the raw slimming (decision 4) the `present` field disappears anyway.

**4. Raw slimming (user un-queued this)**:
drop the `env` object and the file objects (config_files + session_files top-level
raw keys) from the raw block — the evidence section documents the sources. Raw
keeps: `platform_id`, `detectable`, `detected`, `process_lineage`, `harness-urls`,
`provider-urls`, `model-urls`, `evidence` (+ optional rule-declared
`harness_version`).

**5. kimi catalog expansion is IN this release** (user chose include).

**6. Harness-version tracking (user-directed):**
- `fixtures queue --stale` **only stamps queue entries marked stale** (age
  threshold + version marker) — no queue-time evaluation. **Remove the
  queue-time `isStale` age pre-filter** (main.zig:4713-4716).
- The **daemon evaluates** at pop: age (stored threshold) AND version (live
  `--version` call vs the fixture's captured `harness_version`); skips only when
  both are fresh.
- New `--stale-by-version` flag: queues the candidate rows with the version
  marker only.
- Version is captured **only** via a live `--version` call during a refresh,
  stored in a new `fixtures.harness_version` column. No cooked/raw schema change,
  no `HarnessRule.version` population ("no other reasons to capture the version").
- Comparison = string mismatch → stale (semver/calver "newer" comparator is a
  refinement, out of scope).

**7. from-capture follow-up is moot**: its target harnesses are all pending
harnesses (excluded).

## Sweep recap (verified this session)

- `zig build test`: 18/18 pass, exit 0 (`failed command … --listen=-` is a
  cosmetic zig-0.16 test-protocol artifact).
- `zig build dist --prefix .`: all 6 binaries emit. Remote reachable; only
  `nightly` exists (first `latest`). Local `main` is 30 commits ahead of
  `origin/main`; the runbook push covers it.
- **Evidence sweep**: 131 fixtures carry env-source evidence claims on
  non-allowlisted env vars — `OMP_API_KEY` 56, `KILO_API_KEY` 17,
  `OPENCODE_API_KEY` 16, `CRUSH_API_KEY` 16, `QWEN_API_KEY` 10, `CURSOR_API_KEY`
  7, `COPILOT_ALLOW_ALL` 4, `VIBE_API_KEY` 3, `REASONIX_API_KEY` 2. Current
  values are the harness names (`crush`, `cursor`, …), not real secrets — the
  fix is representational.
- **161 fixtures total** (148 from-raw + 13 from-capture: cline 4, pi 6,
  opencode 1, reasonix 1). The raw-slimming format change forces a full
  regeneration; the 13 from-capture fixtures get regenerated as from-raw
  (accepted consequence — follow-up re-captures them).
- 11 cursor/copilot fixtures carry `harness_license: null` (warnings only);
  recipe-mode `check-reciprocal` currently exits 9, becomes 10 after the fix
  (dotted canonical models: `gpt-5.2`, not `gpt-52`).
- All 13 harnesses installed; `--version` formats verified (bare semver,
  `v`-prefixed, `/`-separated, multi-line, calver+hash) — a generic scanner
  `\d+(\.\d+)+([-+][0-9A-Za-z.-]+)?` matches all.
- Top-level dev help (`devUsage`, main.zig:2580-2611) mentions `[scope flags]`
  but doesn't document them (user-reported gap).

## Work items (ordered; commit each logical unit with a fresh co-author trailer)

### 1. License semantics code change — `src/main.zig`
- Add consts `license_none = "NONE"`, `license_noassertion = "NOASSERTION"`.
- `reciprocityOf` (~2334): `"NONE"` → `.not_reciprocal` (before null checks);
  `null` / `"NOASSERTION"` → `.unknown`; else `computeReciprocal`.
- `computeReciprocal` (~2350): `false` for `null` / `"NONE"` / `"NOASSERTION"`;
  keep the conjuncts for real SPDX ids.
- Update doc comments: `HarnessRule.license` (~612), `computeReciprocal` (~2340).

### 2. cursor + copilot harness rules — `src/main.zig` (~705-708)
- `cursor`: `.license = "NONE"`, `.license_sources = &.{ "https://cursor.com/", "https://www.cursor.com/en-US/terms-of-service" }`.
- `copilot`: `.license = "NONE"`, `.license_sources = &.{ "https://github.com/features/copilot", "https://docs.github.com/en/site-policy/github-terms/github-terms-of-service" }` — verify the second URL resolves (else `https://formulae.brew.sh/formula/copilot-cli`).

### 3. Evidence redaction + raw slimming — `src/main.zig`
- **`buildRaw` (~2989)**:
  - Remove the `env` object emission (3015-3027).
  - Remove the `config_files` (3046-3054) and `session_files` (3055-3063) emissions.
  - Evidence emission (3074-3085): for `claim.source == "env"` and
    `!isEnvValueAllowed(claim.name)` → emit `value: "<redacted>"`; else emit the
    claim's redacted value as today. Keep `field` for config/session claims.
  - Keep: `platform_id`, `detectable`, `detected`, `process_lineage`, `*urls`,
    `evidence`, optional rule-declared `harness_version`.
- **`evidenceClaimsValid` (~5876)**:
  - Drop the `env` requirement (5882) and the env/config/session presence checks
    (5897-5910). Keep the `process_lineage` presence check.
  - Value match (5923-5924): `value == "<redacted>"` → accept (`continue
    :outer`); else `valueMatchesDim` as today. (Backward-compatible with old
    fixtures — their env-source secret claims carry the harness name, which
    still matches cooked.)
- **`RawObservation.env_vars/config_files/session_files`**: keep internally
  (detection + redaction decisions still use them); no JSON emission.

### 4. Harness-version tracking + `--stale-by-version` — `src/main.zig`
- **`fixtures` table** (schema ~3178, `FixtureRow` ~3243, `upsertFixture` ~3321,
  `selectFixtures`/`jsonToFixtures` ~3335/3343, `fixtureRow` ~3454): add
  `harness_version TEXT` (nullable).
- **`queue` table** (~3187, `QueueRow` ~3225, upsert ~3312, selects ~3365/3474,
  `queue_dedupe` ~3202, `validateQueueRow` ~3545): add `stale_by_version
  INTEGER`; include in the dedupe index; fold into the stale scope count.
- **Version call helper** (near `probeBinary` ~4390 / `harnessAvailable` ~4972):
  `harnessVersion(io, agent_id) ?[]const u8` — runs each recipe `probeNames`
  with `--version`, captures stdout, extracts the first version token with the
  generic scanner (verified against all 14 formats). Returns `null` when nothing
  runs or no token matches.
- **Queue-time enumeration** (`scopeCandidates` ~4703-4738):
  - `--stale`: remove the `isStale` pre-filter; queue candidate rows with
    `stale_by_days`/`stale_by_minutes` **plus `stale_by_version = 1`**.
  - `--stale-by-version` (new flag, parser ~4530-4560): queue candidate rows
    with `stale_by_version = 1` only.
  - `--all`: unchanged.
- **Daemon pop evaluation** (~5310-5358): for stale-marked rows, look up the
  fixture row, run `harnessVersion`, compare to `fx.harness_version` (uninstalled
  harness → inconclusive → not stale by version). Skip the capture only when
  age-fresh (if threshold set) AND version-equal.
- **Capture stamp**: after a successful from-raw/from-capture capture
  (~5397-5406), run `harnessVersion` and write it into `upsertFixture`. `from-ids`
  → null.
- **Dequeue** WHERE (~3505-3511): match `stale_by_version=1` for
  `--stale-by-version`.
- **fixturesUsage** (~2928-2943): `--stale` marker semantics; add
  `--stale-by-version`.

### 5. Scope-flag help docs — `src/main.zig`
- `devUsage` (2580-2611): add a scope-flags block (condensed from
  `fixturesUsage`) documenting `--all`, `--stale` (marker, daemon-evaluated),
  `--stale-by-version`, `--partial`, `--recipes`, `--missing-fixture`,
  `--available`, `--unavailable`, so `agent-detect-dev --help` documents them.

### 6. Cosmetic doc drift — `build.zig` (~34-38)
- Point the comment at CONTRIBUTING.md § "cut a release" (the DESIGN.md section
  doesn't exist).

### 7. kimi catalog expansion
1. **USER runs** `kimi provider catalog` (imports models.dev providers into
   `~/.kimi-code/config.toml`).
2. Implementer enumerates imported providers + models (`kimi provider list`,
   `~/.kimi-code/config.toml`).
3. Apply the ordering spec (all providers free → minimax all → deepseek all;
   `docs/evergreen-top50-models.txt`). Add missing provider/model rules +
   `recipesForFixtures` entries.
4. `zig build test` green at the checkpoint (old tests, old fixtures).

### 8. Full fixture regeneration (one sweep)
1. `zig build dev`.
2. Implementer deletes `fixtures/*.json` (161 files; the daemon backfills valid
   existing files, so deletion forces re-capture). The 13 from-capture fixtures
   regenerate as from-raw (accepted consequence).
3. Implementer: `./zig-out/bin/agent-detect-dev fixtures queue --recipes --from-raw --available`.
4. **USER runs** `./zig-out/bin/agent-detect-dev fixtures daemon --write-log`
   in a plain terminal (user-only; from-raw = zero tokens).
5. Implementer reviews fixtures as they land (evidence `<redacted>`, no env/file
   objects, `harness_license` values incl. `NONE`, `harness_version` stamped in
   the store); fix detection failures (`buildKimiEnv` for the new kimi combos) or
   trim recipes; re-run the daemon as needed.

### 9. Tests rework + new tests
- `src/known_fixtures.test.zig`:
  - Replace test 9 (env entries carry present) with: raw has **no** `env` object
    and no config/session file top-level keys (raw keys ⊆ `platform_id`,
    `detectable`, `detected`, `process_lineage`, `harness-urls`, `provider-urls`,
    `model-urls`, `evidence`); env-source evidence claims on non-allowlisted
    names are `"<redacted>"`; other env-source claims carry the read value
    (expose `isEnvValueAllowed` via the dev struct so the test can use it).
  - Update test 14 (pretty-print): drop the `"env": {` assertion; keep
    process_lineage + `*-urls`.
  - Update the null-`harness_license` warning test (~403): warn on `null` or
    `"NOASSERTION"` only.
- New `src/exit_statuses.test.zig`: `reciprocityOf` (null/NOASSERTION → unknown;
  NONE → not_reciprocal; SPDX+open-weight+opt-in → reciprocal; closed model /
  enforced provider → not_reciprocal) and `buildTrailerLine` (exact
  Co-authored-by/Assisted-by strings; null on missing identity).
- Add a version-extraction test for `harnessVersion` covering the 14 verified
  `--version` formats.
- Register in `build.zig` `test_files` (build.zig:105-107).
- `zig build test` green against the regenerated fixtures.

### 10. CI smoke asserts — `.github/workflows/build.yml`
- In all three jobs (smoke/nightly/release): `trailer co-author
  --harness=cline --provider=clinepass --model=kimi-k3` → exit 0;
  `check-reciprocal --harness=kilo --provider=deepseek
  --model=deepseek-v4-flash` → `is reciprocal`, 0;
  `check-reciprocal --harness=cursor --provider=cursor --model=gpt-5.2` →
  `not reciprocal`, 10.

### 11. Docs
- CONTRIBUTING.md: "add a new harness rule" license table (NONE/NOASSERTION);
  "refresh a fixture" fixture-format section (raw shape; evidence documents
  sources; `<redacted>`); scope-flags section (`--stale` marker semantics,
  `--stale-by-version`, version capture).
- DESIGN.md: raw block shape; license tri-state + cursor/NONE → 10 example;
  version tracking + `--stale-by-version` note.

### 12. Release (CONTRIBUTING.md runbook)
```sh
today=$(date -u +%Y.%-m.%-d)                            # 2026.8.11
rev=$(git tag --list "${today}-*" | wc -l | tr -d ' ')  # 0 → 2026.8.11-1
new_version="${today}-$((rev + 1))"
sed -i.bak "s/\.version = \".*\"/.version = \"${new_version}\"/" build.zig.zon && rm build.zig.zon.bak
git add build.zig.zon
git commit -m "release: ${new_version}" --trailer "$(./zig-out/bin/agent-detect trailer co-author)"
git tag "${new_version}"
git push origin main "${new_version}"
```
Then: `zig build && ./zig-out/bin/agent-detect --version` → `agent-detect
2026.8.11-1`; `gh release view 2026.8.11-1` shows latest; spot-check
`releases/latest/download/agent-detect-linux-x86_64`.

## Validation
- `zig build test`: exit 0, all tests pass, **zero** harness_license warnings.
- `check-reciprocal --harness=cursor --provider=cursor --model=gpt-5.2` →
  `not reciprocal`, exit 10.
- Regenerated fixtures: raw has no `env`/file objects; secret env evidence
  claims are `"<redacted>"`; cursor/copilot `harness_license` = `"NONE"`.
- `agent-detect-dev --help` documents the scope flags.
- Version flow: `fixtures queue --stale` writes marked rows (no pre-filter); the
  daemon skips fresh rows, captures stale/version-mismatched ones;
  `fixtures.harness_version` populated by captures.
- kimi: new recipes + from-raw fixtures committed.
- `zig build dist --prefix .` emits all 6 binaries; `--version` prints the new
  calver; the `release` job publishes `latest:true`.

## Risks
- **Full regeneration** downgrades the 13 from-capture fixtures to from-raw
  (accepted; follow-up re-captures via `from-capture` when the user confirms
  token spend).
- **Evidence-claim check weakens** for env sources (no presence verification
  without the env block); value-match + `<redacted>`-accept keep its core
  purpose ("no evidence", "evidence contradicts cooked").
- **Version extraction fragility** — generic scanner covers the 14 verified
  formats; per-harness override if a format drifts. Version calls invoke harness
  binaries at daemon pop/capture (zero-token).
- **`--stale` queues all candidate rows** — the daemon drains fresh rows without
  capturing; queue churn is expected and correct.
- **kimi from-raw failures** (partial detection) — fix `buildKimiEnv`/detection
  or trim recipes.
- **First `latest` release** — if the `release` job fails after tagging, fix and
  re-tag as `2026.8.11-2`; never force-push a tag.
- Fixture regen + kimi depend on user daemon runs (steps 8 and 7).

## Out of scope / follow-ups
- Pending harnesses (excluded): claude, codex, grok, gemini,
  amp/roo/qoder/openhands, devin/droid/zencoder/kimchi/firebender,
  continue/cody/windsurf.
- Re-capture the 13 downgraded fixtures via `from-capture` (user-confirmed).
- cursor/github-copilot provider training values (null) — optional polish.
- `NOASSERTION` has no current rule — semantic completeness only.
- Semver/calver "newer-than" comparator for the version check.
- Surfacing the captured version in cooked/raw JSON — excluded.
