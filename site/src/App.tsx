import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { resolveDimId, type CombosFile, type Registry } from "@/lib/registry";
import { AgentPage } from "@/components/agent-page";
import { FilterBar, type Filters } from "@/components/filter-bar";
import { Hero } from "@/components/hero";
import { ResultsTable } from "@/components/results-table";
import { SiteHeader } from "@/components/site-header";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

const DIMS = ["harness", "provider", "model"] as const;
type Dim = (typeof DIMS)[number];

const NO_FILTERS: Filters = { harness: null, provider: null, model: null, email: null };

/**
 * URL params work exactly like the CLI flags: display names and aliases are
 * accepted, the URL is canonicalised to the strict-slug alphanumeric ids
 * (`?harness=Kimi+Code` lands as `?harness=kimicode`). Unresolvable values are
 * dropped with a notice, like an unknown flag.
 */
function parseURL(search: string, registry: Registry) {
  const q = new URLSearchParams(search);
  const filters: Filters = { ...NO_FILTERS };
  const canonical = new URLSearchParams();
  const notices: string[] = [];
  const tables = { harness: registry.harnesses, provider: registry.providers, model: registry.models } as const;
  for (const dim of DIMS) {
    const raw = q.get(dim);
    if (raw == null) continue;
    const id = resolveDimId(tables[dim], raw);
    if (id) {
      filters[dim] = id;
      canonical.set(dim, id);
      if (id !== raw.trim().toLowerCase()) notices.push(`${dim} "${raw}" resolved to the canonical id "${id}"`);
    } else {
      notices.push(`${dim} "${raw}" did not resolve to a rule — dropped`);
    }
  }
  const email = q.get("email")?.trim().toLowerCase();
  if (email) {
    filters.email = email;
    canonical.set("email", email);
  }
  const agent = q.get("agent")?.trim().toLowerCase() || null;
  if (agent) {
    canonical.set("agent", agent);
    if (agent !== q.get("agent")) notices.push(`agent canonicalised to "${agent}"`);
  }
  return { filters, agent, canonical: canonical.toString(), notices };
}

function buildSearch(filters: Filters, agent: string | null): string {
  const q = new URLSearchParams();
  for (const dim of DIMS) if (filters[dim]) q.set(dim, filters[dim]);
  if (filters.email) q.set("email", filters.email);
  if (agent) q.set("agent", agent);
  return q.toString();
}

export default function App() {
  const [registry, setRegistry] = useState<Registry | null>(null);
  const [combosFile, setCombosFile] = useState<CombosFile | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [filters, setFilters] = useState<Filters>({ ...NO_FILTERS });
  const [agent, setAgent] = useState<string | null>(null);
  const [notices, setNotices] = useState<string[]>([]);
  const registryRef = useRef<Registry | null>(null);
  // full-page agent view: the index's scroll position is remembered per entry
  // so "back to results" lands where the click happened
  const scrollMem = useRef(new Map<string, number>());
  const cameFromIndex = useRef(false);
  const viewRef = useRef<"index" | "agent">("index");

  useEffect(() => {
    if ("scrollRestoration" in history) history.scrollRestoration = "manual";
  }, []);

  useEffect(() => {
    Promise.all([
      fetch("/data/registry.json").then((r) => {
        if (!r.ok) throw new Error(`registry: HTTP ${r.status}`);
        return r.json() as Promise<Registry>;
      }),
      fetch("/data/combos.json").then((r) => {
        if (!r.ok) throw new Error(`combos: HTTP ${r.status}`);
        return r.json() as Promise<CombosFile>;
      }),
    ]).then(([reg, cf]) => {
      registryRef.current = reg;
      setRegistry(reg);
      setCombosFile(cf);
      const parsed = parseURL(window.location.search, reg);
      setFilters(parsed.filters);
      setAgent(parsed.agent);
      setNotices(parsed.notices);
      const canonicalSearch = parsed.canonical;
      if (new URLSearchParams(window.location.search).toString() !== canonicalSearch) {
        history.replaceState(null, "", `${window.location.pathname}${canonicalSearch ? `?${canonicalSearch}` : ""}${window.location.hash}`);
      }
    }).catch((err) => setLoadError(String(err)));
  }, []);

  const syncFromURL = useCallback(() => {
    const reg = registryRef.current;
    if (!reg) return;
    const parsed = parseURL(window.location.search, reg);
    setFilters(parsed.filters);
    setAgent(parsed.agent);
    setNotices(parsed.notices);
  }, []);

  useEffect(() => {
    window.addEventListener("popstate", syncFromURL);
    return () => window.removeEventListener("popstate", syncFromURL);
  }, [syncFromURL]);

  const pushURL = (nextFilters: Filters, nextAgent: string | null) => {
    const qs = buildSearch(nextFilters, nextAgent);
    history.pushState(null, "", `${window.location.pathname}${qs ? `?${qs}` : ""}${window.location.hash}`);
  };

  const onDim = (dim: Dim, id: string | null) => {
    const next = { ...filters, [dim]: id };
    setFilters(next);
    setAgent(null);
    setNotices([]);
    pushURL(next, null);
  };
  const onEmail = (email: string | null) => {
    const next = { ...filters, email };
    setFilters(next);
    setAgent(null);
    setNotices([]);
    pushURL(next, null);
  };
  const onClear = () => {
    setFilters({ ...NO_FILTERS });
    setAgent(null);
    setNotices([]);
    pushURL({ ...NO_FILTERS }, null);
  };
  const onSelect = (selected: string) => {
    if (agent === selected) return;
    scrollMem.current.set(window.location.search, window.scrollY);
    cameFromIndex.current = true;
    setAgent(selected);
    pushURL(filters, selected);
  };

  /** "close" the agent results — back to the exact index entry when we came
   * from one, otherwise push the filtered index as a new entry */
  const closeAgent = () => {
    if (cameFromIndex.current) {
      cameFromIndex.current = false;
      history.back();
    } else {
      const qs = buildSearch(filters, null);
      history.pushState(null, "", `${window.location.pathname}${qs ? `?${qs}` : ""}${window.location.hash}`);
      setAgent(null);
      setNotices([]);
    }
  };

  // view transitions: returning to the index restores its remembered scroll;
  // the agent page scrolls itself to the top on mount
  useEffect(() => {
    const next = agent ? "agent" : "index";
    if (next === viewRef.current) return;
    viewRef.current = next;
    if (next === "index") window.scrollTo(0, scrollMem.current.get(window.location.search) ?? 0);
  }, [agent]);

  const rows = useMemo(() => {
    if (!combosFile) return [];
    return combosFile.combos.filter(
      (c) =>
        (!filters.harness || c.harness === filters.harness) &&
        (!filters.provider || c.provider === filters.provider) &&
        (!filters.model || c.model === filters.model) &&
        (!filters.email ||
          c.email === filters.email ||
          (!filters.email.includes("@") && (c.email.split("@")[0] === filters.email || c.agent_id === filters.email))),
    );
  }, [combosFile, filters]);

  const counts = useMemo(() => {
    const harnesses: Record<string, number> = {};
    const providers: Record<string, number> = {};
    const models: Record<string, number> = {};
    for (const c of combosFile?.combos ?? []) {
      harnesses[c.harness] = (harnesses[c.harness] ?? 0) + 1;
      providers[c.provider] = (providers[c.provider] ?? 0) + 1;
      models[c.model] = (models[c.model] ?? 0) + 1;
    }
    return { harnesses, providers, models };
  }, [combosFile]);

  const jsonHref = useMemo(() => `/index.json${buildSearch(filters, agent) ? `?${buildSearch(filters, agent)}` : ""}`, [filters, agent]);
  const selectedRow = useMemo(() => combosFile?.combos.find((c) => c.agent_id === agent) ?? null, [combosFile, agent]);

  return (
    <div className="flex min-h-svh flex-col">
      <SiteHeader jsonHref={jsonHref} onHome={agent ? closeAgent : undefined} />
      {!agent && registry && (
        <Hero registry={registry} combos={combosFile?.counts.combos ?? 0} fixtures={combosFile?.counts.fixtures ?? 0} />
      )}

      {agent ? (
        <AgentPage row={selectedRow} agentId={agent} onBack={closeAgent} />
      ) : (
        <main className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-5 px-4 py-6">
          {loadError && (
            <Card className="border-destructive">
              <CardHeader>
                <CardTitle className="text-destructive text-base">the registry failed to load</CardTitle>
              </CardHeader>
              <CardContent className="text-sm">{loadError}</CardContent>
            </Card>
          )}
          {!registry && !loadError && <p className="text-muted-foreground py-16 text-center text-sm">loading the registry…</p>}

          {registry && combosFile && (
            <>
              {notices.length > 0 && (
                <p className="text-muted-foreground rounded-md border px-3 py-2 text-xs">{notices.join(" · ")}</p>
              )}
              <FilterBar
                registry={registry}
                filters={filters}
                counts={counts}
                rowCount={rows.length}
                totalCount={combosFile.counts.combos}
                jsonHref={jsonHref}
                onDim={onDim}
                onEmail={onEmail}
                onClear={onClear}
              />
              <ResultsTable
                rows={rows}
                totalCount={combosFile.counts.combos}
                filters={filters}
                registry={registry}
                onSelect={onSelect}
              />
            </>
          )}
        </main>
      )}

      <footer className="text-muted-foreground border-t">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-2 px-4 py-4 text-xs">
          <span>
            data regenerated from{" "}
            <a className="underline underline-offset-4" href="https://github.com/bevry-vibes/agent-detect" target="_blank" rel="noreferrer">
              bevry-vibes/agent-detect
            </a>{" "}
            {combosFile ? `· generated ${new Date(combosFile.generated_at * 1000).toISOString().slice(0, 10)}` : ""} · RPL-1.5
          </span>
          <span className="flex gap-3">
            <a className="underline underline-offset-4" href="/registry.json">registry.json</a>
            <a className="underline underline-offset-4" href="/index.json">index.json</a>
            <a className="underline underline-offset-4" href="/llms.txt">llms.txt</a>
          </span>
        </div>
      </footer>
    </div>
  );
}
