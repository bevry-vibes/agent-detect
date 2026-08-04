# commits

## how to commit

Each commit must contain one logical change and only work produced in this conversation.

## commit message format

All commits MUST follow the Conventional Commits 1.0.0 specification:

- Format: `<type>(<scope>): <short summary in present tense>`
- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`.
- Breaking Changes: Append `!` to the type or include `BREAKING CHANGE:` in the body.
- Atomicity: One logical change per commit. Do not mix concerns.
- Example: `feat(api): add endpoint for user profile retrieval`

**Title** — Target ≤ 50 characters, hard cap at 72 (the limit `git log --oneline`, `git shortlog`, GitHub's PR list, and most changelog generators assume).

**Body** — A brief meaning/purpose summary of each distinct change in the commit, in the order the diff presents them — one or two lines per change.

**Shell-safe paragraphs** — Each `git commit -m` argument creates one paragraph. Do **not** put `\n` or `\n\n` inside an ordinary quoted `-m` argument: common shells pass those characters literally instead of turning them into line breaks. Use another `-m` for each paragraph, or write a complete message under `.temp/` and pass it with `git commit --file`. For example:

```text
git commit -m "docs(scope): summarize change" -m "Explain the purpose." -m "Co-authored-by: pi - MiniMax-M3 <pi-minimaxm3@local>"
```

## commit identities and verification

A commit has two **separate** identities: an **author / committer** (always the system git user) and a **co-author trailer** (the agent's harness + model). They are on different lines, in different roles, and follow different rules. The two identities are checked together by the **mandatory post-commit verification** below — never commit, amend, or push without running it and reading every line.

### author + committer

**Author + committer = system git identity, always.** `git config --get user.name` / `user.email` is the only author / committer an agent commit may record. The agent's harness and model (`pi`, `grokbuild`, `minimaxcode`, …) must never appear in the author or committer fields.

If either `user.name` and `user.email` are unset or empty, prompt the user for what to configure for them globally, then apply globally. Never assume.

### co-author trailer

**Co-author trailer = agent harness + model, always.** Every agent-authored commit must end with exactly one `Co-authored-by:` trailer identifying the active harness and model. The trailer is a credit line, not a stand-in for the author; it sits at the end of the message body, on its own line, after a blank line.

Co-author trailer must always be the last line, preceded by blank line, inside the commit message.

Never use `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` env vars, or `-c user.name=…`, `-c user.email=…`, or other`git -c user.*=…` arguments, to attempt to set or attempt to inform the co-author trailer, as they are for the author+committer, not the co-author trailer.

Never guess the co-author identity from git logs, as that may not reflect the current session agent.

Always infer the co-author identity fresh for each new session, and fresh upon model changes within a session. Never re-use a co-author identity from a prior session.

#### calculating the co-author identity

Each harness and model requires different techniques for detection. Note their inputs and outputs below. Keep updated with new inferences:

- `pi`: harness detectable by `PI_CODING_AGENT=true`, model detectable by `model_change` metadata from the current pi session under `$HOME/.pi/agent/sessions/`
- `Grok Build`: harness detectable by @todo, model detectable by @todo
- `MiniMax Code`: harness detectable by @todo, model detectable by @todo
- `Cline` (CLI): harness detectable by `CLINE_*` env vars and a `cline` ancestor process; interface + model detectable via `~/.cline/data` (providers.json, own session json, messages.json) — full procedure in @./self-awareness.md

Parallel sessions exist, so do not blindly pick the newest one globally. When unable to infder, stop and inform the user instead of guessing.

#### formatting the co-author identity trailer

**Trailer format** — `Co-authored-by: ${harness} - ${model} <${lowercase-alphanumeric-harness}-${lowercase-alphanumeric-model}@local>`, on its own line, preceded by a blank line. The `@local` TLD is not a real address. Known co-author identities:

- `Co-authored-by: Grok Build - Grok 4.5 <grokbuild-grok45@local>`
- `Co-authored-by: MiniMax Code - MiniMax-M3 <minimaxcode-minimaxm3@local>`
- `Co-authored-by: pi - MiniMax-M3 <pi-minimaxm3@local>`
- `Co-authored-by: Cline - Kimi K3 <cline-kimik3@local>`

When a new harness/model pair takes over, append its trailer to this list.
