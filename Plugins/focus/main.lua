-- Focus: a timer with a picker, buttons and a week of focus time, drawn with
-- Visor's design system: a section header with a badge, and a "good" banner
-- that offers a break when a session ends.
-- The countdown is drawn by Visor (ui.clock), so the plugin only wakes every
-- 30 seconds to notice a session that has finished.

local ui = visor.ui
local s = visor.store
s.length = s.length or visor.settings.length or 50  -- minutes
s.days = s.days or {}                                -- "2026-11-20" -> minutes

local function today(t) return os.date("%Y-%m-%d", t or os.time()) end

local function format(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function finish()
  s.days[today()] = (s.days[today()] or 0) + s.length
  s.endsAt, s.left = nil, nil
  s.breakAt = os.time()
  visor.peek({ title = "Focus done: " .. s.length .. " minutes", subtitle = "Time for a break", state = "good", icon = "checkmark.circle" })
end

local function render()
  if s.endsAt and os.time() >= s.endsAt then finish() end
  if s.breakAt and os.time() - s.breakAt > 15 * 60 then s.breakAt = nil end

  -- This week, oldest first.
  local week, total = {}, 0
  for i = 6, 0, -1 do
    local m = s.days[today(os.time() - i * 86400)] or 0
    total = total + m
    table.insert(week, m)
  end

  local timer
  if s.endsAt then
    timer = ui.clock { ["until"] = s.endsAt, style = "large" }
  else
    timer = ui.stat { value = format(s.left or s.length * 60), label = s.left and "paused" or "ready", size = "large" }
  end

  local done = s.days[today()] or 0
  visor.view(ui.stack {
    ui.columns {
      ui.stack {
        timer,
        ui.text { s.endsAt and ("until " .. os.date("%H:%M", s.endsAt) .. " · " .. done .. " min today") or (done .. " min of focus today"), style = "caption" },
      },
      ui.stack {
        ui.header { "This week", badge = math.floor(total / 6) / 10 .. " h" },
        ui.bars { values = week, labels = { os.date("%a", os.time() - 6 * 86400), "Today" } },
      },
    },
    ui.columns {
      ui.picker { options = { "25", "50", "90" }, selected = tostring(s.length), action = "length" },
      ui.buttons {
        ui.button { "Reset", action = "reset" },
        s.endsAt and ui.button { "Pause", action = "pause" } or ui.button { s.left and "Resume" or "Start", action = "start", style = "primary" },
      },
    },
    s.breakAt and ui.banner {
      tint = "good", badge = "Done", title = "Time for a break", dismiss = "dismissBreak",
      text = s.length .. " minutes of focus. Stand up, look away, drink some water.",
    } or nil,
  })
  visor.badge(s.endsAt and { icon = "timer", state = "info", help = "Focus until " .. os.date("%H:%M", s.endsAt) } or nil)
end

visor.on("length", function(value)
  s.length = tonumber(value) or s.length
  if not s.endsAt then s.left = nil end
  render()
end)

visor.on("dismissBreak", function()
  s.breakAt = nil
  render()
end)

visor.on("start", function()
  s.breakAt = nil
  s.endsAt = os.time() + (s.left or s.length * 60)
  s.left = nil
  render()
end)

visor.on("pause", function()
  if s.endsAt then s.left = math.max(0, s.endsAt - os.time()); s.endsAt = nil end
  render()
end)

visor.on("reset", function()
  s.endsAt, s.left = nil, nil
  render()
end)

-- Notice a finished session (render does); the clock itself ticks in Visor.
visor.every(30, render)
