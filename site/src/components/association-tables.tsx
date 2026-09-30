import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, Search, SquareArrowOutUpRight } from "lucide-react";

import { type CombosFile, type IndexFile, type Registry } from "@/lib/registry";
import { Badge } from "@/components/ui/badge";
import type { EntityDim } from "@/components/entity-page";

const DIM_TABLES = { harness: "harnesses", provider: "providers", model: "models" } as const;

export type Sel = { harness?: string; provider?: string; model?: string; agent?: string };

export interface AssociationTablesProps {
  /** the page's identity filter — the entity's dim id, or the combo's three
   * dims on a result page */
  page: { harness?: string; provider?: string; model?: string };
  /** the highlighted self cards: the entity itself, or the combo's three dims
   * and the agent */
  self: Sel;
  index: IndexFile | null;
  registry: Registry | null;
  combos: CombosFile | null;
  onOpenEntity: (dim: EntityDim, id: string) => void;
  onOpenAgent: (agentId: string) => void;
  /** a table's search icon: jump to the registry with this table's context */
  onSearch: (filters: { harness: string | null; provider: string | null; model: string | null }) => void;
  /** the self cards' right-side button: back to the homepage */
  onBack: () => void;
}

interface CardView {
  key: string;
  title: string;
  mono: string;
  badges: string[];
  meta: string;
  kind: "self" | "entity" | "agent";
  selected: boolean;
  onCard?: () => void;
  cardTitle: string;
  expandTitle: string;
  onExpand: () => void;
}

type AnyEntry = IndexFile["harnesses"][number] | IndexFile["providers"][number] | IndexFile["models"][number];

function entityBadges(e: AnyEntry): string[] {
  const badges: string[] = [];
  if ("license" in e && e.license) badges.push(`license: ${e.license}`);
  if ("openness" in e && e.openness) badges.push(`openness: ${e.openness}`);
  if (e.open_training) badges.push(`open: ${e.open_training}`);
  if (e.closed_training) badges.push(`closed: ${e.closed_training}`);
  if ("reciprocity_scandal" in e && e.reciprocity_scandal) badges.push("scandal");
  return badges;
}

function Table(
  { title, count, total, items, onSearch }: { title: string; count: number; total: number; items: CardView[]; onSearch: () => void },
) {
  return (
    <div className="rounded-xl border">
      <div className="text-muted-foreground flex items-center justify-between border-b px-3 py-2 text-xs font-medium">
        <span>
          {title} — {count === total ? total : `${count} of ${total}`}
        </span>
        <button
          type="button"
          title="see this in the registry"
          aria-label={`search ${title.toLowerCase()} in the registry`}
          onClick={onSearch}
          className="hover:text-foreground cursor-pointer"
        >
          <Search className="size-3.5" />
        </button>
      </div>
      <ul className="max-h-96 overflow-y-auto p-1" aria-label={title}>
        {items.length === 0 && <li className="text-muted-foreground px-2 py-3 text-center text-xs">none match</li>}
        {items.map((c) => (
          <li key={c.key}>
            <div
              className={`group flex min-w-0 items-stretch gap-0.5 rounded-md border transition-colors ${
                c.kind === "self" || c.selected
                  ? "border-amber-500/60 bg-amber-500/10"
                  : "border-transparent hover:bg-muted/50"
              }`}
            >
              <button
                type="button"
                title={c.cardTitle}
                onClick={c.onCard}
                disabled={c.kind === "self"}
                className={`flex min-w-0 flex-1 flex-col gap-0.5 px-2 py-1.5 text-left ${
                  c.kind === "self" ? "cursor-not-allowed" : "cursor-pointer"
                }`}
              >
                <span className="flex min-w-0 flex-wrap items-baseline gap-x-2">
                  <span className="text-sm font-medium">{c.title}</span>
                  <span className="text-muted-foreground font-mono text-[11px]">{c.mono}</span>
                </span>
                <span className="text-muted-foreground flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-[10px]">
                  {c.badges.map((b) => (
                    <Badge
                      key={b}
                      variant="outline"
                      className={`cursor-help px-1 py-0 text-[10px] ${c.kind === "self" || c.selected ? "border-amber-500/40 text-amber-600 dark:text-amber-300" : ""}`}
                    >
                      {b}
                    </Badge>
                  ))}
                  {c.meta && <span>{c.meta}</span>}
                </span>
              </button>
              <button
                type="button"
                title={c.expandTitle}
                aria-label={c.expandTitle}
                onClick={c.onExpand}
                className={`hover:text-foreground flex w-8 shrink-0 cursor-pointer items-center justify-center transition-colors ${
                  c.kind === "entity" || c.kind === "agent" ? "opacity-0 group-hover:opacity-100 focus-visible:opacity-100" : ""
                }`}
              >
                {c.kind === "self" ? <ArrowLeft className="size-3.5" /> : <SquareArrowOutUpRight className="size-3.5" />}
              </button>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

function titleOf(d: EntityDim): string {
  return d === "harness" ? "Harnesses" : d === "provider" ? "Providers" : "Models";
}

/** the four association tables — harnesses, providers, models, and the agents
 * underneath — shared by the entity detail pages and the result page. The
 * page's identity is the filter (the entity's dim, or the combo's three dims
 * + the agent): every table shows what is available under it, the self cards
 * are gold with a not-allowed cursor and a back arrow (the page can't
 * re-filter itself), and the other cards narrow the tables beside them when
 * clicked. Each header's search icon opens the registry with the table's
 * context. */
export function AssociationTables({ page, self, index, registry, combos, onOpenEntity, onOpenAgent, onSearch, onBack }: AssociationTablesProps) {
  const [sel, setSel] = useState<Sel>({});
  useEffect(() => setSel({}), [page.harness, page.provider, page.model, self.agent]);

  const tables = useMemo(() => {
    if (!index) return [];
    // the effective filter: the page's identity, overridden by the local
    // selections as they are clicked
    const f = {
      harness: sel.harness ?? page.harness ?? null,
      provider: sel.provider ?? page.provider ?? null,
      model: sel.model ?? page.model ?? null,
    };
    const find = (d: EntityDim, eid: string) => index[DIM_TABLES[d]].find((e) => e.id === eid) ?? null;

    // the qualifying triples under the filter — the availability universe the
    // CLI's `index` command narrows to
    const triples: { harness: string; provider: string; model: string }[] = [];
    for (const pv of index.providers) {
      if (f.provider && pv.id !== f.provider) continue;
      const hs = pv.harnesses.filter((h) => !f.harness || h === f.harness);
      if (hs.length === 0) continue;
      for (const m of pv.models) {
        if (f.model && m !== f.model) continue;
        for (const h of hs) triples.push({ harness: h, provider: pv.id, model: m });
      }
    }
    const has = (d: EntityDim, eid: string) => {
      const key = d === "harness" ? "harness" : d === "provider" ? "provider" : "model";
      return triples.some((t) => t[key as "harness" | "provider" | "model"] === eid);
    };
    const isSelf = (d: EntityDim, eid: string) => self[d] === eid;

    const entityCard = (d: EntityDim, eid: string): CardView => {
      const e = find(d, eid);
      const elabel = registry ? registry[DIM_TABLES[d]].find((r) => r.id === eid)?.label ?? eid : eid;
      const selfCard = isSelf(d, eid);
      const selected = sel[d] === eid && !selfCard;
      return {
        key: `${d}-${eid}`,
        title: elabel,
        mono: eid,
        badges: e ? entityBadges(e) : [],
        meta: "",
        kind: selfCard ? "self" : "entity",
        selected,
        onCard: selfCard
          ? undefined
          : () => setSel((s) => ({ ...s, agent: undefined, [d]: s[d] === eid ? undefined : eid })),
        cardTitle: selfCard
          ? `this page's ${d} — the table is filtered to it`
          : selected
          ? `clear the ${d} selection`
          : `narrow the other tables to ${d} ${eid}`,
        expandTitle: selfCard ? "back to the homepage" : `open the ${d} detail page (${d}/${eid})`,
        onExpand: selfCard ? onBack : () => onOpenEntity(d, eid),
      };
    };

    const agentCards: CardView[] = (combos?.combos ?? [])
      .filter((c) => has("harness", c.harness) && has("provider", c.provider) && has("model", c.model))
      .map((c) => {
        const selfCard = self.agent != null && self.agent === c.agent_id;
        return {
          key: c.agent_id,
          title: c.agent_id,
          mono: c.agent_id,
          badges: c.reciprocal ? ["reciprocal"] : ["not reciprocal"],
          meta: c.platforms.join(" "),
          kind: (selfCard ? "self" : "agent") as "self" | "agent",
          selected: sel.agent === c.agent_id && !selfCard,
          onCard: selfCard
            ? undefined
            : () =>
                setSel((s) =>
                  s.agent === c.agent_id ? {} : { harness: c.harness, provider: c.provider, model: c.model, agent: c.agent_id },
                ),
          cardTitle: selfCard
            ? "this page's agent — the table is filtered to it"
            : sel.agent === c.agent_id
            ? "clear the agent selection"
            : "narrow the other tables to this agent's dims",
          expandTitle: selfCard ? "back to the homepage" : `open the result page (/agent/${c.agent_id})`,
          onExpand: selfCard ? onBack : () => onOpenAgent(c.agent_id),
        };
      });

    const mk = (d: EntityDim): { title: string; count: number; total: number; items: CardView[] } => {
      const total = index[DIM_TABLES[d]].length;
      const items = index[DIM_TABLES[d]]
        .filter((e) => has(d, e.id) || isSelf(d, e.id))
        .map((e) => entityCard(d, e.id));
      return { title: titleOf(d), count: items.length, total, items };
    };
    return [
      mk("harness"),
      mk("provider"),
      mk("model"),
      { title: "Agents", count: agentCards.length, total: combos?.counts.combos ?? 0, items: agentCards },
    ];
  }, [index, page.harness, page.provider, page.model, self.harness, self.provider, self.model, self.agent, sel, combos, registry, onBack, onOpenAgent, onOpenEntity]);

  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-muted-foreground text-xs font-medium uppercase tracking-wide">
        associations — click a card to narrow the tables beside it; a card's expand button opens its page
      </h2>
      <div className="grid gap-4 md:grid-cols-3">
        {tables
          .filter((t) => t.title !== "Agents")
          .map((t) => (
            <Table
              key={t.title}
              title={t.title}
              count={t.count}
              total={t.total}
              items={t.items}
              onSearch={() =>
                onSearch({
                  harness: sel.harness ?? page.harness ?? null,
                  provider: sel.provider ?? page.provider ?? null,
                  model: sel.model ?? page.model ?? null,
                })
              }
            />
          ))}
      </div>
      <div className="grid gap-4">
        {tables
          .filter((t) => t.title === "Agents")
          .map((t) => (
            <Table
              key={t.title}
              title={t.title}
              count={t.count}
              total={t.total}
              items={t.items}
              onSearch={() =>
                onSearch({
                  harness: sel.harness ?? page.harness ?? null,
                  provider: sel.provider ?? page.provider ?? null,
                  model: sel.model ?? page.model ?? null,
                })
              }
            />
          ))}
      </div>
    </section>
  );
}
