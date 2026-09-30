import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, SquareArrowOutUpRight } from "lucide-react";

import { type CombosFile, type IndexFile, type Registry } from "@/lib/registry";
import { JsonBlock } from "@/components/json-block";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

export type EntityDim = "harness" | "provider" | "model";

const DIM_TABLES = { harness: "harnesses", provider: "providers", model: "models" } as const;

type Sel = { harness?: string; provider?: string; model?: string; agent?: string };

interface EntityPageProps {
  dim: EntityDim;
  id: string;
  index: IndexFile | null;
  registry: Registry | null;
  combos: CombosFile | null;
  /** an association chip filters the registry section with it */
  onDim: (dim: "harness" | "provider" | "model", id: string) => void;
  /** view the entity's combos in the registry (the dim filter jump) */
  onCombos: () => void;
  /** the expand buttons: entities open their detail page, agents open their result page */
  onOpenEntity: (dim: EntityDim, id: string) => void;
  onOpenAgent: (agentId: string) => void;
  onBack: () => void;
}

interface CardView {
  key: string;
  title: string;
  mono: string;
  badges: string[];
  meta: string;
  selected: boolean;
  onCard: () => void;
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

/** per-value explanations for the policy fields — cursor-help + dotted
 * underline on each value, the same vocabulary the rule tables use */
function policyExplain(field: string, value: string | null | boolean): string {
  if (value == null) return `${field}: not researched — no verified data`;
  if (field === "license") {
    if (value === "NONE") return "license: verified none granted (closed source)";
    if (value === "NOASSERTION") return "license: exists but custom/non-SPDX, or researched without conclusion";
    return `license: ${value} — the SPDX license id (informational; the licence does not gate reciprocity)`;
  }
  if (field === "openness") {
    if (value === "closed") return "openness: closed — API-only, no weights published";
    return `openness: ${value} — the weights are published under this tier`;
  }
  if (field === "open_training") {
    if (value === "NOASSERTION") return "open-model training: researched, inconclusive";
    return `open-model training: ${value} — whether the entity uses your data to train open-weight models (informational; never gates reciprocity)`;
  }
  if (field === "closed_training") {
    if (value === "NOASSERTION") return "closed-model training: researched, inconclusive";
    return `closed-model training: ${value} — whether the entity uses your data to train closed (API) models: enforced = no opt-out, opt-out = trains by default, opt-in = off by default, never = verified never; this axis gates reciprocity`;
  }
  if (field === "reciprocity_scandal") {
    return value
      ? "reciprocity scandal: implicated by a court, regulator, official report, or wire-capture finding (the fair-use purpose test)"
      : "reciprocity scandal: false — no scandal on record (explicit, not inferred from absence)";
  }
  return `${field}: ${value}`;
}

function Table({ title, items }: { title: string; items: CardView[] }) {
  return (
    <div className="rounded-xl border">
      <div className="text-muted-foreground border-b px-3 py-2 text-xs font-medium">
        {title} — {items.length}
      </div>
      <ul className="max-h-96 overflow-y-auto p-1" aria-label={title}>
        {items.length === 0 && <li className="text-muted-foreground px-2 py-3 text-center text-xs">none match</li>}
        {items.map((c) => (
          <li key={c.key}>
            <div
              className={`group flex min-w-0 items-stretch gap-0.5 rounded-md border transition-colors ${
                c.selected ? "border-amber-500/60 bg-amber-500/10" : "border-transparent hover:bg-muted/50"
              }`}
            >
              <button type="button" title={c.cardTitle} onClick={c.onCard} className="flex min-w-0 flex-1 flex-col gap-0.5 px-2 py-1.5 text-left">
                <span className="flex min-w-0 flex-wrap items-baseline gap-x-2">
                  <span className="text-sm font-medium">{c.title}</span>
                  <span className="text-muted-foreground font-mono text-[11px]">{c.mono}</span>
                </span>
                <span className="text-muted-foreground flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-[10px]">
                  {c.badges.map((b) => (
                    <Badge key={b} variant="outline" className={`px-1 py-0 text-[10px] ${c.selected ? "border-amber-500/40 text-amber-600 dark:text-amber-300" : ""}`}>
                      {b}
                    </Badge>
                  ))}
                  <span>{c.meta}</span>
                </span>
              </button>
              <button
                type="button"
                title={c.expandTitle}
                aria-label={c.expandTitle}
                onClick={c.onExpand}
                className="hover:text-foreground flex w-8 shrink-0 cursor-pointer items-center justify-center opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100"
              >
                <SquareArrowOutUpRight className="size-3.5" />
              </button>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** the full-page entity detail (the result page's sibling) — the entry's
 * identity and policy fields, then THREE side-by-side card tables (the same
 * design as the index) of everything it associates with: for a harness that
 * is providers, models, and agents; for a provider, harnesses, models, and
 * agents; for a model, harnesses, providers, and agents. Clicking a card
 * narrows the tables beside it (the gold card is the local selection, click
 * again to clear); a card's expand button opens its detail or result page.
 * The JSON block is the entry verbatim — the same object /model/<id>.json
 * serves. */
export function EntityPage({ dim, id, index, registry, combos, onDim, onCombos, onOpenEntity, onOpenAgent, onBack }: EntityPageProps) {
  const [sel, setSel] = useState<Sel>({});
  useEffect(() => setSel({}), [dim, id]);

  const entry = useMemo(() => {
    if (!index) return null;
    return index[DIM_TABLES[dim]].find((e) => e.id === id) ?? null;
  }, [index, dim, id]);

  const label = registry ? registry[DIM_TABLES[dim]].find((r) => r.id === id)?.label ?? id : id;
  const title = dim === "model" ? "Model" : dim === "provider" ? "Provider" : "Harness";

  const findEntry = (d: EntityDim, eid: string) => (index ? index[DIM_TABLES[d]].find((e) => e.id === eid) ?? null : null);

  const tables = useMemo(() => {
    if (!entry || !index) return [];
    const entityCard = (d: EntityDim, eid: string, selected: boolean): CardView => {
      const e = findEntry(d, eid);
      const elabel = registry ? registry[DIM_TABLES[d]].find((r) => r.id === eid)?.label ?? eid : eid;
      return {
        key: `${d}-${eid}`,
        title: elabel,
        mono: eid,
        badges: e ? entityBadges(e as AnyEntry) : [],
        meta: "",
        selected,
        onCard: () => setSel((s) => ({ ...s, agent: undefined, [d]: s[d] === eid ? undefined : eid })),
        cardTitle: selected ? `clear the ${d} selection` : `narrow the other tables to ${d} ${eid}`,
        expandTitle: `open the ${d} detail page (${d}/${eid})`,
        onExpand: () => onOpenEntity(d, eid),
      };
    };
    // the combo rows involving this entity, narrowed by the local selections —
    // the agents table shows exactly these, and the entity tables narrow by
    // their own selections through the index's association arrays
    const rows = (combos?.combos ?? []).filter((c) => c[dim] === id);
    const narrowed = rows.filter(
      (c) => (!sel.harness || c.harness === sel.harness) && (!sel.provider || c.provider === sel.provider) && (!sel.model || c.model === sel.model),
    );
    const agents: CardView[] = narrowed.map((c) => ({
      key: c.agent_id,
      title: c.agent_id,
      mono: c.agent_id,
      badges: c.reciprocal ? ["reciprocal"] : ["not reciprocal"],
      meta: c.platforms.join(" "),
      selected: sel.agent === c.agent_id,
      onCard: () =>
        setSel((s) =>
          s.agent === c.agent_id ? {} : { harness: c.harness, provider: c.provider, model: c.model, agent: c.agent_id },
        ),
      cardTitle: sel.agent === c.agent_id ? "clear the agent selection" : "narrow the other tables to this agent's dims",
      expandTitle: `open the result page (/agent/${c.agent_id})`,
      onExpand: () => onOpenAgent(c.agent_id),
    }));

    const hEntry = (hid: string) => findEntry("harness", hid) as IndexFile["harnesses"][number] | null;

    if (dim === "harness") {
      const e = entry as IndexFile["harnesses"][number];
      return [
        {
          title: "Providers",
          items: e.providers
            .filter((pid) => !sel.model || !!(findEntry("provider", pid) as IndexFile["providers"][number] | null)?.models.includes(sel.model))
            .map((pid) => entityCard("provider", pid, sel.provider === pid)),
        },
        {
          title: "Models",
          items: e.models
            .filter((mid) => !sel.provider || !!(findEntry("provider", sel.provider) as IndexFile["providers"][number] | null)?.models.includes(mid))
            .map((mid) => entityCard("model", mid, sel.model === mid)),
        },
        { title: "Agents", items: agents },
      ];
    }
    if (dim === "provider") {
      const e = entry as IndexFile["providers"][number];
      return [
        {
          title: "Harnesses",
          items: e.harnesses
            .filter((hid) => !sel.model || !!(hEntry(hid))?.models.includes(sel.model))
            .map((hid) => entityCard("harness", hid, sel.harness === hid)),
        },
        {
          title: "Models",
          items: e.models
            .filter((mid) => !sel.harness || !!(hEntry(sel.harness))?.models.includes(mid))
            .map((mid) => entityCard("model", mid, sel.model === mid)),
        },
        { title: "Agents", items: agents },
      ];
    }
    const e = entry as IndexFile["models"][number];
    return [
      {
        title: "Harnesses",
        items: e.harnesses
          .filter((hid) => !sel.provider || !!(hEntry(hid))?.providers.includes(sel.provider))
          .map((hid) => entityCard("harness", hid, sel.harness === hid)),
      },
      {
        title: "Providers",
        items: e.providers
          .filter((pid) => !sel.harness || !!(hEntry(sel.harness))?.providers.includes(pid))
          .map((pid) => entityCard("provider", pid, sel.provider === pid)),
      },
      { title: "Agents", items: agents },
    ];
  }, [entry, index, dim, sel, combos, registry, id]);

  // two columns: the left stacks license (when the entity carries one),
  // openness (models), and the scandal flag; the right stacks the training
  // pair with closed_training below open_training
  const left: { field: string; value: string | null | boolean }[] = [];
  const right: { field: string; value: string | null | boolean }[] = [];
  if (entry) {
    if ("license" in entry) left.push({ field: "license", value: entry.license });
    if ("openness" in entry) left.push({ field: "openness", value: entry.openness });
    if ("reciprocity_scandal" in entry) {
      left.push({ field: "reciprocity_scandal", value: entry.reciprocity_scandal ? "true" : "false" });
    }
    right.push({ field: "open_training", value: entry.open_training });
    right.push({ field: "closed_training", value: entry.closed_training });
  }

  return (
    <main className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-5 px-4 py-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <Button variant="outline" size="sm" className="gap-1.5" onClick={onBack}>
          <ArrowLeft className="size-4" /> back to the index
        </Button>
        <a
          href={`/${dim}/${id}.json`}
          target="_blank"
          rel="noreferrer"
          className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1 text-xs underline underline-offset-4"
        >
          raw JSON
        </a>
      </div>

      {!entry && (
        <div className="rounded-xl border p-6">
          <h1 className="font-mono text-lg font-semibold">
            {title} {id}
          </h1>
          <p className="text-muted-foreground mt-2 text-sm">unknown {dim} — it resolves to no rule in the index.</p>
          <Button variant="outline" size="sm" className="mt-4" onClick={onBack}>
            <ArrowLeft className="size-4" /> back to the index
          </Button>
        </div>
      )}

      {entry && (
        <>
          <header className="flex flex-col gap-2">
            <div className="flex min-w-0 flex-wrap items-baseline gap-x-3">
              <h1 className="text-2xl font-semibold tracking-tight">{label}</h1>
              <span className="text-muted-foreground font-mono text-sm">{entry.id}</span>
            </div>
            <Badge variant="secondary" className="w-fit font-mono text-[10px]">
              {dim}
            </Badge>
          </header>

          <section className="flex flex-col gap-2 rounded-xl border p-4">
            <h2 className="text-muted-foreground text-xs font-medium uppercase tracking-wide">policy</h2>
            <div className="grid gap-x-6 gap-y-1 sm:grid-cols-2">
              {[left, right].map((column: { field: string; value: string | null | boolean }[], ci: number) => (
                <dl key={ci} className="flex flex-col gap-1">
                  {column.map((row) => (
                    <div key={row.field} className="flex min-w-0 items-baseline gap-2">
                      <dt className="text-muted-foreground w-44 shrink-0 font-mono text-xs">{row.field}</dt>
                      <dd
                        className="cursor-help text-sm underline decoration-dotted underline-offset-2"
                        title={policyExplain(row.field, row.value)}
                      >
                        {row.value ?? <span className="text-muted-foreground">null</span>}
                      </dd>
                    </div>
                  ))}
                </dl>
              ))}
            </div>
          </section>

          <section className="flex flex-col gap-3">
            <h2 className="text-muted-foreground text-xs font-medium uppercase tracking-wide">
              associations — click a card to narrow the tables beside it; a card's expand button opens its detail page
            </h2>
            <div className="grid gap-4 md:grid-cols-3">
              {tables.map((t) => (
                <Table key={t.title} title={t.title} items={t.items} />
              ))}
            </div>
          </section>

          <Button variant="outline" size="sm" className="self-start" onClick={onCombos}>
            view this {dim}'s combos in the registry
          </Button>

          <JsonBlock title="index entry" value={entry} />
        </>
      )}
    </main>
  );
}
