#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-Memograph}"
APP_DIR="${APP_DIR:-dist/${APP_NAME}.app}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found at ${APP_DIR}. Run ./scripts/build_release.sh first." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
spctl -a -t exec -vv "$APP_DIR"
echo "Verification complete for ${APP_DIR}"
