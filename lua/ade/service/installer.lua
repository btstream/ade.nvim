-- Managed installs executed by nvim_ade_server (PROTOCOL.md section 16).
--
-- Same interface as `ade.manager.install`: `install(id, opts, cb)`,
-- `uninstall(id, opts, cb)` and the same progress events, so the agent manager
-- only chooses an implementation and keeps its decisions (confirmation,
-- per-agent task state, notifications) unchanged.
--
-- What moves into the service:
--   * npm runs in the service's process group, with the environment this
--     front end sends, and keeps running when Neovim exits;
--   * the exclusive lock and the release pruning are the service's;
--   * leases for agents the service runs belong to the service (section 16.4).
--
-- What stays here: the registry (package, entry, notes), the "root must not be
-- the working directory" check, the confirmation, and mapping error codes to
-- the wording the user already knows.
local npm_mod = require("ade.manager.npm")
local Registry = require("ade.manager.registry")
local Resolve = require("ade.manager.resolve")
local Store = require("ade.manager.store")

local M = {}

local Installer = {}
Installer.__index = Installer

local job_counter = 0

---A job id the service accepts: `[A-Za-z0-9_-]{1,64}`, unique among the jobs it
---runs. The hrtime suffix separates two front ends that start at the same time.
---@param id string
---@return string
local function new_job(id)
  job_counter = job_counter + 1
  local stamp = string.format("%d", vim.uv.hrtime() % 1e12)
  local suffix = string.format("%d", math.random(1000, 9999))
  return string.format("%s-%s-%s", id:sub(1, 32), stamp, suffix):sub(1, 64)
end

---@param opts {config: fun(): table, connection: table, store: table,
---  notify?: fun(message: string, level: integer|nil),
---  on_progress?: fun(event: table),
---  on_foreign?: fun(event: table),
---  on_changed?: fun()|nil}
---@return table
function M.new(opts)
  local self = setmetatable({
    config = opts.config,
    connection = opts.connection,
    store = opts.store,
    notify = opts.notify or function() end,
    on_progress = opts.on_progress,
    on_foreign = opts.on_foreign,
    on_changed = opts.on_changed,
    -- Per-agent in-flight operation: job id, phase and the JSON-RPC handle to
    -- cancel. One at a time, like the Lua installer.
    jobs = {},
    -- Jobs started by other front ends, keyed by agent id. They make the window
    -- show the agent as busy; the service owns their outcome.
    foreign = {},
  }, Installer)
  pcall(self.connection.subscribe, self.connection, "manager-install", "install.progress", function(payload)
    self:on_service_progress(payload)
  end)
  return self
end

---@param event table
function Installer:progress(event)
  if self.on_progress then
    pcall(self.on_progress, event)
  end
end

function Installer:changed()
  if self.on_changed then
    pcall(self.on_changed)
  end
end

---@return string
function Installer:root()
  return Resolve.manager_root(self.config())
end

---The npm the service should run.
---
---`exepath` gives the absolute path the user's PATH actually resolves, which
---the service needs because its own PATH is not the editor's; when npm is not
---found the configured value is sent as-is so the service reports that it
---cannot start it, instead of this layer guessing.
---@return string
function Installer:npm_path()
  local cfg = self.config() or {}
  local manager_cfg = type(cfg.manager) == "table" and cfg.manager or {}
  local configured = manager_cfg.npm or "npm"
  local found = vim.fn.exepath(configured)
  if type(found) == "string" and found ~= "" then
    return found
  end
  return configured
end

---The complete environment for npm (section 16.3: it is not merged).
---@return table<string, string>
function Installer:env()
  local ok, env = pcall(vim.fn.environ)
  if not ok or type(env) ~= "table" then
    return {}
  end
  return env
end

---@param id string
---@param action string
---@return table|nil entry
---@return string|nil err
function Installer:prepare(id, action)
  local entry = Registry.get(id)
  if not entry then
    return nil, "unknown agent " .. tostring(id)
  end
  if not entry.installable then
    local _, reason = Registry.installable(id)
    return nil, reason or "this agent is not installed by ade.nvim"
  end
  if self.jobs[id] then
    return nil, "an operation is already running for " .. id
  end
  local root = self:root()
  if not root or root == "" then
    return nil, "manager.root is not configured"
  end
  -- The service cannot know the editor's working directory, so that part of
  -- the rule stays here; absolute/home/root are checked here too for the
  -- immediate message, and again by the service.
  local root_ok, root_err = Store.check_root(root)
  if not root_ok then
    return nil, root_err
  end
  if action == "update" then
    local state = self.store:state(id)
    if state.status == "not_installed" then
      return nil, id .. " is not installed; use install"
    end
  end
  return entry
end

---@param id string
---@param action string
---@param value any
---@return table
function Installer:map_error(id, action, value)
  local code = type(value) == "table" and value.code or nil
  local reason = type(value) == "table" and value.message or tostring(value)
  local data = type(value) == "table" and type(value.data) == "table" and value.data or {}
  local detail = type(data.reason) == "string" and data.reason or reason
  if code == -32800 then
    return { cancelled = true }
  end
  if code == -32042 then
    return { message = string.format("%s: another instance is using this agent: %s", id, tostring(detail)) }
  end
  if code == -32044 then
    return { message = string.format("cannot remove %s: %s", id, tostring(detail)) }
  end
  if code == -32045 then
    if action == "update" then
      return { message = id .. " is not installed; use install" }
    end
    return { message = id .. " has no manager-owned install" }
  end
  if code == -32043 then
    return {
      message = tostring(reason),
      log = type(data.log) == "string" and data.log or nil,
    }
  end
  return { message = tostring(reason) }
end

---Turn one `install.progress` notification into the manager's event shape.
---@param payload table
function Installer:on_service_progress(payload)
  local id = payload and payload.agent
  if type(id) ~= "string" then
    return
  end
  local own = self.jobs[id]
  local event = {
    id = id,
    job = payload.job,
    phase = payload.phase,
    action = payload.action,
    line = payload.line,
    version = payload.version,
    dir = payload.dir,
    message = payload.message,
  }
  if own and payload.job == own.job then
    own.phase = payload.phase
    self:progress(event)
    return
  end
  -- Another front end's job: show the agent as busy and refresh, but never
  -- touch this front end's task state (that job's response is not ours).
  local terminal = payload.phase == "committed"
    or payload.phase == "failed"
    or payload.phase == "cancelled"
    or payload.phase == "removed"
  if terminal then
    if not self.foreign[id] or self.foreign[id].job == payload.job then
      self.foreign[id] = nil
    end
  else
    self.foreign[id] = {
      id = id,
      job = payload.job,
      action = payload.action,
      phase = payload.phase,
      foreign = true,
    }
  end
  if self.on_foreign then
    pcall(self.on_foreign, self.foreign[id] or { id = id, job = payload.job, phase = payload.phase })
  end
  self:changed()
end

---@param id string
---@param cb fun(ok: boolean, value: any)
function Installer:resolve(id, spec, cb)
  local entry = assert(Registry.get(id))
  local root = self:root()
  local handle = self.connection:request_tracked("install.resolve", {
    root = root,
    package = entry.package,
    spec = spec,
    npm = self:npm_path(),
    env = self:env(),
    timeout_ms = 60000,
  }, cb)
  return handle
end

---The latest version, for `Manager:check_outdated` (read-only, no lock).
---@param package string
---@param cb fun(ok: boolean, version_or_err: any)
function Installer:latest(package, cb)
  local root = self:root()
  if not root or root == "" then
    cb(false, "manager.root is not configured")
    return
  end
  self.connection:request_tracked("install.resolve", {
    root = root,
    package = package,
    spec = "latest",
    npm = self:npm_path(),
    env = self:env(),
    timeout_ms = 60000,
  }, function(ok, value)
    if ok and type(value) == "table" and type(value.version) == "string" then
      cb(true, value.version)
    else
      cb(false, value)
    end
  end)
end

---@param id string
---@param opts {version?: string, action?: string,
---  confirm: fun(details: table, answer: fun(accepted: boolean))}
---@param cb fun(ok: boolean, result_or_err: any)
function Installer:install(id, opts, cb)
  local action = opts.action or "install"
  local entry, prep_err = self:prepare(id, action)
  if not entry then
    cb(false, prep_err)
    return
  end
  local requested = opts.version or "latest"
  local version_ok, version_err = npm_mod.valid_version(requested)
  if not version_ok then
    cb(false, version_err)
    return
  end
  local job = {
    id = id,
    job = new_job(id),
    action = action,
    phase = "checking",
  }
  self.jobs[id] = job
  local finished = false
  local function finish(ok, value)
    if finished then
      return
    end
    finished = true
    self.jobs[id] = nil
    cb(ok, value)
  end
  self:progress({ id = id, phase = "checking", action = action })
  job.handle = self:resolve(id, requested, function(ok, value)
    job.handle = nil
    if job.cancel_requested then
      finish(false, { cancelled = true })
      return
    end
    if not ok then
      finish(false, self:map_error(id, action, value))
      return
    end
    local version = type(value) == "table" and value.version or nil
    if type(version) ~= "string" then
      finish(false, { message = "the service returned no version" })
      return
    end
    if action == "update" then
      local state = self.store:state(id)
      if state.status == "installed" and state.install and state.install.version == version then
        finish(true, { id = id, version = version, unchanged = true })
        return
      end
    end
    local details = {
      id = id,
      action = action,
      package = entry.package,
      version = version,
      root = self:root(),
      homepage = entry.homepage,
      requires = entry.requires,
      notes = entry.notes,
    }
    local answered = false
    local function answer(accepted)
      if answered then
        return
      end
      answered = true
      if not accepted or job.cancel_requested then
        finish(false, { cancelled = true })
        return
      end
      self:run(id, entry, version, action, job, finish)
    end
    local asked, ask_err = pcall(opts.confirm, details, answer)
    if not asked then
      finish(false, { message = "confirmation failed: " .. tostring(ask_err) })
    end
  end)
  if job.cancel_requested and job.handle then
    self.connection:cancel_request(job.handle.id)
  end
end

---Send `install.run` for the version the user confirmed.
---@param id string
---@param entry table
---@param version string
---@param action string
---@param job table
---@param finish fun(ok: boolean, value: any)
function Installer:run(id, entry, version, action, job, finish)
  if job.cancel_requested then
    finish(false, { cancelled = true })
    return
  end
  local cfg = self.config() or {}
  local manager_cfg = type(cfg.manager) == "table" and cfg.manager or {}
  job.phase = "installing"
  job.handle = self.connection:request_tracked("install.run", {
    job = job.job,
    root = self:root(),
    agent = id,
    action = action,
    package = entry.package,
    entry = entry.entry,
    bin = entry.bin,
    version = version,
    npm = self:npm_path(),
    env = self:env(),
    timeout_ms = manager_cfg.install_timeout or 300000,
    max_log_bytes = manager_cfg.max_log_bytes or 1024 * 1024,
  }, function(ok, value)
    job.handle = nil
    if not ok then
      finish(false, self:map_error(id, action, value))
      return
    end
    local status = type(value) == "table" and value.status or nil
    if status == "unchanged" then
      finish(true, { id = id, version = (type(value) == "table" and value.version) or version, unchanged = true })
      return
    end
    if status ~= "committed" then
      finish(false, { message = "the service returned no install status" })
      return
    end
    finish(true, {
      id = id,
      version = value.version or version,
      install_id = value.installId,
      dir = value.dir,
    })
  end)
  if job.cancel_requested and job.handle then
    self.connection:cancel_request(job.handle.id)
  end
end

---Remove the manager-owned copy of one agent.
---@param id string
---@param opts {confirm: fun(details: table, answer: fun(accepted: boolean))}
---@param cb fun(ok: boolean, result_or_err: any)
function Installer:uninstall(id, opts, cb)
  local entry, prep_err = self:prepare(id, "uninstall")
  if not entry then
    cb(false, prep_err)
    return
  end
  local state = self.store:state(id)
  if state.status == "not_installed" then
    cb(false, id .. " has no manager-owned install")
    return
  end
  if state.status == "broken" and not state.install_id then
    cb(false, { message = id .. ": current.json is unreadable (" .. tostring(state.error) .. "); repair or delete it" })
    return
  end
  local job = {
    id = id,
    job = new_job(id),
    action = "uninstall",
    phase = "checking",
    install_id = state.install_id,
  }
  self.jobs[id] = job
  local finished = false
  local function finish(ok, value)
    if finished then
      return
    end
    finished = true
    self.jobs[id] = nil
    cb(ok, value)
  end
  local details = {
    id = id,
    action = "uninstall",
    package = entry.package,
    version = state.install and state.install.version or nil,
    root = state.dir,
    keep_auth = true,
    install_id = state.install_id,
  }
  local answered = false
  local function answer(accepted)
    if answered then
      return
    end
    answered = true
    if not accepted or job.cancel_requested then
      finish(false, { cancelled = true })
      return
    end
    job.handle = self.connection:request_tracked("install.uninstall", {
      job = job.job,
      root = self:root(),
      agent = id,
      installId = state.install_id,
    }, function(ok, value)
      job.handle = nil
      if not ok then
        finish(false, self:map_error(id, "uninstall", value))
        return
      end
      finish(true, { id = id })
    end)
    if job.cancel_requested and job.handle then
      self.connection:cancel_request(job.handle.id)
    end
  end
  local asked, ask_err = pcall(opts.confirm, details, answer)
  if not asked then
    finish(false, { message = "confirmation failed: " .. tostring(ask_err) })
  end
end

---Cancel the running operation for one agent, if this backend can.
---@param id string
---@return boolean
function Installer:cancel(id)
  local job = self.jobs[id]
  if not job then
    return false
  end
  job.cancel_requested = true
  if job.handle then
    self.connection:cancel_request(job.handle.id)
  end
  return true
end

---Whether an agent is busy in this installer (own job, for the manager's list).
---@param id string|nil
---@return boolean
function Installer:busy(id)
  if id then
    return self.jobs[id] ~= nil
  end
  return next(self.jobs) ~= nil
end

M.Installer = Installer

return M
