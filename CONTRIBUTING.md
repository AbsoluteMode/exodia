# Contributing to Exodia

Thanks for helping. Exodia is a native macOS app (Swift, SwiftUI, AppKit,
SwiftPM). Users bring their own provider keys or OpenAI-compatible endpoints.
Pull requests that preserve this independence from Exodia services are welcome.

## Ground rules

- No Exodia-owned servers, accounts or telemetry. Network calls are limited
  to user-configured providers, monitoring sources and credential stores,
  model/OpenCode downloads and the Sparkle update feed. `Tests/SidekeyTests/CloudRemovalTests.swift`
  enforces this at build time.
- Privacy in logs: never interpolate transcripts, prompts, replies or API keys
  into `os_log`. `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift`
  guards the provider paths that carry this content.
- No emoji in code, comments or commit messages.
- Hotkeys follow `docs/hotkey.md` (single `HotkeyHintView` entry point, a row
  in the Help window for every new shortcut).
- Behavioural changes that need a "why" get a short decision document in
  `docs/decisions/YYYY-MM-DD-<slug>.md` and a `// WHY:` anchor next to the
  code. Read the linked document before changing code that carries one.

## Building

Use macOS 14.2 or newer and Xcode 26 or newer with a Swift 6 toolchain
(`swift-tools-version:6.0`, Swift 5 language mode). No Apple Developer
account, Developer ID certificate or notarization is required.

```bash
git clone https://github.com/AbsoluteMode/exodia.git
cd exodia
./scripts/dev-run.sh --run
swift test
```

The script creates `build/Exodia-Beta-dev.app` for testing on the same Mac.
It uses an existing local `Sidekey Dev` signing identity or falls back to
ad-hoc signing. Use it rather than `swift run` to preserve the app bundle
path and identity. Ad-hoc rebuilds may require granting macOS permissions
again. This development bundle is separate from ready-made releases and uses
`0.0.0-dev` / build `9999`, so the binary feed does not overwrite local
customizations. Update your source with the agent, preserve local changes and
rebuild with the same script.

## Pull requests

1. Branch from `main`.
2. Keep the change focused; add or update tests next to the code you touch.
3. `swift build` and `swift test` must pass locally.
4. Describe what changed and why in the PR body. Note any docs you updated
   (`CLAUDE.md` architecture notes, `docs/hotkey.md`, `docs/build-and-release.md`).
5. Maintainers squash-merge.

Builds and tests run locally. GitHub Actions is disabled to avoid hosted-runner
costs. Include the local validation result in the PR. Ready-made community
builds and in-app updates are the main distribution path; source customization
remains supported. The default release pipeline signs with Exodia's self-signed
community certificate, whose private key only maintainers hold, and Exodia's
Sparkle archive signatures, without an Apple Developer account
(see `docs/build-and-release.md`).

By contributing you agree that your contribution is licensed under the MIT
License of this repository. No CLA is required.

## Reporting bugs

Use the issue templates. Include the macOS version, the Mac model (Apple
Silicon or Intel), the Exodia version from Settings, and which speech / LLM
route you use (your own key or custom endpoint).
