#!/bin/zsh
set -euo pipefail

REFRESH_INTERVAL="${1:-300}"
if ! [[ "$REFRESH_INTERVAL" =~ '^[0-9]+$' ]] || [[ "$REFRESH_INTERVAL" -lt 30 ]]; then
  echo "Usage: $0 [refresh_interval_seconds]"
  echo "refresh_interval_seconds must be an integer >= 30. Default: 300."
  exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/openai-egress-monitor"
LOG_DIR="$HOME/Library/Logs/openai-egress-monitor"
APPLICATIONS_DIR="$HOME/Applications"
APP_BUNDLE="$APPLICATIONS_DIR/EgressMonitor.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
NEW_PLIST="$LAUNCH_AGENTS_DIR/com.local.egress-monitor.plist"
PREVIOUS_PLIST="$LAUNCH_AGENTS_DIR/com.local.openai-egress-status.plist"
OLD_PLIST="$LAUNCH_AGENTS_DIR/com.local.openai-egress-monitor.plist"
PREVIOUS_APP_BUNDLE="$APPLICATIONS_DIR/OpenAI Egress Status.app"

mkdir -p "$APP_SUPPORT_DIR" "$LOG_DIR" "$APPLICATIONS_DIR" "$LAUNCH_AGENTS_DIR"

swift build -c release --product OpenAIEgressStatus --package-path "$SCRIPT_DIR"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$SCRIPT_DIR/.build/release/OpenAIEgressStatus" "$APP_BUNDLE/Contents/MacOS/EgressMonitor"
chmod 755 "$APP_BUNDLE/Contents/MacOS/EgressMonitor"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>EgressMonitor</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.egress-monitor</string>
  <key>CFBundleName</key>
  <string>EgressMonitor</string>
  <key>CFBundleDisplayName</key>
  <string>EgressMonitor</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

if [[ ! -f "$APP_SUPPORT_DIR/openai-egress-monitor.conf" ]]; then
  cp "$SCRIPT_DIR/config/openai-egress-monitor.conf" "$APP_SUPPORT_DIR/openai-egress-monitor.conf"
fi

ensure_config_key() {
  local key="$1"
  local value="$2"
  local file="$APP_SUPPORT_DIR/openai-egress-monitor.conf"

  if grep -q "^${key}=" "$file"; then
    sed -i '' "s#^${key}=.*#${key}=\"${value}\"#" "$file"
  else
    printf '\n%s="%s"\n' "$key" "$value" >> "$file"
  fi
}

ensure_config_key "IPINFO_URL" "https://ipinfo.io/json"
ensure_config_key "PUBLIC_IP_PROBES" "ipinfo-json|https://ipinfo.io/json;ipapi-json|https://ipapi.co/json/;ipwhois-json|https://ipwho.is/"
ensure_config_key "TRACE_URL" "https://chatgpt.com/cdn-cgi/trace"
ensure_config_key "API_URL" "https://api.openai.com"
ensure_config_key "EXPECTED_LOCS" "JP SG"
ensure_config_key "REFRESH_INTERVAL_SECONDS" "$REFRESH_INTERVAL"
ensure_config_key "NOTIFICATION_OPEN_URL" "https://chatgpt.com/cdn-cgi/trace"

rm -f "$APP_SUPPORT_DIR/openai-egress-monitor.sh"

APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/EgressMonitor"
cat > "$NEW_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.egress-monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_EXECUTABLE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/openai-egress-status.out</string>
  <key>StandardErrorPath</key>
  <string>/tmp/openai-egress-status.err</string>
</dict>
</plist>
PLIST

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
plutil -lint "$NEW_PLIST" >/dev/null

launchctl bootout "gui/$(id -u)" "$OLD_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$PREVIOUS_PLIST" >/dev/null 2>&1 || true
rm -f "$OLD_PLIST"
rm -f "$PREVIOUS_PLIST"
rm -rf "$PREVIOUS_APP_BUNDLE"
launchctl bootout "gui/$(id -u)" "$NEW_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$NEW_PLIST"
launchctl enable "gui/$(id -u)/com.local.egress-monitor"
launchctl kickstart -k "gui/$(id -u)/com.local.egress-monitor"

echo "Installed EgressMonitor"
echo "App: $APP_BUNDLE"
echo "LaunchAgent: $NEW_PLIST"
echo "Refresh interval: ${REFRESH_INTERVAL}s"
echo "Config: $APP_SUPPORT_DIR/openai-egress-monitor.conf"
echo "Latest: $LOG_DIR/latest.txt"
echo "History: $LOG_DIR/openai-egress.jsonl"
