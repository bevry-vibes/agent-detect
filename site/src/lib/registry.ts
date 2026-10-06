// Shared registry types + the CLI-faithful name resolution — imported by both
// the SPA (client) and the worker (server), so URLs and API queries resolve
// exactly like `--harness/--provider/--model` flags do in the zig CLI
// (src/lib/rules.zig `canonicalIdFor` / `canonicalFilterDim`).
//
// The types are z.infer re-exports of site/src/lib/schemas.ts — the one
// declaration per json format; nothing here hand-writes a shape.

import {
  type AgentRow,
  type AgentsFile,
  type FixtureOutputs,
  type HarnessEntry,
  type IdentityFile,
  type IndexDataFile,
  type ModelEntry,
  type Platform,
  type ProviderEntry,
  type RegistryFile,
  type Rule,
} from "./schemas";

export type {
  AgentRow,
  AgentsFile,
  FixtureOutputs,
  HarnessEntry,
  IdentityFile,
  IndexDataFile,
  ModelEntry,
  Platform,
  ProviderEntry,
  RegistryFile,
  Rule,
};

export const PLATFORMS: Platform[] = ["darwin", "linux", "windows"];

/** the cli's alias table (canonicalWebPlatform): macos/mac → darwin, win → windows */
const PLATFORM_ALIASES: Record<string, Platform> = { macos: "darwin", mac: "darwin", win: "windows" };

/** a `?platform=` value → its canonical platform (aliases accepted, exactly like `--platform=`) */
export function resolvePlatform(raw: string | null | undefined): Platform | null {
  const v = raw?.trim().toLowerCase();
  if (!v) return null;
  if ((PLATFORMS as string[]).includes(v)) return v as Platform;
  return PLATFORM_ALIASES[v] ?? null;
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

/** the haystack an agent's free-text search matches against — the agent id and
 * email (identical modulo @local) plus each dim's label, name, and id */
export function agentSearchText(row: AgentRow, registry: RegistryFile): string {
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
