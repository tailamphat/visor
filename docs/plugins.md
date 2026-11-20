# Writing Visor plugins

A plugin watches something you care about (CI, pull requests, an on-call pager, a build server) and shows it in the notch: a **badge** on the closed notch, a short **peek** when something happens, and a **section** in the Plugins tab. Plugins are small [Lua 5.4](https://www.lua.org/manual/5.4/) files. Visor draws everything itself, so every plugin looks like part of Visor and none can slow it down.

- [Quick start](#quick-start)
- [How a plugin runs](#how-a-plugin-runs)
- [plugin.json](#pluginjson)
- [The `visor` API](#the-visor-api)
- [Custom views](#custom-views)
- [What shows where](#what-shows-where)
- [Keeping Visor idle](#keeping-visor-idle)
- [The sandbox](#the-sandbox)
- [Debugging](#debugging)
- [Examples](#examples)

## Quick start

1. Make a folder in `~/Library/Application Support/Visor/Plugins/` (menu bar → Plugins Folder opens it):

   ```
   Plugins/
     coffee/
       plugin.json
       main.lua
   ```

2. `plugin.json`:

   ```json
   {
     "id": "coffee",
     "name": "Coffee",
     "icon": "cup.and.saucer",
     "version": "1.0.0"
   }
   ```

3. `main.lua`:

   ```lua
   visor.every(60, function()
     local hour = tonumber(os.date("%H"))
     visor.panel({
       { title = "Coffee", rows = {
           { title = hour < 14 and "Still fine" or "Too late for coffee", status = hour < 14 and "good" or "warn" },
       } },
     })
   end)
   ```

4. Save. Visor loads the plugin straight away (and reloads it every time you save), and a **Plugins** tab appears in the notch.

## How a plugin runs

- Visor runs `main.lua` once when the plugin loads. Set things up there and register work with `visor.every`.
- `visor.every(seconds, fn)` runs `fn` right away, then every `seconds` (never more often than every 30 seconds). Most plugins are one `visor.every` call.
- Each plugin runs on its own background queue, so a slow request never holds up the notch or other plugins. Calls like `visor.http.get` simply wait for the answer.
- Saving any `.lua` or `.json` file in the plugin's folder reloads it. **Reload** in the Plugins tab reloads every plugin.
- An error stops that call, shows in red under the plugin's name, and goes to the log. The next `visor.every` call runs as usual.

## plugin.json

| Key | Required | What it does |
|---|---|---|
| `id` | yes | Lowercase letters, digits and dashes, up to 41 characters. Unique per plugin. |
| `name` | yes | Shown in the Plugins tab. |
| `version` | | Shown in the log. |
| `icon` | | An [SF Symbol](https://developer.apple.com/sf-symbols/) name, e.g. `"arrow.triangle.branch"`. Also the default badge icon. |
| `description` | | One sentence about what it shows. |
| `main` | | The Lua file to run. Default `"main.lua"`. |
| `hosts` | | The only hosts `visor.http` may call, over https. `"*.example.com"` matches any subdomain. |
| `secrets` | | Sign-ins Visor may attach to requests, and where they may go. See [Secrets](#secrets). |
| `settings` | | Name → default value. Users override them in `settings.json`. |
| `accent` | | The plugin's one colour, `"#RRGGBB"`: charts, progress bars and its primary button. Red, amber and green keep their meaning. |

```json
{
  "id": "github",
  "name": "GitHub",
  "version": "1.0.0",
  "icon": "arrow.triangle.branch",
  "description": "Failed Actions runs and pull requests waiting for your review.",
  "hosts": ["api.github.com", "*.ghe.com"],
  "secrets": { "token": "gh auth token --hostname {host}" },
  "settings": { "repos": [], "reviews": true }
}
```

### settings.json

To change a setting without editing the plugin, put a `settings.json` next to `plugin.json`. Its values replace the defaults:

```json
{ "repos": ["octocat/hello-world", "acme.ghe.com/team/api"] }
```

## The `visor` API

### Scheduling

| Call | Does |
|---|---|
| `visor.every(seconds, fn)` | Runs `fn` now, then every `seconds` (at least 30). Call it at the top level of `main.lua`. |
| `visor.now()` | Seconds since 1970, with fractions. |
| `visor.isotime("2026-11-20T08:00:00Z")` | An ISO 8601 time as seconds since 1970, or `nil`. |

`os.time`, `os.date`, `os.clock` and `os.difftime` work as usual.

### Showing things

| Call | Does |
|---|---|
| `visor.panel(sections)` | Replaces the plugin's section in the Plugins tab. |
| `visor.badge(badge)` | Sets the plugin's badge on the closed notch. `visor.badge(nil)` removes it. |
| `visor.peek(peek)` | Shows a few seconds of news in the closed notch. |

```lua
visor.panel({
  { title = "Builds", rows = {
      { title = "api · main · test", detail = "failed", status = "bad",
        url = "https://github.com/acme/api/actions/runs/1", time = "2026-11-20T08:00:00Z" },
      { title = "web · main · build", status = "good" },
  } },
})

visor.badge({ icon = "xmark.octagon.fill", count = 2, state = "bad", help = "2 builds failed" })

visor.peek({ title = "Build failed on main", subtitle = "api · test", state = "bad", icon = "xmark.octagon" })
```

**Section:** `title`, plus `rows`. Up to 10 sections, 50 rows each.

**Row:**

| Field | |
|---|---|
| `title` | Required. One line; long titles are shortened in the middle. |
| `detail` | Short text on the right, e.g. `"failed"` or a repo name. |
| `status` | The dot's colour (see [States](#states)). |
| `url` | Opens in the browser when the row is clicked (http or https). |
| `time` | Seconds since 1970 or an ISO 8601 string. Shown as `now`, `4m`, `3h`, `2d`. |

**Badge:** `icon` (SF Symbol, defaults to the plugin's), `count` (optional number), `state`, and `help` (hover text). Keep a badge for things that stay true until someone deals with them, like a red build or reviews waiting. When it's dealt with, call `visor.badge(nil)`.

**Peek:** `title` (required), `subtitle`, `state`, `icon`. Use it once per event, not on every check. Keep what you've already announced in `visor.store` (see the GitHub example).

#### States

`status` and `state` take `"good"`, `"warn"`, `"bad"`, `"info"` or `"idle"`. Common words also work, so you can often pass an API's own value straight through:

| State | Colour | Also accepts |
|---|---|---|
| `good` | green | `ok`, `success`, `passed`, `done` |
| `warn` | amber | `warning`, `running`, `pending`, `in_progress`, `queued` |
| `bad` | red | `error`, `failure`, `failed`, `cancelled`, `timed_out` |
| `info` | blue | `new` |
| `idle` | grey | anything else |

### Network

```lua
local r = visor.http.get("https://api.github.com/user", {
  headers = { Accept = "application/vnd.github+json" },
  auth = "token",              -- adds "Authorization: Bearer <secret>"
  auth_host = "github.com",    -- which host's sign-in to use (default: the URL's host)
})
if r.status == 200 then
  visor.log("hello " .. r.json.login)
end
```

Plugins are **read-only**: they can look at services but never change anything, so there's `visor.http.get` and no POST, PUT or DELETE. `visor.http.get(url, options)` returns a table:

| Field | |
|---|---|
| `status` | The HTTP status, or 0 if the request couldn't be made (offline, timeout). |
| `body` | The response as a string. |
| `json` | The body decoded, when it's JSON. |
| `headers` | Lowercase header names. |
| `cached` | `true` when the server answered 304 and Visor returned the copy it kept. |

Options: `headers`, `auth` (a secret's name) and `auth_host`.

Only `https` URLs on a host listed in `hosts` work. Anything else raises an error that says which host to add. Requests time out after 20 seconds.

**Free repeat checks:** Visor keeps each GET's answer along with its `ETag` and `Last-Modified`, and sends them back next time. When nothing changed, the server answers 304 and you get the kept copy with `cached = true`. On GitHub, a 304 doesn't count against your rate limit.

### Secrets

Plugins never see a secret. `plugin.json` says how to read it and where it may be sent; Visor reads it, adds it to the request itself, and only for its own host:

```json
"secrets": {
  "token": "gh auth token --hostname {host}",
  "jenkins": { "command": "op read op://Dev/Jenkins/token", "hosts": ["ci.example.com"] }
}
```

```lua
visor.http.get("https://api.github.com/user", { auth = "token", auth_host = "github.com" })
visor.http.get("https://ci.example.com/api/json", { auth = "jenkins", auth_header = "X-Api-Key", auth_scheme = "" })
```

- **A `{host}` secret** (the string form, like `gh auth token`) is read for `auth_host` (default: the URL's host) and is only sent to that host or its subdomains: the github.com sign-in goes to `api.github.com`, never to another site.
- **Any other secret** needs the object form with `hosts`, and is only sent there. A secret that names no host is ignored.
- `auth_header` (default `Authorization`) and `auth_scheme` (default `Bearer`; `""` for the bare secret) shape the header.

Only commands that read a saved sign-in are allowed:

| Command | Example |
|---|---|
| `gh auth token …` | `gh auth token --hostname {host}` |
| `op read …` (1Password CLI) | `op read op://Dev/Jenkins/token` |
| `security find-generic-password …` / `find-internet-password …` | `security find-generic-password -s my-api -w` |

Visor runs the command without a shell, keeps the secret in memory for 30 minutes and never writes it to disk or hands it to the plugin.

### Data

| | |
|---|---|
| `visor.json.encode(value)` / `visor.json.decode(text)` | JSON. `decode` returns `nil` for text that isn't JSON. |
| `visor.store` | A table that is saved after every call and restored when the plugin starts. Numbers, strings, booleans and tables only. |
| `visor.settings` | `plugin.json`'s `settings`, with `settings.json` on top. |
| `visor.repos()` | The git repos your agents are working in right now: `{ host, owner, name, slug, branch, path }`. |
| `visor.log(...)` / `print(...)` | A line in the plugin's log. |

`visor.repos()` makes "what am I working on" plugins easy: Visor already knows which folders Claude Code, Copilot CLI and Antigravity sessions run in, and reads the `origin` remote and the branch from each one's `.git`. The GitHub example uses it to watch CI for exactly the branches your agents are on, with nothing to configure.

## Custom views

Rows are enough for a list. For more, build the plugin's section from Visor's own pieces with `visor.ui` and show it with `visor.view`. Visor draws every piece the way it draws its own Usage and Tokens tabs; you choose pieces and fill them with data, never fonts, sizes or pixel positions.

```lua
local ui = visor.ui
visor.view(ui.stack {
  ui.stats {
    ui.stat { value = "98%", label = "passed, last 14 runs", size = "large", state = "good" },
    ui.stat { value = "1", label = "failing now", state = "bad" },
  },
  ui.bars { values = { 4, 5, { 9, state = "bad" }, 4 }, labels = { "older", "latest" } },
  ui.list { { title = "api · main · test", status = "failure", url = "https://github.com/acme/api/actions" } },
  ui.buttons { ui.button { "Open in GitHub", url = "https://github.com/acme/api/actions", style = "primary" } },
})
```

`visor.view(tree)` replaces the plugin's section (use it instead of `visor.panel`, not with it). Positional values are written first: `ui.text { "Hello", style = "title" }`.

| Piece | Fields | Looks like |
|---|---|---|
| `ui.stack { ... }` | pieces, top to bottom | |
| `ui.columns { a, b, c }` | up to 3 pieces side by side | |
| `ui.divider()` | | the striped band between tools in Usage |
| `ui.text { "…", style = }` | `title`, `body` (default), `caption`, `mono`; `state` colours it | |
| `ui.stats { ui.stat{…}, … }` | stats in a row | the Tokens headline |
| `ui.stat { value =, label =, size = "large", state = }` | | one figure with a label |
| `ui.meter { title =, value = 0.38, text =, caption =, state = }` | `value` 0 to 1; `text` defaults to the percent | a Usage limit |
| `ui.bars { values = { … }, labels = { "first", "last" } }` | up to 60 numbers; `{ n, state = "bad" }` colours one | the spend chart |
| `ui.chips { "eu-west", { "us-east", state = "warn" } }` | up to 12 | Copilot's chips |
| `ui.list { row, … }` | rows as in `visor.panel` | |
| `ui.table { columns = { … }, rows = { { … } } }` | up to 6 columns, 30 rows | the Daily grid |
| `ui.clock { ["until"] = t }` or `{ since = t }` | `style = "large"` | a countdown or timer Visor ticks itself |
| `ui.progress { value = 0.4 }` | omit `value` while unknown | |
| `ui.buttons { ui.button { "…", url = }, ui.button { "…", action = } }` | up to 4; `style = "primary"` uses the accent | |
| `ui.picker { options = { "25", "50" }, selected =, action = }` | up to 6 | 7D / 30D / All |
| `ui.toggle { "Notify", on = true, action = }` | | the switches in Connected accounts |

A view holds at most 300 pieces, 8 levels deep. Past the panel's height the Plugins tab scrolls. A piece this Visor doesn't know shows "needs a newer Visor" in its place.

### Buttons, pickers and toggles

A button with `url` opens the link. A button, picker or toggle with `action` calls the plugin's handler, on its own queue:

```lua
visor.on("length", function(value)   -- the picked option, or the toggle's new state
  visor.store.length = tonumber(value)
  render()                           -- show the change
end)
```

The button spins while its handler runs, and a picker shows the new choice straight away. Plugins are read-only, so actions change what the plugin shows (a filter, a timer, a refresh) and never something outside Visor.

### Loading

Visor shows loading for you:

- **Before the first view:** grey placeholder lines under the plugin's name.
- **While a call runs:** the last view stays and a small spinner sits by the name. Nothing blanks out or jumps.
- **When a call fails:** the last view stays and the header says "couldn't refresh", with the error on hover. A plugin that has never shown anything shows the error instead.

When one part of a view comes later than the rest, give that piece `pending = true`. It's drawn as a still placeholder of its own shape (a dash for a stat, a grey bar for a meter, empty bars for a chart):

```lua
ui.bars { values = durations or {}, pending = durations == nil }
```

### Live without waking the plugin

`ui.clock` and row `time`s are counted by Visor, so a timer or "4m ago" stays current without running the plugin every second. Use `visor.every` (at least 30 seconds) only for checks.

## What shows where

| | Where | Use it for |
|---|---|---|
| Section | The Plugins tab (the puzzle piece right of the notch), once a plugin is installed | The full picture: rows, or a custom view. |
| Badge | The right side of the closed notch, next to the usage numbers | Something that stays true until it's fixed. |
| Peek | The closed notch, for 4 seconds | Something that just happened. |

## Keeping Visor idle

Visor is meant to use about 0% CPU when nothing is happening. Plugins keep that true:

- **No timers of your own.** `visor.every` is the only way to run later, at most every 30 seconds. Visor's timers have leeway, so macOS can wake up for several things at once.
- **Every call has an instruction budget.** A call that runs too long (a loop that never ends) is stopped with "took too long", and the plugin carries on with its next call.
- **Requests use the cache.** Pick an interval that matches how fast the thing changes: 60 to 120 seconds suits CI, and 300 suits a status page.
- **Showing is cheap.** Only the plugin's own part of the notch redraws, and only when you call `visor.panel`, `visor.badge` or `visor.peek`.

## The sandbox

Plugins get Lua's `string`, `table`, `math` and `utf8` libraries, and `os.time`, `os.date`, `os.clock` and `os.difftime`. They **don't** get `io`, `os.execute`, `os.getenv`, `require`, `load`, `dofile`, `debug`, `collectgarbage` or `string.dump`. They can't read files, run programs or load bytecode. The network is limited to the hosts in `plugin.json`, and secrets come only through the commands above. Plugins are read-only (GET requests only), and Visor sets limits so one can't hurt the rest of your Mac or the notch:

| Limit | |
|---|---|
| Memory | 64 MB of Lua per plugin; past it, "not enough memory" inside the plugin. |
| Time | An instruction budget per call, and a step limit on pattern matching. |
| Network | Only listed `https` hosts; redirects only to listed hosts, and without the sign-in when the host changes; answers up to 10 MB; 30 requests per call; no cookies. |
| Timers and handlers | 10 `visor.every` timers, 50 `visor.on` handlers. |
| Showing | One update to the notch per call; one peek per call and per 10 seconds. |
| Data | `visor.store` up to 1 MB; the log up to 1 MB per run. |
| Code | No `load`, bytecode, `debug`, or `__gc` finalizers. |

A plugin can still read what its hosts and sign-ins allow and show it in the notch, and it can send what it read to any host it lists. So look at a plugin's `hosts` and `secrets` before you install it, as you would with any app.

## Debugging

- **Log:** `~/Library/Logs/Visor/<id>.log` (or **Show Log** in the plugin's `…` menu). `visor.log` and `print` go there, and so does every error. Follow it live with `tail -f ~/Library/Logs/Visor/<id>.log`.
- **Errors** show in red under the plugin's name in the Plugins tab, with the file and line: `main.lua:12: attempt to index a nil value (field 'json')`.
- **Reload** by saving, or with **Reload** in the Plugins tab.
- **Turn a plugin off** from its `…` menu. It stays off until you turn it back on.
- **Saved data** lives in `~/Library/Application Support/Visor/PluginData/<id>.json`. Delete it to start fresh.

## Examples

Both are in the Visor repo under [`Plugins/`](../Plugins). Copy one into your Plugins folder to try it:

```sh
cp -R Plugins/hello Plugins/github Plugins/focus ~/Library/Application\ Support/Visor/Plugins/
```

- **[hello](../Plugins/hello/main.lua):** every building block with no network: a panel listing the repos your agents are in, a badge, a peek and a counter kept in `visor.store`.
- **[github](../Plugins/github/main.lua):** a custom view of GitHub Actions for the branches your agents are on (or the repos in `settings.json`): pass rate, failing runs and median build time, build-time bars, the latest run of each workflow, pull requests waiting for your review, and an Open in GitHub button. Works with github.com and GitHub Enterprise (`*.ghe.com`) through your `gh` sign-in. Shows a red badge while anything is failing, and peeks once per new failure.
- **[focus](../Plugins/focus/main.lua):** the interactive example: a focus timer with a 25 / 50 / 90 picker, Start, Pause and Reset buttons, a countdown Visor ticks itself, and this week's focus time as bars.
