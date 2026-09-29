import { Check, Copy, ExternalLink, Mail, ScrollText, SlidersHorizontal, WifiOff } from "lucide-react";
import { Terminal } from "lucide-react";
import { useEffect, useRef, useState, type ReactNode } from "react";

import type { Registry } from "@/lib/registry";
import { CodeLine, JsonBlock } from "@/components/json-block";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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
      {/* mt-1.5 puts the first text line on the icon's midline; extra lines flow below */}
      <span className="text-muted-foreground mt-1.5 text-sm leading-snug">{children}</span>
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
    <article id="cli" className="scroll-mt-14 border-b">
      <div className="mx-auto max-w-7xl px-4 py-10">
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">CLI for Agent Detection</h1>
        <p className="mt-2 text-lg font-medium">Give your agent self-awareness.</p>
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

        {/* one shared platform/arch selection — the cards below never repeat it */}
        <div className="mt-10 flex flex-wrap items-center gap-x-10 gap-y-3">
          <ToggleRow label="platform" options={PLATFORMS} value={platform} onChange={(v) => setPlatform(v as Platform)} />
          <ToggleRow label="arch" options={ARCHES} value={arch} onChange={(v) => setArch(v as Arch)} />
        </div>

        <div className="mt-6 flex flex-col gap-4">
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

          <Card id="commands" className="min-w-0 scroll-mt-14">
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <Terminal className="size-4" /> Commands
              </CardTitle>
              <CardDescription>click a line to copy it — exactly one trailer per artifact, never both</CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
              {usage.map((u) => (
                <div key={u.code} className="flex flex-col gap-1">
                  <CodeLine code={u.code} />
                  <p className="text-muted-foreground pl-1 text-xs">{u.what}</p>
                </div>
              ))}
            </CardContent>
          </Card>

          <Card id="prompts" className="min-w-0 scroll-mt-14">
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <Terminal className="size-4" /> Prompts
              </CardTitle>
              <CardDescription>
                paste these to your agent — snippets load live from{" "}
                <a
                  className="underline underline-offset-4"
                  href="https://github.com/bevry-vibes/skills"
                  target="_blank"
                  rel="noreferrer"
                >
                  bevry-vibes/skills
                </a>
              </CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-4">
              <div className="flex flex-col gap-1">
                <p className="text-sm font-medium">Make a new project with Bevry's conventions.</p>
                <CodeLine code="Scaffold a new project using github.com/bevry-vibes/skills. The project will ..." />
              </div>
              <div className="flex flex-col gap-1">
                <p className="text-sm font-medium">Restrict a skill to a specific model.</p>
                <SkillSnippet file="minimax.md" startWith="# MiniMax" endBefore="### Never use" />
              </div>
              <div className="flex flex-col gap-1">
                <p className="text-sm font-medium">Instruct your agents to write their plans to a consistent directory.</p>
                <SkillSnippet file="plans.md" lines={5} />
              </div>
              <div className="flex flex-col gap-1">
                <p className="text-sm font-medium">Instruct the agent to use co-authored-by trailer for commits.</p>
                <SkillSnippet file="commits.md" startWith="### co-author trailer" endBefore="### signing" />
              </div>
              <div className="flex flex-col gap-1">
                <p className="text-sm font-medium">Instruct the agent to use assisted-by trailer for issues.</p>
                <SkillSnippet
                  file="commits.md"
                  startWith="## github issues"
                  endBefore="## releases"
                  anchor="#github-issues-pull-requests-discussions-and-comments"
                />
              </div>
              <div className="flex flex-col gap-1">
                <p className="text-sm font-medium">Restrict your project to reciprocal agents only.</p>
                <SkillSnippet file="policy.md" startWith="# AI Policy" />
              </div>
            </CardContent>
          </Card>
        </div>
      </div>
    </article>
  );
}

/** the registry section intro — heading, byline, contributing line, and the
 * counts with the filtered view link */
export function RegistryIntro({
  registry,
  combos,
  fixtures,
  jsonHref,
}: {
  registry: Registry;
  combos: number;
  fixtures: number;
  jsonHref: string;
}) {
  return (
    <div className="flex flex-col gap-2">
      <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Registry of Agent Detections</h1>
      <p className="text-lg font-medium">Agents now capable of self-awareness.</p>
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
      <div className="mt-1 flex flex-wrap items-center gap-2">
        <Badge variant="secondary">{combos} combos</Badge>
        <Badge variant="secondary">{registry.counts.harnesses} harnesses</Badge>
        <Badge variant="secondary">{registry.counts.providers} providers</Badge>
        <Badge variant="secondary">{registry.counts.models} models</Badge>
        <Badge variant="secondary">{fixtures} fixtures</Badge>
        <a
          href={jsonHref}
          className="text-muted-foreground hover:text-foreground ml-auto font-mono text-sm underline underline-offset-4"
          title="this filtered view as JSON"
        >
          view as JSON ↗
        </a>
      </div>
    </div>
  );
}

// skill snippets are fetched once per session and shared across renders
const snippetCache = new Map<string, { full: string[]; start: number; end: number }>();

interface SnippetSpec {
  file: "policy.md" | "minimax.md" | "commits.md" | "plans.md";
  /** the line the snippet starts at (substring match) */
  startWith?: string;
  /** the line the snippet stops before (substring match); omitted = to the end */
  endBefore?: string;
  /** take the first N lines instead of anchor extraction */
  lines?: number;
  /** a github anchor on the file url, when the section has one */
  anchor?: string;
}

// tiny markdown line highlighter — escapes, then colors the common constructs
function markdownLineHtml(line: string): string {
  let h = line
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
  if (/^#{1,6}\s/.test(line)) {
    h = `<span class="font-semibold text-foreground">${h}</span>`;
  } else if (/^>\s?/.test(line)) {
    h = `<span class="text-muted-foreground italic">${h}</span>`;
  } else {
    h = h.replace(/\[([^\]]*)\]\(([^)]*)\)/g, '<span class="text-sky-400">[$1]($2)</span>');
    h = h.replace(/(^|[\s(])((?:https?:\/\/)[^\s)]+)/g, '$1<span class="text-sky-400">$2</span>');
    h = h.replace(/\*\*([^*]+)\*\*/g, '<span class="font-semibold text-foreground">$1</span>');
    h = h.replace(/`([^`]+)`/g, '<span class="text-emerald-400">$1</span>');
    h = h.replace(/^(\s*)([-*])\s/, '$1<span class="text-muted-foreground">$2</span> ');
  }
  return h;
}

/** the whole bevry-vibes/skills doc, line-numbered, syntax highlighted — the
 * relevant lines are scrolled into view by default while the rest of the file
 * stays lazily unrendered until scrolled for */
function SkillSnippet(spec: SnippetSpec) {
  const key = `${spec.file}:${spec.startWith ?? ""}:${spec.lines ?? ""}`;
  const [meta, setMeta] = useState<{ full: string[]; start: number; end: number } | null>(
    () => snippetCache.get(key) ?? null,
  );
  const [copied, setCopied] = useState(false);
  const [failed, setFailed] = useState(false);
  const preRef = useRef<HTMLPreElement>(null);

  useEffect(() => {
    if (meta) return;
    let alive = true;
    fetch(`https://raw.githubusercontent.com/bevry-vibes/skills/main/${spec.file}`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.text();
      })
      .then((text) => {
        const all = text.split("\n");
        let start = 0;
        let end = all.length;
        if (spec.lines) {
          end = Math.min(spec.lines, all.length);
        } else {
          start = all.findIndex((l) => l.includes(spec.startWith ?? ""));
          if (start === -1) throw new Error("anchor not found");
          const endBefore = spec.endBefore ?? "";
          if (endBefore) {
            const stop = all.findIndex((l, i) => i > start && l.includes(endBefore));
            if (stop !== -1) end = stop;
          }
        }
        const found = { full: all, start, end };
        snippetCache.set(key, found);
        if (alive) setMeta(found);
      })
      .catch(() => {
        if (alive) setFailed(true);
      });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [spec.file, spec.startWith, spec.endBefore, spec.lines]);

  // the relevant lines are the default view — scroll them to the top of the
  // block once the file is in
  useEffect(() => {
    const pre = preRef.current;
    if (!meta || !pre) return;
    const first = pre.querySelector('[data-relevant-start="true"]');
    if (first) pre.scrollTop = (first as HTMLElement).offsetTop - pre.offsetTop - 4;
  }, [meta]);

  if (failed) {
    return (
      <a
        className="text-muted-foreground inline-flex items-center gap-1 rounded-lg border border-dashed px-3 py-2 font-mono text-xs underline underline-offset-4"
        href={`https://github.com/bevry-vibes/skills/blob/main/${spec.file}${spec.anchor ?? ""}`}
        target="_blank"
        rel="noreferrer"
      >
        view {spec.file} on GitHub ↗
      </a>
    );
  }
  if (!meta) {
    return <p className="text-muted-foreground rounded-lg border border-dashed px-3 py-2 font-mono text-xs">loading {spec.file}…</p>;
  }

  const from = meta.start + 1;
  const to = meta.end;
  const fileLink = `https://github.com/bevry-vibes/skills/blob/main/${spec.file}${spec.anchor ?? ""}#L${from}-L${to}`;
  const linePermalink = `https://github.com/bevry-vibes/skills/blob/main/${spec.file}#L${from}-L${to}`;
  const copyPrompt = async () => {
    try {
      await navigator.clipboard.writeText(meta.full.slice(meta.start, meta.end).join("\n"));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard unavailable — the snippet is still selectable
    }
  };

  return (
    <section className="overflow-hidden rounded-lg border">
      <header className="bg-muted/50 flex flex-wrap items-center justify-between gap-2 border-b px-3 py-1.5">
        <span className="font-mono text-xs">
          <a
            href="https://github.com/bevry-vibes/skills"
            target="_blank"
            rel="noreferrer"
            className="underline underline-offset-4 hover:text-foreground"
          >
            bevry-vibes/skills
          </a>
          {" · "}
          <a href={fileLink} target="_blank" rel="noreferrer" title={fileLink} className="underline underline-offset-4 hover:text-foreground">
            {spec.file} · L{from}–L{to}
          </a>
        </span>
        <div className="flex items-center gap-1">
          <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={copyPrompt}>
            {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
            {copied ? "copied" : "copy prompt"}
          </Button>
          <a
            href={linePermalink}
            target="_blank"
            rel="noreferrer"
            title="view source"
            aria-label="view source"
            className="text-muted-foreground hover:text-foreground inline-flex h-7 w-7 items-center justify-center rounded-md"
          >
            <ExternalLink className="size-3.5" />
          </a>
        </div>
      </header>
      <pre ref={preRef} className="max-h-96 overflow-auto p-0 font-mono text-xs leading-relaxed">
        {meta.full.map((line, i) => {
          const relevant = i >= meta.start && i < meta.end;
          return (
            <div
              key={i}
              data-relevant-start={i === meta.start ? "true" : undefined}
              className={cn("flex items-start", !relevant && "[content-visibility:auto] [contain-intrinsic-size:auto_20px]")}
            >
              <span className="text-muted-foreground/50 w-12 shrink-0 select-none pr-3 text-right">{i + 1}</span>
              <span
                className="min-w-0 flex-1 pr-3"
                dangerouslySetInnerHTML={{ __html: markdownLineHtml(line) || "&nbsp;" }}
              />
            </div>
          );
        })}
      </pre>
    </section>
  );
}
