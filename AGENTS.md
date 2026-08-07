# AGENTS.md

Only one skill from https://github.com/bevry-labs/skills applies to this
project: **commits.md**. None of the other skills in that repository apply,
and this file is not policy — it is a pointer to the one relevant skill.

## commits.md (the only applicable skill)

Follow https://github.com/bevry-labs/skills/blob/main/commits.md for every
commit: Conventional Commits format, atomic commits, and the mandatory
co-author trailer.

The `agent-detect` tool that commits.md refers to is **this project**.
To generate the co-author trailer for the current session, build this
project's binary and run it:

```sh
zig build
./zig-out/bin/agent-detect trailer   # prints the Co-authored-by trailer
```

Then attach it to the commit (never guess or cache the identity):

```sh
git commit --trailer "$(./zig-out/bin/agent-detect trailer)" # along with other args
```

If the trailer cannot be generated (the binary reports "unable to determine
trailer"), do not commit without it and do not guess — fix the trailer
generation for the current harness instead.
