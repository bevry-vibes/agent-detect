# commits.md

Local application of the bevry-vibes skills [commits.md](https://github.com/bevry-vibes/skills/blob/main/commits.md) — see the upstream [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

## this project's tweaks

- Build via `zig build` (released), `zig build dev` (maintainer `fixtures` binary), and `zig build test` before committing.
- Build first, then generate the co-author trailer from the fresh binary: `zig build && ./zig-out/bin/agent-detect trailer co-author`, attached with `git commit --trailer "$(zig build && ./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather than commit without it.
  The build-first is not optional: the binary reads local session stores that drift across app updates (the zcode 3.14 rollout rename left stale binaries resolving nothing), so a stale build can report a different agent than the session committing.
- The issue-tracker assisted-by rule now lives upstream (commits.md §"github issues, pull requests, discussions, and comments") — the local tweak carried it until it landed there, and is retired.
- **Agent-made commits are never signed** — commit with `git commit --no-gpg-sign`. This overrides the upstream signing line (commits sign through the 1Password SSH agent) for agent work: the host's global `commit.gpgsign` signs with the maintainer's key through 1Password, so every signed agent commit both costs the 1Password round-trip and asserts a human made it. Neither is true — the trailer already names the agent. Signing stays the human's act on the human's own commits, which keeps a signature meaning something: human commits signed, agent commits not.

## releases

- This project elects **calver** (upstream "calver" section): the version lives in `build.zig.zon` and the tag equals it exactly, matching the `tags: ['*.*.*-*']` filter in `.github/workflows/build.yml`.
- Annotated tags, and `tag.forceSignAnnotated` is set on this host: `git tag <version>` alone fails — pass `-F`/`-m`. Since 2026.10.6-1 the tag message IS the release notes (the one-line `agent-detect <version>` messages on earlier tags predate this).

After the cut, before the tag, verify locally that the freshly built binary prints the expected version:

```sh
zig build && ./zig-out/bin/agent-detect --version
# → agent-detect <new_version>
```

- **The release notes ride in the annotated tag — the workflow publishes the tag's message (signature stripped) as the release body and FAILS the job when the message carries none**, so a cut can never ship a bodyless release (the workflow-only flow is what left 2026.10.6-1 blank until a manual edit). At cut time:
  1. draft `.release-notes-<version>.md` at the repo root from `git log --oneline <prev-tag>..HEAD` plus the commit bodies — verify every claim against a commit message, never invent. Shape: the `Stable release … Cut from main …` preamble, `## What's changed since <prev-tag>`, themed `###` sections, and a `Plans:` footer citing the `.plans/<id>` folders — no H1, no Full-Changelog link, and the title stays the bare version.
  2. annotate the tag with the file: `git tag -a <version> --cleanup=verbatim -F .release-notes-<version>.md` — **`--cleanup=verbatim` is not optional**: git otherwise strips every `#`-prefixed line from the message as a comment, and the markdown headings never reach the release (found by dry-run, not by review).
  3. before the push, verify the tag round-trips — the same check CI runs:
     ```sh
     git cat-file tag <version> | sed '1,/^$/d' | sed '/^-----BEGIN [A-Z ]*SIGNATURE-----$/,$d' | grep -q "What's changed since" && echo ok
     ```
  4. delete the notes file — the tag carries it now; the file is an artifact, never committed.
- The push publishes notes and all — there is no post-publish edit step anymore. To reword after publication, `gh release edit <version>` (the tag stays as cut). If CI fails on the notes check, nothing was published, so re-cutting the tag is safe: `git tag -d <version> && git push origin :refs/tags/<version>`, re-annotate, push again.
