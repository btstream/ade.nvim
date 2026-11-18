-- Teams: the front end's wiring (PROTOCOL.md section 18).
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local Config = require("ade.config")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")
  local Framing = require("ade.transport.framing")
  local async = require("ade.async")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-s4-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  local function start_service(t, tag, opts)
    local dir = tmpdir(tag)
    local service = fake.new(vim.tbl_extend("force", {
      dir = dir,
      features = { "tunnel", "log", "teams" },
    }, opts or {}))
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
    t.cleanup(function()
      for _, job in ipairs(jobs) do
        pcall(vim.fn.jobstop, job)
      end
      pcall(service.close, service)
    end)
    return service, dir
  end

  local function teams_config(over)
    return vim.tbl_deep_extend("force", {
      spawn_from_chat = true,
      max_workers = 3,
      spawn_confirm = { auto = {} },
      limits = { max_turns_per_task = 30, max_turns_total = 200 },
      templates = {
        worker = { agent = "opencode", role = "You are a worker. Report with bus_send." },
      },
    }, over or {})
  end

  local function setup(t, tag, service, dir, overrides)
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
      -- Pin the session cwd to this test's directory so team keys (bound,
      -- blocked) and the fake's team.cwd agree with what the front end uses.
      cwd = dir,
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      service = { keep_alive = true, idle_timeout = 60 },
      manager = { root = dir .. "/agents" },
      permissions = { prompt = "native", auto_allow = {} },
      teams = teams_config(),
      ui = {},
      layout = { input_height = 6 },
    }, overrides or {}))
    return connection
  end

  local function state()
    return controller.state()
  end

  local function team()
    return state().view.team
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
    end, 25000, "the panel to be ready")
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

  local function calls_of(service, method)
    local out = {}
    for _, call in ipairs(service.calls) do
      if call.method == method then
        out[#out + 1] = call
      end
    end
    return out
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

  t.describe("teams front end", function()
    t.it("validates the teams configuration at setup", function()
      local function validate(over)
        return Config.validate(vim.tbl_deep_extend("force", Config.defaults, over or {}))
      end
      local cfg = validate({ teams = teams_config() })
      t.eq(3, cfg.teams.max_workers)
      t.eq(160, cfg.teams.dashboard.wide)
      local named = validate({
        teams = teams_config({
          enabled = true,
          default = "dev",
          templates = {
            worker = { agent = "opencode", models = { "m1", "m2" }, worktree = true },
          },
          workflows = {
            dev = {
              summary = "two workers",
              text = "1. write 2. review",
              team = { { name = "w1", template = "worker", model = "m1", task = "T1" } },
              columns = { "todo", "review" },
            },
          },
        }),
      })
      t.eq("dev", named.teams.default)
      t.eq(true, named.teams.templates.worker.worktree)
      t.eq({ "m1", "m2" }, named.teams.templates.worker.models)
      t.eq("todo", named.teams.workflows.dev.columns[1])
      local no_role = validate({ teams = { templates = { worker = { agent = "opencode" } } } })
      t.eq(nil, no_role.teams.templates.worker.role)

      -- The old keys fail with the new syntax in the message (no migration).
      local old_errors = {}
      for _, over in ipairs({
        { teams = teams_config({ definitions = { dev = { workers = {} } } }) },
        { teams = teams_config({ workflow = "1. do things" }) },
      }) do
        local ok, err = pcall(validate, over)
        t.eq(false, ok, "an old teams key must be refused")
        old_errors[#old_errors + 1] = tostring(err)
      end
      t.match("teams.workflows", old_errors[1])
      t.match("teams.workflows", old_errors[2])

      -- A workflow cannot ask for more workers than teams.max_workers (19.1):
      -- team.start would refuse all of them, so setup fails early and names
      -- the workflow and both numbers.
      local ok, err = pcall(validate, {
        teams = teams_config({
          workflows = {
            dev = {
              summary = "x",
              team = {
                { name = "w1", template = "worker" },
                { name = "w2", template = "worker" },
                { name = "w3", template = "worker" },
                { name = "w4", template = "worker" },
              },
            },
          },
        }),
      })
      t.eq(false, ok, "more members than max_workers must be refused")
      t.match("teams.workflows.dev.team has 4 members but teams.max_workers is 3", tostring(err))

      local bad = {
        { teams = teams_config({ max_workers = 0 }) },
        { teams = teams_config({ max_workers = 9 }) },
        { teams = teams_config({ dashboard = { wide = 10 } }) },
        { teams = teams_config({ dashboard = { wide = "wide" } }) },
        { teams = { templates = { Bad = { agent = "opencode" } } } },
        { teams = { templates = { worker = { agent = "missing" } } } },
        { teams = { templates = { worker = { agent = "opencode", role = 1 } } } },
        { teams = { templates = { worker = { agent = "opencode", models = "m1" } } } },
        { teams = { templates = { worker = { agent = "opencode", models = { "" } } } } },
        { teams = teams_config({ spawn_confirm = { auto = { "nope" } } }) },
        { teams = teams_config({ limits = { max_turns_per_task = 0, max_turns_total = 10 } }) },
        { teams = teams_config({ limits = { max_turns_per_task = 50, max_turns_total = 10 } }) },
        { teams = teams_config({ default = "nope" }) },
        { teams = teams_config({ workflows = { Bad = { summary = "x" } } }) },
        { teams = teams_config({ workflows = { dev = "text" } }) },
        { teams = teams_config({ workflows = { dev = { summary = "" } } }) },
        { teams = teams_config({ workflows = { dev = { summary = "a\nb" } } }) },
        { teams = teams_config({ workflows = { dev = { summary = string.rep("x", 121) } } }) },
        { teams = teams_config({ workflows = { dev = { summary = "x", text = string.rep("x", 4 * 1024 + 1) } } }) },
        { teams = teams_config({ workflows = { dev = { summary = "x", unknown = 1 } } }) },
        { teams = teams_config({ workflows = { dev = { summary = "x", leader = "me" } } }) },
        { teams = teams_config({ workflows = { dev = { summary = "x", leader = { role = 1 } } } }) },
        {
          teams = teams_config({
            workflows = { dev = { summary = "x", team = { { name = "Bad", template = "worker" } } } },
          }),
        },
        {
          teams = teams_config({
            workflows = { dev = { summary = "x", team = { { name = "leader", template = "worker" } } } },
          }),
        },
        {
          teams = teams_config({
            workflows = {
              dev = {
                summary = "x",
                team = {
                  { name = "w1", template = "worker" },
                  { name = "w1", template = "worker" },
                },
              },
            },
          }),
        },
        {
          teams = teams_config({
            workflows = { dev = { summary = "x", team = { { name = "w1", template = "nope" } } } },
          }),
        },
        {
          teams = teams_config({
            templates = { worker = { agent = "opencode", models = { "m1" } } },
            workflows = {
              dev = { summary = "x", team = { { name = "w1", template = "worker", model = "m2" } } },
            },
          }),
        },
        {
          teams = teams_config({
            workflows = { dev = { summary = "x", team = { { name = "w1", template = "worker", task = 1 } } } },
          }),
        },
        {
          teams = teams_config({
            workflows = {
              dev = {
                summary = "x",
                team = {
                  { name = "w1", template = "worker" },
                  { name = "w2", template = "worker" },
                  { name = "w3", template = "worker" },
                  { name = "w4", template = "worker" },
                  { name = "w5", template = "worker" },
                  { name = "w6", template = "worker" },
                  { name = "w7", template = "worker" },
                  { name = "w8", template = "worker" },
                  { name = "w9", template = "worker" },
                },
              },
            },
          }),
        },
        { teams = teams_config({ workflows = { dev = { summary = "x", columns = {} } } }) },
        { teams = teams_config({ workflows = { dev = { summary = "x", columns = { "a", "a" } } } }) },
        {
          teams = teams_config({
            workflows = { dev = { summary = "x", columns = { string.rep("c", 41) } } },
          }),
        },
        {
          teams = teams_config({
            workflows = {
              dev = {
                summary = "x",
                columns = {
                  "c1",
                  "c2",
                  "c3",
                  "c4",
                  "c5",
                  "c6",
                  "c7",
                  "c8",
                  "c9",
                  "c10",
                  "c11",
                  "c12",
                  "c13",
                  "c14",
                  "c15",
                  "c16",
                  "c17",
                },
              },
            },
          }),
        },
        { teams = teams_config({ templates = { worker = { agent = "opencode", worktree = "yes" } } }) },
      }
      for _, over in ipairs(bad) do
        t.raises(function()
          validate(over)
        end)
      end
    end)

    t.it("injects the leader MCP server, then binds the leader", function()
      local service, dir = start_service(t, "leader")
      setup(t, "leader", service, dir, {
        teams = teams_config({
          templates = {
            worker = { agent = "opencode", role = "You are a worker. Report with bus_send.", worktree = true },
          },
        }),
      })
      local connection = ServiceConnection.shared()
      t.truthy(connection)
      controller.connect()
      wait_ready()

      local frames = sent_frames(service, "session/new")
      t.eq(1, #frames, "exactly one session/new")
      local servers = frames[1].params.mcpServers
      t.eq(1, #servers)
      t.eq("ade-team", servers[1].name)
      t.eq({ "mcp" }, servers[1].args)
      local token
      for _, entry in ipairs(servers[1].env) do
        if entry.name == "ADE_TEAM_TOKEN" then
          token = entry.value
        end
      end
      t.eq("k-test-token", token)

      wait(function()
        return #calls_of(service, "team.bind_leader") == 1
      end, 5000, "team.bind_leader")
      local configures = calls_of(service, "team.configure")
      local leaders = calls_of(service, "team.leader_server")
      local binds = calls_of(service, "team.bind_leader")
      t.eq(1, #configures)
      t.eq(1, #leaders)
      t.eq(1, #binds)
      -- configure before leader_server, bind only after the session response
      local order = {}
      for index, call in ipairs(service.calls) do
        if
          call.method == "team.configure"
          or call.method == "team.leader_server"
          or call.method == "team.bind_leader"
        then
          order[#order + 1] = call.method .. "@" .. index
        end
      end
      t.match("team.configure@", order[1])
      t.match("team.leader_server@", order[2])
      t.match("team.bind_leader@", order[3])
      t.eq("k1", binds[1].params.token_id)
      t.eq("sess_mock", binds[1].params.sessionId)
      t.truthy(binds[1].params.instance)
      local configured = configures[1].params.config
      t.eq(3, configured.max_workers)
      t.truthy(configured.templates.worker)
      t.eq("opencode", configured.templates.worker.key.agent)
      t.truthy(type(configured.templates.worker.role) == "string")
      t.eq(true, configured.templates.worker.worktree)
      t.match("/ade/worktrees$", configured.worktree_root)
      -- No environment/secret leaks into what is logged by the front end.
      t.eq(nil, configured.templates.worker.token)
    end)

    t.it("does not inject a leader when the hello configure fails", function()
      local service, dir = start_service(t, "configure-failed", {
        team_configure_error = { code = -32060, message = "invalid configuration" },
      })
      setup(t, "configure-failed", service, dir)
      controller.connect()
      wait_ready()
      t.eq(0, #calls_of(service, "team.leader_server"), "a failed configure must stop injection")
      t.eq(0, #calls_of(service, "team.bind_leader"))
      local frames = sent_frames(service, "session/new")
      t.eq(1, #frames)
      t.eq(0, #frames[1].params.mcpServers)
    end)

    t.it("waits for an in-flight configure before asking for the leader server", function()
      local service, dir = start_service(t, "configure-slow", { team_configure_delay = 300 })
      setup(t, "configure-slow", service, dir)
      controller.connect()
      wait(function()
        return #calls_of(service, "team.configure") >= 1
      end, 5000, "the slow configure")
      vim.wait(100)
      t.eq(0, #calls_of(service, "team.leader_server"), "leader_server waits for configure")
      wait_ready()
      t.eq(1, #calls_of(service, "team.leader_server"))
      wait(function()
        return #calls_of(service, "team.bind_leader") == 1
      end, 5000, "the bind after the slow configure")
    end)

    t.it("injects the leader MCP server into session/load and session/resume", function()
      local service, dir = start_service(t, "load-resume")
      setup(t, "load-resume", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team().bound[dir] ~= nil
      end, 5000, "the first bind")
      -- Pretend this editor just reconnected: no binding and no live team.
      local function forget_binding()
        team().bound[dir] = nil
        service.teams = {}
      end
      forget_binding()
      state().sess.service:replay("sess_mock", {})
      wait(function()
        return #sent_frames(service, "session/load") == 1
      end, 10000, "session/load")
      local load = sent_frames(service, "session/load")[1].params.mcpServers
      t.eq(1, #load)
      t.eq("ade-team", load[1].name)
      wait(function()
        return state().sess.service.replaying ~= true
      end, 10000, "the load to finish")
      -- The load's own bind recreates the team on the service; wait for it,
      -- then drop the binding again so session/resume asks for a new server.
      wait(function()
        return team().bound[dir] ~= nil
      end, 5000, "the load's bind")
      forget_binding()
      state().sess.service:resume("sess_mock", {})
      wait(function()
        return #sent_frames(service, "session/resume") == 1
      end, 10000, "session/resume")
      local resume = sent_frames(service, "session/resume")[1].params.mcpServers
      t.eq(1, #resume)
      t.eq("ade-team", resume[1].name)
    end)

    t.it("does not inject without the feature, in direct mode, or when disabled", function()
      local function count_team_requests(service)
        local n = 0
        for _, call in ipairs(service.calls) do
          if type(call.method) == "string" and call.method:sub(1, 5) == "team." then
            n = n + 1
          end
        end
        return n
      end

      local old, old_dir = start_service(t, "no-feature", {
        features = { "tunnel", "log" },
      })
      setup(t, "no-feature", old, old_dir)
      controller.connect()
      wait_ready()
      t.eq(0, count_team_requests(old))
      t.eq(0, #sent_frames(old, "session/new")[1].params.mcpServers)

      local disabled, disabled_dir = start_service(t, "disabled")
      setup(t, "disabled", disabled, disabled_dir, {
        teams = teams_config({ spawn_from_chat = false }),
      })
      controller.connect()
      wait_ready()
      t.eq(0, count_team_requests(disabled))
      t.eq(0, #sent_frames(disabled, "session/new")[1].params.mcpServers)

      local direct, direct_dir = start_service(t, "direct")
      setup(t, "direct", direct, direct_dir, { backend = "direct" })
      controller.connect()
      wait_ready()
      t.eq(0, count_team_requests(direct))
      t.eq(0, #direct.sent, "direct mode must never touch the service")
    end)

    t.it("renders _ade/turn_started as a bus turn and settles on _ade/turn_finished", function()
      local service, dir = start_service(t, "turn")
      setup(t, "turn", service, dir)
      controller.connect()
      wait_ready()
      local session = state().sess.current
      local instance = state().conn.client.proc.instance
      service:turn_started(instance, {
        sessionId = session.id,
        origin = "bus",
        prompt = { { type = "text", text = "do the thing" } },
      })
      wait(function()
        for _, block in ipairs(session.blocks or {}) do
          if block.kind == "user" and (block.text or ""):find("do the thing", 1, true) then
            return true
          end
        end
        return false
      end, 5000, "the bus turn content")
      t.eq("running", session.status)
      service:broadcast("tunnel.recv", {
        instance = instance,
        seq = 1,
        message = {
          jsonrpc = "2.0",
          method = "_ade/turn_finished",
          params = { sessionId = session.id, stopReason = "end_turn" },
        },
      })
      wait(function()
        return session.status == "idle"
      end, 5000, "the bus turn to finish")
    end)

    t.it("shows the empty dashboard without teams and renders participants and inbox", function()
      local service, dir = start_service(t, "panel")
      setup(t, "panel", service, dir)
      -- W0f: the dashboard is also the empty state (workflow list).
      t.eq(true, controller.open_team(), "the empty dashboard opens")
      local ui = state().view.team_ui
      t.truthy(ui.buf, "the empty dashboard buffer")
      ui:close()
      local ready = false
      controller.connect()
      wait_ready()
      ready = true
      t.truthy(ready)
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {
          {
            name = "leader",
            role = "leader",
            state = "working",
            task = "T1",
            queued = 0,
            turns = { task = 1, total = 2 },
          },
          {
            name = "w1",
            role = "worker",
            state = "idle",
            task = "_",
            queued = 2,
            turns = { task = 0, total = 1 },
            paused = true,
            worktree = { path = "/tmp/wt/w1", branch = "ade/t1-20260101-000000/w1" },
          },
        },
        inbox = {},
        limits = { max_workers = 3, turns_total = 2, max_turns_total = 200 },
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team changed notification")
      -- The inbox follows team.inbox notifications, not the snapshot in the
      -- last team.changed.
      service:team_inbox({
        id = "i1",
        team = "t1",
        kind = "question",
        from = "w1",
        body = "which one?",
        state = "open",
      })
      wait(function()
        return team():item("i1") ~= nil
      end, 5000, "the inbox notification")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
      t.match("t1", text)
      t.match("leader", text)
      t.match("w1", text)
      t.match("paused", text)
      t.match("wt ade/t1%-20260101%-000000/w1", text)
      -- Answered items disappear without another team.changed.
      service:team_inbox({
        id = "i1",
        team = "t1",
        kind = "question",
        from = "w1",
        body = "which one?",
        state = "answered",
      })
      wait(function()
        local line = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
        return not line:find("which one%?")
      end, 5000, "the answered item to leave the panel")
      ui:close()
    end)

    t.it("answers every inbox kind with the right team.answer payload", function()
      local service, dir = start_service(t, "inbox")
      setup(t, "inbox", service, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      local m = team()
      local items = {
        { id = "i1", team = "t1", kind = "question", from = "w1", body = "q", options = { "a", "b" }, state = "open" },
        {
          id = "i2",
          team = "t1",
          kind = "spawn",
          from = "leader",
          body = "",
          template = "worker",
          name = "w2",
          state = "open",
        },
        {
          id = "i3",
          team = "t1",
          kind = "permission",
          from = "w1",
          body = "",
          options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
          state = "open",
        },
        {
          id = "i4",
          team = "t1",
          kind = "request",
          from = "w1",
          body = "",
          instance = "i",
          method = "x",
          params = {},
          state = "open",
        },
        { id = "i5", team = "t1", kind = "message", from = "w1", body = "hi", state = "open" },
        { id = "i6", team = "t1", kind = "limit", from = "leader", body = "", scope = "task", state = "open" },
      }
      for _, item in ipairs(items) do
        service:team_inbox(item)
      end
      wait(function()
        return #notices >= #items
      end, 5000, "one notification per new inbox item")
      local answers = {
        { "i1", { text = "b" } },
        { "i2", { allow = true } },
        { "i3", { option = "allow" } },
        { "i4", { text = '{"ok":true}' } },
        { "i5", {} },
        { "i6", {} },
      }
      for _, entry in ipairs(answers) do
        local sent = false
        m:answer(entry[1], entry[2], function()
          sent = true
        end)
        wait(function()
          return sent
        end, 5000, "answer " .. entry[1])
      end
      t.eq(#answers, #service.team_answers)
      for index, entry in ipairs(answers) do
        t.eq(entry[1], service.team_answers[index].request)
        for key, value in pairs(entry[2]) do
          t.eq(value, service.team_answers[index][key])
        end
      end
    end)

    t.it("sends, controls, resets and closes through the panel API", function()
      local service, dir = start_service(t, "actions")
      setup(t, "actions", service, dir)
      controller.connect()
      wait_ready()
      local m = team()
      local function call(fn)
        local done = false
        fn(function()
          done = true
        end)
        wait(function()
          return done
        end, 5000, "the team request")
      end
      call(function(cb)
        m:send("t1", "w1", "task", "do it", { task = "T1" }, cb)
      end)
      call(function(cb)
        m:control("t1", "w1", "pause", cb)
      end)
      call(function(cb)
        m:reset_limits("t1", cb)
      end)
      call(function(cb)
        m:close("t1", cb)
      end)
      t.eq(2, #service.team_sends)
      t.eq("task", service.team_sends[1].kind)
      t.eq("T1", service.team_sends[1].task)
      t.eq("control", service.team_sends[2].kind)
      t.eq("pause", service.team_sends[2].body)
      t.truthy(#calls_of(service, "team.reset_limits") >= 1)
      t.truthy(#calls_of(service, "team.close") >= 1)
    end)

    t.it("watches a worker with replay and live updates", function()
      local service, dir = start_service(t, "watch", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replay = {
            { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "replay line" } },
          },
        },
      })
      setup(t, "watch", service, dir)
      controller.connect()
      wait_ready()
      local m = team()
      local renders = 0
      local original_watch = m.on_watch
      m.on_watch = function(session, title)
        renders = renders + 1
        return original_watch and original_watch(session, title)
      end
      t.cleanup(function()
        m.on_watch = original_watch
      end)
      local ok, value
      m:watch("t1", "w1", true, function(result, result_value)
        ok, value = result, result_value
      end)
      wait(function()
        return ok ~= nil
      end, 5000, "team.watch")
      t.eq(true, ok)
      t.eq("sess-w", value.sessionId)
      wait(function()
        local session = m.watching and m.watching.session
        if not session then
          return false
        end
        for _, block in ipairs(session.blocks) do
          if block.kind == "agent" and (block.text or ""):find("replay line", 1, true) then
            return true
          end
        end
        return false
      end, 5000, "the replay to render")
      service:watch_update("inst-w", "sess-w", {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "live line" },
      })
      wait(function()
        local session = m.watching and m.watching.session
        if not session then
          return false
        end
        for _, block in ipairs(session.blocks) do
          if (block.text or ""):find("live line", 1, true) then
            return true
          end
        end
        return false
      end, 5000, "the live watch update")
      t.truthy(renders >= 2, "the watch view must be re-rendered for live updates")
      local ui = state().view.team_ui
      ui:watch(m.watching.session, "t1/w1")
      t.truthy(ui.watch_buf, "the watch view is open")
      local function text()
        return table.concat(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false), "\n")
      end
      wait(function()
        return text():find("replay line", 1, true) and text():find("live line", 1, true)
      end, 5000, "the first watch paint")
      t.match("replay line", text())
      t.match("live line", text())
      m:unwatch()
    end)

    t.it("reports a failure of the newly selected watch", function()
      local service, dir = start_service(t, "watch-b-fail", {
        team_watch = { instance = "inst-w", sessionId = "sess-w", delays = { 10, 30 }, errors = { "", "B failed" } },
      })
      setup(t, "watch-b-fail", service, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      local ui = state().view.team_ui
      ui.watcher:open("t1", "w1")
      wait(function()
        return ui.watch_buf ~= nil and team().watching and team().watching.participant == "w1"
      end, 5000, "the first watch")
      ui.watcher:open("t1", "w2")
      wait(function()
        for _, note in ipairs(notices) do
          if note.message:find("B failed", 1, true) then
            return true
          end
        end
        return false
      end, 5000, "the B failure notice")
      t.eq(nil, team().watching)
      t.eq(nil, ui.watch_buf)
    end)

    t.it("serializes replays and skips intermediate watch targets", function()
      local service, dir = start_service(t, "watch-serialize", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          delays = { 150, 10, 10 },
          replay = { { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "replay" } } },
        },
      })
      setup(t, "watch-serialize", service, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      local ui = state().view.team_ui
      ui.watcher:open("t1", "w1")
      vim.wait(20)
      ui.watcher:open("t1", "w2")
      ui.watcher:open("t1", "w3")
      wait(function()
        return team().watching and team().watching.participant == "w3" and ui.watch_buf ~= nil
      end, 5000, "the last target")
      vim.wait(200)
      t.eq("w3", team().watching.participant, "the intermediate target is skipped")
      for _, note in ipairs(notices) do
        t.falsy(
          note.message:find("replay is already in progress", 1, true),
          "the front end must not ask for two replays at once"
        )
      end
      ui.watcher:close()
    end)

    t.it("does not inject anything when no template is configured", function()
      local service, dir = start_service(t, "no-templates")
      setup(t, "no-templates", service, dir, {
        teams = { spawn_from_chat = true, templates = {} },
      })
      -- Deep-merging overrides keeps the default template; clear it so the
      -- "no templates" shape is the one under test.
      state().config.teams.templates = {}
      controller.connect()
      wait_ready()
      local n = 0
      for _, call in ipairs(service.calls) do
        if type(call.method) == "string" and call.method:sub(1, 5) == "team." then
          n = n + 1
        end
      end
      t.eq(0, n, "no template means no team requests")
      t.eq(0, #sent_frames(service, "session/new")[1].params.mcpServers)
    end)

    t.it("treats an all-unresolvable template set as unavailable", function()
      local service, dir = start_service(t, "all-skipped")
      setup(t, "all-skipped", service, dir, {
        agents = { broken = { command = "broken", source = "managed" } },
      })
      -- Deep-merging overrides keeps the default worker template; use only
      -- the template whose managed agent cannot resolve.
      state().config.teams.templates = {
        broken = { agent = "broken", role = "You are broken." },
      }
      local notices = capture(t)
      controller.connect()
      wait_ready()
      local n = 0
      for _, call in ipairs(service.calls) do
        if
          call.method == "team.configure"
          or call.method == "team.leader_server"
          or call.method == "team.bind_leader"
        then
          n = n + 1
        end
      end
      t.eq(0, n, "no configure/leader request when every template is skipped")
      t.eq(0, #sent_frames(service, "session/new")[1].params.mcpServers)
      -- Re-running configure with the same broken template must not repeat the
      -- warning.
      team():configure(dir, true)
      vim.wait(100)
      local skipped = 0
      for _, note in ipairs(notices) do
        if note.message:find("team template skipped", 1, true) then
          skipped = skipped + 1
        end
      end
      t.eq(1, skipped)
    end)

    local function enabled_teams(over)
      return teams_config(vim.tbl_deep_extend("force", {
        enabled = true,
        default = "dev",
        workflows = {
          dev = {
            summary = "two workers write code",
            team = {
              { name = "w1", template = "worker", task = "T1" },
              { name = "w2", template = "worker" },
            },
          },
        },
      }, over or {}))
    end

    local function suspended_team(dir, session_id, participants)
      return {
        id = "t1",
        cwd = dir,
        state = "suspended",
        suspended_at = 1767225600000,
        leader = { instance = nil, sessionId = session_id },
        participants = participants or {},
        inbox = {},
        limits = { max_turns_per_task = 30, max_turns_total = 200, turns_total = 0 },
      }
    end

    t.it("starts the enabled default workflow once when the leader creates the team", function()
      local service, dir = start_service(t, "enabled", {})
      setup(t, "enabled", service, dir, { teams = enabled_teams() })
      local notices = capture(t)
      controller.connect()
      wait_ready()
      wait(function()
        return #service.team_starts == 1
      end, 10000, "the enabled workflow")
      t.eq("t1", service.team_starts[1].team)
      t.eq("dev", service.team_starts[1].workflow)
      t.eq(nil, service.team_starts[1].task)
      -- A second bind/reconnect for the same team must not start it again.
      team():start_enabled_workers("t1", team():team("t1"))
      vim.wait(100)
      t.eq(1, #service.team_starts, "the workflow starts only once per team")
      for _, note in ipairs(notices) do
        t.falsy(note.message:find("could not start workflow", 1, true), note.message)
      end
    end)

    t.it("does not start the enabled workflow when the team already has a worker", function()
      local service, dir = start_service(t, "enabled-existing", {
        team_participants = {
          { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          { name = "w1", state = "exited", task = "_", queued = 0, turns = {} },
        },
      })
      setup(t, "enabled-existing", service, dir, { teams = enabled_teams() })
      controller.connect()
      wait_ready()
      wait(function()
        return team().bound[dir] ~= nil
      end, 10000, "the bind")
      vim.wait(200)
      t.eq(0, #service.team_starts, "a team that already ran a workflow is not started again")
    end)

    t.it("reports a failed enabled workflow once", function()
      local service, dir = start_service(t, "enabled-failed", {
        team_start_error = { code = -32061, message = "worker limit reached" },
      })
      setup(t, "enabled-failed", service, dir, { teams = enabled_teams() })
      local notices = capture(t)
      controller.connect()
      wait_ready()
      wait(function()
        for _, note in ipairs(notices) do
          if note.message:find("could not start workflow dev", 1, true) then
            return true
          end
        end
        return false
      end, 10000, "the failed workflow notice")
      t.eq(1, #service.team_starts)
    end)

    t.it("does not start the enabled workflow when binding the leader fails", function()
      local service, dir = start_service(t, "enabled-bind-failed", {
        team_bind_error = { code = -32061, message = "another session leads this team" },
      })
      setup(t, "enabled-bind-failed", service, dir, { teams = enabled_teams() })
      controller.connect()
      wait_ready()
      wait(function()
        return team().blocked[dir] == true
      end, 5000, "the failed bind")
      vim.wait(200)
      t.eq(0, #service.team_starts)
    end)

    t.it("does not inject a leader when another instance already leads the cwd", function()
      local service, dir = start_service(t, "other-leader")
      service.teams.t1 = {
        id = "t1",
        cwd = dir,
        state = "active",
        leader = { instance = "someone-else", sessionId = "s-other" },
        participants = {},
        inbox = {},
        limits = {},
      }
      setup(t, "other-leader", service, dir)
      controller.connect()
      wait_ready()
      t.eq(0, #calls_of(service, "team.leader_server"))
      t.eq(0, #sent_frames(service, "session/new")[1].params.mcpServers)
      t.eq(true, team().blocked[dir])
    end)

    t.it("blocks a second leader after a -32061 bind failure", function()
      local service, dir = start_service(t, "bind-blocked", {
        team_bind_error = { code = -32061, message = "another session leads this team" },
      })
      setup(t, "bind-blocked", service, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      wait(function()
        return team().blocked[dir] == true
      end, 5000, "the blocked leader")
      local joined = {}
      for _, note in ipairs(notices) do
        joined[#joined + 1] = note.message
      end
      t.match("another session already leads", table.concat(joined, "\n"))

      -- A second session in the same instance must not ask again.
      local before = #calls_of(service, "team.leader_server")
      controller.new_session()
      wait(function()
        return #sent_frames(service, "session/new") == 2
      end, 10000, "the second session")
      t.eq(before, #calls_of(service, "team.leader_server"))
      t.eq(0, #sent_frames(service, "session/new")[2].params.mcpServers)
    end)

    t.it("does not inject again for a second session of the bound leader", function()
      local service, dir = start_service(t, "second-session")
      setup(t, "second-session", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        local bound = team().bound[dir]
        return bound ~= nil and bound.instance ~= nil
      end, 5000, "the bound leader")
      t.eq(1, #calls_of(service, "team.leader_server"))
      controller.new_session()
      wait(function()
        return #sent_frames(service, "session/new") == 2
      end, 10000, "the second session")
      t.eq(1, #calls_of(service, "team.leader_server"))
      t.eq(1, #calls_of(service, "team.bind_leader"))
      t.eq(0, #sent_frames(service, "session/new")[2].params.mcpServers)
    end)

    t.it("does not inject twice for concurrent session requests", function()
      local service, dir = start_service(t, "leader-race")
      setup(t, "leader-race", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team().bound[dir] ~= nil
      end, 5000, "the first bind")
      -- Start from scratch and race two leader_server calls for this cwd.
      team().bound[dir] = nil
      service.teams = {}
      local instance = state().conn.client.proc.instance
      local results = {}
      local function start()
        return async.run(function()
          local server = team():leader_server(instance, dir)
          results[#results + 1] = server
        end)
      end
      local first = start()
      local second = start()
      wait(function()
        return coroutine.status(first) == "dead" and coroutine.status(second) == "dead"
      end, 10000, "both leader_server calls")
      local servers = 0
      for _, result in ipairs(results) do
        if type(result) == "table" and result.name == "ade-team" then
          servers = servers + 1
        end
      end
      t.eq(1, servers, "only one of the concurrent sessions may become leader")
      t.eq(2, #calls_of(service, "team.leader_server"), "the initial session plus one racer")
    end)

    t.it("can lead again after the team is closed", function()
      local service, dir = start_service(t, "close-rebuild")
      setup(t, "close-rebuild", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        local bound = team().bound[dir]
        return bound ~= nil and bound.instance ~= nil
      end, 5000, "the first bind")
      local done = false
      team():close("t1", function()
        done = true
      end)
      wait(function()
        return done
      end, 5000, "team.close")
      wait(function()
        return team().bound[dir] == nil
      end, 5000, "bound to clear on close")
      controller.new_session()
      wait(function()
        return #sent_frames(service, "session/new") == 2
      end, 10000, "the new session")
      wait(function()
        return #calls_of(service, "team.leader_server") == 2
      end, 5000, "the new leader server")
      t.eq(1, #sent_frames(service, "session/new")[2].params.mcpServers)
      wait(function()
        return #calls_of(service, "team.bind_leader") == 2
      end, 5000, "the new bind")
    end)

    t.it("the panel's m sends a legal bus kind and reports failure", function()
      local service, dir = start_service(t, "panel-send")
      setup(t, "panel-send", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {
          { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
        },
        inbox = {},
        limits = { max_turns_total = 200, turns_total = 0 },
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local lnum
      for index, id in pairs(ui.ids) do
        if id == "t1|w1" then
          lnum = index
        end
      end
      t.truthy(lnum, "the worker line")
      vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(_, _, cb)
        cb("task")
      end
      vim.ui.input = function(_, cb)
        cb("do the thing")
      end
      vim.api.nvim_feedkeys("m", "x", false)
      wait(function()
        return #service.team_sends == 1
      end, 5000, "the panel message")
      t.eq("task", service.team_sends[1].kind)
      t.eq("do the thing", service.team_sends[1].body)

      -- Cancelling the kind picker must abort, not fall back to `notice`.
      vim.ui.select = function(_, _, cb)
        cb(nil)
      end
      for index, id in pairs(ui.ids) do
        if id == "t1|w1" then
          lnum = index
        end
      end
      vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
      vim.api.nvim_feedkeys("m", "x", false)
      vim.wait(150)
      t.eq(1, #service.team_sends, "a cancelled kind picker must not send")
      ui:close()
    end)

    t.it("the panel delegates pending choices to the choice queue", function()
      local service, dir = start_service(t, "panel-permission")
      setup(t, "panel-permission", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = { { name = "w1", state = "idle", task = "_", queued = 0, turns = {} } },
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local queue = state().view.choices
      local old_show = queue.show_pending
      local shown
      queue.show_pending = function(_, team_id)
        shown = team_id
        return true
      end
      t.cleanup(function()
        queue.show_pending = old_show
      end)
      vim.api.nvim_set_current_win(ui.win)
      vim.api.nvim_feedkeys("!", "x", false)
      t.eq("t1", shown)
      ui:close()
    end)

    t.it("the panel's permission answer sends the option id, or none on cancel", function()
      local service, dir = start_service(t, "panel-permission")
      setup(t, "panel-permission", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = { { name = "w1", state = "idle", task = "_", queued = 0, turns = {} } },
        inbox = {},
        limits = {},
      })
      service:team_inbox({
        id = "i1",
        team = "t1",
        kind = "permission",
        from = "w1",
        body = "",
        options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
        state = "open",
      })
      wait(function()
        return team():team("t1") ~= nil and team():item("i1") ~= nil
      end, 5000, "the permission item")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      vim.api.nvim_set_current_win(ui.win)
      vim.api.nvim_feedkeys("!", "x", false)
      wait(function()
        local queue = state().view.choices
        return queue and queue:is_open()
      end, 5000, "the choice component")
      local view = state().view.choices.view
      view:select(1)
      view:submit()
      wait(function()
        return #service.team_answers == 1
      end, 5000, "the permission answer")
      t.eq("allow", service.team_answers[1].option)

      service:team_inbox({
        id = "i1",
        team = "t1",
        kind = "permission",
        from = "w1",
        body = "",
        options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
        state = "answered",
      })
      service:team_inbox({
        id = "i2",
        team = "t1",
        kind = "permission",
        from = "w1",
        body = "",
        options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
        state = "open",
      })
      wait(function()
        return team():item("i2") ~= nil and team():item("i1") == nil
      end, 5000, "the second item")
      vim.api.nvim_set_current_win(ui.win)
      vim.api.nvim_feedkeys("!", "x", false)
      wait(function()
        local queue = state().view.choices
        return queue and queue:is_open()
      end, 5000, "the second choice component")
      state().view.choices.view:cancel()
      wait(function()
        return #service.team_answers == 2
      end, 5000, "the cancelled answer")
      t.eq(nil, service.team_answers[2].option)
      ui:close()
    end)

    t.it("the panel's s starts a worker from a template", function()
      local service, dir = start_service(t, "panel-spawn")
      setup(t, "panel-spawn", service, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = { { name = "leader", state = "idle", task = "_", queued = 0, turns = {} } },
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local lnum
      for index, id in pairs(ui.ids) do
        if id == "team:t1" then
          lnum = index
        end
      end
      t.truthy(lnum, "the team line")
      vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
      local original_select, original_input = vim.ui.select, vim.ui.input
      local answers = { "w9", "task nine" }
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(_, _, cb)
        cb("worker")
      end
      vim.ui.input = function(_, cb)
        cb(table.remove(answers, 1))
      end
      vim.api.nvim_feedkeys("s", "x", false)
      wait(function()
        return #service.team_spawns == 1
      end, 5000, "the person-started worker")
      t.eq("t1", service.team_spawns[1].team)
      t.eq("worker", service.team_spawns[1].template)
      t.eq("w9", service.team_spawns[1].name)
      t.eq("task nine", service.team_spawns[1].task)

      -- Invalid/reserved names are rejected before the request and re-asked.
      for index, id in pairs(ui.ids) do
        if id == "team:t1" then
          lnum = index
        end
      end
      vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
      answers = { "leader", "Bad", "w10", "" }
      vim.api.nvim_feedkeys("s", "x", false)
      wait(function()
        return #service.team_spawns == 2
      end, 5000, "the corrected worker name")
      t.eq("w10", service.team_spawns[2].name)
      t.eq(nil, service.team_spawns[2].task)
      local warned = false
      for _, note in ipairs(notices) do
        if note.message:find("not be leader or human", 1, true) then
          warned = true
        end
      end
      t.truthy(warned, "the reserved-name hint is shown")
      ui:close()
    end)

    t.it("the panel's D removes an exited worker's worktree only", function()
      local service, dir = start_service(t, "panel-worktree", {
        team_remove_result = { removed = true, branch_kept = true, branch = "ade/t1-20260101-000000/w1" },
      })
      setup(t, "panel-worktree", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {
          { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          {
            name = "w1",
            state = "exited",
            task = "_",
            queued = 0,
            turns = {},
            worktree = { path = "/tmp/wt/w1", branch = "ade/t1-20260101-000000/w1" },
          },
          {
            name = "w2",
            state = "idle",
            task = "_",
            queued = 0,
            turns = {},
            worktree = { path = "/tmp/wt/w2", branch = "ade/t1-20260101-000000/w2" },
          },
        },
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      local notices = capture(t)
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local function line_of(name)
        for index, id in pairs(ui.ids) do
          if id == "t1|" .. name then
            return index
          end
        end
      end
      local original_select = vim.ui.select
      t.cleanup(function()
        vim.ui.select = original_select
      end)

      vim.api.nvim_win_set_cursor(ui.win, { line_of("w1"), 0 })
      vim.ui.select = function(_, _, cb)
        cb({ label = "Force remove worktree", value = true })
      end
      vim.api.nvim_feedkeys("D", "x", false)
      wait(function()
        return #service.team_removals == 1
      end, 5000, "the worktree removal")
      t.eq("t1", service.team_removals[1].team)
      t.eq("w1", service.team_removals[1].participant)
      t.eq(true, service.team_removals[1].force)
      wait(function()
        local found = false
        for _, note in ipairs(notices) do
          if note.message:find("was kept", 1, true) then
            found = true
          end
        end
        return found
      end, 5000, "the kept-branch notice")

      -- A running worker has no removable worktree yet.
      vim.ui.select = function(_, _, cb)
        cb({ label = "Remove worktree", value = false })
      end
      vim.api.nvim_win_set_cursor(ui.win, { line_of("w2"), 0 })
      vim.api.nvim_feedkeys("D", "x", false)
      vim.wait(150)
      t.eq(1, #service.team_removals)
      local hint = false
      for _, note in ipairs(notices) do
        if note.message:find("must have exited", 1, true) then
          hint = true
        end
      end
      t.truthy(hint, "a running worker must be told to exit first")
      ui:close()
    end)

    t.it("shows git's stderr when removing a worktree fails", function()
      local service, dir = start_service(t, "panel-worktree-error", {
        team_remove_error = {
          code = -32066,
          message = "git worktree remove failed",
          data = { stderr = "fatal: not a git repository" },
        },
      })
      setup(t, "panel-worktree-error", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {
          { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          {
            name = "w1",
            state = "exited",
            task = "_",
            queued = 0,
            turns = {},
            worktree = { path = "/tmp/wt/w1", branch = "ade/t1-20260101-000000/w1" },
          },
        },
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      local notices = capture(t)
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local lnum
      for index, id in pairs(ui.ids) do
        if id == "t1|w1" then
          lnum = index
        end
      end
      t.truthy(lnum)
      vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
      local original_select = vim.ui.select
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      vim.ui.select = function(_, _, cb)
        cb({ label = "Remove worktree", value = false })
      end
      vim.api.nvim_feedkeys("D", "x", false)
      wait(function()
        local found = false
        for _, note in ipairs(notices) do
          if note.message:find("fatal: not a git repository", 1, true) then
            found = true
          end
        end
        return found
      end, 5000, "git's stderr in the notice")
      ui:close()
    end)

    t.it("buffers watch replay until the response names the instance", function()
      local service, dir = start_service(t, "watch-buffer")
      setup(t, "watch-buffer", service, dir)
      controller.connect()
      wait_ready()
      local leader_session = state().sess.current.id
      service.team_watch = {
        instance = "inst-w",
        sessionId = "sess-w",
        replay = { { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "worker replay" } } },
        foreign = {
          {
            instance = state().conn.client.proc.instance,
            sessionId = leader_session,
            update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "LEADER LEAK" } },
          },
        },
      }
      local m = team()
      local ok = nil
      m:watch("t1", "w1", true, function(result)
        ok = result
      end)
      wait(function()
        return ok ~= nil
      end, 5000, "team.watch")
      t.eq(true, ok)
      t.eq("sess-w", m.watching.session.id)
      local text = {}
      for _, block in ipairs(m.watching.session.blocks) do
        text[#text + 1] = block.text or ""
      end
      local joined = table.concat(text, "\n")
      t.match("worker replay", joined)
      t.falsy(joined:find("LEADER LEAK", 1, true), "the leader's updates leaked into the watch")
      m:unwatch()
    end)

    t.it("unwatches the previous worker when switching", function()
      local service, dir = start_service(t, "watch-switch")
      setup(t, "watch-switch", service, dir)
      controller.connect()
      wait_ready()
      local m = team()
      local first = false
      m:watch("t1", "w1", false, function()
        first = true
      end)
      wait(function()
        return first
      end, 5000, "the first watch")
      local second = false
      m:watch("t1", "w2", false, function()
        second = true
      end)
      wait(function()
        return second
      end, 5000, "the second watch")
      wait(function()
        return service.team_unwatch and #service.team_unwatch >= 1
      end, 5000, "the unwatch of the first worker")
      t.eq("w1", service.team_unwatch[1].participant)
      m:unwatch()
    end)

    t.it("releases a superseded watch response without disturbing the newer watch", function()
      local service, dir = start_service(t, "watch-superseded")
      setup(t, "watch-superseded", service, dir)
      controller.connect()
      wait_ready()
      local m = team()
      local seen = {}
      local original = m.on_watch
      m.on_watch = function(session, title)
        if title then
          seen[#seen + 1] = title
        end
        return original and original(session, title)
      end
      t.cleanup(function()
        m.on_watch = original
      end)
      -- The abandoned first response arrives after the new watch is live.
      service.team_watch = { instance = "inst-w", sessionId = "sess-w", delays = { 200, 5 } }
      local first_ok, second_ok
      m:watch("t1", "w1", false, function(result)
        first_ok = result
      end)
      m:watch("t1", "w2", false, function(result)
        second_ok = result
      end)
      wait(function()
        return second_ok ~= nil
      end, 5000, "the new watch")
      wait(function()
        return first_ok ~= nil
      end, 5000, "the abandoned watch response")
      vim.wait(100)
      t.eq("w2", m.watching.participant)
      t.eq("t1/w2", seen[#seen], "the late response must not reopen the old worker")
      for _, call in ipairs(service.team_unwatch or {}) do
        t.truthy(call.participant ~= "w2", "the abandoned response must not unwatch the newer watch")
      end
      m:unwatch()
    end)

    t.it("the panel's w opens the watch view, keeps the panel, and can reopen it", function()
      local service, dir = start_service(t, "panel-watch")
      setup(t, "panel-watch", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {
          { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
          { name = "w2", state = "idle", task = "_", queued = 0, turns = {} },
        },
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local lnum
      for index, id in pairs(ui.ids) do
        if id == "t1|w1" then
          lnum = index
        end
      end
      t.truthy(lnum)
      vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
      vim.api.nvim_feedkeys("w", "x", false)
      wait(function()
        return ui.watch_buf ~= nil and vim.api.nvim_buf_is_valid(ui.watch_buf)
      end, 5000, "the watch view")
      local first = ui.watch_buf
      -- Let the scheduled WinLeave callback run: the panel must survive its
      -- own programmatic split, otherwise the watch would close immediately.
      vim.wait(100)
      t.eq(true, ui:is_open(), "the panel must stay open while watching")

      vim.api.nvim_win_close(ui.watch_win, true)
      wait(function()
        return ui.watch_buf == nil
      end, 5000, "the watch view to be wiped")
      pcall(vim.api.nvim_set_current_win, ui.win)
      vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
      vim.api.nvim_feedkeys("w", "x", false)
      wait(function()
        return ui.watch_buf ~= nil and ui.watch_buf ~= first and vim.api.nvim_buf_is_valid(ui.watch_buf)
      end, 5000, "the reopened watch view")
      local reopened = ui.watch_buf

      -- Switching workers must not let the old window's wipe callback kill
      -- the new watch.
      local other
      for index, id in pairs(ui.ids) do
        if id == "t1|w2" then
          other = index
        end
      end
      t.truthy(other, "the second worker line")
      vim.api.nvim_win_set_cursor(ui.win, { other, 0 })
      vim.api.nvim_feedkeys("w", "x", false)
      wait(function()
        return team().watching
          and team().watching.participant == "w2"
          and ui.watch_buf ~= nil
          and ui.watch_buf ~= reopened
      end, 5000, "the switched watch")
      vim.wait(150)
      t.eq("w2", team().watching.participant, "the switch must survive the old window cleanup")
      t.truthy(ui.watch_buf and vim.api.nvim_buf_is_valid(ui.watch_buf))
      for _, call in ipairs(service.team_unwatch or {}) do
        t.truthy(call.participant ~= "w2", "the old view must not unwatch the new worker")
      end
      ui:close()
    end)

    t.it("renders watched tools, diffs, turns, plans and bus messages", function()
      local service, dir = start_service(t, "watch-render", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replay = {
            {
              sessionUpdate = "user_message_chunk",
              content = {
                type = "text",
                text = 'You are w1, a worker in team t1.\n<team_role>\nROLE TEXT</team_role><bus from="leader" kind="task" task="T4">do work</bus>',
              },
            },
            {
              sessionUpdate = "tool_call",
              toolCallId = "call-edit",
              title = "Edit src/a.rs",
              kind = "edit",
              status = "in_progress",
              content = {
                { type = "diff", path = "src/a.rs", oldText = "old line", newText = "new line" },
              },
            },
            { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "implemented" } },
          },
        },
      })
      setup(t, "watch-render", service, dir)
      controller.connect()
      wait_ready()
      local m = team()
      local ok = false
      m:watch("t1", "w1", true, function(result)
        ok = result
      end)
      wait(function()
        return ok
      end, 5000, "team.watch")
      local ui = state().view.team_ui
      ui:watch(m.watching.session, "t1/w1")
      t.truthy(ui.watch_buf, "the watch view is open")
      local function text()
        return table.concat(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false), "\n")
      end
      wait(function()
        return text():find("── turn 1", 1, true) and text():find("leader → task T4", 1, true)
      end, 5000, "the first turn heading and bus message")
      t.match("role card", text(), text())
      t.falsy(text():find("ROLE TEXT", 1, true), "the role card starts collapsed")
      t.match("src/a.rs", text())
      local turn1
      for _, line in ipairs(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false)) do
        if line:find("── turn 1", 1, true) then
          turn1 = line
        end
      end
      t.truthy(turn1)
      t.falsy(turn1:match("%d+%.%ds"), "a replayed turn has no reliable duration")

      -- Synthetic blocks keep their expansion across live refreshes.
      local role_line
      for index, line in ipairs(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false)) do
        if line:find("role card", 1, true) then
          role_line = index
        end
      end
      t.truthy(role_line)
      vim.api.nvim_set_current_win(ui.watch_win)
      vim.api.nvim_win_set_cursor(ui.watch_win, { role_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
      wait(function()
        return text():find("ROLE TEXT", 1, true)
      end, 5000, "the role card expansion")

      -- A second live turn with a plan, a diff and a bus tool call.
      service:turn_started("inst-w", {
        sessionId = "sess-w",
        origin = "bus",
        prompt = {
          { type = "text", text = '<bus from="leader" kind="task" task="T5">second task</bus>' },
        },
      })
      service:watch_update("inst-w", "sess-w", {
        sessionUpdate = "plan",
        entries = {
          { content = "补 reconnect 的回归测试", status = "in_progress", priority = "high" },
        },
      })
      service:watch_update("inst-w", "sess-w", {
        sessionUpdate = "tool_call",
        toolCallId = "call-bus",
        title = "ade-team_bus_send",
        status = "completed",
        rawInput = { to = "leader", kind = "report", task = "T4", body = "tests pass" },
      })
      service:turn_finished("inst-w", { sessionId = "sess-w", stopReason = "end_turn" })
      wait(function()
        local body = text()
        return body:find("── turn 2", 1, true)
          and body:find("leader → task T5", 1, true)
          and body:find("补 reconnect 的回归测试", 1, true)
          and body:find("→ leader report T4", 1, true)
          and body:find("tests pass", 1, true)
      end, 5000, "the second turn, plan and bus message")

      -- The diff is rendered by the normal tool card, not flattened text.
      local edit_line
      for index, line in ipairs(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false)) do
        if line:find("src/a.rs", 1, true) then
          edit_line = index
        end
      end
      t.truthy(edit_line)
      vim.api.nvim_set_current_win(ui.watch_win)
      vim.api.nvim_win_set_cursor(ui.watch_win, { edit_line, 0 })
      -- The chat's own tool-expansion key works here too.
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
      wait(function()
        local body = text()
        return body:find("old line", 1, true) or body:find("new line", 1, true)
      end, 5000, "the expanded diff")

      -- The watch window owns a read-only Chat and no composer.
      t.truthy(ui.watcher.chat, "the watch view uses Chat")
      t.eq("ade_team_watch", vim.bo[ui.watch_buf].filetype)
      t.eq(1, #vim.fn.win_findbuf(ui.watch_buf), "one watch window")

      -- za on a heading collapses the whole turn; a second za restores it.
      local heading
      for index, line in ipairs(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false)) do
        if line:find("── turn 2", 1, true) then
          heading = index
        end
      end
      t.truthy(heading)
      vim.api.nvim_set_current_win(ui.watch_win)
      vim.api.nvim_win_set_cursor(ui.watch_win, { heading, 0 })
      vim.api.nvim_feedkeys("za", "x", false)
      wait(function()
        return text():find("── turn 2 · bus · leader → task T5 ·", 1, true)
          and text():find("(collapsed)", 1, true)
          and not text():find("补 reconnect 的回归测试", 1, true)
      end, 5000, "the collapsed turn")
      local heading2
      for index, line in ipairs(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false)) do
        if line:find("── turn 2", 1, true) then
          heading2 = index
        end
      end
      t.truthy(heading2)
      vim.api.nvim_set_current_win(ui.watch_win)
      vim.api.nvim_win_set_cursor(ui.watch_win, { heading2, 0 })
      vim.api.nvim_feedkeys("za", "x", false)
      wait(function()
        return not text():find("(collapsed)", 1, true) and text():find("补 reconnect 的回归测试", 1, true)
      end, 5000, "the expanded turn")

      -- ]] / [[ go to the next / previous turn heading.
      vim.api.nvim_set_current_win(ui.watch_win)
      vim.api.nvim_win_set_cursor(ui.watch_win, { 1, 0 })
      vim.api.nvim_feedkeys("]]", "x", false)
      local cursor = vim.api.nvim_win_get_cursor(ui.watch_win)[1]
      t.match("── turn 1", vim.api.nvim_buf_get_lines(ui.watch_buf, cursor - 1, cursor, false)[1] or "")
      vim.api.nvim_feedkeys("]]", "x", false)
      cursor = vim.api.nvim_win_get_cursor(ui.watch_win)[1]
      t.match("── turn 2", vim.api.nvim_buf_get_lines(ui.watch_buf, cursor - 1, cursor, false)[1] or "")
      vim.api.nvim_feedkeys("[[", "x", false)
      cursor = vim.api.nvim_win_get_cursor(ui.watch_win)[1]
      t.match("── turn 1", vim.api.nvim_buf_get_lines(ui.watch_buf, cursor - 1, cursor, false)[1] or "")

      -- Live updates reuse the same display session: no repeated full
      -- `set_session` and the user's scroll position is preserved.
      local chat = ui.watcher.chat
      local original_set_session = chat.set_session
      local set_sessions = 0
      chat.set_session = function(self, session)
        set_sessions = set_sessions + 1
        return original_set_session(self, session)
      end
      chat.follow = false
      vim.api.nvim_set_current_win(ui.watch_win)
      vim.api.nvim_win_set_cursor(ui.watch_win, { 1, 0 })
      service:watch_update("inst-w", "sess-w", {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "follow up" },
      })
      wait(function()
        return text():find("follow up", 1, true)
      end, 5000, "the live update")
      t.eq(0, set_sessions, "live updates do not call set_session again")
      t.eq(1, vim.api.nvim_win_get_cursor(ui.watch_win)[1], "the scroll position is preserved")
      t.eq(false, chat.follow, "the follow state is preserved")
      t.match("ROLE TEXT", text(), "synthetic expansion survives a refresh")
      m:unwatch()
    end)

    t.it("only bus tools become messages and only the first prompt has a role card", function()
      local watch = require("ade.ui.team.watch")
      t.eq(
        nil,
        watch.bus_tool({ kind = "tool", tool_name = "create_issue", raw_input = { body = "x" } }),
        "a tool with a body argument is not a bus message"
      )
      local direct = watch.bus_tool({
        kind = "tool",
        tool_name = "mcp__ade-team__bus_send",
        raw_input = { to = "leader", kind = "report", task = "T4", body = "done" },
      })
      t.truthy(direct)
      t.match("→ leader report T4", direct.title)
      t.match("done", direct.text)
      local proxy = watch.bus_tool({
        kind = "tool",
        tool_name = "mcp",
        raw_input = {
          tool = "bus_ask_human",
          args = { question = "keep it?" },
        },
      })
      t.truthy(proxy)
      t.match("提问", proxy.title)
      t.match("keep it?", proxy.text)
      local role, message = watch.split_role("You are w1, a worker.")
      t.eq(nil, role)
      t.match("You are w1", message)
      role, message = watch.split_role('You are w1<bus from="leader" kind="task">do</bus>')
      t.truthy(role)
      t.match("do", message)
    end)

    t.it("rapid A-B-A switching keeps the last watch and does not unwatch it again", function()
      local service, dir = start_service(t, "watch-rapid", {
        team_watch = { instance = "inst-w", sessionId = "sess-w", delays = { 200, 10, 10 } },
      })
      setup(t, "watch-rapid", service, dir)
      controller.connect()
      wait_ready()
      local ui = state().view.team_ui
      ui.watcher:open("t1", "w1")
      vim.wait(30)
      ui.watcher:open("t1", "w2")
      vim.wait(30)
      ui.watcher:open("t1", "w1")
      wait(function()
        return team().watching
          and team().watching.participant == "w1"
          and ui.watch_buf ~= nil
          and vim.api.nvim_buf_is_valid(ui.watch_buf)
      end, 5000, "the final A watch")
      vim.wait(400)
      t.eq("w1", team().watching.participant, "a stale A response must not replace the new A")
      local unwatches = 0
      for _, call in ipairs(service.team_unwatch or {}) do
        if call.participant == "w1" then
          unwatches = unwatches + 1
        end
      end
      t.eq(0, unwatches, "A stays current, so B is skipped and A is never unwatched")
      ui.watcher:close()
    end)

    t.it("a superseded watch failure does not clear the current watch", function()
      local service, dir = start_service(t, "watch-superseded-fail", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          delays = { 120, 10 },
          errors = { "superseded failure" },
        },
      })
      setup(t, "watch-superseded-fail", service, dir)
      controller.connect()
      wait_ready()
      local ui = state().view.team_ui
      ui.watcher:open("t1", "w1")
      vim.wait(20)
      ui.watcher:open("t1", "w2")
      wait(function()
        return team().watching and team().watching.participant == "w2" and ui.watch_buf ~= nil
      end, 5000, "the current w2 watch")
      vim.wait(200)
      t.eq("w2", team().watching.participant)
      t.truthy(ui.watch_buf and vim.api.nvim_buf_is_valid(ui.watch_buf))
      ui.watcher:close()
    end)

    t.it("closing during an in-flight watch request releases it", function()
      local service, dir = start_service(t, "watch-inflight-close", {
        team_watch = { instance = "inst-w", sessionId = "sess-w", delays = { 120 } },
      })
      setup(t, "watch-inflight-close", service, dir)
      controller.connect()
      wait_ready()
      local ui = state().view.team_ui
      ui.watcher:open("t1", "w1")
      ui.watcher:close()
      vim.wait(250)
      t.eq(nil, team().watching, "the late response must not leave a watch")
      t.eq(nil, ui.watch_buf, "the late response must not open a window")
      t.truthy(#(service.team_unwatch or {}) >= 1, "the in-flight watch is released")
    end)

    t.it("shows the replay fallback notice and supplements it from team.read", function()
      local service, dir = start_service(t, "watch-fallback", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replayed = false,
          replay = {
            { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "live only" } },
          },
        },
        team_read = {
          messages = {
            { from = "leader", to = "w1", kind = "task", task = "T9", body = "earlier instruction" },
          },
          turns = { { at = 1, text = "earlier turn text" } },
        },
      })
      setup(t, "watch-fallback", service, dir)
      controller.connect()
      wait_ready()
      local m = team()
      local ok = false
      m:watch("t1", "w1", true, function(result)
        ok = result
      end)
      wait(function()
        return ok
      end, 5000, "team.watch")
      local ui = state().view.team_ui
      ui:watch(m.watching.session, "t1/w1")
      local function text()
        return table.concat(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false), "\n")
      end
      wait(function()
        local body = text()
        return body:find("会话过长，只显示观察开始之后的内容", 1, true)
          and body:find("earlier instruction", 1, true)
          and body:find("earlier turn text", 1, true)
      end, 5000, "the replay fallback and team.read supplement")
      m:unwatch()
    end)

    t.it("watch open toggles the same participant and pairs unwatch/watch", function()
      local service, dir = start_service(t, "watch-toggle", {
        team_watch = { instance = "inst-w", sessionId = "sess-w" },
      })
      setup(t, "watch-toggle", service, dir)
      controller.connect()
      wait_ready()
      local ui = state().view.team_ui
      ui.watcher:open("t1", "w1")
      wait(function()
        return ui.watch_buf ~= nil and vim.api.nvim_buf_is_valid(ui.watch_buf)
      end, 5000, "the first watch")
      local first = ui.watch_buf
      ui.watcher:open("t1", "w1")
      wait(function()
        return ui.watch_buf == nil and team().watching == nil
      end, 5000, "the same participant to close the watch")

      ui.watcher:open("t1", "w2")
      wait(function()
        return ui.watch_buf ~= nil and ui.watch_buf ~= first and team().watching and team().watching.participant == "w2"
      end, 5000, "the other worker")
      local found = false
      for _, call in ipairs(service.team_unwatch or {}) do
        if call.participant == "w1" then
          found = true
        end
      end
      t.truthy(found, "switching away unwatches the previous worker")
      ui.watcher:close()
      wait(function()
        return ui.watch_buf == nil and team().watching == nil
      end, 5000, "the closed watch")
    end)

    t.it("selecting the leader reuses the existing chat window", function()
      local service, dir = start_service(t, "watch-leader")
      setup(t, "watch-leader", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = state().view.chat
      wait(function()
        return chat.win ~= nil and vim.api.nvim_win_is_valid(chat.win)
      end, 5000, "the leader chat window")
      local ui = state().view.team_ui
      ui.watcher:open("t1", "w1")
      wait(function()
        return ui.watch_buf ~= nil
      end, 5000, "the worker watch")
      ui.watcher:open("t1", "leader")
      wait(function()
        return ui.watch_buf == nil and vim.api.nvim_get_current_win() == chat.win
      end, 5000, "focus the leader's own chat")
      t.eq(nil, ui.watcher.chat, "no second Chat is created for the leader")
      t.eq(nil, team().watching, "the leader is not watched")
    end)

    t.it("ends the watch when its window, the panel, or the team goes away", function()
      local service, dir = start_service(t, "watch-end")
      setup(t, "watch-end", service, dir)
      controller.connect()
      wait_ready()
      local m = team()
      local function watch(participant)
        local ok = nil
        m:watch("t1", participant, false, function(result)
          ok = result
        end)
        wait(function()
          return ok ~= nil and m.watching ~= nil
        end, 5000, "watch " .. participant)
      end
      local function unwatches()
        return service.team_unwatch and #service.team_unwatch or 0
      end

      -- Closing the read-only window ends the watch on the service.
      watch("w1")
      local ui = state().view.team_ui
      ui:watch(m.watching.session, "t1/w1")
      t.truthy(ui.watch_win, "the watch window")
      local before = unwatches()
      vim.api.nvim_win_close(ui.watch_win, true)
      wait(function()
        return m.watching == nil and unwatches() > before
      end, 5000, "the window close to unwatch")

      -- Closing the panel ends it too.
      watch("w2")
      before = unwatches()
      ui:close()
      wait(function()
        return m.watching == nil and unwatches() > before
      end, 5000, "the panel close to unwatch")

      -- A closed team has nothing left to watch.
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      watch("w3")
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "closed",
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return m.watching == nil
      end, 5000, "the closed team to unwatch")
    end)

    t.it("a cancelled bus turn finishes the session cleanly", function()
      local service, dir = start_service(t, "turn-cancelled")
      setup(t, "turn-cancelled", service, dir)
      controller.connect()
      wait_ready()
      local session = state().sess.current
      local instance = state().conn.client.proc.instance
      service:turn_started(instance, {
        sessionId = session.id,
        origin = "bus",
        prompt = { { type = "text", text = "cancel me" } },
      })
      wait(function()
        return session.status == "running"
      end, 5000, "the bus turn")
      service:broadcast("tunnel.recv", {
        instance = instance,
        seq = 1,
        message = {
          jsonrpc = "2.0",
          method = "_ade/turn_finished",
          params = { sessionId = session.id, stopReason = "cancelled" },
        },
      })
      wait(function()
        return session.status == "idle"
      end, 5000, "the cancelled bus turn to settle")
    end)

    t.it("sends the person's prompt straight through while a bus turn runs", function()
      local service, dir = start_service(t, "bus-priority")
      setup(t, "bus-priority", service, dir)
      controller.connect()
      wait_ready()
      local session = state().sess.current
      local instance = state().conn.client.proc.instance
      service:turn_started(instance, {
        sessionId = session.id,
        origin = "bus",
        prompt = { { type = "text", text = "bus work" } },
      })
      wait(function()
        return session.bus_turn ~= nil and session.status == "running"
      end, 5000, "the bus turn")
      local before = session.turn
      t.eq(true, controller.send_now("person first", nil))
      -- The person's prompt supersedes the bus turn instead of being queued.
      t.eq(nil, session.bus_turn)
      t.eq(0, #session.queue)
      t.truthy(session.turn > before)
      -- A late cancelled bus finish must not end the person's turn.
      team():turn_finished({ sessionId = session.id, stopReason = "cancelled" })
      t.eq("running", session.status)
      wait(function()
        return #sent_frames(service, "session/prompt") == 1
      end, 10000, "the person's session/prompt")
      local found = false
      for _, block in ipairs(session.blocks) do
        if block.kind == "user" and type(block.text) == "string" and block.text:find("person first", 1, true) then
          found = true
        end
      end
      t.truthy(found, "the person's message is shown")
      wait(function()
        return session.status == "idle"
      end, 10000, "the person's turn to finish")
    end)

    t.it("marks teams stale on disconnect and refuses their operations", function()
      local service, dir = start_service(t, "stale", {})
      local connection = setup(t, "stale", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = { { name = "leader", state = "idle", task = "_", queued = 0, turns = {} } },
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local notices = capture(t)
      connection:on_disconnect("lost", true)
      wait(function()
        local t1 = team():team("t1")
        return t1 ~= nil and t1.stale == true
      end, 5000, "the stale team")
      local function panel_text()
        return table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
      end
      wait(function()
        return panel_text():find("connection lost", 1, true)
      end, 5000, "the stale panel notice")
      t.match("connection lost", panel_text())

      local sends = #service.team_sends
      local leader_line
      for index, id in pairs(ui.ids) do
        if id == "t1|leader" then
          leader_line = index
        end
      end
      vim.api.nvim_win_set_cursor(ui.win, { leader_line, 0 })
      vim.api.nvim_feedkeys("m", "x", false)
      vim.wait(100)
      t.eq(sends, #service.team_sends, "a stale team sends nothing")
      local hinted = false
      for _, note in ipairs(notices) do
        if note.message:find("connection to the service is lost", 1, true) then
          hinted = true
        end
      end
      t.truthy(hinted, "the panel explains the lost connection")
      pcall(ui.close, ui)
    end)

    t.it("replaces stale teams on a successful refresh and clears them on failure", function()
      local service, dir = start_service(t, "refresh-stale", {})
      setup(t, "refresh-stale", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      team():team("t1").stale = true
      team():refresh()
      wait(function()
        return team():team("t1") ~= nil and team():team("t1").stale ~= true
      end, 5000, "the refreshed team")

      service.team_list_error = { code = -32066, message = "team list failed" }
      team():refresh()
      wait(function()
        return team():team("t1") == nil
      end, 5000, "a failed refresh to clear the list")
    end)

    t.it("does not start the enabled workflow for a suspended team", function()
      local service, dir = start_service(t, "suspended-bind", {})
      setup(t, "suspended-bind", service, dir, { teams = enabled_teams() })
      controller.connect()
      wait_ready()
      wait(function()
        return #service.team_starts == 1
      end, 10000, "the enabled workflow")
      local before = #service.team_starts
      team():start_enabled_workers("t-suspended", {
        id = "t-suspended",
        state = "suspended",
        participants = {},
      })
      vim.wait(100)
      t.eq(before, #service.team_starts)
      t.eq(nil, team().enabled_teams["t-suspended"])
    end)

    t.it("keeps teams across a disconnect and shows suspended teams after hello", function()
      local service, dir = start_service(t, "reconnect", {})
      local connection = setup(t, "reconnect", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team().bound[dir] ~= nil
      end, 5000, "the first bind")
      local entry = suspended_team(dir, "sess_mock", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
      })
      service.teams.t1 = entry
      -- A reconnect no longer forgets teams: hello re-reads team.list and
      -- keeps a suspended team visible.
      team():on_hello()
      wait(function()
        local t1 = team():team("t1")
        return t1 ~= nil and t1.state == "suspended"
      end, 5000, "the suspended team after hello")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
      local expected = "suspended since " .. os.date("%Y-%m-%d", math.floor(entry.suspended_at / 1000))
      t.truthy(text:find(expected, 1, true), "the panel shows suspended_at")
      t.match("waiting for the leader session", text)

      connection:on_disconnect("lost", true)
      vim.wait(100)
      t.truthy(team():team("t1"), "a disconnect must not forget stored teams")
      t.eq(true, ui:is_open(), "the panel stays available")
      ui:close()
    end)

    t.it("resumes a suspended team and does not restart its configured workers", function()
      local service, dir = start_service(t, "suspended-resume", {})
      service.teams.t1 = suspended_team(dir, "sess_mock", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {}, template = "worker" },
      })
      setup(t, "suspended-resume", service, dir, { teams = enabled_teams() })
      controller.connect()
      wait_ready()
      wait(function()
        local t1 = team():team("t1")
        return t1 ~= nil and t1.state == "active"
      end, 5000, "the resumed team")
      wait(function()
        local t1 = team():team("t1")
        for _, participant in ipairs(t1.participants or {}) do
          if participant.name == "w1" then
            return participant.instance ~= nil
          end
        end
        return false
      end, 5000, "the resumed worker")
      -- hello's configure must reach the service before leader_server.
      local configure_at, leader_at
      for index, call in ipairs(service.calls) do
        if call.method == "team.configure" and not configure_at then
          configure_at = index
        end
        if call.method == "team.leader_server" and not leader_at then
          leader_at = index
        end
      end
      t.truthy(configure_at and leader_at, "configure and leader_server")
      t.truthy(configure_at < leader_at, "configure must precede leader injection")
      vim.wait(100)
      t.eq(0, #service.team_starts, "recovered participants are not started again")

      local session = state().sess.current
      local instance = state().conn.client.proc.instance
      service:turn_started(instance, {
        sessionId = session.id,
        origin = "bus",
        prompt = { { type = "text", text = "team resumed after a service restart" } },
      })
      wait(function()
        for _, block in ipairs(session.blocks) do
          if type(block.text) == "string" and block.text:find("team resumed after a service restart", 1, true) then
            return true
          end
        end
        return false
      end, 5000, "the recovery notice as a bus turn")
    end)

    t.it("keeps a suspended team when the restored session is not its leader", function()
      local service, dir = start_service(t, "suspended-mismatch", {})
      service.teams.t1 = suspended_team(dir, "stored-session", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        {
          name = "w1",
          state = "exited",
          task = "_",
          queued = 0,
          turns = {},
          worktree = { path = "/tmp/wt/w1", branch = "ade/t1-20260101-000000/w1" },
        },
      })
      setup(t, "suspended-mismatch", service, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      wait(function()
        for _, note in ipairs(notices) do
          if note.message:find("still suspended", 1, true) then
            return true
          end
        end
        return false
      end, 5000, "the suspended-team hint")
      t.eq("suspended", team():team("t1").state)
      t.eq(nil, team().blocked[dir], "a suspended team must not block leader injection")
      t.eq(1, #calls_of(service, "team.leader_server"))
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
      t.match("suspended since", text)
      t.match(
        "press x",
        table.concat(
          vim.tbl_map(function(note)
            return note.message
          end, notices),
          "\n"
        )
      )
      ui:close()
    end)

    t.it("refuses watch, spawn and control while a team is suspended", function()
      local service, dir = start_service(t, "suspended-refuse", {})
      service.teams.t1 = suspended_team(dir, "stored-session", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
      })
      setup(t, "suspended-refuse", service, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") and team():team("t1").state == "suspended"
      end, 5000, "the suspended team")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local function line_of(name)
        for index, id in pairs(ui.ids) do
          if id == "t1|" .. name then
            return index
          end
        end
      end
      vim.api.nvim_win_set_cursor(ui.win, { line_of("w1"), 0 })
      local sends = #service.team_sends
      for _, key in ipairs({ "p", "r", "c" }) do
        vim.api.nvim_feedkeys(key, "x", false)
        vim.wait(50)
      end
      t.eq(sends, #service.team_sends, "control must not reach a suspended team")
      vim.api.nvim_feedkeys("w", "x", false)
      vim.wait(50)
      t.eq(nil, team().watching)

      local team_line
      for index, id in pairs(ui.ids) do
        if id == "team:t1" then
          team_line = index
        end
      end
      vim.api.nvim_win_set_cursor(ui.win, { team_line, 0 })
      vim.api.nvim_feedkeys("s", "x", false)
      vim.wait(50)
      t.eq(0, #service.team_spawns, "spawn must not reach a suspended team")

      local hinted = false
      for _, note in ipairs(notices) do
        if note.message:find("team is suspended", 1, true) then
          hinted = true
        end
      end
      t.truthy(hinted, "the panel explains that the team is suspended")
      ui:close()
    end)

    t.it("allows messages, answers, worktree removal and close on a suspended team", function()
      local service, dir = start_service(t, "suspended-allow", {
        team_remove_result = { removed = true, branch_kept = false, branch = "ade/t1-20260101-000000/w1" },
      })
      service.teams.t1 = suspended_team(dir, "stored-session", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        {
          name = "w1",
          state = "exited",
          task = "_",
          queued = 0,
          turns = {},
          worktree = { path = "/tmp/wt/w1", branch = "ade/t1-20260101-000000/w1" },
        },
      })
      setup(t, "suspended-allow", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") and team():team("t1").state == "suspended"
      end, 5000, "the suspended team")
      service:team_inbox({
        id = "i1",
        team = "t1",
        kind = "question",
        from = "w1",
        body = "resume?",
        state = "open",
      })
      wait(function()
        return team():item("i1") ~= nil
      end, 5000, "the inbox item")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      local function line_of(id)
        for index, value in pairs(ui.ids) do
          if value == id then
            return index
          end
        end
      end

      vim.ui.select = function(_, _, cb)
        cb("notice")
      end
      vim.ui.input = function(_, cb)
        cb("queued while suspended")
      end
      vim.api.nvim_win_set_cursor(ui.win, { line_of("t1|w1"), 0 })
      vim.api.nvim_feedkeys("m", "x", false)
      wait(function()
        return #service.team_sends == 1
      end, 5000, "the queued message")
      t.eq("notice", service.team_sends[1].kind)
      t.eq("queued while suspended", service.team_sends[1].body)

      local queue = state().view.choices
      local old_answer = queue.answer_participant
      local answered
      queue.answer_participant = function(_, _, name)
        answered = name
        return true
      end
      t.cleanup(function()
        queue.answer_participant = old_answer
      end)
      vim.api.nvim_win_set_cursor(ui.win, { line_of("t1|w1"), 0 })
      vim.api.nvim_feedkeys("a", "x", false)
      t.eq("w1", answered)

      vim.ui.select = function(_, _, cb)
        cb({ label = "Remove worktree", value = false })
      end
      vim.api.nvim_win_set_cursor(ui.win, { line_of("t1|w1"), 0 })
      vim.api.nvim_feedkeys("D", "x", false)
      wait(function()
        return #service.team_removals == 1
      end, 5000, "the worktree removal")

      local team_line
      for index, id in pairs(ui.ids) do
        if id == "team:t1" then
          team_line = index
        end
      end
      vim.api.nvim_win_set_cursor(ui.win, { team_line, 0 })
      vim.api.nvim_feedkeys("R", "x", false)
      wait(function()
        return #service.team_resets == 1
      end, 5000, "reset_limits while suspended")

      vim.ui.select = function(_, _, cb)
        cb({ label = "Close the team", value = true })
      end
      vim.api.nvim_win_set_cursor(ui.win, { team_line, 0 })
      vim.api.nvim_feedkeys("x", "x", false)
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the suspended team to close")
      pcall(ui.close, ui)
    end)
  end)
end
