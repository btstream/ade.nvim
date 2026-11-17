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
    notified = {},
    -- team id -> {worker name: true} for the pre-built definition.
    started_workers = {},
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
    raw:subscribe("teams", "__disconnected", function()
      self:reset()
    end)
  end
end

---Forget everything a lost connection invalidated.
function Team:reset()
  self.teams = {}
  self.inbox = {}
  self.leader_pending = {}
  self.leader_inflight = {}
  self.configure_inflight = {}
  self.started_workers = {}
  self.bound = {}
  self.blocked = {}
  -- `warned_blocked` / `notified` survive a reconnect: an item or conflict
  -- that was already announced must not be announced again.
  self:unwatch(true)
  self:changed()
end

---Reset what a reconnect invalidates: teams do not survive a service restart.
function Team:on_hello()
  self:reset()
  local cwd = self.resolve_cwd and self.resolve_cwd() or nil
  if cwd then
    self:configure(cwd, true)
  end
  self:refresh()
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

---Resolve the configuration the service expects (18.2).
---@param cwd string
---@return table|nil config
---@return table|nil skipped
function Team:service_config(cwd)
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  local store = self.store and self.store() or nil
  local templates, skipped = {}, {}
  for name, template in pairs(teams.templates or {}) do
    local launch, err = Resolve.resolve(cfg, template.agent, cfg.launch_origin, store)
    if not launch then
      skipped[#skipped + 1] = string.format("%s: %s", name, tostring(err))
    else
      local key = { agent = template.agent, command = launch.command, args = launch.args or {} }
      local entry = {
        key = key,
        env = transport.child_env(launch.env or (cfg.agents[template.agent] or {}).env),
        model = template.model,
        role = template.role,
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
  return {
    max_workers = teams.max_workers or 3,
    worktree_root = M.worktree_root(),
    spawn_confirm = { auto = vim.deepcopy(confirm.auto or {}) },
    limits = {
      max_turns_per_task = limits.max_turns_per_task or 30,
      max_turns_total = limits.max_turns_total or 200,
    },
    templates = next(templates) and templates or vim.empty_dict(),
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
  if self.configure_inflight[cwd] then
    -- Two hello listeners can race; one request is enough.
    cb(true, nil)
    return
  end
  self.configure_inflight[cwd] = true
  local raw = self:_raw()
  raw:request_tracked("team.configure", { cwd = cwd, config = config }, function(ok, value)
    self.configure_inflight[cwd] = nil
    if ok then
      self.sent_config[cwd] = config
    else
      local message = type(value) == "table" and (value.message or value.code) or tostring(value)
      log.warn("team.configure failed: %s", tostring(message))
    end
    cb(ok, value)
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
        if entry.leader.instance == instance then
          self.bound[cwd] = { instance = instance, session_id = entry.leader.sessionId, team = entry.id }
          return done(nil)
        end
        self.blocked[cwd] = true
        if not self.warned_blocked[cwd] then
          self.warned_blocked[cwd] = true
          self.notify("a team already exists for this cwd; close it before starting another", vim.log.levels.WARN)
        end
        return done(nil)
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
        self.blocked[cwd] = true
        if not self.warned_blocked[cwd] then
          self.warned_blocked[cwd] = true
          self.notify("another session already leads this team: " .. tostring(value.message or ""), vim.log.levels.WARN)
        end
      end
      return
    end
    local team_id = type(value) == "table" and type(value.team) == "table" and value.team.id or nil
    self.bound[cwd] = { instance = instance, session_id = session_id, team = team_id }
    self:refresh()
    self:start_defined_workers(team_id, type(value) == "table" and value.team or nil)
  end)
end

---Start the workers of the configured default definition (18.13/18.16).
---
---Only names that are absent from the returned team's participants are started,
---so a re-bind/reconnect or a second front end never starts them twice.
---@param team_id string|nil
---@param entry table|nil team.list entry returned by bind_leader
function Team:start_defined_workers(team_id, entry)
  if type(team_id) ~= "string" then
    return
  end
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  if teams.enabled ~= true then
    return
  end
  local definition = type(teams.definitions) == "table" and teams.default and teams.definitions[teams.default] or nil
  if type(definition) ~= "table" then
    return
  end
  local started = self.started_workers[team_id]
  if started then
    -- This team's definition was already reconciled by this front end.
    return
  end
  started = {}
  self.started_workers[team_id] = started
  local present = {}
  for _, participant in ipairs(type(entry) == "table" and entry.participants or {}) do
    present[participant.name] = true
  end
  for _, worker in ipairs(definition.workers or {}) do
    if not present[worker.name] and not started[worker.name] then
      started[worker.name] = true
      self:spawn(team_id, worker.template, worker.name, worker.task, function(ok, value)
        if not ok then
          local code = type(value) == "table" and value.code or nil
          if code == -32060 then
            -- The service refuses a name an in-flight spawn already took:
            -- not a failure the person needs to see, just a duplicate start.
            log.debug("worker %s was already started: %s", tostring(worker.name), M.error_text(value))
          else
            self.notify(
              "could not start worker " .. tostring(worker.name) .. ": " .. M.error_text(value),
              vim.log.levels.WARN
            )
          end
        end
        self:refresh()
      end)
    end
  end
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
      self:changed()
    end
    if cb then
      cb()
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
    self.teams[team.id] = nil
    for id, item in pairs(self.inbox) do
      if item.team == team.id then
        self.inbox[id] = nil
        self.notified[id] = nil
      end
    end
    for id, team_id in pairs(self.notified) do
      if team_id == team.id then
        self.notified[id] = nil
      end
    end
    self.started_workers[team.id] = nil
    -- The team is gone: this instance may lead a new one for the same cwd.
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
  raw:request_tracked(method, params, cb)
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

---@param team string
---@param cb fun(ok: boolean, value: any)|nil
function Team:close(team, cb)
  self:_call("team.close", { team = team }, cb)
end

---@param team string
---@param cb fun(ok: boolean, value: any)|nil
function Team:reset_limits(team, cb)
  self:_call("team.reset_limits", { team = team }, cb)
end

---@param payload table
---@return string
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
---@return boolean changed
function M.apply_turn_started(session, payload)
  if not session then
    return false
  end
  local text = prompt_text(payload)
  local origin = type(payload) == "table" and payload.origin or "bus"
  session.status = "running"
  session.turn = (session.turn or 0) + 1
  session.bus_turn = session.turn
  session:append({
    id = require("ade.session.state").next_id("bus"),
    kind = "user",
    text = "[" .. tostring(origin) .. "] " .. text,
    bus = { origin = origin },
  })
  return true
end

---@param session table|nil
---@return boolean changed
function M.apply_turn_finished(session, payload)
  if not session or not session.bus_turn then
    return false
  end
  local bus_turn = session.bus_turn
  session.bus_turn = nil
  -- A person's prompt may have replaced the bus turn while it was cancelling;
  -- its late finish must not end the user's (newer) turn.
  if session.turn == bus_turn then
    session:finish_turn(type(payload) == "table" and payload.stopReason or "end_turn")
  end
  return true
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
  if session and session.bus_turn and M.apply_turn_finished(session, payload) then
    self:changed()
    self:_watch_rendered()
    if self.on_turn then
      pcall(self.on_turn, session)
    end
  end
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
  }
  self.watching = entry
  local function apply(payload)
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
      M.apply_turn_started(session, message.params or {})
      self:_watch_rendered()
      return
    end
    if message.method == "_ade/turn_finished" then
      M.apply_turn_finished(session, message.params or {})
      self:_watch_rendered()
      return
    end
    if message.method == "session/update" and type(message.params) == "table" then
      if message.params.sessionId ~= session.id then
        return
      end
      if reducer.apply(session, message.params.update or {}) then
        self:_watch_rendered()
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
    apply(payload)
  end)
  raw:request_tracked(
    "team.watch",
    { team = team, participant = participant, replay = replay == true },
    function(ok, value)
      if self.watching ~= entry then
        -- This watch was superseded/abandoned while its request was in flight.
        -- Do not touch the newer watch, but release the service-side watch.
        if ok then
          raw:request_tracked("team.unwatch", { team = team, participant = participant }, function() end)
        end
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
        if type(value.sessionId) == "string" then
          session.id = value.sessionId
        end
      end
      entry.ready = true
      for _, payload in ipairs(entry.buffer) do
        apply(payload)
      end
      entry.buffer = {}
      if self.on_watch then
        pcall(self.on_watch, session, entry.title)
      end
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
