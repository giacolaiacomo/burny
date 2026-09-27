# Security & privacy

Burny is designed so that installing it can't put your accounts or your machine at risk.

## Claude Code: a locked-down `/usage` call

To read your Claude limits, Burny runs the official CLI's own `/usage` command, the same thing you get by typing `/usage`. `/usage` is a local slash command: **the model is never called**, so there's no prompt for anyone to inject into. Even so, the call has several layers of protection, and any one of them would be enough on its own:

| Layer | What it does |
|---|---|
| Constant input | The only input is the literal string `/usage`. No file, web page or other text is ever passed to the CLI. |
| Genuine binary | Before each run, Burny checks the code signature of `claude`: it must chain to Apple and belong to Anthropic's team (`Q6L2SF6YDW`). A replaced or tampered binary is never executed. |
| No capabilities | `--tools ""` (no tools at all), `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` (no MCP servers), `--setting-sources ""` plus `disableAllHooks` (no settings, hooks or CLAUDE.md), `--no-session-persistence`. |
| Spending cap | `--max-budget-usd 0.0001`, so even a hypothetical model call couldn't spend anything meaningful. |
| Sandbox | The CLI runs under `sandbox-exec` and can't read or write Desktop, Documents, Downloads, Pictures, Movies, Music or iCloud Drive. |
| Minimal environment | Only `HOME`, `USER`, `LANG`, `TMPDIR` and a system-only `PATH`. |
| Output check | The JSON must report 0 turns, $0 and 0 ms of API time. If the CLI ever behaves differently, Burny stops calling it until you restart it. |
| Parse, never execute | Only percentages and reset times are extracted, with a strict regular expression. Nothing from the output is ever executed or opened. |

## Codex

Burny reads the newest `~/.codex/sessions/**/rollout-*.jsonl` files backwards and parses only the `rate_limits` object of the most recent `token_count` event. It reads them only; nothing is written or sent anywhere.

## What Burny never does

- Make network requests of its own.
- Read, copy or forward OAuth tokens, API keys, cookies or Keychain items.
- Call private or undocumented endpoints.
- Send telemetry, or write anything outside `~/Library/Preferences/com.burny.menubar.plist` and `~/Library/Caches/Burny`.

The whole app is one ~800-line file, [`Sources/main.swift`](Sources/main.swift), so you can read all of it before you build it. You always build it from source yourself; no prebuilt binaries are distributed.

To report a problem, please open an issue.
