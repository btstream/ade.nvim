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
local last_sessions = require("ade.storage.last_sessions")

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
    -- PROTOCOL.md 3.2: an entry is `{sessionId, cwd, running, updated_at}`.
    -- `sessionId` is the only id there is; reading a second field name would
    -- hide a stand-in (or a service) that drifted from the spec.
    --
    -- A session without a cwd cannot be matched, and guessing would load
    -- another project's history.
    if type(entry) == "table" and type(entry.sessionId) == "string" and entry.sessionId ~= "" and entry.cwd == cwd then
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
    return tostring(a.sessionId) < tostring(b.sessionId)
  end)
  return matches[1], nil
end

---@class AdeSessionRestore
---@field deps table
local Restore = {}
Restore.__index = Restore

---@param deps {config: fun(): table, cwd: fun(): string|nil,
---  load: fun(session_id: string, opts: table|nil),
---  create: fun(), notify: fun(message: string, level: integer|nil), supported: fun(): boolean}
---@return AdeSessionRestore
function M.new(deps)
  return setmetatable({ deps = deps, reported = false }, Restore)
end

-- ACP agents do not share a standardized "session missing" error code. Do
-- not treat generic server errors, transport failures or auth as deletion.
function M.session_missing(err, id)
  local text = type(err) == "table" and err.message or err
  if type(text) ~= "string" then
    return false
  end
  text = vim.trim(text):lower():gsub("[.!]$", "")
  local subjects = { "session" }
  if type(id) == "string" and id ~= "" then
    id = id:lower()
    for _, value in ipairs({ id, "'" .. id .. "'", '"' .. id .. '"' }) do
      for _, prefix in ipairs({ "session ", "session id ", "session with id " }) do
        subjects[#subjects + 1] = prefix .. value
      end
      for _, prefix in ipairs({ "unknown session ", "unknown session: ", "no such session ", "no such session: " }) do
        if text == prefix .. value then
          return true
        end
      end
    end
  end
  if text == "unknown session" or text == "no such session" then
    return true
  end
  for _, subject in ipairs(subjects) do
    if text == subject .. " not found" or text == subject .. " does not exist" then
      return true
    end
  end
  return false
end

function Restore:after_restart(session)
  local cfg = self.deps.config()
  if not (cfg.service and cfg.service.restore_on_restart) then
    return false
  end
  local cwd = session and session.cwd or self.deps.cwd()
  if type(cwd) ~= "string" or cwd == "" or type(cfg.agent) ~= "string" then
    return false
  end
  local id = session and session.id or last_sessions.get(cfg.agent, cwd)
  if not id then
    return false
  end
  if not self.deps.supported(true) then
    self:report("the agent cannot load or resume the last session", vim.log.levels.WARN)
    return false
  end
  self.deps.load(id, {
    kind = "restore",
    cold_restore = true,
    cwd = cwd,
    on_failed = function(message, err)
      if M.session_missing(err or message, id) then
        last_sessions.forget(cfg.agent, cwd, id)
        self:report("last session " .. id .. " no longer exists", vim.log.levels.WARN)
        return true -- request a new session, but only while this intent is current
      end
      self.deps.notify(
        "could not reopen the last session: " .. message .. "; open ADE again to retry",
        vim.log.levels.WARN
      )
    end,
    on_restored = function()
      self.deps.notify("restored session " .. id .. " after service restart", vim.log.levels.INFO)
    end,
  })
  return true
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
  if type(attach) == "table" and attach.created == true then
    return self:after_restart()
  end
  if service.restore == false then
    return false
  end
  if type(attach) ~= "table" or attach.created ~= false then
    -- Direct connections never participate in service restore.
    return false
  end
  local session, reason = M.pick(attach.sessions, self.deps.cwd())
  if not session then
    -- Nothing to reopen is ordinary (a first visit to this directory), but the
    -- user should still see why the conversation they expected is not there.
    self:report(reason, vim.log.levels.INFO)
    return false
  end
  if not self.deps.supported() then
    self:report("the agent cannot load sessions, so the previous one was not reopened", vim.log.levels.WARN)
    return false
  end
  local id = session.sessionId
  log.info("restoring session %s for %s", tostring(id), tostring(session.cwd))
  -- Success and failure are both reported: without the failure path the user
  -- sees only "Session started" and cannot tell a fallback from a restore.
  self.deps.load(id, {
    kind = "restore",
    on_failed = function(err)
      self:report(
        string.format("session %s could not be restored: %s", tostring(id), tostring(err)),
        vim.log.levels.WARN
      )
    end,
    on_restored = function()
      if self.restored_notified then
        return
      end
      self.restored_notified = true
      self.deps.notify("restored session " .. tostring(id), vim.log.levels.INFO)
    end,
  })
  return true
end

---Tell the user why the restore did not happen.
---
---Once per front end: a reconnect retries, and repeating the same message on
---every attempt would be noise.
---@param reason string|nil
---@param level integer|nil
function Restore:report(reason, level)
  if self.reported or not reason then
    return
  end
  self.reported = true
  log.info("not restoring a session: %s", reason)
  self.deps.notify(reason .. "; starting a new session", level or vim.log.levels.INFO)
end

---Allow the messages again (a new client, a new chance).
function Restore:reset()
  self.reported = false
  self.restored_notified = false
end

return M
