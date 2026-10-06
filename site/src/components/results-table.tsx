import { SquareArrowOutUpRight } from "lucide-react";

import { type AgentRow } from "@/lib/registry";
import type { Filters } from "@/components/filter-bar";
import { AgentCardBody } from "@/components/agent-card";
import { CodeLine } from "@/components/json-block";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

/**
 * The agents table is one card list on every breakpoint — the same card the
 * result page's agents table renders: the agent id in white over the status
 * line (reciprocal verdict · platform pills · updated date), no columns and
 * no sorting — the dim tables beside it and the search bar do that narrowing.
 * Every card stays in the DOM (native Ctrl/Cmd+F finds them all) while
 * `content-visibility: auto` lets the browser skip off-screen cards.
 */
const CARD_LAZY = "[content-visibility:auto] [contain-intrinsic-size:auto_64px]";

interface ResultsTableProps {
  rows: AgentRow[];
  totalCount: number;
  filters: Filters;
  onSelect: (agentId: string) => void;
}

export function ResultsTable({ rows, totalCount, filters, onSelect }: ResultsTableProps) {
  // all three dims selected → the triple pins exactly one combo; its card
  // carries the gold cue (the list is already narrowed to it alone)
  const pinned = !!(filters.harness && filters.provider && filters.model);

  if (rows.length === 0) {
    const allThree = filters.harness && filters.provider && filters.model;
    return (
      <Card>
        <CardHeader>
          <CardTitle className="text-base">No results for this filter</CardTitle>
        </CardHeader>
        <CardContent className="text-muted-foreground flex flex-col gap-3 text-sm">
          <p>
            {allThree
              ? "This combo exists in the rule registry (the dropdowns list it) but has no fixture yet — it has never been declared or captured. Verify it live:"
              : "No combo matches the current filters — loosen one, or clear them to see every fixture-backed combo."}
          </p>
          {allThree && (
            <CodeLine
              code={`agent-detect check-reciprocal --harness=${filters.harness} --provider=${filters.provider} --model=${filters.model}`}
            />
          )}
        </CardContent>
      </Card>
    );
  }

  // the total header the other tables share — `N` when unfiltered, `n of N`
  // under filters (toLocaleString: the raw counts clear four digits)
  const countLabel = `Agents — ${
    rows.length === totalCount ? totalCount.toLocaleString() : `${rows.length.toLocaleString()} of ${totalCount.toLocaleString()}`
  }`;

  return (
    <div role="list" aria-label="agent combos" className="rounded-xl border">
      <div className="text-muted-foreground border-b px-3 py-2 text-xs font-medium">{countLabel}</div>
      {/* the same 7.5-rows cap the dim tables use — all four tables share one height */}
      <div className="max-h-96 overflow-y-auto p-1">
        {rows.map((row) => (
          <div
            key={row.agent_id}
            role="listitem"
            tabIndex={0}
            title={pinned ? "pinned by the three dim filters — click for its result JSON" : undefined}
            onClick={() => onSelect(row.agent_id)}
            onKeyDown={(e) => e.key === "Enter" && onSelect(row.agent_id)}
            className={`${CARD_LAZY} group flex min-w-0 cursor-pointer items-stretch gap-0.5 rounded-md border transition-colors focus-visible:bg-muted focus-visible:outline-none ${
              pinned ? "border-amber-500/60 bg-amber-500/10" : "border-transparent hover:bg-muted/50"
            }`}
          >
            <AgentCardBody agentId={row.agent_id} row={row} />
            {/* the open icon — top right like the dim cards', hover-revealed,
              always visible on the pinned card */}
            <button
              type="button"
              title={`open the result page (/agent/${row.agent_id})`}
              aria-label={`open the result page (/agent/${row.agent_id})`}
              onClick={(e) => {
                e.stopPropagation(); // the card body opens too — one navigation
                onSelect(row.agent_id);
              }}
              className={`hover:text-foreground flex w-8 shrink-0 cursor-pointer flex-col items-center pt-1.5 transition-opacity ${
                pinned ? "" : "opacity-0 group-hover:opacity-100 focus-visible:opacity-100"
              }`}
            >
              <span className="flex h-5 w-full items-center justify-center">
                <SquareArrowOutUpRight className="size-3.5" />
              </span>
            </button>
          </div>
        ))}
      </div>
      <div className="text-muted-foreground border-t px-3 py-2 text-xs">
        click a card for its result JSON — Ctrl/Cmd+F searches the whole list
      </div>
    </div>
  );
}
