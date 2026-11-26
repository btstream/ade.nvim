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
    local State = require("ade.session.state")

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

    local function sent_frames(service, method)
      local out = {}
      for _, entry in ipairs(service.sent) do
        if type(entry.message) == "table" and entry.message.method == method then
          out[#out + 1] = entry.message
        end
      end
      return out
    end

    ---A second ordinary chat of the same project, loaded and idle.
    local function add_chat(id, dir, instance)
      local session = State.new(id, dir)
      session.agent_name = "opencode"
      session.instance = instance or own_instance()
      session.needs_load = false
      session.status = "idle"
      session.blocks = { { kind = "user", text = "chat " .. id } }
      state().sess.all[id] = session
      return session
    end

    t.it("a remote close of a watched worker returns to L, never closes A", function()
      wise(t)
      -- The canned agent advertises `session/close`, so "A was not closed" is a
      -- real statement: the idle close is available and `no_close` suppressed
      -- it (see "teams v3.1 close capability" for the positive control).
      local service, dir = start_service(t, "close-remote-leader", {
        canned_capabilities = { loadSession = true, sessionCapabilities = { close = {} } },
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replay = { { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "worker line" } } },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      t.eq(true, state().conn.client:has_session_capability("close"), "the agent offers `session/close`")
      -- A is the ordinary chat on screen; L is a different chat of the same
      -- project and leads the team. The worker was opened from A, so the
      -- generic "restore the previous chat" path would go back to A.
      local a = state().sess.current
      t.eq("sess_mock", a.id)
      a.status = "idle"
      local inst = own_instance()
      service:track_session(inst, { sessionId = "sess_mock", cwd = dir })
      local l = add_chat("sess_leader", dir, inst)
      seed_team(service, dir, { leader = { instance = inst, sessionId = "sess_leader" } })
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
      local closes_before = #sent_frames(service, "session/close")
      -- A different front end closes the team.
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "closed",
        leader = { instance = inst, sessionId = "sess_leader" },
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      wait(function()
        return UI.router.target == nil
      end, 5000, "the chat to leave the worker")
      t.eq(l, state().sess.current, "the leader conversation is shown, not A")
      t.eq(l, state().chat.session, "the transcript shows L")
      -- Leaving a worker is not a session switch the person asked for.
      t.eq(closes_before, #sent_frames(service, "session/close"), "A was not idle-closed")
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
    end)

    t.it("falls back to the previous chat when the leader is not local", function()
      wise(t)
      local service, dir = start_service(t, "close-remote-foreign", {
        team_watch = { instance = "inst-w", sessionId = "sess-w" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local a = state().sess.current
      a.status = "idle"
      seed_team(service, dir, { leader = { instance = "inst-elsewhere", sessionId = "sess_foreign" } })
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
        return UI.router.target ~= nil
      end, 5000, "the worker transcript")
      local notices = {}
      UI.notify_fn = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      local closes_before = #sent_frames(service, "session/close")
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "closed",
        leader = { instance = "inst-elsewhere", sessionId = "sess_foreign" },
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return UI.router.target == nil
      end, 5000, "the chat to leave the worker")
      t.eq(a, state().sess.current, "back on the chat that was there before")
      t.eq(closes_before, #sent_frames(service, "session/close"), "and it is not closed")
      local text = {}
      for _, note in ipairs(notices) do
        text[#text + 1] = note.message
      end
      t.match("leader", table.concat(text, "\n"))
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
    end)

    t.it("falls back when the service's leader instance is missing", function()
      wise(t)
      local service, dir = start_service(t, "close-leader-no-instance", {
        team_watch = { instance = "inst-w", sessionId = "sess-w" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local a = state().sess.current
      a.status = "idle"
      -- A local chat carries the leader's id; the service omitted `instance`,
      -- so a bare-id match is a guess and must not be trusted.
      add_chat("sess_leader", dir, own_instance())
      -- `vim.NIL` makes the encoded row carry an explicit `null` instance, so a
      -- deep-extend cannot fall back to the default pair.
      seed_team(service, dir, { leader = { instance = vim.NIL, sessionId = "sess_leader" } })
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
        return UI.router.target ~= nil
      end, 5000, "the worker transcript")
      local closes_before = #sent_frames(service, "session/close")
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "closed",
        leader = { sessionId = "sess_leader" },
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return UI.router.target == nil
      end, 5000, "the chat to leave the worker")
      t.eq(a, state().sess.current, "an unknown leader instance restores the previous chat")
      t.eq(closes_before, #sent_frames(service, "session/close"), "A was not closed")
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
    end)

    t.it("falls back when the local session's instance is unknown", function()
      wise(t)
      local service, dir = start_service(t, "close-local-no-instance", {
        team_watch = { instance = "inst-w", sessionId = "sess-w" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local a = state().sess.current
      a.status = "idle"
      local inst = own_instance()
      local l = add_chat("sess_leader", dir, inst)
      l.instance = nil
      seed_team(service, dir, { leader = { instance = inst, sessionId = "sess_leader" } })
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
        return UI.router.target ~= nil
      end, 5000, "the worker transcript")
      local closes_before = #sent_frames(service, "session/close")
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "closed",
        leader = { instance = inst, sessionId = "sess_leader" },
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return UI.router.target == nil
      end, 5000, "the chat to leave the worker")
      t.eq(a, state().sess.current, "the previous chat comes back, not the same-id session")
      t.eq(closes_before, #sent_frames(service, "session/close"), "A was not closed")
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
    end)

    t.it("the tree's `x` closes the team and its panes", function()
      wise(t)
      local service, dir = start_service(t, "close-tree-x", {
        team_watch = { instance = "inst-w", sessionId = "sess-w" },
      })
      setup(t, dir)
      confirm_yes(t)
      controller.connect()
      wait_ready()
      local a = state().sess.current
      a.status = "idle"
      local inst = own_instance()
      local l = add_chat("sess_leader", dir, inst)
      seed_team(service, dir, { leader = { instance = inst, sessionId = "sess_leader" } })
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
        return UI.router.target ~= nil
      end, 5000, "the worker transcript")
      local closes_before = #sent_frames(service, "session/close")
      -- Real key on the tree's leader row.
      local meta = {
        kind = "tree_session",
        session = l,
        cwd = dir,
        instance = inst,
        online = true,
        leader = true,
        team = { id = "t1", cwd = dir },
      }
      t.eq(true, UI:handle_tree_key("x", meta))
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      wait(function()
        return UI.router.target == nil
      end, 5000, "back from the worker")
      t.eq(l, state().sess.current, "the tree close lands on L")
      t.eq(closes_before, #sent_frames(service, "session/close"), "A was not closed")
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
    end)

    t.it("`:Ade team off` with the close confirmation ends the panes", function()
      wise(t)
      local service, dir = start_service(t, "close-off")
      setup(t, dir)
      confirm_yes(t)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = true }
      seed_team(service, dir)
      local UI = ui()
      t.eq(true, controller.open_team("all"))
      local current = state().sess.current
      vim.cmd("Ade team off")
      wait(function()
        return team():team("t1") == nil
      end, 8000, "the team closed by the switch")
      wait(function()
        return not UI.layout:is_open()
      end, 5000, "the panes to go away")
      t.eq(current, state().sess.current, "the leader's chat stays on screen")
      t.eq(nil, pane_win("members"))
      t.eq(nil, pane_win("board"))
      t.eq(nil, pane_win("tree"))
    end)

    t.it("a board showing another project's team survives that close", function()
      wise(t)
      local other_dir = tmpdir("keep-board-other")
      local service, dir = start_service(t, "keep-board")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local other = {
        id = "t9",
        cwd = other_dir,
        state = "active",
        leader = { instance = "inst-other", sessionId = "sess-other" },
        participants = { { name = "leader", state = "idle", task = "_", queued = 0, turns = {} } },
        inbox = {},
        limits = {},
      }
      service.teams.t9 = vim.deepcopy(other)
      service:team_changed(other)
      wait(function()
        return team():team("t9") ~= nil
      end, 5000, "the other team")
      local UI = ui()
      -- Open the tree too, so the assert below proves it is kept.
      t.eq(true, controller.open_team("all"))
      wait(function()
        return pane_win("members") ~= nil and pane_win("tree") ~= nil
      end, 5000, "the members and tree panes")
      -- `b` on the other project's row pins its board.
      t.eq(true, UI:handle_tree_key("b", { kind = "tree_project", cwd = other_dir }))
      wait(function()
        return pane_win("board") ~= nil
      end, 5000, "the board of the other project")
      wait(function()
        return UI.board_team_id == "t9"
      end, 5000, "the board's real target")
      -- Now this project's team closes. Its members pane loses its subject,
      -- but the board shows t9 and must stay.
      service:team_changed(vim.tbl_extend("force", {
        id = "t1",
        cwd = dir,
        state = "closed",
        participants = {},
        inbox = {},
        limits = {},
      }, { leader = nil }))
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      wait(function()
        return UI.board_team_id == "t9"
      end, 3000, "the board keeps showing t9")
      t.truthy(pane_win("board"), "the board showing another team stays")
      t.truthy(pane_win("tree"), "the project tree stays while another team exists")
      wait(function()
        return pane_win("members") == nil
      end, 3000, "the members pane showing the closed team to close")
      UI:close()
    end)

    t.it("a members pane on this project closes with its only team", function()
      wise(t)
      local service, dir = start_service(t, "close-members-only")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local UI = ui()
      t.eq(true, controller.open_team("members"))
      wait(function()
        return pane_win("members") ~= nil and UI.members_team_id == "t1"
      end, 5000, "the members pane")
      service:team_changed(vim.tbl_extend("force", {
        id = "t1",
        cwd = dir,
        state = "closed",
        participants = {},
        inbox = {},
        limits = {},
      }, { leader = nil }))
      wait(function()
        return pane_win("members") == nil
      end, 5000, "the members pane to close with its team")
      t.eq(nil, pane_win("board"))
      t.eq(nil, pane_win("tree"))
    end)

    t.it("edgy's external mode keeps the chat pair when the panes close", function()
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
      t.truthy(chat_win and vim.api.nvim_win_is_valid(chat_win), "the chat window is live")
      t.truthy(input_win and vim.api.nvim_win_is_valid(input_win), "the composer window is live")
    end)
  end)

  ---------------------------------------------------------------------------
  -- 0c. Pane split widths must not disturb ordinary windows
  ---------------------------------------------------------------------------

  t.describe("teams v3.1 pane layout", function()
    local function sidebar(t, width)
      local win = vim.api.nvim_get_current_win()
      vim.cmd("vsplit")
      local side = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_width(side, width)
      vim.wo[side].winfixwidth = true
      t.cleanup(function()
        if vim.api.nvim_win_is_valid(side) then
          pcall(function()
            vim.wo[side].winfixwidth = false
          end)
        end
        if win and vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_set_current_win, win)
        end
      end)
      return side
    end

    t.it("opens in the current tab without touching fixed ordinary sidebars", function()
      local old = vim.o.columns
      vim.o.columns = 200
      t.cleanup(function()
        vim.o.columns = old
        -- Leave the shared window layout sized for the restored screen: a test
        -- that widened it must not hand the next case windows wider than fit.
        pcall(vim.cmd, "wincmd =")
      end)
      local service, dir = start_service(t, "pane-layout")
      setup(t, dir)
      controller.connect()
      wait_ready()
      -- A tab of this test's own: earlier cases leave pinned ade windows in
      -- the shared tab, and this case is about ordinary sidebars only. The
      -- harness closes every tab but the first after the case.
      vim.cmd("tabnew")
      local here = vim.api.nvim_get_current_tabpage()
      local current_side = sidebar(t, 30)
      local current_width = vim.api.nvim_win_get_width(current_side)
      -- Another tab with its own fixed-width sidebar.
      vim.cmd("tabnew")
      local other = vim.api.nvim_get_current_tabpage()
      local other_side = sidebar(t, 24)
      local other_width = vim.api.nvim_win_get_width(other_side)
      vim.api.nvim_set_current_tabpage(here)
      local UI = ui()
      t.eq(true, controller.open_team("members"))
      wait(function()
        return pane_win("members") ~= nil
      end, 5000, "the members pane")
      t.eq(here, vim.api.nvim_win_get_tabpage(pane_win("members")), "the pane opens in the tab it was asked from")
      t.eq(current_width, vim.api.nvim_win_get_width(current_side), "the current tab's sidebar keeps its width")
      t.eq(true, vim.wo[current_side].winfixwidth, "and its fixed-width option")
      t.eq(other_width, vim.api.nvim_win_get_width(other_side), "the other tab's sidebar keeps its width")
      t.eq(true, vim.wo[other_side].winfixwidth, "and its fixed-width option")
      t.eq(other, vim.api.nvim_win_get_tabpage(other_side))
      UI:close()
    end)

    ---Build a native-like tab: a pinned ade_* chat/composer panel of `width`
    ---columns, with an ordinary document window beside it. `width = 0` uses the
    ---configured panel width for `columns`.
    ---@param t table
    ---@param columns integer
    ---@param width integer
    ---@param backend string|nil
    ---@return table pane, integer chat, integer doc
    local function native_panel(t, columns, width, backend)
      local layout = require("ade.ui.team.layout_pane")
      local old = vim.o.columns
      vim.o.columns = columns
      t.cleanup(function()
        vim.o.columns = old
        pcall(vim.cmd, "wincmd =")
      end)
      local cfg = {
        layout = { backend = backend or "native" },
        teams = { dashboard = { members_width = 32 } },
      }
      -- `external_layout()` reads the module-level backend, so the pane's
      -- config alone is not enough: set the layout module too.
      local ade_layout = require("ade.layout")
      local saved_backend = ade_layout.backend()
      ade_layout.setup(require("ade.config").merge(require("ade.config").defaults, cfg))
      t.cleanup(function()
        ade_layout.setup(
          require("ade.config").merge(require("ade.config").defaults, { layout = { backend = saved_backend } })
        )
      end)
      local pane = layout.new({
        config = function()
          return cfg
        end,
        notify = function() end,
      })
      vim.cmd("tabnew")
      local doc = vim.api.nvim_get_current_win()
      vim.cmd("vsplit")
      local chat = vim.api.nvim_get_current_win()
      local chat_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[chat_buf].filetype = "ade_test_chat"
      vim.api.nvim_win_set_buf(chat, chat_buf)
      vim.wo[chat].winfixwidth = false
      local want = width
      if want <= 0 then
        local cfg_mod = require("ade.config")
        want = cfg_mod.panel_width(cfg_mod.effective(), columns)
      end
      pcall(vim.api.nvim_win_set_width, chat, want)
      vim.wo[chat].winfixwidth = true
      vim.cmd("belowright split")
      local input = vim.api.nvim_get_current_win()
      local input_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[input_buf].filetype = "ade_test_input"
      vim.api.nvim_win_set_buf(input, input_buf)
      vim.wo[input].winfixwidth = true
      t.cleanup(function()
        for _, win in ipairs({ chat, input }) do
          if vim.api.nvim_win_is_valid(win) then
            pcall(function()
              vim.wo[win].winfixwidth = false
            end)
          end
        end
        if doc and vim.api.nvim_win_is_valid(doc) then
          pcall(vim.api.nvim_set_current_win, doc)
        end
      end)
      return pane, chat, doc
    end

    ---Column widths of the panel, the document window, members and the board.
    ---@return table
    local function widths(chat, doc, members, board)
      local out = {
        chat = vim.api.nvim_win_get_width(chat),
        doc = vim.api.nvim_win_get_width(doc),
      }
      if members and vim.api.nvim_win_is_valid(members) then
        out.members = vim.api.nvim_win_get_width(members)
      end
      if board and vim.api.nvim_win_is_valid(board) then
        out.board = vim.api.nvim_win_get_width(board)
      end
      return out
    end

    t.it("keeps ade's panel at or above its configured width at every screen size", function()
      -- The pane's wanted width is soft: at 80/100/120 columns there is simply
      -- no room for a 32-wide members + a 56-wide board beside the panel, so
      -- the team panes take what is free and the panel keeps its own width.
      -- Anything that pulled a pane to its wanted width by force would have to
      -- squeeze the panel under `panel_width`.
      local layout = require("ade.ui.team.layout_pane")
      local cfg = require("ade.config")
      for _, columns in ipairs({ 80, 100, 120, 170, 300 }) do
        local pane, chat, doc = native_panel(t, columns, 0)
        local panel_width = cfg.panel_width(cfg.effective(), columns)
        local start_chat = vim.api.nvim_win_get_width(chat)
        t.eq(panel_width, start_chat, "the panel starts at its configured width at " .. columns)
        local start_doc = vim.api.nvim_win_get_width(doc)
        local members = pane:create_split("members")
        t.truthy(members, "members opened at " .. columns)
        pane.windows.members = members
        t.eq(
          panel_width,
          vim.api.nvim_win_get_width(chat),
          "members never takes the panel under its width at " .. columns
        )
        local board = pane:create_split("board")
        t.truthy(board, "the board opened at " .. columns)
        pane.windows.board = board
        t.eq(
          panel_width,
          vim.api.nvim_win_get_width(chat),
          "the board never takes the panel under its width at " .. columns
        )
        t.truthy(
          vim.api.nvim_win_get_width(board) >= 8,
          "the board keeps at least a sliver at " .. columns .. ", got " .. vim.api.nvim_win_get_width(board)
        )
        if columns >= 300 then
          t.eq(56, vim.api.nvim_win_get_width(board), "a wide screen gives the board its wanted width")
          t.eq(32, vim.api.nvim_win_get_width(members), "a wide screen gives members its wanted width")
        end
        -- The document window is never pushed below what a plain `:vsplit`
        -- leaves it: it is not ours to resize.
        t.truthy(vim.api.nvim_win_get_width(doc) >= 1, "the document window survives at " .. columns)
        t.truthy(start_doc >= 1, "the document window existed at " .. columns)
        pane:close()
        t.eq(start_chat, vim.api.nvim_win_get_width(chat), "the panel is back at its width at " .. columns)
        t.eq(start_doc, vim.api.nvim_win_get_width(doc), "the document window is back at its width at " .. columns)
      end
    end)

    t.it("borrows only the missing columns from ade's panel", function()
      -- 120 columns with a 90-column panel: the panel has 25 columns above its
      -- configured 65, and that is all members may take.
      local pane, chat = native_panel(t, 120, 90)
      local before = vim.api.nvim_win_get_width(chat)
      t.eq(90, before, "the panel starts at 90 columns")
      local members = pane:create_split("members")
      pane.windows.members = members
      local lent = before - vim.api.nvim_win_get_width(chat)
      t.eq(12, lent, "members borrowed exactly the columns it was short of")
      t.eq(32, vim.api.nvim_win_get_width(members), "members reached its wanted width")
      t.truthy(vim.api.nvim_win_get_width(chat) >= 65, "the panel stayed at or above its configured width")
      pane:close()
      t.eq(before, vim.api.nvim_win_get_width(chat), "closing members gives the columns back")
    end)

    t.it("leaves a panel width the person changed during a pane alone", function()
      local pane, chat = native_panel(t, 120, 90)
      local members = pane:create_split("members")
      pane.windows.members = members
      t.eq(78, vim.api.nvim_win_get_width(chat), "members borrowed 12 columns")
      -- The person drags the panel while the pane is open.
      vim.wo[chat].winfixwidth = false
      vim.api.nvim_win_set_width(chat, 70)
      vim.wo[chat].winfixwidth = true
      pane:close_pane("members")
      t.eq(70, vim.api.nvim_win_get_width(chat), "the person's width is not undone")
    end)

    t.it("gives the panel back its width whichever pane closes first", function()
      for _, order in ipairs({ { "members", "board" }, { "board", "members" } }) do
        local pane, chat = native_panel(t, 120, 90)
        local start = vim.api.nvim_win_get_width(chat)
        pane.windows.members = pane:create_split("members")
        pane.windows.board = pane:create_split("board")
        t.truthy(vim.api.nvim_win_get_width(chat) < start, "the panes borrowed while both were open")
        pane:close_pane(order[1])
        t.truthy(vim.api.nvim_win_is_valid(chat), "the panel survives the first close")
        pane:close_pane(order[2])
        t.eq(
          start,
          vim.api.nvim_win_get_width(chat),
          "the panel is back at " .. start .. " columns after " .. order[1] .. " then " .. order[2]
        )
      end
    end)

    t.it("restores nothing when it borrowed nothing", function()
      -- A wide screen has room for every pane beside the panel, so no columns
      -- are borrowed and closing must not move the panel at all.
      local pane, chat = native_panel(t, 300, 100)
      local before = vim.api.nvim_win_get_width(chat)
      pane.windows.members = pane:create_split("members")
      t.eq(before, vim.api.nvim_win_get_width(chat), "members borrowed nothing")
      pane.windows.board = pane:create_split("board")
      t.eq(before, vim.api.nvim_win_get_width(chat), "the board borrowed nothing")
      pane:close()
      t.eq(before, vim.api.nvim_win_get_width(chat), "closing with no loan leaves the panel alone")
    end)

    t.it("leaves ade's panel alone under an external layout manager", function()
      -- edgy owns window placement under `backend == "external"`: the team
      -- panes never borrow from ade's own windows and never undo a width the
      -- manager set. The panel here starts at its configured width, so any
      -- narrowing would have to come from our own code.
      -- The panel starts far wider than its configured 65, so there are
      -- plenty of columns a native split would borrow — and the external
      -- backend must still leave every one of them alone.
      local pane, chat = native_panel(t, 170, 130, "external")
      local before = vim.api.nvim_win_get_width(chat)
      t.eq(130, before, "the panel starts at 130 columns")
      local members = pane:create_split("members")
      t.truthy(members, "members opened")
      pane.windows.members = members
      t.eq(0, pane:lendable_columns(), "nothing is lendable under an external layout")
      -- `:vsplit` itself may shave the panel; what must not happen is the
      -- plugin borrowing on top of that. Compare against the width `:vsplit`
      -- left, and require the board not to take more than that.
      local after_members = vim.api.nvim_win_get_width(chat)
      t.truthy(after_members >= before - 20, "members borrowed nothing on its own, got " .. after_members)
      local board = pane:create_split("board")
      t.truthy(board, "the board opened")
      pane.windows.board = board
      t.eq(after_members, vim.api.nvim_win_get_width(chat), "the board borrowed nothing either")
      -- The manager decides a different width while the panes are up.
      vim.wo[chat].winfixwidth = false
      vim.api.nvim_win_set_width(chat, 30)
      vim.wo[chat].winfixwidth = true
      pane:close()
      t.eq(30, vim.api.nvim_win_get_width(chat), "the manager's width is kept on close")
    end)

    t.it("a failed `vsplit` restores the team pane's fixed option", function()
      local old = vim.o.columns
      vim.o.columns = 200
      t.cleanup(function()
        vim.o.columns = old
        pcall(vim.cmd, "wincmd =")
      end)
      local service, dir = start_service(t, "pane-layout-fail")
      setup(t, dir)
      controller.connect()
      wait_ready()
      vim.cmd("tabnew")
      -- An ordinary fixed sidebar that the failed split must leave untouched.
      local side = sidebar(t, 26)
      local side_width = vim.api.nvim_win_get_width(side)
      local UI = ui()
      t.eq(true, controller.open_team("members"))
      wait(function()
        return pane_win("members") ~= nil
      end, 5000, "the members pane")
      local members = pane_win("members")
      local width = vim.api.nvim_win_get_width(members)
      t.eq(true, vim.wo[members].winfixwidth)
      -- Focus the members pane, exactly as `:Ade team board` would be run from
      -- it; the failed split must put the cursor back here.
      pcall(vim.api.nvim_set_current_win, members)
      t.eq(members, vim.api.nvim_get_current_win(), "the members pane has the cursor")
      local real_cmd = vim.cmd
      vim.cmd = function(...)
        local arg = ...
        if arg == "botright vsplit" then
          error("simulated split failure")
        end
        return real_cmd(...)
      end
      t.cleanup(function()
        vim.cmd = real_cmd
      end)
      t.eq(false, UI.layout:show("board"), "the failed split reports itself")
      t.eq(true, vim.api.nvim_win_is_valid(members), "the existing pane is still there")
      t.eq(true, vim.wo[members].winfixwidth, "its fixed-width option is restored")
      t.eq(width, vim.api.nvim_win_get_width(members), "and its width is unchanged")
      t.eq(nil, pane_win("board"))
      t.eq(members, vim.api.nvim_get_current_win(), "the cursor returns to where it was")
      t.eq(side_width, vim.api.nvim_win_get_width(side), "the ordinary sidebar keeps its width")
      t.eq(true, vim.wo[side].winfixwidth, "and its fixed-width option")
      UI:close()
    end)
  end)

  ---------------------------------------------------------------------------
  -- A.1 The close capability: the guard above is only meaningful with it
  ---------------------------------------------------------------------------

  t.describe("teams v3.1 close capability", function()
    local State = require("ade.session.state")

    ---The same canned agent as the close cases: it really offers
    ---`session/close`, so a missing close is a decision, not a limitation.
    local function start_closeable(t, tag, opts)
      return start_service(
        t,
        tag,
        vim.tbl_extend("force", {
          canned_capabilities = { loadSession = true, sessionCapabilities = { close = {} } },
        }, opts or {})
      )
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

    ---A second ordinary chat of the same project, loaded and idle.
    local function add_chat(id, dir, instance)
      local session = State.new(id, dir)
      session.agent_name = "opencode"
      session.instance = instance or own_instance()
      session.needs_load = false
      session.status = "idle"
      session.blocks = {}
      state().sess.all[id] = session
      return session
    end

    t.it("a manual session switch does idle-close the chat it leaves", function()
      local service, dir = start_closeable(t, "close-cap-manual")
      setup(t, dir)
      controller.connect()
      wait_ready()
      t.eq(true, state().conn.client:has_session_capability("close"), "the agent offers `session/close`")
      -- A is the chat on screen and, importantly, leads no team: nothing but
      -- the ordinary switch can keep it from being idle-closed.
      local a = state().sess.current
      t.eq("sess_mock", a.id)
      a.status = "idle"
      t.eq(nil, team():team_for_cwd(dir), "no team protects A in this control")
      local inst = own_instance()
      service:track_session(inst, { sessionId = "sess_mock", cwd = dir })
      local b = add_chat("sess_b", dir, inst)
      service:track_session(inst, { sessionId = "sess_b", cwd = dir })
      local before = #sent_frames(service, "session/close")
      -- `:Ade sessions` <CR> / the tree's <CR>: load the chosen session. This
      -- is the ordinary switch path, not the team-closed one, so it carries no
      -- `no_close`.
      controller.load_session("sess_b")
      wait(function()
        return #sent_frames(service, "session/close") > before
      end, 15000, "the idle close of the chat the switch left")
      t.eq("sess_mock", sent_frames(service, "session/close")[before + 1].params.sessionId)
      -- The replay commits a fresh projection of the same id, so compare ids.
      t.eq(b.id, state().sess.current and state().sess.current.id, "the chosen chat is on screen")
    end)

    t.it("an agent without the capability never receives `session/close`", function()
      -- The negative half: the same switch on an agent that does not advertise
      -- `close` sends nothing, which is why the earlier cases needed the
      -- capability before they could prove anything about `no_close`.
      local service, dir = start_service(t, "close-cap-none")
      setup(t, dir)
      controller.connect()
      wait_ready()
      t.eq(false, state().conn.client:has_session_capability("close"), "the agent does not offer `session/close`")
      local a = state().sess.current
      a.status = "idle"
      local inst = own_instance()
      service:track_session(inst, { sessionId = "sess_mock", cwd = dir })
      add_chat("sess_b", dir, inst)
      service:track_session(inst, { sessionId = "sess_b", cwd = dir })
      local before = #sent_frames(service, "session/close")
      controller.load_session("sess_b")
      wait(function()
        return state().sess.current and state().sess.current.id == "sess_b"
      end, 15000, "the switch without a close capability")
      vim.wait(200)
      t.eq(before, #sent_frames(service, "session/close"), "no close is sent without the capability")
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
        session_injected_default = false,
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local notices = capture(t)
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
        session_injected_default = false,
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
        session_teams_hold_answers = { "off", "off" },
        session_injected_default = false,
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
      t.truthy(table.concat(notices, "\n"):find("turned off", 1, true))
    end)
  end)

  ---------------------------------------------------------------------------
  -- 2. Coalescing the in-progress enable
  ---------------------------------------------------------------------------

  t.describe("teams v3.1 coalesced enable", function()
    t.it("two `:Ade team on` calls send one write and wait once", function()
      local service, dir = start_service(t, "coalesce", {
        session_teams_hold = 1200,
        session_injected_default = false,
      })
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

    t.it("a second `:Ade team start` joins the first start's enable", function()
      local service, dir = start_service(t, "coalesce-two-starts", {
        session_teams_hold = 900,
        session_injected_default = false,
      })
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
      t.eq(true, require("ade.app.team_start").active(dir), "the first start waits on the enable")
      -- A second start of the same project supersedes the first flow but must
      -- join the enable in flight instead of sending another held write.
      vim.cmd("Ade team start default")
      wait(function()
        return prompted > 0
      end, 20000, "the task prompt after the shared enable")
      t.eq(before + 1, enable_writes(service), "the second start joined the first enable")
      wait(function()
        return #calls_of(service, "team.start") == 1
      end, 5000, "one team.start")
    end)

    t.it("a lost connection settles a held enable instead of waiting", function()
      local service, dir = start_service(t, "coalesce-lost", {
        session_teams_hold = 8000,
        session_injected_default = false,
      })
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
      -- waiting start flow must be told, not left hanging. This closes the real
      -- socket, so the front end's own disconnect path runs.
      service:close()
      wait(function()
        return done
      end, 6000, "the cancelled enable")
      t.eq(false, ok)
      t.match("connection", tostring(type(value) == "string" and value or value.message))
    end)
  end)

  ---------------------------------------------------------------------------
  -- 2b. What settles an enable whose load asked for a reload
  ---------------------------------------------------------------------------

  t.describe("teams v3.1 reload settlement", function()
    local function sent(service, method)
      local out = {}
      for _, entry in ipairs(service.sent) do
        if type(entry.message) == "table" and entry.message.method == method then
          out[#out + 1] = entry.message
        end
      end
      return out
    end

    local function start_canned(t, tag, opts)
      return start_service(
        t,
        tag,
        vim.tbl_extend("force", {
          canned_capabilities = { loadSession = true, sessionCapabilities = { close = {}, resume = {} } },
        }, opts or {})
      )
    end

    t.it("does not invent `injected` when the MCP process never connects", function()
      local service, dir = start_canned(t, "reload-never", { session_load_never_injects = true })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local notices = capture(t)
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok, value
      team():enable_session(inst, "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end, { wait_ms = 8000 })
      wait(function()
        return done
      end, 4000, "the enable to settle")
      t.eq(false, ok, "a load alone is not an injected session")
      t.match("did not inject", tostring(type(value) == "table" and value.message or value))
      t.falsy(joined(notices):find("teams are on for this chat", 1, true))
    end)

    t.it("a handshake before the load reply cannot settle the enable", function()
      -- PROTOCOL.md 20.5: the one-shot mark is consumed when the load frame is
      -- *written*, so the service may publish `injected: true` while the load's
      -- own reply is still in flight. That notification is no proof of success.
      local service, dir = start_canned(t, "reload-early-fail", {
        canned_load_delay_ms = 500,
        canned_load_error = { code = -32602, message = "session cwd mismatch" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok, value
      team():enable_session(inst, "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end, { wait_ms = 8000 })
      wait(function()
        return #sent(service, "session/load") > 0
      end, 5000, "the load frame")
      -- The handshake landed before the (delayed) load reply.
      wait(function()
        local cached = team():session_teams(inst, "sess_mock")
        return cached ~= nil and cached.injected == true
      end, 3000, "the early handshake")
      vim.wait(150)
      t.falsy(done, "an injected notification before the load cannot report success")
      wait(function()
        return done
      end, 4000, "the load failure to settle the enable")
      t.eq(false, ok, "the failed load settles it as a failure")
      t.match("cannot reload", tostring(type(value) == "table" and value.message or value))
    end)

    t.it("waits for `session.teams_changed` and succeeds once it injects", function()
      -- After a successful load the service may still be waiting for the MCP
      -- process: the query says `pending: true`, so the enable waits for the
      -- notification instead of settling. `session_load_never_injects` keeps the
      -- fake from injecting on the load frame, so this really exercises the
      -- waiting branch instead of the cache-already-injected shortcut.
      local service, dir = start_canned(t, "reload-late", {
        session_load_never_injects = true,
        session_teams_query_pending = true,
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok, value
      team():enable_session(inst, "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end, { wait_ms = 8000 })
      wait(function()
        return #sent(service, "session/load") > 0
      end, 5000, "the load frame")
      -- The load succeeds; the MCP handshake arrives afterwards.
      wait(function()
        local cached = team():session_teams(inst, "sess_mock")
        return cached ~= nil and cached.injected == false
      end, 5000, "the load reply")
      t.falsy(done, "nothing settles while the service waits for the MCP process")
      vim.defer_fn(function()
        local key = tostring(inst) .. "\0sess_mock"
        service.session_switches[key] = { enabled = true, injected = true }
        service:emit_session_teams(inst, "sess_mock")
      end, 250)
      wait(function()
        return done
      end, 10000, "the enable to settle on the injection")
      t.eq(true, ok, "the late injection settles it as success")
      t.eq(true, type(value) == "table" and value.injected == true)
    end)

    t.it("a handshake before a successful load reply still settles on the load", function()
      local service, dir = start_canned(t, "reload-early-ok", {
        canned_load_delay_ms = 500,
        session_teams_query_pending = true,
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok, value
      team():enable_session(inst, "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end, { wait_ms = 8000 })
      wait(function()
        return #sent(service, "session/load") > 0
      end, 5000, "the load frame")
      wait(function()
        local cached = team():session_teams(inst, "sess_mock")
        return cached ~= nil and cached.injected == true
      end, 3000, "the early handshake")
      vim.wait(150)
      t.falsy(done, "the handshake alone is not the load's success")
      wait(function()
        return done
      end, 4000, "the successful load to settle the enable")
      t.eq(true, ok, "the load succeeded and the switch is injected")
      t.eq(true, type(value) == "table" and value.injected == true)
    end)

    t.it("`pending: false` fails at once instead of waiting out the hold", function()
      local service, dir = start_canned(t, "reload-not-pending", { session_load_never_injects = true })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok
      team():enable_session(inst, "sess_mock", function(result)
        done, ok = true, result
      end, { wait_ms = 8000 })
      local started = vim.uv.now()
      wait(function()
        return done
      end, 4000, "the enable to settle")
      local elapsed = vim.uv.now() - started
      t.eq(false, ok, "no tools means no success")
      t.truthy(elapsed < 5000, "`pending: false` must not wait the whole ten seconds")
    end)

    t.it("a failed switch query fails at once instead of waiting", function()
      local service, dir = start_canned(t, "reload-query-error", {
        session_load_never_injects = true,
        session_teams_query_error = true,
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok, value
      team():enable_session(inst, "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end, { wait_ms = 8000 })
      local started = vim.uv.now()
      wait(function()
        return done
      end, 4000, "the failed query to settle the enable")
      local elapsed = vim.uv.now() - started
      t.eq(false, ok, "an unreadable switch means the tools are not proven")
      t.match("cannot read", tostring(type(value) == "table" and value.message or value))
      t.truthy(elapsed < 5000, "a failed query must not wait out the hold")
    end)

    t.it("`pending: true` that never handshakes fails after `wait_ms`", function()
      local service, dir = start_canned(t, "reload-pending-timeout", {
        session_load_never_injects = true,
        session_teams_query_pending = true,
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok, value
      team():enable_session(inst, "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end, { wait_ms = 400 })
      local started = vim.uv.now()
      wait(function()
        return done
      end, 5000, "the pending wait to time out")
      local elapsed = vim.uv.now() - started
      t.eq(false, ok, "a handshake that never comes is a failure")
      t.match("did not inject", tostring(type(value) == "table" and value.message or value))
      t.truthy(elapsed >= 300, "it must actually wait for the handshake first")
    end)

    t.it("a successful off during a slow load wins over the enable", function()
      local service, dir = start_canned(t, "reload-off", { canned_load_delay_ms = 700 })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok, value
      team():enable_session(inst, "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end, { wait_ms = 5000 })
      wait(function()
        return #sent(service, "session/load") > 0
      end, 3000, "the load frame")
      -- The person turns the switch off while the load is still replaying.
      local off_done, off_ok
      team():set_session_teams(inst, "sess_mock", false, false, function(result)
        off_done, off_ok = true, result
      end)
      wait(function()
        return off_done
      end, 3000, "the off reply")
      t.eq(true, off_ok, "the off succeeded")
      wait(function()
        return done
      end, 12000, "the enable to settle after the off")
      t.eq(false, ok, "the late load must not report success")
      t.match("turned off", tostring(type(value) == "table" and value.message or value))
    end)

    t.it("a refused off leaves the enable to report its own outcome", function()
      local service, dir = start_canned(t, "reload-off-refused", {
        canned_load_delay_ms = 400,
        -- The refusal reaches the front end only after the load has settled:
        -- a pre-emptive supersede at write time would then misreport a success
        -- as "turned off".
        session_teams_off_error = true,
        session_teams_off_delay = 1200,
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local inst = own_instance()
      service.session_switches[tostring(inst) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(inst) .. "\0sess_mock"] = nil
      local done, ok, value
      team():enable_session(inst, "sess_mock", function(result, reason)
        done, ok, value = true, result, reason
      end, { wait_ms = 8000 })
      wait(function()
        return #sent(service, "session/load") > 0
      end, 3000, "the load frame")
      local off_done, off_ok
      team():set_session_teams(inst, "sess_mock", false, false, function(result)
        off_done, off_ok = true, result
      end)
      wait(function()
        return off_done
      end, 5000, "the refused off reply")
      t.eq(false, off_ok, "the service refused the off")
      wait(function()
        return done
      end, 12000, "the enable to settle on its own load")
      t.eq(true, ok, "a refused off must not be read as a supersede")
      t.eq(true, type(value) == "table" and value.injected == true)
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
    t.it("a real `session/new` auth failure ends the start when the picker is cancelled", function()
      -- The start flow needs a replacement session (the agent cannot reload in
      -- place) and that `session/new` fails with auth_required while offering
      -- two login methods. Esc in the picker must end the start instead of
      -- leaving it parked: no task prompt, no team.start.
      local service, dir = start_service(t, "auth-real", {
        canned_auth_methods = {
          { id = "claude", name = "claude.ai" },
          { id = "console", name = "Console", type = "terminal", args = { "login" } },
        },
        session_new_auth_error = true,
        session_new_auth_after = 1,
        session_reload_unsupported = true,
      })
      setup(t, dir)
      controller.connect()
      wait(function()
        local S = state()
        return S.conn.phase == "ready" and S.sess.current ~= nil
      end, 25000, "the panel to be ready")
      local TeamStart = require("ade.app.team_start")
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      local picker_seen = false
      vim.ui.select = function(items, opts, cb)
        local prompt = tostring(opts and opts.prompt or "")
        if prompt == "Log in" then
          picker_seen = true
          cb(nil)
          return
        end
        cb(items[1])
      end
      local prompted = false
      vim.ui.input = function(_, cb)
        prompted = true
        cb("")
      end
      -- The session's tools are not injected: the flow must try an in-place
      -- reload, learn it is unsupported, and create a replacement.
      service.session_switches[tostring(own_instance()) .. "\0sess_mock"] = { enabled = true, injected = false }
      state().view.team.session_states[tostring(own_instance()) .. "\0sess_mock"] = nil
      vim.cmd("Ade team start default")
      wait(function()
        return picker_seen
      end, 20000, "the login picker raised by the replacement session")
      wait(function()
        return TeamStart.active(dir) == false
      end, 15000, "the start to end after the cancelled login")
      vim.wait(200)
      t.falsy(prompted, "the cancelled login must not reach the task prompt")
      t.eq(0, #calls_of(service, "team.start"), "no workflow started after a cancelled login")
    end)
  end)
end
