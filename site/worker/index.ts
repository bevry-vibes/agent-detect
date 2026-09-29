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

import type { AgentFile, CombosFile, Registry } from "../src/lib/registry";
import { resolveDimId } from "../src/lib/registry";

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

interface Resolved {
  harness: string | null;
  provider: string | null;
  model: string | null;
  email: string | null;
  agent: string | null;
}

async function handleIndex(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const origin = url.origin;
  const q = request.url.includes("?") ? url.searchParams : null;
  const raw = {
    harness: q?.get("harness") ?? null,
    provider: q?.get("provider") ?? null,
    model: q?.get("model") ?? null,
    email: q?.get("email") ?? null,
    agent: q?.get("agent") ?? null,
  };

  const resolved: Resolved = { harness: null, provider: null, model: null, email: null, agent: null };
  const unresolved: { param: string; value: string }[] = [];

  if (raw.harness != null || raw.provider != null || raw.model != null) {
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
  if (raw.email != null) resolved.email = raw.email.trim().toLowerCase() || null;
  if (raw.agent != null) resolved.agent = raw.agent.trim().toLowerCase() || null;

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
  const results = combos.filter((c) =>
    (!resolved.harness || c.harness === resolved.harness) &&
    (!resolved.provider || c.provider === resolved.provider) &&
    (!resolved.model || c.model === resolved.model) &&
    (!resolved.email ||
      c.email === resolved.email ||
      (!resolved.email.includes("@") && (c.email.split("@")[0] === resolved.email || c.agent_id === resolved.email))) &&
    (!resolved.agent || c.agent_id === resolved.agent || c.fixtures.some((f) => f.id === resolved.agent))
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
