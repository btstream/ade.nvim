-- In-process stand-in for nvim_ade_server, used by the channel tests.
--
-- It speaks the api_version 2 protocol from `service/PROTOCOL.md` over a real
-- unix socket: one JSON per line, `hello`, `ping`, `shutdown`, and the tunnel
-- methods (`agent.attach/detach/stop/list`, `tunnel.send/recv`, `agent.exited`,
-- `tunnel.error`). The ACP side can be a real child process (normally
-- `tests/mock_agent.py`) so a full conversation can run without the Rust
-- service.
--
-- Version numbers are passed in by the caller, which reads them from
-- `ade.service.version`; nothing here hardcodes the protocol version.
--
-- `tests/fake_service.py` is the same stand-in as a standalone process, used by
-- the launcher test.
local M = {}

local Framing = require("ade.transport.framing")

---@class FakeService
---@field dir string
---@field token string
---@field server table
---@field clients table[]
---@field instances table<string, table>
local Server = {}
Server.__index = Server

---@param opts {dir: string, token?: string, api_version?: number, server_version?: string,
---  wrong_token?: boolean, require_hello?: boolean, on_hello?: fun(params: table),
---  spawn_agent?: fun(instance: table): boolean|nil, exit_code?: integer,
---  stop_delay_ms?: integer}|nil
---@return FakeService
function M.new(opts)
  opts = opts or {}
  -- Version numbers come from the plugin's own constants: the stand-in must keep
  -- handshaking after the version is bumped in the merge commit, without edits.
  local Version = require("ade.service.version")
  local self = setmetatable({
    dir = opts.dir,
    token = opts.token or "test-token",
    api_version = opts.api_version ~= nil and opts.api_version or Version.API_VERSION,
    server_version = opts.server_version or Version.VERSION,
    wrong_token = opts.wrong_token == true,
    require_hello = opts.require_hello == true,
    on_hello = opts.on_hello,
    spawn_agent = opts.spawn_agent,
    exit_code = opts.exit_code,
    -- Tests use this to prove `stop` does not block on the reply.
    stop_delay_ms = opts.stop_delay_ms,
    clients = {},
    instances = {},
    -- Instances whose stop was requested but whose exit has not been announced
    -- yet (PROTOCOL.md 3.4). Listed with `stopping = true`.
    stopping = {},
    counter = 0,
    seq = {},
    -- Every `tunnel.send` frame, for assertions.
    sent = {},
    calls = {},
    attach_results = {},
  }, Server)
  vim.fn.mkdir(self.dir, "p", 448)
  local fh = assert(io.open(self.dir .. "/nvim_ade_server.token", "wb"))
  fh:write(self.token)
  fh:close()
  return self
end

---@return string
function Server:socket()
  return self.dir .. "/nvim_ade_server.sock"
end

---@param path string
---@return string|nil
local function read_token(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  return text
end

M.read_token = read_token

---Start listening. Returns false when the socket cannot be bound.
---@return boolean
function Server:listen()
  pcall(vim.fn.delete, self:socket())
  local server = vim.uv.new_pipe(false)
  self.server = server
  local ok = pcall(function()
    server:bind(self:socket())
  end)
  if not ok then
    return false
  end
  server:listen(16, function()
    local peer = vim.uv.new_pipe(false)
    server:accept(peer)
    self:serve(peer)
  end)
  return true
end

---@param peer table
function Server:serve(peer)
  local decoder = Framing.new_decoder()
  local client = { peer = peer, greeted = false, attached = {} }
  self.clients[#self.clients + 1] = client
  peer:read_start(function(err, data)
    if err or not data then
      pcall(peer.close, peer)
      self:detach_all(client)
      return
    end
    decoder:feed(data, function(line)
      local ok, message = pcall(vim.json.decode, line)
      if not ok or type(message) ~= "table" then
        return
      end
      local reply = self:dispatch(message, client)
      if reply then
        self:send(client, reply)
      end
    end)
  end)
end

---@param client table
---@param payload table
function Server:send(client, payload)
  if not client.peer or client.closed then
    return
  end
  pcall(function()
    client.peer:write(vim.json.encode(payload) .. "\n")
  end)
end

---@param client table
---@param method string
---@param params table
function Server:emit(client, method, params)
  self:send(client, { jsonrpc = "2.0", method = method, params = params })
end

---@param ident any
---@param code integer
---@param message string
---@param data table|nil
---@return table
local function error_reply(ident, code, message, data)
  local payload = { code = code, message = message }
  if data then
    payload.data = data
  end
  return { jsonrpc = "2.0", id = ident, error = payload }
end

---@param message table
---@param client table
---@return table|nil
function Server:dispatch(message, client)
  local method = message.method
  local ident = message.id
  local params = type(message.params) == "table" and message.params or {}
  if method then
    self.calls[#self.calls + 1] = { method = method, params = params, id = ident }
  end
  if method == "hello" then
    if self.wrong_token or params.token ~= self.token then
      return error_reply(ident, -32001, "invalid token")
    end
    if self.api_version ~= nil and params.api_version ~= self.api_version then
      return error_reply(ident, -32002, "incompatible api_version", { server_api_version = self.api_version })
    end
    client.greeted = true
    if self.on_hello then
      pcall(self.on_hello, params)
    end
    return {
      jsonrpc = "2.0",
      id = ident,
      result = {
        server_version = self.server_version,
        api_version = self.api_version,
        features = { "tunnel" },
      },
    }
  end
  if not client.greeted and self.require_hello then
    return error_reply(ident, -32003, "hello required")
  end
  if method == "ping" then
    return { jsonrpc = "2.0", id = ident, result = {} }
  end
  if method == "shutdown" then
    return { jsonrpc = "2.0", id = ident, result = {} }
  end

  if method == "agent.attach" then
    -- Spawning the fake agent runs `jobstart`, which is forbidden in libuv's
    -- fast event context where socket reads arrive. Defer the whole attach one
    -- tick so a stand-in can start a real child process.
    vim.schedule(function()
      self:send(client, self:attach(params, client, ident))
    end)
    return nil
  elseif method == "agent.detach" then
    local instance = self.instances[params.instance]
    if not instance then
      return error_reply(ident, -32020, "unknown instance")
    end
    instance.attached[client] = nil
    client.attached[params.instance] = nil
    return { jsonrpc = "2.0", id = ident, result = {} }
  elseif method == "agent.stop" then
    local instance = self.instances[params.instance]
    if not instance then
      return error_reply(ident, -32020, "unknown instance")
    end
    self:stop_instance(instance, "stop")
    local reply = { jsonrpc = "2.0", id = ident, result = { exited = true, code = 0 } }
    if self.stop_delay_ms and self.stop_delay_ms > 0 then
      -- Deliberately slow: the client must not wait for this reply.
      vim.defer_fn(function()
        self:send(client, reply)
      end, self.stop_delay_ms)
      return nil
    end
    return reply
  elseif method == "agent.list" then
    local instances = {}
    for id, instance in pairs(self.instances) do
      instances[#instances + 1] = {
        instance = id,
        stopping = instance.stopping == true,
        agent = instance.key.agent,
        command = instance.key.command,
        args = instance.key.args,
        cwd = instance.key.cwd,
        pid = instance.pid or 0,
        started_at = instance.started_at,
        initialized = instance.initialized == true,
        attached = vim.tbl_count(instance.attached),
        turns_running = 0,
        pending_requests = #(instance.pending or {}),
      }
    end
    table.sort(instances, function(a, b)
      return a.instance < b.instance
    end)
    return { jsonrpc = "2.0", id = ident, result = { instances = instances } }
  elseif method == "tunnel.send" then
    self:on_tunnel_send(params, client)
    return nil
  end
  return error_reply(ident, -32601, "Method not found: " .. tostring(method))
end

---@param params table
---@param client table
---@param ident any
---@return table
function Server:attach(params, client, ident)
  local key = params.key or {}
  local canonical = vim.json.encode({
    agent = key.agent,
    command = key.command,
    args = key.args or {},
    cwd = key.cwd,
    client_capabilities = params.client_capabilities or {},
  })
  self.attach_results[#self.attach_results + 1] = {
    key = vim.deepcopy(key),
    env = vim.deepcopy(params.env),
    capabilities = vim.deepcopy(params.client_capabilities),
  }
  local id, created = nil, false
  for existing, instance in pairs(self.instances) do
    if instance.canonical == canonical and not instance.stopping then
      id = existing
      break
    end
  end
  if not id then
    self.counter = self.counter + 1
    id = "inst-" .. tostring(self.counter)
    created = true
    local instance = {
      id = id,
      canonical = canonical,
      key = key,
      env = params.env,
      capabilities = params.client_capabilities or {},
      attached = {},
      started_at = math.floor(vim.uv.gettimeofday() * 1000),
      initialized = false,
      agent = nil,
      -- Agent -> client requests this instance has relayed and that nobody has
      -- answered yet, in arrival order (PROTOCOL.md 5.4).
      pending = {},
    }
    self.instances[id] = instance
    if self.spawn_agent then
      local ok = self.spawn_agent(instance)
      if ok == false then
        self.instances[id] = nil
        return error_reply(ident, -32022, "spawn failed")
      end
    end
  end
  local instance = self.instances[id]
  instance.attached[client] = true
  client.attached[id] = true
  -- Becoming (most recently attached) primary: hand over every request that no
  -- front end answered, in arrival order.
  for _, message in ipairs(instance.pending or {}) do
    self:emit(client, "tunnel.recv", {
      instance = id,
      seq = self.seq[id] or 0,
      message = message,
    })
  end
  return {
    jsonrpc = "2.0",
    id = ident,
    result = {
      instance = id,
      created = created,
      pid = instance.pid or 0,
      initialized = instance.initialized == true,
      attached = vim.tbl_count(instance.attached),
    },
  }
end

---Handle one `tunnel.send` frame: route it to the fake agent.
---@param params table
---@param client table
function Server:on_tunnel_send(params, client)
  local instance = self.instances[params.instance]
  if not instance or not instance.attached[client] then
    self:emit(client, "tunnel.error", {
      instance = params.instance,
      code = -32024,
      message = "not attached",
    })
    return
  end
  local message = params.message
  if type(message) ~= "table" then
    self:emit(client, "tunnel.error", {
      instance = params.instance,
      code = -32025,
      message = "frame is not an object",
    })
    return
  end
  self.sent[#self.sent + 1] = { instance = params.instance, message = vim.deepcopy(message) }
  -- A response from a front end answers a relayed agent request: forget it, so
  -- `agent.list` reports the same pending set the service would (PROTOCOL 5.1).
  if message.method == nil and message.id ~= nil and instance.pending then
    for index, pending in ipairs(instance.pending) do
      if pending.id == message.id then
        table.remove(instance.pending, index)
        break
      end
    end
  end
  -- Writing to a child's stdin uses Vimscript (`chansend`), which libuv's fast
  -- event context forbids, and socket reads arrive there. One scheduled hop is
  -- enough and keeps the frame order.
  vim.schedule(function()
    if not instance.handler or not self.instances[instance.id] then
      return
    end
    instance.handler(message, function(reply)
      if reply then
        self:deliver(instance, reply)
      end
    end)
  end)
end

---Deliver one agent message to every attached connection as `tunnel.recv`.
---@param instance table
---@param message table
function Server:deliver(instance, message)
  if type(message) == "table" and message.method and message.id ~= nil then
    -- An agent request: keep it until some front end answers it.
    instance.pending = instance.pending or {}
    instance.pending[#instance.pending + 1] = message
  elseif type(message) == "table" and not message.method and message.id ~= nil then
    -- A response to one of those requests: forget it.
    for index, pending in ipairs(instance.pending or {}) do
      if pending.id == message.id then
        table.remove(instance.pending, index)
        break
      end
    end
  end
  self.seq[instance.id] = (self.seq[instance.id] or 0) + 1
  if message.method == "initialize" then
    instance.initialized = true
  end
  for client in pairs(instance.attached) do
    self:emit(client, "tunnel.recv", {
      instance = instance.id,
      seq = self.seq[instance.id],
      message = message,
    })
  end
end

---Stop an instance, notifying every attached connection.
---
---Per PROTOCOL.md 3.4 the instance leaves the identity lookup as soon as the
---request is processed, so an `agent.attach` with the same key right afterwards
---creates a new instance instead of reusing the dying one. The record itself
---stays listed (with `stopping = true`) until the exit is announced, so
---`agent.list` and in-flight `tunnel.send` still find it by id.
---@param instance table
---@param reason string
function Server:stop_instance(instance, reason)
  instance.stopping = true
  instance.canonical = nil -- no longer matches an attach
  self.stopping[instance.id] = instance
  local code = self.exit_code or 0
  for client in pairs(instance.attached) do
    self:emit(client, "agent.exited", {
      instance = instance.id,
      code = code,
      signal = nil,
      stderr_tail = "",
    })
  end
  if instance.stop_agent then
    pcall(instance.stop_agent)
  end
  self.instances[instance.id] = nil
  self.stopping[instance.id] = nil
  return reason
end

---Detach a client from everything (it disconnected).
---@param client table
function Server:detach_all(client)
  client.closed = true
  for id in pairs(client.attached or {}) do
    local instance = self.instances[id]
    if instance then
      instance.attached[client] = nil
    end
  end
  client.attached = {}
end

---Number of instances currently alive.
---@return integer
function Server:instance_count()
  return vim.tbl_count(self.instances)
end

---Drop every client and stop listening.
function Server:close()
  if self.server then
    pcall(function()
      self.server:close()
    end)
    self.server = nil
  end
  for _, client in ipairs(self.clients) do
    client.closed = true
    pcall(function()
      client.peer:close()
    end)
  end
  for _, instance in pairs(self.instances) do
    if instance.stop_agent then
      pcall(instance.stop_agent)
    end
  end
  self.clients = {}
  self.instances = {}
  pcall(vim.fn.delete, self:socket())
end

return M
