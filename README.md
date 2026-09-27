<p align="center">
  <img src="docs/icon.png" width="128" alt="Headroom icon">
</p>

<h1 align="center">Headroom</h1>

<p align="center">
  <b>Know how much room you have left.</b><br>
  Your Claude Code and Codex plan limits, live in the macOS menu bar.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-single%20file-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/RAM-~12%20MB-2ea44f" alt="~12 MB RAM">
  <img src="https://img.shields.io/badge/network%20calls-none-2ea44f" alt="No network calls">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

<p align="center">
  <img src="docs/menubar.png" height="24" alt="Menu bar">
</p>

<p align="center">
  <img src="docs/popover-light.png" width="300" alt="Popover, light">
  &nbsp;
  <img src="docs/popover-dark.png" width="300" alt="Popover, dark">
  &nbsp;
  <img src="docs/settings-dark.png" width="300" alt="Settings">
</p>

## Features

- **Every limit your plan has.** Claude Code: 5-hour session, weekly (all models) and per-model weekly buckets such as Fable. Codex: 5-hour session and weekly.
- **Glanceable menu bar.** App icon plus the limit closest to running out, turning orange at 75% and red at 90%.
- **Pace marker.** The tick on each bar shows where you'd be if you spread usage evenly across the window. Ahead of the tick means you're burning fast.
- **Reset countdowns.** "Resets in 4h 12m · 00:39" for every window.
- **Settings.** Open at login, show or hide each service, choose which limit the bar shows, % used or % left, refresh interval, and English or Italian.
- **Tiny.** One Swift file with no dependencies: ~290 KB binary, ~12 MB RAM, 0% CPU at idle.

## Install

You need macOS 13+ and the Swift toolchain (`xcode-select --install`).

```sh
git clone https://github.com/INAYA-GIA/headroom.git
cd headroom
./install.sh
```

This builds `~/Applications/Headroom.app` and registers it to start at login. To remove it: `./uninstall.sh`.

## How it gets the data, and why it's safe

Headroom **makes no network requests, never reads tokens or passwords, and never spends your quota.**

| | Source | How often |
|---|---|---|
| **Claude Code** | Runs the official CLI: `claude -p /usage`. It's exactly what typing `/usage` does: 0 tokens, $0, with hooks disabled, no session saved, and sandboxed away from your personal folders. | Every 5 min (configurable) and when you open the popover |
| **Codex** | Reads the `rate_limits` the Codex CLI already writes to `~/.codex/sessions/`. It only reads the tail of the newest log, in small chunks. | Every 30 s, local disk only |

Because it only uses the vendors' own clients and files they already write on your Mac, nothing looks different to Anthropic or OpenAI than you using their tools normally. The Claude plan badge (Pro / Max) is read from `~/.claude.json`. See [SECURITY.md](SECURITY.md) for the full picture.

## Requirements

- **Claude Code**: `claude` installed and signed in with a subscription. Headroom looks in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
- **Codex**: the Codex CLI or app, used at least once.
- The menu bar shows the Claude and ChatGPT app icons if those apps are in `/Applications`, otherwise a coloured ring.

## Limitations

- Codex numbers are as fresh as your last Codex response, because Codex only logs them when you use it.
- ChatGPT chat message limits aren't stored locally, so they aren't shown. Getting them would mean scraping the website with your session, which is exactly what Headroom avoids.
- The popover's wording follows the Claude CLI's `/usage` output. If a future CLI changes that format, the Claude card may go empty until Headroom is updated.

## Development

```sh
swiftc -Osize Sources/main.swift -o /tmp/headroom
/tmp/headroom --snapshot out.png dark en     # render the popover (add: settings, it)
/tmp/headroom --icon icon.png 1024           # render the app icon
```

Adding a language means adding a string table next to `italian` in `Sources/main.swift`.

## Disclaimer

Headroom is an independent project, not affiliated with or endorsed by Anthropic or OpenAI. Claude and Claude Code are trademarks of Anthropic, PBC; ChatGPT and Codex are trademarks of OpenAI.

## License

[MIT](LICENSE)
