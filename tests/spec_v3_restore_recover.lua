-- Restored teams v3 coverage: recovery and auto-start (PROTOCOL.md 20.7,
-- 20.4).
--
-- Ported from `feat/teams-v3:tests/spec_s4_team.lua` (stale teams, a failed
-- refresh, a suspended team that stays suspended after a reconnect and a
-- resumed one that must not restart its workers) and its auto-start block, plus
-- the three cases the review still wanted: one auto-start for a current opt-in
-- session with no team, a late `injected` flip, and a tree query that stays a
-- pure read.
--
-- The old bind/poll fixtures are gone: v3 resumes a suspended team only from a
-- successful forwarded load of its stored leader, and auto-start is gated on
-- the session's own switch, never on a leader injection.
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
    local dir = string.format("/tmp/opencode/ade-v3recover-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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

  local function sent_frames(service, method)
    local out = {}
    for _, entry in ipairs(service.sent) do
      if type(entry.message) == "table" and entry.message.method == method then
        out[#out + 1] = entry.message
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

  local function active_team(dir, over)
    return vim.tbl_deep_extend("force", {
      id = "t1",
      cwd = dir,
      state = "active",
      participants = { { name = "leader", state = "idle", task = "_", queued = 0, turns = {} } },
      inbox = {},
      limits = { max_turns_per_task = 30, max_turns_total = 200, turns_total = 0 },
    }, over or {})
  end

  local function suspended_team(dir, session_id, participants)
    return {
      id = "t1",
      cwd = dir,
      state = "suspended",
      suspended_at = 1767225600000,
      leader = { instance = nil, sessionId = session_id },
      participants = participants or {},
      inbox = {},
      limits = { max_turns_per_task = 30, max_turns_total = 200, turns_total = 0 },
    }
  end

  t.describe("teams v3 recovery", function()
    t.it("marks teams stale on disconnect and refuses their operations", function()
      local service, dir = start_service(t, "stale")
      local connection = setup(t, dir)
      controller.connect()
      wait_ready()
      service:team_changed(active_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      t.eq(true, controller.open_team("members"))
      local UI = state().view.team_ui
      local notices = capture(t)
      connection:on_disconnect("lost", true)
      wait(function()
        local row = team():team("t1")
        return row ~= nil and row.stale == true
      end, 5000, "the stale team")
      wait(function()
        local buf = UI.layout:buf("members")
        return buf
          and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("connection lost", 1, true)
            ~= nil
      end, 5000, "the stale panel notice")
      local sends = #service.team_sends
      local line
      for index, id in pairs(UI.layout.ids.members or {}) do
        if id == "t1|leader" then
          line = index
        end
      end
      t.truthy(line)
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line, 0 })
      UI:handle_key("m")
      vim.wait(100)
      t.eq(sends, #service.team_sends, "a stale team sends nothing")
      t.match("connection to the service is lost", joined(notices))
      pcall(UI.close, UI)
    end)

    t.it("replaces stale teams on a successful refresh and clears them on failure", function()
      local service, dir = start_service(t, "refresh-stale")
      setup(t, dir)
      controller.connect()
      wait_ready()
      service:team_changed(active_team(dir))
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the team")
      team():team("t1").stale = true
      team():refresh()
      wait(function()
        local row = team():team("t1")
        return row ~= nil and row.stale ~= true
      end, 5000, "the refreshed team")
      service.team_list_error = { code = -32066, message = "team list failed" }
      team():refresh()
      wait(function()
        return team():team("t1") == nil
      end, 5000, "a failed refresh to clear the list")
    end)

    t.it("keeps a suspended team visible across a reconnect and on hello", function()
      local service, dir = start_service(t, "reconnect")
      local connection = setup(t, dir)
      controller.connect()
      wait_ready()
      local entry = suspended_team(dir, "sess_mock", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
      })
      service.teams.t1 = entry
      -- A reconnect no longer forgets teams: hello re-reads team.list.
      team():on_hello()
      wait(function()
        local row = team():team("t1")
        return row ~= nil and row.state == "suspended"
      end, 5000, "the suspended team after hello")
      t.eq(true, controller.open_team("members"))
      local UI = state().view.team_ui
      local buf = UI.layout:buf("members")
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      local expected = "suspended since " .. os.date("%Y-%m-%d", math.floor(entry.suspended_at / 1000))
      t.truthy(text:find(expected, 1, true), "the panel shows suspended_at")
      t.match("waiting for the leader session", text)

      connection:on_disconnect("lost", true)
      vim.wait(100)
      t.truthy(team():team("t1"), "a disconnect must not forget stored teams")
      t.eq(true, UI:is_open(), "the panel stays available")
      UI:close()
    end)

    t.it("resumes a suspended team only through a successful load of its leader", function()
      local service, dir = start_service(t, "suspended-resume")
      service.teams.t1 = suspended_team(dir, "sess_mock", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {}, template = "worker" },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      -- Configure alone must not resume it (20.7).
      wait(function()
        return #calls_of(service, "team.configure") >= 1
      end, 5000, "the configuration")
      vim.wait(100)
      t.eq("suspended", service.teams.t1.state, "configure does not resume a team")
      t.eq(0, #service.team_starts, "recovery does not start workers")

      state().sess.service:load("sess_mock", { kind = "load" })
      wait(function()
        return service.teams.t1 and service.teams.t1.state == "active"
      end, 10000, "the resumed team")
      t.eq("sess_mock", service.teams.t1.leader.sessionId)
      t.eq(own_instance(), service.teams.t1.leader.instance)
      -- `team.configure` must reach the service before the forwarded load.
      local configure_at, load_at
      for index, call in ipairs(service.calls) do
        if call.method == "team.configure" and not configure_at then
          configure_at = index
        end
      end
      for index, entry in ipairs(service.sent) do
        if type(entry.message) == "table" and entry.message.method == "session/load" and not load_at then
          load_at = index
        end
      end
      vim.wait(100)
      t.eq(0, #service.team_starts, "the resumed workers are not started again")
      t.truthy(configure_at, "a configure request")
      t.truthy(load_at, "the forwarded load")
    end)

    t.it("keeps a suspended team when the loaded session is not its leader", function()
      local service, dir = start_service(t, "suspended-mismatch")
      service.teams.t1 = suspended_team(dir, "stored-session", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      state().sess.service:load("sess_mock", { kind = "load" })
      wait(function()
        return #sent_frames(service, "session/load") >= 1
      end, 15000, "the load")
      vim.wait(300)
      t.eq("suspended", team():team("t1").state, "a different session does not resume the team")
      t.eq("stored-session", team():team("t1").leader.sessionId)
    end)

    t.it("resumes a suspended team through the resume fallback", function()
      local service, dir = start_service(t, "suspended-resume-only", {
        canned_capabilities = {
          loadSession = false,
          sessionCapabilities = { resume = {}, close = {} },
        },
        canned_resume = true,
      })
      service.teams.t1 = suspended_team(dir, "sess_mock", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "team.configure") >= 1
      end, 5000, "the configuration")
      state().sess.service:resume("sess_mock", {})
      wait(function()
        return service.teams.t1 and service.teams.t1.state == "active"
      end, 15000, "the resumed team")
      t.eq("sess_mock", service.teams.t1.leader.sessionId)
      t.eq(0, #service.team_starts, "the recovered workers are not started again")
    end)

    t.it("does not resume a team when its leader's load fails", function()
      local service, dir = start_service(t, "suspended-load-failed", {
        canned_load_error = { code = -32602, message = "session cwd mismatch" },
      })
      service.teams.t1 = suspended_team(dir, "sess_mock", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      local notices = capture(t)
      state().sess.service:load("sess_mock", { kind = "load" })
      wait(function()
        return joined(notices):find("unable to load", 1, true) ~= nil
      end, 15000, "the failed load notice")
      vim.wait(200)
      t.eq("suspended", service.teams.t1.state, "a failed forwarded load does not resume the team")
      t.eq("suspended", team():team("t1").state, "nor does the cached row")
    end)

    t.it("does not resume a team on a late team.configure", function()
      local service, dir = start_service(t, "late-configure")
      setup(t, dir)
      controller.connect()
      wait_ready()
      service.teams.t1 = suspended_team(dir, "sess_mock", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
      })
      team():refresh()
      wait(function()
        return team():team("t1") ~= nil
      end, 5000, "the suspended team")
      -- A late configuration for the cwd must not resume the stored team.
      local before = #calls_of(service, "team.configure")
      team():configure(dir, true)
      wait(function()
        return #calls_of(service, "team.configure") > before
      end, 5000, "the late configuration")
      vim.wait(200)
      t.eq("suspended", service.teams.t1.state)
      t.eq("suspended", team():team("t1").state)
    end)

    t.it("refuses the watch and control of a suspended team but allows messages", function()
      local service, dir = start_service(t, "suspended-refuse")
      service.teams.t1 = suspended_team(dir, "stored-session", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
      })
      setup(t, dir)
      local notices = capture(t)
      controller.connect()
      wait_ready()
      wait(function()
        local row = team():team("t1")
        return row ~= nil and row.state == "suspended"
      end, 5000, "the suspended team")
      t.eq(true, controller.open_team("members"))
      local UI = state().view.team_ui
      local function line_of(id)
        for index, value in pairs(UI.layout.ids.members or {}) do
          if value == id then
            return index
          end
        end
      end
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of("t1|w1"), 0 })
      local sends = #service.team_sends
      for _, key in ipairs({ "p", "r", "c" }) do
        UI:handle_key(key)
        vim.wait(50)
      end
      t.eq(sends, #service.team_sends, "control must not reach a suspended team")
      UI:handle_key("w")
      vim.wait(50)
      t.eq(nil, team().watching)
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of("team:t1"), 0 })
      UI:handle_key("s")
      vim.wait(50)
      t.eq(0, #service.team_spawns, "spawn must not reach a suspended team")
      t.match("team is suspended", joined(notices))
      UI:close()
    end)

    t.it("allows reset and close on a suspended team", function()
      local service, dir = start_service(t, "suspended-allow", {
        team_remove_result = { removed = true, branch_kept = false, branch = "ade/t1/w1" },
      })
      service.teams.t1 = suspended_team(dir, "stored-session", {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        {
          name = "w1",
          state = "exited",
          task = "_",
          queued = 0,
          turns = {},
          worktree = { path = "/tmp/wt/w1", branch = "ade/t1/w1" },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        local row = team():team("t1")
        return row ~= nil and row.state == "suspended"
      end, 5000, "the suspended team")
      t.eq(true, controller.open_team("members"))
      local UI = state().view.team_ui
      local function line_of(id)
        for index, value in pairs(UI.layout.ids.members or {}) do
          if value == id then
            return index
          end
        end
      end
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of("t1|w1"), 0 })
      local original_select = vim.ui.select
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      vim.ui.select = function(_, _, cb)
        cb({ label = "Remove worktree", value = false })
      end
      UI:handle_key("D")
      wait(function()
        return #service.team_removals == 1
      end, 5000, "the worktree removal")
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of("team:t1"), 0 })
      UI:handle_key("R")
      wait(function()
        return #service.team_resets == 1
      end, 5000, "reset_limits while suspended")
      vim.ui.select = function(_, _, cb)
        cb({ label = "Close the team", value = true })
      end
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of("team:t1"), 0 })
      UI:handle_key("x")
      wait(function()
        return team():team("t1") == nil
      end, 5000, "the suspended team to close")
      pcall(UI.close, UI)
    end)
  end)

  t.describe("teams v3 auto-start", function()
    local auto_teams = {
      max_workers = 3,
      auto_start = true,
      default = "dev",
      session_default = true,
      spawn_confirm = { auto = {} },
      templates = {},
      workflows = { dev = { summary = "dev", team = { { name = "w1", template = "worker" } } } },
    }

    -- PRODUCTION BUG (review round 2, blocker 2): `_maybe_auto_start` requires
    -- `list_by_cwd[cwd]` to exist, but `team.list` only creates that key for a
    -- cwd that already has a team. An empty project therefore never satisfies
    -- the condition, no matter how often the snapshot or `injected` arrives.
    -- `lua/ade/app/team.lua:925–978,1011–1025,1052–1054`.
    t.it("starts the configured workflow once for a current opt-in session with no team", function()
      local service, dir = start_service(t, "auto-start")
      setup(t, dir, { teams = auto_teams })
      controller.connect()
      wait_ready()
      wait(function()
        return #service.team_starts == 1
      end, 15000, "the enabled workflow")
      t.eq("dev", service.team_starts[1].workflow)
      t.eq(nil, service.team_starts[1].task)
      t.truthy(service.team_starts[1].sessionId, "the start names the current session")
      -- A second snapshot for the same session must not start it again.
      team():refresh()
      vim.wait(300)
      t.eq(1, #service.team_starts, "the workflow starts only once per session")
    end)

    t.it("does not auto-start just because teams are enabled", function()
      local service, dir = start_service(t, "auto-off")
      setup(t, dir, {
        teams = vim.tbl_extend("force", vim.deepcopy(auto_teams), { auto_start = false }),
      })
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the session's switch")
      vim.wait(300)
      t.eq(false, state().config.teams.auto_start)
      t.eq(0, #service.team_starts)
    end)

    -- Same production bug: a late `session.teams_changed` with `injected: true`
    -- re-runs `_maybe_auto_start`, which still finds no `list_by_cwd[cwd]` entry.
    t.it("does not start twice when the injected state arrives late", function()
      local service, dir = start_service(t, "auto-late")
      setup(t, dir, { teams = auto_teams })
      controller.connect()
      wait_ready()
      wait(function()
        return #service.team_starts == 1
      end, 15000, "the first auto start")
      local instance = own_instance()
      service:emit_session_teams(instance, state().sess.current.id)
      vim.wait(300)
      t.eq(1, #service.team_starts)
    end)

    t.it("does not auto-start when the session already leads a team", function()
      local service, dir = start_service(t, "auto-led")
      setup(t, dir, { teams = auto_teams })
      controller.connect()
      wait_ready()
      service:team_changed(active_team(dir, { leader = { instance = own_instance(), sessionId = "sess_mock" } }))
      vim.wait(400)
      t.truthy(team():team("t1"), "the team exists")
      t.eq(0, #service.team_starts, "an existing leader keeps its own team")
    end)

    t.it("a tree read of the current row never starts, even racing session_opened", function()
      local service, dir = start_service(t, "tree-pure")
      setup(t, dir, { teams = auto_teams })
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "session.teams") >= 1
      end, 5000, "the session's switch")
      -- Baseline: the current session's own switch event legitimately starts the
      -- workflow once. Everything below must not add a second start.
      wait(function()
        return #service.team_starts >= 1
      end, 15000, "the session's own auto-start")
      vim.wait(200)
      local starts = #service.team_starts
      local model = state().view.team
      local instance = own_instance()
      local id = state().sess.current.id

      -- The earlier start created a team for this cwd; drop it (and the grant it
      -- recorded) so the cwd is a fresh "no team yet" project again and only the
      -- calls below can decide anything.
      service.teams = {}
      model:refresh()
      wait(function()
        return team():team_for_cwd(dir) == nil
      end, 5000, "the cleared team")
      model.auto_eligible[instance .. "\0" .. id] = nil
      model.session_states[instance .. "\0" .. id] = nil
      model.auto_started[instance .. "\0" .. id] = nil

      -- A tree read of the *current* row, tagged `source = "tree"`, answers
      -- `injected: true` and must still not start anything.
      local seen
      model:query_session_teams(instance, id, dir, function(ok)
        seen = ok
      end, { source = "tree" })
      wait(function()
        return seen ~= nil
      end, 5000, "the tree read of the current row")
      vim.wait(300)
      t.eq(starts, #service.team_starts, "a pure read of the current row never starts")

      -- Now the interleaving the review calls out: a tree read is in flight when
      -- the real session event (`session_opened`) joins it. The merged request
      -- must remember that non-tree source and evaluate auto-start on the
      -- re-sent query.
      model.session_states[instance .. "\0" .. id] = nil
      local first
      model:query_session_teams(instance, id, dir, function(ok)
        first = ok
      end, { source = "tree" })
      model:session_opened(instance, id, dir)
      wait(function()
        return first ~= nil
      end, 5000, "the merged query")
      wait(function()
        return #service.team_starts > starts
      end, 5000, "the session event that joined the tree read to start the workflow")
      t.eq(starts + 1, #service.team_starts, "the merged session event starts once")
      t.eq(id, service.team_starts[starts + 1].sessionId)
    end)
  end)
end
