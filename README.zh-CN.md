# AgentRadar

[English](README.md) | 简体中文

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="96" alt="AgentRadar app icon">
</p>

AgentRadar 是一个 macOS 菜单栏工具，用红绿灯状态监控多个 Claude Code 和 Codex 会话。

## 功能

- 状态栏红绿灯：运行、等待、完成、错误、空闲。
- 活跃任务数字角标。
- Popover 展示项目名、git 分支、当前工具、token 使用量、最近活动时间。
- 读取 `~/.claude/projects/**/*.jsonl` 和 `~/.codex/sessions/**/*.jsonl`。
- hooks 事件源：`~/.agentradar/events.jsonl`。
- 原生 Swift/AppKit/SwiftUI，无第三方运行依赖。

## 系统要求

- macOS 14 或更新版本。
- Swift 5.9 或更新版本。
- Claude Code / Codex。

## 构建

```bash
./build.sh
open ./AgentRadar.app
```

`build.sh` 会执行 SwiftPM release 构建，并生成 `AgentRadar.app`。

## 安装 hooks

Codex 状态依赖 hooks；Claude 的等待、完成等状态也通过 hooks 更可靠：

先打开 AgentRadar，点弹窗顶部齿轮按钮里的“安装 Hooks”。应用内会先展示 diff 预览，确认后再写入；也可以继续用命令行：

```bash
./install-hooks.sh
```

安装逻辑由 AgentRadar 原生执行，不依赖 `jq`。它会直接更新 `~/.claude/settings.json`、`~/.codex/config.toml`、`~/.codex/hooks.json`，不再生成备份。Codex hooks 会注入 `SessionStart`、`PermissionRequest`、`PreToolUse`、`PostToolUse`、`Stop`；事件追加到 `~/.agentradar/events.jsonl`。

## 打包 DMG

```bash
./make-dmg.sh
```

生成的 `AgentRadar.dmg` 是本地产物，不提交到仓库。

## 隐私

AgentRadar 只读取本机 Claude Code / Codex 会话文件和本机 hook 事件文件。它不会上传数据，也不包含网络请求。

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

当前 hooks 安装不会自动生成备份，如需回退请自行恢复对应配置文件。

## 许可

MIT。详见 [LICENSE](LICENSE)。
