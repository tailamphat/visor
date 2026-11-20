# Writing Visor plugins

A plugin watches something you care about (CI, pull requests, an on-call pager, a build server) and shows it in the notch: a **badge** on the closed notch, a short **peek** when something happens, and a **section** in the Plugins tab. Plugins are small [Lua 5.4](https://www.lua.org/manual/5.4/) files. Visor draws everything itself, so every plugin looks like part of Visor and none can slow it down.

- [Quick start](#quick-start)
- [How a plugin runs](#how-a-plugin-runs)
- [plugin.json](#pluginjson)
- [The `visor` API](#the-visor-api)
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
| `secrets` | | Name → the command that prints the secret. See [Secrets](#secrets). |
| `settings` | | Name → default value. Users override them in `settings.json`. |

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

`visor.http.get(url, options)` and `visor.http.post(url, options)` return a table:

| Field | |
|---|---|
| `status` | The HTTP status, or 0 if the request couldn't be made (offline, timeout). |
| `body` | The response as a string. |
| `json` | The body decoded, when it's JSON. |
| `headers` | Lowercase header names. |
| `cached` | `true` when the server answered 304 and Visor returned the copy it kept. |

Options: `headers`, `auth` (a secret's name) and `auth_host`. `post` also takes `body`: a string is sent as is, and a table is sent as JSON.

Only `https` URLs on a host listed in `hosts` work. Anything else raises an error that says which host to add. Requests time out after 20 seconds.

**Free repeat checks:** Visor keeps each GET's answer along with its `ETag` and `Last-Modified`, and sends them back next time. When nothing changed, the server answers 304 and you get the kept copy with `cached = true`. On GitHub, a 304 doesn't count against your rate limit.

### Secrets

Plugins never see where a secret is stored. `plugin.json` names a command that prints it, and Visor runs that command (without a shell) when the plugin asks:

```json
"secrets": { "token": "gh auth token --hostname {host}" }
```

```lua
local token = visor.secret("token", "github.com")   -- or use auth = "token" in visor.http
```

`{host}` is replaced with the host you pass. Only commands that read a saved sign-in are allowed:

| Command | Example |
|---|---|
| `gh auth token …` | `gh auth token --hostname {host}` |
| `op read …` (1Password CLI) | `op read op://Dev/Jenkins/token` |
| `security find-generic-password …` / `find-internet-password …` | `security find-generic-password -s my-api -w` |

Visor keeps a secret in memory for 30 minutes and never writes it to disk.

### Data

| | |
|---|---|
| `visor.json.encode(value)` / `visor.json.decode(text)` | JSON. `decode` returns `nil` for text that isn't JSON. |
| `visor.store` | A table that is saved after every call and restored when the plugin starts. Numbers, strings, booleans and tables only. |
| `visor.settings` | `plugin.json`'s `settings`, with `settings.json` on top. |
| `visor.repos()` | The git repos your agents are working in right now: `{ host, owner, name, slug, branch, path }`. |
| `visor.log(...)` / `print(...)` | A line in the plugin's log. |

`visor.repos()` makes "what am I working on" plugins easy: Visor already knows which folders Claude Code, Copilot CLI and Antigravity sessions run in, and reads the `origin` remote and the branch from each one's `.git`. The GitHub example uses it to watch CI for exactly the branches your agents are on, with nothing to configure.

## What shows where

| | Where | Use it for |
|---|---|---|
| Section | The Plugins tab (puzzle piece), once at least one plugin is installed | The full picture: every build, every PR. |
| Badge | The right side of the closed notch, next to the usage numbers | Something that stays true until it's fixed. |
| Peek | The closed notch, for 4 seconds | Something that just happened. |

## Keeping Visor idle

Visor is meant to use about 0% CPU when nothing is happening. Plugins keep that true:

- **No timers of your own.** `visor.every` is the only way to run later, at most every 30 seconds. Visor's timers have leeway, so macOS can wake up for several things at once.
- **Every call has an instruction budget.** A call that runs too long (a loop that never ends) is stopped with "took too long", and the plugin carries on with its next call.
- **Requests use the cache.** Pick an interval that matches how fast the thing changes: 60 to 120 seconds suits CI, and 300 suits a status page.
- **Showing is cheap.** Only the plugin's own part of the notch redraws, and only when you call `visor.panel`, `visor.badge` or `visor.peek`.

## The sandbox

Plugins get Lua's `string`, `table`, `math` and `utf8` libraries, and `os.time`, `os.date`, `os.clock` and `os.difftime`. They **don't** get `io`, `os.execute`, `os.getenv`, `require`, `load`, `dofile`, `debug`, `collectgarbage` or `string.dump`. They can't read files, run programs or load bytecode. The network is limited to the hosts in `plugin.json`, and secrets come only through the commands above. A plugin can still show whatever it likes in the notch, so install plugins you trust, as with any app.

## Debugging

- **Log:** `~/Library/Logs/Visor/<id>.log` (or **Show Log** in the plugin's `…` menu). `visor.log` and `print` go there, and so does every error. Follow it live with `tail -f ~/Library/Logs/Visor/<id>.log`.
- **Errors** show in red under the plugin's name in the Plugins tab, with the file and line: `main.lua:12: attempt to index a nil value (field 'json')`.
- **Reload** by saving, or with **Reload** in the Plugins tab.
- **Turn a plugin off** from its `…` menu. It stays off until you turn it back on.
- **Saved data** lives in `~/Library/Application Support/Visor/PluginData/<id>.json`. Delete it to start fresh.

## Examples

Both are in the Visor repo under [`Plugins/`](../Plugins). Copy one into your Plugins folder to try it:

```sh
cp -R Plugins/hello Plugins/github ~/Library/Application\ Support/Visor/Plugins/
```

- **[hello](../Plugins/hello/main.lua):** every building block with no network: a panel listing the repos your agents are in, a badge, a peek and a counter kept in `visor.store`.
- **[github](../Plugins/github/main.lua):** failed GitHub Actions runs for the branches your agents are on (or the repos in `settings.json`), and pull requests waiting for your review. Works with github.com and GitHub Enterprise (`*.ghe.com`) through your `gh` sign-in. Shows a red badge while anything is failing, and peeks once per new failure.
