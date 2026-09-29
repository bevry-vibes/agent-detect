import { Mail, ScrollText, SlidersHorizontal, WifiOff } from "lucide-react";
import { Terminal } from "lucide-react";
import { useState, type ReactNode } from "react";

import type { Registry } from "@/lib/registry";
import { CodeLine } from "@/components/json-block";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";

type Platform = "linux" | "macos" | "windows";
type Arch = "x86_64" | "aarch64";

const PLATFORMS: { value: Platform; label: string }[] = [
  { value: "linux", label: "linux" },
  { value: "macos", label: "macos" },
  { value: "windows", label: "windows" },
];
const ARCHES: { value: Arch; label: string }[] = [
  { value: "x86_64", label: "x86_64" },
  { value: "aarch64", label: "aarch64" },
];

// best-effort guess so most visitors see their own platform preselected
function detectPlatform(): Platform {
  const ua = navigator.userAgent.toLowerCase();
  if (ua.includes("win")) return "windows";
  if (ua.includes("mac")) return "macos";
  return "linux";
}

function ToggleRow({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: { value: string; label: string }[];
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="text-muted-foreground w-16 shrink-0 text-right text-[10px] font-medium uppercase tracking-wide">
        {label}
      </span>
      <div className="flex flex-wrap gap-1">
        {options.map((o) => (
          <button
            key={o.value}
            type="button"
            aria-pressed={value === o.value}
            onClick={() => onChange(o.value)}
            className={cn(
              "rounded-md border px-2.5 py-1 text-xs font-medium transition-colors",
              value === o.value ? "border-transparent bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-muted",
            )}
          >
            {o.label}
          </button>
        ))}
      </div>
    </div>
  );
}

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

/** the cli section — the command-line tool pitch, then the install/use cards.
 * One platform (+arch for the download) selection drives both cards: the
 * snippets are sh on linux/macos and powershell on windows. */
export function Hero() {
  const [platform, setPlatform] = useState<Platform>(detectPlatform);
  const [arch, setArch] = useState<Arch>("x86_64");
  const prefix = platform === "windows" ? ".\\agent-detect.exe" : "./agent-detect";
  const asset = `agent-detect-${platform}-${arch}${platform === "windows" ? ".exe" : ""}`;
  const installLines =
    platform === "windows"
      ? [`Invoke-WebRequest https://github.com/bevry-vibes/agent-detect/releases/latest/download/${asset} -OutFile agent-detect.exe`]
      : [
          `curl -fLo agent-detect https://github.com/bevry-vibes/agent-detect/releases/latest/download/${asset}`,
          "chmod +x agent-detect",
        ];
  const usage: { code: string; what: string }[] = [
    { code: `${prefix} identify`, what: "machine-readable JSON report of the current agent (harness, provider, model)" },
    { code: `${prefix} check-reciprocal`, what: '"is reciprocal" (0) or "not reciprocal" (10) — the reciprocity compliance verdict' },
    {
      code:
        platform === "windows"
          ? `git commit --trailer "$(& ${prefix} trailer co-author)"`
          : `git commit --trailer "$(${prefix} trailer co-author)"`,
      what: "the Co-authored-by trailer for git commits",
    },
    {
      code:
        platform === "windows"
          ? `git commit --trailer "$(& ${prefix} trailer assisted-by)"`
          : `git commit --trailer "$(${prefix} trailer assisted-by)"`,
      what: "the Assisted-by trailer for issues, PRs, discussions, comments",
    },
    { code: `${prefix} explain`, what: "why the verdict resolved as it did — reasons, judged values, remediation actions" },
    { code: `${prefix} found`, what: "what the detection ladder observed on this machine — the observation trail" },
  ];

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
            <CardContent className="flex flex-col gap-3">
              <ToggleRow label="platform" options={PLATFORMS} value={platform} onChange={(v) => setPlatform(v as Platform)} />
              <ToggleRow label="arch" options={ARCHES} value={arch} onChange={(v) => setArch(v as Arch)} />
              <div className="flex flex-col gap-2">
                <div className="flex items-center justify-between gap-2">
                  <Badge variant="secondary" className="font-mono text-[10px]">
                    {platform === "windows" ? "powershell" : "sh"}
                  </Badge>
                  <span className="text-muted-foreground truncate font-mono text-[10px]" title={asset}>
                    {asset}
                  </span>
                </div>
                {installLines.map((line) => (
                  <CodeLine key={line} code={line} />
                ))}
              </div>
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
              <ToggleRow label="platform" options={PLATFORMS} value={platform} onChange={(v) => setPlatform(v as Platform)} />
              <div className="flex flex-col gap-3">
                {usage.map((u) => (
                  <div key={u.code} className="flex flex-col gap-1">
                    <CodeLine code={u.code} />
                    <p className="text-muted-foreground pl-1 text-xs">{u.what}</p>
                  </div>
                ))}
              </div>
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
