#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexQuotaBar"
VERSION="0.2.0"
APP_BUNDLE="$ROOT_DIR/native/build/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/release"
STAGE_DIR="$RELEASE_DIR/dmg-stage-$VERSION"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.app.zip"
CHECKSUM_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.sha256"
INSTALL_README="$RELEASE_DIR/README-INSTALL.txt"

mkdir -p "$RELEASE_DIR" "$STAGE_DIR"

"$ROOT_DIR/script/build.sh" >/dev/null

ditto --norsrc --noextattr "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -sfn /Applications "$STAGE_DIR/Applications"

cat >"$STAGE_DIR/README-INSTALL.txt" <<README
CodexQuotaBar $VERSION

Install:
1. Drag CodexQuotaBar.app into Applications.
2. Open CodexQuotaBar from Applications.
3. If macOS blocks the app, open System Settings > Privacy & Security and allow it.
4. Optional: enable Open at Login from the CodexQuotaBar menu.

Requirements:
- macOS 13 or newer.
- Codex desktop app or Codex CLI installed and signed in.

Uninstall:
1. Quit CodexQuotaBar from the menu bar.
2. Delete /Applications/CodexQuotaBar.app.
3. Optional clean removal: delete ~/Library/Application Support/CodexQuotaBar/preferences.json.

Privacy:
- Reads local Codex quota through the local Codex app-server.
- Does not read browser cookies.
- Does not read ~/.codex/auth.json.
- Does not store prompts or responses.
- Does not install a LaunchAgent, daemon, or auto-updater.
- Open at Login is optional and controlled from the app menu.
- Stores only UI preferences such as floating ball visibility and position.
README

cp "$STAGE_DIR/README-INSTALL.txt" "$INSTALL_README"

hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$ZIP_PATH"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" "README-INSTALL.txt" >"$(basename "$CHECKSUM_PATH")"
)

printf "%s\n" "$DMG_PATH"
printf "%s\n" "$ZIP_PATH"
printf "%s\n" "$CHECKSUM_PATH"
