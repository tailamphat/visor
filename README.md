# Notchboard

A small, fast macOS notch app for people who work with AI agents. Hover the notch to open it.

- **Usage**: your Claude plan limits (5-hour session and weekly, % used and % left, when each resets) and what your Claude Code usage would cost at API prices (today, 7 days, 30 days, last 14 days).
- **Agents**: every running Claude Code session and what it is doing right now ("Bash: npm test", "Edit: Main.swift"), which ones are waiting for you, and which have finished.
- **Approvals**: when Claude Code asks for permission, the notch opens with Allow / Deny / Always allow, or hands the question back to the terminal.
- **Music**: what Spotify or Apple Music is playing, with artwork, progress and play/pause/skip.

Native Swift (AppKit + SwiftUI), no web view. Everything is event-driven: nothing polls while you're idle.

## Build

Needs macOS 14+ and the Command Line Tools (Xcode not required).

```sh
./scripts/bundle.sh --open     # builds build/Notchboard.app and launches it
swift run NotchboardChecks     # logic checks (XCTest isn't available with CLT)
```

Then choose **Connect Claude Code** in the notch (or the menu bar icon).

## How it works

| Feature | Source |
|---|---|
| Plan limits | `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token Claude Code keeps in your login keychain (`Claude Code-credentials`). Read with `/usr/bin/security`; never written or refreshed by Notchboard. Refreshed every 2 minutes, and when you open the Usage tab if older than 45s. This endpoint is not a documented public API and may change. |
| Spend | Token usage in `~/.claude/projects/**/*.jsonl`, priced with API list prices (`Sources/NotchboardCore/Pricing.swift`). Files are read incrementally, so a rescan takes milliseconds. This is the API-equivalent value, not what a subscription bills. |
| Agents & approvals | Claude Code [hooks](https://code.claude.com/docs/en/hooks). Connecting adds `~/Library/Application Support/Notchboard/agent-hook.sh` to `~/.claude/settings.json` (a one-time backup is saved as `settings.json.notchboard-backup`). The script sends each event to a Unix socket owned by the app, and always exits 0, so Claude Code is never blocked when Notchboard isn't running. |
| Music | Distributed notifications from Spotify / Music, plus AppleScript for position, artwork and controls (macOS asks for Automation permission once). Apps are only scripted while already running. |

### Approvals

`PermissionRequest` hooks run *before* Claude Code shows its own prompt. Notchboard holds the request for up to ~110 seconds. If you don't answer in that time, choose **Ask in terminal**, or interrupt Claude Code, the request goes back to the normal terminal prompt.

If another app (for example Notchy) also registers a `PermissionRequest` hook, both will ask you. Use one at a time.

## Layout

- `Sources/NotchboardCore`: pure logic: pricing, transcript parsing, plan limits, agent state, approval replies.
- `Sources/Notchboard`: the app: notch window and hover, SwiftUI views, hook socket server, usage and music services.
- `Sources/NotchboardChecks`: assertion runner for the core. `NotchboardChecks --real` times a scan of your real transcripts.

Debug builds accept two extra socket messages for testing without a mouse: `{"event":"_show","raw":{"tab":"usage"}}` pins a tab open (`"none"` closes it) and `{"event":"_decide","raw":{"decision":"allow"}}` answers the first approval.

## License

MIT
