-- Hello: every building block, no network.
-- Copy this folder to ~/Library/Application Support/Visor/Plugins/ and open the
-- Plugins tab. Edit this file and Visor reloads it.

-- Runs once when the plugin starts: a random word to say hello, like Claude
-- Code's spinner.
visor.store.starts = (visor.store.starts or 0) + 1
local moods = {
  "Percolating", "Noodling", "Tinkering", "Doodling", "Conjuring", "Brewing",
  "Pondering", "Wiggling", "Simmering", "Booping", "Fiddling", "Moseying",
  "Daydreaming", "Scheming", "Whirring", "Bamboozling", "Sprouting", "Jiggling",
}
visor.peek({ title = moods[math.random(#moods)] .. "…", subtitle = "woken up " .. visor.store.starts .. " times so far", state = "info" })

local waved = false

local function refresh()
  local rows = {}
  for _, repo in ipairs(visor.repos()) do
    table.insert(rows, {
      title = repo.slug,
      detail = repo.branch or "detached",
      status = "info",
      url = "https://" .. repo.host .. "/" .. repo.slug,
    })
  end
  if #rows == 0 then
    table.insert(rows, { title = "No agents running in a git repo right now", status = "idle" })
  end

  visor.panel({
    { title = "Your agents are working in", rows = rows },
    { title = "This plugin", rows = {
        { title = "Started " .. visor.store.starts .. " times", status = "good", time = visor.now() },
        { title = "Visor's docs on writing plugins", status = "info",
          url = "https://github.com/tailamphat/visor/blob/main/docs/plugins.md" },
    } },
  })

  -- A badge on the closed notch for the first minute only, to show what one
  -- looks like. A real plugin keeps a badge only while something needs you.
  if not waved and #visor.repos() > 0 then
    visor.badge({ icon = "hand.wave", count = #visor.repos(), state = "info", help = "Repos your agents are in" })
    waved = true
  else
    visor.badge(nil)
  end
end

-- Runs now, then every 60 seconds (never more often than every 30).
visor.every(60, refresh)
