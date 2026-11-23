# Security policy

## Supported versions

Only the latest release gets security fixes. Visor updates itself with Sparkle (checked every 6 hours, installed on quit), so staying current is the default. If you turned off **Install Updates Automatically**, use **Check for Updates…** in the menu bar menu.

## Reporting a vulnerability

Please report privately through GitHub: open the repo's **Security** tab and choose **Report a vulnerability**. Don't open a public issue for a security problem.

Include the Visor version, the macOS version, steps to reproduce and what an attacker could do. Remove tokens and private paths from logs before you send them.

## In scope

- **Hooks and local sockets.** `agent-hook.sh` and the Unix sockets in `~/Library/Application Support/Visor/` (`hook.sock`, `browser.sock`, and the debug builds' `-debug` sockets). Approvals answered through `hook.sock` decide whether an agent may run a tool, so anything that lets another user or process answer, forge or read them is in scope.
- **Sign-in tokens.** Visor reads existing sign-ins to show usage: Claude Code's OAuth token from the keychain or `~/.claude/.credentials.json`, `gh auth token`, Copilot CLI and Copilot editor plugin tokens, and OpenCode's Go key. A token sent anywhere other than its own service, logged or written to disk is a bug.
- **The plugin sandbox.** Plugins are Lua with no file, process or bytecode access, GET-only requests to listed hosts, and sign-ins attached by Visor only for their own hosts. A plugin that escapes these rules, reads a secret, or reaches a host it didn't list is in scope. See [The sandbox](docs/plugins.md#the-sandbox).
- **The browser bridge.** The Visor Media extension, the `visor-bridge` native messaging helper and the native messaging host manifests Visor writes into each browser.
- **Updates.** Sparkle updates are verified with an EdDSA signature (`SUPublicEDKey` in `Info.plist`). A way to install an update that isn't signed with that key is in scope.

Out of scope: problems that need an attacker who already runs code as your user, and the agents' own permission systems.

## What Visor reads and sends

- Agent events reach Visor only over the local sockets. Transcripts, clipboard history and music stay on your Mac.
- Network calls go only to the usage APIs of the tools you connect (`api.anthropic.com`, GitHub's Copilot API, `opencode.ai`), the Claude and GitHub status pages, the release radar's public feeds (`registry.npmjs.org`, `formulae.brew.sh`, `api.github.com`, no sign-in), the update feed, and the hosts your plugins list.
- Sign-ins are read when needed and never written or refreshed by Visor.
- Codex CLI, OpenCode and Gemini CLI sessions, and MCP server names (never values), are read from those tools' own files. The release radar's Update button opens a Terminal window running a private, self-removing script.
- Visor writes a hook entry in each connected agent's settings and its own files in `~/Library/Application Support/Visor/`, plus logs in `~/Library/Logs/Visor/` (the approvals log records agent, project folder, tool and outcome, never commands or file contents).

Every source, endpoint and refresh interval is listed in [docs/how-it-works.md](docs/how-it-works.md).
