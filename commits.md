# commits.md

Local application of the bevry-vibes skills [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md) — see the upstream [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

## this project's tweaks

- Build via `zig build` (released), `zig build dev` (maintainer `fixtures` binary), and `zig build test` before committing.
- Generate the co-author trailer with `./zig-out/bin/agent-detect trailer co-author` and attach it with `git commit --trailer "$(./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather than commit without it.

## releases

- This project elects **calver** (upstream "calver" section): the version lives in `build.zig.zon` and the tag equals it exactly, matching the `tags: ['*.*.*-*']` filter in `.github/workflows/build.yml`.

After the cut, verify locally that the freshly built binary prints the expected version:

```sh
zig build && ./zig-out/bin/agent-detect --version
# → agent-detect <new_version>
```
