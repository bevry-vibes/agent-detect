# `agent-detect registry` + `agent-detect index` — the registry CLI, round two

Written 2026-09-30, on the linux host, on `main`. Successor to the `web` command plan
(1790692000484), revised after three reviews. `web` becomes `registry` with a wider filter set
and JSON-first output; a new `index` command exposes the rule registry with cross-array
association filtering; the map CSVs fold into ONE committed index file whose entries are the
from-identity fixture's own per-entity identify fields; `fixtures` drops the platform dim from
from-identity work where it never had an effect; and the site shows **from-identity results
only** — plain static platform pills on an always-single-line status row.

## goal

Five work items:

1. **`web` → `registry`** —
   `agent-detect registry --{harness,provider,model,agent,email,platform,free,reciprocal}= --web/json`.
   Filters: `--agent=<id>` (3- or 4-part id, direct to the result page), `--email=<addr>`,
   `--platform=<plat>` (combos declared on that platform), `--free` / `--no-free`
   (`--free=false`), `--reciprocal` / `--no-reciprocal` (`--reciprocal=false`). All become real
   URL filters (`?platform=`, `?email=`, `?free=`, `?reciprocal=`) on the SPA's registry
   section and `/index.json`. `?platform=` is dropped on the RESULT page — there it selects
   nothing.
2. **new `index` command** —
   `agent-detect index --{harness,provider,model,platform,free,reciprocal}= --web/json`.
   Emits the index file (filtered): every harness, provider, and model with the from-identity
   fixture's own per-entity fields, its canonical alphanumeric id, and its associations.
   Filters narrow ALL THREE arrays by association membership: `index --harness=cline` yields
   `.harnesses[](.id == 'cline')` and `.{providers,models}[](.harnesses.includes('cline'))`
   — only what is available for that harness. Purpose: consumers map any name/variation → the
   canonical id and see what is available and how it associates.
3. **the map CSVs fold into the index file** —
   `fixtures/map-*-*.csv` (harness-provider pairs, provider-model cells, free membership) are
   replaced by the committed `fixtures/index-data.json` — the SAME shape the command emits —
   which also carries per-combo fixture facts (platforms, reciprocity) so `--platform`/
   `--reciprocal`/`--free` can filter anywhere, released binary included.
4. **from-identity drops platform** — `--platform=` with `--from-identity` is exit 3
   (queue and dequeue): `expandEntry` works only host-platform candidates and identity files are
   host-stamped (`fixtureId` appends `core.platformId()`), so a platform filter can never change
   what any host mints — it only skews `remaining_anywhere` and can delete an entry while other
   platforms' candidates live.
5. **site shows from-identity results only.** The site has no business rendering the
   from-capture channel — that is the maintainer's live-verification device, and nothing in the
   site's mandate ever asked for it (the both-channels merge was the site implementation's own
   invention, and it is what produced the "platform - declared/captured" tabs). Every
   consumer-visible surface — result page sections, platform pills, combos rows, agents data
   files, `/identify/<id>.json` — is the from-identity channel; from-capture stays in the repo
   files and the dev surface. The status row reads `reciprocal` · `linux` `macos` `windows` ·
   `date` — pills are plain platform names, static, and the reciprocal · pills · date row never
   wraps on mobile.

## the index file (`fixtures/index-data.json`)

ONE type everywhere: this committed file, the `index` command's output, and the site's
`data/index.json` are all the same `IndexFile` (the earlier draft's IndexData/IndexFile split
had no technical reason to survive). Schema, mirrored into `site/src/lib/registry.ts`:

```ts
type Platform = "darwin" | "linux" | "windows";

/** fixtures/index-data.json — the association + property source of truth (the map CSVs'
 * successor), embedded in the released binary, served as data/index.json, and emitted
 * (filtered) by `agent-detect index`. One shape everywhere. */
interface IndexFile {
  harnesses: HarnessEntry[];
  providers: ProviderEntry[];
  models: ModelEntry[];
  /** the free axis — each provider's free models (was map-provider-model-freeprovidermodel.csv,
   * whose provider→models rows this map mirrors 1:1) */
  provider_map_to_free_models: Record<string, string[]>;
  /** per-combo fixture facts from the from-identity channel — absent = never declared.
   * This is the data behind `index --platform`/`--reciprocal`: the released binary ships
   * no fixture channels, so declared platforms and reciprocity of record must be baked
   * in. Refreshed by `agent-detect-dev fixtures index`; `--check` pins freshness. */
  agent_map_to_platforms_reciprocal: Record<string, { platforms: Platform[]; reciprocal: boolean }>;
}

/** Each entry's fields are the from-identity fixture's `identify` block for that entity
 * (the per-entity slice of the 29-field contract, fixtures/fixture.d.ts), unprefixed —
 * minus the instance state that is not present in declared fixtures (the `*_setting`
 * fields, the per-entity `*_reciprocity` deductions, and the combo-level
 * `agent_id`/`reciprocal`) — plus `variations`, which the index's name/variation → id
 * job needs and the per-combo fixture has no use for. */
interface HarnessEntry {
  label: string;
  short_title: string | null;
  name: string;
  id: string;
  license: string | null;
  open_training: "enforced" | "opt-in" | "opt-out" | "never" | "NOASSERTION" | null;
  closed_training: "enforced" | "opt-in" | "opt-out" | "never" | "NOASSERTION" | null;
  reciprocity_scandal: boolean;
  variations: string[];
  providers: string[]; // direct harness-provider feasibility (was harnessprovider.csv)
  models: string[];    // closure over its providers' cells
}

interface ProviderEntry {
  label: string;
  name: string;
  id: string;
  open_training: string | null;
  closed_training: string | null;
  reciprocity_scandal: boolean;
  variations: string[];
  harnesses: string[]; // direct pairs (mirror of the harnesses' side)
  models: string[];    // direct cells (was providermodel.csv)
}

interface ModelEntry {
  label: string;
  short_title: string | null;
  name: string;
  id: string;
  openness: string | null;
  open_training: string | null;
  closed_training: string | null;
  license: string | null;
  variations: string[];
  providers: string[]; // direct cells (mirror)
  harnesses: string[]; // closure: harnesses reaching this model
}
```

Association arrays are plain canonical-id arrays, name-sorted, always computed from the FULL
data — never narrowed by the query's own filters. The hand-maintained facts are the direct
ones (harness `providers`, provider `models`) and `provider_map_to_free_models`;
`agent-detect-dev fixtures index` regenerates everything else in place — entity fields from
the rule tables (the same mapping `buildCooked` already performs), the mirror + closure
directions, and the `agent_map_to_platforms_reciprocal` section from `fixtures/from-identity/`
— so a hand-edit stays
one fact, and `--check` pins file-vs-tables-vs-channels freshness for the tests. Migration:
the implementation converts the CSVs' content into the initial file (verified by the
repointed tests and an unchanged `fixtures status` output), then the CSVs are deleted — see
the rollout order below.

## decisions

1. **Rename with a quiet alias.** `web` still dispatches (to registry semantics) so
   scripts/URLs born with 2026.9.30-1 keep working; `help web` prints a one-line rename notice
   then the registry usage. `--no-open` is gone (opening is opt-in via `--web`); it exits 2
   with a hint. Docs stop advertising `web`.
2. **Shared output semantics, JSON-first (both commands).** Default: JSON on stdout, no
   browser. `--web`: also open the site (platform opener, exit 6 when absent). `--no-json`: no
   stdout at all — exit status only. `--json`/`--no-web`: accepted explicit no-ops. The four
   flags are validated to `registry`/`index` — anywhere else is exit 3 (the `--platform=`
   pattern).
3. **`registry` URL contract.** The filters
   `--harness/--provider/--model/--email/--platform/--free/--reciprocal` compose freely →
   `/?harness=..&provider=..&model=..&email=..&platform=..&free=true&reciprocal=false#registry`
   (anchor iff any filter given; dims resolve via `canonicalFilterDim` — unresolvable is exit
   7; platform validates against darwin/linux/windows — exit 2). `--agent=` is exclusive: with
   any filter it is exit 3; alone (or with all three dims, unchanged) → `/?agent=<id>`.
   `--agent`/`--email` are shape-checked only — the CLI has no fixture data, existence is the
   site's verdict. Default JSON: `{ url, query, opened }` with canonicalized values.
4. **Filter semantics (both commands' new filters; index especially).** Each filter is a
   predicate over feasible combos (harness pairs × provider cells): dim filters match their
   dimension's id; `--platform=P` requires the combo declared on P; `--free` requires the
   (provider, model) cell to be in `provider_map_to_free_models`; `--reciprocal`/
   `--no-reciprocal` require the combo's reciprocity of record true/false. Given flags AND
   together; with no flags everything qualifies. Then each of the
   three arrays keeps the entries participating in ≥1 qualifying combo, while association
   lists stay full — `providers[].harnesses` still shows every harness a provider
   serves, not just the filtered one. The `combos` section emits filtered to the qualifying
   combos. Unresolvable ids in the file are skipped (the known_fixtures tests keep alignment).
5. **`index --web`** composes `siteUrl/?<dims>#index` — the site's index section honors the
   three dim params; `--platform/--free/--reciprocal` are JSON-output filters (their website
   parity lives on the registry view, where combos live).
6. **Site index section.** A homepage section `#index` beside `#registry` (same anchor nav, no
   new routing) fed by `data/index.json` (the committed file, copied by `build_data.ts`; the
   site's live combos stay in `combos.json`): three lists — label, name, mono id (the mapping
   consumers came for), variations, compact policy badges, association counts; a click filters
   the registry section (the existing dim jump); the section applies the resolved `?dim=`
   filters to its own lists. `registry.json` and the SPA's existing `Rule` lookups stay
   as-is — the index types are additive.
7. **Result page: from-identity only, plain pills.** The status row reads `reciprocal` ·
   `linux` `macos` `windows` · `date` — pills are the plain platform names of the combo's
   from-identity fixtures, clicking does nothing, and `?platform=` never reaches the agent page
   (the props die with the tabs). Below, one section per declared platform (pill heading = the
   platform name only — no channel vocabulary anywhere on the page), showing that platform's
   from-identity fixture with its recorded outputs + meta. Site-wide: `build_data.ts` emits the
   identity channel only — combos rows (values, platforms, fixtures) and `agents/<agent_id>.json`
   derive from `fixtures/from-identity/` alone, the `channels` field dies, and a combo with no
   identity fixture does not appear until declared. from-capture files stay maintainer-side
   (repo + dev surface, staleness comparisons unchanged).
8. **Single-line status row.** Reciprocal tag + platform pills + date become one shared
   component used by the agent page header row AND the results-table mobile card line;
   container-query font sizing (`100cqw`, `whitespace-nowrap`) shrinks the line instead of
   wrapping — `flex-wrap` leaves the agent page row.
9. **Registry filters on the site.** `parseURL`/worker gain `email` (exact, case-insensitive),
   `platform` (must be a known platform, else dropped with a notice), `free`, `reciprocal`
   (`true`/`false`); all land in `resolved` and the row filter. FilterBar gets two tri-state
   toggles (reciprocal: any/yes/no; free: any/free/paid). `combos.json` rows gain `free`
   (from `provider_map_to_free_models`) so the SPA/worker need no extra lookups.
10. **from-identity drops platform.** Explicit `--from-identity` rejects `--platform=` and
    `--fixture=` (whose id bakes a platform in — use `--agent=`) with exit 3, on queue and
    dequeue; expansion ignores any stored platform on identity entries so legacy queue rows
    degrade gracefully; usage text updated.
11. **Exit codes.** `registry`: 0 ok · 2 unrecognised argument (bad `--platform` value,
    `--no-open`) · 3 conflicting argument (`--agent` with a filter; the output flags elsewhere)
    · 6 opener absent/failed · 7 unresolvable dim or malformed `--agent`. `index`: 0 · 2 · 3 ·
    6 · 7 (dim resolves to no rule). Both keep the dims-block convention on 7.
12. **Tests.** `src/web.test.zig`: rename + the new URL shapes/conflict pins. New
    `src/index.test.zig` (wired into build.zig): the cross-array filter rule from the goal
    (`--harness=cline` → the exact three-array assertion), free/platform/reciprocal scoping,
    association completeness + closures, name-sorting, entry fields == the fixture contract's
    per-entity fields (minus instance state, plus variations). `src/exit_statuses.test.zig`:
    new 3/7 pins. `src/index_store.test.zig`: `--from-identity --platform=` → 3; expansion
    ignoring stored platform on identity entries. known_fixtures: grid/free alignment tests
    repoint from the CSVs to the index file. A freshness pin runs `fixtures index --check`.
    Site: `deno task check` green; `deno task build` + `deno task dev` manual pass (restart
    wrangler after the vite build), result page + registry filters eyeballed at 360px.

## surface

```
agent-detect registry [--harness=H] [--provider=P] [--model=M] [--agent=ID] [--email=E]
                      [--platform=PL] [--free|--no-free] [--reciprocal|--no-reciprocal]
                      [--web] [--no-web] [--json] [--no-json]
agent-detect index    [--harness=H] [--provider=P] [--model=M] [--platform=PL]
                      [--free|--no-free] [--reciprocal|--no-reciprocal]
                      [--web] [--no-web] [--json] [--no-json]
```

`web` aliases `registry`; `--no-open` is removed. Boolean filters take the bare, `=true`,
and `--no-` forms.

## files

- `fixtures/index-data.json` — new committed index file; the three `map-*.csv` deleted
  (rollout order below)
- `build.zig` — `@embedFile` the index file into both options modules; test list gains
  `src/index.test.zig`
- `src/lib/index_data.zig` — new: parse the embedded JSON, combo-qualification + association
  queries, entry emission (the `buildCooked` field mapping, reused per entity)
- `src/lib/core.zig` — `registryUsage` (ex-`webUsage`), `indexUsage`, URL builder extended,
  `buildIndexJson` (+ filter evaluation)
- `src/main.zig` — `registry`/`index` actions + `isKnownAction`, `web` alias, the new flag
  parsing/validation, `runRegistry`/`runIndex`, usage text
- `src/dev/dev.zig` — `FeasibilityGrids` derives pairs/cells from the entries and `FreeGrid`
  from `provider_map_to_free_models` (same semantics, same structures); new `fixtures index`
  action
  (+ `--check`); from-identity platform rejection; usage text
- `src/web.test.zig`, `src/index.test.zig`, `src/exit_statuses.test.zig`,
  `src/index_store.test.zig`, `src/known_fixtures.test.zig`
- `site/tools/build_data.ts` — copy the index file to `data/index.json`; identity channel
  only; `free` on combo rows; `channels` field dies
- `site/worker/index.ts` — `/index.json` gains `email`/`platform`/`free`/`reciprocal`
- `site/src/lib/registry.ts` — `IndexFile` + entry types; identity-only row shapes; filter
  helpers
- `site/src/App.tsx` — the four registry filters; platform leaves the agent-page props; the
  `#index` section
- `site/src/components/agent-page.tsx` — identity-only sections, plain pills, shared status row
- `site/src/components/results-table.tsx` — card line uses the shared status row
- `site/src/components/filter-bar.tsx` — reciprocal/free toggles
- docs — README (registry/index examples, opener note), DESIGN.md (CLI surface, website
  section, optional deps, exit registry), site/README (routes + command name), llms.txt (grep
  `web`/csv), AGENTS.md (site section: the index file as consumed data; zig section: five
  files)

## rollout order (the daemon reads the grids every poll)

`daemonPick` reloads the grids per poll, so the running daemon breaks if the CSVs vanish
underneath it. Land in two commits: (1) everything except the CSV deletion — index file
committed, all readers switched, tests repointed; then `zig build dev` and write `restart` to
`fixtures/daemon.ctl`, confirming the daemon reboots onto the new build; (2) `git rm` the
CSVs.

## release

CLI lands on `main` with `zig build test` green; the site needs `deno task build` + the
maintainer's authenticated `deno task deploy` (credentials are maintainer-side). Calver cut
covers the CLI; the site deploys independently of the tag.

## provenance

Every prompt that shaped this plan is recorded verbatim in the companion file
`.plans/1790730916816-registry-index-commands.prompts.md`. Agent model: GLM-5.3 Flash
(reported by the harness).
