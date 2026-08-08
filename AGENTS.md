# AGENTS.md

This project conforms to Bevry's skills. Reference their remote URLs
only — do not pull their contents into this file.

- https://github.com/bevry-vibes/skills/blob/main/ai-policy.md —
  **not applied to this project.** agent-detect is the enforcement
  mechanism that ai-policy.md delegates to, so this project must run
  on all agents, including those that violate that policy; it cannot
  apply the policy to itself.
- https://github.com/bevry-vibes/skills/blob/main/commits.md —
  **applies**, with this project's tweaks: build via `zig build`,
  generate the co-author trailer with
  `./zig-out/bin/agent-detect trailer co-author`, attach it with
  `git commit --trailer "$(./zig-out/bin/agent-detect trailer co-author)"`.
  Never guess or cache the trailer; if generation fails, fix it rather
  than commit without it.
- https://github.com/bevry-vibes/skills/blob/main/minimax.md —
  **applies** when the running agent is a MiniMax M3 model (its rules
  gate themselves on model and harness).

This file is not policy — it is a pointer.
