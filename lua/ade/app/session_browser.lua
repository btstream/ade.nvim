-- One session browser for `:Ade sessions` and `:Ade sessions all`
-- (docs/team-layout-and-session-browser.md, part C; PROTOCOL.md 21).
--
-- Three scopes share one window:
--
--   here   the panel agent's sessions in the editor directory, live through
--          the panel's ACP connection (works on the direct backend)
--   agent  the current agent's sessions in every directory, from the service
--   all    every configured agent, from the service catalog
--
-- The catalog is read from the cache at once and refreshed in the background;
-- each agent's rows are replaced as its `sessions.updated` arrives. Opening or
-- deleting a row decides between the panel's own connection and the service
-- (`sessions.delete`, PROTOCOL.md 21.8) from the row's agent.
local Resolve = require("ade.manager.resolve")
local transport = require("ade.service.transport")
local ServiceSessions = require("ade.service.sessions")
local last_sessions = require("ade.storage.last_sessions")
local capabilities = require("ade.protocol.capabilities")

local M = {}

---Channel ids are unique per browser: the shared connection keys listeners by
---channel, so a rebuilt browser must not overwrite the previous one's until it
---is gone.
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

---@class AdeSessionBrowserDeps
---@field state fun(): table
---@field config fun(): table
---@field notify fun(message: string, level: integer|nil)
---@field setup fun(opts: table, action: table|nil)
---@field open fun()
---@field resolve_cwd fun(): string
---@field presenter table|nil
---@field ui table|nil injectable browser backend (tests)
---@field executable fun(command: string): boolean injectable PATH check (tests)
---@field is_dir fun(path: string): boolean injectable directory check (tests)
---@field catalog table|nil the panel's Catalog (live `session/list`)
---@field generation fun(): integer|nil the panel operations generation

local Browser = {}
Browser.__index = Browser

---@param deps AdeSessionBrowserDeps
---@return table
function M.new(deps)
  channel_seq = channel_seq + 1
  return setmetatable({
    deps = deps,
    channel = string.format("session-browser-%d-%d", vim.uv.os_getpid(), channel_seq),
    -- `here` source
    here_rows = {},
    here_refreshing = false,
    here_client = nil,
    here_generation = nil,
    -- catalog source
    catalog_state = nil, -- nil = not tried, true = ready, false = unavailable
    catalog_started = false,
    connection = nil,
    agents = {},
    params = {},
    unavailable = {},
    configured = {},
    catalog_entries = {},
    agent_states = {},
    refreshing = {},
    updated_agents = {},
    -- window
    scope = "here",
    scopes = {},
    ui = nil,
    status = nil,
    scope_hint_shown = false,
    -- Each opening owns one round; callbacks from an older round (or before a
    -- close) are dropped instead of mutating the new window.
    round = 0,
    refresh_seq = 0,
    hello_connection = nil,
    disposed = false,
    pending_scope = nil,
  }, Browser)
end

function Browser:get_state()
  return self.deps.state()
end

function Browser:config()
  return self.deps.config()
end

function Browser:notify(message, level)
  self.deps.notify(message, level)
end

---The shared front-end service connection, started on demand.
---@return table|nil
function Browser:service_connection()
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

---Whether the panel holds a live agent client (the `here` source).
---@return boolean
function Browser:panel_ready()
  local S = self:get_state()
  local client = S.conn.client
  if S.conn.phase ~= "ready" or not client then
    return false
  end
  -- Light test doubles have no is_ready; a client object is enough there.
  if type(client.is_ready) == "function" then
    return client:is_ready()
  end
  return true
end

---@return string[]
function Browser:available_scopes()
  local scopes = {}
  if self:panel_ready() then
    scopes[#scopes + 1] = "here"
  end
  if self.catalog_state == true then
    scopes[#scopes + 1] = "agent"
    scopes[#scopes + 1] = "all"
  end
  return scopes
end

---Resolve every configured agent's launch exactly the way the panel does.
---@param cfg table
---@return string[] agents, table[] params, table<string, string> unavailable
function Browser:resolve_agents(cfg)
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

---------------------------------------------------------------------------
-- catalog source
---------------------------------------------------------------------------

---Check the service and start the catalog when it is available.
---
---Returns true/false, or nil while the handshake is still running; the hello
---callback then finishes the preparation.
---
---The availability check is what lets the scope line show `agent`/`all` while
---the window opens at `here`; the cached read and refresh only start when a
---catalog scope is actually shown (`start_now`).
---@param start_now boolean|nil
---@return boolean|nil
function Browser:prepare_catalog(start_now)
  if self.catalog_state ~= nil then
    return self.catalog_state
  end
  local cfg = self:config()
  local backend = cfg.backend or "direct"
  if backend ~= "service" and backend ~= "auto" then
    self.catalog_state = false
    return false
  end
  local connection = self:service_connection()
  if not connection then
    self.catalog_state = false
    return false
  end

  local settled, ready = false, false
  connection:ensure(function(ok)
    settled, ready = true, ok
  end)
  if not settled then
    self:wait_for_catalog(connection)
    return nil
  end
  if not ready or (type(connection.has_feature) == "function" and not connection:has_feature("sessions")) then
    self.catalog_state = false
    return false
  end
  self.catalog_state = true
  self.connection = connection
  if start_now then
    self:start_catalog(connection)
  end
  return true
end

---Start the catalog once the service handshake finishes.
---@param connection table
function Browser:wait_for_catalog(connection)
  local round = self.round
  self.hello_connection = connection
  connection:on_hello(self.channel, function()
    connection:on_hello(self.channel, nil)
    if self.hello_connection == connection then
      self.hello_connection = nil
    end
    vim.schedule(function()
      -- A close or a replacement may have happened while the handshake was in
      -- flight; only the round that asked may continue.
      if self.disposed or round ~= self.round then
        return
      end
      self.catalog_state = nil
      if self:prepare_catalog(false) == true then
        -- A deferred open (`:Ade sessions all` waiting for the service) can
        -- now proceed; `open` starts the catalog for the effective scope. An
        -- already open window only needs the catalog if it is showing one.
        if not (self.ui and self.ui:is_open()) then
          self:open(self.pending_scope or "here")
        elseif self.scope == "agent" or self.scope == "all" then
          self:start_catalog(self.connection)
        end
        self:refresh_view()
      end
    end)
  end)
end

---@param connection table
function Browser:start_catalog(connection)
  if self.catalog_started then
    return
  end
  connection = connection or self.connection
  if not connection then
    return
  end
  local cfg = self:config()
  self.catalog_started = true
  self.connection = connection
  local round = self.round
  self.agents, self.params, self.unavailable = self:resolve_agents(cfg)
  self.configured = {}
  for _, id in ipairs(self.agents) do
    self.configured[id] = true
  end
  self.catalog_entries, self.agent_states, self.refreshing, self.updated_agents = {}, {}, {}, {}
  ServiceSessions.subscribe(connection, self.channel, function(payload)
    if round ~= self.round then
      return
    end
    self:on_updated(payload)
  end)
  self:request_cached(round)
  self:refresh_catalog()
end

---Keep only rows of agents that are still configured.
---@param entries table
---@return table[]
function Browser:filter_entries(entries)
  local kept = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and self.configured[entry.agent] then
      kept[#kept + 1] = entry
    end
  end
  return kept
end

---@param round integer the open round this request belongs to
function Browser:request_cached(round)
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
    for _, entry in ipairs(self.catalog_entries) do
      if self.updated_agents[entry.agent] then
        kept[#kept + 1] = entry
      end
    end
    for _, entry in ipairs(cached) do
      kept[#kept + 1] = entry
    end
    self.catalog_entries = kept
    -- Merge the cached agent states without losing one a failed refresh (or an
    -- earlier successful listing) already delivered.
    local states = type(value.agents) == "table" and value.agents or {}
    for agent, cached_state in pairs(states) do
      if self.configured[agent] and not self.updated_agents[agent] and type(cached_state) == "table" then
        local state = self.agent_states[agent] or {}
        state.error = state.error or cached_state.error
        state.listed_at = state.listed_at or cached_state.listed_at
        if state.can_delete == nil then
          state.can_delete = cached_state.can_delete
        end
        self.agent_states[agent] = state
      end
    end
    self:refresh_view()
  end)
end

---Ask the service to list every available agent again.
function Browser:refresh_catalog()
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
function Browser:on_updated(payload)
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
    -- A failed refresh keeps whatever rows this window already has: the latest
    -- successful update, or — when this agent never succeeded — a cached
    -- snapshot the (possibly still pending) cache reply will fill in.
    state.error = payload.error
    self.agent_states[agent] = state
    self:refresh_view()
    return
  end
  self.updated_agents[agent] = true
  local kept = {}
  for _, entry in ipairs(self.catalog_entries) do
    if entry.agent ~= agent then
      kept[#kept + 1] = entry
    end
  end
  for _, entry in ipairs(self:filter_entries(payload.sessions)) do
    if entry.agent == agent then
      kept[#kept + 1] = entry
    end
  end
  self.catalog_entries = kept
  state.error = nil
  state.listed_at = math.floor(vim.uv.gettimeofday() * 1000)
  self.agent_states[agent] = state
  self:refresh_view()
end

---The reply to `sessions.refresh`: settle every agent's header.
---@param ok boolean
---@param value any
function Browser:on_refresh_reply(ok, value)
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
  -- `sessions.updated` and the refresh reply do not carry `can_delete` on the
  -- wire; a capability change is only visible in the refreshed cache entry.
  self:refresh_capabilities()
  self:refresh_view()
end

---Re-read the cached agent states and merge only `can_delete`.
---
---The restart of the catalog during a refresh can change an agent's delete
---capability (a managed update, a different adapter); the cached state is the
---only place the service records it. Rows are untouched, so this cannot
---resurrect a stale snapshot.
function Browser:refresh_capabilities()
  local connection = self.connection
  if not connection then
    return
  end
  local round = self.round
  local seq = self.refresh_seq
  ServiceSessions.cached(connection, function(ok, value)
    if not ok or round ~= self.round or seq ~= self.refresh_seq or not self.connection then
      return
    end
    local states = type(value) == "table" and value.agents or {}
    for agent, cached_state in pairs(states) do
      if self.configured[agent] and type(cached_state) == "table" then
        local state = self.agent_states[agent] or {}
        state.can_delete = cached_state.can_delete
        self.agent_states[agent] = state
      end
    end
    self:refresh_view()
  end)
end

---------------------------------------------------------------------------
-- `here` source
---------------------------------------------------------------------------

---List the panel agent's sessions in the editor directory.
---@param cb fun(ok: boolean, rows: table[])|nil
function Browser:fetch_live(cb)
  local S = self:get_state()
  if not self:panel_ready() or not self.deps.catalog then
    if cb then
      cb(false, {})
    end
    return
  end
  local cfg = self:config()
  local client, generation = S.conn.client, self.deps.generation and self.deps.generation() or nil
  self.here_client, self.here_generation = client, generation
  local round = self.round
  self.here_refreshing = true
  self:refresh_view()
  self.deps.catalog:list(self.deps.resolve_cwd(), function(ok, sessions)
    if round ~= self.round then
      return
    end
    self.here_refreshing = false
    if not ok then
      self:refresh_view()
      if cb then
        cb(false, {})
      end
      return
    end
    local rows = {}
    for _, info in ipairs(sessions or {}) do
      if type(info) == "table" and type(info.sessionId) == "string" then
        local cwd = type(info.cwd) == "string" and info.cwd ~= "" and info.cwd or self.deps.resolve_cwd()
        rows[#rows + 1] = {
          agent = cfg.agent,
          sessionId = info.sessionId,
          cwd = cwd,
          title = info.title,
          updatedAt = info.updatedAt,
          createdAt = info.createdAt,
          source = "live",
        }
      end
    end
    self.here_rows = rows
    self:refresh_view()
    if cb then
      cb(true, rows)
    end
  end)
end

---------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------

---The table the browser renders from.
---@return table
function Browser:view()
  local cfg = self:config() or {}
  local S = self:get_state()
  local current = S.sess and S.sess.current or nil
  local entries
  if self.scope == "here" then
    entries = self.here_rows
  elseif self.scope == "agent" then
    entries = {}
    for _, entry in ipairs(self.catalog_entries) do
      if entry.agent == cfg.agent then
        entries[#entries + 1] = entry
      end
    end
  else
    entries = self.catalog_entries
  end
  local refreshing = {}
  if self.scope == "here" then
    refreshing[cfg.agent] = self.here_refreshing
  else
    refreshing = self.refreshing
  end
  local agents
  if self.scope == "all" then
    agents = self.agents
  else
    agents = { cfg.agent }
  end
  return {
    scopes = self:available_scopes(),
    scope = self.scope,
    entries = entries,
    agents = agents,
    agent_state = self.agent_states,
    refreshing = refreshing,
    unavailable = self.catalog_state == true and self.unavailable or {},
    current_agent = cfg.agent,
    current_id = current and current.id or nil,
    use_icons = type(cfg.ui) == "table" and cfg.ui.icons or nil,
    status = self.status,
    can_delete = function(entry)
      return self:can_delete(entry)
    end,
    on_open = function(entry)
      self:open_row(entry)
    end,
    on_delete = function(entry, done)
      self:delete_row(entry, done)
    end,
    on_refresh = function()
      self:refresh()
    end,
    on_cycle_scope = function()
      self:cycle_scope()
    end,
    on_close = function()
      self:window_closed()
    end,
    is_dir = self.deps.is_dir or function(path)
      return vim.fn.isdirectory(path) == 1
    end,
  }
end

function Browser:refresh_view()
  if self.ui then
    self.ui:update(self:view())
  end
end

---Drop the listener and invalidate every callback of the current round.
function Browser:release()
  self.round = self.round + 1
  self.refreshing = {}
  self.here_refreshing = false
  local connection = self.connection
  self.connection = nil
  self.catalog_state = nil
  self.catalog_started = false
  if connection then
    ServiceSessions.unsubscribe(connection, self.channel)
  end
  -- An `open` waiting for the handshake must not fire after the window closed
  -- or the browser was replaced.
  local hello = self.hello_connection
  self.hello_connection = nil
  if hello and type(hello.on_hello) == "function" then
    pcall(hello.on_hello, hello, self.channel, nil)
  end
end

---The window closed on its own (q, <Esc>, or losing focus).
function Browser:window_closed()
  if self.ui == nil then
    -- `close_window` detached the handle and releases itself.
    return
  end
  self.ui = nil
  self:release()
end

---Forget this browser: used when a reconfiguration replaces it.
function Browser:dispose()
  self.disposed = true
  self:close_window()
end

---Close the window and drop listeners, ignoring any request still in flight.
function Browser:close_window()
  local ui = self.ui
  -- Detach the handle first: the window's own close notification must not try
  -- to release a second time (and double-bump the round).
  self.ui = nil
  if ui then
    pcall(ui.close, ui)
  end
  self:release()
end

---@param scopes string[]
---@param requested string|nil
---@return string
function Browser:choose_scope(scopes, requested)
  local function has(scope)
    for _, candidate in ipairs(scopes) do
      if candidate == scope then
        return true
      end
    end
  end
  if requested and has(requested) then
    return requested
  end
  if has("here") then
    return "here"
  end
  if has("agent") then
    return "agent"
  end
  return scopes[1]
end

---Open the browser.
---
---`:Ade sessions` requests `here` and `:Ade sessions all` requests `all`; a
---missing scope falls back to the next available one (here -> agent -> all).
---@param requested string|nil "here" | "agent" | "all"
function Browser:open(requested)
  if self.disposed then
    return
  end
  local cfg = self:config()
  if type(cfg) ~= "table" then
    return
  end
  if self.ui and self.ui:is_open() then
    return
  end
  requested = requested or "here"
  self.pending_scope = requested
  -- One round per opening, before any catalog request can carry it.
  self.round = self.round + 1
  local round = self.round

  local panel = self:panel_ready()
  local backend = cfg.backend or "direct"
  local catalog_capable = backend == "service" or backend == "auto"
  -- The availability check decides whether the scope line offers `agent` and
  -- `all`; the catalog's cached read and refresh start only when one is shown.
  if self.catalog_state == nil and catalog_capable then
    if self:prepare_catalog(false) == nil then
      -- The handshake is still running. When the effective scope needs the
      -- catalog (the requested one, or every scope because `here` is missing),
      -- wait for the hello and reopen; otherwise `here` can open now.
      local needs_catalog = requested ~= "here" or not panel
      if needs_catalog then
        return
      end
    end
  end

  local scopes = self:available_scopes()
  if #scopes == 0 then
    self:notify("No agent process is running", vim.log.levels.WARN)
    return
  end

  self.scope = self:choose_scope(scopes, requested)
  self.status = nil
  self.scope_hint_shown = false
  if self.scope == "here" then
    self.here_rows = {}
    self:fetch_live(function(ok, rows)
      if round ~= self.round then
        return
      end
      if not ok then
        return
      end
      if #rows == 0 then
        self:notify("No stored sessions found", vim.log.levels.INFO)
        return
      end
      self:open_window()
    end)
    return
  end
  -- The effective scope is `agent`/`all` (here was skipped or the request fell
  -- back to the agent). Start the catalog exactly once for this round.
  if self.catalog_state == true then
    self:start_catalog(self.connection)
  end
  self:open_window()
end

---Open the configured picker with the current state.
function Browser:open_window()
  local cfg = self:config() or {}
  local backend = type(cfg.ui) == "table" and cfg.ui.session_picker or nil
  local handle
  if self.deps.ui then
    handle = self.deps.ui.open(self:view())
  else
    local presenter = self.deps.presenter or require("ade.app.presenter")
    handle = presenter.open_session_browser(self:view(), backend)
  end
  self.ui = handle
  if handle then
    self:refresh_view()
  end
end

---Switch scope, refreshing the newly visible source.
---@param scope string
function Browser:set_scope(scope)
  if scope == self.scope then
    return
  end
  self.scope = scope
  self.status = nil
  if scope == "here" then
    self:fetch_live()
    return
  end
  if self.catalog_state == true then
    self:start_catalog(self.connection)
  end
  self:refresh_view()
end

---`<Tab>`: here -> agent -> all -> here.
function Browser:cycle_scope()
  if self.catalog_state == nil then
    local prepared = self:prepare_catalog(false)
    if prepared == nil then
      self:notify("the service is still connecting; try again in a moment", vim.log.levels.INFO)
      return
    end
  end
  local scopes = self:available_scopes()
  if #scopes <= 1 then
    if not self.scope_hint_shown then
      self.scope_hint_shown = true
      self:notify("The session manager needs the ade service; showing this agent's sessions", vim.log.levels.WARN)
    end
    return
  end
  local index = 1
  for position, candidate in ipairs(scopes) do
    if candidate == self.scope then
      index = position
      break
    end
  end
  self:set_scope(scopes[index % #scopes + 1])
end

---`<C-r>`: refresh the source behind the current scope.
function Browser:refresh()
  if self.scope == "here" then
    self:fetch_live()
  elseif self.catalog_state == true then
    self:refresh_catalog()
  end
end

---------------------------------------------------------------------------
-- actions
---------------------------------------------------------------------------

---Whether a row may be deleted.
---
---The panel agent answers from its own client capability; every other agent
---uses the catalog's `can_delete` (unknown/absent: allow, the service then
---answers -32073).
---@param entry table
---@return boolean
function Browser:can_delete(entry)
  local cfg = self:config() or {}
  local S = self:get_state()
  if entry.agent == cfg.agent and self:panel_ready() then
    return capabilities.supports(capabilities.agent(S.conn.client), "sessionCapabilities.delete")
  end
  local state = self.agent_states and self.agent_states[entry.agent]
  if state and state.can_delete == false then
    return false
  end
  return true
end

---Open one row: live rows load on the panel, catalog rows use the manager path.
---@param entry table
function Browser:open_row(entry)
  if type(entry) ~= "table" or type(entry.sessionId) ~= "string" then
    return
  end
  if entry.source == "live" then
    local S = self:get_state()
    if S.conn.client ~= self.here_client then
      return
    end
    if self.deps.generation and self.deps.generation() ~= self.here_generation then
      return
    end
    if self:panel_ready() and S.sess and S.sess.service then
      self:close_window()
      S.sess.service:load(entry.sessionId)
    end
    return
  end
  self:load_catalog_row(entry)
end

---Delete one row, through the panel or the service (PROTOCOL.md 21.8).
---@param entry table
---@param done fun(ok: boolean)
function Browser:delete_row(entry, done)
  done = done or function() end
  if type(entry) ~= "table" or type(entry.sessionId) ~= "string" then
    done(false)
    return
  end
  local cfg = self:config() or {}
  local S = self:get_state()
  if self:panel_ready() and entry.agent == cfg.agent then
    -- The panel's own agent: the tunnel path, with the local cleanup and the
    -- new session when the current one is deleted.
    if S.sess and S.sess.service then
      S.sess.service:delete(entry.sessionId, function(ok)
        if ok then
          self:forget_row(entry)
        end
        done(ok)
      end)
    else
      done(false)
    end
    return
  end
  self:delete_remote(entry, done)
end

---Delete a row of an agent the panel is not connected to.
---@param entry table
---@param done fun(ok: boolean)
function Browser:delete_remote(entry, done)
  local connection = self.connection
  if self.catalog_state ~= true or not connection then
    self:notify("The session manager needs the ade service to delete another agent's session", vim.log.levels.WARN)
    done(false)
    return
  end
  if type(connection.has_feature) == "function" and not connection:has_feature("sessions.delete") then
    self:notify(
      "this service is too old to delete another agent's sessions; run :Ade service install",
      vim.log.levels.WARN
    )
    done(false)
    return
  end
  local params
  for _, candidate in ipairs(self.params or {}) do
    if candidate.agent == entry.agent then
      params = candidate
      break
    end
  end
  if not params then
    local reason = self.unavailable[entry.agent] or "the agent is not available"
    self:notify(
      string.format("unable to delete the session: %s (%s)", tostring(reason), entry.agent),
      vim.log.levels.WARN
    )
    done(false)
    return
  end
  ServiceSessions.delete(connection, params, entry.sessionId, function(ok, value)
    if ok then
      last_sessions.forget_session(entry.agent, entry.sessionId)
      self:forget_row(entry)
      done(true)
      return
    end
    local code = type(value) == "table" and value.code or nil
    local message
    if code == -32073 then
      message = "this agent cannot delete sessions"
    elseif code == -32074 then
      message = "the session is open in a running agent instance"
    elseif type(value) == "table" and type(value.message) == "string" then
      -- Any other agent error (auth, missing directory, ...) is shown as the
      -- service reported it.
      message = "unable to delete the session: " .. value.message
    else
      message = "unable to delete the session: " .. tostring(value or "the service did not answer")
    end
    local known = code == -32073 or code == -32074
    self:notify(message, known and vim.log.levels.WARN or vim.log.levels.ERROR)
    done(false)
  end)
end

---Drop one row from both in-memory views after a successful delete.
---@param entry table
function Browser:forget_row(entry)
  local function drop(list)
    local kept = {}
    for _, row in ipairs(list or {}) do
      if not (row.agent == entry.agent and row.sessionId == entry.sessionId) then
        kept[#kept + 1] = row
      end
    end
    return kept
  end
  self.here_rows = drop(self.here_rows)
  self.catalog_entries = drop(self.catalog_entries)
  self:refresh_view()
end

---Whether the panel's live connection already runs in `cwd` for `agent`.
---@param cfg table
---@param agent string
---@param cwd string
---@return boolean
function Browser:connected_in(cfg, agent, cwd)
  local S = self:get_state()
  if cfg.agent ~= agent or S.conn.phase ~= "ready" then
    return false
  end
  local client = S.conn.client
  return client ~= nil and same_dir(client.cwd, cwd)
end

---Load one catalog row (the previous session manager's path).
---@param entry table
function Browser:load_catalog_row(entry)
  local cwd = entry.cwd
  local is_dir = self.deps.is_dir or function(path)
    return vim.fn.isdirectory(path) == 1
  end
  if type(cwd) ~= "string" or cwd == "" or not is_dir(cwd) then
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

  -- A failed setup leaves the browser open so the person can pick again.
  if self:connected_in(cfg, entry.agent, cwd) then
    self:load_on_current(entry, cwd)
    return
  end
  self:load_with_new_connection(entry, cwd, cfg)
end

---Path 3: the live connection already serves this agent and directory.
---@param entry table
---@param cwd string
function Browser:load_on_current(entry, cwd)
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
function Browser:load_with_new_connection(entry, cwd, cfg)
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
    -- The confirmation picker takes focus; keep the browser open until it
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
