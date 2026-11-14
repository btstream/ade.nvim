-- Where the service keeps its socket, token and lock.
--
-- The resolution order is fixed by `.acp-work/contract.md` so the Rust service
-- and this client always agree:
--
--   1. `$NVIM_ADE_SERVER_DIR` (tests and advanced users)
--   2. `$XDG_RUNTIME_DIR/ade`
--   3. `$XDG_STATE_HOME/ade`
--   4. `~/.local/state/ade`
--
-- Windows uses `%LOCALAPPDATA%\ade` and a named pipe instead of a socket path.
-- No directory is created here: `paths()` is a pure description, and only the
-- launcher/installer create things.
local M = {}

local SOCKET_NAME = "nvim_ade_server.sock"
local TOKEN_NAME = "nvim_ade_server.token"
local LOCK_NAME = "nvim_ade_server.lock"

---@return boolean
function M.is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

---@param value string|nil
---@return string|nil
local function nonempty(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

---Named pipe path for the current user (Windows only).
---@return string
function M.pipe_name()
  local user = nonempty(vim.env.USER) or nonempty(vim.env.USERNAME) or "default"
  -- A pipe name cannot contain a backslash, so keep only a safe subset.
  user = user:gsub("[^%w%-%._]", "_")
  return "\\\\.\\pipe\\nvim_ade_server-" .. user
end

---The service directory, without creating it.
---@return string
function M.dir()
  local explicit = nonempty(vim.env.NVIM_ADE_SERVER_DIR)
  if explicit then
    return vim.fs.normalize(vim.fn.fnamemodify(explicit, ":p"))
  end
  if M.is_windows() then
    local localappdata = nonempty(vim.env.LOCALAPPDATA)
    if localappdata then
      return vim.fs.normalize(vim.fn.fnamemodify(localappdata, ":p")) .. "/ade"
    end
  end
  local runtime = nonempty(vim.env.XDG_RUNTIME_DIR)
  if runtime then
    return vim.fs.normalize(vim.fn.fnamemodify(runtime, ":p")) .. "/ade"
  end
  local state = nonempty(vim.env.XDG_STATE_HOME)
  if state then
    return vim.fs.normalize(vim.fn.fnamemodify(state, ":p")) .. "/ade"
  end
  return vim.fs.normalize(vim.fn.expand("~/.local/state")) .. "/ade"
end

---Everything the client needs to reach the service.
---@return {dir: string, socket: string, token: string, lock: string, pipe: boolean}
function M.paths()
  local dir = M.dir()
  local pipe = M.is_windows()
  return {
    dir = dir,
    socket = pipe and M.pipe_name() or (dir .. "/" .. SOCKET_NAME),
    token = dir .. "/" .. TOKEN_NAME,
    lock = dir .. "/" .. LOCK_NAME,
    pipe = pipe,
  }
end

---Read the shared token, or nil plus a reason.
---@param path string|nil
---@return string|nil token
---@return string|nil err
function M.read_token(path)
  path = path or M.paths().token
  local fh = io.open(path, "rb")
  if not fh then
    return nil, "token file not found: " .. path
  end
  local text = fh:read("*a")
  fh:close()
  local token = type(text) == "string" and vim.trim(text) or ""
  if token == "" then
    return nil, "token file is empty: " .. path
  end
  return token
end

return M
