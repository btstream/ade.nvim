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
---@param opts {notify: fun(message: string, level: integer|nil)|nil, join: boolean|nil}|nil
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
    M._settle(team, key, ok, value)
  end
  local function on_answer(ok, value)
    if state_of(team)[key] ~= entry then
      return
    end
    if not ok then
      settle(false, value)
      return
    end
    local outcome = M.outcome(value)
    if outcome == "reload" then
      -- A forwarded load that answered successfully restarts the session's log
      -- and injects the tools, so a successful load is the terminal success of
      -- this enable. A failed load leaves the session as it was: report it as
      -- a failure, never as "teams are on".
      team:reload_session(instance, session_id, function(reloaded, err)
        if not reloaded then
          settle(false, {
            message = "cannot reload the session's team tools: " .. tostring(err and (err.message or err) or "?"),
            stage = "reload",
          })
          return
        end
        settle(true, { enabled = true, injected = true, reloaded = true })
      end)
      return
    end
    if outcome == "on" then
      settle(true, value)
      return
    end
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
