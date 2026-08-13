# kilo.md

Local application of the bevry-vibes skills [kilo.md](https://github.com/bevry-vibes/skills/blob/main/kilo.md) —
see [meta.md](./meta.md) for the reference pattern.

## this project's tweak (to be upstreamed)

Every plan file the agent generates records its provenance in an
accompanying `<plan>.prompts.md` companion file: the original prompt
that initiated the plan, every followup prompt that shaped it —
verbatim, untruncated, timestamped, in order — and the agent model
that generated it (as reported by the harness). The plan file itself
only links to the companion and never inlines prompts (inlined prompts
with plans confuse readers and agents).
