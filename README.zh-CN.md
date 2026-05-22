# AgentRadar

[English](README.md) | 简体中文

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="96" alt="AgentRadar app icon">
</p>

AgentRadar 是一个 macOS 菜单栏工具，用红绿灯状态监控多个 Claude Code 会话。

## 功能

- 状态栏红绿灯：运行、等待、完成、错误、空闲。
- 活跃任务数字角标。
- Popover 展示项目名、git 分支、当前工具、token 使用量、最近活动时间。
- 读取 `~/.claude/projects/**/*.jsonl`。
- 可选 hooks 事件源：`~/.agentradar/events.jsonl`。
- 原生 Swift/AppKit/SwiftUI，无第三方运行依赖。

## 系统要求

- macOS 14 或更新版本。
- Swift 5.9 或更新版本。
- Claude Code。
- 可选：`jq`，仅 `install-hooks.sh` 需要。

## 构建

```bash
./build.sh
open ./AgentRadar.app
```

`build.sh` 会执行 SwiftPM release 构建，并生成 `AgentRadar.app`。

## 安装 hooks（可选）

hooks 让等待、完成等状态更可靠：

```bash
brew install jq
./install-hooks.sh
```

脚本会备份 `~/.claude/settings.json`，再注入 `Stop`、`Notification`、`PreToolUse`、`PostToolUse`、`UserPromptSubmit`、`SubagentStop` hooks。事件追加到 `~/.agentradar/events.jsonl`。

## 打包 DMG

```bash
./make-dmg.sh
```

生成的 `AgentRadar.dmg` 是本地产物，不提交到仓库。

## 隐私

AgentRadar 只读取本机 Claude Code 会话文件和可选 hook 事件文件。它不会上传数据，也不包含网络请求。

## 开发

```bash
swift build
swift run AgentRadar
```

项目使用 SwiftPM，源码在 `Sources/AgentRadar`。

## 卸载

```bash
rm -rf AgentRadar.app .build AgentRadar.dmg
rm -rf ~/.agentradar
```

如需还原 hooks 配置，使用 `install-hooks.sh` 生成的 `settings.json.bak.<timestamp>` 备份覆盖 `~/.claude/settings.json`。

## 许可

MIT。详见 [LICENSE](LICENSE)。
