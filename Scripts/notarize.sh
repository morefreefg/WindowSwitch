#!/bin/zsh
set -euo pipefail
artifact="${1:?Usage: notarize.sh app-or-dmg}"
: "${NOTARY_KEY_PATH:?Missing notarization key path}"
: "${NOTARY_KEY_ID:?Missing notarization key ID}"
: "${NOTARY_ISSUER_ID:?Missing notarization issuer ID}"
if [[ "$artifact" == *.app ]]; then
  staging=$(mktemp -d "${TMPDIR:-/tmp}/windowswitch-notary.XXXXXX")
  trap 'rm -rf "$staging"' EXIT
  submission="$staging/WindowSwitch.zip"
  ditto --norsrc --noextattr -c -k --keepParent "$artifact" "$submission"
else
  submission="$artifact"
fi
xcrun notarytool submit "$submission" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
