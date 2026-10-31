# Notchboard

A small, fast macOS notch app for people who work with AI agents. Hover the notch to open it.

- **Usage**: your Copilot premium requests (used, left, reset date) for every GitHub account `gh` is signed in to, including company `*.ghe.com` accounts; and your Claude plan limits (5-hour session and weekly, % used and % left, when each resets) and what your Claude Code usage would cost at API prices (today, 7 days, 30 days, last 14 days).
- **Agents**: every running Claude Code and Copilot CLI session, grouped by agent, and what it is doing right now ("Bash: npm test", "Edit: Main.swift"), which ones are waiting for you, and which have finished.
- **Approvals**: when Claude Code asks for permission, the notch opens with who is asking (agent, project, app, task) and Allow / Deny / Always allow (naming the rule, e.g. `git push`).
- **Bar**: your own row of things in the notch. Drag apps, files, folders and web links onto the notch to add them; add live widgets (clock, CPU, battery, timer) and your Shortcuts from the + tile. Drag tiles to reorder, right-click to remove, drop a file on an app to open it with that app.
- **Music**: what Spotify, Apple Music, or a browser (YouTube, YouTube Music, SoundCloud, ...) is playing, with artwork, progress and play/pause/skip.

Native Swift (AppKit + SwiftUI), no web view. Everything is event-driven, and looping animations run as Core Animation layers in the window server, so the app uses ~0% CPU and ~50 MB at rest.

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
| Copilot | For each host in `gh auth status` (github.com and `*.ghe.com`), `GET <api>/copilot_internal/user` with that host's `gh auth token`, the same call Copilot's own apps use. Plans without premium requests (Copilot Free) are hidden. The token is fetched from `gh` each time and never stored. Internal endpoint; it may change. |
| Spend | Token usage in `~/.claude/projects/**/*.jsonl`, priced with API list prices (`Sources/NotchboardCore/Pricing.swift`). Files are read incrementally, so a rescan takes milliseconds. This is the API-equivalent value, not what a subscription bills. |
| Agents & approvals | Claude Code [hooks](https://code.claude.com/docs/en/hooks). Connecting adds `~/Library/Application Support/Notchboard/agent-hook.sh` to `~/.claude/settings.json` (a one-time backup is saved as `settings.json.notchboard-backup`). The script sends each event to a Unix socket owned by the app, and always exits 0, so Claude Code is never blocked when Notchboard isn't running. |
| Copilot CLI agents | Menu bar → Connect Copilot CLI writes `~/.copilot/hooks/notchboard.json` (Copilot CLI loads every file there), running the same hook script for session, prompt, tool, notification and stop events. Status only: Copilot's permission hook runs before its own allow rules, so its approvals stay in its terminal. |
| Music | Distributed notifications from Spotify / Music, plus AppleScript for position, artwork and controls (macOS asks for Automation permission once). Apps are only scripted while already running. |
| Browser music | Core Audio reports which browser is making sound (no permission needed). Only then is that browser asked, over AppleScript, to run a small script in its media-site tabs that reads the page's Media Session metadata and `<video>`/`<audio>` state, and to play/pause/skip. Chrome, Arc, Brave, Edge, Vivaldi and Safari. For this, turn on **Allow JavaScript from Apple Events** (Chrome: View > Developer; Safari: Develop menu); without it the notch shows the tab title only, with no controls. |

### Approvals

`PermissionRequest` hooks run *before* Claude Code shows its own prompt. Notchboard holds the request for up to ~110 seconds. If you don't answer in that time, or you answer in the terminal, or interrupt Claude Code, the card closes and the terminal prompt takes over.

If another app (for example Notchy) also registers a `PermissionRequest` hook, both will ask you. Use one at a time.

## Development

- **Test first.** For any behaviour change, add a failing check to `Sources/NotchboardChecks` (run `swift run NotchboardChecks` and see it fail), then make it pass. Logic lives in `NotchboardCore` so it can be checked.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): short plain description`, for example `feat(usage): show Copilot premium requests` or `fix(bar): accept addresses dragged as text`.
- **UI changes** start from a mockup; after building, check the real thing with a screenshot (debug builds accept `_show`, `_music` and `_decide` socket messages, see below).

## Layout

- `Sources/NotchboardCore`: pure logic: pricing, transcript parsing, plan limits, agent state, approval replies.
- `Sources/Notchboard`: the app: notch window and hover, SwiftUI views, hook socket server, usage and music services.
- `Sources/NotchboardChecks`: assertion runner for the core. `NotchboardChecks --real` times a scan of your real transcripts.

Debug builds accept two extra socket messages for testing without a mouse: `{"event":"_show","raw":{"tab":"usage"}}` pins a tab open (`"none"` closes it) and `{"event":"_decide","raw":{"decision":"allow"}}` answers the first approval.

## License

MIT
