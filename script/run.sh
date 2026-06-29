#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/native/build/CodexQuotaBar.app"

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/CodexQuotaBar" ]]; then
  "$ROOT_DIR/script/build.sh" >/dev/null
fi

/usr/bin/open -na "$APP_BUNDLE"
