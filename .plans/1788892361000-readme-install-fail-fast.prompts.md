# Prompts — 1788892361000-readme-install-fail-fast

Model: builtin:zai-coding-plan/GLM-5.3 (as reported by the ZCode harness).
Timestamps of individual prompts were not observable by the agent; they are recorded
in conversation order only.

## Prompt 1 (initiating)

> "The tool lives at bevry-vibes/agent-detect on GitHub. Trying it via npx directly from the repo:
>
> [transcript excerpt of the aural-keyboard session: npx github:bevry-vibes/agent-detect → npm ENOENT; curl of a guessed asset name agent-detect-macos-arm64 → silent 404 body saved as the binary; exec fails with `error: unable to find 'Found' in PATH`; the real asset is agent-detect-macos-aarch64]
>
> You ran into issues following the agent-detect readme instructions. Send a patch to the agent-detect repo with a fix so this doesn't happen again."

## Prompt 2 (implicit scope)

No further prompts; the patch was prepared directly from prompt 1 plus the repo's own AGENTS.md/commits.md/plans.md conventions.
