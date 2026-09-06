# Prompts — provider fold / individuation review (1788716755355)

The user's directives that produced
[1788716755355-provider-fold-individuation-review.md](./1788716755355-provider-fold-individuation-review.md),
paraphrased compactly; wording follows the session.

1. Refer to CONTRIBUTING.md. Commits 506a5f0 and 327922a added new
   harness, model, and providers. Use the more intelligent model to
   review their approach, and review potential folding into variations
   vs individuation of rules/ids/names. Consider the ids against the
   various indexes (models.dev one of them, others in DESIGN.md /
   CONTRIBUTING.md), so identities are resolved holistically — not by
   what individual contexts perceive. For instance, kimi and moonshot
   seem foldable, but what should their name be, what do the indexes
   consider them? Furthermore they still did ollama and ollama-cloud
   separately — for now they should have been folded, dealing with
   proper individuation later (harnesses reporting provider `ollama`
   with `:cloud`-suffixed models are really ollama-cloud; note the
   possible future `local` provider umbrella for local runtimes, with
   the caveat that local vendors still have their own policies). Other
   things: google vs google-vertex — should google become
   google-gemini, can they fold, are they the same thing? Cloudflare
   has Workers AI and AI Gateway. Peruse all known providers/harnesses
   and develop a report around what to do.

2. Also add a review task for their training: the dumber
   models/harnesses did the training research, double-check everything
   — find and cross-reference evidence; if the provider makes models,
   are they open or closed; do the policies state training on open or
   closed, leave it ambiguous, or differ; if ambiguous, assume it
   applies to both open and closed axes, unless the provider/company is
   exclusively an open-model or exclusively a closed-model company,
   then do whatever is appropriate to signal the type they don't do,
   and the handling. Consider what is involved for the ollama /
   ollama-cloud separation/individuation where `:cloud` model ids need
   to be sent to ollama-cloud as the model provider rather than
   `ollama`. Look for models that were incorrectly individuated as
   `:cloud` instead of aliased. Do a thorough comprehensive review of
   the ruleset, data, guidance, and the code — for divergences from the
   documents, redundancies, things that could be improved. Note the
   plan as we go, per plans.md, and keep me posted on the decisions
   made, so I can review or redo if anything was suspect.

3. Delegated research prompt (background agent): independent
   re-verification of the 24 provider training postures the commits
   set, against live policy pages, with per-axis verdicts
   (CONFIRMS/CONTRADICTS/NOT_FOUND + verbatim quotes), company
   open/closed model-production classification, and recommendations
   under the ambiguity/exclusivity rubric (D7).
