-- An **asynchronous** fake service connection for the command tests.
--
-- The bug these tests exist for was invisible because the fakes answered
-- synchronously: `:Ade service agents` sent a request and read the result in the
-- next statement, which only ever works when the callback already ran. So the
-- default here replies on a later tick, exactly like a real socket.
--
-- A test that genuinely needs a synchronous answer must ask for it:
--
--     local conn = fake_connection.new({ sync = true })
--
-- The wrapper records every notification so a test can assert *when* something
-- was printed, not only that it was printed.
local M = {}

---@class FakeConnection
---@field calls {method: string, params: any}[]
---@field notes {text: string}[]
---@field pending integer number of replies not yet delivered

---@param opts {sync?: boolean, delay_ms?: integer,
---  responders?: table<string, fun(params: any): boolean, any>,
---  request?: fun(self: table, method: string, params: any, cb: fun(ok: boolean, value: any), timeout_ms: integer|nil): integer|nil}|nil
---@return table
function M.new(opts)
  opts = opts or {}
  local self = {
    calls = {},
    notes = {},
    pending = 0,
    subscriptions = {},
    closed = false,
    -- `sync` must be written explicitly: the point is that nothing is
    -- synchronous by accident.
    sync = opts.sync == true,
    delay_ms = opts.delay_ms or 1,
    responders = opts.responders or {},
  }

  ---Record one visible message, the way `vim.notify` would.
  ---@param text string
  function self:note(text)
    self.notes[#self.notes + 1] = tostring(text)
  end

  ---The `notify` callback handed to the command under test.
  function self:notify()
    return function(message)
      self:note(message)
    end
  end

  ---Matches `Connection:subscribe(channel_id, method, fn)`.
  function self:subscribe(_channel_id, method, fn)
    self.subscriptions[method] = fn
  end

  function self:unsubscribe_all() end

  function self:notify_service()
    return true
  end

  function self:is_connected()
    return not self.closed
  end

  function self:last_error()
    return nil
  end

  ---A connection with no explicit config; the resolver is injectable so a test
  ---can decide what the shared connection would resolve to.
  function self:resolve()
    return { path = "/fake/nvim_ade_server", source = "configured" }
  end

  function self:ensure(cb)
    if self.closed then
      cb(false, "connection closed")
      return
    end
    cb(true, nil)
  end

  ---Reply to a recorded request, honouring the sync/async mode.
  ---@param method string
  ---@param params any
  ---@param cb fun(ok: boolean, value: any)
  ---@return integer|nil id
  function self:request(method, params, cb, _timeout_ms)
    self.calls[#self.calls + 1] = { method = method, params = params }
    local responder = self.responders[method]
    local ok, value = true, {}
    if responder then
      ok, value = responder(params)
    end
    self.pending = self.pending + 1
    local function deliver()
      self.pending = self.pending - 1
      if cb then
        cb(ok, value)
      end
    end
    if self.sync then
      deliver()
    else
      -- A later tick, like a real socket reply. `vim.defer_fn` keeps the test
      -- honest about ordering without needing a real service.
      vim.defer_fn(deliver, self.delay_ms)
    end
    return 1
  end
  self.request = opts.request or self.request

  ---Simulate a dropped connection: every subscriber is told, once.
  function self:drop(reason)
    self.closed = true
    local fn = self.subscriptions["__disconnected"]
    if fn then
      fn({ reason = reason or "socket closed" })
    end
  end

  return self
end

return M
