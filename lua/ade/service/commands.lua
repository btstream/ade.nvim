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

---Default ceiling for one command request, in milliseconds.
M.DEFAULT_TIMEOUT = 5000

---Send one request and report the outcome through `cb`, at most once.
---
---Every `:Ade service` command is asynchronous: the reply arrives after the
---command returns. A missing reply (a wedged service) and a dropped connection
---both have to end as a failure, or the UI silently does nothing — which is
---exactly the "unable to list agents: nil" the bug report showed.
---@param connection table
---@param method string
---@param params any
---@param opts {timeout?: integer, on_done: fun(ok: boolean, value: any)}|nil
function M.request(connection, method, params, opts)
  opts = opts or {}
  local on_done = opts.on_done or function() end
  local timeout = opts.timeout or M.DEFAULT_TIMEOUT
  local settled = false
  local timer
  local function finish(ok, value)
    if settled then
      return
    end
    settled = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    pcall(on_done, ok, value)
  end
  -- The connection reports a drop through its own fan-out; subscribe so an
  -- in-flight request fails instead of hanging.
  local channel = "command-" .. tostring(vim.uv.hrtime())
  connection:subscribe(channel, "__disconnected", function(payload)
    local reason = type(payload) == "table" and tostring(payload.reason or "connection lost") or "connection lost"
    finish(false, { code = -32000, message = reason })
  end)
  connection:request(method, params, function(ok, value)
    finish(ok, value)
  end)
  if timeout and timeout > 0 then
    timer = vim.uv.new_timer()
    timer:start(timeout, 0, function()
      vim.schedule(function()
        finish(false, {
          code = -32000,
          message = string.format("the service did not answer %s within %.1f seconds", method, timeout / 1000),
        })
      end)
    end)
  end
  return function()
    finish(false, { code = -32000, message = "command cancelled" })
  end
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
---
---`connect` and `shutdown` are both blocking on the client, so this command
---completes synchronously like before; the timeout reasons are now explicit
---instead of a bare `nil`.
---@param opts {config?: table, client?: table, timeout?: integer,
---  notify?: fun(message: string, level: integer|nil), on_done?: fun(ok: boolean)}|nil
function M.stop(opts)
  opts = opts or {}
  local show = opts.notify or notify
  local timeout = opts.timeout or M.DEFAULT_TIMEOUT
  -- The panel holds the same service through the shared connection. Stopping
  -- with a second client leaves that one to discover EOF with no intent, so
  -- the automatic reconnect loop starts again against the user's wish. When the
  -- shared connection is live, stop through it: `Connection:shutdown` marks the
  -- loss deliberate and closes the client the panel is actually using.
  local shared
  if not opts.client then
    shared = opts.connection or require("ade.service.connection").shared()
  end
  if type(shared) == "table" and type(shared.is_connected) == "function" then
    -- Cancel the retry loop first, including the case where no socket exists
    -- (between attempts), where no EOF can carry the intent.
    if type(shared.stopped_intent) == "function" then
      local ok, err = pcall(shared.stopped_intent, shared)
      if not ok then
        log.warn("could not cancel the reconnect loop for :Ade service stop: %s", tostring(err))
      end
    end
    -- An attempt may be inside `ensure()` right now (`connecting` is true and
    -- the new client does not exist yet). Cancelling the loop does not stop
    -- that attempt, so wait for it and then stop through the client it created:
    -- the intent is attached to that client, and the EOF it produces is
    -- deliberate.
    if shared.connecting then
      vim.wait(timeout, function()
        return not shared.connecting
      end, 10)
    end
    if shared:is_connected() then
      local answered, err = false, nil
      shared:shutdown(function(ok, value)
        answered = ok
        if not ok then
          err = value
        end
      end, timeout)
      if answered then
        show("service stopped")
        if opts.on_done then
          pcall(opts.on_done, true)
        end
        return true
      end
      local reason = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
      if type(err) == "table" and err.pending then
        -- Not a failure to retry: the request is still with the service, and
        -- the intent stays on that client so its eventual exit is deliberate.
        show("service stop requested; the service has not confirmed it yet (" .. reason .. ")", vim.log.levels.WARN)
      else
        show("unable to stop the service: " .. reason, vim.log.levels.WARN)
      end
      if opts.on_done then
        pcall(opts.on_done, false)
      end
      return false
    end
  end
  local Client = opts.client or require("ade.service.client")
  local client = Client.new({ timeout = timeout })
  local connected, info = false, nil
  client:connect(function(ok, value)
    connected, info = ok, value
  end)
  if not connected then
    client:close()
    local reason = type(info) == "table" and (info.message or vim.inspect(info)) or tostring(info)
    show("the service is not running: " .. reason)
    if opts.on_done then
      pcall(opts.on_done, false)
    end
    return false
  end
  local answered, err = false, nil
  client:shutdown(function(ok, value)
    answered = ok
    if not ok then
      err = value
    end
  end, timeout)
  client:close()
  if answered then
    show("service stopped")
    if opts.on_done then
      pcall(opts.on_done, true)
    end
    return true
  end
  local reason = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
  show("unable to stop the service: " .. reason, vim.log.levels.WARN)
  if opts.on_done then
    pcall(opts.on_done, false)
  end
  return false
end

---`:Ade service agents`: list the agent instances the service is holding.
---
---Asynchronous: the reply is printed from the callback. The command returns
---nothing; reading a result here would be the very bug this replaced.
---@param opts {config?: table, connection?: table, timeout?: integer,
---  notify?: fun(message: string, level: integer|nil),
---  on_done?: fun(instances: table|nil)}|nil
function M.agents(opts)
  opts = opts or {}
  local show = opts.notify or notify
  local connection = opts.connection or require("ade.service.connection").shared()
  return M.request(connection, "agent.list", {}, {
    timeout = opts.timeout,
    on_done = function(ok, value)
      if not ok then
        show("unable to list agents: " .. require("ade.service.transport").describe(value), vim.log.levels.WARN)
        if opts.on_done then
          pcall(opts.on_done, nil)
        end
        return
      end
      local instances = type(value) == "table" and value.instances or nil
      if type(instances) ~= "table" then
        show("unable to list agents: the service returned no instance list", vim.log.levels.WARN)
        if opts.on_done then
          pcall(opts.on_done, nil)
        end
        return
      end
      if #instances == 0 then
        show("no agent instances")
      else
        local now = os.time()
        for _, instance in ipairs(instances) do
          show(require("ade.service.status").instance_line(instance, now))
        end
      end
      if opts.on_done then
        pcall(opts.on_done, instances)
      end
    end,
  })
end

---`:Ade service kill <instance>`: stop one agent instance.
---
---Asynchronous like `agents`. A missing id is the one local error, and it is
---reported immediately because no request is sent.
---@param instance string|nil
---@param opts {config?: table, connection?: table, timeout?: integer,
---  notify?: fun(message: string, level: integer|nil),
---  on_done?: fun(ok: boolean)}|nil
function M.kill(instance, opts)
  opts = opts or {}
  local show = opts.notify or notify
  if type(instance) ~= "string" or instance == "" then
    show(":Ade service kill needs an instance id (see :Ade service agents)", vim.log.levels.WARN)
    if opts.on_done then
      pcall(opts.on_done, false)
    end
    return
  end
  local connection = opts.connection or require("ade.service.connection").shared()
  return M.request(connection, "agent.stop", { instance = instance }, {
    timeout = opts.timeout,
    on_done = function(ok, value)
      if ok then
        show("stopped agent " .. instance)
      else
        show(
          "unable to stop " .. instance .. ": " .. require("ade.service.transport").describe(value),
          vim.log.levels.WARN
        )
      end
      if opts.on_done then
        pcall(opts.on_done, ok)
      end
    end,
  })
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
