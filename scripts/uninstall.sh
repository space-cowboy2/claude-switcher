#!/bin/bash
# Removes Claude Switcher: the menu bar app, its login item, the command-line tool and the hooks.
# Sessions stay where they are in both profiles. The second profile (and its sign-in), the config
# and the backups in ~/Library/Application Support/AccountSwitcher are kept; delete that folder by
# hand if you want them gone.
set -uo pipefail

APP="$HOME/Applications/Claude Switcher.app"
LABEL="com.dannytran.claude-switcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_LINK="$HOME/.local/bin/claude-switch"

[ -x "$BIN_LINK" ] && "$BIN_LINK" uninstall-hooks
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -f "$APP/Contents/MacOS/ClaudeSwitcher" 2>/dev/null
rm -f "$PLIST" "$BIN_LINK"
rm -rf "$APP"
echo "Removed. Kept: ~/Library/Application Support/AccountSwitcher (second profile, config, backups)."
