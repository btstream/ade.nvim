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
    end)
  end)

  t.describe("teams v3 commands", function()
    t.it("rejects unknown team subcommands in the command line", function()
      local notices = capture(t)
      vim.cmd("Ade team nope")
      t.truthy(notices[1] and tostring(notices[1].message):match("unknown team command"))
    end)
  end)
end
