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
 * the homepage's scroll position, unlike a bare #anchor. */
export function ReleaseEntry({ release, compact = false }: { release: Release; compact?: boolean }) {
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
      {!compact && (
        <p className="mt-3 text-xs">
          <a href="#releases" className="text-muted-foreground hover:text-foreground">
            all releases
          </a>
        </p>
      )}
    </section>
  );
}

/** the homepage section — the release notes, newest first, the way the
 * democratic-ai journal reads. GitHub releases carry the notes; the site reads
 * the annotated tags directly (tools/build_data.ts), so the two cannot drift. */
export function ReleasesSection({ file }: { file: ReleasesFile }) {
  return (
    <article id="releases" className="mx-auto flex w-full max-w-7xl flex-col gap-6 scroll-mt-14 border-t px-4 py-10">
      <div className="flex flex-col gap-2">
        <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">Releases</h2>
        <p className="text-muted-foreground max-w-3xl text-sm">
          Dated notes for each published version, newest first. The notes are the annotated tag's message — the same text
          the GitHub release carries — and every release keeps a permalink at{" "}
          <code className="bg-muted rounded px-1 py-0.5 font-mono text-[0.9em]">/releases/&lt;tag&gt;</code>.
        </p>
      </div>
      {file.releases.length === 0 ? (
        <p className="text-muted-foreground text-sm">No releases in this checkout.</p>
      ) : (
        file.releases.map((release) => <ReleaseEntry key={release.tag} release={release} />)
      )}
    </article>
  );
}
