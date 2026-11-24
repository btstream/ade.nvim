-- W0e v3: the `:Ade team start` flow against a fake team module.
return function(t)
  local TeamStart = require("ade.app.team_start")

  local function base_cwd(tag)
    local dir = string.format("/tmp/opencode/ade-w0e-%s-%d", tag, vim.uv.os_getpid())
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  local function harness(t, opts)
    opts = opts or {}
    local cwd = base_cwd(opts.tag or "flow")
    local session = {
      id = "s1",
      cwd = cwd,
      instance = "i1",
      blocks = {
        { kind = "user", text = "fix the parser" },
        { kind = "assistant", text = "the parser is in lua/parser.lua" },
      },
    }
    local all = { s1 = session, s9 = { id = "s9", cwd = cwd, blocks = {} } }
    local states = { ["i1\0s1"] = { enabled = opts.enabled ~= false, injected = true } }
    local calls = { starts = {}, enables = {}, leaders = {}, news = 0, submitted = {} }
    local workflows = opts.workflows
      or {
        { name = "default", summary = "the built-in flow", team = {} },
        { name = "dev", summary = "two workers", team = {} },
      }
    local fake_team = {
      available = function()
        return true
      end,
    }
    function fake_team:workflows(_, cb)
      cb(true, { workflows = vim.deepcopy(workflows) })
    end
    function fake_team:session_teams(instance, id)
      return states[tostring(instance) .. "\0" .. tostring(id)]
    end
    function fake_team:query_session_teams(instance, id, _, cb)
      local key = tostring(instance) .. "\0" .. tostring(id)
      local state = states[key]
      if not state then
        -- A session the front end has not seen yet: the service answers with
        -- its stored switch (here: the configured default).
        state = { enabled = opts.enabled ~= false, injected = true }
        states[key] = state
      end
      cb(true, state)
    end
    function fake_team:set_session_teams(instance, id, enabled, close, cb)
      calls.enables[#calls.enables + 1] = { instance = instance, id = id, enabled = enabled, close = close }
      local state = states[tostring(instance) .. "\0" .. tostring(id)] or {}
      if enabled == false and state.leader and not close and opts.leads_team then
        cb(false, { code = -32061, data = { reason = "leads_team" } })
        return
      end
      if enabled == true and opts.reload_unsupported and state.injected == false then
        cb(false, { code = -32061, data = { reason = "reload_unsupported" } })
        return
      end
      if enabled == true and opts.reload and state.injected == false then
        state.enabled = true
        states[tostring(instance) .. "\0" .. tostring(id)] = state
        cb(true, { enabled = true, injected = false, reload = true })
        return
      end
      state.enabled = enabled
      state.injected = true
      states[tostring(instance) .. "\0" .. tostring(id)] = state
      cb(true, state)
    end
    function fake_team:start_session(instance, id, workflow, task, cb)
      calls.starts[#calls.starts + 1] = { instance = instance, id = id, workflow = workflow, task = task }
      if opts.start_off_once and #calls.starts == 1 then
        -- Another front end switched the session off while the task prompt was
        -- open: the first start is refused structurally.
        cb(false, { code = -32061, data = { reason = "off" } })
        return
      end
      if opts.led_by and #calls.starts == 1 then
        cb(
          false,
          { code = -32061, data = { reason = "led_by", team = "t9", leader = { instance = "i2", sessionId = "s9" } } }
        )
        return
      end
      cb(true, { workflow = workflow })
    end
    function fake_team:set_leader(team, instance, id, cb)
      calls.leaders[#calls.leaders + 1] = { team = team, instance = instance, id = id }
      cb(true, {})
    end
    function fake_team:team_for_cwd()
      return nil
    end
    function fake_team:reload_session(instance, id, cb)
      calls.reloads = calls.reloads or {}
      calls.reloads[#calls.reloads + 1] = { instance = instance, id = id }
      if opts.reload_fails then
        cb(false, "the agent refused the load")
        return
      end
      local state = states[tostring(instance) .. "\0" .. tostring(id)] or {}
      state.enabled = true
      state.injected = true
      states[tostring(instance) .. "\0" .. tostring(id)] = state
      cb(true, { reloaded = true })
    end

    local choices = { asks = {} }
    function choices:ask(o)
      self.asks[#self.asks + 1] = o
      if opts.answer then
        o.on_choice(opts.answer)
      end
      return true
    end

    local S = {
      view = { team = fake_team },
      sess = { current = session, all = all },
    }
    local flow = TeamStart.new({
      state = function()
        return S
      end,
      config = function()
        return {
          backend = "service",
          teams = { enabled = true, default = "default", session_default = opts.session_default },
          cwd = cwd,
        }
      end,
      notify = function() end,
      resolve_cwd = function()
        return cwd
      end,
      open = function() end,
      new_session = function(o)
        calls.news = calls.news + 1
        if opts.new_session_fails == true then
          if o and o.on_failed then
            o.on_failed("the agent refused")
          end
          return
        end
        local new = { id = "s2", cwd = cwd, blocks = {}, instance = "i1" }
        all.s2 = new
        S.sess.current = new
        if o and o.on_created then
          o.on_created(new)
        end
      end,
      connect = function() end,
      pick_agent = function() end,
      options = function()
        return opts.options
      end,
      canonical_session = opts.canonical_session,
      client = function()
        return { proc = { instance = "i1" } }
      end,
      generation = function()
        return 0
      end,
      report_error = function(value)
        return type(value) == "table" and tostring(value.message or value.code) or tostring(value)
      end,
      choices = function()
        return choices
      end,
      find_session = function(id)
        return all[id]
      end,
      select_session = function(target)
        calls.selected = target and target.id
      end,
      submit = function(text, session)
        calls.submitted[#calls.submitted + 1] = text
        calls.submitted_to = session and session.id or nil
      end,
    })
    return { flow = flow, calls = calls, states = states, choices = choices, all = all, cwd = cwd, session = session }
  end

  local function stub_ui(t, opts)
    local original_select = vim.ui.select
    local original_input = vim.ui.input
    local picked = {}
    local asked = {}
    vim.ui.select = function(items, _, cb)
      picked[#picked + 1] = vim.deepcopy(items)
      local want = opts.select
      if type(want) == "function" then
        cb(want(items))
        return
      end
      cb(items[1])
    end
    vim.ui.input = function(_, cb)
      asked[#asked + 1] = true
      cb(opts.task)
    end
    t.cleanup(function()
      vim.ui.select = original_select
      vim.ui.input = original_input
    end)
    return { picked = picked, asked = asked }
  end

  local function wait_idle(flow)
    local ok = vim.wait(5000, function()
      return flow.starting == false
    end, 20)
    if not ok then
      error("the flow did not finish", 2)
    end
  end

  t.describe("W0e v3 start flow", function()
    t.it("offers workflows with the default first and starts the current session", function()
      local h = harness(t, { tag = "default", task = "write it" })
      local ui = stub_ui(t, { task = "write it" })
      h.flow:start(nil)
      wait_idle(h.flow)
      t.eq("default", ui.picked[1][1], "the default workflow is offered first")
      t.eq(0, h.calls.news, "no session is created")
      t.eq(1, #h.calls.starts)
      t.eq("s1", h.calls.starts[1].id)
      t.eq("default", h.calls.starts[1].workflow)
      t.eq("write it", h.calls.starts[1].task)
    end)

    t.it("enables the session switch before starting when it is off", function()
      local h = harness(t, { tag = "off", enabled = false })
      stub_ui(t, { task = "" })
      h.flow:start("dev")
      wait_idle(h.flow)
      t.eq(1, #h.calls.enables)
      t.eq(true, h.calls.enables[1].enabled)
      t.eq(1, #h.calls.starts)
      t.eq("s1", h.calls.starts[1].id)
    end)

    t.it("opens a replacement session on reload_unsupported and hands over a summary", function()
      local h = harness(t, { tag = "reload", reload_unsupported = true })
      h.states["i1\0s1"] = { enabled = true, injected = false }
      stub_ui(t, {
        task = "",
        select = function(items)
          return items[1]
        end,
      })
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq(1, h.calls.news)
      t.eq("s2", h.calls.starts[1].id)
      t.truthy(h.calls.submitted[1] and h.calls.submitted[1]:match("fix the parser"), "the summary goes first")
      t.eq("s2", h.calls.submitted_to, "the summary is addressed to the replacement session")
    end)

    t.it("runs the normal load when the service answers reload: true", function()
      local h = harness(t, { tag = "reload-true", reload = true })
      h.states["i1\0s1"] = { enabled = true, injected = false }
      stub_ui(t, { task = "" })
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq(0, h.calls.news, "no replacement session: the load is in place")
      t.eq(1, #(h.calls.reloads or {}))
      t.eq("s1", h.calls.reloads[1].id)
      t.eq(1, #h.calls.starts)
      t.eq("s1", h.calls.starts[1].id)
    end)

    t.it("stops when the in-place reload fails", function()
      local h = harness(t, { tag = "reload-broken", reload = true, reload_fails = true })
      h.states["i1\0s1"] = { enabled = true, injected = false }
      stub_ui(t, { task = "" })
      local notices = {}
      h.flow.deps.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq(1, #(h.calls.reloads or {}))
      t.eq(0, #h.calls.starts, "no start after a failed reload")
      t.truthy(table.concat(notices, "\n"):match("reload"))
    end)

    t.it("ends the flow when the replacement session cannot be created", function()
      local h = harness(t, { tag = "reload-fails", reload_unsupported = true, new_session_fails = true })
      h.states["i1\0s1"] = { enabled = true, injected = false }
      stub_ui(t, {
        task = "",
        select = function(items)
          return items[1]
        end,
      })
      local notices = {}
      h.flow.deps.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq(0, #h.calls.starts, "no start after a failed replacement")
      t.truthy(table.concat(notices, "\n"):match("replacement session"))
    end)

    t.it("summarises agent replies as well as the person's", function()
      local h = harness(t, { tag = "summary-agent" })
      local summary = h.flow:summary({
        blocks = {
          { kind = "user", text = "do it" },
          { kind = "agent", text = "done it" },
          { kind = "assistant", text = "older reply" },
        },
      })
      t.truthy(summary:match("done it"))
      t.truthy(summary:match("older reply"))
    end)

    t.it("refuses to promise a replacement session when new sessions start with teams off", function()
      local h = harness(t, {
        tag = "default-off",
        reload_unsupported = true,
        session_default = false,
      })
      h.states["i1\0s1"] = { enabled = true, injected = false }
      stub_ui(t, {
        task = "",
        select = function(items)
          return items[1]
        end,
      })
      local notices = {}
      h.flow.deps.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq(0, h.calls.news, "no replacement session is created")
      t.eq(0, #h.calls.starts)
      local text = table.concat(notices, "\n")
      t.truthy(text:match("session_default"))
      t.truthy(text:match("cannot reload"))
    end)

    t.it("reloads before retrying a start refused with off", function()
      local h = harness(t, { tag = "off-retry", start_off_once = true, enabled = true })
      stub_ui(t, { task = "" })
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq(2, #h.calls.starts, "the refused start is retried once")
      t.eq(1, #h.calls.enables, "the retry enables the session first")
      t.eq(true, h.calls.enables[1].enabled)
    end)

    t.it("reports the model switch applied to the start target", function()
      local applied = {}
      local options = {
        set_for = function(self, control, value, client, generation, session, cb)
          applied[#applied + 1] = { value = value, session = session.id, client = client, generation = generation }
          if cb then
            cb(true, nil)
          end
          return true
        end,
      }
      local notices = {}
      local h = harness(t, {
        tag = "model-target",
        options = options,
        workflows = {
          {
            name = "default",
            summary = "flow",
            leader = { model = "big" },
            team = {},
          },
        },
        canonical_session = function(instance, id)
          return h_all_target
        end,
      })
      local h_all_target -- defined below for the closure above
      local controls = { model = { id = "model", options = { { value = "big" } } } }
      local target = { id = "s1", instance = "i1", controls = controls }
      h_all_target = target
      h.session.controls = controls
      h.flow.deps.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      stub_ui(t, { task = "" })
      h.flow:start("default")
      wait_idle(h.flow)
      vim.wait(500, function()
        return #applied > 0
      end, 20)
      t.eq(1, #applied, "the workflow model is written once")
      t.eq("s1", applied[1].session)
      t.eq("big", applied[1].value)
      local text = table.concat(notices, "\n")
      t.truthy(text:match("switched"))
      t.falsy(text:match("could not"))
    end)

    t.it("does not claim a model switch that failed", function()
      local options = {
        set_for = function(_, _, _, _, _, _, cb)
          if cb then
            cb(false, "the agent refused")
          end
          return true
        end,
      }
      local notices = {}
      local h = harness(t, {
        tag = "model-fails",
        options = options,
        workflows = {
          { name = "default", summary = "flow", leader = { model = "big" }, team = {} },
        },
      })
      h.session.controls = { model = { id = "model", options = { { value = "big" } } } }
      h.flow.deps.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      stub_ui(t, { task = "" })
      h.flow:start("default")
      wait_idle(h.flow)
      vim.wait(500, function()
        return table.concat(notices, "\n"):match("could not switch") ~= nil
      end, 20)
      local text = table.concat(notices, "\n")
      t.truthy(text:match("could not switch"))
      t.falsy(text:match("switched to big."))
    end)

    t.it("turns a led_by error into a choice and retries after the move", function()
      local h = harness(t, { tag = "led", led_by = true, answer = "move" })
      stub_ui(t, { task = "" })
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq(1, #h.choices.asks)
      local labels = {}
      for _, item in ipairs(h.choices.asks[1].options) do
        labels[#labels + 1] = item.label
      end
      t.truthy(table.concat(labels, "|"):match("移交"))
      t.eq(1, #h.calls.leaders)
      t.eq("t9", h.calls.leaders[1].team)
      t.eq(2, #h.calls.starts, "the start is retried after taking over")
    end)

    t.it("can jump to the leader session instead", function()
      local h = harness(t, { tag = "jump", led_by = true, answer = "jump" })
      stub_ui(t, { task = "" })
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq("s9", h.calls.selected)
      t.eq(0, #h.calls.leaders)
      t.eq(1, #h.calls.starts, "jumping does not retry here")
    end)

    t.it("reports an unknown workflow without asking for a task", function()
      local h = harness(t, { tag = "unknown" })
      local ui = stub_ui(t, { task = "" })
      h.flow:start("nope")
      wait_idle(h.flow)
      t.eq(0, #ui.asked)
      t.eq(0, #h.calls.starts)
    end)

    t.it("starts in an explicitly passed session, not the current one", function()
      local h = harness(t, { tag = "selected" })
      stub_ui(t, { task = "" })
      local target = { id = "s3", cwd = h.cwd, instance = "i1", blocks = {} }
      h.all.s3 = target
      h.flow:start("default", target)
      wait_idle(h.flow)
      t.eq("s3", h.calls.starts[1].id, "the passed session is the start target")
    end)

    t.it("refuses a target session whose instance is not the live one", function()
      local h = harness(t, { tag = "foreign-instance" })
      stub_ui(t, { task = "" })
      local target = { id = "s4", cwd = h.cwd, instance = "i-other", blocks = {} }
      h.all.s4 = target
      local notices = {}
      h.flow.deps.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      h.flow:start("default", target)
      t.eq(0, #h.calls.starts)
      t.truthy(table.concat(notices, "\n"):match("instance"))
    end)
  end)
end
