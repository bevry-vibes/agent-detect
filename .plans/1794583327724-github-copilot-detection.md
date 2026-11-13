# GitHub Copilot desktop detection and release

Companion: [.plans/1794583327724-github-copilot-detection.prompts.md](./1794583327724-github-copilot-detection.prompts.md)

## status

- Implementation is committed on the feature branch. The registry site was deployed before the model id was corrected; regenerate `site/public/data/` and redeploy after the pull request merges.
- The pull request to `main` is open; the binary release is gated on its merge.
- The Copilot Fusion model id is `copilotfusion` (not the session store's generic `auto`); the branch's commit trailers are normalized to the matching `githubcopilot-githubcopilot-copilotfusion` agent id.
- Before release, normalize every commit trailer to the canonical agent id and keep this plan with its prompt companion in the branch.

## goal

Detect the GitHub Copilot desktop app as a first-class harness, add real identity and manual-capture fixtures for the current Copilot Fusion (`auto`) selection, and publish the registry update without asserting which backend model served any response.

## decisions

1. **Canonical identity:** harness rule name `github-copilot`, label `GitHub Copilot`, stable alphanumeric id `githubcopilot`. Accept `GitHub Copilot.app` and `Copilot App` as aliases; the latter is user-requested and is not presented as an official product name.
2. **Detection:** use the app session marker and the `copilot-runtime` → `github` process ancestry. Read provider/model from `COPILOT_MODEL` when present, otherwise from the newest relevant non-archived session in `~/.copilot/data.db`.
3. **Dynamic model selection:** record the **Copilot Fusion** route with canonical name/id `copilotfusion` (label `Copilot Fusion`); the session store's generic selector `auto` is folded to it inside Copilot sessions only. The database establishes the selected route, not the backend model used by any completion; do not assert GPT-6 or another backend model.
4. **Capture workflow:** Copilot.app has no supported headless launcher that selects a model. Run each `from-capture` manually from its live app session; keep `meta.capture_kind = "manual"`.
5. **Commit attribution:** build first and use `agent-detect trailer co-author` as the sole `Co-authored-by` trailer. Live detection needs no filter. The CLI accepts either no recipe dimensions or all three (`--harness`, `--provider`, `--model`); a harness-only filter is not supported.
6. **Release gate:** do not tag from the feature branch. Follow the repository release runbook from `main` after the pull request merges.

## implementation

- Add the GitHub Copilot desktop harness rule and its ancestry-gated detector.
- Register Copilot Fusion as the canonical model rule `copilotfusion` (label `Copilot Fusion`), folding the session store's `auto` selector inside Copilot sessions without inferring the serving model.
- Regenerate identity fixtures, the real manual capture, `fixtures/index-data.json`, and site data with the canonical `githubcopilot` id.
- Add focused coverage for the label, aliases, capture metadata, and the unknown backend model.
- Document the manual capture limitation and the canonical harness identity.

## verification

- `zig build`
- `zig build test`
- `agent-detect-dev fixtures index --check`
- `cd site && deno task data && deno task check`
- Verify the deployed agent JSON and index identify `GitHub Copilot` as `githubcopilot` and expose both requested aliases.
- Verify each commit has one generated co-author trailer using the same `githubcopilot` identity.

## remaining release step

After the pull request merges to `main`, bump the calver version, build and verify the new version, create an annotated tag with release notes, push the tag, and confirm the GitHub release workflow publishes successfully.

## provenance

The companion records the user's prompts verbatim. Agent selection: GitHub Copilot, Copilot Fusion (`auto`); the backend model is not observable from the session data.
