import { useEffect, useMemo, useState } from "react";
import { ArrowLeft } from "lucide-react";

import { type CombosFile, type IndexFile, type Registry } from "@/lib/registry";
import { NO_FILTERS } from "@/components/filter-bar";
import { JsonBlock } from "@/components/json-block";
import { AssociationTables } from "@/components/association-tables";
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
  /** the expand buttons: entities open their detail page, agents open their result page */
  onOpenEntity: (dim: EntityDim, id: string) => void;
  onOpenAgent: (agentId: string) => void;
  /** a table's search icon: the registry section filtered to that context */
  onSearch: (filters: Filters) => void;
  onBack: () => void;
}

interface Filters {
  harness: string | null;
  provider: string | null;
  model: string | null;
  search: string | null;
  email: string | null;
  platform: string | null;
  free: boolean | null;
  reciprocal: boolean | null;
}

export function EntityPage({ dim, id, index, registry, combos, onSearch, onOpenEntity, onOpenAgent, onBack }: EntityPageProps) {

  const entry = useMemo(() => {
    if (!index) return null;
    return index[DIM_TABLES[dim]].find((e) => e.id === id) ?? null;
  }, [index, dim, id]);

  const label = registry ? registry[DIM_TABLES[dim]].find((r) => r.id === id)?.label ?? id : id;
  const title = dim === "model" ? "Model" : dim === "provider" ? "Provider" : "Harness";

  const policy: { field: string; value: string | null | boolean }[] = [];
  if (entry) {
    if ("license" in entry) policy.push({ field: "license", value: entry.license });
    if ("openness" in entry) policy.push({ field: "openness", value: entry.openness });
    if ("reciprocity_scandal" in entry) {
      policy.push({ field: "reciprocity_scandal", value: entry.reciprocity_scandal ? "true" : "false" });
    }
    policy.push({ field: "open_training", value: entry.open_training });
    policy.push({ field: "closed_training", value: entry.closed_training });
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
              {[
                policy.filter((row) => row.field !== "open_training" && row.field !== "closed_training"),
                policy.filter((row) => row.field === "open_training" || row.field === "closed_training"),
              ].map((column: typeof policy, ci: number) => (
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

          <AssociationTables
            page={{ [dim]: id }}
            self={{ [dim]: id }}
            index={index}
            registry={registry}
            combos={combos}
            onOpenEntity={onOpenEntity}
            onOpenAgent={onOpenAgent}
            onSearch={(f) => {
              const next = { ...NO_FILTERS };
              if (f.harness) next.harness = f.harness;
              if (f.provider) next.provider = f.provider;
              if (f.model) next.model = f.model;
              onSearch(next);
            }}
            onBack={onBack}
          />

          <JsonBlock title="index entry" value={entry} />
        </>
      )}
    </main>
  );
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
