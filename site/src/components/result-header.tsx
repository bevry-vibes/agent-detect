import { useEffect, useState } from "react";
import { ArrowLeft, ExternalLink } from "lucide-react";

import { Button } from "@/components/ui/button";

/** the one top row every result page renders — back to homepage on the left,
 * the page's identity centered (a 1fr/auto/1fr grid, so it centers regardless
 * of the side widths), its raw JSON link on the right with the icon trailing
 * the text. Below 560px the sides collapse to their icons — the label words
 * would not fit beside a long id — and the whole line shrinks as one, so the
 * identity always fits at full: the ids are never truncated, here or in the
 * cards. The row is the `[container-type:inline-size]` container the formula
 * reads (sans ≈ 0.55em/char, mono ≈ 0.62em/char; chrome ≈ 100px with the
 * label words, ≈ 80px icon-only). */
export function ResultHeader({ id, mono, rawHref, onHome }: { id: string; mono?: string; rawHref: string; onHome: () => void }) {
  const [narrow, setNarrow] = useState(() => window.innerWidth < 560);
  useEffect(() => {
    const onResize = () => setNarrow(window.innerWidth < 560);
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  // the identity renders at 1.45em of the row's font — its factor carries
  // that multiplier, so the formula guarantees the full id always fits
  const k = (0.8 * id.length + (narrow ? 0 : 0.55 * 24 + 0.49 * (mono?.length ?? 0))).toFixed(2);
  const overhead = narrow ? 80 : 100;
  return (
    // the container is the wrapper: an element's own font-size cannot query
    // itself — cqw would fall through to the viewport
    <div className="[container-type:inline-size]">
      <div
        className="grid grid-cols-[1fr_minmax(0,auto)_1fr] items-center gap-3"
        style={{ fontSize: `min(14px, max(6px, (100cqw - ${overhead}px) / ${k}))` }}
      >
      <Button
        variant="outline"
        size="sm"
        aria-label="back to homepage"
        title="back to homepage"
        className="justify-self-start gap-[0.4em] text-[1em]"
        onClick={onHome}
      >
        <ArrowLeft className="size-[1.2em]" />
        {!narrow && <span>back to homepage</span>}
      </Button>
      <span className="flex min-w-0 items-baseline justify-center gap-x-3">
        <h1 title={id} className="min-w-0 whitespace-nowrap text-[1.45em] font-semibold tracking-tight">
          {id}
        </h1>
        {mono && !narrow && <span className="shrink-0 text-muted-foreground font-mono text-[0.79em]">{mono}</span>}
      </span>
      <a
        href={rawHref}
        target="_blank"
        rel="noreferrer"
        aria-label="raw JSON"
        title="raw JSON"
        className="text-muted-foreground hover:text-foreground inline-flex shrink-0 items-center justify-self-end gap-[0.4em] whitespace-nowrap text-[1em] underline underline-offset-4"
      >
        {!narrow && <span>raw JSON</span>} <ExternalLink className="size-[1em]" />
      </a>
      </div>
    </div>
  );
}
