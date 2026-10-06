// site/src/lib/schemas.ts — one zod schema per json format; types export via
// z.infer and every producer/consumer boundary validates through these.
//
// The naming taxonomy (stated once, so the schemas read without prose):
//   *FileSchema     — a whole json document that exists on disk or is served
//                     verbatim (registry.json, index.json, agents.json, and
//                     the per-agent identity fixture copies).
//   *ReportSchema   — an ephemeral query response, never stored (the worker's
//                     /index.json envelope; the filtered-entity 422 body).
//                     A report's `count` is a property of the query, not of
//                     any document.
//   FixtureOutputs  — the `outputs` object embedded in the fixture channels
//                     (the saved CLI outputs, verbatim); Identify is its one
//                     fully-typed payload — the 29-field contract.
//   bare names      — embedded entries, rows, and shared primitives.
//
// Stored files carry no summary fields: anything recomputable from the same
// document (array lengths) is not stated. There is deliberately no
// CaptureFileSchema — the from-capture channel's types stay in
// fixtures/fixture.d.ts, maintainer-side; nothing about it is served.

import { z } from "zod";

/** strict slug — the zig `slugId` output: lowercase alphanumeric only */
export const Slug = z.string().regex(/^[a-z0-9]+$/);
/** dash-joined strict slugs — `<harness>-<provider>-<model>`. NOT a strict slug
 * itself (the agent map's record keys are these); each dash-separated segment is one. */
export const AgentId = z.string().regex(/^[a-z0-9]+(-[a-z0-9]+)*$/);
/** canonical platform ids only — `macos`/`mac` → `darwin`, `win` → `windows`
 * normalise at the query boundaries (resolvePlatform); stored data is always
 * canonical. On the site and in the index, a platforms array means: platforms
 * with captures — the from-capture stems, scanned and never parsed. */
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
});

// ── 2. index.json ≡ fixtures/index-data.json ≡ `agent-detect index` output ──

const IndexEntryBase = {
  label: z.string(),
  name: z.string(),
  id: Slug,
  open_training: TrainingAxis,
  closed_training: TrainingAxis,
  variations: z.array(z.string()),
  // NO reciprocity_scandal here — ModelRule has no such field and no model
  // entry carries it; it sits on harnesses/providers only.
};

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
   * agent's from-capture stems (platforms with captures — the stems are the
   * only capture fact the cli ever carries); reciprocal = the agent's
   * from-identity declaration of record. agents.json must agree (check_data
   * asserts it). Keyed by agent id — the dash-joined form, not a strict slug. */
  agent_map_to_platforms_reciprocal: z.record(
    AgentId,
    z.object({ platforms: z.array(Platform), reciprocal: z.boolean() }),
  ),
});

// ── 3. agents.json — one row per agent ──────────────────────────────────────

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
  /** the declaration's explain.state */
  state: z.enum(["reciprocal", "not-reciprocal", "undetectable", "unknown"]).nullable(),
  free: z.boolean(),
  /** platforms with captures — the agent's from-capture stems */
  platforms: z.array(Platform),
  /** the declaration's meta.updated_at */
  updated_at: Epoch,
  // no fixtures array: from-identity fixture ids ARE agent ids, so ?agent=
  // matches agent_id alone; no counts — lengths recompute from the arrays.
});
export const AgentsFileSchema = z.object({
  generated_at: Epoch,
  agents: z.array(AgentRowSchema),
});

// ── 4+8. agents/<agent_id>.json ≡ /identify/<agent_id>.json —
//         the from-identity fixture, verbatim (the filename IS the agent id;
//         no site envelope — the dims stay in the filename) ─────────────────

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
     * enum — identify, explain, check-reciprocal) — the trailers and found print
     * none, so they carry no keys */
    "identify.stderr": StderrLines.optional(),
    "explain.stderr": StderrLines.optional(),
    /** the recorded stdout verdict — the fixture form, spaces and "is" included
     * (fixture.d.ts's union). mutually exclusive with the stderr by state:
     * stdout on the states that print stdout (0/10), stderr-only on 8/9 */
    "check-reciprocal": z.enum(["is reciprocal", "not reciprocal"]).optional(),
    "check-reciprocal.stderr": StderrLines.optional(),
  })
  .passthrough();

/** restates fixture.d.ts's IdentityFile for runtime use — the site serves the
 * from-identity fixture verbatim; check_data.ts asserts envelope-wide field
 * identity against the d.ts */
export const IdentityFileSchema = z.object({
  outputs: FixtureOutputsSchema,
  meta: z.object({ updated_at: Epoch }),
});

// ── 5. worker GET /index.json — the query report (ephemeral, never stored) ──

/** `params` is the RAW echo; `resolved` is canonical */
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
//       web's 422 body (the id resolved, the filters did not) ────────────────

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
  /** every given filter, each with its match state */
  filters: z.array(FilterMatchSchema).min(1),
  /** the same view without the violating filters — the web returns the path,
   * the cli prints the absolute deep link */
  unfiltered_url: z.string(),
});


// ── inferred types — the site imports these, never hand-writes interfaces ───

export type Slug = z.infer<typeof Slug>;
export type AgentId = z.infer<typeof AgentId>;
export type Platform = z.infer<typeof Platform>;
export type TrainingAxis = z.infer<typeof TrainingAxis>;
export type StderrLines = z.infer<typeof StderrLines>;
export type Rule = z.infer<typeof RuleSchema>;
export type RegistryFile = z.infer<typeof RegistryFileSchema>;
export type HarnessEntry = z.infer<typeof HarnessEntrySchema>;
export type ProviderEntry = z.infer<typeof ProviderEntrySchema>;
export type ModelEntry = z.infer<typeof ModelEntrySchema>;
export type IndexDataFile = z.infer<typeof IndexDataFileSchema>;
export type AgentRow = z.infer<typeof AgentRowSchema>;
export type AgentsFile = z.infer<typeof AgentsFileSchema>;
export type Identify = z.infer<typeof IdentifySchema>;
export type FixtureOutputs = z.infer<typeof FixtureOutputsSchema>;
export type IdentityFile = z.infer<typeof IdentityFileSchema>;
export type IndexQueryReport = z.infer<typeof IndexQueryReportSchema>;
export type FilterMatch = z.infer<typeof FilterMatchSchema>;
export type EntityMatchReport = z.infer<typeof EntityMatchReportSchema>;
