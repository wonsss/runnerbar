#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/RunnerBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
swift scripts/create-app-icon.swift
swift build -c release

rm -rf "$APP"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"
cp "$ROOT/.build/release/RunnerBar" "$MACOS/RunnerBar"
cp "$ROOT/Resources/RunnerBar.icns" "$RESOURCES/RunnerBar.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>RunnerBar</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.wonsss.runnerbar</string>
  <key>CFBundleName</key>
  <string>RunnerBar</string>
  <key>CFBundleIconFile</key>
  <string>RunnerBar</string>
  <key>CFBundleIconName</key>
  <string>RunnerBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "$APP"
