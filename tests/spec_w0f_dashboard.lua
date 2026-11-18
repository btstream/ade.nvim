-- W0f: the unified team dashboard.
local Board = require("ade.ui.team.board")

return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")

  local counter = 0
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-w0f-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  local function setup(t, tag, service, dir)
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
    ade.setup({
      backend = "service",
      cwd = dir,
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { vim.fn.getcwd() .. "/tests/mock_agent.py" } } },
      service = { keep_alive = true, idle_timeout = 60 },
      manager = { root = dir .. "/agents" },
      permissions = { prompt = "native", auto_allow = {} },
      teams = {
        spawn_from_chat = true,
        max_workers = 3,
        spawn_confirm = { auto = {} },
        limits = { max_turns_per_task = 30, max_turns_total = 200 },
        dashboard = { wide = 100 },
        templates = { opencode = { agent = "opencode" } },
      },
      ui = {},
      layout = { input_height = 6 },
    })
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

  local function wide(t)
    local old = vim.o.columns
    vim.o.columns = 170
    t.cleanup(function()
      vim.o.columns = old
    end)
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

  t.describe("W0f dashboard", function()
    t.it("wide layout opens four panes, renders turns and closes back to the tab", function()
      wide(t)
      local service, dir = start_service(t, "wide", { team_board = sample_board() })
      setup(t, "wide", service, dir)
      controller.connect()
      wait_ready()
      local original = vim.api.nvim_get_current_tabpage()
      service:team_changed(base_team(dir))
      service:team_inbox({
        id = "i21",
        team = "t1",
        kind = "spawn",
        from = "leader",
        name = "w2",
        template = "opencode",
        model = "m2",
        group = "g1",
        state = "open",
        body = "spawn w2",
      })
      service:team_inbox({
        id = "i22",
        team = "t1",
        kind = "spawn",
        from = "leader",
        name = "w3",
        template = "opencode",
        group = "g1",
        state = "open",
        body = "spawn w3",
      })
      wait(function()
        return team():team("t1") ~= nil and team():item("i22") ~= nil
      end, 5000, "the team and inbox")
      t.eq(true, controller.open_team())
      local UI = ui()
      wait(function()
        return UI.tab ~= nil and UI.tab:is_open()
      end, 5000, "the wide tab")
      t.eq(2, #{ UI.tab.panels.members, UI.tab.panels.board })
      for _, win in ipairs({ UI.tab.panels.members, UI.tab.panels.board }) do
        t.truthy(vim.api.nvim_win_is_valid(win))
      end
      t.eq(nil, UI.tab.panels.inbox)
      t.eq(nil, UI.tab.panels.detail)
      wait(function()
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.members, 0, -1, false), "\n")
        return text:find("w1", 1, true) and text:find("执行 cargo test", 1, true)
      end, 5000, "member rows with activity")
      local members = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.members, 0, -1, false), "\n")
      t.match("●", members)
      t.match("↳", members)
      t.match("wt ade/t1/w1", members)
      wait(function()
        local board = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.board, 0, -1, false), "\n")
        return board:find("T1", 1, true) and board:find("待开发", 1, true)
      end, 5000, "the board")
      t.match("流程 dev", vim.o.tabline)
      t.match("阶段 S1", vim.o.tabline)
      local before_win = vim.api.nvim_get_current_win()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
      t.truthy(vim.api.nvim_get_current_win() ~= before_win, "Tab cycles panes")

      local tab = UI.tab
      vim.api.nvim_set_current_win(tab.panels.members)
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return not tab:is_open() and vim.api.nvim_get_current_tabpage() == original
      end, 5000, "closing back to the original tab")
    end)

    t.it("board cursor, details, history, card message and archived stages", function()
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
        start_service(t, "board", { team_board = sample_board(), team_card_history = history.versions })
      setup(t, "board", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      wait(function()
        local lines = vim.api.nvim_buf_get_lines(UI.tab.buffers.board, 0, -1, false)
        for _, line in ipairs(lines) do
          if line:find("T1", 1, true) then
            return true
          end
        end
        return false
      end, 5000, "the board row")
      -- Locate T1's cell and put the cursor there.
      local line_no, col
      for index, line in ipairs(vim.api.nvim_buf_get_lines(UI.tab.buffers.board, 0, -1, false)) do
        local at = line:find("T1", 1, true)
        if at then
          line_no, col = index, at - 1
        end
      end
      t.truthy(line_no)
      vim.api.nvim_set_current_win(UI.tab.panels.board)
      vim.api.nvim_win_set_cursor(UI.tab.panels.board, { line_no, col })
      t.truthy(#vim.api.nvim_buf_get_keymap(UI.tab.buffers.board, "n") > 0, "board keys")
      UI.tab.dashboard:handle_key("cr")
      wait(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[buf].filetype == "ade_team_detail" then
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            if text:find("已修复", 1, true) and text:find("tests=✓ 42", 1, true) then
              return true
            end
          end
        end
        return false
      end, 5000, "the card detail popup")
      wait(function()
        local marks = vim.api.nvim_buf_get_extmarks(UI.tab.buffers.board, UI.tab.cursor_ns, 0, -1, {})
        return #marks > 0
      end, 5000, "the card cursor highlight")
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "ade_team_detail" then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      -- Card message carries `card`.
      local original_input = vim.ui.input
      t.cleanup(function()
        vim.ui.input = original_input
      end)
      vim.ui.input = function(_, cb)
        cb("please check this")
      end
      vim.api.nvim_feedkeys("m", "x", false)
      wait(function()
        local sends = service.team_sends or {}
        return #sends > 0 and sends[#sends].card == "T1"
      end, 5000, "the card message")
      -- History opens a window with the versions.
      UI.tab.dashboard:handle_key("H")
      wait(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[buf].filetype == "ade_team_history" then
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            return text:find("旧标题", 1, true) ~= nil
          end
        end
        return false
      end, 5000, "the history window")
      -- Archived stage expands with <CR>.
      local stage_line
      for index, line in ipairs(vim.api.nvim_buf_get_lines(UI.tab.buffers.board, 0, -1, false)) do
        if line:find("S1 · 已提交", 1, true) then
          stage_line = index
        end
      end
      t.truthy(stage_line)
      vim.api.nvim_set_current_win(UI.tab.panels.board)
      vim.api.nvim_win_set_cursor(UI.tab.panels.board, { stage_line, 0 })
      UI.tab.dashboard:handle_key("cr")
      wait(function()
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.board, 0, -1, false), "\n")
        return text:find("T2 补文档", 1, true) ~= nil
      end, 5000, "the expanded archived stage")
    end)

    t.it("notifications and single-line text", function()
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
      UI._impl:notify("hello")
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
      local member_detail = Detail.participant(
        {
          participants = {
            {
              name = "w1",
              state = "idle",
              task = "T\n1",
              activity = { text = "a\nb" },
              turns = { task = 0, total = 0 },
            },
          },
        },
        "w1",
        {
          cards = { { id = "T1", title = "title\nsecond", owner = "w1" } },
        }
      )
      for _, line in ipairs(member_detail) do
        t.falsy(line:find("\n", 1, true), line)
      end
    end)

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
      local function page_width(lines)
        local out = {}
        for _, line in ipairs(lines) do
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

    t.it("S starts the selected workflow from the empty state", function()
      wide(t)
      local service2, dir2 = start_service(t, "empty", {
        team_workflows = {
          { name = "dev", summary = "两个 worker 写代码", scope = "builtin", team = {}, columns = { "todo" } },
        },
      })
      setup(t, "empty", service2, dir2)
      local started
      controller.state().view.team_commands.start = function(_, name)
        started = name
      end
      controller.connect()
      wait_ready()
      t.eq(true, controller.open_team())
      local UI2 = ui()
      wait(function()
        local lines = vim.api.nvim_buf_get_lines(UI2.tab.buffers.members, 0, -1, false)
        for _, line in ipairs(lines) do
          if line:find("dev", 1, true) then
            return true
          end
        end
        return false
      end, 5000, "the empty-state workflow list")
      local line
      for index, id in pairs(UI2.tab.ids.members or {}) do
        if id == "workflow:dev" then
          line = index
        end
      end
      t.truthy(line)
      vim.api.nvim_set_current_win(UI2.tab.panels.members)
      vim.api.nvim_win_set_cursor(UI2.tab.panels.members, { line, 0 })
      vim.api.nvim_feedkeys("S", "x", false)
      t.eq("dev", started)
    end)

    t.it("moves the leader chat and input into the right column and restores them", function()
      wide(t)
      local service, dir = start_service(t, "leader")
      setup(t, "leader", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = controller.state().view.chat
      local input = controller.state().view.input
      wait(function()
        return chat.win ~= nil and vim.api.nvim_win_is_valid(chat.win)
      end, 5000, "the main chat window")
      local old_chat, old_input = chat.win, input.win
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      local leader_line
      for index, id in pairs(UI.tab.ids.members or {}) do
        if id == "t1|leader" then
          leader_line = index
        end
      end
      t.truthy(leader_line)
      vim.api.nvim_set_current_win(UI.tab.panels.members)
      vim.api.nvim_win_set_cursor(UI.tab.panels.members, { leader_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        return chat.win ~= old_chat
          and vim.api.nvim_win_is_valid(chat.win)
          and vim.api.nvim_win_get_buf(chat.win) == chat.buf
          and input.win ~= old_input
          and vim.api.nvim_win_get_buf(input.win) == input.buf
      end, 5000, "the leader chat in the right column")
      t.eq(vim.api.nvim_get_current_tabpage(), UI.tab.tab)
      local function widths()
        local out = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(UI.tab.tab)) do
          out[#out + 1] = vim.api.nvim_win_get_width(win)
        end
        return table.concat(out, ",")
      end
      local before = widths()
      for _ = 1, 3 do
        UI:refresh()
      end
      t.eq(before, widths(), "a refresh must not squeeze the mounted leader")
      t.eq(true, vim.api.nvim_win_get_width(chat.win) >= 16, "the chat keeps a usable width")
      t.eq(true, vim.api.nvim_win_get_width(input.win) >= 16, "the input keeps a usable width")
      -- Only a window the person drags is recorded; a passively resized
      -- neighbour is not (N6).
      local tab = UI.tab
      local old_members, old_watch = tab.members_width, tab.watch_width
      tab.applied_members, tab.applied_right, tab.watch_width = 32, 30, nil
      t.eq(true, tab:record_resize(40, 20, tab.panels.members))
      t.eq(40, tab.members_width)
      t.eq(nil, tab.watch_width)
      tab.watch_width = nil
      t.eq(true, tab:record_resize(32, 24, tab:right_win()))
      t.eq(24, tab.watch_width)
      tab.watch_width = nil
      t.eq(false, tab:record_resize(36, 18, tab.panels.board))
      t.eq(nil, tab.watch_width)
      tab.members_width, tab.watch_width = old_members, old_watch
      tab.applied_members, tab.applied_right = nil, nil
      vim.cmd("stopinsert")

      local original_tab = UI._impl.leader_mounted and UI._impl.leader_mounted.original_tab or nil
      vim.api.nvim_set_current_win(UI.tab.panels.members)
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return chat.win ~= nil
          and vim.api.nvim_win_is_valid(chat.win)
          and vim.api.nvim_win_get_buf(chat.win) == chat.buf
          and input.win ~= nil
          and vim.api.nvim_win_is_valid(input.win)
          and vim.api.nvim_win_get_buf(input.win) == input.buf
          and not UI._impl.leader_mounted
      end, 5000, "the chat restored to the panel")
    end)

    t.it("closing the dashboard as the last tab keeps a normal window", function()
      wide(t)
      local service, dir = start_service(t, "last-tab")
      setup(t, "last-tab", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      vim.cmd("tabonly")
      vim.api.nvim_set_current_win(UI.tab.panels.members)
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return UI.tab == nil
      end, 5000, "the closed dashboard")
      t.truthy(#vim.api.nvim_list_wins() >= 1, "a normal window remains")
      t.truthy(vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()))
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        t.falsy(vim.bo[vim.api.nvim_win_get_buf(win)].filetype:find("ade_team_", 1, true))
      end
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        t.falsy(vim.bo[buf].filetype:find("ade_team_", 1, true))
      end
    end)

    t.it("direct close and mounted last-tab close leave no dashboard buffers", function()
      wide(t)
      local service, dir = start_service(t, "last-tab-mounted")
      setup(t, "last-tab-mounted", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = controller.state().view.chat
      wait(function()
        return chat.win ~= nil
      end, 5000, "the main chat")
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      local leader_line
      for index, id in pairs(UI.tab.ids.members or {}) do
        if id == "t1|leader" then
          leader_line = index
        end
      end
      t.truthy(leader_line)
      vim.api.nvim_set_current_win(UI.tab.panels.members)
      vim.api.nvim_win_set_cursor(UI.tab.panels.members, { leader_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        return UI._impl.leader_mounted ~= nil
      end, 5000, "the leader mount")
      vim.cmd("tabonly")
      UI._impl:close()
      wait(function()
        return UI.tab == nil
      end, 5000, "the closed dashboard")
      t.truthy(chat.win ~= nil and vim.api.nvim_win_is_valid(chat.win))
      t.eq(chat.buf, vim.api.nvim_win_get_buf(chat.win))
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        t.falsy(vim.bo[buf].filetype:find("ade_team_", 1, true))
      end
    end)

    t.it("closing one dashboard pane closes the whole dashboard", function()
      wide(t)
      local service, dir = start_service(t, "zombie")
      setup(t, "zombie", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      vim.api.nvim_win_close(UI.tab.panels.board, true)
      wait(function()
        return UI.tab == nil
      end, 5000, "the whole dashboard closing")
      t.truthy(#vim.api.nvim_list_wins() >= 1)
    end)

    t.it("a hidden panel stays hidden after a leader mount", function()
      wide(t)
      local service, dir = start_service(t, "hidden-leader")
      setup(t, "hidden-leader", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      local chat = controller.state().view.chat
      wait(function()
        return chat.win ~= nil
      end, 5000, "the main panel")
      controller.hide()
      wait(function()
        return chat.win == nil
      end, 5000, "the hidden panel")
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      local leader_line
      for index, id in pairs(UI.tab.ids.members or {}) do
        if id == "t1|leader" then
          leader_line = index
        end
      end
      t.truthy(leader_line)
      vim.api.nvim_set_current_win(UI.tab.panels.members)
      vim.api.nvim_win_set_cursor(UI.tab.panels.members, { leader_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        return UI._impl.leader_mounted ~= nil
      end, 5000, "the leader mount")
      vim.api.nvim_set_current_win(UI.tab.panels.members)
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return UI._impl.leader_mounted == nil
      end, 5000, "the unmounted leader")
      t.eq(nil, chat.win, "a hidden panel is not reopened")
    end)

    t.it("setup can run again while the dashboard is open", function()
      wide(t)
      local service, dir = start_service(t, "setup-again")
      setup(t, "setup-again", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local ok, err = pcall(function()
        require("ade").setup(controller.state().config)
      end)
      t.truthy(ok, tostring(err))
      t.truthy(controller.state().view.team_ui, "the dashboard view exists after setup")
    end)

    t.it("tabline shows the title and pending counts and members keep their width", function()
      wide(t)
      local service, dir = start_service(t, "v2-layout")
      setup(t, "v2-layout", service, dir)
      controller.connect()
      wait_ready()
      controller.state().config.teams.dashboard.members_width = 40
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      wait(function()
        return UI.tab.panels.members ~= nil
      end, 5000, "the tab")
      local queue = UI:choices()
      local old_counts = queue.pending_counts
      queue.pending_counts = function()
        return { question = 2, approval = 1 }
      end
      t.cleanup(function()
        queue.pending_counts = old_counts
      end)
      UI:update_tabline()
      t.match("team t1", vim.o.tabline)
      t.match("? 待回答 2", vim.o.tabline)
      t.match("⚑ 待批准 1", vim.o.tabline)
      t.eq(40, vim.api.nvim_win_get_width(UI.tab.panels.members))
      t.eq(true, vim.api.nvim_get_option_value("winfixwidth", { win = UI.tab.panels.members }))
      t.eq(2, vim.o.showtabline)
      -- Other tabs keep the saved tabline.
      local saved = UI.saved_tabline
      vim.cmd("tabnew")
      vim.wait(20)
      t.eq(saved, vim.o.tabline)
      vim.cmd("tabclose")
      vim.wait(20)
      t.match("team t1", vim.o.tabline)
      vim.wait(250)
      vim.api.nvim_win_set_width(UI.tab.panels.members, 48)
      -- Headless nvim does not deliver WinResized for API resizes; a real drag
      -- does, and the test emits it before any scheduled refresh can run.
      vim.cmd("doautocmd WinResized")
      vim.wait(50)
      vim.cmd("doautocmd VimResized")
      t.eq(48, vim.api.nvim_win_get_width(UI.tab.panels.members))
      -- Opening and closing the right column must not ratchet the width (M1).
      for _ = 1, 5 do
        UI.tab:open_watch_host()
        vim.wait(30)
        vim.cmd("doautocmd WinResized")
        UI.tab:close_watch_host()
        vim.wait(30)
        vim.cmd("doautocmd WinResized")
        UI:refresh()
        t.eq(48, vim.api.nvim_win_get_width(UI.tab.panels.members))
      end
      -- The watch column keeps a user width too (M2).
      local host = UI.tab:open_watch_host()
      vim.wait(250)
      vim.api.nvim_win_set_width(host, 40)
      vim.cmd("doautocmd WinResized")
      UI:refresh()
      t.eq(40, vim.api.nvim_win_get_width(host))
      UI.tab:close_watch_host()
      vim.wait(250)

      -- Manual resizes are not clamped to the config range (m1).
      vim.wait(250)
      vim.api.nvim_win_set_width(UI.tab.panels.members, 10)
      vim.cmd("doautocmd WinResized")
      UI:refresh()
      t.eq(10, vim.api.nvim_win_get_width(UI.tab.panels.members))
    end)

    t.it("member roles and board frames use the v2 style", function()
      wide(t)
      local service, dir = start_service(t, "v2-style", { team_board = sample_board() })
      setup(t, "v2-style", service, dir)
      controller.connect()
      wait_ready()
      controller.state().config.teams.dashboard.members_width = 80
      local entry = base_team(dir)
      entry.participants[2].label = "coder"
      entry.participants[2].agent = "opencode"
      entry.participants[2].model = "opencode/deepseek-v4.1-flash"
      service:team_changed(entry)
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      wait(function()
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.members, 0, -1, false), "\n")
        return text:find("coder", 1, true) and text:find("deepseek-v4.1-flash", 1, true)
      end, 5000, "role member row")
      local members = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.members, 0, -1, false), "\n")
      t.match("★", members)
      t.match("◆", members)
      t.match("workers", members)
      local member_marks =
        vim.api.nvim_buf_get_extmarks(UI.tab.buffers.members, UI.tab.mark_ns, 0, -1, { details = true })
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
      wait(function()
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.board, 0, -1, false), "\n")
        return text:find("┃", 1, true) and text:find("╭", 1, true)
      end, 5000, "framed board")
      local marks = vim.api.nvim_buf_get_extmarks(UI.tab.buffers.board, UI.tab.mark_ns, 0, -1, { details = true })
      local groups = {}
      for _, mark in ipairs(marks) do
        groups[mark[4].hl_group] = true
      end
      t.truthy(groups.AdeBoardColumn1, vim.inspect(groups))
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

    t.it("a and ! call the choice queue for members", function()
      wide(t)
      local service, dir = start_service(t, "v2-choices")
      setup(t, "v2-choices", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      local queue = UI:choices()
      local old_answer, old_show = queue.answer_participant, queue.show_pending
      local answered, shown
      queue.answer_participant = function(_, team_id, name)
        answered = name
        return true
      end
      queue.show_pending = function(_, team_id)
        shown = team_id
        return true
      end
      t.cleanup(function()
        queue.answer_participant = old_answer
        queue.show_pending = old_show
      end)
      local line
      for index, id in pairs(UI.tab.ids.members or {}) do
        if id == "t1|w1" then
          line = index
        end
      end
      t.truthy(line)
      vim.api.nvim_set_current_win(UI.tab.panels.members)
      vim.api.nvim_win_set_cursor(UI.tab.panels.members, { line, 0 })
      vim.api.nvim_feedkeys("a", "x", false)
      t.eq("w1", answered)
      vim.api.nvim_feedkeys("!", "x", false)
      t.eq("t1", shown)
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
      t.eq(true, controller.open_team())
      local UI = ui()
      local tab = UI.tab
      wait(function()
        return #vim.api.nvim_buf_get_lines(tab.buffers.board, 0, -1, false) > 3
      end, 5000, "the board")
      local lines = vim.api.nvim_buf_get_lines(tab.buffers.board, 0, -1, false)

      local widths, separators = {}, {}
      for line, info in pairs(tab.meta.board) do
        if info.kind == "board_header" or info.kind == "board_row" or info.kind == "board_gap" then
          local text = lines[line]
          widths[#widths + 1] = vim.fn.strdisplaywidth(text)
          local seen = {}
          local pos = 1
          while true do
            local at = text:find("┃", pos, true)
            if not at then
              break
            end
            seen[#seen + 1] = vim.fn.strdisplaywidth(text:sub(1, at - 1))
            pos = at + 1
          end
          separators[#separators + 1] = table.concat(seen, ",")
        end
      end
      t.truthy(#widths > 3)
      for _, width in ipairs(widths) do
        t.eq(widths[1], width, "every board row has one width")
      end
      for _, cells in ipairs(separators) do
        t.eq(separators[1], cells, "every board row puts ┃ in the same cells")
      end

      vim.api.nvim_set_current_win(tab.panels.board)
      local hits = 0
      for line, info in pairs(tab.meta.board) do
        if info.kind == "board_row" then
          for _, cell in ipairs(info.cells or {}) do
            if cell.card then
              vim.api.nvim_win_set_cursor(tab.panels.board, { line, cell.start })
              local kind, _, card = tab:current()
              t.eq("card", kind)
              t.eq(cell.card.id, card.id)
              hits = hits + 1
            end
          end
        end
      end
      t.truthy(hits > 0)

      -- The bold span covers the card id itself, not a border byte.
      local ids = {}
      for _, info in pairs(tab.meta.board) do
        for _, cell in ipairs(info.cells or {}) do
          if cell.card then
            ids[cell.card.id] = true
          end
        end
      end
      local bold = 0
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(tab.buffers.board, tab.mark_ns, 0, -1, { details = true })) do
        if mark[4].hl_group == "AdeBold" then
          local text = vim.api.nvim_buf_get_text(tab.buffers.board, mark[2], mark[3], mark[2], mark[4].end_col, {})[1]
          t.truthy(ids[text], text)
          bold = bold + 1
        end
      end
      t.truthy(bold > 0)
      local header_text = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(tab.buffers.board, tab.mark_ns, 0, -1, { details = true })) do
        if mark[4].hl_group == "AdeBoardColumn1" then
          header_text[#header_text + 1] =
            vim.api.nvim_buf_get_text(tab.buffers.board, mark[2], mark[3], mark[2], mark[4].end_col, {})[1]
        end
      end
      t.match("待开发", table.concat(header_text, ""))
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
      -- The model moves to its own line when the first one is full.
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
      ctx.width = 30
      local spawn_failed = render({
        kind = "tool",
        tool_name = "ade-team_team_spawn",
        status = "failed",
        raw_input = { name = "worker-long-name", template = "coder", model = "a/very-long-model-name" },
      })
      t.match("失败", spawn_failed)
      ctx.width = 12
      ctx.icons = blocks.icon_set("ascii")
      local short = render({
        kind = "tool",
        tool_name = "ade-team_board_update",
        status = "completed",
        raw_input = { upsert = { { id = "C1" }, { id = "C2" } } },
      })
      t.truthy(vim.fn.strdisplaywidth(short:gsub("\n.*", "")) <= 12, short)
    end)

    t.it("card detail focuses the popup and closes with q", function()
      wide(t)
      local service, dir = start_service(t, "v2-popup", { team_board = sample_board() })
      setup(t, "v2-popup", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      local tab = UI.tab
      wait(function()
        for _, info in pairs(tab.meta.board or {}) do
          for _, cell in ipairs(info.cells or {}) do
            if cell.card and cell.card.id == "T1" then
              return true
            end
          end
        end
        return false
      end, 5000, "the T1 card cell")
      local line, col
      for lnum, info in pairs(tab.meta.board or {}) do
        for _, cell in ipairs(info.cells or {}) do
          if cell.card and cell.card.id == "T1" then
            line, col = lnum, cell.start
          end
        end
      end
      t.truthy(line)
      vim.api.nvim_set_current_win(tab.panels.board)
      vim.api.nvim_win_set_cursor(tab.panels.board, { line, col })
      tab.dashboard:handle_key("cr")
      local detail_win, detail_buf
      wait(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == "ade_team_detail" then
            detail_win, detail_buf = win, buf
            return true
          end
        end
        return false
      end, 5000, "the card popup")
      t.eq(detail_win, vim.api.nvim_get_current_win(), "focus moves into the popup")
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return not vim.api.nvim_buf_is_valid(detail_buf) or #vim.api.nvim_buf_get_lines(detail_buf, 0, -1, false) == 0
      end, 5000, "the popup to close")
      t.eq(false, vim.api.nvim_win_is_valid(detail_win))
    end)

    t.it("the narrow float shows roles, marks and reachable cards", function()
      local service, dir = start_service(t, "v2-float", { team_board = sample_board() })
      setup(t, "v2-float", service, dir)
      controller.state().config.teams.dashboard.wide = 300
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team())
      local UI = ui()
      wait(function()
        return UI.win ~= nil and vim.api.nvim_win_is_valid(UI.win)
      end, 5000, "the float")
      t.eq(nil, UI.tab)
      local width = vim.api.nvim_win_get_width(UI.win)
      wait(function()
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false), "\n")
        return text:find("┃", 1, true) ~= nil
      end, 5000, "the float board")
      -- Move to the column that has the card (one column is visible).
      vim.api.nvim_set_current_win(UI.win)
      for lnum, id in pairs(UI.ids or {}) do
        if id == "t1|w1" then
          vim.api.nvim_win_set_cursor(UI.win, { lnum, 0 })
        end
      end
      local pressed = false
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(UI.buf, "n")) do
        if map.lhs == "zl" then
          map.callback()
          pressed = true
          break
        end
      end
      t.truthy(pressed)
      wait(function()
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false), "\n")
        return text:find("T1", 1, true) ~= nil
      end, 5000, "the card column")
      local text = table.concat(vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false), "\n")
      t.match("★", text)
      t.match("◆", text)
      t.match("┃", text)
      t.match("╭", text)
      for _, line in ipairs(vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)) do
        t.truthy(vim.fn.strdisplaywidth(line) <= width, line)
      end
      t.truthy(#vim.api.nvim_buf_get_extmarks(UI.buf, -1, 0, -1, {}) > 0)
      local card_line
      for lnum, id in pairs(UI.ids or {}) do
        if id == "card:t1|T1" then
          card_line = lnum
        end
      end
      t.truthy(card_line)
      vim.api.nvim_set_current_win(UI.win)
      vim.api.nvim_win_set_cursor(UI.win, { card_line, 0 })
      local kind, team_id, card = UI:current()
      t.eq("card", kind)
      t.eq("t1", team_id)
      t.eq("T1", card)

      -- Scrolling works from a card row, reports the position and clamps.
      for _ = 1, 5 do
        vim.api.nvim_feedkeys("zl", "x", false)
      end
      local float_text = table.concat(vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false), "\n")
      t.match("列 2/2", float_text)
      vim.api.nvim_feedkeys("zh", "x", false)
      t.match("列 1/2", table.concat(vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false), "\n"))
      -- Put the cursor back on T1 for the card actions.
      vim.api.nvim_feedkeys("zl", "x", false)
      for lnum, id in pairs(UI.ids or {}) do
        if id == "card:t1|T1" then
          vim.api.nvim_win_set_cursor(UI.win, { lnum, 0 })
        end
      end

      -- <CR> opens the card popup in the float.
      vim.api.nvim_set_current_win(UI.win)
      for lnum, id in pairs(UI.ids or {}) do
        if id == "card:t1|T1" then
          card_line = lnum
        end
      end
      vim.api.nvim_win_set_cursor(UI.win, { card_line, 0 })
      local check_kind = UI:current()
      t.eq("card", check_kind)
      vim.cmd("stopinsert")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "ade_team_detail" then
            return true
          end
        end
        return false
      end, 5000, "the float card popup")
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "ade_team_detail" then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end

      -- m on a card messages the leader about the card.
      vim.ui.input = function(_, cb)
        cb("please check the float card")
      end
      vim.api.nvim_feedkeys("m", "x", false)
      wait(function()
        local sends = service.team_sends or {}
        return #sends > 0 and sends[#sends].card == "T1"
      end, 5000, "the float card message")
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

    t.it("free-text questions do not mount the leader, option questions use the queue", function()
      wide(t)
      local service, dir = start_service(t, "v2-free-question")
      setup(t, "v2-free-question", service, dir)
      controller.connect()
      wait_ready()
      controller.open()
      service:team_changed(base_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      service:team_inbox({
        id = "i1",
        team = "t1",
        kind = "question",
        from = "w1",
        body = "type an answer",
        state = "open",
      })
      wait(function()
        return team():item("i1") ~= nil
      end, 5000, "the free-text question")
      t.eq(true, controller.open_team())
      local UI = ui()
      local queue = UI:choices()
      t.eq(0, queue:selectable_count("t1"))
      t.eq(1, (queue:pending_counts("t1") or {}).question)
      local function press(lhs)
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(UI.tab.buffers.members, "n")) do
          if map.lhs == lhs then
            map.callback()
            return true
          end
        end
        return false
      end
      t.eq(true, press("!"))
      t.eq(nil, UI._impl.leader_mounted, "! must not mount the leader for free text")

      service:team_inbox({
        id = "i2",
        team = "t1",
        kind = "question",
        from = "reviewer",
        body = "pick one",
        questions = { { question = "pick one", options = { { label = "A" }, { label = "B" } } } },
        state = "open",
      })
      wait(function()
        return team():item("i2") ~= nil
      end, 5000, "the option question")
      queue:answer_participant("t1", "reviewer")
      wait(function()
        return queue:is_open()
      end, 5000, "the option question in the component")
      queue.view:cancel()
    end)

    t.it("coalesces frequent dashboard refreshes", function()
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
        return team():board("t1") ~= nil or team():team("t1").board_rev == nil
      end, 5000, "the first paint")
      local impl = UI._impl
      local count = 0
      local original = impl.refresh
      impl.refresh = function(self)
        count = count + 1
        return original(self)
      end
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
      t.truthy(count <= 2, "a burst of three changes coalesces into at most two paints")
      wait(function()
        return vim.o.tabline:find("team t1", 1, true) ~= nil
      end, 5000, "the final state after the merged refresh")
    end)
  end)
end
