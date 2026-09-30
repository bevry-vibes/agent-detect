import { useMemo } from "react";
import { ArrowUpDown, SquareArrowOutUpRight } from "lucide-react";

import { type HarnessEntry, type IndexFile, type ModelEntry, type ProviderEntry } from "@/lib/registry";
import { type Filters } from "@/components/filter-bar";
import { Badge } from "@/components/ui/badge";

interface IndexSectionProps {
  index: IndexFile | null;
  filters: Filters;
  /** clicking an entry toggles its dim filter; a NEW selection also jumps to
   * the registry section (the same jump the result page's dim entries use) */
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

/** what each index-card badge means — the training axes are the two sides of
 * the reciprocity question: does the entity use your data to train OPEN-weight
 * models (informational) or CLOSED API models (the axis that gates
 * reciprocity); a license/openness badge states its value's own meaning */
function badgeTitle(b: string): string {
  if (b.startsWith("open: ")) return `open-model training: ${b.slice(6)} — whether the entity uses your data to train open-weight models (informational; never gates reciprocity)`;
  if (b.startsWith("closed: ")) return `closed-model training: ${b.slice(8)} — whether the entity uses your data to train closed (API) models: enforced = no opt-out, opt-out = trains by default, opt-in = off by default, never = verified never, NOASSERTION = researched, inconclusive; this axis gates reciprocity`;
  if (b === "scandal") return "reciprocity scandal — implicated by a court, regulator, official report, or wire-capture finding (the fair-use purpose test)";
  if (b === "license: NONE") return "license: verified none granted (closed source)";
  if (b === "license: NOASSERTION") return "license: exists but custom/non-SPDX, or researched without conclusion";
  if (b.startsWith("license: ")) return `license: ${b.slice(9)} — the SPDX license id`;
  if (b === "openness: closed") return "openness: closed — API-only, no weights published";
  if (b.startsWith("openness: open-")) return `${b} — the weights are published under this tier`;
  if (b.startsWith("openness: ")) return `${b} — the weights' openness tier`;
  return b;
}

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

/** the index section (#index) — the same article structure as the registry
 * section: header, description, count badges, and the data-as-JSON link, then
 * every harness, provider, and model from data/index.json (the committed index
 * file the CLI embeds) with its canonical alphanumeric id, properties, and
 * associations. A dim filter narrows only its own list; the selected entry
 * carries the gold cue, and clicking it again clears the filter. The open/max
 * icon opens the entity's detail page. */
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
    <article id="index" className="mx-auto flex w-full max-w-7xl flex-col gap-5 scroll-mt-14 px-4 py-8">
      <div className="flex flex-col gap-2">
        <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">Index of Agent Detections</h2>
        <p className="text-lg font-medium">Every harness, provider, and model.</p>
        <p className="text-muted-foreground text-sm">
          The rule index the CLI embeds — map any name or variation to its canonical alphanumeric id, with each entry's
          properties and its associations. A dim filter narrows only its own list; the gold entry is selected — click it
          again to clear, or open it with the <SquareArrowOutUpRight className="inline size-3" aria-hidden /> icon for its detail
          page.
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
                          className="flex min-w-0 flex-1 flex-col gap-0.5 px-2 py-1.5 text-left"
                        >
                          <span className="flex min-w-0 flex-wrap items-baseline gap-x-2">
                            <span className="text-sm font-medium">{e.label}</span>
                            <span className="text-muted-foreground font-mono text-[11px]">{e.id}</span>
                          </span>
                          <span className="text-muted-foreground flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-[10px]">
                            {e.badges.map((b) => (
                              <Badge
                                key={b}
                                variant="outline"
                                title={badgeTitle(b)}
                                className={`cursor-help px-1 py-0 text-[10px] ${selected ? "border-amber-500/40 text-amber-600 dark:text-amber-300" : ""}`}
                              >
                                {b}
                              </Badge>
                            ))}
                          </span>
                        </button>
                        <button
                          type="button"
                          title={`open the ${dim} detail page (${dim}/${e.id})`}
                          aria-label={`open ${dim} ${e.id} details`}
                          onClick={() => onOpenEntity(dim, e.id)}
                          className="hover:text-foreground flex w-8 shrink-0 cursor-pointer items-center justify-center opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100"
                        >
                          <SquareArrowOutUpRight className="size-3.5" />
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
    </article>
  );
}
