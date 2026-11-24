-- Restored teams v3 coverage: the board cache and the workflow window
-- (PROTOCOL.md 19.2, 19.5).
--
-- Ported from `feat/teams-v3:tests/spec_w0e_team.lua` (one `team.board` in
-- flight plus a coalesced refetch, a revision fetched only once, a late board
-- after a close, a late board from a dead connection, the implicit fetch from
-- `team.changed`, the workflows window's list/open/delete and its late
-- replies). `tests/spec_w0f_dashboard.lua` keeps the rendering of the board
-- pane itself.
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-v3board-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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

  local function team_changed(service, dir, over)
    service:team_changed(vim.tbl_deep_extend("force", {
      id = "t1",
      cwd = dir,
      state = "active",
      participants = {},
      inbox = {},
      limits = {},
    }, over or {}))
  end

  local function wait_team(service, dir)
    wait(function()
      return team():team("t1") ~= nil
    end, 5000, "the team")
  end

  t.describe("teams v3 board cache", function()
    t.it("keeps one team.board in flight and refetches the latest revision once", function()
      local service, dir = start_service(t, "board", {
        team_board_delay = 150,
        team_boards = {},
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      service.team_boards = {
        { rev = 1, columns = { "todo" }, cards = {} },
        { rev = 2, columns = { "todo", "doing" }, cards = {} },
        { rev = 3, columns = { "todo", "doing", "done" }, cards = {} },
      }
      team_changed(service, dir, { board_rev = 1 })
      wait_team(service, dir)
      -- Both notifications arrive while the first request is in flight: the
      -- second only sets the latch, so exactly one coalesced refetch follows.
      service:emit_team_board_changed("t1", 2)
      service:emit_team_board_changed("t1", 2)
      wait(function()
        local board = team():board("t1")
        return board ~= nil and board.rev == 2
      end, 10000, "the refetched board")
      t.eq(2, #service.team_board_requests, "one request plus exactly one coalesced refetch")
      -- A later notification fetches again.
      service:emit_team_board_changed("t1", 3)
      wait(function()
        local board = team():board("t1")
        return #service.team_board_requests == 3 and board ~= nil and board.rev == 3
      end, 10000, "the next board change")
    end)

    t.it("fetches a stale revision only once", function()
      local service, dir = start_service(t, "board-rev-once", {
        team_board_error = { code = -32066, message = "board read failed" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      team_changed(service, dir, { board_rev = 2 })
      wait(function()
        return team():team("t1") ~= nil and #service.team_board_requests == 1
      end, 5000, "the first board attempt")
      team_changed(service, dir, { board_rev = 2 })
      team_changed(service, dir, { board_rev = 2 })
      vim.wait(150)
      t.eq(1, #service.team_board_requests, "the same revision is not retried")
      -- A real notification is a fresh reason to try again.
      service:emit_team_board_changed("t1", 2)
      wait(function()
        return #service.team_board_requests == 2
      end, 5000, "the retry after board_changed")
    end)

    t.it("fetches a board named by team.changed without a board_changed", function()
      local service, dir = start_service(t, "board-sync", {
        team_board = { rev = 3, columns = { "todo" }, cards = {} },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      team_changed(service, dir, { board_rev = 3 })
      wait(function()
        local board = team():board("t1")
        return board ~= nil and board.rev == 3
      end, 5000, "the board from team.changed")
      t.eq(1, #service.team_board_requests)
    end)

    t.it("ignores a board reply that arrives after the team closed", function()
      local service, dir = start_service(t, "board-late-close", { team_board_delay = 200 })
      setup(t, dir)
      controller.connect()
      wait_ready()
      team_changed(service, dir)
      wait_team(service, dir)
      team():request_board("t1")
      team_changed(service, dir, { state = "closed" })
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      vim.wait(400)
      t.eq(nil, team():board("t1"), "a late board must not resurrect the cache")
      t.eq(nil, team().boards["t1"])
      local before = #service.team_board_requests
      service:emit_team_board_changed("t1", 5)
      vim.wait(150)
      t.eq(before, #service.team_board_requests, "a closed team's board is never fetched")
    end)

    t.it("drops a board reply from a connection that already died", function()
      local service, dir = start_service(t, "board-stale", { team_board_delay = 200 })
      setup(t, dir)
      controller.connect()
      wait_ready()
      team_changed(service, dir)
      wait_team(service, dir)
      team():request_board("t1")
      team():forget_connection()
      vim.wait(400)
      t.eq(nil, team():board("t1"), "the stale reply is ignored")
      local entry = team().boards["t1"]
      t.eq(false, entry and entry.inflight or false, "the latch is clear")
      t.eq(false, entry and entry.again or false)
    end)

    t.it("refreshes the board pane only on a real team change", function()
      local service, dir = start_service(t, "board-pane", {
        team_board = {
          rev = 1,
          columns = { "todo" },
          cards = {
            { id = "T1", title = "first", column = "todo", archived = false, updated_by = "leader", updated_at = 1 },
          },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      team_changed(service, dir, { board_rev = 1 })
      wait_team(service, dir)
      local UI = state().view.team_ui
      t.eq(true, controller.open_team("board"))
      local function text()
        local buf = UI.layout:buf("board")
        return buf and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") or ""
      end
      wait(function()
        return text():find("T1", 1, true) ~= nil
      end, 5000, "the first card")
      -- A new revision with the card renamed: only `team.changed` carries it,
      -- so the pane must repaint from that alone.
      service.team_board = {
        rev = 2,
        columns = { "todo" },
        cards = {
          { id = "T1", title = "renamed", column = "todo", archived = false, updated_by = "leader", updated_at = 2 },
        },
      }
      service:emit_team_board_changed("t1", 2)
      wait(function()
        return text():find("renamed", 1, true) ~= nil
      end, 5000, "the repainted card")
      UI:close()
    end)
  end)

  t.describe("teams v3 workflows", function()
    t.it("lists, opens and deletes workflows from :Ade workflows", function()
      local service, dir = start_service(t, "command-workflows", {
        team_workflows = {
          {
            name = "default",
            summary = "the built-in default flow",
            text = "1. plan\n2. work",
            team = {},
            columns = { "todo" },
            scope = "builtin",
          },
          {
            name = "review",
            summary = "opencode writes, pi reviews",
            text = "1. write 2. review",
            team = { { name = "reviewer", template = "worker", model = "m1" } },
            columns = { "todo", "review" },
            scope = "project",
          },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      vim.cmd("Ade workflows")
      local ui = state().view.team_commands.workflows_ui
      wait(function()
        return ui and ui:is_open()
      end, 5000, "the workflows window")
      local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
      t.match("default", text)
      t.match("builtin", text)
      t.match("review", text)
      -- <CR> shows the flow text of the workflow under the cursor.
      vim.api.nvim_win_set_cursor(ui.win, { 3, 0 })
      ui:detail()
      local detail_lines = vim.api.nvim_buf_get_lines(ui.detail_buf, 0, -1, false)
      local detail = table.concat(detail_lines, "\n")
      t.match("1%. plan", detail)
      local first = vim.fn.index(detail_lines, "1. plan")
      t.eq("2. work", detail_lines[first + 2], "flow lines stay adjacent")
      ui:close_detail()
      -- The built-in default cannot be deleted.
      local notices = capture(t)
      vim.api.nvim_win_set_cursor(ui.win, { 3, 0 })
      ui:delete_current()
      vim.wait(100)
      t.eq(0, #service.team_workflow_deletes)
      t.match("cannot be deleted", joined(notices))
      -- A stored workflow is deleted through the service, after a
      -- confirmation; the window refetches instead of closing.
      local original_select = vim.ui.select
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      vim.ui.select = function(items, _, cb)
        cb(items[2]) -- "No"
      end
      vim.api.nvim_win_set_cursor(ui.win, { 4, 0 })
      ui:delete_current()
      vim.wait(100)
      t.eq(0, #service.team_workflow_deletes, "a refused confirmation deletes nothing")
      vim.ui.select = function(items, _, cb)
        cb(items[1]) -- "Yes"
      end
      t.eq("review", ui:current().name)
      ui:delete_current()
      wait(function()
        return #service.team_workflow_deletes == 1
      end, 5000, "the workflow delete")
      t.eq("review", service.team_workflow_deletes[1].name)
      t.eq("project", service.team_workflow_deletes[1].scope)
      wait(function()
        local lines = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
        return not lines:find("review", 1, true)
      end, 5000, "the refetched workflow list")
      t.eq(true, ui:is_open(), "deleting keeps the window open")
      ui:close()
    end)

    t.it("does not reopen the workflows window when the first fetch is late", function()
      local service, dir = start_service(t, "workflows-late-first", {
        team_workflows = {
          { name = "review", summary = "by pi", text = "x", team = {}, scope = "project" },
        },
        team_workflows_delay = 200,
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local UI
      vim.cmd("Ade workflows")
      UI = state().view.team_commands.workflows_ui
      t.truthy(UI)
      UI:close()
      vim.wait(400)
      t.eq(false, UI:is_open(), "a late first reply must not open the window")
    end)

    t.it("does not reopen the workflows window when a delete reply arrives late", function()
      local service, dir = start_service(t, "workflows-late", {
        team_workflows = {
          { name = "review", summary = "by pi", text = "x", team = {}, scope = "project" },
        },
        team_workflow_delete_delay = 150,
      })
      setup(t, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      vim.cmd("Ade workflows")
      local ui = state().view.team_commands.workflows_ui
      wait(function()
        return ui and ui:is_open()
      end, 5000, "the workflows window")
      vim.api.nvim_win_set_cursor(ui.win, { 3, 0 })
      local original_select = vim.ui.select
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      vim.ui.select = function(items, _, cb)
        cb(items[1])
      end
      ui:delete_current()
      ui:close()
      wait(function()
        return #service.team_workflow_deletes == 1
      end, 5000, "the delete reply")
      vim.wait(400)
      t.eq(false, ui:is_open(), "a late delete reply must not reopen the window")
      t.falsy(joined(notices):find("cannot list workflows", 1, true), joined(notices))
    end)
  end)
end
