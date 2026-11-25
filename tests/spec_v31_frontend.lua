-- Teams v3.1 (review items A, 1, 2, 5): what a `session.teams {enabled:true}`
-- answer means, the coalesced enable, the auth-method picker's Esc, and closing
-- the team panes without taking the leader conversation away.
--
-- Every case drives the real production path (the fake service's wire shapes and
-- the real controller); nothing stubs the function under test.
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")
  local Team = require("ade.app.team")
  local auth = require("ade.app.auth")
  local picker = require("ade.ui.picker")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-v31-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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

  local function team()
    return state().view.team
  end

  local function own_instance()
    local client = state().conn.client
    return client and client.proc and client.proc.instance or nil
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

  local function enable_writes(service)
    local n = 0
    for _, call in ipairs(calls_of(service, "session.teams")) do
      if call.params.enabled == true then
        n = n + 1
      end
    end
    return n
  end

  local function ui()
    return state().view.team_ui
  end

  local function pane_win(name)
    local UI = ui()
    return UI and UI.layout:win(name) or nil
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

  ---------------------------------------------------------------------------
  -- A. Closing the team closes its panes and keeps the leader conversation
  ---------------------------------------------------------------------------

  t.describe("teams v3.1 close", function()
    local function wise(t)
      local old = vim.o.columns
      vim.o.columns = 170
      t.cleanup(function()
        vim.o.columns = old
      end)
    end

    local function confirm_yes(t)
      local presenter = require("ade.app.presenter")
      local original = presenter.confirm
      presenter.confirm = function(_, cb)
        cb("yes")
      end
      t.cleanup(function()
        presenter.confirm = original
      end)
    end

    t.it("`:Ade team close` closes the panes and keeps the leader chat", function()
      wise(t)
      local service, dir = start_service(t, "close-panes")
      setup(t, dir)
      confirm_yes(t)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      t.eq(true, controller.open_team("all"))
      local UI = ui()
      wait(function()
        return pane_win("tree") and pane_win("members") and pane_win("board")
      end, 5000, "all three panes")
      local chat_win = state().chat.win
      local input_win = state().input.win
      local session = state().sess.current
      vim.cmd("Ade team close")
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
      t.eq(nil, pane_win("tree"))
      t.eq(nil, pane_win("members"))
      t.eq(nil, pane_win("board"))
      -- The ordinary pair survives, unchanged, on the same session.
      t.eq(chat_win, state().chat.win, "the chat window is unchanged")
      t.eq(input_win, state().input.win, "the composer window is unchanged")
      t.eq(session, state().sess.current, "the leader session stays on screen")
    end)

    t.it("closing while a worker is watched returns to the leader", function()
      wise(t)
      local service, dir = start_service(t, "close-worker", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replay = { { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "worker line" } } },
        },
      })
      setup(t, dir)
      confirm_yes(t)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local UI = ui()
      t.eq(true, controller.open_team("all"))
      local watched
      team():watch("t1", "w1", true, function(ok)
        watched = ok
      end)
      wait(function()
        return watched
      end, 10000, "the watch")
      UI:watch(team().watching.session, "t1/w1")
      wait(function()
        return UI.router.target ~= nil and UI.router.target.participant == "w1"
      end, 5000, "the worker transcript")
      local leader = state().sess.current
      vim.cmd("Ade team close")
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      wait(function()
        return UI.router.target == nil
      end, 5000, "the chat to leave the worker")
      t.eq(leader, state().sess.current, "back on the leader conversation")
      t.eq(leader, state().chat.session, "the transcript shows the leader")
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
      t.eq(nil, team().watching, "the watch is released with the team")
    end)

    t.it("a close notification from another front end behaves the same way", function()
      wise(t)
      local service, dir = start_service(t, "close-remote-worker", {
        team_watch = { instance = "inst-w", sessionId = "sess-w" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      t.eq(true, controller.open_team("all"))
      local UI = ui()
      local watched
      team():watch("t1", "w1", true, function(ok)
        watched = ok
      end)
      wait(function()
        return watched
      end, 10000, "the watch")
      UI:watch(team().watching.session, "t1/w1")
      wait(function()
        return UI.router.target ~= nil
      end, 5000, "the worker transcript")
      local leader = state().sess.current
      -- The service says the team is gone; nothing in this front end asked.
      service:team_changed(vim.tbl_extend("force", {
        id = "t1",
        cwd = dir,
        state = "closed",
        leader = { instance = own_instance(), sessionId = "sess_mock" },
        participants = {},
        inbox = {},
        limits = {},
      }, {}))
      wait(function()
        return team():team("t1") == nil and UI.router.target == nil
      end, 5000, "the chat back on the leader")
      t.eq(leader, state().sess.current)
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
    end)

    t.it("edgy's external layout keeps the chat pair when the panes close", function()
      wise(t)
      local service, dir = start_service(t, "close-edgy")
      setup(t, dir, { layout = { backend = "external", input_height = 6 } })
      controller.open()
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      t.eq(true, controller.open_team("all"))
      local UI = ui()
      wait(function()
        return pane_win("members") ~= nil
      end, 5000, "the members pane")
      local chat_win = state().chat.win
      local input_win = state().input.win
      t.truthy(chat_win, "the panel was open before the team panes")
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "closed",
        leader = { instance = own_instance(), sessionId = "sess_mock" },
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away under the external backend")
      t.eq(chat_win, state().chat.win, "the chat window is unchanged")
      t.eq(input_win, state().input.win, "the composer window is unchanged")
      t.truthy(state().chat.win and vim.api.nvim_win_is_valid(state().chat.win), "the chat window is live")
      t.truthy(state().input.win and vim.api.nvim_win_is_valid(state().input.win), "the composer window is live")
    end)
  end)

  ---------------------------------------------------------------------------
  -- 1. What `session.teams {enabled:true}` means
  ---------------------------------------------------------------------------

  t.describe("teams v3.1 enable outcome", function()
    t.it("classifies every answer the service can give", function()
      t.eq("reload", Team.enable_outcome({ enabled = true, injected = false, reload = true }))
      t.eq("on", Team.enable_outcome({ enabled = true, injected = true }))
      t.eq("off", Team.enable_outcome({ enabled = false, injected = true }))
      t.eq("uninjected", Team.enable_outcome({ enabled = true, injected = false }))
      t.eq("uninjected", Team.enable_outcome(nil))
      -- The error the caller reads names the actual problem.
      t.match("turned off", Team.enable_error({ enabled = false }).message)
      t.match("did not inject", Team.enable_error({ enabled = true, injected = false }).message)
    end)

    t.it("`:Ade team on` does not claim success when the switch came back off", function()
      local service, dir = start_service(t, "on-cancelled", {
        session_teams_hold = 150,
        session_teams_hold_answers = { "off", "off" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local notices = capture(t)
      local key = tostring(own_instance()) .. "\0sess_mock"
      service.session_switches[key] = { enabled = true, injected = true }
      vim.cmd("Ade team on")
      wait(function()
        return joined(notices):find("cannot turn teams on", 1, true) ~= nil
      end, 8000, "the failure notice")
      t.match("turned off", joined(notices))
      t.falsy(joined(notices):find("teams are on for this chat", 1, true), joined(notices))
    end)

    t.it("an enable whose hold ends without injection is a failure", function()
      local service, dir = start_service(t, "on-uninjected", {
        session_teams_hold = 100,
        session_teams_hold_answers = { { enabled = true, injected = false, reload = false } },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local notices = capture(t)
      vim.cmd("Ade team on")
      wait(function()
        return joined(notices):find("cannot turn teams on", 1, true) ~= nil
      end, 8000, "the failure notice")
      t.match("did not inject", joined(notices))
      t.falsy(joined(notices):find("teams are on for this chat", 1, true), joined(notices))
    end)

    t.it("a successful enable still reports success once", function()
      local service, dir = start_service(t, "on-success")
      setup(t, dir)
      controller.connect()
      wait_ready()
      local notices = capture(t)
      service.session_switches[tostring(own_instance()) .. "\0sess_mock"] = { enabled = true, injected = true }
      vim.cmd("Ade team on")
      wait(function()
        return joined(notices):find("teams are on for this chat", 1, true) ~= nil
      end, 8000, "the success notice")
      t.falsy(joined(notices):find("cannot turn teams on", 1, true), joined(notices))
    end)

    t.it("the tree's `t` explains a cancelled enable instead of staying silent", function()
      local service, dir = start_service(t, "tree-cancelled", {
        session_teams_hold = 100,
        session_teams_hold_answers = { { enabled = true, injected = false, reload = false } },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local UI = ui()
      local notices = {}
      UI.notify_fn = function(message)
        notices[#notices + 1] = tostring(message)
      end
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = false, injected = true }
      local meta = {
        kind = "tree_session",
        session = { id = "sess_mock", cwd = dir, instance = inst },
        cwd = dir,
        instance = inst,
        online = true,
        switch = { enabled = false, injected = true },
      }
      t.eq(true, UI:handle_tree_key("t", meta))
      wait(function()
        return table.concat(notices, "\n"):find("cannot turn teams on", 1, true) ~= nil
      end, 8000, "the tree failure notice")
      t.truthy(table.concat(notices, "\n"):find("did not inject", 1, true))
    end)
  end)

  ---------------------------------------------------------------------------
  -- 2. Coalescing the in-progress enable
  ---------------------------------------------------------------------------

  t.describe("teams v3.1 coalesced enable", function()
    t.it("two `:Ade team on` calls send one write and wait once", function()
      local service, dir = start_service(t, "coalesce", { session_teams_hold = 1200 })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local notices = capture(t)
      local before = enable_writes(service)
      vim.cmd("Ade team on")
      vim.wait(120)
      vim.cmd("Ade team on")
      wait(function()
        return joined(notices):find(Team.ENABLE_WAIT_TEXT, 1, true) ~= nil
      end, 3000, "the in-progress notice")
      t.eq(before + 1, enable_writes(service), "one held write, not two")
      wait(function()
        return joined(notices):find("teams are on for this chat", 1, true) ~= nil
      end, 8000, "the single success notice")
      t.eq(before + 1, enable_writes(service), "still one write after the reply")
    end)

    t.it("a second start joins the enable in flight and starts once it lands", function()
      local service, dir = start_service(t, "coalesce-start", { session_teams_hold = 900 })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(items, _, cb)
        cb(items[1])
      end
      local prompted = 0
      vim.ui.input = function(_, cb)
        prompted = prompted + 1
        cb("")
      end
      service.session_switches[tostring(own_instance()) .. "\0sess_mock"] = { enabled = false, injected = true }
      local before = enable_writes(service)
      vim.cmd("Ade team start default")
      vim.wait(150)
      t.eq(true, require("ade.app.team_start").active(dir), "the start is waiting on the enable")
      vim.cmd("Ade team on")
      wait(function()
        return prompted > 0
      end, 15000, "the task prompt after the shared enable")
      t.eq(before + 1, enable_writes(service), "the on click joined the start's enable")
      wait(function()
        return #calls_of(service, "team.start") == 1
      end, 5000, "the start")
    end)

    t.it("a lost connection settles a held enable instead of waiting", function()
      local service, dir = start_service(t, "coalesce-lost", { session_teams_hold = 3000 })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local done, ok, value
      team():enable_session(own_instance(), "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end)
      vim.wait(150)
      t.falsy(done, "the enable is still held")
      -- The held reply will never arrive on a connection that is gone: the
      -- waiting start flow must be told, not left hanging.
      team():forget_connection()
      wait(function()
        return done
      end, 5000, "the cancelled enable")
      t.eq(false, ok)
      t.match("connection", tostring(type(value) == "string" and value or value.message))
    end)
  end)

  ---------------------------------------------------------------------------
  -- 5. Auth method picker: Esc ends the flow
  ---------------------------------------------------------------------------

  t.describe("teams v3.1 auth picker", function()
    local function harness()
      local notices = {}
      local client = { auth_methods = {}, capabilities = {}, authenticate = function() end }
      local failed
      local a = auth.new({
        config = function()
          return { agent = "opencode", cwd = "/tmp", agents = { opencode = { command = "opencode", args = { "acp" } } } }
        end,
        client = function()
          return client
        end,
        notify = function(message, level)
          notices[#notices + 1] = { message = message, level = level }
        end,
        restart = function() end,
        after_ready = function(fn)
          fn()
        end,
        open_terminal = function()
          return 1
        end,
        on_changed = function() end,
      })
      return { auth = a, client = client, notices = notices }
    end

    t.it("a dismissed method picker runs the creation failure callback", function()
      local h = harness()
      h.client.auth_methods = {
        { id = "a", name = "claude.ai" },
        { id = "b", name = "Console", type = "terminal", args = { "login" } },
      }
      local failed
      local original = picker.select
      local seen
      picker.select = function(opts)
        seen = opts
        -- Esc in the built-in picker calls `on_cancel`; `vim.ui.select` reports
        -- a dismissal as a nil choice. Both must end the login.
        opts.on_cancel()
      end
      local ok, err = pcall(function()
        h.auth:login(nil, function()
          error("the login must not retry after a cancel")
        end, function(message)
          failed = message
        end)
      end)
      picker.select = original
      if not ok then
        error(err, 0)
      end
      t.truthy(seen and type(seen.on_cancel) == "function", "the picker got an on_cancel")
      t.match("cancel", tostring(failed))
      t.eq(false, h.auth:is_running(), "a cancelled login is not left running")
    end)

    t.it("a dismissed prompt through vim.ui.select also ends the login", function()
      local h = harness()
      h.client.auth_methods = {
        { id = "a", name = "claude.ai" },
        { id = "b", name = "Console", type = "terminal", args = { "login" } },
      }
      local failed
      local original = vim.ui.select
      vim.ui.select = function(_, _, cb)
        cb(nil)
      end
      local ok, err = pcall(function()
        h.auth:login(nil, function()
          error("no retry after a dismissed picker")
        end, function(message)
          failed = message
        end)
      end)
      vim.ui.select = original
      if not ok then
        error(err, 0)
      end
      t.match("cancel", tostring(failed))
    end)

    t.it("an agent without a login method ends the waiting creation", function()
      local h = harness()
      local failed
      t.falsy(h.auth:login(nil, function() end, function(message)
        failed = message
      end))
      t.truthy(failed, "the caller was told nothing will happen")
    end)
  end)
end
