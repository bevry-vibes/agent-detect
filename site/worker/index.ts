// The agent-detect website worker — the JSON routes in front of the static
// assets (the SPA + generated data files live in dist/, served by the assets
// system without invoking this worker).
//
// Routes:
//   /index.json                       — the search view as JSON (same filters
//                                       and name→id resolution as the app's
//                                       URL params)
//   /agent|/harness|/provider|/model/<id>       — the entity views: the page
//   /agent|/harness|/provider|/model/<id>.json  — and the data; the query
//                                       filters GATE the entity (422 + the
//                                       match report on a mismatch)
//   /identify/<agent_id>.json         — 308 → /agent/<agent_id>.json (retired)
//   /registry.json                    — the rule registry (alias to /data/registry.json)
//   everything else                   — SPA fallback (index.html)
//
// Name resolution mirrors the zig CLI's `canonicalIdFor`/`canonicalFilterDim`
// (src/lib/registry.ts is shared with the SPA).

import type { AgentRow, IdentityFile, AgentsFile, IndexDataFile, Platform, RegistryFile } from "../src/lib/registry.ts";
import { agentSearchText, resolveDimId, resolvePlatform } from "../src/lib/registry.ts";

/** full fixture outputs embedded per result row, past this many rows */
const EXPAND_CAP = 50;

interface Env {
  ASSETS: Fetcher;
}

const JSON_HEADERS: Record<string, string> = {
  "content-type": "application/json; charset=utf-8",
  "access-control-allow-origin": "*",
  "cache-control": "public, max-age=300",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), { status, headers: JSON_HEADERS });
}

// the generated data files are parsed once per isolate and memoized
let registryPromise: Promise<RegistryFile> | null = null;
let combosPromise: Promise<AgentsFile> | null = null;
let indexPromise: Promise<IndexDataFile> | null = null;

async function assetJSON<T>(env: Env, origin: string, p: string): Promise<T> {
  const res = await env.ASSETS.fetch(new URL(p, origin));
  if (!res.ok) throw new Error(`asset ${p} → ${res.status}`);
  return await res.json() as T;
}

function getRegistry(env: Env, origin: string): Promise<RegistryFile> {
  registryPromise ??= assetJSON<RegistryFile>(env, origin, "/data/registry.json");
  return registryPromise;
}

function getAgents(env: Env, origin: string): Promise<AgentsFile> {
  combosPromise ??= assetJSON<AgentsFile>(env, origin, "/data/agents.json");
  return combosPromise;
}

function getIndex(env: Env, origin: string): Promise<IndexDataFile> {
  indexPromise ??= assetJSON<IndexDataFile>(env, origin, "/data/index.json");
  return indexPromise;
}

// ── the entity routes — /{agent,harness,provider,model}/{id}(.json)? ────────
// The cli's `index <kind> <id>` maps onto exactly these. The id is an INPUT
// normalised into the canonical id (names/labels/aliases for the dims; the
// agent id trimmed + lowercased + its trailing @local stripped). The query
// filters GATE the entity — they never slice: a filter that excludes it 422s
// with the per-filter match states (the cli's exit-14 twin) and a link to the
// view without the violating filters; an unknown id 404s.

type EntityKind = "agent" | "harness" | "provider" | "model";
const ENTITY_KINDS = ["agent", "harness", "provider", "model"] as const;

interface GateFilters {
  harness?: string;
  provider?: string;
  model?: string;
  email?: string;
  platform?: Platform;
  free?: boolean;
  reciprocal?: boolean;
}

interface GateMatch {
  filter: string;
  value: string;
  matched: boolean;
  fact?: string;
  /** the query param + resolved value the unfiltered link carries (matched filters only) */
  param?: string;
  qvalue?: string;
}

/** evaluate the filters against the entity — predicates, never slices. An
 * agent view predicates on its row's facts; a dim view on participation
 * (the entity participates in ≥1 combo satisfying the filter). */
function gateEntity(kind: EntityKind, canonical: string, f: GateFilters, agents: AgentRow[]): GateMatch[] {
  const seg = (agent: string, i: number) => agent.split("-")[i] ?? "";
  const viewSeg = kind === "harness" ? 0 : kind === "provider" ? 1 : 2;
  const viewRows =
    kind === "agent" ? agents.filter((a) => a.agent_id === canonical) : agents.filter((a) => seg(a.agent_id, viewSeg) === canonical);
  const matches: GateMatch[] = [];
  const push = (filter: string, value: string, matched: boolean, fact?: string, param?: string, qvalue?: string) =>
    matches.push({ filter, value, matched, fact, param, qvalue });

  if (kind === "agent") {
    const row = viewRows[0];
    if (f.harness != null) push("--harness", f.harness, row.harness === f.harness, `the agent's harness is ${row.harness}`, "harness", row.harness);
    if (f.provider != null) push("--provider", f.provider, row.provider === f.provider, `the agent's provider is ${row.provider}`, "provider", row.provider);
    if (f.model != null) push("--model", f.model, row.model === f.model, `the agent's model is ${row.model}`, "model", row.model);
    if (f.free != null) push(f.free ? "--free" : "--no-free", "", row.free === f.free, row.free ? "the cell is free" : "the cell is not free", "free", String(f.free));
    if (f.reciprocal != null)
      push(f.reciprocal ? "--reciprocal" : "--no-reciprocal", "", row.reciprocal === f.reciprocal, `the reciprocity of record is ${row.reciprocal}`, "reciprocal", String(f.reciprocal));
    if (f.platform != null) {
      const has = row.platforms.includes(f.platform);
      push("--platform", f.platform, has, row.platforms.length > 0 ? `captured on: ${row.platforms.join(", ")}` : "no captures", "platform", f.platform);
    }
    if (f.email != null) push("--email", f.email, row.email.toLowerCase() === f.email, `the email of record is ${row.email}`, "email", row.email);
  } else {
    const any = (pred: (r: AgentRow) => boolean) => viewRows.some(pred);
    if (f.free != null) {
      const found = any((r) => r.free === f.free);
      push(f.free ? "--free" : "--no-free", "", found, found ? "a combo's cell matches" : "no combo's cell matches", "free", String(f.free));
    }
    if (f.reciprocal != null) {
      const found = any((r) => r.reciprocal === f.reciprocal);
      push(f.reciprocal ? "--reciprocal" : "--no-reciprocal", "", found, found ? "a combo's reciprocity of record matches" : "no combo's reciprocity of record matches", "reciprocal", String(f.reciprocal));
    }
    if (f.platform != null) {
      const found = any((r) => r.platforms.includes(f.platform!));
      push("--platform", f.platform, found, found ? "a combo was captured on it" : "no combo was captured on it", "platform", f.platform);
    }
    if (f.email != null) {
      const local = f.email.replace(/@local$/, "");
      const row = agents.find((a) => a.agent_id === local);
      const found = row != null && seg(row.agent_id, viewSeg) === canonical;
      push("--email", f.email, found, found ? "the email's agent carries this dim" : "the email's agent does not carry this dim", "email", row?.email ?? f.email);
    }
    if (f.harness != null && kind !== "harness") {
      const found = any((r) => seg(r.agent_id, 0) === f.harness);
      push("--harness", f.harness, found, found ? "a combo carries it" : "no combo carries it", "harness", f.harness);
    }
    if (f.provider != null && kind !== "provider") {
      const found = any((r) => seg(r.agent_id, 1) === f.provider);
      push("--provider", f.provider, found, found ? "a combo carries it" : "no combo carries it", "provider", f.provider);
    }
    if (f.model != null && kind !== "model") {
      const found = any((r) => seg(r.agent_id, 2) === f.model);
      push("--model", f.model, found, found ? "a combo carries it" : "no combo carries it", "model", f.model);
    }
  }
  return matches;
}

/** the entity route's query → the resolved gate filters. Dim values resolve
 * like everywhere else; an unresolvable dim can never match (the fact says so). */
async function parseGateFilters(url: URL, env: Env, origin: string): Promise<GateFilters> {
  const f: GateFilters = {};
  const q = url.searchParams;
  if (q.get("harness") != null || q.get("provider") != null || q.get("model") != null) {
    const registry = await getRegistry(env, origin);
    const tables = { harness: registry.harnesses, provider: registry.providers, model: registry.models } as const;
    for (const dim of ["harness", "provider", "model"] as const) {
      const raw = q.get(dim);
      if (raw == null) continue;
      f[dim] = resolveDimId(tables[dim], raw) ?? `unresolvable:${raw}`;
    }
  }
  const email = q.get("email");
  if (email != null && email.trim() !== "") f.email = email.trim().toLowerCase();
  const platform = resolvePlatform(q.get("platform"));
  if (platform != null) f.platform = platform;
  const free = triBool(q.get("free"));
  if (free != null) f.free = free;
  const reciprocal = triBool(q.get("reciprocal"));
  if (reciprocal != null) f.reciprocal = reciprocal;
  return f;
}

function unfilteredUrl(kind: EntityKind, canonical: string, matches: GateMatch[]): string {
  const qs = matches
    .filter((m) => m.matched && m.param != null)
    .map((m) => `${m.param}=${encodeURIComponent(m.qvalue ?? "")}`)
    .join("&");
  return qs.length > 0 ? `/${kind}/${canonical}?${qs}` : `/${kind}/${canonical}`;
}

/** the filtered-out report — the cli's exit-14 twin (EntityMatchReportSchema) */
function matchReport(kind: EntityKind, input: string, canonical: string, matches: GateMatch[]): Record<string, unknown> {
  return {
    error: "filtered-out",
    entity: kind,
    input,
    id: canonical,
    filters: matches.map((m) => ({ filter: m.filter, value: m.value, matched: m.matched, ...(m.fact ? { fact: m.fact } : {}) })),
    unfiltered_url: unfilteredUrl(kind, canonical, matches),
  };
}

/** the filtered-out explanation page — server-rendered, no app boot needed */
function filteredOutPage(kind: EntityKind, input: string, canonical: string, matches: GateMatch[]): Response {
  const items = matches
    .map((m) =>
      `<li><strong>${m.matched ? "matched" : "did not match"}</strong> <code>${m.filter}${m.value ? `=${m.value}` : ""}</code>${m.fact ? ` — ${m.fact}` : ""}</li>`)
    .join("");
  const link = unfilteredUrl(kind, canonical, matches);
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>filtered out — ${canonical}</title></head>
<body style="font-family:ui-monospace,monospace;max-width:42rem;margin:4rem auto;padding:0 1rem;line-height:1.6">
<h1>filtered out</h1>
<p>${kind} <code>${input}</code> resolved to <code>${canonical}</code> — but:</p>
<ul>${items}</ul>
<p><a href="${link}">view ${canonical} without the violating filters</a></p>
</body></html>`;
  return new Response(html, { status: 422, headers: { "content-type": "text/html; charset=utf-8", ...JSON_HEADERS } });
}

/** normalise an agent-route input: trim + lowercase + the trailing @local strip */
function normaliseAgentInput(raw: string): string {
  const lowered = raw.trim().toLowerCase();
  return lowered.endsWith("@local") ? lowered.slice(0, -"@local".length) : lowered;
}

/** the entity routes — the data (.json) and the page (bare path) share the
 * resolution and the gate; only the 422/404 bodies differ. */
async function handleEntityRoute(kindRaw: string, rawInput: string, url: URL, env: Env, asJson: boolean): Promise<Response> {
  const kind = kindRaw as EntityKind;
  const origin = url.origin;
  const input = rawInput;

  // resolve the canonical id
  let canonical: string | null = null;
  if (kind === "agent") {
    canonical = normaliseAgentInput(input);
    const agents = await getAgents(env, origin);
    if (!agents.agents.some((a) => a.agent_id === canonical)) canonical = null;
  } else {
    const registry = await getRegistry(env, origin);
    const tables = { harness: registry.harnesses, provider: registry.providers, model: registry.models } as const;
    const dim = kind as "harness" | "provider" | "model";
    canonical = resolveDimId(tables[dim], input);
  }
  if (canonical == null) {
    if (asJson) {
      return json(
        kind === "agent"
          ? { error: `unknown agent: ${input}`, hint: "see /index.json for the valid agent_ids" }
          : { error: `unknown ${kind}: ${input}`, hint: "see /registry.json for the resolvable names" },
        404,
      );
    }
    // the app's unknown-entity page renders with the honest status
    const res = await env.ASSETS.fetch(new URL("/index.html", origin));
    return new Response(res.body, { status: 404, headers: { "content-type": "text/html; charset=utf-8", ...JSON_HEADERS } });
  }

  // a non-canonical input 308s to the canonical route (the dims resolve from
  // names/labels/aliases; the agent id from case/@local form)
  if (canonical !== input) {
    const target = `/${kind}/${canonical}.json`.replace(/\.json$/, asJson ? ".json" : "");
    const suffix = asJson ? ".json" : "";
    return new Response(null, { status: 308, headers: { location: `/${kind}/${canonical}${suffix}${url.search}`, ...JSON_HEADERS } });
  }

  // the gate
  const filters = await parseGateFilters(url, env, origin);
  const gateKeys = Object.keys(filters);
  if (gateKeys.length > 0) {
    const agents = await getAgents(env, origin);
    const matches = gateEntity(kind, canonical, filters, agents.agents);
    if (matches.some((m) => !m.matched)) {
      if (asJson) return json(matchReport(kind, input, canonical, matches), 422);
      return filteredOutPage(kind, input, canonical, matches);
    }
  }

  // passed — the payload
  if (asJson) {
    if (kind === "agent") {
      const res = await env.ASSETS.fetch(new URL(`/data/agents/${canonical}.json`, origin));
      if (!res.ok) return json({ error: `unknown agent: ${canonical}` }, 404);
      return new Response(res.body, { status: 200, headers: JSON_HEADERS });
    }
    const index = await getIndex(env, origin);
    const entry = index[kind === "harness" ? "harnesses" : kind === "provider" ? "providers" : "models"].find((e) => e.id === canonical);
    if (!entry) return json({ error: `unknown ${kind}: ${input}` }, 404);
    return json(entry);
  }
  return await env.ASSETS.fetch(new URL("/index.html", origin));
}

interface Resolved {
  harness: string | null;
  provider: string | null;
  model: string | null;
  search: string | null;
  agent: string | null;
  email: string | null;
  platform: Platform | null;
  free: boolean | null;
  reciprocal: boolean | null;
}

/** a `?free=`/`?reciprocal=` value → its boolean (`false`/`no` accepted), or null */
function triBool(raw: string | null): boolean | null {
  const v = raw?.trim().toLowerCase();
  if (v == null || v === "") return null;
  if (v === "true" || v === "1" || v === "yes") return true;
  if (v === "false" || v === "0" || v === "no") return false;
  return null;
}

async function handleIndex(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const origin = url.origin;
  const q = request.url.includes("?") ? url.searchParams : null;
  const raw = {
    harness: q?.get("harness") ?? null,
    provider: q?.get("provider") ?? null,
    model: q?.get("model") ?? null,
    search: q?.get("search") ?? null,
    agent: q?.get("agent") ?? null,
    email: q?.get("email") ?? null,
    platform: q?.get("platform") ?? null,
    free: q?.get("free") ?? null,
    reciprocal: q?.get("reciprocal") ?? null,
  };

  const resolved: Resolved = { harness: null, provider: null, model: null, search: null, agent: null, email: null, platform: null, free: null, reciprocal: null };
  const unresolved: { param: string; value: string }[] = [];

  if (raw.harness != null || raw.provider != null || raw.model != null || raw.search != null) {
    const registry = await getRegistry(env, origin);
    const tables = { harness: registry.harnesses, provider: registry.providers, model: registry.models } as const;
    for (const dim of ["harness", "provider", "model"] as const) {
      const value = raw[dim];
      if (value == null) continue;
      const id = resolveDimId(tables[dim], value);
      if (id) resolved[dim] = id;
      else unresolved.push({ param: dim, value });
    }
  }
  if (raw.search != null) resolved.search = raw.search.trim().toLowerCase() || null;
  if (raw.agent != null) resolved.agent = raw.agent.trim().toLowerCase() || null;
  if (raw.email != null) resolved.email = raw.email.trim().toLowerCase() || null;
  if (raw.platform != null) {
    const plat = resolvePlatform(raw.platform);
    if (plat) resolved.platform = plat;
    else unresolved.push({ param: "platform", value: raw.platform });
  }
  resolved.free = triBool(raw.free);
  resolved.reciprocal = triBool(raw.reciprocal);

  if (unresolved.length) {
    return json(
      {
        error: "unresolved filter value(s) — accept display names or strict ids, like the CLI flags",
        unresolved,
        hint: "see /registry.json for the resolvable names, or /index.json unfiltered for the combo index",
      },
      404,
    );
  }

  const agents = (await getAgents(env, origin)).agents;
  const searchRegistry = resolved.search != null ? await getRegistry(env, origin) : null;
  const results = agents.filter((c) =>
    (!resolved.harness || c.harness === resolved.harness) &&
    (!resolved.provider || c.provider === resolved.provider) &&
    (!resolved.model || c.model === resolved.model) &&
    (!resolved.search || !searchRegistry || agentSearchText(c, searchRegistry).includes(resolved.search)) &&
    (!resolved.agent || c.agent_id === resolved.agent) &&
    (!resolved.email || c.email.toLowerCase() === resolved.email) &&
    (!resolved.platform || c.platforms.includes(resolved.platform)) &&
    (resolved.free == null || c.free === resolved.free) &&
    (resolved.reciprocal == null || c.reciprocal === resolved.reciprocal)
  );

  const hasFilter = Object.values(resolved).some((v) => v != null);
  const truncated = hasFilter && results.length > EXPAND_CAP;
  const expand = hasFilter && !truncated;

  const body = {
    params: raw,
    resolved,
    count: results.length,
    truncated,
    ...(truncated ? { note: `more than ${EXPAND_CAP} agents matched — compact rows only; narrow the filter for embedded fixture outputs` } : {}),
    results: expand
      ? await Promise.all(results.map(async (row) => ({
          ...row,
          detail: await assetJSON<IdentityFile>(env, origin, `/data/agents/${row.agent_id}.json`),
        })))
      : results,
  };
  return json(body);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET, HEAD, OPTIONS",
        },
      });
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return json({ error: "method not allowed" }, 405);
    }

    if (url.pathname === "/index.json") return await handleIndex(request, env);

    const entityJson = url.pathname.match(/^\/(agent|harness|provider|model)\/([^/]+)\.json$/);
    if (entityJson) {
      return await handleEntityRoute(entityJson[1], decodeURIComponent(entityJson[2]), url, env, true);
    }

    const entityPage = url.pathname.match(/^\/(agent|harness|provider|model)\/([^/]+)$/);
    if (entityPage) {
      return await handleEntityRoute(entityPage[1], decodeURIComponent(entityPage[2]), url, env, false);
    }

    // the retired route — the agent documents live at /agent/<id>.json now
    const identify = url.pathname.match(/^\/identify\/([a-z0-9-]+)\.json$/);
    if (identify) {
      return new Response(null, { status: 308, headers: { location: `/agent/${identify[1]}.json`, ...JSON_HEADERS } });
    }

    if (url.pathname === "/registry.json") {
      const res = await env.ASSETS.fetch(new URL("/data/registry.json", url.origin));
      if (!res.ok) return json({ error: "registry unavailable" }, 500);
      return new Response(res.body, { status: 200, headers: JSON_HEADERS });
    }

    // SPA fallback: every path that reaches the worker and is not a route
    // above renders the app (static assets that exist never reach here).
    return await env.ASSETS.fetch(new URL("/index.html", url.origin));
  },
} satisfies ExportedHandler<Env>;
