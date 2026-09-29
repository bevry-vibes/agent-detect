import { Check, Copy, Terminal } from "lucide-react";

import { useCopied } from "@/lib/use-copied";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";

/** a copyable block of JSON (or any value) — the detail view's building block.
 * `command` adds a second button next to copy that copies the CLI invocation
 * that reproduces this block with the recipe-mode flags. */
export function JsonBlock({
  title,
  titleHref,
  value,
  command,
  className,
}: {
  title: string;
  titleHref?: string;
  value: unknown;
  command?: string;
  className?: string;
}) {
  const { copied, copy: copyText } = useCopied();
  const { copied: copiedCommand, copy: copyCommand } = useCopied();
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);

  return (
    <section className={cn("overflow-hidden rounded-lg border", className)}>
      <header className="bg-muted/50 flex items-center justify-between gap-2 border-b px-3 py-1.5">
        <h4 className="font-mono text-xs font-medium">
          {titleHref ? (
            <a href={titleHref} target="_blank" rel="noreferrer" className="underline underline-offset-4 hover:text-foreground">
              {title}
            </a>
          ) : (
            title
          )}
        </h4>
        <div className="flex items-center gap-1">
          {command && (
            <Button
              variant="ghost"
              size="sm"
              className="h-7 gap-1 px-2 text-xs"
              title={command}
              onClick={() => copyCommand(command)}
            >
              <Terminal className="size-3" />
              {copiedCommand ? "command copied" : "copy command"}
            </Button>
          )}
          <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={() => copyText(text)}>
            {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
            {copied ? "copied" : "copy result"}
          </Button>
        </div>
      </header>
      <pre className="max-h-96 overflow-auto p-3 font-mono text-xs leading-relaxed">{text}</pre>
    </section>
  );
}

/** a copyable one-line command, for the hero */
export function CodeLine({ code }: { code: string }) {
  const { copied, copy } = useCopied();

  return (
    <button
      type="button"
      onClick={() => copy(code)}
      title="click to copy"
      className="group flex w-full min-w-0 items-start justify-between gap-2 rounded-md border bg-muted/40 px-3 py-1.5 text-left font-mono text-xs hover:bg-muted/70"
    >
      {/* commands are never truncated — long ones wrap */}
      <code className="block min-w-0 whitespace-pre-wrap break-all">{code}</code>
      <span className="text-muted-foreground mt-0.5 shrink-0 group-hover:text-foreground">
        {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5 opacity-60" />}
      </span>
    </button>
  );
}
