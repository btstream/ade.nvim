-- The service channel: the same Client talking through nvim_ade_server.
--
-- The stand-in (`tests/fake_service.lua`) speaks the api_version 2 tunnel and
-- runs a real `tests/mock_agent.py` child for the conversation cases, so the
-- whole path — Client, tunnel, ACP agent — is exercised without the Rust
-- service. Direct-backend behaviour is covered by the existing specs and is not
-- touched here.
return function(t)
  local Version = require("ade.service.version")
  local Framing = require("ade.transport.framing")
  local fake = require("tests.fake_service")
  local service_transport = require("ade.service.transport")
  local client_mod = require("ade.protocol.client")
  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local counter = 0
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-s1a-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.mkdir(dir, "p")
    t.cleanup(function()
      vim.fn.delete(dir, "rf")
    end)
    return dir
  end

  ---Start a stand-in service that answers ACP frames with a real mock agent.
  ---@param opts table|nil
  local function start_service(opts)
    opts = opts or {}
    local dir = tmpdir("svc")
    local service = fake.new({
      dir = dir,
      api_version = opts.api_version,
      server_version = opts.server_version,
    })
    service.spawn_agent = function(instance)
      if opts.no_agent then
        return true
      end
      local job = vim.fn.jobstart({ "python3", root .. "tests/mock_agent.py" }, {
        stdin = "pipe",
        stdout_buffered = false,
        on_stdout = function(_, data)
          local decoder = instance.decoder or Framing.new_decoder()
          instance.decoder = decoder
          for _, chunk in ipairs(data or {}) do
            if chunk ~= "" then
              decoder:feed(chunk .. "\n", function(line)
                if line == "" then
                  return
                end
                local ok, message = pcall(vim.json.decode, line)
                if ok and type(message) == "table" then
                  service:deliver(instance, message)
                end
              end)
            end
          end
        end,
      })
      instance.job = job
      instance.handler = function(message, reply)
        local ok, encoded = pcall(vim.json.encode, message)
        if ok then
          pcall(vim.fn.chansend, job, encoded .. "\n")
        end
        -- The mock agent answers asynchronously through on_stdout.
        reply(nil)
      end
      instance.stop_agent = function()
        pcall(vim.fn.jobstop, job)
      end
      return job > 0
    end
    assert(service:listen(), "the stand-in service could not listen")
    t.cleanup(function()
      service:close()
    end)
    return service, dir
  end

  ---A connection object wired to the stand-in, with its own NVIM_ADE_SERVER_DIR.
  local function connect(service, dir, opts)
    opts = opts or {}
    local Connection = require("ade.service.connection")
    local saved = vim.env.NVIM_ADE_SERVER_DIR
    vim.env.NVIM_ADE_SERVER_DIR = dir
    t.cleanup(function()
      vim.env.NVIM_ADE_SERVER_DIR = saved
    end)
    local connection = Connection.new(vim.tbl_extend("force", {
      resolve_binary = function()
        return { path = "/fake/nvim_ade_server", version = Version.VERSION, api_version = Version.API_VERSION }
      end,
      ensure_service = function()
        return true
      end,
      timeout = 3000,
    }, opts))
    local ok, err = nil, nil
    connection:ensure(function(result, reason)
      ok, err = result, reason
    end)
    return connection, ok, err
  end

  t.describe("service channel", function()
    t.it("wraps outgoing lines in tunnel.send", function()
      local service, dir = start_service({ no_agent = true })
      local stylized = {}
      local connection = {
        subscribe = function() end,
        unsubscribe_all = function() end,
        request = function(_, method, params, cb)
          if cb then
            cb(true, { instance = "inst-1" })
          end
          stylized[#stylized + 1] = { method = method, params = params }
        end,
        notify = function(_, method, params)
          stylized[#stylized + 1] = { method = method, params = params }
          return true
        end,
      }
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
        on_line = function() end,
      }))
      t.eq("agent.attach", stylized[1].method)
      t.eq("agent", stylized[1].params.key.agent)
      t.eq("/tmp", stylized[1].params.key.cwd)
      t.truthy(type(stylized[1].params.env) == "table", "the attach must carry the complete env")

      local payload = vim.json.encode({ jsonrpc = "2.0", id = 7, method = "initialize", params = {} })
      t.truthy(channel:write(payload))
      local sent = stylized[#stylized]
      t.eq("tunnel.send", sent.method)
      t.eq("inst-1", sent.params.instance)
      t.eq("initialize", sent.params.message.method)
      t.eq(7, sent.params.message.id)
      service:close()
    end)

    t.it("queues frames written before attach is answered", function()
      local calls = {}
      local pending_attach
      local connection = {
        subscribe = function() end,
        unsubscribe_all = function() end,
        request = function(_, method, params, cb)
          calls[#calls + 1] = { method = method, params = params }
          if method == "agent.attach" then
            pending_attach = cb
          end
        end,
        notify = function(_, method, params)
          calls[#calls + 1] = { method = method, params = params }
          return true
        end,
      }
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
      }))
      t.truthy(channel:write(vim.json.encode({ jsonrpc = "2.0", id = 1, method = "initialize" })))
      t.eq(1, #calls, "nothing but the attach may be sent before the instance exists")
      pending_attach(true, { instance = "inst-9" })
      t.eq(2, #calls, "the queued frame must be flushed after the attach")
      t.eq("tunnel.send", calls[2].method)
      t.eq("inst-9", calls[2].params.instance)
    end)

    t.it("delivers tunnel.recv to on_message and ignores other instances", function()
      local listeners = {}
      local connection = {
        subscribe = function(_, _, method, fn)
          listeners[method] = fn
        end,
        unsubscribe_all = function() end,
        request = function(_, _, _, cb)
          cb(true, { instance = "inst-1" })
        end,
        notify = function()
          return true
        end,
      }
      local received = {}
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
        on_message = function(message)
          received[#received + 1] = message
        end,
      }))
      listeners["tunnel.recv"]({
        instance = "inst-1",
        seq = 1,
        message = { jsonrpc = "2.0", method = "x", params = {} },
      })
      listeners["tunnel.recv"]({ instance = "other", seq = 2, message = { jsonrpc = "2.0", method = "y", params = {} } })
      t.eq(1, #received)
      t.eq("x", received[1].method)
    end)

    t.it("reports an exit from agent.exited with the stderr tail", function()
      local listeners = {}
      local connection = {
        subscribe = function(_, _, method, fn)
          listeners[method] = fn
        end,
        unsubscribe_all = function() end,
        request = function(_, _, _, cb)
          cb(true, { instance = "inst-1" })
        end,
        notify = function()
          return true
        end,
      }
      local exited = nil
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
        on_exit = function(code, stderr)
          exited = { code = code, stderr = stderr }
        end,
      }))
      listeners["agent.exited"]({ instance = "inst-1", code = 3, signal = nil, stderr_tail = "boom" })
      t.eq(3, exited.code)
      t.eq("boom", exited.stderr)
      t.eq(false, channel:is_alive())
      t.eq("boom", channel:stderr())
    end)

    t.it("turns a rejected tunnel.send into an error response for that request", function()
      local listeners = {}
      local connection = {
        subscribe = function(_, _, method, fn)
          listeners[method] = fn
        end,
        unsubscribe_all = function() end,
        request = function(_, _, _, cb)
          cb(true, { instance = "inst-1" })
        end,
        notify = function()
          return true
        end,
      }
      local received = {}
      assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
        on_message = function(message)
          received[#received + 1] = message
        end,
      }))
      listeners["tunnel.error"]({ instance = "inst-1", code = -32025, message = "too long", id = 12 })
      t.eq(1, #received)
      t.eq(12, received[1].id)
      t.eq(-32025, received[1].error.code)
      t.match("too long", received[1].error.message)
    end)

    t.it("reports an exit when the shared connection is lost", function()
      local listeners = {}
      local connection = {
        subscribe = function(_, _, method, fn)
          listeners[method] = fn
        end,
        unsubscribe_all = function() end,
        request = function(_, _, _, cb)
          cb(true, { instance = "inst-1" })
        end,
        notify = function()
          return true
        end,
      }
      local exited = nil
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
        on_exit = function(code, stderr)
          exited = { code = code, stderr = stderr }
        end,
      }))
      listeners["__disconnected"]({ reason = "socket closed" })
      t.truthy(exited)
      t.eq(-1, exited.code)
      t.match("service connection lost", exited.stderr)
      t.eq(false, channel:is_alive())
    end)

    t.it("detaches only for a deliberate, initialized, keep-alive leave", function()
      local calls = {}
      local function new_channel(opts)
        local connection = {
          subscribe = function() end,
          unsubscribe_all = function() end,
          request = function(_, method, params, cb)
            calls[#calls + 1] = { method = method, params = params }
            if cb then
              cb(true, { instance = "inst-1" })
            end
          end,
          notify = function()
            return true
          end,
        }
        return assert(service_transport.spawn(vim.tbl_extend("force", {
          connection = connection,
          command = "agent",
          args = {},
          cwd = "/tmp",
        }, opts or {})))
      end

      -- The whole decision table: detach only when everything holds.
      local cases = {
        {
          label = "keep_alive + initialized + deliberate",
          keep_alive = true,
          initialized = true,
          allow = true,
          expect = "agent.detach",
        },
        { label = "keep_alive off", keep_alive = false, initialized = true, allow = true, expect = "agent.stop" },
        { label = "not initialized", keep_alive = true, initialized = false, allow = true, expect = "agent.stop" },
        { label = "not deliberate", keep_alive = true, initialized = true, allow = false, expect = "agent.stop" },
      }
      for _, case in ipairs(cases) do
        calls = {}
        local channel = new_channel({ keep_alive = case.keep_alive })
        if case.initialized then
          channel:set_initialized(true)
        end
        channel:leave(case.allow)
        local methods = {}
        for _, call in ipairs(calls) do
          methods[#methods + 1] = call.method
        end
        t.truthy(
          vim.tbl_contains(methods, case.expect),
          string.format("%s: expected %s, got %s", case.label, case.expect, table.concat(methods, ","))
        )
        t.eq(false, channel:is_alive())
      end
    end)

    t.it("detaches without sending when the connection was already lost", function()
      local listeners, calls = {}, {}
      local connection = {
        subscribe = function(_, _, method, fn)
          listeners[method] = fn
        end,
        unsubscribe_all = function() end,
        request = function(_, method, params, cb)
          calls[#calls + 1] = { method = method, params = params }
          if cb then
            cb(true, { instance = "inst-1" })
          end
        end,
        notify = function()
          return true
        end,
      }
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
      }))
      channel:set_initialized(true)
      -- The socket is gone: the service already removed this connection from
      -- `attached` and keeps the instance and its pending set (PROTOCOL 5.4/9.4).
      listeners["__disconnected"]({ reason = "socket closed" })
      t.eq(false, channel:is_alive())
      t.truthy(channel:will_detach(), "a lost connection must still count as a detach")

      channel:leave(true)
      local methods = {}
      for _, call in ipairs(calls) do
        methods[#methods + 1] = call.method
      end
      -- Nothing to send: `agent.detach` would reopen a service this front end is
      -- leaving, and `agent.stop` would kill an agent that survived.
      t.eq({ "agent.attach" }, methods, "a lost connection must not send detach or stop")
      t.truthy(channel.detached, "the channel must record the detach")
    end)

    t.it("does not ask a dead or already-exited channel to stop the agent", function()
      local function report(kill)
        local listeners, calls = {}, {}
        local connection = {
          subscribe = function(_, _, method, fn)
            listeners[method] = fn
          end,
          unsubscribe_all = function() end,
          request = function(_, method, params, cb)
            calls[#calls + 1] = { method = method, params = params }
            if cb then
              cb(true, { instance = "inst-1" })
            end
          end,
          notify = function()
            return true
          end,
        }
        local channel = assert(service_transport.spawn({
          connection = connection,
          command = "agent",
          args = {},
          cwd = "/tmp",
        }))
        channel:set_initialized(true)
        kill(listeners)
        channel:stop(false)
        local methods = {}
        for _, call in ipairs(calls) do
          methods[#methods + 1] = call.method
        end
        return methods, channel
      end

      -- Initialized=false is the interesting variant here: `will_detach` says
      -- stop, but the connection is already gone, so `agent.stop` would make
      -- `Connection:request` ensure() a service just as the editor leaves.
      local disconnected, channel = report(function(listeners)
        listeners["__disconnected"]({ reason = "socket closed" })
      end)
      t.eq(false, channel:is_alive())
      t.eq({ "agent.attach" }, disconnected, "a lost connection must not send agent.stop")

      local exited = report(function(listeners)
        listeners["agent.exited"]({ instance = "inst-1", code = 0, stderr_tail = "" })
      end)
      t.eq({ "agent.attach" }, exited, "an agent that already exited must not be stopped again")
    end)

    t.it("runs a real ACP conversation through the tunnel", function()
      if vim.fn.executable("python3") ~= 1 then
        io.write("SKIP: python3 is required for the mock agent\n")
        return
      end
      local service, dir = start_service()
      local connection, ok, err = connect(service, dir)
      t.truthy(ok, tostring(err))

      local events = {}
      local client = client_mod.new({
        agent = { command = "python3", args = { root .. "tests/mock_agent.py" } },
        cwd = root,
        client_capabilities = {},
        agent_id = "opencode",
        transport = service_transport,
        connection = connection,
        keep_alive = false,
        on_event = function(name, payload)
          events[#events + 1] = { name = name, payload = payload }
        end,
      })
      local ready
      client:start(function(started, start_err)
        ready = { ok = started, err = start_err }
      end)
      t.truthy(
        vim.wait(15000, function()
          return ready ~= nil
        end, 20),
        "the client did not start"
      )
      t.truthy(ready.ok, vim.inspect(ready.err))
      t.truthy(client:is_ready())
      t.eq(1, service:instance_count(), "the service should hold exactly one instance")

      local session
      client.start_co = require("ade.async").run(function()
        local created, result = client:new_session(root)
        assert(created, vim.inspect(result))
        session = result.sessionId
      end)
      t.truthy(
        vim.wait(10000, function()
          return session ~= nil
        end, 20),
        "session/new did not complete"
      )
      t.eq("sess_mock", session, "the mock agent's session id")

      client:shutdown(true)
      t.truthy(
        vim.wait(5000, function()
          return service:instance_count() == 0
        end, 20),
        "agent.stop must remove the instance"
      )
    end)

    t.it("fails the client clearly when attach is refused", function()
      local listeners = {}
      local connection = {
        subscribe = function(_, _, method, fn)
          listeners[method] = fn
        end,
        unsubscribe_all = function() end,
        request = function(_, method, _, cb)
          if method == "agent.attach" then
            cb(false, { code = -32022, message = "spawn failed: ENOENT" })
          end
        end,
        notify = function()
          return true
        end,
      }
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "no-such-agent",
        args = {},
        cwd = "/tmp",
      }))
      t.truthy(vim.wait(1000, function()
        return not channel:is_alive()
      end, 10))
      t.match("spawn failed", tostring(channel:stderr()))
    end)
  end)

  t.describe("stop does not block", function()
    ---A connection whose `agent.stop` reply is delayed by `delay_ms`.
    local function slow_service(delay_ms)
      local dir = tmpdir("slowstop")
      local service = fake.new({ dir = dir, stop_delay_ms = delay_ms })
      t.cleanup(function()
        service:close()
      end)
      assert(service:listen())
      local connection, ok, err = connect(service, dir)
      assert(ok, tostring(err))
      return service, connection
    end

    t.it("returns from stop long before the service replies", function()
      local service, connection = slow_service(1500)
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
      }))
      -- Give the attach a moment so the channel has an instance to stop.
      vim.wait(2000, function()
        return channel.instance ~= nil
      end, 10)
      local started = vim.uv.hrtime()
      channel:stop(false)
      local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
      t.truthy(elapsed_ms < 100, string.format("stop blocked for %.1f ms", elapsed_ms))
      t.eq(false, channel:is_alive())
      service:close()
    end)

    t.it("returns from leave long before the reply", function()
      local service, connection = slow_service(1500)
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
        keep_alive = true,
      }))
      vim.wait(2000, function()
        return channel.instance ~= nil
      end, 10)
      channel:set_initialized(true)
      local started = vim.uv.hrtime()
      channel:leave(true)
      local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
      t.truthy(elapsed_ms < 100, string.format("leave blocked for %.1f ms", elapsed_ms))
      t.eq(true, channel.detached)
      service:close()
    end)

    t.it("synthesizes an exit when the stop request itself fails", function()
      local connection = {
        subscribe = function() end,
        unsubscribe_all = function() end,
        request = function(_, method, _, cb)
          if method == "agent.attach" then
            cb(true, { instance = "inst-1" })
          elseif method == "agent.stop" then
            -- The service rejected it: no `agent.exited` will follow.
            cb(false, { code = -32020, message = "unknown instance" })
          end
        end,
        notify = function()
          return true
        end,
      }
      local exited = nil
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
        on_exit = function(code, stderr)
          exited = { code = code, stderr = stderr }
        end,
      }))
      channel.stopping = false
      channel:stop(false)
      t.truthy(exited, "a rejected stop must still report an exit")
      t.eq(false, channel:is_alive())
    end)

    t.it("stops at once but the next attach gets a different instance", function()
      -- PROTOCOL.md 3.4: the stopped instance leaves the identity lookup when the
      -- request is processed, so the new attach must never reuse it.
      local exit_code = 0
      local dir = tmpdir("stop-attach")
      local service = fake.new({ dir = dir })
      service.spawn_agent = function(instance)
        instance.pid = 1000 + (self and 0 or 0)
        return true
      end
      assert(service:listen())
      t.cleanup(function()
        service:close()
      end)
      local connection, ok, err = connect(service, dir)
      assert(ok, tostring(err))

      local first = assert(service_transport.spawn({
        connection = connection,
        command = "agent-1",
        args = {},
        cwd = "/tmp",
      }))
      vim.wait(2000, function()
        return first.instance ~= nil
      end, 10)
      local first_id = first.instance
      t.truthy(first_id)

      first:stop(false)
      -- No waiting between stop and attach: this is exactly the race the old
      -- waiting code existed to paper over.
      local second = assert(service_transport.spawn({
        connection = connection,
        command = "agent-1",
        args = {},
        cwd = "/tmp",
      }))
      vim.wait(2000, function()
        return second.instance ~= nil
      end, 10)
      t.truthy(second.instance)
      t.truthy(second.instance ~= first_id, "the new attach reused the stopped instance")
      t.eq(exit_code, 0)
      service:close()
    end)
  end)

  t.describe("exit waits at most 2 seconds", function()
    t.it("bounds the wait to 2 seconds when the editor is exiting", function()
      -- `vim.v.exiting` is read-only, so the wait helper is exercised directly
      -- through a channel whose reply never arrives: with the editor "exiting"
      -- simulated, the helper must stop after its 2 s ceiling and no longer.
      local waits = {}
      local saved_wait = vim.wait
      local saved_exiting = vim.v.exiting
      vim.wait = function(timeout, ...)
        waits[#waits + 1] = timeout
        return saved_wait(5, ...)
      end
      t.cleanup(function()
        vim.wait = saved_wait
        local _ = saved_exiting
      end)
      -- Not exiting: no wait at all.
      local connection = {
        subscribe = function() end,
        unsubscribe_all = function() end,
        request = function(_, method, _, cb)
          if method == "agent.attach" then
            cb(true, { instance = "inst-1" })
          end
          -- `agent.stop` never answers.
        end,
        notify = function()
          return true
        end,
      }
      local channel = assert(service_transport.spawn({
        connection = connection,
        command = "agent",
        args = {},
        cwd = "/tmp",
      }))
      waits = {}
      channel:stop(false)
      t.eq(0, #waits, "stop must not wait while the editor is live")
    end)

    t.it("documents the 2 s ceiling in the exit path", function()
      -- The ceiling is a constant in `flush_if_exiting`; asserting it here keeps
      -- the number from growing silently (the point of the review was that the
      -- old 10 s/5 s waits froze shutdown).
      local source = table.concat(vim.fn.readfile(vim.fn.fnamemodify("lua/ade/service/transport.lua", ":p")), "\n")
      t.match("flush_if_exiting%(state, 2000%)", source)
      t.falsy(source:find("await%(state", 1, true), "the blocking await helper must be gone")
      t.falsy(source:find("10000%)", 1, true))
    end)
  end)

  t.describe("service connection", function()
    t.it("fans notifications out to the subscribed channels only", function()
      local Connection = require("ade.service.connection")
      local connection = Connection.new({ resolve_binary = function() end })
      local seen = {}
      connection:subscribe("a", "tunnel.recv", function(payload)
        seen[#seen + 1] = "a:" .. payload.instance
      end)
      connection:subscribe("b", "tunnel.recv", function(payload)
        seen[#seen + 1] = "b:" .. payload.instance
      end)
      connection:dispatch("tunnel.recv", { instance = "i1" })
      t.eq({ "a:i1", "b:i1" }, seen)
      connection:unsubscribe("a", "tunnel.recv")
      seen = {}
      connection:dispatch("tunnel.recv", { instance = "i2" })
      t.eq({ "b:i2" }, seen)
    end)

    t.it("tells every channel each time the connection drops", function()
      -- One notification per drop, delivered to every subscriber. Two drops are
      -- two events: the connection object stays usable between them (a later
      -- `ensure()` reconnects), so a second loss must still be reported.
      local Connection = require("ade.service.connection")
      local connection = Connection.new({})
      local reasons = {}
      connection:subscribe("a", "__disconnected", function(payload)
        reasons[#reasons + 1] = payload.reason
      end)
      connection:subscribe("b", "__disconnected", function(payload)
        reasons[#reasons + 1] = payload.reason
      end)
      connection:on_disconnect("socket closed")
      connection:on_disconnect("socket closed again")
      t.eq(4, #reasons, "each drop is reported to each channel")
      t.match("socket closed", reasons[1])
      t.match("again", reasons[3])
    end)

    t.it("reports an unusable service without a retry loop", function()
      local Connection = require("ade.service.connection")
      local connection = Connection.new({
        resolve_binary = function()
          return nil, "nvim_ade_server is not installed"
        end,
      })
      local ok, err
      connection:ensure(function(result, reason)
        ok, err = result, reason
      end)
      t.falsy(ok)
      t.match("not installed", err)
      t.eq(false, connection:is_connected())
    end)

    t.it("connects lazily and shares one socket between channels", function()
      local service, dir = start_service({ no_agent = true })
      local connection, ok, err = connect(service, dir)
      t.truthy(ok, tostring(err))
      t.truthy(connection:is_connected())
      -- A second ensure must not open another connection.
      local again
      connection:ensure(function(result)
        again = result
      end)
      t.truthy(again)
      t.eq(1, #service.clients, "one socket for the whole editor")
      connection:close()
    end)
  end)

  t.describe("JSON null normalisation", function()
    ---Every `vim.NIL` reachable from `value`, as a path for the failure message.
    ---@param value any
    ---@param path string
    ---@param out string[]
    local function find_nil(value, path, out)
      if value == vim.NIL then
        out[#out + 1] = path
        return out
      end
      if type(value) ~= "table" then
        return out
      end
      for key, item in pairs(value) do
        find_nil(item, path .. "." .. tostring(key), out)
      end
      return out
    end

    ---A `session/resume`-shaped response with nulls in every position the ACP
    ---schema allows: a scalar field, an array element and a nested object.
    ---
    ---Written as raw JSON, not encoded from a Lua table: `vim.NIL` in a table
    ---does not survive `vim.json.encode` predictably, and the wire form is what
    ---the decoder under test actually sees.
    local function response_with_nulls()
      return table.concat({
        '{"jsonrpc":"2.0","id":7,"result":{',
        '"sessionId":"sess_old",',
        '"configOptions":null,',
        '"modes":null,',
        '"capabilities":{"images":null,"tools":[null,"read"]},',
        '"nested":{"deeper":{"value":null}}',
        "}}",
      })
    end

    t.it("normalises null to nil the same way the direct transport does", function()
      local decoded = {}
      local client = require("ade.service.client").new({ timeout = 2000 })
      t.cleanup(function()
        client:close()
      end)
      -- `rpc:handle(message)` prepends the rpc table as `self`, so the message
      -- is the *second* parameter.
      client.rpc = {
        handle = function(_, message)
          decoded[#decoded + 1] = message
        end,
        close = function() end,
      }
      client.ready = true
      local wire = response_with_nulls()
      t.truthy(wire:find("null", 1, true), "the fixture must really contain null")
      -- Feed the decoder exactly like the socket callback does, then dispatch
      -- through the production path.
      client.decoder:feed(wire .. "\n", function(line)
        local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
        t.truthy(ok)
        client:enqueue(message)
      end)
      client:schedule_drain()
      vim.wait(3000, function()
        return #decoded > 0
      end, 5)
      t.eq(1, #decoded)

      local nulls = find_nil(decoded[1], "message", {})
      t.eq({}, nulls, "vim.NIL leaked into the decoded message: " .. table.concat(nulls, ", "))
      -- A null scalar becomes nil.
      t.eq(nil, decoded[1].result.configOptions)
      t.eq(nil, decoded[1].result.modes)
      t.eq(nil, decoded[1].result.capabilities.images)
      -- A null array element becomes a hole, not a value: this is exactly what
      -- the direct transport produces with the same options, and the reason
      -- both paths must decode identically.
      t.eq(nil, decoded[1].result.capabilities.tools[1])
      t.eq("read", decoded[1].result.capabilities.tools[2])
    end)

    t.it("comes through the real socket without vim.NIL", function()
      -- The unit above hand-decodes; this one proves the production reader
      -- (`Client:read_loop`) uses the same options by pushing a frame over a
      -- real unix socket.
      local service, dir = start_service({ no_agent = true })
      local connection, ok, err = connect(service, dir)
      t.truthy(ok, tostring(err))
      local received = {}
      local client = require("ade.service.client").new({ timeout = 2000 })
      t.cleanup(function()
        client:close()
      end)
      client.paths = {
        dir = dir,
        socket = service:socket(),
        token = dir .. "/nvim_ade_server.token",
        pipe = false,
      }
      local connected = false
      client.pipe = vim.uv.new_pipe(false)
      client.pipe:connect(service:socket(), function(connect_err)
        connected = connect_err == nil
      end)
      vim.wait(3000, function()
        return connected
      end, 10)
      t.truthy(connected)
      client.rpc = {
        handle = function(_, message)
          received[#received + 1] = message
        end,
        close = function() end,
      }
      client.ready = true
      client:read_loop()
      local peer = service.clients[#service.clients]
      t.truthy(peer, "the fake service did not accept the connection")
      -- The tunnel envelope carries the raw JSON text of the ACP message.
      peer.peer:write(
        '{"jsonrpc":"2.0","method":"tunnel.recv","params":{"instance":"inst-1","seq":1,"message":'
          .. response_with_nulls()
          .. "}}\n"
      )
      vim.wait(5000, function()
        return #received > 0
      end, 10)
      t.eq(1, #received)
      local nulls = find_nil(received[1], "message", {})
      t.eq({}, nulls, "vim.NIL leaked through the socket: " .. table.concat(nulls, ", "))
      client:close()
      service:close()
    end)
  end)
end
