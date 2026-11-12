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
scratch=$(mktemp -d "${TMPDIR:-/tmp}/windowswitch-dmg.XXXXXX")
cleanup() {
  [[ -z "${mounted_volume:-}" ]] || hdiutil detach "$mounted_volume" -quiet -force 2>/dev/null || true
  rm -rf "$staging" "$scratch"
}
trap cleanup EXIT
if [[ "${WINDOWSWITCH_NOTARIZE:-0}" == 1 ]]; then "$project_root/Scripts/notarize.sh" "$app_path"; fi
ditto --norsrc --noextattr "$app_path" "$staging/WindowSwitch.app"
ln -s /Applications "$staging/Applications"
mkdir -p "$staging/.background"
swift "$project_root/Scripts/make-dmg-background.swift" "$staging/.background"
tiffutil -cathidpicheck "$staging/.background/background.png" "$staging/.background/background@2x.png" \
  -out "$staging/.background/background.tiff" >/dev/null
rm -f "$staging/.background/background.png" "$staging/.background/background@2x.png"
name="WindowSwitch-$version-universal"

# 先造一个可写镜像，让 Finder 把窗口布局写进 .DS_Store，再压成只读分发镜像
writable="$scratch/writable.dmg"
staged_mb=$(( $(du -sk "$staging" | cut -f1) / 1024 + 50 ))
hdiutil create -quiet -ov -format UDRW -volname WindowSwitch -size "${staged_mb}m" -srcfolder "$staging" "$writable"
attach_output=$(hdiutil attach "$writable" -nobrowse -noverify -noautoopen)
mounted_volume=$(print -r -- "$attach_output" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)
[[ -n "$mounted_volume" ]] || { print -u2 'Could not mount the writable image.'; exit 70; }
# 缺少 ds-store 时只是拿不到窗口布局，镜像内容本身不受影响
if ! "${WINDOWSWITCH_PYTHON:-python3}" "$project_root/Scripts/dmg-layout.py" "$mounted_volume"; then
  print -u2 -r -- 'Warning: packaged without the window layout; `pip install ds-store` enables it.'
fi
sync
hdiutil detach "$mounted_volume" -quiet
mounted_volume=''
hdiutil convert "$writable" -quiet -format UDZO -imagekey zlib-level=9 -ov -o "$output_dir/$name.dmg"

ditto --norsrc --noextattr -c -k --keepParent "$app_path" "$output_dir/$name.zip"
if [[ "${WINDOWSWITCH_NOTARIZE:-0}" == 1 ]]; then "$project_root/Scripts/notarize.sh" "$output_dir/$name.dmg"; fi
python3 "$project_root/Scripts/artifact-manifest.py" "$app_path" "$output_dir/$name.build.json"
(cd "$output_dir" && shasum -a 256 "$name.dmg" "$name.zip" "$name.build.json" > SHA256SUMS)
print -r -- "Packaged: $output_dir/$name.dmg"
