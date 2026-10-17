# Install Exodia

The normal installation uses a ready-made macOS build. You do not need Xcode,
a terminal or an Apple Developer account to use it.

In [GitHub Releases](https://github.com/AbsoluteMode/exodia/releases), choose
`Exodia-latest.dmg` from an Exodia release. Whytap-named assets are historical
builds. If no Exodia asset is listed yet, use the source-build path below.

## Download and open

1. Download the Exodia DMG from the repository's Releases page.
2. Open it and drag **Exodia** into **Applications**.
3. Open Exodia from Applications, then eject the disk image.

Community builds use ad-hoc signing and are not notarized by Apple. macOS may
warn that it cannot verify the developer. For the specific download you trust,
follow **System Settings → Privacy & Security → Open Anyway** if offered;
[Apple explains this per-app approval](https://support.apple.com/102445).
Signing changes between ad-hoc builds may also require granting permissions
again. Sparkle update signatures verify Exodia's archives separately from
Apple's launch checks.

Requirements: macOS 14.2 or newer. Local speech and text models require Apple
Silicon; Intel Macs can use provider keys or compatible endpoints.

## Moving from Whytap

Some earlier Whytap copies use a different update feed and need one manual
Exodia installation. Quit Whytap first. Move its old app bundle out of
Applications or to Trash before opening Exodia, so two copies with the same
bundle identity do not run together. Keep the old bundle elsewhere if you want
a rollback copy; do not delete Application Support data or Keychain items.

Exodia retains the production bundle identity and storage paths. Settings,
notes, keys and history remain in their existing stores. macOS may ask for
permissions or Keychain access again because the signing identity changed.
After this transition, community updates use Exodia's GitHub feed.

## First dictation

Exodia opens directly to the island, without a setup wizard. Open **Settings**
from its hover controls:

1. In **Permissions**, allow Microphone and Accessibility. macOS may open
   **System Settings → Privacy & Security** to grant them. Reopen Exodia if
   macOS asks you to quit after changing a permission.
2. In **Models**, choose **Your key**, select a speech provider and enter its
   API key. Save to check the connection and store it in macOS Keychain.
3. Optionally configure OpenRouter or your own endpoint for text cleanup and
   meeting summaries.
4. Focus a text field, hold **Space**, speak, then release Space.

Exodia is free. Your selected provider handles API billing; there are no Exodia
accounts, plans or credits. For on-device processing, choose **Local** and download
the speech model. The initial download needs internet access; local text cleanup
uses a separate model.

For the optional agent, open **Settings → Agents**, install OpenCode, choose an
OpenRouter model and save your key with **Save & connect**. Meeting recording may
also request **System Audio Recording** permission.

## Updates

When the island offers **Update**, choose **Download**. Sparkle verifies the
archive using Exodia's Ed25519 public key. When the app is idle, the requested
update installs and relaunches when ready. If a meeting recording, dictation or
agent task is active, the app keeps the update ready without interrupting it.
Finish the activity, then choose **Restart** to apply the update. A prepared
download can also apply when you quit Exodia normally. Choose **Later** to cancel
the current installation; it will not then apply on that quit. Returning to idle
does not force a restart. Installation after force quit or a crash is not guaranteed.

You can also install a newer Exodia DMG over the copy in Applications. Keys,
settings and local knowledge are stored outside the app bundle. Ad-hoc signature
changes may require regranting macOS permissions.

## Customize from source

Use Xcode 26 or newer with its command-line tools:

```bash
git clone https://github.com/AbsoluteMode/exodia.git
cd exodia
./scripts/dev-run.sh --run
```

This creates `build/Exodia-Beta-dev.app`, using an existing local `Sidekey Dev`
signing identity or ad-hoc signing. Version `0.0.0-dev` / build `9999` keeps the
binary feed from overwriting your custom build. Have your agent update the source
while preserving local changes, then validate and rebuild. See
[customization](customization/README.md) and [build details](build-and-release.md).

## Troubleshooting and removal

- **“Install Exodia before opening it”:** drag the app to Applications and open
  that copy instead of the disk-image copy. For source builds, use the writable
  checkout and `scripts/dev-run.sh`.
- **The shortcut or paste does not work:** check Microphone and Accessibility
  for the installed copy, then quit and reopen it. Regrant if an update changed
  its code identity.
- **The API key does not connect:** check the provider, key, endpoint/model and
  internet connection. Never include the key in a bug report.
- **The source build fails:** run `python3 scripts/customize.py doctor --json`
  from the checkout and include the build error and toolchain version in a
  [bug report](https://github.com/AbsoluteMode/exodia/issues/new/choose).

To remove Exodia, quit it and move the app to Trash. Keys, settings and local
knowledge remain outside the bundle so reinstalling preserves them.
