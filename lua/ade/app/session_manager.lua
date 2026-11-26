-- One list of every agent's stored sessions (docs/session-manager.md).
--
-- The service owns the catalog (PROTOCOL.md 21): opening this window reads the
-- cache at once, asks the service to refresh every agent in the background and
-- replaces an agent's rows as its `sessions.updated` arrives. Loading a row is
-- still a normal load through the panel's own connection, so this module only
-- decides *which* connection has to be built and hands the session to the
-- one-shot pending load in `app/bootstrap.lua`.
local Resolve = require("ade.manager.resolve")
local transport = require("ade.service.transport")
local ServiceSessions = require("ade.service.sessions")

local M = {}

---One fallback notice per configuration. Repeating "you need the service" on
---every `:Ade sessions all` would be noise; a new configuration (a setup with a
---different backend) deserves the warning again.
local fallback_noticed = setmetatable({}, { __mode = "k" })

---Channel ids must be unique per manager: the shared connection keys its
---listeners by channel, and a rebuilt manager must not overwrite the previous
---one's subscription before it is gone.
local channel_seq = 0

---@param command string
---@return boolean
local function default_executable(command)
  return type(command) == "string" and command ~= "" and vim.fn.executable(command) == 1
end

---Compare two directory paths the way the agents do: resolved and without a
---trailing separator.
---@param a string
---@param b string
---@return boolean
local function same_dir(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then
    return false
  end
  return vim.fs.normalize(a) == vim.fs.normalize(b)
end

---@param value any
---@return string
local function describe_error(value)
  if type(value) == "table" then
    return string.format("%s (code %s)", tostring(value.message or "service error"), tostring(value.code))
  end
  return tostring(value or "the service did not answer")
end

---@class AdeSessionManagerDeps
---@field state fun(): table
---@field config fun(): table
---@field notify fun(message: string, level: integer|nil)
---@field setup fun(opts: table, action: table|nil)
---@field open fun()
---@field pick_session fun()
---@field resolve_cwd fun(): string
---@field presenter table|nil
---@field ui table|nil injectable browser backend (tests)
---@field executable fun(command: string): boolean injectable PATH check (tests)

local Manager = {}
Manager.__index = Manager

---@param deps AdeSessionManagerDeps
---@return table
function M.new(deps)
  channel_seq = channel_seq + 1
  return setmetatable({
    deps = deps,
    channel = string.format("session-manager-%d-%d", vim.uv.os_getpid(), channel_seq),
    agents = {},
    params = {},
    unavailable = {},
    entries = {},
    agent_states = {},
    refreshing = {},
    -- Per-agent ids in one set, used to drop cached rows of agents that are no
    -- longer configured.
    configured = {},
    connection = nil,
    ui = nil,
    status = nil,
    -- Each opening of the window owns one round; callbacks from an older round
    -- (or from before a close) are dropped instead of mutating the new window.
    round = 0,
    -- Every `refresh` owns a sequence: a late reply must not settle the header
    -- of a newer refresh.
    refresh_seq = 0,
  }, Manager)
end

function Manager:get_state()
  return self.deps.state()
end

function Manager:config()
  return self.deps.config()
end

function Manager:notify(message, level)
  self.deps.notify(message, level)
end

---The shared front-end service connection, started on demand.
---
---This is the same object `:Ade agents` and installs use; the session manager
---must work when the panel has never connected, so it never touches the
---panel's client.
---@return table|nil
function Manager:service_connection()
  local S = self:get_state()
  local service = S.conn and S.conn.service
  if not service or type(service.service_connection) ~= "function" then
    return nil
  end
  local ok, connection = pcall(service.service_connection, service)
  if not ok or type(connection) ~= "table" then
    return nil
  end
  return connection
end

---Fall back to the current agent's browser, saying why once.
---@param cfg table
function Manager:fallback(cfg)
  if not fallback_noticed[cfg] then
    fallback_noticed[cfg] = true
    self:notify("The session manager needs the ade service; showing this agent's sessions", vim.log.levels.WARN)
  end
  if type(self.deps.pick_session) == "function" then
    self.deps.pick_session()
  end
end

---Resolve every configured agent's launch exactly the way the panel does.
---
---Returns the sorted ids (the header lists every configured agent, available or
---not), the `sessions.refresh` entries for the ones that can start, and the
---reason each unavailable one cannot.
---@param cfg table
---@return string[] agents, table[] params, table<string, string> unavailable
function Manager:resolve_agents(cfg)
  local ids = {}
  for id in pairs(cfg.agents or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids)

  local store
  local store_ok, value = pcall(Resolve.new_store, cfg)
  if store_ok then
    store = value
  end

  local params, unavailable = {}, {}
  local cwd = self.deps.resolve_cwd()
  local executable = self.deps.executable or default_executable

  for _, id in ipairs(ids) do
    local ok, spec, err = pcall(Resolve.resolve, cfg, id, cfg.launch_origin, store)
    if not ok then
      unavailable[id] = tostring(spec)
    elseif not spec then
      unavailable[id] = tostring(err or "not available")
    elseif not executable(spec.command) then
      unavailable[id] = "not found: " .. tostring(spec.command)
    else
      local entry = {
        agent = id,
        command = spec.command,
        args = vim.deepcopy(spec.args or {}),
        cwd = cwd,
        -- The service replaces the child's environment completely, so the same
        -- helper the panel's transport uses builds it here too.
        env = transport.child_env(spec.env),
      }
      if spec.source == "managed" and type(spec.install_id) == "string" then
        entry.launch = {
          root = Resolve.manager_root(cfg),
          agent = id,
          installId = spec.install_id,
        }
      end
      params[#params + 1] = entry
    end
  end
  return ids, params, unavailable
end

---The table the browser renders from.
---@return table
function Manager:view()
  local cfg = self:config() or {}
  local S = self:get_state()
  local current = S.sess and S.sess.current or nil
  return {
    agents = self.agents,
    entries = self.entries,
    agent_state = self.agent_states,
    refreshing = self.refreshing,
    unavailable = self.unavailable,
    current_agent = cfg.agent,
    current_id = current and current.id or nil,
    use_icons = type(cfg.ui) == "table" and cfg.ui.icons or nil,
    status = self.status,
    on_open = function(entry)
      self:load(entry)
    end,
    on_refresh = function()
      self:refresh()
    end,
    on_close = function()
      self:window_closed()
    end,
    is_dir = self.deps.is_dir or function(path)
      return vim.fn.isdirectory(path) == 1
    end,
  }
end

function Manager:refresh_view()
  if self.ui then
    self.ui:update(self:view())
  end
end

---Drop the listener and invalidate every callback of the current round.
---
---Called whenever the window goes away: the service keeps answering requests
---long after the browser closed, and those answers must not reach (or reopen)
---anything.
function Manager:release()
  self.round = self.round + 1
  self.refreshing = {}
  local connection = self.connection
  self.connection = nil
  if connection then
    ServiceSessions.unsubscribe(connection, self.channel)
  end
end

---The window closed on its own (q, <Esc>, or losing focus).
function Manager:window_closed()
  if self.ui == nil then
    -- `close_window` detached the handle and releases itself.
    return
  end
  self.ui = nil
  self:release()
end

---Forget this manager: used when a reconfiguration replaces it.
function Manager:dispose()
  self:close_window()
end

---Open the browser and start loading the catalog.
---
---The backend and feature checks happen before anything is shown: on a direct
---backend or an old service the existing `:Ade sessions` picker is the honest
---answer.
function Manager:open()
  local cfg = self:config()
  if type(cfg) ~= "table" then
    return
  end
  if self.ui and self.ui:is_open() then
    return
  end
  local backend = cfg.backend or "direct"
  if backend ~= "service" and backend ~= "auto" then
    self:fallback(cfg)
    return
  end
  local connection = self:service_connection()
  if not connection then
    self:fallback(cfg)
    return
  end

  local settled, ready = false, false
  connection:ensure(function(ok)
    settled, ready = true, ok
  end)
  if not settled then
    -- The handshake is still running (a version restart). Open when it lands
    -- instead of blocking the editor; if it never does, nothing is shown.
    connection:on_hello(self.channel, function()
      connection:on_hello(self.channel, nil)
      vim.schedule(function()
        self:open()
      end)
    end)
    return
  end
  if not ready then
    self:fallback(cfg)
    return
  end
  if type(connection.has_feature) == "function" and not connection:has_feature("sessions") then
    self:fallback(cfg)
    return
  end
  self:start(connection, cfg)
end

---@param connection table
---@param cfg table
function Manager:start(connection, cfg)
  self.connection = connection
  self.round = self.round + 1
  local round = self.round
  self.agents, self.params, self.unavailable = self:resolve_agents(cfg)
  self.configured = {}
  for _, id in ipairs(self.agents) do
    self.configured[id] = true
  end
  self.entries, self.agent_states, self.refreshing, self.status = {}, {}, {}, nil
  -- Agents whose fresh rows already arrived. The cache reply can be overtaken
  -- by a fast refresh; its stale rows must not overwrite the fresh ones.
  self.updated_agents = {}

  ServiceSessions.subscribe(connection, self.channel, function(payload)
    if round ~= self.round then
      return
    end
    self:on_updated(payload)
  end)

  local ui = self.deps.ui or require("ade.ui.session_manager")
  self.ui = ui.open(self:view())

  self:request_cached(round)
  self:refresh()
end

---Keep only rows of agents that are still configured. A cached catalog can
---outlive an agent removed from the configuration.
---@param entries table
---@return table[]
function Manager:filter_entries(entries)
  local kept = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and self.configured[entry.agent] then
      kept[#kept + 1] = entry
    end
  end
  return kept
end

---@param round integer the open round this request belongs to
function Manager:request_cached(round)
  local connection = self.connection
  if not connection then
    return
  end
  ServiceSessions.cached(connection, function(ok, value)
    if not ok or round ~= self.round or not self.connection then
      return
    end
    value = type(value) == "table" and value or {}
    local cached = {}
    for _, entry in ipairs(self:filter_entries(value.sessions)) do
      if not self.updated_agents[entry.agent] then
        cached[#cached + 1] = entry
      end
    end
    -- Keep rows that a refresh already delivered.
    local kept = {}
    for _, entry in ipairs(self.entries) do
      if self.updated_agents[entry.agent] then
        kept[#kept + 1] = entry
      end
    end
    for _, entry in ipairs(cached) do
      kept[#kept + 1] = entry
    end
    self.entries = kept
    -- Merge the cached agent states without losing one a failed refresh (or an
    -- earlier successful listing) already delivered.
    local states = type(value.agents) == "table" and value.agents or {}
    for agent, cached_state in pairs(states) do
      if self.configured[agent] and not self.updated_agents[agent] and type(cached_state) == "table" then
        local state = self.agent_states[agent] or {}
        state.error = state.error or cached_state.error
        state.listed_at = state.listed_at or cached_state.listed_at
        self.agent_states[agent] = state
      end
    end
    self:refresh_view()
  end)
end

---Ask the service to list every available agent again.
function Manager:refresh()
  local connection = self.connection
  if not connection then
    return
  end
  local round = self.round
  self.refresh_seq = self.refresh_seq + 1
  local seq = self.refresh_seq
  self.status = nil
  self.refreshing = {}
  for _, entry in ipairs(self.params) do
    self.refreshing[entry.agent] = true
  end
  -- Refresh notifications for this call replace the rows of one agent at a
  -- time; the reply only settles the header.
  ServiceSessions.refresh(connection, self.params, function(ok, value)
    if round ~= self.round or seq ~= self.refresh_seq then
      return
    end
    self:on_refresh_reply(ok, value)
  end)
  self:refresh_view()
end

---One agent finished: replace its rows, or keep them and show the error.
---@param payload table
function Manager:on_updated(payload)
  if type(payload) ~= "table" or type(payload.agent) ~= "string" then
    return
  end
  local agent = payload.agent
  if not self.configured[agent] then
    return
  end
  self.refreshing[agent] = nil
  local state = self.agent_states[agent] or {}
  if payload.error then
    -- A failed refresh keeps the cached rows visible and must not count as
    -- fresh rows: a late `sessions.cached` reply still has to fill them in.
    self.updated_agents[agent] = nil
    state.error = payload.error
    self.agent_states[agent] = state
    self:refresh_view()
    return
  end
  self.updated_agents[agent] = true
  local kept = {}
  for _, entry in ipairs(self.entries) do
    if entry.agent ~= agent then
      kept[#kept + 1] = entry
    end
  end
  for _, entry in ipairs(self:filter_entries(payload.sessions)) do
    if entry.agent == agent then
      kept[#kept + 1] = entry
    end
  end
  self.entries = kept
  state.error = nil
  state.listed_at = math.floor(vim.uv.gettimeofday() * 1000)
  self.agent_states[agent] = state
  self:refresh_view()
end

---The reply to `sessions.refresh`: settle every agent's header.
---@param ok boolean
---@param value any
function Manager:on_refresh_reply(ok, value)
  self.refreshing = {}
  if not ok then
    self.status = "refresh failed: " .. describe_error(value)
    self:refresh_view()
    return
  end
  local results = type(value) == "table" and value.agents or {}
  for agent, result in pairs(results) do
    if self.configured[agent] and type(result) == "table" then
      local state = self.agent_states[agent] or {}
      if result.ok then
        state.error = nil
      elseif result.error then
        state.error = result.error
      end
      self.agent_states[agent] = state
    end
  end
  self:refresh_view()
end

---Close the browser and drop the listener, ignoring any request still in flight.
function Manager:close_window()
  local ui = self.ui
  -- Detach the handle first: the window's own close notification must not try
  -- to release a second time (and double-bump the round).
  self.ui = nil
  if ui then
    pcall(ui.close, ui)
  end
  self:release()
end

---Whether the panel's live connection already runs in `cwd` for `agent`.
---@param cfg table
---@param agent string
---@param cwd string
---@return boolean
function Manager:connected_in(cfg, agent, cwd)
  local S = self:get_state()
  if cfg.agent ~= agent or S.conn.phase ~= "ready" then
    return false
  end
  local client = S.conn.client
  return client ~= nil and same_dir(client.cwd, cwd)
end

---Load one catalog row (docs/session-manager.md, "Loading a row").
---@param entry table
function Manager:load(entry)
  if type(entry) ~= "table" or type(entry.sessionId) ~= "string" then
    return
  end
  local cwd = entry.cwd
  if type(cwd) ~= "string" or cwd == "" or vim.fn.isdirectory(cwd) ~= 1 then
    self:notify(
      "That session's directory does not exist: " .. tostring(cwd ~= "" and cwd or "(none)"),
      vim.log.levels.WARN
    )
    return
  end

  local cfg = self:config()
  if type(cfg) ~= "table" then
    return
  end
  if type(cfg.cwd) == "string" and cfg.cwd ~= "" and not same_dir(cfg.cwd, cwd) then
    self:notify(
      string.format("cwd is pinned to %s, so the session manager cannot switch folders", cfg.cwd),
      vim.log.levels.WARN
    )
    return
  end

  -- A failed setup leaves the manager open so the person can pick again.
  if self:connected_in(cfg, entry.agent, cwd) then
    self:load_on_current(entry, cwd)
    return
  end
  self:load_with_new_connection(entry, cwd, cfg)
end

---Path 3: the live connection already serves this agent and directory.
---@param entry table
---@param cwd string
function Manager:load_on_current(entry, cwd)
  local S = self:get_state()
  self:close_window()
  local catalog = S.sess and S.sess.catalog
  if catalog and type(catalog.cwds) == "function" then
    -- `session/load` must use the directory the agent reported, not the
    -- editor's current one.
    catalog:cwds()[entry.sessionId] = cwd
  end
  if S.sess and S.sess.service then
    S.sess.service:load(entry.sessionId, { cwd = cwd })
  end
end

---Path 4: the target needs another agent process (agent and/or cwd differ).
---@param entry table
---@param cwd string
---@param cfg table
function Manager:load_with_new_connection(entry, cwd, cfg)
  local S = self:get_state()
  local flow = S.conn and S.conn.flow
  local queued, running = 0, 0
  if flow and type(flow.pending_work) == "function" then
    local ok, q, r = pcall(flow.pending_work, flow)
    if ok then
      queued, running = q or 0, r or 0
    end
  end

  local function switch()
    self:close_window()
    -- The panel is a global singleton: editor and agent must agree on one
    -- directory, so this is a plain `:cd`, not a window-local change.
    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(cwd))
    -- One-shot, carried by the setup action: `on_ready` loads this session
    -- instead of auto-restoring another one or creating an empty session, and
    -- any other reconfiguration drops the intent. It is scoped to the agent and
    -- directory the new connection must have.
    local intent = { agent = entry.agent, cwd = cwd, id = entry.sessionId }
    pcall(function()
      require("ade.inline").stop()
    end)
    local opts = vim.deepcopy(cfg)
    opts.agent = entry.agent
    self.deps.setup(opts, { discard_queued = true, pending_load = intent })
    self.deps.open()
  end

  if queued == 0 and running == 0 then
    switch()
    return
  end

  local presenter = self.deps.presenter or require("ade.app.presenter")
  if self.ui then
    -- The confirmation picker takes focus; keep the manager open until it
    -- answers (its BufLeave would close it otherwise).
    self.ui:set_busy(true)
  end
  local function finish_confirmation()
    if self.ui then
      self.ui:set_busy(false)
    end
    self:refresh_view()
  end
  local ok = pcall(presenter.select, {
    title = string.format(
      "Switch to %s in %s?\nThis drops %d queued message(s) and interrupts %d running turn(s).",
      entry.agent,
      cwd,
      queued,
      running
    ),
    items = {
      { label = "Switch", value = "switch" },
      { label = "Cancel", value = "cancel" },
    },
    filter = false,
    on_choice = function(choice)
      if choice == "switch" then
        if self.ui then
          self.ui:set_busy(false)
        end
        switch()
        return
      end
      finish_confirmation()
    end,
    -- Dismissing the picker (Esc, <C-c>, leaving the float) is a Cancel: the
    -- browser must not stay busy forever.
    on_cancel = finish_confirmation,
  })
  if not ok then
    if self.ui then
      self.ui:set_busy(false)
    end
    error("ade.nvim: unable to ask before switching agents", 0)
  end
end

return M
