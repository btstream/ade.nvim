-- Start the service on demand and connect to it.
--
-- The service is started only by a Neovim that needs it (design §4.1): no
-- systemd/launchd unit, and no automatic restart. `ensure()` therefore does
-- the minimum: return early when the socket already accepts a connection,
-- otherwise spawn `nvim_ade_server serve` detached and wait for the one-line
-- JSON status the contract requires on stdout.
--
-- Nothing here downloads or installs anything: a missing binary is an explicit
-- "not installed" error so the caller can suggest `:Ade service install`.
local log = require("ade.log")
local Paths = require("ade.service.paths")

local M = {}

---Default time to wait for the service's ready line.
M.DEFAULT_START_TIMEOUT = 5000

---Whether something is listening on the service socket right now.
---
---Connecting is the only portable probe: a stale socket file survives a crash,
---and a named pipe has no file at all. The test connection is closed at once;
---the service treats a connection that sends nothing as a client that left.
---@param paths table
---@return boolean reachable
function M.probe(paths)
  paths = paths or Paths.paths()
  if not paths.pipe and vim.fn.isdirectory(paths.dir) == 0 and vim.fn.filereadable(paths.socket) ~= 1 then
    -- A named pipe has no file; a unix socket does. Without it, skip the
    -- connect attempt so a missing service never logs an error.
    return false
  end
  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    return false
  end
  local connected = false
  local failed = false
  local ok = pcall(function()
    pipe:connect(paths.socket, function(err)
      if err then
        failed = true
      else
        connected = true
      end
    end)
  end)
  if not ok then
    pcall(function()
      pipe:close()
    end)
    return false
  end
  -- `connect` on a unix socket completes synchronously in libuv, so this wait
  -- usually returns on the first iteration. The timeout only protects a
  -- pathologically slow filesystem.
  vim.wait(500, function()
    return connected or failed
  end, 5)
  pcall(function()
    pipe:close()
  end)
  return connected
end

---Parse the single status line printed by `nvim_ade_server serve`.
---@param line string|nil
---@return table|nil status
---@return string|nil err
function M.parse_status(line)
  if type(line) ~= "string" or vim.trim(line) == "" then
    return nil, "the service printed no status line"
  end
  local ok, decoded = pcall(vim.json.decode, vim.trim(line))
  if not ok or type(decoded) ~= "table" then
    return nil, "the service status is not JSON: " .. line:sub(1, 120)
  end
  local status = decoded.status
  if status ~= "ready" and status ~= "already_running" and status ~= "error" then
    return nil, "unknown service status: " .. tostring(status)
  end
  return decoded, nil
end

---Spawn the service and wait for its status line.
---
---`spawn` is injectable: tests replace it with a scripted function so no real
---process is started.
---@param opts {bin: string, paths: table, timeout?: integer, idle_timeout?: integer,
---  spawn?: fun(argv: string[], on_line: fun(line: string), on_exit: fun(code: integer)): boolean}
---@return boolean ok
---@return string|nil err
---@return table|nil status
function M.start(opts)
  local timeout = opts.timeout or M.DEFAULT_START_TIMEOUT
  local paths = opts.paths or Paths.paths()
  local argv = { opts.bin, "serve" }
  -- The service owns the idle timer, so the configured value has to travel with
  -- the command line rather than in any front-end state.
  if type(opts.idle_timeout) == "number" and opts.idle_timeout > 0 then
    vim.list_extend(argv, { "--idle-timeout", tostring(math.floor(opts.idle_timeout)) })
  end
  local spawn = opts.spawn
    or function(cmd, on_line, on_exit)
      local lines = {}
      local id = vim.fn.jobstart(cmd, {
        detach = true,
        stdin = "null",
        on_stdout = function(_, data)
          for _, chunk in ipairs(data or {}) do
            if chunk ~= "" then
              lines[#lines + 1] = chunk
              on_line(table.concat(lines, "\n"))
            end
          end
        end,
        on_exit = function(_, code)
          on_exit(code or -1)
        end,
      })
      return type(id) == "number" and id > 0
    end

  local status, failure, exited = nil, nil, nil
  local started = spawn(argv, function(line)
    if status then
      return
    end
    local parsed, err = M.parse_status(line)
    if parsed then
      status = parsed
    elseif err then
      failure = err
    end
  end, function(code)
    exited = code
  end)
  if not started then
    return false, "unable to start " .. opts.bin, nil
  end
  vim.wait(timeout, function()
    return status ~= nil or exited ~= nil
  end, 10)
  if not status then
    if failure then
      return false, "the service printed an unusable status: " .. failure, nil
    end
    if exited ~= nil then
      return false, string.format("the service exited with %s before becoming ready", tostring(exited)), nil
    end
    return false, string.format("the service did not become ready within %d ms", timeout), nil
  end
  if status.status == "error" then
    return false, "the service failed to start: " .. tostring(status.message or "no message"), status
  end
  return true, nil, status
end

---Make sure a service is running and return the paths to reach it.
---
---The binary comes from `install.resolve_binary`, the single place that knows
---about `service.path` versus the managed install, unless the caller passes an
---explicit `bin` (tests, and a future "run exactly this" path). Returns
---`false, reason` when there is no usable binary; the reason is written to be
---shown to the user as-is.
---@param opts {bin?: string, config?: table, path?: string, data_dir?: string,
---  timeout?: integer, idle_timeout?: integer, spawn?: function,
---  probe?: fun(paths: table): boolean, run?: function}|nil
---@return boolean ok
---@return string|nil err
---@return table|nil info `{paths, status, bin, version, source, warning}`
function M.ensure(opts)
  opts = opts or {}
  local paths = Paths.paths()
  local probe = opts.probe or M.probe
  if probe(paths) then
    log.debug("service already reachable at %s", paths.socket)
    return true, nil, { paths = paths, status = { status = "already_running", socket = paths.socket } }
  end

  local install = require("ade.service.install")
  local bin, resolved = opts.bin, nil
  if not bin then
    local resolve_opts = {
      config = opts.config,
      path = opts.path,
      data_dir = opts.data_dir,
      target = opts.target,
      run = opts.run,
      timeout = opts.timeout or M.DEFAULT_START_TIMEOUT,
    }
    local resolve_err
    resolved, resolve_err = install.resolve_binary(resolve_opts)
    if not resolved then
      return false, resolve_err, nil
    end
    bin = resolved.path
    if resolved.warning then
      log.warn("%s", resolved.warning)
    end
  end

  -- `resolve_binary` already refused a non-executable file; an explicit `bin`
  -- has not been checked yet.
  if vim.fn.executable(bin) ~= 1 then
    return false, "the service binary is not executable: " .. bin, nil
  end

  log.info("starting nvim_ade_server: %s", bin)
  local ok, err, status = M.start({
    bin = bin,
    paths = paths,
    timeout = opts.timeout,
    idle_timeout = opts.idle_timeout,
    spawn = opts.spawn,
  })
  if not ok then
    return false, err, nil
  end
  return true,
    nil,
    {
      paths = paths,
      status = status,
      bin = bin,
      version = resolved and resolved.version or nil,
      source = resolved and resolved.source or nil,
      warning = resolved and resolved.warning or nil,
    }
end

return M
