import { type AgentRow } from "@/lib/registry";
import { StatusRow } from "@/components/status-row";

/** the one agent card body the homepage's agents table and the association
 * tables' agent rows both render: the agent id in white — shrinking with the
 * card, never truncating (sans ≈ 0.56em/char) — over the status line
 * (reciprocal verdict · platform pills · updated date). The body span is the
 * `[container-type:inline-size]` container on purpose: its content box is
 * exactly the line's available width, so `100cqw` never counts the card
 * padding. The status line's copy button stops propagation so a click copies
 * without firing the card's own click. */
export function AgentCardBody({ agentId, row }: { agentId: string; row: AgentRow }) {
  return (
    <span className="flex min-w-0 flex-1 flex-col gap-1 px-2 py-1.5 text-left [container-type:inline-size]">
      <span
        className="min-w-0 whitespace-nowrap font-medium"
        style={{ fontSize: `min(14px, max(8px, 100cqw / ${(0.56 * agentId.length).toFixed(2)}))` }}
      >
        {agentId}
      </span>
      <span className="block min-w-0 overflow-hidden">
        <StatusRow row={row} dims={{ h: row.harness, p: row.provider, m: row.model }} />
      </span>
    </span>
  );
}
