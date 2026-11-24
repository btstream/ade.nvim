-- Restored teams v3 coverage: the members panel's actions and the wire shape of
-- `team.answer` / `team.send` / `team.spawn` / `team.remove_worktree`
-- (PROTOCOL.md 19.4, 20.4, 20.6).
--
-- Ported from `feat/teams-v3:tests/spec_s4_team.lua` (the whole
-- "panel" block: every inbox kind, send/control/reset/close, `m`, `s`, `s`'s
-- name validation, `D` and git's stderr) and
-- `feat/teams-v3:tests/spec_w0e_team.lua` (the new `team.list` fields and a
-- partially failed group answer). The dashboard rendering spec keeps the
-- empty state and the per-pane drawing; this file pins the actions.
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
    local dir = string.format("/tmp/opencode/ade-v3panel-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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

  local function calls_of(service, method)
    local out = {}
    for _, call in ipairs(service.calls) do
      if call.method == method then
        out[#out + 1] = call
      end
    end
    return out
  end

  local function team()
    return state().view.team
  end

  local function ui()
    return state().view.team_ui
  end

  local function panel_text(name)
    local UI = ui()
    local buf = UI.layout:buf(name or "members")
    if not buf then
      return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function row_of(id, pane)
    local UI = ui()
    pane = pane or "members"
    for index, value in pairs(UI.layout.ids[pane] or {}) do
      if value == id then
        return index
      end
    end
  end

  local function focus_row(id, pane)
    local UI = ui()
    pane = pane or "members"
    local line = row_of(id, pane)
    t.truthy(line, "a row for " .. id)
    vim.api.nvim_set_current_win(UI.layout:win(pane))
    vim.api.nvim_win_set_cursor(UI.layout:win(pane), { line, 0 })
    return line
  end

  ---Give the front end an active team on the service side.
  local function seed_team(service, dir, over)
    local team_row = vim.tbl_deep_extend("force", {
      id = "t1",
      cwd = dir,
      state = "active",
      participants = {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
      },
      inbox = {},
      limits = { max_turns_per_task = 30, max_turns_total = 200, turns_total = 0 },
    }, over or {})
    service.teams[team_row.id] = vim.deepcopy(team_row)
    service:team_changed(team_row)
    wait(function()
      return team():team(team_row.id) ~= nil
    end, 5000, "the team")
    return team_row
  end

  local function call(fn)
    local done, ok, value = false, nil, nil
    fn(function(result, result_value)
      done, ok, value = true, result, result_value
    end)
    wait(function()
      return done
    end, 5000, "the team request")
    return ok, value
  end

  local function stub_ui(t, choices)
    local original_select, original_input = vim.ui.select, vim.ui.input
    local asked = {}
    vim.ui.select = function(items, _, cb)
      local want = choices.select
      asked[#asked + 1] = vim.deepcopy(items)
      if want == vim.NIL then
        cb(nil)
        return
      end
      if type(want) == "function" then
        cb(want(items))
        return
      end
      cb(want)
    end
    vim.ui.input = function(_, cb)
      local want = choices.input
      asked[#asked + 1] = true
      cb(type(want) == "function" and want() or want)
    end
    t.cleanup(function()
      vim.ui.select, vim.ui.input = original_select, original_input
    end)
    return asked
  end

  local function yes_confirm(t)
    local original = presenter.confirm
    presenter.confirm = function(_, cb)
      cb("yes")
    end
    t.cleanup(function()
      presenter.confirm = original
    end)
  end

  t.describe("teams v3 panel actions", function()
    t.it("keeps every new team.list field and renders the inbox", function()
      local service, dir = start_service(t, "fields")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir, {
        board_rev = 4,
        workflow_name = "dev",
        stages = { { stage = "todo", open = 2, archived = 1 } },
        participants = {
          { name = "leader", role = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          {
            name = "w1",
            state = "working",
            task = "T1",
            queued = 0,
            turns = {},
            activity = { text = "running tests", at = 1767225600000 },
            state_since = 1767225600001,
            worktree = { path = "/tmp/wt/w1", branch = "ade/t1/w1" },
          },
        },
      })
      local entry = team():team("t1")
      t.eq(4, entry.board_rev)
      t.eq("dev", entry.workflow_name)
      t.eq(2, entry.stages[1].open)
      local worker = team():participant("t1", "w1")
      t.eq("running tests", worker.activity.text)
      t.eq(1767225600001, worker.state_since)

      service:team_inbox({
        id = "i1",
        team = "t1",
        kind = "question",
        from = "w1",
        body = "which one?",
        state = "open",
      })
      wait(function()
        return team():item("i1") ~= nil
      end, 5000, "the inbox item")
      t.eq(true, controller.open_team("members"))
      local UI = ui()
      wait(function()
        return panel_text("members"):find("running tests", 1, true) ~= nil
      end, 5000, "the member rows")
      local text = panel_text("members")
      t.match("t1", text)
      t.match("leader", text)
      t.match("w1", text)
      t.match("wt ade/t1/w1", text)
      -- An answered item leaves the panel without another team.changed.
      service:team_inbox({
        id = "i1",
        team = "t1",
        kind = "question",
        from = "w1",
        body = "which one?",
        state = "answered",
      })
      wait(function()
        local item = team():item("i1")
        return item ~= nil and item.state == "answered"
      end, 5000, "the answered item to leave the open inbox")
      UI:close()
    end)

    t.it("answers every inbox kind with the right team.answer payload", function()
      local service, dir = start_service(t, "inbox")
      setup(t, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local m = team()
      local items = {
        { id = "i1", team = "t1", kind = "question", from = "w1", body = "q", options = { "a", "b" }, state = "open" },
        {
          id = "i2",
          team = "t1",
          kind = "spawn",
          from = "leader",
          body = "",
          template = "worker",
          name = "w2",
          state = "open",
        },
        {
          id = "i3",
          team = "t1",
          kind = "permission",
          from = "w1",
          body = "",
          options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
          state = "open",
        },
        {
          id = "i4",
          team = "t1",
          kind = "request",
          from = "w1",
          body = "",
          instance = "i",
          method = "x",
          params = {},
          state = "open",
        },
        { id = "i5", team = "t1", kind = "message", from = "w1", body = "hi", state = "open" },
        { id = "i6", team = "t1", kind = "limit", from = "leader", body = "", scope = "task", state = "open" },
        {
          id = "i7",
          team = "t1",
          kind = "handover",
          from = { instance = "i2", sessionId = "s9" },
          leader = { instance = "i2", sessionId = "s9" },
          body = "",
          state = "open",
        },
      }
      for _, item in ipairs(items) do
        service:team_inbox(item)
      end
      wait(function()
        return joined(notices):find("team inbox", 1, true) ~= nil and #vim.tbl_keys(m.inbox) >= #items
      end, 5000, "one notification per new inbox item")
      local answers = {
        { "i1", { text = "b" } },
        { "i2", { allow = true } },
        { "i3", { option = "allow" } },
        { "i4", { text = '{"ok":true}' } },
        { "i5", {} },
        { "i6", {} },
        { "i7", { option = "move" } },
      }
      for _, answer in ipairs(answers) do
        local sent = false
        m:answer(answer[1], answer[2], function()
          sent = true
        end)
        wait(function()
          return sent
        end, 5000, "answer " .. answer[1])
      end
      t.eq(#answers, #service.team_answers)
      for index, answer in ipairs(answers) do
        t.eq(answer[1], service.team_answers[index].request)
        for key, value in pairs(answer[2]) do
          t.eq(value, service.team_answers[index][key])
        end
      end
    end)

    t.it("hands a partially failed group answer to the caller", function()
      local service, dir = start_service(t, "group-partial", {
        team_answer_group_failed = { { id = "i2", code = -32061, message = "unknown template" } },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local ok, value = call(function(cb)
        team():answer_group("g1", true, cb)
      end)
      t.eq(true, ok)
      t.eq("g1", service.team_answer_groups[1].group)
      t.eq(true, service.team_answer_groups[1].allow)
      t.eq(1, #value.failed, vim.inspect(value))
      t.eq("i2", value.failed[1].id)
      t.eq(-32061, value.failed[1].code)
      -- A service that omits `failed` still gives the caller an empty list.
      service.team_answer_group_failed = nil
      local plain_ok, plain = call(function(cb)
        team():answer_group("g2", false, cb)
      end)
      t.eq(true, plain_ok)
      t.truthy(type(plain.failed) == "table")
      t.eq(0, #plain.failed)
    end)

    t.it("sends, controls, resets and closes through the panel API", function()
      local service, dir = start_service(t, "actions")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local m = team()
      call(function(cb)
        m:send("t1", "w1", "task", "do it", { task = "T1" }, cb)
      end)
      call(function(cb)
        m:control("t1", "w1", "pause", cb)
      end)
      call(function(cb)
        m:reset_limits("t1", cb)
      end)
      call(function(cb)
        m:close("t1", cb)
      end)
      t.eq(2, #service.team_sends)
      t.eq("task", service.team_sends[1].kind)
      t.eq("T1", service.team_sends[1].task)
      t.eq("control", service.team_sends[2].kind)
      t.eq("pause", service.team_sends[2].body)
      t.truthy(#calls_of(service, "team.reset_limits") >= 1)
      t.truthy(#calls_of(service, "team.close") >= 1)
      -- A closed team leaves the local cache as soon as the reply lands.
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
    end)

    t.it("`m` sends a legal bus kind and a cancelled picker sends nothing", function()
      local service, dir = start_service(t, "panel-send")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      t.eq(true, controller.open_team("members"))
      stub_ui(t, { select = "task", input = "do the thing" })
      focus_row("t1|w1")
      ui():handle_key("m")
      wait(function()
        return #service.team_sends == 1
      end, 5000, "the panel message")
      t.eq("task", service.team_sends[1].kind)
      t.eq("do the thing", service.team_sends[1].body)
      t.eq("w1", service.team_sends[1].to)

      -- Cancelling the kind picker must abort, not fall back to `notice`.
      stub_ui(t, { select = vim.NIL, input = "never" })
      focus_row("t1|w1")
      ui():handle_key("m")
      vim.wait(150)
      t.eq(1, #service.team_sends, "a cancelled kind picker must not send")
      ui():close()
    end)

    t.it("`s` starts a worker from a template and re-asks an invalid name", function()
      local service, dir = start_service(t, "panel-spawn")
      setup(t, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      t.eq(true, controller.open_team("members"))
      local answers = { "w9", "task nine" }
      stub_ui(t, {
        select = "worker",
        input = function()
          return table.remove(answers, 1)
        end,
      })
      focus_row("team:t1")
      ui():handle_key("s")
      wait(function()
        return #service.team_spawns == 1
      end, 5000, "the person-started worker")
      t.eq("t1", service.team_spawns[1].team)
      t.eq("worker", service.team_spawns[1].template)
      t.eq("w9", service.team_spawns[1].name)
      t.eq("task nine", service.team_spawns[1].task)

      -- Invalid/reserved names are rejected before the request and re-asked.
      answers = { "leader", "Bad", "w10", "" }
      focus_row("team:t1")
      ui():handle_key("s")
      wait(function()
        return #service.team_spawns == 2
      end, 5000, "the corrected worker name")
      t.eq("w10", service.team_spawns[2].name)
      t.eq(nil, service.team_spawns[2].task)
      t.match("not be leader or human", joined(notices))
      ui():close()
    end)

    t.it("`D` removes an exited worker's worktree only", function()
      local service, dir = start_service(t, "panel-worktree", {
        team_remove_result = { removed = true, branch_kept = true, branch = "ade/t1/w1" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir, {
        participants = {
          { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          {
            name = "w1",
            state = "exited",
            task = "_",
            queued = 0,
            turns = {},
            worktree = { path = "/tmp/wt/w1", branch = "ade/t1/w1" },
          },
          {
            name = "w2",
            state = "idle",
            task = "_",
            queued = 0,
            turns = {},
            worktree = { path = "/tmp/wt/w2", branch = "ade/t1/w2" },
          },
        },
      })
      local notices = capture(t)
      t.eq(true, controller.open_team("members"))
      stub_ui(t, {
        select = function()
          return { label = "Force remove worktree", value = true }
        end,
      })
      focus_row("t1|w1")
      ui():handle_key("D")
      wait(function()
        return #service.team_removals == 1
      end, 5000, "the worktree removal")
      t.eq("t1", service.team_removals[1].team)
      t.eq("w1", service.team_removals[1].participant)
      t.eq(true, service.team_removals[1].force)
      wait(function()
        return joined(notices):find("was kept", 1, true) ~= nil
      end, 5000, "the kept-branch notice")

      -- A worker that has not exited has nothing removable yet.
      focus_row("t1|w2")
      ui():handle_key("D")
      vim.wait(150)
      t.eq(1, #service.team_removals)
      t.match("must have exited", joined(notices))
      ui():close()
    end)

    t.it("shows git's stderr when removing a worktree fails", function()
      local service, dir = start_service(t, "panel-worktree-error", {
        team_remove_error = {
          code = -32066,
          message = "git worktree remove failed",
          data = { stderr = "fatal: not a git repository" },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir, {
        participants = {
          { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          {
            name = "w1",
            state = "exited",
            task = "_",
            queued = 0,
            turns = {},
            worktree = { path = "/tmp/wt/w1", branch = "ade/t1/w1" },
          },
        },
      })
      local notices = capture(t)
      t.eq(true, controller.open_team("members"))
      stub_ui(t, {
        select = function()
          return { label = "Remove worktree", value = false }
        end,
      })
      focus_row("t1|w1")
      ui():handle_key("D")
      wait(function()
        return joined(notices):find("fatal: not a git repository", 1, true) ~= nil
      end, 5000, "git's stderr in the notice")
      ui():close()
    end)

    t.it("closes the team through the panel only after confirmation", function()
      local service, dir = start_service(t, "panel-close")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      yes_confirm(t)
      t.eq(true, controller.open_team("members"))
      stub_ui(t, {
        select = function()
          return { label = "Close the team", value = true }
        end,
      })
      focus_row("team:t1")
      ui():handle_key("x")
      wait(function()
        return #calls_of(service, "team.close") == 1
      end, 5000, "the close")
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team")
      ui():close()
    end)

    t.it("resets the limits from the panel", function()
      local service, dir = start_service(t, "panel-reset")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      t.eq(true, controller.open_team("members"))
      focus_row("team:t1")
      ui():handle_key("R")
      wait(function()
        return #service.team_resets == 1
      end, 5000, "team.reset_limits")
      t.eq("t1", service.team_resets[1].team)
      ui():close()
    end)
  end)
end
