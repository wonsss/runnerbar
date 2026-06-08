#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/RunnerBar.app"
PLIST="$HOME/Library/LaunchAgents/local.runnerbar.plist"

if [ ! -x "$APP/Contents/MacOS/RunnerBar" ]; then
  "$ROOT/scripts/build-app.sh" >/dev/null
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.runnerbar</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/RunnerBar</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/RunnerBar.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/RunnerBar.err.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "$PLIST"
