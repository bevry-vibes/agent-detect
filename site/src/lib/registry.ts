// Shared registry types + the CLI-faithful name resolution — imported by both
// the SPA (client) and the worker (server), so URLs and API queries resolve
// exactly like `--harness/--provider/--model` flags do in the zig CLI
// (src/lib/rules.zig `canonicalIdFor` / `canonicalFilterDim`).

export interface Rule {
  /** canonical rule name, e.g. "kimi-code" */
  name: string;
  /** display label, e.g. "Kimi Code" */
  label: string;
  short_title: string | null;
  variations: string[];
  /** the strict-slug id (`slugId(name)`) — the alphanumeric form URLs carry */
  id: string;
  // policy fields (presence varies by entity)
  openness?: string | null;
  license?: string | null;
  closed_training?: string | null;
  open_training?: string | null;
  sources?: string[];
  license_sources?: string[];
  training_sources?: string[];
  reciprocity_scandal?: boolean;
  reciprocity_scandal_sources?: string[];
}

export interface Registry {
  generated_at: number;
  counts: { harnesses: number; providers: number; models: number };
  harnesses: Rule[];
  providers: Rule[];
  models: Rule[];
}

export type Platform = "darwin" | "linux" | "windows";
export const PLATFORMS: Platform[] = ["darwin", "linux", "windows"];

/** a known platform id (the ?platform= filter accepts exactly these) */
export function resolvePlatform(raw: string | null | undefined): Platform | null {
  const v = raw?.trim().toLowerCase();
  return (PLATFORMS as string[]).includes(v ?? "") ? (v as Platform) : null;
}

/** compact row in data/combos.json — one per h×p×m combo, from the
 * from-identity channel alone (the site shows declared identifications only) */
export interface ComboRow {
  agent_id: string;
  harness: string; // strict slug
  provider: string;
  model: string;
  /** trailer email of record (the `<...>` part of the trailer) */
  email: string;
  /** the most recent fixture's `identify.reciprocal` */
  reciprocal: boolean;
  /** explain.state of the most recent fixture that carries one */
  state: string | null;
  /** the free axis — the combo's provider-model cell is in
   * provider_map_to_free_models */
  free: boolean;
  platforms: Platform[];
  updated_at: number;
  fixtures: { id: string; platform: Platform; updated_at: number }[];
}

/** the index — fixtures/index-data.json verbatim (also the released `index`
 * action's embedded data and data/index.json). Entries carry the from-identity
 * fixture's per-entity identify fields (unprefixed, minus instance state) plus
 * variations and their association id arrays. */
export interface HarnessEntry {
  label: string;
  short_title: string | null;
  name: string;
  id: string;
  license: string | null;
  open_training: string | null;
  closed_training: string | null;
  reciprocity_scandal: boolean;
  variations: string[];
  providers: string[];
  models: string[];
}

export interface ProviderEntry {
  label: string;
  name: string;
  id: string;
  open_training: string | null;
  closed_training: string | null;
  reciprocity_scandal: boolean;
  variations: string[];
  harnesses: string[];
  models: string[];
}

export interface ModelEntry {
  label: string;
  short_title: string | null;
  name: string;
  id: string;
  openness: string | null;
  open_training: string | null;
  closed_training: string | null;
  license: string | null;
  variations: string[];
  providers: string[];
  harnesses: string[];
}

export interface IndexFile {
  harnesses: HarnessEntry[];
  providers: ProviderEntry[];
  models: ModelEntry[];
  provider_map_to_free_models: Record<string, string[]>;
  agent_map_to_platforms_reciprocal: Record<string, { platforms: Platform[]; reciprocal: boolean }>;
}

export interface CombosFile {
  generated_at: number;
  counts: { combos: number; fixtures: number };
  combos: ComboRow[];
}

/** one fixture's outputs — the verbatim CLI outputs the site displays */
export interface FixtureOutputs {
  identify: Record<string, unknown>;
  "trailer co-author"?: string;
  "trailer assisted-by"?: string;
  found?: unknown;
  raw?: unknown;
  explain?: Record<string, unknown> | null;
  "check-reciprocal"?: string;
  [key: string]: unknown;
}

/** data/agents/<agent_id>.json — the combo's from-identity fixtures, merged */
export interface AgentFile {
  agent_id: string;
  harness: string;
  provider: string;
  model: string;
  fixtures: {
    id: string;
    platform: Platform;
    updated_at: number;
    meta: Record<string, unknown>;
    outputs: FixtureOutputs;
  }[];
}

/** the zig `slugId`: lowercase, strip every non-alphanumeric character */
export function slugId(display: string): string {
  let out = "";
  for (const c of display.toLowerCase()) {
    if (/[a-z0-9]/.test(c)) out += c;
  }
  return out;
}

/** models shed their catalog namespace (`deepseek-ai/DeepSeek-V4-Flash` → the bare id) */
function afterNamespace(input: string): string {
  const slash = input.lastIndexOf("/");
  return slash === -1 ? input : input.slice(slash + 1);
}

function slugEquals(display: string, slug: string): boolean {
  return slugId(display) === slug;
}

/**
 * resolve a user-provided dim to its canonical rule, mirroring the CLI's
 * `canonicalIdFor`: exact canonical-name equality first, then the normalized
 * alias set (name, label, short_title, variations), first rule in array order.
 */
export function resolveDim(rules: Rule[], input: string): Rule | null {
  const lookup = afterNamespace(input.trim());
  if (!lookup) return null;
  for (const r of rules) {
    if (r.name === lookup) return r;
  }
  const slug = slugId(lookup);
  if (!slug) return null;
  for (const r of rules) {
    if (slugEquals(r.name, slug)) return r;
    if (slugEquals(r.label, slug)) return r;
    if (r.short_title != null && slugEquals(r.short_title, slug)) return r;
    for (const v of r.variations) {
      if (slugEquals(v, slug)) return r;
    }
  }
  return null;
}

/** the dim's strict-slug filter id (`canonicalFilterDim`) */
export function resolveDimId(rules: Rule[], input: string): string | null {
  const rule = resolveDim(rules, input);
  return rule ? rule.id : null;
}

/** the haystack a combo's free-text search matches against — the combo id and
 * email (identical modulo @local) plus each dim's label, name, and id */
export function comboSearchText(row: ComboRow, registry: Registry): string {
  const rule = (dim: "harnesses" | "providers" | "models", id: string) => registry[dim].find((r) => r.id === id);
  const h = rule("harnesses", row.harness);
  const p = rule("providers", row.provider);
  const m = rule("models", row.model);
  return [
    row.agent_id,
    row.email,
    row.harness,
    row.provider,
    row.model,
    h?.label,
    h?.name,
    p?.label,
    p?.name,
    m?.label,
    m?.name,
  ]
    .filter((v): v is string => !!v)
    .join("\n")
    .toLowerCase();
}

/** resolve a rule's aliases into combobox search keywords */
export function ruleKeywords(rule: Rule): string[] {
  return [rule.name, rule.label, rule.id, ...(rule.short_title ? [rule.short_title] : []), ...rule.variations];
}

/** trailer email of a fixture — the `<...>` part of a trailer line */
export function trailerEmail(trailer: string | undefined | null): string | null {
  if (!trailer) return null;
  const m = /<([^<>]+)>/.exec(trailer);
  return m ? m[1] : null;
}
