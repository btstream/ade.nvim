-- W0e: front-end configuration, team state and the start commands
-- (PROTOCOL.md section 19).
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local Config = require("ade.config")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")
  local Team = require("ade.app.team")
  local TeamStart = require("ade.app.team_start")
  local Workflows = require("ade.ui.workflows")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-w0e-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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

  local function teams_config(over)
    return vim.tbl_deep_extend("force", {
      spawn_from_chat = true,
      max_workers = 3,
      spawn_confirm = { auto = {} },
      limits = { max_turns_per_task = 30, max_turns_total = 200 },
      templates = {
        worker = { agent = "opencode", role = "You are a worker. Report with bus_send." },
      },
    }, over or {})
  end

  local function setup(t, tag, service, dir, overrides)
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
      teams = teams_config(),
      ui = {},
      layout = { input_height = 6 },
    }, overrides or {}))
    return connection
  end

  local function state()
    return controller.state()
  end

  local function team()
    return state().view.team
  end

  local function wait(cond, timeout, label)
    local ok = vim.wait(timeout or 20000, cond, 20)
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

  ---A completely fake team module for the flow's unit tests.
  local function fake_team(cwd, rows, workflows)
    local fake_ = {
      available = function()
        return true
      end,
      rows = rows or {},
      bound = {},
      works = workflows,
      starts = {},
      closes = {},
      deletes = {},
      new_session_count = 0,
    }
    if not fake_.works then
      fake_.works = {
        {
          name = "dev",
          summary = "two workers",
          text = "1. write 2. review",
          team = { { name = "w1", template = "worker" } },
          columns = { "todo" },
          scope = "project",
        },
        {
          name = "default",
          summary = "the built-in flow",
          text = "1. plan",
          team = {},
          scope = "builtin",
        },
      }
    end
    if #fake_.rows > 0 then
      fake_.bound[cwd] = { instance = "i1", session_id = "s1", team = fake_.rows[1].id }
    end
    function fake_:list_rows()
      return self.rows
    end
    function fake_:workflows(asked_cwd, cb)
      self.asked_cwd = asked_cwd
      if self.workflows_delay then
        self.workflows_cb = cb
        return
      end
      cb(true, { workflows = self.works })
    end
    function fake_:start(team_id, workflow, task, cb)
      self.starts[#self.starts + 1] = { team = team_id, workflow = workflow, task = task }
      cb(true, { workflow = workflow, started = {}, skipped = {} })
    end
    function fake_:close(team_id, cb)
      self.closes[#self.closes + 1] = team_id
      -- Like a service whose reply arrives before `team.changed(closed)`: the
      -- lists still contain the team when the reply is delivered.
      cb(true, {})
    end
    function fake_:forget_team(team_id)
      local left = {}
      for _, entry in ipairs(self.rows) do
        if entry.id ~= team_id then
          left[#left + 1] = entry
        end
      end
      self.rows = left
      for asked, bound in pairs(self.bound) do
        if bound.team == team_id then
          self.bound[asked] = nil
        end
      end
    end
    function fake_:workflow_delete(asked_cwd, name, scope, cb)
      self.deletes[#self.deletes + 1] = { cwd = asked_cwd, name = name, scope = scope }
      local left = {}
      for _, entry in ipairs(self.works) do
        if entry.name ~= name or entry.scope ~= scope then
          left[#left + 1] = entry
        end
      end
      self.works = left
      cb(true, {})
    end
    return fake_
  end

  ---A flow wired to a mutable state table, so `pick_agent` can rebuild the
  ---controller like the real one does (new Team object, no sessions).
  local function fake_flow(cwd, fake, over)
    local holder = {
      view = { team = fake },
      sess = { current = over and over.session or nil },
      config = teams_config(),
    }
    local function current_team()
      return holder.view.team
    end
    local deps = vim.tbl_extend("force", {
      state = function()
        return holder
      end,
      config = function()
        return vim.tbl_deep_extend("force", {
          cwd = cwd,
          agent = "opencode",
          teams = teams_config(),
        }, over and over.config or {})
      end,
      notify = function() end,
      resolve_cwd = function()
        return cwd
      end,
      open = function() end,
      new_session = function()
        local team = current_team()
        team.new_session_count = (team.new_session_count or 0) + 1
        team.rows = {
          { id = "t2", cwd = cwd, state = "active", participants = {} },
        }
        team.bound[cwd] = { instance = "i1", session_id = "s2", team = "t2" }
      end,
      connect = function() end,
      pick_agent = function() end,
      options = function()
        return nil
      end,
      client = function()
        return nil
      end,
      generation = function()
        return 0
      end,
      report_error = function(value)
        return type(value) == "table" and (value.message or value.code) or tostring(value)
      end,
      open_team = function()
        local team = current_team()
        team.opened = (team.opened or 0) + 1
      end,
    }, over and over.deps or {})
    if over and type(over.setup) == "function" then
      over.setup(deps, holder)
    end
    return TeamStart.new(deps), deps, holder
  end

  t.describe("W0e configuration", function()
    t.it("sends workflows, models and the tool style in team.configure", function()
      local cfg = Config.validate(vim.tbl_deep_extend("force", Config.defaults, {
        agents = {
          opencode = { command = "python3" },
          pi = { command = "python3", profile = "pi" },
        },
        teams = teams_config({
          default = "dev",
          templates = {
            worker = { agent = "opencode", role = "plain", models = { "m1", "m2" } },
            reviewer = { agent = "pi" },
          },
          workflows = {
            dev = {
              text = "1. write\n2. review",
              team = { { name = "w1", template = "worker", model = "m1", task = "T1" } },
              columns = { "todo", "review" },
            },
          },
        }),
      }))
      local team_ = Team.new({
        config = function()
          return cfg
        end,
        connection = function()
          return nil
        end,
        resolve_cwd = function()
          return "/tmp/w0e"
        end,
        notify = function() end,
        on_changed = function() end,
      })
      local config = team_:service_config("/tmp/w0e")
      t.eq("dev", config.default_workflow)
      t.eq("1. write\n2. review", config.workflows.dev.text)
      -- The summary is derived from the first text line when the config has
      -- none: the service requires one on the wire (19.1).
      t.eq("1. write", config.workflows.dev.summary)
      t.eq("todo", config.workflows.dev.columns[1])
      t.eq({ "m1", "m2" }, config.templates.worker.models)
      t.eq("plain", config.templates.worker.role)
      t.eq("", config.templates.reviewer.role)
      t.eq("direct", config.templates.worker.tool_style)
      t.eq("mcp_proxy", config.templates.reviewer.tool_style, "pi reaches tools through its mcp proxy")
      t.eq("mcp_proxy", config.templates.reviewer.tool_style)
    end)
  end)

  t.describe("W0e board cache", function()
    t.it("keeps one team.board request in flight and refetches the latest revision", function()
      local service, dir = start_service(t, "board", {
        team_board_delay = 150,
        team_boards = {
          { rev = 1, columns = { "todo" }, cards = {} },
          { rev = 2, columns = { "todo", "doing" }, cards = {} },
        },
      })
      setup(t, "board", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {},
        inbox = {},
        limits = {},
        board_rev = 1,
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      -- Both notifications arrive while the first request is in flight: the
      -- second only sets the latch, so exactly one coalesced refetch follows.
      service:emit_team_board_changed("t1", 2)
      service:emit_team_board_changed("t1", 2)
      wait(function()
        local board = team():board("t1")
        return board ~= nil and board.rev == 2
      end, 5000, "the refetched board")
      t.eq(2, #service.team_board_requests, "one request plus exactly one coalesced refetch")
      -- A later notification fetches again.
      service:emit_team_board_changed("t1", 3)
      wait(function()
        local board = team():board("t1")
        return #service.team_board_requests == 3 and board ~= nil and board.rev == 3
      end, 5000, "the next board change")
    end)
  end)

  t.describe("W0e team state", function()
    t.it("keeps the new team.list fields and forwards the new calls", function()
      local service, dir = start_service(t, "state", {})
      setup(t, "state", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the bound team")
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        board_rev = 4,
        workflow_name = "dev",
        stages = { { stage = "todo", open = 2, archived = 1 } },
        participants = {
          { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
          {
            name = "w1",
            state = "working",
            task = "T1",
            queued = 0,
            turns = {},
            activity = { text = "running tests", at = 1767225600000 },
            state_since = 1767225600001,
          },
        },
        inbox = {},
        limits = {},
      })
      wait(function()
        local entry = team():team("t1")
        return entry ~= nil and entry.board_rev == 4
      end, 5000, "the new team.list fields")
      local worker = team():participant("t1", "w1")
      t.eq("running tests", worker.activity.text)
      t.eq(1767225600001, worker.state_since)
      t.eq("dev", team():team("t1").workflow_name)
      t.eq(2, team():team("t1").stages[1].open)

      local function call(fn)
        local done, ok, value = false, nil, nil
        fn(function(result, result_value)
          done, ok, value = true, result, result_value
        end)
        wait(function()
          return done
        end, 5000, "the team call")
        return ok, value
      end
      call(function(cb)
        team():send("t1", "leader", "notice", "hi", { card = "T1", task = "T2" }, cb)
      end)
      local sent = service.team_sends[#service.team_sends]
      t.eq("T1", sent.card)
      t.eq("T2", sent.task)
      call(function(cb)
        team():answer_group("g1", true, cb)
      end)
      t.eq("g1", service.team_answer_groups[1].group)
      t.eq(true, service.team_answer_groups[1].allow)
      local ok, value = call(function(cb)
        team():card_history("t1", "T1", cb)
      end)
      t.eq(true, ok)
      t.truthy(type(value.versions) == "table")
      ok, value = call(function(cb)
        team():workflows(dir, cb)
      end)
      t.eq(true, ok)
      t.eq("default", value.workflows[1].name)
      t.truthy(vim.tbl_contains(team():known_workflows(), "default"))
      call(function(cb)
        team():workflow_delete(dir, "gone", "user", cb)
      end)
      t.eq("gone", service.team_workflow_deletes[1].name)
      t.eq("user", service.team_workflow_deletes[1].scope)
    end)
  end)

  t.describe("W0e group answers", function()
    t.it("ignore partial failures and hand them to the caller", function()
      local service, dir = start_service(t, "group-partial", {
        team_answer_group_failed = {
          { id = "i2", code = -32061, message = "unknown template" },
        },
      })
      setup(t, "group-partial", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the bound team")
      local done, ok, value = false, nil, nil
      team():answer_group("g1", true, function(result, result_value)
        done, ok, value = true, result, result_value
      end)
      wait(function()
        return done
      end, 5000, "team.answer_group")
      t.eq(true, ok)
      t.eq(1, #value.failed, vim.inspect(value))
      t.eq("i2", value.failed[1].id)
      t.eq(-32061, value.failed[1].code)
      -- A service that omits `failed` still gives the caller an empty list.
      service.team_answer_group_failed = nil
      local plain_done, plain_ok, plain = false, nil, nil
      team():answer_group("g2", false, function(result, result_value)
        plain_done, plain_ok, plain = true, result, result_value
      end)
      wait(function()
        return plain_done
      end, 5000, "the second group answer")
      t.eq(true, plain_ok)
      t.truthy(type(plain.failed) == "table")
      t.eq(0, #plain.failed)
    end)
  end)

  t.describe("W0e start flow", function()
    t.it("picks a workflow and starts it with the task", function()
      local cwd = "/tmp/w0e-flow"
      local fake_ = fake_team(cwd, { { id = "t1", cwd = cwd, state = "active", participants = {} } })
      local flow = fake_flow(cwd, fake_)
      local asked
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(items, opts, cb)
        asked = { kind = "select", prompt = opts and opts.prompt, items = items }
        cb(items[1])
      end
      vim.ui.input = function(opts, cb)
        asked.input = opts.prompt
        cb("do the thing")
      end
      flow:start(nil)
      wait(function()
        return #fake_.starts == 1
      end, 5000, "the workflow start")
      t.eq("/tmp/w0e-flow", fake_.asked_cwd)
      t.eq("dev", fake_.starts[1].workflow)
      t.eq("t1", fake_.starts[1].team)
      t.eq("do the thing", fake_.starts[1].task)
      t.eq(1, fake_.opened, "the panel opens after a successful start")
      t.truthy(asked and asked.kind == "select")
    end)

    t.it("reports an unknown workflow without asking for a task", function()
      local cwd = "/tmp/w0e-unknown"
      local fake_ = fake_team(cwd, { { id = "t1", cwd = cwd, state = "active", participants = {} } })
      local flow, deps = fake_flow(cwd, fake_)
      local notices = {}
      deps.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      flow:start("nope")
      wait(function()
        return #notices > 0
      end, 5000, "the unknown-workflow notice")
      t.match("unknown workflow", notices[1])
      t.eq(0, #fake_.starts)
    end)

    t.it("asks before touching a team that already runs workers", function()
      local cwd = "/tmp/w0e-busy"
      local rows = {
        {
          id = "t1",
          cwd = cwd,
          state = "active",
          participants = {
            { name = "leader", state = "idle" },
            { name = "w1", state = "idle" },
          },
        },
      }
      local fake_ = fake_team(cwd, rows)
      local flow = fake_flow(cwd, fake_)
      local selected
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(items, _, cb)
        selected = items
        cb(items[2]) -- start only the missing members
      end
      vim.ui.input = function(_, cb)
        cb("")
      end
      flow:start("dev")
      wait(function()
        return #fake_.starts == 1
      end, 5000, "the append start")
      t.eq(0, #fake_.closes, "appending does not close the team")
      t.eq(nil, fake_.starts[1].task)
      t.match("close the team", selected[1])
      t.match("missing members", selected[2])
      t.match("cancel", selected[3])

      -- Cancelling starts nothing.
      vim.ui.select = function(_, _, cb)
        cb(selected[3])
      end
      flow:start("dev")
      vim.wait(100)
      t.eq(1, #fake_.starts)
      t.eq(0, #fake_.closes)
    end)

    t.it("closes and recreates the team when the person chooses to start over", function()
      local cwd = "/tmp/w0e-restart"
      local rows = {
        {
          id = "t1",
          cwd = cwd,
          state = "active",
          participants = { { name = "leader", state = "idle" }, { name = "w1", state = "idle" } },
        },
      }
      local fake_ = fake_team(cwd, rows)
      local flow = fake_flow(cwd, fake_)
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(items, _, cb)
        cb(items[1]) -- close and start over
      end
      vim.ui.input = function(_, cb)
        cb("again")
      end
      flow:start("dev")
      wait(function()
        return #fake_.starts == 1
      end, 5000, "the restarted workflow")
      t.eq(1, #fake_.closes, "the old team is closed")
      t.eq("t2", fake_.starts[1].team, "a new team took the workflow")
      t.eq("again", fake_.starts[1].task)
      t.eq(1, fake_.new_session_count)
    end)

    t.it("creates a leader session when there is no team yet", function()
      local cwd = "/tmp/w0e-new"
      local fake_ = fake_team(cwd, {})
      local flow = fake_flow(cwd, fake_)
      local original_input = vim.ui.input
      t.cleanup(function()
        vim.ui.input = original_input
      end)
      vim.ui.input = function(_, cb)
        cb("")
      end
      flow:start("dev")
      wait(function()
        return #fake_.starts == 1
      end, 10000, "the workflow after a new session")
      t.eq(1, fake_.new_session_count)
      t.eq("t2", fake_.starts[1].team)
    end)

    t.it("ignores a leader agent mismatch on request and starts anyway", function()
      local cwd = "/tmp/w0e-agent"
      local fake_ = fake_team(cwd, { { id = "t1", cwd = cwd, state = "active", participants = {} } })
      fake_.works = {
        {
          name = "claude_flow",
          summary = "wants claude",
          text = "1. do",
          leader = { agent = "claude" },
          team = {},
          scope = "project",
        },
      }
      local flow = fake_flow(cwd, fake_)
      local prompts = {}
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(items, opts, cb)
        prompts[#prompts + 1] = (opts and opts.prompt or "") .. "|" .. table.concat(items, ",")
        cb(items[2]) -- ignore and use the current leader
      end
      vim.ui.input = function(_, cb)
        cb("")
      end
      flow:start("claude_flow")
      wait(function()
        return #fake_.starts == 1
      end, 5000, "the ignored mismatch")
      t.match("wants a claude leader", prompts[1])
      t.match("ignore it", prompts[1])
      t.eq(0, #fake_.closes)
    end)

    t.it("switches the leader agent when the workflow asks for one and the person agrees", function()
      local cwd = "/tmp/w0e-switch"
      local fake_ = fake_team(
        cwd,
        { { id = "t1", cwd = cwd, state = "active", participants = { { name = "w1", state = "idle" } } } }
      )
      fake_.works = {
        {
          name = "claude_flow",
          summary = "wants claude",
          text = "1. do",
          leader = { agent = "claude", model = "mock-2" },
          team = {},
          scope = "project",
        },
      }
      local fresh = fake_team(cwd, {})
      fresh.works = fake_.works
      local switched
      local flow, deps = fake_flow(cwd, fake_, {
        session = { id = "s0" },
        setup = function(d, holder)
          d.pick_agent = function(name)
            switched = name
            -- The real pick_agent reruns setup(): a new Team object, no
            -- binding, and a fresh session with its own controls.
            holder.view.team = fresh
            holder.sess.current = {
              id = "s1",
              controls = {
                model = { id = "model", options = { { value = "mock-1" }, { value = "mock-2" } } },
              },
            }
          end
        end,
      })
      local applied
      deps.options = function()
        return {
          apply = function(_, control, value)
            applied = { control = control.id, value = value }
          end,
        }
      end
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      local prompts = 0
      vim.ui.select = function(items, _, cb)
        prompts = prompts + 1
        if prompts == 1 then
          cb(items[1]) -- open a claude leader
        else
          cb(nil)
        end
      end
      vim.ui.input = function(_, cb)
        cb("")
      end
      flow:start("claude_flow")
      wait(function()
        return #fresh.starts == 1
      end, 5000, "the switched workflow")
      t.eq("claude", switched)
      t.eq(1, prompts, "switching never asks about the old team's workers")
      t.eq(1, #fake_.closes, "the old team is closed exactly once")
      t.eq(0, #fake_.starts, "nothing starts on the old team")
      t.eq(0, fake_.new_session_count or 0, "no session is created before the switch")
      t.eq(1, fresh.new_session_count, "one new session for the new leader")
      t.eq("t2", fresh.starts[1].team)
      t.truthy(applied and applied.control == "model" and applied.value == "mock-2")
    end)

    t.it("only switches a leader model the agent offers", function()
      local cwd = "/tmp/w0e-model"
      local fake_ = fake_team(cwd, { { id = "t1", cwd = cwd, state = "active", participants = {} } })
      fake_.works = {
        { name = "solo", summary = "solo", text = "x", leader = { model = "nope" }, team = {}, scope = "project" },
      }
      local applied = 0
      local flow, deps = fake_flow(cwd, fake_)
      local notices = {}
      deps.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      deps.options = function()
        return {
          apply = function()
            applied = applied + 1
          end,
        }
      end
      deps.state = function()
        return {
          view = { team = fake_ },
          sess = {
            current = {
              id = "s1",
              controls = { model = { id = "model", options = { { value = "mock-1" } } } },
            },
          },
          config = teams_config(),
        }
      end
      local original_input = vim.ui.input
      t.cleanup(function()
        vim.ui.input = original_input
      end)
      vim.ui.input = function(_, cb)
        cb("")
      end
      flow:start("solo")
      wait(function()
        return #fake_.starts == 1
      end, 5000, "the workflow with an unknown model")
      t.eq(0, applied, "an unoffered model is never applied")
      local joined = table.concat(notices, "\n")
      t.match("does not offer", joined)
    end)
  end)

  t.describe("W0e commands", function()
    t.it("starts the named workflow through the service and opens the panel", function()
      local service, dir = start_service(t, "command-start", {
        team_workflows = {
          {
            name = "dev",
            summary = "two workers",
            text = "1. write 2. review",
            team = { { name = "w1", template = "worker" } },
            columns = { "todo" },
            scope = "project",
          },
        },
        team_start_result = { workflow = "dev", started = { "w1" }, skipped = {} },
      })
      setup(t, "command-start", service, dir)
      local original_input = vim.ui.input
      t.cleanup(function()
        vim.ui.input = original_input
      end)
      vim.ui.input = function(_, cb)
        cb("ship it")
      end
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the bound team")
      controller.start_team("dev")
      wait(function()
        return #service.team_starts == 1
      end, 10000, "team.start")
      t.eq("t1", service.team_starts[1].team)
      t.eq("dev", service.team_starts[1].workflow)
      t.eq("ship it", service.team_starts[1].task)
      wait(function()
        local ui = state().view.team_ui
        return ui ~= nil and ui:is_open()
      end, 5000, "the panel opened after the start")
      state().view.team_ui:close()
    end)

    t.it("closes the team of this cwd only after the person confirms", function()
      local service, dir = start_service(t, "command-close", {})
      setup(t, "command-close", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the bound team")
      local original_select = vim.ui.select
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      local prompt
      vim.ui.select = function(items, opts, cb)
        prompt = opts and opts.prompt or ""
        cb(items[#items]) -- No
      end
      vim.cmd("Ade team close")
      vim.wait(100)
      t.eq(0, #calls_of(service, "team.close"))
      t.match("t1", prompt)
      t.match("command%-close", prompt)
      -- A team of another cwd is never closed by this command.
      local notices = capture(t)
      service:team_changed({
        id = "t9",
        cwd = "/somewhere/else",
        state = "active",
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t9") ~= nil
      end, 5000, "the foreign team")
      team():team("t1").cwd = "/other/dir"
      vim.ui.select = function(items, _, cb)
        cb(items[1]) -- Yes
      end
      vim.cmd("Ade team close")
      vim.wait(100)
      t.eq(0, #calls_of(service, "team.close"), "a foreign team is not closed")
      local joined = table.concat(
        vim.tbl_map(function(note)
          return note.message
        end, notices),
        "\n"
      )
      t.match("no team to close for this cwd", joined)
      team():team("t1").cwd = dir

      vim.cmd("Ade team close")
      wait(function()
        return #calls_of(service, "team.close") == 1
      end, 5000, "team.close")
    end)

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
      setup(t, "command-workflows", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the bound team")
      vim.cmd("Ade workflows")
      local ui = state().view.team_commands.workflows_ui
      wait(function()
        return ui and ui:is_open()
      end, 5000, "the workflows window")
      local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
      t.match("default", text)
      t.match("builtin", text)
      -- <CR> shows the flow text of the workflow under the cursor, without
      -- the double spacing `gmatch` used to produce.
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
      local joined = table.concat(
        vim.tbl_map(function(note)
          return note.message
        end, notices),
        "\n"
      )
      t.match("cannot be deleted", joined)
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
  end)

  t.describe("W0e review regressions", function()
    t.it("never switches the agent after the person chose to ignore it", function()
      local cwd = "/tmp/w0e-ignore"
      -- The team exists but this front end is not its leader (a suspended or
      -- foreign team): no binding here.
      local fake_ = fake_team(cwd, { { id = "t1", cwd = cwd, state = "active", participants = {} } })
      fake_.bound = {}
      fake_.works = {
        {
          name = "claude_flow",
          summary = "wants claude",
          text = "1. do",
          leader = { agent = "claude" },
          team = {},
          scope = "project",
        },
      }
      local switched
      local notices = {}
      local flow, deps = fake_flow(cwd, fake_, {
        setup = function(d)
          d.pick_agent = function(name)
            switched = name
          end
          d.notify = function(message)
            notices[#notices + 1] = tostring(message)
          end
        end,
      })
      local original_select, original_input = vim.ui.select, vim.ui.input
      t.cleanup(function()
        vim.ui.select, vim.ui.input = original_select, original_input
      end)
      vim.ui.select = function(items, _, cb)
        cb(items[2]) -- ignore and use the current leader
      end
      vim.ui.input = function(_, cb)
        cb("")
      end
      flow:start("claude_flow")
      wait(function()
        return #notices > 0
      end, 5000, "the unbound-team notice")
      t.eq(nil, switched, "ignoring the mismatch must not switch the agent")
      t.eq(0, #fake_.starts)
      t.eq(0, #fake_.closes)
      t.eq(0, fake_.new_session_count)
      t.match("not the leader", table.concat(notices, "\n"))
      _ = deps
    end)

    t.it("cancels a stuck flow so a later start can run", function()
      local cwd = "/tmp/w0e-cancel"
      local fake_ = fake_team(cwd, { { id = "t1", cwd = cwd, state = "active", participants = {} } })
      fake_.workflows_delay = true
      local flow = fake_flow(cwd, fake_)
      local original_input = vim.ui.input
      t.cleanup(function()
        vim.ui.input = original_input
      end)
      vim.ui.input = function(_, cb)
        cb("")
      end
      flow:start("dev")
      t.eq(true, TeamStart.active(cwd))
      flow:cancel()
      t.eq(false, TeamStart.active(cwd))
      fake_.workflows_delay = nil
      flow:start("dev")
      wait(function()
        return #fake_.starts == 1
      end, 5000, "the start after a cancel")
    end)

    t.it("suppresses the enabled auto start while a start flow runs", function()
      local cwd = "/tmp/w0e-auto-suppress"
      local starts = 0
      local team = Team.new({
        config = function()
          return {
            agent = "opencode",
            cwd = cwd,
            teams = teams_config({ enabled = true, default = "dev" }),
          }
        end,
        connection = function()
          return nil
        end,
        resolve_cwd = function()
          return cwd
        end,
        notify = function() end,
        on_changed = function() end,
      })
      team.teams["t1"] = { id = "t1", cwd = cwd, state = "active", participants = {} }
      team.start = function(_, team_id, workflow)
        starts = starts + 1
        team._last = { team_id = team_id, workflow = workflow }
      end
      local fake_ = fake_team(cwd, {})
      fake_.workflows_delay = true
      local flow = fake_flow(cwd, fake_)
      local original_input = vim.ui.input
      t.cleanup(function()
        vim.ui.input = original_input
      end)
      vim.ui.input = function(_, cb)
        cb("")
      end
      flow:start("dev")
      team:start_enabled_workers("t1", team.teams["t1"])
      t.eq(0, starts, "the flow owns this cwd")
      flow:cancel()
      team:start_enabled_workers("t1", team.teams["t1"])
      t.eq(1, starts, "the enabled workflow starts once the flow is done")
      t.eq("dev", team._last.workflow)
      team:start_enabled_workers("t1", team.teams["t1"])
      t.eq(1, starts, "still only once per team")
    end)

    t.it("ignores a board reply that arrives after the team closed", function()
      local service, dir = start_service(t, "board-late-close", { team_board_delay = 200 })
      setup(t, "board-late-close", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      team():request_board("t1")
      service:team_changed({ id = "t1", cwd = dir, state = "closed", participants = {}, inbox = {}, limits = {} })
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
      setup(t, "board-stale", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      team():request_board("t1")
      team():forget_connection()
      vim.wait(400)
      t.eq(nil, team():board("t1"), "the stale reply is ignored")
      local entry = team().boards["t1"]
      t.eq(false, entry and entry.inflight or false, "the latch is clear")
      t.eq(false, entry and entry.again or false)
    end)

    t.it("fetches a board named by team.changed without a board_changed", function()
      local service, dir = start_service(t, "board-sync", {
        team_board = { rev = 3, columns = { "todo" }, cards = {} },
      })
      setup(t, "board-sync", service, dir)
      controller.connect()
      wait_ready()
      service:team_changed({
        id = "t1",
        cwd = dir,
        state = "active",
        participants = {},
        inbox = {},
        limits = {},
        board_rev = 3,
      })
      wait(function()
        local board = team():board("t1")
        return board ~= nil and board.rev == 3
      end, 5000, "the board from team.changed")
      t.eq(1, #service.team_board_requests)
    end)

    t.it("validates the leader fields and omits an empty leader", function()
      local function validate(over)
        return Config.validate(vim.tbl_deep_extend("force", Config.defaults, over or {}))
      end
      t.raises(function()
        validate({
          teams = teams_config({
            workflows = {
              dev = { summary = "x", leader = { agent = "not-an-agent" } },
            },
          }),
        })
      end)
      t.raises(function()
        validate({
          teams = teams_config({
            workflows = {
              dev = { summary = "x", leader = { role = string.rep("r", 4 * 1024 + 1) } },
            },
          }),
        })
      end)
      local cfg = validate({
        teams = teams_config({
          workflows = {
            dev = { summary = "x", leader = { agent = "claude", role = string.rep("r", 4 * 1024) } },
            empty = { summary = "y", leader = {} },
          },
        }),
      })
      t.eq(4 * 1024, #cfg.teams.workflows.dev.leader.role)
      local team_ = Team.new({
        config = function()
          return cfg
        end,
        connection = function()
          return nil
        end,
        resolve_cwd = function()
          return "/tmp/w0e-leader"
        end,
        notify = function() end,
        on_changed = function() end,
      })
      local service_config = team_:service_config("/tmp/w0e-leader")
      t.eq("claude", service_config.workflows.dev.leader.agent)
      t.eq(nil, service_config.workflows.empty.leader, "an empty leader is omitted, not encoded as []")
    end)

    t.it("does not reopen the workflows window when a delete reply arrives late", function()
      local service, dir = start_service(t, "workflows-late", {
        team_workflows = {
          { name = "review", summary = "by pi", text = "x", team = {}, scope = "project" },
        },
        team_workflow_delete_delay = 150,
      })
      setup(t, "workflows-late", service, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the bound team")
      vim.cmd("Ade workflows")
      local ui = state().view.team_commands.workflows_ui
      wait(function()
        return ui and ui:is_open()
      end, 5000, "the workflows window")
      local original_select = vim.ui.select
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      vim.ui.select = function(items, _, cb)
        cb(items[1]) -- Yes
      end
      vim.api.nvim_win_set_cursor(ui.win, { 3, 0 })
      ui:delete_current()
      ui:close()
      wait(function()
        return #service.team_workflow_deletes == 1
      end, 5000, "the late delete")
      vim.wait(200)
      t.eq(false, ui:is_open(), "a late reply must not reopen the window")
    end)
  end)

  t.describe("W0e old service", function()
    t.it("explains an api-5 service instead of showing raw -32601", function()
      local service, dir = start_service(t, "old-service", {
        old_service_methods = {
          ["team.board"] = true,
          ["team.card_history"] = true,
          ["team.start"] = true,
          ["team.workflows"] = true,
          ["team.workflow_delete"] = true,
          ["team.answer_group"] = true,
        },
      })
      setup(t, "old-service", service, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the bound team")
      -- hello's workflow cache warm-up already noticed the old service.
      wait(function()
        return team().old_service == true
      end, 5000, "the old-service flag")
      local function warnings()
        local n = 0
        for _, note in ipairs(notices) do
          if note.message:find("too old", 1, true) then
            n = n + 1
          end
        end
        return n
      end
      t.eq(1, warnings(), "the version hint is shown once")

      local function call(fn)
        local done, ok, value = false, nil, nil
        fn(function(result, result_value)
          done, ok, value = true, result, result_value
        end)
        wait(function()
          return done
        end, 5000, "the old-service call")
        return ok, value
      end
      local ok, value = call(function(cb)
        team():workflows(dir, cb)
      end)
      t.eq(false, ok)
      t.match("too old", value.message)
      t.match(":Ade service stop", value.message)
      t.eq(1, warnings(), "still one hint")
      ok, value = call(function(cb)
        team():start("t1", "dev", nil, cb)
      end)
      t.eq(false, ok)
      t.match("too old", value.message)

      -- The board cache does not retry a method the service does not have.
      team():request_board("t1")
      vim.wait(150)
      service:emit_team_board_changed("t1", 2)
      vim.wait(200)
      t.eq(0, #service.team_board_requests, "no board request against an api-5 service")
    end)
  end)

  t.describe("W0e completion", function()
    t.it("completes the team subcommands and workflow names", function()
      local complete = vim.fn.getcompletion("Ade team ", "cmdline")
      t.truthy(vim.tbl_contains(complete, "start"), vim.inspect(complete))
      t.truthy(vim.tbl_contains(complete, "close"), vim.inspect(complete))
      local names = vim.fn.getcompletion("Ade team start ", "cmdline")
      t.truthy(vim.tbl_contains(names, "default"), vim.inspect(names))
    end)
  end)
end
