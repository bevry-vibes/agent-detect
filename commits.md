# commits.md

Local application of the bevry-vibes skills [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md) —
see [meta.md](./meta.md) for the reference pattern.

## this project's tweaks

- Build via `zig build` (released), `zig build dev` (maintainer
  `fixtures` binary), and `zig build test` before committing.
- Generate the co-author trailer with
  `./zig-out/bin/agent-detect trailer co-author` and attach it with
  `git commit --trailer "$(./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather
  than commit without it.
