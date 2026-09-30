import { useMemo } from "react";
import { ArrowLeft } from "lucide-react";

import { type IndexFile, type Registry } from "@/lib/registry";
import { JsonBlock } from "@/components/json-block";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

export type EntityDim = "harness" | "provider" | "model";

const DIM_TABLES = { harness: "harnesses", provider: "providers", model: "models" } as const;

interface EntityPageProps {
  dim: EntityDim;
  id: string;
  index: IndexFile | null;
  registry: Registry | null;
  /** an association chip filters the registry section with it */
  onDim: (dim: "harness" | "provider" | "model", id: string) => void;
  /** view the entity's combos in the registry (the dim filter jump) */
  onCombos: () => void;
  onBack: () => void;
}

function AssociationChips(
  { ids, dim, registry, onDim }: { ids: string[]; dim: "harness" | "provider" | "model"; registry: Registry | null; onDim: EntityPageProps["onDim"] },
) {
  const table = DIM_TABLES[dim];
  return (
    <span className="flex flex-wrap gap-1">
      {ids.length === 0 && <span className="text-muted-foreground text-xs">none</span>}
      {ids.map((id) => {
        const label = registry?.[table].find((r) => r.id === id)?.label ?? id;
        return (
          <button
            key={id}
            type="button"
            title={`registry results for ${dim} ${id}`}
            onClick={() => onDim(dim, id)}
            className="hover:bg-muted/50 inline-flex items-baseline gap-1 rounded-md border px-1.5 py-0.5 text-xs transition-colors"
          >
            <span className="font-medium">{label}</span>
            <span className="text-muted-foreground font-mono text-[10px]">{id}</span>
          </button>
        );
      })}
    </span>
  );
}

/** the full-page entity detail (the result page's sibling) — every field the
 * index carries for one harness/provider/model: its identity, policy fields,
 * and its associations (chips filter the registry). The JSON block is the
 * entry verbatim — the same object /model/<id>.json serves. */
export function EntityPage({ dim, id, index, registry, onDim, onCombos, onBack }: EntityPageProps) {
  const entry = useMemo(() => {
    if (!index) return null;
    const table = index[DIM_TABLES[dim]];
    return table.find((e) => e.id === id) ?? null;
  }, [index, dim, id]);

  const label = registry ? registry[DIM_TABLES[dim]].find((r) => r.id === id)?.label ?? id : id;
  const title = dim === "model" ? "Model" : dim === "provider" ? "Provider" : "Harness";

  const assoc: { label: string; dim: EntityDim; ids: string[] }[] = [];
  if (entry) {
    if ("harnesses" in entry && "providers" in entry) {
      assoc.push({ label: "providers", dim: "provider", ids: entry.providers }); // model
      assoc.push({ label: "harnesses", dim: "harness", ids: entry.harnesses });
    } else if ("harnesses" in entry) {
      assoc.push({ label: "harnesses", dim: "harness", ids: entry.harnesses }); // provider
      assoc.push({ label: "models", dim: "model", ids: entry.models });
    } else {
      assoc.push({ label: "providers", dim: "provider", ids: entry.providers }); // harness
      assoc.push({ label: "models", dim: "model", ids: entry.models });
    }
  }

  const policy: { field: string; value: string | null }[] = [];
  if (entry) {
    policy.push({ field: "license", value: "license" in entry ? entry.license : null });
    if ("openness" in entry) policy.push({ field: "openness", value: entry.openness });
    policy.push({ field: "open_training", value: entry.open_training });
    policy.push({ field: "closed_training", value: entry.closed_training });
    if ("reciprocity_scandal" in entry) {
      policy.push({ field: "reciprocity_scandal", value: entry.reciprocity_scandal ? "true" : "false" });
    }
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
              <Badge variant="secondary" className="font-mono text-[10px]">
                {dim}
              </Badge>
            </div>
            <p className="text-muted-foreground text-sm">
              <span className="font-mono">{entry.name}</span>
              {entry.variations.length > 0 && <> — also answers to {entry.variations.join(", ")}</>}
            </p>
          </header>

          <section className="flex flex-col gap-2 rounded-xl border p-4">
            <h2 className="text-muted-foreground text-xs font-medium uppercase tracking-wide">policy</h2>
            <dl className="grid gap-x-6 gap-y-1 sm:grid-cols-2">
              {policy.map((row) => (
                <div key={row.field} className="flex min-w-0 items-baseline gap-2">
                  <dt className="text-muted-foreground w-44 shrink-0 font-mono text-xs">{row.field}</dt>
                  <dd className="text-sm">{row.value ?? <span className="text-muted-foreground">null</span>}</dd>
                </div>
              ))}
            </dl>
          </section>

          <section className="flex flex-col gap-3 rounded-xl border p-4">
            <h2 className="text-muted-foreground text-xs font-medium uppercase tracking-wide">associations</h2>
            {assoc.map((group) => (
              <div key={group.label} className="flex min-w-0 flex-col gap-1">
                <span className="text-muted-foreground font-mono text-xs">{group.label}</span>
                <AssociationChips ids={group.ids} dim={group.dim} registry={registry} onDim={onDim} />
              </div>
            ))}
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
