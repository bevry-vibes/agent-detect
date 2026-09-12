# Scandal research — providers and harnesses

Generated: 2026-09-10, by the method in [README.md](./README.md).
Verdicts are judgements against the criterion below, not legal
findings. Sources follow each finding. Update this file with the same
method; never edit a verdict without a source.

## The criterion (the liberation ethic)

It is fine for reciprocal models to train on reciprocal models — they
give back. It is fine for reciprocal models to train on
non-reciprocal models — they Robin Hood it back to the commons. It is
not fine for closed models to take from reciprocal models — nothing
is given back. Therefore:

- **(a) Piracy of third-party content** — books, articles, or code
  scraped without a license → scandal, whoever does it, whatever the
  output.
- **(b) User-data betrayal** — training on user or customer data
  against the stated terms, or by default without consent; charging
  for the opt-out; transferring user data to third parties without
  consent → scandal.
- **(c) Distillation** → scandal only when a closed output takes from
  a reciprocal source. Distillation into open weights that ship back
  is liberation, whatever the source. Closed-on-closed is not a
  commons concern.
- **(d) False claims about data handling**, proven by wire capture or
  admission → scandal.
- **The purpose test (ruling, 2026-09-10).** Judge every finding by
  its purpose, not only by its act. A taking in service of
  reciprocal purposes — it feeds weights that ship back — is fair
  use: let it slide, and note it as a caveat. A taking in service of
  non-reciprocal purposes — it feeds enclosure — violates fair use:
  flag it. Fair use is a right that overrides enforcement that would
  otherwise be draconian, and consent is not needed for fair use.
  That is the balance. Flagging every user-data finding would leave
  almost no reciprocal options, because all AI companies train on
  whatever they can get — the purpose test is what separates the
  fair use from the violation.

A disclosed, terms-consented behaviour is a **caveat**, not a scandal.
An unproven suspicion is a **caveat**, never a scandal.

## Part 1 — the big western labs

### Anthropic — SCANDAL: (a), (b)

- (a) Trained Claude on ~7M books downloaded from LibGen and PiLiMi.
  Bartz v. Anthropic (2024): Judge Alsup held that training legally
  purchased books was fair use, but the pirated downloads were not.
  The $1.5B settlement (~500k works, ~$3,000 per book, dataset
  destruction) was announced Sep 5 2025 and approved Jul 20 2026.
  Sources: [Authors Guild](https://authorsguild.org/advocacy/artificial-intelligence/what-authors-need-to-know-about-the-anthropic-settlement/),
  [AP](https://apnews.com/article/anthropic-copyright-authors-settlement-training-f294266bc79a16ec90d2ddccdf435164),
  [Reuters](https://www.reuters.com/world/us/judge-approves-anthropics-15-billion-settlement-copyright-lawsuit-2026-07-20/).
- (b) Consumer default-on training of chats, announced Aug 2025;
  users had to opt out by Sep 28 2025 (extended Oct 8 2025). Source:
  [Goldfarb](https://www.goldfarb.com/updates-to-anthropics-claude-ai-terms-and-privacy-policy-what-you-need-to-know/).
- (b) Reddit v. Anthropic (Jun 2025): scraping since 2021, including
  deleted posts, over 100k bot accesses, against the licence and
  terms; remanded to state court 2026. Source:
  [Courthouse News](https://www.courthousenews.com/reddit-privacy-case-against-anthropic-kicked-back-to-state-court/).
- (b) The Bedrock "Covered Models" episode (Aug–Sep 2026): Claude
  Fable 5 / Mythos 5 on AWS required a `provider_data_share` mode —
  30-day retention of prompts and outputs shared with Anthropic, no
  zero-retention, or the model reported unavailable. Anthropic
  revised the policy after backlash on Sep 1 2026. Sources:
  [AWS blog](https://aws.amazon.com/blogs/aws/anthropic-claude-fable-5-on-aws-mythos-class-capabilities-with-built-in-safeguards-now-available/),
  [CNBC](https://www.cnbc.com/2026/09/01/anthropic-data-retention.html),
  [Securosis](https://securosis.com/blog/aws-destroyed-the-value-proposition-for-bedrock/).
- The Feb 2026 distillation report (DeepSeek, Moonshot, MiniMax named)
  is a ToS-violation story about closed inputs; under clause (c) it
  is not a scandal for its subjects. Source:
  [Anthropic](https://www.anthropic.com/news/detecting-and-preventing-distillation-attacks).

### OpenAI — SCANDAL: (a), (d)

- (a) Books1 (tied to the Books3/Bibliotik dump) and Books2 (widely
  suspected LibGen, never confirmed). Suits: Authors Guild (Sep
  2023), NYT + Microsoft (Dec 2023), ~400 Alden newspapers (Apr
  2024), Britannica / Merriam-Webster (Mar 2026, ~100k articles),
  consolidated In re OpenAI (ongoing 2026). Sources:
  [The Atlantic](https://www.theatlantic.com/technology/archive/2025/03/libgen-meta-openai/682093/),
  [Reuters](https://www.reuters.com/legal/litigation/encyclopedia-britannica-sues-openai-over-ai-training-2026-03-16/),
  [NPR](https://www.npr.org/2024/04/30/1248141220/lawsuit-openai-microsoft-copyright-infringement-newspaper-tribune-post).
- (d) OpenAI allegedly deleted its pirated-book datasets during
  litigation. Source:
  [Ars Technica](https://arstechnica.com/tech-policy/2025/12/openai-desperate-to-avoid-explaining-why-it-deleted-pirated-book-datasets/).
- (d) The NYT-led sanctions motion (Jul 9 2026): alleged concealment
  of tools and datasets, deletion of user chats against a
  preservation order. Sources:
  [Reuters](https://www.reuters.com/legal/litigation/new-york-times-led-group-asks-court-sanction-openai-us-copyright-dispute-2026-07-09/),
  [Variety](https://variety.com/2026/digital/news/new-york-times-news-outlets-accuse-openai-of-lying-lawsuit-1236805648/).
- (b, allegation stage) Canada OPC PIPEDA finding 2026-002: personal
  information retained in training use.

### Meta — SCANDAL: (a)

- (a) Kadrey v. Meta: staff torrented at least 81.7 TB from
  LibGen/Books3 in spring 2023; unsealed filings (Jan 2025) show
  Zuckerberg personally approved LibGen use despite staff flagging "a
  dataset we know to be pirated" and discussing scrubbing piracy
  markers. The Jun 2025 fair-use ruling was expressly narrow. Sources:
  [The Guardian](https://www.theguardian.com/technology/2025/jan/10/mark-zuckerberg-meta-books-ai-models-sarah-silverman),
  [The Atlantic](https://www.theatlantic.com/technology/archive/2025/03/libgen-meta-openai/682093/).

### Mistral AI — SCANDAL: (a), (b)

- (a) Mediapart investigation (Feb 26 2026): Mistral Large 3 trained
  on copyrighted books (Harry Potter), songs (Elton John lyrics),
  and articles without authorisation. Sources:
  [OECD.AI incident](https://oecd.ai/en/incidents/2026-02-23-c733),
  [Mediapart via chatgptiseatingtheworld](https://chatgptiseatingtheworld.com/2026/02/26/).
- (a) Co-founder Guillaume Lample, at Meta FAIR, was ensnared in the
  LibGen torrenting revelations ("everyone is using lib-gen"). Source:
  [OECD.AI incident](https://oecd.ai/en/incidents/2025-12-23-9c7e).
- (b) Le Chat free and consumer tiers train on inputs and outputs by
  default; paid tiers do not — privacy-by-default requires paying. A
  free settings toggle exists, so the literal "fee to opt out" claim
  is not verified, but the pay-for-privacy shape stands. Sources:
  [Mistral help](https://help.mistral.ai/en/articles/455207-can-i-opt-out-of-my-input-or-output-data-being-used-for-training),
  [HN](https://news.ycombinator.com/item?id=49535284).
- Not a scandal under (c): Mistral's distillation work ships as open
  weights — liberation per the criterion.

### Microsoft — SCANDAL on the training side; Azure AI Foundry surface CLEAN

- (a) Authors (Kai Bird, Jia Tolentino, Daniel Okrent) sued Jun 25
  2025 over pirated books used to train Megatron. Sources:
  [The Guardian](https://www.theguardian.com/technology/2025/jun/26/microsoft-ai-authors-lawsuit),
  [Reuters](https://www.reuters.com/legal/litigation/microsoft-sued-by-authors-over-use-of-books-in-ai-training-2025-06-25/).
- (a, co-defendant) Named in the NYT and Alden suits over Copilot and
  ChatGPT article scraping; still live Sep 2026. Source:
  [Chicago Tribune](https://www.chicagotribune.com/2026/09/04/fair-use-copyright-case/).
- No criterion-fitting finding against the Azure AI Foundry serving
  surface itself.

### GitHub Copilot (provider + harness) — SCANDAL: (a), (b)

- (a) Doe v. GitHub / Microsoft / OpenAI (filed Nov 2022): the model
  trained on public repositories including copyleft code, with
  licence and attribution stripped — the canonical (a) case for code.
  A 2023 allegation says GitHub varied output to defeat near-verbatim
  detection. Sources:
  [EFF via HN](https://news.ycombinator.com/item?id=33468849),
  [HN](https://news.ycombinator.com/item?id=36271664).
- (b) From Apr 24 2026, Free/Pro/Pro+ interaction data (prompts and
  suggestions) trains models by default; Business and Enterprise are
  excluded; an opt-out exists. Sources:
  [GitHub docs](https://docs.github.com/copilot/how-tos/manage-your-account/managing-copilot-policies-as-an-individual-subscriber),
  [WinBuzzer](https://winbuzzer.com/2026/03/26/github-copilot-ai-training-data-default-opt-out-xcxwbn/).

### Google — CAVEAT

- (a, alleged, unproven) In re Google Generative AI Copyright
  Litigation: authors allege pirated books; class-cert hearing Feb
  2026. Source:
  [Authors Alliance](https://www.authorsalliance.org/2026/01/27/ai-class-action-litigation-update-books-where-things-stand-in-early-2026/).
- (b, disclosed) The Gemini API / AI Studio free tier trains on
  prompts and outputs by default with human review; the only real
  opt-outs are attaching a billing account or disabling Gemini Apps
  Activity. Paid, Vertex, and enterprise tiers do not train.
  Disclosed in terms, so a caveat, not a scandal. Sources:
  [Google AI forum](https://discuss.ai.google.dev/t/data-privacy-in-use-google-ai-studio/34455),
  [Redact](https://redact.dev/blog/gemini-api-terms-2025).

### Amazon (Bedrock) — CAVEAT

- AWS states Bedrock does not train on customer data. The Fable 5
  `provider_data_share` episode attaches to Anthropic (see above);
  Bedrock was the venue, not the actor. Sources:
  [AWS](https://repost.aws/knowledge-center/amazon-bedrock-model-data-use),
  [Securosis](https://securosis.com/blog/aws-destroyed-the-value-proposition-for-bedrock/).

### xAI — SCANDAL: (b), (d)

- (b) X fed the posts of 60M+ EU users into Grok training from May
  2024, default-on, no prior notice; NOYB filed nine GDPR complaints
  (Aug 2024); training suspended Sep 2024 under Irish DPC pressure.
  Source: [NOYB](https://noyb.eu/en/twitters-ai-plans-hit-9-more-gdpr-complaints).
- (b)+(d) Grok Build (the CLI coding agent): a wire-level analysis
  (Jul 2026) showed it uploading entire git repositories — full
  history and unredacted `.env` secrets, and files the agent was told
  not to read — to xAI cloud storage, while xAI claimed "no code" was
  uploaded. xAI acknowledged the retention issue, open-sourced Grok
  Build under Apache-2.0 on Jul 15 2026, and pledged deletion.
  Sources:
  [The Hacker News](https://thehackernews.com/2026/07/grok-build-uploads-entire-git.html),
  [TNW](https://thenextweb.com/news/grok-build-uploaded-entire-git-repositories-secrets),
  [HN wire capture](https://news.ycombinator.com/item?id=48877371),
  [xAI](https://x.ai/news/grok-build-open-source).

## Part 2 — the Chinese labs

### The distillation reports — judged under clause (c)

Anthropic's Feb 2026 report named DeepSeek, Moonshot, and MiniMax
(hundreds of fraudulent accounts, 3.4M+ exchanges for Moonshot; 13M+
for MiniMax). A separate Anthropic letter to Congress (Jun 24 2026)
named Alibaba (28.8M+ exchanges via ~25k accounts). The joint
CISA/NSA/FBI advisory AA26-251A (Sep 8 2026) named DeepSeek,
Moonshot, Alibaba, MiniMax, StepFun, and Z.ai. Under clause (c) these
are **not scandals**: the inputs were closed models, and the outputs
are weights that ship back — liberation. Sources:
[Anthropic](https://www.anthropic.com/news/detecting-and-preventing-distillation-attacks),
[Reuters](https://www.reuters.com/world/china/anthropic-says-alibaba-illicitly-extracted-claude-ai-model-capabilities-2026-06-24/),
[CISA](https://www.cisa.gov/news-events/cybersecurity-advisories/aa26-251a).

### Alibaba — CAVEAT (distillation acquitted; per-surface divergence)

- Distillation judged under (c): the distilled Qwen weights ship
  back; the re-enclosed flagship (Qwen3.6-Max, closed) took only from
  a closed source — not a commons concern.
- Model Studio says customer data is "never used for model training"
  ([privacy notice](https://www.alibabacloud.com/help/en/model-studio/privacy-notice)),
  but the Coding Plan docs carry a data-usage authorisation clause,
  and the Chinese-language FAQ states data will be used for training
  ([Coding Plan docs](https://help.aliyun.com/en/model-studio/coding-plan)).
  A per-surface divergence to record in the rule comments, not a
  scandal (disclosed).

### Moonshot AI — SCANDAL: (b)

- China's National Network and Information Security Information
  Notification Center named the Kimi app (May 20 2025) among 35 apps
  illegally collecting personal information — collection inconsistent
  with stated business functions. Source:
  [Securities Times](https://www.stcn.com/article/detail/1838869.html).
- The API policy permits training on user prompts and uploads by
  default, with a contact-based opt-out only and no published
  retention period. Source:
  [policy analysis](https://gist.github.com/gadgetb0y/11931119946c2e9dcae0a438fdefe0d5).
- The Kimi K3 weights shipped Jul 26–27 2026 (modified-MIT licence)
  — the "unshipped weights" claim is outdated. The White House
  accusation (Jul 22 2026) imposed no sanction. Distillation: acquitted
  under (c). Source:
  [CyberScoop](https://cyberscoop.com/white-house-accuses-moonshot-ai-anthropic-model-distillation/).

### MiniMax — CAVEAT

- Distillation acquitted under (c) (open-weight outputs; the report
  says it even used prompt injections to make Claude Code believe it
  was a MiniMax product — a ToS story, not a commons one).
- The minimax.io privacy policy (updated Mar 30 2026) commits to no
  fixed retention period and no clear no-training commitment. Source:
  [policy](https://platform.minimax.io/protocol/privacy-policy).

### Z.ai / Zhipu — SCANDAL: (b), with a surface question

- The CAC named Zhipu Qingyan (May 20 2025) for "collecting personal
  information beyond user authorization scope". Source:
  [Securities Times](https://www.stcn.com/article/detail/1838869.html).
  The finding attaches to the consumer chat app; the API surface
  shares the GLM models. Flag or leave absent is a maintainer call.
- Distillation (CISA naming) acquitted under (c). The API has no
  published training opt-out ([privacy policy](https://docs.z.ai/legal-agreement/privacy-policy)).
- Nothing adverse found on ZCode or AutoClaw client behaviour.

### DeepSeek — SCANDAL: (b)

- Korea's PIPC (Apr 24 2025): full prompt content was transferred to
  ByteDance's Beijing Volcano Engine (China and US) without consent;
  no training opt-out at launch; misleading keystroke-collection
  disclosure; binding corrective orders. Source:
  [PIPC](https://www.pipc.go.kr/eng/user/ltn/new/noticeDetail.do?bbsId=BBSMSTR_000000000001&nttId=2784).
- Italy's Garante banned DeepSeek (Jan 30 2025, still in force).
  Source: [ai-regulation.com](https://ai-regulation.com/deepseek-one-year-later-regulatory-storm-global-surge/).
- CISA also flags the "$5.6M training cost" claim as misleading
  (efficiency misrepresentation tied to the hidden distillation).
  Distillation itself: acquitted under (c) — R1/V3 ship MIT.

### Xiaomi — CAVEAT

No regulator action, no official-report naming. The MiMo platform
terms give no no-training guarantee
([terms](https://mimo.mi.com/docs/terms/user-agreement)); community
benchmark-contamination scepticism only.

### StepFun — CAVEAT

Named in CISA AA26-251A for distillation (Claude and GPT families
into the Step 4 model). Acquitted under (c) if Step 4 ships open
(openness currently unverified in our rule table — verify before any
flag). Source: [CISA](https://www.cisa.gov/news-events/cybersecurity-advisories/aa26-251a).

## Part 3 — the inference providers and gateways

No provider in this part met the scandal bar. The caveats:

- **OpenRouter** — CAVEAT: contributor-tier and `:free` listings
  train on request data (disclosed, tier-consented); as of Aug 2026
  paid endpoints that train exist behind an explicit opt-in toggle.
  Provider-level retention variance is disclosed at
  [openrouter.ai/docs/guides/privacy/provider-logging](https://openrouter.ai/docs/guides/privacy/provider-logging).
- **NVIDIA** — CAVEAT: API Trial Terms §3.3 collects User Content by
  default (disclosed). Open-weight Nemotron releases unaffected.
- **Nous Research** — CAVEAT: Portal Privacy Mode defaults off
  ([policy](https://portal.nousresearch.com/privacy)). The May–Jun
  2026 hermes-agent attribution row (a blanked GitHub issue, deleted
  comments, blocked users over EvoMap derivation claims) is a
  governance row, not a data-handling violation.
- **Sakana AI** — CAVEAT: the Feb 2025 "AI CUDA Engineer" benchmark
  claims were gamed by exploiting its own eval harness; Sakana
  admitted and corrected ([sakana.ai/ai-cuda-engineer/](https://sakana.ai/ai-cuda-engineer/)).
  The Mar 2025 "passed peer review" claim was walked back under
  organiser pushback. Self-corrected overclaims — caveat, not
  scandal.
- **Phala** — CAVEAT: a researcher showed compromised/revoked TEE
  machines could pass dstack attestation (a real hole in the core
  marketing); Phala patched ([Phala reports](https://phala.com/tags/Reports)).
- **Chutes** — CAVEAT: current policy states API content is never
  logged or used for training ([privacy](https://chutes.ai/privacy));
  community friction (free-tier removal, KYC) and an unproven
  quantisation-variant suspicion.
- **DeepInfra** — CAVEAT: community complaints of opaque fp4 serving;
  an unverified recollection of a Feb 2025 stripped-licence Llama
  hosting story (could not re-verify — treat as unconfirmed).
- **SiliconFlow** — CAVEAT: quantisation transparency complaints
  only; the API-key-leak saga was third parties' fault.
- **Novita AI, ZenMux, GMI Cloud, Upstage, Nebius, Fireworks,
  NanoGPT, Arcee, Groq, Cerebras, Cloudflare, Vercel, Hugging Face,
  Ollama** — CLEAN: no criterion-fitting finding. Ollama cloud states
  prompt and response data is never logged or trained on; Groq and
  Fireworks carry public no-training commitments; Arcee's
  distillations ship open (liberation).

## Part 4 — the harnesses

- **Grok Build (xAI, pending rule)** — SCANDAL (d): the reference
  case. Wire-capture-proven whole-repo upload including secrets,
  while xAI claimed "no code"; open-sourced under Apache-2.0 Jul 15
  2026 as damage control. Notably: the harness is now open licensed,
  which proves licence and data use do not correlate. Sources:
  [The Hacker News](https://thehackernews.com/2026/07/grok-build-uploads-entire-git.html),
  [HN](https://news.ycombinator.com/item?id=48877371),
  [xAI](https://x.ai/news/grok-build-open-source).
- **GitHub Copilot CLI** — SCANDAL: carries the provider record
  (Doe v. GitHub; Apr 2026 default-on training for individual
  tiers). CLI-side handling is disclosed; the product-specific terms
  were deprecated Mar 2026 and retention is undocumented — a
  transparency gap on top.
- **Cursor** — CAVEAT: the iOS-app login silently and irreversibly
  downgraded Privacy Mode (Legacy) (Jun 2026,
  [HN](https://news.ycombinator.com/item?id=48737226)); using Fable 5
  requires accepting provider-side retention regardless of Privacy
  Mode ([HN](https://news.ycombinator.com/item?id=48474552)); forum
  reports of connections to undocumented domains under Privacy Mode
  ([forum](https://forum.cursor.com/t/cursor-connects-to-multiple-undocumented-domains/162860));
  training happens by default whenever Privacy Mode is off, and no
  tier publishes retention day-counts
  ([census](https://www.digitalapplied.com/blog/coding-agent-data-terms-census-2026)).
  Context: acquired by SpaceX (Apr 2026) — the xAI family.
- **Cline** — CAVEAT: disclosed provider-pass-through handling; the
  Feb 2026 "Clinejection" supply-chain compromise made the company
  the victim, not the actor.
- **OpenCode** — CAVEAT: always-on usage analytics on gateway paths
  ([opencode.ai/data](https://opencode.ai/data/)); an unauthenticated
  RCE CVE (Jan 2026) is security, not data. No training-on-user-code
  allegation.
- **Crush / Charm Hyper** — CAVEAT: opt-out telemetry
  (`disable_metrics` / `CRUSH_DISABLE_METRICS`); Hyper's
  zero-data-retention claim is unaudited marketing.
- **Qwen Code** — CAVEAT: CLI usage statistics have a documented
  opt-out; the consumer qwen.ai service is reported to train on
  chats by default ([AI UnSpun](https://aiunspun.com/privacy-checkup/qwen),
  disputed) — that attaches to the qwen provider surface (already
  `enforced` in our tables).
- **Kimi Code** — CAVEAT: no working privacy page (nginx placeholder)
  — training/retention unverifiable.
- **ZCode** — CAVEAT: training status undocumented; the privacy
  policy scope-excludes business-customer content and the DPA links
  404.
- **AutoClaw** — CAVEAT: the FAQ's "only necessary task context" claim
  is the same unfalsifiable class that failed for Grok Build; no
  wire-capture evidence either way.
- **Hermes Agent** — CAVEAT: the attribution/moderation row (above,
  under Nous) — not user data.
- **Goose, Kilo Code, Pi, oh-my-pi, Reasonix, mmx** — CLEAN: no
  findings in coverage and primary docs. "No findings" is not an
  audit.

## Part 5 — the mapping to rules (2026-09-10 recommendation)

Flag `reciprocity_scandal: true`, with sources in
`reciprocity_scandal_sources`. The purpose test applied: each flagged
taking fed enclosure, not weights that ship back.

| rule | clauses | headline |
| ---- | ------- | -------- |
| `anthropic` | (a)(b) | LibGen/PiLiMi, $1.5B settlement; Reddit suit; consumer default training; the Bedrock data-share episode — all fed closed Claude |
| `openai` | (a)(d) | Books1/Books2 + four suits; the sanctions motion — fed closed GPT |
| `xai` | (b)(d) | X posts → Grok by default; Grok Build repo upload — fed closed Grok |
| `github-copilot` + `copilot` harness | (a)(b) | Doe v. GitHub; Apr 2026 default-on training — fed GitHub's closed models |
| `deepseek` | (b) | PIPC: prompts to ByteDance without consent; Italy ban — a transfer with no reciprocal purpose |

Leave absent, moved by the purpose test (2026-09-10) — their takings
fed weights that ship back (fair use; caveats, not scandals):

| rule | finding that slid | why |
| ---- | ----------------- | --- |
| `meta` | LibGen/Books3 (81.7 TB, Kadrey) | fed the open Llama weights; borderline — re-flag if the re-enclosure reads as the dominant purpose |
| `mistral` | Mediapart books; Le Chat free-tier training | fed Apache-2.0 open weights; pay-for-privacy stays a caveat |
| `moonshotai` | CAC app finding; API default training | fed the K3 weights, which shipped Jul 2026 |
| `zai` | CAC Qingyan finding | fed the GLM open weights; the surface question dissolves |

Leave absent, unchanged: the distillation-acquitted labs (DeepSeek,
Moonshot, MiniMax, Alibaba, StepFun, Z.ai — clause (c));
`azure-foundry` (the Megatron piracy attaches to the model maker, not
the serving surface); `google`, `alibaba`, `amazon-bedrock`
(disclosed terms); all Part 3 providers (caveats); all Part 4
harnesses except the two flagged. When the `grok` harness rule lands,
it lands pre-flagged.

Unverified items to watch: the OpenAI "Books2 = LibGen" identification
(conjecture); the DeepInfra Feb 2025 stripped-licence story (could not
re-verify); Mistral's literal fee-to-opt-out (it is pay-for-privacy
with a free toggle); the qwen.ai consumer-service default-training
report (disputed).
