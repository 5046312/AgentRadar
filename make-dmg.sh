#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AgentRadar"
APP_BUNDLE="$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_TEMP="$APP_NAME-temp.dmg"
VOL_NAME="$APP_NAME"
STAGING="/tmp/agentradar-dmg-staging"

# 先构建
if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "未找到 $APP_BUNDLE，先执行构建..."
    ./build.sh
fi

echo "[1/4] 准备 DMG 内容"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "[2/4] 创建 DMG"
rm -f "$DMG_TEMP" "$DMG_NAME"
hdiutil create -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDRW \
    "$DMG_TEMP"

echo "[3/4] 设置窗口样式"
DEVICE=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep '/Volumes/' | awk '{print $1}')
MOUNT="/Volumes/$VOL_NAME"

osascript <<EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 720, 400}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set position of item "$APP_BUNDLE" of container window to {130, 140}
        set position of item "Applications" of container window to {390, 140}
        close
    end tell
end tell
EOF
sync
hdiutil detach "$DEVICE" 2>/dev/null || true

echo "[4/4] 压缩 DMG"
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"
rm -f "$DMG_TEMP"
rm -rf "$STAGING"

echo
echo "完成 → $DMG_NAME ($(du -h "$DMG_NAME" | cut -f1))"
echo "双击打开，拖 AgentRadar 到 Applications 即可。"
