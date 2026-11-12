# Building and releasing

The `Build` workflow runs on pull requests, pushes to main, tags, published releases, and manual dispatch. It uses GitHub's Xcode 27 arm64 runner, executes unit tests, builds both arm64 and x86_64 Release slices, verifies the signature, and archives a DMG, ZIP, SHA256SUMS, and public build manifest as workflow artifacts. A `v` tag matching `CFBundleShortVersionString` additionally creates a GitHub Release. Only the DMG and its signed `.update.json` are attached to that release; the ZIP, checksums, and manifest stay on the workflow run.

The DMG contains WindowSwitch and an Applications link, and opens to a fixed drag-to-install window: the app on the left, the Applications link on the right, over a background picture. `Scripts/dmg-layout.py` writes that layout straight into `.DS_Store`, so packaging never drives Finder and works without a GUI session. Temporary staging files are removed after packaging. The default signature is ad-hoc; it contains no personal signing certificate and is not an Apple notarization. Ad-hoc signing has no Team ID, so `Scripts/sign.sh` adds `com.apple.security.cs.disable-library-validation` for those builds only — without it the hardened runtime refuses to load the app's own embedded frameworks and the app aborts at launch. Developer ID builds keep the stricter entitlement set. The x86_64 slice is compiled but requires Intel hardware for runtime testing.

## Optional Developer ID signing and notarization

Configure all of these repository Actions secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key export |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting that export |
| `MACOS_SIGNING_IDENTITY` | Complete Developer ID Application identity |
| `NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key |
| `NOTARY_KEY_ID` | API key ID |
| `NOTARY_ISSUER_ID` | API issuer ID |

The workflow imports these into an ephemeral keychain. Certificates and keys never enter the repository or artifacts and are deleted in an always-run cleanup step. Signing secrets are not used for pull-request builds. An incomplete signing configuration fails rather than publishing an incorrectly labeled notarized build.

The signed app is notarized and stapled before packaging; the DMG is then notarized and stapled as well. Apple-issued signatures contain the certificate holder's public identity; review that identity before enabling distribution signing.

Apple documentation: [Developer ID](https://developer.apple.com/developer-id/) and [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Local builds

Packaging the styled DMG needs the `ds-store` package. Point `WINDOWSWITCH_PYTHON` at an interpreter that has it, for example `python3 -m venv .venv && .venv/bin/pip install ds-store mac_alias` and then `WINDOWSWITCH_PYTHON=.venv/bin/python ./Scripts/package.sh`. Without it packaging still produces a working DMG, only without the window layout, and prints a warning.

`WINDOWSWITCH_BUILD_ROOT` and `WINDOWSWITCH_DIST_DIR` override temporary build and package output paths. `WINDOWSWITCH_SIGNING_IDENTITY` is opt-in; no local signing identity is selected automatically. `WINDOWSWITCH_APP_ID` can override the application bundle identifier for a separate local build. Keep a stable identifier and certificate for an existing installation to preserve its permission identity. The installer refuses to overwrite an app with a different bundle identifier.

## GitHub-only update publishing

Sparkle 2.10.1 uses `https://morefreefg.github.io/WindowSwitch/appcast.xml`. The repository Pages source is GitHub Actions. `Update feed` deploys static XML; no application server is needed.

`SPARKLE_PRIVATE_KEY` is the private update-signing key stored as a repository Actions secret. The public key is embedded in Info.plist. The private key is also backed up in the maintainer's Keychain and password manager; it must never be committed or uploaded as a release asset. Apple distribution credentials are separate and optional.

For a new release, push a version tag such as `v0.2.0-rc.2`, or publish a release with that tag in GitHub's UI. The Build workflow derives the marketing version from the tag and uses the monotonically increasing workflow run number as the bundle build number. It builds the Universal app, packages DMG/ZIP, signs the DMG, verifies that signature against the embedded public key, and uploads the DMG together with its public `.update.json` metadata. Sparkle therefore downloads the DMG itself for updates; the ZIP is no longer a release asset. RC tags create GitHub pre-releases. Existing manually created releases receive the built assets as well; their release notes are preserved.

After publishing, the reusable Update feed workflow reads published stable/RC releases, ignores drafts and other pre-release channels, requires signed archive metadata, sorts by build number, signs the feed, and deploys it using GitHub Pages. Manual release publication/edit/deletion also refreshes the feed. No signing keys enter the Pages artifact. The client requires the signed feed and permits RC and stable channels by default; it does not send Sparkle system-profile data.

Do not rename/reset the Build workflow's run-number sequence without explicitly preserving increasing bundle build numbers. Keep the application bundle ID stable for public updates. Private test builds with another identity open GitHub Releases for manual migration rather than trying to install an incompatible bundle.
