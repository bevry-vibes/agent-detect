# meta.md

How this repo consumes the [bevry-vibes/skills](https://github.com/bevry-vibes/skills) skill library. AGENTS.md
follows this pattern and points here.

## skill-reference pattern

1. When a referenced bevry-vibes skill applies to this project **with
   this project's tweaks**, create a local `<name>.md` file at the repo
   root that:
   - references the remote skill URL (the remote file stays the single
     source of truth), and
   - lists this project's tweaks underneath it.
2. AGENTS.md references the **local** file, never the remote URL with
   inline tweaks.
3. When a skill applies **without tweaks**, AGENTS.md keeps the plain
   remote URL bullet (e.g. `minimax.md`).
4. A decision that a skill does **not** apply is a non-application
   decision, not a tweak — it stays an AGENTS.md bullet with its
   rationale (e.g. `policy.md`).

This keeps the remote files authoritative and the tweaks visible
separately (so they can be upstreamed), while AGENTS.md stays a pure
pointer.
