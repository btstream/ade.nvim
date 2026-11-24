-- Restored teams v3 coverage: the tree's real actions (PROTOCOL.md 20.2,
-- 20.4) and the board target.
--
-- Ported from `feat/teams-v3:tests/spec_s4_team.lua` / `spec_w0e_team.lua`
-- ("新入口生产集成" in the review): `<CR>` really loads a released session (and
-- does not close the leader that was on screen), `S` starts in the row's
-- session rather than the current one, the tree only queries live rows and
-- follows an instance change, and `b` names the row's team explicitly.
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local Framing = require("ade.transport.framing")
  local controller = require("ade.controller")
  local ade = require("ade")
  local State = require("ade.session.state")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-v3tree-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  ---A stand-in service that runs a real `tests/mock_agent.py` child, so the
  ---advertised capabilities (and therefore load/resume/close) are the agent's.
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
        -- The agent's own profile travels as the attach env; without it the
        -- child would always advertise the default profile's capabilities.
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

  local function team()
    return state().view.team
  end

  local function own_instance()
    local client = state().conn.client
    return client and client.proc and client.proc.instance or nil
  end

  local function open_tree()
    ade.open_team("tree")
    wait(function()
      local UI = state().view.team_ui
      return UI and UI:is_open("tree")
    end, 5000, "the tree")
    return state().view.team_ui
  end

  local function tree_line(text)
    local UI = state().view.team_ui
    local buf = UI.layout:buf("tree")
    for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find(text, 1, true) then
        return index
      end
    end
  end

  local function cursor_on(text)
    local UI = state().view.team_ui
    local line = tree_line(text)
    t.truthy(line, "a tree row containing " .. text)
    vim.api.nvim_set_current_win(UI.layout:win("tree"))
    vim.api.nvim_win_set_cursor(UI.layout:win("tree"), { line, 0 })
    return line
  end

  ---Add a session the front end knows but has not loaded yet.
  local function add_session(id, cwd, instance)
    local session = State.new(id, cwd)
    session.agent_name = "opencode"
    session.instance = instance or own_instance()
    session.needs_load = true
    state().sess.all[id] = session
    return session
  end

  local function seed_team(service, dir, over)
    local row = vim.tbl_deep_extend("force", {
      id = "t1",
      cwd = dir,
      state = "active",
      leader = { instance = own_instance(), sessionId = "sess_mock" },
      participants = {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
      },
      inbox = {},
      limits = { max_turns_per_task = 30, max_turns_total = 200, turns_total = 0 },
    }, over or {})
    service.teams[row.id] = vim.deepcopy(row)
    service:team_changed(row)
    wait(function()
      return team():team(row.id) ~= nil
    end, 5000, "the team")
    return row
  end

  t.describe("teams v3 tree entries", function()
    t.it("`<CR>` really loads a released session and keeps the leader open", function()
      local service, dir = start_service(t, "tree-load")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      add_session("sess_old", dir, own_instance())
      local UI = open_tree()
      cursor_on("sess_old")
      local before_load = #sent_frames(service, "session/load")
      local before_close = #sent_frames(service, "session/close")
      UI:handle_key("cr")
      wait(function()
        return #sent_frames(service, "session/load") > before_load
      end, 15000, "the real session/load")
      local load = sent_frames(service, "session/load")[#sent_frames(service, "session/load")]
      t.eq("sess_old", load.params.sessionId)
      wait(function()
        return state().sess.current and state().sess.current.id == "sess_old"
      end, 15000, "the loaded session to become current")
      vim.wait(100)
      t.eq(
        before_close,
        #sent_frames(service, "session/close"),
        "loading another session must not close the leader it replaced"
      )
    end)

    t.it("`<CR>` resumes when the agent cannot load history", function()
      local service, dir = start_service(t, "tree-resume")
      setup(t, dir, {
        agents = {
          opencode = {
            command = "python3",
            args = { root .. "tests/mock_agent.py" },
            env = { ACP_MOCK_PROFILE = "resumeonly" },
            profile = "resumeonly",
          },
        },
      })
      controller.connect()
      wait_ready()
      add_session("sess_old", dir, own_instance())
      local UI = open_tree()
      cursor_on("sess_old")
      UI:handle_key("cr")
      wait(function()
        return #sent_frames(service, "session/resume") == 1
      end, 15000, "the real session/resume")
      t.eq(0, #sent_frames(service, "session/load"), "the agent cannot load, so it must resume")
      wait(function()
        return state().sess.current and state().sess.current.id == "sess_old"
      end, 15000, "the resumed session to become current")
    end)

    -- PRODUCTION BUG (review round 2, "新入口生产集成" / item 2): the tree calls
    -- `self:start_team(nil, session)` with method syntax on a plain function, so
    -- the dashboard becomes the workflow name and the row's session is dropped
    -- (`lua/ade/ui/team/init.lua:1023–1025`; the flow then reports
    -- "unknown workflow table: 0x…").
    t.it("`S` starts in the row's session, not the current one", function()
      local service, dir = start_service(t, "tree-start")
      setup(t, dir, {
        teams = {
          max_workers = 3,
          spawn_confirm = { auto = {} },
          templates = {},
          dashboard = { wide = 100 },
          workflows = { dev = { summary = "dev", team = { { name = "w1", template = "worker" } } } },
        },
      })
      controller.connect()
      wait_ready()
      local current = state().sess.current
      local other = add_session("s-other", dir, own_instance())
      other.needs_load = false
      other.status = "idle"
      local UI = open_tree()
      cursor_on("s-other")
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(items, _, cb)
        cb(items[1])
      end
      vim.ui.input = function(_, cb)
        cb("row task")
      end
      UI:handle_key("S")
      wait(function()
        return #calls_of(service, "team.start") == 1
      end, 10000, "the start from the row")
      local start = calls_of(service, "team.start")[1].params
      t.eq("s-other", start.sessionId, "the row's session is the start target")
      t.eq(own_instance(), start.instance)
      t.eq("row task", start.task)
      t.eq(current, state().sess.current, "starting elsewhere does not switch the chat")
    end)

    -- PRODUCTION BUG (review round 2, "树查询重新连接仍不可靠"): the renderer
    -- queries every row that has an instance and no cached switch, without
    -- checking `entry.online` (`lua/ade/ui/team/init.lua:373–395`). Opening the
    -- tree with a session from a service instance this editor is not connected
    -- to asks the service about it instead of leaving it alone.
    t.it("does not query the switch of an offline row", function()
      local service, dir = start_service(t, "tree-offline")
      setup(t, dir)
      controller.connect()
      wait_ready()
      add_session("s-other", dir, "inst-old")
      local UI = open_tree()
      wait(function()
        return tree_line("s-other") ~= nil
      end, 5000, "the foreign row")
      vim.wait(200)
      for _, call in ipairs(calls_of(service, "session.teams")) do
        t.truthy(call.params.instance ~= "inst-old", "the old instance must never be queried")
      end
      _ = UI
    end)

    t.it("queries a row once its own instance is live and marks its switch", function()
      local service, dir = start_service(t, "tree-instance")
      setup(t, dir)
      controller.connect()
      wait_ready()
      local session = add_session("s-other", dir, "inst-old")
      local UI = open_tree()
      wait(function()
        return tree_line("s-other") ~= nil
      end, 5000, "the foreign row")
      local buf = UI.layout:buf("tree")
      t.match("%[offline%]", table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))

      -- The session comes back on this editor's instance with teams off: the
      -- tree queries it and paints the real switch instead of guessing.
      session.instance = own_instance()
      service.session_switches[own_instance() .. "\0s-other"] = { enabled = false, injected = true }
      team():changed()
      wait(function()
        for _, call in ipairs(calls_of(service, "session.teams")) do
          if call.params.sessionId == "s-other" and call.params.instance == own_instance() then
            return true
          end
        end
        return false
      end, 5000, "the query after the instance came back")
      wait(function()
        local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        return lines:find("s%-other.-%[team off%]") ~= nil
      end, 5000, "the row to show its switch")
    end)

    -- PRODUCTION BUG (review round 2, "`b` 未实现跨项目目标"):
    -- `Dashboard:handle_tree_key` writes `board_selected_id`/`resolved_cwd` for
    -- the row (`lua/ade/ui/team/init.lua:954–960`), but `open()` then overwrites
    -- `resolved_cwd` from the editor cwd and `board_team()` prefers the project
    -- cwd (`576–579`, `185–209`), so the pane resolves `t1` instead of `t2`.
    t.it("`b` on a row of another project opens that project's board", function()
      local other_dir = tmpdir("tree-board-other")
      local service, dir = start_service(t, "tree-board", {
        team_board = { rev = 1, columns = { "todo" }, cards = {} },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local other = {
        id = "t2",
        cwd = other_dir,
        state = "active",
        leader = { instance = "inst-other", sessionId = "s-other" },
        participants = { { name = "leader", state = "idle" }, { name = "w9", state = "idle" } },
        inbox = {},
        limits = {},
      }
      service.teams.t2 = vim.deepcopy(other)
      service:team_changed(other)
      add_session("s-other", other_dir, "inst-other")
      wait(function()
        return team():team("t2") ~= nil
      end, 5000, "the other project's team")
      local UI = open_tree()
      cursor_on(other_dir)
      UI:handle_key("b")
      wait(function()
        return UI:is_open("board")
      end, 5000, "the board pane")
      vim.wait(150)
      t.eq("t2", UI.board_selected_id, "the row's project is the board target")
      -- `:Ade team board` keeps following the editor's cwd.
      UI:close()
      t.eq(true, controller.open_team("board"))
      t.eq("t1", UI.board_selected_id)
      UI:close()
    end)

    t.it("`x` on a non-leader row never closes the team", function()
      local service, dir = start_service(t, "tree-close-row")
      setup(t, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      add_session("s-other", dir, own_instance())
      local UI = open_tree()
      local meta = {
        kind = "tree_session",
        session = { id = "s-other", cwd = dir, instance = own_instance() },
        cwd = dir,
        instance = own_instance(),
        online = true,
        leader = false,
        team = team():team_for_cwd(dir),
      }
      t.eq(true, UI:handle_tree_key("x", meta))
      t.eq(0, #calls_of(service, "team.close"))
      t.match("leader", joined(notices))
    end)
  end)
end
