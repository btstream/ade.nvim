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
    pending_bind = {},
    -- cwd -> {instance, session_id} once this front end's leader is bound.
    bound = {},
    -- cwd -> true when another session already leads that team (-32061).
    blocked = {},
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
  self.leader_pending = nil
  self.bound = {}
  self.blocked = {}
  self:unwatch(true)
  self:changed()
end

---Reset what a reconnect invalidates: teams do not survive a service restart.
function Team:on_hello()
  self.teams = {}
  self.inbox = {}
  self.leader_pending = nil
  self.bound = {}
  self.blocked = {}
  self:unwatch(true)
  local cwd = self.resolve_cwd and self.resolve_cwd() or nil
  if cwd then
    self:configure(cwd, true)
  end
  self:refresh()
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
    spawn_confirm = { auto = vim.deepcopy(confirm.auto or {}) },
    limits = {
      max_turns_per_task = limits.max_turns_per_task or 30,
      max_turns_total = limits.max_turns_total or 200,
    },
    templates = templates,
  },
    skipped
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
  for _, problem in ipairs(skipped or {}) do
    self.notify("team template skipped: " .. problem, vim.log.levels.WARN)
  end
  if not force and vim.deep_equal(config, self.sent_config[cwd]) then
    cb(true, nil)
    return
  end
  local raw = self:_raw()
  raw:request_tracked("team.configure", { cwd = cwd, config = config }, function(ok, value)
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
  local ok, result = async.await(function(done)
    self:configure(cwd, false, function(ok)
      if not ok then
        done(false, nil)
        return
      end
      local raw = self:_raw()
      raw:request_tracked("team.leader_server", { instance = instance, cwd = cwd }, function(ok2, value)
        if not ok2 and type(value) == "table" and value.code == -32061 then
          -- Another session already leads that cwd's team; a single-agent
          -- session must not be injected with a leader server.
          self.blocked[cwd] = true
        end
        done(ok2, value)
      end)
    end)
  end)
  if not ok or type(result) ~= "table" or type(result.server) ~= "table" then
    return nil
  end
  self.leader_pending = {
    instance = instance,
    cwd = cwd,
    token_id = result.token_id,
  }
  return result.server
end

---Bind the leader after session/new|load|resume succeeded.
---@param instance string|nil
---@param session_id string
---@param cwd string
function Team:bind_leader(instance, session_id, cwd)
  local pending = self.leader_pending
  if not pending or pending.instance ~= instance or pending.cwd ~= cwd then
    return
  end
  self.leader_pending = nil
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
      return
    end
    self.bound[cwd] = { instance = instance, session_id = session_id }
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
      self.teams = teams
      self.inbox = {}
      for id, team in pairs(teams) do
        for _, item in ipairs(team.inbox or {}) do
          item.team = item.team or id
          self.inbox[item.id] = item
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
      end
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
  if fresh then
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
  session.bus_turn = true
  session.status = "running"
  session.turn = (session.turn or 0) + 1
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
function M.apply_turn_finished(session)
  if not session or not session.bus_turn then
    return false
  end
  session.bus_turn = nil
  session.status = "idle"
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
  if session and session.bus_turn and M.apply_turn_finished(session) then
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
  self:unwatch(true)
  local raw = self:_raw()
  local session = State.new("watch:" .. tostring(participant), self.resolve_cwd())
  session.historical = true
  local channel = "team-watch-" .. tostring(vim.uv.hrtime())
  local entry = {
    channel = channel,
    session = session,
    title = team .. "/" .. participant,
  }
  self.watching = entry
  raw:subscribe(channel, "tunnel.recv", function(payload)
    if not self.watching or self.watching ~= entry then
      return
    end
    if type(payload) ~= "table" or (entry.instance and payload.instance ~= entry.instance) then
      return
    end
    local message = payload.message
    if type(message) == "table" and message.method == "_ade/turn_started" then
      M.apply_turn_started(session, message.params or {})
      self:_watch_rendered()
      return
    end
    if type(message) == "table" and message.method == "_ade/turn_finished" then
      M.apply_turn_finished(session)
      self:_watch_rendered()
      return
    end
    if type(message) == "table" and message.method == "session/update" and type(message.params) == "table" then
      -- Replay arrives before the watch response: adopt the session id from
      -- the first update instead of comparing with the placeholder.
      if session.id:sub(1, 6) == "watch:" and type(message.params.sessionId) == "string" then
        session.id = message.params.sessionId
      end
      if message.params.sessionId == session.id and reducer.apply(session, message.params.update or {}) then
        self:_watch_rendered()
      end
    end
  end)
  raw:request_tracked(
    "team.watch",
    { team = team, participant = participant, replay = replay == true },
    function(ok, value)
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
        entry.replayed = value.replayed
      end
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
  if not quiet and raw then
    local team_id, participant = entry.title:match("^([^/]+)/(.+)$")
    if team_id then
      raw:request_tracked("team.unwatch", { team = team_id, participant = participant }, function() end)
    end
  end
  if self.on_watch then
    pcall(self.on_watch, nil, nil)
  end
end

M.Team = Team

return M
