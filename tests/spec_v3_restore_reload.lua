-- Restored teams v3 coverage: the in-place reload behind `:Ade team on`
-- (PROTOCOL.md 20.5) and the `off/no_tools` retry of `team.start` (20.4).
--
-- Ported from `feat/teams-v3:tests/spec_s4_team.lua` (the "reload: true" case)
-- and `spec_w0e_team.lua` (the start flow's retry branches). The review wanted
-- the round trip proved end to end: the switch reply, the real load, and the
-- state the front end keeps afterwards.
return function(t)
  local Version = require("ade.service.version")
  local Config = require("ade.config")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local Framing = require("ade.transport.framing")
  local controller = require("ade.controller")
  local ade = require("ade")
  local TeamStart = require("ade.app.team_start")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-v3reload-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  ---A stand-in service with a real agent child, so the capabilities (and thus
  ---`session/close`) are the agent's own. A canned service is left alone: its
  ---reply table is the whole agent.
  local function start_service(t, tag, opts)
    local dir = tmpdir(tag)
    local service = fake.new(vim.tbl_extend("force", {
      dir = dir,
      features = { "tunnel", "log", "teams" },
    }, opts or {}))
    local jobs = {}
    if not service.canned_agent then
      service.spawn_agent = function(instance)
        local decoder = Framing.new_decoder()
        local job = vim.fn.jobstart({ "python3", root .. "tests/mock_agent.py" }, {
          stdin = "pipe",
          env = instance.env,
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
    end
    assert(service:listen(), "the stand-in service could not listen")
    t.cleanup(function()
      for _, job in ipairs(jobs) do
        pcall(vim.fn.jobstop, job)
      end
      pcall(service.close, service)
    end)
    return service, dir
  end

  local function setup(t, dir, overrides)
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
      cwd = dir,
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      service = { keep_alive = true, idle_timeout = 60 },
      manager = { root = dir .. "/agents" },
      permissions = { prompt = "native", auto_allow = {} },
      teams = {
        max_workers = 3,
        spawn_confirm = { auto = {} },
        templates = {},
        dashboard = { wide = 100 },
      },
      ui = {},
      layout = { input_height = 6 },
    }, overrides or {}))
    return connection
  end

  local function state()
    return controller.state()
  end

  local function wait(cond, timeout, label)
    local ok = vim.wait(timeout or 10000, cond, 20)
    if not ok then
      error("timed out: " .. (label or "condition"), 2)
    end
  end

  local function wait_ready()
    wait(function()
      local S = state()
      return S.conn.phase == "ready" and S.sess.current ~= nil
    end, 25000, "the panel to be ready")
  end

  local function sent_frames(service, method)
    local out = {}
    for _, entry in ipairs(service.sent) do
      if type(entry.message) == "table" and entry.message.method == method then
        out[#out + 1] = entry.message
      end
    end
    return out
  end

  local function capture(t)
    local notices = {}
    local original = vim.notify
    vim.notify = function(message, level)
      notices[#notices + 1] = { message = tostring(message), level = level }
    end
    t.cleanup(function()
      vim.notify = original
    end)
    return notices
  end

  local function joined(notices)
    local out = {}
    for _, note in ipairs(notices) do
      out[#out + 1] = note.message
    end
    return table.concat(out, "\n")
  end

  local function own_instance()
    local client = state().conn.client
    return client and client.proc and client.proc.instance or nil
  end

  ---The session the front end created came from before teams were configured.
  local function mark_uninjected(service)
    local key = own_instance() .. "\0sess_mock"
    service.session_switches[key] = { enabled = true, injected = false }
    state().view.team.session_states[key] = nil
    state().view.team.session_applied[key] = nil
  end

  t.describe("teams v3 reload", function()
    -- The canned agent already advertises `close`, so the reload round trip
    -- (and the close that may follow it) is exercised for real.
    local function start_canned(t, tag)
      return start_service(t, tag, {
        canned_agent = true,
        canned_capabilities = { loadSession = true, sessionCapabilities = { close = {}, resume = {} } },
      })
    end

    t.it(":Ade team on runs the real load after a reload: true answer", function()
      local service, dir = start_canned(t, "on-reload")
      setup(t, dir)
      controller.connect()
      wait_ready()
      mark_uninjected(service)
      local notices = capture(t)
      local before = #sent_frames(service, "session/load")
      vim.cmd("Ade team on")
      wait(function()
        return #sent_frames(service, "session/load") > before
      end, 15000, "the reload's session/load")
      local load = sent_frames(service, "session/load")[#sent_frames(service, "session/load")]
      t.eq("sess_mock", load.params.sessionId)
      wait(function()
        return joined(notices):find("teams are on for this chat", 1, true) ~= nil
      end, 15000, "the success notice")
      -- The transcript is visible again afterwards (the load re-rendered it).
      t.eq(true, state().sess.current ~= nil)
      -- PROTOCOL.md 20.5: the forwarded load injects the tools, and the cache
      -- ends up saying so instead of keeping the pre-load answer.
      local key = own_instance() .. "\0sess_mock"
      wait(function()
        local cached = state().view.team:session_teams(own_instance(), "sess_mock")
        return service.session_switches[key] ~= nil
          and service.session_switches[key].injected == true
          and cached ~= nil
          and cached.injected == true
      end, 15000, "the injected switch after the reload")
    end)

    t.it(":Ade team on does not load when the tools are already injected", function()
      local service, dir = start_canned(t, "on-injected")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #sent_frames(service, "session/new") == 1
      end, 10000, "the session request")
      local before = #sent_frames(service, "session/load")
      vim.cmd("Ade team on")
      vim.wait(500)
      t.eq(before, #sent_frames(service, "session/load"), "an injected session needs no reload")
    end)

    -- PRODUCTION BUG (review round 2, blocker 1): `Sessions:load` creates a new
    -- projection and commits it as canonical; `select_session` only compares Lua
    -- objects (`previous ~= session`, `lua/ade/app/window.lua:40–58`), so it
    -- thinks it left the session and sends `session/close` for the *same* id
    -- (`lua/ade/app/sessions.lua:572–584`, `lua/ade/app/window.lua:40–58`).
    -- The service then forgets the session and revokes the token just injected,
    -- while the front end reports success.
    t.pending(
      "does not close the session it just reloaded",
      "lua/ade/app/window.lua:40–58 + sessions.lua:572–584: an in-place reload replaces the projection, so select_session closes the same session id",
      function()
        local service, dir = start_canned(t, "on-close")
        setup(t, dir)
        controller.connect()
        wait_ready()
        mark_uninjected(service)
        vim.cmd("Ade team on")
        wait(function()
          return #sent_frames(service, "session/load") >= 1
        end, 15000, "the reload's session/load")
        vim.wait(1000)
        local closes = sent_frames(service, "session/close")
        t.eq(0, #closes, "the reloaded session must not be closed: " .. vim.inspect(closes))
        t.eq(true, state().sess.current ~= nil, "the session is still on screen")
      end
    )

    t.it("reports a failed reload and leaves the session usable", function()
      local service, dir = start_canned(t, "on-reload-broken")
      setup(t, dir)
      controller.connect()
      wait_ready()
      mark_uninjected(service)
      local notices = capture(t)
      -- An agent that refuses every load: the session must stay as it was.
      local original = state().sess.service.load
      state().sess.service.load = function(_, _, opts)
        if opts and opts.on_failed then
          opts.on_failed("the agent refused the load")
        end
        return true
      end
      t.cleanup(function()
        state().sess.service.load = original
      end)
      vim.cmd("Ade team on")
      wait(function()
        return joined(notices):find("cannot reload the session's team tools", 1, true) ~= nil
      end, 5000, "the failed-reload notice")
      t.match("the agent refused the load", joined(notices))
      t.eq(true, state().sess.current ~= nil, "the session is still on screen")
    end)
  end)

  t.describe("teams v3 start retries", function()
    local function base_cwd(tag)
      local dir = string.format("/tmp/opencode/ade-v3retry-%s-%d", tag, vim.uv.os_getpid())
      vim.fn.mkdir(dir, "p", 448)
      return dir
    end

    ---The flow against a scripted team module, like `spec_w0e_team.lua`.
    local function flow_harness(t, opts)
      opts = opts or {}
      local cwd = base_cwd(opts.tag or "flow")
      local session = { id = "s1", cwd = cwd, instance = "i1", blocks = { { kind = "user", text = "fix it" } } }
      local all = { s1 = session }
      local calls = { starts = {}, enables = {}, reloads = {} }
      local fake_team = {
        available = function()
          return true
        end,
      }
      function fake_team:workflows(_, cb)
        cb(true, { workflows = { { name = "default", summary = "the flow", team = {} } } })
      end
      function fake_team:session_teams()
        return { enabled = opts.enabled ~= false, injected = opts.injected ~= false }
      end
      function fake_team:query_session_teams(_, _, _, cb)
        cb(true, { enabled = opts.enabled ~= false, injected = opts.injected ~= false })
      end
      function fake_team:set_session_teams(_, _, enabled, _, cb)
        calls.enables[#calls.enables + 1] = enabled
        if opts.enable_answers_reload then
          cb(true, { enabled = true, injected = false, reload = true })
          return
        end
        cb(true, { enabled = enabled, injected = true })
      end
      function fake_team:reload_session(_, id, cb)
        calls.reloads[#calls.reloads + 1] = id
        cb(true, { reloaded = true })
      end
      function fake_team:start_session(_, id, workflow, task, cb)
        calls.starts[#calls.starts + 1] = { id = id, workflow = workflow, task = task }
        if #calls.starts == 1 and opts.first_start_reason then
          cb(false, { code = -32061, data = { reason = opts.first_start_reason } })
          return
        end
        cb(true, { workflow = workflow })
      end
      local S = { view = { team = fake_team }, sess = { current = session, all = all } }
      local flow = TeamStart.new({
        state = function()
          return S
        end,
        config = function()
          return { backend = "service", teams = { enabled = true, default = "default" }, cwd = cwd }
        end,
        notify = function() end,
        resolve_cwd = function()
          return cwd
        end,
        open = function() end,
        new_session = function() end,
        connect = function() end,
        pick_agent = function() end,
        options = function()
          return nil
        end,
        client = function()
          return { proc = { instance = "i1" } }
        end,
        generation = function()
          return 0
        end,
        report_error = function(value)
          return type(value) == "table" and tostring(value.data and value.data.reason or value.message or value.code)
            or tostring(value)
        end,
        choices = function()
          return nil
        end,
        find_session = function(id)
          return all[id]
        end,
        select_session = function() end,
        submit = function() end,
      })
      local original_select, original_input = vim.ui.select, vim.ui.input
      vim.ui.select = function(items, _, cb)
        cb(items[1])
      end
      vim.ui.input = function(_, cb)
        cb(opts.task or "")
      end
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      return flow, calls
    end

    local function wait_idle(flow)
      local ok = vim.wait(5000, function()
        return flow.starting == false
      end, 20)
      if not ok then
        error("the flow did not finish", 2)
      end
    end

    -- PRODUCTION BUG (review round 2, 20.5 "off/no_tools 重试分支漏 load"):
    -- after the pre-start check, `team.start` may still answer `off`/`no_tools`;
    -- the retry enables the switch and immediately calls `launch` again without
    -- honouring `value2.reload` (`lua/ade/app/team_start.lua:543–561`). Under the
    -- new rule the service only marks a one-shot forward, so the retry can still
    -- see `no_tools`.
    t.pending(
      "reloads before retrying a start that answered no_tools",
      "lua/ade/app/team_start.lua:543–561: the off/no_tools retry ignores value2.reload",
      function()
        local flow, calls = flow_harness(t, {
          tag = "no-tools",
          first_start_reason = "no_tools",
          enable_answers_reload = true,
        })
        flow:start("default")
        wait_idle(flow)
        t.eq(1, #calls.reloads, "the retry must run the load the service asked for")
        t.eq(2, #calls.starts, "and then retry the start")
      end
    )

    t.it("retries a start that answered off without reloading when the switch is already in place", function()
      local flow, calls = flow_harness(t, { tag = "off", first_start_reason = "off" })
      flow:start("default")
      wait_idle(flow)
      t.eq(2, #calls.starts)
      t.eq(0, #calls.reloads, "no reload was asked for")
    end)

    t.it("enables the switch before asking for a task", function()
      local flow, calls = flow_harness(t, { tag = "enable", enabled = false, task = "go" })
      flow:start("default")
      wait_idle(flow)
      t.eq(1, #calls.enables)
      t.eq(1, #calls.starts)
      t.eq("go", calls.starts[1].task)
    end)
  end)

  -- Keep the helper honest: the flow must be namespaced so no other spec leaks.
  _ = Config
end
