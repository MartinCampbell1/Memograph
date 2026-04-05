#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Memograph}"
REPO_URL="${REPO_URL:-https://github.com/MartinCampbell1/Memograph.git}"
DEST_DIR="${DEST_DIR:-/Applications}"
DEST_APP="${DEST_DIR}/${APP_NAME}.app"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command git
require_command swift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || true)"
TEMP_DIR=""

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT

if [[ -f "${ROOT_DIR}/Package.swift" && -f "${ROOT_DIR}/scripts/build_release.sh" ]]; then
  WORK_DIR="$ROOT_DIR"
else
  TEMP_DIR="$(mktemp -d)"
  WORK_DIR="${TEMP_DIR}/Memograph"
  git clone --depth 1 "$REPO_URL" "$WORK_DIR" >/dev/null
fi

cd "$WORK_DIR"
./scripts/build_release.sh >/dev/null

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x MyMacAgent >/dev/null 2>&1 || true
pkill -f "/Audio/whisper_transcribe.py" >/dev/null 2>&1 || true

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
ditto "dist/${APP_NAME}.app" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" >/dev/null 2>&1 || true

echo "Installed ${APP_NAME} to ${DEST_APP}"
echo "Launching ${APP_NAME}..."
if ! open -n "$DEST_APP"; then
  echo "open -n failed; falling back to direct executable launch." >&2
  "${DEST_APP}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
fi
