# Changelog

## 1.0.0 — 2026-09-27

First public release.

- Menu bar item with the limit closest to running out for Claude Code and Codex, coloured at 75% and 90%.
- Popover with every limit: Claude Code session, weekly and per-model buckets (e.g. Fable); Codex session and weekly. Each has a reset countdown and a pace marker.
- Settings: open at login, English/Italian, per-service visibility, limit shown, % used or left, refresh interval.
- Security: Claude data comes from the official CLI's local `/usage` command. The binary's signature is verified first, and the call runs with no tools, no MCP, no hooks, a budget cap, a sandbox and an output check. Codex data comes from its local logs. No network calls of Burny's own.
- About 13 MB of RAM, a single Swift file.
