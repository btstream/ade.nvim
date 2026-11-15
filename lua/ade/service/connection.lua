-- One shared connection to nvim_ade_server per Neovim.
--
-- Every agent instance channel goes through this object, so a panel with two
-- sessions (or a conversation and an inline turn) uses one socket instead of
-- one each. Connecting is lazy: the service is only started when something
-- actually needs it.
--
-- The connection is deliberately thin. It owns:
--
--   * `ensure()` — resolve the binary, start the service if needed, connect and
--     `hello`;
--   * `request`/`notify` — pass-throughs;
--   * subscription fan-out: every `tunnel.recv`, `agent.exited` and
--     `tunnel.error` is delivered to the listeners registered here, which are
--     the instance channels.
--
-- Losing the connection is reported once to every listener. There is no
-- automatic reconnection in this stage (S1b): the design says a later attach
-- restores the conversation, so silently reconnecting now would hide the state
-- from the UI instead of showing it.
local log = require("ade.log")
local Client = require("ade.service.client")
local Version = require("ade.service.version")

local M = {}

---@class AdeServiceConnection
---@field client table|nil
---@field listeners table<string, table<string, fun(payload: any)>>
---@field connecting boolean
---@field error string|nil
local Connection = {}
Connection.__index = Connection

---Listeners are keyed per channel and per notification name so one channel
---cannot accidentally receive another's messages.
local NAMES = { "tunnel.recv", "agent.exited", "tunnel.error" }

---@param opts {paths?: table, timeout?: integer, resolve_binary?: fun(): table|nil,string|nil,
---  ensure_service?: fun(): boolean,string|nil, client?: table, idle_timeout?: integer}|nil
---@return AdeServiceConnection
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    opts = opts,
    client = nil,
    listeners = {},
    connecting = false,
    error = nil,
    -- Injectable for tests: the real ones resolve the binary and start the
    -- service. Keeping them as fields means the unit tests never spawn a
    -- process, and the "not installed" path is testable without a service.
    resolve_binary = opts.resolve_binary,
    ensure_service = opts.ensure_service,
    client_factory = opts.client_factory,
    idle_timeout = opts.idle_timeout,
    closed = false,
  }, Connection)
end

---The process-wide connection. Created on first use so requiring this module
---in a headless script does not touch the environment.
---@type AdeServiceConnection|nil
local shared = nil

---@return AdeServiceConnection
function M.shared()
  if not shared then
    shared = M.new()
  end
  return shared
end

---Replace the shared connection. Tests use this to inject a fake service; the
---plugin itself never calls it outside of `setup`.
---@param conn AdeServiceConnection|nil
function M.set_shared(conn)
  if shared and shared ~= conn then
    shared:close("replaced")
  end
  shared = conn
end

---@return string|nil
function Connection:last_error()
  return self.error
end

---@return boolean
function Connection:is_connected()
  return self.client ~= nil and self.client:is_ready()
end

---Register a listener for one notification name.
---@param channel_id string
---@param method string
---@param fn fun(payload: any)
function Connection:subscribe(channel_id, method, fn)
  self.listeners[method] = self.listeners[method] or {}
  self.listeners[method][channel_id] = fn
end

---@param channel_id string
---@param method string
function Connection:unsubscribe(channel_id, method)
  local list = self.listeners[method]
  if list then
    list[channel_id] = nil
  end
end

---Remove every subscription a channel made.
---@param channel_id string
function Connection:unsubscribe_all(channel_id)
  for _, method in ipairs(NAMES) do
    self:unsubscribe(channel_id, method)
  end
end

---Deliver one notification to the channels interested in it.
---@param method string
---@param payload any
function Connection:dispatch(method, payload)
  local list = self.listeners[method]
  if not list then
    return
  end
  -- Sorted by channel id: iteration order over a hash table is not stable, and
  -- callers (tests, and a future "the primary channel answers") need a
  -- deterministic delivery order.
  local ids = {}
  for id in pairs(list) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  -- Resolve the callbacks first: a listener may unsubscribe from inside its own
  -- callback (a channel that decides it is done), and mutating the table while
  -- iterating would skip a sibling.
  local targets = {}
  for _, id in ipairs(ids) do
    targets[#targets + 1] = { id = id, fn = list[id] }
  end
  for _, target in ipairs(targets) do
    if type(target.fn) == "function" then
      local ok, err = pcall(target.fn, payload)
      if not ok then
        log.error("service listener %s for %s failed: %s", target.id, method, tostring(err))
      end
    end
  end
end

---Whether the configured backend may use the service.
---@param backend string|nil
---@return boolean
function M.wants_service(backend)
  return backend == "service" or backend == "auto"
end

---Resolve the binary through `install.resolve_binary`, the single entry point.
---@return table|nil resolved
---@return string|nil err
function Connection:resolve()
  if self.resolve_binary then
    return self.resolve_binary()
  end
  -- `opts.config` may be the live config function (the plugin) or a table
  -- (tests). Both are accepted here so `service.path` is read from the same
  -- place the rest of the plugin reads it.
  local config = self.opts.config
  if type(config) == "function" then
    local ok, value = pcall(config)
    config = ok and value or nil
  end
  local service = type(config) == "table" and type(config.service) == "table" and config.service or {}
  return require("ade.service.install").resolve_binary({
    path = service.path,
    config = type(config) == "table" and config or nil,
    timeout = service.start_timeout,
  })
end

---Start the service when needed and connect.
---
---Only `close()` (the editor is exiting) is permanent. A dropped socket or an
---explicit `:Ade service stop` merely invalidates the current client: the next
---call starts the service again and greets it, which is what PROTOCOL.md 7 and
---9 promise. Concurrent callers share one attempt.
---@param cb fun(ok: boolean, err: string|nil)
function Connection:ensure(cb)
  if self.closed then
    cb(false, "service connection was closed")
    return
  end
  if self:is_connected() then
    cb(true, nil)
    return
  end
  -- A client that is present but not connected is a dead socket: drop it so the
  -- reconnect below cannot reuse it.
  if self.client and not self.client:is_ready() then
    local stale = self.client
    self.client = nil
    pcall(stale.close, stale)
  end
  if self.connecting then
    -- A second caller during the handshake waits for the same result instead of
    -- opening a second socket.
    self.waiters = self.waiters or {}
    self.waiters[#self.waiters + 1] = cb
    return
  end
  self.connecting = true
  self.waiters = { cb }
  self.error = nil

  local resolved, err = self:resolve()
  if not resolved then
    self:finish(false, err)
    return
  end

  local started, start_err
  if self.ensure_service then
    started, start_err = self.ensure_service(resolved)
  else
    started, start_err = require("ade.service.launcher").ensure({
      bin = resolved.path,
      config = self.opts.config,
      timeout = self.opts.timeout or 5000,
      idle_timeout = self.idle_timeout,
    })
  end
  if not started then
    self:finish(false, start_err)
    return
  end

  local client = (self.client_factory or Client).new({
    timeout = self.opts.timeout or 5000,
    -- Shared with the direct transport so a streaming agent gets the same
    -- bounded slices whichever backend opened the connection.
    scheduler = self.opts.scheduler,
    dispatch_budget_ms = self.opts.dispatch_budget_ms,
  })
  self.client = client
  self:install_handlers(client)
  local ok, info
  client:connect(function(connected, value)
    ok, info = connected, value
  end)
  if not ok then
    self.client = nil
    self:finish(false, type(info) == "table" and (info.message or vim.inspect(info)) or tostring(info))
    return
  end
  if type(info) == "table" and info.api_version ~= nil and info.api_version ~= Version.API_VERSION then
    self.client = nil
    client:close()
    self:finish(
      false,
      string.format(
        "the service speaks api_version %s but this plugin needs %d; run :Ade service install",
        tostring(info.api_version),
        Version.API_VERSION
      )
    )
    return
  end
  self:finish(true, nil)
end

---Install the notification fan-out and the disconnect hook on a client.
---@param client table
function Connection:install_handlers(client)
  for _, method in ipairs(NAMES) do
    client:on(method, function(payload)
      self:dispatch(method, payload)
    end)
  end
  client.on_disconnect_cb = function(reason)
    self:on_disconnect(type(reason) == "string" and reason or tostring(reason))
  end
end

---Report a dropped connection once, to every channel.
---
---The shared object stays usable on purpose: an unexpected drop or a user-issued
---`:Ade service stop` only ends *this* socket. The channels attached to it report
---their exit, and a later `ensure()` starts a new service and re-attaches. Only
---`close()` is permanent.
---@param reason string
function Connection:on_disconnect(reason)
  if self.closed then
    return
  end
  self.error = tostring(reason)
  self.client = nil
  log.warn("service connection lost: %s", self.error)
  self:dispatch("__disconnected", { reason = self.error })
end

---Resolve the in-flight `ensure` callers.
---@param ok boolean
---@param err string|nil
function Connection:finish(ok, err)
  self.connecting = false
  if not ok then
    self.error = err or "the service is unavailable"
  end
  local waiters = self.waiters or {}
  self.waiters = nil
  for _, cb in ipairs(waiters) do
    pcall(cb, ok, err)
  end
end

---Send one request, connecting first when needed.
---@param method string
---@param params any
---@param cb fun(ok: boolean, value: any)|nil
function Connection:request(method, params, cb)
  self:ensure(function(ok, err)
    if not ok then
      if cb then
        cb(false, { code = -32000, message = err or "the service is unavailable" })
      end
      return
    end
    self.client:request(method, params, cb)
  end)
end

---Send one notification, connecting first when needed.
---@param method string
---@param params any
function Connection:notify(method, params)
  self:ensure(function(ok)
    if ok then
      self.client:notify(method, params)
    end
  end)
end

---Close for good: the editor is exiting.
---
---This is the only permanent state. `shutdown()` (the user stopped the service)
---and a dropped socket both leave the object reusable.
---@param reason string|nil
function Connection:close(reason)
  self.closed = true
  local client = self.client
  self.client = nil
  if client then
    client:close()
  end
  self.error = reason or "closed"
end

---Stop the service itself (`:Ade service stop`).
---@param cb fun(ok: boolean, value: any)|nil
function Connection:shutdown(cb)
  if not self:is_connected() then
    if cb then
      cb(false, "not connected")
    end
    return
  end
  self.client:shutdown(function(ok, value)
    -- The user stopped the service; they did not forbid using it later, so the
    -- connection object stays reusable (`on_disconnect` already cleared the
    -- client).
    self.client = nil
    if cb then
      cb(ok, value)
    end
  end)
end

return M
