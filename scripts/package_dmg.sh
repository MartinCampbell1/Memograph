#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-Memograph}"
APP_DIR="${APP_DIR:-dist/${APP_NAME}.app}"
DMG_PATH="${DMG_PATH:-dist/${APP_NAME}.dmg}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found at ${APP_DIR}. Run ./scripts/build_release.sh first." >&2
  exit 1
fi

rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"
echo "Packaged DMG at: ${DMG_PATH}"
