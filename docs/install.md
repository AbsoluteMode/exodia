# Install Whytap

The normal installation uses a ready-made macOS build. You do not need Xcode,
a terminal or an Apple Developer account to use it.

In [GitHub Releases](https://github.com/AbsoluteMode/whytap/releases), choose
`Whytap-latest.dmg` when available. The latest published package may still be
`Exodia-latest.dmg` and contain **Exodia** until a Whytap release is published.
That is the same application; use the name shown in that disk image.

## Download and open

1. Download the Whytap DMG from the repository's Releases page.
2. Open it and drag **Whytap** into **Applications**.
3. Open Whytap from Applications, then eject the disk image.

Community builds are signed with the Developer ID certificate of Whytap's Apple
team and are not notarized by Apple. macOS may warn that it cannot verify the
developer. For the specific download you trust, follow **System Settings →
Privacy & Security → Open Anyway** if offered;
[Apple explains this per-app approval](https://support.apple.com/102445).
You never install or trust a certificate yourself. Because every community
build carries the same team identity, macOS keeps privacy permissions such as
Microphone and System Audio Recording and access to Whytap's Keychain items
across updates. Earlier builds were signed with Whytap's self-signed
certificate or ad hoc, so the first team-signed update asks for these
permissions one last time and asks once for each Keychain item; choose
**Always Allow** there. Sparkle update signatures verify Whytap's archives separately from Apple's
launch checks.

Requirements: macOS 14.2 or newer, on Apple Silicon or Intel.

## Moving from Exodia or an older Whytap

Whytap is the restored product name. Quit the running app normally before
replacing it. Keep one installed working copy: move the previous **Exodia.app**
out of Applications as a rollback copy, then install **Whytap.app**. Do not run
both copies together or delete Application Support data or Keychain items.

The production bundle ID, Keychain services, storage paths, community signing
certificate and Sparkle public key are unchanged. This rename does not require
new privacy permissions. Existing Exodia GitHub links redirect to Whytap.
Older Whytap builds using the retired update host still need one manual install;
changing this GitHub repository does not migrate those feeds.

## First dictation

Whytap opens directly to the island, without a setup wizard. Open **Settings**
from its hover controls:

1. In **Permissions**, allow Microphone and Accessibility. macOS may open
   **System Settings → Privacy & Security** to grant them. Reopen Whytap if
   macOS asks you to quit after changing a permission.
2. In **API & Models**, click **Add key**, choose a speech provider and enter its
   API key. Whytap checks it and stores it in macOS Keychain; then pick a model
   for Drop Fast and Drop Smart.
3. Optionally add OpenRouter or your own endpoint and pick models for text
   cleanup and meeting summaries.
4. Focus a text field, hold **Space**, speak, then release Space.

Whytap is free. Your selected provider handles API billing; there are no Whytap
accounts, plans or credits. On-device speech and text models were removed; if
you used **Local** before, choose a speech model in **API & Models** to dictate
again.

For the optional agent, open **Settings → Agents**, install OpenCode, then add an
OpenRouter or Anthropic key and choose the Agent model in **API & Models**, and
press **Save & connect**. Meeting recording may
also request **System Audio Recording** permission.

## Updates

When the island offers **Update**, choose **Download**. Sparkle verifies the
archive using Whytap's Ed25519 public key. When the app is idle, the requested
update installs and relaunches when ready. If a meeting recording, dictation or
agent task is active, the app keeps the update ready without interrupting it.
Finish the activity, then choose **Restart** to apply the update. A prepared
download can also apply when you quit Whytap normally. Choose **Later** to cancel
the current installation; it will not then apply on that quit. Returning to idle
does not force a restart. Installation after force quit or a crash is not guaranteed.

You can also install a newer Whytap DMG over the copy in Applications. Keys,
settings and local knowledge are stored outside the app bundle, and macOS
permissions carry over because community builds share one signing certificate.

## Customize from source

Use Xcode 26 or newer with its command-line tools:

```bash
git clone https://github.com/AbsoluteMode/whytap.git
cd whytap
./scripts/dev-run.sh --run
```

This creates `build/Whytap-Beta-dev.app`, using an existing local `Sidekey Dev`
signing identity or ad-hoc signing. Version `0.0.0-dev` / build `9999` keeps the
binary feed from overwriting your custom build. Have your agent update the source
while preserving local changes, then validate and rebuild. See
[customization](customization/README.md) and [build details](build-and-release.md).

## Troubleshooting and removal

- **“Install Whytap before opening it”:** drag the app to Applications and open
  that copy instead of the disk-image copy. For source builds, use the writable
  checkout and `scripts/dev-run.sh`.
- **The shortcut or paste does not work:** open **Whytap Settings → Permissions**,
  check the Drop shortcut status and click **Retry Shortcut** after granting
  the missing permission. Refresh and reopening Whytap also recheck the monitors.
- **An unexpected copy opens:** Settings shows the actual version, channel and
  application path. New builds allow one running copy across production and
  beta; a second copy offers to activate the existing app. Quit the running
  copy before switching. Older binaries do not implement this coordination.
- **The API key does not connect:** check the provider, key, endpoint/model and
  internet connection. Never include the key in a bug report.
- **The source build fails:** run `python3 scripts/customize.py doctor --json`
  from the checkout and include the build error and toolchain version in a
  [bug report](https://github.com/AbsoluteMode/whytap/issues/new/choose).

To remove Whytap, quit it and move the app to Trash. Keys, settings and local
knowledge remain outside the bundle so reinstalling preserves them.
