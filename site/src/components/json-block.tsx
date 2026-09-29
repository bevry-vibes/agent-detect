import { useState } from "react";
import { Check, Copy, Terminal } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";

/** a copyable block of JSON (or any value) — the detail view's building block.
 * `command` adds a second button next to copy that copies the CLI invocation
 * that reproduces this block with the recipe-mode flags. */
export function JsonBlock({ title, value, command, className }: { title: string; value: unknown; command?: string; className?: string }) {
  const [copied, setCopied] = useState(false);
  const [copiedCommand, setCopiedCommand] = useState(false);
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);

  const copy = async (what: string, done: () => void) => {
    try {
      await navigator.clipboard.writeText(what);
      done();
      setTimeout(done, 1500);
    } catch {
      // clipboard unavailable (insecure context) — the block is still selectable
    }
  };

  return (
    <section className={cn("overflow-hidden rounded-lg border", className)}>
      <header className="bg-muted/50 flex items-center justify-between gap-2 border-b px-3 py-1.5">
        <h4 className="font-mono text-xs font-medium">{title}</h4>
        <div className="flex items-center gap-1">
          {command && (
            <Button
              variant="ghost"
              size="sm"
              className="h-7 gap-1 px-2 text-xs"
              title={command}
              onClick={() => copy(command, () => setCopiedCommand(true))}
            >
              <Terminal className="size-3" />
              {copiedCommand ? "command copied" : "copy command"}
            </Button>
          )}
          <Button variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={() => copy(text, () => setCopied(true))}>
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
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(code);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // as above
    }
  };

  return (
    <button
      type="button"
      onClick={copy}
      title="click to copy"
      className="group flex w-full min-w-0 items-center justify-between gap-2 rounded-md border bg-muted/40 px-3 py-1.5 text-left font-mono text-xs hover:bg-muted/70"
    >
      <code className="block min-w-0 truncate">{code}</code>
      <span className="text-muted-foreground group-hover:text-foreground shrink-0">
        {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5 opacity-60" />}
      </span>
    </button>
  );
}
