import { Badge } from "@/components/ui/badge";

/** what each index/association policy badge means — the training axes are the
 * two sides of the reciprocity question: does the entity use your data to
 * train OPEN-weight models (informational) or CLOSED API models (the axis
 * that gates reciprocity); a license/openness badge states its value's own
 * meaning */
export function policyTitle(b: string): string {
  if (b.startsWith("open: ")) return `open-model training: ${b.slice(6)} — whether the entity uses your data to train open-weight models (informational; never gates reciprocity)`;
  if (b.startsWith("closed: ")) return `closed-model training: ${b.slice(8)} — whether the entity uses your data to train closed (API) models: enforced = no opt-out, opt-out = trains by default, opt-in = off by default, never = verified never, NOASSERTION = researched, inconclusive; this axis gates reciprocity`;
  if (b === "scandal") return "reciprocity scandal — implicated by a court, regulator, official report, or wire-capture finding (the fair-use purpose test)";
  if (b === "license: NONE") return "license: verified none granted (closed source)";
  if (b === "license: NOASSERTION") return "license: exists but custom/non-SPDX, or researched without conclusion";
  if (b.startsWith("license: ")) return `license: ${b.slice(9)} — the SPDX license id`;
  if (b === "openness: closed") return "openness: closed — API-only, no weights published";
  if (b.startsWith("openness: open-")) return `${b} — the weights are published under this tier`;
  if (b.startsWith("openness: ")) return `${b} — the weights' openness tier`;
  return b;
}

/** the good/bad spectrum a badge's value sits on — the same green/amber/red
 * vocabulary the reciprocal verdict uses; null = no verdict (researched
 * without conclusion), which stays untinted */
function tone(b: string): "good" | "mid" | "bad" | null {
  if (b === "scandal") return "bad";
  if (b.startsWith("license: ")) {
    const v = b.slice(9);
    if (v === "NONE") return "bad";
    if (v === "NOASSERTION") return null;
    return "good";
  }
  if (b.startsWith("openness: ")) {
    const v = b.slice(10);
    if (v === "closed") return "bad";
    if (v.startsWith("open-")) return "good";
    return "mid";
  }
  if (b.startsWith("open: ") || b.startsWith("closed: ")) {
    const v = b.slice(b.indexOf(": ") + 2);
    if (v === "never") return "good";
    if (v === "enforced") return "bad";
    if (v === "opt-out" || v === "opt-in") return "mid";
    return null;
  }
  return null;
}

const TONE_CLASS: Record<"good" | "mid" | "bad", string> = {
  good: "border-emerald-500/40 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400",
  mid: "border-amber-500/40 bg-amber-500/10 text-amber-600 dark:text-amber-400",
  bad: "border-red-500/40 bg-red-500/10 text-red-600 dark:text-red-400",
};

/** a policy badge — coloured on the good/bad spectrum, with the value's
 * explanation on hover */
export function PolicyBadge({ badge }: { badge: string }) {
  const t = tone(badge);
  return (
    <Badge variant="outline" title={policyTitle(badge)} className={`cursor-help px-1 py-0 text-[10px] ${t ? TONE_CLASS[t] : ""}`}>
      {badge}
    </Badge>
  );
}
