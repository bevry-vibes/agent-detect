# prompts — the quality & doctrine pass

## 1 — 2026-09-30

> Two things worth knowing: zig build test prints a failed command: line on this host even though every test passes and the exit is 0 — I bisected it and it exists at the previous release commit too, so it's pre-existing host-side zig noise, not this change. And the plans file records that the quality pass and the command were one prompt (round 32 in the website companion, mirrored in the web plan's own companion).
>
> fix this, and fix other code quality issues / linting issues

## 2 — 2026-09-30

> Reciprocity data vs. their own comments (rules.zig): openrouter (381–386), opencode (387–392), opencode-go (393–399), and google (499–502) rows carry never/opt-out while their documentation argues opt-in — these disagree on exit codes, so I can't tell which side is stale
>
> Verify. It could be confusing telemetry with training, or model specific training with provider training. Find out what our policies are here, and research.
>
> providerForBaseUrl maps dashscope → qwen (rules.zig:863), but the repo's own doctrine says that surface is the alibaba rule (never) — a dashscope-backed qwen harness currently reports qwen/enforced → exit 10
>
> Goose mixed-source evidence attribution (core.zig detectGoose): one shared src string misattributes which of env/config resolved each dim when the two come from different sources (decision #11 chain wrong both ways) — needs per-dim source tracking.
>
> Dev-only, lower confidence: classifyCaptureFailure probes only the first 512 bytes of combined output though its doc says the full text — late-appearing harness error markers would classify as .other.
>
> I don't know what these mean. If the resolution is unambigious do it. If it needs more research, do the more research.
>
> Duplicate mistral-small rules (mistral-small-latest vs mistral-small-3) — folding them as a variation would match the sibling precedent, but that's a table-modeling call.
>
> Yeah, establish a policy that `-latest` are ephemeral variations and we need to make sure we keep on top of them.

## 3 — 2026-09-30

> commits, push, release
