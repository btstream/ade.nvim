-- Wiring tests: the S1b features have to work through `ade.setup`, not only
-- when their modules are constructed by hand.
--
-- Every defect these tests exist for was invisible to the unit suite because it
-- tested the module in isolation:
--
--   * restore read `entry.id` while the protocol says `sessionId`, and the
--     stand-in produced `id` too, so both agreed with each other and with
--     nothing else;
--   * automatic reconnection subscribed to the app-level connection object,
--     which has no `subscribe`, behind a `type(...) == "function"` guard that
--     skipped the whole block silently;
--   * `created = false` was swallowed by an `and/or` before it reached the
--     restore gate;
--   * `version_check` reported through a `notify` the connection never had.
--
-- So the rule here: build the plugin with `ade.setup`, drive it through public
-- entry points and the stand-in service, and assert on the visible result.
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local Framing = require("ade.transport.framing")
  local controller = require("ade.controller")
  local ade = require("ade")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-wiring-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  ---A stand-in service that runs a real `tests/mock_agent.py` child.
  local function start_service(tag, opts)
    local dir = tmpdir(tag)
    local service = fake.new(vim.tbl_extend("force", { dir = dir }, opts or {}))
    local jobs = {}
    service.spawn_agent = function(instance)
      local decoder = Framing.new_decoder()
      local job = vim.fn.jobstart({ "python3", root .. "tests/mock_agent.py" }, {
        stdin = "pipe",
        stdout_buffered = false,
        on_stdout = function(_, data)
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
      jobs[#jobs + 1] = job
      instance.handler = function(message)
        pcall(vim.fn.chansend, job, vim.json.encode(message) .. "\n")
      end
      instance.stop_agent = function()
        pcall(vim.fn.jobstop, job)
      end
      return job > 0
    end
    assert(service:listen(), "the stand-in service could not listen")
    return service, dir, jobs
  end

  ---Install an isolated service connection and `ade.setup` over it.
  ---
  ---The connection is the real `ade.service.connection`; only "is a service
  ---running" is answered affirmatively, because the stand-in is a Lua socket
  ---rather than a process the launcher could start.
  local function setup(tag, service, dir, overrides)
    local saved_dir = vim.env.NVIM_ADE_SERVER_DIR
    vim.env.NVIM_ADE_SERVER_DIR = dir
    local connection = ServiceConnection.new({
      resolve_binary = function()
        return { path = "/fake/nvim_ade_server", version = Version.VERSION, api_version = Version.API_VERSION }
      end,
      ensure_service = function()
        return true
      end,
      timeout = 3000,
    })
    local previous = ServiceConnection.shared()
    ServiceConnection.set_shared(connection)
    t.cleanup(function()
      pcall(connection.close, connection, "test over")
      ServiceConnection.set_shared(previous)
      vim.env.NVIM_ADE_SERVER_DIR = saved_dir
      pcall(function()
        require("ade.service.commands").kill_all({ notify = function() end })
      end)
    end)
    ade.setup(vim.tbl_deep_extend("force", {
      backend = "service",
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      service = { keep_alive = true, idle_timeout = 60, reconnect_attempts = 3 },
      ui = {},
      layout = { input_height = 6 },
    }, overrides or {}))
    return connection
  end

  local function state()
    return controller.state()
  end

  local function wait(cond, timeout, label)
    local ok = vim.wait(timeout or 20000, cond, 20)
    if not ok then
      error("timed out: " .. (label or "condition"), 2)
    end
  end

  local function wait_ready()
    wait(function()
      local S = state()
      return S.conn.phase == "ready" and S.sess.current ~= nil
    end, 25000, "the panel is ready over the stand-in service")
  end

  ---Run `fn` from a libuv callback, which is the fast event context a real
  ---socket EOF arrives in. Editor APIs raise there, so this is how a test can
  ---tell whether the drop path is fast-context safe.
  local function fast_call(fn)
    local timer = vim.uv.new_timer()
    timer:start(10, 0, function()
      timer:close()
      fn()
    end)
  end

  local function messages()
    return (vim.api.nvim_exec2("messages", { output = true }) or {}).output or ""
  end

  local function occurrences(text, needle)
    local count, index = 0, 1
    while true do
      local start = text:find(needle, index, true)
      if not start then
        return count
      end
      count = count + 1
      index = start + #needle
    end
  end

  ---Capture `vim.notify` for one test, restoring it in cleanup.
  ---@return table notices
  ---@return fun(): string joined
  local function capture(t)
    local notices = {}
    local original = vim.notify
    vim.notify = function(message, level)
      notices[#notices + 1] = { message = tostring(message), level = level }
    end
    t.cleanup(function()
      vim.notify = original
    end)
    return notices,
      function()
        local lines = {}
        for _, note in ipairs(notices) do
          lines[#lines + 1] = note.message
        end
        return table.concat(lines, "\n")
      end
  end

  t.describe("S1b wiring through ade.setup", function()
    t.it("reconnects automatically when the service connection drops", function()
      local service, dir = start_service("reconnect")
      local connection = setup("reconnect", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local before = S.sess.current.id

      t.truthy(S.conn.reconnector, "the panel has no reconnector at all")
      -- Count attempts through the real object. Instrumenting it is not the
      -- same as replacing it: the wiring under test (the `__disconnected`
      -- subscription) still has to call into it.
      local attempts = 0
      local original = S.conn.reconnector.attempt_once
      S.conn.reconnector.attempt_once = function(self)
        attempts = attempts + 1
        return original(self)
      end

      -- The real drop path: the shared connection reports it to every listener.
      connection:on_disconnect("socket closed by the test")

      -- The badge must be up as soon as the drop is known. The first retry
      -- waits out the 0.5 s backoff, and a service that starts quickly would
      -- otherwise clear the status before anyone can see it.
      t.match("reconnecting", S.conn.reconnect_status or "", "the reconnecting badge must appear at once")

      -- Wait for the panel to *notice* first. Waiting for "ready" straight
      -- away would pass before the drop was even delivered, which is exactly
      -- how the missing subscription stayed invisible.
      wait(function()
        return S.conn.phase ~= "ready"
      end, 10000, "the panel noticed the drop")
      wait(function()
        return S.conn.phase == "ready"
      end, 25000, "the panel reconnected by itself (no :Ade reconnect was run)")
      wait(function()
        return S.sess.current ~= nil
      end, 25000, "the session came back")
      t.truthy(attempts > 0, "no reconnect attempt was made: __disconnected is not subscribed")
      t.eq(before, S.sess.current.id, "the reconnect must restore the same session")
      t.eq(nil, S.conn.reconnect_status, "the reconnecting badge must be cleared")
      controller.hide()
    end)

    t.it("reports reconnected before the restore step that follows it", function()
      local service, dir = start_service("notify-order")
      local connection = setup("notify-order", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local _, text = capture(t)

      -- `Reconnector:attempt_once` reports "reconnected" and then runs the
      -- reconnect flow, whose session restore reports synchronously in the
      -- same tick. The two must keep that order — scheduling the loop's own
      -- notification unconditionally would push it behind the restore notice.
      local original = S.conn.reconnector.deps.reconnect
      S.conn.reconnector.deps.reconnect = function()
        original()
        vim.notify("ade.nvim: restored session after reconnect", vim.log.levels.INFO)
      end
      t.cleanup(function()
        S.conn.reconnector.deps.reconnect = original
      end)

      service:drop(service.clients[1])
      wait(function()
        return text():find("restored session after reconnect", 1, true) ~= nil
      end, 15000, "the reconnect follow-up")
      local body = text()
      local reconnected = body:find("reconnected", 1, true)
      local restored = body:find("restored session after reconnect", 1, true)
      t.truthy(
        reconnected and restored and reconnected < restored,
        "reconnected must be reported before the restore step: " .. body
      )
      controller.hide()
    end)

    t.it("a late shutdown reply that ends the service is still a deliberate stop", function()
      local service, dir = start_service("shutdown-late", {
        shutdown_delay_ms = 400,
        shutdown_closes = true,
      })
      local connection = setup("shutdown-late", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local _, text = capture(t)

      local calls = {}
      connection:shutdown(function(ok, value)
        calls[#calls + 1] = { ok = ok, value = value }
      end, 100)
      wait(function()
        return #calls == 1
      end, 1000, "the timed-out shutdown to report")
      t.falsy(calls[1].ok, "an unconfirmed shutdown must not claim success")
      t.truthy(type(calls[1].value) == "table" and calls[1].value.pending, "the timeout is 'pending', not a refusal")
      t.truthy(connection:is_connected(), "a pending stop must leave the live socket attached")

      -- The late success reply closes the service; that disconnect belongs to
      -- the stop and must not start a retry loop.
      wait(function()
        return not connection:is_connected()
      end, 5000, "the service to close after its late reply")
      vim.wait(2000)
      t.eq(1, #calls, "the late shutdown reply called the callback twice")
      t.falsy(S.conn.reconnector:is_running(), "a late reply must not start a retry loop")
      t.falsy(
        text():find("reconnecting", 1, true) or text():find("reconnected", 1, true),
        "a deliberate stop must not report a reconnect: " .. text()
      )
      controller.hide()
    end)

    t.it("a refused shutdown keeps the connection and reconnects after a later drop", function()
      local service, dir = start_service("shutdown-refused", {
        shutdown_error = { code = -32000, message = "cannot stop while a turn is running" },
      })
      local connection = setup("shutdown-refused", service, dir)
      ade.open()
      wait_ready()
      local S = state()

      local calls = {}
      connection:shutdown(function(ok, value)
        calls[#calls + 1] = { ok = ok, value = value }
      end, 2000)
      wait(function()
        return #calls == 1
      end, 5000, "the refused shutdown to report")
      t.falsy(calls[1].ok)
      t.falsy(type(calls[1].value) == "table" and calls[1].value.pending, "a refusal is not a timeout")
      t.truthy(connection:is_connected(), "a refused stop must keep the live client usable")

      -- The service is still there; a later real drop is an accident again.
      service:drop(service.clients[1])
      wait(function()
        return S.conn.reconnector:is_running()
      end, 5000, "the retry loop after the real drop")
      -- Wait for the attempt itself: the panel may still be "ready" from
      -- before the drop until the scheduled loss handler runs.
      wait(function()
        return not S.conn.reconnector:is_running()
      end, 20000, "the reconnect loop to finish")
      wait_ready()
      controller.hide()
    end)

    t.it("a service that exits while the stop waits is a deliberate stop", function()
      local service, dir = start_service("shutdown-eof", { shutdown_eof = true })
      local connection = setup("shutdown-eof", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local _, text = capture(t)

      local calls = {}
      connection:shutdown(function(ok, value)
        calls[#calls + 1] = { ok = ok, value = value }
      end, 3000)
      wait(function()
        return #calls == 1
      end, 5000, "the shutdown that ended in EOF to report")
      t.truthy(calls[1].ok, "EOF because the service exited is the stop succeeding")
      wait(function()
        return not connection:is_connected()
      end, 3000, "the connection to notice the socket is gone")
      vim.wait(1500)
      t.falsy(S.conn.reconnector:is_running(), "EOF caused by the stop must not start a retry loop")
      t.falsy(
        text():find("reconnecting", 1, true) or text():find("reconnected", 1, true),
        "a deliberate stop must not report a reconnect: " .. text()
      )
      controller.hide()
    end)

    t.it(":Ade service stop cancels a reconnect that is waiting to retry", function()
      local service, dir = start_service("stop-during-backoff")
      local connection = setup("stop-during-backoff", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      t.cleanup(function()
        vim.notify = original_notify
      end)

      -- Unexpected drop: the loop is now between attempts, so the shared
      -- connection has no socket and the stop command takes its one-shot path.
      service:drop(service.clients[1])
      wait(function()
        return S.conn.reconnector:is_running()
      end, 5000, "the drop to start the retry loop")
      require("ade.service.commands").dispatch("stop", {})
      wait(function()
        return not S.conn.reconnector:is_running()
      end, 5000, "the stop command to cancel the pending retry")
      t.eq(0, S.conn.reconnector.attempt, "no attempt may happen after a deliberate stop")

      -- The cancelled timer must not restart the loop later.
      vim.wait(1500)
      t.falsy(S.conn.reconnector:is_running(), "the loop restarted after a deliberate stop")
      local joined = {}
      for _, note in ipairs(notices) do
        joined[#joined + 1] = tostring(note.message)
      end
      local text = table.concat(joined, "\n")
      t.falsy(
        text:find("reconnecting", 1, true) or text:find("reconnected", 1, true),
        "a deliberate stop must not report a reconnect: " .. text
      )
      controller.hide()
    end)

    t.it(":Ade service stop during a reconnect attempt stops that attempt's service", function()
      -- The handshake is slow, so the retry's `ensure()` is still connecting
      -- when the user stops: cancelling the loop alone would let that attempt
      -- finish, and the one-shot stop client would then close the service the
      -- shared connection just attached to — EOF with no intent → reconnect.
      local service, dir = start_service("stop-during-ensure", {
        hello_delay_ms = 300,
        shutdown_closes = true,
      })
      local connection = setup("stop-during-ensure", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local notices = capture(t)

      local stopped, mark = false, 0
      service:drop(service.clients[1])
      wait(function()
        return S.conn.reconnector:is_running()
      end, 5000, "the drop to start the retry loop")

      -- Run the command from the moment the retry actually owns the
      -- connection (`connecting`), not from a guessed delay.
      local poll = vim.uv.new_timer()
      t.cleanup(function()
        if not poll:is_closing() then
          poll:stop()
          poll:close()
        end
      end)
      poll:start(0, 5, function()
        if connection.connecting then
          poll:stop()
          poll:close()
          vim.schedule(function()
            -- The attempt has already announced "reconnecting (1/3)" before
            -- it started connecting; only later messages can be a bug.
            mark = #notices
            require("ade.service.commands").dispatch("stop", {
              on_done = function(ok)
                stopped = ok
              end,
            })
          end)
        end
      end)

      wait(function()
        return stopped
      end, 15000, "the stop command to finish")
      vim.wait(2000)
      t.falsy(S.conn.reconnector:is_running(), "the retry loop must stay stopped")
      local after = {}
      for index = mark + 1, #notices do
        after[#after + 1] = notices[index].message
      end
      local body = table.concat(after, "\n")
      t.falsy(
        body:find("reconnecting", 1, true) or body:find("reconnected", 1, true),
        "stopping during an attempt must not report a reconnect: " .. body
      )
      controller.hide()
    end)

    t.it("says it gave up from the socket callback where vim.notify would raise", function()
      local service, dir = start_service("fast-notify")
      local connection = setup("fast-notify", service, dir, {
        service = { keep_alive = true, idle_timeout = 60, reconnect_attempts = 1 },
      })
      ade.open()
      wait_ready()
      local S = state()

      -- One successful retry uses the only attempt; the next loss within the
      -- 60 s stability window reaches the give-up branch in `lost()`, which is
      -- exactly the code a real EOF runs in a fast event context.
      fast_call(function()
        connection:on_disconnect("first drop")
      end)
      wait(function()
        return S.conn.reconnector.attempt == 1 and not S.conn.reconnector:is_running()
      end, 15000, "the first retry to finish")

      local before = occurrences(messages(), "keeps disconnecting")
      fast_call(function()
        connection:on_disconnect("second drop")
      end)
      wait(function()
        return occurrences(messages(), "keeps disconnecting") > before
      end, 5000, "the give-up notice to reach :messages")
      controller.hide()
    end)

    t.it("does not reconnect after :Ade service stop", function()
      local service, dir = start_service("intentional")
      local connection = setup("intentional", service, dir)
      ade.open()
      wait_ready()
      local S = state()

      -- `shutdown` is the `:Ade service stop` path: it marks the loss as
      -- intentional and closes the socket, which fires the same fan-out.
      local answered = false
      connection:shutdown(function()
        answered = true
      end)
      vim.wait(5000, function()
        return answered
      end, 20)
      vim.wait(1500)
      t.falsy(S.conn.reconnector:is_running(), "stopping the service must not start a retry loop")
      t.eq(0, S.conn.reconnector.attempt, "no attempt may be made after a deliberate stop")
      controller.hide()
    end)

    t.it(":Ade service stop itself never starts a retry loop", function()
      -- The direct `connection:shutdown` call above is not the user's path:
      -- the command used to open a *second* client, so the shared connection
      -- the panel listens on saw EOF with no intent and reconnected. Drive the
      -- command body the plugin calls, with the same wiring `ade.setup` built.
      local service, dir = start_service("cmd-stop")
      local connection = setup("cmd-stop", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      t.cleanup(function()
        vim.notify = original_notify
      end)

      require("ade.service.commands").dispatch("stop", {})
      wait(function()
        return not connection:is_connected()
      end, 5000, "the command to stop the service")
      vim.wait(1500)
      local joined = {}
      for _, note in ipairs(notices) do
        joined[#joined + 1] = tostring(note.message)
      end
      local text = table.concat(joined, "\n")
      t.falsy(
        text:find("reconnecting", 1, true) or text:find("reconnected", 1, true),
        "a deliberate stop must not report a reconnect: " .. text
      )
      t.falsy(S.conn.reconnector:is_running(), "stopping the service must not start a retry loop")
      t.eq(0, S.conn.reconnector.attempt, "no attempt may be made after a deliberate stop")
      controller.hide()
    end)

    t.it("stops after a crash loop instead of retrying forever", function()
      local service, dir = start_service("crashloop")
      local connection = setup("crashloop", service, dir, {
        service = { keep_alive = true, idle_timeout = 60, reconnect_attempts = 2 },
      })
      ade.open()
      wait_ready()
      local S = state()
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end

      -- Each "reconnect" makes the next drop happen at once: connect, then die.
      local drops = 0
      local original_ready = S.conn.service.on_ready
      S.conn.service.on_ready = function(...)
        if drops > 0 and drops <= 4 then
          vim.schedule(function()
            drops = drops + 1
            connection:on_disconnect("the fresh connection died too")
          end)
        end
        return original_ready and original_ready(...)
      end

      drops = 1
      connection:on_disconnect("first drop")
      local ok, err = pcall(function()
        vim.wait(20000, function()
          return not S.conn.reconnector:is_running() and drops >= 3
        end, 20)
      end)
      vim.notify = original_notify
      S.conn.service.on_ready = original_ready
      t.truthy(ok, tostring(err))
      local joined = {}
      for _, note in ipairs(notices) do
        joined[#joined + 1] = tostring(note.message)
      end
      local text = table.concat(joined, "\n")
      -- The crash-loop guard: after the attempts are used up it says so, and
      -- does not start another endless round.
      t.match("keeps disconnecting", text)
      t.falsy(S.conn.reconnector:is_running(), "the loop must stop")
      t.truthy(S.conn.reconnector.attempt >= 2, "the attempts were not used")
      controller.hide()
    end)

    t.it("does not reconnect after :Ade disconnect", function()
      local service, dir = start_service("disconnect")
      setup("disconnect", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      controller.disconnect()
      vim.wait(1500)
      t.falsy(S.conn.reconnector:is_running(), "an explicit disconnect must not start a retry loop")
      t.eq("stopped", S.conn.phase)
      controller.hide()
    end)

    t.it("marks an adopted turn running and settles it", function()
      local service, dir = start_service("adopt")
      setup("adopt", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local id = S.sess.current.id
      local instance = nil
      for _, record in pairs(service.instances) do
        instance = record.id
      end
      t.truthy(instance, "the stand-in has no instance")

      t.truthy(service:adopt(instance, id), "the stand-in could not adopt")
      wait(function()
        return S.sess.current and S.sess.current.status == "running"
      end, 10000, "the adopted turn made the session look running")
      t.truthy(S.conn.adoption:is_adopted(id))

      t.truthy(service:finish_adopted(instance, id, "end_turn"))
      wait(function()
        return S.sess.current and S.sess.current.status == "idle"
      end, 10000, "the adopted turn ended")
      t.falsy(S.conn.adoption:is_adopted(id))
      controller.hide()
    end)

    t.it("restores the session the service still holds", function()
      local service, dir = start_service("restore")
      local connection = setup("restore", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local first = S.sess.current.id
      local instance = nil
      for _, record in pairs(service.instances) do
        instance = record.id
      end
      t.truthy(instance)

      -- A service that keeps the session after the editor left (PROTOCOL 3.2).
      service:track_session(instance, {
        sessionId = first,
        cwd = S.sess.current.cwd or root,
        running = false,
        updated_at = os.time() * 1000,
      })

      -- A fresh front end over the same instance: `created = false`, so the
      -- restore gate must open and the reported `sessionId` must be loaded.
      connection:close("test front end leaving")
      local saving = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir
      local fresh = ServiceConnection.new({
        resolve_binary = function()
          return { path = "/fake/nvim_ade_server", version = Version.VERSION, api_version = Version.API_VERSION }
        end,
        ensure_service = function()
          return true
        end,
        timeout = 3000,
      })
      ServiceConnection.set_shared(fresh)
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      local ok, err = pcall(function()
        ade.setup({
          backend = "service",
          agent = "opencode",
          agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
          service = { keep_alive = true, idle_timeout = 60, restore = true },
          ui = {},
          layout = { input_height = 6 },
        })
        ade.open()
        wait_ready()
      end)
      vim.notify = original_notify
      vim.env.NVIM_ADE_SERVER_DIR = saving
      t.truthy(ok, tostring(err))
      local restored = state().sess.current
      t.truthy(restored)
      t.eq(first, restored.id, "the reported session was not reopened")
      local joined = {}
      for _, note in ipairs(notices) do
        joined[#joined + 1] = note.message
      end
      t.match("restored session " .. vim.pesc(first), table.concat(joined, "\n"))
      controller.hide()
    end)

    t.it("reports the version restart to the user", function()
      local hellos = 0
      local service, dir = start_service("version", {
        -- The first hello describes an old build. Before the second one —
        -- the restart's own connection — the stand-in reports this plugin's
        -- version, exactly like a service replaced by a new binary.
        server_version = Version.VERSION .. "-old",
      })
      service.on_hello = function()
        hellos = hellos + 1
        if hellos >= 2 then
          service.server_version = Version.VERSION
        end
      end
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      local ok, err = pcall(function()
        setup("version", service, dir)
        ade.open()
        wait_ready()
      end)
      vim.notify = original_notify
      t.truthy(ok, tostring(err))
      local joined = {}
      for _, note in ipairs(notices) do
        joined[#joined + 1] = note.message
      end
      local text = table.concat(joined, "\n")
      t.match("restarting nvim_ade_server", text)
      t.match("idle agent", text)
      controller.hide()
    end)
    t.it("does not forget the session when the editor exits by detaching", function()
      local service, dir = start_service("exit")
      setup("exit", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local instance_id
      for _, record in pairs(service.instances) do
        instance_id = record.id
      end
      t.truthy(instance_id, "the stand-in has no instance")
      t.truthy(S.conn.client, "no client to ask")
      -- The application layer must be able to ask the real client, not just a
      -- hand-built stand-in: `Sessions:close_all_on_exit` used to look for a
      -- method only the transport channel had, so it always decided "stop".
      t.truthy(S.conn.client:will_detach(), "the service client must report that it detaches")

      -- The real exit hook: the panel's VimLeavePre autocmd (window.lua). It
      -- closes the sessions before leaving, which is exactly what must be
      -- skipped for a detachable exit (PROTOCOL.md 11: close means forget).
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = S.view.panel.augroup })
      vim.wait(3000, function()
        local record = service.instances[instance_id]
        return record ~= nil and next(record.attached) == nil
      end, 20)

      local closed = {}
      for _, frame in ipairs(service.sent) do
        local message = frame.message or {}
        if message.method == "session/close" then
          closed[#closed + 1] = (message.params or {}).sessionId
        end
      end
      t.eq({}, closed, "exiting by detaching must not send session/close")
      -- The detach is what makes "keep the session" meaningful: the next editor
      -- finds the same instance and the same agent-side session.
      t.truthy(
        service.instances[instance_id] ~= nil and next(service.instances[instance_id].attached) == nil,
        "the editor must detach from the instance instead of stopping it"
      )
      controller.hide()
    end)

    t.it("adopts a turn announced before the load reply is committed", function()
      local service, dir = start_service("adoptrace")
      setup("adoptrace", service, dir)
      ade.open()
      wait_ready()
      local instance_id
      for _, record in pairs(service.instances) do
        instance_id = record.id
      end
      t.truthy(instance_id, "the stand-in has no instance")

      -- PROTOCOL.md 13: the service sends `_ade/turn_adopted` right after the
      -- `session/load` reply, before the front end has committed the replay.
      -- Deliver it *before* the reply here to exercise the worst ordering.
      local original = service.on_tunnel_send
      local raced = false
      service.on_tunnel_send = function(self, params, client)
        local message = params.message or {}
        if message.method == "session/load" and not raced then
          raced = true
          self:adopt(params.instance, (message.params or {}).sessionId)
        end
        original(self, params, client)
      end
      local ok, err = pcall(function()
        controller.load_session("sess_restored")
        wait(function()
          local current = state().sess.current
          return current ~= nil and current.id == "sess_restored"
        end, 10000, "the session was loaded")
      end)
      service.on_tunnel_send = original
      t.truthy(ok, tostring(err))
      t.truthy(raced, "the test did not exercise the race")
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.status == "running"
      end, 10000, "the adopted turn is running after its load")
      t.truthy(state().conn.adoption:is_adopted("sess_restored"))

      t.truthy(service:finish_adopted(instance_id, "sess_restored", "end_turn"))
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.status == "idle"
      end, 10000, "the adopted turn ended")
      t.falsy(state().conn.adoption:is_adopted("sess_restored"))
      controller.hide()
    end)

    t.it("adopts a turn announced after the load reply was sent", function()
      local service, dir = start_service("adoptraceafter")
      setup("adoptraceafter", service, dir)
      ade.open()
      wait_ready()
      local instance_id
      for _, record in pairs(service.instances) do
        instance_id = record.id
      end
      t.truthy(instance_id, "the stand-in has no instance")

      -- The service's actual order: reply first, then `_ade/turn_adopted`. Both
      -- still arrive before the replay coroutine resumes, so this reaches the
      -- same pending path.
      local original = service.on_tunnel_send
      local raced = false
      service.on_tunnel_send = function(self, params, client)
        original(self, params, client)
        local message = params.message or {}
        if message.method == "session/load" and not raced then
          raced = true
          self:adopt(params.instance, (message.params or {}).sessionId)
        end
      end
      local ok, err = pcall(function()
        controller.load_session("sess_after")
        wait(function()
          local current = state().sess.current
          return current ~= nil and current.id == "sess_after"
        end, 10000, "the session was loaded")
      end)
      service.on_tunnel_send = original
      t.truthy(ok, tostring(err))
      t.truthy(raced, "the test did not exercise the race")
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.status == "running"
      end, 10000, "the adopted turn is running after its load")
      t.truthy(state().conn.adoption:is_adopted("sess_after"))

      t.truthy(service:finish_adopted(instance_id, "sess_after", "end_turn"))
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.status == "idle"
      end, 10000, "the adopted turn ended")
      controller.hide()
    end)

    t.it("adopts onto the reloaded session, not the object commit replaced", function()
      local service, dir = start_service("adoptreload")
      setup("adoptreload", service, dir)
      ade.open()
      wait_ready()
      local instance_id
      for _, record in pairs(service.instances) do
        instance_id = record.id
      end
      t.truthy(instance_id, "the stand-in has no instance")

      -- First load commits `sess_reload` and leaves it idle.
      controller.load_session("sess_reload")
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.id == "sess_reload" and current.status == "idle"
      end, 10000, "the first load of the session")
      -- Loading an idle cached session replays it again, so `Runtime:stage`
      -- keeps the committed object visible in `sess.all` until commit. The
      -- adoption below must not land on that old object.
      local original = service.on_tunnel_send
      local raced = false
      service.on_tunnel_send = function(self, params, client)
        local message = params.message or {}
        if message.method == "session/load" and not raced then
          raced = true
          self:adopt(params.instance, (message.params or {}).sessionId)
        end
        original(self, params, client)
      end
      local ok, err = pcall(function()
        controller.load_session("sess_reload")
        -- Wait for the replay itself to settle: until commit the still-visible
        -- object is the old one, so checking "running" too early would pass
        -- against the object commit is about to replace.
        local started = vim.wait(2000, function()
          return state().conn.replaying == true
        end, 5)
        t.truthy(started, "the second load did not start a replay")
        wait(function()
          return state().conn.replaying == false
        end, 10000, "the reload settled")
        local current = state().sess.current
        t.eq("sess_reload", current and current.id, "the reloaded session must be current")
        t.eq("running", current and current.status, "the reloaded session adopted the turn")
      end)
      service.on_tunnel_send = original
      t.truthy(ok, tostring(err))
      t.truthy(raced, "the test did not exercise the race")
      t.truthy(state().conn.adoption:is_adopted("sess_reload"))

      t.truthy(service:finish_adopted(instance_id, "sess_reload", "end_turn"))
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.status == "idle"
      end, 10000, "the adopted turn ended")
      controller.hide()
    end)

    t.it("forgets a pending adoption when its load fails", function()
      local service, dir = start_service("adoptfail")
      setup("adoptfail", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local instance_id
      for _, record in pairs(service.instances) do
        instance_id = record.id
      end
      t.truthy(instance_id, "the stand-in has no instance")
      local id = S.sess.current.id

      -- Emit an adoption and then let the load fail: the adoption belongs to a
      -- session that never arrives and must not survive to the next load. The
      -- mock agent rejects a load whose cwd differs from the session's, which is
      -- a real agent-side error, not a synthetic reply.
      local original = service.on_tunnel_send
      local raced = false
      service.on_tunnel_send = function(self, params, client)
        local message = params.message or {}
        if message.method == "session/load" and not raced then
          raced = true
          self:adopt(params.instance, (message.params or {}).sessionId)
        end
        original(self, params, client)
      end
      local good_cwd = S.sess.cwds[id]
      S.sess.cwds[id] = "/tmp/ade-adopt-failure-elsewhere"
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      local failed = false
      local ok, err = pcall(function()
        controller.load_session(id)
        failed = vim.wait(10000, function()
          for _, line in ipairs(notices) do
            if line:find("unable to load the session", 1, true) then
              return true
            end
          end
          return false
        end, 20)
      end)
      vim.notify = original_notify
      service.on_tunnel_send = original
      t.truthy(ok, tostring(err))
      t.truthy(raced, "the test did not exercise the failure race")
      t.truthy(failed, "the failed load was not reported: " .. table.concat(notices, "\n"))
      local adoption = state().conn.adoption
      t.eq(nil, adoption.pending[id], "a failed load must drop its pending adoption")
      -- The next load is only accepted once the failed replay has settled.
      t.truthy(
        vim.wait(5000, function()
          return state().conn.replaying == false
        end, 20),
        "the failed replay must release the replaying flag"
      )

      -- The same session loads again, with no adoption from the service: it must
      -- stay idle instead of applying the stale one.
      S.sess.cwds[id] = good_cwd
      controller.load_session(id)
      t.truthy(
        vim.wait(3000, function()
          return state().conn.replaying == true
        end, 5),
        "the second load did not start a replay"
      )
      t.truthy(
        vim.wait(10000, function()
          return state().conn.replaying == false
        end, 20),
        "the second replay did not settle"
      )
      local current = state().sess.current
      t.eq(id, current and current.id, "the second load must make the session current")
      t.eq("idle", current and current.status, "the second load must leave the session idle")
      t.falsy(adoption:is_adopted(id))
      local loads = 0
      for _, frame in ipairs(service.sent) do
        if (frame.message or {}).method == "session/load" then
          loads = loads + 1
        end
      end
      t.eq(2, loads, "the service must have received both load attempts")
      controller.hide()
    end)

    t.it("keeps a reloaded session idle when its turn finished before commit", function()
      local service, dir = start_service("adoptfinish")
      setup("adoptfinish", service, dir)
      ade.open()
      wait_ready()
      local instance_id
      for _, record in pairs(service.instances) do
        instance_id = record.id
      end
      t.truthy(instance_id, "the stand-in has no instance")

      -- First load commits the session; the service then adopts a turn so the
      -- old object is running and marked adopted.
      controller.load_session("sess_cycle")
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.id == "sess_cycle" and current.status == "idle"
      end, 10000, "the first load of the session")
      t.truthy(service:adopt(instance_id, "sess_cycle"))
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.status == "running"
      end, 10000, "the first adopted turn to run")

      -- A running cached session would just be activated; force the replay path
      -- that a reconnect/restore takes.
      state().sess.all["sess_cycle"].needs_load = true
      local original = service.on_tunnel_send
      local raced = false
      service.on_tunnel_send = function(self, params, client)
        local message = params.message or {}
        if message.method == "session/load" and not raced then
          raced = true
          local sid = (message.params or {}).sessionId
          -- The service re-announces the adoption for this load and the turn
          -- finishes before the replay commits.
          self:adopt(params.instance, sid)
          self:finish_adopted(params.instance, sid, "end_turn")
        end
        original(self, params, client)
      end
      local ok, err = pcall(function()
        controller.load_session("sess_cycle")
        t.truthy(
          vim.wait(2000, function()
            return state().conn.replaying == true
          end, 5),
          "the reload did not start a replay"
        )
        wait(function()
          return state().conn.replaying == false
        end, 10000, "the reload settled")
      end)
      service.on_tunnel_send = original
      t.truthy(ok, tostring(err))
      t.truthy(raced, "the test did not exercise the finish-before-commit race")
      local current = state().sess.current
      t.eq("sess_cycle", current and current.id, "the reloaded session must be current")
      t.eq(
        "idle",
        current and current.status,
        "a turn that finished before commit must not leave the reloaded session running"
      )
      t.falsy(state().conn.adoption:is_adopted("sess_cycle"))
      controller.hide()
    end)

    t.it("settles the old adopted turn when its reload fails after the finish", function()
      local service, dir = start_service("adoptfinishfail")
      setup("adoptfinishfail", service, dir)
      ade.open()
      wait_ready()
      local S = state()
      local instance_id
      for _, record in pairs(service.instances) do
        instance_id = record.id
      end
      t.truthy(instance_id, "the stand-in has no instance")

      -- The session the editor created: the mock agent knows its cwd, so a
      -- load under a different cwd is a real agent-side error.
      local id = S.sess.current.id
      t.truthy(service:adopt(instance_id, id))
      wait(function()
        local current = state().sess.current
        return current ~= nil and current.status == "running"
      end, 10000, "the first adopted turn to run")

      -- Reload: the service re-announces the adoption, the turn finishes before
      -- commit, and then the load itself fails (real agent error, cwd mismatch).
      state().sess.all[id].needs_load = true
      local good_cwd = S.sess.cwds[id]
      S.sess.cwds[id] = "/tmp/ade-adopt-finish-failure"
      local original = service.on_tunnel_send
      local raced = false
      service.on_tunnel_send = function(self, params, client)
        local message = params.message or {}
        if message.method == "session/load" and not raced then
          raced = true
          local sid = (message.params or {}).sessionId
          self:adopt(params.instance, sid)
          self:finish_adopted(params.instance, sid, "end_turn")
        end
        original(self, params, client)
      end
      local ok, err = pcall(function()
        controller.load_session(id)
        t.truthy(
          vim.wait(2000, function()
            return state().conn.replaying == true
          end, 5),
          "the reload did not start a replay"
        )
        wait(function()
          return state().conn.replaying == false
        end, 10000, "the failed reload settled")
      end)
      service.on_tunnel_send = original
      S.sess.cwds[id] = good_cwd
      t.truthy(ok, tostring(err))
      t.truthy(raced, "the test did not exercise the finish-before-failure race")
      local current = state().sess.current
      t.eq(id, current and current.id, "the old session must stay current")
      t.eq("idle", current and current.status, "the consumed finish must settle the old object")
      t.falsy(state().conn.adoption:is_adopted(id))
      controller.hide()
    end)

    t.it("drops a cancelled load's staging record and pending adoption", function()
      local service, dir = start_service("adoptcancel")
      setup("adoptcancel", service, dir)
      ade.open()
      wait_ready()

      local original = service.on_tunnel_send
      local loads = 0
      service.on_tunnel_send = function(self, params, client)
        local message = params.message or {}
        if message.method == "session/load" then
          loads = loads + 1
          if loads == 1 then
            self:adopt(params.instance, (message.params or {}).sessionId)
            -- Hold the reply until after the replay has been cancelled; it then
            -- arrives for a task the scope no longer owns.
            vim.defer_fn(function()
              original(self, params, client)
            end, 100)
            return
          end
        end
        original(self, params, client)
      end
      local ok, err = pcall(function()
        local service_obj = state().sess.service
        service_obj:replay("sess_cancel_one", {})
        t.truthy(
          vim.wait(3000, function()
            return loads >= 1
          end, 10),
          "the first load did not reach the service"
        )
        -- Starting the same key again is how the scope cancels an in-flight
        -- replay (`Scope:run` cancels the previous task): cancel, then load
        -- again immediately. The public load path refuses while a replay is in
        -- flight, so the replacement is made directly.
        service_obj:replay("sess_cancel_two", {})
        t.truthy(
          vim.wait(3000, function()
            return state().sess.runtime.replays["sess_cancel_one"] == nil
          end, 20),
          "a cancelled load must drop its staging record"
        )
        t.eq(nil, state().conn.adoption.pending["sess_cancel_one"], "a cancelled load must drop its pending adoption")
      end)
      service.on_tunnel_send = original
      t.truthy(ok, tostring(err))
      controller.hide()
    end)
  end)
end
