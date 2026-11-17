-- Teams: the front end's wiring (PROTOCOL.md section 18).
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local Config = require("ade.config")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")
  local Framing = require("ade.transport.framing")

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
        { teams = teams_config({ spawn_confirm = { auto = { "nope" } } }) },
        { teams = teams_config({ limits = { max_turns_per_task = 0, max_turns_total = 10 } }) },
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
        inbox = {
          { id = "i1", team = "t1", kind = "question", from = "w1", body = "which one?", state = "open" },
        },
        limits = { max_workers = 3, turns_total = 2, max_turns_total = 200 },
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team changed notification")
      t.eq(true, controller.open_team())
      local ui = state().view.team_ui
      local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
      t.match("t1", text)
      t.match("leader", text)
      t.match("w1", text)
      t.match("paused", text)
      t.match("which one%?", text)
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
