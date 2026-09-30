import { Check } from "lucide-react";

import { formatDate } from "@/lib/utils";
import { useCopied } from "@/lib/use-copied";
import { type ComboRow } from "@/lib/registry";
import { Badge } from "@/components/ui/badge";

/** the combo's status triplet on ONE line — reciprocal verdict (clicking it
 * copies the check-reciprocal invocation), the plain platform pills of the
 * observed declarations (static; nothing here navigates), and the result date.
 * The parent must establish a `[container-type:inline-size]` container: the
 * line shrinks with the viewport instead of ever wrapping (the cards' id-line
 * technique — mono ≈ 0.6em/char, sans ≈ 0.55em/char). */
export function StatusRow(
  { row, dims, className = "" }: { row: ComboRow; dims: { h: string; p: string; m: string }; className?: string },
) {
  const { copied, copy } = useCopied();
  const command = `agent-detect check-reciprocal --harness=${dims.h} --provider=${dims.p} --model=${dims.m}`;
  const reciprocalText = copied ? "command copied" : row.reciprocal ? "reciprocal" : "not reciprocal";
  const date = formatDate(row.updated_at);
  const pillsText = row.platforms.join("");
  // the text scales with the font; the chrome does not — badge/border padding
  // (~14px per pill), the pill gaps, the reciprocal button's padding, and the
  // two justify-between gaps are all fixed overhead the line must also fit
  const n = row.platforms.length;
  const overhead = 18 + 14 * n + 4 * Math.max(0, n - 1) + 16;
  const k = (0.55 * reciprocalText.length + 0.6 * pillsText.length + 0.55 * date.length).toFixed(2);
  return (
    <div
      className={`flex items-center justify-between gap-2 whitespace-nowrap ${className}`}
      style={{ fontSize: `min(13px, max(8px, (100cqw - ${overhead}px) / ${k}))` }}
    >
      <button
        type="button"
        title={`copy: ${command}`}
        onClick={() => copy(command)}
        className={`inline-flex shrink-0 items-center gap-1.5 rounded-md border px-2 py-1 font-medium transition-colors ${
          row.reciprocal
            ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
            : "border-red-500/40 bg-red-500/10 text-red-600 dark:text-red-400"
        }`}
      >
        {copied && <Check className="size-3.5" />}
        {reciprocalText}
      </button>
      <span className="flex min-w-0 items-center gap-1">
        {row.platforms.map((p) => (
          <Badge key={p} variant="secondary" className="px-1.5 py-0 font-mono">
            {p}
          </Badge>
        ))}
      </span>
      <span title={`result generated ${new Date(row.updated_at * 1000).toISOString()}`} className="shrink-0 font-mono text-muted-foreground">
        {date}
      </span>
    </div>
  );
}
