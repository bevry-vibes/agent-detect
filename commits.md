# commits.md

Local application of the bevry-vibes skills [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md) —
see the upstream [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

## this project's tweaks

- Build via `zig build` (released), `zig build dev` (maintainer
  `fixtures` binary), and `zig build test` before committing.
- Generate the co-author trailer with
  `./zig-out/bin/agent-detect trailer co-author` and attach it with
  `git commit --trailer "$(./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather
  than commit without it.

## release notes

The notes flow (watch the run, `gh release edit --notes-file`, draft
from `git log`, delete the artifact, verify with `gh release view`)
lives in the upstream skill. The project-specific pieces:

- The release runbook itself (calver version, bump, tag, push) lives in
  [CONTRIBUTING.md](./CONTRIBUTING.md) "cut a release".
- The `release` job in `.github/workflows/build.yml` publishes the
  pushed tag with a fixed one-line body — the stable-release pointer
  plus the `releases/latest/download/<asset>` note — and sets `latest`
  itself (`make_latest: true`), so the verified end state is
  `prerelease=false` with the assets present.
