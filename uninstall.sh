#!/bin/zsh
set -euo pipefail

NEW_PLIST="$HOME/Library/LaunchAgents/com.local.egress-monitor.plist"
PREVIOUS_PLIST="$HOME/Library/LaunchAgents/com.local.openai-egress-status.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/com.local.openai-egress-monitor.plist"
APP_BUNDLE="$HOME/Applications/EgressMonitor.app"
PREVIOUS_APP_BUNDLE="$HOME/Applications/OpenAI Egress Status.app"

launchctl bootout "gui/$(id -u)" "$NEW_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$PREVIOUS_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$OLD_PLIST" >/dev/null 2>&1 || true
rm -f "$NEW_PLIST" "$PREVIOUS_PLIST" "$OLD_PLIST"
rm -rf "$APP_BUNDLE" "$PREVIOUS_APP_BUNDLE"

echo "Uninstalled EgressMonitor"
echo "Kept config and logs under:"
echo "  $HOME/Library/Application Support/openai-egress-monitor"
echo "  $HOME/Library/Logs/openai-egress-monitor"
