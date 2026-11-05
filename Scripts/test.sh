#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
build_root="${WINDOWSWITCH_BUILD_ROOT:-${TMPDIR:-/tmp}/windowswitch-build}"
cd "$project_root"
xcodegen generate
xcodebuild -project WindowSwitch.xcodeproj -scheme WindowSwitch -configuration Debug -derivedDataPath "$build_root" -destination 'platform=macOS' test

PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/windowswitch-pycache" python3 -m unittest discover -s Tests -p 'test_*.py'
