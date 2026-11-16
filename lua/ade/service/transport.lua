-- The service-backed transport: same interface as `ade.transport.process`.
--
-- `Client:do_start` starts its agent through a transport module and only uses
-- the returned object's `write`, `stop`, `is_alive`, `mark_phase`, `stats` and
-- `stderr`. This module implements exactly that on top of the shared service
-- connection, so every piece of ACP logic (initialize, timeouts, cancellation
-- draining, permissions, elicitation) keeps running unchanged — only the pipe
-- to the agent moves from a local child process into nvim_ade_server.
--
-- Wire shape (service/PROTOCOL.md, api_version 2):
--
--   agent.attach {key, client_capabilities, env}      -> {instance, created, ...}
--   tunnel.send  {instance, message}                  (notification)
--   tunnel.recv  {instance, seq, message}             (notification)
--   agent.exited {instance, code, signal, stderr_tail}(notification)
--   tunnel.error {instance, code, message, id?}       (notification)
--   agent.stop   {instance, force?}                   -> {exited, code, signal}
--   agent.detach {instance}                           -> {}
local log = require("ade.log")

local M = {}

---@class AdeServiceChannel
---@field instance string|nil
---@field attached boolean
---@field alive boolean
---@field stopping boolean
---@field pending string[] frames queued until attach completes
---@field stats table
local Channel = {}
Channel.__index = Channel

local function new_stats()
  return {
    phase = nil,
    sent = 0,
    received = 0,
    received_bytes = 0,
    dropped = 0,
    attach_ms = nil,
    detach = false,
    instance = nil,
  }
end

---Build the complete child environment.
---
---The service replaces the child environment wholesale when `env` is present, so
---the front end has to send everything the agent would otherwise inherit. Agent
---configuration wins over the editor's environment, matching `process.spawn`.
---@param extra table<string, string>|nil
---@return table<string, string>
function M.child_env(extra)
  local env = {}
  local ok, current = pcall(vim.fn.environ)
  if ok and type(current) == "table" then
    for key, value in pairs(current) do
      if type(key) == "string" and type(value) == "string" then
        env[key] = value
      end
    end
  end
  for key, value in pairs(extra or {}) do
    if type(key) == "string" and type(value) == "string" then
      env[key] = value
    end
  end
  return env
end

---Start one agent instance through the service.
---
---Returns a process-compatible object immediately. The `agent.attach` request
---is asynchronous, so frames written before the reply are queued and flushed in
---order once the instance exists; that is what lets `Client:do_start` send
---`initialize` without waiting for the attach round trip.
---@param opts table `process.spawn` options plus `connection`, `agent_id`,
---  `client_capabilities`, `keep_alive`, `on_message`
---@return AdeServiceChannel|nil channel
---@return string|nil err
function M.spawn(opts)
  local connection = opts.connection
  if not connection then
    return nil, "no service connection"
  end

  local self = setmetatable({
    connection = connection,
    agent_id = opts.agent_id or "agent",
    alive = true,
    attached = false,
    stopping = false,
    detached = false,
    pending = {},
    stats = new_stats(),
    on_line = opts.on_line,
    on_message = opts.on_message,
    on_exit = opts.on_exit,
    stderr_tail = "",
    keep_alive = opts.keep_alive ~= false,
    initialized = false,
    failed = nil,
  }, Channel)
  self.channel_id = string.format("%s-%d", self.agent_id, tostring(vim.uv.hrtime()))

  connection:subscribe(self.channel_id, "tunnel.recv", function(payload)
    self:on_recv(payload)
  end)
  connection:subscribe(self.channel_id, "agent.exited", function(payload)
    self:on_exited(payload)
  end)
  connection:subscribe(self.channel_id, "tunnel.error", function(payload)
    self:on_tunnel_error(payload)
  end)
  connection:subscribe(self.channel_id, "__disconnected", function(payload)
    self:on_service_lost(payload)
  end)

  local params = {
    key = {
      agent = self.agent_id,
      command = opts.command,
      args = opts.args or {},
      cwd = opts.cwd,
    },
    client_capabilities = opts.client_capabilities or {},
    env = M.child_env(opts.env),
  }
  -- A managed release the service runs needs its own lease (PROTOCOL.md 16.4).
  -- The service writes it before spawning, and keeps it while the instance
  -- lives, so the release survives Neovim exiting (which the Lua lease does
  -- not). `launch` is not part of the instance identity.
  local launch = opts.launch
  if
    type(launch) == "table"
    and launch.source == "managed"
    and type(launch.install_id) == "string"
    and type(opts.manager_root) == "string"
  then
    params.launch = {
      root = opts.manager_root,
      agent = self.agent_id,
      installId = launch.install_id,
    }
  end
  local started = vim.uv.hrtime()
  connection:request("agent.attach", params, function(ok, value)
    if not self.alive or self.stopping then
      return
    end
    if not ok then
      local reason = M.describe(value)
      self:fail(reason)
      return
    end
    if type(value) ~= "table" or type(value.instance) ~= "string" then
      self:fail("the service returned no instance id")
      return
    end
    self.instance = value.instance
    self.stats.instance = value.instance
    self.stats.attach_ms = math.floor((vim.uv.hrtime() - started) / 1e6)
    self.attached = true
    -- The service reports the sessions it already tracks for this instance
    -- (PROTOCOL.md 3.2). The application layer uses them to reopen the most
    -- recent session for this cwd instead of starting an empty one; the
    -- transport only carries the data.
    self.sessions = type(value.sessions) == "table" and value.sessions or nil
    self.created = value.created == true
    if opts.on_attach_result then
      pcall(opts.on_attach_result, value)
    end
    self:flush()
  end)

  return self, nil
end

---Turn a JSON-RPC error into one readable line.
---@param value any
---@return string
function M.describe(value)
  if type(value) == "table" then
    return string.format("%s (code %s)", tostring(value.message or "service error"), tostring(value.code))
  end
  return tostring(value)
end

---@param reason string
function Channel:fail(reason)
  self.failed = reason
  self.alive = false
  -- Keep the reason where `stderr()` reports it, so the Client's exit payload
  -- and `:AdeDebug` surface a useful message instead of an empty tail.
  self.stderr_tail = reason
  self.connection:unsubscribe_all(self.channel_id)
  log.warn("service channel %s failed: %s", self.agent_id, reason)
  -- `agent.exited` carries a stderr tail; an attach failure has none, but the
  -- Client's exit path expects the same shape.
  if self.on_exit then
    pcall(self.on_exit, -1, reason)
  end
end

---Write a JSON line produced by the Client.
---@param payload string
---@return boolean
function Channel:write(payload)
  if not self.alive or self.stopping then
    return false
  end
  if not self.attached then
    self.pending[#self.pending + 1] = payload
    return true
  end
  return self:send(payload)
end

---@param payload string
---@return boolean
function Channel:send(payload)
  -- The Client hands over a complete JSON line. Decode and re-wrap it rather
  -- than splicing strings: the outer envelope has to be valid JSON, and a
  -- textual splice would break for any payload containing a newline escape.
  --
  -- Decoded without `luanil` on purpose, so JSON null round-trips as `null`
  -- instead of disappearing from the object.
  local ok, message = pcall(vim.json.decode, payload)
  if not ok or type(message) ~= "table" then
    log.warn("service channel could not decode an outgoing frame: %s", tostring(payload):sub(1, 200))
    self.stats.dropped = self.stats.dropped + 1
    return false
  end
  self.stats.sent = self.stats.sent + 1
  return self.connection:notify("tunnel.send", { instance = self.instance, message = message })
end

---Flush frames queued while the attach was in flight.
function Channel:flush()
  local pending = self.pending
  self.pending = {}
  for _, payload in ipairs(pending) do
    if not self.alive then
      return
    end
    if not self:send(payload) then
      self.stats.dropped = self.stats.dropped + 1
    end
  end
end

---@param payload table
function Channel:on_recv(payload)
  if not self.alive or type(payload) ~= "table" then
    return
  end
  if payload.instance ~= nil and self.instance ~= nil and payload.instance ~= self.instance then
    return
  end
  local message = payload.message
  if type(message) ~= "table" then
    log.warn("service sent a tunnel.recv without a message object")
    return
  end
  self.stats.received = self.stats.received + 1
  self.stats.received_bytes = self.stats.received_bytes + #vim.json.encode(message)
  if self.on_message then
    pcall(self.on_message, message)
  end
end

---@param payload table
function Channel:on_exited(payload)
  if not self.alive then
    return
  end
  payload = type(payload) == "table" and payload or {}
  -- Instance ids are the only thing that ties an exit to this channel. A stale
  -- `agent.exited` for a previous instance (a stop that finished after a new
  -- attach began) must not kill the channel that replaced it.
  if self.instance == nil or payload.instance ~= self.instance then
    return
  end
  self.stderr_tail = type(payload.stderr_tail) == "string" and payload.stderr_tail or ""
  self:finish_exit(payload.code, self.stderr_tail)
end
---Report a rejected `tunnel.send`.
---
---When the frame carried a request id, the failure is turned into an error
---response for that id, so the Client's pending request fails instead of
---waiting for its timeout.
---@param payload table
function Channel:on_tunnel_error(payload)
  if not self.alive or type(payload) ~= "table" then
    return
  end
  if payload.instance ~= nil and self.instance ~= nil and payload.instance ~= self.instance then
    return
  end
  local code = tonumber(payload.code) or -32025
  local message = tostring(payload.message or "the service rejected a frame")
  log.warn("service tunnel error: %s (code %s)", message, tostring(code))
  if payload.id ~= nil and self.on_message then
    pcall(self.on_message, {
      jsonrpc = "2.0",
      id = payload.id,
      error = { code = code, message = message },
    })
  end
end

---The shared connection dropped: every instance channel reports an exit.
---@param payload table
function Channel:on_service_lost(payload)
  if not self.alive then
    return
  end
  local reason = type(payload) == "table" and tostring(payload.reason or "service connection lost")
    or "service connection lost"
  -- An overflow is the front end's own failure to keep up, and saying so is what
  -- tells the user reconnecting will help. Every other drop is the service's.
  local text
  if reason:find("inbox overflow", 1, true) then
    text = "the editor stopped keeping up with the agent stream (client inbox overflow); reconnecting resumes"
  else
    text = "service connection lost: " .. reason
  end
  self.alive = false
  self.attached = false
  self.connection:unsubscribe_all(self.channel_id)
  log.warn("service channel %s lost its connection: %s", self.agent_id, reason)
  if self.on_exit then
    pcall(self.on_exit, -1, text)
  end
end

---Whether the editor is on its way out.
---
---`vim.v.exiting` is `vim.NIL` in a live editor and a number during shutdown.
---During shutdown the frames must reach the socket before the process ends,
---which is the one case where a bounded wait is justified.
---@return boolean
local function exiting()
  local ok, value = pcall(function()
    return vim.v.exiting
  end)
  return ok and value ~= nil and value ~= vim.NIL
end

---Give an out-of-band request up to `timeout` ms to settle, only while exiting.
---
---Normally `stop`/`leave` never block: the service removes a stopped instance
---from its identity lookup when it processes the request, so the next attach
---already gets a new instance (PROTOCOL.md 3.4 and 9.4). The reply only matters
---for flushing the frame before Neovim goes away.
---@param state table `{done: boolean}`
---@param timeout integer
local function flush_if_exiting(state, timeout)
  if not exiting() or vim.in_fast_event() then
    return
  end
  vim.wait(timeout, function()
    return state.done
  end, 10)
end

---Stop the agent process.
---
---`stop(force)` is the "kill it" path: an explicit disconnect, a login restart,
---a discarded half-started client, or any failure. `leave(allow)` is the
---opposite: the front end is going away on purpose (editor exit, agent switch)
---and may let the agent keep running.
---
---Both send their request and return immediately. The state moves on through
---`agent.exited` (a real stop) or the request's failure callback, so a slow or
---wedged service can never freeze the editor.
---@param force boolean|nil
function Channel:stop(force)
  -- `stopping` already makes `is_alive()` false, but the subscription stays: the
  -- service answers with `agent.exited` after the process is gone, and the Client
  -- needs that event to move the UI to "disconnected" exactly like a direct
  -- child process' exit callback does.
  --
  -- A channel that cannot reach the service (its connection was lost) or whose
  -- agent already exited must not send `agent.stop`: `Connection:request` would
  -- `ensure()` and can bring the service back just as the editor is leaving, and
  -- the service already detached this connection when the socket closed
  -- (PROTOCOL.md 5.4/9.4). Record the exit locally instead.
  local reachable = self.alive and not self.stopping
  self.stopping = true
  local instance = self.instance
  if not instance or not reachable then
    self.alive = false
    self.attached = false
    self.connection:unsubscribe_all(self.channel_id)
    -- Nothing was attached yet; the queued attach will see `stopping` and leave
    -- the (possibly created) instance to the service's idle timeout.
    return
  end
  local state = { done = false }
  self.connection:request("agent.stop", { instance = instance, force = force == true }, function(ok, value)
    state.done = true
    if not ok then
      log.warn("agent.stop failed for %s: %s", instance, M.describe(value))
      -- No `agent.exited` will follow a rejected stop, so synthesize the exit:
      -- otherwise the Client keeps a dead process object and a pending prompt
      -- waits for its timeout.
      self:finish_exit(0, self.stderr_tail or "")
    end
  end)
  -- Only a shutdown waits, and only long enough to get the frame onto the
  -- socket. The service no longer needs the reply before the next attach.
  flush_if_exiting(state, 2000)
end

---Whether `leave(true)` would detach rather than stop.
---
---The Client asks this before deciding how to settle its pending interactions:
---requests must survive only when the process really does. Keeping the decision
---in one place stops the two sides from drifting apart.
---
---`stopping` and `failed` forbid a detach: an explicit stop or a broken channel
---is not a hand-over. A channel whose connection was lost (`alive == false`)
---does detach: the service removed this connection from `attached` when the
---socket closed and keeps the instance and its pending set pending
---(PROTOCOL.md 5.4 and 9.4), so the agent survives and this front end must
---abandon, not cancel, its requests.
---@return boolean
function Channel:will_detach()
  return self.instance ~= nil and self.keep_alive and self.initialized and not self.failed and not self.stopping
end

---Leave the instance, detaching when that is safe.
---
---Detach keeps the agent alive for the next Neovim, which is only correct when
---the user asked for it (`service.keep_alive`), the ACP session actually
---finished initializing, and nothing went wrong. Every other case stops the
---process: keeping a half-initialized or broken agent around only leaves a
---process nobody can reach.
---
---The branch is `will_detach()` itself, so the decision `Client:leave` takes
---(abandon pending requests vs. answer them `cancelled`) is exactly the action
---taken here. A channel that lost its connection has already been detached by
---the service when the socket closed (PROTOCOL.md 5.4/9.4); it marks itself
---detached and sends nothing, because any request would reconnect a service
---this front end is leaving.
---@param allow_detach boolean
function Channel:leave(allow_detach)
  local instance = self.instance
  if not instance then
    self:stop(true)
    return
  end
  if not allow_detach or not self:will_detach() then
    self:stop(false)
    return
  end
  local reachable = self.alive and not self.stopping
  self.alive = false
  self.detached = true
  self.stats.detach = true
  self.connection:unsubscribe_all(self.channel_id)
  if not reachable then
    return
  end
  local state = { done = false }
  self.connection:request("agent.detach", { instance = instance }, function(ok, value)
    state.done = true
    if not ok then
      log.warn("agent.detach failed for %s: %s", instance, M.describe(value))
    end
  end)
  flush_if_exiting(state, 2000)
end

---Report an exit that the service will not announce (a rejected stop).
---@param code integer|nil
---@param stderr string|nil
function Channel:finish_exit(code, stderr)
  if not self.alive then
    return
  end
  self.alive = false
  self.attached = false
  self.connection:unsubscribe_all(self.channel_id)
  if self.on_exit then
    pcall(self.on_exit, code, stderr or self.stderr_tail or "")
  end
end

---Record that the ACP session finished initializing.
---
---The Client owns this fact; the channel only needs it to answer "may this
---instance be detached?" without guessing from traffic.
---@param initialized boolean
function Channel:set_initialized(initialized)
  self.initialized = initialized == true
end

---Mark the current protocol phase for diagnostics.
---@param phase string|nil
function Channel:mark_phase(phase)
  self.stats.phase = phase
end

---@return boolean
function Channel:is_alive()
  return self.alive and not self.stopping
end

---@return string
function Channel:stderr()
  return self.stderr_tail
end

---Ask for the instance list (`:Ade service agents`).
---@param cb fun(ok: boolean, value: any)
function M.list(connection, cb)
  connection:request("agent.list", {}, cb)
end

return M
