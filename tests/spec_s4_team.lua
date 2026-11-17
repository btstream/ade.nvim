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
      local function valid(over)
        return Config.validate(vim.tbl_deep_extend("force", Config.defaults, over or {}))
      end
      local cfg = valid({ teams = teams_config() })
      t.eq(3, cfg.teams.max_workers)
      local bad = {
        { teams = teams_config({ max_workers = 0 }) },
        { teams = teams_config({ max_workers = 9 }) },
        { teams = { templates = { Bad = { agent = "opencode", role = "" } } } },
        { teams = { templates = { worker = { agent = "missing", role = "" } } } },
        { teams = { templates = { worker = { agent = "opencode" } } } },
        { teams = { templates = { worker = { agent = "opencode", role = "   " } } } },
        { teams = teams_config({ spawn_confirm = { auto = { "nope" } } }) },
        { teams = teams_config({ limits = { max_turns_per_task = 0, max_turns_total = 10 } }) },
        { teams = teams_config({ limits = { max_turns_per_task = 50, max_turns_total = 10 } }) },
      }
      for _, over in ipairs(bad) do
        t.raises(function()
          Config.validate(vim.tbl_deep_extend("force", Config.defaults, over))
        end)
      end
    end)

    t.it("injects the leader MCP server, then binds the leader", function()
      local service, dir = start_service(t, "leader")
      setup(t, "leader", service, dir)
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
      -- No environment/secret leaks into what is logged by the front end.
      t.eq(nil, configured.templates.worker.token)
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

    t.it("shows the panel only with teams and renders participants and inbox", function()
      local service, dir = start_service(t, "panel")
      setup(t, "panel", service, dir)
      t.eq(false, controller.open_team(), "no team means no panel")
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
      t.match("which one%?", text)
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
      local text = table.concat(vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false), "\n")
      t.match("replay line", text)
      t.match("live line", text, text)
      m:unwatch()
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

    t.it("the panel's permission answer sends the option id, or none on cancel", function()
      local service, dir = start_service(t, "panel-permission")
      setup(t, "panel-permission", service, dir)
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
      local lnum
      for index, id in pairs(ui.ids) do
        if id == "item:i1" then
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
        cb({ label = "Allow", value = "allow" })
      end
      vim.api.nvim_feedkeys("a", "x", false)
      wait(function()
        return #service.team_answers == 1
      end, 5000, "the permission answer")
      t.eq("allow", service.team_answers[1].option)

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
        local line
        for index, id in pairs(ui.ids) do
          if id == "item:i2" then
            line = index
          end
        end
        return line ~= nil
      end, 5000, "the second item")
      for index, id in pairs(ui.ids) do
        if id == "item:i2" then
          lnum = index
        end
      end
      vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
      vim.ui.select = function(_, _, cb)
        cb({ label = "Cancel", value = false })
      end
      vim.api.nvim_feedkeys("a", "x", false)
      wait(function()
        return #service.team_answers == 2
      end, 5000, "the cancelled answer")
      t.eq(nil, service.team_answers[2].option)
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

    t.it("treats a reconnect as the end of every team", function()
      local service, dir = start_service(t, "reconnect", {})
      local connection = setup(t, "reconnect", service, dir)
      controller.connect()
      wait_ready()
      -- Let the setup-time team reconcile run before injecting a team, so the
      -- disconnect assertion is the only thing that can clear it.
      vim.wait(100)
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
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      connection:on_disconnect("lost", true)
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the team to be forgotten")
      wait(function()
        return not ui:is_open()
      end, 5000, "the panel to close")
    end)
  end)
end
