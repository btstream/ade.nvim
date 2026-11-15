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
  end)
end
