#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AgentRadar"
APP_BUNDLE="$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_BUNDLE"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
INSTALL_WORK_DIR=""
BACKUP_APP=""
HAD_INSTALLED_APP=false

cleanup() {
    if [[ -n "$INSTALL_WORK_DIR" && -d "$INSTALL_WORK_DIR" ]]; then
        rm -rf "$INSTALL_WORK_DIR"
    fi
}
trap cleanup EXIT

restore_installed_app() {
    echo "恢复旧安装：$INSTALLED_APP" >&2
    if [[ "$HAD_INSTALLED_APP" == true ]]; then
        if rm -rf "$INSTALLED_APP" 2>/dev/null && ditto "$BACKUP_APP" "$INSTALLED_APP"; then
            return
        fi
        sudo rm -rf "$INSTALLED_APP"
        sudo ditto "$BACKUP_APP" "$INSTALLED_APP"
        return
    fi

    if ! rm -rf "$INSTALLED_APP" 2>/dev/null; then
        sudo rm -rf "$INSTALLED_APP"
    fi
}

echo "[1/5] 构建 $APP_BUNDLE"
./build.sh

echo "[2/5] 打包 $APP_NAME.dmg"
./make-dmg.sh

echo "[3/5] 关闭旧实例"
if pgrep -x "$APP_NAME" >/dev/null; then
    # 先结束本地包或旧安装包进程，避免 LaunchServices 继续激活旧实例。
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x "$APP_NAME" >/dev/null; then
            break
        fi
        sleep 0.1
    done
    pkill -x "$APP_NAME" 2>/dev/null || true
    for _ in {1..20}; do
        if ! pgrep -x "$APP_NAME" >/dev/null; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "无法关闭旧实例，停止安装。" >&2
        exit 1
    fi
else
    echo "未发现运行中的 $APP_NAME"
fi

echo "[4/5] 安装到 $INSTALLED_APP"
INSTALL_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentradar-install.XXXXXX")"
BACKUP_APP="$INSTALL_WORK_DIR/$APP_BUNDLE"
if [[ -d "$INSTALLED_APP" ]]; then
    # 完整替换前保留旧包；写入或二进制校验失败时恢复安装前状态。
    ditto "$INSTALLED_APP" "$BACKUP_APP"
    HAD_INSTALLED_APP=true
fi

if ! rm -rf "$INSTALLED_APP" 2>/dev/null || ! ditto "$APP_BUNDLE" "$INSTALLED_APP"; then
    echo "写入 /Applications 需要管理员权限。"
    if ! sudo rm -rf "$INSTALLED_APP" || ! sudo ditto "$APP_BUNDLE" "$INSTALLED_APP"; then
        restore_installed_app
        echo "安装失败，已恢复安装前状态。" >&2
        exit 1
    fi
fi

if [[ ! -x "$INSTALLED_EXECUTABLE" ]] || ! cmp -s "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$INSTALLED_EXECUTABLE"; then
    restore_installed_app
    echo "安装校验失败：$INSTALLED_EXECUTABLE 不是本次构建版本" >&2
    exit 1
fi

echo "[5/5] 启动安装后的 App"
open -n "$INSTALLED_APP"

for _ in {1..30}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
        break
    fi
    sleep 0.1
done

if ! pgrep -x "$APP_NAME" >/dev/null; then
    echo "启动失败：未发现 $APP_NAME 进程" >&2
    exit 1
fi

echo
echo "运行中 -> $INSTALLED_APP"
echo "本地构建 -> ./$APP_BUNDLE"
echo "DMG -> ./$APP_NAME.dmg"
