#!/usr/bin/env bash
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/io.github.wonsss.runnerbar.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "removed $PLIST"
