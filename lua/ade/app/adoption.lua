-- Adopting a turn that is already running in the service (PROTOCOL.md 13).
--
-- When this Neovim attaches to an instance whose session has a `session/prompt`
-- in flight from a front end that is gone, the service keeps the turn alive and
-- tells the adopter through two ACP extension notifications:
--
--   `_ade/turn_adopted  {sessionId}`                    the turn is ours to watch
--   `_ade/turn_finished {sessionId, stopReason, error?}` the agent answered
--
-- The turn has no local prompt task — nothing here waited for it — so the UI
-- needs its state set by hand: the session must look "running" (spinner, cancel
-- key, queueing behave like a normal turn) and stop looking so when it finishes.
--
-- Everything is defensive: a notification for an unknown session, for a session
-- that is not running, or a duplicate `turn_adopted` is ignored with a debug
-- line, because a service that re-sends after a reconnect must not corrupt the
-- state of a panel that already moved on.
local log = require("ade.log")

local M = {}

---@class AdeTurnAdoption
---@field deps table
local Adoption = {}
Adoption.__index = Adoption

---@param deps {state: fun(): table, refresh_chrome: fun(), schedule_render: fun()|nil,
---  dispatch_queued: fun(session: table)|nil, add_block: fun(text: string, kind: string|nil)|nil,
---  notify: fun(message: string, level: integer|nil)}
---@return AdeTurnAdoption
function M.new(deps)
  return setmetatable({ deps = deps, adopted = {} }, Adoption)
end

---The session a notification refers to, or nil.
---@param session_id string|nil
---@return table|nil
function Adoption:session(session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return nil
  end
  return self.deps.state().sess.all[session_id]
end

---Handle `_ade/turn_adopted`.
---@param payload {session_id: string|nil}
function Adoption:adopted_turn(payload)
  local session_id = payload and payload.session_id
  local session = self:session(session_id)
  if not session then
    log.debug("turn_adopted for unknown session %s", tostring(session_id))
    return
  end
  if self.adopted[session_id] then
    log.debug("turn_adopted repeated for session %s", session_id)
    return
  end
  if session.status ~= "idle" then
    -- A local prompt owns the turn: the service would not have adopted it, so a
    -- notification here is stale. Leaving the state alone is safer than
    -- replacing a real turn's bookkeeping.
    log.debug("turn_adopted while session %s is %s; ignoring", session_id, tostring(session.status))
    return
  end
  -- A turn with no prompt task: `begin_turn` bumps the turn number and sets the
  -- status, and nothing will call `finish_turn` except `turn_finished` below.
  session:begin_turn()
  self.adopted[session_id] = true
  self.deps.refresh_chrome()
  if self.deps.schedule_render then
    self.deps.schedule_render()
  end
end

---Handle `_ade/turn_finished`.
---@param payload {session_id: string|nil, stop_reason: string|nil, error: any}
function Adoption:finished_turn(payload)
  local session_id = payload and payload.session_id
  if not self.adopted[session_id] then
    -- Not one of ours: a normal prompt task settles itself through
    -- `prompt_finished`, and a duplicate notification must not end a new turn.
    log.debug("turn_finished for a session this front end did not adopt: %s", tostring(session_id))
    return
  end
  self.adopted[session_id] = nil
  local session = self:session(session_id)
  if not session then
    -- The session was closed or switched away while the turn ran: there is no
    -- state left to settle.
    log.debug("turn_finished after the adopted session %s went away", session_id)
    return
  end
  if session.status == "idle" then
    log.debug("turn_finished for an idle session %s", session_id)
    return
  end
  local stop_reason = payload.stop_reason
  if payload.error ~= nil then
    stop_reason = "error"
    local message = type(payload.error) == "table" and (payload.error.message or vim.inspect(payload.error))
      or tostring(payload.error)
    if self.deps.add_block then
      self.deps.add_block("The adopted turn failed: " .. message, "error")
    end
    if self.deps.notify then
      pcall(self.deps.notify, "the adopted turn failed: " .. message, vim.log.levels.WARN)
    end
  end
  session:finish_turn(stop_reason or "end_turn")
  self.deps.refresh_chrome()
  if self.deps.schedule_render then
    self.deps.schedule_render()
  end
  -- A turn that ends is exactly when queued messages move on.
  if self.deps.dispatch_queued then
    pcall(self.deps.dispatch_queued, session)
  end
end

---Forget every adoption. Called when the client goes away.
---
---Without this, a session adopted by a client that is being replaced would keep
---a "running" status with no turn behind it — a spinner nobody can stop.
function Adoption:reset(reason)
  local ids = {}
  for session_id in pairs(self.adopted) do
    ids[#ids + 1] = session_id
  end
  self.adopted = {}
  for _, session_id in ipairs(ids) do
    local session = self:session(session_id)
    if session and session.status ~= "idle" then
      -- Settle as interrupted: the agent may still be working, but this front
      -- end can no longer see it.
      session:finish_turn("cancelled")
      log.debug("settled adopted turn for %s (%s)", session_id, tostring(reason or "client gone"))
    end
  end
  if #ids > 0 then
    self.deps.refresh_chrome()
    if self.deps.schedule_render then
      self.deps.schedule_render()
    end
  end
end

---Whether a session is currently adopted (for tests and diagnostics).
---@param session_id string
---@return boolean
function Adoption:is_adopted(session_id)
  return self.adopted[session_id] == true
end

return M
