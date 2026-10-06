import { useEffect, useMemo, useRef, useState } from "react";
import { X } from "lucide-react";

import { resolveDimId, resolvePlatform, slugId, type RegistryFile } from "@/lib/registry";

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

export function anyFilter(filters: Filters): boolean {
  return !!(filters.harness || filters.provider || filters.model || filters.search || filters.email || filters.platform || filters.free != null || filters.reciprocal != null);
}

interface FilterBarProps {
  registry: RegistryFile;
  filters: Filters;
  onDim: (dim: "harness" | "provider" | "model", id: string | null) => void;
  onFilters: (next: Filters) => void;
  onClear: () => void;
}

/** the registry section's single filter surface: a pill search box. Active
 * filters render as removable gold-tinted pills (the applied cue); typing
 * accepts `harness:/provider:/model:/email:/platform:/free:/reciprocal:`
 * tokens — the dims resolving names and aliases exactly like the CLI flags —
 * and bare text becomes free-text search. The pills read the same state the
 * index section writes, so the two stay in lockstep. */
export function FilterBar({ registry, filters, onDim, onFilters, onClear }: FilterBarProps) {
  const [draft, setDraft] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => setDraft(filters.search ?? ""), [filters.search]);

  const applyKind = (kind: string, value: string | boolean) => {
    const next = { ...filters };
    if (kind === "harness") next.harness = typeof value === "string" ? resolveDimId(registry.harnesses, value) : null;
    else if (kind === "provider") next.provider = typeof value === "string" ? resolveDimId(registry.providers, value) : null;
    else if (kind === "model") next.model = typeof value === "string" ? resolveDimId(registry.models, value) : null;
    else if (kind === "email") next.email = typeof value === "string" ? value.toLowerCase() : null;
    else if (kind === "platform") next.platform = typeof value === "string" ? resolvePlatform(value) : null;
    else if (kind === "free") next.free = typeof value === "boolean" ? value : null;
    else if (kind === "reciprocal") next.reciprocal = typeof value === "boolean" ? value : null;
    onFilters(next);
  };

  const commitToken = (raw: string) => {
    const t = raw.trim();
    if (!t) return;
    const bar = t.indexOf(":");
    const kind = (bar === -1 ? "" : t.slice(0, bar).trim().toLowerCase());
    const rest = bar === -1 ? "" : t.slice(bar + 1).trim();
    const next = { ...filters };
    if (["harness", "h"].includes(kind) && rest) {
      const id = resolveDimId(registry.harnesses, rest);
      if (id) next.harness = id;
      else next.search = t.toLowerCase();
    } else if (["provider", "p"].includes(kind) && rest) {
      const id = resolveDimId(registry.providers, rest);
      if (id) next.provider = id;
      else next.search = t.toLowerCase();
    } else if (["model", "m"].includes(kind) && rest) {
      const id = resolveDimId(registry.models, rest);
      if (id) next.model = id;
      else next.search = t.toLowerCase();
    } else if (kind === "email" && rest) {
      next.email = rest.toLowerCase();
    } else if (kind === "platform" && rest) {
      next.platform = resolvePlatform(rest);
    } else if (["free", "paid"].includes(kind)) {
      next.free = kind === "free" ? (rest ? !["false", "no", "0"].includes(rest.toLowerCase()) : true) : false;
    } else if (kind === "reciprocal" && rest) {
      next.reciprocal = !["false", "no", "0"].includes(rest.toLowerCase());
    } else if (!bar && ["free", "paid", "reciprocal", "not-reciprocal", "notreciprocal"].includes(t.toLowerCase())) {
      const w = t.toLowerCase();
      next.free = w === "free" ? true : w === "paid" ? false : next.free;
      next.reciprocal = w === "reciprocal" ? true : w.startsWith("not") ? false : next.reciprocal;
    } else if (bar === -1) {
      next.search = t.toLowerCase();
    } else {
      // an unknown kind — treat the whole token as free text
      next.search = t.toLowerCase();
    }
    onFilters(next);
  };

  const commitDraft = () => {
    if (!draft.trim()) return;
    commitToken(draft);
    setDraft("");
  };

  const removeKey = (key: keyof Filters) => {
    const next = { ...filters, [key]: null };
    onFilters(next);
    if (key !== "search") inputRef.current?.focus();
  };

  // the dim pills resolve to display labels through the registry so a pill
  // reads "harness: Kimi Code" while filtering by the canonical id
  const label = (table: "harnesses" | "providers" | "models", id: string) =>
    registry[table].find((r) => r.id === id)?.label ?? id;
  const dimPill = (kind: string, table: "harnesses" | "providers" | "models", key: "harness" | "provider" | "model") =>
    filters[key] ? { text: `${kind}: ${label(table, filters[key]!)}`, onRemove: () => onDim(key, null) } : null;
  const pills = [
    dimPill("harness", "harnesses", "harness"),
    dimPill("provider", "providers", "provider"),
    dimPill("model", "models", "model"),
    filters.email ? { text: `email: ${filters.email}`, onRemove: () => removeKey("email") } : null,
    filters.platform ? { text: `platform: ${filters.platform}`, onRemove: () => removeKey("platform") } : null,
    filters.free != null ? { text: filters.free ? "free" : "paid", onRemove: () => removeKey("free") } : null,
    filters.reciprocal != null
      ? { text: filters.reciprocal ? "reciprocal" : "not reciprocal", onRemove: () => removeKey("reciprocal") }
      : null,
  ].filter((p): p is { text: string; onRemove: () => void } => p != null);

  // autocomplete — the draft's `kind:` prefix narrows the suggestions to that
  // kind's values (dims matching by name/label/alias slug prefix, exactly the
  // resolution the flags use); the bare keywords suggest themselves
  const suggestions = useMemo(() => {
    const t = draft.trim().toLowerCase();
    if (!t) return [];
    const bar = t.indexOf(":");
    const kind = bar > 0 ? t.slice(0, bar) : "";
    const value = bar > 0 ? t.slice(bar + 1) : "";
    const needle = slugId(value);
    const matchDim = (rules: RegistryFile["harnesses"], r: (typeof rules)[number]) =>
      !needle ||
      [r.name, r.label, r.id, r.short_title ?? "", ...r.variations].some((v) => slugId(v).startsWith(needle) || slugId(v).includes(needle));
    if (["harness", "h"].includes(kind)) return registry.harnesses.filter((r) => matchDim(registry.harnesses, r)).slice(0, 8).map((r) => ({ label: `harness: ${r.label}`, apply: () => applyKind("harness", r.name) }));
    if (["provider", "p"].includes(kind)) return registry.providers.filter((r) => matchDim(registry.providers, r)).slice(0, 8).map((r) => ({ label: `provider: ${r.label}`, apply: () => applyKind("provider", r.name) }));
    if (["model", "m"].includes(kind)) return registry.models.filter((r) => matchDim(registry.models, r)).slice(0, 8).map((r) => ({ label: `model: ${r.label}`, apply: () => applyKind("model", r.name) }));
    if (kind === "platform") return ["darwin", "macos", "linux", "windows"].filter((v) => v.startsWith(value)).map((v) => ({ label: `platform: ${v}`, apply: () => applyKind("platform", v) }));
    if (bar === -1) {
      const words: [string, () => void][] = [
        ["free", () => applyKind("free", true)],
        ["paid", () => applyKind("free", false)],
        ["reciprocal", () => applyKind("reciprocal", true)],
        ["not reciprocal", () => applyKind("reciprocal", false)],
      ];
      return words.filter(([w]) => slugId(w).startsWith(needle)).map(([w, apply]) => ({ label: w, apply }));
    }
    return [];
  }, [draft, registry, filters]);

  const [active, setActive] = useState(-1);
  useEffect(() => setActive(-1), [draft]);
  const commitSuggestion = (i: number) => {
    suggestions[i]?.apply();
    setDraft("");
    inputRef.current?.focus();
  };

  return (
    <div
      className={`flex w-full flex-wrap items-center gap-1.5 rounded-lg border bg-transparent px-2 py-1.5 transition-colors ${
        anyFilter(filters) ? "border-amber-500/60 dark:border-amber-400/50" : "border-input"
      }`}
      onClick={(e) => {
        if (e.target === e.currentTarget) inputRef.current?.focus();
      }}
    >
      {pills.map((pill) => (
        <span
          key={pill.text}
          className="inline-flex items-center gap-1 rounded-md border border-amber-500/50 bg-amber-500/10 px-1.5 py-0.5 text-xs text-amber-600 dark:text-amber-300"
        >
          {pill.text}
          <button type="button" aria-label={`remove ${pill.text}`} onClick={pill.onRemove} className="hover:text-foreground">
            <X className="size-3" />
          </button>
        </span>
      ))}
      <span className="relative flex min-w-32 flex-1 items-center">
        <input
          ref={inputRef}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown" && suggestions.length) {
              e.preventDefault();
              setActive((a) => (a + 1) % suggestions.length);
            } else if (e.key === "ArrowUp" && suggestions.length) {
              e.preventDefault();
              setActive((a) => (a <= 0 ? suggestions.length - 1 : a - 1));
            } else if (e.key === "Enter") {
              e.preventDefault();
              if (suggestions.length > 0) commitSuggestion(active >= 0 ? active : 0);
              else commitDraft();
            } else if (e.key === "Escape") {
              setActive(-1);
            } else if (e.key === "Backspace" && !draft && pills.length > 0) {
              pills[pills.length - 1].onRemove();
            }
          }}
          onBlur={commitDraft}
          placeholder={pills.length ? "add filter — harness: provider: model: email: platform: free paid reciprocal" : "search or filter — harness: provider: model: email: platform: free paid reciprocal"}
          aria-label="search or filter"
          className="w-full bg-transparent py-1 text-sm outline-none placeholder:text-muted-foreground"
        />
        {suggestions.length > 0 &&(
          <span className="absolute top-full left-0 z-30 mt-1 flex w-64 flex-col rounded-lg border bg-background shadow-md">
            {suggestions.map((s2, i) => (
              <button
                key={s2.label}
                type="button"
                onMouseDown={(e) => {
                  e.preventDefault(); // keep the input's focus
                  commitSuggestion(i);
                }}
                onMouseEnter={() => setActive(i)}
                className={`px-3 py-1.5 text-left text-sm ${i === active ? "bg-muted" : ""}`}
              >
                {s2.label}
              </button>
            ))}
          </span>
        )}
      </span>
      {anyFilter(filters) && (
        <button
          type="button"
          aria-label="clear all filters"
          title="clear all filters"
          onClick={onClear}
          className="text-muted-foreground hover:text-foreground mr-1"
        >
          <X className="size-4" />
        </button>
      )}
    </div>
  );
}
