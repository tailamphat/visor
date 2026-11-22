# Visor

A small, fast macOS notch app for people who work with AI agents. Hover the notch to open it.

**Website:** https://tailamphat.github.io/visor/ (try the notch in your browser).

Native Swift (AppKit + SwiftUI), no web view. Everything is event-driven, and looping animations run as Core Animation layers, so Visor uses ~0% CPU and ~50 MB at rest.

## Features

Short list below; [docs/features.md](docs/features.md) has the full details of each feature.

### Agents

- **Sessions**: every running Claude Code, Copilot CLI and Antigravity CLI session, grouped by agent, with what it's doing now ("Bash: npm test") and which are waiting for you or done.
  - Context ring around each Claude Code session's icon, amber with the percent from 80%.
  - Subagents: "Waiting on 3 helpers" and a list of each helper's task, type and current tool.
- **Approvals**: Allow / Deny / Always allow (naming the rule, e.g. `git push`) from the notch, with who is asking.
  - Keys while the pointer is over the card: Return allows, A always allows, Esc denies.
  - Claude Code and Copilot CLI. Turn off with **Approvals in the Notch** to keep them in the terminal.
- **Questions**: when Claude Code asks a multiple-choice question, a blue "?" shows; click the row to jump to its terminal.
- **Office**: the Agents tab as a room where each session is a little person who walks to the terminal, bookshelf or your desk.
  - Worlds: Night Studio, Galaxy (Star Wars) and Starfleet (Star Trek).
- **Turn summary**: when an agent finishes, open the notch during the green check for time taken, files changed, lines, commands, tests, and View diff.
- **Clash warning**: the notch peeks when two agents edit the same file within ten minutes.
- **Provider status**: incidents on status.claude.com and githubstatus.com show as a peek and a red or amber dot. Checked every five minutes.

### Usage

- **Limits**: Claude plan (5-hour and weekly), Copilot premium requests (every `gh` account, `*.ghe.com` included), OpenCode Go and Antigravity, with reset times.
  - Pace: "Runs out in ~1h 15m" or "On pace" with what will be left at the reset.
  - The closed notch shows time left ("42m") when a limit runs out within the hour, and opens on "Claude limit is back" when it resets.
- **Spend**: what your Claude Code and OpenCode usage would cost at API prices (today, 7 days, 30 days).
- **Tokens**: every token across Claude Code, Copilot CLI, OpenCode, Antigravity CLI, Codex CLI and Gemini CLI, by model and day, for 7 days, 30 days or all time.
  - Visor keeps its own daily totals (`tokens.json`), so history outlives deleted transcripts.
- **Connected accounts** (the gear): each tool's sign-in status, a button to fix it, and switches to hide or reorder tools.

### Everyday

- **Clipboard**: everything you copy, newest first. ⌘⇧V opens it from anywhere; type to search, Return to paste.
  - Pin, delete, paste as plain text. Copies marked secret by password managers are never kept.
  - Stays on this Mac: 200 items or 30 days, pins always.
- **Music**: what Spotify, Apple Music or a browser tab is playing, with artwork, progress and controls.
  - Any browser with the **Visor Media** extension (menu bar → Browser Extension for Music…); Chromium browsers and Safari also through AppleScript.
- **Keep awake**: the cup in the Agents tab keeps your Mac from sleeping. On, Auto (only while an agent works) or Off.

### Plugins

- **Plugins**: small Lua files that add a section, a badge or a peek to the notch. Three examples ship in [`Plugins/`](Plugins): **github** (failed Actions runs and PRs waiting for your review), **focus** (a focus timer with a week of focus time) and **hello**. See [Writing Visor plugins](docs/plugins.md).

## Requirements

- macOS 14 or later, on a Mac with a notch.
- At least one agent: Claude Code, Copilot CLI or Antigravity CLI (`agy`). Usage also reads OpenCode, Codex CLI and Gemini CLI.
- To build from source: the Command Line Tools (Xcode not required).

## Installation

```sh
brew install --cask tailamphat/tap/visor
```

Visor is signed ad hoc, not notarized. The cask clears the quarantine flag for you. If you install it another way and macOS says "Visor is damaged", run:

```sh
xattr -dr com.apple.quarantine /Applications/Visor.app
```

Updates: Visor checks every 6 hours, downloads in the background and installs when it quits or restarts. The menu has **Restart to Update** once one is ready, and **Install Updates Automatically** to turn this off.

Visor was called Notchboard; on first launch it moves Notchboard's files and re-points its hooks.

Uninstall:

```sh
brew uninstall --cask visor
```

## Usage

1. Launch Visor and choose **Connect your agents** in the notch (or the menu bar icon).
2. Hover the notch to open it. Click the icons in its header to switch tabs.
3. macOS asks for Accessibility (pasting, some shortcuts) and Automation (music controls) the first time you use those features.

| Shortcut | Where | Does |
|---|---|---|
| ⌘⇧V | Anywhere | Open the clipboard |
| ↑ / ↓, Return | Clipboard | Pick and paste into the app you were in |
| ⌥Return | Clipboard | Paste as plain text |
| ⌘P | Clipboard | Pin or unpin |
| ⌫ | Clipboard | Delete (with Undo) |
| Return / A / Esc | Approval card | Allow / Always allow / Deny |

## How it works

| Feature | Source |
|---|---|
| Plan limits | `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token Claude Code keeps in your login keychain (`Claude Code-credentials`, with a hash suffix when `CLAUDE_CONFIG_DIR` is set), or in `~/.claude/.credentials.json` when the keychain isn't used. Read with `/usr/bin/security`; a refused keychain prompt isn't asked again until you press Allow access; never written or refreshed by Visor. Refreshed every 2 minutes, and when you open the Usage tab if older than 45s. The plan's name (Pro, Max 5x, ...) comes from `GET https://api.anthropic.com/api/oauth/profile` with the same token, read at most every 15 minutes, because the saved sign-in keeps the plan Claude Code signed in with. This endpoint is not a documented public API and may change. |
| Copilot | For each host in `gh auth status` (github.com and `*.ghe.com`), `GET <api>/copilot_internal/user` with that host's `gh auth token`, the same call Copilot's own apps use. Plans without premium requests (Copilot Free) show their chat and completions limits in the Usage tab only. The token is fetched from `gh` each time and never stored. Accounts signed in only to Copilot CLI (`~/.copilot/config.json`) use its keychain token (`copilot-cli`); accounts signed in only through a Copilot editor plugin (JetBrains, Neovim, Xcode, older VS Code: `~/.config/github-copilot/apps.json` or `hosts.json`) use the token in that file. VS Code keeps its sign-in encrypted, so VS Code-only users need `gh auth login`. When an account can't be read, Connected accounts says why. `gh` is looked for in Homebrew, MacPorts, `~/.local/bin`, Nix and mise/asdf shims. Internal endpoint; it may change. |
| Antigravity | `agy -p /usage --output-format json` (Antigravity CLI print mode) when the Usage tab opens, cached for two minutes. The CLI takes a few seconds and about 200 MB, so it never polls in the background. Hidden when `agy` isn't installed. |
| OpenCode | Assistant messages in `~/.local/share/opencode/opencode.db` (`$XDG_DATA_HOME/opencode`, or `$OPENCODE_DATA_DIR`), read with `/usr/bin/sqlite3 -json`; tokens and cost come from OpenCode's own records, so free models show $0. Go limits come from `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key in `auth.json`. Hidden when OpenCode has no recorded usage and there is no Go key. |
| Claude spend | Token usage in `~/.claude/projects/**/*.jsonl`, priced with API list prices (`Sources/VisorCore/Pricing.swift`). Files are read incrementally, so a rescan takes milliseconds. This is the API-equivalent value, not what a subscription bills. |
| Agents & approvals | Claude Code [hooks](https://code.claude.com/docs/en/hooks). Connecting adds `~/Library/Application Support/Visor/agent-hook.sh` to `~/.claude/settings.json` (a one-time backup is saved as `settings.json.visor-backup`). The script sends each event to a Unix socket owned by the app, and always exits 0, so Claude Code is never blocked when Visor isn't running. |
| Copilot CLI agents | Menu bar → Agents → Copilot CLI writes `~/.copilot/hooks/visor.json` (Copilot CLI loads every file there), running the same hook script for session, prompt, tool, notification, stop and approval events. Approvals use the same card as Claude Code, for commands, file changes and web fetches only. Copilot's hooks can't save rules, so **Always** is kept by Visor per project (`copilot-rules.json`) and later matching requests are allowed without a card. Copilot asks the hook even for things it would allow itself (`--allow-all-tools`); turn **Approvals in the Notch** off in the menu to keep every agent's approvals in its own terminal. |
| Antigravity CLI agents | Menu bar → Agents → Antigravity CLI writes the `"visor"` entry in `~/.gemini/config/hooks.json`. Antigravity's `SessionStart`, `PreInvocation`, `PreToolUse`, `PostToolUse` and `Stop` hooks feed the same socket, so its sessions show up with their project, prompt and current tool. `PreToolUse` returns `{"decision":"allow"}`, which defers to Antigravity's own permission rules; approvals stay in its terminal. Restart `agy` after connecting so it loads the hooks. |
| Clipboard | macOS doesn't announce clipboard changes, so the clipboard's change counter is read once a second and on every app switch. History is saved to `~/Library/Application Support/Visor/clipboard.json` (images in `Clips/`). Copies with `org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType` are skipped, as are apps listed in the `clipboardExcludedApps` default. Pasting presses ⌘V with the Accessibility permission. ⌘⇧V is a Carbon hot key (no permission). |
| Music | Distributed notifications from Spotify / Music, plus AppleScript for position, artwork and controls (macOS asks for Automation permission once). Apps are only scripted while already running. |
| Browser music | Core Audio reports which browser is making sound (no permission needed). Only then is that browser asked, over AppleScript, to run a small script in its media-site tabs that reads the page's Media Session metadata and `<video>`/`<audio>` state, and to play/pause/skip. Chrome, Arc, Brave, Edge, Vivaldi and Safari. For this, turn on **Allow JavaScript from Apple Events** (Chrome: View > Developer; Safari: Develop menu); without it the notch shows the tab title only, with no controls. |

### Approvals

`PermissionRequest` hooks run *before* Claude Code shows its own prompt. Visor holds the request for up to ~110 seconds. If you don't answer in that time, or you answer in the terminal, or interrupt Claude Code, the card closes and the terminal prompt takes over.

Questions (`AskUserQuestion`) go through the same hook, but Visor lets go of it at once so the terminal's own prompt answers the question. The notch only signals it: the blue "?" and the Agents row point you to the terminal. Opening that row brings the app forward.

**Approvals in the Notch** in the menu bar menu is one switch for every agent that can ask the notch (Claude Code and Copilot CLI). Turn it off and Visor lets go of each request at once, so it asks in its own terminal; agents still show in the notch.

If another app (for example Notchy) also registers a `PermissionRequest` hook, both will ask you. Use one at a time.

## Development

```sh
./scripts/bundle.sh --open     # builds build/Visor.app and launches it
scripts/test.sh                # unit tests (Swift Testing)
swift scripts/make-icon.swift  # redraws the app and menu bar icons
scripts/release.sh 0.1.0       # universal zip, sha256, and the signed Sparkle appcast.xml
```

- **Test first.** For any behaviour change, add a failing test to `Tests/VisorCoreTests` (run `scripts/test.sh` and see it fail), then make it pass. Logic lives in `VisorCore` so it can be tested.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): short plain description`, for example `feat(usage): show Copilot premium requests` or `fix(bar): accept addresses dragged as text`.
- **UI changes** start from a mockup; after building, check the real thing with a screenshot.
- Use `scripts/test.sh` rather than plain `swift test`: with the Command Line Tools, incremental test builds can lose Swift Testing's macro plugin, and the script passes its location. `VISOR_REAL=1 scripts/test.sh --filter realTranscripts` times a scan of your real transcripts.
- Debug builds accept extra socket messages for testing without a mouse: `{"event":"_show","raw":{"tab":"usage"}}` pins a tab open (`"none"` closes it) and `{"event":"_decide","raw":{"decision":"allow"}}` answers the first approval. See CLAUDE.md for more.

## Project structure

- `Sources/VisorCore`: pure logic: pricing, transcript parsing, plan limits, agent state, approval replies.
- `Sources/Visor`: the app, a folder per feature: `App` (delegate, model, menu, updates), `Notch` (window, layout, theme, layer animations), `Agents` (list, approvals, hook server and installer), `Office`, `Usage` (service per provider, views), `Music`, `Clipboard`, `Bar`, `Plugins`, `Shared` (small components) and `Support` (shell, sockets, hot keys, media keys).
- `Tests/VisorCoreTests`: unit tests for the core (Swift Testing; XCTest isn't available with the Command Line Tools).
- `Plugins/`: example plugins. `Extension/`: the Visor Media browser extension. `docs/`: the website, [features](docs/features.md), [architecture](docs/architecture.md) (module map, data flows, recipes for adding features) and the [plugin guide](docs/plugins.md).

## License

MIT
