---
id: whytap-screenshot-toolbar
type: decision
title: Compact screenshot editor and text-and-number blur
summary: Explicit local capture opens a native toolbar with Blur defaulting to text and standalone numbers and an entire-area alternative.
status: confirmed
tags: [screenshots, capture, blur, numbers, vision, toolbar, privacy]
canonical_for: [screenshot-editor, screenshot-text-number-blur]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested implementation of the approved compact screenshot toolbar, explicitly including text and numbers in the default Blur mode.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotCoordinator.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotDocument.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotTests.swift
    confirmed_at: 2026-10-20
related: [../project.md]
---

# Context

The user approved a compact screenshot toolbar and corrected Blur to include
text **and numbers**, including standalone digits.

# Alternatives

Whole-rectangle blur unnecessarily hides the interface. Remote image analysis
adds setup and sends content away. A full editor window adds navigation.

# Decision

Use explicitly triggered ScreenCaptureKit snapshots, an AppKit canvas/toolbar
and system Vision. Blur defaults to Text and numbers, with Entire area as an
alternative. Secondary tools live in More. Existing layouts/shortcuts do not
gain an automatic pinned tile or reserved key.

# Rationale

Recognition without language correction retains number/code identities;
additional text detection does not depend on recognizing a language. Blur
uses already edited pixels, composites replacement pixels and exports no
editable original layer. Copy text also uses the edited image.

# Sources

Frontmatter links the confirmation and implementation. See the
[screenshot guide](../../docs/screenshots.md) for behavior and limitations.

# Comments and objections

OCR and blur do not guarantee finding every glyph or irreversible anonymization.

# Resolution

Keep the result visible, both modes explicit, and analysis errors non-destructive.
Export waits for local processing; cancellation invalidates late results.

# Consequences

Screen Recording is requested on invocation. Content stays in memory until
explicit copy/save/pin/system share. System OCR adds no app-managed speech/LLM
weights or provider traffic. The editor blocks update restarts. Screen/Space
changes and sleep cancel stale captures. Real permission/capture/dialog flows
remain installed-app acceptance checks.

# Supersedes / superseded by

No prior screenshot-editor decision is superseded.
