# commits.md

Local application of the bevry-vibes skills [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md) — see the upstream [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

## this project's tweaks

- Build via `zig build` (released), `zig build dev` (maintainer `fixtures` binary), and `zig build test` before committing.
- Build first, then generate the co-author trailer from the fresh binary: `zig build && ./zig-out/bin/agent-detect trailer co-author`, attached with `git commit --trailer "$(zig build && ./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather than commit without it.
  The build-first is not optional: the binary reads local session stores that drift across app updates (the zcode 3.14 rollout rename left stale binaries resolving nothing), so a stale build can report a different agent than the session committing.
- The issue-tracker assisted-by rule now lives upstream (commits.md §"github issues, pull requests, discussions, and comments") — the local tweak carried it until it landed there, and is retired.

## releases

- This project elects **calver** (upstream "calver" section): the version lives in `build.zig.zon` and the tag equals it exactly, matching the `tags: ['*.*.*-*']` filter in `.github/workflows/build.yml`.
- Annotated tags: previous tags carry the one-line `agent-detect <version>` message (upstream's one-paragraph summary, shortened here); `tag.forceSignAnnotated` is set on this host, so `git tag <version>` alone fails — pass `-m`.

After the cut, before the tag, verify locally that the freshly built binary prints the expected version:

```sh
zig build && ./zig-out/bin/agent-detect --version
# → agent-detect <new_version>
```

- **The release notes are a manual post-publish step — the workflow only attaches assets, so a cut that ends at the tag push ships a bodyless release** (upstream "drafting notes" + "publishing"; this step was skipped for 2026.9.30-1 → 2026.10.6-1, the recurrence that wrote this line). After pushing the tag:
  1. draft `.release-notes-<version>.md` at the repo root from `git log --oneline <prev-tag>..HEAD` plus the commit bodies — verify every claim against a commit message, never invent. This repo's shape: the `Stable release … Cut from main …` preamble, `## What's changed since <prev-tag>`, themed `###` sections, and a `Plans:` footer citing the `.plans/<id>` folders — no H1, no Full-Changelog link, and the title stays the bare version (the workflow sets it; the upstream `<version> — <headline>` rule has never been applied here).
  2. `gh run watch` the release workflow, then `gh release edit <version> --notes-file .release-notes-<version>.md`.
  3. delete the notes file — it is an artifact, never committed — and confirm with `gh release view <version>` (body filled, assets present, latest).
