#!/bin/zsh
set -euo pipefail
destination="${1:?Usage: sparkle-tools.sh destination}"
mkdir -p "$destination"
archive="$destination/Sparkle.tar.xz"
curl --fail --location --retry 3 --silent --show-error https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz -o "$archive"
print -r -- "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  $archive" | shasum -a 256 -c -
tar -xJf "$archive" -C "$destination"
