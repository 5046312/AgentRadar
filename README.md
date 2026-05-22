# AgentRadar

macOS 状态栏工具，监控多个 Claude Code 任务的运行状态。

## 功能

- 状态栏红绿灯：绿色脉冲（运行）/ 黄色闪烁（等待输入）/ 红色（出错）
- 任务完成时绿灯闪 3 次
- 角标数字：当前活跃任务数
- 悬浮 Popover：每个会话的项目名、git 分支、当前工具、token 使用量、相对时间
- 双数据源：FSEvents 监听 `~/.claude/projects/**/*.jsonl` + 可选 hook 事件 `~/.agentradar/events.jsonl`

## 构建

```bash
./build.sh
open ./AgentRadar.app
```

要求：macOS 14+，Swift 5.9+（自带的 Command Line Tools 即可）。

## 安装 hooks（可选）

让状态切换更可靠：

```bash
brew install jq        # 仅在缺少 jq 时
./install-hooks.sh
```

会修改 `~/.claude/settings.json` 注入 Stop / Notification / PreToolUse / PostToolUse / UserPromptSubmit / SubagentStop 钩子，每次事件追加一行 JSON 到 `~/.agentradar/events.jsonl`，原文件备份保存为 `settings.json.bak.<时间戳>`。

## 状态聚合优先级

red > yellow > green pulse > green flash > 灰

## 卸载

```bash
rm -rf AgentRadar.app .build
# 还原 settings.json
mv ~/.claude/settings.json.bak.* ~/.claude/settings.json
```

详见 [PLAN.md](PLAN.md)。
