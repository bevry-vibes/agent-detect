import { useMemo, useState } from "react";
import { ArrowDown, ArrowUp, ArrowUpDown } from "lucide-react";

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
 *
 * Columns sort client-side on header click: ascending → descending → default.
 * Below the md breakpoint the grid is replaced by a stacked card list — no
 * horizontal scroll, same rows, same click target.
 */
const GRID = "grid grid-cols-[minmax(130px,1fr)_minmax(150px,1.1fr)_minmax(150px,1.2fr)_150px_150px_minmax(210px,1.4fr)_110px]";
const CELL = "px-3 py-2.5 flex flex-col justify-center gap-0.5 leading-snug min-w-0";
const ROW_LAZY = "[content-visibility:auto] [contain-intrinsic-size:auto_57px]";
const CARD_LAZY = "[content-visibility:auto] [contain-intrinsic-size:auto_150px]";

type SortKey = "harness" | "provider" | "model" | "reciprocal" | "platforms" | "email" | "updated_at";
type Sort = { key: SortKey; dir: "asc" | "desc" } | null;

const COLUMNS: { key: SortKey; label: string; align?: "right" }[] = [
  { key: "harness", label: "Harness" },
  { key: "provider", label: "Provider" },
  { key: "model", label: "Model" },
  { key: "reciprocal", label: "Reciprocal" },
  { key: "platforms", label: "Platforms" },
  { key: "email", label: "Trailer email" },
  { key: "updated_at", label: "Updated", align: "right" },
];

function ReciprocalBadge({ row }: { row: ComboRow }) {
  const className = row.reciprocal
    ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
    : "border-red-500/40 bg-red-500/10 text-red-600 dark:text-red-400";
  return (
    <span className="flex shrink-0 items-center gap-1.5" title={row.state ?? undefined}>
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

function PlatformBadges({ row, wrap }: { row: ComboRow; wrap?: boolean }) {
  return (
    <span className={`gap-1 ${wrap ? "flex flex-wrap" : "flex"}`}>
      {row.platforms.map((p) => (
        <Badge key={p} variant="secondary" className="font-mono text-[10px]">
          {p}
        </Badge>
      ))}
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

  const [sort, setSort] = useState<Sort>(null);
  const cycleSort = (key: SortKey) =>
    setSort((s) => (s?.key !== key ? { key, dir: "asc" } : s.dir === "asc" ? { key, dir: "desc" } : null));

  const sorted = useMemo(() => {
    if (!sort) return rows;
    const mul = sort.dir === "asc" ? 1 : -1;
    const value = (r: ComboRow): string | number => {
      switch (sort.key) {
        case "harness":
          return labelOf("harnesses", r.harness).toLowerCase();
        case "provider":
          return labelOf("providers", r.provider).toLowerCase();
        case "model":
          return labelOf("models", r.model).toLowerCase();
        case "reciprocal":
          return r.reciprocal ? 1 : 0;
        case "platforms":
          return r.platforms.join(",");
        case "email":
          return r.email;
        case "updated_at":
          return r.updated_at;
      }
    };
    return [...rows].sort((a, b) => {
      const va = value(a);
      const vb = value(b);
      const cmp = typeof va === "number" && typeof vb === "number" ? va - vb : String(va).localeCompare(String(vb));
      return (cmp || a.agent_id.localeCompare(b.agent_id)) * mul;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, sort, registry]);

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
    <>
      {/* mobile: stacked cards — no horizontal scroll, same rows in the DOM */}
      <div role="list" aria-label="agent combos" className="md:hidden flex flex-col gap-2">
        {sorted.map((row) => (
          <div
            key={row.agent_id}
            role="listitem"
            tabIndex={0}
            onClick={() => onSelect(row.agent_id)}
            onKeyDown={(e) => e.key === "Enter" && onSelect(row.agent_id)}
            className={`${CARD_LAZY} cursor-pointer rounded-lg border p-3 transition-colors hover:bg-muted/50 focus-visible:bg-muted focus-visible:outline-none`}
          >
            <div className="flex min-w-0 flex-col gap-1 leading-snug">
              {([
                { label: "harness", dim: "harnesses", field: "harness" },
                { label: "provider", dim: "providers", field: "provider" },
                { label: "model", dim: "models", field: "model" },
              ] as const).map(({ label, dim, field }) => (
                <div key={dim} className="flex items-baseline gap-2 min-w-0">
                  <span className="w-16 shrink-0 text-right text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
                    {label}
                  </span>
                  <span className="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-2">
                    <span className="text-sm font-medium">{labelOf(dim, row[field])}</span>
                    <span className="font-mono text-[11px] text-muted-foreground">{row[field]}</span>
                  </span>
                </div>
              ))}
              <div className="flex items-baseline gap-2 min-w-0">
                <span className="w-16 shrink-0 text-right text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
                  email
                </span>
                <span className="min-w-0 flex-1 break-all font-mono text-[11px] text-muted-foreground">{row.email}</span>
              </div>
            </div>
            <div className="mt-2 flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
              <span className="flex flex-wrap items-center gap-1.5">
                <ReciprocalBadge row={row} />
                <PlatformBadges row={row} />
              </span>
              <span className="text-muted-foreground text-xs">{formatDate(row.updated_at)}</span>
            </div>
          </div>
        ))}
        <p className="text-muted-foreground px-1 text-xs">
          {rows.length.toLocaleString()} of {totalCount.toLocaleString()} fixture-backed combos — tap one for its result
          JSON
        </p>
      </div>

      {/* desktop: the lazy div-grid table with sortable headers */}
      <div className="hidden md:block rounded-xl border">
        <div className="max-h-[calc(100svh-11rem)] overflow-auto">
          <div role="table" aria-label="agent combos" className="w-full min-w-[1080px]">
            <div role="row" className={`${GRID} text-muted-foreground sticky top-0 z-20 border-b bg-background text-xs font-medium`}>
              {COLUMNS.map((col) => {
                const active = sort?.key === col.key;
                const ariaSort = active ? (sort.dir === "asc" ? "ascending" : "descending") : "none";
                const Arrow = !active ? ArrowUpDown : sort.dir === "asc" ? ArrowUp : ArrowDown;
                return (
                  <div key={col.key} role="columnheader" aria-sort={ariaSort} className={`px-3 py-2.5 ${col.align === "right" ? "text-right" : ""}`}>
                    <button
                      type="button"
                      onClick={() => cycleSort(col.key)}
                      title={`sort by ${col.label.toLowerCase()}${active ? (sort.dir === "asc" ? " — descending next" : " — default order next") : ""}`}
                      className={`inline-flex items-center gap-1 whitespace-nowrap hover:text-foreground ${active ? "text-foreground" : ""}`}
                    >
                      {col.label}
                      <Arrow className={`size-3 shrink-0 ${active ? "" : "opacity-40"}`} />
                    </button>
                  </div>
                );
              })}
            </div>
            <div role="rowgroup">
              {sorted.map((row) => (
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
                    <PlatformBadges row={row} wrap />
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
        </div>
        <div className="text-muted-foreground border-t px-3 py-2 text-xs">
          {rows.length.toLocaleString()} of {totalCount.toLocaleString()} fixture-backed combos — click a row for its
          result JSON, a column header to sort, or Ctrl/Cmd+F to search the whole list
        </div>
      </div>
    </>
  );
}
