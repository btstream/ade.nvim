-- Teams: the front end's half of the service-owned team bus (PROTOCOL.md 18).
--
-- The service owns the bus, participants, delivery and limits. This module
-- turns the configuration into `team.configure`, injects the leader's MCP
-- server into session/new|load|resume, binds the leader, keeps the inbox and
-- team list warm, and exposes the methods the panel uses.
local log = require("ade.log")
local Resolve = require("ade.manager.resolve")
local State = require("ade.session.state")
local reducer = require("ade.session.reducer")
local async = require("ade.async")
local transport = require("ade.service.transport")

local M = {}

---Message for a failed team request, including git's stderr when present.
---@param value any
---@return string
function M.error_text(value)
  local message = type(value) == "table" and (value.message or value.code) or tostring(value)
  if type(value) == "table" and type(value.data) == "table" then
    local stderr = value.data.stderr
    if type(stderr) == "string" and stderr ~= "" then
      return tostring(message) .. ": " .. stderr
    end
  end
  return tostring(message)
end

local Team = {}
Team.__index = Team

---@param opts {config: fun(): table, connection: fun(): table|nil,
---  resolve_cwd: fun(): string, store: fun(): table|nil,
---  notify: fun(message: string, level: integer|nil),
---  on_changed: fun(), on_inbox: fun(item: table)|nil,
---  on_watch: fun(session: table|nil, title: string|nil)|nil,
---  runtime: fun(): table|nil}
---@return table
function M.new(opts)
  local self = setmetatable({
    config = opts.config,
    connection = opts.connection,
    resolve_cwd = opts.resolve_cwd,
    store = opts.store,
    notify = opts.notify or function() end,
    on_changed = opts.on_changed or function() end,
    on_inbox = opts.on_inbox,
    on_watch = opts.on_watch,
    on_turn = opts.on_turn,
    get_runtime = opts.runtime,
    teams = {},
    inbox = {},
    -- cwd -> the exact config sent (so a rebuild/hello can re-send it).
    sent_config = {},
    resolved_config = {},
    configure_inflight = {},
    warned_skipped = {},
    pending_bind = {},
    -- instance+cwd -> {instance, cwd, token_id} while a leader token is unused.
    leader_pending = {},
    -- cwd -> true while a leader_server request is in flight for this cwd.
    leader_inflight = {},
    -- cwd -> {instance, session_id, team} once this front end's leader binds.
    bound = {},
    -- cwd -> true when another session already leads that team (-32061).
    blocked = {},
    warned_blocked = {},
    -- cwd -> team id when team.list showed a suspended team for it.
    suspended_cwd = {},
    warned_suspended = {},
    notified = {},
    -- team id -> true once this front end started the enabled workflow.
    enabled_teams = {},
    -- team id -> {board, inflight, again, seq} for the board cache (19.2).
    boards = {},
    -- team id -> the board_rev whose fetch was already attempted (19.2): a
    -- failed or unavailable board must not be refetched on every team.changed.
    board_requested = {},
    watching = nil,
    raw = nil,
  }, Team)
  return self
end

---@return table|nil
function Team:_raw()
  local app = self.connection()
  if not app or type(app.service_connection) ~= "function" then
    return nil
  end
  local ok, raw = pcall(app.service_connection, app)
  if not ok or type(raw) ~= "table" then
    return nil
  end
  return raw
end

---Whether this editor should use service teams at all.
---@return boolean
function Team:available()
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  if cfg.backend == "direct" or teams.spawn_from_chat == false then
    return false
  end
  -- A team needs at least one template; without one nothing is injected and
  -- the single-agent experience is untouched.
  if next(teams.templates or {}) == nil then
    return false
  end
  local raw = self:_raw()
  if not raw then
    return false
  end
  self:_attach(raw)
  return raw:is_connected() and raw:has_feature("teams")
end

---@param raw table
function Team:_attach(raw)
  if self.raw == raw then
    return
  end
  self.raw = raw
  self.sent_config = {}
  if type(raw.on_hello) == "function" then
    raw:on_hello("teams", function()
      self:on_hello()
    end)
  end
  if type(raw.subscribe) == "function" then
    raw:subscribe("teams", "team.changed", function(payload)
      self:on_changed_payload(payload)
    end)
    raw:subscribe("teams", "team.inbox", function(payload)
      self:on_inbox_payload(payload)
    end)
    raw:subscribe("teams", "team.board_changed", function(payload)
      self:on_board_changed_payload(payload)
    end)
    raw:subscribe("teams", "__disconnected", function()
      self:forget_connection()
    end)
  end
end

---Forget connection-scoped state; stored teams stay visible.
function Team:forget_connection()
  for _, team in pairs(self.teams) do
    if type(team) == "table" then
      team.stale = true
    end
  end
  self.leader_pending = {}
  self.leader_inflight = {}
  local inflight_config = self.configure_inflight
  self.configure_inflight = {}
  for _, entry in pairs(inflight_config or {}) do
    for _, waiter in ipairs(entry.waiters or {}) do
      pcall(waiter, false, "the service connection was lost")
    end
  end
  self.sent_config = {}
  self.bound = {}
  self.blocked = {}
  self.suspended_cwd = {}
  -- A board request that was in flight when the connection died may still
  -- call back; bumping its token makes that late reply a no-op while the next
  -- `team.changed` can start a fresh request.
  for _, entry in pairs(self.boards) do
    if type(entry) == "table" then
      entry.seq = (entry.seq or 0) + 1
      entry.inflight = false
      entry.again = false
    end
  end
  -- A reconnect may reach a different service; let revisions be tried again.
  self.board_requested = {}
  -- `warned_blocked` / `warned_suspended` / `notified` survive a reconnect:
  -- a conflict that was already announced must not be announced again.
  self:unwatch(true)
  self:changed()
end

---Forget everything, including the team list (service gone/teams unavailable).
function Team:reset()
  self.teams = {}
  self.inbox = {}
  self.enabled_teams = {}
  self.boards = {}
  self:forget_connection()
end

---A service restart leaves teams suspended until their leader session returns.
function Team:on_hello()
  -- A new handshake may be a newer service.
  self.old_service = false
  self.warned_old_service = false
  self:forget_connection()
  local cwd = self.resolve_cwd and self.resolve_cwd() or nil
  if cwd then
    self:configure(cwd, true)
  end
  self:refresh()
  -- Warm the workflow cache for completion; failure only means the list stays
  -- as it was, never an error the person has to read.
  self:refresh_workflows()
end

---Whether a known team is suspended (waiting for its leader session).
---@param team_id string|nil
---@return boolean
function Team:is_suspended(team_id)
  local team = type(team_id) == "string" and self.teams[team_id] or nil
  return type(team) == "table" and team.state == "suspended"
end

---Whether a team is from before a lost connection and not refreshed yet.
---@param team_id string|nil
---@return boolean
function Team:is_stale(team_id)
  local team = type(team_id) == "string" and self.teams[team_id] or nil
  return type(team) == "table" and team.stale == true
end

---The absolute directory the service creates worker worktrees under (18.12).
---@return string
function M.worktree_root()
  local path = vim.fn.stdpath("data") .. "/ade/worktrees"
  path = vim.fn.fnamemodify(path, ":p")
  if #path > 1 then
    path = path:gsub("/+$", "")
  end
  return path
end

---Resolve the configuration the service expects (18.2, 19.1).
---@param cwd string
---@return table|nil config
---@return table|nil skipped
function Team:service_config(cwd)
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  local store = self.store and self.store() or nil
  local agents = require("ade.agents")
  local templates, skipped = {}, {}
  for name, template in pairs(teams.templates or {}) do
    local launch, err = Resolve.resolve(cfg, template.agent, cfg.launch_origin, store)
    if not launch then
      skipped[#skipped + 1] = string.format("%s: %s", name, tostring(err))
    else
      local key = { agent = template.agent, command = launch.command, args = launch.args or {} }
      local models = template.models
      if type(models) == "table" and #models == 0 then
        models = nil
      end
      local profile = agents.get(cfg.agents and cfg.agents[template.agent] or nil, template.agent)
      local entry = {
        key = key,
        env = transport.child_env(launch.env or (cfg.agents[template.agent] or {}).env),
        model = template.model,
        role = template.role or "",
        models = models,
        -- pi reaches MCP tools through its own `mcp` proxy (19.6).
        tool_style = profile and profile.name == "pi" and "mcp_proxy" or "direct",
        worktree = template.worktree == true,
      }
      if launch.source == "managed" and launch.install_id then
        entry.launch = {
          root = Resolve.manager_root(cfg),
          agent = template.agent,
          installId = launch.install_id,
        }
      end
      templates[name] = entry
    end
  end
  local confirm = type(teams.spawn_confirm) == "table" and teams.spawn_confirm or {}
  local limits = type(teams.limits) == "table" and teams.limits or {}
  local workflows = {}
  for name, workflow in pairs(teams.workflows or {}) do
    local copy = vim.deepcopy(workflow)
    if type(copy.leader) == "table" and next(copy.leader) == nil then
      -- An empty Lua table encodes as `[]`; `leader` must be an object.
      copy.leader = nil
    end
    if type(copy.summary) ~= "string" or copy.summary == "" then
      -- 19.1 requires a summary on the wire; a config entry may rely on its
      -- text's first line instead (the draft's `default = { text = ... }`).
      local first = tostring(copy.text or ""):match("^[^\r\n]*") or ""
      first = vim.trim(first)
      if vim.fn.strchars(first) > 120 then
        first = vim.fn.strcharpart(first, 0, 120)
      end
      copy.summary = first ~= "" and first or name
    end
    workflows[name] = copy
  end
  return {
    max_workers = teams.max_workers or 3,
    worktree_root = M.worktree_root(),
    spawn_confirm = { auto = vim.deepcopy(confirm.auto or {}) },
    limits = {
      max_turns_per_task = limits.max_turns_per_task or 30,
      max_turns_total = limits.max_turns_total or 200,
    },
    templates = next(templates) and templates or vim.empty_dict(),
    -- An empty Lua table encodes as a JSON array; the service expects an
    -- object for `workflows` (19.1).
    workflows = next(workflows) and workflows or vim.empty_dict(),
    default_workflow = teams.default,
  },
    skipped
end

---Whether at least one template resolves to a launchable agent.
---@param cwd string
---@return boolean
function Team:has_usable_templates(cwd)
  local config = self:service_config(cwd)
  return config ~= nil and next(config.templates or {}) ~= nil
end

local function pending_key(instance, cwd)
  return tostring(instance) .. "\0" .. tostring(cwd)
end

---Send `team.configure` for a cwd when the resolved config changed.
---@param cwd string
---@param force boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:configure(cwd, force, cb)
  cb = cb or function() end
  if not self:available() then
    cb(false, "teams are not available")
    return
  end
  local config, skipped = self:service_config(cwd)
  local changed = not vim.deep_equal(config, self.resolved_config[cwd])
  if changed then
    -- A new configuration is a fresh reason to explain its broken templates.
    self.warned_skipped[cwd] = {}
    self.resolved_config[cwd] = config
  end
  local warned = self.warned_skipped[cwd] or {}
  for _, problem in ipairs(skipped or {}) do
    -- The same name+error is announced once per configuration, not on every
    -- hello/reconcile pass.
    if not warned[problem] then
      warned[problem] = true
      self.notify("team template skipped: " .. problem, vim.log.levels.WARN)
    end
  end
  self.warned_skipped[cwd] = warned
  if next(config.templates or {}) == nil then
    -- Every template failed to resolve: behave as if teams were unavailable.
    self.sent_config[cwd] = nil
    cb(false, "no usable team templates")
    return
  end
  if not force and vim.deep_equal(config, self.sent_config[cwd]) then
    cb(true, nil)
    return
  end
  local inflight = self.configure_inflight[cwd]
  if inflight then
    -- Two hello listeners can race, and a leader_server arriving while the
    -- hello configure is still in flight must wait for its real result: it
    -- cannot inject a leader before the service has the configuration.
    inflight.waiters[#inflight.waiters + 1] = cb
    return
  end
  inflight = { waiters = { cb } }
  self.configure_inflight[cwd] = inflight
  local raw = self:_raw()
  raw:request_tracked("team.configure", { cwd = cwd, config = config }, function(ok, value)
    if self.configure_inflight[cwd] == inflight then
      self.configure_inflight[cwd] = nil
    end
    if ok then
      self.sent_config[cwd] = config
    else
      local message = type(value) == "table" and (value.message or value.code) or tostring(value)
      log.warn("team.configure failed: %s", tostring(message))
    end
    for _, waiter in ipairs(inflight.waiters) do
      pcall(waiter, ok, value)
    end
  end)
end

---Ask for the leader's MCP server before session/new|load|resume.
---@param instance string|nil
---@param cwd string
---@return table|nil server
function Team:leader_server(instance, cwd)
  if not self:available() or not instance then
    return nil
  end
  local bound = self.bound[cwd]
  if bound and bound.instance == instance then
    -- This instance already leads the team for cwd; a second session does not
    -- become another leader.
    return nil
  end
  if self.blocked[cwd] then
    return nil
  end
  -- Concurrent session/new|load|resume for the same cwd must not each ask
  -- for (and inject) a leader server.
  if self.leader_inflight[cwd] then
    return nil
  end
  -- Every template failed to resolve: nothing to configure or inject.
  if not self:has_usable_templates(cwd) then
    return nil
  end
  local key = pending_key(instance, cwd)
  -- No stale token may bind a session whose request never completed.
  self.leader_pending[key] = nil
  local inflight = {}
  self.leader_inflight[cwd] = inflight
  local finished = false
  local function done(server)
    if not finished then
      finished = true
      if self.leader_inflight[cwd] == inflight then
        self.leader_inflight[cwd] = nil
      end
    end
    return server
  end
  -- Backstop if an unexpected error unwinds before `done` runs; the identity
  -- check keeps a stale finalizer from clearing a newer request.
  async.finally(function()
    if self.leader_inflight[cwd] == inflight then
      self.leader_inflight[cwd] = nil
    end
  end)
  -- A reconnect empties `bound`; ask the service who leads this cwd before
  -- injecting a second leader server for the same instance.
  local listed_ok, listed = async.await(function(settled)
    local raw = self:_raw()
    if not raw then
      settled(false, nil)
      return
    end
    raw:request_tracked("team.list", {}, function(ok, value)
      settled(ok, value)
    end)
  end)
  if listed_ok and type(listed) == "table" and type(listed.teams) == "table" then
    for _, entry in ipairs(listed.teams) do
      if entry.cwd == cwd and type(entry.leader) == "table" then
        if entry.state == "suspended" then
          -- PROTOCOL.md 18.15: a suspended team may be resumed by any instance
          -- whose session cwd matches; leader.instance is null, never a conflict.
          self.suspended_cwd[cwd] = entry.id
        elseif entry.leader.instance == instance then
          self.suspended_cwd[cwd] = nil
          self.bound[cwd] = { instance = instance, session_id = entry.leader.sessionId, team = entry.id }
          return done(nil)
        elseif entry.leader.instance ~= nil then
          self.suspended_cwd[cwd] = nil
          self.blocked[cwd] = true
          if not self.warned_blocked[cwd] then
            self.warned_blocked[cwd] = true
            self.notify("a team already exists for this cwd; close it before starting another", vim.log.levels.WARN)
          end
          return done(nil)
        end
      end
    end
  end
  local ok, result = async.await(function(settled)
    self:configure(cwd, false, function(ok)
      if not ok then
        settled(false, nil)
        return
      end
      local raw = self:_raw()
      raw:request_tracked("team.leader_server", { instance = instance, cwd = cwd }, function(ok2, value)
        if not ok2 and type(value) == "table" and value.code == -32061 then
          -- Another session already leads that cwd's team; a single-agent
          -- session must not be injected with a leader server.
          self.blocked[cwd] = true
        end
        settled(ok2, value)
      end)
    end)
  end)
  if not ok or type(result) ~= "table" or type(result.server) ~= "table" then
    return done(nil)
  end
  self.leader_pending[key] = {
    instance = instance,
    cwd = cwd,
    token_id = result.token_id,
  }
  return done(result.server)
end

---Bind the leader after session/new|load|resume succeeded.
---@param instance string|nil
---@param session_id string
---@param cwd string
function Team:bind_leader(instance, session_id, cwd)
  local key = pending_key(instance, cwd)
  local pending = self.leader_pending[key]
  if not pending or pending.instance ~= instance or pending.cwd ~= cwd then
    return
  end
  self.leader_pending[key] = nil
  local raw = self:_raw()
  if not raw then
    return
  end
  raw:request_tracked("team.bind_leader", {
    instance = instance,
    sessionId = session_id,
    token_id = pending.token_id,
  }, function(ok, value)
    if not ok then
      local message = type(value) == "table" and (value.message or value.code) or tostring(value)
      log.warn("team.bind_leader failed: %s", tostring(message))
      if type(value) == "table" and value.code == -32061 then
        if self.suspended_cwd[cwd] then
          -- The restored session is not the stored leader; the team stays
          -- suspended and the person can close it from the panel.
          if not self.warned_suspended[cwd] then
            self.warned_suspended[cwd] = true
            self.notify(
              "the team for this cwd is still suspended; open :Ade team and press x to close it",
              vim.log.levels.WARN
            )
          end
        else
          self.blocked[cwd] = true
          if not self.warned_blocked[cwd] then
            self.warned_blocked[cwd] = true
            self.notify(
              "another session already leads this team: " .. tostring(value.message or ""),
              vim.log.levels.WARN
            )
          end
        end
      end
      return
    end
    local team_id = type(value) == "table" and type(value.team) == "table" and value.team.id or nil
    self.bound[cwd] = { instance = instance, session_id = session_id, team = team_id }
    self:refresh()
    self:start_enabled_workers(team_id, type(value) == "table" and value.team or nil)
  end)
end

---Start the enabled default workflow once per team (19.7).
---
---`teams.enabled = true` replaces the per-worker `team.spawn` loop: the
---service starts the workflow's members and skips names that already exist, so
---a re-bind, a reconnect or a second front end never starts them twice.
---@param team_id string|nil
---@param entry table|nil team.list entry returned by bind_leader
function Team:start_enabled_workers(team_id, entry)
  if type(team_id) ~= "string" then
    return
  end
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  if teams.enabled ~= true then
    return
  end
  local team = self.teams[team_id]
  local cwd = team and team.cwd or (type(entry) == "table" and entry.cwd or nil)
  local bound = cwd and self.bound[cwd] or nil
  if not bound or bound.team ~= team_id then
    -- Another front end leads this team (or it belongs to another cwd): its
    -- workflow is not this front end's to start.
    return
  end
  if cwd and require("ade.app.team_start").active(cwd) then
    -- `:Ade team start` is picking a workflow for this cwd: its own team.start
    -- must not be pre-empted by the configured default. Remember the decision
    -- even if that flow is cancelled: the person already chose a workflow, so
    -- the default must not start behind their back later.
    self.enabled_teams[team_id] = true
    return
  end
  if type(entry) == "table" and entry.state == "suspended" then
    -- A resume still waiting for its configuration cannot take team.start; do
    -- not mark the team so the active `team.changed` can try later.
    return
  end
  if self.enabled_teams[team_id] then
    return
  end
  for _, participant in ipairs(type(entry) == "table" and entry.participants or {}) do
    if participant.name ~= "leader" and participant.name ~= "human" then
      -- The team already has a worker: this is not its first start.
      return
    end
  end
  self.enabled_teams[team_id] = true
  local workflow = teams.default or "default"
  self:start(team_id, workflow, nil, function(ok, value)
    if not ok then
      self.notify("could not start workflow " .. tostring(workflow) .. ": " .. M.error_text(value), vim.log.levels.WARN)
    end
    self:refresh()
  end)
end

---Refresh the whole team list.
---@param cb fun()|nil
function Team:refresh(cb)
  if not self:available() then
    self.teams = {}
    self.inbox = {}
    self:changed()
    if cb then
      cb()
    end
    return
  end
  local raw = self:_raw()
  raw:request_tracked("team.list", {}, function(ok, value)
    if ok and type(value) == "table" and type(value.teams) == "table" then
      local teams = {}
      for _, team in ipairs(value.teams) do
        teams[team.id] = team
      end
      -- Keep open items announced by `team.inbox` when an older snapshot does
      -- not list them yet: the list and the notification stream race.
      local announced = {}
      for id, item in pairs(self.inbox) do
        if item.state == "open" then
          announced[id] = item
        end
      end
      self.teams = teams
      self.inbox = {}
      for id, team in pairs(teams) do
        for _, item in ipairs(team.inbox or {}) do
          item.team = item.team or id
          self.inbox[item.id] = item
          if item.state == "open" then
            -- Items first seen through refresh were already announced by the
            -- service; do not notify them again after a reconnect.
            self.notified[item.id] = item.team
          end
        end
      end
      for id, item in pairs(announced) do
        if self.inbox[id] == nil and teams[item.team] ~= nil then
          self.inbox[id] = item
        end
      end
      self:changed()
    else
      -- A failed refresh means the stored list can no longer be trusted.
      self.teams = {}
      self.inbox = {}
      self:changed()
    end
    self:_sync_boards()
    if cb then
      cb()
    end
  end)
end

---Fetch the board of `team` when its cached revision is stale (19.2).
function Team:_fetch_board_if_needed(team)
  local rev = tonumber(type(team) == "table" and team.board_rev or nil)
  if rev == nil or self.old_service then
    return
  end
  local cached = self.boards[team.id]
  if cached and type(cached.board) == "table" and tonumber(cached.board.rev) == rev then
    return
  end
  if self.board_requested[team.id] == rev then
    -- Already tried this revision (a failure or an unavailable board waits for
    -- the next `team.board_changed`).
    return
  end
  self.board_requested[team.id] = rev
  self:request_board(team.id)
end

---Ask for the board of every known team whose cached revision is stale (19.2).
function Team:_sync_boards()
  if self.old_service then
    return
  end
  for _, team in pairs(self.teams) do
    self:_fetch_board_if_needed(team)
  end
end

---The cached board of a team (19.2), or nil before the first fetch.
---@param team_id string
---@return table|nil
function Team:board(team_id)
  local entry = self.boards[team_id]
  return type(entry) == "table" and entry.board or nil
end

---Fetch `team.board` once per team at a time.
---
---A `team.board_changed` that arrives while a request is in flight sets a latch;
---the request's completion then fetches the current revision once more, so the
---cache ends up at the latest state, never at an intermediate one.
---@param team_id string
---@param cb fun(ok: boolean, board: table|nil)|nil
function Team:request_board(team_id, cb)
  cb = cb or function() end
  if type(team_id) ~= "string" then
    cb(false, nil)
    return
  end
  if self.old_service then
    -- An api-5 service has no team.board; never retry it in a loop.
    cb(false, nil)
    return
  end
  local entry = self.boards[team_id]
  if type(entry) ~= "table" then
    entry = { board = nil, inflight = false, again = false, seq = 0 }
    self.boards[team_id] = entry
  end
  if entry.inflight then
    entry.again = true
    return
  end
  if not self:available() then
    cb(false, nil)
    return
  end
  entry.inflight = true
  -- A per-request token: a reply that arrives after the team was closed, the
  -- cache reset or the connection dropped must not touch a newer request.
  entry.seq = (entry.seq or 0) + 1
  local seq = entry.seq
  self:_call("team.board", { team = team_id }, function(ok, value)
    if self.boards[team_id] ~= entry or entry.seq ~= seq then
      cb(ok, nil)
      return
    end
    entry.inflight = false
    if ok and type(value) == "table" and type(value.board) == "table" then
      entry.board = value.board
      self:changed()
    end
    cb(ok, ok and entry.board or nil)
    if entry.again then
      entry.again = false
      self:request_board(team_id)
    end
  end)
end

function Team:changed()
  pcall(self.on_changed)
end

---@param payload table
function Team:on_changed_payload(payload)
  local team = type(payload) == "table" and (payload.team or payload) or nil
  if type(team) ~= "table" or type(team.id) ~= "string" then
    return
  end
  if team.state == "closed" then
    self:forget_team(team.id)
    for cwd, id in pairs(self.suspended_cwd) do
      if id == team.id then
        self.suspended_cwd[cwd] = nil
        self.warned_suspended[cwd] = nil
      end
    end
    for cwd, entry in pairs(self.bound) do
      if entry.team == team.id or team.cwd == cwd then
        self.bound[cwd] = nil
      end
    end
    for cwd in pairs(self.blocked) do
      if team.cwd == cwd then
        self.blocked[cwd] = nil
        self.warned_blocked[cwd] = nil
      end
    end
    if self.watching and self.watching.team_id == team.id then
      -- The team is gone; there is nothing left to unwatch on the service.
      self:unwatch(true)
    end
  else
    self.teams[team.id] = team
    if team.state ~= "suspended" then
      for cwd, id in pairs(self.suspended_cwd) do
        if id == team.id then
          self.suspended_cwd[cwd] = nil
          self.warned_suspended[cwd] = nil
        end
      end
    end
    -- A team created after the cache was cleared (or a reconnect) gets its
    -- board when its revision differs from the cache.
    self:_fetch_board_if_needed(team)
    -- A suspended team may become active later; then the enabled workflow can
    -- start (still at most once per team).
    if team.state ~= "suspended" then
      self:start_enabled_workers(team.id, team)
    end
  end
  self:changed()
end

---@param payload table
function Team:on_inbox_payload(payload)
  local item = type(payload) == "table" and (payload.item or payload) or nil
  if type(item) ~= "table" or type(item.id) ~= "string" then
    return
  end
  local fresh = self.inbox[item.id] == nil and item.state == "open"
  self.inbox[item.id] = item
  if fresh and self.notified[item.id] ~= item.team then
    self.notified[item.id] = item.team
    local message = string.format("team inbox: %s from %s", tostring(item.kind), tostring(item.from))
    self.notify(message, vim.log.levels.INFO)
  end
  if self.on_inbox then
    pcall(self.on_inbox, item)
  end
  self:changed()
end

---@param payload table
function Team:on_board_changed_payload(payload)
  local team_id = type(payload) == "table" and (payload.team or (payload.board and payload.board.id)) or nil
  if type(team_id) ~= "string" then
    return
  end
  if self.old_service or not self.teams[team_id] then
    -- An api-5 service has no board, and a late notification for a closed (or
    -- not yet listed) team must not recreate its cache entry.
    return
  end
  local entry = self.boards[team_id]
  if type(entry) == "table" and type(entry.board) == "table" then
    local rev = tonumber(payload.rev)
    if rev ~= nil and tonumber(entry.board.rev) == rev then
      -- Already at this revision (a duplicate notification).
      return
    end
  end
  -- A real notification is a fresh reason to fetch, even when an earlier
  -- revision failed.
  self.board_requested[team_id] = nil
  self:request_board(team_id)
end

---Every team, flattened for the panel.
---@return table[]
function Team:list_rows()
  local out = {}
  for _, team in pairs(self.teams) do
    out[#out + 1] = team
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---@param item_id string
---@return table|nil
function Team:item(item_id)
  return self.inbox[item_id]
end

---@param team_id string
---@return table|nil
function Team:team(team_id)
  return self.teams[team_id]
end

---@param team_id string
---@return table|nil
function Team:participant(team_id, name)
  local team = self.teams[team_id]
  for _, entry in ipairs(team and team.participants or {}) do
    if entry.name == name then
      return entry
    end
  end
end

---Methods that only exist at api_version 6 (19.5/19.7). An older service
---answers -32601 for them; that is a version problem, not a bug in the call.
local NEW_METHODS = {
  ["team.start"] = true,
  ["team.answer_group"] = true,
  ["team.board"] = true,
  ["team.card_history"] = true,
  ["team.workflows"] = true,
  ["team.workflow_delete"] = true,
}

---Explain that the running service predates boards/workflows, once.
function Team:_warn_old_service()
  if self.warned_old_service then
    return
  end
  self.warned_old_service = true
  self.notify(
    "the running service is too old for team boards and workflows; "
      .. "it restarts automatically when idle, or run :Ade service stop",
    vim.log.levels.WARN
  )
end

---@param method string
---@param params table
---@param cb fun(ok: boolean, value: any)|nil
function Team:_call(method, params, cb)
  cb = cb or function() end
  if not self:available() then
    cb(false, "teams are not available")
    return
  end
  local raw = self:_raw()
  raw:request_tracked(method, params, function(ok, value)
    if not ok and type(value) == "table" and value.code == -32601 and NEW_METHODS[method] then
      self.old_service = true
      self:_warn_old_service()
      value = {
        code = -32601,
        message = "the running service is too old for "
          .. method
          .. "; it restarts automatically when idle, or run :Ade service stop",
        data = { old_service = true, method = method },
      }
    end
    cb(ok, value)
  end)
end

---@param team string
---@param to string
---@param kind string
---@param body string
---@param extra table|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:send(team, to, kind, body, extra, cb)
  extra = extra or {}
  self:_call("team.send", {
    team = team,
    to = to,
    kind = kind,
    body = body,
    task = extra.task,
    refs = extra.refs,
    -- 19.3: the service prefixes the card's summary line and uses `card` as
    -- the task when `task` is absent.
    card = extra.card,
  }, cb)
end

---@param team string
---@param to string
---@param body string "pause"|"resume"|"cancel"
---@param cb fun(ok: boolean, value: any)|nil
function Team:control(team, to, body, cb)
  self:send(team, to, "control", body, nil, cb)
end

---@param item_id string
---@param fields table
---@param cb fun(ok: boolean, value: any)|nil
function Team:answer(item_id, fields, cb)
  local params = vim.tbl_extend("force", { request = item_id }, fields or {})
  self:_call("team.answer", params, cb)
end

---Start a worker on behalf of the person (18.13).
---@param team string
---@param template string
---@param name string|nil
---@param task string|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:spawn(team, template, name, task, cb)
  cb = cb or function() end
  self:_call("team.spawn", { team = team, template = template, name = name, task = task }, function(ok, value)
    if ok and type(value) == "table" and value.warning == "dirty_tree" then
      self.notify(
        "worker "
          .. tostring(value.name or name or template)
          .. " starts from the last commit; uncommitted changes are not in its worktree",
        vim.log.levels.WARN
      )
    end
    cb(ok, value)
  end)
end

---Remove an exited worker's worktree (18.12).
---@param team string
---@param participant string
---@param force boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:remove_worktree(team, participant, force, cb)
  cb = cb or function() end
  local params = { team = team, participant = participant }
  if force then
    params.force = true
  end
  self:_call("team.remove_worktree", params, function(ok, value)
    if ok and type(value) == "table" and value.branch_kept then
      self.notify(
        "branch " .. tostring(value.branch or "?") .. " was kept (it is not merged into HEAD)",
        vim.log.levels.INFO
      )
    end
    cb(ok, value)
  end)
end

---@param team string
---@param participant string
---@param since integer|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:read(team, participant, since, cb)
  self:_call("team.read", { team = team, participant = participant, since = since }, cb)
end

---Remove a team from the local caches (a close reply, or `team.changed`
---closed). A board request still in flight must not recreate its entry.
---@param team_id string
function Team:forget_team(team_id)
  if type(team_id) ~= "string" then
    return
  end
  local entry = self.boards[team_id]
  if type(entry) == "table" then
    entry.seq = (entry.seq or 0) + 1
    entry.inflight = false
    entry.again = false
  end
  self.boards[team_id] = nil
  self.board_requested[team_id] = nil
  self.teams[team_id] = nil
  self.enabled_teams[team_id] = nil
  for id, item in pairs(self.inbox) do
    if item.team == team_id then
      self.inbox[id] = nil
      self.notified[id] = nil
    end
  end
  for cwd, bound in pairs(self.bound) do
    if bound.team == team_id then
      self.bound[cwd] = nil
    end
  end
end

---@param team string
---@param cb fun(ok: boolean, value: any)|nil
function Team:close(team, cb)
  self:_call("team.close", { team = team }, function(ok, value)
    if ok then
      -- The reply may arrive before `team.changed(closed)`; the local state
      -- must not keep a team that is already gone (19.7 "start over").
      self:forget_team(team)
      self:changed()
    end
    if cb then
      cb(ok, value)
    end
  end)
end

---@param team string
---@param cb fun(ok: boolean, value: any)|nil
function Team:reset_limits(team, cb)
  self:_call("team.reset_limits", { team = team }, cb)
end

---Start a named workflow on behalf of the person (19.7).
---@param team string
---@param workflow string
---@param task string|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:start(team, workflow, task, cb)
  self:_call("team.start", { team = team, workflow = workflow, task = task }, cb)
end

---Answer every open inbox item of a spawn group (19.6).
---
---A partially failed group is still a success: `value.failed` lists the items
---that stayed open, for the caller (the panel) to show.
---@param group string
---@param allow boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:answer_group(group, allow, cb)
  self:_call("team.answer_group", { group = group, allow = allow }, function(ok, value)
    if ok and type(value) == "table" then
      if type(value.failed) ~= "table" then
        value.failed = {}
      end
    end
    if cb then
      cb(ok, value)
    end
  end)
end

---Read a card's stored versions, newest first (19.4).
---@param team string
---@param card string
---@param cb fun(ok: boolean, value: any)|nil
function Team:card_history(team, card, cb)
  self:_call("team.card_history", { team = team, card = card }, cb)
end

---List every workflow visible from a cwd, resolved (19.5).
---@param cwd string
---@param cb fun(ok: boolean, value: any)|nil
function Team:workflows(cwd, cb)
  self:_call("team.workflows", { cwd = cwd }, function(ok, value)
    if ok and type(value) == "table" and type(value.workflows) == "table" then
      local names = {}
      for _, workflow in ipairs(value.workflows) do
        if type(workflow.name) == "string" then
          names[#names + 1] = workflow.name
        end
      end
      self.workflow_names = names
    end
    if cb then
      cb(ok, value)
    end
  end)
end

---Workflow names known without asking the service again (completion).
---@return string[]
function Team:known_workflows()
  local names, seen = {}, {}
  local function add(name)
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(self.workflow_names or {}) do
    add(name)
  end
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  for name in pairs(teams.workflows or {}) do
    add(name)
  end
  add("default")
  table.sort(names)
  return names
end

---Ask the service for the workflow list once (completion cache warm-up).
---@param cb fun()|nil
function Team:refresh_workflows(cb)
  cb = cb or function() end
  if not self:available() then
    cb()
    return
  end
  local cwd = self.resolve_cwd and self.resolve_cwd() or nil
  if not cwd then
    cb()
    return
  end
  self:workflows(cwd, function()
    cb()
  end)
end

---Delete a stored (project or user) workflow by name and scope (19.5).
---@param cwd string
---@param name string
---@param scope "project"|"user"
---@param cb fun(ok: boolean, value: any)|nil
function Team:workflow_delete(cwd, name, scope, cb)
  self:_call("team.workflow_delete", { cwd = cwd, name = name, scope = scope }, cb)
end

---@param payload table
---@return string
local function epoch_ms()
  if vim.uv and vim.uv.gettimeofday then
    local seconds, micros = vim.uv.gettimeofday()
    return seconds * 1000 + math.floor(micros / 1000)
  end
  return os.time() * 1000
end

local function prompt_text(payload)
  local parts = {}
  for _, block in ipairs(type(payload) == "table" and payload.prompt or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts, "\n")
end

---Mark a bus turn on a session and render it as user-side content.
---@param session table|nil
---@param payload table
---@return table|nil block the bus prompt block
function M.apply_turn_started(session, payload)
  if not session then
    return nil
  end
  local text = prompt_text(payload)
  local origin = type(payload) == "table" and payload.origin or "bus"
  session.status = "running"
  session.turn = (session.turn or 0) + 1
  session.bus_turn = session.turn
  return session:append({
    id = require("ade.session.state").next_id("bus"),
    kind = "user",
    text = "[" .. tostring(origin) .. "] " .. text,
    bus = { origin = origin },
  })
end

---@param session table|nil
---@return table|nil block the bus prompt block the turn ended on
function M.apply_turn_finished(session, payload)
  if not session or not session.bus_turn then
    return nil
  end
  local bus_turn = session.bus_turn
  session.bus_turn = nil
  local block
  for i = #session.blocks, 1, -1 do
    if session.blocks[i].bus then
      block = session.blocks[i]
      break
    end
  end
  -- A person's prompt may have replaced the bus turn while it was cancelling;
  -- its late finish must not end the user's (newer) turn.
  if session.turn == bus_turn then
    session:finish_turn(type(payload) == "table" and payload.stopReason or "end_turn")
  end
  return block
end

---The main (attached) session a notification is about.
---@param session_id string
---@return table|nil
function Team:session_of(session_id)
  local runtime = self.get_runtime and self.get_runtime() or nil
  if runtime and runtime.sessions then
    local session = runtime.sessions[session_id]
    if session then
      return session
    end
  end
  if self.watching and self.watching.session and self.watching.session.id == session_id then
    return self.watching.session
  end
end

---Handle `_ade/turn_started` (bus turn).
---@param payload table
function Team:turn_started(payload)
  payload = type(payload) == "table" and payload or {}
  local session = self:session_of(payload.sessionId or payload.session_id)
  if not session then
    return
  end
  if M.apply_turn_started(session, payload) then
    self:changed()
    self:_watch_rendered()
    if self.on_turn then
      pcall(self.on_turn, session)
    end
  end
end

---Handle `_ade/turn_finished` for a bus turn. Adoption keeps its own turns.
---@param payload table
function Team:turn_finished(payload)
  payload = type(payload) == "table" and payload or {}
  local session = self:session_of(payload.sessionId or payload.session_id)
  if session and session.bus_turn then
    -- Even without a bus block to attach the finish to, the turn still ended.
    M.apply_turn_finished(session, payload)
    self:changed()
    self:_watch_rendered()
    if self.on_turn then
      pcall(self.on_turn, session)
    end
  end
end

---Coalesce live watch frames: reducer.apply is cheap, rendering the whole
---transcript is not. At most one render is scheduled per window.
---@param entry table
function Team:_watch_schedule(entry)
  if self.watching ~= entry or entry.render_scheduled then
    return
  end
  entry.render_scheduled = true
  vim.defer_fn(function()
    entry.render_scheduled = false
    if self.watching == entry then
      self:_watch_rendered()
    end
  end, 50)
end

function Team:_watch_rendered()
  if self.watching and self.on_watch then
    pcall(self.on_watch, self.watching.session, self.watching.title)
  end
end

---Watch a worker's transcript (18.7). Replays through tunnel.recv frames.
---@param team string
---@param participant string
---@param replay boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:watch(team, participant, replay, cb)
  cb = cb or function() end
  if not self:available() then
    cb(false, "teams are not available")
    return
  end
  -- A real unwatch for the previous worker while the connection is still up.
  self:unwatch(false)
  local raw = self:_raw()
  local session = State.new("watch:" .. tostring(participant), self.resolve_cwd())
  session.historical = true
  local channel = "team-watch-" .. tostring(vim.uv.hrtime())
  local entry = {
    channel = channel,
    session = session,
    title = team .. "/" .. participant,
    team_id = team,
    participant = participant,
    buffer = {},
    ready = false,
    -- Display-only turn timings, keyed by the bus prompt block id.
    turn_times = {},
  }
  self.watching = entry
  local function apply(payload, schedule)
    if type(payload) ~= "table" or not entry.ready then
      return
    end
    if entry.instance and payload.instance ~= entry.instance then
      return
    end
    local message = payload.message
    if type(message) ~= "table" then
      return
    end
    if message.method == "_ade/turn_started" then
      local block = M.apply_turn_started(session, message.params or {})
      if block then
        entry.turn_times[block.id] = { started_at = epoch_ms() }
      end
      if schedule ~= false then
        self:_watch_schedule(entry)
      end
      return
    end
    if message.method == "_ade/turn_finished" then
      local block = M.apply_turn_finished(session, message.params or {})
      if block then
        local timing = entry.turn_times[block.id] or {}
        timing.ended_at = epoch_ms()
        entry.turn_times[block.id] = timing
      end
      if schedule ~= false then
        self:_watch_schedule(entry)
      end
      return
    end
    if message.method == "session/update" and type(message.params) == "table" then
      if message.params.sessionId ~= session.id then
        return
      end
      if reducer.apply(session, message.params.update or {}) then
        if schedule ~= false then
          self:_watch_schedule(entry)
        end
      end
    end
  end
  raw:subscribe(channel, "tunnel.recv", function(payload)
    if self.watching ~= entry then
      return
    end
    -- Replay frames arrive before the response names the instance/session;
    -- buffer them so a leader's update cannot leak into the watch.
    if not entry.ready then
      entry.buffer[#entry.buffer + 1] = payload
      return
    end
    apply(payload, true)
  end)
  raw:request_tracked(
    "team.watch",
    { team = team, participant = participant, replay = replay == true },
    function(ok, value)
      if self.watching ~= entry then
        -- This watch was superseded/abandoned while its request was in flight.
        -- The switch/close that superseded it already released that watch; a
        -- late success must not send another unwatch that could cancel a newer
        -- watch of the same participant.
        cb(ok, value)
        return
      end
      if not ok then
        self:unwatch(true)
        cb(false, value)
        return
      end
      if type(value) == "table" then
        entry.instance = value.instance
        entry.replayed = value.replayed ~= false
        if type(value.sessionId) == "string" then
          session.id = value.sessionId
        end
      end
      entry.ready = true
      -- Replay is a batch: reduce every frame first, render the final session
      -- once. Rendering per frame is quadratic on a long transcript.
      local started = vim.uv.hrtime()
      local frames = #entry.buffer
      for _, payload in ipairs(entry.buffer) do
        local ok, err = pcall(apply, payload, false)
        if not ok then
          log.error("dropping a watch replay frame: %s", tostring(err))
        end
      end
      entry.buffer = {}
      local after_apply = vim.uv.hrtime()
      self:_watch_rendered()
      local after_render = vim.uv.hrtime()
      log.debug(
        "watch replay frames=%d apply_ms=%.1f render_ms=%.1f",
        frames,
        (after_apply - started) / 1e6,
        (after_render - after_apply) / 1e6
      )
      cb(true, value)
    end
  )
end

---@param quiet boolean|nil no team.unwatch request (connection already gone)
function Team:unwatch(quiet)
  local entry = self.watching
  if not entry then
    return
  end
  entry.render_scheduled = false
  self.watching = nil
  local raw = self:_raw()
  if raw and type(raw.unsubscribe) == "function" then
    pcall(raw.unsubscribe, raw, entry.channel, "tunnel.recv")
  end
  if not quiet and raw and entry.team_id and entry.participant then
    raw:request_tracked("team.unwatch", { team = entry.team_id, participant = entry.participant }, function() end)
  end
  if self.on_watch then
    pcall(self.on_watch, nil, nil)
  end
end

M.Team = Team

return M
