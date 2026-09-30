# agent-detect website

The browsable registry at `agent-detect.bevry.workers.dev` — a shadcn/ui-style SPA plus a small
JSON API. **Its own deployment; not part of the zig binary.** It consumes the repo's committed rule
tables, the index file (`fixtures/index-data.json`, copied verbatim), and the from-identity channel
as data and never forks them. The site shows declared identifications only — the from-capture
channel stays maintainer-side and never renders.

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
2. `fixtures/index-data.json` — the committed index the released `index` action embeds — is copied
   verbatim to `index.json` (the `#index` section's data).
3. `fixtures/from-identity/*.json` are grouped per combo and emitted verbatim as `registry.json`,
   `combos.json` (rows gain `free` from the index's `provider_map_to_free_models`), and
   `agents/<agent_id>.json`.

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

- `/` — the app; the registry section's filters write `?harness=&provider=&model=&search=&email=&platform=&free=&reciprocal=`
  (+`?agent=` for a result page — the platform param never reaches it) via the history API, the dims
  accepting names and resolving to the strict-slug ids exactly like the CLI flags; the `#index`
  section lists every harness/provider/model with its canonical id and associations
- `/index.json` — the filtered view as JSON (see `public/llms.txt`)
- `/identify/<agent_id>.json` — one combo's from-identity fixture outputs
- `/registry.json`, `/index.json` (data), `/llms.txt` — the rule registry; the index; the LLM-facing site map

## opening it from the cli

The released binary's `agent-detect registry` command prints its JSON report (`{url, query, opened}`)
and opens the url with `--web` (`--no-json` prints nothing): the filters land as
`?harness=`/`?provider=`/`?model=`/`?email=`/`?platform=`/`?free=`/`?reciprocal=` scrolled to the
registry section (`#registry`), a complete combo or `--agent=` lands on the combo's result page
(`?agent=<agent_id>`), and `agent-detect index --web` deep-links the `#index` section. Every value
resolves exactly like the CLI's own flags.
