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

---@param opts {paths?: table, timeout?: integer}
---@return AdeServiceClient
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    paths = opts.paths or Paths.paths(),
    timeout = opts.timeout or 5000,
    decoder = Framing.new_decoder(),
    ready = false,
    closed = false,
  }, Client)
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

---Feed incoming bytes into the decoder and the RPC layer.
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
      if ok and type(decoded) == "table" then
        self.rpc:handle(decoded)
      else
        log.warn("service sent a non-JSON line: %s", line:sub(1, 200))
      end
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
  if self.on_disconnect then
    pcall(self.on_disconnect, tostring(reason))
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
