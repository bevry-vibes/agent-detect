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

## release notes

The release runbook itself (calver version, bump, tag, push) lives in
[CONTRIBUTING.md](./CONTRIBUTING.md) "cut a release". The notes flow
picks up where it ends:

1. The `release` job in `.github/workflows/build.yml` publishes the
   pushed tag with a fixed one-line body — the stable-release pointer
   plus the `releases/latest/download/<asset>` note.
2. Once that run completes (`gh run watch <run-id> --exit-status`),
   replace the body with the full changelog:
   `gh release edit <version> --notes-file .release-notes-<version>.md`.
3. Draft the notes in `.release-notes-<version>.md` at the repo root,
   sourced from `git log --oneline <prev-tag>..HEAD` and the commit
   bodies — verify every claim against a commit message, never invent.
   Structure: lead with the workflow's stable-release line unchanged,
   then `## What's changed since <prev-tag>` with themed `###`
   sections (e.g. new detection / platform support / detection matrix
   / dev tooling — adapt to what the release actually contains), and
   close with a **Full Changelog** compare link:
   `https://github.com/bevry-vibes/agent-detect/compare/<prev-tag>...<version>`.
4. The notes file is an artifact — delete it after uploading, never
   commit it.
5. Verify the final state with `gh release view <version>`: body
   updated, `prerelease=false`, the assets present. `latest` itself is
   set by the workflow (`make_latest: true`).
