# Security Policy

## Reporting

Please open a private security advisory on GitHub if available. If not, open an issue with a minimal description and avoid posting sensitive local data.

## Data handling

AgentRadar reads local Claude Code / Codex session files and local hook events. Hook records are minimized to status-related fields, stored locally with restricted permissions, and size-limited.

Endpoint probes send requests only to a Base URL explicitly configured by the user. Probe API keys are stored in macOS Keychain. Other probe metadata is stored in UserDefaults.
