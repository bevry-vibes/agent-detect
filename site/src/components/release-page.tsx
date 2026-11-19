import { ArrowLeft, ArrowUpRight, Link2 } from "lucide-react";

import { Markdown } from "@/lib/markdown";
import type { ReleasesFile } from "@/lib/schemas";
import { releaseDay } from "@/components/releases-page";

/** one release at its own URL — /releases/<tag> is the permalink the release
 * notes, the journal, and the announcements point at. */
export function ReleasePage({
  tag,
  file,
  onReleases,
  onHome,
}: {
  tag: string;
  file: ReleasesFile | null;
  onReleases: () => void;
  onHome: () => void;
}) {
  if (!file) {
    return (
      <main className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-4 px-4 py-10">
        <p className="text-muted-foreground text-sm">loading the release…</p>
      </main>
    );
  }

  const release = file.releases.find((r) => r.tag === tag) ?? null;

  if (!release) {
    return (
      <main className="mx-auto flex w-full max-w-7xl flex-1 flex-col gap-4 px-4 py-10">
        <h1 className="text-2xl font-semibold tracking-tight">Unknown release</h1>
        <p className="text-muted-foreground text-sm">
          No annotated tag <code className="bg-muted rounded px-1 py-0.5 font-mono">{tag}</code> exists in this checkout.
        </p>
        <p className="text-sm">
          <a href="/releases" className="underline underline-offset-4" onClick={(e) => { e.preventDefault(); onReleases(); }}>
            all releases
          </a>
        </p>
      </main>
    );
  }

  return (
    <main className="mx-auto flex w-full max-w-4xl flex-1 flex-col gap-6 px-4 py-10">
      <nav aria-label="breadcrumb" className="text-muted-foreground text-sm">
        <a
          href="/releases"
          className="hover:text-foreground inline-flex items-center gap-1"
          onClick={(e) => {
            e.preventDefault();
            onReleases();
          }}
        >
          <ArrowLeft className="size-3" />
          releases
        </a>
      </nav>
      <header className="flex flex-col gap-2 border-b pb-5">
        <p className="text-muted-foreground text-xs tracking-wide uppercase">release</p>
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">{release.tag}</h1>
        <p className="text-muted-foreground flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
          <a href={`/releases/${release.tag}`} className="hover:text-foreground inline-flex items-center gap-1">
            <Link2 className="size-3" />
            permalink
          </a>
          <time dateTime={release.date}>{releaseDay(release.date)}</time>
          <a
            href={release.url}
            target="_blank"
            rel="noreferrer"
            className="hover:text-foreground ml-auto inline-flex items-center gap-1 text-xs"
          >
            GitHub release
            <ArrowUpRight className="size-3" />
          </a>
        </p>
      </header>
      <Markdown text={release.body} />
      <p className="border-t pt-4 text-sm">
        <button type="button" onClick={onHome} className="underline underline-offset-4">
          back to the registry
        </button>
      </p>
    </main>
  );
}
