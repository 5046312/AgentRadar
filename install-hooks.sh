#!/usr/bin/env bash
set -euo pipefail

EVENTS_DIR="$HOME/.agentradar"
EVENTS_FILE="$EVENTS_DIR/events.jsonl"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CODEX_HOOKS="$CODEX_DIR/hooks.json"

mkdir -p "$EVENTS_DIR"
touch "$EVENTS_FILE"

if ! command -v jq >/dev/null 2>&1; then
    echo "需要 jq：brew install jq" >&2
    exit 1
fi

mkdir -p "$(dirname "$CLAUDE_SETTINGS")" "$CODEX_DIR"

if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    echo '{}' > "$CLAUDE_SETTINGS"
fi

if [[ ! -f "$CODEX_HOOKS" ]]; then
    echo '{}' > "$CODEX_HOOKS"
fi

cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%s)"
if [[ -f "$CODEX_CONFIG" ]]; then
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak.$(date +%s)"
fi
cp "$CODEX_HOOKS" "$CODEX_HOOKS.bak.$(date +%s)"

LOG_CMD='jq -c --arg runtime "RUNTIME_NAME" --arg event "EVENT_NAME" --arg ts "$(date +%s.%N)" '"'"'. + {runtime: $runtime, event: $event, ts: ($ts | tonumber), agentradar_ts: $ts}'"'"' >> "$HOME/.agentradar/events.jsonl"'

build_hook() {
    local runtime=$1
    local event=$2
    local cmd="${LOG_CMD/RUNTIME_NAME/$runtime}"
    cmd="${cmd/EVENT_NAME/$event}"
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

enable_codex_hooks_feature() {
    if [[ ! -f "$CODEX_CONFIG" ]]; then
        printf '[features]\nhooks = true\n' > "$CODEX_CONFIG"
        return
    fi

    awk '
        BEGIN { in_features = 0; has_features = 0; done = 0 }
        /^[[:space:]]*\[features\][[:space:]]*$/ {
            in_features = 1
            has_features = 1
            print
            next
        }
        /^[[:space:]]*\[/ && in_features && !done {
            print "hooks = true"
            done = 1
            in_features = 0
        }
        in_features && /^[[:space:]]*hooks[[:space:]]*=/ {
            print "hooks = true"
            done = 1
            next
        }
        { print }
        END {
            if (!done) {
                if (has_features) {
                    print "hooks = true"
                } else {
                    if (NR > 0) print ""
                    print "[features]"
                    print "hooks = true"
                }
            }
        }
    ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp"
    mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
}

CLAUDE_HOOKS=$(jq -n \
    --argjson stop          "$(build_hook claude Stop)" \
    --argjson subagent      "$(build_hook claude SubagentStop)" \
    --argjson notif         "$(build_hook claude Notification)" \
    --argjson preTool       "$(build_hook claude PreToolUse)" \
    --argjson postTool      "$(build_hook claude PostToolUse)" \
    --argjson userPrompt    "$(build_hook claude UserPromptSubmit)" \
    '{
        Stop:            [$stop.hooks[0]],
        SubagentStop:    [$subagent.hooks[0]],
        Notification:    [$notif.hooks[0]],
        PreToolUse:      [$preTool.hooks[0]],
        PostToolUse:     [$postTool.hooks[0]],
        UserPromptSubmit: [$userPrompt.hooks[0]]
    }')

CODEX_EVENT_HOOKS=$(jq -n \
    --argjson sessionStart  "$(build_hook codex SessionStart)" \
    --argjson stop          "$(build_hook codex Stop)" \
    --argjson permission    "$(build_hook codex PermissionRequest)" \
    --argjson preTool       "$(build_hook codex PreToolUse)" \
    --argjson postTool      "$(build_hook codex PostToolUse)" \
    '{
        SessionStart:      [$sessionStart.hooks[0]],
        Stop:              [$stop.hooks[0]],
        PermissionRequest: [$permission.hooks[0]],
        PreToolUse:        [$preTool.hooks[0]],
        PostToolUse:       [$postTool.hooks[0]]
    }')

jq --argjson hooks "$CLAUDE_HOOKS" '.hooks = ((.hooks // {}) * $hooks)' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp"
mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"

enable_codex_hooks_feature
jq --argjson hooks "$CODEX_EVENT_HOOKS" '.hooks = ((.hooks // {}) * $hooks)' "$CODEX_HOOKS" > "$CODEX_HOOKS.tmp"
mv "$CODEX_HOOKS.tmp" "$CODEX_HOOKS"

echo "已注入 Claude hooks 到 $CLAUDE_SETTINGS"
echo "已启用 Codex hooks：$CODEX_CONFIG"
echo "已注入 Codex hooks 到 $CODEX_HOOKS"
echo "事件文件：$EVENTS_FILE"
