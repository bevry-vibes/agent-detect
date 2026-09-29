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
  search: string | null;
}

interface FilterBarProps {
  registry: Registry;
  filters: Filters;
  counts: { harnesses: Record<string, number>; providers: Record<string, number>; models: Record<string, number> };
  onDim: (dim: "harness" | "provider" | "model", id: string | null) => void;
  onSearch: (text: string | null) => void;
  onClear: () => void;
}

/** the top row — three searchable dropdowns (harness, provider, model) plus a
 * free-text search over combo ids and dim names/ids; every change lands in the
 * URL via the history API */
export function FilterBar({ registry, filters, counts, onDim, onSearch, onClear }: FilterBarProps) {
  const [searchDraft, setSearchDraft] = useState(filters.search ?? "");
  useEffect(() => setSearchDraft(filters.search ?? ""), [filters.search]);

  const commitSearch = () => {
    const trimmed = searchDraft.trim().toLowerCase();
    onSearch(trimmed || null);
  };

  return (
    <div className="flex flex-col gap-3">
      <div className="grid gap-2 md:grid-cols-4">
        <DimCombobox label="Harness" value={filters.harness} rules={registry.harnesses} counts={counts.harnesses} onChange={(id) => onDim("harness", id)} />
        <DimCombobox label="Provider" value={filters.provider} rules={registry.providers} counts={counts.providers} onChange={(id) => onDim("provider", id)} />
        <DimCombobox label="Model" value={filters.model} rules={registry.models} counts={counts.models} onChange={(id) => onDim("model", id)} />
        <div className="relative">
          <Input
            value={searchDraft}
            onChange={(e) => setSearchDraft(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && commitSearch()}
            onBlur={commitSearch}
            placeholder="search"
            aria-label="search"
            className="h-10 pr-8"
          />
          {filters.search && (
            <button
              type="button"
              aria-label="clear search"
              onClick={() => {
                setSearchDraft("");
                onSearch(null);
              }}
              className="text-muted-foreground hover:text-foreground absolute top-1/2 right-2 -translate-y-1/2"
            >
              <X className="size-4" />
            </button>
          )}
        </div>
      </div>
      {(filters.harness || filters.provider || filters.model || filters.search) && (
        <div className="flex">
          <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={onClear}>
            <X className="size-3" /> clear filters
          </Button>
        </div>
      )}
    </div>
  );
}
