import { Terminal } from "lucide-react";

import type { Registry } from "@/lib/registry";
import { CodeLine } from "@/components/json-block";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

const INSTALL_SH =
  "curl -fLo agent-detect https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-linux-x86_64\nchmod +x agent-detect";
const INSTALL_PS = "Invoke-WebRequest https://github.com/bevry-vibes/agent-detect/releases/latest/download/agent-detect-windows-x86_64.exe -OutFile agent-detect.exe";

const USAGE: { code: string; what: string }[] = [
  { code: "./agent-detect identify", what: "machine-readable JSON report of the current agent (harness, provider, model)" },
  { code: "./agent-detect check-reciprocal", what: '"is reciprocal" (0) or "not reciprocal" (10) — the reciprocity compliance verdict' },
  { code: 'git commit --trailer "$(./agent-detect trailer co-author)"', what: "the Co-authored-by trailer for git commits" },
  { code: 'git commit --trailer "$(./agent-detect trailer assisted-by)"', what: "the Assisted-by trailer for issues, PRs, discussions, comments" },
  { code: "./agent-detect explain", what: "why the verdict resolved as it did — reasons, judged values, remediation actions" },
  { code: "./agent-detect found", what: "what the detection ladder observed on this machine — the observation trail" },
];

export function Hero({ registry, combos, fixtures }: { registry: Registry; combos: number; fixtures: number }) {
  return (
    <section className="border-b">
      <div className="mx-auto max-w-7xl px-4 py-10">
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">
          The agent identity registry
        </h1>
        <p className="text-muted-foreground mt-3 max-w-3xl text-base sm:text-lg">
          <strong className="text-foreground">agent-detect</strong> infers the current AI agent's{" "}
          <em>harness</em>, <em>provider</em>, and <em>model</em> — multi-harness, multi-OS, multi-arch — so agents can
          identify themselves accurately, as required by various AI policies and skills.
        </p>
        <p className="text-muted-foreground mt-2 max-w-3xl text-sm">
          It enables policy compliance checks (<code className="font-mono">check-reciprocal</code>), attribution trailers
          for commits and issue posts, and failure introspection (<code className="font-mono">explain</code>,{" "}
          <code className="font-mono">found</code>). Every combo below is backed by a declared or live-captured fixture.
        </p>
        <div className="mt-4 flex flex-wrap gap-2">
          <Badge variant="secondary">{registry.counts.harnesses} harnesses</Badge>
          <Badge variant="secondary">{registry.counts.providers} providers</Badge>
          <Badge variant="secondary">{registry.counts.models} models</Badge>
          <Badge variant="secondary">{combos} combos</Badge>
          <Badge variant="secondary">{fixtures} fixtures</Badge>
          <Badge variant="outline">no network I/O at detection time</Badge>
        </div>

        <div className="mt-8 grid gap-4 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <Terminal className="size-4" /> Install
              </CardTitle>
              <CardDescription>
                Prebuilt static binaries on the{" "}
                <a
                  className="underline underline-offset-4"
                  href="https://github.com/bevry-vibes/agent-detect/releases/latest"
                  target="_blank"
                  rel="noreferrer"
                >
                  releases page
                </a>{" "}
                — no npm/crates package exists. The optional <code className="font-mono">sqlite3</code> CLI is only
                needed for live detection inside some harnesses.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Tabs defaultValue="sh">
                <TabsList className="mb-2">
                  <TabsTrigger value="sh">sh (linux, macos)</TabsTrigger>
                  <TabsTrigger value="powershell">powershell (windows)</TabsTrigger>
                </TabsList>
                <TabsContent value="sh" className="flex flex-col gap-2">
                  {INSTALL_SH.split("\n").map((line) => (
                    <CodeLine key={line} code={line} />
                  ))}
                </TabsContent>
                <TabsContent value="powershell">
                  <CodeLine code={INSTALL_PS} />
                </TabsContent>
              </Tabs>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <Terminal className="size-4" /> Use
              </CardTitle>
              <CardDescription>click a line to copy it — exactly one trailer per artifact, never both</CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-2">
              {USAGE.map((u) => (
                <div key={u.code} className="flex flex-col gap-1">
                  <CodeLine code={u.code} />
                  <p className="text-muted-foreground pl-1 text-xs">{u.what}</p>
                </div>
              ))}
            </CardContent>
          </Card>
        </div>
      </div>
    </section>
  );
}
