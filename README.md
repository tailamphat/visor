# Visor

A small, fast macOS notch app for people who work with AI agents. Hover the notch to open it.

- **Usage**: your Copilot premium requests (used, left, reset date) for every GitHub account `gh` is signed in to, including company `*.ghe.com` accounts; and your Claude plan limits (5-hour session and weekly, % used and % left, when each resets) and what your Claude Code usage would cost at API prices (today, 7 days, 30 days, last 14 days).
- **Agents**: every running Claude Code and Copilot CLI session, grouped by agent, and what it is doing right now ("Bash: npm test", "Edit: Main.swift"), which ones are waiting for you, and which have finished.
- **Approvals**: when Claude Code asks for permission, the notch opens with who is asking (agent, project, app, task) and Allow / Deny / Always allow (naming the rule, e.g. `git push`).
- **Questions**: when Claude Code asks you a multiple-choice question, the notch shows it with its options; pick one (or several, page by page) and send, or hand it to the terminal. The closed notch tells an approval (amber "!") from a question (blue "?"), and shows which project finished and how long it took.
- **Bar**: your own row of things in the notch. Drag apps, files, folders and web links onto the notch to add them; add live widgets (clock, CPU, battery, timer) and your Shortcuts from the + tile. Drag tiles to reorder, right-click to remove, drop a file on an app to open it with that app.
- **Clipboard**: everything you copy, newest first, one line each (a swatch for colours). ⌘⇧V opens it from anywhere: type to search, ↑/↓ and Return to paste into the app you were in (⌥Return as plain text), ⌘P to pin, ⌫ to delete. Deleting the item that's on the clipboard clears it from the macOS clipboard too, with Undo. Copies password managers mark as secret are never kept; history stays on this Mac (200 items or 30 days, pins always).
- **Music**: what Spotify, Apple Music, or a browser (YouTube, YouTube Music, SoundCloud, ...) is playing, with artwork, progress and play/pause/skip.

Native Swift (AppKit + SwiftUI), no web view. Everything is event-driven, and looping animations run as Core Animation layers in the window server, so the app uses ~0% CPU and ~50 MB at rest.

## Build

Visor was called Notchboard; on first launch it moves Notchboard's files and re-points its Claude Code and Copilot CLI hooks.


Needs macOS 14+ and the Command Line Tools (Xcode not required).

```sh
./scripts/bundle.sh --open     # builds build/Visor.app and launches it
scripts/test.sh                # unit tests (Swift Testing)
swift scripts/make-icon.swift  # redraws the app and menu bar icons
```

Then choose **Connect Claude Code** in the notch (or the menu bar icon).

## How it works

| Feature | Source |
|---|---|
| Plan limits | `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token Claude Code keeps in your login keychain (`Claude Code-credentials`). Read with `/usr/bin/security`; never written or refreshed by Visor. Refreshed every 2 minutes, and when you open the Usage tab if older than 45s. This endpoint is not a documented public API and may change. |
| Copilot | For each host in `gh auth status` (github.com and `*.ghe.com`), `GET <api>/copilot_internal/user` with that host's `gh auth token`, the same call Copilot's own apps use. Plans without premium requests (Copilot Free) are hidden. The token is fetched from `gh` each time and never stored. Internal endpoint; it may change. |
| Spend | Token usage in `~/.claude/projects/**/*.jsonl`, priced with API list prices (`Sources/VisorCore/Pricing.swift`). Files are read incrementally, so a rescan takes milliseconds. This is the API-equivalent value, not what a subscription bills. |
| Agents & approvals | Claude Code [hooks](https://code.claude.com/docs/en/hooks). Connecting adds `~/Library/Application Support/Visor/agent-hook.sh` to `~/.claude/settings.json` (a one-time backup is saved as `settings.json.visor-backup`). The script sends each event to a Unix socket owned by the app, and always exits 0, so Claude Code is never blocked when Visor isn't running. |
| Copilot CLI agents | Menu bar → Connect Copilot CLI writes `~/.copilot/hooks/visor.json` (Copilot CLI loads every file there), running the same hook script for session, prompt, tool, notification, stop and approval events. Approvals use the same card as Claude Code, for commands, file changes and web fetches only. Copilot's hooks can't save rules, so **Always** is kept by Visor per project (`copilot-rules.json`) and later matching requests are allowed without a card. Copilot asks the hook even for things it would allow itself (`--allow-all-tools`); turn **Copilot Approvals in the Notch** off in the menu to keep them in the terminal. |
| Clipboard | macOS doesn't announce clipboard changes, so the clipboard's change counter is read once a second and on every app switch. History is saved to `~/Library/Application Support/Visor/clipboard.json` (images in `Clips/`). Copies with `org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType` are skipped, as are apps listed in the `clipboardExcludedApps` default. Pasting presses ⌘V with the Accessibility permission. ⌘⇧V is a Carbon hot key (no permission). |
| Music | Distributed notifications from Spotify / Music, plus AppleScript for position, artwork and controls (macOS asks for Automation permission once). Apps are only scripted while already running. |
| Browser music | Core Audio reports which browser is making sound (no permission needed). Only then is that browser asked, over AppleScript, to run a small script in its media-site tabs that reads the page's Media Session metadata and `<video>`/`<audio>` state, and to play/pause/skip. Chrome, Arc, Brave, Edge, Vivaldi and Safari. For this, turn on **Allow JavaScript from Apple Events** (Chrome: View > Developer; Safari: Develop menu); without it the notch shows the tab title only, with no controls. |

### Approvals

`PermissionRequest` hooks run *before* Claude Code shows its own prompt. Visor holds the request for up to ~110 seconds. If you don't answer in that time, or you answer in the terminal, or interrupt Claude Code, the card closes and the terminal prompt takes over.

Questions (`AskUserQuestion`) go through the same hook: Visor answers by allowing the tool with its input plus the picked `answers`, exactly as the terminal would. Choosing **Other…** or **Answer in terminal** lets go of the hook so the terminal prompt answers it.

If another app (for example Notchy) also registers a `PermissionRequest` hook, both will ask you. Use one at a time.

## Development

- **Test first.** For any behaviour change, add a failing test to `Tests/VisorCoreTests` (run `scripts/test.sh` and see it fail), then make it pass. Logic lives in `VisorCore` so it can be tested.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): short plain description`, for example `feat(usage): show Copilot premium requests` or `fix(bar): accept addresses dragged as text`.
- **UI changes** start from a mockup; after building, check the real thing with a screenshot (debug builds accept `_show`, `_music` and `_decide` socket messages, see below).

## Layout

- `Sources/VisorCore`: pure logic: pricing, transcript parsing, plan limits, agent state, approval replies.
- `Sources/Visor`: the app: notch window and hover, SwiftUI views, hook socket server, usage and music services.
- `Tests/VisorCoreTests`: unit tests for the core (Swift Testing; XCTest isn't available with the Command Line Tools). `VISOR_REAL=1 scripts/test.sh --filter realTranscripts` times a scan of your real transcripts. Use `scripts/test.sh` rather than plain `swift test`: with the Command Line Tools, incremental test builds can lose Swift Testing's macro plugin, and the script passes its location.

Debug builds accept extra socket messages for testing without a mouse: `{"event":"_show","raw":{"tab":"usage"}}` pins a tab open (`"none"` closes it), `{"event":"_decide","raw":{"decision":"allow"}}` answers the first approval, and `_handoff`, `_pick` (`{"option":1}`) and `_send` work the open question card. See CLAUDE.md for more.

## License

MIT
