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

---How many load replies may be waiting for their session to be committed.
---A `_ade/turn_adopted` is only ever sent for a session this connection just
---loaded, so the set stays tiny; the cap is a guard against a service that
---misbehaves, not an expected size.
local MAX_PENDING = 16

---@class AdeTurnAdoption
---@field deps table
local Adoption = {}
Adoption.__index = Adoption

---@param deps {state: fun(): table, refresh_chrome: fun(), schedule_render: fun()|nil,
---  dispatch_queued: fun(session: table)|nil, add_block: fun(text: string, kind: string|nil)|nil,
---  notify: fun(message: string, level: integer|nil)}
---@return AdeTurnAdoption
function M.new(deps)
  return setmetatable({ deps = deps, adopted = {}, pending = {} }, Adoption)
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

---Whether a replay for this id is in flight.
---@param session_id string
---@return boolean
function Adoption:replaying(session_id)
  local runtime = self.deps.state().sess.runtime
  return runtime ~= nil and type(runtime.is_staged) == "function" and runtime:is_staged(session_id) == true
end

---Handle `_ade/turn_adopted`.
---@param payload {session_id: string|nil}
function Adoption:adopted_turn(payload)
  local session_id = payload and payload.session_id
  if type(session_id) ~= "string" or session_id == "" then
    log.debug("turn_adopted without a session id")
    return
  end
  if self:replaying(session_id) then
    -- PROTOCOL.md 13: the notification can arrive before the load reply resolves
    -- the coroutine that commits the replay. A reload is the same case: the
    -- visible object is the old one, which commit is about to replace.
    self:pending_adoption(session_id)
    return
  end
  local session = self:session(session_id)
  if not session then
    self:pending_adoption(session_id)
    return
  end
  self:adopt(session_id, session)
end

---Remember a `_ade/turn_adopted` that arrived before its session was committed.
---@param session_id string
function Adoption:pending_adoption(session_id)
  if self.pending[session_id] then
    return
  end
  local count = 0
  for _ in pairs(self.pending) do
    count = count + 1
  end
  if count >= MAX_PENDING then
    -- Misbehaving service: drop the whole set instead of growing without bound.
    log.warn("dropping %d deferred turn adoptions; too many loads never committed", count)
    self.pending = {}
  end
  -- Clear the marker on the object commit will replace (`adopt` must not call it
  -- "repeated"), but remember the object: `forget_pending` restores the marker
  -- if the load fails and that object is still current.
  self.pending[session_id] = {
    finished = nil,
    previous_session = self.adopted[session_id] and self:session(session_id) or nil,
  }
  self.adopted[session_id] = nil
  log.debug("turn_adopted for %s before its load committed; deferring", session_id)
end

---Take a pending adoption out of the bookkeeping.
---@param session_id string
---@return table|nil pending
function Adoption:take_pending(session_id)
  local pending = self.pending[session_id]
  self.pending[session_id] = nil
  return pending
end

---Apply an adoption to a session that is idle.
---@param session_id string
---@param session table
function Adoption:adopt(session_id, session)
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

---Drop a deferred adoption that will never be applied, restoring the old
---object's marker when the replay never replaced it.
---@param session_id string|nil
function Adoption:forget_pending(session_id)
  if type(session_id) ~= "string" then
    return
  end
  local pending = self:take_pending(session_id)
  if not pending then
    return
  end
  local session = self:session(session_id)
  if not session or session ~= pending.previous_session then
    return
  end
  if pending.finished then
    -- The finish arrived while the load was in flight and the load then failed:
    -- consume it now, or the old object keeps running with no event left.
    if session.status ~= "idle" then
      if pending.finished.error ~= nil then
        self:adopted_error(pending.finished.error)
      end
      session:finish_turn(pending.finished.stop_reason or "end_turn")
      self.deps.refresh_chrome()
      if self.deps.schedule_render then
        self.deps.schedule_render()
      end
      if self.deps.dispatch_queued then
        pcall(self.deps.dispatch_queued, session)
      end
      log.debug("settled the adopted turn for %s after its load ended", session_id)
    end
    self.adopted[session_id] = nil
    return
  end
  self.adopted[session_id] = true
end

---Report an adopted turn that ended with an error, exactly like a live finish.
---@param error_ any
function Adoption:adopted_error(error_)
  local message = type(error_) == "table" and (error_.message or vim.inspect(error_)) or tostring(error_)
  if self.deps.add_block then
    self.deps.add_block("The adopted turn failed: " .. message, "error")
  end
  if self.deps.notify then
    pcall(self.deps.notify, "the adopted turn failed: " .. message, vim.log.levels.WARN)
  end
end

---A replay finished committing a session: apply an adoption that was waiting.
---@param session table|nil
function Adoption:session_ready(session)
  local session_id = session and session.id
  if type(session_id) ~= "string" then
    return
  end
  local pending = self:take_pending(session_id)
  if not pending then
    return
  end
  -- Defensive: `pending_adoption` already cleared it.
  self.adopted[session_id] = nil
  if pending.finished then
    -- The turn ended before commit: report an error as a live finish would.
    if pending.finished.error ~= nil then
      self:adopted_error(pending.finished.error)
    end
    log.debug("turn for %s finished before its load committed", session_id)
    return
  end
  self:adopt(session_id, session)
end

---Handle `_ade/turn_finished`.
---@param payload {session_id: string|nil, stop_reason: string|nil, error: any}
function Adoption:finished_turn(payload)
  local session_id = payload and payload.session_id
  local pending = self.pending[session_id]
  if pending then
    -- A finish that arrives before commit belongs to the turn the pending
    -- adoption described (the visible object may still be the old, adopted one).
    if not pending.finished then
      pending.finished = payload
    end
    self.adopted[session_id] = nil
    log.debug("turn_finished for %s before its load committed", tostring(session_id))
    return
  end
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
    self:adopted_error(payload.error)
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
  self.pending = {}
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
