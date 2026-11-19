import { ArrowUpRight, Link2 } from "lucide-react";

import { Markdown } from "@/lib/markdown";
import type { Release, ReleasesFile } from "@/lib/schemas";

/** the tagger date, without the time — the release is a day, not a moment */
export function releaseDay(date: string): string {
  const d = new Date(date);
  if (Number.isNaN(d.getTime())) return date;
  return d.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
}

/** one release, with its permalink on the tag and again on the date. The
 * permalink is the site page (/releases/<tag>) — a stable link that survives
 * the list's scroll position, unlike a bare #anchor. */
export function ReleaseEntry({ release }: { release: Release }) {
  const href = `/releases/${release.tag}`;
  return (
    <section id={release.tag} className="scroll-mt-20 border-t pt-6 first:border-t-0 first:pt-0">
      <header className="mb-3 flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 className="text-lg font-semibold tracking-tight">
          <a href={href} className="hover:underline underline-offset-4">
            {release.tag}
          </a>
        </h3>
        <a
          href={href}
          className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1 text-xs"
          title={`permalink to ${release.tag}`}
        >
          <Link2 className="size-3" />
          permalink
        </a>
        <a href={href} className="text-muted-foreground hover:text-foreground text-sm hover:underline underline-offset-4">
          <time dateTime={release.date}>{releaseDay(release.date)}</time>
        </a>
        <a
          href={release.url}
          target="_blank"
          rel="noreferrer"
          className="text-muted-foreground hover:text-foreground ml-auto inline-flex items-center gap-1 text-xs"
        >
          GitHub release
          <ArrowUpRight className="size-3" />
        </a>
      </header>
      <Markdown text={release.body} />
    </section>
  );
}

/** the releases page — the public changelog, newest first, the way the
 * democratic-ai journal reads. GitHub releases carry the notes; the site reads
 * the annotated tags (and their `releases/<tag>.md` overlays) directly in
 * `tools/build_data.ts`, so the two cannot drift. */
export function ReleasesPage({ file }: { file: ReleasesFile | null }) {
  return (
    <main className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-8 px-4 py-10">
      <header className="flex flex-col gap-2">
        <p className="text-muted-foreground text-xs tracking-wide uppercase">the record</p>
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Releases</h1>
        <p className="text-muted-foreground max-w-3xl text-sm">
          Dated notes for each published version, newest first. The notes are the annotated tag's message — the same text
          the GitHub release carries — and every release keeps a permalink at{" "}
          <code className="bg-muted rounded px-1 py-0.5 font-mono text-[0.9em]">/releases/&lt;tag&gt;</code>.
        </p>
      </header>
      {!file ? (
        <p className="text-muted-foreground text-sm">loading the releases…</p>
      ) : file.releases.length === 0 ? (
        <p className="text-muted-foreground text-sm">No releases in this checkout.</p>
      ) : (
        <div className="flex flex-col gap-6">
          {file.releases.map((release) => (
            <ReleaseEntry key={release.tag} release={release} />
          ))}
        </div>
      )}
    </main>
  );
}
