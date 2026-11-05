#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
build_root="${WINDOWSWITCH_BUILD_ROOT:-${TMPDIR:-/tmp}/windowswitch-build}"
app_source="$build_root/Build/Products/Release/WindowSwitch.app"
app_target="$HOME/Applications/WindowSwitch.app"
[[ -d "$app_source" ]] || "$project_root/Scripts/build.sh"
codesign --verify --deep --strict "$app_source"
if pgrep -f "^$app_target/Contents/MacOS/WindowSwitch" >/dev/null; then print -u2 'Quit WindowSwitch before installing.'; exit 1; fi
if [[ -e "$app_target" ]]; then
  installed_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_target/Contents/Info.plist")
  source_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_source/Contents/Info.plist")
  [[ "$installed_id" == "$source_id" ]] || { print -u2 'The installed app has a different identity; it was not replaced.'; exit 65; }
  backup_root=$(mktemp -d "${TMPDIR:-/tmp}/windowswitch-install.XXXXXX")
  mv "$app_target" "$backup_root/WindowSwitch.app"
fi
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "$app_source" "$app_target"
codesign --verify --deep --strict "$app_target"
print -r -- "Installed: $app_target"
