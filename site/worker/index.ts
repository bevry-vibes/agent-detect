// The agent-detect website worker — the JSON routes in front of the static
// assets (the SPA + generated data files live in dist/, served by the assets
// system without invoking this worker).
//
// Routes:
//   /index.json                — the filtered result view as JSON (same filters
//                                and name→id resolution as the app's URL params)
//   /identify/<agent_id>.json  — one combo's merged fixture outputs
//   /registry.json             — the rule registry (alias to /data/registry.json)
//   everything else            — SPA fallback (index.html)
//
// Name resolution mirrors the zig CLI's `canonicalIdFor`/`canonicalFilterDim`
// (src/lib/registry.ts is shared with the SPA).

import type { AgentFile, CombosFile, IndexFile, Platform, Registry } from "../src/lib/registry";
import { comboSearchText, resolveDimId, resolvePlatform } from "../src/lib/registry";

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
let registryPromise: Promise<Registry> | null = null;
let combosPromise: Promise<CombosFile> | null = null;
let indexPromise: Promise<IndexFile> | null = null;

async function assetJSON<T>(env: Env, origin: string, p: string): Promise<T> {
  const res = await env.ASSETS.fetch(new URL(p, origin));
  if (!res.ok) throw new Error(`asset ${p} → ${res.status}`);
  return await res.json() as T;
}

function getRegistry(env: Env, origin: string): Promise<Registry> {
  registryPromise ??= assetJSON<Registry>(env, origin, "/data/registry.json");
  return registryPromise;
}

function getCombos(env: Env, origin: string): Promise<CombosFile> {
  combosPromise ??= assetJSON<CombosFile>(env, origin, "/data/combos.json");
  return combosPromise;
}

function getIndex(env: Env, origin: string): Promise<IndexFile> {
  indexPromise ??= assetJSON<IndexFile>(env, origin, "/data/index.json");
  return indexPromise;
}

/** `/harness|provider|model/<input>.json` — one index entry as JSON. The input
 * resolves exactly like the CLI flags (names, labels, aliases); a resolvable
 * non-canonical input 308-redirects to the strict-slug id's path. */
async function handleEntity(dim: "harness" | "provider" | "model", input: string, env: Env, origin: string): Promise<Response> {
  const registry = await getRegistry(env, origin);
  const tables = { harness: registry.harnesses, provider: registry.providers, model: registry.models } as const;
  const id = resolveDimId(tables[dim], input);
  if (!id) {
    return json({ error: `unknown ${dim}: ${input}`, hint: "see /registry.json for the resolvable names" }, 404);
  }
  if (id !== input) {
    return new Response(null, { status: 308, headers: { location: `/${dim}/${id}.json`, ...JSON_HEADERS } });
  }
  const index = await getIndex(env, origin);
  const entry = index[dim === "harness" ? "harnesses" : dim === "provider" ? "providers" : "models"].find((e) => e.id === id);
  if (!entry) return json({ error: `unknown ${dim}: ${input}` }, 404);
  return json(entry);
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

  const combos = (await getCombos(env, origin)).combos;
  const searchRegistry = resolved.search != null ? await getRegistry(env, origin) : null;
  const results = combos.filter((c) =>
    (!resolved.harness || c.harness === resolved.harness) &&
    (!resolved.provider || c.provider === resolved.provider) &&
    (!resolved.model || c.model === resolved.model) &&
    (!resolved.search || !searchRegistry || comboSearchText(c, searchRegistry).includes(resolved.search)) &&
    (!resolved.agent || c.agent_id === resolved.agent || c.fixtures.some((f) => f.id === resolved.agent)) &&
    (!resolved.email || c.email.toLowerCase() === resolved.email) &&
    (!resolved.platform || c.platforms.includes(resolved.platform)) &&
    (resolved.free == null || c.free === resolved.free) &&
    (resolved.reciprocal == null || c.reciprocal === resolved.reciprocal)
  );

  const hasFilter = Object.values(resolved).some((v) => v != null);
  const truncated = hasFilter && results.length > EXPAND_CAP;
  const expand = hasFilter && !truncated;

  const body = {
    query: raw,
    resolved,
    count: results.length,
    truncated,
    ...(truncated ? { note: `more than ${EXPAND_CAP} combos matched — compact rows only; narrow the filter for embedded fixture outputs` } : {}),
    results: expand
      ? await Promise.all(results.map(async (row) => ({
          ...row,
          detail: await assetJSON<AgentFile>(env, origin, `/data/agents/${row.agent_id}.json`),
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

    const entity = url.pathname.match(/^\/(harness|provider|model)\/([^/]+)\.json$/);
    if (entity) {
      return await handleEntity(entity[1] as "harness" | "provider" | "model", decodeURIComponent(entity[2]).toLowerCase(), env, url.origin);
    }

    const identify = url.pathname.match(/^\/identify\/([a-z0-9-]+)\.json$/);
    if (identify) {
      const res = await env.ASSETS.fetch(new URL(`/data/agents/${identify[1]}.json`, url.origin));
      if (!res.ok) {
        return json({ error: `unknown agent: ${identify[1]}`, hint: "see /index.json for the valid agent_ids" }, 404);
      }
      return new Response(res.body, { status: 200, headers: JSON_HEADERS });
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
