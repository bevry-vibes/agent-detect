import { type ComboRow, type Registry } from "@/lib/registry";
import type { Filters } from "@/components/filter-bar";
import { CodeLine } from "@/components/json-block";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { formatDate } from "@/lib/utils";

/**
 * The results "table" is a div grid rather than a real <table> on purpose:
 * every row stays in the DOM (native Ctrl/Cmd+F finds them all) while
 * `content-visibility: auto` lets the browser skip layout/paint of off-screen
 * rows — JS virtualization would drop rows from the DOM and kill find-in-page,
 * and content-visibility does not apply to <tr> internals.
 */
const GRID = "grid grid-cols-[minmax(130px,1fr)_minmax(150px,1.1fr)_minmax(150px,1.2fr)_150px_150px_minmax(210px,1.4fr)_110px]";
const CELL = "px-3 py-2.5 flex flex-col justify-center leading-tight min-w-0";
const ROW_LAZY = "[content-visibility:auto] [contain-intrinsic-size:auto_57px]";

function ReciprocalBadge({ row }: { row: ComboRow }) {
  const className = row.reciprocal
    ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
    : "border-red-500/40 bg-red-500/10 text-red-600 dark:text-red-400";
  return (
    <span className="flex items-center gap-1.5" title={row.state ?? undefined}>
      <Badge variant="outline" className={className}>
        {row.reciprocal ? "reciprocal" : "not reciprocal"}
      </Badge>
      {row.state && row.state !== "reciprocal" && row.state !== "not-reciprocal" && (
        <Badge variant="outline" className="text-muted-foreground">
          {row.state}
        </Badge>
      )}
    </span>
  );
}

interface ResultsTableProps {
  rows: ComboRow[];
  totalCount: number;
  filters: Filters;
  registry: Registry;
  onSelect: (agentId: string) => void;
}

export function ResultsTable({ rows, totalCount, filters, registry, onSelect }: ResultsTableProps) {
  const labelOf = (dim: "harnesses" | "providers" | "models", id: string) =>
    registry[dim].find((r) => r.id === id)?.label ?? id;

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

  return (
    <div className="overflow-hidden rounded-xl border">
      <div role="table" aria-label="agent combos" className="min-w-[1080px] overflow-x-auto">
        <div role="row" className={`${GRID} text-muted-foreground sticky top-14 z-10 border-b bg-background/95 text-xs font-medium backdrop-blur`}>
          <div role="columnheader" className="px-3 py-2.5">Harness</div>
          <div role="columnheader" className="px-3 py-2.5">Provider</div>
          <div role="columnheader" className="px-3 py-2.5">Model</div>
          <div role="columnheader" className="px-3 py-2.5">Reciprocal</div>
          <div role="columnheader" className="px-3 py-2.5">Platforms</div>
          <div role="columnheader" className="px-3 py-2.5">Trailer email</div>
          <div role="columnheader" className="px-3 py-2.5 text-right">Updated</div>
        </div>
        <div role="rowgroup">
          {rows.map((row) => (
            <div
              key={row.agent_id}
              role="row"
              tabIndex={0}
              onClick={() => onSelect(row.agent_id)}
              onKeyDown={(e) => e.key === "Enter" && onSelect(row.agent_id)}
              className={`${GRID} ${ROW_LAZY} cursor-pointer border-b transition-colors hover:bg-muted/50 focus-visible:bg-muted focus-visible:outline-none`}
            >
              <div role="cell" className={CELL}>
                <span className="truncate">{labelOf("harnesses", row.harness)}</span>
                <span className="text-muted-foreground truncate font-mono text-xs">{row.harness}</span>
              </div>
              <div role="cell" className={CELL}>
                <span className="truncate">{labelOf("providers", row.provider)}</span>
                <span className="text-muted-foreground truncate font-mono text-xs">{row.provider}</span>
              </div>
              <div role="cell" className={CELL}>
                <span className="truncate">{labelOf("models", row.model)}</span>
                <span className="text-muted-foreground truncate font-mono text-xs">{row.model}</span>
              </div>
              <div role="cell" className={CELL}>
                <ReciprocalBadge row={row} />
              </div>
              <div role="cell" className={CELL}>
                <span className="flex gap-1">
                  {row.platforms.map((p) => (
                    <Badge key={p} variant="secondary" className="font-mono text-[10px]">
                      {p}
                    </Badge>
                  ))}
                </span>
              </div>
              <div role="cell" className={CELL}>
                <span className="text-muted-foreground truncate font-mono text-xs" title={row.email}>
                  {row.email}
                </span>
              </div>
              <div role="cell" className={`${CELL} text-right`}>
                <span className="text-muted-foreground text-xs">{formatDate(row.updated_at)}</span>
              </div>
            </div>
          ))}
        </div>
      </div>
      <div className="text-muted-foreground border-t px-3 py-2 text-xs">
        {rows.length.toLocaleString()} of {totalCount.toLocaleString()} fixture-backed combos — click a row for its result
        JSON, or Ctrl/Cmd+F to search the whole list
      </div>
    </div>
  );
}
