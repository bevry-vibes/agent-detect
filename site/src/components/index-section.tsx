import { useMemo } from "react";
import { ArrowUpDown } from "lucide-react";

import { type HarnessEntry, type IndexFile, type ModelEntry, type ProviderEntry } from "@/lib/registry";
import { type Filters } from "@/components/filter-bar";
import { Badge } from "@/components/ui/badge";

interface IndexSectionProps {
  index: IndexFile | null;
  filters: Filters;
  /** clicking an entry filters the registry section with that dim (the same
   * jump the result page's dim entries use) */
  onSelect: (dim: "harness" | "provider" | "model", id: string) => void;
}

interface EntryView {
  id: string;
  name: string;
  label: string;
  variations: string[];
  badges: string[];
  associations: string;
}

type AnyEntry = HarnessEntry | ProviderEntry | ModelEntry;

function entryView(e: AnyEntry): EntryView {
  const badges: string[] = [];
  if ("license" in e && e.license) badges.push(e.license);
  if ("openness" in e && e.openness) badges.push(e.openness);
  if (e.open_training) badges.push(`open: ${e.open_training}`);
  if (e.closed_training) badges.push(`closed: ${e.closed_training}`);
  if ("reciprocity_scandal" in e && e.reciprocity_scandal) badges.push("scandal");
  // the association shape discriminates the entity (the contract carries no
  // provider_short_title/license; harnesses and models both carry license)
  const associations =
    "providers" in e && "harnesses" in e
      ? `${e.providers.length} providers · ${e.harnesses.length} harnesses` // model
      : "harnesses" in e
      ? `${e.harnesses.length} harnesses · ${e.models.length} models` // provider
      : `${e.providers.length} providers · ${e.models.length} models`; // harness
  return { id: e.id, name: e.name, label: e.label, variations: e.variations, badges, associations };
}

/** the index section (#index) — the same article structure as the registry
 * section: header, description, count badges, and the data-as-JSON link, then
 * every harness, provider, and model from data/index.json (the committed index
 * file the CLI embeds) with its canonical alphanumeric id, properties, and
 * associations. A dim filter narrows only its own list; clicking an entry
 * filters the registry. */
export function IndexSection({ index, filters, onSelect }: IndexSectionProps) {
  const groups = useMemo(() => {
    if (!index) return null;
    // a dim filter narrows ONLY its own list — a provider filter shrinks the
    // providers column and leaves the harnesses/models lists (and every
    // association list inside each entry) untouched
    return [
      {
        dim: "harness" as const,
        title: "Harnesses",
        total: index.harnesses.length,
        entries: (filters.harness ? index.harnesses.filter((e) => e.id === filters.harness) : index.harnesses).map(entryView),
      },
      {
        dim: "provider" as const,
        title: "Providers",
        total: index.providers.length,
        entries: (filters.provider ? index.providers.filter((e) => e.id === filters.provider) : index.providers).map(entryView),
      },
      {
        dim: "model" as const,
        title: "Models",
        total: index.models.length,
        entries: (filters.model ? index.models.filter((e) => e.id === filters.model) : index.models).map(entryView),
      },
    ];
  }, [index, filters.harness, filters.provider, filters.model]);

  return (
    <article id="index" className="mx-auto flex w-full max-w-7xl flex-col gap-5 scroll-mt-14 px-4 py-8">
      <div className="flex flex-col gap-2">
        <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">Index of Agent Detections</h2>
        <p className="text-lg font-medium">Every harness, provider, and model.</p>
        <p className="text-muted-foreground text-sm">
          The rule index the CLI embeds — map any name or variation to its canonical alphanumeric id, with each entry's
          properties and its associations. A dim filter narrows only its own list; click an entry to filter the
          registry.
        </p>
        <div className="mt-1 flex flex-wrap items-center gap-2">
          {index && (
            <>
              <Badge variant="secondary">{index.harnesses.length} harnesses</Badge>
              <Badge variant="secondary">{index.providers.length} providers</Badge>
              <Badge variant="secondary">{index.models.length} models</Badge>
            </>
          )}
          <a
            href="/data/index.json"
            target="_blank"
            rel="noreferrer"
            className="text-muted-foreground hover:text-foreground ml-auto font-mono text-sm underline underline-offset-4"
            title="the index file as JSON — the same bytes the released `agent-detect index` embeds"
          >
            view as JSON ↗
          </a>
        </div>
      </div>

      {!index && <p className="text-muted-foreground py-8 text-center text-sm">loading the index…</p>}
      {index && groups && (
        <div className="grid gap-4 md:grid-cols-3">
          {groups.map(({ dim, title, entries, total }) => (
            <div key={dim} className="rounded-xl border">
              <div className="text-muted-foreground flex items-center justify-between border-b px-3 py-2 text-xs font-medium">
                <span>
                  {title} — {entries.length === total ? total : `${entries.length} of ${total}`}
                </span>
                <ArrowUpDown className="size-3 opacity-40" aria-hidden />
              </div>
              <ul className="max-h-96 overflow-y-auto p-1" aria-label={`${title} index`}>
                {entries.map((e) => (
                  <li key={e.id}>
                    <button
                      type="button"
                      title={`registry results for ${dim} ${e.id}`}
                      onClick={() => onSelect(dim, e.id)}
                      className="hover:bg-muted/50 flex w-full min-w-0 flex-col gap-0.5 rounded-md px-2 py-1.5 text-left transition-colors"
                    >
                      <span className="flex min-w-0 flex-wrap items-baseline gap-x-2">
                        <span className="text-sm font-medium">{e.label}</span>
                        <span className="text-muted-foreground font-mono text-[11px]">{e.id}</span>
                      </span>
                      <span className="text-muted-foreground flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-[10px]">
                        <span className="font-mono">{e.name}</span>
                        {e.variations.length > 0 && <span className="font-mono">aka {e.variations.join(", ")}</span>}
                        {e.badges.map((b) => (
                          <Badge key={b} variant="outline" className="px-1 py-0 text-[10px]">
                            {b}
                          </Badge>
                        ))}
                        <span>· {e.associations}</span>
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      )}
    </article>
  );
}
