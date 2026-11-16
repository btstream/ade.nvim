-- S1b plugin-side behaviour: adoption, restore, auto-reconnect, version
-- reconciliation and the new service flags.
--
-- Everything here is offline: the stand-in service and the fake connection are
-- asynchronous by default (tests that want a synchronous reply say so).
return function(t)
  local Version = require("ade.service.version")
  local Config = require("ade.config")
  local Adoption = require("ade.app.adoption")
  local Restore = require("ade.app.restore")
  local Reconnector = require("ade.app.reconnector")
  local VersionCheck = require("ade.service.version_check")

  local counter = 0
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-s1b-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.mkdir(dir, "p", 448)
    t.cleanup(function()
      vim.fn.delete(dir, "rf")
    end)
    return dir
  end

  local function config_with(overrides)
    return Config.validate(Config.merge(Config.defaults, overrides or {}))
  end

  t.describe("service event log and reconnect configuration", function()
    t.it("defaults the new service switches", function()
      local cfg = config_with({})
      t.eq(true, cfg.service.event_log)
      t.eq(256, cfg.service.event_log_max_mb)
      t.eq(true, cfg.service.restore)
      t.eq(8, cfg.service.reconnect_attempts)
    end)

    t.it("validates event_log, event_log_max_mb, restore and reconnect_attempts", function()
      t.eq(false, config_with({ service = { event_log = false } }).service.event_log)
      t.eq(16, config_with({ service = { event_log_max_mb = 16 } }).service.event_log_max_mb)
      t.eq(4096, config_with({ service = { event_log_max_mb = 4096 } }).service.event_log_max_mb)
      t.eq(false, config_with({ service = { restore = false } }).service.restore)
      t.eq(0, config_with({ service = { reconnect_attempts = 0 } }).service.reconnect_attempts)
      t.eq(50, config_with({ service = { reconnect_attempts = 50 } }).service.reconnect_attempts)

      t.raises(function()
        config_with({ service = { event_log = "on" } })
      end, "event_log must be a boolean")
      t.raises(function()
        config_with({ service = { event_log_max_mb = 15 } })
      end, "event_log_max_mb")
      t.raises(function()
        config_with({ service = { event_log_max_mb = 4097 } })
      end, "event_log_max_mb")
      t.raises(function()
        config_with({ service = { restore = "yes" } })
      end, "restore must be a boolean")
      t.raises(function()
        config_with({ service = { reconnect_attempts = -1 } })
      end, "reconnect_attempts")
      t.raises(function()
        config_with({ service = { reconnect_attempts = 51 } })
      end, "reconnect_attempts")
    end)
  end)

  t.describe("launcher flags", function()
    local Launcher = require("ade.service.launcher")

    t.it("passes the event-log flags when it starts the service", function()
      local argv = nil
      local ok = Launcher.start({
        bin = "/fake/nvim_ade_server",
        timeout = 100,
        event_log = false,
        event_log_max_mb = 64,
        spawn = function(cmd, on_line)
          argv = vim.deepcopy(cmd)
          on_line('{"status":"ready","socket":"/tmp/x.sock","pid":1}')
          return true
        end,
      })
      t.truthy(ok)
      local joined = table.concat(argv, " ")
      t.match("%-%-event%-log off", joined)
      t.match("%-%-event%-log%-max%-mb 64", joined)
    end)

    t.it("says on when the log is enabled", function()
      local argv = nil
      Launcher.start({
        bin = "/fake/nvim_ade_server",
        timeout = 100,
        event_log = true,
        spawn = function(cmd, on_line)
          argv = vim.deepcopy(cmd)
          on_line('{"status":"ready","socket":"/tmp/x.sock","pid":1}')
          return true
        end,
      })
      t.match("%-%-event%-log on", table.concat(argv, " "))
    end)

    t.it("omits the flags when nothing is configured", function()
      local argv = nil
      Launcher.start({
        bin = "/fake/nvim_ade_server",
        timeout = 100,
        spawn = function(cmd, on_line)
          argv = vim.deepcopy(cmd)
          on_line('{"status":"ready","socket":"/tmp/x.sock","pid":1}')
          return true
        end,
      })
      t.falsy(table.concat(argv, " "):find("--event-log", 1, true))
    end)
  end)

  t.describe("turn adoption", function()
    ---A minimal session object: adoption only needs the turn bookkeeping.
    local function fake_session(id)
      local session = {
        id = id,
        status = "idle",
        turn = 0,
        queue = {},
        blocks = {},
        finished = {},
      }
      function session:begin_turn()
        self.turn = self.turn + 1
        self.status = "running"
      end
      function session:finish_turn(reason)
        self.status = "idle"
        self.finished[#self.finished + 1] = reason
      end
      return session
    end

    ---An adoption instance over a state table, recording what it did.
    local function harness(sessions)
      local state = { sess = { all = sessions or {} } }
      local record = { chrome = 0, renders = 0, dispatched = {}, blocks = {}, notes = {} }
      local instance = Adoption.new({
        state = function()
          return state
        end,
        refresh_chrome = function()
          record.chrome = record.chrome + 1
        end,
        schedule_render = function()
          record.renders = record.renders + 1
        end,
        dispatch_queued = function(session)
          record.dispatched[#record.dispatched + 1] = session.id
        end,
        add_block = function(text, kind)
          record.blocks[#record.blocks + 1] = { text = text, kind = kind }
        end,
        notify = function(message, level)
          record.notes[#record.notes + 1] = { message = message, level = level }
        end,
      })
      return instance, state, record
    end

    t.it("marks the session running and records the adoption", function()
      local session = fake_session("s1")
      local instance, _, record = harness({ s1 = session })
      instance:adopted_turn({ session_id = "s1" })
      t.eq("running", session.status)
      t.truthy(instance:is_adopted("s1"))
      t.truthy(record.chrome > 0, "the toolbar must be refreshed")
      t.truthy(record.renders > 0)
    end)

    t.it("finishes the turn and dispatches the queue", function()
      local session = fake_session("s1")
      local instance, _, record = harness({ s1 = session })
      instance:adopted_turn({ session_id = "s1" })
      instance:finished_turn({ session_id = "s1", stop_reason = "end_turn" })
      t.eq("idle", session.status)
      t.eq({ "end_turn" }, session.finished)
      t.eq({ "s1" }, record.dispatched, "the queued messages must be dispatched")
      t.falsy(instance:is_adopted("s1"))
    end)

    t.it("uses the same cancel path when the user stops an adopted turn", function()
      -- The session looks like a normal running turn, so `session/cancel` works
      -- with no extra code. This asserts the state the cancel path relies on.
      local session = fake_session("s1")
      local instance = harness({ s1 = session })
      instance:adopted_turn({ session_id = "s1" })
      t.eq("running", session.status)
      -- `turn` is a real turn number, so `Session:cancel_turn` accepts it.
      t.truthy(session.turn > 0)
      t.falsy(session.prompt_task, "an adopted turn must not pretend to own a prompt task")
    end)

    t.it("ignores an unknown session", function()
      local instance, _, record = harness({})
      instance:adopted_turn({ session_id = "missing" })
      t.falsy(instance:is_adopted("missing"))
      t.eq(0, record.chrome, "nothing to refresh")
    end)

    t.it("ignores a repeated adoption", function()
      local session = fake_session("s1")
      local instance, _, record = harness({ s1 = session })
      instance:adopted_turn({ session_id = "s1" })
      local turn = session.turn
      instance:adopted_turn({ session_id = "s1" })
      t.eq(turn, session.turn, "a duplicate must not bump the turn")
      t.eq(1, record.chrome)
    end)

    t.it("ignores an adoption while a local turn owns the session", function()
      local session = fake_session("s1")
      session.status = "running"
      local instance, _, _ = harness({ s1 = session })
      instance:adopted_turn({ session_id = "s1" })
      t.falsy(instance:is_adopted("s1"), "a local turn must keep its bookkeeping")
    end)

    t.it("ignores a finish for a turn this front end did not adopt", function()
      local session = fake_session("s1")
      local instance, _, _ = harness({ s1 = session })
      instance:finished_turn({ session_id = "s1", stop_reason = "end_turn" })
      t.eq({}, session.finished, "a stray finish must not end an idle session")
    end)

    t.it("reports an adopted turn that failed", function()
      local session = fake_session("s1")
      local instance, _, record = harness({ s1 = session })
      instance:adopted_turn({ session_id = "s1" })
      instance:finished_turn({
        session_id = "s1",
        stop_reason = "end_turn",
        error = { code = -32099, message = "boom" },
      })
      t.eq({ "error" }, session.finished)
      t.eq(1, #record.blocks)
      t.eq("error", record.blocks[1].kind)
      t.match("boom", record.blocks[1].text)
      t.eq(1, #record.notes, "the failure is reported once")
    end)

    t.it("settles everything when the client goes away", function()
      local one = fake_session("s1")
      local two = fake_session("s2")
      local instance, _, _ = harness({ s1 = one, s2 = two })
      instance:adopted_turn({ session_id = "s1" })
      instance:adopted_turn({ session_id = "s2" })
      instance:reset("connection lost")
      t.eq("idle", one.status, "no spinner may outlive the connection")
      t.eq("idle", two.status)
      t.eq({ cancelled = true }, { cancelled = one.finished[1] == "cancelled" })
      t.falsy(instance:is_adopted("s1"))
    end)
  end)

  t.describe("session restore", function()
    t.it("picks the most recently updated session for the cwd", function()
      local sessions = {
        { sessionId = "old", cwd = "/proj", updated_at = 100 },
        { sessionId = "new", cwd = "/proj", updated_at = 300 },
        { sessionId = "other", cwd = "/elsewhere", updated_at = 900 },
      }
      local picked = Restore.pick(sessions, "/proj")
      t.truthy(picked)
      t.eq("new", picked.sessionId)
    end)

    t.it("does not pick another project's session", function()
      local picked, reason = Restore.pick({ { sessionId = "a", cwd = "/other", updated_at = 1 } }, "/proj")
      t.falsy(picked)
      t.match("/proj", reason)
    end)

    t.it("breaks ties deterministically", function()
      local sessions = {
        { sessionId = "b", cwd = "/p", updated_at = 5 },
        { sessionId = "a", cwd = "/p", updated_at = 5 },
      }
      t.eq("a", Restore.pick(sessions, "/p").sessionId)
    end)

    t.it("reports an empty session list", function()
      local picked, reason = Restore.pick({}, "/p")
      t.falsy(picked)
      t.match("no sessions", reason)
    end)

    ---A restore instance with recording deps.
    local function harness(opts)
      opts = opts or {}
      local record = { loaded = {}, created = 0, notes = {} }
      local instance = Restore.new({
        config = function()
          return opts.config or config_with({})
        end,
        cwd = function()
          return opts.cwd or "/proj"
        end,
        supported = function()
          return opts.supported ~= false
        end,
        load = function(id, load_opts)
          record.loaded[#record.loaded + 1] = id
          record.load_opts = load_opts
          if opts.fail_load then
            if load_opts and load_opts.on_failed then
              load_opts.on_failed(opts.fail_load)
            end
            return
          end
          if load_opts and load_opts.on_restored then
            load_opts.on_restored()
          end
        end,
        create = function()
          record.created = record.created + 1
        end,
        notify = function(message, level)
          record.notes[#record.notes + 1] = { message = message, level = level }
        end,
      })
      return instance, record
    end

    t.it("loads the reported session when the instance is reused", function()
      local instance, record = harness()
      local restored = instance:after_ready({
        created = false,
        sessions = { { sessionId = "s9", cwd = "/proj", updated_at = 10 } },
      })
      t.truthy(restored)
      t.eq({ "s9" }, record.loaded)
    end)

    t.it("does nothing for a newly created instance", function()
      local instance, record = harness()
      local restored = instance:after_ready({
        created = true,
        sessions = { { sessionId = "s9", cwd = "/proj", updated_at = 10 } },
      })
      t.falsy(restored)
      t.eq({}, record.loaded)
    end)

    t.it("honours service.restore = false", function()
      local instance, record = harness({ config = config_with({ service = { restore = false } }) })
      local restored = instance:after_ready({
        created = false,
        sessions = { { sessionId = "s9", cwd = "/proj", updated_at = 10 } },
      })
      t.falsy(restored)
      t.eq({}, record.loaded)
      t.eq(0, #record.notes, "turning it off is not an error")
    end)

    t.it("explains once when there is no session for this cwd", function()
      local instance, record = harness()
      local restored = instance:after_ready({
        created = false,
        sessions = { { sessionId = "s9", cwd = "/other", updated_at = 10 } },
      })
      t.falsy(restored)
      t.eq(1, #record.notes)
      t.match("/proj", record.notes[1].message)
      -- A second attempt stays quiet.
      instance:after_ready({ created = false, sessions = { { sessionId = "s8", cwd = "/other" } } })
      t.eq(1, #record.notes)
    end)

    t.it("ignores an entry shaped like the old non-spec field", function()
      -- PROTOCOL.md 3.2 says `sessionId`. Reading `id` as well would hide a
      -- service (or a stand-in) that drifted from the spec: the whole defect
      -- this test exists for was a fake that used `id` and a reader to match.
      local picked, reason = Restore.pick({ { id = "wrong", cwd = "/p", updated_at = 1 } }, "/p")
      t.falsy(picked)
      t.match("no session for /p", reason)
    end)

    t.it("tells the user which session was restored", function()
      local instance, record = harness()
      instance:after_ready({
        created = false,
        sessions = { { sessionId = "s9", cwd = "/proj", updated_at = 10 } },
      })
      t.eq(1, #record.notes, "a restore must say so")
      t.eq(vim.log.levels.INFO, record.notes[1].level)
      t.match("restored session s9", record.notes[1].message)
    end)

    t.it("says why a session could not be restored", function()
      local instance, record = harness({ fail_load = "session not found" })
      instance:after_ready({
        created = false,
        sessions = { { sessionId = "s7", cwd = "/proj", updated_at = 10 } },
      })
      t.eq({ "s7" }, record.loaded)
      local joined = {}
      for _, note in ipairs(record.notes) do
        joined[#joined + 1] = note.message
        t.eq(vim.log.levels.WARN, note.level, "a failed restore is a warning")
      end
      t.match("session s7 could not be restored", table.concat(joined, "\n"))
      t.match("session not found", table.concat(joined, "\n"))
    end)

    t.it("says why a session could not be restored (fallback)", function()
      local instance, record = harness({ supported = false })
      instance:after_ready({
        created = false,
        sessions = { { sessionId = "s9", cwd = "/proj", updated_at = 10 } },
      })
      t.eq(1, #record.notes)
      t.eq(vim.log.levels.WARN, record.notes[1].level, "a fallback the user did not ask for is a warning")
    end)

    t.it("falls back when the agent cannot load sessions", function()
      local instance, record = harness({ supported = false })
      local restored = instance:after_ready({
        created = false,
        sessions = { { sessionId = "s9", cwd = "/proj", updated_at = 10 } },
      })
      t.falsy(restored)
      t.eq({}, record.loaded)
      t.eq(1, #record.notes)
      t.match("cannot load", record.notes[1].message)
    end)
  end)

  t.describe("stand-in shapes match the protocol", function()
    t.it("reports sessions as {sessionId, cwd, running, updated_at}", function()
      -- A stand-in that uses a different field name than PROTOCOL.md 3.2 would
      -- make a wrong reader look correct: that is how `restore.lua` read `id`
      -- and still passed every test.
      local fake = require("tests.fake_service")
      local dir = tmpdir("shape")
      local service = fake.new({ dir = dir, canned_agent = true })
      service.spawn_agent = function()
        return true
      end
      t.truthy(service:listen())
      t.cleanup(function()
        service:close()
      end)
      local first = service:attach({
        key = { agent = "a", command = "b", args = {}, cwd = "/proj" },
        client_capabilities = {},
      }, { greeted = true, attached = {} }, 1)
      local instance = first.result.instance
      t.truthy(instance)
      service:track_session(instance, { sessionId = "s1", cwd = "/proj", updated_at = 5 })
      service:track_session(instance, { sessionId = "s2", cwd = "/proj", updated_at = 9 })
      local ok, reply = pcall(service.attach, service, {
        key = { agent = "a", command = "b", args = {}, cwd = "/proj" },
        client_capabilities = {},
      }, { greeted = true, attached = {} }, 2)
      t.truthy(ok, tostring(reply))
      t.eq(instance, reply.result.instance)
      local sessions = reply.result.sessions
      t.eq(2, #sessions)
      for _, entry in ipairs(sessions) do
        t.truthy(entry.sessionId, "a stand-in session without sessionId")
        t.eq(nil, entry.id, "the stand-in must not invent an `id` field")
        t.truthy(entry.cwd)
        t.eq(false, entry.running)
        t.truthy(type(entry.updated_at) == "number")
      end
    end)
  end)

  t.describe("automatic reconnection", function()
    t.it("uses the documented backoff ladder", function()
      t.eq(500, Reconnector.delay_for(1))
      t.eq(1000, Reconnector.delay_for(2))
      t.eq(2000, Reconnector.delay_for(3))
      t.eq(4000, Reconnector.delay_for(4))
      t.eq(8000, Reconnector.delay_for(5))
      t.eq(15000, Reconnector.delay_for(6))
      t.eq(15000, Reconnector.delay_for(9))
    end)

    ---A reconnector driven by a manual clock: `defer` records what would run.
    local function harness(opts)
      opts = opts or {}
      local record = { delays = {}, notes = {}, statuses = {}, reconnects = 0, ensures = 0, now = 0 }
      local pending = {}
      local instance = Reconnector.new({
        config = function()
          return opts.config or config_with({})
        end,
        ensure = function(cb)
          record.ensures = record.ensures + 1
          -- Not `x and x[i] or true`: a `false` entry would fall through to the
          -- default. Each scripted result is explicit.
          local ok = true
          if opts.results and opts.results[record.ensures] ~= nil then
            ok = opts.results[record.ensures]
          end
          cb(ok, ok and nil or "service unavailable")
        end,
        reconnect = function()
          record.reconnects = record.reconnects + 1
        end,
        notify = function(message, level)
          record.notes[#record.notes + 1] = { message = message, level = level }
        end,
        set_status = function(text)
          -- `nil` means "clear": store a string sentinel. A Lua `false` at the
          -- end of a table is invisible to `#`/`vim.inspect`, which would make
          -- the assertion lie.
          record.statuses[#record.statuses + 1] = text == nil and "<cleared>" or text
        end,
        -- Injectable clock, in milliseconds: the crash-loop protection is
        -- about elapsed time, and a test cannot wait a minute.
        now = function()
          return record.now
        end,
        defer = function(fn, delay)
          record.delays[#record.delays + 1] = delay
          pending[#pending + 1] = fn
          return fn
        end,
      })
      local function step()
        local fn = table.remove(pending, 1)
        if fn then
          fn()
        end
        return fn ~= nil
      end
      return instance, record, step
    end

    t.it("retries with the ladder, then reports and stops", function()
      local instance, record, step =
        harness({ results = { false, false, false }, config = config_with({ service = { reconnect_attempts = 3 } }) })
      instance:lost()
      -- `lost()` schedules attempt 1.
      t.eq({ 500 }, record.delays)
      t.truthy(step()) -- attempt 1 fails, schedules attempt 2
      t.eq({ 500, 1000 }, record.delays)
      t.truthy(step()) -- attempt 2 fails, schedules attempt 3
      t.eq({ 500, 1000, 2000 }, record.delays)
      t.truthy(step()) -- attempt 3 is the last: reports and stops
      -- The third failure reached the limit, so nothing new was scheduled.
      t.eq({ 500, 1000, 2000 }, record.delays)
      t.falsy(instance:is_running())
      local last = record.notes[#record.notes]
      t.eq(vim.log.levels.ERROR, last.level)
      t.match("could not reconnect after 3 attempts", last.message)
    end)

    t.it("reports progress on the first attempt and success once", function()
      local instance, record, step = harness({ config = config_with({ service = { reconnect_attempts = 3 } }) })
      instance:lost()
      step()
      local progress = {}
      for _, note in ipairs(record.notes) do
        progress[#progress + 1] = note.message
      end
      t.match("reconnecting %(1/3%)", table.concat(progress, "\n"))
      t.eq(1, record.reconnects)
      t.match("reconnected", record.notes[#record.notes].message)
      t.falsy(instance:is_running())
    end)

    t.it("only one loop runs, however many drops arrive", function()
      local instance, record, _ = harness()
      instance:lost()
      instance:lost()
      instance:lost()
      t.eq(1, #record.delays, "a second drop must not schedule another attempt")
    end)

    t.it("does nothing when reconnect_attempts is 0", function()
      local instance, record, _ = harness({ config = config_with({ service = { reconnect_attempts = 0 } }) })
      instance:lost()
      t.eq({}, record.delays)
      t.falsy(instance:is_running())
    end)

    t.it("cancels immediately on an explicit disconnect", function()
      local instance, record, step = harness({ results = { false, false } })
      instance:lost()
      step()
      t.truthy(instance:is_running())
      instance:cancel("user disconnected")
      t.falsy(instance:is_running())
      local before = #record.delays
      -- A timer that was already handed to `defer` must not restart the loop
      -- after the cancel.
      while step() do
        -- drain whatever was pending
      end
      t.eq(before, #record.delays, "a stale timer restarted the loop")
      t.falsy(instance:is_running())
    end)

    t.it("keeps climbing through a crash loop instead of restarting the ladder", function()
      -- The service comes back and dies again within seconds. Treating every
      -- success as a fresh start would retry forever at 0.5s, starting a new
      -- service each time and never telling the user anything is wrong.
      local instance, record, step = harness({ config = config_with({ service = { reconnect_attempts = 4 } }) })
      local delays, rounds = {}, 0
      -- Four rounds of "connect, then die immediately". `record.now` never
      -- advances, so each round is inside the 60 s stability window.
      for _ = 1, 4 do
        instance:lost()
        delays[#delays + 1] = record.delays[#record.delays]
        step()
        rounds = rounds + 1
        t.falsy(instance:is_running(), "a successful reconnect ends the loop")
        t.eq(rounds, record.reconnects)
      end
      t.eq({ 500, 1000, 2000, 4000 }, delays, "the ladder must continue across a crash loop")
      -- Every attempt is used, so the next loss reports and stops.
      instance:lost()
      t.eq(4, #delays)
      t.falsy(instance:is_running())
      local last = record.notes[#record.notes]
      t.eq(vim.log.levels.ERROR, last.level)
      t.match("keeps disconnecting", last.message)
    end)

    t.it("resets the ladder after a stable connection", function()
      local instance, record, step = harness({ config = config_with({ service = { reconnect_attempts = 4 } }) })
      instance:lost()
      step()
      t.eq(1, instance.attempt)
      t.truthy(record.reconnects == 1)
      -- More than 60 s of stability: the next loss is a new incident.
      record.now = 120000
      instance:lost()
      t.eq(500, record.delays[#record.delays], "a stable connection starts the ladder over")
      t.eq(0, instance.attempt)
    end)

    t.it("leaves manual reconnect available after giving up", function()
      local instance, record, step = harness({
        results = { false },
        config = config_with({ service = { reconnect_attempts = 1 } }),
      })
      instance:lost()
      step()
      t.falsy(instance:is_running())
      t.match("could not reconnect", record.notes[#record.notes].message)
      -- `:Ade reconnect` goes through `Connection:reconnect`, not this module,
      -- so the loop being stopped must not block it. Starting a new incident
      -- still works.
      record.now = 300000
      instance:lost()
      t.truthy(instance:is_running(), "a manual reconnect must not be blocked by the exhausted loop")
    end)

    t.it("clears the status text when it finishes", function()
      local instance, record, step = harness()
      instance:lost()
      step()
      t.eq("<cleared>", record.statuses[#record.statuses], "the reconnecting badge must go away")
    end)

    t.it("sets the badge before and clears it after", function()
      local instance, record, step = harness()
      instance:lost()
      step()
      -- The last write is the clear; the first is the progress text.
      t.match("reconnecting %(1/", record.statuses[1])
      t.eq("<cleared>", record.statuses[#record.statuses])
    end)

    t.it("shows the badge while the first retry is still waiting", function()
      -- The ladder waits 0.5s before the first attempt. A fast service comes
      -- back so quickly that the status written by `attempt_once` can be gone
      -- before any observer notices; the user must see the retry start as soon
      -- as the drop is known, not only when the attempt happens to run.
      local instance, record, step = harness({ config = config_with({ service = { reconnect_attempts = 3 } }) })
      instance:lost()
      t.eq(
        "reconnecting (1/3)",
        record.statuses[#record.statuses],
        "the badge must appear when the drop is known, before the backoff elapses"
      )
      step()
      -- The attempt itself writes the same progress text again; the clear only
      -- comes with the result.
      t.eq("<cleared>", record.statuses[#record.statuses], "the badge goes away once the attempt succeeds")
    end)

    t.it("clears the badge when the loop is cancelled", function()
      local instance, record = harness()
      instance:lost()
      t.match("reconnecting %(1/", record.statuses[#record.statuses])
      instance:cancel("user disconnected")
      t.eq("<cleared>", record.statuses[#record.statuses], "a cancelled loop must not leave a badge behind")
    end)

    t.it("does not leave a badge when the previous incident used every attempt", function()
      local instance, record, step = harness({
        config = config_with({ service = { reconnect_attempts = 1 } }),
      })
      instance:lost()
      step()
      t.eq("<cleared>", record.statuses[#record.statuses])
      -- A second loss inside the 60 s stability window happens after the only
      -- attempt was used: it gives up immediately, and must not show a retry
      -- badge for an attempt it will never make.
      instance:lost()
      t.falsy(instance:is_running())
      t.eq("<cleared>", record.statuses[#record.statuses], "the give-up path must not leave a stale badge")
      t.match("keeps disconnecting", record.notes[#record.notes].message)
    end)
  end)

  t.describe("version reconciliation", function()
    ---A version checker with a scripted idle probe and restart.
    local function harness(opts)
      opts = opts or {}
      local record = { notes = {}, restarts = 0, restart_ok = opts.restart_ok ~= false }
      local instance = VersionCheck.new({
        config = function()
          return opts.config or config_with({})
        end,
        request_sync = function()
          if opts.list == "timeout" then
            return false, { code = -32000, message = "timed out" }
          end
          if opts.list == "unsupported" then
            return false, { code = -32601, message = "Method not found" }
          end
          return true, { instances = opts.instances or {} }
        end,
        restart = function(cb)
          record.restarts = record.restarts + 1
          cb(record.restart_ok, record.restart_ok and nil or "restart failed")
        end,
        notify = function(message, level)
          record.notes[#record.notes + 1] = { message = message, level = level }
        end,
      })
      return instance, record
    end

    t.it("accepts the same version without probing", function()
      local instance, record = harness()
      t.truthy(instance:check({ server_version = Version.VERSION, api_version = Version.API_VERSION }))
      t.eq(0, record.restarts)
      t.eq(0, #record.notes)
    end)

    t.it("restarts an idle service on a different version", function()
      local instance, record = harness({ instances = {} })
      t.truthy(instance:check({ server_version = Version.VERSION .. "-old", api_version = Version.API_VERSION }))
      t.eq(1, record.restarts)
      t.eq(1, #record.notes)
      t.eq(vim.log.levels.INFO, record.notes[1].level)
      t.match("restarting nvim_ade_server", record.notes[1].message)
      t.match("0 idle agent", record.notes[1].message)
    end)

    t.it("says how many idle agents the restart takes with it", function()
      -- A service restart stops the agents that live in it: their sessions come
      -- back only through the agent's own `session/load`. Saying "service
      -- restarted" alone hides that from the user.
      local instances = {
        { turns_running = 0, pending_requests = 0, attached = 1, agent = "opencode" },
        { turns_running = 0, pending_requests = 0, attached = 0, agent = "claude" },
        { turns_running = 0, pending_requests = 0, attached = 0, agent = "codex" },
      }
      local instance, record = harness({ instances = instances })
      t.truthy(instance:check({ server_version = Version.VERSION .. "-old", api_version = Version.API_VERSION }))
      t.eq(1, record.restarts)
      t.match(
        "restarting nvim_ade_server %("
          .. vim.pesc(Version.VERSION .. "-old")
          .. " %-> "
          .. vim.pesc(Version.VERSION)
          .. "%)",
        record.notes[1].message
      )
      t.match("3 idle agent%(s%) will restart with it", record.notes[1].message)
    end)

    t.it("waits for a busy service and warns only once", function()
      local instances = { { turns_running = 1, attached = 1, pending_requests = 0 } }
      local instance, record = harness({ instances = instances })
      t.truthy(instance:check({ server_version = Version.VERSION .. "-old", api_version = Version.API_VERSION }))
      t.eq(0, record.restarts, "a running turn must not be interrupted")
      t.eq(1, #record.notes)
      t.eq(vim.log.levels.WARN, record.notes[1].level)
      t.match("restarts automatically", record.notes[1].message)
      -- A later ensure checks again but stays quiet.
      instance:check({ server_version = Version.VERSION .. "-old", api_version = Version.API_VERSION })
      t.eq(1, #record.notes, "the warning is once per Neovim")
    end)

    t.it("treats another attached front end as busy", function()
      local instances = { { turns_running = 0, pending_requests = 0, attached = 2 } }
      local instance, record = harness({ instances = instances })
      instance:check({ server_version = Version.VERSION .. "-old", api_version = Version.API_VERSION })
      t.eq(0, record.restarts)
    end)

    t.it("treats a pending permission request as busy", function()
      local instances = { { turns_running = 0, pending_requests = 1, attached = 1 } }
      local instance, record = harness({ instances = instances })
      instance:check({ server_version = Version.VERSION .. "-old", api_version = Version.API_VERSION })
      t.eq(0, record.restarts)
    end)

    t.it("treats a service without agent.list as idle", function()
      local instance, record = harness({ list = "unsupported" })
      instance:check({ server_version = Version.VERSION .. "-old", api_version = 1 })
      t.eq(1, record.restarts)
    end)

    t.it("leaves a wedged service alone and says so", function()
      local instance, record = harness({ list = "timeout" })
      t.truthy(instance:check({ server_version = Version.VERSION .. "-old", api_version = Version.API_VERSION }))
      t.eq(0, record.restarts)
      t.eq(1, #record.notes)
      t.match("could not be checked", record.notes[1].message)
    end)

    t.it("reports a failed restart", function()
      local instance, record = harness({ restart_ok = false })
      t.truthy(instance:check({ server_version = Version.VERSION .. "-old", api_version = Version.API_VERSION }))
      t.eq(1, record.restarts)
      t.match("restarting nvim_ade_server", record.notes[1].message)
      t.match("could not restart", record.notes[2].message)
      t.eq(vim.log.levels.WARN, record.notes[2].level)
    end)

    t.it("does not report a failure while an asynchronous restart is in flight", function()
      -- A real restart is `shutdown` (socket round trip) then `ensure` (another
      -- one). Reading its result in the same statement always saw false, so a
      -- successful restart was reported as a failure. Its callback arrives on a
      -- later tick; nothing may be reported before then.
      local record = { notes = {}, restarts = 0, done = 0 }
      local pending_cb = nil
      local instance = VersionCheck.new({
        config = function()
          return config_with({})
        end,
        request_sync = function()
          return true, { instances = {} }
        end,
        restart = function(cb)
          record.restarts = record.restarts + 1
          pending_cb = cb
        end,
        notify = function(message, level)
          record.notes[#record.notes + 1] = { message = message, level = level }
        end,
      })
      local usable = instance:check({ server_version = Version.VERSION .. "-old" }, function()
        record.done = record.done + 1
      end)
      t.eq("pending", usable, "an in-flight restart must not claim to be settled")
      t.eq(1, record.restarts)
      -- Nothing has failed yet: only the "restarting ..." notice exists.
      t.eq(1, #record.notes)
      t.match("restarting nvim_ade_server", record.notes[1].message)
      -- The restart succeeds on a later tick.
      pending_cb(true, nil)
      t.eq(1, record.done)
      t.eq(1, #record.notes, "a successful restart must not add a failure notice")
      t.match("restarting", record.notes[1].message)
    end)
  end)
end
