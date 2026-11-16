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
  --
  -- When nothing was injected, read the effective config directly. Commands
  -- (`:Ade service agents` and friends) use `shared()` without going through
  -- the chat path, and used to get an unconfigured object: `service.path` was
  -- then ignored and the command reported "not installed" even though `start`
  -- had just used that binary.
  local config = self.opts.config
  if config == nil then
    local ok, value = pcall(function()
      return require("ade.config").effective()
    end)
    config = ok and value or nil
  end
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
    local service = self:service_config()
    started, start_err = require("ade.service.launcher").ensure({
      bin = resolved.path,
      config = self.opts.config,
      timeout = self.opts.timeout or 5000,
      idle_timeout = self.idle_timeout or service.idle_timeout,
      -- Event-log flags only apply to a service this call starts; PROTOCOL.md 15.
      event_log = service.event_log,
      event_log_max_mb = service.event_log_max_mb,
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
    -- An incompatible api_version is a different problem from a stale build: the
    -- wire protocol changed. Retry once with the version the service reports, so
    -- a service that is merely older can still be asked whether it is idle
    -- (see `version_check`), and only then give up.
    local retried = self:handshake_retry(client, info)
    if not retried then
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
    info = retried
  end
  -- A different version on the same api_version means the plugin was updated
  -- while an old service kept running. Reconcile it, preferably by restarting an
  -- idle service onto the new binary.
  local checker = require("ade.service.version_check").new({
    config = function()
      return self:service_config_all()
    end,
    request_sync = function(method, params, timeout)
      return self:request_sync(method, params, timeout)
    end,
    restart = function(done)
      -- Restart through the same path as everything else: stop the service, then
      -- bring it back up. `restart_service` is injectable for tests.
      self:restart_service(done)
    end,
    -- PROTOCOL.md 3.2: the app layer supplies `notify`; without it the user
    -- never sees the version notice (the old code only logged). Falling back to
    -- `vim.notify` keeps commands (`:Ade service agents`) that build the shared
    -- connection without a panel from swallowing it.
    notify = function(message, level)
      pcall(log.warn, "%s", message)
      local target = self.opts.notify
      if type(target) == "function" then
        pcall(target, message, level)
      else
        pcall(vim.notify, "ade.nvim: " .. tostring(message), level or vim.log.levels.INFO)
      end
    end,
  })
  local usable = checker:check(info, function()
    -- The restart finished later (shutdown + reconnect round-trips). Report the
    -- connection as usable now: `ensure` cannot wait indefinitely, and the
    -- restart's own notification says what happened.
    if not self.connecting then
      return
    end
    self.version_info = info
    self:finish(true, nil)
  end)
  if usable == "pending" then
    -- The checker will resolve the handshake; do not finish twice.
    return
  end
  if not usable then
    self.client = nil
    client:close()
    self:finish(false, "the running service is not usable")
    return
  end
  self.version_info = info
  self:finish(true, nil)
end

---Retry the handshake after `-32002`, using the version the service reports.
---
---PROTOCOL.md 3.1: the error carries `data.server_api_version`. Sending that
---number again lets an older service complete the handshake so the idle probe
---below can decide whether it may be replaced. Returns the handshake result, or
---nil when the retry fails too.
---@param client table
---@param first table the failed handshake error
---@return table|nil info
function Connection:handshake_retry(client, first)
  local data = type(first) == "table" and type(first.data) == "table" and first.data or {}
  local reported = tonumber(data.server_api_version)
  if not reported then
    return nil
  end
  local ok, info = false, nil
  client:connect_with_version(reported, function(connected, value)
    ok, info = connected, value
  end)
  if ok and type(info) == "table" then
    return info
  end
  return nil
end

---The `service` table of the effective configuration.
---@return table
function Connection:service_config()
  local config = self:service_config_all()
  return type(config.service) == "table" and config.service or {}
end

---The effective configuration, as a table.
---@return table
function Connection:service_config_all()
  local config = self.opts.config
  if config == nil then
    local ok, value = pcall(function()
      return require("ade.config").effective()
    end)
    config = ok and value or nil
  end
  if type(config) == "function" then
    local ok, value = pcall(config)
    config = ok and value or nil
  end
  return type(config) == "table" and config or {}
end

---Stop the service and start it again, then report through `done`.
---
---Injectable: tests replace it, so the version logic can be exercised without a
---process. The real path is `shutdown` on the client, then one more `ensure`.
---@param done fun(ok: boolean, err: string|nil)
function Connection:restart_service(done)
  if self.restart_service_impl then
    self.restart_service_impl(done)
    return
  end
  local client = self.client
  local function start_again()
    self.client = nil
    -- This runs *inside* an `ensure` (the version check is part of the
    -- handshake), so the in-flight state has to be cleared first: a second
    -- `ensure` while `connecting` is true would only queue another waiter and
    -- the restart would never be attempted. The original callers are resolved
    -- from here, because the nested `ensure` owns `waiters` now.
    local waiters = self.waiters or {}
    self.connecting = false
    self.waiters = nil
    self:ensure(function(ok, err)
      -- `ensure` may have been refused because `closed` is set; that is not a
      -- restart failure of the service.
      for _, waiter in ipairs(waiters) do
        pcall(waiter, ok, err)
      end
      done(ok == true, err)
    end)
  end
  if not client or not client:is_ready() then
    start_again()
    return
  end
  local answered = false
  client:shutdown(function()
    answered = true
    start_again()
  end)
  if not answered then
    -- A wedged service: report rather than hang.
    done(false, "the service did not answer shutdown")
  end
end

---Install the notification fan-out and the disconnect hook on a client.
---@param client table
function Connection:install_handlers(client)
  for _, method in ipairs(NAMES) do
    client:on(method, function(payload)
      self:dispatch(method, payload)
    end)
  end
  client.on_disconnect_cb = function(reason, intentional)
    self:on_disconnect(type(reason) == "string" and reason or tostring(reason), intentional == true)
  end
end

---Report a dropped connection once, to every channel.
---
---The shared object stays usable on purpose: an unexpected drop or a user-issued
---`:Ade service stop` only ends *this* socket. The channels attached to it report
---their exit, and a later `ensure()` starts a new service and re-attaches. Only
---`close()` is permanent.
---@param reason string
---@param intentional boolean|nil the disconnecting client carried a stop intent
function Connection:on_disconnect(reason, intentional)
  if self.closed then
    return
  end
  self.error = tostring(reason)
  self.client = nil
  log.warn("service connection lost: %s", self.error)
  -- `intentional` tells the application whether automatic reconnection should
  -- kick in: a user-issued `:Ade service stop` or `:Ade disconnect` is not an
  -- accident, and retrying would fight the user. The intent lives on the
  -- client that is being lost, so a later client (a real connection) does not
  -- inherit it.
  self:dispatch("__disconnected", { reason = self.error, intentional = intentional == true })
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

---Wait for one reply from an already-connected client.
---
---The single implementation of "bounded wait for a request" in the service
---layer: `Connection:request_sync` and `Status.collect` both go through it, so
---there is one timeout behaviour and one error wording. `vim.wait` appears here
---and nowhere else for requests.
---
---`Status.collect` keeps its own client because its probe must stay read-only
---(calling `ensure()` would start a service the health check is only supposed
---to describe).
---@param client table an `ade.service.client`
---@param method string
---@param params any
---@param timeout_ms integer|nil
---@return boolean ok
---@return any value result, or `{code, message}` on failure/timeout
function M.await_request(client, method, params, timeout_ms)
  local wait_ms = timeout_ms or 2000
  local done, ok, value = false, false, nil
  client:request(method, params, function(result_ok, result_value)
    done, ok, value = true, result_ok, result_value
  end)
  if not done then
    vim.wait(wait_ms, function()
      return done
    end, 10)
  end
  if not done then
    return false,
      {
        code = -32000,
        message = string.format("the service did not answer %s within %.1f seconds", method, wait_ms / 1000),
      }
  end
  return ok, value
end

---Send one request and **wait** for the reply.
---
---For the few callers that must produce a result synchronously: the health
---check and `:Ade service status` (they build a text report) and `commands`
---helpers that already ran asynchronously elsewhere. Waiting is bounded, and a
---missing reply is reported as an error with a reason — never as a silent nil,
---which is what made `agent.list` look empty.
---
---The request itself is still the normal asynchronous one: this only adds the
---wait, so the ordering is unchanged.
---@param method string
---@param params any
---@param timeout_ms integer|nil
---@return boolean ok
---@return any value result, or `{code, message}` on failure/timeout
function Connection:request_sync(method, params, timeout_ms)
  local wait_ms = timeout_ms or 2000
  -- Connect first (this is the caller that may start a service), then use the
  -- one bounded-wait implementation.
  local ready, connect_err = false, nil
  self:ensure(function(ok, err)
    ready, connect_err = ok, err
  end)
  if not ready then
    return false, { code = -32000, message = connect_err or "the service is unavailable" }
  end
  if not self.client then
    return false, { code = -32000, message = "the service connection is gone" }
  end
  return M.await_request(self.client, method, params, wait_ms)
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

---Tell the panel the user asked the service to stop.
---
---The EOF payload normally carries that intent, but `:Ade service stop` can run
---while the socket is already gone — the reconnect loop is between backoff
---attempts — and then no EOF ever arrives to cancel it. A dedicated
---notification covers both cases; `bootstrap.lua` handles it like an
---intentional `__disconnected`.
function Connection:stopped_intent()
  self:dispatch("__stopped", { intentional = true })
end

---Stop the service itself (`:Ade service stop`).
---
---The stop intent lives on the client that carries the request
---(`Client.shutdown_requested`), so every disconnect it later reports is
---deliberate — a prompt close, a late success reply, an EOF while the service
---exits. A new client starts without the intent, so a later real drop still
---reconnects.
---
---A refusal (`ok == false`) keeps the client attached and usable; a timeout
---(`value.pending`) keeps it attached too, because the user's stop is still in
---flight. Reports exactly once.
---@param cb fun(ok: boolean, value: any)|nil
---@param timeout integer|nil
function Connection:shutdown(cb, timeout)
  -- Tell the panel before asking: a slow or unanswered shutdown produces no
  -- EOF, and the retry loop must not keep starting services in the background.
  self:stopped_intent()
  if not self:is_connected() then
    if cb then
      cb(false, "not connected")
    end
    return
  end
  local client = self.client
  client:shutdown(function(ok, value)
    if ok and self.client == client then
      -- The service confirmed; `Client:shutdown` closes the socket next, and
      -- the close carries this client's stop intent.
      self.client = nil
    end
    -- On refusal/timeout the client stays: it is the live socket, and closing
    -- it here would report a drop nobody asked for. `Client:shutdown` already
    -- revoked the intent on a refusal and kept it on a timeout.
    if cb then
      cb(ok, value)
    end
  end, timeout)
end

return M
