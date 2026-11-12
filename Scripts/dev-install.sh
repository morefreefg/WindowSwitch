#!/bin/zsh
# Build this checkout, sign it with the stable release certificate, and replace the
# installed app, so local builds keep the installed app's Accessibility/Screen Recording
# permissions and can be tested with real hotkeys before anything is released.
#   WINDOWSWITCH_SIGNING_KEYCHAIN           keychain holding "WindowSwitch Release Signing"
#   WINDOWSWITCH_SIGNING_KEYCHAIN_PASSWORD  file containing that keychain's password
set -euo pipefail
project_root="${0:A:h:h}"
: "${WINDOWSWITCH_SIGNING_KEYCHAIN:?Set WINDOWSWITCH_SIGNING_KEYCHAIN}"
: "${WINDOWSWITCH_SIGNING_KEYCHAIN_PASSWORD:?Set WINDOWSWITCH_SIGNING_KEYCHAIN_PASSWORD}"
security unlock-keychain -p "$(<"$WINDOWSWITCH_SIGNING_KEYCHAIN_PASSWORD")" "$WINDOWSWITCH_SIGNING_KEYCHAIN"
export WINDOWSWITCH_SIGNING_IDENTITY="WindowSwitch Release Signing" WINDOWSWITCH_SIGNING_SELF_SIGNED=1
export WINDOWSWITCH_BUILD_ROOT="${WINDOWSWITCH_BUILD_ROOT:-${TMPDIR:-/tmp}/windowswitch-dev-build}"
"$project_root/Scripts/build.sh" >/dev/null
app_source="$WINDOWSWITCH_BUILD_ROOT/Build/Products/Release/WindowSwitch.app"
app_target="$HOME/Applications/WindowSwitch.app"
requirement=$(codesign -d -r- "$app_source" 2>&1 | sed -n 's/^designated => //p')
[[ "$requirement" == *'certificate leaf'* ]] || { print -u2 'Build is not certificate-signed; refusing to install.'; exit 65; }
osascript -e 'quit app id "io.github.morefreefg.WindowSwitch"' >/dev/null 2>&1 || true
for _ in {1..40}; do pgrep -f "^$app_target/Contents/MacOS/WindowSwitch" >/dev/null || break; sleep 0.25; done
if pgrep -f "^$app_target/Contents/MacOS/WindowSwitch" >/dev/null; then print -u2 'WindowSwitch did not quit.'; exit 1; fi
if [[ -e "$app_target" ]]; then
  backup=$(mktemp -d "${TMPDIR:-/tmp}/windowswitch-previous.XXXXXX")
  mv "$app_target" "$backup/WindowSwitch.app"
  print -r -- "Previous app: $backup/WindowSwitch.app"
fi
ditto --norsrc --noextattr "$app_source" "$app_target"
codesign --verify --deep --strict "$app_target"
open "$app_target"
print -r -- "Installed $(git -C "$project_root" describe --tags --always --dirty) with: $requirement"
