import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, ExternalLink } from "lucide-react";

import { formatDate } from "@/lib/utils";
import { type AgentFile, type ComboRow, type CombosFile, type FixtureOutputs, type IndexFile, type Registry } from "@/lib/registry";
import { JsonBlock } from "@/components/json-block";
import { StatusRow } from "@/components/status-row";
import { AssociationTables } from "@/components/association-tables";
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
  index: IndexFile | null;
  registry: Registry | null;
  combos: CombosFile | null;
  /** the dim rows open the entity's detail page (/model/<id> etc.) */
  onOpenEntity: (dim: "harness" | "provider" | "model", id: string) => void;
  /** a table's search icon: the registry section filtered to that context */
  onSearch: (filters: { harness: string | null; provider: string | null; model: string | null }) => void;
  onBack: () => void;
}

/** the result page — `agent: {id}` prominent over its three dims, the status
 * row, the four association tables filtered to the combo (its dims and the
 * agent are the gold self cards, each with a back arrow), then the declared
 * fixtures' outputs. */
export function AgentPage({ row, agentId, index, registry, combos, onOpenEntity, onSearch, onBack }: AgentPageProps) {
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

  const sortedFixtures = useMemo(
    () => (file ? [...file.fixtures].sort((a, b) => b.updated_at - a.updated_at) : null),
    [file],
  );

  const dims = row ? { h: row.harness, p: row.provider, m: row.model } : { h: "", p: "", m: "" };

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
        <header className="flex flex-col gap-1">
          <h1 className="font-mono text-2xl font-bold tracking-tight">
            <span className="text-muted-foreground">agent:</span> {row.agent_id}
          </h1>
          {(["harness", "provider", "model"] as const).map((dim) => {
            const id = row[dim];
            return (
              <a
                key={dim}
                href={`/${dim}/${id}`}
                title={`open the ${dim} detail page (${dim}/${id})`}
                onClick={(e) => {
                  e.preventDefault();
                  onOpenEntity(dim, id);
                }}
                className="hover:bg-muted/50 -mx-1 flex min-w-0 items-baseline gap-1 rounded-md px-1 py-0.5 text-sm transition-colors"
              >
                <span className="text-muted-foreground">{dim}:</span>
                <span className="font-mono underline-offset-4 hover:underline">{id}</span>
              </a>
            );
          })}
        </header>
      )}

      {row && error && (
        <p className="text-destructive text-sm">
          failed to load the result JSON: {error} — the fixture may not be deployed yet
        </p>
      )}
      {row && !error && !file && <p className="text-muted-foreground text-sm">loading result JSON…</p>}

      {row && (
        <div className="[container-type:inline-size]">
          <StatusRow row={row} dims={dims} />
        </div>
      )}

      {row && index && registry && combos && (
        <AssociationTables
          page={{ harness: row.harness, provider: row.provider, model: row.model }}
          self={{ harness: row.harness, provider: row.provider, model: row.model, agent: row.agent_id }}
          index={index}
          registry={registry}
          combos={combos}
          onOpenEntity={onOpenEntity}
          onOpenAgent={onBack}
          onSearch={onSearch}
          onBack={onBack}
        />
      )}

      {row && !error && file && sortedFixtures && sortedFixtures.length > 0 && (
        <div className="flex flex-col gap-5">
          {sortedFixtures.map((f) => (
            <FixtureDetail key={f.id} fixture={f} dims={dims} />
          ))}
        </div>
      )}
    </main>
  );
}
