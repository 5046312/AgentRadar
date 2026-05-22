#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AgentRadar"
APP_BUNDLE="$APP_NAME.app"

echo "[1/4] swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
EXEC="$BIN_PATH/$APP_NAME"
if [[ ! -f "$EXEC" ]]; then
    echo "build artifact not found at $EXEC" >&2
    exit 1
fi

echo "[2/4] assemble $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$EXEC" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "[3/4] codesign ad-hoc"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "[4/4] done -> $APP_BUNDLE"
echo
echo "运行：open ./$APP_BUNDLE"
echo "或后台启动：./$APP_BUNDLE/Contents/MacOS/$APP_NAME &"
