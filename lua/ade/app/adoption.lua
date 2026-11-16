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
  return setmetatable({ deps = deps, adopted = {}, pending = {}, pending_order = {} }, Adoption)
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
---
---`Runtime:stage` keeps the previously committed object in `sessions[id]` until
---`commit`, so a lookup by id is not enough: during a reload the visible object
---is the *old* one, and an adoption applied to it would be lost when `commit`
---replaces it with the replayed session. `replays` is the authoritative "this
---id is being loaded" mark.
---@param session_id string
---@return boolean
function Adoption:replaying(session_id)
  local runtime = self.deps.state().sess.runtime
  return runtime ~= nil and type(runtime.replays) == "table" and runtime.replays[session_id] ~= nil
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
    -- PROTOCOL.md 13: the notification follows the `session/load` reply on the
    -- same connection, but the reply resolves the load coroutine on a later
    -- tick. The replay has not been committed to the runtime yet, so the
    -- session is not visible; remember the adoption and apply it once
    -- `session_ready` sees the committed session. A reload of an already
    -- committed session is the same case: `sess.all` still holds the old
    -- object, which commit is about to replace.
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
  if not self.pending[session_id] then
    -- An adoption marker on the currently visible object belongs to the object
    -- `commit` is about to replace. Clear it so `adopt` cannot answer
    -- "repeated" for the new object. Remember it instead: if the load fails or
    -- is rolled back the old object stays current and must keep its marker so
    -- `turn_finished` can still settle it.
    self.pending[session_id] = { finished = nil, previous_adopted = self.adopted[session_id] == true }
    self.adopted[session_id] = nil
    self.pending_order[#self.pending_order + 1] = session_id
    -- Oldest first: a load that never commits must not keep the rest forever.
    while #self.pending_order > MAX_PENDING do
      local oldest = table.remove(self.pending_order, 1)
      self.pending[oldest] = nil
    end
    log.debug("turn_adopted for %s before its load committed; deferring", session_id)
  end
end

---Take a pending adoption out of the bookkeeping.
---@param session_id string
---@return table|nil pending
function Adoption:take_pending(session_id)
  local pending = self.pending[session_id]
  if not pending then
    return nil
  end
  self.pending[session_id] = nil
  for index, id in ipairs(self.pending_order) do
    if id == session_id then
      table.remove(self.pending_order, index)
      break
    end
  end
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

---Drop a deferred adoption that will never be applied.
---
---A failed or rolled-back replay has no session to attach it to. Keeping it would
---make a later, successful load of the same id adopt a turn the service never
---announced for that load.
---@param session_id string|nil
---@param restore boolean|nil put back an adoption marker the pending entry cleared
function Adoption:forget_pending(session_id, restore)
  if type(session_id) ~= "string" then
    return
  end
  local pending = self:take_pending(session_id)
  if not pending then
    return
  end
  if restore and pending.previous_adopted then
    -- The load never replaced the session, so the old object is still current
    -- and its adopted turn must keep being tracked until `turn_finished`.
    self.adopted[session_id] = true
  end
  if restore and pending.finished then
    -- The turn ended while the load was in flight and the load then failed or
    -- was cancelled. The old object is still current, so consume the finish here:
    -- leaving a running status whose finish event has already been handled would
    -- be a spinner nothing can stop.
    local session = self:session(session_id)
    if session and session.status ~= "idle" then
      if pending.finished.error ~= nil then
        self:adopted_error(pending.finished.error)
      end
      session:finish_turn(pending.finished.stop_reason or "end_turn")
      self.adopted[session_id] = nil
      self.deps.refresh_chrome()
      if self.deps.schedule_render then
        self.deps.schedule_render()
      end
      if self.deps.dispatch_queued then
        pcall(self.deps.dispatch_queued, session)
      end
      log.debug("settled the adopted turn for %s after its load ended", session_id)
    end
  end
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
  -- The marker belonged to the object this commit replaced (it was already
  -- cleared when the pending entry was made; this is defensive).
  self.adopted[session_id] = nil
  if pending.finished then
    -- The turn ended while the replay was still being committed. There is
    -- nothing left to watch; report an error the way a live finish would.
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
    -- The visible object may be the old one commit is about to replace, and it
    -- may even be adopted (`adopted[id]` true). The finish belongs to the turn
    -- the pending adoption described: record it there so `session_ready` does
    -- not start a spinner for a turn that is already over, and drop the
    -- obsolete marker.
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
  self.pending_order = {}
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
