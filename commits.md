# commits.md

Local application of the bevry-vibes skills [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md) — see the upstream [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

## this project's tweaks

- Build via `zig build` (released), `zig build dev` (maintainer `fixtures` binary), and `zig build test` before committing.
- Build first, then generate the co-author trailer from the fresh binary: `zig build && ./zig-out/bin/agent-detect trailer co-author`, attached with `git commit --trailer "$(zig build && ./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather than commit without it.
  The build-first is not optional: the binary reads local session stores that drift across app updates (the zcode 3.14 rollout rename left stale binaries resolving nothing), so a stale build can report a different agent than the session committing.
- Any content an agent posts to this project's issue tracker (issues, PRs, discussions, comments) carries a footer with the freshly generated `trailer assisted-by` line — generated, never guessed, same as commit trailers.
  This rule belongs in the upstream commits.md skill; keep the local tweak until it lands there.

## releases

- This project elects **calver** (upstream "calver" section): the version lives in `build.zig.zon` and the tag equals it exactly, matching the `tags: ['*.*.*-*']` filter in `.github/workflows/build.yml`.

After the cut, before the tag, verify locally that the freshly built binary prints the expected version:

```sh
zig build && ./zig-out/bin/agent-detect --version
# → agent-detect <new_version>
```
