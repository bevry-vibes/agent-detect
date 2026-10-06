import { useEffect, useMemo, useState } from "react";
import { ArrowLeft } from "lucide-react";

import { formatDate } from "@/lib/utils";
import { type IdentityFile, type AgentRow, type AgentsFile, type FixtureOutputs, type IndexDataFile, type RegistryFile } from "@/lib/registry";
import { JsonBlock } from "@/components/json-block";
import { ResultHeader } from "@/components/result-header";
import { AssociationTables } from "@/components/association-tables";
import { Button } from "@/components/ui/button";

/** the stderr keys and the command whose block they render under — each
 * stderr travels with the output it belongs to, not in whatever spot the
 * capture recorded it */
const STDERR_PARENT: Record<string, string> = {
  "identify.stderr": "identify",
  "explain.stderr": "explain",
  "check-reciprocal.stderr": "check-reciprocal",
};

/** the outputs in the fixture file's own order, each stderr block directly
 * after the command that prints it. (A few exit-9 captures recorded
 * identify.stderr after explain — identify printed no stdout, so the capture
 * order drifted; attaching fixes those.) A stderr whose command printed no
 * stdout at all (check-reciprocal on the stderr-only states) keeps its
 * fixture-file position. */
function sectionsFor(outputs: FixtureOutputs): { title: string; value: unknown }[] {
  const entries = Object.entries(outputs).filter(([, v]) => v !== undefined);
  const sections: { title: string; value: unknown }[] = [];
  for (const [key, value] of entries) {
    if (key === "raw" && outputs.found !== undefined) continue; // the found rename — show only the current key
    if (STDERR_PARENT[key]) continue; // emitted below, attached to its command
    sections.push({ title: key, value });
    for (const [stderrKey, stderrValue] of entries) {
      if (STDERR_PARENT[stderrKey] === key) sections.push({ title: stderrKey, value: stderrValue });
    }
  }
  for (const [key, value] of entries) {
    const parent = STDERR_PARENT[key];
    if (parent && outputs[parent] === undefined) sections.push({ title: key, value });
  }
  return sections;
}

/** per-session cache — revisiting an agent (back/forward) renders instantly */
const fileCache = new Map<string, IdentityFile>();

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

function FixtureDetail({ file, dims }: { file: IdentityFile; dims: { h: string; p: string; m: string } }) {
  const sections = useMemo(() => sectionsFor(file.outputs), [file]);
  const meta: Record<string, unknown> = { ...file.meta, updated_at: formatDate(file.meta.updated_at) };
  const bin = "./agent-detect";
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
      {!file.outputs.explain && (
        <p className="text-muted-foreground rounded-lg border border-dashed px-3 py-2 text-xs">
          no explain recorded for this fixture
        </p>
      )}
      <JsonBlock title="meta" value={meta} />
    </div>
  );
}

interface AgentPageProps {
  row: AgentRow | null;
  agentId: string;
  index: IndexDataFile | null;
  registry: RegistryFile | null;
  combos: AgentsFile | null;
  /** the dim rows open the entity's detail page (/model/<id> etc.) */
  onOpenEntity: (dim: "harness" | "provider" | "model", id: string) => void;
  /** a table's search icon: the registry section filtered to that context */
  onSearch: (filters: { harness: string | null; provider: string | null; model: string | null }) => void;
  /** the top-left button: to the homepage (the locked cards' own buttons go
   * back to the prior page instead) */
  onHome: () => void;
}

/** the result page — `agent: {id}` prominent over its three dims, the four
 * association tables filtered to the combo (its dims and the agent are the
 * gold self cards, each body acting like its action icon), then the declared
 * fixtures' outputs. */
export function AgentPage({ row, agentId, index, registry, combos, onOpenEntity, onSearch, onHome }: AgentPageProps) {
  const [file, setFile] = useState<IdentityFile | null>(() => fileCache.get(agentId) ?? null);
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
        return (await res.json()) as IdentityFile;
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

  const dims = row ? { h: row.harness, p: row.provider, m: row.model } : { h: "", p: "", m: "" };

  return (
    <main className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-5 px-4 py-6">
      {row && <ResultHeader id={row.agent_id} rawHref={`/agent/${row.agent_id}.json`} onHome={onHome} />}

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
          <Button variant="outline" size="sm" className="mt-4" onClick={onHome}>
            <ArrowLeft className="size-4" /> back to homepage
          </Button>
        </div>
      )}

      {row && error && (
        <p className="text-destructive text-sm">
          failed to load the result JSON: {error} — the fixture may not be deployed yet
        </p>
      )}
      {row && !error && !file && <p className="text-muted-foreground text-sm">loading result JSON…</p>}

      {row && index && registry && combos && (
        <AssociationTables
          page={{ harness: row.harness, provider: row.provider, model: row.model }}
          highlight={{ harness: row.harness, provider: row.provider, model: row.model }}
          selfBack={{ agent: row.agent_id }}
          index={index}
          registry={registry}
          combos={combos}
          onOpenEntity={onOpenEntity}
          onOpenAgent={onHome}
          onSearch={onSearch}
          onBackSelf={() => window.history.back()}
        />
      )}

      {row && !error && file && <FixtureDetail file={file} dims={dims} />}
    </main>
  );
}
