#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app_path="${1:?Usage: sign.sh /path/to/WindowSwitch.app}"
signing_identity="${WINDOWSWITCH_SIGNING_IDENTITY:--}"
signing_options=(--force --sign "$signing_identity" --options runtime)
if [[ "$signing_identity" == '-' ]]; then signing_options+=(--timestamp=none); else signing_options+=(--timestamp); fi
if [[ -n "${WINDOWSWITCH_SIGNING_KEYCHAIN:-}" ]]; then signing_options+=(--keychain "$WINDOWSWITCH_SIGNING_KEYCHAIN"); fi
for framework in "$app_path"/Contents/Frameworks/*.framework(N); do codesign "${signing_options[@]}" "$framework"; done
codesign "${signing_options[@]}" --entitlements "$project_root/Sources/WindowSwitch.entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"
