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
  /** exact trailer-email match (URL filter — no input here; free-text search
   * also matches emails) */
  email: string | null;
  /** combos declared on this platform */
  platform: string | null;
  /** the provider-model cell's free-axis membership */
  free: boolean | null;
  /** the combo's reciprocity of record */
  reciprocal: boolean | null;
}

export const NO_FILTERS: Filters = {
  harness: null,
  provider: null,
  model: null,
  search: null,
  email: null,
  platform: null,
  free: null,
  reciprocal: null,
};

/** a tri-state chip row — any / yes / no; "any" only renders when set */
function TriToggle(
  { label, value, onChange }: { label: string; value: boolean | null; onChange: (v: boolean | null) => void },
) {
  const chip = (v: boolean | null, text: string, active: boolean) => (
    <button
      key={text}
      type="button"
      aria-pressed={active}
      title={`${label}: ${text}`}
      onClick={() => onChange(v)}
      className={`rounded-md border px-2 py-1 text-xs transition-colors ${
        active ? "bg-foreground text-background border-transparent" : "hover:bg-muted/50 text-muted-foreground"
      }`}
    >
      {text}
    </button>
  );
  return (
    <span className="flex items-center gap-1">
      <span className="text-muted-foreground text-xs">{label}</span>
      {value == null && chip(true, "any", true)}
      {chip(true, "yes", value === true)}
      {chip(false, "no", value === false)}
      {value != null && chip(null, "any", false)}
    </span>
  );
}

interface FilterBarProps {
  registry: Registry;
  filters: Filters;
  counts: { harnesses: Record<string, number>; providers: Record<string, number>; models: Record<string, number> };
  onDim: (dim: "harness" | "provider" | "model", id: string | null) => void;
  onSearch: (text: string | null) => void;
  onTriFilter: (key: "free" | "reciprocal", value: boolean | null) => void;
  onClear: () => void;
}

/** the top row — three searchable dropdowns (harness, provider, model), a
 * free-text search over combo ids and dim names/ids, and the reciprocal/free
 * tri-state toggles; every change lands in the URL via the history API.
 * The email and platform filters are URL-only (?email=, ?platform=). */
export function FilterBar({ registry, filters, counts, onDim, onSearch, onTriFilter, onClear }: FilterBarProps) {
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
      <div className="flex flex-wrap items-center gap-3">
        <TriToggle label="reciprocal" value={filters.reciprocal} onChange={(v) => onTriFilter("reciprocal", v)} />
        <TriToggle label="free" value={filters.free} onChange={(v) => onTriFilter("free", v)} />
      </div>
      {(filters.harness || filters.provider || filters.model || filters.search || filters.email || filters.platform || filters.free != null || filters.reciprocal != null) && (
        <div className="flex">
          <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={onClear}>
            <X className="size-3" /> clear filters
          </Button>
        </div>
      )}
    </div>
  );
}
