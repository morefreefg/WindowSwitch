#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
build_root="${WINDOWSWITCH_BUILD_ROOT:-${TMPDIR:-/tmp}/windowswitch-build}"
cd "$project_root"
xcodegen generate
build_options=()
if [[ -n "${WINDOWSWITCH_APP_ID:-}" ]]; then build_options+=("WINDOWSWITCH_APP_ID=$WINDOWSWITCH_APP_ID"); fi
if [[ -n "${WINDOWSWITCH_VERSION:-}" ]]; then build_options+=("MARKETING_VERSION=$WINDOWSWITCH_VERSION"); fi
if [[ -n "${WINDOWSWITCH_BUILD_NUMBER:-}" ]]; then build_options+=("CURRENT_PROJECT_VERSION=$WINDOWSWITCH_BUILD_NUMBER"); fi
xcodebuild -project WindowSwitch.xcodeproj -scheme WindowSwitch -configuration Release \
  -derivedDataPath "$build_root" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  "OTHER_SWIFT_FLAGS=\$(inherited) -debug-prefix-map $project_root=/workspace/WindowSwitch -file-prefix-map $project_root=/workspace/WindowSwitch" \
  "OTHER_CFLAGS=\$(inherited) -fdebug-prefix-map=$project_root=/workspace/WindowSwitch -ffile-prefix-map=$project_root=/workspace/WindowSwitch" \
  "${build_options[@]}" build
"$project_root/Scripts/sign.sh" "$build_root/Build/Products/Release/WindowSwitch.app"
print -r -- "App: $build_root/Build/Products/Release/WindowSwitch.app"
