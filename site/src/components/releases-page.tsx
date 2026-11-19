import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowUpRight } from "lucide-react";

import { Markdown } from "@/lib/markdown";
import type { Release, ReleasesFile } from "@/lib/schemas";

/** the tagger date, without the time — the release is a day, not a moment */
export function releaseDay(date: string): string {
  const d = new Date(date);
  if (Number.isNaN(d.getTime())) return date;
  return d.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
}

/** the `yyyy-mm-dd` date anchor — several releases can share one day */
function releaseDateAnchor(date: string): string {
  return date.slice(0, 10);
}

function ReleaseEntry({ release, flash }: { release: Release; flash: boolean }) {
  const day = releaseDateAnchor(release.date);
  return (
    <section
      id={release.tag}
      data-date={day}
      className={`scroll-mt-20 border-t pt-6 ${flash ? "release-flash" : ""}`}
    >
      <header className="mb-3 flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 className="text-lg font-semibold tracking-tight">
          {/* the tag is the permalink: /releases/#<tag> */}
          <a href={`#${release.tag}`} className="hover:underline underline-offset-4">
            {release.tag}
          </a>
        </h3>
        <a
          href={`#${day}`}
          className="text-muted-foreground hover:text-foreground text-sm hover:underline underline-offset-4"
        >
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
 * democratic-ai journal reads.
 *
 * Permalinks are anchors, not pages: `#<tag>` points at one release and
 * `#<yyyy-mm-dd>` at every release cut that day. Both flash the target for a
 * moment. The old `/releases/<tag>` and `/releases/<date>` paths 308 to these
 * anchors (worker/index.ts), so a published link keeps working. */
export function ReleasesPage({ file }: { file: ReleasesFile | null }) {
  const [flashId, setFlashId] = useState<string | null>(null);
  const timer = useRef<number | null>(null);

  const groups = useMemo(() => {
    const byDay = new Map<string, Release[]>();
    for (const release of file?.releases ?? []) {
      const day = releaseDateAnchor(release.date);
      const list = byDay.get(day) ?? [];
      list.push(release);
      byDay.set(day, list);
    }
    return [...byDay.entries()];
  }, [file]);

  // the hash is the permalink: flash the named release, or every release of the
  // named day. Re-runs on hash change so a second click still flashes.
  useEffect(() => {
    const apply = () => {
      const id = decodeURIComponent(window.location.hash.replace(/^#/, ""));
      if (!id) return;
      const target = document.getElementById(id);
      if (!target) return;
      setFlashId(id);
      target.scrollIntoView({ block: "start" });
      if (timer.current) window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => setFlashId(null), 2400);
    };
    apply();
    window.addEventListener("hashchange", apply);
    return () => {
      window.removeEventListener("hashchange", apply);
      if (timer.current) window.clearTimeout(timer.current);
    };
  }, [file]);

  return (
    <main className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-8 px-4 py-10">
      <header className="flex flex-col gap-2">
        <p className="text-muted-foreground text-xs tracking-wide uppercase">the record</p>
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Releases</h1>
        <p className="text-muted-foreground max-w-3xl text-sm">
          Dated notes for each published version, newest first. The notes are the annotated tag's message — the same text
          the GitHub release carries. Every release is its own permalink at{" "}
          <code className="bg-muted rounded px-1 py-0.5 font-mono text-[0.9em]">/releases/#&lt;tag&gt;</code>, and every
          day at <code className="bg-muted rounded px-1 py-0.5 font-mono text-[0.9em]">/releases/#&lt;yyyy-mm-dd&gt;</code>.
        </p>
      </header>
      {!file ? (
        <p className="text-muted-foreground text-sm">loading the releases…</p>
      ) : file.releases.length === 0 ? (
        <p className="text-muted-foreground text-sm">No releases in this checkout.</p>
      ) : (
        <div className="flex flex-col gap-8">
          {groups.map(([day, releases]) => (
            <div key={day} id={day} className="date-group flex scroll-mt-20 flex-col gap-6">
              {releases.map((release) => (
                <ReleaseEntry key={release.tag} release={release} flash={flashId === release.tag || flashId === day} />
              ))}
            </div>
          ))}
        </div>
      )}
    </main>
  );
}
