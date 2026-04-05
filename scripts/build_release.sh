#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-Memograph}"
BINARY_NAME="${BINARY_NAME:-MyMacAgent}"
BUNDLE_ID="${BUNDLE_ID:-com.memograph.app}"
VERSION="${VERSION:-0.1.0}"
BUILD_DIR="${BUILD_DIR:-dist/build}"
APP_DIR="${APP_DIR:-dist/${APP_NAME}.app}"
ICON_PATH="${ICON_PATH:-AppAssets/AppIcon.icns}"

mkdir -p "$BUILD_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${BINARY_NAME}"
BIN_DIR="$(dirname "$BIN_PATH")"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

if compgen -G "${BIN_DIR}/*.bundle" > /dev/null; then
  cp -R "${BIN_DIR}"/*.bundle "$APP_DIR/Contents/Resources/"
fi

if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAccessibilityUsageDescription</key>
  <string>Accessibility access improves context extraction for active windows and focused UI.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Microphone access is optional and only used when experimental audio transcription is enabled.</string>
</dict>
</plist>
EOF

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --identifier "$BUNDLE_ID" --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
  # Force a clean ad-hoc signature so TCC and macOS privacy panes see the shipped bundle ID,
  # not the original SwiftPM product identifier baked into the executable.
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

echo "Release app built at: ${APP_DIR}"
