-- S1b integration: adoption, retraction and restore through the real Client.
--
-- The stand-in service speaks the api_version 2 protocol and runs a real
-- `tests/mock_agent.py` child, so these exercise the whole path: notification
-- from the service → Client → application layer.
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local Framing = require("ade.transport.framing")
  local service_transport = require("ade.service.transport")
  local Connection = require("ade.service.connection")
  local client_mod = require("ade.protocol.client")
  local Interactions = require("ade.app.interactions")
  local Adoption = require("ade.app.adoption")
  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local counter = 0
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-s1bit-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.mkdir(dir, "p", 448)
    t.cleanup(function()
      vim.fn.delete(dir, "rf")
    end)
    return dir
  end

  ---A stand-in service (no agent process: these cases push notifications by
  ---hand, which is exactly what the relay does).
  local function start_service()
    local dir = tmpdir("svc")
    -- A canned ACP agent: these cases only need the tunnel, and a real child
    -- process would add startup time and its own scheduling.
    local service = fake.new({ dir = dir, canned_agent = true })
    service.spawn_agent = function()
      return true
    end
    assert(service:listen())
    t.cleanup(function()
      service:close()
    end)
    return service, dir
  end

  local function connect(service, dir)
    local saved = vim.env.NVIM_ADE_SERVER_DIR
    vim.env.NVIM_ADE_SERVER_DIR = dir
    t.cleanup(function()
      vim.env.NVIM_ADE_SERVER_DIR = saved
    end)
    local connection = Connection.new({
      resolve_binary = function()
        return { path = "/fake", version = Version.VERSION, api_version = Version.API_VERSION }
      end,
      ensure_service = function()
        return true
      end,
      timeout = 3000,
    })
    local ok, err
    connection:ensure(function(result, reason)
      ok, err = result, reason
    end)
    return connection, ok, err
  end

  ---A Client over the service channel with a recording adoption owner.
  local function client(connection)
    local events = {}
    local sessions = {}
    local instance = Adoption.new({
      state = function()
        return { sess = { all = sessions } }
      end,
      refresh_chrome = function() end,
      schedule_render = function() end,
      dispatch_queued = function(session)
        session.dispatched = (session.dispatched or 0) + 1
      end,
      add_block = function(text, kind)
        events[#events + 1] = { name = "block", text = text, kind = kind }
      end,
      notify = function(message)
        events[#events + 1] = { name = "notify", text = message }
      end,
    })
    local c = client_mod.new({
      agent = { command = "agent", args = {} },
      cwd = root,
      client_capabilities = {},
      agent_id = "opencode",
      transport = service_transport,
      connection = connection,
      keep_alive = false,
      on_event = function(name, payload)
        events[#events + 1] = { name = name, payload = payload }
        if name == "turn_adopted" then
          instance:adopted_turn(payload)
        elseif name == "turn_finished" then
          instance:finished_turn(payload)
        end
      end,
    })
    return c, instance, sessions, events
  end

  t.describe("turn adoption over the tunnel", function()
    t.it("routes _ade/turn_adopted and _ade/turn_finished to the app layer", function()
      local service, dir = start_service()
      local connection, ok, err = connect(service, dir)
      t.truthy(ok, tostring(err))
      local c, adoption, sessions, events = client(connection)
      local ready
      c:start(function(started, start_err)
        ready = { ok = started, err = start_err }
      end)
      t.truthy(
        vim.wait(5000, function()
          return ready ~= nil
        end, 10),
        "client did not start"
      )
      t.truthy(ready.ok, vim.inspect(ready.err))
      local instance_id = c.proc.instance

      -- A session the app layer knows about, exactly as a load would create it.
      local session = {
        id = "sess_mock",
        status = "idle",
        turn = 0,
        queue = {},
        blocks = {},
        finished = {},
      }
      function session:begin_turn()
        self.turn = self.turn + 1
        self.status = "running"
      end
      function session:finish_turn(reason)
        self.status = "idle"
        self.finished[#self.finished + 1] = reason
      end
      sessions.sess_mock = session

      t.truthy(service:adopt(instance_id, "sess_mock"))
      vim.wait(2000, function()
        return session.status == "running"
      end, 10)
      t.eq("running", session.status, "the Adoption event never reached the app layer")
      t.truthy(adoption:is_adopted("sess_mock"))

      t.truthy(service:finish_adopted(instance_id, "sess_mock", "end_turn"))
      vim.wait(2000, function()
        return session.status == "idle"
      end, 10)
      t.eq("idle", session.status)
      t.eq({ "end_turn" }, session.finished)
      t.eq(1, session.dispatched or 0, "the queue must be dispatched")
      c:shutdown(true)
      connection:close()
      service:close()
    end)

    t.it("does not resurrect an adoption after the connection drops", function()
      local service, dir = start_service()
      local connection, ok, err = connect(service, dir)
      t.truthy(ok, tostring(err))
      local c, adoption, sessions, events = client(connection)
      local ready
      c:start(function(started)
        ready = started
      end)
      vim.wait(5000, function()
        return ready ~= nil
      end, 10)
      local session = {
        id = "s",
        status = "idle",
        turn = 0,
        queue = {},
        blocks = {},
        finished = {},
      }
      function session:begin_turn()
        self.turn = self.turn + 1
        self.status = "running"
      end
      function session:finish_turn(reason)
        self.status = "idle"
        self.finished[#self.finished + 1] = reason
      end
      sessions.s = session
      service:adopt(c.proc.instance, "s")
      vim.wait(2000, function()
        return session.status == "running"
      end, 10)
      t.eq("running", session.status)

      -- The adopted turn must not outlive the client that adopted it. That is
      -- `Adoption:reset`, which `Connection:lost` calls; drive it directly here
      -- because this test has no controller to receive the exit event.
      adoption:reset("connection lost")
      t.eq("idle", session.status, "an adopted turn outlived its connection")
      t.eq("cancelled", session.finished[1])
      t.falsy(adoption:is_adopted("s"))
      connection:close()
    end)
  end)

  t.describe("retracting a request over the tunnel", function()
    t.it("closes the picker and answers -32800", function()
      local service, dir = start_service()
      local connection, ok, err = connect(service, dir)
      t.truthy(ok, tostring(err))
      local presented = {}
      local interactions = Interactions.new({
        presenters = {
          permission = {
            present = function(interaction)
              presented[#presented + 1] = interaction
              return true
            end,
            dismiss = function() end,
          },
          elicitation = {
            present = function(interaction)
              presented[#presented + 1] = interaction
              return true
            end,
            dismiss = function() end,
          },
        },
        notify = function() end,
        on_changed = function() end,
      })
      local sent = {}
      local c = client_mod.new({
        agent = { command = "python3", args = { root .. "tests/mock_agent.py" } },
        cwd = root,
        client_capabilities = require("ade.protocol.capabilities").client(require("ade.config").effective()),
        interactions = interactions,
        agent_id = "opencode",
        transport = service_transport,
        connection = connection,
        keep_alive = false,
        on_event = function() end,
      })
      local ready
      c:start(function(started, start_err)
        ready = { ok = started, err = start_err }
      end)
      t.truthy(
        vim.wait(10000, function()
          return ready ~= nil
        end, 20),
        "client did not start"
      )
      t.truthy(ready.ok, vim.inspect(ready.err))
      local instance_id = c.proc.instance

      -- A pending agent request, delivered to this front end.
      local request = {
        jsonrpc = "2.0",
        id = 4242,
        method = "session/request_permission",
        params = {
          sessionId = "sess_mock",
          toolCall = { toolCallId = "c1", title = "Write a file" },
          options = { { optionId = "allow", name = "Allow", kind = "allow_once" } },
        },
      }
      local session
      c.start_co = require("ade.async").run(function()
        local created, result = c:new_session(root)
        assert(created, vim.inspect(result))
        session = result.sessionId
      end)
      vim.wait(5000, function()
        return session ~= nil
      end, 20)
      service:deliver(service.instances[instance_id], request)
      t.truthy(
        vim.wait(5000, function()
          return #presented > 0
        end, 10),
        "the permission request was not presented"
      )
      local interaction = presented[1]
      t.eq(4242, interaction.rpc_id)

      -- The RPC layer must have recorded the request, or `$/cancel_request` has
      -- nothing to answer. This is what makes the -32800 possible at all.
      t.truthy(
        vim.wait(3000, function()
          return c.rpc.incoming[4242] ~= nil
        end, 10),
        "the request was never registered as incoming"
      )
      -- The service retracts it (another front end answered, or the agent
      -- withdrew it). The picker must close and a -32800 must go back.
      t.truthy(service:retract(instance_id, 4242))
      vim.wait(3000, function()
        return #interactions:pending() == 0
      end, 10)
      t.eq({}, interactions:pending(), "the retracted request must be gone")

      -- The answer travels the same asynchronous path as everything else: the
      -- `tunnel.send` is a notification queued behind `ensure`, so wait for it.
      local errors = {}
      vim.wait(3000, function()
        errors = {}
        for _, frame in ipairs(service.sent) do
          local message = frame.message
          if message and message.id == 4242 and message.error then
            errors[#errors + 1] = message.error
          end
        end
        return #errors > 0
      end, 10)
      t.truthy(#errors > 0, "no error response was sent for the retracted request")
      t.eq(-32800, errors[#errors].code)
      c:shutdown(true)
      connection:close()
      service:close()
    end)
  end)
end
