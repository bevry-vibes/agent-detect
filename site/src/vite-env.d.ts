/// <reference types="vite/client" />

/** injected by vite's `define` at build time from git (vite.config.ts) — the
 * latest calver release tag + its creation date; null when git has none, in
 * which case the footer omits the release link */
declare const __RELEASE_TAG__: string | null;
declare const __RELEASE_DATE__: string | null;
