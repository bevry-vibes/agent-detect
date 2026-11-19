import type { ReactNode } from "react";

// Release notes are our own Markdown — headings, bullets, links, and inline
// code. The renderer covers that subset rather than pulling a Markdown engine
// (and its HTML output) into the site: every node below is built as React,
// so the notes can never inject markup.

const INLINE = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)\s]+\)|https?:\/\/[^\s<)]+)/g;

function inline(text: string, key: string): ReactNode[] {
  return text.split(INLINE).filter(Boolean).map((part, i) => {
    const id = `${key}-${i}`;
    if (part.startsWith("**") && part.endsWith("**")) return <strong key={id}>{part.slice(2, -2)}</strong>;
    if (part.startsWith("`") && part.endsWith("`")) {
      return (
        <code key={id} className="bg-muted rounded px-1 py-0.5 font-mono text-[0.9em]">
          {part.slice(1, -1)}
        </code>
      );
    }
    const md = /^\[([^\]]+)\]\(([^)\s]+)\)$/.exec(part);
    if (md) {
      return (
        <a key={id} href={md[2]} className="underline underline-offset-4" target="_blank" rel="noreferrer">
          {md[1]}
        </a>
      );
    }
    if (/^https?:\/\//.test(part)) {
      return (
        <a key={id} href={part} className="underline underline-offset-4 break-all" target="_blank" rel="noreferrer">
          {part}
        </a>
      );
    }
    return part;
  });
}

export function Markdown({ text }: { text: string }) {
  const blocks: ReactNode[] = [];
  const lines = text.split("\n");
  let paragraph: string[] = [];
  let bullets: string[] = [];

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    const body = paragraph.join(" ");
    blocks.push(
      <p key={`p-${blocks.length}`} className="text-muted-foreground text-sm leading-relaxed">
        {inline(body, `p-${blocks.length}`)}
      </p>,
    );
    paragraph = [];
  };
  const flushBullets = () => {
    if (bullets.length === 0) return;
    const key = `ul-${blocks.length}`;
    blocks.push(
      <ul key={key} className="text-muted-foreground list-disc space-y-1.5 pl-5 text-sm leading-relaxed">
        {bullets.map((item, i) => (
          <li key={`${key}-${i}`}>{inline(item, `${key}-${i}`)}</li>
        ))}
      </ul>,
    );
    bullets = [];
  };

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === "") {
      flushParagraph();
      flushBullets();
      continue;
    }
    if (trimmed.startsWith("### ")) {
      flushParagraph();
      flushBullets();
      blocks.push(
        <h4 key={`h4-${blocks.length}`} className="mt-4 text-sm font-semibold">
          {inline(trimmed.slice(4), `h4-${blocks.length}`)}
        </h4>,
      );
      continue;
    }
    if (trimmed.startsWith("## ")) {
      flushParagraph();
      flushBullets();
      blocks.push(
        <h3 key={`h3-${blocks.length}`} className="mt-5 text-base font-semibold first:mt-0">
          {inline(trimmed.slice(3), `h3-${blocks.length}`)}
        </h3>,
      );
      continue;
    }
    if (trimmed.startsWith("- ")) {
      flushParagraph();
      bullets.push(trimmed.slice(2));
      continue;
    }
    flushBullets();
    paragraph.push(trimmed);
  }
  flushParagraph();
  flushBullets();

  return <div className="space-y-3">{blocks}</div>;
}
