-- `:Ade service <subcommand>`.
--
-- Kept out of `plugin/ade.lua` so the command handler can be tested without
-- creating user commands, and so all service actions report through the same
-- notify helper. None of these subcommands change the chat backend: S0 only
-- makes the service installable, startable and inspectable.
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
  if type(service.path) == "string" and service.path ~= "" then
    local ok, err = require("ade.service.install").check_configured({ path = service.path })
    if ok then
      show("service.path is usable (version " .. tostring(ok.version) .. ")")
    else
      show(tostring(err), vim.log.levels.WARN)
    end
    return
  end
  local install = opts.install or require("ade.service.install")
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
  local ok, err, info = launcher.ensure({ timeout = service.start_timeout })
  if not ok then
    show(tostring(err), vim.log.levels.WARN)
    return false
  end
  local status = info and info.status
  if status and status.status == "already_running" then
    show("service is already running at " .. tostring(status.socket))
  else
    show("service is ready (version " .. Version.VERSION .. ")")
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

---Dispatch one `:Ade service <sub>` invocation.
---@param sub string|nil
---@param opts table|nil
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
  end
  local show = (opts and opts.notify) or notify
  show("unknown service subcommand " .. sub .. " (install|status|start|stop)", vim.log.levels.WARN)
  return nil
end

return M
