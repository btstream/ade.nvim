-- Automatic reconnection after an unexpected service-connection loss.
--
-- The shared connection survives a drop (S1a-F), but nothing retried: the user
-- had to run `:Ade reconnect`. This module owns the retry loop, and only one:
-- several panels and several `__disconnected` notifications must not produce
-- competing loops, because each would start its own service.
--
-- Backoff is 0.5s, 1s, 2s, 4s, 8s, then 15s for every remaining attempt, up to
-- `service.reconnect_attempts` (default 8, 0 disables). Each attempt calls
-- `ensure()` — which restarts the service when needed — and hands success to the
-- existing `Connection:reconnect()` flow, so a reconnect is the same code path as
-- the manual command.
--
-- A service that reconnects and immediately dies again must not reset the
-- ladder: that would retry at 0.5s forever, starting a fresh service each time
-- and never telling the user anything is wrong. So a success is only a *new
-- incident* once the connection has been stable for `STABLE_MS`; before that the
-- attempt count and backoff position carry on, and the loop eventually gives up
-- with an explicit message.
--
-- The timers and the injected clock are fields so the tests can drive the whole
-- schedule without sleeping.
local log = require("ade.log")

local M = {}

---How long a connection must stay up before the next loss counts as a new
---incident rather than a continuation of the crash loop.
local STABLE_MS = 60000

---The delay before attempt `index` (1-based), in milliseconds.
---@param index integer
---@return integer
function M.delay_for(index)
  local ladder = { 500, 1000, 2000, 4000, 8000, 15000 }
  return ladder[index] or 15000
end

---@class AdeReconnector
---@field deps table
---@field attempt integer
---@field timer table|nil
---@field running boolean
local Reconnector = {}
Reconnector.__index = Reconnector

---@param deps {config: fun(): table, ensure: fun(cb: fun(ok: boolean, err: string|nil)),
---  reconnect: fun(), notify: fun(message: string, level: integer|nil),
---  set_status: fun(text: string|nil)|nil, now?: fun(): integer,
---  defer?: fun(fn: fun(), delay_ms: integer): any, cancel_defer?: fun(handle: any)}
---@return AdeReconnector
function M.new(deps)
  return setmetatable({
    deps = deps,
    attempt = 0,
    timer = nil,
    running = false,
    -- Wall-clock time of the last successful reconnection, in ms.
    last_success = nil,
  }, Reconnector)
end

---@return integer
function Reconnector:limit()
  local cfg = self.deps.config() or {}
  local service = type(cfg.service) == "table" and cfg.service or {}
  local attempts = service.reconnect_attempts
  if type(attempts) ~= "number" then
    attempts = 8
  end
  return math.max(0, math.floor(attempts))
end

---Whether a retry loop is in flight.
---@return boolean
function Reconnector:is_running()
  return self.running
end

---Milliseconds on the injected clock.
---@return integer
function Reconnector:now()
  local clock = self.deps.now
  if type(clock) == "function" then
    local ok, value = pcall(clock)
    if ok and type(value) == "number" then
      return value
    end
  end
  return math.floor(vim.uv.gettimeofday() * 1000)
end

---Whether the previous success is still "recent", meaning a new loss continues
---the same incident.
---@return boolean
function Reconnector:continues_incident()
  if not self.last_success then
    return false
  end
  return self:now() - self.last_success < STABLE_MS
end

---@param delay_ms integer
---@return any handle
function Reconnector:schedule(delay_ms)
  local defer = self.deps.defer or function(fn, ms)
    return vim.defer_fn(fn, ms)
  end
  local token = {}
  self.schedule_token = token
  return defer(function()
    if self.schedule_token ~= token then
      -- Cancelled while this timer was pending: a stale timer must not restart
      -- the loop after the user disconnected.
      return
    end
    self.timer = nil
    self:attempt_once()
  end, delay_ms)
end

---Cancel any pending attempt. Used by an explicit disconnect and by tests.
---@param reason string|nil
function Reconnector:cancel(reason)
  if not self.running and not self.timer then
    return
  end
  self.running = false
  -- Invalidate any timer that has already been handed to `defer`.
  self.schedule_token = nil
  self.attempt = 0
  if self.timer then
    if self.deps.cancel_defer then
      pcall(self.deps.cancel_defer, self.timer)
    else
      pcall(function()
        self.timer:stop()
        self.timer:close()
      end)
    end
    self.timer = nil
  end
  if self.deps.set_status then
    pcall(self.deps.set_status, nil)
  end
  if reason then
    log.debug("reconnect loop cancelled: %s", reason)
  end
end

---A connection was lost while the service backend was in use.
---
---Only the first call starts a loop; later ones (another panel, a repeated
---notification) are ignored.
function Reconnector:lost()
  if self.running then
    return
  end
  if self:limit() == 0 then
    return
  end
  self.running = true
  -- A crash loop continues where it left off; a stable connection starts over.
  if not self:continues_incident() then
    self.attempt = 0
  end
  local limit = self:limit()
  if self.attempt >= limit then
    -- The previous incident already used every attempt: report once and stop
    -- rather than starting another endless round.
    self.running = false
    if self.deps.notify then
      pcall(
        self.deps.notify,
        string.format("the service keeps disconnecting (%d attempts used); run :Ade reconnect when it is stable", limit),
        vim.log.levels.ERROR
      )
    end
    return
  end
  -- Show the badge as soon as the drop is known, not only when the attempt
  -- starts: the first retry waits 0.5s, and without this the user sees a
  -- disconnected panel with no sign that anything is being retried. A service
  -- that was killed by the OS usually comes back at once, so the status set in
  -- `attempt_once` alone can be too short to observe at all.
  if self.deps.set_status then
    pcall(self.deps.set_status, string.format("reconnecting (%d/%d)", self.attempt + 1, limit))
  end
  -- First retry is almost immediate; a service that was killed by the OS
  -- usually comes back at once.
  self.timer = self:schedule(M.delay_for(self.attempt + 1))
end

---One attempt: `ensure`, then the normal reconnect flow.
function Reconnector:attempt_once()
  if not self.running then
    return
  end
  local limit = self:limit()
  self.attempt = self.attempt + 1
  local index = self.attempt
  if self.deps.notify and index == 1 then
    pcall(self.deps.notify, string.format("reconnecting (%d/%d)", index, limit), vim.log.levels.INFO)
  end
  if self.deps.set_status then
    pcall(self.deps.set_status, string.format("reconnecting (%d/%d)", index, limit))
  end
  self.deps.ensure(function(ok, err)
    if not self.running then
      return
    end
    if ok then
      self.running = false
      -- Remember when: the next loss within a minute continues this incident.
      self.last_success = self:now()
      if self.deps.set_status then
        pcall(self.deps.set_status, nil)
      end
      if self.deps.notify then
        pcall(self.deps.notify, "reconnected", vim.log.levels.INFO)
      end
      -- The manual `:Ade reconnect` path, unchanged.
      pcall(self.deps.reconnect)
      return
    end
    if index >= limit then
      self.running = false
      self.attempt = 0
      if self.deps.set_status then
        pcall(self.deps.set_status, nil)
      end
      if self.deps.notify then
        pcall(
          self.deps.notify,
          string.format(
            "could not reconnect after %d attempts (%s); run :Ade reconnect when the service is available",
            limit,
            tostring(err)
          ),
          vim.log.levels.ERROR
        )
      end
      return
    end
    self.timer = self:schedule(M.delay_for(index + 1))
  end)
end

return M
