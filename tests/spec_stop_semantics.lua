-- Stop semantics: detach versus stop, at every call site.
--
-- The table is the contract from the task:
--
--   leave/terminate (editor exit, agent switch)   -> detach when allowed
--   disconnect (the user stopped the agent)       -> stop
--   restart (login needs new credentials)         -> stop
--   a discarded not-ready client                  -> stop
--   any failure inside Client                      -> stop
--
-- "allowed" means `service.keep_alive`, an initialized ACP session and no error
-- so far. Every other combination stops, because a half-started agent nobody
-- can reach is worse than no agent.
return function(t)
  local client_mod = require("ade.protocol.client")
  local transport = require("ade.service.transport")

  ---A process-like object that records which path the Client took.
  local function fake_proc()
    local proc = { calls = {} }
    function proc:write()
      return true
    end
    function proc:stop(force)
      self.calls[#self.calls + 1] = force and "stop:force" or "stop"
    end
    function proc:leave(allow)
      self.calls[#self.calls + 1] = allow and "leave:allow" or "leave:deny"
    end
    function proc:is_alive()
      return true
    end
    function proc:mark_phase() end
    function proc:stderr()
      return ""
    end
    proc.stats = {}
    return proc
  end

  ---A client whose rpc and process are stand-ins, so nothing spawns.
  local function stub_client(opts)
    local client = client_mod.new({
      agent = { command = "agent", args = {} },
      cwd = "/tmp",
      client_capabilities = {},
      on_event = function() end,
    })
    client.rpc = {
      close = function() end,
    }
    client.proc = (opts and opts.proc) or fake_proc()
    client.initialized = opts and opts.initialized or false
    return client
  end

  t.describe("stop semantics", function()
    t.it("leaves through the transport when it can detach", function()
      local client = stub_client({ initialized = true })
      local proc = client.proc
      client:leave(true)
      t.eq({ "leave:allow" }, proc.calls)
      t.eq(nil, client.proc, "the client forgets the transport after leaving")
      t.eq(false, client.initialized)
    end)

    t.it("stops a direct process, which has no leave()", function()
      -- The direct transport object has no `leave`: leaving must still stop it,
      -- which is what the old `shutdown(true)` did.
      local proc = fake_proc()
      proc.leave = nil
      local client = stub_client({ proc = proc, initialized = true })
      client:leave(true)
      t.eq({ "stop" }, proc.calls)
    end)

    t.it("stops when detaching is not allowed", function()
      local client = stub_client({ initialized = true })
      local proc = client.proc
      client:leave(false)
      t.eq({ "stop" }, proc.calls)
    end)

    t.it("always stops on an explicit shutdown", function()
      local client = stub_client({ initialized = true })
      local proc = client.proc
      client:shutdown(true)
      t.eq({ "stop:force" }, proc.calls)
    end)

    t.it("stops a failed start instead of leaving it running", function()
      -- The failure paths call `shutdown(true)`; this pins the Client half of
      -- the rule, so a future refactor cannot turn a broken start into a
      -- detach by accident.
      local client = stub_client({ initialized = false })
      local proc = client.proc
      client:shutdown(true, { message = "initialize failed" })
      t.eq({ "stop:force" }, proc.calls)
    end)

    t.it("marks the channel initialized only when the ACP session is", function()
      local channel = transport.spawn({
        connection = {
          subscribe = function() end,
          unsubscribe_all = function() end,
          request = function(_, _, _, cb)
            cb(true, { instance = "inst-1" })
          end,
          notify = function()
            return true
          end,
        },
        command = "agent",
        args = {},
        cwd = "/tmp",
      })
      t.falsy(channel.initialized)
      channel:set_initialized(true)
      t.truthy(channel.initialized)
    end)
  end)

  t.describe("leaving on exit", function()
    t.it("the panel's leave hook reaches Connection:terminate", function()
      -- `terminate` is the exit path (`VimLeavePre` -> panel on_leave). It must
      -- call `leave`, not `shutdown`, or the agent would be killed every time
      -- the editor closes.
      local Connection = require("ade.app.connection")
      local client_calls = {}
      local client = {
        leave = function(_, allow)
          client_calls[#client_calls + 1] = allow and "leave:allow" or "leave:deny"
        end,
        shutdown = function()
          client_calls[#client_calls + 1] = "shutdown"
        end,
      }
      local state = { conn = { client = client } }
      local conn = Connection.new({
        config = function()
          return { backend = "direct", agents = {}, service = {} }
        end,
        state = function()
          return state
        end,
        locks = {
          unlease = function() end,
        },
      })
      conn:terminate()
      t.eq({ "leave:allow" }, client_calls)
      t.eq(nil, state.conn.client)
    end)

    t.it("reconfiguring leaves instead of killing the old agent", function()
      local Connection = require("ade.app.connection")
      local calls = {}
      local client = {
        leave = function()
          calls[#calls + 1] = "leave"
        end,
        shutdown = function()
          calls[#calls + 1] = "shutdown"
        end,
      }
      local state = { conn = { client = client } }
      local conn = Connection.new({
        state = function()
          return state
        end,
        config = function()
          return { backend = "direct" }
        end,
        locks = { unlease = function() end },
      })
      conn:terminate()
      t.eq({ "leave" }, calls)
    end)
  end)
end
