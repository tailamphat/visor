# Visor: notes for Claude

A macOS notch app (Swift, AppKit + SwiftUI) for people who work with AI agents. README.md covers features, how each one works, build commands and the dev rules; read it first. This file holds what isn't obvious from the code.

## Working rules

- **Test first.** Behaviour changes start with a failing test in `Tests/VisorCoreTests`; logic lives in `VisorCore` so it can be tested. Run `scripts/test.sh`, never plain `swift test` (see below).
- **Commits:** Conventional Commits, `type(scope): plain description`. Commit or push only when asked.
- **UI changes:** show the user a visual mockup first (an HTML page they can look at) and let them pick; after building, check the real thing with a screenshot.
- **Writing:** no em dashes anywhere (code comments, docs, commits, chat). Use a hyphen or a colon.
- **Fast and idle:** the user cares most that Visor is fast with no lag. Keep everything event-driven and off the main thread; idle CPU should stay ~0%.
- **Keep the repo personal:** no employer names, work accounts, internal hosts or project names in code, tests or docs. Use `acme.ghe.com`, `octocat` and `/Users/me` in fixtures.

## Toolchain (Command Line Tools only, no Xcode)

- Build and launch: `./scripts/bundle.sh --open`. Tests: `scripts/test.sh` (Swift Testing). The script passes the Swift Testing macro plugin path; without it, incremental test builds lose `TestingMacros`.
- Package uses tools-version 6.0 with `swiftLanguageModes [.v5]`. XCTest isn't available.
- SwiftUI `@State` doesn't compile with the Command Line Tools (no SwiftUIMacros plugin). Keep view state on the `@Observable` `AppModel` instead (e.g. `spendHover`, `questionPicks`).
- Signing: `scripts/bundle.sh` signs with a local self-signed certificate if present, so macOS keeps Accessibility and Automation permissions across rebuilds. On a new Mac run `scripts/make-signing-identity.sh` once first.

## Performance rules

- Looping animations must be Core Animation layer animations (`LayerAnimations.swift`), never SwiftUI `symbolEffect` or `repeatForever` (those cost ~10% CPU).
- Wrap background parsing loops in `autoreleasepool`.
- Measure with `ps -o %cpu`, `sample` and `footprint`.
- Publish to the model only when something visible changes (see `AgentBoard.differsVisibly`).

## Testing the UI without a mouse

Debug builds (`swift build --product Visor`, run `.build/debug/Visor`) accept extra messages on the hook socket `~/Library/Application Support/Visor/hook.sock`:

- `{"event":"_show","raw":{"tab":"usage"}}` pins a tab open (`"none"` closes it)
- `{"event":"_decide","raw":{"decision":"allow|always|deny"}}` answers the first approval
- `{"event":"_music","raw":{"title":..,"playing":true}}` fakes a song
- `{"event":"_handoff","raw":{}}` hides the open question card; `_pick` `{"option":1}` and `_send` answer it

Send with `printf '%s\n' '<json>' | nc -U "$HOME/Library/Application Support/Visor/hook.sock"`. Fake agent sessions with real hook events (`PreToolUse`, `PermissionRequest`, ...) and the pid of any running process. Screenshot with `screencapture -x -R x,y,w,h file.png`. Run the debug build with `VISOR_NO_MUSIC=1` to skip scripting players. Quit Notchy first if it's running: it draws over the notch. Relaunch the release build afterwards.

## Agents, approvals and questions

- Hooks: `HookInstaller` writes `agent-hook.sh`; only `PermissionRequest` connections stay open (nc `-w 110`), everything else is fire-and-forget. macOS `/usr/bin/nc` half-closes after stdin EOF, so EOF does not mean the hook is gone; `HookServer` checks the hook's pid instead.
- The terminal shows its own prompt while Visor holds a hook; answering there makes Claude Code drop the hook.
- Questions (Claude Code's `AskUserQuestion`): `PreToolUse` arrives first (card shows), then `PermissionRequest` (held, so the card can answer). Reply `allow` with `updatedInput` = the original input plus `"answers": {"<question text>": "<label>"}` (several picks joined with ", "). Verified live: Claude Code takes it as the user's answer. Closing the hook with no output leaves the terminal prompt.
- Closed notch: amber "!" bubble = approval, blue "?" bubble = question or waiting for a reply, green check = done or answered.

## Music

- Spotify and Music announce changes with distributed notifications; browsers announce nothing.
- Core Audio says which browser is making sound. Per-process `kAudioProcessPropertyIsRunningOutput` listeners never fire, so watch the process list and the default device's `DeviceIsRunningSomewhere`, plus a 1 s check only while the device runs.
- Browser state and controls come from AppleScript running page JavaScript; the browser needs "Allow JavaScript from Apple Events". Dia refuses page JS unless launched with `--enable-applescript-javascript`, so for Dia "playing" comes from sound.
- A browser plays all its tabs through one audio process, so a web call (Teams in Dia) sounds like music. While the browser uses the microphone, sound is treated as ambiguous and the last shown or pressed state stands.
- Dia keeps its audio stream open a few seconds after a pause; an on-page pause shows after ~3-5 s (accepted). A pause pressed in the notch shows at once (`PlaybackIntent`).
- Media keys posted from a shell don't reach apps (no Accessibility), so they can't be used for tests.
- Don't use the private MediaRemote framework or adapters that load it: the user decided against it.
