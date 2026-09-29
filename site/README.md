# agent-detect website

The browsable registry at `agent-detect.bevry.workers.dev` — a shadcn/ui-style SPA plus a small
JSON API. **Its own deployment; not part of the zig binary.** It consumes the repo's committed rule
tables and fixture channels as data and never forks them.

## stack

- **Deno** — toolchain + task runner (`deno.json`) and the data pipeline (`tools/build_data.ts`).
- **Vite + React 19 + TypeScript + Tailwind v4** — the SPA, with the shadcn/ui components vendored
  into `src/components/ui` (the shadcn copy-paste model; Radix primitives + cmdk underneath).
- **Cloudflare Workers with static assets** (not Pages) — one `wrangler.jsonc`: `dist/` is the
  assets directory, `worker/index.ts` handles the JSON routes.

## data flow

`deno task data` generates `public/data/` (gitignored — regenerate before any build/deploy):

1. `src/lib/rules.zig` is compiled standalone via `zig run` on a temp copy with a generated dump
   program, so the registry's alias sets and policy fields can never drift from the CLI's
   name resolution (`canonicalIdFor`/`canonicalFilterDim` semantics live in `src/lib/registry.ts`,
   shared by the SPA and the worker).
2. `fixtures/from-identity/*.json` + `fixtures/from-capture/*.json` are grouped per combo and
   emitted verbatim as `registry.json`, `combos.json`, and `agents/<agent_id>.json`.

## tasks

```sh
deno install          # node_modules (npm deps via deno)
deno task data        # generate public/data (needs zig on PATH)
deno task build       # data + vite build → dist/
deno task check       # tsc + deno check
deno task spa         # vite dev server (proxies the worker routes to :8787)
deno task dev         # wrangler dev (serves dist/ + worker on :8787)
deno task deploy      # build + wrangler deploy → agent-detect.bevry.workers.dev
```

## urls

- `/` — the app; filters write `?harness=&provider=&model=&search=` (+`?agent=` and `?platform=`) via
  the history API, the dims accepting names and resolving to the strict-slug ids exactly like the
  CLI flags, `search` free-text matching combo ids and dim names/ids
- `/index.json` — the filtered view as JSON (see `public/llms.txt`)
- `/identify/<agent_id>.json` — one combo's merged fixture outputs
- `/registry.json`, `/llms.txt` — the rule registry; the LLM-facing site map
