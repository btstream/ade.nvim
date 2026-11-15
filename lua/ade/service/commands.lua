-- `:Ade service <subcommand>`.
--
-- Kept out of `plugin/ade.lua` so the command handler can be tested without
-- creating user commands, and so all service actions report through the same
-- notify helper. These subcommands manage the service itself; which backend
-- carries the chat is `config.backend`, set at setup time.
local log = require("ade.log")
local Version = require("ade.service.version")

local M = {}

---@return table
local function service_config()
  local ok, cfg = pcall(function()
    return require("ade.config").effective()
  end)
  if not ok or type(cfg) ~= "table" or type(cfg.service) ~= "table" then
    return { install_timeout = 10 * 60 * 1000, start_timeout = 5000 }
  end
  return cfg.service
end

---@param message string
---@param level integer|nil
local function notify(message, level)
  vim.notify("ade.nvim: " .. message, level or vim.log.levels.INFO)
end

---Print the status lines through `vim.notify`, worst level last.
---@param opts {config?: table, notify?: fun(message: string, level: integer|nil)}|nil
---@return table status
function M.status(opts)
  opts = opts or {}
  local show = opts.notify or notify
  local config = opts.config or require("ade.config").effective()
  local Status = require("ade.service.status")
  local status = Status.collect({ config = config })
  local levels =
    { ok = vim.log.levels.INFO, info = vim.log.levels.INFO, warn = vim.log.levels.WARN, error = vim.log.levels.ERROR }
  for _, line in ipairs(Status.lines(status)) do
    show(line.text, levels[line.level] or vim.log.levels.INFO)
  end
  return status
end

---`:Ade service install`: download/compile in the background.
---@param opts {config?: table, install?: table, notify?: fun(message: string, level: integer|nil)}|nil
function M.install(opts)
  opts = opts or {}
  local show = opts.notify or notify
  local service = (opts.config and opts.config.service) or service_config()
  local install = opts.install or require("ade.service.install")
  if type(service.path) == "string" and service.path ~= "" then
    -- `run` handles `service.path` itself (version check only), so the command
    -- and the build hook cannot drift apart.
    local ok, err = install.run({
      path = service.path,
      config = opts.config,
      timeout = service.install_timeout,
      on_notify = function(message)
        show(message)
      end,
      on_progress = function(message)
        log.info("service: %s", message)
      end,
    })
    if ok then
      show("service.path is usable")
    elseif err then
      show(tostring(err), vim.log.levels.WARN)
    end
    return
  end
  install.install_async({
    release_base = service.release_base,
    timeout = service.install_timeout,
    on_notify = function(message)
      show(message)
    end,
    on_progress = function(message)
      log.info("service: %s", message)
    end,
  })
end

---`:Ade service start`: make sure a service is running.
---@param opts {config?: table, launcher?: table, notify?: fun(message: string, level: integer|nil)}|nil
function M.start(opts)
  opts = opts or {}
  local show = opts.notify or notify
  local launcher = opts.launcher or require("ade.service.launcher")
  local service = (opts.config and opts.config.service) or service_config()
  -- The launcher resolves `service.path` itself through
  -- `install.resolve_binary`, so start, status and health always agree about
  -- which binary runs.
  local ok, err, info = launcher.ensure({
    config = opts.config,
    path = service.path,
    timeout = service.start_timeout,
  })
  if not ok then
    show(tostring(err), vim.log.levels.WARN)
    return false
  end
  if info and info.warning then
    show(tostring(info.warning), vim.log.levels.WARN)
  end
  local status = info and info.status
  if status and status.status == "already_running" then
    show("service is already running at " .. tostring(status.socket))
  else
    local where = info and info.bin and (" at " .. info.bin) or ""
    show("service is ready (version " .. tostring(info and info.version or Version.VERSION) .. ")" .. where)
  end
  return true
end

---`:Ade service stop`: ask a running service to exit.
---@param opts {config?: table, client?: table, notify?: fun(message: string, level: integer|nil)}|nil
function M.stop(opts)
  opts = opts or {}
  local show = opts.notify or notify
  local Client = opts.client or require("ade.service.client")
  local client = Client.new({ timeout = 5000 })
  local connected, info = false, nil
  client:connect(function(ok, value)
    connected, info = ok, value
  end)
  if not connected then
    client:close()
    show("the service is not running: " .. tostring(info))
    return false
  end
  local answered, err = false, nil
  client:shutdown(function(ok, value)
    answered = ok
    if not ok then
      err = value
    end
  end)
  client:close()
  if answered then
    show("service stopped")
    return true
  end
  show("unable to stop the service: " .. tostring(err), vim.log.levels.WARN)
  return false
end

---`:Ade service agents`: list the agent instances the service is holding.
---@param opts {config?: table, connection?: table, notify?: fun(message: string, level: integer|nil)}|nil
---@return table|nil instances
function M.agents(opts)
  opts = opts or {}
  local show = opts.notify or notify
  local connection = opts.connection or require("ade.service.connection").shared()
  local instances, failure = nil, nil
  connection:request("agent.list", {}, function(ok, value)
    if ok and type(value) == "table" then
      instances = value.instances or {}
    else
      failure = require("ade.service.transport").describe(value)
    end
  end)
  if not instances then
    show("unable to list agents: " .. tostring(failure), vim.log.levels.WARN)
    return nil
  end
  if #instances == 0 then
    show("no agent instances")
    return instances
  end
  local now = os.time()
  for _, instance in ipairs(instances) do
    show(require("ade.service.status").instance_line(instance, now))
  end
  return instances
end

---`:Ade service kill <instance>`: stop one agent instance.
---@param instance string|nil
---@param opts {config?: table, connection?: table, notify?: fun(message: string, level: integer|nil)}|nil
function M.kill(instance, opts)
  opts = opts or {}
  local show = opts.notify or notify
  if type(instance) ~= "string" or instance == "" then
    show(":Ade service kill needs an instance id (see :Ade service agents)", vim.log.levels.WARN)
    return false
  end
  local connection = opts.connection or require("ade.service.connection").shared()
  local done, failure = false, nil
  connection:request("agent.stop", { instance = instance }, function(ok, value)
    done = ok
    if not ok then
      failure = require("ade.service.transport").describe(value)
    end
  end)
  if done then
    show("stopped agent " .. instance)
    return true
  end
  show("unable to stop " .. instance .. ": " .. tostring(failure), vim.log.levels.WARN)
  return false
end

---Dispatch one `:Ade service <sub>` invocation.
---@param sub string|nil
---@param opts table|nil extra options; `rest` carries `kill`'s instance id
function M.dispatch(sub, opts)
  sub = sub or "status"
  if sub == "install" then
    return M.install(opts)
  elseif sub == "status" then
    return M.status(opts)
  elseif sub == "start" then
    return M.start(opts)
  elseif sub == "stop" then
    return M.stop(opts)
  elseif sub == "agents" then
    return M.agents(opts)
  elseif sub == "kill" then
    return M.kill(opts and opts.rest, opts)
  end
  local show = (opts and opts.notify) or notify
  show("unknown service subcommand " .. sub .. " (install|status|start|stop|agents|kill)", vim.log.levels.WARN)
  return nil
end

return M
