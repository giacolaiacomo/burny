# Changelog

## 1.1.0 — 2026-09-27

- **Burn forecast:** "Runs out ~18:40 at this pace" when your pace would hit a limit before it resets. It uses your recent readings, falling back to the average since the window opened.
- **Alerts** at 80% and 90% (optional, off by default), once per limit and window.
- **Update check** for new Burny releases (optional, off by default): one request a day to GitHub's public API, nothing installed automatically.
- Old Codex data is now greyed out, with a hint that it refreshes when you use Codex.
- Fix: reset times without minutes ("2pm") were shown with the current clock's minutes (e.g. 14:13 instead of 14:00).
- `--self-test` checks the `/usage` and Codex parsers and the forecast; CI runs it on every push.
- Lighter README images.

## 1.0.0 — 2026-09-27

First public release.

- Menu bar item with the limit closest to running out for Claude Code and Codex, coloured at 75% and 90%.
- Popover with every limit: Claude Code session, weekly and per-model buckets (e.g. Fable); Codex session and weekly. Each has a reset countdown and a pace marker.
- Settings: open at login, English/Italian, per-service visibility, limit shown, % used or left, refresh interval.
- Security: Claude data comes from the official CLI's local `/usage` command. The binary's signature is verified first, and the call runs with no tools, no MCP, no hooks, a budget cap, a sandbox and an output check. Codex data comes from its local logs. No network calls of Burny's own.
- About 13 MB of RAM, a single Swift file.
