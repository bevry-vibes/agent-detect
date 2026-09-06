# provider training policies: hermes-reachable providers

research pass (2026-09-06) — sources are each provider's own privacy
policy + terms of service pages (two independent same-provider
documents per the rule-table contract). vocabulary:
`enforced | opt-in | opt-out | never | NOASSERTION | null`.

| provider rule id | models.dev id | hermes profile id(s) | closed_training | open_training | sources | notes |
|---|---|---|---|---|---|---|
| ollama-cloud | `ollama-cloud` | `ollama-cloud` | TBD | TBD | ollama.com/privacy, ollama.com/legal | |
| ollama | — | (custom provider surface) | TBD | TBD | ollama.com/privacy | **follow-up flaw**: `:cloud`-suffixed models on a local ollama server are ollama-cloud traffic — currently folded into `ollama` via the model-tag comment; individuate later |
| nous | — | `nous` | TBD | TBD | portal.nousresearch.com/privacy | privacy mode = opt-out (verified 2026-09-06) |
| anthropic | `anthropic` | `anthropic` | never | null | (ruled) | existing rule stands |
| openai | `openai` | `openai-codex` | opt-in | opt-in | (ruled) | existing rule stands; codex surface shares the policy |
| google | `google` | `gemini` | TBD | TBD | ai.google.dev/gemini-api/terms | |
| google-vertex | `google-vertex` | `vertex` | TBD | TBD | cloud.google.com/terms/vertex-ai | |
| amazon-bedrock | `amazon-bedrock` | `bedrock` | TBD | TBD | aws.amazon.com/bedrock, aws service terms | |
| azure-foundry | `azure` | `azure-foundry` | TBD | TBD | microsoft.com/legal | |
| deepseek | `deepseek` | `deepseek` | never | never | (ruled) | existing rule stands |
| zai | `zai` | `zai` | null | null | (ruled) | unverified |
| xai | `xai` | `xai` | null | null | (ruled) | unverified |
| minimax | `minimax` | `minimax` | opt-in | opt-in | (ruled) | existing rule stands |
| kimi-coding | `kimi-for-coding` | `kimi-coding` | null | null | mirrors moonshot | unverified |
| alibaba | `alibaba` | `alibaba` | TBD | TBD | qwen.ai/legal, alibaba cloud privacy | |
| huggingface | `huggingface` | `huggingface` | TBD | TBD | huggingface.co/legal/privacy | hub "don't train on user content" claims need verification |
| fireworks-ai | `fireworks-ai` | `fireworks` | never | never | (ruled) | existing rule stands |
| gmi-cloud | `gmicloud` | `gmi` | TBD | TBD | gmi.cloud privacy/terms | |
| github-copilot | `github-copilot` | `copilot`, `copilot-acp` | TBD | TBD | github terms, copilot trust center | copilot commercial ToS claims no training; individual terms differ |
| vercel | `vercel` | `ai-gateway` | TBD | TBD | vercel.com/legal/privacy-policy | |
| novita-ai | `novita-ai` | `novita` | TBD | TBD | novita.ai terms/privacy | |
| nvidia | `nvidia` | `nvidia` | TBD | TBD | nvidia.com privacy | |
| deepinfra | `deepinfra` | `deepinfra` | TBD | TBD | deepinfra.com/privacy, deepinfra.com/terms | |
| nebius | `nebius` | `nebius-token-factory` | TBD | TBD | nebius.com legal | |
| upstage | `upstage` | `upstage` | TBD | TBD | upstage.ai legal | |
| xiaomi | `xiaomi` | `xiaomi` | TBD | TBD | xiaomi legal | |
| stepfun | `stepfun` | `stepfun` | TBD | TBD | stepfun.ai legal | |
| arcee | `arcee` | `arcee` | TBD | TBD | arcee.ai legal | |
| opencode-zen | `opencode` | `opencode-zen` | null | null | (ruled) | unverified |
| opencode-go | `opencode-go` | `opencode-go` | opt-in | opt-in | (ruled) | existing rule stands |
| opencode-free | `opencode` | `opencode-free` | null | null | mirrors opencode | |
| kimi-coding-cn | — | `kimi-coding-cn` | null | null | mirrors moonshot | |
| alibaba-coding-plan | `alibaba-coding-plan` | `alibaba-coding-plan` | TBD | TBD | qwen.ai/legal + coding plan terms | |
| qwen (oauth) | `qwen-oauth` | `qwen-oauth` | TBD | TBD | portal.qwen.ai terms | |
| openai-codex | — | `openai-codex` | TBD | TBD | openai.com legal | surface may fold into `openai` |
| actual | `actual` | `actual` | TBD | TBD | | niche; may stay null |
| commandcode | `commandcode` | `commandcode` | TBD | TBD | | |
| router (ramp) | `ramp` | `router` | TBD | TBD | | |
| lmstudio (not hermes-reachable) | `lmstudio` | — | n/a | n/a | — | noted for the local-provider discernment with ollama |