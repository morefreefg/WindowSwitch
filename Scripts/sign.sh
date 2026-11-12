#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app_path="${1:?Usage: sign.sh /path/to/WindowSwitch.app}"
signing_identity="${WINDOWSWITCH_SIGNING_IDENTITY:--}"
signing_options=(--force --sign "$signing_identity" --options runtime)
entitlements="$project_root/Sources/WindowSwitch.entitlements"
# 自签名证书：身份固定（升级后保留 TCC 授权），但同样没有 Team ID，也不能用 Apple 时间戳服务
self_signed="${WINDOWSWITCH_SIGNING_SELF_SIGNED:-0}"
if [[ "$signing_identity" == '-' || "$self_signed" == 1 ]]; then
  signing_options+=(--timestamp=none)
  # adhoc/自签名都没有 Team ID，hardened runtime 的 library validation 会拒绝加载内嵌 framework
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/windowswitch-sign.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  entitlements="$scratch/WindowSwitch.entitlements"
  cp "$project_root/Sources/WindowSwitch.entitlements" "$entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements" >/dev/null
else
  signing_options+=(--timestamp)
fi
if [[ -n "${WINDOWSWITCH_SIGNING_KEYCHAIN:-}" ]]; then signing_options+=(--keychain "$WINDOWSWITCH_SIGNING_KEYCHAIN"); fi
for framework in "$app_path"/Contents/Frameworks/*.framework(N); do
  if [[ "${framework:t}" == Sparkle.framework ]]; then
    for helper in "$framework/Versions/B/XPCServices/Installer.xpc" "$framework/Versions/B/XPCServices/Downloader.xpc" \
                  "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app"; do
      [[ ! -e "$helper" ]] || codesign "${signing_options[@]}" --preserve-metadata=entitlements "$helper"
    done
  fi
  codesign "${signing_options[@]}" "$framework"
done
codesign "${signing_options[@]}" --entitlements "$entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"
