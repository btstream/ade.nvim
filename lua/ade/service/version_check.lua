-- Version reconciliation between this plugin and a running service.
--
-- The plugin and `nvim_ade_server` ship from the same repository but update at
-- different times, so the two cases are:
--
--   * same version                               -> nothing to do;
--   * different version, same `api_version`      -> the wire protocol still
--     matches. Restart the service onto the new binary, but only when it is
--     **idle** (see below) — killing it mid-turn would lose an agent's work;
--   * different `api_version`                    -> the handshake failed with
--     `-32002`. Retry once with the version the service reports, then apply the
--     same idle rule. A service old enough to have no `agent.list` (api 1) is
--     idle by definition.
--
-- "Idle" means: no instance has `turns_running > 0` or `pending_requests > 0`,
-- and this connection is the only one attached (`attached <= 1`). A busy service
-- is used as-is, with a single warning per Neovim, and each later `ensure()`
-- checks again — that is how it eventually restarts without interrupting work.
local log = require("ade.log")
local Version = require("ade.service.version")

local M = {}

---Parse `server_version` into comparable parts.
---
---Only used to decide "same or not"; a version string this plugin cannot parse
---is treated as different, which reuses the safe idle-gated path.
---@param version any
---@return string|nil
function M.normalize(version)
  if type(version) ~= "string" or version == "" then
    return nil
  end
  return version
end

---Whether the running service is on the version this plugin expects.
---@param server_version any
---@return boolean
function M.matches(server_version)
  return M.normalize(server_version) == Version.VERSION
end

---Whether an `agent.list` reply describes an idle service.
---
---`instances` nil (a service too old to answer) counts as idle: it cannot be
---running a turn this plugin could adopt.
---@param instances table|nil
---@return boolean
function M.is_idle(instances)
  if instances == nil then
    return true
  end
  for _, instance in ipairs(instances) do
    if (tonumber(instance.turns_running) or 0) > 0 then
      return false
    end
    if (tonumber(instance.pending_requests) or 0) > 0 then
      return false
    end
    if (tonumber(instance.attached) or 0) > 1 then
      -- Another Neovim is attached: it may be waiting on a permission prompt
      -- this restart would destroy.
      return false
    end
  end
  return true
end

---@class AdeVersionCheck
---@field deps table
local Check = {}
Check.__index = Check

---@param deps {config: fun(): table,
---  request_sync: fun(method: string, params: any, timeout: integer|nil): boolean, any,
---  restart: fun(cb: fun(ok: boolean, err: string|nil)),
---  notify: fun(message: string, level: integer|nil)}
---@return AdeVersionCheck
function M.new(deps)
  return setmetatable({ deps = deps, warned = false }, Check)
end

---Handle a successful handshake. Returns whether the connection may be used
---as-is.
---
---Synchronous on purpose: `ensure()` is a synchronous API (callers wait for its
---callback), and the idle probe is one `agent.list` with a bounded wait.
---@param info table handshake result: `{server_version, api_version}`
---@return boolean usable
function Check:check(info)
  info = type(info) == "table" and info or {}
  if M.matches(info.server_version) then
    return true
  end
  local ok, value = self.deps.request_sync("agent.list", {}, 2000)
  local instances = ok and type(value) == "table" and value.instances or nil
  if not ok then
    -- The service could not answer. "Method not found" means a service old
    -- enough to predate `agent.list` (api 1): idle by definition. A timeout
    -- means it is busy or wedged, and restarting it could destroy work, so it is
    -- left alone with one explanation.
    local code = type(value) == "table" and value.code or nil
    if code == -32601 then
      instances = nil
    else
      if not self.warned then
        self.warned = true
        self.deps.notify(
          "the running service ("
            .. tostring(info.server_version)
            .. ") could not be checked for idleness; run :Ade service stop to restart it on "
            .. Version.VERSION,
          vim.log.levels.WARN
        )
      end
      return true
    end
  end
  if not M.is_idle(instances) then
    if not self.warned then
      self.warned = true
      self.deps.notify(
        string.format(
          "the service has an update (%s -> %s); it restarts automatically once the current task finishes",
          tostring(info.server_version),
          Version.VERSION
        ),
        vim.log.levels.WARN
      )
    end
    return true
  end
  local restarted, err = false, nil
  self.deps.restart(function(a, b)
    restarted, err = a, b
  end)
  if restarted then
    -- The agents are the service's children: shutting it down stops them too,
    -- and only each agent's own `session/load` brings a session back. Saying so
    -- is the difference between a surprise and an expected restart.
    local agents = type(instances) == "table" and #instances or 0
    self.deps.notify(
      string.format(
        "restarting nvim_ade_server (%s -> %s); %d idle agent(s) will restart with it",
        tostring(info.server_version),
        Version.VERSION,
        agents
      ),
      vim.log.levels.INFO
    )
    return true
  end
  if not self.warned then
    self.warned = true
    self.deps.notify(
      string.format(
        "could not restart the service onto %s (%s); run :Ade service stop and reconnect",
        Version.VERSION,
        tostring(err)
      ),
      vim.log.levels.WARN
    )
  end
  return true
end

---Forget the one-shot warning. A new client means a new chance to report.
function Check:reset()
  self.warned = false
end

return M
