# Building and releasing

The `Build` workflow runs on pull requests, pushes to main, tags, and manual dispatch. It uses GitHub's Xcode 27 arm64 runner, executes unit tests, builds both arm64 and x86_64 Release slices, verifies the signature, and uploads a DMG, ZIP, SHA256SUMS, and public build manifest. A `v` tag matching `CFBundleShortVersionString` additionally creates a GitHub Release.

The DMG contains WindowSwitch and an Applications link. Temporary staging files are removed after packaging. The default signature is ad-hoc; it contains no personal signing certificate and is not an Apple notarization. The x86_64 slice is compiled but requires Intel hardware for runtime testing.

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

`WINDOWSWITCH_BUILD_ROOT` and `WINDOWSWITCH_DIST_DIR` override temporary build and package output paths. `WINDOWSWITCH_SIGNING_IDENTITY` is opt-in; no local signing identity is selected automatically. `WINDOWSWITCH_APP_ID` can override the application bundle identifier for a separate local build. Keep a stable identifier and certificate for an existing installation to preserve its permission identity. The installer refuses to overwrite an app with a different bundle identifier.
