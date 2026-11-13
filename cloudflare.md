# Cloudflare — local tweaks

The bevry-vibes [cloudflare.md](https://github.com/bevry-vibes/skills/blob/main/cloudflare.md) skill **applies**, with this project's tweaks:

- The browsable registry deploys from `site/` as its own Worker + static assets (`deno task deploy` from that directory); it consumes the committed rule tables and `fixtures/index-data.json` as data and shows declared identifications only.
- Canonical deployment: **https://agent-detect.bevry.me**. The Worker is `agent-detect`; `agent-detect.bevry.workers.dev` and the `agentdetect.bevry.me` typo 308-redirect to the canonical domain from `site/worker/index.ts`, preserving path and query.
- `site/wrangler.jsonc` holds a `custom_domain` entry (DNS + certificate) and a host-scoped `zone_name` route (traffic) for both hosts — the `pati-reports` convention. Explicit hostnames only: never a `*.bevry.me/*` wildcard, which would swallow sibling Workers on the zone.
- `assets.run_worker_first: true` is load-bearing for the redirects: without it static asset requests bypass the Worker and stay reachable on the redirect hosts. Existing files still fall through to the `ASSETS` binding.
- `workers_dev` stays enabled because it is a redirect source, not a deployment target. Local serving: `deno task dev` (wrangler dev on `127.0.0.1:8787`) after `deno task build` (vite). Restart wrangler dev after every vite build — the stale asset manifest serves the old bundle as the 942-byte `index.html` fallback and the page renders blank.
- `deno task data` regenerates `site/public/data/` from the rule tables (needs zig on PATH); keep it run before deploy when the rules changed.
