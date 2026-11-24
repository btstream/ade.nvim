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
      cb(true, states[tostring(instance) .. "\0" .. tostring(id)])
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
      state.enabled = enabled
      state.injected = true
      states[tostring(instance) .. "\0" .. tostring(id)] = state
      cb(true, state)
    end
    function fake_team:start_session(instance, id, workflow, task, cb)
      calls.starts[#calls.starts + 1] = { instance = instance, id = id, workflow = workflow, task = task }
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
          teams = { enabled = true, default = "default" },
          cwd = cwd,
        }
      end,
      notify = function() end,
      resolve_cwd = function()
        return cwd
      end,
      open = function() end,
      new_session = function()
        calls.news = calls.news + 1
        local new = { id = "s2", cwd = cwd, blocks = {} }
        all.s2 = new
        S.sess.current = new
        -- Mirror the front end: the service reports the new session, which
        -- resumes a pending handover.
        vim.schedule(function()
          if opts.new_session_fails ~= true then
            TeamStart.session_opened("i1", "s2", cwd)
          end
        end)
      end,
      connect = function() end,
      pick_agent = function() end,
      options = function()
        return nil
      end,
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
      submit = function(text)
        calls.submitted[#calls.submitted + 1] = text
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

    t.it("starts on the session the tree selected", function()
      local h = harness(t, { tag = "selected" })
      stub_ui(t, { task = "" })
      h.flow:start("default")
      wait_idle(h.flow)
      t.eq("s1", h.calls.starts[1].id)
    end)
  end)
end
