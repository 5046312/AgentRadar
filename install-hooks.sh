#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

APP_EXECUTABLE="/Applications/AgentRadar.app/Contents/MacOS/AgentRadar"
if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "未找到已安装的 AgentRadar，请先运行 ./package-and-run.sh" >&2
    exit 1
fi
exec "$APP_EXECUTABLE" install-hooks
