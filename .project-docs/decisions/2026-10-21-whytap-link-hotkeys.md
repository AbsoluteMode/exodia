---
id: whytap-link-hotkeys
type: decision
title: A whytap:// link may propose a tool hotkey, applied only after confirmation in Whytap
summary: whytap://hotkey/<HoverTool>?keys=… proposes one tool hotkey; Whytap's own dialog (Cancel default, Assign armed after 1 s) is the only path to the change, and links still never read data or change where it goes.
status: confirmed
tags: [links, url-scheme, hotkeys, security]
canonical_for: [whytap-link-changes]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user asked for links that set a hotkey the visitor asked for on the website, with care that no link can steal passwords or open other people's meetings, and approved starting with tool hotkeys confirmed inside Whytap.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Settings/WhytapLink.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Settings/WhytapLinkConfirmation.swift
    confirmed_at: 2026-10-21
related: [2026-10-20-whytap-links.md]
---

## Context

The existing [feature hotkey decision](../../docs/decisions/2026-10-19-feature-hotkeys.md) owns normal tool binding behavior.

The website's question page can already link to the place a feature lives.
The user wants it to go one step further: a visitor says which hotkey they
want, the page gives a link, and following it sets the hotkey. Any web page
can open a `whytap://` URL, and macOS does not say which site opened it, so
the protection cannot depend on where the link came from.

## Decision

- `whytap://hotkey/<HoverTool rawValue>?keys=<modifiers>+<key>` parses to
  `WhytapLinkRequest.propose(.toolHotkey(tool, combo))`. `WhytapLinkChange`
  is the allowlist of changes a link may propose; tool hotkeys are its only
  case.
- The combination needs ⌃ or ⌥, so a link cannot take app shortcuts (⌘C, ⌘Q)
  or typed capitals (⇧A). Keys are A–Z, 0–9, US punctuation and F1–F20; no
  Space, Tab, Return, Escape or Delete. `acceptsLinkHotkey` excludes Quit (an
  exhaustive switch, so a new tile needs a decision). Exactly one `keys`
  query item is accepted. Anything else only opens Settings → Hotkeys.
- `WhytapLinkChange.plan` compares with the current configuration: the same
  binding is `unchanged`; keys owned by another action (core hotkeys, other
  tools, fixed Help/History strip) are a `conflict` shown to the user with
  nothing changed; otherwise `confirm(current:)`.
- `WhytapLinkConfirmation` is an NSAlert in Whytap: Cancel is the first,
  default button explicitly through its window defaultButtonCell (a Cancel title
  alone receives Escape from AppKit). Return cancels; a modal-local Escape
  handler cancels only this alert and is removed on exit. Assign has no key equivalent and is
  disabled for one second. One confirmation at a time; links arriving during
  it are dropped. After Assign the plan is rechecked and the change goes
  through `HotkeyPreferences.apply`, the validated path Settings Save uses;
  then Settings → Hotkeys is shown. An open Hotkeys pane without unsaved edits
  adopts the new configuration.

## Rationale

Signing links would not help: a signed link from our page can be copied and
opened from any other page. What protects the user is that the change is
shown in Whytap's own window, exactly as it will be applied, and needs a
deliberate click that page clicks or typing cannot supply. Tool hotkeys are a
safe first change: the worst case is an inconvenient, visible binding that
Settings reverts. Links stay one-way. They never read data, and nothing is
reported back to the page, so there is no path for keys, Case values,
meetings or clipboard content to leave. Changes to where data is sent (a
provider endpoint pointed at someone else's server) would be an exfiltration
path and stay excluded.

## Tested

`WhytapLinkHotkeyTests`: every tool but Quit proposes its hotkey; modifier
aliases, case, percent-encoding and F-keys; unsafe combinations (⌘C, ⇧A, bare
keys, Space/Tab/Return/Escape/Delete, duplicate or unknown modifiers) and
malformed queries only show Hotkeys; plan results for free keys, replacement,
unchanged and conflicts with Meeting record, Help and another tool; applying
changes only that tool; a temporary `HotkeyPreferences` saves it and reloads
it. `WhytapLinkTests` source-checks that the URL handler never calls `apply`,
that `propose` confirms before its single `apply`. An actual native NSAlert
factory regression checks Cancel is the Return default before/after offscreen
layout and Assign has no key equivalent and starts disabled. The fixture never
activates or displays the dialog; Escape delivery remains installed acceptance. Removing the confirmation (an `apply` in the
handler) was shown to fail that test. The dialog itself and LaunchServices
delivery are verified only on the installed build.

## Rejected

- Applying without a dialog, or with Assign as the default button: any page
  could change settings, and Return would approve.
- Signed or origin-checked links: a valid link can be copied; macOS does not
  report the opening site.
- A local HTTP endpoint for the site: a known attack surface, and against the
  no Whytap services invariant.
- Core hotkeys (Drop, Agent) first: their gestures (hold Space, Right Command
  tap/hold) need their own rules; tool hotkeys cover the common question.
- Changes that read data or change where it goes: they are exfiltration paths.

2026-10-21 — PR: branch `claude/whytap-link-hotkeys`.
