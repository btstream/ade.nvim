-- Front-end client for nvim_ade_server.
--
-- The transport is the same one ACP uses in direct mode: a `vim.uv` pipe, the
-- existing newline framer (`ade.transport.framing`) and the JSON-RPC layer
-- (`ade.transport.jsonrpc`). Both are transport-agnostic — the framing module
-- only encodes/decodes lines and the RPC layer takes a `send` callback — so no
-- change was needed to reuse them here.
--
-- What this stage provides is the skeleton: connect, `hello`, `ping`,
-- `shutdown`, and a clean disconnect callback. Subscriptions, replay by
-- sequence number and reconnection belong to S1 and are not implemented yet.
local log = require("ade.log")
local Framing = require("ade.transport.framing")
local JsonRpc = require("ade.transport.jsonrpc")
local Paths = require("ade.service.paths")
local Version = require("ade.service.version")

local M = {}

---Contract error codes. Named so callers never compare bare numbers.
M.ERR_INVALID_TOKEN = -32001
M.ERR_API_VERSION = -32002
M.ERR_HELLO_REQUIRED = -32003

---@class AdeServiceClient
---@field paths table
---@field rpc table|nil
---@field pipe table|nil
---@field decoder table
---@field ready boolean
---@field closed boolean
local Client = {}
Client.__index = Client

---Turn a JSON-RPC error into a message a user can act on.
---@param err table|nil
---@return string
function M.describe_error(err)
  if type(err) ~= "table" then
    return "unknown service error"
  end
  local code = err.code
  if code == M.ERR_INVALID_TOKEN then
    return "the service rejected the token; delete " .. Paths.paths().token .. " and restart the service"
  elseif code == M.ERR_API_VERSION then
    local data = type(err.data) == "table" and err.data or {}
    return string.format(
      "the service speaks api_version %s but this plugin needs %d; update it with :Ade service install",
      tostring(data.server_api_version),
      Version.API_VERSION
    )
  elseif code == M.ERR_HELLO_REQUIRED then
    return "the service required hello before this request"
  end
  return string.format("%s (code %s)", tostring(err.message or "service error"), tostring(code))
end

---Default slice for dispatching incoming messages, in milliseconds.
---
---Matches the direct transport's `dispatch_budget_ms`: a burst of 5000 streamed
---chunks must not hold the main loop long enough to delay timers, input or
---redraws.
M.DEFAULT_DISPATCH_BUDGET_MS = 4

---Ceiling for the pending-dispatch queue, in bytes.
---
---PROTOCOL.md 7 makes the same choice for the service's outbound queue: **never
---drop a frame silently**, close the connection instead. Dropping anything here
---would leave a request hanging until its timeout (a lost response) or a pending
---permission unanswered, and the failure would look like an agent bug. So an
---overflow is treated as a lost connection: the instances report an exit with a
---reason that blames the front end, and the user reconnects.
M.DEFAULT_MAX_INBOX_BYTES = 64 * 1024 * 1024

---Disconnect reason used when the front end cannot keep up with the stream.
M.OVERFLOW_REASON = "client inbox overflow"

---@param opts {paths?: table, timeout?: integer, scheduler?: table|nil,
---  dispatch_budget_ms?: integer}
---@return AdeServiceClient
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    paths = opts.paths or Paths.paths(),
    timeout = opts.timeout or 5000,
    -- Shared editor scheduler: inbound frames are dispatched in bounded slices
    -- exactly like the direct transport's receive loop, so a streaming agent
    -- cannot starve timers, input or redraws.
    scheduler = opts.scheduler,
    dispatch_budget_ms = opts.dispatch_budget_ms or M.DEFAULT_DISPATCH_BUDGET_MS,
    max_inbox_bytes = opts.max_inbox_bytes or M.DEFAULT_MAX_INBOX_BYTES,
    inbox = {},
    inbox_bytes = 0,
    inbox_overflowed = false,
    draining = false,
    dispatches = 0,
    dispatch_slices = 0,
    max_dispatch_ms = 0,
    decoder = Framing.new_decoder(),
    -- Notifications are subscribed before the socket exists, then installed on
    -- the RPC object once it does. This matters because a caller (the instance
    -- channel) subscribes while connecting.
    handlers = {},
    ready = false,
    closed = false,
  }, Client)
end

---Subscribe to a service notification (`tunnel.recv`, `agent.exited`, ...).
---
---One handler per method: a later subscription replaces the earlier one, which
---is what the per-instance channels need (they filter by instance anyway).
---@param method string
---@param fn fun(params: any)
function Client:on(method, fn)
  self.handlers[method] = fn
  if self.rpc then
    self.rpc:on_notification(method, fn)
  end
end

---Send a request and report the answer through `cb`.
---
---Unlike `ping`/`shutdown` this does not wait: the service channel needs many
---in-flight requests (attach, detach, stop, list) without blocking the editor.
---@param method string
---@param params any
---@param cb fun(ok: boolean, value: any)|nil
function Client:request(method, params, cb)
  if not self.ready or not self.rpc then
    if cb then
      cb(false, { code = -32000, message = "not connected to the service" })
    end
    return nil
  end
  return self.rpc:request(method, params, cb)
end

---Send a notification; best effort, like `tunnel.send`.
---@param method string
---@param params any
---@return boolean sent
function Client:notify(method, params)
  if not self.ready or not self.rpc then
    return false
  end
  self.rpc:notify(method, params)
  return true
end

---Whether requests can be sent right now.
---@return boolean
function Client:is_ready()
  return self.ready and not self.closed
end

---Connect to the socket and send `hello`.
---
---A refused connection (no service) is reported as a plain error string, not an
---exception, so the caller can fall back to the direct backend silently.
---@param cb fun(ok: boolean, info: table|string)
function Client:connect(cb)
  if self.pipe then
    cb(false, "already connected")
    return
  end
  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    cb(false, "unable to create a pipe")
    return
  end
  self.pipe = pipe
  local state = { done = false, ok = false, err = nil }
  pipe:connect(self.paths.socket, function(err)
    state.done = true
    if err then
      state.err = "cannot connect to the service at " .. self.paths.socket .. ": " .. tostring(err)
    else
      state.ok = true
    end
  end)
  vim.wait(self.timeout, function()
    return state.done
  end, 5)
  if not state.done then
    state.err = "timed out connecting to " .. self.paths.socket
  end
  if not state.ok then
    pcall(pipe.close, pipe)
    self.pipe = nil
    cb(false, state.err)
    return
  end

  self.rpc = JsonRpc.new({
    send = function(payload)
      if not self.pipe or self.closed then
        return false
      end
      local ok = pcall(function()
        self.pipe:write(payload)
      end)
      return ok
    end,
  })
  -- Install every notification subscription made before the connection.
  -- `tunnel.recv`, `agent.exited` and `tunnel.error` are all notifications in
  -- the protocol (section 3.6-3.9), never requests.
  for method, fn in pairs(self.handlers) do
    self.rpc:on_notification(method, fn)
  end
  self:read_loop()

  local token, token_err = Paths.read_token(self.paths.token)
  if not token then
    self:close()
    cb(false, token_err)
    return
  end
  self:hello(token, cb)
end

---Read until the `hello` response arrives.
---@param token string
---@param cb fun(ok: boolean, info: table|string)
function Client:hello(token, cb)
  local answered = false
  local function finish(ok, value)
    if answered then
      return
    end
    answered = true
    if not ok then
      self:close()
    end
    cb(ok, value)
  end
  self.rpc:request("hello", {
    token = token,
    client = "ade.nvim",
    client_version = Version.VERSION,
    api_version = Version.API_VERSION,
  }, function(ok, value)
    if ok then
      self.ready = true
      finish(true, value)
    else
      finish(false, M.describe_error(value))
    end
  end)
  vim.wait(self.timeout, function()
    return answered
  end, 5)
  if not answered then
    finish(false, "the service did not answer hello within " .. self.timeout .. " ms")
  end
end

---Queue one decoded message for bounded dispatch.
---
---Decoding happens in the socket callback; dispatch happens on the main loop in
---time-boxed slices. Socket reads arrive in libuv's fast event context, where
---any editor API raises, and a streaming agent can deliver thousands of
---`session/update` frames back to back — dispatching them one `vim.schedule`
---each would let the queue drain for as long as the burst lasts.
---@param decoded table
function Client:enqueue(decoded)
  if self.closed then
    return
  end
  local size = 0
  local ok, encoded = pcall(vim.json.encode, decoded)
  if ok and type(encoded) == "string" then
    size = #encoded
  end
  self.inbox[#self.inbox + 1] = { message = decoded, bytes = size }
  self.inbox_bytes = self.inbox_bytes + size
  if self.inbox_bytes > self.max_inbox_bytes then
    self:overflow()
    return
  end
  self:schedule_drain()
end

---Abandon the connection because dispatch cannot keep up.
---
---Mirrors PROTOCOL.md 7: a frame is never dropped silently. Discarding any
---single message (a response, a permission request, a cancellation) would leave
---that request waiting for its timeout, or leave the UI quietly wrong, and it
---would be indistinguishable from an agent bug. Closing the connection is honest
---and recoverable: the agent keeps running, and reconnecting attaches again.
function Client:overflow()
  if self.inbox_overflowed then
    return
  end
  self.inbox_overflowed = true
  log.warn("service inbox exceeded %d bytes while dispatching; dropping the connection", self.max_inbox_bytes)
  self.inbox, self.inbox_bytes = {}, 0
  self:on_disconnect(M.OVERFLOW_REASON)
end

---Schedule one bounded dispatch slice, if none is pending.
---
---The scheduler keeps a "protocol" queue in FIFO order and re-runs a job that
---returns true at the head of that queue, which is what preserves message order
---across slices.
function Client:schedule_drain()
  if self.draining or self.closed then
    return
  end
  self.draining = true
  local function step()
    if self.closed then
      self.draining = false
      return false
    end
    local started = vim.uv.hrtime()
    local deadline = started + self.dispatch_budget_ms * 1e6
    local handled = 0
    while self.inbox[1] and vim.uv.hrtime() < deadline do
      local entry = table.remove(self.inbox, 1)
      self.inbox_bytes = self.inbox_bytes - (entry.bytes or 0)
      handled = handled + 1
      if self.rpc then
        self.rpc:handle(entry.message)
      end
    end
    self.dispatch_slices = self.dispatch_slices + 1
    self.dispatches = self.dispatches + handled
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    if elapsed > self.max_dispatch_ms then
      self.max_dispatch_ms = elapsed
    end
    if self.inbox[1] then
      return true
    end
    self.draining = false
    return false
  end
  if self.scheduler then
    self.scheduler:enqueue("protocol", step, { label = "service receive" })
    return
  end
  -- No scheduler configured (unit tests, headless scripts): one slice per tick.
  vim.schedule(function()
    while step() do
      -- keep going; `step` yields the loop between slices via the scheduler
      -- path above, this fallback simply runs to completion.
    end
  end)
end

---Feed incoming bytes into the decoder and the dispatch queue.
function Client:read_loop()
  local pipe = self.pipe
  if not pipe then
    return
  end
  pipe:read_start(function(err, data)
    if err then
      self:on_disconnect(err)
      return
    end
    if not data then
      self:on_disconnect("the service closed the connection")
      return
    end
    self.decoder:feed(data, function(line)
      local ok, decoded = pcall(vim.json.decode, line)
      if not ok or type(decoded) ~= "table" then
        log.warn("service sent a non-JSON line: %s", line:sub(1, 200))
        return
      end
      self:enqueue(decoded)
    end)
  end)
end

---Report a dropped connection once.
---@param reason any
function Client:on_disconnect(reason)
  if self.closed then
    return
  end
  self.closed = true
  self.ready = false
  if self.rpc then
    self.rpc:close(tostring(reason))
  end
  if self.pipe then
    pcall(function()
      self.pipe:close()
    end)
    self.pipe = nil
  end
  -- `on_disconnect_cb`, not `on_disconnect`: the latter is this method, and a
  -- field with the same name would either shadow it or call itself forever.
  if self.on_disconnect_cb then
    pcall(self.on_disconnect_cb, tostring(reason))
  end
end

---Send `ping` and wait for the reply.
---@param cb fun(ok: boolean, value: any)
function Client:ping(cb)
  if not self.ready then
    cb(false, "not connected")
    return
  end
  local answered = false
  self.rpc:request("ping", {}, function(ok, value)
    answered = true
    cb(ok, value)
  end)
  vim.wait(self.timeout, function()
    return answered
  end, 5)
  if not answered then
    cb(false, "ping timed out")
  end
end

---Ask the service to exit.
---@param cb fun(ok: boolean, value: any)|nil
function Client:shutdown(cb)
  cb = cb or function() end
  if not self.ready then
    cb(false, "not connected")
    return
  end
  local answered = false
  self.rpc:request("shutdown", {}, function(ok, value)
    answered = true
    cb(ok, value)
    self:close()
  end)
  vim.wait(self.timeout, function()
    return answered
  end, 5)
  if not answered then
    cb(false, "shutdown timed out")
  end
end

---Close the connection without asking the service to exit.
function Client:close()
  self:on_disconnect("closed by the client")
end

return M
