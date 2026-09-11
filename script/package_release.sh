#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexQuotaBar"
VERSION="0.4.2"
BUILD_ROOT="${CQB_BUILD_ROOT:-$ROOT_DIR/native/build-release-$VERSION}"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
RELEASE_DIR="${CQB_RELEASE_DIR:-$ROOT_DIR/release/v$VERSION}"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.app.zip"
CHECKSUM_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.sha256"
INSTALL_README="$RELEASE_DIR/README-INSTALL.txt"

mkdir -p "$RELEASE_DIR"
for artifact in "$DMG_PATH" "$ZIP_PATH" "$CHECKSUM_PATH" "$INSTALL_README"; do
  if [[ -e "$artifact" ]]; then
    printf 'Refusing to overwrite existing release artifact: %s\n' "$artifact" >&2
    exit 1
  fi
done
STAGE_DIR="$(mktemp -d "$RELEASE_DIR/dmg-stage-$VERSION.XXXXXX")"

CQB_BUILD_ROOT="$BUILD_ROOT" "$ROOT_DIR/script/build.sh" >/dev/null
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || { printf 'Bundle version mismatch\n' >&2; exit 1; }
codesign --verify --deep --strict "$APP_BUNDLE"

ditto --norsrc --noextattr "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

cat >"$STAGE_DIR/README-INSTALL.txt" <<README
CodexQuotaBar $VERSION

Install:
1. Open the DMG, or extract the ZIP, and drag CodexQuotaBar.app into Applications.
2. Open CodexQuotaBar from Applications.
3. If macOS blocks the app, open System Settings > Privacy & Security and allow it.
4. Optional: enable Open at Login from the CodexQuotaBar menu.

Requirements:
- Apple Silicon (arm64), macOS 13 or newer.
- ChatGPT desktop app, legacy Codex desktop app, or Codex CLI installed.
- Quota reading requires a ChatGPT account authenticated in the local Codex app-server.
- An API-only or unauthenticated setup may show unknown quota (--); this is not a zero balance.
- This app is ad-hoc signed and is not notarized.

Uninstall:
1. Quit CodexQuotaBar from the menu bar.
2. Move /Applications/CodexQuotaBar.app to Trash.
3. Optional clean removal: use Clear Local Data from the app menu before quitting,
   or move ~/Library/Application Support/CodexQuotaBar to Trash after quitting.

Privacy:
- Reads local Codex quota through the local Codex app-server.
- Extracts Token-count, timestamp, and model metadata from ~/.codex/sessions and ~/.codex/archived_sessions for local usage summaries.
- The Codex CLI may maintain its own runtime state under ~/.codex.
- Does not read browser cookies.
- Does not read ~/.codex/auth.json.
- Does not store prompts or responses.
- Does not install a LaunchAgent, daemon, or auto-updater.
- Open at Login is optional and controlled from the app menu.
- Stores UI preferences, local quota history, and the local Token index under ~/Library/Application Support/CodexQuotaBar.
- Quota history is stored in history.sqlite and contains timestamps, remaining quota percentages, reset times, plan, and source only.
README

cp "$STAGE_DIR/README-INSTALL.txt" "$INSTALL_README"

ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$ZIP_PATH"
DMG_OK=0
if hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -format UDZO \
  "$DMG_PATH" >/dev/null; then
  hdiutil verify "$DMG_PATH" >/dev/null
  DMG_OK=1
else
  printf 'DMG creation unavailable; publishing ZIP fallback only.\n' >&2
fi

(
  cd "$RELEASE_DIR"
  ASSETS=("$(basename "$ZIP_PATH")" "README-INSTALL.txt")
  if [[ "$DMG_OK" == 1 ]]; then ASSETS+=("$(basename "$DMG_PATH")"); fi
  shasum -a 256 "${ASSETS[@]}" >"$(basename "$CHECKSUM_PATH")"
)

if [[ "$DMG_OK" == 1 ]]; then printf "%s\n" "$DMG_PATH"; fi
printf "%s\n" "$ZIP_PATH"
printf "%s\n" "$CHECKSUM_PATH"
