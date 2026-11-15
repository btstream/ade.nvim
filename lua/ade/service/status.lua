-- Read-only description of the service, shared by `:Ade service status` and
-- `:checkhealth ade`.
--
-- Everything here only inspects: it never installs, starts or stops anything.
-- The health check must stay safe to run at any time, and the status command
-- must be able to answer "nothing is installed" without a side effect.
local Paths = require("ade.service.paths")
local Version = require("ade.service.version")

local M = {}

---Collect the current state.
---
---`client` is injected so the tests can answer `ping` without a real service.
---@param opts {config?: table, client?: table, launcher?: table, timeout?: integer}|nil
---@return table status
function M.collect(opts)
  opts = opts or {}
  local config = opts.config or require("ade.config").effective()
  local service_cfg = type(config.service) == "table" and config.service or {}
  local install = require("ade.service.install")
  local paths = Paths.paths()
  local data_dir = vim.fn.stdpath("data")

  local status = {
    required_version = Version.VERSION,
    required_api_version = Version.API_VERSION,
    configured_path = service_cfg.path,
    dir = paths.dir,
    socket = paths.socket,
    backend = config.backend,
    installed_version = nil,
    binary = nil,
    running = false,
    reachable = false,
    api_version = nil,
    api_ok = nil,
    server_version = nil,
    instances = nil,
    warning = nil,
    error = nil,
    ping_error = nil,
    instances_error = nil,
  }

  if type(service_cfg.path) == "string" and service_cfg.path ~= "" then
    local resolved, err = install.resolve_binary({ path = service_cfg.path, run = opts.run })
    status.binary = vim.fs.normalize(vim.fn.expand(service_cfg.path))
    if resolved then
      status.server_version = resolved.version
      status.api_version = resolved.api_version
      status.api_ok = resolved.api_version == Version.API_VERSION
      status.installed_version = resolved.version
      status.warning = resolved.warning
    end
    status.error = err
  else
    local resolved, err = install.resolve_binary({ data_dir = data_dir, run = opts.run })
    if resolved then
      status.binary = resolved.path
      status.installed_version = resolved.version
      status.api_version = resolved.api_version
      status.api_ok = resolved.api_version == Version.API_VERSION
      status.warning = resolved.warning
    else
      status.binary = nil
      status.installed_version = nil
      status.error = err
    end
  end

  -- Reachability first: it is cheap and does not need a token. A ping then
  -- proves the protocol works, which is what "running" should mean.
  local launcher = opts.launcher or require("ade.service.launcher")
  status.reachable = launcher.probe(paths)
  if status.reachable then
    local Client = require("ade.service.client")
    local client = (opts.client or Client).new({ paths = paths, timeout = opts.timeout or 2000 })
    local answered, info = false, nil
    client:connect(function(ok, value)
      answered, info = ok, value
    end)
    if answered and type(info) == "table" then
      status.running = true
      status.server_version = info.server_version or status.server_version
      status.api_version = info.api_version or status.api_version
      status.api_ok = info.api_version == Version.API_VERSION
      -- Both calls must produce a value before this function returns: status is
      -- a synchronous report. The bounded wait lives in
      -- `Connection.await_request` — the one implementation shared with the
      -- command helpers.
      local ServiceConnection = require("ade.service.connection")
      local ok_ping, ping_value = ServiceConnection.await_request(client, "ping", {}, opts.timeout)
      if not ok_ping then
        status.ping_error = require("ade.service.transport").describe(ping_value)
      end
      local list_ok, list_value = ServiceConnection.await_request(client, "agent.list", {}, opts.timeout)
      if list_ok and type(list_value) == "table" and type(list_value.instances) == "table" then
        status.instances = #list_value.instances
      else
        -- The count is optional (`agent.list` only exists from api_version 2),
        -- so a failure here is reported but does not make the service "not
        -- running". It must still carry a reason, and it must not be swallowed
        -- by an unrelated earlier error.
        status.instances_error = require("ade.service.transport").describe(list_value)
      end
    else
      status.error = status.error or tostring(info)
    end
    client:close()
  end

  return status
end

---One line for an `agent.list` entry.
---@param instance table
---@param now integer|nil unix seconds
---@return string
function M.instance_line(instance, now)
  now = now or os.time()
  local started = tonumber(instance.started_at)
  local uptime = ""
  if started then
    local seconds = math.max(0, now - math.floor(started / 1000))
    if seconds >= 3600 then
      uptime = string.format(" %dh%02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
    elseif seconds >= 60 then
      uptime = string.format(" %dm%02ds", math.floor(seconds / 60), seconds % 60)
    else
      uptime = string.format(" %ds", seconds)
    end
  end
  return string.format(
    "%s  %s  %s  pid %s%s  attached %s  turns %s  pending %s",
    tostring(instance.instance),
    tostring(instance.agent),
    tostring(instance.cwd),
    tostring(instance.pid),
    uptime,
    tostring(instance.attached or 0),
    tostring(instance.turns_running or 0),
    tostring(instance.pending_requests or 0)
  )
end

---Human-readable lines for the status command and the health section.
---@param status table
---@return {level: string, text: string}[]
function M.lines(status)
  local out = {}
  local function add(level, text)
    out[#out + 1] = { level = level, text = text }
  end
  add(
    "info",
    "required service version: " .. status.required_version .. " (api_version " .. status.required_api_version .. ")"
  )
  add("info", "backend: " .. tostring(status.backend))
  if status.configured_path then
    add("info", "service.path: " .. tostring(status.configured_path))
  end
  if status.installed_version then
    add("info", "installed version: " .. tostring(status.installed_version))
  else
    add("warn", "the service is not installed; run :Ade service install")
  end
  if status.binary then
    if vim.fn.executable(status.binary) == 1 then
      add("ok", "binary: " .. status.binary)
    else
      add("warn", "binary is not executable: " .. status.binary)
    end
  end
  if status.warning then
    add("warn", tostring(status.warning))
  end
  add("info", "directory: " .. status.dir)
  add("info", "socket: " .. status.socket)
  if status.running then
    add(
      "ok",
      "service is running" .. (status.server_version and (" (version " .. tostring(status.server_version) .. ")") or "")
    )
    if status.instances ~= nil then
      add("info", "agent instances: " .. tostring(status.instances))
    end
  elseif status.reachable then
    add("warn", "the socket accepts connections but hello/ping failed")
  else
    add("info", "service is not running")
  end
  if status.api_ok == true then
    add("ok", "api_version " .. tostring(status.api_version) .. " matches")
  elseif status.api_ok == false then
    add(
      "error",
      "api_version " .. tostring(status.api_version) .. " does not match the required " .. status.required_api_version
    )
  end
  if status.ping_error then
    add("warn", "ping failed: " .. tostring(status.ping_error))
  end
  if status.instances_error then
    add("warn", tostring(status.instances_error))
  end
  -- "not installed" is already reported above; repeating it only adds noise.
  if status.error and status.installed_version then
    add(status.running and "warn" or "info", tostring(status.error))
  end
  return out
end

return M
