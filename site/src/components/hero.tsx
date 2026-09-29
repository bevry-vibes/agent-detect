import { Mail, ScrollText, SlidersHorizontal, WifiOff } from "lucide-react";
import type { ReactNode } from "react";

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

function Feature({ icon: Icon, children }: { icon: typeof Mail; children: ReactNode }) {
  return (
    <li className="flex items-start gap-3">
      <span className="flex size-8 shrink-0 items-center justify-center rounded-md border bg-muted/50">
        <Icon className="size-4" />
      </span>
      <span className="text-muted-foreground text-sm leading-snug">{children}</span>
    </li>
  );
}

/** the cli section — the command-line tool pitch, then the install/use cards */
export function Hero() {
  return (
    <section id="cli" className="scroll-mt-14 border-b">
      <div className="mx-auto max-w-7xl px-4 py-10">
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">
          <code className="rounded-md bg-muted/60 px-2 py-0.5 font-mono text-[0.85em]">agent-detect</code> command-line tool
        </h1>
        <p className="mt-3 text-lg font-medium">Give your agent self-awareness.</p>
        <ul className="mt-4 grid gap-3 sm:grid-cols-2">
          <Feature icon={Mail}>
            Generate accurate <code className="font-mono text-[0.9em]">Co-Authored-By</code> &amp;{" "}
            <code className="font-mono text-[0.9em]">Assisted-By</code> trailers for agent-made commits and issues.
          </Feature>
          <Feature icon={SlidersHorizontal}>
            Scope rules, skills, and policies by agent harness, provider, and/or model.
          </Feature>
          <Feature icon={ScrollText}>
            Detailed training, license, and reciprocity information for policy enforcement.
          </Feature>
          <Feature icon={WifiOff}>Offline agent detection without telemetry.</Feature>
        </ul>

        <div className="mt-10 grid grid-cols-1 gap-4 lg:grid-cols-2">
          <Card id="install" className="min-w-0 scroll-mt-14">
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

          <Card id="use" className="min-w-0 scroll-mt-14">
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <Terminal className="size-4" /> Use
              </CardTitle>
              <CardDescription>click a line to copy it — exactly one trailer per artifact, never both</CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
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

/** the registry section intro — heading, contributing line, and the counts */
export function RegistryIntro({
  registry,
  combos,
  fixtures,
}: {
  registry: Registry;
  combos: number;
  fixtures: number;
}) {
  return (
    <div className="flex flex-col gap-2">
      <h2 className="text-2xl font-semibold tracking-tight">
        <code className="rounded-md bg-muted/60 px-2 py-0.5 font-mono text-[0.85em]">agent-detect</code> registry
      </h2>
      <p className="text-muted-foreground text-sm">
        Past inferences from our test suite. Missing yours,{" "}
        <a
          className="underline underline-offset-4"
          href="https://github.com/bevry-vibes/agent-detect/blob/main/CONTRIBUTING.md"
          target="_blank"
          rel="noreferrer"
        >
          send a pull request.
        </a>
      </p>
      <div className="mt-1 flex flex-wrap gap-2">
        <Badge variant="secondary">{registry.counts.harnesses} harnesses</Badge>
        <Badge variant="secondary">{registry.counts.providers} providers</Badge>
        <Badge variant="secondary">{registry.counts.models} models</Badge>
        <Badge variant="secondary">{combos} combos</Badge>
        <Badge variant="secondary">{fixtures} fixtures</Badge>
      </div>
    </div>
  );
}
