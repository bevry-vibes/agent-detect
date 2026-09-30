Assisted-by: ZCode · GLM 5.3 Flash <zcode-zcode-glm53flash@local>

# website ↔ cli json consistency, with typescript schemas

Companion: [.plans/1790792125916-website-cli-json-consistency-schemas.prompts.md](./1790792125916-website-cli-json-consistency-schemas.prompts.md)

## the problem

The project speaks JSON in two places that must agree but currently only gesture at each other:

- the **cli** (zig) — the `identify` contract, the `registry`/`index` action outputs, the fixture channels;
- the **website** (deno/vite/worker) — the static data files under `site/public/data/`, the worker api routes, and the spa's imported types.

The site's types (`site/src/lib/registry.ts`) are hand-written interfaces restating shapes that other files own normatively (`fixtures/fixture.d.ts`, `fixtures/index.d.ts`, `tools/build_data.ts`'s dump struct, `src/main.zig`'s report structs). Nothing validates one against another, and research found real drift (below). The repo already has the right instinct — `fixtures/index.d.ts` declares "TypeScript structure declarations are the SOURCE OF TRUTH … the zig program never imports TypeScript; this file is the normative shape humans and agents read instead of prose" — but that instinct stops at the fixtures directory.

Goal: **one typed schema per json format, stated in typescript, validated at every producer/consumer boundary, with the documented inconsistencies resolved.** Non-goal: making zig consume typescript (per the repo's own rule, zig never imports typescript — the zig side stays validated by its own tests plus golden files).

## the inventory — every json surface, who makes it, who reads it

| # | format | producer | consumers | normative source today | drift risk |
|---|--------|----------|-----------|------------------------|------------|
| 1 | `registry.json` (rule tables) | `tools/build_data.ts` (`zig run` dump of `src/lib/rules.zig`) | spa, worker (name resolution), `agent-detect registry` docs | the dump struct inside build_data (by zig reflection) | silent: a new rules.zig field appears in the json untyped; site types hand-listed |
| 2 | `data/index.json` ≡ `fixtures/index-data.json` ≡ `agent-detect index` output | zig (`index_data.zig`) embeds; build_data copies verbatim | released cli (embedded), spa, worker | `fixtures/index.d.ts` describes the STORE, not this built output; site's `IndexFile` interface hand-written | naming collision (two "Index" types), store doc is stale (says free axis comes from map csvs — deleted in b08b893) |
| 3 | `combos.json` | `tools/build_data.ts` (from-identity channel) | spa, worker `/index.json` | site's `ComboRow` interface | silent |
| 4 | `agents/<agent_id>.json` ≡ `/identify/<agent_id>.json` | build_data (verbatim fixture outputs) | spa result page, worker route | `fixtures/fixture.d.ts` (normative!) but site's `FixtureOutputs` is `Record<string, unknown>` | the 29-field identify contract is untyped on the site |
| 5 | worker `/index.json` report | `site/worker/index.ts` | external api consumers, docs | nothing | envelope shape (query/resolved/count/truncated/results) undocumented; `results` rows gain `detail` when expanded — a variant nobody states |
| 6 | cli `registry` action report | `src/main.zig` `runRegistry` | agents scripting the cli | nothing | `{url, query, opened}` — `query` means resolved ids here but RAW echo on the website's `/index.json`. Same field name, different semantics |
| 7 | cli `index` action output | `src/main.zig` `runIndex` → `idx.buildFiltered` | agents, the website (as #2) | same as #2 | it is the built index verbatim — no envelope — so any envelope added to the website's copy would fork the formats |
| 8 | cli `identify` / fixture `outputs.identify` | `core.buildCooked` | site fixtures display, `fixture.d.ts` `Identify` | `fixtures/fixture.d.ts` (normative, frozen by DESIGN.md #9) | site types it as `Record<string, unknown>` |

## the inconsistencies (researched, not hypothetical)

1. **`query` means two things.** cli registry report `query` = resolved canonical ids (it refuses to emit unresolved). website `/index.json` `query` = the raw param echo (display names, possibly unresolved) + `search`. The website separately exposes `resolved` (canonical + lowercased raw `search`). A consumer switching from cli to web breaks silently.
2. **platform aliases.** cli `--platform=macos|mac|win` canonicalizes (`canonicalWebPlatform`, main.zig:547). the website's `resolvePlatform` accepts only exact `darwin|linux|windows` — `?platform=macos` 404s on the site while the same value works on the cli.
3. **stale store doc.** `fixtures/index.d.ts` still says the free axis is "declared by `fixtures/map-provider-model-freeprovidermodel.csv`" — those csvs were deleted (b08b893); the index file now embeds `provider_map_to_free_models` and `agent_map_to_platforms_reciprocal`.
4. **two "Index" types.** the site's `IndexFile` is the BUILT index (entries + the two maps); `fixtures/index.d.ts` `Index` is the committed store. same word, different shapes, different files.
5. **untyped identify on the site.** the 29-field contract is frozen in `fixture.d.ts` but the site's `FixtureOutputs.identify` is `Record<string, unknown>` — typos in displayed keys can't be caught.
6. **`ComboRow.state` is a bare string.** its values come from `explain.state` (`reciprocal` / `not-reciprocal` / `undetectable` / `unknown`) — unenumerated.
7. **the expanded-results variant is unstated.** worker `/index.json` embeds `detail: AgentFile` per row when the filter yields ≤ 50 rows (`EXPAND_CAP`), and swaps rows for compact rows with a `note` when truncated. the schema must state both variants or consumers guess.
8. **derived duplication.** `agent_map_to_platforms_reciprocal` (in the index) restates each combo's `platforms` + `reciprocal`, which `combos.json` also carries. fine (the cli embeds only the index), but the schemas should say which is authoritative (combos.json) so a validator can assert they agree.
9. **verdict vocabulary.** `check-reciprocal` prints `is reciprocal` / `not reciprocal` (space form) while fixture keys and combo rows use `reciprocal` / `not reciprocal` — the schema pins the fixture/api form; the cli stdout form is display text.

## approach — options considered

| option | what | pros | cons |
|--------|------|------|------|
| A. normative `.d.ts` only | extend the `fixtures/*.d.ts` convention: a `site/public/data/data.d.ts` declaring every data-file shape; types only | zero dependencies; matches the repo's stated convention | no runtime validation — build_data and the worker still accept anything; drift caught by review only |
| B. zod schemas + inferred types (chosen) | `site/src/lib/schemas.ts`: one zod schema per format; types exported via `z.infer`; validation runs at the boundaries | runtime validation at every producer/consumer; type and validator from one declaration; zod v4 runs on deno, node, and in the vite bundle; errors name the exact field | one new dependency (`npm:zod`); schemas could drift from `fixtures/*.d.ts` — mitigated by a cross-check test |
| C. json schema + codegen | draft json schema documents, generate ts types | language-neutral (zig could read them too) | codegen pipeline; two artifacts per format; zig still wouldn't (per repo rule); heaviest |

B is chosen: the repo's boundary problem is runtime (build_data writes what zig reflected; the worker serves what build_data wrote), which types alone cannot catch. A's `.d.ts` convention stays authoritative for the fixture store — schema B cross-references it and a test asserts the field lists match.

## the schemas — `site/src/lib/schemas.ts` (proposed, complete)

```ts
import { z } from "zod";

/** strict slug — the zig `slugId` output: lowercase alphanumeric only */
export const Slug = z.string().regex(/^[a-z0-9]+$/);
export const Platform = z.enum(["darwin", "linux", "windows"]);
/** the training-axis vocabulary — rules.zig and the identify contract share it */
export const TrainingAxis = z.enum(["enforced", "opt-in", "opt-out", "never", "NOASSERTION"]).nullable();
/** unix epoch seconds */
export const Epoch = z.number().int().nonnegative();

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
  counts: z.object({ harnesses: z.number().int(), providers: z.number().int(), models: z.number().int() }),
  harnesses: z.array(RuleSchema),
  providers: z.array(RuleSchema),
  models: z.array(RuleSchema),
});

// ── 2. index.json ≡ fixtures/index-data.json ≡ `agent-detect index` output ──
const IndexEntryBase = {
  label: z.string(),
  name: z.string(),
  id: Slug,
  open_training: TrainingAxis,
  closed_training: TrainingAxis,
  reciprocity_scandal: z.boolean(),
  variations: z.array(z.string()),
};
export const HarnessEntrySchema = z.object({
  ...IndexEntryBase,
  short_title: z.string().nullable(),
  license: z.string().nullable(),
  providers: z.array(Slug),
  models: z.array(Slug),
});
export const ProviderEntrySchema = z.object({
  ...IndexEntryBase,
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
export const IndexDataSchema = z.object({
  harnesses: z.array(HarnessEntrySchema),
  providers: z.array(ProviderEntrySchema),
  models: z.array(ModelEntrySchema),
  /** free axis — the provider×model cells whose model ids are the free tier */
  provider_map_to_free_models: z.record(Slug, z.array(z.string())),
  /** derived from combos.json (the authoritative source) at build_data time */
  agent_map_to_platforms_reciprocal: z.record(Slug, z.object({ platforms: z.array(Platform), reciprocal: z.boolean() })),
});

// ── 3. combos.json ──────────────────────────────────────────────────────────
export const ComboRowSchema = z.object({
  agent_id: z.string(),
  harness: Slug,
  provider: Slug,
  model: Slug,
  /** trailer email of record — `<…>@local` */
  email: z.string(),
  /** the most recent fixture's identify.reciprocal */
  reciprocal: z.boolean(),
  /** the most recent explain.state — reciprocal | not-reciprocal | undetectable | unknown */
  state: z.enum(["reciprocal", "not-reciprocal", "undetectable", "unknown"]).nullable(),
  free: z.boolean(),
  platforms: z.array(Platform),
  updated_at: Epoch,
  fixtures: z.array(z.object({ id: z.string(), platform: Platform, updated_at: Epoch })),
});
export const CombosFileSchema = z.object({
  generated_at: Epoch,
  counts: z.object({ combos: z.number().int(), fixtures: z.number().int() }),
  combos: z.array(ComboRowSchema),
});

// ── 4+8. agents/<id>.json ≡ /identify/<id>.json — fixture outputs ───────────
/** the 29-field contract — normative text lives in fixtures/fixture.d.ts
 * (Identify, frozen by DESIGN.md #9); this schema must stay field-identical
 * (cross-checked by tools/check_data.ts) */
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
  agent_id: z.string(),
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
    /** the check-reciprocal verdict — the fixture form without "is" */
    "check-reciprocal": z.enum(["reciprocal", "not reciprocal"]).optional(),
    "check-reciprocal.stderr": z.array(z.string()).optional(),
  })
  .passthrough();
export const AgentFileSchema = z.object({
  agent_id: z.string(),
  harness: Slug,
  provider: Slug,
  model: Slug,
  fixtures: z.array(
    z.object({
      id: z.string(),
      platform: Platform,
      updated_at: Epoch,
      meta: z.record(z.string(), z.unknown()),
      outputs: FixtureOutputsSchema,
    }),
  ),
});

// ── 5. worker GET /index.json — the query report ────────────────────────────
/** `params` is the RAW echo (see consistency decision D1); `resolved` is canonical */
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
  /** expanded rows embed the full AgentFile when count ≤ 50 (EXPAND_CAP) */
  results: z.array(ComboRowSchema.extend({ detail: AgentFileSchema.optional() })),
});

// ── 6. cli `registry` action report ─────────────────────────────────────────
export const RegistryActionReportSchema = z.object({
  url: z.string(),
  query: z.object({
    harness: Slug.nullable(),
    provider: Slug.nullable(),
    model: Slug.nullable(),
    email: z.string().nullable(),
    platform: Platform.nullable(),
    free: z.boolean().nullable(),
    reciprocal: z.boolean().nullable(),
    agent: z.string().nullable(),
  }),
  opened: z.boolean(),
});
```

`explain` and `raw` stay `unknown` deliberately: `raw` is shapeless by design (fixture.d.ts says so), and `explain`'s reasons/actions arrays are presentation-shaped — typing them is a separate, optional follow-up.

## consistency decisions

- **D1 — `query` renamed on the website.** the worker's raw echo becomes `params`; `resolved` stays. the cli's `query` keeps its name (it IS the resolved query — the cli refuses to emit unresolved values), and its schema's comment says so. both schemas state the distinction where a prose reader will trip on it.
- **D2 — platform aliases unified.** the website's `resolvePlatform` adopts the cli's alias set (macos, mac → darwin; win → windows), so `?platform=macos` behaves identically to `--platform=macos`.
- **D3 — one "Index" name each.** the site's `IndexFile` interface is renamed `IndexData` (it types `index-data.json` / the `index` action output). the fixtures store keeps `Index` in `fixtures/index.d.ts`. no type is shared between them — they are different formats.
- **D4 — authority.** `combos.json` is authoritative for per-combo `platforms`/`reciprocal`; `agent_map_to_platforms_reciprocal` is derived and must agree — `check_data.ts` asserts the agreement.
- **D5 — identify cross-check.** `IdentifySchema` restates `fixture.d.ts`'s `Identify` for runtime use; `check_data.ts` asserts the two field lists stay identical (parse the d.ts's `export interface Identify` block, compare key sets), so the frozen contract and the runtime schema cannot drift apart.

## validation points — where the schemas actually run

1. **`tools/check_data.ts`** (new, `deno task check:data`, wired into `deno task check`): validates every `site/public/data/*.json` file, `fixtures/index-data.json`, and every `fixtures/from-identity/*.json` against the schemas; asserts D4 agreement and D5 field-identity. fails the build on drift — this is the drift alarm.
2. **`tools/build_data.ts`**: parses its own output through the schemas before writing (same process, cheap) so a zig dump change that breaks a shape fails `deno task build`, not a browser session.
3. **worker**: `getRegistry`/`getCombos`/`getIndex` parse through the schemas on first memoized load — an isolate boot fails loudly on a bad deploy rather than serving 500s per route.
4. **spa**: types come from `z.infer` (replacing the hand-written interfaces in `registry.ts`); no runtime parsing needed client-side (the data is same-origin and build-validated).
5. **cli golden test** (follow-up, optional): `zig build` then pipe `agent-detect index` / `registry --no-web` / `identify` outputs through the schemas in a deno test — skipped when the binary is absent so `deno task check` stays hermetic.

## code impact inventory

| step | file | change |
|------|------|--------|
| M1 | `site/src/lib/schemas.ts` (new) | all schemas above |
| M1 | `site/tools/check_data.ts` (new) | boundary validation + D4/D5 cross-checks |
| M1 | `site/deno.json` | `check:data` task; `check` runs it |
| M1 | `site/tools/build_data.ts` | pre-write validation; import schemas |
| M1 | `site/package.json` | `npm:zod` dependency |
| M2 | `site/src/lib/registry.ts` | `resolvePlatform` alias set (D2); interfaces replaced by `z.infer` re-exports from schemas.ts (D3 rename `IndexFile` → `IndexData`) |
| M2 | `site/worker/index.ts` | `query` → `params` (D1); schema-parse memoized assets |
| M2 | `fixtures/index.d.ts` | stale free-axis paragraph rewritten to the embedded maps (drift #3) |
| M2 | `site/public/llms.txt` | document every json endpoint + its schema name |
| M3 (optional, cli) | `src/main.zig` + `src/web.test.zig` | registry report gains `params`/`resolved` naming to mirror D1 (a breaking cli output change — its own commit + version note) |
| M3 (optional) | golden deno test | validate the built cli's `index`/`registry`/`identify` outputs (skipped when no binary) |

## milestones

1. **M1 — schemas + drift alarm.** schemas.ts, check_data.ts, tasks wired; `deno task check` fails on the current tree only if real drift exists (expected: none — the schemas were written from the shipped bytes).
2. **M2 — the consistency fixes.** D1–D5 landed, llms.txt documents the api; the website's `?platform=macos` works; `/index.json` returns `params`.
3. **M3 — cli-side mirror (optional).** only if the cli report's consumers want the mirrored naming; breaking change to the cli's json output, so it is its own decision and commit.
