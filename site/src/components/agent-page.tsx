import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, ExternalLink, Filter } from "lucide-react";

import { formatDate } from "@/lib/utils";
import { useCopied } from "@/lib/use-copied";
import { type AgentFile, type ComboRow, type FixtureOutputs, type Registry } from "@/lib/registry";
import { JsonBlock } from "@/components/json-block";
import { StatusRow } from "@/components/status-row";
import { Button } from "@/components/ui/button";

const SECTION_ORDER = ["identify", "trailer co-author", "trailer assisted-by", "explain", "found", "raw", "check-reciprocal"] as const;

function sectionsFor(outputs: FixtureOutputs): { title: string; value: unknown }[] {
  const sections: { title: string; value: unknown }[] = [];
  for (const key of SECTION_ORDER) {
    if (key === "raw" && outputs.found) continue; // the found rename — show only the current key
    if (key in outputs && outputs[key] !== undefined) sections.push({ title: key, value: outputs[key] });
  }
  for (const [key, value] of Object.entries(outputs)) {
    if ((SECTION_ORDER as readonly string[]).includes(key)) continue;
    sections.push({ title: key, value });
  }
  return sections;
}

/** per-session cache — revisiting an agent (back/forward) renders instantly */
const fileCache = new Map<string, AgentFile>();

/** the CLI invocations each result block corresponds to — recipe actions take
 * the combo flags, the trailers take none */
const RECIPE_ACTIONS: Record<string, string> = {
  identify: "identify",
  explain: "explain",
  found: "found",
  "check-reciprocal": "check-reciprocal",
};
const TRAILER_ACTIONS: Record<string, string> = {
  "trailer co-author": "trailer co-author",
  "trailer assisted-by": "trailer assisted-by",
};

function FixtureDetail({ fixture, dims }: { fixture: AgentFile["fixtures"][number]; dims: { h: string; p: string; m: string } }) {
  const sections = useMemo(() => sectionsFor(fixture.outputs), [fixture]);
  const meta: Record<string, unknown> = { ...fixture.meta, updated_at: formatDate(fixture.updated_at) };
  const bin = fixture.platform === "windows" ? ".\\agent-detect.exe" : "./agent-detect";
  const commandFor = (title: string) => {
    if (RECIPE_ACTIONS[title])
      return `${bin} ${RECIPE_ACTIONS[title]} --harness=${dims.h} --provider=${dims.p} --model=${dims.m}`;
    if (TRAILER_ACTIONS[title]) return `${bin} ${TRAILER_ACTIONS[title]}`;
    return undefined;
  };
  return (
    <div className="flex flex-col gap-3">
      {sections.map((s) => (
        <JsonBlock key={s.title} title={s.title} value={s.value} command={commandFor(s.title)} />
      ))}
      {!fixture.outputs.explain && (
        <p className="text-muted-foreground rounded-lg border border-dashed px-3 py-2 text-xs">
          no explain recorded for this fixture
        </p>
      )}
      <JsonBlock title="meta" value={meta} />
    </div>
  );
}

interface AgentPageProps {
  row: ComboRow | null;
  agentId: string;
  /** the rule registry — resolves the dims' display titles (null while loading) */
  registry: Registry | null;
  /** the dim rows open the entity's detail page (/model/<id> etc.) */
  onOpenEntity: (dim: "harness" | "provider" | "model", id: string) => void;
  /** the filter-agents pill applies the combo's three dims as index filters
   * and lands on the index anchor, where the applied filters are visible */
  onFilterAgents: (h: string, p: string, m: string) => void;
  onBack: () => void;
}

// the combo dimensions as rich `type title id` entries linking to the
// filtered index — the same format the index cards use
const DIM_ENTRIES = [
  { label: "harness", dim: "harness", table: "harnesses", field: "harness" },
  { label: "provider", dim: "provider", table: "providers", field: "provider" },
  { label: "model", dim: "model", table: "models", field: "model" },
] as const;

function DimEntries({
  row,
  registry,
  onOpenEntity,
}: {
  row: ComboRow;
  registry: Registry | null;
  onOpenEntity: AgentPageProps["onOpenEntity"];
}) {
  return (
    <nav aria-label="combo dimensions" className="flex flex-col gap-1">
      {DIM_ENTRIES.map(({ label, dim, table, field }) => {
        const id = row[field];
        const title = registry?.[table].find((r) => r.id === id)?.label ?? id;
        const href = `/${dim}/${id}`;
        return (
          <a
            key={dim}
            href={href}
            title={`open the ${dim} detail page (${dim}/${id})`}
            onClick={(e) => {
              e.preventDefault();
              onOpenEntity(dim, id);
            }}
            className="hover:bg-muted/50 -mx-1 flex min-w-0 items-baseline gap-2 rounded-md px-1 py-0.5 transition-colors"
          >
            <span className="text-muted-foreground w-16 shrink-0 text-right text-[10px] font-medium uppercase tracking-wide">
              {label}
            </span>
            <span className="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-2">
              <span className="text-sm font-medium underline-offset-4 hover:underline">{title}</span>
              <span className="text-muted-foreground font-mono text-[11px]">{id}</span>
            </span>
          </a>
        );
      })}
    </nav>
  );
}

/** the full-page replacement for an agent combo — the from-identity results
 * only, one section per declared platform (pill heading = the platform name,
 * nothing clickable), newest first. The status row reads
 * `reciprocal · platforms · date` on a single shrinking line. The registry
 * stays one back-button away. */
export function AgentPage({ row, agentId, registry, onOpenEntity, onFilterAgents, onBack }: AgentPageProps) {
  const [file, setFile] = useState<AgentFile | null>(() => fileCache.get(agentId) ?? null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const cached = fileCache.get(agentId);
    setFile(cached ?? null);
    setError(null);
    if (cached) return;
    let alive = true;
    fetch(`/data/agents/${agentId}.json`)
      .then(async (res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return (await res.json()) as AgentFile;
      })
      .then((f) => {
        fileCache.set(agentId, f);
        if (alive) setFile(f);
      })
      .catch((err) => {
        if (alive) setError(String(err));
      });
    return () => {
      alive = false;
    };
  }, [agentId]);

  useEffect(() => {
    window.scrollTo({ top: 0, behavior: "instant" });
  }, []);

  // one section per declared platform, newest first — the identity channel is
  // all the site shows (from-capture stays maintainer-side)
  const sortedFixtures = useMemo(
    () => (file ? [...file.fixtures].sort((a, b) => b.updated_at - a.updated_at) : null),
    [file],
  );

  return (
    <main className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-5 px-4 py-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <Button variant="outline" size="sm" className="gap-1.5" onClick={onBack}>
          <ArrowLeft className="size-4" /> back to results
        </Button>
        {row && (
          <a
            href={`/identify/${row.agent_id}.json`}
            target="_blank"
            rel="noreferrer"
            className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1 text-xs underline underline-offset-4"
          >
            <ExternalLink className="size-3" /> raw JSON
          </a>
        )}
      </div>

      {!row && (
        <div className="rounded-xl border p-6">
          <h1 className="font-mono text-lg font-semibold">{agentId}</h1>
          <p className="text-muted-foreground mt-2 text-sm">
            unknown agent — it has no fixture. See{" "}
            <a className="underline underline-offset-4" href="/index.json">
              /index.json
            </a>{" "}
            for the valid agent_ids.
          </p>
          <Button variant="outline" size="sm" className="mt-4" onClick={onBack}>
            <ArrowLeft className="size-4" /> back to results
          </Button>
        </div>
      )}

      {row && (
        <header className="flex flex-col gap-3">
          <h1 className="font-mono text-xl font-semibold tracking-tight">{row.agent_id}</h1>
          <DimEntries row={row} registry={registry} onOpenEntity={onOpenEntity} />
          <div>
            <button
              type="button"
              title="apply this combo's harness, provider, and model as index filters"
              onClick={() => onFilterAgents(row.harness, row.provider, row.model)}
              className="hover:bg-muted/50 inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium transition-colors"
            >
              <Filter className="size-3" /> filter agents
            </button>
          </div>
        </header>
      )}

      {row && error && (
        <p className="text-destructive text-sm">
          failed to load the result JSON: {error} — the fixture may not be deployed yet
        </p>
      )}
      {row && !error && !file && <p className="text-muted-foreground text-sm">loading result JSON…</p>}
      {row && !error && file && sortedFixtures && sortedFixtures.length === 0 && (
        <p className="text-muted-foreground text-sm">no declared fixtures for this combo yet</p>
      )}
      {row && !error && file && sortedFixtures && sortedFixtures.length > 0 && (
        <div className="flex flex-col gap-5 [container-type:inline-size]">
          {/* the status line: reciprocal · platforms · date — always one line,
            shrinking with the viewport, nothing on it clickable */}
          <StatusRow row={row} dims={{ h: row.harness, p: row.provider, m: row.model }} />
          {sortedFixtures.map((f) => (
            <section key={f.id} className="flex flex-col gap-3">
              <div className="flex items-center gap-2">
                <span
                  title={`declared ${new Date(f.updated_at * 1000).toISOString()}`}
                  className="text-muted-foreground rounded-md border bg-muted/50 px-2 py-1 font-mono text-xs"
                >
                  {f.platform}
                </span>
              </div>
              <FixtureDetail fixture={f} dims={{ h: row.harness, p: row.provider, m: row.model }} />
            </section>
          ))}
        </div>
      )}
    </main>
  );
}
