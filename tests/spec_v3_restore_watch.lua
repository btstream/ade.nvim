-- Restored teams v3 coverage: the worker watch path over the real service
-- (PROTOCOL.md 18.7): replay buffering until the reply names the instance, the
-- coalesced 2000-frame replay, a bad frame, paging back through turns, the
-- A→B→A switch, a close while the request is in flight and the `team.read`
-- fallback for a session the service could not replay.
--
-- Ported from `feat/teams-v3:tests/spec_s4_team.lua`. The v3 front end renders
-- the worker in the shared chat, so nothing here opens a dedicated watch
-- window; `tests/spec_worker_chat.lua` keeps the shared-composer semantics.
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
    local dir = string.format("/tmp/opencode/ade-v3watch-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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

  local function ui()
    return state().view.team_ui
  end

  local function blocks_text(session)
    local out = {}
    for _, block in ipairs(session and session.blocks or {}) do
      out[#out + 1] = block.text or ""
    end
    return table.concat(out, "\n")
  end

  local function seed_team(service, dir, over)
    local row = vim.tbl_deep_extend("force", {
      id = "t1",
      cwd = dir,
      state = "active",
      participants = {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w2", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w3", state = "idle", task = "_", queued = 0, turns = {} },
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

  local function watch(team_id, participant, replay)
    local m = team()
    local done, ok, value = false, nil, nil
    m:watch(team_id or "t1", participant, replay ~= false, function(result, result_value)
      done, ok, value = true, result, result_value
    end)
    wait(function()
      return done
    end, 10000, "team.watch " .. tostring(participant))
    return ok, value
  end

  t.describe("teams v3 watch", function()
    t.it("buffers the replay until the response names the instance", function()
      local service, dir = start_service(t, "watch-buffer")
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local leader_session = state().sess.current.id
      service.team_watch = {
        instance = "inst-w",
        sessionId = "sess-w",
        replay = { { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "worker replay" } } },
        foreign = {
          {
            instance = state().conn.client.proc.instance,
            sessionId = leader_session,
            update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "LEADER LEAK" } },
          },
        },
      }
      local ok = watch("t1", "w1")
      t.eq(true, ok)
      t.eq("sess-w", team().watching.session.id)
      local text = blocks_text(team().watching.session)
      t.match("worker replay", text)
      t.falsy(text:find("LEADER LEAK", 1, true), "the leader's updates leaked into the watch")
      team():unwatch()
    end)

    t.it("renders a replay and its live updates once each", function()
      local service, dir = start_service(t, "watch-live", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replay = {
            { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "replay line" } },
          },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local m = team()
      local renders = 0
      local original = m.on_watch
      m.on_watch = function(session, title)
        renders = renders + 1
        return original and original(session, title)
      end
      t.cleanup(function()
        m.on_watch = original
      end)
      local ok, value = watch("t1", "w1")
      t.eq(true, ok)
      t.eq("sess-w", value.sessionId)
      wait(function()
        return blocks_text(m.watching.session):find("replay line", 1, true) ~= nil
      end, 5000, "the replay to render")
      service:watch_update("inst-w", "sess-w", {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "live line" },
      })
      wait(function()
        return blocks_text(m.watching.session):find("live line", 1, true) ~= nil
      end, 5000, "the live watch update")
      wait(function()
        return renders >= 2
      end, 5000, "the watch view to render the live update")
      m:unwatch()
    end)

    t.it("batches a 2000-frame replay into one render and coalesces a live burst", function()
      local replay = {}
      for index = 1, 2000 do
        replay[index] = {
          sessionUpdate = "agent_message_chunk",
          content = { type = "text", text = "frame " .. index .. "\n" },
        }
      end
      local service, dir = start_service(t, "watch-batch", {
        team_watch = { instance = "inst-w", sessionId = "sess-w", replay = replay },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local m = team()
      local renders = 0
      local original = m.on_watch
      m.on_watch = function(session, title)
        renders = renders + 1
        return original and original(session, title)
      end
      t.cleanup(function()
        m.on_watch = original
      end)
      local started = vim.uv.hrtime()
      local ok = watch("t1", "w1")
      t.eq(true, ok)
      t.truthy(m.watching and m.watching.session, "the watched session")
      local elapsed = (vim.uv.hrtime() - started) / 1e6
      t.eq(1, renders, "a replay batch renders once")
      t.truthy(elapsed < 5000, string.format("the replay took %.0f ms", elapsed))
      local session = m.watching.session
      t.match("frame 2000", blocks_text(session))
      for index = 1, 100 do
        service:watch_update("inst-w", "sess-w", {
          sessionUpdate = "agent_message_chunk",
          content = { type = "text", text = "live " .. index .. "\n" },
        })
      end
      wait(function()
        return blocks_text(session):find("live 100", 1, true) ~= nil
      end, 5000, "the live burst")
      vim.wait(120)
      t.truthy(renders <= 4, "live frames are coalesced, got " .. tostring(renders) .. " renders")
      m:unwatch()
    end)

    t.it("skips a failing replay frame and still completes the watch", function()
      local reducer = require("ade.session.reducer")
      local original_reducer = reducer.apply
      local calls = 0
      reducer.apply = function(session, update)
        calls = calls + 1
        if calls == 1 then
          error("synthetic reducer failure")
        end
        return original_reducer(session, update)
      end
      t.cleanup(function()
        reducer.apply = original_reducer
      end)
      local service, dir = start_service(t, "watch-bad-frame", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replay = {
            { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "BAD" } },
            { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "GOOD" } },
          },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local ok = watch("t1", "w1")
      t.eq(true, ok)
      wait(function()
        return blocks_text(team().watching.session):find("GOOD", 1, true) ~= nil
      end, 5000, "the valid frame")
      t.falsy(blocks_text(team().watching.session):find("BAD", 1, true), "the bad frame is dropped")
      team():unwatch()
    end)

    t.it("pages a long watch and jumps to the previous turn across pages", function()
      local replay = {}
      for turn = 1, 40 do
        replay[#replay + 1] = {
          sessionUpdate = "user_message_chunk",
          content = { type = "text", text = "turn " .. turn },
        }
        replay[#replay + 1] = {
          sessionUpdate = "agent_message_chunk",
          content = { type = "text", text = "answer " .. turn },
        }
      end
      for tool = 1, 60 do
        replay[#replay + 1] = {
          sessionUpdate = "tool_call",
          toolCallId = "tail-" .. tool,
          title = "tail tool " .. tool,
          status = "completed",
          rawInput = {},
        }
      end
      local service, dir = start_service(t, "watch-pages", {
        team_watch = { instance = "inst-w", sessionId = "sess-w", replay = replay },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local ok = watch("t1", "w1")
      t.eq(true, ok)
      local UI = ui()
      UI:watch(team().watching.session, "t1/w1")
      local router = UI.router
      wait(function()
        return router.chat and router.chat.page and not router.chat.commit_job
      end, 10000, "the paged watch")
      local page = router.chat.page
      t.truthy(page.first > 1, "the watch pages old turns")
      local before_first = page.first
      local old_first = router.chat.session.blocks[page.first]
      local page_ok = old_first.id:match("^watch%-turn%-") ~= nil
      if page.continuation then
        local buffer_text = table.concat(vim.api.nvim_buf_get_lines(router.chat.buf, 0, -1, false), "\n")
        page_ok = page_ok or buffer_text:find("（" .. page.continuation .. "）", 1, true) ~= nil
      end
      t.truthy(page_ok, "a watch page starts on a turn heading or a continuation line: " .. tostring(old_first.id))
      local current_turn
      if page.continuation then
        current_turn = tonumber(page.continuation:match("(%d+)"))
      else
        current_turn = tonumber(old_first.id:match("(%d+)$"))
      end
      local previous = current_turn
      vim.api.nvim_set_current_win(router.chat.win)
      vim.api.nvim_win_set_cursor(router.chat.win, { 1, 0 })
      router:jump_turn(-1)
      wait(function()
        return router.chat.page.first < before_first and not router.chat.commit_job and not router.chat.layout_job
      end, 10000, "the older page")
      local cursor = vim.api.nvim_win_get_cursor(router.chat.win)[1]
      local line = vim.api.nvim_buf_get_lines(router.chat.buf, cursor - 1, cursor, false)[1] or ""
      t.match("── turn " .. tostring(previous - 1), line, "jump to the previous turn heading")
      t.eq("system", router.chat.session.blocks[router.chat.page.first].kind)
      -- Collapsing a visible turn keeps the reader on the same heading.
      local visible = router:turn_lines()
      local heading = visible[2] or visible[1]
      t.truthy(heading)
      vim.api.nvim_win_set_cursor(router.chat.win, { heading.line, 0 })
      router:toggle_at_cursor()
      wait(function()
        return not router.chat.commit_job and not router.chat.layout_job
      end, 10000, "the collapsed turn")
      t.truthy(router.collapsed[heading.number], "the turn is folded as a whole")
      router:close()
      team():unwatch()
    end)

    t.it("rapid A-B-A switching keeps the last watch and does not unwatch it again", function()
      local service, dir = start_service(t, "watch-rapid", {
        team_watch = { instance = "inst-w", sessionId = "sess-w", delays = { 200, 10, 10 } },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local UI = ui()
      UI.router:open("t1", "w1")
      vim.wait(30)
      UI.router:open("t1", "w2")
      vim.wait(30)
      UI.router:open("t1", "w1")
      wait(function()
        return team().watching
          and team().watching.participant == "w1"
          and UI.router.target
          and UI.router.target.participant == "w1"
      end, 5000, "the final A watch")
      vim.wait(400)
      t.eq("w1", team().watching.participant, "a stale A response must not replace the new A")
      local unwatches = 0
      for _, call in ipairs(service.team_unwatch or {}) do
        if call.participant == "w1" then
          unwatches = unwatches + 1
        end
      end
      t.eq(0, unwatches, "A stays current, so B is skipped and A is never unwatched")
      UI.router:close()
    end)

    t.it("closing during an in-flight watch request releases it", function()
      local service, dir = start_service(t, "watch-close", {
        team_watch = { instance = "inst-w", sessionId = "sess-w", delays = { 150 } },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local UI = ui()
      UI.router:open("t1", "w1")
      UI.router:close()
      vim.wait(300)
      t.eq(nil, team().watching, "the late response must not leave a watch")
      t.eq(nil, UI.router.target, "the late response must not open a worker")
      t.truthy(#(service.team_unwatch or {}) >= 1, "the in-flight watch is released")
    end)

    t.it("shows the replay fallback notice and supplements it from team.read", function()
      local service, dir = start_service(t, "watch-fallback", {
        team_watch = {
          instance = "inst-w",
          sessionId = "sess-w",
          replayed = false,
          replay = { { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "live only" } } },
        },
        team_read = {
          messages = {
            { from = "leader", to = "w1", kind = "task", task = "T9", body = "earlier instruction" },
          },
          turns = { { at = 1, text = "earlier turn text" } },
        },
      })
      setup(t, dir)
      controller.connect()
      wait_ready()
      seed_team(service, dir)
      local ok = watch("t1", "w1")
      t.eq(true, ok)
      local UI = ui()
      UI:watch(team().watching.session, "t1/w1")
      local function text()
        return table.concat(vim.api.nvim_buf_get_lines(UI.router.chat.buf, 0, -1, false), "\n")
      end
      wait(function()
        local body = text()
        return body:find("会话过长，只显示观察开始之后的内容", 1, true) ~= nil
          and body:find("earlier instruction", 1, true) ~= nil
          and body:find("earlier turn text", 1, true) ~= nil
      end, 10000, "the replay fallback and team.read supplement")
      UI.router:close()
      team():unwatch()
    end)

    t.it("ends the watch when the panel closes or the team goes away", function()
      local service, dir = start_service(t, "watch-end")
      setup(t, dir)
      controller.connect()
      wait_ready()
      local instance = state().conn.client.proc.instance
      local session_id = state().sess.current.id
      seed_team(service, dir, { leader = { instance = instance, sessionId = session_id } })
      local UI = ui()
      local function count()
        return service.team_unwatch and #service.team_unwatch or 0
      end
      watch("t1", "w1")
      UI:watch(team().watching.session, "t1/w1")
      t.truthy(UI.router.target, "the worker is shown in the shared chat")
      local before = count()
      UI:close()
      wait(function()
        return team().watching == nil and count() > before
      end, 5000, "the panel close to unwatch")
      -- A closed team has nothing left to watch, and no unwatch is sent for it.
      service:team_changed({
        id = "t2",
        cwd = dir,
        state = "active",
        participants = { { name = "leader", state = "idle" }, { name = "w9", state = "idle" } },
        leader = { instance = instance, sessionId = session_id },
        inbox = {},
        limits = {},
      })
      wait(function()
        return team():team("t2") ~= nil
      end, 5000, "the second team")
      watch("t2", "w9", false)
      local unwatches = count()
      service:team_changed({
        id = "t2",
        cwd = dir,
        state = "closed",
        participants = {},
        inbox = {},
        limits = {},
      })
      wait(function()
        return team().watching == nil
      end, 5000, "the closed team to unwatch")
      t.eq(unwatches, count(), "a closed team sends no team.unwatch")
    end)
  end)
end
