-- Teams v3 front end: no injection, per-session switch, lazy creation and the
-- session tree (PROTOCOL.md section 20).
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")
  local presenter = require("ade.app.presenter")

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
      canned_agent = true,
    }, opts or {}))
    assert(service:listen(), "the stand-in service could not listen")
    t.cleanup(function()
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
      teams = { max_workers = 3, spawn_confirm = { auto = {} } },
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

  local function instance()
    local client = state().conn.client
    return client and client.proc and client.proc.instance or nil
  end

  local team
  local function current_id()
    return state().sess.current and state().sess.current.id or nil
  end

  ---Create a team on the current session through the real RPC.
  local function start_team(workflow)
    local inst = instance()
    local id = current_id()
    return team():start_session(inst, id, workflow or "default", nil, function() end)
  end

  function team()
    return state().view.team
  end

  local function yes_confirm()
    local original = presenter.confirm
    presenter.confirm = function(_, cb)
      cb("yes")
    end
    t.cleanup(function()
      presenter.confirm = original
    end)
  end

  t.describe("teams v3 front end", function()
    t.it("negotiates api_version 7", function()
      t.eq(7, Version.API_VERSION)
    end)

    t.it("sends the configuration but injects no MCP server", function()
      local service, dir = start_service(t, "no-injection")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "team.configure") == 1
      end, 5000, "the configuration")
      local config = calls_of(service, "team.configure")[1].params.config
      t.eq(true, config.enabled)
      t.eq(true, config.session_default)
      t.eq(nil, config.derived)
      t.eq(0, #calls_of(service, "team.leader_server"))
      t.eq(0, #calls_of(service, "team.bind_leader"))
      local frames = sent_frames(service, "session/new")
      t.eq(1, #frames)
      local servers = frames[1].params.mcpServers or {}
      for _, server in ipairs(servers) do
        t.truthy(server.name ~= "ade-team", "the service injects ade-team itself")
      end
      -- Empty templates are legal: the service builds `worker` itself.
      t.eq(nil, next(config.templates or {}))
    end)

    t.it("queries the new session's switch once it exists", function()
      local service, dir = start_service(t, "session-query")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the session.teams query")
      local query = calls_of(service, "session.teams")[1].params
      t.eq("sess_mock", query.sessionId)
      t.truthy(query.instance)
      wait(function()
        local st = team():session_teams(query.instance, "sess_mock")
        return st ~= nil
      end, 5000, "the switch state")
      t.eq(true, team():session_teams(query.instance, "sess_mock").enabled)
    end)

    t.it("starts a team on the current session, without creating a session", function()
      local service, dir = start_service(t, "start-session")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      local before = #sent_frames(service, "session/new")
      team():start_session(instance(), "sess_mock", "default", nil, function() end)
      wait(function()
        return #calls_of(service, "team.start") == 1
      end, 5000, "team.start")
      local call = calls_of(service, "team.start")[1].params
      t.eq("sess_mock", call.sessionId)
      t.eq("default", call.workflow)
      t.eq(nil, call.team)
      t.eq(before, #sent_frames(service, "session/new"), "no new session")
      wait(function()
        return team():team_for_cwd(dir) ~= nil
      end, 5000, "the team")
    end)

    t.it("answers led_by with a choice card that can take the team over", function()
      local service, dir = start_service(t, "led-by")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      -- Another chat already leads this cwd's team.
      local other = {
        id = "t9",
        cwd = dir,
        state = "active",
        leader = { instance = "inst-other", sessionId = "other-session" },
        participants = { { name = "leader", state = "idle" }, { name = "w1", state = "idle" } },
        inbox = {},
      }
      service.teams[other.id] = other
      local shown
      local choices = state().view.choices
      choices.ask = function(_, o)
        shown = o.options
        o.on_choice("move")
        return true
      end
      local original_input = vim.ui.input
      vim.ui.input = function(_, cb)
        cb("")
      end
      t.cleanup(function()
        vim.ui.input = original_input
      end)
      ade.start_team("default")
      wait(function()
        return #calls_of(service, "team.start") == 1
      end, 5000, "the refused start")
      wait(function()
        return #calls_of(service, "team.set_leader") == 1
      end, 5000, "the handover")
      local move = calls_of(service, "team.set_leader")[1].params
      t.eq("t9", move.team)
      t.eq("sess_mock", move.sessionId)
      wait(function()
        return #calls_of(service, "team.start") == 2
      end, 5000, "the retried start")
      t.truthy(shown)
      local labels = {}
      for _, item in ipairs(shown) do
        labels[#labels + 1] = item.label
      end
      t.truthy(table.concat(labels, "|"):match("移交"))
      t.eq("sess_mock", other.leader.sessionId)
    end)

    t.it("enables a session before starting when its switch is off", function()
      local service, dir = start_service(t, "switch-off")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      local inst = instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = false, injected = true }
      team():start_session(inst, "sess_mock", "default", nil, function() end)
      -- team.start itself rejects an off switch.
      wait(function()
        return #calls_of(service, "session.teams") >= 2
      end, 5000, "the explicit use")
    end)

    t.it("team on and off call session.teams for the current session", function()
      local service, dir = start_service(t, "on-off")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      ade.team_off()
      wait(function()
        for _, call in ipairs(calls_of(service, "session.teams")) do
          if call.params.enabled == false then
            return true
          end
        end
        return false
      end, 5000, "team off")
      local off
      for _, call in ipairs(calls_of(service, "session.teams")) do
        if call.params.enabled == false then
          off = call.params
        end
      end
      t.eq(false, off and off.enabled)
      ade.team_on()
      wait(function()
        for _, call in ipairs(calls_of(service, "session.teams")) do
          if call.params.enabled == true then
            return true
          end
        end
        return false
      end, 5000, "team on")
      local on
      for _, call in ipairs(calls_of(service, "session.teams")) do
        if call.params.enabled == true then
          on = call.params
        end
      end
      t.eq(true, on and on.enabled)
    end)

    t.it("team off closes a led team after the confirmation", function()
      local service, dir = start_service(t, "off-leads")
      setup(t, dir)
      yes_confirm()
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      start_team()
      wait(function()
        return team():team_for_cwd(dir) ~= nil
      end, 5000, "the team")
      ade.team_off()
      wait(function()
        return team():team_for_cwd(dir) == nil
      end, 5000, "the close")
      local off
      for _, call in ipairs(calls_of(service, "session.teams")) do
        if call.params.enabled == false then
          off = call.params
        end
      end
      t.eq(true, off and off.close)
    end)

    t.it("team stop and team leader reach the new RPCs", function()
      local service, dir = start_service(t, "stop-leader")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      start_team()
      wait(function()
        return team():team_for_cwd(dir) ~= nil
      end, 5000, "the team")
      local row = team():team_for_cwd(dir)
      table.insert(service.teams[row.id].participants, { name = "w1", state = "idle" })
      team():refresh()
      wait(function()
        return team():participant(row.id, "w1") ~= nil
      end, 5000, "w1 in the panel")
      ade.team_stop("w1", false)
      wait(function()
        return #calls_of(service, "team.stop_worker") == 1
      end, 5000, "team.stop_worker")
      t.eq("w1", calls_of(service, "team.stop_worker")[1].params.name)
      table.insert(service.teams[row.id].participants, { name = "w2", state = "idle" })
      team():refresh()
      wait(function()
        return team():participant(row.id, "w2") ~= nil
      end, 5000, "w2 in the panel")
      ade.team_stop("w2", true)
      wait(function()
        return #calls_of(service, "team.stop_worker") == 2
      end, 5000, "the remove form")
      t.eq(true, calls_of(service, "team.stop_worker")[2].params.remove)

      service.teams[row.id].leader = { instance = "inst-other", sessionId = "other" }
      team():refresh()
      wait(function()
        local entry = team():team_for_cwd(dir)
        return entry and entry.leader and entry.leader.sessionId == "other"
      end, 5000, "the foreign leader")
      ade.team_leader()
      wait(function()
        return #calls_of(service, "team.set_leader") == 1
      end, 5000, "team.set_leader")
      t.eq("sess_mock", calls_of(service, "team.set_leader")[1].params.sessionId)
    end)

    t.it("reloads in place without closing the session, even with close-capable agents", function()
      local service, dir = start_service(t, "reload-true", {
        -- If the guard is wrong, the agent really would receive session/close.
        agent_capabilities = { sessionCapabilities = { close = {}, resume = {} } },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      local inst = instance()
      -- The session was created before teams were configured: no tools yet.
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      local seen
      team():set_session_teams(inst, "sess_mock", true, false, function(ok, value)
        seen = { ok = ok, value = value }
      end)
      wait(function()
        return seen ~= nil
      end, 5000, "the switch reply")
      t.eq(true, seen.ok)
      t.eq(true, seen.value.reload, "the service marks a forwarded load")
      local before = #sent_frames(service, "session/load")
      local reloaded
      -- The front end must perform the load itself, through its normal path.
      team():reload_session(inst, "sess_mock", function(ok)
        reloaded = ok
      end)
      wait(function()
        return #sent_frames(service, "session/load") > before
      end, 5000, "the forwarded load")
      wait(function()
        return reloaded ~= nil
      end, 5000, "the reload to settle")
      t.eq(true, reloaded)
      -- Loading in place replaces the transcript projection of the same logical
      -- session; that is not "leaving" it, so no ACP session/close may follow
      -- (it would revoke the token the load just injected).
      vim.wait(200)
      t.eq(0, #sent_frames(service, "session/close"), "an in-place reload must not close the session")
      wait(function()
        local state = team():session_teams(inst, "sess_mock")
        return state ~= nil and state.injected == true
      end, 5000, "the switch to show the injected tools")
    end)

    t.it("never closes a session restored onto a different instance", function()
      local service, dir = start_service(t, "reload-new-instance", {
        agent_capabilities = { sessionCapabilities = { close = {}, resume = {} } },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      local State = require("ade.session.state")
      local S = state()
      local live = instance()
      local old = S.sess.current
      -- After an agent restart the runtime keeps the old object (old instance,
      -- needs_load); the restore commits a fresh projection of the same id.
      old.instance = "inst-from-before-the-restart"
      old.status = "idle"
      old.queue = {}
      local restored = State.new(old.id, old.cwd)
      restored.instance = live
      S.sess.service.activate(restored)
      vim.wait(300)
      t.eq(old.id, S.sess.current.id, "the restored projection is on screen")
      t.eq(0, #sent_frames(service, "session/close"), "a session restored onto a new instance is never closed")
      -- Control: a genuine switch-away of a close-capable idle session does
      -- send session/close, so the assertion above can actually fail.
      local other = State.new("sess-other", old.cwd)
      other.instance = live
      S.sess.service.activate(other)
      wait(function()
        return #sent_frames(service, "session/close") >= 1
      end, 5000, "the real close of a left-behind idle session")
    end)

    t.it("auto-starts once on an empty team list and again when tools appear", function()
      local service, dir = start_service(t, "auto-start-empty")
      service.teams = {}
      setup(t, dir, {
        teams = {
          auto_start = true,
          max_workers = 3,
          spawn_confirm = { auto = {} },
          limits = { max_turns_per_task = 30, max_turns_total = 200 },
        },
      })
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "team.start") == 1
      end, 8000, "the auto-start of an empty project")
      local call = calls_of(service, "team.start")[1].params
      t.eq("sess_mock", call.sessionId)
      t.eq("default", call.workflow)
      vim.wait(300)
      t.eq(1, #calls_of(service, "team.start"), "only one auto-start per session")
    end)

    t.it("auto-starts when the switch reports injected later", function()
      local service, dir = start_service(t, "auto-start-later", { session_injected_default = false })
      service.teams = {}
      setup(t, dir, {
        teams = {
          auto_start = true,
          max_workers = 3,
          spawn_confirm = { auto = {} },
          limits = { max_turns_per_task = 30, max_turns_total = 200 },
        },
      })
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      local inst = instance()
      vim.wait(300)
      t.eq(0, #calls_of(service, "team.start"), "nothing starts before the tools are injected")
      -- The service now reports the session injected: the pending decision runs.
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = true }
      service:emit_session_teams(inst, "sess_mock")
      wait(function()
        return #calls_of(service, "team.start") >= 1
      end, 8000, "the auto-start after injected")
    end)

    t.it("pair team.spawn answers structured errors instead of an inbox item", function()
      local service, dir = start_service(t, "spawn-pair")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      local inst = instance()
      -- Off first: the pair form must say why, not create an item.
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = false, injected = true }
      local seen
      team():spawn_pair(inst, "sess_mock", "worker", nil, nil, function(ok, value)
        seen = { ok = ok, value = value }
      end)
      wait(function()
        return seen ~= nil
      end, 5000, "the off refusal")
      t.eq(false, seen.ok)
      t.eq("off", seen.value.data.reason)
      -- Injected but another chat leads: structured led_by, no item either.
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = true }
      service.teams.t9 = {
        id = "t9",
        cwd = dir,
        state = "active",
        leader = { instance = "inst-other", sessionId = "other" },
        participants = { { name = "leader", state = "idle" } },
        inbox = {},
      }
      seen = nil
      team():spawn_pair(inst, "sess_mock", "worker", nil, nil, function(ok, value)
        seen = { ok = ok, value = value }
      end)
      wait(function()
        return seen ~= nil
      end, 5000, "the led_by refusal")
      t.eq(false, seen.ok)
      t.eq("led_by", seen.value.data.reason)
      local spawns = calls_of(service, "team.spawn")
      t.eq(2, #spawns)
      t.eq("sess_mock", spawns[1].params.sessionId)
      t.eq(nil, spawns[1].params.team, "the pair form sends no team id")
    end)

    t.it("team.start from {instance, sessionId} answers led_by without an inbox item", function()
      local service, dir = start_service(t, "led-by-structured")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      service.teams.t9 = {
        id = "t9",
        cwd = dir,
        state = "active",
        leader = { instance = "inst-other", sessionId = "other-session" },
        participants = { { name = "leader", state = "idle" }, { name = "w1", state = "idle" } },
        inbox = {},
      }
      local seen
      team():start_session(instance(), "sess_mock", "default", nil, function(ok, value)
        seen = { ok = ok, value = value }
      end)
      wait(function()
        return seen ~= nil
      end, 5000, "the structured refusal")
      t.eq(false, seen.ok)
      t.eq("led_by", seen.value.data.reason)
      t.eq("t9", seen.value.data.team.id)
      t.eq("other-session", seen.value.data.leader.sessionId)
      t.eq(nil, seen.value.data.handover, "no handover item is created for the front end")
    end)

    t.it("resumes a stored team only through a successful load of its leader", function()
      local service, dir = start_service(t, "resume-load")
      local suspended = {
        id = "t7",
        cwd = dir,
        state = "suspended",
        leader = { instance = nil, sessionId = "sess_mock" },
        participants = { { name = "leader", state = "idle" } },
        inbox = {},
      }
      service.teams[suspended.id] = vim.deepcopy(suspended)
      setup(t, dir)
      controller.connect()
      wait_ready()
      -- Configure alone must not resume it (PROTOCOL.md 20.7).
      wait(function()
        return #calls_of(service, "team.configure") >= 1
      end, 5000, "the configuration")
      vim.wait(100)
      t.eq("suspended", service.teams.t7.state, "configure does not resume a team")
      -- A real load of the leader session does.
      state().sess.service:load("sess_mock", { kind = "load" })
      wait(function()
        return service.teams.t7 and service.teams.t7.state == "active"
      end, 8000, "the resumed team")
      t.eq("sess_mock", service.teams.t7.leader.sessionId)
    end)

    t.it("validates session_default and rejects spawn_from_chat", function()
      local Config = require("ade.config")
      local base = vim.deepcopy(Config.defaults)
      base.backend = "service"
      base.cwd = "/tmp"
      base.agent = "opencode"
      base.agents = { opencode = { command = "true" } }
      base.teams = vim.tbl_extend("force", base.teams or {}, { enabled = true, session_default = true })
      Config.validate(base)
      local bad = vim.deepcopy(base)
      bad.teams.session_default = "yes"
      t.raises(function()
        Config.validate(bad)
      end)
      local old = vim.deepcopy(base)
      old.teams.spawn_from_chat = true
      t.raises(function()
        Config.validate(old)
      end)
    end)

    t.describe("the tree", function()
      local function open_tree()
        ade.open_team("tree")
        wait(function()
          local ui = state().view.team_ui
          return ui and ui:is_open("tree")
        end, 5000, "the tree")
      end

      local function line_of(text)
        local ui = state().view.team_ui
        local buf = ui.layout:buf("tree")
        for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
          if line:find(text, 1, true) then
            return index
          end
        end
      end

      local function cursor_on(text)
        local ui = state().view.team_ui
        local line = line_of(text)
        t.truthy(line, "a row containing " .. text)
        vim.api.nvim_win_set_cursor(ui.layout:win("tree"), { line, 0 })
        return line
      end

      t.it("groups sessions by project and marks leaders and off switches", function()
        local service, dir = start_service(t, "tree")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        start_team()
        wait(function()
          return team():team_for_cwd(dir) ~= nil
        end, 5000, "the team")
        local row = team():team_for_cwd(dir)
        table.insert(row.participants, { name = "w1", label = "worker", state = "working" })
        team():changed()
        open_tree()
        local lines = vim.api.nvim_buf_get_lines(state().view.team_ui.layout:buf("tree"), 0, -1, false)
        local text = table.concat(lines, "\n")
        t.truthy(text:find(dir, 1, true), "the project header")
        t.match("%[leader%]", text)
        t.match("w1", text)
        t.match("worker", text)
        t.match("工作中", text)
      end)

      t.it("t toggles the switch of the session under the cursor", function()
        local service, dir = start_service(t, "tree-key")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        open_tree()
        cursor_on("sess_mock")
        state().view.team_ui:handle_key("t")
        wait(function()
          local found = false
          for _, call in ipairs(calls_of(service, "session.teams")) do
            if call.params.enabled == false then
              found = true
            end
          end
          return found
        end, 5000, "turning teams off from the tree")
      end)

      t.it("x on a worker row stops it", function()
        local service, dir = start_service(t, "tree-x")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        start_team()
        wait(function()
          return team():team_for_cwd(dir) ~= nil
        end, 5000, "the team")
        local row = team():team_for_cwd(dir)
        table.insert(row.participants, { name = "w1", state = "idle" })
        team():changed()
        open_tree()
        cursor_on("w1")
        state().view.team_ui:handle_key("x")
        wait(function()
          return #calls_of(service, "team.stop_worker") == 1
        end, 5000, "the stop")
        t.eq("w1", calls_of(service, "team.stop_worker")[1].params.name)
      end)

      t.it("L on a session row moves the lead there", function()
        local service, dir = start_service(t, "tree-L")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        start_team()
        wait(function()
          return team():team_for_cwd(dir) ~= nil
        end, 5000, "the team")
        local row = team():team_for_cwd(dir)
        service.teams[row.id].leader = { instance = "inst-other", sessionId = "other" }
        team():refresh()
        wait(function()
          local entry = team():team_for_cwd(dir)
          return entry and entry.leader and entry.leader.sessionId == "other"
        end, 5000, "the foreign leader")
        team():changed()
        open_tree()
        cursor_on("sess_mock")
        state().view.team_ui:handle_key("L")
        wait(function()
          return #calls_of(service, "team.set_leader") == 1
        end, 5000, "the move")
        t.eq("sess_mock", calls_of(service, "team.set_leader")[1].params.sessionId)
      end)

      t.it("refuses t/L/S on a row whose instance is not the live one", function()
        local service, dir = start_service(t, "tree-instance")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        local ui = state().view.team_ui
        open_tree()
        local meta = {
          kind = "tree_session",
          session = { id = "s-foreign", cwd = dir, instance = "inst-other" },
          cwd = dir,
          instance = "inst-other",
          online = false,
          team = { id = "t9" },
        }
        local notices = {}
        ui.notify_fn = function(message)
          notices[#notices + 1] = tostring(message)
        end
        for _, key in ipairs({ "t", "L", "S" }) do
          local before = #service.calls
          t.eq(true, ui:handle_tree_key(key, meta), key .. " is handled")
          t.eq(before, #service.calls, key .. " sends no RPC for a foreign instance")
        end
        t.truthy(table.concat(notices, "\n"):match("instance"))
      end)

      t.it("t on an unknown switch queries first and never assumes off", function()
        local service, dir = start_service(t, "tree-unknown")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        local ui = state().view.team_ui
        open_tree()
        local meta = {
          kind = "tree_session",
          session = { id = "sess_mock", cwd = dir, instance = instance() },
          cwd = dir,
          instance = instance(),
          online = true,
          switch = nil,
        }
        t.eq(true, ui:handle_tree_key("t", meta))
        -- The service says teams are on: the follow-up must send `enabled: false`
        -- instead of assuming they were already off and turning them on.
        local function off_sent()
          for _, call in ipairs(calls_of(service, "session.teams")) do
            if call.params.enabled == false then
              return true
            end
          end
          return false
        end
        wait(off_sent, 5000, "the follow-up")
        for _, call in ipairs(calls_of(service, "session.teams")) do
          t.falsy(call.params.enabled == true, "no blind enabled:true before the query answered")
        end
      end)

      t.it("x closes the team only from the leader row and cancels a start", function()
        local service, dir = start_service(t, "tree-close")
        setup(t, dir)
        yes_confirm()
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        start_team()
        wait(function()
          return team():team_for_cwd(dir) ~= nil
        end, 5000, "the team")
        open_tree()
        local ui = state().view.team_ui
        local meta = {
          kind = "tree_session",
          session = { id = "sess_mock", cwd = dir, instance = instance() },
          cwd = dir,
          instance = instance(),
          online = true,
          leader = false,
          team = team():team_for_cwd(dir),
        }
        local notices = {}
        ui.notify_fn = function(message)
          notices[#notices + 1] = tostring(message)
        end
        t.eq(true, ui:handle_tree_key("x", meta))
        t.eq(0, #calls_of(service, "team.close"), "a non-leader row does not close the team")
        t.truthy(table.concat(notices, "\n"):match("leader"))
        meta.leader = true
        t.eq(true, ui:handle_tree_key("x", meta))
        wait(function()
          return #calls_of(service, "team.close") == 1
        end, 5000, "the close")
      end)

      t.it("b opens the row's team even when the editor cwd is another project", function()
        local service, dir = start_service(t, "tree-board-other")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        -- A team of a different project, not the editor's cwd.
        local other_cwd = dir .. "-other"
        service.teams.t9 = {
          id = "t9",
          cwd = other_cwd,
          state = "active",
          leader = { instance = "inst-x", sessionId = "s-other" },
          participants = { { name = "leader", state = "idle" } },
          inbox = {},
        }
        team():refresh()
        wait(function()
          return team():team("t9") ~= nil
        end, 5000, "the other project's team")
        open_tree()
        local ui = state().view.team_ui
        t.eq(true, ui:handle_tree_key("b", { kind = "tree_session", cwd = other_cwd, team = team():team("t9") }))
        wait(function()
          return ui:is_open("board")
        end, 5000, "the board pane")
        t.eq("t9", ui.board_selected_id, "the tree's row decides the board")
        t.eq("t9", ui:board_team().id)
      end)

      t.it("never marks a row online without a live client", function()
        local notices = {}
        local service, dir = start_service(t, "tree-no-live")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        local ui = state().view.team_ui
        -- A real disconnect (service still up) leaves the cached team snapshot
        -- behind; no row may look online while the client is gone, and `t` must
        -- refuse instead of guessing an instance.
        local inst = instance()
        service.teams.t1 = {
          id = "t1",
          cwd = dir,
          state = "active",
          leader = { instance = inst, sessionId = "sess_mock" },
          participants = { { name = "leader", state = "idle" } },
          inbox = {},
        }
        team():refresh()
        wait(function()
          return team():team_for_cwd(dir) ~= nil
        end, 5000, "the team before disconnecting")
        ade.disconnect()
        wait(function()
          return state().conn.phase ~= "ready"
        end, 5000, "the agent to disconnect")
        local groups = ui:tree_groups()
        for _, group in ipairs(groups) do
          for _, entry in ipairs(group.sessions) do
            t.falsy(entry.online, "no live client means no online row")
          end
        end
        t.truthy(table
          .concat(
            vim.tbl_map(function(group)
              return group.cwd
            end, groups),
            ","
          )
          :find(dir, 1, true))
        -- A tree row action for that row is refused (no live instance).
        ui.notify_fn = function(message)
          notices[#notices + 1] = tostring(message)
        end
        local meta = {
          kind = "tree_session",
          session = state().sess.current,
          cwd = dir,
          instance = inst,
          online = false,
          team = team():team_for_cwd(dir),
        }
        local before = #service.calls
        t.eq(true, ui:handle_tree_key("L", meta))
        t.eq(before, #service.calls, "an offline row sends no RPC")
        t.truthy(table.concat(notices, "\n"):match("instance"))
      end)

      t.it("b opens the board of the row's team", function()
        local service, dir = start_service(t, "tree-board")
        setup(t, dir)
        controller.connect()
        wait_ready()
        wait(function()
          return #calls_of(service, "session.teams") >= 1
        end, 5000, "the switch")
        start_team()
        wait(function()
          return team():team_for_cwd(dir) ~= nil
        end, 5000, "the team")
        open_tree()
        local ui = state().view.team_ui
        local row = team():team_for_cwd(dir)
        local meta = {
          kind = "tree_session",
          session = { id = "sess_mock", cwd = dir, instance = instance() },
          cwd = dir,
          instance = instance(),
          online = true,
          team = row,
        }
        t.eq(true, ui:handle_tree_key("b", meta))
        wait(function()
          return ui:is_open("board")
        end, 5000, "the board pane")
        t.eq(row.id, ui.board_selected_id)
      end)
    end)
  end)

  t.describe("teams v3 commands", function()
    t.it("rejects unknown team subcommands in the command line", function()
      local notices = capture(t)
      vim.cmd("Ade team nope")
      t.truthy(notices[1] and tostring(notices[1].message):match("unknown team command"))
    end)

    t.it("supports both stop! syntaxes and completes the team's workers", function()
      local service, dir = start_service(t, "stop-syntax")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      start_team()
      wait(function()
        return team():team_for_cwd(dir) ~= nil
      end, 5000, "the team")
      local row = team():team_for_cwd(dir)
      table.insert(service.teams[row.id].participants, { name = "w1", state = "idle" })
      table.insert(service.teams[row.id].participants, { name = "w2", state = "idle" })
      team():refresh()
      wait(function()
        return team():participant(row.id, "w1") ~= nil and team():participant(row.id, "w2") ~= nil
      end, 5000, "the workers")

      -- Completion runs against the real `:Ade` command.
      local candidates = vim.fn.getcompletion("Ade team stop ", "cmdline")
      local names = table.concat(candidates, ",")
      t.truthy(names:find("w1", 1, true), "w1 is completed")
      t.truthy(names:find("w2", 1, true), "w2 is completed")

      vim.cmd("Ade team stop w1")
      wait(function()
        return #calls_of(service, "team.stop_worker") == 1
      end, 5000, "the plain stop")
      t.falsy(calls_of(service, "team.stop_worker")[1].params.remove, "no remove without a bang")
      vim.cmd("Ade team stop! w2")
      wait(function()
        return #calls_of(service, "team.stop_worker") == 2
      end, 5000, "the trailing bang")
      t.eq(true, calls_of(service, "team.stop_worker")[2].params.remove)
    end)

    t.it("accepts the leading bang too", function()
      local service, dir = start_service(t, "stop-leading-bang")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      start_team()
      wait(function()
        return team():team_for_cwd(dir) ~= nil
      end, 5000, "the team")
      local row = team():team_for_cwd(dir)
      table.insert(service.teams[row.id].participants, { name = "w1", state = "idle" })
      team():refresh()
      wait(function()
        return team():participant(row.id, "w1") ~= nil
      end, 5000, "the worker")
      vim.cmd("Ade! team stop w1")
      wait(function()
        return #calls_of(service, "team.stop_worker") == 1
      end, 5000, "the leading-bang stop")
      t.eq(true, calls_of(service, "team.stop_worker")[1].params.remove)
    end)

    t.it("public ade.start_team starts in the given session without changing the UI selection", function()
      local service, dir = start_service(t, "public-start")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      local S = state()
      local current = S.sess.current
      local current_instance = instance()
      -- A second session of the same project, never shown.
      local State = require("ade.session.state")
      local other = State.new("sess_other", dir)
      other.instance = current_instance
      other.blocks = {}
      S.sess.all.sess_other = other
      local original_input = vim.ui.input
      vim.ui.input = function(_, cb)
        cb("")
      end
      local original_select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        cb(items[1])
      end
      t.cleanup(function()
        vim.ui.input = original_input
        vim.ui.select = original_select
      end)
      -- The selection must not move: the flow addresses the target by pair.
      ade.start_team("default", other)
      wait(function()
        return #calls_of(service, "team.start") == 1
      end, 8000, "the explicit start")
      t.eq(current, S.sess.current, "the current chat is untouched")
      local call = calls_of(service, "team.start")[1].params
      t.eq("sess_other", call.sessionId)
      t.eq(current_instance, call.instance)
    end)

    t.it("a tree query is a pure read and never auto-starts", function()
      local service, dir = start_service(t, "tree-pure", { session_injected_default = false })
      service.teams = {}
      setup(t, dir, {
        teams = {
          auto_start = true,
          max_workers = 3,
          spawn_confirm = { auto = {} },
          limits = { max_turns_per_task = 30, max_turns_total = 200 },
        },
      })
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      local inst = instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = true }
      -- Let the connection-time refresh and its own auto-start decision settle
      -- first, so the only caller left is the tree's read below.
      wait(function()
        return team().list_ready == true
      end, 8000, "the team list to be ready")
      vim.wait(500)
      local before = #calls_of(service, "team.start")
      -- Forget what the session event cached, then let the tree's own read be
      -- the first to see `injected: true`. A pure read may cache it but must not
      -- start a team, even though the person opted into auto-start.
      team().session_states = {}
      team().auto_started = {}
      local read
      team():query_session_teams(inst, "sess_mock", dir, function(ok)
        read = ok
      end, { source = "tree" })
      wait(function()
        local known = team():session_teams(inst, "sess_mock")
        return read and known ~= nil and known.injected == true
      end, 8000, "the tree read to cache the switch")
      vim.wait(300)
      t.eq(before, #calls_of(service, "team.start"), "a tree read never starts a team")
    end)

    t.it("closes a led team through :Ade team off and :Ade team close", function()
      local service, dir = start_service(t, "commands-off")
      setup(t, dir)
      yes_confirm()
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the switch")
      start_team()
      wait(function()
        return team():team_for_cwd(dir) ~= nil
      end, 5000, "the team")
      vim.cmd("Ade team off")
      wait(function()
        return team():team_for_cwd(dir) == nil
      end, 5000, "the closed team")
      local off
      for _, call in ipairs(calls_of(service, "session.teams")) do
        if call.params.enabled == false then
          off = call.params
        end
      end
      t.eq(true, off and off.close)
    end)
  end)
end
