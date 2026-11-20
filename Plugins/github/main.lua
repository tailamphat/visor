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

-- Which repos to watch: the settings, else where the agents are.
local function watched()
  local list = {}
  for _, entry in ipairs(visor.settings.repos or {}) do
    local host, owner, name = entry:match("^([^/]+)/([^/]+)/([^/]+)$")
    if not host then host = "github.com"; owner, name = entry:match("^([^/]+)/([^/]+)$") end
    if owner then table.insert(list, { host = host, owner = owner, name = name }) end
  end
  if #list == 0 then list = visor.repos() end
  return list
end

-- The newest run of each workflow, on the repo's branch when we know it.
local function latestRuns(repo)
  local path = "/repos/" .. repo.owner .. "/" .. repo.name .. "/actions/runs?per_page=20"
  if repo.branch then path = path .. "&branch=" .. urlencode(repo.branch) end
  local body = get(repo.host, path)
  if not body then return {} end
  local seen, runs = {}, {}
  for _, run in ipairs(body.workflow_runs or {}) do
    if not seen[run.workflow_id] then
      seen[run.workflow_id] = true
      table.insert(runs, run)
    end
  end
  return runs
end

local function check()
  local rows, failed = {}, 0
  local known = visor.store.failed or {}
  local now = {}

  for _, repo in ipairs(watched()) do
    for _, run in ipairs(latestRuns(repo)) do
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

  local sections = {}
  if #rows > 0 then table.insert(sections, { title = "Actions", rows = rows }) end

  local reviews = 0
  if visor.settings.reviews then
    local list = {}
    for _, host in ipairs(visor.settings.hosts or { "github.com" }) do
      local found = get(host, "/search/issues?per_page=10&q=" .. urlencode("is:open is:pr review-requested:@me archived:false"))
      for _, pr in ipairs(found and found.items or {}) do
        local repoName = (pr.repository_url or ""):match("([^/]+)$") or ""
        table.insert(list, { title = "#" .. pr.number .. " " .. pr.title, detail = repoName, status = "info",
                             url = pr.html_url, time = pr.updated_at })
      end
    end
    reviews = #list
    if reviews > 0 then table.insert(sections, { title = "Review requested", rows = list }) end
  end

  if #sections == 0 then
    local where = #watched() == 0 and "No repos to watch: start an agent in a GitHub repo, or set \"repos\" in settings.json"
      or "No failed runs, no reviews waiting"
    sections = { { title = "GitHub", rows = { { title = where, status = #watched() == 0 and "idle" or "good" } } } }
  end
  visor.panel(sections)
  if failed > 0 then
    visor.badge({ icon = "xmark.octagon.fill", count = failed > 1 and failed or nil, state = "bad", help = failed .. " failed workflow runs" })
  elseif reviews > 0 then
    visor.badge({ icon = "eye", count = reviews, state = "info", help = reviews .. " pull requests waiting for your review" })
  else
    visor.badge(nil)
  end
end

visor.every(120, check)
