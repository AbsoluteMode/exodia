# Local builds and community releases

Most users install a ready-made Exodia DMG and update through the island's
**Update** button. Source builds remain available for customization. Both the
development build and default community release pipeline work without an Apple
Developer account, Developer ID certificate, notarization or App Store Connect key.

In [Releases](https://github.com/AbsoluteMode/exodia/releases), Exodia community
builds use Exodia-named assets. Earlier Whytap assets are historical; when no
Exodia package is listed, use a local source build until one is published.

## Build and run a customization

For the maintainer's parallel feature sessions, follow the
[shared application procedure](../.project-docs/processes/shared-app-development.md).
Feature worktrees use non-launching Swift builds/tests. The commands below
describe a standalone source customization; dev packaging can stop other beta
processes, so it is not the way to update the shared installed production app.

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
packaging requires the macOS 26 SDK, committed BlockNote assets and the Sparkle
public key. The MLX metallib and `scripts/build-metallib.sh` were removed with
the on-device models; see
[the decision](../.project-docs/decisions/2026-10-18-remove-local-models.md).

Build, test and package on the maintainer's Mac. Record local verification in the
PR. GitHub hosts source and finished release assets; GitHub Actions stays disabled.
Scripts support the Bash 3.2 shipped with macOS; avoid empty-array expansion under
`set -u`.

## Publish a community release

Bump `VERSION` and commit the release inputs before building. `Sources/`,
`Resources/`, `Package.swift`, `Package.resolved`, `VERSION` and `scripts/` must
be clean. The normal commands are:

```bash
FLAVOR=prod ./scripts/user-release.sh --dry-run
doppler run --project sidekey --config dev -- env FLAVOR=prod ./scripts/user-release.sh --build-only
doppler run --project sidekey --config dev -- env FLAVOR=prod ./scripts/user-release.sh
```

Doppler supplies the community code-signing key for the build and the Sparkle key
for publication; see below.

`--dry-run` reads the live feed and installed build to calculate versions, but
does not build or upload. It is not the offline preflight. `--build-only` creates
the universal arm64/x86_64 app and DMG without publishing. The default full command
builds and publishes to GitHub Releases, including Sparkle's appcast with
cryptographic signatures for the update archives. The XML feed itself is not
signed; HTTPS protects its transport and Sparkle verifies each archive before
extraction.
The script chooses a build number newer than the live feed and installed copy;
set `BUILD_VERSION` explicitly for a first release when neither exists.

### Release provenance contract

Every upload must be bound to the commit used for its build. The release helper
`scripts/release-provenance.py` must capture the build-time HEAD and clean input
state, then seal the completed DMG's SHA-256 and size together with its version,
build, flavor, distribution mode, code-signing identity, bundle ID and
architectures. Its subcommands are `capture`, `seal` and `verify`; the build and
upload scripts call them. The upload derives the expected code-signing identity
from the committed certificate (see below), so a local ad-hoc or test-certificate
build cannot be published.
Keep the adjacent `<DMG>.manifest.json` with the archive;
`--upload-only` requires both files from the same build.

The publication gate must reject a missing or inconsistent manifest, changed
source commit or changed archive bytes before loading signing keys or uploading.
The GitHub release must target the verified manifest's build commit, rather
than whichever HEAD happens to be current during upload. Do not reuse a DMG
after changing HEAD, relabel an old archive or edit a manifest to make it pass;
commit the intended inputs and rebuild. These are pipeline requirements;
candidate-specific verification remains part of release acceptance.

For CLI packaging without a live Finder layout session, set
`EXODIA_DMG_HEADLESS=1`. It skips only cosmetic Finder layout; packaging and
verification remain the same. The default keeps the Finder layout step.

Community mode skips Apple notarization. Publication still requires
authenticated GitHub release access and Exodia's Sparkle Ed25519 private key
through `SPARKLE_ED_PRIVATE_KEY` or `SPARKLE_ED_PRIVATE_KEY_FILE`. Keep its
matching public key in `Resources/sparkle-public-ed-key.txt`. Never commit or
print the private key. `upload-release.sh` verifies the generated archive
signature before upload.

Sparkle signatures authenticate update archives using Exodia's own key. They
are independent of Apple code signing and do not make a community download
Apple-notarized. First-download Gatekeeper warnings remain; see
[installation](install.md).

### Community code-signing identity

`build-dmg.sh` signs the app, its nested code and the DMG with Exodia's
self-signed code-signing certificate, committed as
`Resources/community-signing-certificate.pem` (CN "Exodia Community Code
Signing", SHA-1 `39da363652f6df4b52ac950998e16c98fd39bc6b`, valid until
2056-10-11). Without that file, for example in a fork that removed it, the build
signs ad hoc.

The certificate gives every build the same designated requirement:
`identifier "com.rootwise.sidekey" and certificate leaf = H"<certificate SHA-1>"`
(`com.rootwise.sidekey.beta` for beta). macOS privacy grants such as Microphone
and System Audio Recording are stored against that requirement, so they survive
updates. An ad-hoc requirement is the build's code hash, which changes with
every build, so each ad-hoc update asked for those permissions again. The
certificate is not issued by Apple and changes nothing for Gatekeeper; users
never trust or install it.

The certificate is public. Its private key lives only in Doppler as
`EXODIA_COMMUNITY_SIGNING_KEY` in `sidekey/dev`, next to the Sparkle key. Never
commit or print it. Build with the key in the environment:

```bash
doppler run --project sidekey --config dev -- env FLAVOR=prod ./scripts/user-release.sh --build-only
```

`EXODIA_COMMUNITY_SIGNING_KEY_FILE` reads the key from a file instead. Before
compiling, the build checks that the key matches the certificate. For signing it
imports the identity into a temporary keychain that is not added to the keychain
search list and is deleted on exit. It checks the app against the expected
designated requirement, checks that each nested component and the DMG carry the
certificate, repeats the app check on the mounted DMG and seals
`code_signing: certificate:<SHA-1>` in the manifest.

`./scripts/community-signing-bootstrap.sh` creates the identity once. It refuses
to replace an existing certificate or Doppler secret. A new certificate is a new
identity: every install has to grant its permissions once more, so rotate only
if the key leaks. `PackagingRebrandTests` pins the certificate's SHA-1, so a
replaced certificate fails the tests until the pin is changed on purpose. Code
signed with the key inherits the users' grants, which is why the key stays as
private as the Sparkle key.

The first certificate-signed release changes the requirement of installs that
came from an ad-hoc build, so they grant Microphone and System Audio Recording
one last time. Sparkle accepts the change: it checks the archive's EdDSA
signature and the new app's code signature, not its identity. Keychain prompts
after an update are expected to stay as before, because without an Apple team
ID the keychain ties its access to the code hash.

For local experiments, `EXODIA_COMMUNITY_SIGNING=adhoc` forces ad-hoc signing
and `EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE` signs with another certificate.
Neither can be published: `user-release.sh` refuses them in a full run, and the
upload rejects any archive whose identity differs from the committed
certificate.

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
Busy meeting recording, dictation or agent activity defers app-initiated relaunch.
Returning to idle does not restart the app automatically. A prepared download may
apply on ordinary user quit; **Restart** applies it once work is finished, while
ready-stage **Later** cancels this installation with `.skip` without permanently
skipping the version. No installation guarantee applies to force quit, crashes,
process kills or power loss. The updater behavior is defined in
`Sources/Sidekey/Updates/UpdateController.swift` and `IslandUpdateUserDriver.swift`.

The package is named Exodia, while Swift targets, bundle IDs, Keychain services,
UserDefaults keys and data directories retain compatibility names. Keep these
stable to preserve user data. A separate fork must choose its own identities,
Sparkle key pair, code-signing certificate and update feed; see
[trademarks](../TRADEMARK.md). Exodia's certificate cannot sign without
Exodia's key: delete `Resources/community-signing-certificate.pem`, then run
`community-signing-bootstrap.sh` with the fork's own Doppler project or
`--key-file`, or publish ad hoc.
