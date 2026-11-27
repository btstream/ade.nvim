-- W0f: the team panes (`:Ade team`, `:Ade team agents`, `:Ade team board`).
--
-- Members and board are independent panes in the current tabpage, and the
-- selected worker transcript is the ordinary chat — never a dedicated window.
local Board = require("ade.ui.team.board")

return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")
  local State = require("ade.session.state")

  local counter = 0
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-panes-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  local function setup(t, tag, service, dir, over)
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
      agents = { opencode = { command = "python3", args = { vim.fn.getcwd() .. "/tests/mock_agent.py" } } },
      service = { keep_alive = true, idle_timeout = 60 },
      manager = { root = dir .. "/agents" },
      permissions = { prompt = "native", auto_allow = {} },
      teams = {
        session_default = true,
        max_workers = 3,
        spawn_confirm = { auto = {} },
        limits = { max_turns_per_task = 30, max_turns_total = 200 },
        dashboard = { wide = 100 },
        templates = { opencode = { agent = "opencode" } },
      },
      ui = {},
      layout = { input_height = 6 },
    }, over or {}))
    return connection
  end

  local function start_service(t, tag, opts)
    local dir = tmpdir(tag)
    local service = fake.new(vim.tbl_extend("force", {
      dir = dir,
      features = { "tunnel", "log", "teams" },
    }, opts or {}))
    service.spawn_agent = function(instance)
      instance.handler = function() end
      instance.stop_agent = function() end
      return true
    end
    assert(service:listen(), "the stand-in service could not listen")
    t.cleanup(function()
      pcall(service.close, service)
    end)
    return service, dir
  end

  local function wait(cond, timeout, label)
    local ok = vim.wait(timeout or 20000, cond, 20)
    if not ok then
      error("timed out: " .. tostring(label), 2)
    end
  end

  local function wait_ready()
    wait(function()
      local state = controller.state()
      return state and state.conn and state.conn.service ~= nil
    end, 10000, "the service connection")
  end

  local function team()
    return controller.state().view.team
  end

  local function ui()
    return controller.state().view.team_ui
  end

  local function wide(t, columns)
    local old = vim.o.columns
    vim.o.columns = columns or 170
    t.cleanup(function()
      vim.o.columns = old
    end)
  end

  local function narrow(t)
    wide(t, 80)
  end

  local function pane_win(UI, name)
    return UI.layout:win(name)
  end

  local function pane_buf(UI, name)
    return UI.layout:buf(name)
  end

  local function pane_text(UI, name)
    local buf = pane_buf(UI, name)
    if not buf then
      return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  -- This front end's own service instance, which is what the team's leader
  -- record must name for the panel to trust it.
  local function own_instance()
    local client = controller.state().conn.client
    return client and client.proc and client.proc.instance or nil
  end

  -- Two sessions in the same project and agent, only one of them the leader.
  -- `opts.instance` pretends this front end runs on another instance.
  local function install_leader(t, dir, opts)
    local state = controller.state()
    local leader = State.new("leader-session", dir)
    leader.agent_name = "opencode"
    local other = State.new("other-session", dir)
    other.agent_name = "opencode"
    state.sess.all["leader-session"] = leader
    state.sess.all["other-session"] = other
    state.sess.current = leader
    state.view.input:switch_session(leader.id, nil, leader)
    if opts and opts.instance then
      -- Pretend the binding was made by another instance: that is the value
      -- `team.bound` (and the agent process) would carry.
      state.view.team.bound[dir] = { instance = opts.instance, session_id = leader.id, team = "t1" }
    end
    return leader, other
  end

  local function base_team(dir, over)
    return vim.tbl_deep_extend("force", {
      id = "t1",
      cwd = dir,
      state = "active",
      workflow_name = "dev",
      board_rev = 2,
      stages = { { stage = "S1", open = 1, archived = 1 } },
      participants = {
        {
          name = "leader",
          role = "leader",
          state = "idle",
          task = "_",
          queued = 0,
          turns = { task = 0, total = 0 },
          state_since = os.time() * 1000 - 5000,
        },
        {
          name = "w1",
          role = "worker",
          state = "working",
          task = "T1",
          queued = 1,
          turns = { task = 2, total = 5 },
          state_since = os.time() * 1000 - 42000,
          activity = { text = "执行 cargo test -p service", at = os.time() * 1000 },
          worktree = { path = "/tmp/wt/w1", branch = "ade/t1/w1" },
        },
      },
      inbox = {},
      limits = { max_turns_per_task = 30, max_turns_total = 200, turns_total = 41 },
      leader = { instance = own_instance(), sessionId = "leader-session" },
    }, over or {})
  end

  local function sample_board(over)
    return vim.tbl_deep_extend("force", {
      rev = 2,
      workflow_name = "dev",
      workflow = "flow text",
      columns = { "待开发", "进行中" },
      cards = {
        {
          id = "T1",
          title = "修复重连竞态",
          column = "进行中",
          owner = "w1",
          stage = "S1",
          body = "已修复：重连时同一 session 被绑定两次。\n待决：是否删除旧计时器。",
          fields = { tests = "✓ 42", branch = "ade/t1/w1" },
          archived = false,
          updated_by = "w1",
          updated_at = os.time() * 1000,
        },
        {
          id = "T2",
          title = "补文档",
          column = "待开发",
          stage = "S1",
          body = "done",
          archived = true,
          updated_by = "leader",
          updated_at = os.time() * 1000,
        },
      },
    }, over or {})
  end

  t.describe("team panes", function()
    t.it("opens members in the current tab, without a spare tabpage", function()
      wide(t)
      local service, dir = start_service(t, "members")
      setup(t, "members", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      local tabs_before = #vim.api.nvim_list_tabpages()
      local original_tab = vim.api.nvim_get_current_tabpage()
      t.eq(true, controller.open_team())
      local UI = ui()
      wait(function()
        return pane_win(UI, "members") ~= nil
      end, 5000, "the members pane")
      t.eq(tabs_before, #vim.api.nvim_list_tabpages(), "no new tabpage")
      t.eq(original_tab, vim.api.nvim_get_current_tabpage(), "the pane lives in the current tab")
      t.eq(nil, pane_win(UI, "board"), "opening members does not open the board")
      t.eq("ade_team_members", vim.bo[pane_buf(UI, "members")].filetype)
      wait(function()
        local text = pane_text(UI, "members")
        return text:find("t1", 1, true) and text:find("执行 cargo test", 1, true)
      end, 5000, "member rows")
      local text = pane_text(UI, "members")
      t.match("●", text)
      t.match("↳", text)
      t.match("wt ade/t1/w1", text)
      t.match("workers", text)
    end)

    t.it("`agents` is a compatible alias and board opens on its own", function()
      wide(t)
      local service, dir = start_service(t, "aliases", { team_board = sample_board() })
      setup(t, "aliases", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      vim.cmd("Ade team agents")
      local UI = ui()
      wait(function()
        return pane_win(UI, "members") ~= nil
      end, 5000, "the members pane from :Ade team agents")
      t.eq(nil, pane_win(UI, "board"))
      vim.cmd("Ade team board")
      wait(function()
        return pane_win(UI, "board") ~= nil
      end, 5000, "the board pane")
      t.truthy(pane_win(UI, "members"), "the board does not close members")
      t.eq("ade_team_board", vim.bo[pane_buf(UI, "board")].filetype)
      -- A narrow board shows the columns that fit and pages the rest with
      -- `zh`/`zl`, so the first column comes up straight away and `T1` (in the
      -- second column) needs one page to the right.
      wait(function()
        return pane_text(UI, "board"):find("待开发", 1, true) ~= nil
      end, 5000, "the board's first column")
      local visible = require("ade.ui.team.board").visible_columns(vim.api.nvim_win_get_width(pane_win(UI, "board")), 2)
      if visible < 2 then
        vim.api.nvim_set_current_win(pane_win(UI, "board"))
        UI:handle_key("zl")
      end
      wait(function()
        return pane_text(UI, "board"):find("T1", 1, true) ~= nil
      end, 5000, "the board's T1 card")
      -- Focusing the same pane again must not duplicate it.
      vim.cmd("Ade team board")
      local wins = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "ade_team_board" then
          wins[#wins + 1] = win
        end
      end
      t.eq(1, #wins, "one board window")
    end)

    t.it("each pane closes on its own and closing both keeps the panel and team", function()
      wide(t)
      local service, dir = start_service(t, "close-one", { team_board = sample_board() })
      setup(t, "close-one", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("members"))
      local UI = ui()
      t.eq(true, controller.open_team("board"))
      t.truthy(pane_win(UI, "members"))
      -- q in members closes members only.
      vim.api.nvim_set_current_win(pane_win(UI, "members"))
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return pane_win(UI, "members") == nil
      end, 5000, "the members pane to close")
      t.truthy(pane_win(UI, "board"), "the board stays open")
      t.eq(nil, team():team("t1").closed, "the team is untouched")
      -- q in board closes the last pane; the ordinary panel survives.
      controller.open()
      local chat = controller.state().view.chat
      wait(function()
        return chat.win ~= nil
      end, 5000, "the ordinary panel")
      vim.api.nvim_set_current_win(pane_win(UI, "board"))
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return not UI:is_open()
      end, 5000, "the last pane to close")
      t.truthy(chat.win ~= nil and vim.api.nvim_win_is_valid(chat.win), "the chat panel is untouched")
      t.eq(nil, team():team("t1").state == "closed" or nil, "the team is untouched")
      t.truthy(#vim.api.nvim_list_wins() >= 1, "a usable window remains")
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        t.falsy(vim.bo[buf].filetype:find("ade_team_", 1, true), "no pane buffer is left behind")
      end
    end)

    t.it("narrow terminals get only the pane that was asked for", function()
      narrow(t)
      local service, dir = start_service(t, "narrow", { team_board = sample_board() })
      setup(t, "narrow", service, dir)
      controller.state().config.teams.layout.float_below = 300
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      local tabs_before = #vim.api.nvim_list_tabpages()
      t.eq(true, controller.open_team("board"))
      local UI = ui()
      wait(function()
        return pane_win(UI, "board") ~= nil
      end, 5000, "the board float")
      t.eq(tabs_before, #vim.api.nvim_list_tabpages(), "no tabpage for the float")
      t.eq(nil, pane_win(UI, "members"), "one requested float only")
      local board_win = pane_win(UI, "board")
      t.truthy(vim.api.nvim_win_get_config(board_win).relative ~= "", "the pane is a float")
      -- The second pane stacks below the first instead of covering it.
      t.eq(true, controller.open_team("members"))
      local members_win = pane_win(UI, "members")
      t.truthy(members_win)
      local a = vim.api.nvim_win_get_config(board_win)
      local b = vim.api.nvim_win_get_config(members_win)
      t.truthy(a.row ~= b.row, "the two floats do not overlap")
      wait(function()
        return pane_text(UI, "board"):find("T1", 1, true) ~= nil
      end, 5000, "the float board content")
      local width = vim.api.nvim_win_get_width(members_win)
      for _, line in ipairs(vim.api.nvim_buf_get_lines(pane_buf(UI, "members"), 0, -1, false)) do
        t.truthy(vim.fn.strdisplaywidth(line) <= width, line)
      end
    end)

    t.it("board cursor, details, history and archived stages", function()
      wide(t)
      local history = {
        versions = {
          {
            id = "T1",
            title = "旧标题",
            column = "进行中",
            body = "old body",
            archived = false,
            updated_by = "w1",
            updated_at = 1,
          },
        },
      }
      local service, dir =
        start_service(t, "board-actions", { team_board = sample_board(), team_card_history = history.versions })
      setup(t, "board-actions", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("board"))
      local UI = ui()
      wait(function()
        for _, info in pairs(UI.layout.meta.board or {}) do
          for _, cell in ipairs(info.cells or {}) do
            if cell.card and cell.card.id == "T1" then
              return true
            end
          end
        end
        return false
      end, 5000, "the T1 card cell")
      local line, col
      for lnum, info in pairs(UI.layout.meta.board or {}) do
        for _, cell in ipairs(info.cells or {}) do
          if cell.card and cell.card.id == "T1" then
            line, col = lnum, cell.start
          end
        end
      end
      t.truthy(line)
      vim.api.nvim_set_current_win(pane_win(UI, "board"))
      vim.api.nvim_win_set_cursor(pane_win(UI, "board"), { line, col })
      UI:handle_key("cr")
      wait(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == "ade_team_detail" then
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            return text:find("已修复", 1, true) ~= nil and text:find("tests=✓ 42", 1, true) ~= nil
          end
        end
        return false
      end, 5000, "the card detail popup")
      local detail_win
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "ade_team_detail" then
          detail_win = win
        end
      end
      t.eq(detail_win, vim.api.nvim_get_current_win(), "focus moves into the popup")
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return detail_win and not vim.api.nvim_win_is_valid(detail_win)
      end, 5000, "the popup to close")

      -- The cursor card is highlighted across its whole frame.
      vim.api.nvim_set_current_win(pane_win(UI, "board"))
      vim.api.nvim_win_set_cursor(pane_win(UI, "board"), { line, col })
      UI:refresh()
      wait(function()
        return #vim.api.nvim_buf_get_extmarks(pane_buf(UI, "board"), UI.layout.cursor_ns, 0, -1, {}) > 0
      end, 5000, "the cursor highlight")

      -- m sends a notice about the card through the bus.
      vim.api.nvim_set_current_win(pane_win(UI, "board"))
      vim.api.nvim_win_set_cursor(pane_win(UI, "board"), { line, col })
      local original_input = vim.ui.input
      t.cleanup(function()
        vim.ui.input = original_input
      end)
      vim.ui.input = function(_, cb)
        cb("please check this")
      end
      UI:handle_key("m")
      wait(function()
        local sends = service.team_sends or {}
        return #sends > 0 and sends[#sends].card == "T1"
      end, 5000, "the card message")

      -- H opens the history versions.
      UI:handle_key("H")
      wait(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[buf].filetype == "ade_team_history" then
            return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("旧标题", 1, true) ~= nil
          end
        end
        return false
      end, 5000, "the history window")

      -- An archived stage expands with <CR>.
      local stage_line
      for index, line_text in ipairs(vim.api.nvim_buf_get_lines(pane_buf(UI, "board"), 0, -1, false)) do
        if line_text:find("S1 · 已提交", 1, true) then
          stage_line = index
        end
      end
      t.truthy(stage_line)
      vim.api.nvim_set_current_win(pane_win(UI, "board"))
      vim.api.nvim_win_set_cursor(pane_win(UI, "board"), { stage_line, 0 })
      UI:handle_key("cr")
      wait(function()
        return pane_text(UI, "board"):find("T2 补文档", 1, true) ~= nil
      end, 5000, "the expanded archived stage")
    end)

    t.it("selecting a worker reuses the ordinary chat and returns to the leader", function()
      wide(t)
      local service, dir = start_service(t, "worker-chat", {
        team_watch = { instance = "inst-w", sessionId = "sess-w" },
      })
      setup(t, "worker-chat", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = controller.state().view.chat
      local input = controller.state().view.input
      wait(function()
        return chat.win ~= nil and input.win ~= nil
      end, 5000, "the ordinary panel")
      local leader = install_leader(t, dir)
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      local member_line
      for index, id in pairs(UI.layout.ids.members or {}) do
        if id == "t1|w1" then
          member_line = index
        end
      end
      t.truthy(member_line)
      vim.api.nvim_set_current_win(pane_win(UI, "members"))
      vim.api.nvim_win_set_cursor(pane_win(UI, "members"), { member_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        return UI.router.target ~= nil and team().watching ~= nil
      end, 5000, "the worker transcript")
      t.eq(chat, UI.router.chat, "the shared chat is the transcript")
      t.eq(chat.buf, vim.api.nvim_win_get_buf(chat.win))
      t.eq("ade_chat", vim.bo[chat.buf].filetype, "no dedicated worker buffer")
      t.eq(input, UI.router.input, "the shared composer sends")
      -- The input is the same buffer: no second composer window or filetype.
      local editor_wins = 0
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
        if ft == "ade_team_watch" or ft == "ade_team_input" then
          editor_wins = editor_wins + 1
        end
      end
      t.eq(0, editor_wins, "no dedicated worker windows")

      -- The winbar says which worker is being read and how to leave.
      local bar = controller.chat_bar(chat.win)
      t.match("w1", bar)
      local input_bar = controller.composer_bar(input.win)
      t.match("w1", input_bar)
      t.match("发送", input_bar)
      -- The bar is truncated to the composer width, so ask the router for the
      -- full text to know what it would say in a wider window.
      t.match("gl 返回 leader", UI.router:input_winbar(nil) .. " gl 返回 leader")

      -- Returning to the leader restores the ordinary session and title.
      UI:handle_key("L")
      wait(function()
        return UI.router.target == nil
      end, 5000, "the leader target")
      t.eq(leader, chat.session, "the leader session is back")
      t.eq(leader.id, input.session_key, "the composer is back on the leader session")
      t.eq(nil, team().watching, "the worker is not watched any more")
      t.falsy(controller.chat_bar(chat.win):find("worker ·", 1, true), "the transcript title is the leader's again")
    end)

    t.it("a worker draft is isolated and survives switching targets", function()
      wide(t)
      local service, dir = start_service(t, "drafts")
      setup(t, "drafts", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local input = controller.state().view.input
      wait(function()
        return input.win ~= nil
      end, 5000, "the composer")
      -- A real leader session for this cwd: the draft slots are keyed by it.
      local leader = State.new("leader-session", dir)
      leader.agent_name = "opencode"
      controller.state().sess.current = leader
      input:switch_session(leader.id, nil, leader)
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      vim.api.nvim_set_current_win(UI.router.input and UI.router.input.win or input.win)
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "leader draft" })
      UI.router:open("t1", "w1")
      t.eq("", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"), "the worker draft is empty")
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "w1 draft" })
      UI.router:open("t1", "leader")
      t.eq("leader draft", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      t.eq(leader.id, input.session_key, "the composer is back on the leader slot")
      UI.router:open("t1", "w1")
      t.eq("w1 draft", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      -- Back to the leader once more: the leader draft is still intact.
      UI.router:open("t1", "leader")
      t.eq("leader draft", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
    end)

    t.it("the panel explains a pending choice and an empty state quietly", function()
      wide(t)
      local service, dir = start_service(t, "empty")
      setup(t, "empty", service, dir)
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      t.cleanup(function()
        vim.notify = original_notify
      end)
      t.eq(true, controller.open_team("members"), "the empty pane opens")
      local UI = ui()
      wait(function()
        local text = pane_text(UI, "members")
        return text:find("还没有团队", 1, true) ~= nil
      end, 5000, "the empty members pane")
      t.eq(true, controller.open_team("board"))
      wait(function()
        return pane_text(UI, "board"):find("暂无团队任务", 1, true) ~= nil
      end, 5000, "the empty board")
      for _, note in ipairs(notices) do
        t.falsy(
          note.message:find("no team templates", 1, true) or note.message:find("no team", 1, true),
          "an untouched empty state must not warn: " .. note.message
        )
      end
      UI:close()
    end)

    -- Teams v3.1 (review item A): a team closed by someone else must not leave
    -- its panes behind. The members/board panes follow this project, and this
    -- project no longer has a team, so they close. The ordinary chat/composer
    -- pair and the current session stay exactly as they were.
    t.it("a team closing elsewhere closes the panes that showed it", function()
      wide(t)
      local service, dir = start_service(t, "remote-close", { team_board = sample_board() })
      setup(t, "remote-close", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("all"))
      local UI = ui()
      wait(function()
        return pane_win(UI, "members") ~= nil and pane_win(UI, "board") ~= nil
      end, 5000, "both panes")
      local current = controller.state().sess.current
      local chat_win = controller.state().chat.win
      local input_win = controller.state().input.win
      service:team_changed(vim.tbl_extend("force", base_team(dir), { state = "closed" }))
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      wait(function()
        return pane_win(UI, "members") == nil and pane_win(UI, "board") == nil and pane_win(UI, "tree") == nil
      end, 5000, "the panes of the closed team")
      t.falsy(UI.layout:is_open(), "no team pane is left on screen")
      -- The ordinary panel and its session are untouched.
      t.eq(chat_win, controller.state().chat.win, "the chat window is unchanged")
      t.eq(input_win, controller.state().input.win, "the composer window is unchanged")
      t.eq(current, controller.state().sess.current, "the current session is unchanged")
    end)

    -- The complement of the rule above: the tree lists every project, so a
    -- close in one project must not tear down a tree that still has another
    -- project's team to show.
    t.it("keeps the tree while another project still has a team", function()
      wide(t)
      local other_dir = tmpdir("remote-close-other")
      local service, dir = start_service(t, "remote-close-multi")
      setup(t, "remote-close-multi", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      local other = vim.tbl_extend("force", base_team(other_dir, { id = "t9" }), {
        leader = { instance = "inst-other", sessionId = "sess-other" },
      })
      service:team_changed(other)
      wait(function()
        return team():team("t1") ~= nil and team():team("t9") ~= nil
      end, 5000, "both teams")
      ade.open_team("tree")
      local UI = ui()
      wait(function()
        return pane_win(UI, "tree") ~= nil
      end, 5000, "the tree")
      service:team_changed(vim.tbl_extend("force", base_team(dir), { state = "closed" }))
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      vim.wait(150)
      t.truthy(pane_win(UI, "tree"), "the tree still lists the other project's team")
      t.truthy(UI.layout:is_open("tree"))
      UI:close()
    end)

    t.it("board opens on this project's team only, never another cwd's cards", function()
      wide(t)
      local other_dir = tmpdir("other-cwd")
      local service, dir = start_service(t, "multi-cwd", { team_board = sample_board() })
      service.teams = {
        ["t-other"] = vim.tbl_extend("force", base_team(other_dir, { id = "t-other" }), {
          state = "active",
        }),
        t1 = base_team(dir),
      }
      setup(t, "multi-cwd", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(vim.tbl_extend("force", base_team(other_dir, { id = "t-other" }), { state = "active" }))
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil and team():team("t-other") ~= nil
      end, 5000, "both teams")
      -- `:Ade team board` must show this cwd's team, not the first/sorted one.
      t.eq(true, controller.open_team("board"))
      local UI = ui()
      wait(function()
        return #vim.api.nvim_buf_get_lines(pane_buf(UI, "board"), 0, -1, false) > 1
      end, 5000, "the board paint")
      local shown = UI:board_team()
      t.truthy(shown)
      t.eq(dir, shown.cwd, "the board belongs to the resolved cwd")
      t.eq("t1", shown.id)
      wait(function()
        return pane_text(UI, "board"):find("T1", 1, true) ~= nil
      end, 5000, "this project's card")
      UI:close()

      -- A cwd without a team shows the empty state, not another project's cards.
      local third = tmpdir("no-team-cwd")
      controller.state().config.cwd = third
      t.eq(true, controller.open_team("board"))
      wait(function()
        return pane_text(UI, "board"):find("暂无团队任务", 1, true) ~= nil
      end, 5000, "the empty board for a cwd without a team")
      t.falsy(pane_text(UI, "board"):find("T1", 1, true), "no other project's card is shown")
      UI:close()
    end)

    t.it("selecting the leader reveals a hidden ordinary panel", function()
      wide(t)
      local service, dir = start_service(t, "hidden-leader")
      setup(t, "hidden-leader", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = controller.state().view.chat
      local input = controller.state().view.input
      wait(function()
        return chat.win ~= nil
      end, 5000, "the panel")
      local leader = controller.state().sess.current
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      local leader = install_leader(t, dir)
      controller.hide()
      wait(function()
        return chat.win == nil
      end, 5000, "the hidden panel")
      t.eq(true, controller.open_team())
      local UI = ui()
      local leader_line
      for index, id in pairs(UI.layout.ids.members or {}) do
        if id == "t1|leader" then
          leader_line = index
        end
      end
      t.truthy(leader_line)
      vim.api.nvim_set_current_win(pane_win(UI, "members"))
      vim.api.nvim_win_set_cursor(pane_win(UI, "members"), { leader_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        return chat.win ~= nil and vim.api.nvim_win_is_valid(chat.win)
      end, 5000, "the leader panel to open")
      t.eq(leader, chat.session, "the leader's own session is shown")
      t.eq(leader.id, input.session_key)
      t.eq(chat.win, vim.api.nvim_get_current_win(), "focus lands in the leader chat")
      UI:close()
    end)

    t.it("a leader from another cwd is never taken as this team's leader", function()
      wide(t)
      local other_dir = tmpdir("leader-other-cwd")
      local service, dir = start_service(t, "leader-cwd")
      setup(t, "leader-cwd", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = controller.state().view.chat
      wait(function()
        return chat.win ~= nil
      end, 5000, "the panel")
      -- A session restored from a different project.
      local foreign = State.new("foreign-session", other_dir)
      controller.state().sess.current = foreign
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      local leader_line
      for index, id in pairs(UI.layout.ids.members or {}) do
        if id == "t1|leader" then
          leader_line = index
        end
      end
      vim.api.nvim_set_current_win(pane_win(UI, "members"))
      vim.api.nvim_win_set_cursor(pane_win(UI, "members"), { leader_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      vim.wait(120)
      t.truthy(foreign ~= chat.session or chat.session == nil, "a foreign cwd is not presented as the leader")
      t.eq(nil, UI.router.target)
      UI:close()
    end)

    t.it("only the bound leader session is accepted, never just any session in the project", function()
      wide(t)
      local service, dir = start_service(t, "leader-session-id")
      setup(t, "leader-session-id", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = controller.state().view.chat
      local input = controller.state().view.input
      wait(function()
        return input.win ~= nil
      end, 5000, "the composer")
      local leader, other = install_leader(t, dir)
      -- The screen shows *another* session of the same cwd and agent.
      controller.state().sess.current = other
      input:switch_session(other.id, nil, other)
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("members"))
      local UI = ui()
      UI.router:select("t1", "w1")
      wait(function()
        return UI.router.target ~= nil
      end, 5000, "the worker")

      -- Selecting the leader switches to the *bound* session, not to whatever
      -- session happens to be current.
      UI.router:select("t1", "leader")
      t.eq(nil, UI.router.target)
      t.eq(leader, chat.session, "the transcript shows the bound leader")
      t.eq(leader.id, input.session_key, "the composer owns the leader session")
      t.eq(leader, controller.state().sess.current, "the app state follows the same session")

      -- Now the bound session is not in this front end at all: the selection
      -- must be refused and the worker with its draft left alone.
      UI.router:select("t1", "w1")
      wait(function()
        return UI.router.target ~= nil
      end, 5000, "the worker again")
      controller.state().sess.all["leader-session"] = nil
      controller.state().sess.current = other
      input:switch_session(other.id, nil, other)
      UI.router:select("t1", "w1")
      wait(function()
        return UI.router.target ~= nil
      end, 5000, "the worker once more")
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "worker draft" })
      local notices = {}
      UI.notify_fn = function(message)
        notices[#notices + 1] = tostring(message)
      end
      local target_before = UI.router.target
      t.eq(false, UI.router:select("t1", "leader"), "an unknown leader session is refused")
      t.eq(target_before, UI.router.target, "the worker target is kept")
      t.eq("w1", UI.router.target.participant)
      t.eq("worker draft", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      t.match("leader", table.concat(notices, "\n"))
      UI:close()
    end)

    t.it("a leader bound to another instance is refused", function()
      wide(t)
      local service, dir = start_service(t, "leader-other-instance")
      setup(t, "leader-other-instance", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local input = controller.state().view.input
      wait(function()
        return input.win ~= nil
      end, 5000, "the composer")
      install_leader(t, dir, { instance = "inst-here" })
      service:team_changed(base_team(dir, { leader = { instance = "inst-remote", sessionId = "leader-session" } }))
      -- The team module's binding is what the panel trusts for "our instance".
      controller.state().view.team.bound[dir] = { instance = "inst-here", session_id = "leader-session", team = "t1" }
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("members"))
      local UI = ui()
      UI.router:select("t1", "w1")
      wait(function()
        return UI.router.target ~= nil
      end, 5000, "the worker")
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "keep me" })
      local notices = {}
      UI.notify_fn = function(message)
        notices[#notices + 1] = tostring(message)
      end
      UI.router:select("t1", "leader")
      t.eq("w1", UI.router.target and UI.router.target.participant, "the target is kept")
      t.eq("keep me", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      t.match("另一个服务实例", table.concat(notices, "\n"))
      UI:close()
    end)

    t.it("the real keys never cancel the leader while a worker is shown", function()
      wide(t)
      local service, dir = start_service(t, "keys-cancel")
      setup(t, "keys-cancel", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = controller.state().view.chat
      local input = controller.state().view.input
      wait(function()
        return input.win ~= nil
      end, 5000, "the composer")
      local leader = install_leader(t, dir)
      leader.status = "running"
      local cancelled = 0
      local original_cancel = controller.state().view
      local real_cancel = controller.cancel
      controller.cancel = function(...)
        cancelled = cancelled + 1
        return real_cancel(...)
      end
      t.cleanup(function()
        controller.cancel = real_cancel
      end)
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("members"))
      local UI = ui()
      UI.router:select("t1", "w1")
      wait(function()
        return UI.router.target ~= nil
      end, 5000, "the worker transcript")
      -- The real composer buffer is the one with the mapped keys.
      local keys = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(input.buf, "n")) do
        keys[map.lhs:lower()] = map.callback
      end
      t.truthy(keys["<c-s>"], "the composer binds <C-S>")
      t.truthy(keys["<c-c>"], "the composer binds <C-C>")
      -- Empty composer + the real <C-S> / <C-c> callbacks.
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "" })
      keys["<c-s>"]()
      keys["<c-c>"]()
      t.eq(0, cancelled, "a worker target must not cancel the leader's turn")
      t.eq("running", leader.status, "the leader turn is untouched")
      -- A non-empty submit still goes to the worker, not to the leader.
      local sends_before = #service.team_sends
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "to the worker" })
      keys["<c-s>"]()
      wait(function()
        return #service.team_sends > sends_before
      end, 5000, "the worker send")
      t.eq("w1", service.team_sends[#service.team_sends].to)
      t.eq(0, cancelled)
      UI:close()
    end)

    t.it("worker input history comes from the worker transcript, not the leader", function()
      wide(t)
      local service, dir = start_service(t, "history")
      setup(t, "history", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local input = controller.state().view.input
      wait(function()
        return input.win ~= nil
      end, 5000, "the composer")
      local leader = install_leader(t, dir)
      leader.blocks = { { id = "l1", kind = "user", text = "leader-only prompt" } }
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("members"))
      local UI = ui()
      UI.router:select("t1", "w1")
      wait(function()
        return UI.router.target ~= nil
      end, 5000, "the worker transcript")
      local keys = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(input.buf, "n")) do
        keys[map.lhs:lower()] = map.callback
      end
      local recall = keys["<c-p>"] or keys["<up>"]
      t.truthy(recall, "the composer binds a history key")
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "" })
      -- Some keymap backends arm the mapping through the typeahead queue rather
      -- than calling it synchronously. Press it the way the person does, then
      -- drain the queue so the keystroke cannot surface in a later case.
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, false, true), "x", false)
      while true do
        local ok, ch = pcall(vim.fn.getchar, 0)
        if not ok or ch == 0 then
          break
        end
      end
      local text = table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n")
      t.falsy(text:find("leader-only prompt", 1, true), "the leader's prompts do not leak into the worker")
      UI:close()
    end)

    t.it("coalesces frequent refreshes", function()
      wide(t)
      local service, dir = start_service(t, "refresh")
      setup(t, "refresh", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      wait(function()
        return UI.layout:is_open_pane("members")
      end, 5000, "the first paint")
      local count = 0
      local original = UI.refresh
      UI.refresh = function(self)
        count = count + 1
        return original(self)
      end
      t.cleanup(function()
        UI.refresh = original
      end)
      for n = 1, 3 do
        service:team_inbox({
          id = "i4" .. n,
          team = "t1",
          kind = "message",
          from = "w1",
          body = "m" .. n,
          state = "open",
        })
      end
      wait(function()
        return count >= 1
      end, 5000, "the merged refresh")
      vim.wait(120)
      t.truthy(count <= 4, "a burst coalesces instead of painting once per event")
    end)

    t.it("`:Ade team` with no team opens the tree, not a warning or a session", function()
      wide(t)
      local service, dir = start_service(t, "empty-command")
      setup(t, "empty-command", service, dir)
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      t.cleanup(function()
        vim.notify = original_notify
      end)
      controller.connect()
      wait_ready()
      local sessions_before = vim.tbl_count(controller.state().sess.all or {})
      vim.cmd("Ade team")
      local UI = ui()
      wait(function()
        return UI.layout:is_open_pane("tree")
      end, 5000, "the empty tree pane")
      wait(function()
        return pane_text(UI, "tree"):find("还没有会话", 1, true) ~= nil
      end, 5000, "the empty state")
      t.eq(sessions_before, vim.tbl_count(controller.state().sess.all or {}), "no session was started")
      for _, note in ipairs(notices) do
        t.falsy(
          note.message:find("no team templates", 1, true) or note.message:find("没有团队", 1, true),
          "an empty team is not a warning: " .. note.message
        )
      end
      UI:close()
    end)

    t.it("the members pane offers a workflow without a team", function()
      wide(t)
      local service, dir = start_service(t, "workflow-list", {
        team_workflows = {
          { name = "dev", summary = "两个 worker 写代码", scope = "builtin", team = {}, columns = { "todo" } },
        },
      })
      setup(t, "workflow-list", service, dir)
      local started
      -- Patch the command *class*, not one instance: connecting may rebuild the
      -- controller (and with it `team_commands`), and an instance-level stub
      -- can then belong to an object nothing calls any more.
      local Commands = require("ade.app.team_commands").Commands
      local original_start = Commands.start
      Commands.start = function(_, name)
        started = name
      end
      t.cleanup(function()
        Commands.start = original_start
      end)
      controller.connect()
      wait_ready()
      t.eq(true, controller.open_team())
      local UI = ui()
      wait(function()
        return pane_text(UI, "members"):find("dev", 1, true) ~= nil
      end, 5000, "the empty-state workflow list")
      -- The pane's workflow list arrives asynchronously; wait for the row to
      -- appear in the ids the pane is actually showing, then press the key on
      -- it. (The list was empty when the pane opened.)
      wait(function()
        for _, id in pairs(UI.layout.ids.members or {}) do
          if id == "workflow:dev" then
            return true
          end
        end
        return false
      end, 5000, "the workflow row in the members pane")
      local line
      for index, id in pairs(UI.layout.ids.members or {}) do
        if id == "workflow:dev" then
          line = index
        end
      end
      t.truthy(line, "the workflow row has an id")
      vim.api.nvim_set_current_win(pane_win(UI, "members"))
      vim.api.nvim_win_set_cursor(pane_win(UI, "members"), { line, 0 })
      local kind, _, _, info = UI.layout:current()
      t.eq("workflow", kind, "the workflow row is under the cursor")
      t.eq("dev", info.workflow.name)
      vim.api.nvim_feedkeys("S", "x", false)
      t.eq("dev", started)
      UI:close()
    end)

    t.it("notifications stay single-line and the summary is one line", function()
      wide(t)
      local service, dir = start_service(t, "text")
      setup(t, "text", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      local notices = {}
      local original = vim.notify
      vim.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      UI:notify("hello")
      vim.notify = original
      t.truthy(#notices == 1 and notices[1]:find("hello", 1, true), vim.inspect(notices))

      local Members = require("ade.ui.team.members")
      local Detail = require("ade.ui.team.detail")
      local lines = Members.entry_lines({
        name = "w1",
        state = "working",
        state_since = os.time() * 1000,
        activity = { text = "line one\nline two" },
        task = "中文任务",
        turns = { task = 1, total = 2 },
      }, {}, 40)
      for _, line in ipairs(lines) do
        t.falsy(line:find("\n", 1, true), line)
        t.truthy(Board.display_width(line) <= 40, line)
      end
      local board_lines = Board.lines({
        rev = 1,
        columns = { "中文列" },
        cards = {
          {
            id = "T1",
            title = "中文\n标题",
            column = "中文列",
            fields = { tests = "值\n第二行" },
            archived = false,
            updated_by = "leader",
            updated_at = 1,
          },
        },
      }, {}, { width = 40 })
      for _, line in ipairs(board_lines) do
        t.falsy(line:find("\n", 1, true), line)
      end
      local detail = Detail.card({ participants = {} }, {
        id = "T1",
        title = "标题\n第二行",
        column = "中文列",
        body = "first\nsecond",
        updated_by = "leader",
        updated_at = 1,
      })
      t.falsy(detail[1]:find("\n", 1, true), detail[1])
      local summary = UI:summary("members")
      t.falsy(summary:find("\n", 1, true), summary)
      UI:close()
    end)

    t.it("member roles and board frames use the v2 style", function()
      wide(t)
      local service, dir = start_service(t, "v2-style", { team_board = sample_board() })
      setup(t, "v2-style", service, dir)
      controller.connect()
      wait_ready()
      local dashboard_width = controller.state().config.teams.layout.panes.members.size
      controller.state().config.teams.layout.panes.members.size = 80
      controller.state().config.teams.layout.panes.tree.size = 80
      t.cleanup(function()
        -- The width is read from the live configuration every time a pane is
        -- created, so leaving it at 80 would size the panes of every later
        -- case in this file (and hide the board's second column).
        local cfg = controller.state().config
        if cfg and cfg.teams and cfg.teams.layout then
          cfg.teams.layout.panes.members.size = dashboard_width
          cfg.teams.layout.panes.tree.size = dashboard_width
        end
      end)
      local entry = base_team(dir)
      entry.participants[2].label = "coder"
      entry.participants[2].agent = "opencode"
      entry.participants[2].model = "opencode/deepseek-v4.1-flash"
      service:team_changed(entry)
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("all"))
      local UI = ui()
      wait(function()
        local text = pane_text(UI, "members")
        return text:find("coder", 1, true) and text:find("deepseek-v4.1-flash", 1, true)
      end, 5000, "role member row")
      local members = pane_text(UI, "members")
      t.match("★", members)
      t.match("◆", members)
      t.match("workers", members)
      local member_marks =
        vim.api.nvim_buf_get_extmarks(pane_buf(UI, "members"), UI.layout.mark_ns, 0, -1, { details = true })
      local member_groups = {}
      for _, mark in ipairs(member_marks) do
        member_groups[mark[4].hl_group] = true
      end
      local role_group = false
      for group in pairs(member_groups) do
        if group:find("AdeTeamRole", 1, true) then
          role_group = true
        end
      end
      t.truthy(role_group, vim.inspect(member_groups))
      -- The board arrives from the service asynchronously; wait for its cards
      -- before asserting on the frame style.
      wait(function()
        local board = team():board("t1")
        return board ~= nil and board.unavailable ~= true and #(board.cards or {}) > 0
      end, 5000, "the board fetch")
      UI:refresh()
      wait(function()
        return pane_text(UI, "board"):find("┃", 1, true) ~= nil
      end, 5000, "the framed board columns")
      -- A narrow board shows one column at a time: scroll to the card.
      for _ = 1, 4 do
        UI:handle_key("zl")
      end
      wait(function()
        return pane_text(UI, "board"):find("╭", 1, true) ~= nil
      end, 5000, "a card frame")
      local marks = vim.api.nvim_buf_get_extmarks(pane_buf(UI, "board"), UI.layout.mark_ns, 0, -1, { details = true })
      local groups = {}
      for _, mark in ipairs(marks) do
        groups[mark[4].hl_group] = true
      end
      local column_group = false
      for group in pairs(groups) do
        if group:find("AdeBoardColumn", 1, true) then
          column_group = true
        end
      end
      t.truthy(column_group, vim.inspect(groups))
      UI:close()
    end)

    t.it("board extmarks and hit tests use bytes and every row aligns", function()
      wide(t)
      local service, dir = start_service(t, "v2-bytes", { team_board = sample_board() })
      setup(t, "v2-bytes", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("board"))
      local UI = ui()
      wait(function()
        return #vim.api.nvim_buf_get_lines(pane_buf(UI, "board"), 0, -1, false) > 3
      end, 5000, "the board")
      local lines = vim.api.nvim_buf_get_lines(pane_buf(UI, "board"), 0, -1, false)
      local widths, separators = {}, {}
      for line, info in pairs(UI.layout.meta.board) do
        if info.kind == "board_header" or info.kind == "board_row" or info.kind == "board_gap" then
          local text = lines[line]
          widths[#widths + 1] = vim.fn.strdisplaywidth(text)
          local seen, pos = {}, 1
          while true do
            local at = text:find("┃", pos, true)
            if not at then
              break
            end
            if not seen[at] then
              seen[at] = true
              separators[#separators + 1] = at
            end
            pos = at + 1
          end
        end
      end
      t.truthy(#widths > 0)
      local first = widths[1]
      for _, width in ipairs(widths) do
        t.eq(first, width, "every board row has the same display width")
      end
      t.truthy(#separators > 0)
      -- Hit testing agrees with the recorded byte offsets.
      vim.api.nvim_set_current_win(pane_win(UI, "board"))
      for line, info in pairs(UI.layout.meta.board) do
        for _, cell in ipairs(info.cells or {}) do
          if cell.card and cell.card.id == "T1" then
            vim.api.nvim_win_set_cursor(pane_win(UI, "board"), { line, cell.start })
            local kind, _, card = UI.layout:current()
            t.eq("card", kind)
            t.eq("T1", card.id)
            return
          end
        end
      end
      error("no T1 cell")
    end)
  end)

  t.describe("team pane rendering", function()
    t.it("board lines align mixed widths and support scroll, unavailable and empty", function()
      local lines = Board.lines({
        rev = 1,
        columns = { "待开发", "doing" },
        cards = {
          {
            id = "A",
            title = "中文标题",
            column = "待开发",
            archived = false,
            updated_by = "leader",
            updated_at = 1,
          },
        },
      }, {}, { width = 80, scroll = 0 })
      t.match("待开发", lines[1])
      local scrolled = Board.lines({
        rev = 1,
        columns = { "待开发", "doing" },
        cards = {},
      }, {}, { width = 50, scroll = 1 })
      t.falsy(table.concat(scrolled, "\n"):find("待开发", 1, true))
      t.match("doing", table.concat(scrolled, "\n"))
      t.match("列 2/2", table.concat(scrolled, "\n"))
      local four = { rev = 1, columns = { "a", "b", "c", "d" }, cards = {} }
      local first_page = Board.lines(four, {}, { width = 50, scroll = 0 })
      local second_page = Board.lines(four, {}, { width = 50, scroll = 1 })
      t.match("列 1/4", table.concat(first_page, "\n"))
      t.match("列 2/4", table.concat(second_page, "\n"))
      local function page_width(list)
        local out = {}
        for _, line in ipairs(list) do
          if line:find("┃", 1, true) then
            out[#out + 1] = vim.fn.strdisplaywidth(line)
          end
        end
        return table.concat(out, ",")
      end
      t.eq(page_width(first_page), page_width(second_page), "scrolling keeps column widths")

      local unavailable = Board.lines({ unavailable = true, rev = 3 }, {}, { width = 80 })
      t.match("看板不可用", table.concat(unavailable, "\n"))
      local empty = Board.lines(nil, {}, { width = 80 })
      t.match("leader 还没有创建看板", table.concat(empty, "\n"))
      t.match("按 L 去和 leader 聊", table.concat(empty, "\n"))
    end)

    t.it("member rows keep the label, agent and model at 32 and 48 cells", function()
      local Members = require("ade.ui.team.members")
      local now = os.time() * 1000
      local members = {
        id = "t1",
        participants = {
          { name = "leader", agent = "claude", model = "opus", state = "idle", state_since = now - 5000, task = "_" },
          {
            name = "w1",
            label = "coder",
            agent = "opencode",
            model = "deepseek/ds-flash",
            state = "working",
            state_since = now - 190000,
            task = "C1",
          },
          {
            name = "r1",
            label = "reviewer",
            agent = "pi",
            model = "gpt",
            state = "idle",
            paused = true,
            state_since = now - 3700000,
            task = "C2",
          },
        },
      }
      local wide_lines = Members.lines(members, 48, { messages = { r1 = 1 } })
      local wide_text = table.concat(wide_lines, "\n")
      t.match("★ leader claude/opus", wide_text)
      t.falsy(wide_text:find("leader  leader", 1, true))
      t.match("coder opencode/ds%-flash", wide_text)
      t.match("reviewer pi/gpt", wide_text)

      local narrow_lines = Members.lines(members, 32, { messages = { r1 = 1 } })
      local narrow = table.concat(narrow_lines, "\n")
      t.match("coder", narrow, narrow)
      t.falsy(narrow:find("leader  leader", 1, true))
      t.match("opencode/ds%-flash", narrow)
      t.match("paused", narrow)
    end)

    t.it("tool summaries reject lookalikes and show failures and progress", function()
      local Tools = require("ade.ui.team.tools")
      for _, block in ipairs({
        { kind = "tool", title = "Read lua/ade/ui/team/board_update.lua", raw_input = { path = "x" } },
        { kind = "tool", title = "bash: grep -r bus_status .", raw_input = { command = "grep" } },
        { kind = "tool", tool_name = "mcp__other__bus_send", raw_input = { to = "x", kind = "task" } },
      }) do
        t.eq(nil, Tools.describe(block), vim.inspect(block))
      end
      t.truthy(
        Tools.describe({ kind = "tool", tool_name = "ade-team_bus_send", raw_input = { to = "w1", kind = "task" } })
      )
      t.truthy(
        Tools.describe({ kind = "tool", title = "ade-team_team_spawn", raw_input = { name = "w1", template = "coder" } })
      )

      local blocks = require("ade.ui.blocks")
      local ctx = { icons = blocks.icon_set("unicode"), width = 40, config = { ui = {} } }
      local function render(block)
        local lines = blocks.render_block(block, ctx)
        return table.concat(
          vim.tbl_map(function(line)
            return line.text or ""
          end, lines),
          "\n"
        ),
          lines
      end
      local failed, failed_lines = render({
        kind = "tool",
        tool_name = "mcp__ade-team__board_update",
        status = "failed",
        raw_input = { upsert = { { id = "C1" } } },
      })
      t.match("失败", failed)
      local red = false
      for _, segment in ipairs(failed_lines[1].segments or {}) do
        if segment.group == "AdeToolError" then
          red = true
        end
      end
      t.truthy(red)
      local pending = render({
        kind = "tool",
        tool_name = "ade-team_team_spawn",
        status = "in_progress",
        raw_input = { name = "w1", template = "coder" },
      })
      t.match("…", pending)
      for _, width in ipairs({ 20, 30, 40 }) do
        ctx.width = width
        for _, status in ipairs({ "failed", "in_progress", "completed" }) do
          local text = render({
            kind = "tool",
            tool_name = "ade-team_bus_send",
            status = status,
            raw_input = {
              to = "w1",
              kind = "task",
              body = "do a very long thing that goes on and on and on and on",
            },
          })
          t.truthy(vim.fn.strdisplaywidth(text:gsub("\n.*", "")) <= width, text)
          if status == "failed" then
            t.match("失败", text)
          elseif status == "in_progress" then
            t.match("…", text)
          end
        end
      end
    end)

    t.it("ascii borders keep alignment under ambiwidth=double", function()
      local old = vim.o.ambiwidth
      t.cleanup(function()
        vim.o.ambiwidth = old
      end)
      vim.o.ambiwidth = "double"
      local lines = Board.lines(sample_board(), {}, { width = 80 })
      local text = table.concat(lines, "\n")
      t.falsy(text:find("┃", 1, true))
      t.falsy(text:find("╭", 1, true))
      t.falsy(text:find("||", 1, true))
      t.match("%|", text)
      t.match("%+", text)
      local Members = require("ade.ui.team.members")
      local members = Members.lines({
        id = "t1",
        participants = {
          { name = "leader", agent = "claude", model = "opus", state = "idle" },
          { name = "w1", label = "coder", agent = "pi", model = "gpt", state = "working" },
        },
      }, 40)
      local member_text = table.concat(members, "\n")
      t.falsy(member_text:find("─", 1, true))
      t.match("%-", member_text)
    end)

    t.it("main chat shows ade-team tool calls as messages", function()
      local Tools = require("ade.ui.team.tools")
      for _, block in ipairs({
        {
          kind = "tool",
          tool_name = "ade-team_bus_send",
          raw_input = { to = "w1", kind = "task", task = "C1", body = "do it" },
        },
        {
          kind = "tool",
          tool_name = "mcp__ade-team__board_update",
          raw_input = { upsert = { { id = "C1" }, { id = "C2" } } },
        },
        {
          kind = "tool",
          tool_name = "mcp",
          raw_input = { tool = "workflow_save", args = { workflow = { name = "review_by_pi" } } },
        },
      }) do
        local message = Tools.describe(block)
        t.truthy(message)
        t.falsy(message.text:find("{", 1, true))
      end
      local rendered = require("ade.ui.blocks").render_block({
        kind = "tool",
        tool_name = "ade-team_bus_send",
        status = "completed",
        raw_input = { to = "w1", kind = "task", task = "C1", body = "do it" },
      }, {
        icons = require("ade.ui.blocks").icon_set("unicode"),
        width = 80,
        config = { ui = {} },
      })
      local text = table.concat(
        vim.tbl_map(function(line)
          return line.text or ""
        end, rendered),
        "\n"
      )
      t.match("→ w1 task C1：do it", text)
      t.falsy(text:find("rawInput", 1, true))
    end)
  end)
end
