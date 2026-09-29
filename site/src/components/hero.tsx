import {
  Check,
  ChevronDown,
  ChevronUp,
  Copy,
  ExternalLink,
  Eye,
  Mail,
  ScrollText,
  SlidersHorizontal,
  Sparkles,
  SquareTerminal,
  Terminal,
  WifiOff,
} from "lucide-react";
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
      {/* leading-5 makes the math exact — (32px icon − 20px line) / 2 = mt-1.5 — so
          the first line's center sits on the icon's midline and every feature's
          first line shares the same y; extra lines flow below */}
      <span className="text-muted-foreground mt-1.5 text-sm leading-5">{children}</span>
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
            Generate accurate <code className="font-mono text-[0.9em] leading-none">Co-Authored-By</code> &amp;{" "}
            <code className="font-mono text-[0.9em] leading-none">Assisted-By</code> trailers for agent-made commits and
            issues.
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
                {installLines.map((line) => (
                  <CodeLine key={line} code={line} />
                ))}
              </div>
            </CardContent>
          </Card>

          <Card id="commands" className="min-w-0 scroll-mt-14">
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <SquareTerminal className="size-4" /> Commands
              </CardTitle>
              <CardDescription>Have your agent run these commands.</CardDescription>
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
                <Sparkles className="size-4" /> Prompts
              </CardTitle>
              <CardDescription>Enhance your prompting with these snippets.</CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
              <InlinePrompt
                description="Make a new project with Bevry's conventions."
                text="Scaffold a new project using github.com/bevry-vibes/skills. The project will ..."
              />
              <SkillSnippet description="Restrict a skill to a specific model." file="minimax.md" startWith="# MiniMax" endBefore="### Never use" />
              <SkillSnippet description="Instruct your agents to write their plans to a consistent directory." file="plans.md" lines={5} />
              <SkillSnippet
                description="Instruct the agent to use co-authored-by trailer for commits."
                file="commits.md"
                startWith="### co-author trailer"
                endBefore="### signing"
              />
              <SkillSnippet
                description="Instruct the agent to use assisted-by trailer for issues."
                file="commits.md"
                startWith="## github issues"
                endBefore="## releases"
                anchor="#github-issues-pull-requests-discussions-and-comments"
              />
              <SkillSnippet description="Restrict your project to reciprocal agents only." file="policy.md" startWith="# AI Policy" />
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
  /** the prompt description doubles as the snippet header */
  description: string;
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

function CollapseToggle({ open, onToggle }: { open: boolean; onToggle: () => void }) {
  return (
    <Button
      variant="ghost"
      size="sm"
      className="h-7 w-7 p-0"
      onClick={onToggle}
      aria-expanded={open}
      aria-label={open ? "collapse" : "expand"}
      title={open ? "collapse" : "expand"}
    >
      {open ? <ChevronUp className="size-3.5" /> : <ChevronDown className="size-3.5" />}
    </Button>
  );
}

function SnippetHeader({ description, children }: { description: string; children: ReactNode }) {
  return (
    <header className="bg-muted/50 flex flex-wrap items-center justify-between gap-x-2 gap-y-1 border-b px-3 py-1.5">
      <span className="text-sm font-medium">{description}</span>
      <div className="flex items-center gap-1">{children}</div>
    </header>
  );
}

/** the scaffold prompt — plain text with no skill file behind it, so copy prompt
 * and the collapse toggle are all it has */
function InlinePrompt({ description, text }: { description: string; text: string }) {
  const [open, setOpen] = useState(true);
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard unavailable — the text is still selectable
    }
  };
  return (
    <section className="overflow-hidden rounded-lg border">
      <SnippetHeader description={description}>
        <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={copy}>
          {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
          {copied ? "copied" : "copy prompt"}
        </Button>
        <CollapseToggle open={open} onToggle={() => setOpen(!open)} />
      </SnippetHeader>
      {open && (
        <div className="p-3">
          <CodeLine code={text} />
        </div>
      )}
    </section>
  );
}

/** a bevry-vibes/skills doc rendered in stages: collapsed until first opened,
 * then just the relevant line-numbered lines; `show file` brings in the whole
 * file scrolled to the relevant lines, and `view file` permalinks there with
 * the range highlighted on GitHub */
function SkillSnippet(spec: SnippetSpec) {
  const key = `${spec.file}:${spec.startWith ?? ""}:${spec.lines ?? ""}`;
  const [open, setOpen] = useState(false);
  const [stage, setStage] = useState<"prompt" | "file">("prompt");
  const [meta, setMeta] = useState<{ full: string[]; start: number; end: number } | null>(
    () => snippetCache.get(key) ?? null,
  );
  const [copied, setCopied] = useState(false);
  const [failed, setFailed] = useState(false);
  const preRef = useRef<HTMLPreElement>(null);

  // staged loading — nothing hits the network until the block is first expanded
  useEffect(() => {
    if (!open || meta || failed) return;
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
  }, [open, meta, failed, key, spec.file, spec.startWith, spec.endBefore, spec.lines]);

  // in the file stage the relevant lines are scrolled to the top of the block
  useEffect(() => {
    const pre = preRef.current;
    if (!open || stage !== "file" || !meta || !pre) return;
    const first = pre.querySelector('[data-relevant-start="true"]');
    if (first) pre.scrollTop = (first as HTMLElement).offsetTop - pre.offsetTop - 4;
  }, [open, stage, meta]);

  const toggleStage = () => {
    setStage(stage === "prompt" ? "file" : "prompt");
    setOpen(true);
  };
  const from = meta ? meta.start + 1 : 0;
  const to = meta ? meta.end : 0;
  const linePermalink = meta
    ? `https://github.com/bevry-vibes/skills/blob/main/${spec.file}#L${from}-L${to}`
    : `https://github.com/bevry-vibes/skills/blob/main/${spec.file}${spec.anchor ?? ""}`;
  const copyText = async () => {
    if (!meta) return; // nothing fetched yet — expand first
    try {
      await navigator.clipboard.writeText(
        stage === "file" ? meta.full.join("\n") : meta.full.slice(meta.start, meta.end).join("\n"),
      );
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard unavailable — the snippet is still selectable
    }
  };

  const renderLines = (lines: { text: string; n: number; relevant: boolean }[]) => (
    <pre ref={preRef} className="max-h-96 overflow-auto p-0 font-mono text-xs leading-relaxed">
      {lines.map(({ text, n, relevant }) => (
        <div
          key={n}
          data-relevant-start={relevant && n === from ? "true" : undefined}
          className={cn(
            "flex items-start",
            relevant
              ? stage === "file" && "bg-muted/40"
              : "[content-visibility:auto] [contain-intrinsic-size:auto_20px]",
          )}
        >
          <span className="text-muted-foreground/50 w-12 shrink-0 select-none pr-3 text-right">{n}</span>
          <span
            className="min-w-0 flex-1 pr-3"
            dangerouslySetInnerHTML={{ __html: markdownLineHtml(text) || "&nbsp;" }}
          />
        </div>
      ))}
    </pre>
  );

  return (
    <section className="overflow-hidden rounded-lg border">
      <SnippetHeader description={spec.description}>
        <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={copyText}>
          {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
          {copied ? "copied" : stage === "file" ? "copy file" : "copy prompt"}
        </Button>
        <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={toggleStage}>
          <Eye className="size-3" />
          {stage === "file" ? "show prompt" : "show file"}
        </Button>
        <a
          href={linePermalink}
          target="_blank"
          rel="noreferrer"
          title="view file"
          aria-label="view file"
          className="text-muted-foreground hover:text-foreground inline-flex h-7 items-center gap-1 rounded-md px-2 text-xs"
        >
          <ExternalLink className="size-3" />
          view file
        </a>
        <CollapseToggle open={open} onToggle={() => setOpen(!open)} />
      </SnippetHeader>
      {open &&
        (failed ? (
          <div className="p-3">
            <a
              className="text-muted-foreground inline-flex items-center gap-1 rounded-lg border border-dashed px-3 py-2 font-mono text-xs underline underline-offset-4"
              href={linePermalink}
              target="_blank"
              rel="noreferrer"
            >
              view {spec.file} on GitHub ↗
            </a>
          </div>
        ) : !meta ? (
          <p className="text-muted-foreground px-3 py-3 font-mono text-xs">loading {spec.file}…</p>
        ) : stage === "file" ? (
          renderLines(meta.full.map((text, i) => ({ text, n: i + 1, relevant: i >= meta.start && i < meta.end })))
        ) : (
          renderLines(
            meta.full.slice(meta.start, meta.end).map((text, i) => ({ text, n: meta.start + 1 + i, relevant: true })),
          )
        ))}
    </section>
  );
}
