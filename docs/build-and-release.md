# Local builds and community releases

Most users install a ready-made Exodia DMG and update through the island's
**Update** button. Source builds remain available for customization. Both the
development build and default community release pipeline work without an Apple
Developer account, Developer ID certificate, notarization or App Store Connect key.

In [Releases](https://github.com/AbsoluteMode/exodia/releases), Exodia community
builds use Exodia-named assets. Earlier Whytap assets are historical; when no
Exodia package is listed, use a local source build until one is published.

## Build and run a customization

Use macOS 14.2 or newer and Xcode 26 or newer with its command-line tools:

```bash
git clone https://github.com/AbsoluteMode/exodia.git
cd exodia
swift build
swift test
./scripts/dev-run.sh --run
```

The script builds `build/Exodia-Beta-dev.app` at a stable path with the beta
bundle identity. It uses an existing local `Sidekey Dev` signing identity or
falls back to ad-hoc signing. Do not launch the main app with `swift run`.
Ad-hoc rebuilds may require granting macOS permissions again.

Development version `0.0.0-dev` / build `9999` keeps published binary updates
from replacing the custom app. Update the checkout with your coding agent,
preserve local changes, validate and rerun the script. Production users receive
ready-made updates without rebuilding source.

## Validate locally

```bash
swift build
swift test
python3 scripts/customize.py doctor --json
FLAVOR=prod ./scripts/build-dmg.sh --preflight-only
```

The packaging preflight is offline: it checks resources, the selected toolchain
and distribution mode without building, downloading or publishing. Community
packaging requires the macOS 26 SDK, committed BlockNote assets, Sparkle public
key and the MLX metallib matching `Package.resolved`.

`Resources/mlx.metallib` and its `.revision` sidecar are version-locked to
`mlx-swift`. Regenerate both with `scripts/build-metallib.sh` when updating MLX.
The metallib remains a sealed resource with a relative symlink from
`Contents/MacOS/`; see [the metallib decision](decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md).

Build, test and package on the maintainer's Mac. Record local verification in the
PR. GitHub hosts source and finished release assets; GitHub Actions stays disabled.
Scripts support the Bash 3.2 shipped with macOS; avoid empty-array expansion under
`set -u`.

## Publish a community release

Bump `VERSION` for the intended release. The normal commands are:

```bash
FLAVOR=prod ./scripts/user-release.sh --dry-run
FLAVOR=prod ./scripts/user-release.sh --build-only
FLAVOR=prod ./scripts/user-release.sh
```

`--dry-run` reads the live feed and installed build to calculate versions, but
does not build or upload. It is not the offline preflight. `--build-only` creates
the universal arm64/x86_64 app and DMG without publishing. The default full command
builds and publishes to GitHub Releases, including Sparkle's appcast with
cryptographic signatures for the update archives. The XML feed itself is not
signed; HTTPS protects its transport and Sparkle verifies each archive before
extraction.
The script chooses a build number newer than the live feed and installed copy;
set `BUILD_VERSION` explicitly for a first release when neither exists.

Default community mode signs ad hoc and skips Apple notarization. Publication
still requires authenticated GitHub release access and Exodia's Sparkle Ed25519
private key through `SPARKLE_ED_PRIVATE_KEY` or `SPARKLE_ED_PRIVATE_KEY_FILE`.
Keep its matching public key in `Resources/sparkle-public-ed-key.txt`. Never
commit or print the private key. `upload-release.sh` verifies the generated
archive signature before upload.

Sparkle signatures authenticate update archives using Exodia's own key. They
are independent of Apple code signing and do not make a community download
Apple-notarized. First-download Gatekeeper warnings and permission regrants after
ad-hoc updates remain possible; see [installation](install.md).

`EXODIA_LEGACY_SIGNED_RELEASE=1` explicitly selects the optional Developer ID and
notarization path. Only that mode requires `TEAM_ID`, a Developer ID certificate
and `ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8`. It is not the default
Exodia delivery path.

## Channels and updates

| Flavor | Bundle ID | App | Sparkle feed |
| --- | --- | --- | --- |
| `prod` | `com.rootwise.sidekey` | `Exodia.app` | `https://github.com/AbsoluteMode/exodia/releases/latest/download/appcast.xml` |
| `beta` | `com.rootwise.sidekey.beta` | `Exodia-Beta.app` | `https://github.com/AbsoluteMode/exodia/releases/download/beta/appcast.xml` |

Production tags are `v<version>` and include the versioned DMG,
`Exodia-latest.dmg` and `appcast.xml`. Beta releases are prereleases with a rolling
`beta` feed. Every update is a complete archive, verified by Sparkle before
installation.

Scheduled discovery shows **Update** in the island; downloading requires the
user's action. An idle app installs and relaunches after the requested download.
Busy meeting recording, dictation or agent activity defers a restart. Returning to idle does not restart the app automatically: the user
chooses **Restart** or **Later**. The updater behavior is defined in
`Sources/Sidekey/Updates/UpdateController.swift` and `IslandUpdateUserDriver.swift`.

The package is named Exodia, while Swift targets, bundle IDs, Keychain services,
UserDefaults keys and data directories retain compatibility names. Keep these
stable to preserve user data. A separate fork must choose its own identities,
Sparkle key pair and update feed; see [trademarks](../TRADEMARK.md).
