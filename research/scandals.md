# Scandal research — providers and harnesses

Generated: 2026-09-28 (the doctrine overhaul — findings retain their original dates and sources),
by the method in [README.md](./README.md). Verdicts are judgements against the criterion below, not
legal findings. Sources follow each finding. Update this file with the same method; never edit a
verdict without a source.

## The law

> We care about consent and copyright violations — except takings that feed reciprocal output
> (liberation, fair use into reciprocal models). Violations that feed no model are out of scope.

- **Ambiguity is allowed.** Only an explicit promise, instruction, or license binds an entity;
  silent or ambiguous policy is not a violation. (Maintainer, 2026-09-28, from the DeepSeek-Korea
  review.)
- **Same-entity exclusion.** A copyright holder may do what it wants with its own models: a lab
  distilling its own closed model into its own smaller one takes from no one. The mischief clause
  covers third-party sources only.
- **The lie escalator.** A proven lie about data handling (wire capture or admission) escalates any
  finding one level: recorded as context → recorded, no effect → scandal.
- **The proof scale.** A regulator finding, a wire capture, an admission, or an approved settlement
  is flag-worthy. A suit-stage allegation is recorded, never a flag. An unproven suspicion is
  recorded, never a flag.
- **The states.** *Scandal* — the entity fails the determination (flagged in the rule tables; shows
  in `identify`, `explain`, and `scandal-urls`). *Recorded, no effect* — the finding stays here
  permanently, visible to maintainers, but never changes the determination. *Recorded as context* —
  a real finding in the wrong lane (it fed no model); history only.

## The matrix

| What was taken ↓ / What it fed → | Fed reciprocal output (weights shipped back) | Fed non-reciprocal output (closed) | Fed no model (serving, infra) |
|---|---|---|---|
| Pirated copyrighted content | recorded, no effect | scandal | recorded as context, out of scope |
| — with destruction of original works | scandal | scandal | recorded as context, out of scope |
| User data, breaching explicit terms/instructions | recorded, no effect — scandal if intentional, unremedied, or unrectified | scandal | recorded as context — a proven lie escalates it |
| User data, silent/ambiguous policy | out of scope | recorded, no effect | out of scope |
| A third-party closed model's outputs, distilled | fine — liberation | scandal — proprietary mischief | — |
| Open-source/open-weight software or models, used in violation of their license | recorded, no effect — scandal if intentional, unremedied, or unrectified | scandal | recorded as context — a proven lie escalates it |

**The unverifiable-recipient rule.** When the recipient of a taking cannot be verified (unreleased,
rumoured, vanished), the finding is recorded with no effect; it re-derives if the recipient ever
ships (fine, if open) or ever serves closed (scandal).

## The redemption gates (one policy for every vector)

| Gate | Question | Pass | Fail |
|---|---|---|---|
| 1. Intent | Was it a deliberate practice, or accident/negligence? | Accident proceeds on gates 3–6 | Deliberate proceeds only with every later gate plus a longer clean record |
| 2. Malice | Did it involve deception, concealment, or harm to users? | — | Path closed while it stands; a proven cover-up survives only via self-disclosure or independent verification of the fix |
| 3. Remedy | Were affected parties made whole — data deleted, users notified or compensated? | Required | Without remedy, the path is closed |
| 4. Rectification | Did the behavior structurally change — policy rewrite, technical fix, independent audit, open-sourcing? | Required, verified by someone other than the entity | Self-attestation is insufficient |
| 5. Recurrence | Any further violation since rectification? | None | Any recurrence resets the clock; repeated findings compound |
| 6. Sustained record | A year or more clean after rectification | Scandal steps down to recorded, no effect; with years more, removal | — |

**The character clause.** A pattern of findings, especially with concealment, marks the entity
itself: the redemption path is permanently closed. OpenAI and Anthropic are ruled character-flawed
(maintainer, 2026-09-28) — their scandals are not redeemable.

## Part 1 — the big western labs

### Anthropic — SCANDAL (character clause: the redemption path is closed)

- Piracy → fed closed Claude (matrix: scandal). Trained Claude on ~7M books downloaded from LibGen
  and PiLiMi. Bartz v. Anthropic (2024): Judge Alsup held that training legally purchased books was
  fair use, but the pirated downloads were not. The $1.5B settlement (~500k works, ~$3,000 per
  book, dataset destruction) was announced Sep 5 2025 and approved Jul 20 2026 — an approved
  settlement is flag-worthy under the proof scale.
  Sources: [Authors Guild](https://authorsguild.org/advocacy/artificial-intelligence/what-authors-need-to-know-about-the-anthropic-settlement/),
  [AP](https://apnews.com/article/anthropic-copyright-authors-settlement-training-f294266bc79a16ec90d2ddccdf435164),
  [Reuters](https://www.reuters.com/world/us/judge-approves-anthropics-15-billion-settlement-copyright-lawsuit-2026-07-20/).
- User data, disclosed default-on (matrix: recorded, no effect — disclosed, with an opt-out).
  Consumer default-on training of chats, announced Aug 2025; users had to opt out by Sep 28 2025
  (extended Oct 8 2025). Source:
  [Goldfarb](https://www.goldfarb.com/updates-to-anthropics-claude-ai-terms-and-privacy-policy-what-you-need-to-know/).
- User data (matrix: recorded) — Reddit v. Anthropic (Jun 2025): scraping since 2021, including
  deleted posts, over 100k bot accesses, against the licence and terms; remanded to state court
  2026. Suit-stage → recorded. Source:
  [Courthouse News](https://www.courthousenews.com/reddit-privacy-case-against-anthropic-kicked-back-to-state-court/).
- User data, breaching expectations (matrix: recorded — revised after backlash). The Bedrock
  "Covered Models" episode (Aug–Sep 2026): Claude Fable 5 / Mythos 5 on AWS required a
  `provider_data_share` mode — 30-day retention of prompts and outputs shared with Anthropic, no
  zero-retention, or the model reported unavailable. Anthropic revised the policy after backlash on
  Sep 1 2026. Sources:
  [AWS blog](https://aws.amazon.com/blogs/aws/anthropic-claude-fable-5-on-aws-mythos-class-capabilities-with-built-in-safeguards-now-available/),
  [CNBC](https://www.cnbc.com/2026/09/01/anthropic-data-retention.html),
  [Securosis](https://securosis.com/blog/aws-destroyed-the-value-proposition-for-bedrock/).
- Not a finding against its subjects: the Feb 2026 distillation report (DeepSeek, Moonshot, MiniMax
  named) is a ToS story about closed inputs; see Part 2. Source:
  [Anthropic](https://www.anthropic.com/news/detecting-and-preventing-distillation-attacks).

### OpenAI — SCANDAL (character clause: the redemption path is closed)

- Piracy → fed closed GPT (matrix: scandal). Books1 (tied to the Books3/Bibliotik dump) and Books2
  (widely suspected LibGen, never confirmed). Suits: Authors Guild (Sep 2023), NYT + Microsoft
  (Dec 2023), ~400 Alden newspapers (Apr 2024), Britannica / Merriam-Webster (Mar 2026, ~100k
  articles), consolidated In re OpenAI (ongoing 2026). Sources:
  [The Atlantic](https://www.theatlantic.com/technology/archive/2025/03/libgen-meta-openai/682093/),
  [Reuters](https://www.reuters.com/legal/litigation/encyclopedia-britannica-sues-openai-over-ai-training-2026-03-16/),
  [NPR](https://www.npr.org/2024/04/30/1248141220/lawsuit-openai-microsoft-copyright-infringement-newspaper-tribune-post).
- Proven lies about data handling (the escalator). OpenAI allegedly deleted its pirated-book
  datasets during litigation. Source:
  [Ars Technica](https://arstechnica.com/tech-policy/2025/12/openai-desperate-to-avoid-explaining-why-it-deleted-pirated-book-datasets/).
- The NYT-led sanctions motion (Jul 9 2026): alleged concealment of tools and datasets, deletion of
  user chats against a preservation order. Sources:
  [Reuters](https://www.reuters.com/legal/litigation/new-york-times-led-group-asks-court-sanction-openai-us-copyright-dispute-2026-07-09/),
  [Variety](https://variety.com/2026/digital/news/new-york-times-news-outlets-accuse-openai-of-lying-lawsuit-1236805648/).
- (Recorded) Canada OPC PIPEDA finding 2026-002: personal information retained in training use.

### Meta — recorded, no effect

- Piracy → fed the open Llama weights (matrix: recorded, no effect — liberation; the origin stays
  on this record permanently). Kadrey v. Meta: staff torrented at least 81.7 TB from LibGen/Books3
  in spring 2023; unsealed filings (Jan 2025) show Zuckerberg personally approved LibGen use
  despite staff flagging "a dataset we know to be pirated" and discussing scrubbing piracy markers.
  The Jun 2025 fair-use ruling was expressly narrow. Re-derive if re-enclosure becomes the dominant
  purpose. Sources:
  [The Guardian](https://www.theguardian.com/technology/2025/jan/10/mark-zuckerberg-meta-books-ai-models-sarah-silverman),
  [The Atlantic](https://www.theatlantic.com/technology/archive/2025/03/libgen-meta-openai/682093/).

### Mistral AI — recorded, no effect

- Piracy → fed Apache-2.0 open weights (matrix: recorded, no effect). Mediapart investigation
  (Feb 26 2026): Mistral Large 3 trained on copyrighted books (Harry Potter), songs (Elton John
  lyrics), and articles without authorisation. Sources:
  [OECD.AI incident](https://oecd.ai/en/incidents/2026-02-23-c733),
  [Mediapart via chatgptiseatingtheworld](https://chatgptiseatingtheworld.com/2026/02/26/).
- Co-founder Guillaume Lample, at Meta FAIR, was ensnared in the LibGen torrenting revelations
  ("everyone is using lib-gen"). Source:
  [OECD.AI incident](https://oecd.ai/en/incidents/2025-12-23-9c7e).
- User data, disclosed with a working opt-out (matrix: out of scope / recorded). Le Chat free and
  consumer tiers train on inputs and outputs by default; paid tiers do not — pay-for-privacy, but a
  free settings toggle exists, so the literal "fee to opt out" claim is not verified. Sources:
  [Mistral help](https://help.mistral.ai/en/articles/455207-can-i-opt-out-of-my-input-or-output-data-being-used-for-training),
  [HN](https://news.ycombinator.com/item?id=49535284).
- Distillation ships as open weights — liberation (fine).

### Microsoft — training-side finding; the Azure AI Foundry serving surface stays out of scope

- Piracy → fed closed Megatron (matrix: scandal on the training side; the Foundry serving surface
  fed no model and stays clean). Authors (Kai Bird, Jia Tolentino, Daniel Okrent) sued Jun 25 2025
  over pirated books used to train Megatron. Sources:
  [The Guardian](https://www.theguardian.com/technology/2025/jun/26/microsoft-ai-authors-lawsuit),
  [Reuters](https://www.reuters.com/legal/litigation/microsoft-sued-by-authors-over-use-of-books-in-ai-training-2025-06-25/).
- Named (co-defendant) in the NYT and Alden suits over Copilot and ChatGPT article scraping; still
  live Sep 2026 — recorded (suit-stage). Source:
  [Chicago Tribune](https://www.chicagotribune.com/2026/09/04/fair-use-copyright-case/).

### GitHub Copilot (provider + harness) — SCANDAL

- Copyright, license violations → fed closed models (matrix: the license-violation row, col 2 —
  and the piracy row). Doe v. GitHub / Microsoft / OpenAI (filed Nov 2022): the model trained on
  public repositories including copyleft code, with licence and attribution stripped — commons-
  licensed material taken into enclosure. A 2023 allegation says GitHub varied output to defeat
  near-verbatim detection. Sources:
  [EFF via HN](https://news.ycombinator.com/item?id=33468849),
  [HN](https://news.ycombinator.com/item?id=36271664).
- User data, disclosed default-on (matrix: recorded, no effect — disclosed, opt-out exists). From
  Apr 24 2026, Free/Pro/Pro+ interaction data (prompts and suggestions) trains models by default;
  Business and Enterprise are excluded. The flag rests on the license/piracy leg alone.
  Sources: [GitHub docs](https://docs.github.com/copilot/how-tos/manage-your-account/managing-copilot-policies-as-an-individual-subscriber),
  [WinBuzzer](https://winbuzzer.com/2026/03/26/github-copilot-ai-training-data-default-opt-out-xcxwbn/).

### Google — recorded as context

- Piracy allegation (suit-stage → recorded): In re Google Generative AI Copyright Litigation;
  authors allege pirated books; class-cert hearing Feb 2026. Source:
  [Authors Alliance](https://www.authorsalliance.org/2026/01/27/ai-class-action-litigation-update-books-where-things-stand-in-early-2026/).
- User data, disclosed (matrix: out of scope — disclosed terms). The Gemini API / AI Studio free
  tier trains on prompts and outputs by default with human review; the only real opt-outs are
  attaching a billing account or disabling Gemini Apps Activity. Paid, Vertex, and enterprise tiers
  do not train. Sources:
  [Google AI forum](https://discuss.ai.google.dev/t/data-privacy-in-use-google-ai-studio/34455),
  [Redact](https://redact.dev/blog/gemini-api-terms-2025).

### Amazon (Bedrock) — recorded as context

AWS states Bedrock does not train on customer data. The Fable 5 `provider_data_share` episode
attaches to Anthropic (see above); Bedrock was the venue, not the actor. Sources:
[AWS](https://repost.aws/knowledge-center/amazon-bedrock-model-data-use),
[Securosis](https://securosis.com/blog/aws-destroyed-the-value-proposition-for-bedrock/).

### xAI — SCANDAL

- User data, breaching explicit scope → fed closed Grok (matrix: scandal). X fed the posts of 60M+
  EU users into Grok training from May 2024, default-on, no prior notice; NOYB filed nine GDPR
  complaints (Aug 2024); training suspended Sep 2024 under Irish DPC pressure. Public-by-visibility
  is not the exception — the exception is about what ships back, and Grok ships no weights. Source:
  [NOYB](https://noyb.eu/en/twitters-ai-plans-hit-9-more-gdpr-complaints).
- User data + a proven lie (the escalator; also gate 2 malice). Grok Build (the CLI coding agent):
  a wire-level analysis (Jul 2026) showed it uploading entire git repositories — full history and
  unredacted `.env` secrets, and files the agent was told not to read — to xAI cloud storage, while
  xAI claimed "no code" was uploaded. xAI acknowledged the retention issue, open-sourced Grok Build
  under Apache-2.0 on Jul 15 2026, and pledged deletion. The open licence does not launder the lie
  (the licence is not a gate), and the closed Grok line's ongoing conduct keeps the redemption path
  closed. Sources:
  [The Hacker News](https://thehackernews.com/2026/07/grok-build-uploads-entire-git.html),
  [TNW](https://thenextweb.com/news/grok-build-uploaded-entire-git-repositories-secrets),
  [HN wire capture](https://news.ycombinator.com/item?id=48877371),
  [xAI](https://x.ai/news/grok-build-open-source).

## Part 2 — the Chinese labs

### The distillation campaigns — judged under the mischief clause

CISA AA26-251A (Sep 8 2026) documents high-volume distillation campaigns by DeepSeek, Moonshot AI,
Alibaba, MiniMax, StepFun, and Z.AI against U.S. frontier models since late 2024. Under the matrix,
distilling a third-party closed model is judged by what the output fed:

- **Fed reciprocal output — fine (liberation):** DeepSeek (R1/V3 ship MIT), Moonshot (K3 shipped
  Jul 2026), MiniMax, Alibaba (the Qwen weights ship; the re-enclosed flagship took only from a
  closed source). Sources:
  [Anthropic](https://www.anthropic.com/news/detecting-and-preventing-distillation-attacks),
  [Reuters](https://www.reuters.com/world/china/anthropic-says-alibaba-illicitly-extracted-claude-ai-model-capabilities-2026-06-24/),
  [CISA](https://www.cisa.gov/news-events/cybersecurity-advisories/aa26-251a).
- **StepFun — recorded, no effect (the unverifiable-recipient rule).** CISA: "Between late 2025 and
  early 2026, StepFun distilled data from Claude Opus 4.1 and 4.5, Claude Sonnet 4.5, Claude Haiku
  4.5, GPT-5 Mini, GPT-5 Pro, GPT-5.1, GPT-5.1 Codex, and GPT-5.2 to improve its Step 4 model's
  coding and agentic functions" — via "pools of accounts" with "user accounts obfuscating their
  country of origin" (deliberate; gate 1 fails). But no Step 4 ever shipped: the stepfun-ai
  Hugging Face org holds no Step 4 repo (verified 2026-09-28), and no official Step 4 product
  exists — the taking cannot be placed in a matrix column. Re-derives if Step 4 (or a renamed
  successor) ever ships open (fine) or serves closed (scandal). Source:
  [CISA](https://www.cisa.gov/news-events/cybersecurity-advisories/aa26-251a).

### Alibaba — recorded as context

Distillation acquitted above. Model Studio says customer data is "never used for model training"
([privacy notice](https://www.alibabacloud.com/help/en/model-studio/privacy-notice)), but the
Coding Plan docs carry a data-usage authorisation clause, and the Chinese-language FAQ states data
will be used for training ([Coding Plan docs](https://help.aliyun.com/en/model-studio/coding-plan))
— per-surface divergence, disclosed → recorded.

### Moonshot AI — recorded, no effect

- The CAC finding (May 20 2025): the Kimi app named among 35 apps illegally collecting personal
  information — collection frequency "had no direct relation to business functions" (excessive-
  collection discipline). Redemption gates: accidental, rectified in the regulator's window, 16+
  months clean → passes. Source: [Securities Times](https://www.stcn.com/article/detail/1838869.html),
  [SCMP](https://www.scmp.com/), [MLex](https://mlex.com/).
- The API policy permits training on user prompts and uploads by default, with a contact-based
  opt-out only and no published retention period — disclosed (matrix: recorded), and the takings
  fed the K3 weights, which shipped (liberation).
  Source: [policy analysis](https://gist.github.com/gadgetb0y/11931119946c2e9dcae0a438fdefe0d5).
- The Kimi K3 weights shipped Jul 26–27 2026 (modified-MIT licence). Distillation acquitted.
  Source: [CyberScoop](https://cyberscoop.com/white-house-accuses-moonshot-ai-anthropic-model-distillation/).

### MiniMax — recorded as context

Distillation acquitted (open-weight outputs; the prompt-injection trick against Claude Code was a
ToS story against a closed source). The minimax.io privacy policy (updated Mar 30 2026) commits to
no fixed retention period and no clear no-training commitment. Source:
[policy](https://platform.minimax.io/protocol/privacy-policy).

### Z.ai / Zhipu — recorded, no effect

- The CAC finding (May 20 2025): Zhipu Qingyan (v2.9.6) named among 35 apps for "collecting
  personal information beyond user authorization scope" — excessive-collection discipline;
  accidental, rectified in-window, no recurrence → passes the redemption gates. The finding
  attaches to the consumer chat app; the API surface shares the GLM models (whole-entity
  attribution, but the verdict is recorded-only either way). Source:
  [Securities Times](https://www.stcn.com/article/detail/1838869.html).
- The ZCode episode (2026): repo uploads tied to an opt-in feature — consented — and resolved with
  gate-4-grade rectification (the client open-sourced for community oversight, a security audit, a
  standing vulnerability-response mechanism). Matrix: no violation (consented); the episode is the
  reference case for gate 4. Sources: [每日经济新闻](https://www.nbd.com.cn),
  [zai-org/ZCode](https://github.com/zai-org/ZCode).
- Distillation (CISA naming) acquitted. The API has no published training opt-out
  ([privacy policy](https://docs.z.ai/legal-agreement/privacy-policy)) — silent → out of scope;
  and the takings fed the open GLM weights.

### DeepSeek — recorded as context; the flag dissolved 2026-09-28

- The PIPC finding (Apr 24 2025): full prompt content was transferred to ByteDance's Beijing
  Volcano Engine (China and US) without consent; no training opt-out at launch; misleading
  keystroke-collection disclosure; binding corrective orders. **Matrix: fed no model** (a serving-
  layer transfer) → out of scope — a real scandal, not a reciprocity concern (maintainer ruling,
  2026-09-28). Redemption: PIPC cited lack of intent/negligence; DeepSeek blocked the transfers
  (~Apr 10 2025), accepted all measures, added a Korea-specific PIPA annex, and the app returned to
  Korean stores — gates 3–6 pass. Sources:
  [PIPC](https://www.pipc.go.kr/eng/user/ltn/new/noticeDetail.do?bbsId=BBSMSTR_000000000001&nttId=2784),
  [Yonhap](https://www.yna.co.kr/view/AKR20250424001700530),
  [MBC](https://imnews.imbc.com/news/2025/econo/article/6711044_36737.html).
- Italy's Garante ban (Jan 30 2025, still in force) — attached to the same lane. Source:
  [ai-regulation.com](https://ai-regulation.com/deepseek-one-year-later-regulatory-storm-global-surge/).
- CISA also flags the "$5.6M training cost" claim as misleading — the misdirection fed the
  acquitted distillation; noted under it, not a separate flag.
- Distillation: acquitted — R1/V3 ship MIT.

### Xiaomi — recorded as context

No regulator action. The MiMo platform terms give no no-training guarantee
([terms](https://mimo.mi.com/docs/terms/user-agreement)) — silent → out of scope; community
benchmark-contamination scepticism only.

### StepFun — recorded, no effect

See the distillation campaigns above: proven, deliberate taking; unverifiable recipient. The
`stepfun` provider rule keeps its opt-in/opt-in training postures (independently sourced). The
`step-3.7-flash` model rule verified open-weight Apache-2.0 on 2026-09-28 (the stepfun-ai HF org).

## Part 3 — the inference providers and gateways

No provider in this part met the flag bar. The recorded items (all caveats under the matrix):

- **OpenRouter** — contributor-tier and `:free` listings train on request data (disclosed,
  tier-consented); as of Aug 2026 paid endpoints that train exist behind an explicit opt-in toggle.
  Provider-level retention variance is disclosed at
  [openrouter.ai/docs/guides/privacy/provider-logging](https://openrouter.ai/docs/guides/privacy/provider-logging).
- **NVIDIA** — API Trial Terms §3.3 collects User Content by default (disclosed). Open-weight
  Nemotron releases unaffected.
- **Nous Research** — Portal Privacy Mode defaults off
  ([policy](https://portal.nousresearch.com/privacy)). The May–Jun 2026 hermes-agent attribution
  row (a blanked GitHub issue, deleted comments, blocked users over EvoMap derivation claims) is a
  governance row, not a data-handling violation.
- **Sakana AI** — self-corrected benchmark overclaims (the "AI CUDA Engineer" eval exploit, the
  walked-back peer-review claim) — recorded.
  [sakana.ai/ai-cuda-engineer/](https://sakana.ai/ai-cuda-engineer/)
- **Phala** — a researcher showed compromised/revoked TEE machines could pass dstack attestation;
  Phala patched ([Phala reports](https://phala.com/tags/Reports)) — security, not data.
- **Chutes** — current policy states API content is never logged or used for training
  ([privacy](https://chutes.ai/privacy)); community friction (free-tier removal, KYC) and an
  unproven quantisation-variant suspicion. Sweep target under the license-violation vector: verify
  the community-license terms of every hosted weight family against MaaS serving.
- **DeepInfra** — opaque fp4 serving complaints; an unverified recollection of a Feb 2025
  stripped-licence Llama hosting story (could not re-verify — treat as unconfirmed). If ever
  proven, it lands under the license-violation vector.
- **SiliconFlow** — quantisation transparency complaints only; the API-key-leak saga was third
  parties' fault.
- **Novita AI, ZenMux, GMI Cloud, Upstage, Nebius, Fireworks, NanoGPT, Arcee, Groq, Cerebras,
  Cloudflare, Vercel, Hugging Face, Ollama** — clean: no criterion-fitting finding. Ollama cloud
  states prompt and response data is never logged or trained on; Groq and Fireworks carry public
  no-training commitments; Arcee's distillations ship open (liberation).

## Part 4 — the harnesses

- **Grok Build (xAI, pending rule)** — SCANDAL: the reference case for the lie escalator. Wire-
  capture-proven whole-repo upload including secrets, while xAI claimed "no code"; open-sourced
  under Apache-2.0 Jul 15 2026 as damage control — the licence is not a gate, and the proven lie
  keeps the redemption path closed while the closed Grok line's conduct continues. The harness rule
  lands pre-flagged. Sources:
  [The Hacker News](https://thehackernews.com/2026/07/grok-build-uploads-entire-git.html),
  [HN](https://news.ycombinator.com/item?id=48877371),
  [xAI](https://x.ai/news/grok-build-open-source).
- **GitHub Copilot CLI** — SCANDAL: carries the provider record (Doe v. GitHub; Apr 2026 default-on
  training for individual tiers). CLI-side handling is disclosed; the product-specific terms were
  deprecated Mar 2026 and retention is undocumented — a transparency gap on top.
- **Cursor** — recorded as context: the iOS-app login silently and irreversibly downgraded Privacy
  Mode (Legacy) (Jun 2026, [HN](https://news.ycombinator.com/item?id=48737226)); using Fable 5
  requires accepting provider-side retention regardless of Privacy Mode
  ([HN](https://news.ycombinator.com/item?id=48474552)); forum reports of connections to
  undocumented domains under Privacy Mode
  ([forum](https://forum.cursor.com/t/cursor-connects-to-multiple-undocumented-domains/162860));
  training happens by default whenever Privacy Mode is off, and no tier publishes retention
  day-counts ([census](https://www.digitalapplied.com/blog/coding-agent-data-terms-census-2026)).
  Context: acquired by SpaceX (Apr 2026) — the xAI family.
- **Cline** — recorded as context: disclosed provider-pass-through handling; the Feb 2026
  "Clinejection" supply-chain compromise made the company the victim, not the actor.
- **OpenCode** — recorded as context: always-on usage analytics on gateway paths
  ([opencode.ai/data](https://opencode.ai/data/)); an unauthenticated RCE CVE (Jan 2026) is
  security, not data. No training-on-user-code allegation.
- **Crush / Charm Hyper** — recorded as context: opt-out telemetry (`disable_metrics` /
  `CRUSH_DISABLE_METRICS`); Hyper's zero-data-retention claim is unaudited marketing.
- **Qwen Code** — recorded as context: CLI usage statistics have a documented opt-out; the consumer
  qwen.ai service is reported to train on chats by default
  ([AI UnSpun](https://aiunspun.com/privacy-checkup/qwen), disputed) — that attaches to the qwen
  provider surface (already `enforced` in the training tables).
- **Kimi Code** — recorded as context: no working privacy page (nginx placeholder) —
  training/retention unverifiable.
- **ZCode** — recorded, no effect: the repo-upload episode was tied to a consented opt-in feature
  and is resolved — the client open-sourced for community oversight with a security audit and a
  standing vulnerability-response mechanism. Nothing adverse found otherwise. Sources:
  [每日经济新闻](https://www.nbd.com.cn), [zai-org/ZCode](https://github.com/zai-org/ZCode).
- **AutoClaw** — recorded as context: the FAQ's "only necessary task context" claim is the same
  unfalsifiable class that failed for Grok Build; no wire-capture evidence either way.
- **Hermes Agent** — recorded as context: the attribution/moderation row (above, under Nous) — not
  user data.
- **Goose, Kilo Code, Pi, oh-my-pi, Reasonix, mmx** — clean: no findings in coverage and primary
  docs. "No findings" is not an audit.

## Part 5 — the mapping to the rule tables (2026-09-28)

| rule | state | legs |
| ---- | ----- | --- |
| `anthropic` | flagged | piracy → closed Claude (LibGen/PiLiMi, the approved settlement); character clause — never redeemable |
| `openai` | flagged | piracy → closed GPT + proven deletions; character clause — never redeemable |
| `xai` | flagged | X posts → closed Grok; the Grok Build proven lie |
| `github-copilot` + `copilot` harness | flagged | copyleft licence violations + piracy → closed models |
| `deepseek` | **unflagged 2026-09-28** | the Korea transfer fed no model and was redeemed; the disclosure redeemed; distillation liberated (R1/V3 ship MIT) — the flag's legs all dissolved |

Left unflagged, under the matrix (recorded, no effect — the liberation exception and the redemption
gates): `meta`, `mistral`, `moonshotai`, `zai`, `stepfun` (the unverifiable-recipient rule);
`azure-foundry` (the Megatron piracy attaches to the model maker, not the serving surface);
`google`, `alibaba`, `amazon-bedrock` (disclosed terms); all Part 3 providers; all Part 4 harnesses
except the two flagged. When the `grok` harness rule lands, it lands pre-flagged.

## Unverified items to watch

- The OpenAI "Books2 = LibGen" identification (conjecture).
- The DeepInfra Feb 2025 stripped-licence story (could not re-verify).
- Mistral's literal fee-to-opt-out (it is pay-for-privacy with a free toggle).
- The qwen.ai consumer-service default-training report (disputed).
- **Step 4 re-derivation** — if StepFun ever ships the Step 4 line open, the finding becomes
  liberation; if it ever serves closed, it becomes proprietary-mischief scandal.
- **The license-violation sweep** — audit the community-license terms of every hosted weight family
  against MaaS serving (Chutes, DeepInfra, SiliconFlow, Novita first).
- **Step-5-Preview** — a third-party Hugging Face repo of unverified provenance; not ruled.
