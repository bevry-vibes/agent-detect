# Cloudflare — local tweaks

The bevry-vibes [cloudflare.md](https://github.com/bevry-vibes/skills/blob/main/cloudflare.md) skill **applies**, with this project's tweaks:

- The browsable registry deploys from `site/` as its own Worker + static assets (`deno task deploy` from that directory); it consumes the committed rule tables and `fixtures/index-data.json` as data and shows declared identifications only.
- Local serving: `deno task dev` (wrangler dev on `127.0.0.1:8787`) after `deno task build` (vite). Restart wrangler dev after every vite build — the stale asset manifest serves the old bundle as the 942-byte `index.html` fallback and the page renders blank.
- `deno task data` regenerates `site/public/data/` from the rule tables (needs zig on PATH); keep it run before deploy when the rules changed.
