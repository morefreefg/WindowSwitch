#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
build_root="${WINDOWSWITCH_BUILD_ROOT:-${TMPDIR:-/tmp}/windowswitch-build}"
app_path="${1:-$build_root/Build/Products/Release/WindowSwitch.app}"
output_dir="${WINDOWSWITCH_DIST_DIR:-$project_root/dist}"
[[ -d "$app_path" ]] || { print -u2 'Build the Release app first.'; exit 66; }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9.]+)?$' ]] || exit 65
binary="$app_path/Contents/MacOS/WindowSwitch"
architectures=$(lipo -archs "$binary")
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] || { print -u2 'Expected a Universal app.'; exit 65; }
codesign --verify --deep --strict "$app_path"
mkdir -p "$output_dir"
staging=$(mktemp -d "${TMPDIR:-/tmp}/windowswitch-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
if [[ "${WINDOWSWITCH_NOTARIZE:-0}" == 1 ]]; then "$project_root/Scripts/notarize.sh" "$app_path"; fi
ditto --norsrc --noextattr "$app_path" "$staging/WindowSwitch.app"
ln -s /Applications "$staging/Applications"
name="WindowSwitch-$version-universal"
hdiutil create -quiet -ov -format UDZO -volname WindowSwitch -srcfolder "$staging" "$output_dir/$name.dmg"
ditto --norsrc --noextattr -c -k --keepParent "$app_path" "$output_dir/$name.zip"
if [[ "${WINDOWSWITCH_NOTARIZE:-0}" == 1 ]]; then "$project_root/Scripts/notarize.sh" "$output_dir/$name.dmg"; fi
python3 "$project_root/Scripts/artifact-manifest.py" "$app_path" "$output_dir/$name.build.json"
(cd "$output_dir" && shasum -a 256 "$name.dmg" "$name.zip" "$name.build.json" > SHA256SUMS)
print -r -- "Packaged: $output_dir/$name.dmg"
