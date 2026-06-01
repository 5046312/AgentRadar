# AgentRadar

English | [简体中文](README.zh-CN.md)

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="96" alt="AgentRadar app icon">
</p>

AgentRadar is a native macOS menu bar monitor for Claude Code and Codex project status.

## Features

- Fixed 3x3 menu bar indicator with active-task badge.
- Running animation lights cells cumulatively, then clears and restarts.
- Each newly lit cell is colored by TPS trend for that interval: green for faster, yellow for slight/no drop, red for large drop.
- Popover shows runtime tabs, all-project average TPS, project-level TPS, and project-level status.
- Completion and failure reminders via status bar bubble or system notification.
- In-app hook installer with diff preview before writing.
- Native Swift/AppKit/SwiftUI app with no third-party runtime dependencies.

## Status Source

- Claude reads `~/.claude/projects/**/*.jsonl` and uses hooks for more reliable waiting/completion states.
- Codex status depends on hooks only. JSONL files only fill project and token details.
- Hook events are appended to `~/.agentradar/events.jsonl`.
- Internal Codex memory paths and root-level internal tasks are ignored so they do not appear as user projects.

## Requirements

- macOS 14 or later.
- Swift 5.9 or later.
- Claude Code / Codex.

## Build

```bash
./build.sh
open ./AgentRadar.app
```

`build.sh` runs a SwiftPM release build and assembles `AgentRadar.app`.

## Install Hooks

Open AgentRadar, click the gear button, then choose **Install Hooks**. The app shows a diff preview first; after confirmation it writes directly without backup files.

You can also use the CLI wrapper:

```bash
./install-hooks.sh
```

The installer is implemented natively and does not require `jq`. It updates `~/.claude/settings.json`, `~/.codex/config.toml`, and `~/.codex/hooks.json`.

Codex hooks installed by AgentRadar:

- `UserPromptSubmit`
- `PermissionRequest`
- `PreToolUse`
- `PostToolUse`
- `Stop`

Restart current Claude/Codex sessions after installing hooks. Codex may ask you to review and trust the hook on first restart.

## Settings

- Reminder style: status bar bubble or system notification.
- Sound: toggle completion sound.
- Nine-grid speed: adjustable between `0.18` and `0.54` seconds per cell.

## Package DMG

```bash
./make-dmg.sh
```

`AgentRadar.dmg` is a local build artifact and should not be committed.

## Privacy

AgentRadar only reads local Claude Code / Codex session files and local hook events. It does not upload data and contains no network requests.

## Development

```bash
swift build
swift run AgentRadar
```

This project uses SwiftPM. Source code lives in `Sources/AgentRadar`.

## Uninstall

```bash
rm -rf AgentRadar.app .build AgentRadar.dmg
rm -rf ~/.agentradar
```

Hook install does not create automatic backups. Restore config files manually if you need to roll back.

## License

MIT. See [LICENSE](LICENSE).
