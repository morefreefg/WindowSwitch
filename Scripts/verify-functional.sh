#!/bin/zsh
set -euo pipefail

# Build a disposable fixture, then run the installed, already-authorized app via
# LaunchServices. This script never requests TCC access or stops another tool.
project_root="${0:A:h:h}"
task_root=/tmp/codex-windowswitch
app_target="$HOME/Applications/WindowSwitch.app"
extended=false
build_only=false
render_ui=false
capture_probe=false
focus_stress=false
quick_switch=false
dock_input=false
while (( $# > 0 )); do
  case "$1" in
    --app) app_target="$2"; shift 2 ;;
    --extended) extended=true; shift ;;
    --build-only) build_only=true; shift ;;
    --render-ui) render_ui=true; shift ;;
    --probe-capture) capture_probe=true; render_ui=true; shift ;;
    --focus-stress) focus_stress=true; shift ;;
    --quick-switch) quick_switch=true; shift ;;
    --dock-input) dock_input=true; shift ;;
    *) print -u2 -- "Usage: $0 [--app installed/WindowSwitch.app] [--extended] [--build-only]"; exit 64 ;;
  esac
done

session=$(/usr/bin/uuidgen)
fixture_root="$task_root/Fixture-$session"
fixture_app="$fixture_root/WindowSwitchFixture.app"
fixture_binary="$fixture_app/Contents/MacOS/WindowSwitchFixture"
mkdir -p "$fixture_app/Contents/MacOS"
xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library -O \
  "$project_root/Scripts/WindowSwitchFixture.swift" -o "$fixture_binary"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.morefreefg.WindowSwitchFixture</string>
<key>CFBundleExecutable</key><string>WindowSwitchFixture</string>
<key>CFBundleName</key><string>WindowSwitch Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# This is a newly-created fixture only; the installed WindowSwitch identity is untouched.
/usr/bin/codesign --force --sign - "$fixture_app" >/dev/null
fixture_binary_canonical="${fixture_binary:A}"
print -r -- "Fixture: $fixture_app"
if $build_only; then exit 0; fi

[[ -d "$app_target" ]] || { print -u2 -- "Installed app missing: $app_target"; exit 66; }
app_bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_target/Contents/Info.plist")
[[ "$app_bundle" == "${WINDOWSWITCH_APP_ID:-io.github.morefreefg.WindowSwitch}" ]] || { print -u2 -- 'Unexpected installed app bundle ID'; exit 65; }

fixture_pid=""
sentinel_pid=""
cleanup_fixture() {
  local fixture_process actual_command
  for fixture_process in "$fixture_pid" "$sentinel_pid"; do
    [[ -n "$fixture_process" ]] || continue
    actual_command=$(/bin/ps -ww -p "$fixture_process" -o command= 2>/dev/null || true)
    if [[ ( "$actual_command" == "$fixture_binary "* || "$actual_command" == "$fixture_binary_canonical "* ) && "$actual_command" == *"--session $session"* ]]; then
      /bin/kill -TERM "$fixture_process" 2>/dev/null || true
    fi
  done
}
trap cleanup_fixture EXIT INT TERM

wait_fixture() {
  python3 - "$session" "$1" <<'PY'
import glob, json, sys, time
session, sentinel = sys.argv[1], sys.argv[2] == 'true'
for _ in range(100):
    for path in glob.glob('/tmp/codex-windowswitch/fixture-state-*.json'):
        try:
            value = json.load(open(path))
            if (value.get('session') == session and value.get('sentinel') == sentinel
                    and value.get('launchReady') is True and value.get('activationObserved') is True
                    and len(value.get('windows', [])) >= value.get('expectedWindowCount', 999)):
                print(value['pid']); sys.exit(0)
        except (OSError, ValueError):
            pass
    time.sleep(.1)
sys.exit(1)
PY
}

fixture_arguments=(--session "$session")
if $capture_probe; then fixture_arguments+=(--capture-child); fi
/usr/bin/open -n "$fixture_app" --args "${fixture_arguments[@]}"
fixture_pid=$(wait_fixture false)
/usr/bin/open -n "$fixture_app" --args --session "$session" --sentinel
sentinel_pid=$(wait_fixture true)

verifier_args=(--verify-fixture --fixture-session "$session" --fixture-app "$fixture_app")
if $extended; then verifier_args+=(--extended); fi
if $render_ui; then verifier_args+=(--render-ui); fi
if $capture_probe; then verifier_args+=(--probe-capture); fi
if $focus_stress; then verifier_args+=(--focus-stress); fi
if $quick_switch; then verifier_args+=(--quick-switch); fi
if $dock_input; then verifier_args+=(--dock-input); fi
/usr/bin/open -n -g --stdout "$fixture_root/verifier.log" --stderr "$fixture_root/verifier-error.log" \
  "$app_target" --args "${verifier_args[@]}"

python3 - "$session" "$render_ui" <<'PY'
import json, sys, time
session = sys.argv[1]
path = '/tmp/codex-windowswitch/' + ('ui-functional-report.json' if sys.argv[2] == 'true' else 'functional-report.json')
for _ in range(1800):
    try:
        report = json.load(open(path))
        if report.get('session') == session:
            print(json.dumps(report, ensure_ascii=False, indent=2))
            print('Report: ' + path)
            sys.exit({'passed': 0, 'blocked': 2}.get(report.get('status'), 1))
    except (OSError, ValueError):
        pass
    time.sleep(.1)
print('Timed out waiting for this fixture session report', file=sys.stderr)
sys.exit(124)
PY
