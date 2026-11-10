#!/bin/bash
# Builds Claude Switcher and installs it for the current user:
#   ~/Applications/Claude Switcher.app      menu bar app (starts at login)
#   ~/.local/bin/claude-switch              command-line tool
#   ~/.claude/settings.json                 two Claude Code hooks (a backup is written first)
# Nothing here touches Claude's own data or sign-in. Undo with scripts/uninstall.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Claude Switcher.app"
LABEL="com.dannytran.claude-switcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_LINK="$HOME/.local/bin/claude-switch"

cd "$ROOT"
swift build -c release

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/ClaudeSwitcher" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeSwitcher .build/release/claude-switch "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Switcher</string>
  <key>CFBundleDisplayName</key><string>Claude Switcher</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1

mkdir -p "$(dirname "$BIN_LINK")"
ln -sf "$APP/Contents/MacOS/claude-switch" "$BIN_LINK"

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ClaudeSwitcher</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

"$BIN_LINK" install-hooks --bin "$BIN_LINK"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Installed. Look for the ⇄ icon in the menu bar."
"$BIN_LINK" status
