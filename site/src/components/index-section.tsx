import { useMemo } from "react";
import { ArrowUpDown, SquareArrowOutUpRight } from "lucide-react";

import { type HarnessEntry, type IndexDataFile, type ModelEntry, type ProviderEntry } from "@/lib/registry";
import { type Filters } from "@/components/filter-bar";
import { PolicyBadge } from "@/components/policy-badge";

interface IndexSectionProps {
  index: IndexDataFile | null;
  filters: Filters;
  /** clicking an entry toggles its dim filter — no scroll, the gold cue and
   * the pill box show it in place */
  onSelect: (dim: "harness" | "provider" | "model", id: string) => void;
  /** the open/max icon opens the entity's detail page (/model/<id> etc.) */
  onOpenEntity: (dim: "harness" | "provider" | "model", id: string) => void;
}

interface EntryView {
  id: string;
  label: string;
  badges: string[];
}

type AnyEntry = HarnessEntry | ProviderEntry | ModelEntry;

function entryView(e: AnyEntry): EntryView {
  const badges: string[] = [];
  if ("license" in e && e.license) badges.push(`license: ${e.license}`);
  if ("openness" in e && e.openness) badges.push(`openness: ${e.openness}`);
  if (e.open_training) badges.push(`open: ${e.open_training}`);
  if (e.closed_training) badges.push(`closed: ${e.closed_training}`);
  if ("reciprocity_scandal" in e && e.reciprocity_scandal) badges.push("scandal");
  // the association shape discriminates the entity (the contract carries no
  // provider_short_title/license; harnesses and models both carry license)
  return { id: e.id, label: e.label, badges };
}

/** the three index tables — every harness, provider, and model from
 * data/index.json (the committed index file the CLI embeds), in the
 * agent-card format with its canonical alphanumeric id, properties, and
 * associations. A dim filter narrows only its own list; the gold entry is
 * selected — click it again to clear, or open it with the
 * <SquareArrowOutUpRight /> icon (always visible on the gold cards) for its
 * detail page. Rendered inside the registry section, under its search bar. */
export function IndexSection({ index, filters, onSelect, onOpenEntity }: IndexSectionProps) {
  const groups = useMemo(() => {
    if (!index) return null;
    // dim filters narrow ALL THREE lists to what is available under them —
    // the same rule `agent-detect index --harness=…` applies: an entry stays
    // when it participates in a combo with every other set filter (through
    // its association arrays: direct for the pair it belongs to, closures
    // for the dims it reaches)
    return [
      {
        dim: "harness" as const,
        title: "Harnesses",
        total: index.harnesses.length,
        entries: index.harnesses
          .filter(
            (e) =>
              (!filters.harness || e.id === filters.harness) &&
              (!filters.provider || e.providers.includes(filters.provider)) &&
              (!filters.model || e.models.includes(filters.model)),
          )
          .map(entryView),
      },
      {
        dim: "provider" as const,
        title: "Providers",
        total: index.providers.length,
        entries: index.providers
          .filter(
            (e) =>
              (!filters.provider || e.id === filters.provider) &&
              (!filters.harness || e.harnesses.includes(filters.harness)) &&
              (!filters.model || e.models.includes(filters.model)),
          )
          .map(entryView),
      },
      {
        dim: "model" as const,
        title: "Models",
        total: index.models.length,
        entries: index.models
          .filter(
            (e) =>
              (!filters.model || e.id === filters.model) &&
              (!filters.harness || e.harnesses.includes(filters.harness)) &&
              (!filters.provider || e.providers.includes(filters.provider)),
          )
          .map(entryView),
      },
    ];
  }, [index, filters.harness, filters.provider, filters.model]);

  return (
    <>
      {!index && <p className="text-muted-foreground py-8 text-center text-sm">loading the registry…</p>}
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
              <ul className="max-h-96 overflow-y-auto p-1" aria-label={`${title} registry`}>
                {entries.map((e) => {
                  const selected = filters[dim] === e.id;
                  return (
                    <li key={e.id}>
                      <div
                        className={`group flex min-w-0 items-stretch gap-0.5 rounded-md transition-colors ${
                          selected
                            ? "border border-amber-500/60 bg-amber-500/10"
                            : "border border-transparent hover:bg-muted/50"
                        }`}
                      >
                        <button
                          type="button"
                          title={selected ? `clear the ${dim} filter` : `registry results for ${dim} ${e.id}`}
                          onClick={() => onSelect(dim, e.id)}
                          className={`flex min-w-0 flex-1 flex-col gap-0.5 px-2 py-1.5 text-left [container-type:inline-size] ${
                            selected ? "cursor-zoom-out" : "cursor-copy"
                          }`}
                        >
                          {/* the title keeps its natural size (so card heights
                            stay naturally constant) and the id — its own
                            container — shrinks into the leftover space,
                            never truncating (mono ≈ 0.62em/char) */}
                          <span className="flex min-w-0 items-baseline gap-x-2 whitespace-nowrap">
                            <span className="shrink-0 text-sm font-medium">{e.label}</span>
                            <span className="min-w-0 flex-1 [container-type:inline-size]">
                              <span
                                className="block text-muted-foreground font-mono"
                                style={{ fontSize: `min(11px, max(8px, 100cqw / ${(0.62 * e.id.length).toFixed(2)}))` }}
                              >
                                {e.id}
                              </span>
                            </span>
                          </span>
                          <span className="text-muted-foreground flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-[10px]">
                            {e.badges.map((b) => (
                              <PolicyBadge key={b} badge={b} />
                            ))}
                          </span>
                        </button>
                        <button
                          type="button"
                          title={`open the ${dim} detail page (${dim}/${e.id})`}
                          aria-label={`open ${dim} ${e.id} details`}
                          onClick={() => onOpenEntity(dim, e.id)}
                          className={`hover:text-foreground flex w-8 shrink-0 cursor-pointer flex-col items-center pt-1.5 transition-opacity ${
                            selected ? "" : "opacity-0 group-hover:opacity-100 focus-visible:opacity-100"
                          }`}
                        >
                          <span className="flex h-5 w-full items-center justify-center">
                            <SquareArrowOutUpRight className="size-3.5" />
                          </span>
                        </button>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))}
        </div>
      )}
    </>
  );
}
