Assisted-by: ZCode · GLM 5.3 Flash <zcode-zcode-glm53flash@local>

# website ↔ cli json consistency, with typescript schemas

Companion: [.plans/1790792125916-website-cli-json-consistency-schemas.prompts.md](./1790792125916-website-cli-json-consistency-schemas.prompts.md)

Revised (prompt 15): the from-identity channel drops the platform dim; the data vocabulary unifies on "agent"; derived `counts` fields are dropped; the file/report/outputs naming taxonomy is stated; the `check-reciprocal` enum corrected against the shipped bytes.
Revised again (prompt 16): the from-identity reset is delete-and-regenerate rather than a content-merging sweep; the per-agent site envelope is eliminated — the identity fixtures are served verbatim; the capture serving boundary is explicit (D9).
Revised again (prompt 17): the dhi spike ran — zod stays (no zig↔ts schema sharing; see the approach section); the spike's strict validation against the shipped bytes caught two bugs in this plan's own schema draft (model entries never carry `reciprocity_scandal`; the agent map's keys are agent ids, not strict slugs) and fixed them.
Revised again (prompt 18): `agent-detect registry` is dropped — one `agent-detect index` with the search view and the four entity views (D10); filters gate entity views on the cli (exit 14 + per-filter stderr) and the web (422 + an explanation page linking the identity without the violating filters); the released-cli doc pass lands with it.
Revised again (prompt 19): the reset is staged for git — `git mv` the surviving copy per agent, fs-delete the rest, regen, all one commit, so rename detection pairs old→new.
Revised again (prompt 20): the agent entity input also accepts the trailer-email form — a trailing `@local` is stripped before resolution (cli and site alike).
Revised again (prompt 21): `FixtureOutputsSchema` gains the missing `identify.stderr` and `explain.stderr` (a `StderrLines` primitive shared with `check-reciprocal.stderr`) — the complete recorded stderr surface, three actions.

## the problem

The project speaks JSON in two places that must agree but currently only gesture at each other:

- the **cli** (zig) — the `identify` contract, the `index` action output (and, until M3, `registry`'s report), the fixture channels;
- the **website** (deno/vite/worker) — the static data files under `site/public/data/`, the worker api routes, and the spa's imported types.

The site's types (`site/src/lib/registry.ts`) are hand-written interfaces restating shapes that other files own normatively (`fixtures/fixture.d.ts`, `fixtures/index.d.ts`, `tools/build_data.ts`'s dump struct, `src/main.zig`'s report structs). Nothing validates one against another, and research found real drift (below). The repo already has the right instinct — `fixtures/index.d.ts` declares "TypeScript structure declarations are the SOURCE OF TRUTH … the zig program never imports TypeScript; this file is the normative shape humans and agents read instead of prose" — but that instinct stops at the fixtures directory.

Goal: **one typed schema per json format, stated in typescript, validated at every producer/consumer boundary, with the documented inconsistencies resolved.** Non-goal: making zig consume typescript (per the repo's own rule, zig never imports typescript — the zig side stays validated by its own tests plus golden files).

## the inventory — every json surface, who makes it, who reads it

| # | format | producer | consumers | normative source today | drift risk |
|---|--------|----------|-----------|------------------------|------------|
| 1 | `registry.json` (rule tables) | `tools/build_data.ts` (`zig run` dump of `src/lib/rules.zig`) | spa, worker (name resolution), the `index` action's docs | the dump struct inside build_data (by zig reflection) | silent: a new rules.zig field appears in the json untyped; site types hand-listed |
| 2 | `data/index.json` ≡ `fixtures/index-data.json` ≡ `agent-detect index` output | zig (`index_data.zig`) embeds; build_data copies verbatim | released cli (embedded), spa, worker | `fixtures/index.d.ts` describes the STORE, not this built output; site's `IndexFile` interface hand-written | naming collision (two "Index" types), store doc is stale (says free axis comes from map csvs — deleted in b08b893) |
| 3 | `agents.json` (was `combos.json`) | `tools/build_data.ts` (a projection: the identity fixtures + the capture stems + the index's free axis) | spa, worker `/index.json` | site's `ComboRow` interface | silent |
| 4 | `agents/<agent_id>.json` ≡ `/agent/<agent_id>.json` (today `/identify/`; renamed by D10/M3) | build_data (the from-identity fixture copied verbatim) | spa result page, worker route | `fixtures/fixture.d.ts` `IdentityFile` (normative!) but the site wraps it in an invented envelope restating the dims (#13); `FixtureOutputs.identify` is `Record<string, unknown>` | the 29-field identify contract is untyped on the site; the envelope violates the dims-only-in-the-filename rule |
| 5 | worker `/index.json` report | `site/worker/index.ts` | external api consumers, docs | nothing | envelope shape (params/resolved/count/truncated/results) undocumented; `results` rows gain `detail` when expanded — a variant nobody states |
| 6 | cli `registry` action report | `src/main.zig` `runRegistry` | agents scripting the cli | nothing | `{url, query, opened}` — `query` means resolved ids here but RAW echo on the website's `/index.json`. retired by the collapse (D10/M3) |
| 7 | cli `index` action output | `src/main.zig` `runIndex` → `idx.buildFiltered` | agents, the website (as #2) | same as #2 | it is the built index verbatim — no envelope — so any envelope added to the website's copy would fork the formats |
| 8 | cli `identify` / fixture `outputs.identify` | `core.buildCooked` | site fixtures display, `fixture.d.ts` `Identify` | `fixtures/fixture.d.ts` (normative, frozen by DESIGN.md #9) | site types it as `Record<string, unknown>` |

## the inconsistencies (researched, not hypothetical)

1. **`query` means two things.** cli registry report `query` = resolved canonical ids (it refuses to emit unresolved). website `/index.json` `query` = the raw param echo (display names, possibly unresolved) + `search`. The website separately exposes `resolved` (canonical + lowercased raw `search`). A consumer switching from cli to web breaks silently.
2. **platform aliases.** cli `--platform=macos|mac|win` canonicalizes (`canonicalWebPlatform`, main.zig:547: `macos`/`mac` → `darwin`, `win` → `windows`). the website's `resolvePlatform` accepts only exact `darwin|linux|windows` — `?platform=macos` 404s on the site while the same value works on the cli.
3. **stale store doc.** `fixtures/index.d.ts` still says the free axis is "declared by `fixtures/map-provider-model-freeprovidermodel.csv`" — those csvs were deleted (b08b893); the index file now embeds `provider_map_to_free_models` and `agent_map_to_platforms_reciprocal`.
4. **two "Index" types.** the site's `IndexFile` is the BUILT index (entries + the two maps); `fixtures/index.d.ts` `Index`/`IndexStore` is the committed store. same word, different shapes, different files.
5. **untyped identify on the site.** the 29-field contract is frozen in `fixture.d.ts` but the site's `FixtureOutputs.identify` is `Record<string, unknown>` — typos in displayed keys can't be caught.
6. **`ComboRow.state` is a bare string.** its values come from `explain.state` (`reciprocal` / `not-reciprocal` / `undetectable` / `unknown`) — unenumerated.
7. **the expanded-results variant is unstated.** worker `/index.json` embeds `detail` per row when the filter yields ≤ 50 rows (`EXPAND_CAP`), and swaps rows for compact rows with a `note` when truncated. the schema must state both variants or consumers guess.
8. **derived duplication.** `agent_map_to_platforms_reciprocal` (in the index) restates each agent's `platforms` + `reciprocal`, which `agents.json` also carries. fine (the cli embeds only the index), but the schemas must say which is authoritative (`agents.json`) so a validator can assert they agree.
9. **two verdict vocabularies.** `explain.state` (and agent rows) say `not-reciprocal` — hyphenated; the recorded `check-reciprocal` verdict says `"is reciprocal"` / `"not reciprocal"` — the stdout form with spaces (verified against the shipped bytes: 753 fixture occurrences, matching `fixture.d.ts`'s `"is reciprocal" | "not reciprocal"`). the first draft of this plan pinned `["reciprocal", "not reciprocal"]` — wrong against the bytes. the schema pins the recorded form; `explain.state` keeps its hyphenated form; both are stated.
10. **the from-identity platform split is pure noise — and it has already drifted.** 2,794 from-identity files cover 1,390 agents; 814 agents hold more than one platform copy. The channel never observes a host (`DeclaredRaw` carries no `platform_id`; the cli already refuses `--from-identity --platform=` — "the platform dim is capture-only"), so per-platform copies should be identical — and they are not: rule sweeps land per-platform (the 2026-09-29 sweep regenerated linux only; darwin/windows still carry 2026-09-07 generations), so 520 agents' copies disagree on identify content and verdicts conflict across copies (`kilo-minimax-minimaxm3`: linux not-reciprocal vs darwin/windows reciprocal; `cline-openrouter-qwen38flash` the reverse). The disagreements correlate with `meta.updated_at`, never with platform. The latest-wins tie-breaks in build_data and `scanIdentityCombos` exist only to paper over this self-inflicted drift.
11. **one noun, two words.** the same rows are "combos" in `combos.json`/`ComboRow` and "agents" everywhere else: rows are keyed `agent_id`, rendered as agent cards, served from `agents/<agent_id>.json` and `/identify/<agent_id>.json`, filtered by `--agent=`, exit 7 is "unknown agent", and the index map is `agent_map_to_platforms_reciprocal`. An agent IS the resolved harness×provider×model triple; "combo" survives only in DESIGN.md's queue prose (a candidate cell of the grid, pre-fixture). The data layer must pick one word.
12. **derived `counts` in stored files.** build_data emits `counts` into `registry.json` (read by nothing on the site) and `combos.json` (`counts.combos` read twice, both trivially `rows.length`; `counts.fixtures` read by nothing). A stored file restating lengths of its own arrays is a drift surface with zero value.
13. **the per-agent envelope restates the dims.** `data/agents/<agent_id>.json` wraps each from-identity fixture in a site-invented envelope carrying `agent_id`/`harness`/`provider`/`model` inside the file — violating `fixture.d.ts`'s own rule that "the filename is the only channel key, and the dims are never repeated inside the file". With D6 the filename IS the agent id, so there is nothing left for an envelope to say: the site should serve the fixture verbatim.
14. **the registry/index split.** one dataset, two actions, two contracts: `registry` prints a navigation report (`{url, query, opened}`) and never the data; `index` prints the data verbatim and rejects `--agent=` outright. the filters are duplicated across the two, the deep-link contract is split (`registry` → `#registry`, `index` → `#index`), and their usage texts drift separately (the `--agent=` "3- or 4-part" wording, "combos declared on that platform" in both). nothing on the site corresponds to the split — the site has one searchable section and one result-page kind per entity. one command, mapping onto the site's routes, is the resolution (D10).

## approach — options considered

| option | what | pros | cons |
|--------|------|------|------|
| A. normative `.d.ts` only | extend the `fixtures/*.d.ts` convention: a `site/public/data/data.d.ts` declaring every data-file shape; types only | zero dependencies; matches the repo's stated convention | no runtime validation — build_data and the worker still accept anything; drift caught by review only |
| B. zod schemas + inferred types (chosen) | `site/src/lib/schemas.ts`: one zod schema per format; types exported via `z.infer`; validation runs at the boundaries | runtime validation at every producer/consumer; type and validator from one declaration; zod v4 runs on deno, node, and in the vite bundle; errors name the exact field | one new dependency (`npm:zod`); schemas could drift from `fixtures/*.d.ts` — mitigated by a cross-check test |
| C. json schema + codegen | draft json schema documents, generate ts types | language-neutral (zig could read them too) | codegen pipeline; two artifacts per format; zig still wouldn't (per repo rule); heaviest |

B is chosen: the repo's boundary problem is runtime (build_data writes what zig reflected; the worker serves what build_data wrote), which types alone cannot catch. A's `.d.ts` convention stays authoritative for the fixture store — schema B cross-references it and a test asserts the field lists match.

**Validator spike — dhi instead of zod (prompt 17, evaluated 2026-10-06).** [dhi](https://github.com/justrach/dhi) pitches one zig SIMD core behind a Zod-4-compatible API. The spike swapped the full schema draft to `npm:dhi@1.7.0` and ran it against the shipped bytes under Deno: it works (first-class `deno`/`workerd`/`browser` export conditions; the core those entries serve is pure ESM JS — no WASM instantiation, no Node builtins, no top-level await; `z.infer` inference compiles under `deno check`; regex/enums/nullable/optional/`int().nonnegative()`/two-arg `record`/`passthrough` all behaved; errors carry dot-paths and codes). But the spike's verdict is **zod stays**:
- **the sharing claim doesn't hold for us.** dhi shares a validation *core* across languages, not a schema artifact: the zig side is a parallel, hand-written comptime API (`dhi.Model(...)` — Pydantic-style), and `tools/ts-to-dhi` converts TS types to dhi TS schemas, never to zig. Our zig side would keep hand-maintaining its own declarations — exactly today's situation, plus an experimental solo-project dependency. True one-artifact sharing (option C) stays rejected.
- **the core is inert on our runtimes anyway.** Deno, the Cloudflare workerd, and the vite bundle all resolve to the pure-JS core — the SIMD/wasm layer only runs under Node — and our validation is build-time on megabytes, not a hot path, so the performance pitch is irrelevant.
- the spike still paid for itself: run strictly, the schema draft failed on the shipped bytes in ways that were *our* bugs (fixed in this revision: `reciprocity_scandal` is absent from all 103 model entries — it moves out of `IndexEntryBase`; the agent map's record keys are dash-joined agent ids, not strict slugs — the `AgentId` primitive), and it quantified the contract-violating fixtures the M1 reset repairs (1,767: 1,700 pre-`model_openness`-rename generations, 67 with null trailers where the contract requires strings). the one-artifact gap is filed upstream as [justrach/dhi#83](https://github.com/justrach/dhi/issues/83) — if it lands (a serialized schema both sides consume, or `ts-to-dhi --zig`), option B's validator swaps to dhi and the zig side gains real schema sharing; re-run the spike then.

## the naming taxonomy — file vs report vs outputs

The schema names carry three suffixes, stated once here so the schemas read without prose:

- **`*FileSchema`** — a whole json document that exists on disk or is served verbatim. Three kinds, three reasons to exist:
  - `RegistryFileSchema` and `IndexDataFileSchema` mirror zig-owned formats byte-for-byte (the reflection dump; the embedded index). They cannot be derived from the fixtures — they don't come from the fixtures — so the schema IS the drift alarm against the zig bytes.
  - `AgentsFileSchema` is the site's ONE authored shape: a projection across three sources (the identity fixtures' outputs, the from-capture stems, the index's free axis). Every column's type is borrowed from an existing schema; it introduces no vocabulary of its own.
  - `IdentityFileSchema` restates `fixture.d.ts`'s `IdentityFile` for runtime use. The site invents no envelope of its own — `data/agents/<agent_id>.json` is the from-identity fixture copied verbatim (the filename IS the agent id, D6), so the only schema work is the cross-checked restatement (D5).
- **`*ReportSchema`** — an ephemeral query response, never stored: `IndexQueryReportSchema` (worker `GET /index.json`) and `EntityMatchReportSchema` (the filtered-out body — the cli's exit-14 stderr twin and the web's 422 body, D10). A report embeds the request echo and the results; its `count` is a property of the query, not of any document. (The cli `registry` report `{url, query, opened}` is retired by the collapse — D10.)
- **`FixtureOutputsSchema`** — the `outputs` object embedded in the fixture channels (the saved CLI outputs, verbatim). `IdentifySchema` is its one fully-typed payload — the 29-field contract.
- bare names (`RuleSchema`, `HarnessEntrySchema`, `AgentRowSchema`, `Slug`, `AgentId`, `Platform`, `TrainingAxis`, `Epoch`, `StderrLines`) — embedded entries, rows, and shared primitives.

Stored files carry no summary fields: anything recomputable from the same document (array lengths) is not stated (decision D8). Projection columns (the rows file's dim slugs) are the file's purpose, not summaries. Reports are the other exception because `count` is defined by the query. There is deliberately **no `CaptureFileSchema`**: the from-capture channel's types stay in `fixture.d.ts`, maintainer-side — nothing about it is served, embedded, or validated for serving (D9).

## the schemas — `site/src/lib/schemas.ts` (proposed, complete)

```ts
import { z } from "zod";

/** strict slug — the zig `slugId` output: lowercase alphanumeric only */
export const Slug = z.string().regex(/^[a-z0-9]+$/);
/** dash-joined strict slugs — `<harness>-<provider>-<model>`. NOT a strict slug
 * itself (spike finding: the agent map's record keys are these — the first
 * draft wrongly used Slug there); each dash-separated segment is one. */
export const AgentId = z.string().regex(/^[a-z0-9]+(-[a-z0-9]+)*$/);
/** canonical platform ids only — `macos`/`mac` → `darwin`, `win` → `windows`
 * normalise at the query boundaries (D2); stored data is always canonical.
 * on the site and in the index, a platforms array means: platforms with captures (D6). */
export const Platform = z.enum(["darwin", "linux", "windows"]);
/** the training-axis vocabulary — rules.zig and the identify contract share it */
export const TrainingAxis = z.enum(["enforced", "opt-in", "opt-out", "never", "NOASSERTION"]).nullable();
/** unix epoch seconds */
export const Epoch = z.number().int().nonnegative();
/** newline-split stderr lines — fixture.d.ts's StderrLines (never multiline strings) */
export const StderrLines = z.array(z.string());

// ── 1. registry.json — dumped from src/lib/rules.zig ────────────────────────
export const RuleSchema = z.object({
  name: z.string(), // canonical rule name ("kimi-code")
  label: z.string(), // display label ("Kimi Code")
  short_title: z.string().nullable(),
  variations: z.array(z.string()),
  id: Slug,
  openness: z.string().nullable().optional(), // models only
  license: z.string().nullable().optional(), // harnesses + models
  closed_training: TrainingAxis.optional(),
  open_training: TrainingAxis.optional(),
  sources: z.array(z.string()).optional(),
  license_sources: z.array(z.string()).optional(),
  training_sources: z.array(z.string()).optional(),
  reciprocity_scandal: z.boolean().optional(),
  reciprocity_scandal_sources: z.array(z.string()).optional(),
});
export const RegistryFileSchema = z.object({
  generated_at: Epoch,
  harnesses: z.array(RuleSchema),
  providers: z.array(RuleSchema),
  models: z.array(RuleSchema),
}); // counts dropped (D8)

// ── 2. index.json ≡ fixtures/index-data.json ≡ `agent-detect index` output ──
const IndexEntryBase = {
  label: z.string(),
  name: z.string(),
  id: Slug,
  open_training: TrainingAxis,
  closed_training: TrainingAxis,
  variations: z.array(z.string()),
}; // NO reciprocity_scandal here — ModelRule has no such field and none of the
   // 103 model entries carry it (spike finding); it sits on harnesses/providers
export const HarnessEntrySchema = z.object({
  ...IndexEntryBase,
  reciprocity_scandal: z.boolean(),
  short_title: z.string().nullable(),
  license: z.string().nullable(),
  providers: z.array(Slug),
  models: z.array(Slug),
});
export const ProviderEntrySchema = z.object({
  ...IndexEntryBase,
  reciprocity_scandal: z.boolean(),
  harnesses: z.array(Slug),
  models: z.array(Slug),
});
export const ModelEntrySchema = z.object({
  ...IndexEntryBase,
  short_title: z.string().nullable(),
  openness: z.string().nullable(),
  license: z.string().nullable(),
  providers: z.array(Slug),
  harnesses: z.array(Slug),
});
export const IndexDataFileSchema = z.object({
  harnesses: z.array(HarnessEntrySchema),
  providers: z.array(ProviderEntrySchema),
  models: z.array(ModelEntrySchema),
  /** free axis — the provider×model cells whose model ids are the free tier */
  provider_map_to_free_models: z.record(Slug, z.array(z.string())),
  /** per-agent fixture facts, derived at `fixtures index` time: platforms = the
   * agent's from-capture stems (platforms with captures, D6/D9 — the stems are
   * the only capture fact the cli ever carries); reciprocal = the agent's
   * from-identity declaration of record. agents.json must agree (D4).
   * keyed by agent id — the dash-joined form, not a strict slug */
  agent_map_to_platforms_reciprocal: z.record(AgentId, z.object({ platforms: z.array(Platform), reciprocal: z.boolean() })),
});

// ── 3. agents.json (was combos.json) — one row per agent (D7) ───────────────
export const AgentRowSchema = z.object({
  /** the resolved harness×provider×model triple — an agent */
  agent_id: AgentId,
  harness: Slug,
  provider: Slug,
  model: Slug,
  /** trailer email of record — `<…>@local` */
  email: z.string(),
  /** the from-identity declaration of record — identify.reciprocal */
  reciprocal: z.boolean(),
  /** the declaration's explain.state — reciprocal | not-reciprocal | undetectable | unknown */
  state: z.enum(["reciprocal", "not-reciprocal", "undetectable", "unknown"]).nullable(),
  free: z.boolean(),
  /** platforms with captures — the agent's from-capture stems (D6/D9) */
  platforms: z.array(Platform),
  /** the declaration's meta.updated_at */
  updated_at: Epoch,
}); // no fixtures array: from-identity fixture ids ARE agent ids now (D6), so
    // ?agent= matches agent_id alone; no counts (D8)
export const AgentsFileSchema = z.object({
  generated_at: Epoch,
  agents: z.array(AgentRowSchema),
});

// ── 4+8. agents/<agent_id>.json ≡ /agent/<agent_id>.json —
//         the from-identity fixture, verbatim (D6: the filename IS the agent
//         id; #13: no site envelope — the dims stay in the filename) ─────────
/** the 29-field contract — normative text lives in fixtures/fixture.d.ts
 * (Identify, frozen by DESIGN.md #9); this schema must stay field-identical
 * (cross-checked by tools/check_data.ts, D5) */
export const IdentifySchema = z.object({
  harness_label: z.string(),
  harness_short_title: z.string().nullable(),
  harness_name: z.string(),
  harness_id: Slug,
  harness_license: z.string().nullable(),
  harness_open_training: TrainingAxis.optional(),
  harness_closed_training: TrainingAxis.optional(),
  harness_open_setting: z.enum(["enabled", "disabled", "NOASSERTION"]).nullable().optional(),
  harness_closed_setting: z.enum(["enabled", "disabled", "NOASSERTION"]).nullable().optional(),
  harness_reciprocity_scandal: z.boolean().optional(),
  harness_reciprocity: z.boolean().nullable().optional(),
  provider_label: z.string(),
  provider_name: z.string(),
  provider_id: Slug,
  provider_closed_training: TrainingAxis,
  provider_open_training: TrainingAxis,
  provider_reciprocity_scandal: z.boolean().optional(),
  provider_reciprocity: z.boolean().nullable().optional(),
  model_label: z.string(),
  model_short_title: z.string().nullable(),
  model_name: z.string(),
  model_id: Slug,
  model_openness: z.string().nullable(),
  model_open_training: TrainingAxis.optional(),
  model_closed_training: TrainingAxis.nullable().optional(),
  model_license: z.string().nullable(),
  model_reciprocity: z.boolean().nullable().optional(),
  agent_id: AgentId,
  reciprocal: z.boolean(),
});
export const FixtureOutputsSchema = z
  .object({
    identify: IdentifySchema,
    "trailer co-author": z.string().optional(),
    "trailer assisted-by": z.string().optional(),
    found: z.unknown().optional(),
    raw: z.unknown().optional(),
    explain: z.record(z.string(), z.unknown()).nullable().optional(),
    /** the stderr each recorded action would print for the recorded state, as
     * line arrays — absent when it printed none. this is the COMPLETE stderr
     * surface: exactly the three actions that print stderr (core.stderrLinesFor's
     * enum — identify, explain, check-reciprocal; verified against the shipped
     * bytes: 246 / 621 / 621 occurrences) — the trailers and found print none,
     * so they carry no keys */
    "identify.stderr": StderrLines.optional(),
    "explain.stderr": StderrLines.optional(),
    /** the recorded stdout verdict — the fixture form, spaces and "is" included
     * (fixture.d.ts's union, verified against the shipped bytes; see #9).
     * mutually exclusive with the stderr by state: stdout on the states that
     * print stdout (0/10), stderr-only on 8/9 */
    "check-reciprocal": z.enum(["is reciprocal", "not reciprocal"]).optional(),
    "check-reciprocal.stderr": StderrLines.optional(),
  })
  .passthrough();
/** restates fixture.d.ts's IdentityFile for runtime use — the site serves the
 * from-identity fixture verbatim; check_data.ts asserts envelope-wide field
 * identity against the d.ts (D5) */
export const IdentityFileSchema = z.object({
  outputs: FixtureOutputsSchema,
  meta: z.object({ updated_at: Epoch }),
});

// ── 5. worker GET /index.json — the search view's json (ephemeral, D10) ─────
/** `params` is the RAW echo (D1); `resolved` is canonical */
export const IndexQueryReportSchema = z.object({
  params: z.record(z.string(), z.string().nullable()),
  resolved: z.object({
    harness: Slug.nullable(),
    provider: Slug.nullable(),
    model: Slug.nullable(),
    search: z.string().nullable(),
    agent: z.string().nullable(),
    email: z.string().nullable(),
    platform: Platform.nullable(),
    free: z.boolean().nullable(),
    reciprocal: z.boolean().nullable(),
  }),
  count: z.number().int(),
  truncated: z.boolean(),
  note: z.string().optional(),
  /** expanded rows embed the agent's identity file when count ≤ 50 (EXPAND_CAP) */
  results: z.array(AgentRowSchema.extend({ detail: IdentityFileSchema.optional() })),
});

// ── 6. the filtered-entity report — the cli's exit-14 stderr twin and the
//       web's 422 body (D10): the id resolved, the filters did not ───────────
export const FilterMatchSchema = z.object({
  /** the filter as given — "--platform" */
  filter: z.string(),
  /** the value as given — "darwin" (normalised into the canonical id for the test) */
  value: z.string(),
  matched: z.boolean(),
  /** the fact that decided it — e.g. "captured on: linux, windows" */
  fact: z.string().optional(),
});
export const EntityMatchReportSchema = z.object({
  error: z.literal("filtered-out"),
  entity: z.enum(["agent", "harness", "provider", "model"]),
  /** the input as given ("Kimi Code") */
  input: z.string(),
  /** the canonical id the input resolved to — one strict-slug segment for dim
   * entities, dash-joined for agents (AgentId's pattern covers both) */
  id: AgentId,
  /** every given filter, each with its match state — "matches or doesn't match which filters" */
  filters: z.array(FilterMatchSchema).min(1),
  /** the same view without the violating filters — the web returns the path,
   * the cli prints the absolute deep link */
  unfiltered_url: z.string(),
});
```

`explain` and `raw`/`found` stay `unknown` deliberately: the spa renders every outputs key generically and never reads into them structurally; `raw` is the shapeless runtime observations block (fixture.d.ts's own words); typing `explain`'s reasons/actions arrays is a separate, optional follow-up. The identify schema tightens `fixture.d.ts`'s `provider_*_training` (`string | null` there) to the shared `TrainingAxis` union — M2 tightens the d.ts to match (D5). The entity views' success payloads: `index harness <id> --json` prints that harness's `IndexDataFile` entry; `index agent <id> --json` prints the agent's facts as the embedded index knows them (id, dims, the `<id>@local` email of record, captured platforms, reciprocity, free) — the `IdentityFile` itself is NOT embedded in the binary; it stays the site's `/agent/<id>.json` (implemented M3; the earlier drafts' "prints the agent's IdentityFile" was wrong about the cli's reach). The `.stderr` keys are the complete recorded stderr surface — the first drafts omitted `identify.stderr` and `explain.stderr` (the shipped bytes carry 246 and 621 of them; `core.stderrLinesFor`'s enum is exactly the three actions that print stderr, so the trailers and `found` carry none). D5's envelope cross-check makes this class of omission unshippable: the schema's outputs key set must equal the d.ts's, and this one would have failed it.

## consistency decisions

- **D1 — `query` renamed on the website.** the worker's raw echo becomes `params`; `resolved` stays. (the cli `registry` report this decision originally mirrored is retired by D10; the merged `index` command's resolution semantics are stated in its usage text instead.) both schemas state the distinction where a prose reader will trip on it.
- **D2 — platform aliases unified.** the website's `resolvePlatform` adopts the cli's alias table (`canonicalWebPlatform`, main.zig:547): `macos` and `mac` normalise into `darwin`, `win` into `windows`. `?platform=macos` then behaves identically to `--platform=macos`. stored data and schema values are canonical-only; aliases exist at the query boundaries — and the entity views normalise dim inputs the same way ("`<*-id>` is inputs that are normalised into the id", D10).
- **D3 — one "Index" name each.** the site's `IndexFile` type is renamed `IndexDataFile` (it types `index-data.json` / the `index` action output; the schema is `IndexDataFileSchema`). the fixtures store keeps `Index`/`IndexStore` in `fixtures/index.d.ts`. no type is shared between them — they are different formats.
- **D4 — authority.** `agents.json` is authoritative for per-agent `platforms`/`reciprocal`; `agent_map_to_platforms_reciprocal` is derived and must agree — `check_data.ts` asserts the agreement. both derive from the same fixture store (platforms from from-capture stems, reciprocal from the declaration), so the check also catches a site build running against a stale committed index.
- **D5 — identify cross-check.** `IdentifySchema`/`IdentityFileSchema` restate `fixture.d.ts`'s `Identify`/`IdentityFile` for runtime use; `check_data.ts` asserts the two stay field-identical — the `Identify` key set, and the `IdentityFile` envelope's keys (`outputs`/`meta`, the outputs key set) — by parsing the d.ts blocks and comparing, so the frozen contract and the runtime schema cannot drift apart. M2 also tightens the d.ts's `provider_open_training`/`provider_closed_training`/`model_*_training` to the same union the harness fields already use.
- **D6 — the from-identity channel drops platform.** platform has no impact on a declared identification: the channel observes nothing (no `platform_id` in `DeclaredRaw`), and the per-platform copies have already drifted by generation (#10). from-identity files become `<harness>-<provider>-<model>.json` — one per agent, the fixture id ≡ the agent id, so the filename IS the agent id and the dims stay in the filename (#13). platform henceforth signifies **platforms we have captures from**: from-capture keeps its `-<platform>` stem segment, and every `platforms` array on the site and in the index (agent rows, `?platform=`, the platform pills, `agent_map_to_platforms_reciprocal.platforms`) is capture-derived. `reciprocal`/`state`/`email` stay declaration-derived. the channel is not migrated — it is **reset** — but the reset is staged for git's rename detection, in one commit: `git mv` each agent's surviving platform copy (the most-recently-`updated_at` one — the content the site last rendered) to its 3-segment name, fs-delete the other platform copies, then regenerate the channel in one zero-token from-identity run and `fixtures index` to rebuild the committed index. the moved files' contents change only by the regen (the platform lived in the filename — the dims are never inside the file), so similarity stays high and git's rename detection pairs old→new: history follows the 1,390 survivors while the ~1,404 dropped copies land as plain deletes. "hopefully" is honest — rename detection is similarity-based at diff time, never recorded by `git mv` itself — but a same-commit delete+add pair with near-identical content is exactly what it detects. the regen remains the clean guarantee: every declaration is rewritten against the current rules (DESIGN.md: out-of-sync content is regenerated, never edited), the scan's `best_updated`/`best_platform` tie-break dies (one file, one truth), agents whose rules have left the tables correctly disappear, and nothing else is lost — capture platforms live in from-capture (untouched) and declarations are reproducible from the rules. zig touchpoints: the from-identity worker's writer, `scanIdentityCombos` (reciprocal from the single identity file; platforms from from-capture stems), the stem splitters, queue expansion (from-identity candidates expand once, not per `platforms_all`), `fixtures status` counts (identity counts become platform-independent; capture counts stay per-platform), `index_data.zig`'s header and `Filters.platform` comment ("captured platform"), `fixture.d.ts`/`index.d.ts` docs (the from-identity filename convention; the shared-trio (not shared-stem) cross-channel rule; `FixtureId`; `QueueEntry.platform` = from-capture only, matching the existing cli rejection).
- **D7 — the data noun is "agent".** an agent is the combination of harness, provider, and model — the resolved triple every artifact already names: `agent_id`, `--agent=`, the agent route and file, `agent_map_to_platforms_reciprocal`, exit 7 "unknown agent". the site data vocabulary unifies on it: `data/combos.json` → `data/agents.json`, `ComboRow` → `AgentRow`, `CombosFile` → `AgentsFile`, `comboSearchText` → `agentSearchText`, the worker's `?agent=` filter matches `agent_id` (the row's fixtures array is gone — see D6). "combo" keeps its DESIGN.md meaning — a candidate cell of the harness×provider×model grid before any fixture exists — and stays zig-internal queue vocabulary; renaming `ComboFacts`/`scanIdentityCombos` is optional M4 cosmetics, not part of this plan's data contract.
- **D8 — no derived counts in stored files.** build_data stops emitting `counts` in `registry.json` and `agents.json`; the spa's two `counts.combos` read sites (App.tsx, association-tables.tsx) switch to `agents.length`. the query report's `count` stays — it is a property of the query (pairs with `truncated`/`note`), not a summary of a document.
- **D9 — the capture boundary.** from-capture content never leaves the git repo: no route serves it, no data file embeds it, the cli never embeds it, and no schema exists for it on the site/cli side (its types stay in `fixture.d.ts`, maintainer-side). The single capture-derived fact on the wire is the **captured-platform set per agent**, taken from from-capture file stems only — a from-capture file is written only on success, so stem presence means a successful capture on that platform. build_data and `scanIdentityCombos` read those stems and parse nothing; `check_data.ts` asserts platform agreement without opening a single capture file. ramifications, stated: the index the released cli embeds carries platform facts, never capture data (outputs, `meta`, `harness_version`, invocations — repo-only); the `?platform=` filter and the site's platform pills mean "captured here"; capture-only agents (captured but never declared) stay off the wire until declared — the agent universe on the site and in the index remains the declared identifications, captures only annotate them with platforms; and a future "serves capture outputs" feature would be a new decision, not an accident.
- **D10 — one command: `agent-detect index` (registry is dropped).** the cli maps onto the site's routes 1:1 (#14):
  - `agent-detect index [--free|--reciprocal|--platform=|--email=|--search=…]` — the **search view**, ≡ `/?<filters>`: prints the filtered index data (today's `index` action, shape unchanged — the built index verbatim, no envelope). `--web` opens the deep link (`siteUrl/?<filters>#registry`); `--no-json` prints nothing. dim flags are NOT search filters here — they address entities (below), replacing today's "narrow all three arrays" semantics: "everything for cline" is `index harness cline`, whose associations are that narrowed view. `--search=` joins the flag set (the site's `?search=`, free-text over the haystack `comboSearchText`/`agentSearchText` already defines).
  - `agent-detect index {agent|harness|provider|model} <id>` — the **entity views**, ≡ `/agent/<id>` · `/harness/<id>` · `/provider/<id>` · `/model/<id>`. `<id>` is an INPUT, normalised into the canonical id exactly like the site's routes (names, labels, aliases; trim + lowercase; a resolvable non-canonical input behaves as the canonical id). the agent input also accepts the trailer-email form: a trailing `@local` is stripped before resolution, so a pasted `Co-authored-by: … <cline-chutes-glm51@local>` addresses the agent directly — and the site's `/agent/<id>` and `?agent=` accept it identically, keeping the 1:1 mapping. flag forms: `--agent=<id>` is the agent entity form (today's `index` rejection of `--agent=` dies); `--harness=`/`--provider=`/`--model=` with a value are likewise entity forms — one dim flag names that entity; all three together name the AGENT (`index --harness=H --provider=P --model=M` ≡ `index agent H-P-M`, preserving today's registry behavior); two dim flags conflict (exit 3).
  - **filters gate entity views.** every search filter is also valid on an entity view, as a PREDICATE, not a slice: the view's data is never narrowed — filters either pass or fail the entity. agent views predicate on the row's facts (`--free`, `--reciprocal`, `--platform=` ∈ captured platforms, `--email=`, dim equality); harness/provider/model views predicate on participation (the entity participates in ≥1 combo satisfying the filter — the same semantics `buildFiltered` uses). all filters pass → success, exit 0, and the payload is the entity's json (the index entry / the agent's `IdentityFile`). any filter fails → **exit 14** (new: "found, filtered out"; unknown ids stay exit 7); stderr names the resolution and EVERY filter's state — "`cline-chutes-glm51` matched `--free`; did not match `--platform=darwin` (captured on: linux, windows)"; `--no-json` silences stdout only — the stderr explanation always prints on failure.
  - **the web mirrors it.** `/{agent|harness|provider|model}/<id>` become real routes (today only the `.json` variants exist, plus `?agent=`): the worker serves the spa page for the bare path and the data for `.json`. an unknown id → 404 (today's body). a known id with failing filters → **422** with a page (html for the bare path, `EntityMatchReportSchema` for `.json`) explaining the lack of match — which filters matched vs didn't, with the deciding facts — and a hyperlink to the identity **without the violating filters** (only the failing filters are stripped; passing ones stay applied). `--web` on a filtered-out entity opens that failure page — the parity is the point.
  - **the registry report retires.** `{url, query, opened}` is gone with the command; the urls are the documented routes (`llms.txt`), constructible without a report. this retires the old "params/resolved cli mirror" work item entirely.
  - `?agent=<id>` on the site stays working as an alias for `/agent/<id>` (deployed links; history.replaceState to the canonical path).
  - docs land with the change: `core.usage`'s registry line and `core.registryUsage` are deleted; `core.indexUsage` is rewritten around the views + filters + exit 14 + the provenance sentence ("regenerated by `agent-detect-dev fixtures index` — a stale index is stale facts"); README's "the registry website" section and DESIGN.md's deep-link contract + exit-status registry (+14, "unknown agent" unified) follow; the site's llms.txt and "cli registry" menubar wording update.

## validation points — where the schemas actually run

1. **`tools/check_data.ts`** (new, `deno task check:data`, wired into `deno task check`): validates every `site/public/data/*.json` file, every `site/public/data/agents/*.json` against `IdentityFileSchema` (they ARE the fixtures — this validates the channel end-to-end), and `fixtures/index-data.json` against the schemas; asserts D4 agreement (agents.json ↔ the committed index's agent map ↔ the store itself: platforms == the from-capture stems — scanned, never parsed, D9 — and reciprocal == the declaration's `identify.reciprocal`) and D5 field-identity against the d.ts blocks. fails the build on drift — this is the drift alarm.
2. **`tools/build_data.ts`**: parses its own output through the schemas before writing (same process, cheap) so a zig dump change that breaks a shape fails `deno task build`, not a browser session.
3. **worker**: `getRegistry`/`getAgents`/`getIndex` parse through the schemas on first memoized load — an isolate boot fails loudly on a bad deploy rather than serving 500s per route.
4. **spa**: types come from `z.infer` (replacing the hand-written interfaces in `registry.ts`); no runtime parsing needed client-side (the data is same-origin and build-validated).
5. **cli golden test** (M4, optional): `zig build` then pipe the merged `index` command's outputs (the search view's data, the entity views' entries/identity files, the exit-14/422 body) and `identify`'s output through the schemas in a deno test — skipped when the binary is absent so `deno task check` stays hermetic. this is also what pins the usage texts' claims (shapes, filters, exit codes) to behavior.

## code impact inventory

| step | file | change |
|------|------|--------|
| M1 | `fixtures/from-identity/` | the reset, one commit: `git mv` each agent's latest platform copy to its 3-segment name, fs-delete the rest (2,794 per-platform files → 1,390 declarations), regen — staged so git detects the renames (D6) |
| M1 | `src/dev/dev.zig` | from-identity worker writes 3-segment stems; `scanIdentityCombos` loses the tie-break and takes platforms from from-capture stems (parsed never — stem scan only, D9); queue expansion of from-identity entries drops the per-platform fan-out; `fixtures status` identity counts become platform-independent; stem splitters; the usage texts' store paragraph and flag docs (from-identity id shapes, the platform-rejection reason) |
| M1 | `src/lib/index_data.zig` | header comment and `Filters.platform`: "captured platform the combo must carry" |
| M1 | `fixtures/fixture.d.ts` | channel docs: the from-identity filename convention, the shared-trio (not shared-stem) cross-channel rule, `IdentityFile` |
| M1 | `fixtures/index.d.ts` | `FixtureId` (from-capture carries `-<platform>`; from-identity ids ≡ agent ids), `QueueEntry.platform` = from-capture only (matches the existing cli rejection), the stale free-axis paragraph (drift #3) |
| M1 | `fixtures/index-data.json` | regenerated: the agent map's platforms are capture-derived |
| M1 | zig tests (`index.test.zig`, `known_fixtures.test.zig`, …) | stem shapes, scan fixtures, status counts |
| M2 | `site/src/lib/schemas.ts` (new) | all schemas above (with `RegistryActionReportSchema` still present until M3 removes it) |
| M2 | `site/tools/check_data.ts` (new) | boundary validation + D4/D5 cross-checks |
| M2 | `site/deno.json` | `check:data` task; `check` runs it |
| M2 | `site/tools/build_data.ts` | copies each identity fixture verbatim to `data/agents/<agent_id>.json` (no envelope, #13); reads from-capture as stems only (D9); writes `data/agents.json` (D7) without counts (D8); pre-write validation; import schemas |
| M2 | `site/package.json` | `npm:zod` dependency |
| M2 | `site/src/lib/registry.ts` | interfaces replaced by `z.infer` re-exports from schemas.ts (`AgentRow`, `AgentsFile`, `IdentityFile`, `IndexDataFile`); `resolvePlatform` alias set (D2); `comboSearchText` → `agentSearchText` |
| M2 | `site/worker/index.ts` | `query` → `params` (D1); reads `/data/agents.json`; `?agent=` matches `agent_id`; `/identify/` proxies the verbatim fixture; expanded detail = the identity file; schema-parse memoized assets; the truncation note's wording ("agents matched") |
| M2 | `site/src/App.tsx`, `site/src/components/association-tables.tsx` | `counts.combos` → `agents.length` (D8) |
| M2 | `site/src/components/agent-page.tsx` | consumes the verbatim `IdentityFile` (`outputs` + `meta.updated_at`); dims still come from the row |
| M2 | `site/public/llms.txt` | document every json endpoint + its schema name; `platform` = platforms with captures (D6/D9); the file/report taxonomy; `agents/<id>.json` = the identity fixture verbatim |
| M3 | `src/main.zig` + `src/lib/core.zig` | `runRegistry` merges into `runIndex` (D10): the four entity views + the search view, input normalisation (names/aliases, trim+lowercase, the agent input's trailing-`@local` strip), filter gating, exit 14 + per-filter stderr, `--web` url builders for the entity routes; `registryUsage` deleted, `indexUsage` rewritten (views, filters, exit 14, the provenance sentence), `core.usage`'s registry line and `RegistryQuery`/report plumbing retired |
| M3 | `src/web.test.zig` + zig tests | the collapse's behavior tests (views, gating, exits 3/7/14) |
| M3 | `site/worker/index.ts` | path routes `/{agent,harness,provider,model}/<id>` (spa page + `.json` data); agent inputs accept the trailing-`@local` email form; filter gating → 422 + `EntityMatchReportSchema` body / explanation page with the stripped-filters link; 404 unknowns unchanged; `/identify/<id>.json` → 308 `/agent/<id>.json` |
| M3 | `site/src/App.tsx` (+ routing) | path-based entity pages; `?agent=` alias kept via replaceState to `/agent/<id>` |
| M3 | `site/src/lib/schemas.ts` | drop `RegistryActionReportSchema`; add `EntityMatchReportSchema` |
| M3 | `site/public/llms.txt`, site menubar copy | the route map (`/agent/<id>` …), the filtered-out page + status, "cli registry" wording → the merged command |
| M3 | `README.md`, `DESIGN.md`, `CONTRIBUTING.md` | the released-cli doc pass: registry section rewritten around `index`'s views; DESIGN.md's deep-link contract + exit-status registry (+14, "unknown agent" unified); the vocabulary pass (combo→agent identity-facing, declared→captured for platform, one exit-code term each) |
| M4 (optional) | golden deno test | the merged cli's outputs through the schemas (skipped when no binary); pins the usage texts' claims |
| M4 (optional, cli) | zig internals | `ComboFacts`/`scanIdentityCombos` → agent naming (D7 cosmetics) |

## milestones

1. **M1 — the fixture store drops platform (D6, D9).** one commit: `git mv` each agent's latest platform copy to its 3-segment name, fs-delete the remaining platform copies, land the platform-less zig code (writers, scanners, queue expansion, status, docs, tests), regenerate the channel in one zero-token from-identity run, and `fixtures index` to rebuild the committed index. `zig build test` green and `fixtures index --check` green — platforms in the index are now capture-derived, every declaration carries a fresh, honest `updated_at`, and git's rename detection pairs the moved files (history follows the 1,390 survivors). the reset also repairs the 1,767 shipped files that violate the frozen contract outright (1,700 pre-`model_openness`-rename generations; 67 with null trailers where `fixture.d.ts` requires strings — spike-verified, prompt 17). must land immediately before M2 (the old build_data skips every 3-segment stem, so the site data regenerates only after both; the site deploys once, after M2).
2. **M2 — schemas + the site consistency sweep (D1–D5, D7–D9).** schemas.ts, check_data.ts, tasks wired; build_data emits `agents.json` (no counts, capture-stem platforms) and serves the identity fixtures verbatim; the spa/worker type swaps and renames; llms.txt documents the api. the schemas describe the post-M1 world, so M2 lands schemas + producers + consumers in one commit set — `deno task check` passes in-commit. note: unlike the first draft, the schemas are written from the post-decision state, not the shipped bytes.
3. **M3 — the index/registry collapse (D10) + the released-cli doc pass.** one `agent-detect index` with the search view and the four entity views; filters gate entity views (cli exit 14 + per-filter stderr; web 422 + the explanation page linking the identity without the violating filters); `/identify/` becomes `/agent/`; the registry report retires; the usage texts, README, DESIGN.md, and the site copy are rewritten in the same commit set. this is a breaking cli change (`registry` is gone) — its own commit and version note.
4. **M4 — optional follow-ups.** the golden deno test (validates the merged cli's outputs through the schemas and pins the docs' claims) and the zig-internal agent naming. only if wanted; nothing on the wire depends on them.
