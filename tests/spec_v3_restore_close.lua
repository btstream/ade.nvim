-- Restored teams v3 coverage: the close/command races and the structured errors
-- the panel must report (PROTOCOL.md 19.7, 20.4, 20.6).
--
-- Ported from `feat/teams-v3:tests/spec_w0e_team.lua` ("closes the team of this
-- cwd only after the person confirms", "cancels a running start only after the
-- close is confirmed") and the review's remaining gaps: closing then reopening
-- in the same session, a tree query that fails without poisoning the cache, and
-- `team.spawn`'s structured error / dirty-tree warning.
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")
  local TeamStart = require("ade.app.team_start")
  local presenter = require("ade.app.presenter")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-v3close-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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

  local function own_instance()
    local client = state().conn.client
    return client and client.proc and client.proc.instance or nil
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

  local function stub_select(t, answer)
    local original = vim.ui.select
    local prompts = {}
    vim.ui.select = function(items, opts, cb)
      prompts[#prompts + 1] = opts and opts.prompt or ""
      if type(answer) == "function" then
        cb(answer(items))
        return
      end
      cb(answer)
    end
    t.cleanup(function()
      vim.ui.select = original
    end)
    return prompts
  end

  t.describe("teams v3 close and commands", function()
    t.it("`:Ade team close` refuses a foreign team and closes only this cwd's", function()
      local service, dir = start_service(t, "close-cwd")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local other = {
        id = "t9",
        cwd = "/somewhere/else",
        state = "active",
        participants = {},
        inbox = {},
        limits = {},
      }
      service.teams.t9 = vim.deepcopy(other)
      service:team_changed(other)
      wait(function()
        return team():team("t9") ~= nil
      end, 5000, "the foreign team")
      local notices = capture(t)
      local prompts = stub_select(t, function(items)
        return items[#items]
      end)
      -- A refused confirmation must close nothing.
      vim.cmd("Ade team close")
      vim.wait(150)
      t.eq(0, #calls_of(service, "team.close"))
      t.match("t1", prompts[#prompts])
      t.truthy(prompts[#prompts]:find(dir, 1, true), prompts[#prompts])

      -- The team list carries two teams; the command still closes only the
      -- current cwd's, never the other project's.
      local all = stub_select(t, function(items)
        return items[1]
      end)
      vim.cmd("Ade team close")
      wait(function()
        return #calls_of(service, "team.close") == 1
      end, 5000, "the close")
      t.eq("t1", calls_of(service, "team.close")[1].params.team)
      t.match("t1", all[#all])
      t.truthy(team():team("t9") ~= nil, "the foreign team is untouched")
      t.falsy(joined(notices):find("no team to close for this cwd", 1, true))
    end)

    t.it("a refused close leaves a running start alone; a confirmed one cancels it", function()
      local service, dir = start_service(t, "close-cancels-start", {
        team_workflows = {
          { name = "dev", summary = "two workers", text = "1. do", team = {}, scope = "project" },
        },
        team_workflows_delay = 400,
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      stub_select(t, function(items)
        return items[#items] -- No
      end)
      vim.cmd("Ade team start dev")
      vim.wait(100)
      t.eq(true, TeamStart.active(dir), "the start is waiting for the workflow list")
      vim.cmd("Ade team close")
      vim.wait(100)
      t.eq(true, TeamStart.active(dir), "a refused close leaves the start alone")
      t.eq(0, #calls_of(service, "team.close"))
      stub_select(t, function(items)
        return items[1] -- Yes
      end)
      vim.cmd("Ade team close")
      wait(function()
        return #calls_of(service, "team.close") == 1
      end, 5000, "the confirmed close")
      wait(function()
        return TeamStart.active(dir) == false
      end, 5000, "the close to cancel the start")
      t.eq(0, #calls_of(service, "team.start"), "a cancelled start never reaches the service")
    end)

    t.it("the same session can start a new team after closing the old one", function()
      local service, dir = start_service(t, "close-reopen")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local instance = own_instance()
      local done = false
      local before_close_seq = service.team_seq or 0
      team():close("t1", function()
        done = true
      end)
      wait(function()
        return done
      end, 5000, "team.close")
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the closed team to leave the cache")
      -- A real service never reuses an id; the stand-in shares its counter.
      service.team_seq = before_close_seq + 1
      local started
      team():start_session(instance, "sess_mock", "default", nil, function(ok, value)
        started = { ok = ok, value = value }
      end)
      wait(function()
        return started ~= nil
      end, 5000, "team.start")
      t.eq(true, started.ok, "the session may lead again")
      t.eq(1, #calls_of(service, "team.start"))
      wait(function()
        return team():team_for_cwd(dir) ~= nil
      end, 5000, "the new team")
      t.truthy(team():team_for_cwd(dir).id ~= "t1", "a new team replaces the closed one")
    end)

    t.it("a failed team.answer_group surfaces the service error", function()
      local service, dir = start_service(t, "group-failed", {
        team_answer_group_error = { code = -32064, message = "unknown group" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local done, ok, value = false, nil, nil
      team():answer_group("g1", true, function(result, err)
        done, ok, value = true, result, err
      end)
      wait(function()
        return done
      end, 5000, "team.answer_group")
      t.eq(false, ok)
      t.eq(-32064, value.code)
      t.match("unknown group", tostring(value.message))
    end)

    t.it("`team.spawn` reports a structured error and a dirty-tree warning", function()
      local service, dir = start_service(t, "spawn-errors")
      setup(t, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      -- A structured refusal keeps its `data.reason` for the caller.
      service.team_spawn_error = {
        code = -32061,
        message = "this chat does not lead the team",
        data = { reason = "no_tools" },
      }
      local done, ok, value = false, nil, nil
      team():spawn("t1", "worker", "w2", "T1", function(result, err)
        done, ok, value = true, result, err
      end)
      wait(function()
        return done
      end, 5000, "the refused spawn")
      t.eq(false, ok)
      t.eq("no_tools", value.data.reason, "the structured reason reaches the caller")

      -- A successful spawn of a dirty tree warns about the last commit.
      service.team_spawn_error = nil
      service.team_spawn_warning = "dirty_tree"
      service.team_participants = { { name = "leader", state = "idle" } }
      local spawned
      team():spawn("t1", "worker", "w3", nil, function(result, result_value)
        spawned = { ok = result, value = result_value }
      end)
      wait(function()
        return spawned ~= nil
      end, 5000, "the dirty-tree spawn")
      t.eq(true, spawned.ok)
      t.match("last commit", joined(notices))
      t.match("w3", joined(notices))
    end)

    t.it("a failed tree query shows a notice and does not poison the cache", function()
      local service, dir = start_service(t, "tree-query-fail")
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the initial switch")
      local UI = state().view.team_ui
      local notices = {}
      UI.notify_fn = function(message)
        notices[#notices + 1] = tostring(message)
      end
      local real_query = team().query_session_teams
      local failures = 1
      team().query_session_teams = function(self, instance, session_id, cwd, cb)
        if failures > 0 then
          failures = failures - 1
          cb(false, { code = -32001, message = "connection lost" })
          return
        end
        return real_query(self, instance, session_id, cwd, cb)
      end
      t.cleanup(function()
        team().query_session_teams = real_query
      end)
      local meta = {
        kind = "tree_session",
        session = { id = "sess_mock", cwd = dir, instance = own_instance() },
        cwd = dir,
        instance = own_instance(),
        online = true,
        switch = nil,
      }
      local function writes()
        local n = 0
        for _, call in ipairs(calls_of(service, "session.teams")) do
          if call.params.enabled ~= nil then
            n = n + 1
          end
        end
        return n
      end
      local before = writes()
      t.eq(true, UI:handle_tree_key("t", meta))
      t.match("cannot read the teams switch", table.concat(notices, "\n"))
      vim.wait(100)
      t.eq(before, writes(), "a failed read sends no blind write")

      -- The failed read did not cache a wrong answer: the next `t` queries
      -- again and acts on the real state (teams are on, so it turns them off).
      t.eq(true, UI:handle_tree_key("t", meta))
      local off = false
      wait(function()
        for _, call in ipairs(calls_of(service, "session.teams")) do
          if call.params.enabled == false then
            off = true
          end
        end
        return off
      end, 5000, "the retried query to turn the switch off")
    end)
  end)
end
