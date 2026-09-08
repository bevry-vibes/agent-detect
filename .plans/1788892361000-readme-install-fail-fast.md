# README installation: fail fast on bad downloads, pre-empt package-manager guesses

Assisted-by: ZCode · GLM 5.3 <zcode-zaicodingplan-glm53@local>

> Prompts: [1788892361000-readme-install-fail-fast.prompts.md](1788892361000-readme-install-fail-fast.prompts.md)

## Context

A downstream session (aural-keyboard) hit two README-guided failure modes while
bootstrapping `agent-detect` on macOS aarch64:

1. `npx agent-detect` / `npx @bevry/agent-detect` / `npx github:bevry-vibes/agent-detect`
   all fail — the tool is not on npm, but nothing in the README says so, so
   package-manager guesses come first.
2. The sh download example used `curl -Lo` without `-f`; a guessed asset name
   (`agent-detect-macos-arm64` — GitHub auto-naming says arm64, our assets say
   aarch64) 404s, and curl silently saves the "Not Found" body as the binary.
   `chmod +x` succeeds; executing the 9-byte text file then fails with a baffling
   `error: unable to find 'Found' in PATH` instead of anything pointing at the
   download.

## Change

README installation section only:

- State up front that there is no npm/crates.io package — the release binaries are
  the only distribution (kills the `npx` guessing).
- `curl -Lo` → `curl -fLo`, with a load-bearing-flag note explaining the silent-404
  failure mode it prevents (`Invoke-WebRequest` already fails on HTTP errors, so the
  powershell example is unchanged).
- Point the sh example's comment at the asset table so the platform/arch name is
  substituted, not reconstructed from memory.

## Verification

- `zig build test` and `zig build` pass (repo rule: build before commit).
- The flagged command re-checked against the live failure transcript above.
- Docs-only diff — no code paths touched.
