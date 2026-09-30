import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Github } from "lucide-react";

import { comboSearchText, resolveDimId, resolvePlatform, type CombosFile, type IndexFile, type Registry } from "@/lib/registry";
import { AgentPage } from "@/components/agent-page";
import { FilterBar, NO_FILTERS, type Filters } from "@/components/filter-bar";
import { Hero, RegistryIntro } from "@/components/hero";
import { IndexSection } from "@/components/index-section";
import { ResultsTable } from "@/components/results-table";
import { SiteHeader } from "@/components/site-header";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

const DIMS = ["harness", "provider", "model"] as const;
type Dim = (typeof DIMS)[number];

/** a `?free=`/`?reciprocal=` value → its boolean, or null */
function triBool(raw: string | null): boolean | null {
  const v = raw?.trim().toLowerCase();
  if (v == null || v === "") return null;
  if (v === "true" || v === "1" || v === "yes") return true;
  if (v === "false" || v === "0" || v === "no") return false;
  return null;
}

/**
 * URL params work exactly like the CLI flags: display names and aliases are
 * accepted, the URL is canonicalised to the strict-slug alphanumeric ids
 * (`?harness=Kimi+Code` lands as `?harness=kimicode`). Unresolvable values are
 * dropped with a notice, like an unknown flag. `?search=` free-text matches
 * combo ids and harness/provider/model names and ids; `?email=` matches the
 * trailer email of record; `?platform=` (darwin/linux/windows) requires a
 * declared fixture on that platform; `?free=`/`?reciprocal=` take booleans.
 * `?agent=` is the result page — the platform param never reaches it.
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
  const text = q.get("search")?.trim().toLowerCase();
  if (text) {
    filters.search = text;
    canonical.set("search", text);
  }
  const email = q.get("email")?.trim().toLowerCase();
  if (email) {
    filters.email = email;
    canonical.set("email", email);
  }
  const free = triBool(q.get("free"));
  if (free != null) {
    filters.free = free;
    canonical.set("free", String(free));
  }
  const reciprocal = triBool(q.get("reciprocal"));
  if (reciprocal != null) {
    filters.reciprocal = reciprocal;
    canonical.set("reciprocal", String(reciprocal));
  }
  const agent = q.get("agent")?.trim().toLowerCase() || null;
  if (agent) {
    canonical.set("agent", agent);
    if (agent !== q.get("agent")) notices.push(`agent canonicalised to "${agent}"`);
  }
  const platformRaw = q.get("platform");
  const platform = resolvePlatform(platformRaw);
  if (platformRaw != null) {
    if (platform) canonical.set("platform", platform);
    else notices.push(`platform "${platformRaw}" is not one of darwin, linux, windows — dropped`);
  }
  return { filters, agent, platform, canonical: canonical.toString(), notices };
}

function buildSearch(filters: Filters, agent: string | null): string {
  const q = new URLSearchParams();
  for (const dim of DIMS) if (filters[dim]) q.set(dim, filters[dim]);
  if (filters.search) q.set("search", filters.search);
  if (filters.email) q.set("email", filters.email);
  if (filters.platform) q.set("platform", filters.platform);
  if (filters.free != null) q.set("free", String(filters.free));
  if (filters.reciprocal != null) q.set("reciprocal", String(filters.reciprocal));
  if (agent) q.set("agent", agent);
  return q.toString();
}

export default function App() {
  const [registry, setRegistry] = useState<Registry | null>(null);
  const [combosFile, setCombosFile] = useState<CombosFile | null>(null);
  const [indexFile, setIndexFile] = useState<IndexFile | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [filters, setFilters] = useState<Filters>({ ...NO_FILTERS });
  const [agent, setAgent] = useState<string | null>(null);
  const [notices, setNotices] = useState<string[]>([]);
  const registryRef = useRef<Registry | null>(null);
  // full-page agent view: the index's scroll position is remembered per entry
  // so "back to results" lands where the click happened
  const scrollMem = useRef(new Map<string, number>());
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
      fetch("/data/index.json").then((r) => {
        if (!r.ok) throw new Error(`index: HTTP ${r.status}`);
        return r.json() as Promise<IndexFile>;
      }),
    ]).then(([reg, cf, ix]) => {
      registryRef.current = reg;
      setRegistry(reg);
      setCombosFile(cf);
      setIndexFile(ix);
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
  const onSearch = (text: string | null) => {
    const next = { ...filters, search: text };
    setFilters(next);
    setAgent(null);
    setNotices([]);
    pushURL(next, null);
  };
  const onTriFilter = (key: "free" | "reciprocal", value: boolean | null) => {
    const next = { ...filters, [key]: value };
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
    setAgent(selected);
    pushURL(filters, selected);
  };

  /** "close" the agent results — always lands on the index entry for the
   * current filters (never a browser back), with the remembered scroll
   * position restored */
  const closeAgent = () => {
    setAgent(null);
    setNotices([]);
    pushURL(filters, null);
  };

  // view transitions: returning to the index restores its remembered scroll;
  // the agent page scrolls itself to the top on mount. Both scrolls are
  // explicit-instant — the html's smooth scroll-behavior turns programmatic
  // scrolls into animations that other scrolls (and re-renders) cancel.
  useEffect(() => {
    const next = agent ? "agent" : "index";
    if (next === viewRef.current) return;
    viewRef.current = next;
    if (next === "index") window.scrollTo({ top: scrollMem.current.get(window.location.search) ?? 0, behavior: "instant" });
  }, [agent]);

  // a center-nav click on the agent page closes it and jumps to the section
  const pendingAnchor = useRef<string | null>(null);
  const onNavClick = (href: string): boolean => {
    if (!agent) return false;
    // carry the anchor into the index url so the closeAgent push keeps it
    history.replaceState(null, "", `${window.location.pathname}${window.location.search}#${href.slice(1)}`);
    pendingAnchor.current = href.slice(1);
    closeAgent();
    return true;
  };
  useEffect(() => {
    if (agent) return;
    const id = pendingAnchor.current;
    if (!id) return;
    pendingAnchor.current = null;
    const el = document.getElementById(id);
    if (el) {
      el.scrollIntoView({ behavior: "instant" });
      el.classList.add("anchor-flash");
      setTimeout(() => el.classList.remove("anchor-flash"), 1800);
    }
  }, [agent]);

  const searchIndex = useMemo(() => {
    const m = new Map<string, string>();
    if (registry && combosFile) for (const c of combosFile.combos) m.set(c.agent_id, comboSearchText(c, registry));
    return m;
  }, [registry, combosFile]);

  const rows = useMemo(() => {
    if (!combosFile) return [];
    return combosFile.combos.filter(
      (c) =>
        (!filters.harness || c.harness === filters.harness) &&
        (!filters.provider || c.provider === filters.provider) &&
        (!filters.model || c.model === filters.model) &&
        (!filters.search || (searchIndex.get(c.agent_id) ?? "").includes(filters.search)) &&
        (!filters.email || c.email.toLowerCase() === filters.email) &&
        (!filters.platform || c.platforms.includes(filters.platform as never)) &&
        (filters.free == null || c.free === filters.free) &&
        (filters.reciprocal == null || c.reciprocal === filters.reciprocal),
    );
  }, [combosFile, filters, searchIndex]);

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
  // a dim click on the result page or the index section lands at the registry
  // section so the filtered results are actually in view
  const selectedRow = useMemo(() => combosFile?.combos.find((c) => c.agent_id === agent) ?? null, [combosFile, agent]);

  const onJumpToRegistry = (dim: Dim, id: string) => {
    pendingAnchor.current = "registry";
    onDim(dim, id);
  };

  return (
    <div className="flex min-h-svh flex-col">
      <SiteHeader
        onHome={agent ? closeAgent : undefined}
        onNavClick={onNavClick}
        centerNav={[
          { label: "cli", href: "#cli" },
          { label: "registry", href: "#registry" },
          { label: "index", href: "#index" },
        ]}
      />
      {agent ? (
        <AgentPage
          row={selectedRow}
          agentId={agent}
          registry={registry}
          onDim={onJumpToRegistry}
          onBack={closeAgent}
        />
      ) : (
        <main className="flex flex-col">
          <Hero />
          <article id="registry" className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-5 scroll-mt-14 px-4 py-8">
            {registry && (
              <RegistryIntro
                registry={registry}
                combos={combosFile?.counts.combos ?? 0}
                fixtures={combosFile?.counts.fixtures ?? 0}
                jsonHref={jsonHref}
              />
            )}
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
                  onDim={onDim}
                  onSearch={onSearch}
                  onTriFilter={onTriFilter}
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
          </article>
          <IndexSection index={indexFile} filters={filters} onSelect={onJumpToRegistry} />
        </main>
      )}

      <footer className="text-muted-foreground border-t">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-2 px-4 py-4 text-xs">
          <span className="flex flex-wrap items-center gap-1.5">
            <Github className="size-3.5" />
            <a className="underline underline-offset-4" href="https://github.com/bevry-vibes/agent-detect" target="_blank" rel="noreferrer">
              bevry-vibes/agent-detect
            </a>
            {combosFile ? `· ${new Date(combosFile.generated_at * 1000).toISOString().slice(0, 10)} ·` : "·"} RPL-1.5
          </span>
          <span className="flex gap-3">
            <a className="underline underline-offset-4" href="/registry.json">registry.json</a>
            <a className="underline underline-offset-4" href="/index.json">index.json</a>
            <a className="underline underline-offset-4" href="/llms.txt">llms.txt</a>
            <a
              className="underline underline-offset-4"
              href="https://github.com/bevry-vibes/agent-detect/blob/main/CONTRIBUTING.md"
              target="_blank"
              rel="noreferrer"
            >
              contributing.md
            </a>
          </span>
        </div>
      </footer>
    </div>
  );
}
