import { useMemo, useState } from "react";
import { Check, ChevronsUpDown } from "lucide-react";

import { ruleKeywords, type Rule } from "@/lib/registry";
import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";

export interface DimComboboxProps {
  /** the filter's display name, e.g. "Harness" */
  label: string;
  /** the selected rule's strict-slug id, or null */
  value: string | null;
  rules: Rule[];
  /** combo count per rule id, for the option badges */
  counts: Record<string, number>;
  onChange: (id: string | null) => void;
}

/** one searchable filter dropdown — the URL carries the strict-slug id, the
 * search matches every alias the CLI flag resolution accepts */
export function DimCombobox({ label, value, rules, counts, onChange }: DimComboboxProps) {
  const [open, setOpen] = useState(false);
  const selected = useMemo(() => rules.find((r) => r.id === value) ?? null, [rules, value]);
  const sorted = useMemo(() => [...rules].sort((a, b) => a.label.localeCompare(b.label)), [rules]);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          role="combobox"
          aria-expanded={open}
          aria-label={`filter by ${label}`}
          className="h-10 w-full justify-between px-3 font-normal"
        >
          <span className="flex min-w-0 flex-col items-start leading-tight">
            <span className="text-muted-foreground text-[10px] font-medium uppercase tracking-wide">{label}</span>
            <span className="truncate text-sm">
              {selected ? (
                <>
                  {selected.label} <span className="text-muted-foreground font-mono text-xs">{selected.id}</span>
                </>
              ) : (
                <span className="text-muted-foreground">any {label.toLowerCase()}</span>
              )}
            </span>
          </span>
          <ChevronsUpDown className="shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-(--radix-popover-trigger-width) p-0" align="start">
        <Command>
          <CommandInput placeholder={`search ${label.toLowerCase()} — names, labels, aliases…`} />
          <CommandList>
            <CommandEmpty>no rule matches — it may exist upstream but not in this registry</CommandEmpty>
            <CommandGroup>
              <CommandItem
                value="␀clear"
                onSelect={() => {
                  onChange(null);
                  setOpen(false);
                }}
              >
                <Check className={cn(!value ? "opacity-100" : "opacity-0")} />
                <span className="text-muted-foreground">any {label.toLowerCase()}</span>
              </CommandItem>
              {sorted.map((rule) => (
                <CommandItem
                  key={rule.id}
                  value={rule.id}
                  keywords={[...ruleKeywords(rule), String(counts[rule.id] ?? 0)]}
                  onSelect={() => {
                    onChange(rule.id === value ? null : rule.id);
                    setOpen(false);
                  }}
                >
                  <Check className={cn(rule.id === value ? "opacity-100" : "opacity-0")} />
                  <span className="flex min-w-0 flex-1 flex-col">
                    <span className="truncate">{rule.label}</span>
                    <span className="text-muted-foreground truncate font-mono text-xs">{rule.name}</span>
                  </span>
                  <Badge variant="secondary" className="ml-auto tabular-nums">
                    {counts[rule.id] ?? 0}
                  </Badge>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
