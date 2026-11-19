return function(t)
  local ade = require("ade")
  local controller = require("ade.controller")
  local picker = require("ade.ui.picker")
  local state = require("ade.session.state")
  local agents = require("ade.agents")
  local Options = require("ade.app.options")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local mock = root .. "tests/mock_agent.py"

  local function setup(profile, extra)
    ade.setup(vim.tbl_deep_extend("force", {
      agent = profile,
      agents = {
        [profile] = {
          command = "python3",
          args = { mock },
          env = { ACP_MOCK_PROFILE = profile },
          profile = profile,
        },
      },
      permissions = { prompt = "native" },
    }, extra or {}))
    controller.open()
    local S = controller.state()
    vim.wait(8000, function()
      return S.sess.current ~= nil
    end, 20)
    return S
  end

  ---Replace the picker for one call and return what it was given.
  local function capture(fn)
    local captured
    local original = picker.select
    picker.select = function(opts)
      captured = opts
    end
    local ok, err = pcall(fn)
    picker.select = original
    if not ok then
      error(err, 0)
    end
    return captured
  end

  ---A minimal session whose only control source is legacy `modes`.
  local function modes_only_session()
    local s = state.new("s", "/tmp")
    s.profile = agents.get({ profile = "generic" })
    s:configure({
      modes = {
        currentModeId = "ask",
        availableModes = { { id = "ask", name = "Ask" }, { id = "code", name = "Code" } },
      },
    })
    return s
  end

  ---An Options instance wired to a stub client that records RPC calls.
  local function stub_options(session, calls)
    local client = {
      set_mode = function(_, session_id, mode_id)
        calls[#calls + 1] = { method = "set_mode", session_id = session_id, value = mode_id }
        return true, {}
      end,
      set_config_option = function(_, session_id, config_id, value)
        calls[#calls + 1] = { method = "set_config_option", session_id = session_id, id = config_id, value = value }
        return true, {}
      end,
    }
    return Options.new({
      config = function()
        return { ui = { icons = true } }
      end,
      current = function()
        return session
      end,
      client = function()
        return client
      end,
      generation = function()
        return 0
      end,
      ui_current = function()
        return true
      end,
      run = function(key, client_arg, s, fn, _, finally)
        local task = {
          check = function() end,
          call = function(_, method, ...)
            return client_arg[method](client_arg, ...)
          end,
          status = "running",
        }
        fn(task)
        if finally then
          finally()
        end
        return task
      end,
      on_changed = function() end,
      notify = function() end,
    })
  end

  t.describe("controller session controls", function()
    t.it("serializes mode and model writes with the newest control snapshot", function()
      local session, calls = state.new("s", "/tmp"), {}
      local function payload(mode, model)
        return {
          configOptions = {
            {
              id = "mode",
              category = "mode",
              type = "select",
              currentValue = mode,
              options = { { value = "plan" }, { value = "build" } },
            },
            {
              id = "model",
              category = "model",
              type = "select",
              currentValue = model,
              options = { { value = "one" }, { value = "two" } },
            },
          },
        }
      end
      session:configure(payload("plan", "one"))
      local options = stub_options(session, {})
      options.run = function(_, _, _, fn, _, finally)
        calls[#calls + 1] = function(response)
          fn({
            call = function()
              return true, response
            end,
          })
          finally()
        end
      end
      options:cycle_mode()
      local old_model = session.controls.model
      options:apply(old_model, "two", options.get_client(), options.generation(), session)
      t.eq(1, #calls)
      calls[1](payload("build", "one"))
      t.eq(2, #calls)
      t.truthy(old_model ~= session.controls.model)
      calls[2]() -- an acknowledgement without a snapshot updates the fresh control
      t.eq("build", session.controls.mode.current)
      t.eq("two", session.controls.model.current)
    end)

    t.it("skips bypass and full-access modes when cycling but leaves them in the picker", function()
      local session = modes_only_session()
      table.insert(session.modes.availableModes, 2, { id = "bypassPermissions" })
      table.insert(session.modes.availableModes, 3, { id = "unrestricted", _meta = { kind = "full_access" } })
      session:refresh_controls()
      local calls = {}
      local options = stub_options(session, calls)
      options:cycle_mode()
      t.eq("code", session.controls.mode.current)

      local picker = capture(function()
        options:pick_mode()
      end)
      t.eq("bypassPermissions", picker.items[2].value)
      t.eq("unrestricted", picker.items[3].value)
      picker.on_choice(picker.items[2].value)
      t.eq("bypassPermissions", session.controls.mode.current)

      table.remove(session.modes.availableModes, 4) -- only one safe mode remains
      session:refresh_controls()
      options:cycle_mode()
      t.eq("ask", session.controls.mode.current)
      options:cycle_mode()
      t.eq(3, #calls, "do not resend the current mode")
    end)

    t.it("binds Shift-Tab to change the current Claude mode without a picker", function()
      local S = setup("claude")
      local session = S.sess.current
      local sent = {}
      S.conn.client.set_config_option = function(_, session_id, config_id, value)
        sent[#sent + 1] = { session_id, config_id, value }
        local payload = vim.deepcopy(session.config_options)
        for _, option in ipairs(payload) do
          if option.id == config_id then
            option.currentValue = value
          end
        end
        return true, { configOptions = payload }
      end
      for _, mode in ipairs({ "n", "i" }) do
        local found
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(S.view.input.buf, mode)) do
          if map.desc == "ade: cycle mode" then
            found = map
            break
          end
        end
        t.truthy(found)
        t.eq(vim.keycode("<S-Tab>"), vim.keycode(found.lhs))
        local expected = mode == "n" and "acceptEdits" or "plan"
        t.eq(nil, capture(found.callback))
        t.truthy(vim.wait(3000, function()
          return session.controls.mode.current == expected
        end))
      end
      t.eq({ { session.id, "mode", "acceptEdits" }, { session.id, "mode", "plan" } }, sent)
      controller.hide()
    end)

    t.it("cycles through work modes in agent order and wraps without opening a picker", function()
      local session, calls = modes_only_session(), {}
      local options = stub_options(session, calls)
      t.eq(
        nil,
        capture(function()
          options:cycle_mode()
        end)
      )
      t.eq("code", session.controls.mode.current)
      options:cycle_mode()
      t.eq("ask", session.controls.mode.current)
      t.eq({
        { method = "set_mode", session_id = "s", value = "code" },
        { method = "set_mode", session_id = "s", value = "ask" },
      }, calls)
    end)

    t.it("groups models using ACP groups or model prefixes and retains their original IDs", function()
      local session, calls = state.new("s", "/tmp"), {}
      session:configure({
        configOptions = {
          {
            id = "model",
            category = "model",
            type = "select",
            currentValue = "one",
            options = {
              { value = "one", name = "github-copilot/One" },
              { group = "anthropic", name = "Anthropic", options = { { value = "two", name = "Two" } } },
              { value = "github-copilot/three", name = "Three" },
              { group = "github-copilot", name = "GitHub Copilot", options = { { value = "four", name = "Four" } } },
              { value = "unknown", name = "Unknown" },
            },
          },
        },
      })
      local options = stub_options(session, calls)
      local picker = capture(function()
        options:pick_model()
      end)
      local ids = {}
      for i, item in ipairs(picker.items) do
        ids[i] = item.value
      end
      t.eq({ "one", "github-copilot/three", "four", "two", "unknown" }, ids)
      for i, label in ipairs({ "GitHub Copilot /", "GitHub Copilot /", "GitHub Copilot /", "Anthropic /", "Other /" }) do
        t.truthy(picker.items[i].label:find(label, 1, true))
      end
      picker.on_choice(picker.items[2].value)
      t.eq("github-copilot/three", calls[1].value)
    end)

    t.it("switches pi thinking levels through set_config_option", function()
      local S = setup("pi")
      t.truthy(S.sess.current.controls.model)
      t.truthy(S.sess.current.controls.thinking)
      t.eq(nil, S.sess.current.controls.mode, "pi modes are a duplicate of thought_level")

      local sent = {}
      local original = S.conn.client.set_config_option
      S.conn.client.set_config_option = function(_, session_id, config_id, value)
        sent[#sent + 1] = { id = config_id, value = value }
        return true, {}
      end
      local captured = capture(ade.pick_thinking)
      t.truthy(captured, "no thinking picker")
      local clicked = capture(_G.AdePickThinking)
      t.eq(captured.items, clicked.items)
      local map
      for _, candidate in ipairs(vim.api.nvim_buf_get_keymap(S.view.input.buf, "n")) do
        if candidate.lhs == "gT" then
          map = candidate.callback
        end
      end
      t.truthy(map, "no buffer-local thinking binding")
      t.eq(captured.items, capture(map).items)
      local choice = captured.items[#captured.items].value
      captured.on_choice(choice)
      vim.wait(500)
      t.eq("thinking", sent[1].id)
      t.eq(choice, S.sess.current.controls.thinking.current)
      S.conn.client.set_config_option = original
      controller.hide()
    end)

    t.it("uses the configured Claude mode icon without replacing its picker label", function()
      setup("claude", { ui = { icon_overrides = { modes = { claude = { acceptEdits = "EDIT" } } } } })
      local captured = capture(ade.pick_mode)
      for _, item in ipairs(captured.items) do
        if item.value == "acceptEdits" then
          t.match("EDIT Accept edits", item.label)
          controller.hide()
          return
        end
      end
      error("Claude's acceptEdits mode was missing")
    end)

    t.it("refuses a work-mode picker when the agent has no work mode", function()
      local S = setup("pi")
      local captured = capture(function()
        controller.pick_mode()
      end)
      t.eq(nil, captured, "pi must not offer its thinking levels as a work mode")
      controller.hide()
    end)

    t.it("toggles a boolean extra instead of opening a picker", function()
      local S = setup("claude")
      local extra
      for _, control in ipairs(S.sess.current.controls.extras) do
        if control.id == "fast" then
          extra = control
        end
      end
      t.truthy(extra, "the boolean config option is missing")

      local sent = {}
      local original = S.conn.client.set_config_option
      S.conn.client.set_config_option = function(_, session_id, config_id, value)
        sent[#sent + 1] = { id = config_id, value = value }
        return true, {}
      end
      local captured = capture(function()
        S.view.options:toggle(extra, S.conn.client, S.view.options.generation(), S.sess.current)
      end)
      vim.wait(500)
      t.eq(nil, captured, "a boolean must not open a second picker")
      t.eq("fast", sent[1].id)
      t.eq(true, sent[1].value)
      S.conn.client.set_config_option = original
      controller.hide()
    end)

    t.it("lists every control in :Ade config", function()
      local S = setup("claude")
      local captured = capture(function()
        controller.pick_config()
      end)
      t.truthy(captured)
      local labels = {}
      for _, item in ipairs(captured.items) do
        labels[#labels + 1] = item.label
      end
      local joined = table.concat(labels, "\n")
      t.match("Model", joined)
      t.match("Mode", joined)
      t.match("Fast mode", joined)
      controller.hide()
    end)

    t.it("uses set_mode when modes are the only source", function()
      local session = modes_only_session()
      local calls = {}
      local options = stub_options(session, calls)
      t.truthy(session.controls.mode)
      t.eq("modes", session.controls.mode.source)
      options:apply(session.controls.mode, "code", options.get_client(), options.generation(), session)
      t.eq("set_mode", calls[1].method)
      t.eq("code", calls[1].value)
      t.eq("code", session.current_mode)
      t.eq("code", session.controls.mode.current)
    end)

    t.it("uses set_config_option when configOptions are the source", function()
      local session = state.new("s", "/tmp")
      session.profile = agents.get({ profile = "opencode" })
      session:configure({
        configOptions = {
          {
            id = "model",
            category = "model",
            type = "select",
            currentValue = "m1",
            options = { { value = "m1", name = "One" }, { value = "m2", name = "Two" } },
          },
        },
      })
      local calls = {}
      local options = stub_options(session, calls)
      options:apply(session.controls.model, "m2", options.get_client(), options.generation(), session)
      t.eq("set_config_option", calls[1].method)
      t.eq("model", calls[1].id)
      t.eq("m2", calls[1].value)
      t.eq("m2", session.controls.model.current)
    end)

    t.it("switches agents and keeps session metadata separate", function()
      local S = setup("opencode")
      local opts = vim.deepcopy(S.config)
      opts.agents.claude = {
        command = "python3",
        args = { mock },
        env = { ACP_MOCK_PROFILE = "claude" },
        profile = "claude",
      }
      controller.setup(opts, { discard_queued = true })
      controller.pick_agent("claude")
      local S2 = controller.state()
      vim.wait(10000, function()
        return S2.session ~= nil
      end, 20)
      t.eq("claude", S2.config.agent)
      t.truthy(S2.session, "the new agent did not create a session")
      t.truthy(S2.session.controls.mode)

      controller.pick_agent("opencode")
      local S3 = controller.state()
      vim.wait(10000, function()
        return S3.session ~= nil
      end, 20)
      t.eq("opencode", S3.config.agent)
      controller.hide()
    end)
    t.it("warns about dropped work when switching agents", function()
      local S = setup("opencode")
      -- Register the second agent before the turn so the switch is the only
      -- thing that tears the session down.
      local opts = vim.deepcopy(S.config)
      opts.agents.claude = {
        command = "python3",
        args = { mock },
        env = { ACP_MOCK_PROFILE = "claude" },
        profile = "claude",
      }
      S.config = opts
      controller.submit("slow", {})
      vim.wait(2000, function()
        local now = controller.state().session
        return now ~= nil and now.status == "running"
      end, 20)
      t.truthy(controller.state().session and controller.state().session.status ~= "idle", "no running turn")

      local notices = {}
      local original = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      local ok, err = pcall(controller.pick_agent, "claude")
      vim.notify = original
      t.truthy(ok, tostring(err))
      local warned
      for _, notice in ipairs(notices) do
        if notice.message:find("dropped", 1, true) then
          warned = notice.message
        end
      end
      t.truthy(warned, "switching agents dropped a running turn without a warning")
      t.match("interrupted 1 running turn", warned)
      controller.hide()
    end)
  end)
end
