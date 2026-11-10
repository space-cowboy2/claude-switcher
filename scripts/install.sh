#!/bin/bash
# Builds Second Wind and installs it for the current user:
#   ~/Applications/Second Wind.app        menu bar app (starts at login)
#   ~/.local/bin/secondwind               command-line tool
#   ~/.claude/settings.json               two Claude Code hooks (a backup is written first)
# Nothing here touches Claude's own data or sign-in. Undo with scripts/uninstall.sh.
# An install made under the tool's old name (Claude Switcher) is replaced.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Second Wind.app"
LABEL="io.github.space-cowboy2.secondwind"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
BIN_LINK="$HOME/.local/bin/secondwind"

cd "$ROOT"
swift build -c release

# Stop and remove this install and any made under the old name. Old login items are found by
# file name, so no earlier identifier needs spelling out here.
for plist in "$PLIST" "$AGENTS"/*.claude-switcher.plist; do
  [ -e "$plist" ] || continue
  launchctl bootout "gui/$(id -u)/$(basename "$plist" .plist)" 2>/dev/null || true
  rm -f "$plist"
done
pkill -f "$HOME/Applications/Claude Switcher.app/Contents/MacOS/" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/SecondWindBar" 2>/dev/null || true
rm -rf "$HOME/Applications/Claude Switcher.app" "$APP"
rm -f "$HOME/.local/bin/claude-switch"

mkdir -p "$APP/Contents/MacOS"
cp .build/release/SecondWindBar .build/release/secondwind "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Second Wind</string>
  <key>CFBundleDisplayName</key><string>Second Wind</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>SecondWindBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST_EOF
codesign --force --sign - "$APP" >/dev/null 2>&1

mkdir -p "$(dirname "$BIN_LINK")"
ln -sf "$APP/Contents/MacOS/secondwind" "$BIN_LINK"

mkdir -p "$AGENTS"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/SecondWindBar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST_EOF

# Replaces hooks installed under either name.
"$BIN_LINK" install-hooks --bin "$BIN_LINK"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Installed. Look for the ⇄ icon in the menu bar."
"$BIN_LINK" status
