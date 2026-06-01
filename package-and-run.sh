#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AgentRadar"
APP_BUNDLE="$APP_NAME.app"

echo "[1/4] 构建 $APP_BUNDLE"
./build.sh

echo "[2/4] 打包 $APP_NAME.dmg"
./make-dmg.sh

echo "[3/4] 关闭旧实例"
if pgrep -x "$APP_NAME" >/dev/null; then
    # 菜单栏 App 已运行时，open 可能只激活旧进程；先退出才能加载刚打出的包。
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x "$APP_NAME" >/dev/null; then
            break
        fi
        sleep 0.1
    done
    pkill -x "$APP_NAME" 2>/dev/null || true
else
    echo "未发现运行中的 $APP_NAME"
fi

echo "[4/4] 启动 $APP_BUNDLE"
open "./$APP_BUNDLE"

echo
echo "完成 -> ./$APP_BUNDLE"
echo "DMG -> ./$APP_NAME.dmg"
