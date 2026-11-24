-- Restored teams v3 coverage: a bus turn in the ordinary chat and the rendering
-- of a watched worker's tools, plans and bus messages (PROTOCOL.md 19.9).
--
-- Ported from `feat/teams-v3:tests/spec_s4_team.lua` ("renders
-- _ade/turn_started …", "a cancelled bus turn finishes the session cleanly",
-- "sends the person's prompt straight through while a bus turn runs", "renders
-- watched tools, diffs, turns, plans and bus messages", and the bus-tool unit
-- checks). The v3 router shows the worker in the shared chat, so the diff and
-- the role card are asserted through that one buffer.
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
    local dir = string.format("/tmp/opencode/ade-v3turn-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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

  local function team()
    return state().view.team
  end

  local function transcript(session)
    local out = {}
    for _, block in ipairs(session and session.blocks or {}) do
      out[#out + 1] = block.text or ""
    end
    return table.concat(out, "\n")
  end

  local function seed_team(service, dir)
    service:team_changed({
      id = "t1",
      cwd = dir,
      state = "active",
      participants = {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
      },
      inbox = {},
      limits = { max_turns_per_task = 30, max_turns_total = 200, turns_total = 0 },
    })
    wait(function()
      return team():team("t1") ~= nil
    end, 5000, "the team")
  end

  t.describe("teams v3 bus turn", function()
    t.it("renders _ade/turn_started as a bus turn and settles on _ade/turn_finished", function()
      local service, dir = start_service(t, "turn")
      setup(t, dir)
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
        return transcript(session):find("do the thing", 1, true) ~= nil
      end, 5000, "the bus turn content")
      t.eq("running", session.status)
      t.truthy(session.bus_turn, "the turn is marked as a bus turn")
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
      t.eq(nil, session.bus_turn)
    end)

    t.it("a cancelled bus turn finishes the session cleanly", function()
      local service, dir = start_service(t, "turn-cancelled")
      setup(t, dir)
      controller.connect()
      wait_ready()
      local session = state().sess.current
      local instance = state().conn.client.proc.instance
      service:turn_started(instance, {
        sessionId = session.id,
        origin = "bus",
        prompt = { { type = "text", text = "cancel me" } },
      })
      wait(function()
        return session.status == "running"
      end, 5000, "the bus turn")
      service:broadcast("tunnel.recv", {
        instance = instance,
        seq = 1,
        message = {
          jsonrpc = "2.0",
          method = "_ade/turn_finished",
          params = { sessionId = session.id, stopReason = "cancelled" },
        },
      })
      wait(function()
        return session.status == "idle"
      end, 5000, "the cancelled bus turn to settle")
      t.eq(nil, session.bus_turn, "the bus turn is cleared")
    end)

    t.it("sends the person's prompt straight through while a bus turn runs", function()
      local service, dir = start_service(t, "bus-priority")
      setup(t, dir)
      controller.connect()
      wait_ready()
      local session = state().sess.current
      local instance = state().conn.client.proc.instance
      service:turn_started(instance, {
        sessionId = session.id,
        origin = "bus",
        prompt = { { type = "text", text = "bus work" } },
      })
      wait(function()
        return session.bus_turn ~= nil and session.status == "running"
      end, 5000, "the bus turn")
      local before = session.turn
      t.eq(true, controller.send_now("person first", nil))
      -- The person's prompt supersedes the bus turn instead of being queued.
      t.eq(nil, session.bus_turn)
      t.eq(0, #session.queue)
      t.truthy(session.turn > before)
      -- A late cancelled bus finish must not end the person's turn.
      team():turn_finished({ sessionId = session.id, stopReason = "cancelled" })
      t.eq("running", session.status)
      wait(function()
        return transcript(session):find("person first", 1, true) ~= nil
      end, 10000, "the person's message")
      wait(function()
        return session.status == "idle"
      end, 15000, "the person's turn to finish")
    end)
  end)

  t.describe("teams v3 watched rendering", function()
    t.it("renders turns, the collapsed role card, a diff and a bus message", function()
      local service, dir = start_service(t, "watch-render", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replay = {
            {
              sessionUpdate = "user_message_chunk",
              content = {
                type = "text",
                text = 'You are w1, a worker in team t1.\n<team_role>\nROLE TEXT</team_role><bus from="leader" kind="task" task="T4">do work</bus>',
              },
            },
            {
              sessionUpdate = "tool_call",
              toolCallId = "call-edit",
              title = "Edit src/a.rs",
              kind = "edit",
              status = "in_progress",
              content = { { type = "diff", path = "src/a.rs", oldText = "old line", newText = "new line" } },
            },
            { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "implemented" } },
          },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local ok = false
      team():watch("t1", "w1", true, function(result)
        ok = result
      end)
      wait(function()
        return ok
      end, 10000, "team.watch")
      local UI = state().view.team_ui
      UI:watch(team().watching.session, "t1/w1")
      local router = UI.router
      t.truthy(router.target, "the worker is shown in the shared chat")
      local buf = router.chat.buf
      local win = router.chat.win
      local function text()
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      end
      wait(function()
        return text():find("── turn 1", 1, true) ~= nil and text():find("leader → task T4", 1, true) ~= nil
      end, 10000, "the first turn heading and bus message")
      t.match("role card", text())
      t.falsy(text():find("ROLE TEXT", 1, true), "the role card starts collapsed")
      t.match("src/a.rs", text())
      local turn1
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("── turn 1", 1, true) then
          turn1 = line
        end
      end
      t.truthy(turn1)
      t.falsy(turn1:match("%d+%.%ds"), "a replayed turn has no reliable duration")

      -- The role card expands in place and survives live refreshes.
      local role_line
      for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("role card", 1, true) then
          role_line = index
        end
      end
      t.truthy(role_line)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { role_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
      wait(function()
        return text():find("ROLE TEXT", 1, true) ~= nil
      end, 5000, "the role card expansion")

      -- A second live turn with a plan and a bus tool call.
      service:turn_started("inst-w", {
        sessionId = "sess-w",
        origin = "bus",
        prompt = { { type = "text", text = '<bus from="leader" kind="task" task="T5">second task</bus>' } },
      })
      service:watch_update("inst-w", "sess-w", {
        sessionUpdate = "plan",
        entries = { { content = "补 reconnect 的回归测试", status = "in_progress", priority = "high" } },
      })
      service:watch_update("inst-w", "sess-w", {
        sessionUpdate = "tool_call",
        toolCallId = "call-bus",
        title = "ade-team_bus_send",
        status = "completed",
        rawInput = { to = "leader", kind = "report", task = "T4", body = "tests pass" },
      })
      service:turn_finished("inst-w", { sessionId = "sess-w", stopReason = "end_turn" })
      wait(function()
        local body = text()
        return body:find("── turn 2", 1, true) ~= nil
          and body:find("leader → task T5", 1, true) ~= nil
          and body:find("补 reconnect 的回归测试", 1, true) ~= nil
          and body:find("→ leader report T4", 1, true) ~= nil
          and body:find("tests pass", 1, true) ~= nil
      end, 10000, "the second turn, plan and bus message")

      -- The diff is the ordinary tool card, not flattened text.
      local edit_line
      for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("src/a.rs", 1, true) then
          edit_line = index
        end
      end
      t.truthy(edit_line)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { edit_line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
      wait(function()
        local body = text()
        return body:find("old line", 1, true) ~= nil or body:find("new line", 1, true) ~= nil
      end, 5000, "the expanded diff")

      -- The worker transcript is the ordinary chat: no dedicated filetype and
      -- no second composer.
      t.eq("ade_chat", vim.bo[buf].filetype)
      t.eq(1, #vim.fn.win_findbuf(buf), "one transcript window")
      t.eq(state().view.chat, router.chat, "the shared chat renders the worker")

      -- za folds the whole turn under the cursor; a second za restores it.
      local heading
      for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("── turn 2", 1, true) then
          heading = index
        end
      end
      t.truthy(heading)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { heading, 0 })
      vim.api.nvim_feedkeys("za", "x", false)
      wait(function()
        local body = text()
        return body:find("── turn 2 ·", 1, true) ~= nil
          and body:find("(collapsed)", 1, true) ~= nil
          and body:find("补 reconnect 的回归测试", 1, true) == nil
      end, 5000, "the collapsed turn")
      local heading2
      for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("── turn 2", 1, true) then
          heading2 = index
        end
      end
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { heading2, 0 })
      vim.api.nvim_feedkeys("za", "x", false)
      wait(function()
        local body = text()
        return body:find("(collapsed)", 1, true) == nil and body:find("补 reconnect 的回归测试", 1, true) ~= nil
      end, 5000, "the expanded turn")

      -- ]] and [[ move between turn headings.
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.api.nvim_feedkeys("]]", "x", false)
      local cursor = vim.api.nvim_win_get_cursor(win)[1]
      t.match("── turn 1", vim.api.nvim_buf_get_lines(buf, cursor - 1, cursor, false)[1] or "")
      vim.api.nvim_feedkeys("]]", "x", false)
      cursor = vim.api.nvim_win_get_cursor(win)[1]
      t.match("── turn 2", vim.api.nvim_buf_get_lines(buf, cursor - 1, cursor, false)[1] or "")
      vim.api.nvim_feedkeys("[[", "x", false)
      cursor = vim.api.nvim_win_get_cursor(win)[1]
      t.match("── turn 1", vim.api.nvim_buf_get_lines(buf, cursor - 1, cursor, false)[1] or "")

      -- Live updates reuse the display session: the scroll position, the
      -- follow flag and the synthetic expansions survive a refresh.
      local chat = router.chat
      local original_set_session = chat.set_session
      local set_sessions = 0
      chat.set_session = function(self, session)
        set_sessions = set_sessions + 1
        return original_set_session(self, session)
      end
      chat.follow = false
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      service:watch_update("inst-w", "sess-w", {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "follow up" },
      })
      wait(function()
        return text():find("follow up", 1, true) ~= nil
      end, 5000, "the live update")
      t.eq(0, set_sessions, "live updates do not call set_session again")
      t.eq(1, vim.api.nvim_win_get_cursor(win)[1], "the scroll position is preserved")
      t.eq(false, chat.follow, "the follow state is preserved")
      t.match("ROLE TEXT", text(), "synthetic expansion survives a refresh")
      router:close()
      team():unwatch()
    end)

    t.it("only bus tools become messages and only the first prompt has a role card", function()
      local watch = require("ade.ui.team.watch")
      t.eq(
        nil,
        watch.bus_tool({ kind = "tool", tool_name = "create_issue", raw_input = { body = "x" } }),
        "a tool with a body argument is not a bus message"
      )
      local direct = watch.bus_tool({
        kind = "tool",
        tool_name = "mcp__ade-team__bus_send",
        raw_input = { to = "leader", kind = "report", task = "T4", body = "done" },
      })
      t.truthy(direct)
      t.match("→ leader report T4", direct.title)
      t.match("done", direct.text)
      local proxy = watch.bus_tool({
        kind = "tool",
        tool_name = "mcp",
        raw_input = { tool = "bus_ask_human", args = { question = "keep it?" } },
      })
      t.truthy(proxy)
      t.match("提问", proxy.title)
      t.match("keep it?", proxy.text)
      local role, message = watch.split_role("You are w1, a worker.")
      t.eq(nil, role)
      t.match("You are w1", message)
      role, message = watch.split_role('You are w1<bus from="leader" kind="task">do</bus>')
      t.truthy(role)
      t.match("do", message)
    end)
  end)
end
