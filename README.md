# AgentRadar

English | [简体中文](README.zh-CN.md)

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="96" alt="AgentRadar app icon">
</p>

AgentRadar is a native macOS menu bar app for monitoring Claude Code and Codex project status. It reads local session data, records hook events, and reminds you when a task waits for confirmation, finishes, or fails.

## Highlights

- Compact popover with project-level status only.
- 3x3 menu bar indicator with the active-project count shown on the right.
- Running animation lights one more grid cell per tick, uses subtle green tone variation, and speeds up by the current number of running projects.
- Running projects show elapsed time from task start.
- Completion, failure, and confirmation-waiting reminders via status bar bubble or system notification.
- Status bar bubbles auto-size to content. Completion reminders include duration.
- In-app hook installer with diff preview before writing.
- User-started OpenAI-compatible endpoint probes with Keychain-backed API keys.
- Native Swift/AppKit/SwiftUI app. No `jq` or third-party runtime dependency.

## Status Detection

- Claude reads `~/.claude/projects/**/*.jsonl`; hooks improve running, waiting, and completion transitions.
- Codex task status is hook-only. JSONL/transcript data only fills project/session details and final turn outcome.
- Hook records are appended to `~/.agentradar/events.jsonl`. AgentRadar watches file changes and also drains once per second as a fallback.
- Codex events without `transcript_path`, root `/` tasks, and internal memory paths are ignored so internal background work does not appear as user projects.

## Requirements

- macOS 14 or later.
- Swift 5.9 or later.
- Claude Code / Codex.

## Build

```bash
./build.sh
```

`build.sh` runs a SwiftPM release build and assembles `AgentRadar.app`.

To package, install, and run the latest build:

```bash
./package-and-run.sh
```

This command builds `AgentRadar.app`, creates `AgentRadar.dmg`, installs the latest bundle at `/Applications/AgentRadar.app`, stops any old instance, and launches only the installed app. The previous installation is restored if replacement or binary verification fails. Administrator authorization is requested only when `/Applications` is not directly writable.

## Install Hooks

Open AgentRadar, click the gear button, then choose **Install Hooks**. The app shows a diff preview first; after confirmation it writes directly without backup files.

You can also use the CLI wrapper:

```bash
./install-hooks.sh
```

The wrapper uses the stable executable inside `/Applications/AgentRadar.app`. Run `./package-and-run.sh` first.

The installer is implemented natively and does not require `jq`. It updates `~/.claude/settings.json`, `~/.codex/config.toml`, and `~/.codex/hooks.json`.

Claude hooks installed by AgentRadar:

- `Stop`
- `SubagentStop`
- `Notification`
- `PreToolUse`
- `PostToolUse`
- `UserPromptSubmit`

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
- Nine-grid speed: base speed defaults to 1 second per cell and can be adjusted from 0.25 to 2 seconds per cell.
- Tick speed is multiplied by the number of running projects.
- Interval variation defaults to +/-50%; enter a number from 0 to 100 only.
- Saved endpoint probes do not start automatically. Each run stops after success or 10 failed attempts, with exponential backoff.

## Package DMG

```bash
./make-dmg.sh
```

`AgentRadar.dmg` is a local build artifact and should not be committed.

## Privacy

AgentRadar reads local Claude Code / Codex session files and local hook events. Hook records contain only fields required for status detection and are stored locally with restricted permissions.

Endpoint probes make network requests only after you add a probe and start it. Requests go to the configured OpenAI-compatible Base URL and include the selected model, a short `hi` prompt, and the API Key in the Authorization header. API Keys are stored in macOS Keychain; probe metadata is stored in UserDefaults.

## Development

```bash
swift build
swift run AgentRadar
swift test
```

This project uses SwiftPM. Source code lives in `Sources/AgentRadar`.

## Uninstall

```bash
rm -rf AgentRadar.app .build AgentRadar.dmg
sudo rm -rf /Applications/AgentRadar.app
rm -rf ~/.agentradar
```

Hook install does not create automatic backups. Restore config files manually if you need to roll back.

## License

MIT. See [LICENSE](LICENSE).
