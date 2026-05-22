#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AgentRadar"
APP_BUNDLE="$APP_NAME.app"

echo "[1/5] generate AppIcon.icns"
ICON_SRC="Assets/AppIcon-1024.png"
ICON_OUT="Assets/AppIcon.icns"
if [[ ! -f "$ICON_SRC" ]]; then
    echo "missing $ICON_SRC" >&2
    exit 1
fi
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$ICON_SRC" "$ICONSET/icon_512x512@2x.png"
rm -f "$ICON_OUT"
iconutil -c icns "$ICONSET" -o "$ICON_OUT"
rm -rf "$(dirname "$ICONSET")"

echo "[2/5] swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
EXEC="$BIN_PATH/$APP_NAME"
if [[ ! -f "$EXEC" ]]; then
    echo "build artifact not found at $EXEC" >&2
    exit 1
fi

echo "[3/5] assemble $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$EXEC" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp "$ICON_OUT" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "[4/5] refresh icon cache"
touch "$APP_BUNDLE"

echo "[5/5] codesign ad-hoc"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "done -> $APP_BUNDLE"
echo
echo "运行：open ./$APP_BUNDLE"
echo "或后台启动：./$APP_BUNDLE/Contents/MacOS/$APP_NAME &"
