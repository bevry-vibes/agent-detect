import { execFileSync } from "node:child_process";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

/** the latest calver release, read from git — the tag and its creation date.
 * The footer links it; null (the footer then omits the segment) when git is
 * absent or no calver tag exists. Argv-only — no shell, nothing to inject. */
function latestRelease(): { tag: string; date: string } | null {
  try {
    const row = execFileSync(
      "git",
      [
        "for-each-ref",
        "refs/tags/*.*.*-*",
        "--sort=-creatordate",
        "--count=1",
        "--format=%(refname:short)%09%(creatordate:unix)",
      ],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    if (!row) return null;
    const [tag, ts] = row.split("\t");
    if (!tag || !ts || !Number.isFinite(Number(ts))) return null;
    return { tag, date: new Date(Number(ts) * 1000).toISOString().slice(0, 10) };
  } catch {
    return null;
  }
}

const release = latestRelease();

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": new URL("./src", import.meta.url).pathname,
    },
  },
  define: {
    // baked in at build time from git — consumed by the footer (App.tsx),
    // declared in src/vite-env.d.ts
    __RELEASE_TAG__: JSON.stringify(release?.tag ?? null),
    __RELEASE_DATE__: JSON.stringify(release?.date ?? null),
  },
  server: {
    // `deno task spa` + `deno task dev` (wrangler) side by side: the SPA dev
    // server proxies the worker endpoints to wrangler on 8787.
    proxy: {
      "/index.json": "http://127.0.0.1:8787",
      "/registry.json": "http://127.0.0.1:8787",
      "/identify": "http://127.0.0.1:8787",
    },
  },
});
