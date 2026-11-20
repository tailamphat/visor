-- GitHub: failed Actions runs and review requests.
--
-- Repos: settings.repos ("owner/name" or "host/owner/name"), or else every
-- repo an agent is working in right now, on the branch it has checked out.
-- Sign-in: `gh auth login` for each host (github.com, your *.ghe.com).
-- Requests send If-None-Match, so a check that finds nothing new is free.

local function api(host)
  if host == "github.com" then return "https://api.github.com" end
  return "https://" .. host .. "/api/v3"
end

local function urlencode(text)
  return (text:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function get(host, path)
  local r = visor.http.get(api(host) .. path, {
    auth = "token",
    auth_host = host, -- the token for github.com, not api.github.com
    headers = { Accept = "application/vnd.github+json", ["X-GitHub-Api-Version"] = "2022-11-28" },
  })
  if r.status == 200 then return r.json end
  visor.log("GET " .. path .. " on " .. host .. " -> " .. r.status)
  return nil
end

-- Only GitHub: github.com and GitHub Enterprise (*.ghe.com). Agents also work
-- in GitLab, Azure DevOps and other repos; those are skipped.
local function isGitHub(host)
  return host == "github.com" or host:sub(-8) == ".ghe.com"
end

-- Which repos to watch: the settings, else where the agents are.
local function watched()
  local list = {}
  for _, entry in ipairs(visor.settings.repos or {}) do
    local host, owner, name = entry:match("^([^/]+)/([^/]+)/([^/]+)$")
    if not host then host = "github.com"; owner, name = entry:match("^([^/]+)/([^/]+)$") end
    if owner then table.insert(list, { host = host, owner = owner, name = name }) end
  end
  if #list == 0 then
    for _, repo in ipairs(visor.repos()) do
      if isGitHub(repo.host) then table.insert(list, repo) end
    end
  end
  return list
end

-- The newest run of each workflow, on the repo's branch when we know it, and
-- every run fetched (for the pass rate and build times).
local function latestRuns(repo)
  local path = "/repos/" .. repo.owner .. "/" .. repo.name .. "/actions/runs?per_page=20"
  if repo.branch then path = path .. "&branch=" .. urlencode(repo.branch) end
  local body = get(repo.host, path)
  if not body then return {}, {} end
  local seen, runs = {}, {}
  for _, run in ipairs(body.workflow_runs or {}) do
    if not seen[run.workflow_id] then
      seen[run.workflow_id] = true
      table.insert(runs, run)
    end
  end
  return runs, body.workflow_runs or {}
end

-- Minutes between a run's start and its last update.
local function minutes(run)
  local from, to = visor.isotime(run.run_started_at or ""), visor.isotime(run.updated_at or "")
  if from and to and to > from then return (to - from) / 60 end
  return nil
end

local function check()
  local ui = visor.ui
  local rows, recent, failed = {}, {}, 0
  local known = visor.store.failed or {}
  local now = {}
  local repos = watched()
  local link = nil

  for _, repo in ipairs(repos) do
    -- One repo failing (no access, renamed) doesn't stop the others.
    local ok, runs, all = pcall(latestRuns, repo)
    if not ok then visor.log(repo.host .. "/" .. repo.owner .. "/" .. repo.name .. ": " .. tostring(runs)); runs, all = {}, {} end
    for _, run in ipairs(all) do
      if run.status == "completed" then
        table.insert(recent, { time = run.updated_at or "", minutes = minutes(run), passed = run.conclusion == "success" })
      end
    end
    link = link or ("https://" .. repo.host .. "/" .. repo.owner .. "/" .. repo.name .. "/actions")
    for _, run in ipairs(runs) do
      local state = run.conclusion or run.status -- "failure", "success", "in_progress", ...
      table.insert(rows, {
        title = repo.name .. " · " .. (run.head_branch or "?") .. " · " .. run.name,
        detail = state,
        status = state,
        url = run.html_url,
        time = run.updated_at,
      })
      if run.conclusion == "failure" then
        failed = failed + 1
        local id = tostring(run.id)
        now[id] = true
        if not known[id] then
          visor.peek({ title = "CI failed on " .. (run.head_branch or repo.name), subtitle = repo.name .. " · " .. run.name, state = "bad", icon = "xmark.octagon" })
        end
      end
    end
  end
  visor.store.failed = now

  -- Failures first, then the rest by time.
  table.sort(rows, function(a, b)
    if (a.status == "failure") ~= (b.status == "failure") then return a.status == "failure" end
    return (a.time or "") > (b.time or "")
  end)

  local reviews = {}
  if visor.settings.reviews then
    for _, host in ipairs(visor.settings.hosts or { "github.com" }) do
      local found = get(host, "/search/issues?per_page=10&q=" .. urlencode("is:open is:pr review-requested:@me archived:false"))
      for _, pr in ipairs(found and found.items or {}) do
        local repoName = (pr.repository_url or ""):match("([^/]+)$") or ""
        table.insert(reviews, { title = "#" .. pr.number .. " " .. pr.title, detail = repoName, status = "info",
                                url = pr.html_url, time = pr.updated_at })
      end
    end
  end

  -- The view: figures, build times, the runs, the reviews, a link.
  local view = {}
  if #recent > 0 then
    table.sort(recent, function(a, b) return a.time < b.time end)
    local passed, bars, times = 0, {}, {}
    for i = math.max(1, #recent - 13), #recent do
      local r = recent[i]
      if r.passed then passed = passed + 1 end
      table.insert(bars, { r.minutes or 0, state = (not r.passed) and "bad" or nil })
      if r.minutes then table.insert(times, r.minutes) end
    end
    table.sort(times)
    local median = #times > 0 and times[math.ceil(#times / 2)] or nil
    local shown = math.min(14, #recent)
    table.insert(view, ui.stats {
      ui.stat { value = math.floor(passed / shown * 100 + 0.5) .. "%", label = "passed, last " .. shown .. (shown == 1 and " run" or " runs"), size = "large",
                state = passed < shown and "warn" or "good" },
      ui.stat { value = tostring(failed), label = "failing now", state = failed > 0 and "bad" or nil },
      ui.stat { value = median and (median < 1 and "<1m" or math.floor(median + 0.5) .. "m") or "—", label = "median build" },
    })
    table.insert(view, ui.bars { values = bars, labels = { "older", "latest" } })
  end
  if #rows > 0 then
    table.insert(view, ui.text { "Actions", style = "caption" })
    table.insert(view, ui.list(rows))
  end
  if #reviews > 0 then
    table.insert(view, ui.text { "Review requested", style = "caption" })
    table.insert(view, ui.list(reviews))
  end
  if #view == 0 then
    table.insert(view, ui.text { #repos == 0 and "No repos to watch: start an agent in a GitHub repo, or set \"repos\" in settings.json"
                                 or "No failed runs, no reviews waiting", style = "body", state = #repos == 0 and nil or "good" })
  end
  if link then
    table.insert(view, ui.buttons { ui.button { "Open in GitHub", url = link, style = "primary" } })
  end
  visor.view(ui.stack(view))

  if failed > 0 then
    visor.badge({ icon = "xmark.octagon.fill", count = failed > 1 and failed or nil, state = "bad", help = failed .. " failed workflow runs" })
  elseif #reviews > 0 then
    visor.badge({ icon = "eye", count = #reviews, state = "info", help = #reviews .. " pull requests waiting for your review" })
  else
    visor.badge(nil)
  end
end

visor.every(120, check)
