# How Visor works

Where each feature's data comes from, what goes over the network, and what Visor writes. The [README](../README.md#privacy) has the short version; [features.md](features.md) explains what each feature does.

Every source below uses the same labels, left out when empty: **Reads**, **Network**, **Refresh**, **Permissions**, **Good to know**.

## Contents

- [Agents](#agents): [Claude Code](#claude-code-hooks), [Copilot CLI](#copilot-cli-hooks), [Antigravity CLI](#antigravity-cli-hooks), [Approvals](#approvals)
- [Usage](#usage): [Claude limits](#claude-limits), [Copilot](#copilot), [Antigravity](#antigravity), [OpenCode](#opencode), [Claude spend](#claude-spend), [Provider status](#provider-status)
- [Everyday](#everyday): [Clipboard](#clipboard), [Music](#music), [Browser music](#browser-music)
- [What Visor writes](#what-visor-writes)

## Agents

### Claude Code hooks

- **Reads:** Claude Code [hooks](https://code.claude.com/docs/en/hooks). Connecting adds `~/Library/Application Support/Visor/agent-hook.sh` to `~/.claude/settings.json`; a one-time backup is saved as `settings.json.visor-backup`.
- **Network:** none. The script sends each event to a Unix socket owned by the app.
- **Good to know:** the script always exits 0, so Claude Code is never blocked when Visor isn't running.

### Copilot CLI hooks

- **Reads:** menu bar → Agents → Copilot CLI writes `~/.copilot/hooks/visor.json` (Copilot CLI loads every file there). It runs the same hook script for session, prompt, tool, notification, stop and approval events.
- **Good to know:**
  - Approvals use the same card as Claude Code, for commands, file changes and web fetches only.
  - Copilot's hooks can't save rules, so **Always** is kept by Visor per project (`copilot-rules.json`), and later matching requests are allowed without a card.
  - Copilot asks the hook even for things it would allow itself (`--allow-all-tools`). Turn **Approvals in the Notch** off in the menu to keep every agent's approvals in its own terminal.

### Antigravity CLI hooks

- **Reads:** menu bar → Agents → Antigravity CLI writes the `"visor"` entry in `~/.gemini/config/hooks.json`. Antigravity's `SessionStart`, `PreInvocation`, `PreToolUse`, `PostToolUse` and `Stop` hooks feed the same socket, so its sessions show up with their project, prompt and current tool.
- **Good to know:** `PreToolUse` returns `{"decision":"allow"}`, which defers to Antigravity's own permission rules; approvals stay in its terminal. Restart `agy` after connecting so it loads the hooks.

### Approvals

- **Reads:** `PermissionRequest` hooks, which run *before* the agent shows its own prompt.
- **Good to know:**
  - Visor holds the request for up to ~110 seconds. If you don't answer in that time, answer in the terminal, or interrupt the agent, the card closes and the terminal prompt takes over.
  - Questions (`AskUserQuestion`) go through the same hook, but Visor lets go at once so the terminal's own prompt answers the question. The notch only signals it: the blue "?" and the Agents row point you to the terminal.
  - **Approvals in the Notch** in the menu bar menu is one switch for every agent that can ask the notch (Claude Code and Copilot CLI). Off, Visor lets go of each request at once, so it asks in its own terminal; agents still show in the notch.
  - If another app (for example Notchy) also registers a `PermissionRequest` hook, both will ask you. Use one at a time.

## Usage

### Claude limits

- **Reads:** the OAuth token Claude Code keeps in your login keychain (`Claude Code-credentials`, with a hash suffix when `CLAUDE_CONFIG_DIR` is set), or `~/.claude/.credentials.json` when the keychain isn't used. Read with `/usr/bin/security`; never written or refreshed by Visor.
- **Network:** `GET https://api.anthropic.com/api/oauth/usage` with that token. The plan's name (Pro, Max 5x, ...) comes from `GET https://api.anthropic.com/api/oauth/profile`, because the saved sign-in keeps the plan Claude Code signed in with.
- **Refresh:** every 2 minutes, and when you open the Usage tab if older than 45 s. The profile at most every 15 minutes.
- **Permissions:** keychain access. A refused keychain prompt isn't asked again until you press Allow access.
- **Good to know:** these endpoints are not a documented public API and may change.

### Copilot

- **Reads:** each host in `gh auth status` (github.com and `*.ghe.com`) with that host's `gh auth token`, fetched each time and never stored.
  - Accounts signed in only to Copilot CLI (`~/.copilot/config.json`) use its keychain token (`copilot-cli`).
  - Accounts signed in only through a Copilot editor plugin (JetBrains, Neovim, Xcode, older VS Code: `~/.config/github-copilot/apps.json` or `hosts.json`) use the token in that file.
  - `gh` is looked for in Homebrew, MacPorts, `~/.local/bin`, Nix and mise/asdf shims.
- **Network:** `GET <api>/copilot_internal/user`, the same call Copilot's own apps use.
- **Good to know:**
  - Internal endpoint; it may change.
  - Plans without premium requests (Copilot Free) show their chat and completions limits in the Usage tab only.
  - VS Code keeps its sign-in encrypted, so VS Code-only users need `gh auth login`.
  - When an account can't be read, Connected accounts says why.

### Antigravity

- **Reads:** `agy -p /usage --output-format json` (Antigravity CLI print mode).
- **Network:** made by `agy` itself.
- **Refresh:** only when the Usage tab opens, cached for two minutes. The CLI takes a few seconds and about 200 MB, so it never polls in the background.
- **Good to know:** hidden when `agy` isn't installed.

### OpenCode

- **Reads:** assistant messages in `~/.local/share/opencode/opencode.db` (`$XDG_DATA_HOME/opencode`, or `$OPENCODE_DATA_DIR`), with `/usr/bin/sqlite3 -json`. Tokens and cost come from OpenCode's own records, so free models show $0.
- **Network:** Go limits only: `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key in `auth.json`.
- **Good to know:** hidden when OpenCode has no recorded usage and there is no Go key.

### Claude spend

- **Reads:** token usage in `~/.claude/projects/**/*.jsonl`, priced with API list prices (`Sources/VisorCore/Pricing.swift`).
- **Network:** none.
- **Refresh:** files are read incrementally, so a rescan takes milliseconds.
- **Good to know:** this is the API-equivalent value, not what a subscription bills.

### Provider status

- **Network:** the public status pages status.claude.com (Claude Code, Claude API) and githubstatus.com (Copilot).
- **Refresh:** every five minutes, only for tools you've connected.

## Everyday

### Clipboard

- **Reads:** the clipboard's change counter, once a second and on every app switch (macOS doesn't announce clipboard changes).
- **Network:** none. History is saved to `~/Library/Application Support/Visor/clipboard.json` (images in `Clips/`).
- **Permissions:** pasting presses ⌘V with the Accessibility permission. ⌘⇧V is a Carbon hot key (no permission).
- **Good to know:** copies with `org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType` are skipped, as are apps listed in the `clipboardExcludedApps` default.

### Music

- **Reads:** distributed notifications from Spotify and Music, plus AppleScript for position, artwork and controls.
- **Permissions:** Automation, asked once.
- **Good to know:** apps are only scripted while already running.

### Browser music

- **Reads:** Core Audio reports which browser is making sound (no permission needed). Only then is that browser asked, over AppleScript, to run a small script in its media-site tabs that reads the page's Media Session metadata and `<video>`/`<audio>` state, and to play, pause and skip.
- **Permissions:** turn on **Allow JavaScript from Apple Events** in the browser (Chrome: View > Developer; Safari: Develop menu). Without it the notch shows the tab title only, with no controls.
- **Good to know:** works with Chrome, Arc, Brave, Edge, Vivaldi and Safari. The **Visor Media** extension (any browser, Firefox and Zen included) replaces all of this: it reports media tabs through a native messaging helper, with no AppleScript.

## What Visor writes

- A hook entry in each connected agent's settings: `~/.claude/settings.json` (with a one-time backup), `~/.copilot/hooks/visor.json`, `~/.gemini/config/hooks.json`.
- `~/Library/Application Support/Visor/`: the hook script, sockets, `sessions.json`, `copilot-rules.json`, `clipboard.json` and `Clips/`, `tokens.json`, `Plugins/` and `PluginData/`.
- Settings in Visor's own user defaults.
