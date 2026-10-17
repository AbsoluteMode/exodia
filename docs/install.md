# Build and run Exodia

Exodia is distributed as source. You do not need an Apple Developer account,
Developer ID signing or notarization to develop and run it on your Mac.
[Earlier releases](https://github.com/AbsoluteMode/exodia/releases) contain
historical Whytap binaries and do not represent the current Exodia source.

## Local setup

Use macOS 14.2 or newer and Xcode 26 or newer with its command-line tools.
Local speech and text models require Apple Silicon; Intel Macs can use their
own provider keys or compatible endpoints.

```bash
git clone https://github.com/AbsoluteMode/exodia.git
cd exodia
./scripts/dev-run.sh --run
```

The script builds and opens `build/Exodia-Beta-dev.app`. It uses an existing
local `Sidekey Dev` signing identity when available, otherwise an ad-hoc
signature. This bundle is for testing on the Mac that built it; it is not a
trusted downloadable installer. It uses the beta bundle identity and does
not replace the production app.

## First dictation

Exodia opens directly to the island, without a setup wizard. Open **Settings**
from its hover controls:

1. In **Permissions**, allow Microphone and Accessibility. macOS may open
   **System Settings → Privacy & Security** to grant these permissions.
   Reopen Exodia if macOS asks you to quit it after changing a permission.
2. In **Models**, choose **Your key**, select a speech provider and paste its
   API key. Save to check the connection and store it in macOS Keychain.
3. Optionally configure OpenRouter or your own endpoint for text cleanup and
   meeting summaries.
4. Focus a text field in your app, hold **Space**, speak, then release Space.

Exodia is free. Your selected provider handles API billing; Exodia does not
sell credits or require an account.

For on-device processing, choose **Local** and download the speech model.
Local models require internet access for their initial download. Local text
cleanup uses a separate model.

For the optional agent, open **Settings → Agents**, install OpenCode, choose an
OpenRouter model and save your OpenRouter key with **Save & connect**.
Meeting recording may also request **System Audio Recording** permission.

## If something does not work

- **The build fails:** check `xcode-select -p` and run
  `python3 scripts/customize.py doctor --json` from the checkout. Include the
  build error and toolchain version in a
  [bug report](https://github.com/AbsoluteMode/exodia/issues/new/choose).
- **The shortcut does not work or text is not pasted:** check Microphone and
  Accessibility for this development copy, then quit and reopen it. Ad-hoc
  rebuilds may require granting permissions again.
- **“Install Exodia before opening it”:** launch the development bundle from
  the writable checkout using `./scripts/dev-run.sh --run`, rather than a
  read-only disk image or translocated downloaded copy.
- **The API key does not connect:** check the selected provider, its key and
  your internet connection. For a self-hosted endpoint, check its base URL
  and model name. Never include your key in a bug report.
- **No speech model or key is configured:** open **Settings → Models** from
  the island. There is no menu-bar icon; controls live at the top of the screen.

## Updating and removal

Update the source checkout and run `./scripts/dev-run.sh --run` again.
The development bundle has a high development build number so the retained
Sparkle updater does not offer historical production releases as an update.

To remove the local build, quit Exodia and delete `build/Exodia-Beta-dev.app`.
Keys, settings and local history remain outside the bundle. Exodia preserves
historical storage identities so the rename does not reset existing data.
