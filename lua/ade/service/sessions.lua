-- Session catalog across agents (PROTOCOL.md 21).
--
-- Listing needs an agent process, and the service has no agent configuration of
-- its own: the front end sends each agent's launch and the service lists,
-- caches and returns the results. These helpers keep the wire method names and
-- payload shapes in one place so the app layer never spells a method itself.
local M = {}

M.CACHED = "sessions.cached"
M.REFRESH = "sessions.refresh"
M.UPDATED = "sessions.updated"

---Read the cached catalog. Answers immediately, without contacting an agent.
---@param connection table
---@param cb fun(ok: boolean, value: any)
function M.cached(connection, cb)
  connection:request(M.CACHED, {}, cb)
end

---List the given agents. Each entry carries `agent, command, args, cwd` and
---optionally `env` / `launch`, exactly like the `agent.attach` identity.
---@param connection table
---@param agents table[]
---@param cb fun(ok: boolean, value: any)
---@param timeout_ms integer|nil per agent; the service defaults to 30s
function M.refresh(connection, agents, cb, timeout_ms)
  local params = { agents = agents }
  if timeout_ms then
    params.timeout_ms = timeout_ms
  end
  connection:request(M.REFRESH, params, cb)
end

---Receive `sessions.updated` for one request channel.
---@param connection table
---@param channel_id string
---@param fn fun(payload: table)
function M.subscribe(connection, channel_id, fn)
  connection:subscribe(channel_id, M.UPDATED, fn)
end

---@param connection table
---@param channel_id string
function M.unsubscribe(connection, channel_id)
  connection:unsubscribe(channel_id, M.UPDATED)
end

return M
