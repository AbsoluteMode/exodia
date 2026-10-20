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
    reference: On 2026-10-20 the user requested a single toolbar row, faster and cleaner Blur, Copy plus direct Download with filename confirmation, and Enter to copy and close.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 the user requested a Screen Recording entry for screenshots in Settings Permissions.
    confirmed_at: 2026-10-20
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
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotSelectionTests.swift
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
Selecting an existing immovable Blur is a selection-only gesture, not a new
crop gesture. Clicking, dragging or deleting it preserves the crop and leaves
undo/redo attached to actual edits. Dedicated unshown-canvas regressions cover
these interactions alongside normal crop creation, movement and resizing.
The old ScreenRecordingRemoval guards predate explicit screenshots. Their
capture exception is restricted to ScreenshotCoordinator's still-frame entry.
The user's later request adds a Screen Recording status and explicit Allow/Open
action in Settings Permissions; PermissionsHelper owns that action's request
and system-settings link. Passive refresh never requests access. Launch,
the orb and meeting audio retain the no-screen-capture/no-prompt contract.

# Follow-up polish

The user rejected the second settings row and slow/rough Blur. Keep tool settings
inline in one row. Download replaces Save, uses a downward arrow and writes PNG
directly into Downloads under a readable local timestamp, with exclusive creation
and numbered collision suffixes. Download writes into an owned temporary
directory first, then publishes the completed PNG using exclusive atomic rename;
failures remove staging instead of leaving a truncated final file. Success names the actual file and retains the
editor. Return copies and closes after selection; if Blur is pending it waits for
the patch, and a failed Blur remains open. Return in the label field also copies/closes, as requested. Typing only prepares
the label; click the screenshot to place it. The placeholder/help explicitly say
that an unplaced label is discarded; native clipboard editing stays in the field.

Fresh-executable checks reproduced a 30-second first accurate-OCR call even
with CPU compute devices. Blur therefore combines fast Vision recognition and
language-independent regions, with a bounded extra pass for isolated digits.
That pass examines up to 8192 contours and classifies up to 256 uncovered glyph
candidates in a repeated-glyph atlas, accepting repeated letters/digits and mapping them
back to original coordinates. Atlas pixels never reach output. Accurate OCR
remains in Copy text. Dark crops are normalized for recognition only, preserving
original screenshot colors. Pure region detection and fast OCR alone were
rejected because they missed small single digits. Per-region blur strengths
replace a median strength that could leave a large amount legible beside small
labels; stronger overlapping masks apply last. Crop-first compositing allocates only the selected
pixels. Rendering/detection/PNG work happens off the UI thread, and a reusable
hardware-backed Core Image context replaces per-gesture software setup. Mask
strength follows text height, with padded, subtly rounded text edges; Entire area
covers its full rectangle. Geometry and pixel regressions preserve Retina/crop
alignment and background pixels. See [interface decisions](../../docs/DESIGN.md).

# Consequences

Screen Recording is requested on invocation. Content stays in memory until
explicit copy/download/pin/system share. System OCR adds no app-managed speech/LLM
weights or provider traffic. The editor blocks update restarts. Screen/Space
changes and sleep cancel stale captures. Real permission/capture/dialog flows
remain installed-app acceptance checks.

# Supersedes / superseded by

No prior screenshot-editor decision is superseded.
