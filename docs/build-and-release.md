# Local build and source distribution

Exodia is developed and distributed as open source. Building, testing and
running it locally do not require an Apple Developer account, Developer ID
certificate, notarization or an App Store Connect key. Apple account
agreements are not a delivery requirement for this source project.

## Build and run

Use macOS 14.2 or newer and Xcode 26 or newer with its command-line tools.

```bash
git clone https://github.com/AbsoluteMode/exodia.git
cd exodia
./scripts/dev-run.sh --run
```

The script creates `build/Exodia-Beta-dev.app` and launches it. It uses an
existing local `Sidekey Dev` signing identity when available; otherwise it
signs ad hoc. No paid Apple account or signing credential is requested.
This app bundle is for testing on the Mac that built it, rather than a
trusted downloadable installer.

Use the script instead of `swift run`: it assembles a proper app at a stable
path with the beta bundle identity. An existing local signing identity helps
preserve permissions across builds; ad-hoc rebuilds can require granting
permissions again. Keep macOS permission checks and Keychain storage intact.

The package metadata is `Exodia`; the library, executable product and targets
remain `Sidekey` / `SidekeyApp`. Bundle IDs, Keychain services, UserDefaults
keys and Application Support paths keep their historical names. This
preserves existing keys, settings, notes and agent memory. Do not rename
these compatibility identifiers without a migration.

## Local validation

```bash
swift build
swift test
python3 scripts/customize.py doctor --json
```

Record the local results in the pull request. GitHub hosts the source and
PRs; GitHub Actions is disabled to avoid runner costs. Do not enable or
dispatch hosted workflows for validation.

The release scripts support the Bash 3.2 shipped with macOS. Optional
arguments must be appended to nonempty arrays: expanding an empty array
with `set -u` fails in Bash 3.2.

`Resources/mlx.metallib` is version-locked to the resolved `mlx-swift`
revision (`Resources/mlx.metallib.revision`). When bumping MLX, rebuild it
with `scripts/build-metallib.sh` in the same change. It stays a sealed
resource with a relative symlink from `Contents/MacOS/`; see
[the metallib decision](decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md).

## Update a source build

Update the checkout, validate the change and run `./scripts/dev-run.sh --run`
again. The development bundle uses a high development build number to avoid
receiving historical binaries from the retained Sparkle feed.

The existing updater remains in the code: scheduled checks show an island
pill, and downloading requires a user action. Its presence does not make
binary publishing part of the source-development workflow.

## Historical binary tooling

[Earlier GitHub releases](https://github.com/AbsoluteMode/exodia/releases)
contain Whytap binaries. They are historical builds, not the current Exodia
source. There is no active Exodia DMG release pipeline or requirement to
renew Apple Developer access.

The following scripts are retained as inactive tooling. They refuse to run
unless `EXODIA_LEGACY_SIGNED_RELEASE=1` is explicitly set; the normal local
build does not set it:

- `scripts/user-release.sh`: coordinates a binary build and upload.
- `scripts/build-dmg.sh`: builds a universal app, signs with Developer ID,
  notarizes, staples and packages it as a DMG.
- `scripts/upload-release.sh`: publishes the DMG and a signed Sparkle feed.

Using that separate workflow would require its own deliberate distribution
choice and credentials: Developer ID and notarization credentials for the
binary, a Sparkle Ed25519 key pair and GitHub release access for publication.
These are not prerequisites for cloning, developing or running Exodia.

The retained flavor contracts are:

| Flavor | Bundle ID | Optional binary name | Sparkle feed |
|---|---|---|---|
| `prod` | `com.rootwise.sidekey` | `Exodia.app` | `https://github.com/AbsoluteMode/exodia/releases/latest/download/appcast.xml` |
| `beta` | `com.rootwise.sidekey.beta` | `Exodia-Beta.app` | `https://github.com/AbsoluteMode/exodia/releases/download/beta/appcast.xml` |

The local development bundle uses the beta identity and separate beta
Keychain service. Its name is `Exodia-Beta-dev.app`; it does not replace the
production app. Legacy file-backed credentials migrate into Keychain.

If a fork later chooses to distribute binaries, it must use its own app
name, bundle identifiers, signing credentials, Sparkle keys and update feed
so it cannot install another project's releases over itself. See
[trademarks](../TRADEMARK.md). `VERSION` remains the marketing version;
Sparkle build numbers, if that optional pipeline is used, stay monotonic
across the live feed and installed copies.
