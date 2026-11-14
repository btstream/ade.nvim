-- In-process stand-in for nvim_ade_server, used by the client tests.
--
-- It speaks the S0 contract (`.acp-work/contract.md`) over a real unix socket:
-- one JSON per line, `hello`/`ping`/`shutdown`, and the three error codes. Using
-- a real socket keeps the client test honest about framing and pipes while
-- staying fully offline.
--
-- `tests/fake_service.py` is the same contract as a standalone process, used by
-- the launcher's end-to-end test.
local M = {}

local Framing = require("ade.transport.framing")

---@class FakeService
---@field dir string
---@field token string
---@field server table
---@field clients table[]
local Server = {}
Server.__index = Server

---@param opts {dir: string, token?: string, api_version?: number, wrong_token?: boolean,
---  require_hello?: boolean, on_hello?: fun(params: table)}|nil
---@return FakeService
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    dir = opts.dir,
    token = opts.token or "test-token",
    api_version = opts.api_version or 1,
    wrong_token = opts.wrong_token == true,
    require_hello = opts.require_hello == true,
    on_hello = opts.on_hello,
    clients = {},
    greeted = {},
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
  local client = { peer = peer, greeted = false }
  self.clients[#self.clients + 1] = client
  peer:read_start(function(err, data)
    if err or not data then
      pcall(peer.close, peer)
      return
    end
    decoder:feed(data, function(line)
      local ok, message = pcall(vim.json.decode, line)
      if not ok or type(message) ~= "table" then
        return
      end
      local reply = self:dispatch(message, client)
      if reply then
        pcall(function()
          peer:write(vim.json.encode(reply) .. "\n")
        end)
        if reply.__shutdown then
          reply.__shutdown = nil
          pcall(peer.close, peer)
        end
      end
    end)
  end)
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
  if method == "hello" then
    if self.wrong_token or params.token ~= self.token then
      client.greeted = "rejected"
      return error_reply(ident, -32001, "invalid token")
    end
    if params.api_version ~= self.api_version then
      return error_reply(ident, -32002, "incompatible api_version", { server_api_version = self.api_version })
    end
    client.greeted = true
    if self.on_hello then
      pcall(self.on_hello, params)
    end
    return {
      jsonrpc = "2.0",
      id = ident,
      result = { server_version = "0.1.0", api_version = self.api_version, features = {} },
    }
  end
  if not client.greeted and self.require_hello then
    return error_reply(ident, -32003, "hello required")
  end
  if method == "ping" then
    return { jsonrpc = "2.0", id = ident, result = {} }
  end
  if method == "shutdown" then
    return { jsonrpc = "2.0", id = ident, result = {}, __shutdown = true }
  end
  return error_reply(ident, -32601, "Method not found: " .. tostring(method))
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
    pcall(function()
      client.peer:close()
    end)
  end
  self.clients = {}
  pcall(vim.fn.delete, self:socket())
end

return M
