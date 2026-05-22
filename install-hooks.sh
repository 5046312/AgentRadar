#!/usr/bin/env bash
set -euo pipefail

EVENTS_DIR="$HOME/.agentradar"
EVENTS_FILE="$EVENTS_DIR/events.jsonl"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$EVENTS_DIR"
touch "$EVENTS_FILE"

if ! command -v jq >/dev/null 2>&1; then
    echo "需要 jq：brew install jq" >&2
    exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
    echo '{}' > "$SETTINGS"
fi

cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

LOG_CMD='jq -c --arg event "EVENT_NAME" --arg ts "$(date +%s.%N)" '"'"'. + {event: $event, ts: ($ts | tonumber), agentradar_ts: $ts}'"'"' >> "$HOME/.agentradar/events.jsonl"'

build_hook() {
    local event=$1
    local cmd="${LOG_CMD/EVENT_NAME/$event}"
    jq -n --arg cmd "$cmd" '{
        hooks: [
            {
                hooks: [
                    {type: "command", command: $cmd}
                ]
            }
        ]
    }'
}

NEW_HOOKS=$(jq -n \
    --argjson stop          "$(build_hook Stop)" \
    --argjson subagent      "$(build_hook SubagentStop)" \
    --argjson notif         "$(build_hook Notification)" \
    --argjson preTool       "$(build_hook PreToolUse)" \
    --argjson postTool      "$(build_hook PostToolUse)" \
    --argjson userPrompt    "$(build_hook UserPromptSubmit)" \
    '{
        Stop:            [$stop.hooks[0]],
        SubagentStop:    [$subagent.hooks[0]],
        Notification:    [$notif.hooks[0]],
        PreToolUse:      [$preTool.hooks[0]],
        PostToolUse:     [$postTool.hooks[0]],
        UserPromptSubmit: [$userPrompt.hooks[0]]
    }')

jq --argjson hooks "$NEW_HOOKS" '.hooks = ((.hooks // {}) * $hooks)' "$SETTINGS" > "$SETTINGS.tmp"
mv "$SETTINGS.tmp" "$SETTINGS"

echo "已注入 hooks 到 $SETTINGS"
echo "事件文件：$EVENTS_FILE"
