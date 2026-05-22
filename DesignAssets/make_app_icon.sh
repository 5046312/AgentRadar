#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ICON_NAME="AppIcon"
PNG_PATH="Assets/${ICON_NAME}-1024.png"
ICONSET="/tmp/agentradar-${ICON_NAME}.iconset"

swift DesignAssets/render_app_icon.swift "$PNG_PATH"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

sips -z 16 16     "$PNG_PATH" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$PNG_PATH" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$PNG_PATH" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$PNG_PATH" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$PNG_PATH" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$PNG_PATH" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$PNG_PATH" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$PNG_PATH" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$PNG_PATH" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$PNG_PATH" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "Assets/${ICON_NAME}.icns"
rm -rf "$ICONSET"

echo "generated Assets/${ICON_NAME}.icns"
