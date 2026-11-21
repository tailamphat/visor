# Visor

A small, fast macOS notch app for people who work with AI agents. Hover the notch to open it.

**Website:** https://tailamphat.github.io/visor/ (try the notch in your browser).

- **Usage**: your Copilot premium requests (used, left, reset date) for every GitHub account `gh`, Copilot CLI or a Copilot editor plugin is signed in to, including company `*.ghe.com` accounts (switch accounts with `gh auth switch` or in Copilot CLI and Visor follows within two minutes, or as soon as you open the Usage tab); your OpenCode Go limits (5-hour session, weekly, monthly) when you signed in with a Go key, plus OpenCode's token usage and cost from its local database (today, 7 days, 30 days); your Antigravity weekly limits (Gemini models, Claude and GPT models, % left and reset date); and your Claude plan limits (5-hour session and weekly, % used and % left, when each resets) and what your Claude Code usage would cost at API prices (today, 7 days, 30 days, last 14 days). Each limit also says how it's going at your current pace: "Runs out in ~1h 15m" when it will run out before it resets, or "On pace" with what will be left at the reset. The pace comes from the last half hour of readings, or the average since the window began. When a limit will run out within the hour, the closed notch shows the time left ("42m") instead of its percent. When a Claude or OpenCode Go limit that had run out, or was at least 90% used, resets, the notch opens for a few seconds on the refilled meter ("Claude limit is back").
  The switch at the top of the Usage tab opens **Tokens**: every token you've used across Claude Code, Copilot CLI, OpenCode, Antigravity CLI, Codex CLI and Gemini CLI, by model, like tokscale. A headline (all tokens, and without cache reads, the cheap re-reading of the conversation), a stacked chart per day by model, and Overview, Models, Daily and Tools pages for 7 days, 30 days or all time. Visor keeps its own daily totals (`tokens.json`), so history outlives Claude Code deleting old transcripts. Under Connected accounts (the gear), drag a tool by its handle to change its place in Usage and in the closed notch.
  The gear on the Usage tab opens **Connected accounts**: each tool's status (connected as whom, not signed in, not installed, keychain access denied, API key), a button to fix it (Allow access, Sign in… in Terminal, Refresh), and a switch to hide the tool from the Usage tab and the notch.
- **Agents**: every running Claude Code, Copilot CLI and Antigravity CLI session, grouped by agent, and what it is doing right now ("Bash: npm test", "Edit: Main.swift"), which ones are waiting for you, and which have finished. Sessions sit two to a row; each Claude Code session has a ring around its icon showing how full its context window is (from the last reply in its transcript), amber with the percent from 80% when it's about to compact. Transcripts don't say whether a session has the 200k or the 1M window: it counts as 1M once it goes past 200k, or when the `model` setting asks for `[1m]`. Switch the Agents tab to the **office** with the list/office switch on its first line (or click the Agents tab again): each tool is a table and each session a little person at it, facing each other across it, who walks to the terminal to run commands, the bookshelf to read, the web kiosk to browse, your desk with a "!" or "?" when it needs you, and the sofa when it's done. Tables flow left to right in up to two rows, so any number of tools fits; a bar above the room sums up who is working and waiting. Hover someone for what they're doing; click to bring their app forward. It's drawn with Core Animation layers, so it costs nothing while closed. The palette button over the office opens its world setting, a tile for each world with a preview: the Night Studio, **Galaxy** (Star Wars characters in a hangar, holochess on break) or **Starfleet** (Star Trek characters on a starship deck, poker night on break); a ring at each character's feet shows its agent.
- **Turn summary**: when an agent finishes, open the notch during its green check to see what it did: how long it took, files changed, lines added and removed, commands run and whether its tests passed, with Open in its app and View diff.
- **Clash warning**: when two agents edit the same file within ten minutes, the notch peeks with both marks and "same file", and the Agents tab names the file until it goes quiet.
- **Provider status**: when status.claude.com or githubstatus.com reports an incident on Claude Code, the Claude API or Copilot, the notch peeks once, the tool's mark gets a red or amber dot, and Usage says what's wrong with a link. Checked every five minutes, only for tools you've connected.
- **Approvals**: when Claude Code asks for permission, the notch opens with who is asking (agent, project, app, task) and Allow / Deny / Always allow (naming the rule, e.g. `git push`). With the pointer over the card, Return allows, A always allows and Esc denies; the notch takes the keyboard only then.
- **Questions**: when Claude Code asks you a multiple-choice question, the closed notch shows a blue "?" and the app it runs in, and the Agents tab says which project is asking and what about. Click its row to jump to that terminal, where the question waits. The closed notch tells an approval (amber "!") from a question (blue "?"), and shows which project finished and how long it took.
- **Plugins**: small Lua files that put your own things in the notch: a section in the Plugins tab, a badge on the closed notch, a peek when something happens. Two examples ship in [`Plugins/`](Plugins): **github** (failed Actions runs on the branches your agents are on, and PRs waiting for your review) and **hello**. See [Writing Visor plugins](docs/plugins.md).
- **Clipboard**: everything you copy, newest first, one line each (a swatch for colours). ⌘⇧V opens it from anywhere: type to search, ↑/↓ and Return to paste into the app you were in (⌥Return as plain text), ⌘P or the pin button on hover to pin, ⌫ to delete. Pinned items show a pin. Deleting the item that's on the clipboard clears it from the macOS clipboard too, with Undo. Copies password managers mark as secret are never kept; history stays on this Mac (200 items or 30 days, pins always).
- **Music**: what Spotify, Apple Music, or a browser (YouTube, YouTube Music, SoundCloud, ...) is playing, with artwork, progress and play/pause/skip. Any browser, Firefox and Zen included, works with the **Visor Media** extension (menu bar → Browser Extension for Music…): it reports every media tab and plays, pauses and skips the exact tab, with no AppleScript or browser settings. Without it, Chromium browsers and Safari are read through AppleScript.

Native Swift (AppKit + SwiftUI), no web view. Everything is event-driven, and looping animations run as Core Animation layers in the window server, so the app uses ~0% CPU and ~50 MB at rest.

## Install

```sh
brew install --cask tailamphat/tap/visor
```

Visor keeps itself up to date: it checks for a new version every 6 hours, downloads it in the background and installs it when Visor quits or restarts. The menu has **Restart to Update** once one is ready, and **Install Updates Automatically** to turn this off (then Visor asks first).

Visor is signed ad hoc, not notarized. The cask clears the quarantine flag on install and upgrade for you. If you install it another way and macOS says "Visor is damaged", run:

```sh
xattr -dr com.apple.quarantine /Applications/Visor.app
```

Then launch Visor and choose **Connect your agents**. macOS asks for Accessibility (pasting and some shortcuts) and Automation (music controls) the first time you use those features.

```sh
brew uninstall --cask visor
```

## Build

Visor was called Notchboard; on first launch it moves Notchboard's files and re-points its Claude Code and Copilot CLI hooks.


Needs macOS 14+ and the Command Line Tools (Xcode not required).

```sh
./scripts/bundle.sh --open     # builds build/Visor.app and launches it
scripts/test.sh                # unit tests (Swift Testing)
swift scripts/make-icon.swift  # redraws the app and menu bar icons
scripts/release.sh 0.1.0       # universal zip, sha256, and the signed Sparkle appcast.xml
```

Then choose **Connect your agents** in the notch (or the menu bar icon).

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

- **Test first.** For any behaviour change, add a failing test to `Tests/VisorCoreTests` (run `scripts/test.sh` and see it fail), then make it pass. Logic lives in `VisorCore` so it can be tested.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): short plain description`, for example `feat(usage): show Copilot premium requests` or `fix(bar): accept addresses dragged as text`.
- **UI changes** start from a mockup; after building, check the real thing with a screenshot (debug builds accept `_show`, `_music` and `_decide` socket messages, see below).

## Layout

- `Sources/VisorCore`: pure logic: pricing, transcript parsing, plan limits, agent state, approval replies.
- `Sources/Visor`: the app: notch window and hover, SwiftUI views, hook socket server, usage and music services.
- `Tests/VisorCoreTests`: unit tests for the core (Swift Testing; XCTest isn't available with the Command Line Tools). `VISOR_REAL=1 scripts/test.sh --filter realTranscripts` times a scan of your real transcripts. Use `scripts/test.sh` rather than plain `swift test`: with the Command Line Tools, incremental test builds can lose Swift Testing's macro plugin, and the script passes its location.

Debug builds accept extra socket messages for testing without a mouse: `{"event":"_show","raw":{"tab":"usage"}}` pins a tab open (`"none"` closes it) and `{"event":"_decide","raw":{"decision":"allow"}}` answers the first approval. See CLAUDE.md for more.

## License

MIT
