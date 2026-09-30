import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Github } from "lucide-react";

import {
  comboSearchText,
  resolveDimId,
  resolvePlatform,
  type CombosFile,
  type IndexFile,
  type Registry,
} from "@/lib/registry";
import { AgentPage } from "@/components/agent-page";
import { EntityPage, type EntityDim } from "@/components/entity-page";
import { FilterBar, NO_FILTERS, type Filters } from "@/components/filter-bar";
import { Hero, RegistryIntro } from "@/components/hero";
import { IndexSection } from "@/components/index-section";
import { ResultsTable } from "@/components/results-table";
import { SiteHeader } from "@/components/site-header";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

const DIMS = ["harness", "provider", "model"] as const;
type Dim = (typeof DIMS)[number];

/** the three views — the index (the default), a combo's result page
 * (/agent/<id>), and an entity's detail page (/<dim>/<id>). The ids ride in
 * the path; the index filters ride in the query. */
type View = { kind: "index" } | { kind: "agent"; id: string } | { kind: "entity"; dim: EntityDim; id: string };

/** a `?free=`/`?reciprocal=` value → its boolean, or null */
function triBool(raw: string | null): boolean | null {
  const v = raw?.trim().toLowerCase();
  if (v == null || v === "") return null;
  if (v === "true" || v === "1" || v === "yes") return true;
  if (v === "false" || v === "0" || v === "no") return false;
  return null;
}

/** the canonical path for a view (the index is the bare path) */
function viewPath(view: View): string {
  if (view.kind === "agent") return `/agent/${view.id}`;
  if (view.kind === "entity") return `/${view.dim}/${view.id}`;
  return "/";
}

/**
 * URL params work exactly like the CLI flags: display names and aliases are
 * accepted, the URL is canonicalised to the strict-slug alphanumeric ids
 * (`?harness=Kimi+Code` lands as `?harness=kimicode`). Unresolvable values are
 * dropped with a notice, like an unknown flag. `?search=` free-text matches
 * combo ids and harness/provider/model names and ids; `?email=` matches the
 * trailer email of record; `?platform=` (darwin/linux/windows) requires a
 * declared fixture on that platform; `?free=`/`?reciprocal=` take booleans.
 *
 * Paths: `/agent/<id>` is a combo's result page (the legacy `?agent=` param
 * canonicalises to it); `/model/<input>`, `/provider/<input>`, and
 * `/harness/<input>` are entity detail pages — any input that resolves to a
 * rule (name, label, alias) canonicalises to the strict-slug id.
 */
function parseView(pathname: string): View {
  const parts = pathname.split("/").filter((s) => s.length > 0);
  if (parts[0] === "agent" && parts[1]) {
    const id = parts.slice(1).join("-").trim().toLowerCase();
    if (id) return { kind: "agent", id };
  }
  if (["harness", "provider", "model"].includes(parts[0]) && parts[1]) {
    return { kind: "entity", dim: parts[0] as EntityDim, id: decodeURIComponent(parts[1]).trim().toLowerCase() };
  }
  return { kind: "index" };
}

function parseFilters(search: string, registry: Registry): { filters: Filters; notices: string[] } {
  const q = new URLSearchParams(search);
  const filters: Filters = { ...NO_FILTERS };
  const notices: string[] = [];
  const canonical = new URLSearchParams();
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
  const platformRaw = q.get("platform");
  const platform = resolvePlatform(platformRaw);
  if (platformRaw != null) {
    if (platform) {
      filters.platform = platform;
      canonical.set("platform", platform);
    } else notices.push(`platform "${platformRaw}" is not one of darwin, linux, windows — dropped`);
  }
  return { filters, notices };
}

function buildSearch(filters: Filters): string {
  const q = new URLSearchParams();
  for (const dim of DIMS) if (filters[dim]) q.set(dim, filters[dim]);
  if (filters.search) q.set("search", filters.search);
  if (filters.email) q.set("email", filters.email);
  if (filters.platform) q.set("platform", filters.platform);
  if (filters.free != null) q.set("free", String(filters.free));
  if (filters.reciprocal != null) q.set("reciprocal", String(filters.reciprocal));
  return q.toString();
}

export default function App() {
  const [registry, setRegistry] = useState<Registry | null>(null);
  const [combosFile, setCombosFile] = useState<CombosFile | null>(null);
  const [indexFile, setIndexFile] = useState<IndexFile | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [filters, setFilters] = useState<Filters>({ ...NO_FILTERS });
  const [view, setView] = useState<View>({ kind: "index" });
  const [notices, setNotices] = useState<string[]>([]);
  const registryRef = useRef<Registry | null>(null);
  // the index's scroll position is remembered per url so "back to results"
  // lands where the click happened
  const scrollMem = useRef(new Map<string, number>());
  const viewRef = useRef<string>("/");
  // a center-nav click on a detail page closes it and jumps to the section
  const pendingAnchor = useRef<string | null>(null);

  useEffect(() => {
    if ("scrollRestoration" in history) history.scrollRestoration = "manual";
  }, []);

  const applyParsed = useCallback((parsed: { filters: Filters; view: View; canonical: string; notices: string[] }) => {
    setFilters(parsed.filters);
    setView(parsed.view);
    setNotices(parsed.notices);
    const target = `${viewPath(parsed.view)}${parsed.canonical ? `?${parsed.canonical}` : ""}`;
    if (`${window.location.pathname}${window.location.search}` !== target) {
      history.replaceState(null, "", target + window.location.hash);
    }
  }, []);

  const reparse = useCallback(() => {
    const reg = registryRef.current;
    if (!reg) return;
    const view = parseView(window.location.pathname);
    // the legacy ?agent= param canonicalises to the /agent/<id> path
    const agentParam = new URLSearchParams(window.location.search).get("agent")?.trim().toLowerCase() || null;
    const effective: View = view.kind === "index" && agentParam ? { kind: "agent", id: agentParam } : view;
    const { filters: f, notices } = parseFilters(window.location.search, reg);
    applyParsed({ filters: f, view: effective, canonical: buildSearch(f), notices });
  }, [applyParsed]);

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
      const view = parseView(window.location.pathname);
      const agentParam = new URLSearchParams(window.location.search).get("agent")?.trim().toLowerCase() || null;
      const effective: View = view.kind === "index" && agentParam ? { kind: "agent", id: agentParam } : view;
      const { filters: f, notices } = parseFilters(window.location.search, reg);
      applyParsed({ filters: f, view: effective, canonical: buildSearch(f), notices });
    }).catch((err) => setLoadError(String(err)));
  }, [applyParsed]);

  useEffect(() => {
    window.addEventListener("popstate", reparse);
    return () => window.removeEventListener("popstate", reparse);
  }, [reparse]);

  // an entity input that resolves to a rule (name, label, alias) canonicalises
  // to the strict-slug id's path; an unresolved input lands on the unknown page
  useEffect(() => {
    if (!registry || view.kind !== "entity") return;
    const tables = { harness: registry.harnesses, provider: registry.providers, model: registry.models } as const;
    const canon = resolveDimId(tables[view.dim], view.id);
    if (canon && canon !== view.id) {
      const fixed: View = { kind: "entity", dim: view.dim, id: canon };
      setView(fixed);
      history.replaceState(null, "", viewPath(fixed) + window.location.hash);
    }
  }, [registry, view]);

  const pushURL = (nextFilters: Filters, nextView: View) => {
    const qs = buildSearch(nextFilters);
    history.pushState(null, "", `${viewPath(nextView)}${qs ? `?${qs}` : ""}${window.location.hash}`);
  };

  const onDim = (dim: Dim, id: string | null) => {
    const next = { ...filters, [dim]: id };
    setFilters(next);
    setView({ kind: "index" });
    setNotices([]);
    pushURL(next, { kind: "index" });
  };
  const onFilters = (next: Filters) => {
    setFilters(next);
    setView({ kind: "index" });
    setNotices([]);
    pushURL(next, { kind: "index" });
  };
  const onClear = () => {
    setFilters({ ...NO_FILTERS });
    setView({ kind: "index" });
    setNotices([]);
    pushURL({ ...NO_FILTERS }, { kind: "index" });
  };
  const onSelect = (selected: string) => {
    if (view.kind === "agent" && view.id === selected) return;
    // remember where the index was, under the key the view-transition effect
    // reads when returning from this detail page
    scrollMem.current.set(viewPath({ kind: "agent", id: selected }), window.scrollY);
    setView({ kind: "agent", id: selected });
    pushURL(filters, { kind: "agent", id: selected });
  };

  /** an index entry click only toggles its filter — no scroll, no anchor;
   * the gold cue and the pill box show the applied filter in place */
  const onIndexSelect = (dim: Dim, id: string) => {
    onDim(dim, filters[dim] === id ? null : id);
  };

  const onOpenEntity = (dim: EntityDim, id: string) => {
    scrollMem.current.set(viewPath({ kind: "entity", dim, id }), window.scrollY);
    setView({ kind: "entity", dim, id });
    pushURL({ ...NO_FILTERS }, { kind: "entity", dim, id });
  };

  /** "back to results" — always lands on the index for the current filters
   * (never a browser back), with the remembered scroll restored */
  const closeToIndex = () => {
    setView({ kind: "index" });
    setNotices([]);
    pushURL(filters, { kind: "index" });
  };

  // view transitions: returning to the index restores its remembered scroll;
  // detail pages scroll themselves to the top on mount. Both scrolls are
  // explicit-instant — the html's smooth scroll-behavior turns programmatic
  // scrolls into animations that other scrolls (and re-renders) cancel.
  const viewKey = viewPath(view);
  useEffect(() => {
    if (viewKey === viewRef.current) return;
    const from = viewRef.current;
    viewRef.current = viewKey;
    if (viewKey === "/") window.scrollTo({ top: scrollMem.current.get(from) ?? 0, behavior: "instant" });
  }, [viewKey]);

  const onNavClick = (href: string): boolean => {
    if (view.kind === "index") return false;
    // carry the anchor into the index url so the closeToIndex push keeps it
    const qs = buildSearch(filters);
    history.replaceState(null, "", `${viewPath({ kind: "index" })}${qs ? `?${qs}` : ""}#${href.slice(1)}`);
    pendingAnchor.current = href.slice(1);
    closeToIndex();
    return true;
  };
  useEffect(() => {
    if (view.kind !== "index") return;
    const id = pendingAnchor.current;
    if (!id) return;
    pendingAnchor.current = null;
    const el = document.getElementById(id);
    if (el) {
      el.scrollIntoView({ behavior: "instant" });
      el.classList.add("anchor-flash");
      setTimeout(() => el.classList.remove("anchor-flash"), 1800);
    }
  }, [view.kind, filters]);

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

  const jsonHref = useMemo(() => `/index.json${buildSearch(filters) ? `?${buildSearch(filters)}` : ""}`, [filters]);
  const selectedRow = useMemo(
    () => (view.kind === "agent" ? combosFile?.combos.find((c) => c.agent_id === view.id) ?? null : null),
    [combosFile, view],
  );

  // a dim click on a detail page should land the user at the registry
  // section so the filtered results are actually in view
  const onJumpToRegistry = (dim: Dim, id: string) => {
    pendingAnchor.current = "registry";
    onDim(dim, id);
  };

  /** the result page's filter-agents pill: persist the carried filters, apply
   * the combo's three dims on top, and land on the index anchor where the
   * applied filters are visible */
  const onFilterAgents = (h: string, p: string, m: string) => {
    history.replaceState(null, "", `${window.location.pathname}${window.location.search}#index`);
    pendingAnchor.current = "index";
    const next = { ...filters, harness: h, provider: p, model: m };
    setFilters(next);
    setView({ kind: "index" });
    setNotices([]);
    pushURL(next, { kind: "index" });
  };

  return (
    <div className="flex min-h-svh flex-col">
      <SiteHeader
        onHome={view.kind !== "index" ? closeToIndex : undefined}
        onNavClick={onNavClick}
        centerNav={[
          { label: "cli", href: "#cli" },
          { label: "index", href: "#index" },
          { label: "registry", href: "#registry" },
        ]}
      />
      {view.kind === "agent" ? (
        <AgentPage
          row={selectedRow}
          agentId={view.id}
          registry={registry}
          onOpenEntity={onOpenEntity}
          onFilterAgents={onFilterAgents}
          onBack={closeToIndex}
        />
      ) : view.kind === "entity" ? (
        <EntityPage
          dim={view.dim}
          id={view.id}
          index={indexFile}
          registry={registry}
          combos={combosFile}
          onDim={onJumpToRegistry}
          onCombos={() => {
            pendingAnchor.current = "registry";
            onDim(view.dim, view.id);
          }}
          onOpenEntity={onOpenEntity}
          onOpenAgent={onSelect}
          onBack={closeToIndex}
        />
      ) : (
        <main className="flex flex-col">
          <Hero />
          <IndexSection index={indexFile} filters={filters} onSelect={onIndexSelect} onOpenEntity={onOpenEntity} />
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
                <FilterBar registry={registry} filters={filters} onDim={onDim} onFilters={onFilters} onClear={onClear} />
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
            <a className="underline underline-offset-4" href="/data/index.json">index.json</a>
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
