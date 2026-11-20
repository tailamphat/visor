# Visor: notes for Claude

A macOS notch app (Swift, AppKit + SwiftUI) for people who work with AI agents. README.md covers features, how each one works, build commands and the dev rules; read it first. This file holds what isn't obvious from the code.

## Working rules

- **Test first.** Behaviour changes start with a failing test in `Tests/VisorCoreTests`; logic lives in `VisorCore` so it can be tested. Run `scripts/test.sh`, never plain `swift test` (see below).
- **Commits:** Conventional Commits, `type(scope): plain description`. Commit or push only when asked.
- **UI changes:** show the user a visual mockup first (an HTML page they can look at) and let them pick; after building, check the real thing with a screenshot.
- **Writing:** no em dashes anywhere (code comments, docs, commits, chat). Use a hyphen or a colon.
- **Fast and idle:** the user cares most that Visor is fast with no lag. Keep everything event-driven and off the main thread; idle CPU should stay ~0%.
- **Balanced around the camera, always.** Anything beside the hardware notch sits the same distance from it on the left as on the right, in every state and every new feature:
  - Closed: each side's content keeps `NotchEars.inset` (8 pt) to the notch (sides sized from measured content, never hard-coded).
  - Open: every panel shows the same centred header, three equal 22 pt slots each side (`NotchEars.musicTab`), packed from the outer edges: Agents, Usage, Music | Clipboard, Plugins, the agents' badge. The panel never slides between tabs.
  - Adding a tab or header item: keep both sides the same number of slots (add one each side, or swap one); if that can't work, show a mockup first. Never pin something to one side only, never spread icons out, never offset the panel. Panel-specific controls go inside the panel (like the Usage gear in its bar).
- **Keep the repo personal:** no employer names, work accounts, internal hosts or project names in code, tests or docs. Use `acme.ghe.com`, `octocat` and `/Users/me` in fixtures.

## Toolchain (Command Line Tools only, no Xcode)

- Build and launch: `./scripts/bundle.sh --open`. Tests: `scripts/test.sh` (Swift Testing). The script passes the Swift Testing macro plugin path; without it, incremental test builds lose `TestingMacros`.
- Package uses tools-version 6.0 with `swiftLanguageModes [.v5]`. XCTest isn't available.
- SwiftUI `@State` doesn't compile with the Command Line Tools (no SwiftUIMacros plugin). Keep view state on the `@Observable` `AppModel` instead (e.g. `spendHover`, `clipHover`).
- Signing: `scripts/bundle.sh` signs with a local self-signed certificate if present, so macOS keeps Accessibility and Automation permissions across rebuilds. On a new Mac run `scripts/make-signing-identity.sh` once first.

## Performance rules

- Looping animations must be Core Animation layer animations (`LayerAnimations.swift`), never SwiftUI `symbolEffect` or `repeatForever` (those cost ~10% CPU).
- Wrap background parsing loops in `autoreleasepool`.
- Antigravity's `agy -p /usage` takes about 4 s and 200 MB; run it only when the Usage tab opens, off the main thread, with a two-minute cache.
- Measure with `ps -o %cpu`, `sample` and `footprint`.
- Publish to the model only when something visible changes (see `AgentBoard.differsVisibly`).

## Testing the UI without a mouse

Debug builds (`swift build --product Visor`, run `.build/debug/Visor`) listen on their own socket, `~/Library/Application Support/Visor/hook-debug.sock`, never the real `hook.sock`, so a test build can't receive (or answer) real agent requests: while it runs, agents ask in their own terminal. Never send `_decide` to the real socket. The debug socket also accepts extra messages:

- `{"event":"_show","raw":{"tab":"usage"}}` pins a tab open (`"none"` closes it); add `"accounts":true` for Connected accounts, `"office":true` with `"world":"galaxy"` (or `studio`, `starfleet`) for the office
- `{"event":"_decide","raw":{"decision":"allow|always|deny"}}` answers the first approval
- `{"event":"_music","raw":{"title":..,"playing":true}}` fakes a song
- `{"event":"_musicCommand","raw":{"command":"playPause|next|previous"}}` presses a music button

Send with `printf '%s\n' '<json>' | nc -U "$HOME/Library/Application Support/Visor/hook-debug.sock"`. Fake agent sessions with real hook events (`PreToolUse`, `PermissionRequest`, ...) and the pid of any running process. Screenshot with `screencapture -x -R x,y,w,h file.png`. Run the debug build with `VISOR_NO_MUSIC=1` to skip scripting players. Quit Notchy first if it's running: it draws over the notch. Relaunch the release build afterwards.

## Plugins

- Lua 5.4.7 is vendored in `Sources/CLua` (MIT, `LICENSE` there) with one marked "Visor patch" in `lstrlib.c`: a step limit on pattern matching, which runs in C where the instruction hook can't stop it. `CLua.h` wraps the C macros Swift can't call; `clua.c` has the budget hook, the trampoline and a per-plugin memory cap that is enforced only while plugin code runs (`clua_enforce`), so Visor's own pushes never fail halfway.
- Security rules (tested in "Plugin security"): plugins never see secrets (`visor.secret` is gone); a sign-in is attached by Visor only for its own host (`PluginSecret`: `{host}` commands for the sign-in host and subdomains, others only for their listed `hosts`); GET only; redirects only to listed hosts, without the sign-in on a host change; answers capped at 10 MB; `lua_checkstack` before every push; read Visor's own fields raw (`lua_rawget`), never with metamethods; `__gc` refused; output, peeks, requests, timers, handlers, store, log and `visor.repos()` are rationed. `LuaPlugin` (VisorCore, tested) is one sandboxed state per plugin; `PluginService`/`PluginRunner` (app) give each plugin a serial queue, `DispatchSourceTimer`s with 10% leeway, URLSession with an ETag cache, the secret allowlist (`PluginSecrets`), `visor.repos()` from agent cwds, logs in `~/Library/Logs/Visor/<id>.log` and the store in `PluginData/<id>.json`.
- Lua errors raised from Swift functions go through the C trampoline (`clua_pushfunction`): Swift returns -1 with the message pushed and C calls `lua_error`, so longjmp never crosses Swift frames. Never call `lua_error`/`luaL_error` from Swift.
- Push NSNumber before Bool when converting to Lua: JSON's 0/1 would otherwise become booleans.
- Plugins live in `~/Library/Application Support/Visor/Plugins/` (shared by debug and release builds). Each plugin folder and its `.lua`/`.json` files are watched; a change reloads all plugins. `docs/plugins.md` is the author guide; keep it in step with the API.

## Updates and releases

- Check for Updates… is Sparkle 2 (`SPUStandardUpdaterController` in `AppDelegate`), reading `appcast.xml` from `main` (SUFeedURL). Automatic installs are on by default (`SUAutomaticallyUpdate`, checked every 6 hours): an update downloads silently and installs on quit; `UpdateFeed` keeps Sparkle's install-now block for the menu's "Restart to Update". The menu toggle writes the user default, which wins over Info.plist. Updates are verified with the EdDSA key whose public half is SUPublicEDKey; the private key is in the login Keychain (shared with Treatly) and never in the repo. On a new Mac, import it with `.build/artifacts/sparkle/Sparkle/bin/generate_keys -f <exported-key-file>` before releasing.
- Release: tag, `scripts/release.sh <version>` (zip plus a new `appcast.xml` entry), push `main` with `appcast.xml`, `gh release create` with the zip, then bump the tap's `Casks/visor.rb`. Add `auto_updates true` to the cask only once the version with Sparkle (0.6.4) has been out a while: with it, plain `brew upgrade` skips Visor, which would strand anyone still on 0.6.3 (no updater).
- CFBundleVersion is the commit count, which Sparkle compares; never build a release from a commit behind the last one.
- Try an update before releasing: bundle a higher version, `generate_appcast --download-url-prefix http://127.0.0.1:8765/` into a folder, serve it with `python3 -m http.server`, and run an older bundle with `VISOR_UPDATE_FEED=http://127.0.0.1:8765/appcast.xml`. With `SULastCheckTime` set in the past it downloads at launch and installs on quit.

## Agents, approvals and questions

- Hooks: `HookInstaller` writes `agent-hook.sh`; only `PermissionRequest` connections stay open (nc `-w 110`), everything else is fire-and-forget. macOS `/usr/bin/nc` half-closes after stdin EOF, so EOF does not mean the hook is gone; `HookServer` checks the hook's pid instead.
- The terminal shows its own prompt while Visor holds a hook. Denying there kills the hook (Visor sees its pid go). Allowing there does not: the hook keeps running and nothing is sent until `PostToolUse`, so `HookServer` looks for the command starting under the agent (`eval '<command>'`, see `TerminalAnswer`) to close the card at once. Verified with Claude Code 2.1.311.
- Questions (Claude Code's `AskUserQuestion`): `PreToolUse` sets the session to asking; the notch shows a blue "?" but no card, and does not open. On `PermissionRequest`, reply with no output at once so the terminal's own prompt answers it. The Agents row (click) brings the host app forward; `AgentQuestion` only parses the label. A `PostToolUse` for the tool shows the "Answered" peek.
- Antigravity CLI (`agy`): hooks live in `~/.gemini/config/hooks.json` (top-level named hooks; tool events use the nested `matcher`/`hooks` shape, lifecycle events the flat shape). `agent-hook.sh` takes the provider first (`antigravity <Event>`). `PreInvocation` with `invocationNum == 0` starts a turn; later invocations are just "Thinking". `PreToolUse` prints `{"decision":"allow"}` to defer to agy's own permissions, so the notch shows sessions and activity but approvals stay in the terminal. Set `VISOR_USAGE_PROBE=1` on `agy -p /usage` runs so the quota check never shows up as a session.
- Sessions are saved to `sessions.json` (debug builds: `sessions-debug.json`) and restored on launch, minus agents whose process has exited; agents only send events when something happens, so without it an idle session stays missing after a restart until its next turn.
- The notch window never resizes (resizing it mid-animation drew text outside the panel); it ignores the mouse except over the open panel.
- Closed notch sides are sized from their measured content (`leftEarContent`/`rightEarContent`), with `NotchEars.inset` to the notch and to the outer edge, so anything shown there gets the same padding. Never hard-code a side's width. A badge offset past its icon needs trailing padding equal to the part that shows (black backing doesn't show on the notch).
- Closed notch: amber "!" bubble = approval, blue "?" bubble = question or waiting for a reply, green check = done or answered.

## Music

- Spotify and Music announce changes with distributed notifications; browsers announce nothing.
- Core Audio says which browser is making sound. Per-process `kAudioProcessPropertyIsRunningOutput` listeners never fire, so watch the process list and the default device's `DeviceIsRunningSomewhere`, plus a 1 s check only while the device runs.
- Browser state and controls come from AppleScript running page JavaScript; the browser needs "Allow JavaScript from Apple Events". Dia refuses page JS unless launched with `--enable-applescript-javascript`, so for Dia "playing" comes from sound.
- A browser plays all its tabs through one audio process, so a web call (Teams in Dia) sounds like music. While the browser uses the microphone (a call, or Teams keeping it open), sound is ambiguous: the notch shows a neutral play/pause (`NowPlaying.stateKnown` false) instead of guessing. Keeping the last shown state got stuck inverted once the video was paused on the page.
- Dia freezes background tabs: timers stop and no media element (not even a new one) loads, so `play()` leaves YouTube "playing" with the clock stopped and YouTube pauses it ~2 s later. Nothing from a script, a Web Lock or a seek gets past it. Visor checks after 1 s and, if the clock hasn't moved, `focus`es the tab until it plays, then focuses the previous tab and reactivates the previous app (`startHeldBackTab`). Once playing, the hidden tab keeps playing.
- Dia keeps its audio stream open a few seconds after a pause; an on-page pause shows after ~3-5 s (accepted). A pause pressed in the notch shows at once (`PlaybackIntent`).
- Media keys posted from a shell don't reach apps (no Accessibility), so they can't be used for tests.
- The Visor Media extension (`Extension/`, Chromium and Firefox/Zen) is the browser-independent path: content scripts on media sites report to the background script, which talks native messaging to `visor-bridge` (`Contents/Helpers`), which relays lines to `browser.sock` (debug: `browser-debug.sock`). Visor writes the host manifest (`visor.media.json`) into each installed browser's `NativeMessagingHosts` on launch, so a debug run points them at `.build/debug/visor-bridge` until the release build runs again. The Chromium extension id is fixed by the manifest `key`. Browsers with the extension are never scripted. Fake a browser by running `visor-bridge` and writing framed messages to its stdin.
- Don't use the private MediaRemote framework or adapters that load it: the user decided against it.
