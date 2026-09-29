import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, ExternalLink } from "lucide-react";

import { formatDate } from "@/lib/utils";
import { type AgentFile, type ComboRow, type FixtureOutputs } from "@/lib/registry";
import { JsonBlock } from "@/components/json-block";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

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

function FixtureDetail({ fixture }: { fixture: AgentFile["fixtures"][number] }) {
  const sections = useMemo(() => sectionsFor(fixture.outputs), [fixture]);
  const meta: Record<string, unknown> = { ...fixture.meta, updated_at: formatDate(fixture.updated_at) };
  return (
    <div className="flex flex-col gap-3">
      {sections.map((s) => (
        <JsonBlock key={s.title} title={s.title} value={s.value} />
      ))}
      <JsonBlock title="meta" value={meta} />
    </div>
  );
}

interface AgentPageProps {
  row: ComboRow | null;
  agentId: string;
  onBack: () => void;
}

/** the full-page replacement for an agent combo — the result JSON (identify,
 * both trailers, explain, and the rest of the recorded outputs), one tab per
 * platform × channel fixture. The index stays one back-button away. */
export function AgentPage({ row, agentId, onBack }: AgentPageProps) {
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
    window.scrollTo(0, 0);
  }, []);

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
          <div className="flex flex-wrap items-center gap-2">
            <Badge
              variant={row.reciprocal ? "outline" : "destructive"}
              className={row.reciprocal ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400" : undefined}
            >
              {row.reciprocal ? "reciprocal" : "not reciprocal"}
            </Badge>
            {row.state && row.state !== "reciprocal" && row.state !== "not-reciprocal" && (
              <Badge variant="outline" className="text-muted-foreground">
                {row.state}
              </Badge>
            )}
            <Badge variant="secondary" className="font-mono text-[10px]">
              {row.harness}
            </Badge>
            <Badge variant="secondary" className="font-mono text-[10px]">
              {row.provider}
            </Badge>
            <Badge variant="secondary" className="font-mono text-[10px]">
              {row.model}
            </Badge>
            {row.platforms.map((p) => (
              <Badge key={p} variant="outline" className="font-mono text-[10px]">
                {p}
              </Badge>
            ))}
            <span className="text-muted-foreground font-mono text-xs">{formatDate(row.updated_at)}</span>
          </div>
          <p className="text-muted-foreground font-mono text-xs">{row.email}</p>
        </header>
      )}

      {row && error && (
        <p className="text-destructive text-sm">
          failed to load the result JSON: {error} — the fixture may not be deployed yet
        </p>
      )}
      {row && !error && !file && <p className="text-muted-foreground text-sm">loading result JSON…</p>}
      {row && file && (
        <Tabs defaultValue={file.fixtures[0] ? `${file.fixtures[0].platform}:${file.fixtures[0].channel}` : undefined}>
          <TabsList className="flex-wrap">
            {file.fixtures.map((f) => (
              <TabsTrigger key={f.id} value={`${f.platform}:${f.channel}`}>
                <span className="font-mono text-xs">
                  {f.platform} · {f.channel === "capture" ? "captured" : "declared"}
                </span>
              </TabsTrigger>
            ))}
          </TabsList>
          {file.fixtures.map((f) => (
            <TabsContent key={f.id} value={`${f.platform}:${f.channel}`}>
              <FixtureDetail fixture={f} />
            </TabsContent>
          ))}
        </Tabs>
      )}
    </main>
  );
}
