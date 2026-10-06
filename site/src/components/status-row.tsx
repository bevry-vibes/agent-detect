import { Check } from "lucide-react";

import { formatDate } from "@/lib/utils";
import { useCopied } from "@/lib/use-copied";
import { type AgentRow } from "@/lib/registry";
import { Badge } from "@/components/ui/badge";

/** the combo's status line — the coloured reciprocal verdict (clicking it
 * copies the check-reciprocal invocation) with the free-axis pill beside it,
 * the platform pills of the observed declarations, and the result date. The
 * three groups sit in a 1fr/auto/1fr grid so the pills always start at the
 * card's center regardless of the verdict's or the date's width; the pills
 * share one size, and every group scales with the font — the pills' padding
 * is em-sized — so shrinking shrinks the whole line, never one group. The
 * 10px cap is the dim cards' badge size — the tables' default pill size. The
 * parent must establish a `[container-type:inline-size]` container whose
 * content box is exactly the line's width. */
export function StatusRow(
  { row, dims, className = "" }: { row: AgentRow; dims: { h: string; p: string; m: string }; className?: string },
) {
  const { copied, copy } = useCopied();
  const command = `agent-detect check-reciprocal --harness=${dims.h} --provider=${dims.p} --model=${dims.m}`;
  const reciprocalText = copied ? "command copied" : row.reciprocal ? "reciprocal" : "not reciprocal";
  const freeText = row.free ? "free" : "paid";
  const date = formatDate(row.updated_at);
  const pillsText = row.platforms.join("");
  const n = row.platforms.length;
  // the text and the pills' em padding scale with the font; what does not is
  // the pills' borders (2px each), the pill gaps (4px), the left group's gap
  // (4px), the grid gaps (8px), and a small safety margin
  const k = 0.5 * reciprocalText.length + 0.62 * (freeText.length + pillsText.length) + 0.6 * date.length + 1.8 * (n + 2);
  const overhead = 6 * n + 26;
  return (
    <div
      className={`grid grid-cols-[1fr_auto_1fr] items-baseline gap-2 whitespace-nowrap ${className}`}
      style={{ fontSize: `min(10px, max(8px, (100cqw - ${overhead}px) / ${k.toFixed(2)}))` }}
    >
      <span className="flex shrink-0 items-baseline justify-self-start gap-1">
        <button
          type="button"
          title={`${row.reciprocal ? "passes" : "fails"} the reciprocity requirement — click to copy: ${command}`}
          onClick={(e) => {
            // the card hosting this line is itself clickable (the agents
            // tables) — copying must not also fire the card's click
            e.stopPropagation();
            copy(command);
          }}
          className={`inline-flex shrink-0 cursor-help items-center gap-[0.4em] rounded-md border px-[0.9em] py-[0.15em] font-medium transition-colors ${
            row.reciprocal
              ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
              : "border-red-500/40 bg-red-500/10 text-red-600 dark:text-red-400"
          }`}
        >
          {copied && <Check className="size-[1em]" />}
          {reciprocalText}
        </button>
        <span
          title="the free axis — whether the combo's provider-model cell is in its provider's free tier"
          className="inline-flex shrink-0 cursor-help items-center rounded-md bg-secondary px-[0.9em] py-[0.15em] font-mono text-secondary-foreground"
        >
          {freeText}
        </span>
      </span>
      <span className="flex shrink-0 items-baseline justify-self-center gap-[0.4em]">
        {row.platforms.map((p) => (
          <Badge
            key={p}
            variant="secondary"
            title={`declared on ${p} — the combo has a from-identity fixture captured on this platform`}
            className="cursor-help px-[0.9em] py-[0.15em] font-mono text-[1em]"
          >
            {p}
          </Badge>
        ))}
      </span>
      <span
        title={`result generated ${new Date(row.updated_at * 1000).toISOString()}`}
        className="cursor-help justify-self-end shrink-0 font-mono text-muted-foreground"
      >
        {date}
      </span>
    </div>
  );
}
