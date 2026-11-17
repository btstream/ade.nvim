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
      t.eq(4, #{ UI.tab.panels.members, UI.tab.panels.inbox, UI.tab.panels.board, UI.tab.panels.detail })
      for _, win in ipairs({ UI.tab.panels.members, UI.tab.panels.inbox, UI.tab.panels.board, UI.tab.panels.detail }) do
        t.truthy(vim.api.nvim_win_is_valid(win))
      end
      wait(function()
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.members, 0, -1, false), "\n")
        return text:find("w1", 1, true) and text:find("执行 cargo test", 1, true)
      end, 5000, "member rows with activity")
      local members = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.members, 0, -1, false), "\n")
      t.match("●", members)
      t.match("↳", members)
      t.match("wt ade/t1/w1", members)
      local inbox = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.inbox, 0, -1, false), "\n")
      t.match("i21–i22", inbox)
      t.match("申请启动 2 个 worker", inbox)
      t.match("w2 opencode/m2", inbox)
      wait(function()
        local board = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.board, 0, -1, false), "\n")
        return board:find("T1", 1, true) and board:find("待开发", 1, true)
      end, 5000, "the board")
      t.match("流程：dev", vim.wo[UI.tab.panels.members].winbar .. vim.wo[UI.tab.panels.board].winbar)
      t.match("阶段 S1", vim.wo[UI.tab.panels.board].winbar)
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
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.detail, 0, -1, false), "\n")
        return text:find("已修复", 1, true) and text:find("tests=✓ 42", 1, true)
      end, 5000, "the card detail")
      wait(function()
        local marks = vim.api.nvim_buf_get_extmarks(UI.tab.buffers.members, UI.tab.dashboard.link_ns, 0, -1, {})
        return #marks > 0
      end, 5000, "the owner highlight")
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
      local inbox_detail =
        Detail.inbox({ kind = "question", id = "i1", state = "open", from = "w1\nsecond", body = "a\nb" })
      t.falsy(inbox_detail[1]:find("\n", 1, true), inbox_detail[1])
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
      }, {}, { width = 80, scroll = 1 })
      t.falsy(table.concat(scrolled, "\n"):find("待开发", 1, true))
      t.match("doing", scrolled[1])
      local unavailable = Board.lines({ unavailable = true, rev = 3 }, {}, { width = 80 })
      t.match("看板不可用", table.concat(unavailable, "\n"))
      local empty = Board.lines(nil, {}, { width = 80 })
      t.match("leader 还没有创建看板", table.concat(empty, "\n"))
      t.match("按 L 去和 leader 聊", table.concat(empty, "\n"))
    end)

    t.it("group A approves all spawns and S starts the selected workflow", function()
      wide(t)
      local service, dir = start_service(t, "actions")
      setup(t, "actions", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      service:team_inbox({
        id = "i31",
        team = "t1",
        kind = "spawn",
        from = "leader",
        name = "w2",
        template = "opencode",
        group = "g2",
        state = "open",
        body = "spawn",
      })
      service:team_inbox({
        id = "i32",
        team = "t1",
        kind = "spawn",
        from = "leader",
        name = "w3",
        template = "opencode",
        group = "g2",
        state = "open",
        body = "spawn",
      })
      wait(function()
        return team():item("i32") ~= nil
      end, 5000, "the spawn group")
      t.eq(true, controller.open_team())
      local UI = ui()
      local group_line
      for index, id in pairs(UI.tab.ids.inbox or {}) do
        if id == "item:i31" then
          group_line = index
        end
      end
      t.truthy(group_line)
      vim.api.nvim_set_current_win(UI.tab.panels.inbox)
      vim.api.nvim_win_set_cursor(UI.tab.panels.inbox, { group_line, 0 })
      vim.api.nvim_feedkeys("A", "x", false)
      wait(function()
        return #(service.team_answer_groups or {}) == 1
      end, 5000, "the group answer")
      t.eq("g2", service.team_answer_groups[1].group)

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
      vim.api.nvim_win_close(UI.tab.panels.inbox, true)
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

    t.it("the narrow float keeps the group A key", function()
      local service, dir = start_service(t, "narrow-actions")
      setup(t, "narrow-actions", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed(base_team(dir))
      service:team_inbox({
        id = "i41",
        team = "t1",
        kind = "spawn",
        from = "leader",
        name = "w2",
        template = "opencode",
        group = "g4",
        state = "open",
        body = "spawn",
      })
      service:team_inbox({
        id = "i42",
        team = "t1",
        kind = "spawn",
        from = "leader",
        name = "w3",
        template = "opencode",
        group = "g4",
        state = "open",
        body = "spawn",
      })
      wait(function()
        return team():item("i42") ~= nil
      end, 5000, "the narrow spawn group")
      t.eq(true, controller.open_team())
      local UI = ui()
      local line
      for index, id in pairs(UI.ids or {}) do
        if id == "item:i41" or id == "item:i42" then
          line = index
        end
      end
      t.truthy(line)
      vim.api.nvim_set_current_win(UI.win)
      vim.api.nvim_win_set_cursor(UI.win, { line, 0 })
      vim.api.nvim_feedkeys("A", "x", false)
      wait(function()
        return #(service.team_answer_groups or {}) == 1
      end, 5000, "the narrow group answer")
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
        local text = table.concat(vim.api.nvim_buf_get_lines(UI.tab.buffers.inbox, 0, -1, false), "\n")
        return text:find("i43", 1, true) ~= nil
      end, 5000, "the final state after the merged refresh")
    end)
  end)
end
