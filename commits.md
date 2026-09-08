# commits.md

Local application of the bevry-vibes skills [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md) — see the upstream [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

## this project's tweaks

- Build via `zig build` (released), `zig build dev` (maintainer `fixtures` binary), and `zig build test` before committing.
- Generate the co-author trailer with `./zig-out/bin/agent-detect trailer co-author` and attach it with `git commit --trailer "$(./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather than commit without it.

## releases

- Versioning is calver: `<year>.<month>.<day>-<revision>` — UTC date, the revision resets to `1` each day and increments per same-day release — and the tag equals the `build.zig.zon` version exactly, with no `v` prefix, matching the `tags: ['*.*.*-*']` filter in `.github/workflows/build.yml`.
- The bump commit is `release: <version>` (this repo's `<area>:` style — no headline).
