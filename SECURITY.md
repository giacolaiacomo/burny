# Security & privacy

Headroom is designed so that installing it cannot put your accounts at risk.

**What it does**
- Runs `claude -p /usage --output-format json --no-session-persistence --setting-sources user --settings '{"disableAllHooks":true}'` from `~/Library/Caches/Headroom`. It's the official Claude Code CLI doing its own read-only `/usage` request, with 0 tokens and $0 cost. Your hooks are disabled for that call and no session is saved.
- Reads the newest `~/.codex/sessions/**/rollout-*.jsonl` files backwards, parsing only the `rate_limits` object of the most recent `token_count` event.
- Reads `~/.claude.json` only to show your plan tier (Pro / Max).
- Stores its settings in `~/Library/Preferences/com.headroom.menubar.plist`.

**What it never does**
- Make network requests of its own.
- Read, copy or forward OAuth tokens, API keys, cookies or Keychain items.
- Call private or undocumented endpoints.
- Send telemetry, or write anything outside its own preferences and cache folder.

The whole app is one ~750-line file, [`Sources/main.swift`](Sources/main.swift), so you can read all of it before you build it. You always build it from source yourself; no prebuilt binaries are distributed.

To report a problem, please open an issue.
