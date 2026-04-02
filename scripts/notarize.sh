#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-Memograph}"
APP_DIR="${APP_DIR:-dist/${APP_NAME}.app}"
ZIP_PATH="${ZIP_PATH:-dist/${APP_NAME}.zip}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set NOTARY_PROFILE to a valid xcrun notarytool keychain profile." >&2
  exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found at ${APP_DIR}. Run ./scripts/build_release.sh first." >&2
  exit 1
fi

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
echo "Notarization complete for ${APP_DIR}"
