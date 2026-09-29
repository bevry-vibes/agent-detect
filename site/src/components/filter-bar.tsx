import { useEffect, useState } from "react";
import { X } from "lucide-react";

import type { Registry } from "@/lib/registry";
import { DimCombobox } from "@/components/dim-combobox";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export interface Filters {
  harness: string | null;
  provider: string | null;
  model: string | null;
  email: string | null;
}

interface FilterBarProps {
  registry: Registry;
  filters: Filters;
  counts: { harnesses: Record<string, number>; providers: Record<string, number>; models: Record<string, number> };
  rowCount: number;
  totalCount: number;
  jsonHref: string;
  onDim: (dim: "harness" | "provider" | "model", id: string | null) => void;
  onEmail: (email: string | null) => void;
  onClear: () => void;
}

/** the top row — three searchable dropdowns (harness, provider, model) plus the
 * trailer-email lookup; every change lands in the URL via the history API */
export function FilterBar({ registry, filters, counts, rowCount, totalCount, jsonHref, onDim, onEmail, onClear }: FilterBarProps) {
  const [emailDraft, setEmailDraft] = useState(filters.email ?? "");
  useEffect(() => setEmailDraft(filters.email ?? ""), [filters.email]);

  const commitEmail = () => {
    const trimmed = emailDraft.trim().toLowerCase();
    onEmail(trimmed || null);
  };

  return (
    <div className="flex flex-col gap-3">
      <div className="grid gap-2 md:grid-cols-4">
        <DimCombobox label="Harness" value={filters.harness} rules={registry.harnesses} counts={counts.harnesses} onChange={(id) => onDim("harness", id)} />
        <DimCombobox label="Provider" value={filters.provider} rules={registry.providers} counts={counts.providers} onChange={(id) => onDim("provider", id)} />
        <DimCombobox label="Model" value={filters.model} rules={registry.models} counts={counts.models} onChange={(id) => onDim("model", id)} />
        <div className="relative">
          <Input
            value={emailDraft}
            onChange={(e) => setEmailDraft(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && commitEmail()}
            onBlur={commitEmail}
            placeholder="trailer email — e.g. cline-clinepass-deepseekv4flash@local"
            aria-label="filter by trailer email"
            className="h-10 pr-8 font-mono text-xs"
          />
          {filters.email && (
            <button
              type="button"
              aria-label="clear email filter"
              onClick={() => {
                setEmailDraft("");
                onEmail(null);
              }}
              className="text-muted-foreground hover:text-foreground absolute top-1/2 right-2 -translate-y-1/2"
            >
              <X className="size-4" />
            </button>
          )}
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-3 text-sm">
        <span className="text-muted-foreground">
          <strong className="text-foreground tabular-nums">{rowCount.toLocaleString()}</strong> of{" "}
          {totalCount.toLocaleString()} combos
        </span>
        {(filters.harness || filters.provider || filters.model || filters.email) && (
          <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={onClear}>
            <X className="size-3" /> clear filters
          </Button>
        )}
        <a
          href={jsonHref}
          className="text-muted-foreground hover:text-foreground ml-auto font-mono text-xs underline underline-offset-4"
          title="this filtered view as JSON"
        >
          view as JSON ↗
        </a>
      </div>
    </div>
  );
}
