-- Reopening the session the service was already holding (PROTOCOL.md 3.2).
--
-- When this Neovim attaches to an instance it did not create (`created = false`)
-- and the service has an event log, `agent.attach` reports the sessions it
-- tracks. The agent may still be working, and the user closed the editor on a
-- real conversation — starting an empty session would throw that away.
--
-- The rule is the narrow one from the task: same `cwd` as this front end, most
-- recently updated first. Everything else (a different project, no matching
-- session, an agent that cannot load, a load that fails) falls back to a normal
-- new session, with a single message explaining why.
--
-- Loading itself is `Sessions:load`, unchanged: replay locking, the replay
-- marker and the "needs load" bookkeeping all stay in one place.
local log = require("ade.log")

local M = {}

---Pick the session to restore.
---
---@param sessions table[]|nil `agent.attach`'s `sessions` field
---@param cwd string|nil this front end's working directory
---@return table|nil session the best candidate
---@return string|nil reason why there is none
function M.pick(sessions, cwd)
  if type(sessions) ~= "table" or #sessions == 0 then
    return nil, "the service has no sessions to restore"
  end
  if type(cwd) ~= "string" or cwd == "" then
    return nil, "no working directory to match a session against"
  end
  local matches = {}
  for _, entry in ipairs(sessions) do
    -- The service reports `cwd` and `updated_at`; a session without a cwd
    -- cannot be matched, and guessing would load another project's history.
    if type(entry) == "table" and entry.id and entry.cwd == cwd then
      matches[#matches + 1] = entry
    end
  end
  if #matches == 0 then
    return nil, "the service has no session for " .. cwd
  end
  table.sort(matches, function(a, b)
    local ua = tonumber(a.updated_at) or 0
    local ub = tonumber(b.updated_at) or 0
    if ua ~= ub then
      return ua > ub
    end
    -- Stable tie-break so two sessions updated in the same millisecond do not
    -- depend on table order.
    return tostring(a.id) < tostring(b.id)
  end)
  return matches[1], nil
end

---@class AdeSessionRestore
---@field deps table
local Restore = {}
Restore.__index = Restore

---@param deps {config: fun(): table, cwd: fun(): string|nil, load: fun(session_id: string),
---  create: fun(), notify: fun(message: string, level: integer|nil), supported: fun(): boolean}
---@return AdeSessionRestore
function M.new(deps)
  return setmetatable({ deps = deps, reported = false }, Restore)
end

---Reopen a session after a ready event, or start a new one.
---
---`attach` is the transport's attach result (`created`, `sessions`), or nil for
---the direct backend.
---@param attach table|nil
---@return boolean restored
function Restore:after_ready(attach)
  local cfg = self.deps.config() or {}
  local service = type(cfg.service) == "table" and cfg.service or {}
  if service.restore == false then
    return false
  end
  if type(attach) ~= "table" or attach.created ~= false then
    -- A brand-new instance has nothing to restore: whatever sessions it reports
    -- (none) belong to nobody.
    return false
  end
  local session, reason = M.pick(attach.sessions, self.deps.cwd())
  if not session then
    self:report(reason)
    return false
  end
  if not self.deps.supported() then
    self:report("the agent cannot load sessions, so the previous one was not reopened")
    return false
  end
  log.info("restoring session %s for %s", tostring(session.id), tostring(session.cwd))
  self.deps.load(session.id)
  return true
end

---Tell the user once why the restore did not happen.
---
---Once per front end: a reconnect retries, and repeating the same message on
---every attempt would be noise.
---@param reason string|nil
function Restore:report(reason)
  if self.reported or not reason then
    return
  end
  self.reported = true
  log.info("not restoring a session: %s", reason)
  self.deps.notify(reason .. "; starting a new session", vim.log.levels.INFO)
end

---Allow the message again (a new client, a new chance).
function Restore:reset()
  self.reported = false
end

return M
