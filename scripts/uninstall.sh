#!/bin/bash
# Removes Second Wind: the menu bar app, its login item, the command-line tool and the hooks.
# Also removes an install made under the old name (Claude Switcher).
# Sessions stay where they are in both profiles. The second profile (and its sign-in), the config
# and the backups in ~/Library/Application Support/AccountSwitcher are kept; delete that folder by
# hand if you want them gone.
set -uo pipefail

APP="$HOME/Applications/Second Wind.app"
LABEL="io.github.space-cowboy2.secondwind"
AGENTS="$HOME/Library/LaunchAgents"
BIN_LINK="$HOME/.local/bin/secondwind"

if [ -x "$BIN_LINK" ]; then "$BIN_LINK" uninstall-hooks; fi
for plist in "$AGENTS/$LABEL.plist" "$AGENTS"/*.claude-switcher.plist; do
  [ -e "$plist" ] || continue
  launchctl bootout "gui/$(id -u)/$(basename "$plist" .plist)" 2>/dev/null
  rm -f "$plist"
done
pkill -f "$APP/Contents/MacOS/SecondWindBar" 2>/dev/null
pkill -f "$HOME/Applications/Claude Switcher.app/Contents/MacOS/" 2>/dev/null
rm -f "$BIN_LINK" "$HOME/.local/bin/claude-switch"
rm -rf "$APP" "$HOME/Applications/Claude Switcher.app"
echo "Removed. Kept: ~/Library/Application Support/AccountSwitcher (second profile, config, backups)."
