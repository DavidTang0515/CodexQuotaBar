#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexQuotaBar"
APP_VERSION="0.4.1"
APP_BUNDLE="$ROOT_DIR/native/build/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
MODULE_CACHE_DIR="$ROOT_DIR/native/build/module-cache"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
mkdir -p "$MODULE_CACHE_DIR"

swiftc "$ROOT_DIR/native/CodexQuotaBar.swift" \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -o "$APP_BINARY" \
  -framework AppKit \
  -framework Foundation \
  -framework ServiceManagement \
  -lsqlite3

cp "$ROOT_DIR/native/codex_quota.py" "$APP_RESOURCES/codex_quota.py"
cp "$ROOT_DIR/native/codex_usage.py" "$APP_RESOURCES/codex_usage.py"
chmod +x "$APP_BINARY" "$APP_RESOURCES/codex_quota.py" "$APP_RESOURCES/codex_usage.py"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.codexquotabar</string>
  <key>CFBundleName</key>
  <string>CodexQuotaBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>7</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_BUNDLE" >/dev/null
printf "%s\n" "$APP_BUNDLE"
