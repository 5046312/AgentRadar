# AgentRadar

[English](README.md) | 简体中文

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="96" alt="AgentRadar app icon">
</p>

AgentRadar 是一个原生 macOS 菜单栏工具，用来监控 Claude Code 和 Codex 的项目级任务状态。它读取本机会话数据，记录 hooks 事件，并在任务等待确认、完成或失败时提醒检查。

## 亮点

- 紧凑弹窗，只展示项目级状态。
- 状态栏固定使用 3x3 九宫格图标，运行中项目数量显示在图标右侧。
- 运行中每个 tick 多点亮一格，带轻微绿色层次变化；亮点速度会随运行中项目数量加快。
- 运行中的项目显示从任务开始累计的运行时长。
- 任务完成、失败、等待确认支持状态栏气泡或系统消息提醒。
- 状态栏气泡会根据内容自适应宽度；完成提醒会显示耗时。
- 内置 hooks 安装器，写入前先展示 diff 预览。
- 原生 Swift/AppKit/SwiftUI，无 `jq` 或第三方运行依赖。

## 状态检测

- Claude 读取 `~/.claude/projects/**/*.jsonl`；hooks 用来提高运行、等待、完成状态的准确性。
- Codex 任务状态只依赖 hooks；JSONL/transcript 只用于补充项目、会话信息和最终回合结果。
- hooks 事件统一追加到 `~/.agentradar/events.jsonl`，应用会监听文件变化，并每秒兜底读取一次新增事件。
- 缺少 `transcript_path` 的 Codex 事件、根目录 `/` 任务、内部 memory 路径会被忽略，避免内部后台任务显示成用户项目。

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

## 安装 Hooks

打开 AgentRadar，点击齿轮按钮，然后选择“安装 Hooks”。应用会先展示 diff 预览，确认后直接写入，不生成备份文件。

也可以继续使用命令行包装脚本：

```bash
./install-hooks.sh
```

安装逻辑由 AgentRadar 原生实现，不依赖 `jq`。它会更新 `~/.claude/settings.json`、`~/.codex/config.toml`、`~/.codex/hooks.json`。

AgentRadar 安装的 Claude hooks：

- `Stop`
- `SubagentStop`
- `Notification`
- `PreToolUse`
- `PostToolUse`
- `UserPromptSubmit`

AgentRadar 安装的 Codex hooks：

- `UserPromptSubmit`
- `PermissionRequest`
- `PreToolUse`
- `PostToolUse`
- `Stop`

安装后需要重启当前 Claude/Codex 会话。Codex 首次重启时可能要求 review 并信任 hook。

## 设置

- 提醒方式：状态栏气泡或系统消息。
- 音效：可开关任务完成音效。
- 九宫格速度：默认基础速度 1 秒/格，可在 0.25 到 2 秒/格之间调整。
- 亮点切换速度会乘以运行中项目数。
- 间隔左右浮动默认 ±50%，输入时只填 0 到 100 的数字。

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

hooks 安装不会自动生成备份，如需回退请自行恢复对应配置文件。

## 许可

MIT。详见 [LICENSE](LICENSE)。
