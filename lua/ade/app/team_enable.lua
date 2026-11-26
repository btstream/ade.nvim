-- Turning one session's team tools on (PROTOCOL.md 20.5).
--
-- He lives in his own module because two owners need exactly these rules:
--
--  * `:Ade team on` and the tree (`ade.app.team_commands`, `ui.team`), which
--    must explain the three possible answers instead of assuming success;
--  * the start flow (`ade.app.team_start`), which must not continue into a
--    task prompt when the tools never arrived.
--
-- A plain `require` between `ade.app.team` and `ade.app.team_start` would be a
-- cycle (the flow reads the team module through the controller), so the rules
-- live here and both call in.
--
-- The module only needs two methods of a team object — `set_session_teams` (the
-- raw write) and `reload_session` (the front-end load) — so it also works with
-- a stand-in in tests.
local M = {}

---What one `session.teams {enabled: true}` answer means.
---
---Three outcomes matter, and only one of them means "the tools are usable":
---
---  * `reload`: the service marked the session one-shot forward; the front end
---    still has to run its own load before anything is injected;
---  * `on`: `enabled: true` **and** `injected: true` — a held reply that ended
---    on the connection, or a session that already had its tools;
---  * `off` / `uninjected`: the switch is not on, or it is on but no MCP
---    process ever injected the tools (the held wait was cancelled: the switch
---    was turned off from another window, the agent exited, the session
---    closed). Both are a failed enable, never success.
---@param value any
---@return "reload"|"on"|"off"|"uninjected"
function M.outcome(value)
  if type(value) ~= "table" then
    return "uninjected"
  end
  if value.reload == true then
    return "reload"
  end
  if value.enabled ~= true then
    return "off"
  end
  if value.injected == true then
    return "on"
  end
  return "uninjected"
end

---The error value for a failed enable, suited to `report_error`/`notify`.
---@param value any
---@param outcome string|nil
---@return table
function M.error(value, outcome)
  outcome = outcome or M.outcome(value)
  local message
  if outcome == "off" then
    message = "teams were turned off for this chat; run :Ade team on to turn them back on"
  elseif outcome == "wrote_off" then
    message = "teams were turned off while the session was reloading; run :Ade team on again"
  else
    message = "the agent did not inject the team tools (its MCP server never connected)"
  end
  return {
    code = type(value) == "table" and value.code or nil,
    message = message,
    reason = outcome,
    data = { reason = outcome },
  }
end

---The notice shown while a `session.teams` write is still unanswered.
---
---The service holds a fresh session's enable for up to ten seconds while it
---waits for the agent's MCP process, so silence is not an option.
M.WAIT_TEXT = "正在等待 agent 加载 team 工具…"

---How long an enable may be silent before the in-progress notice appears.
local HINT_MS = 150

---Per-team enables in flight: `team table -> {session_key -> entry}`.
---
---Keyed by the team object rather than kept on it, so a stand-in team (the
---start flow's tests) gets the same coalescing without implementing it.
local states = setmetatable({}, { __mode = "k" })

---@param instance string|nil
---@param session_id string|nil
---@return string|nil
function M.key(instance, session_id)
  if not instance or not session_id then
    return nil
  end
  return tostring(instance) .. "\0" .. tostring(session_id)
end

---@param team table
---@return table
local function state_of(team)
  local state = states[team]
  if not state then
    state = {}
    states[team] = state
  end
  return state
end

---Settle every waiter of one pending enable and clear its slot.
---@param team table
---@param key string|nil
---@param ok boolean
---@param value any
function M._settle(team, key, ok, value)
  local state = state_of(team)
  local entry = key and state[key] or nil
  if not entry then
    return
  end
  if state[key] == entry then
    state[key] = nil
  end
  -- Release the injection wait a successful load may have started.
  if entry.stop then
    pcall(entry.stop)
    entry.stop = nil
  end
  if entry.hint then
    pcall(function()
      entry.hint:stop()
      entry.hint:close()
    end)
    entry.hint = nil
  end
  for _, waiter in ipairs(entry.waiters or {}) do
    pcall(waiter, ok, value)
  end
end

---Whether one enable of `(instance, sessionId)` is in flight right now.
---@param team table
---@param instance string|nil
---@param session_id string|nil
---@return boolean
function M.pending(team, instance, session_id)
  local state = state_of(team)
  return state[M.key(instance, session_id) or ""] ~= nil
end

---Mark a pending enable as overtaken by a write of the opposite switch. The
---enable still waits for the load it started to end, but that load's success
---must not be reported as "teams are on".
---@param team table
---@param instance string|nil
---@param session_id string|nil
---@param reason string
function M.supersede(team, instance, session_id, reason)
  local state = state_of(team)
  local entry = state[M.key(instance, session_id) or ""]
  if entry then
    entry.superseded = entry.superseded or reason
  end
end

---Clear a supersede mark (the opposite write failed, so the enable still owns
---the outcome).
---@param team table
---@param instance string|nil
---@param session_id string|nil
function M.resume(team, instance, session_id)
  local state = state_of(team)
  local entry = state[M.key(instance, session_id) or ""]
  if entry then
    entry.superseded = nil
  end
end

---Settle a pending enable as cancelled (the switch went off, the pair is gone).
---@param team table
---@param instance string|nil
---@param session_id string|nil
---@param reason any
function M.cancel(team, instance, session_id, reason)
  M._settle(team, M.key(instance, session_id), false, reason)
end

---Settle every pending enable of one team (a lost connection, a reset).
---@param team table
---@param reason any
function M.cancel_all(team, reason)
  local state = states[team]
  if not state then
    return
  end
  local keys = {}
  for key in pairs(state) do
    keys[#keys + 1] = key
  end
  for _, key in ipairs(keys) do
    M._settle(team, key, false, reason)
  end
end

---Turn a session's tools on, coalescing the in-progress enable→reload.
---
---One `(instance, sessionId)` has at most one enable in flight, and its result
---(the reply, the load it asked for, and the outcome) is delivered to every
---caller waiting on it. `cb(ok, value)`:
---
---  * `ok, {enabled: true, injected: true, ...}` — the tools are in place;
---  * `false, error` for a failed request, a cancelled enable (`off`) or a failed
---    load. `M.error` explains the reason.
---
---A repeated request while one is in flight reports "in progress" instead of
---sending a second write: the service holds each enable up to ten seconds, and
---two held replies could each ask for a reload. Callers that must still know
---how the shared attempt ended (a start flow) join its waiters; a plain
---`:Ade team on` passes `join = false` and only says it is in progress.
---@param team table
---@param instance string
---@param session_id string
---@param cb fun(ok: boolean, value: any)|nil
---@param opts {notify: fun(message: string, level: integer|nil)|nil, join: boolean|nil,
---  wait_ms: integer|nil}|nil
function M.run(team, instance, session_id, cb, opts)
  cb = cb or function() end
  opts = opts or {}
  local notify = opts.notify
  local key = M.key(instance, session_id)
  if not key then
    cb(false, "no session to enable")
    return
  end
  local state = state_of(team)
  local pending = state[key]
  if pending then
    if notify then
      pcall(notify, M.WAIT_TEXT, vim.log.levels.INFO)
    end
    if opts.join ~= false then
      pending.waiters = pending.waiters or {}
      pending.waiters[#pending.waiters + 1] = cb
    end
    return
  end
  local entry = { waiters = { cb } }
  state[key] = entry
  if notify then
    -- The service may hold the reply for up to ten seconds; say so instead of
    -- looking hung. `defer_fn` keeps a fast reply from flashing the notice.
    entry.hint = vim.defer_fn(function()
      entry.hint = nil
      if state_of(team)[key] == entry then
        pcall(notify, M.WAIT_TEXT, vim.log.levels.INFO)
      end
    end, HINT_MS)
  end
  local function settle(ok, value)
    if state_of(team)[key] ~= entry then
      return
    end
    entry.settled = true
    M._settle(team, key, ok, value)
  end
  ---Finish an enable whose write asked for a reload.
  ---
  ---The load only restarts the transcript: the agent's MCP process may connect
  ---after it (or never). Two facts must both hold before this reports success:
  ---the ACP load really succeeded, and the newest switch state says `enabled`
  ---and `injected`. The listener is registered **before** the load starts,
  ---because the service may publish `session.teams_changed` before the load
  ---reply reaches this callback — but such an early notification is only
  ---recorded, never settlement, since the load may still fail or be cancelled.
  local latest = nil
  ---The newest state the cache accepted for this pair.
  local function state_now()
    local cached = team.session_teams and team:session_teams(instance, session_id) or nil
    return cached or latest
  end
  local function terminal(state)
    return state and (state.injected == true or state.enabled == false)
  end
  local load_done = false
  local settle_reload
  local function on_state(state)
    if not state then
      return
    end
    latest = state
    if load_done and terminal(state) then
      settle_reload(state)
    end
  end
  local unsubscribe
  if type(team.watch_session_state) == "function" then
    unsubscribe = team:watch_session_state(instance, session_id, on_state)
  end
  local timer
  local released = false
  local function release_wait()
    released = true
    if timer then
      pcall(function()
        timer:stop()
        timer:close()
      end)
      timer = nil
    end
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
  end
  -- Settling or cancelling the entry from outside must also drop the listener.
  entry.stop = release_wait
  settle_reload = function(state)
    if state_of(team)[key] ~= entry then
      return
    end
    release_wait()
    if entry.superseded then
      settle(false, M.error({}, "wrote_off"))
      return
    end
    if state.enabled == false then
      settle(false, M.error(state, "off"))
      return
    end
    if state.injected == true then
      settle(true, state)
      return
    end
    settle(false, M.error(state, "uninjected"))
  end
  local function after_load()
    if state_of(team)[key] ~= entry then
      release_wait()
      return
    end
    -- From here on the load is known good: an early notification may settle.
    load_done = true
    if entry.superseded then
      release_wait()
      settle(false, M.error({}, "wrote_off"))
      return
    end
    local now = state_now()
    if terminal(now) then
      settle_reload(now)
      return
    end
    if type(team.query_session_teams) ~= "function" then
      -- No way to ask: do not claim the tools are there.
      settle_reload(now or { enabled = true, injected = false })
      return
    end
    -- Ask the service for the real switch once; the cache may still hold the
    -- pre-load answer if the notification raced the reply.
    team:query_session_teams(instance, session_id, nil, function(ok, value)
      if state_of(team)[key] ~= entry then
        return
      end
      if not ok or type(value) ~= "table" then
        -- Reading the switch is not proof the tools arrived: say so at once.
        release_wait()
        settle(false, {
          message = "cannot read the session's team tools: "
            .. tostring(type(value) == "table" and (value.message or value.code) or value),
          stage = "reload",
        })
        return
      end
      -- Decide from the state the cache accepted: a newer notification must
      -- win over this reply, which only tells us whether the service is still
      -- waiting for the agent's MCP process (`pending`).
      local accepted = state_now()
      if accepted and terminal(accepted) then
        settle_reload(accepted)
        return
      end
      if value.pending == true then
        -- The service still waits for the agent's MCP process: wait for
        -- `session.teams_changed`, bounded like the service's own hold.
        timer = vim.defer_fn(function()
          timer = nil
          if released or state_of(team)[key] ~= entry then
            return
          end
          settle_reload(state_now() or { enabled = true, injected = false })
        end, opts.wait_ms or 10000)
        return
      end
      -- `pending: false` with nothing injected: no handshake is coming.
      release_wait()
      settle(false, M.error(accepted or value, "uninjected"))
    end, { source = "session" })
  end
  local function on_answer(ok, value)
    if state_of(team)[key] ~= entry then
      return
    end
    if not ok then
      release_wait()
      settle(false, value)
      return
    end
    local outcome = M.outcome(value)
    if outcome == "reload" then
      -- A failed load leaves the session as it was: report it, never "teams are
      -- on". A successful one still has to prove the tools were injected.
      team:reload_session(instance, session_id, function(reloaded, err)
        if state_of(team)[key] ~= entry then
          release_wait()
          return
        end
        if not reloaded then
          release_wait()
          settle(false, {
            message = "cannot reload the session's team tools: " .. tostring(err and (err.message or err) or "?"),
            stage = "reload",
          })
          return
        end
        after_load()
      end)
      return
    end
    if outcome == "on" then
      release_wait()
      settle(true, value)
      return
    end
    release_wait()
    settle(false, M.error(value, outcome))
  end
  -- The raw write. `set_session_teams` is a plain enable here (no `close`), so
  -- a real Team will not cancel this pending entry; a stand-in team only has
  -- this method and it is its raw write.
  team:set_session_teams(instance, session_id, true, false, on_answer)
end

---The text for a failed enable: a failed load keeps its own sentence, every
---other failure is the caller's prefix plus the reply's reason.
---@param value any
---@param report fun(value: any): string|nil the caller's error formatter
---@param prefix string|nil e.g. "cannot turn teams on: "
---@return string
function M.error_text(value, report, prefix)
  if type(value) == "table" and value.stage == "reload" then
    return tostring(value.message)
  end
  local reason
  if report then
    local ok, text = pcall(report, value)
    if ok and type(text) == "string" and text ~= "" then
      reason = text
    end
  end
  reason = reason or tostring(type(value) == "table" and (value.message or value.code) or value)
  return (prefix or "") .. reason
end

return M
