#!/bin/bash
# Regenerates the app icon from scripts/make-icon.swift:
#   Resources/AppIcon.icns   copied into the app bundle by scripts/install.sh
#   docs/images/icon.png     shown in the README
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift "$ROOT/scripts/make-icon.swift" "$TMP" >/dev/null
mkdir -p "$ROOT/Resources" "$ROOT/docs/images"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
cp "$TMP/icon.png" "$ROOT/docs/images/icon.png"
echo "wrote Resources/AppIcon.icns and docs/images/icon.png"
