# The website — the browsable registry at agent-detect.bevry.workers.dev

Written 2026-09-29, on the linux host, on the `website` branch. This plan lands the
agent-detect website: a shadcn/ui-style single-page app plus a small JSON API, deployed as a
Cloudflare Worker with static assets. The website is its own thing — it lives in `site/`, is not
part of the zig binary, and consumes the committed rule tables and fixture channels as data; it
never forks them.

## Provenance

Every prompt that shaped this plan is recorded verbatim (untruncated, timestamped, in order) in the
companion file `.plans/1790666509289-website-registry-site.prompts.md` — plans link to it; they do
not inline prompts. Agent model: GLM-5.3 Flash (reported by the harness). The session crashed once
mid-implementation and resumed (no decisions were lost; the work continued on the same branch).

## Stack and why

- **Deno** is the toolchain, not a runtime dependency of the site: `deno.json` carries the tasks
  (`data`, `build`, `spa`, `dev`, `check`, `deploy`), `deno install` materialises `node_modules`
  (from `package.json`, `nodeModulesDir: "auto"`), and the data pipeline (`site/tools/build_data.ts`)
  is a plain Deno script. Wrangler/vite run as node binaries from `node_modules/.bin` via
  `deno task` (deno task puts `.bin` on PATH), so the npm tooling runs under node while Deno runs
  the scripts and the checks.
- **Cloudflare Workers with static assets — not Cloudflare Pages.** Workers assets is Cloudflare's
  current unified product (Pages is in maintenance mode for new projects); one `wrangler.jsonc`
  binds the built SPA (`site/dist/`) as the `ASSETS` binding and points `main` at
  `site/worker/index.ts`. Requests matching a static asset are served without invoking the worker;
  unmatched paths invoke the worker, which handles the JSON routes and falls back to
  `env.ASSETS.fetch(request)` so `not_found_handling: "single-page-application"` serves
  `index.html` for app deep-links.
- **shadcn/ui** is vendored the shadcn way — the components are copied into `site/src/components/ui`
  (Tailwind v4 + Radix primitives + cmdk), no component library dependency beyond the primitives.
- **No capture fixtures on the website**: the capture *tooling* stays in the zig dev binary. The
  website shows the *results* (the committed fixture files) read-only.

## The data pipeline (`deno task data` → `site/public/data/`, gitignored)

Data is generated at build/deploy time from the committed sources, so it can never drift:

1. **The rule registry comes from the zig source, not a copy.** A generated one-shot zig program
   (`dump.zig`) imports a temp copy of `src/lib/rules.zig` (the table file is data-only and
   compiles standalone) and `std.json.Stringify.valueAlloc`s the three rule tables. This buys the
   exact alias sets (name/label/short_title/variations) and policy fields, so the site resolves
   names exactly like the CLI flags do (`canonicalIdFor`/`canonicalFilterDim` semantics:
   exact canonical-name match first, then lowercase+strip-non-alphanumeric whole-string slug match
   over the alias set, first rule in array order; models shed a catalog namespace before the last
   `/`).
2. **The combo results come from the fixture channels verbatim.** `fixtures/from-identity/*.json`
   and `fixtures/from-capture/*.json` are grouped by combo (`<h>-<p>-<m>`; a stem in both channels
   keeps both), and emitted as:
   - `registry.json` — harnesses/providers/models with policy fields + sources + alias sets;
   - `combos.json` — one compact row per combo (ids, labels are client-side lookups, trailer email,
     reciprocal, explain state, platforms, channels, per-fixture index, latest updated_at);
   - `agents/<agent_id>.json` — the merged detail for one combo: every platform × channel fixture
     with its verbatim `outputs` (identify, both trailers, explain when recorded, found, stderr,
     check-reciprocal) and `meta`.

## The URLs

- `/` — the app. Header hero (what agent-detect is, what it enables, install, usage), the filter
  row (four searchable dropdowns: harness, provider, model, trailer email — shadcn Combobox/Command),
  and the result table (one row per combo). The results table is a div-grid with every row kept in
  the DOM under CSS `content-visibility: auto` — lazy rendering without dropping rows, so native
  Ctrl/Cmd+F searches the whole list (JS virtualization would break find-in-page, and
  content-visibility does not apply to `<tr>` internals). Columns sort client-side on header click —
  ascending → descending → default — with `aria-sort` tracking on the columnheader.
- Filters write `?harness=&provider=&model=&email=` through the **HTML5 history API** (pushState on
  user interaction, replaceState to canonicalise hand-typed names, popstate to go back/forward).
  Values resolve **exactly like the arg flags**: display names ("Kimi Code", "kimi-code",
  "Kimi-K2.5") are accepted, but the URL always carries the resolved strict-slug alphanumeric id
  (`kimicode`).
- Row click → the **agent results page**, a full-page replacement of the index (decided
  2026-09-29, replacing the original below-the-table detail panel): `?agent=<agent_id>` renders the
  result JSON — identify, both trailers (co-author + assisted-by), and explain — tabbed per platform
  × channel when a combo has several, each block copyable, with a link to the raw JSON URL. The
  index stays one history entry away; the site header wordmark or the page's "back to results"
  button closes the agent view, and the index's scroll position is remembered per entry
  (`history.scrollRestoration = "manual"` + a per-search scroll map) so returning lands where the
  click happened. Deep-linked agent pages push the filtered index as a new entry on close.
- **`.json` for JSON results**:
  - `/index.json` — the filtered view as JSON. Accepts the same params (harness/provider/model/
    email/agent) with the same name→id resolution. Unfiltered it returns the compact combo index;
    with any filter it embeds each combo's full fixtures (identify + trailers + explain), capped at
    50 combos before degrading to compact rows with `truncated: true`.
  - `/identify/<agent_id>.json` — one combo's merged result (same bytes as
    `/data/agents/<agent_id>.json`).
  - `/registry.json` — the rule registry.
  - `/llms.txt` — the LLM-facing map of the site and its endpoints.
- Trailer-email lookup matches the full email, or the local part / agent_id when no `@` is given.
  From-identity fixtures carry `<agent_id@local>` emails.

## Layout of `site/`

`deno.json` (tasks), `package.json` (deps), `wrangler.jsonc` (worker + assets), `vite.config.ts`,
`index.html`, `src/` (the SPA: `lib/registry.ts` shared resolution + types, `components/ui/*` the
vendored shadcn set, `components/*` the app), `worker/index.ts` (the JSON routes), `tools/build_data.ts`
(the pipeline), `public/llms.txt`, `public/data/` (generated, gitignored).

## Deployment

`deno task deploy` = generate data → `vite build` → `wrangler deploy` (wrangler is authorised on the
maintainer's host). Worker name `agent-detect` → `agent-detect.bevry.workers.dev`. The work lands on
the `website` branch so it can be dropped wholesale if we change our minds.
