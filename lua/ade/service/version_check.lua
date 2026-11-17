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

---Whether the handshake advertised service-owned teams.
---@param info table
---@return boolean
local function advertises_teams(info)
  for _, feature in ipairs(type(info.features) == "table" and info.features or {}) do
    if feature == "teams" then
      return true
    end
  end
  return false
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
---The idle probe is synchronous (`agent.list` with a bounded wait), but the
---restart itself is not: `shutdown` and the following `ensure` both reply on a
---socket callback. Reading the result of `restart()` immediately after calling
---it therefore always saw "not restarted" and reported a failure for a restart
---that went on to succeed. So the caller may pass `done`; then a restart reports
---back through it.
---
---@param info table handshake result: `{server_version, api_version}`
---@param done fun()|nil called once the reconciliation finished (possibly later)
---@return boolean|string usable `true`, `false`, or `"pending"` when `done` is
---  still to come
function Check:check(info, done)
  info = type(info) == "table" and info or {}
  if M.matches(info.server_version) then
    return true
  end
  -- PROTOCOL.md 18.14/18.16: a service with any team (except a suspended one)
  -- is busy whatever the instances say, so ask before agent.list and treat a
  -- failed/timeout probe as busy. -32601 means the service has no teams.
  if advertises_teams(info) then
    local teams_ok, teams_value = self.deps.request_sync("team.list", {}, 5000)
    local busy = false
    if not teams_ok then
      local code = type(teams_value) == "table" and teams_value.code or nil
      busy = code ~= -32601
    elseif type(teams_value) ~= "table" or type(teams_value.teams) ~= "table" then
      busy = true
    else
      for _, team in ipairs(teams_value.teams) do
        if type(team) ~= "table" or team.state ~= "suspended" then
          busy = true
          break
        end
      end
    end
    if busy then
      if not self.warned then
        self.warned = true
        self.deps.notify(
          string.format(
            "the service has an update (%s -> %s); it restarts after the team ends, on the next connection or with :Ade service stop",
            tostring(info.server_version),
            Version.VERSION
          ),
          vim.log.levels.WARN
        )
      end
      return true
    end
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
          "the service has an update (%s -> %s); it restarts after the current task ends, on the next connection or with :Ade service stop",
          tostring(info.server_version),
          Version.VERSION
        ),
        vim.log.levels.WARN
      )
    end
    return true
  end
  -- The agents are the service's children: shutting it down stops them too,
  -- and only each agent's own `session/load` brings a session back. Saying so
  -- is the difference between a surprise and an expected restart — and it is
  -- said *before* the restart, so it does not depend on a reply.
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
  local settled, restarted, err = false, false, nil
  self.deps.restart(function(a, b)
    settled, restarted, err = true, a == true, b
    if not restarted then
      self:report_failed_restart(err)
    end
    if done then
      pcall(done)
    end
  end)
  if settled then
    return true
  end
  if done then
    -- The restart's callback owns the outcome; `ensure` must not finish early
    -- and must not report anything yet.
    return "pending"
  end
  -- No callback and no synchronous answer: the restart is in flight. The
  -- connection is still usable, and a failure is reported when it happens.
  return true
end

---Report a restart that did not happen, once per front end.
---@param err any
function Check:report_failed_restart(err)
  if self.warned then
    return
  end
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

---Forget the one-shot warning. A new client means a new chance to report.
function Check:reset()
  self.warned = false
end

return M
