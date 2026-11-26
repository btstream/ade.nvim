-- Cross-agent session manager (docs/session-manager.md, PROTOCOL.md 21).
--
-- Three layers are covered: the app module's catalog/refresh/load decisions
-- (with a fake connection and a fake window), the window itself (header,
-- sorting, filtering and keys) and a real service backend run through
-- `tests/fake_service.lua`, including the one-shot pending load.
return function(t)
  local SessionManager = require("ade.app.session_manager")
  local ui = require("ade.ui.session_manager")
  local picker = require("ade.ui.picker")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0
  local original_cwd = vim.fn.getcwd()

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-sm-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  local function config(agents, extra)
    return vim.tbl_extend("force", {
      agent = "alpha",
      backend = "service",
      ui = { icons = true },
      agents = agents,
      launch_origin = {},
    }, extra or {})
  end

  local function fake_connection(opts)
    opts = opts or {}
    local connection = {
      requests = {},
      listeners = {},
      features = opts.features or { sessions = true },
      ensure_ok = opts.ensure_ok ~= false,
    }
    function connection:ensure(cb)
      cb(self.ensure_ok, self.ensure_ok and nil or "the service is unavailable")
    end
    function connection:has_feature(name)
      return self.features[name] == true
    end
    function connection:subscribe(channel, method, fn)
      self.listeners[method] = fn
      self.channel = channel
    end
    function connection:unsubscribe(channel, method)
      self.listeners[method] = nil
      self.unsubscribed = { channel = channel, method = method }
    end
    function connection:on_hello(channel, fn)
      self.hello = { channel = channel, fn = fn }
    end
    function connection:request(method, params, cb)
      self.requests[#self.requests + 1] = { method = method, params = params, cb = cb }
    end
    function connection:reply(method, ok, value)
      for index = #self.requests, 1, -1 do
        local request = self.requests[index]
        if request.method == method and not request.replied then
          request.replied = true
          request.cb(ok, value)
          return true
        end
      end
      return false
    end
    function connection:updated(payload)
      local fn = self.listeners["sessions.updated"]
      if fn then
        fn(payload)
      end
    end
    return connection
  end

  local function fake_ui()
    local handles = {}
    local module = {
      open = function(view)
        local handle = { view = view, updates = { view } }
        function handle:update(next_view)
          if next_view then
            self.view = next_view
            self.updates[#self.updates + 1] = next_view
          end
        end
        function handle:set_busy(value)
          self.busy = value == true
        end
        function handle:close()
          self.closed = true
        end
        function handle:is_open()
          return self.closed ~= true
        end
        handles[#handles + 1] = handle
        return handle
      end,
    }
    return module, handles
  end

  local function manager(opts)
    local connection = opts.connection or fake_connection()
    local ui_module, handles = fake_ui()
    local calls = {
      notifications = {},
      presenter = {},
      setups = {},
      opened = 0,
      picked = 0,
      loads = {},
    }
    local state = {
      config = opts.cfg,
      conn = {
        phase = opts.phase or "ready",
        client = opts.client,
        service = {
          service_connection = function()
            return connection
          end,
        },
        flow = opts.flow,
      },
      sess = {
        current = opts.current,
        catalog = opts.catalog,
        service = {
          load = function(_, id, load_opts)
            calls.loads[#calls.loads + 1] = { id = id, opts = load_opts }
          end,
        },
      },
    }
    local instance = SessionManager.new({
      state = function()
        return state
      end,
      config = function()
        return opts.cfg
      end,
      notify = function(message, level)
        calls.notifications[#calls.notifications + 1] = { message = message, level = level }
      end,
      setup = function(next_opts, action)
        calls.setups[#calls.setups + 1] = { opts = next_opts, action = action }
      end,
      open = function()
        calls.opened = calls.opened + 1
      end,
      pick_session = function()
        calls.picked = calls.picked + 1
      end,
      resolve_cwd = function()
        return opts.cwd or original_cwd
      end,
      presenter = {
        select = function(select_opts)
          calls.presenter[#calls.presenter + 1] = select_opts
        end,
      },
      ui = ui_module,
      executable = opts.executable or function(command)
        return command ~= "missing-binary"
      end,
    })
    local ctx = {
      state = state,
      connection = connection,
      ui_module = ui_module,
      handles = handles,
      calls = calls,
    }
    setmetatable(ctx, {
      __index = function(_, key)
        if key == "ui" then
          return handles[#handles]
        end
      end,
    })
    if opts.preopen then
      instance.ui = ui_module.open(instance:view())
    end
    return instance, ctx
  end

  local function has_line(lines, needle)
    for _, line in ipairs(lines) do
      if line:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  local function line_index(lines, needle)
    for index, line in ipairs(lines) do
      if line:find(needle, 1, true) then
        return index
      end
    end
    return nil
  end

  local function close_manager_windows()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "ade_session_manager" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  t.describe("session manager catalog", function()
    t.it("shows cached rows before the refresh finishes", function()
      local dir = tmpdir("cache")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      instance:open()
      t.eq(2, #ctx.connection.requests)
      t.eq("sessions.cached", ctx.connection.requests[1].method)
      t.eq("sessions.refresh", ctx.connection.requests[2].method)
      t.truthy(ctx.ui, "the window must open before any reply")
      t.eq(0, #ctx.ui.view.entries)

      local cwd = dir
      ctx.connection:reply("sessions.cached", true, {
        sessions = {
          { agent = "alpha", sessionId = "a1", cwd = cwd, title = "Cached one" },
          { agent = "ghost", sessionId = "g1", cwd = cwd, title = "Removed agent" },
        },
        agents = { alpha = { listed_at = 10 } },
      })
      t.eq(1, #ctx.ui.view.entries, "only configured agents may be shown")
      t.eq("Cached one", ctx.ui.view.entries[1].title)
      t.truthy(ctx.ui.view.refreshing.alpha, "the header must say the agent is refreshing")

      ctx.connection:updated({
        agent = "alpha",
        sessions = { { agent = "alpha", sessionId = "a2", cwd = cwd, title = "Fresh one" } },
      })
      t.eq(1, #ctx.ui.view.entries)
      t.eq("Fresh one", ctx.ui.view.entries[1].title, "sessions.updated must replace the agent's rows")
      t.eq(nil, ctx.ui.view.refreshing.alpha)

      ctx.connection:reply("sessions.refresh", true, { agents = { alpha = { ok = true, count = 1 } } })
      t.eq(nil, ctx.ui.view.status)
    end)

    t.it("keeps a refresh that lands before the cache reply", function()
      local dir = tmpdir("race")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      instance:open()
      ctx.connection:updated({
        agent = "alpha",
        sessions = { { agent = "alpha", sessionId = "a2", cwd = dir, title = "Fresh one" } },
      })
      ctx.connection:reply("sessions.cached", true, {
        sessions = { { agent = "alpha", sessionId = "a1", cwd = dir, title = "Stale one" } },
        agents = { alpha = { listed_at = 1 } },
      })
      t.eq(1, #ctx.ui.view.entries)
      t.eq("Fresh one", ctx.ui.view.entries[1].title, "the stale cache must not win")
    end)

    t.it("keeps cached rows and shows the error when an agent fails", function()
      local dir = tmpdir("failed")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        cwd = dir,
      })
      instance:open()
      ctx.connection:reply("sessions.cached", true, {
        sessions = {
          { agent = "alpha", sessionId = "a1", cwd = dir, title = "Old alpha" },
          { agent = "beta", sessionId = "b1", cwd = dir, title = "Old beta" },
        },
        agents = {},
      })
      ctx.connection:updated({ agent = "beta", error = { code = -32070, message = "auth required" } })
      t.eq(2, #ctx.ui.view.entries, "a failed agent keeps its cached rows")
      t.eq("Old beta", ctx.ui.view.entries[2].title)
      t.eq("auth required", ctx.ui.view.agent_state.beta.error.message)
      t.eq(nil, ctx.ui.view.refreshing.beta)
    end)

    t.it("sends each available launch and marks missing ones unavailable", function()
      local dir = tmpdir("params")
      local instance, ctx = manager({
        cfg = config({
          alpha = { command = "alpha-acp", args = { "--serve" }, env = { ALPHA = "1" } },
          beta = { command = "missing-binary" },
        }),
        cwd = dir,
      })
      instance:open()
      local params = ctx.connection.requests[2].params.agents
      t.eq(1, #params)
      t.eq("alpha", params[1].agent)
      t.eq("alpha-acp", params[1].command)
      t.eq({ "--serve" }, params[1].args)
      t.eq(dir, params[1].cwd)
      t.eq("1", params[1].env.ALPHA, "the complete environment must carry the agent env")
      t.eq("string", type(params[1].env.PATH), "the child environment is inherited")
      t.eq("not found: missing-binary", ctx.ui.view.unavailable.beta)
      t.eq(nil, params[1].launch, "an external launch carries no managed lease")
    end)

    t.it("falls back to this agent's browser without the sessions feature", function()
      local cfg = config({ alpha = { command = "alpha-acp" } })
      local instance, ctx = manager({
        cfg = cfg,
        connection = fake_connection({ features = {} }),
      })
      instance:open()
      instance:open()
      t.eq(2, ctx.calls.picked, "every invocation falls back to the picker")
      t.eq(1, #ctx.calls.notifications, "the notice is shown once per configuration")
      t.match("needs the ade service", ctx.calls.notifications[1].message)
      t.eq(nil, ctx.ui)
    end)

    t.it("falls back on a direct backend and on an unreachable service", function()
      local direct, direct_ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }, { backend = "direct" }),
      })
      direct:open()
      t.eq(1, direct_ctx.calls.picked)
      t.eq(nil, direct_ctx.ui)

      local unreachable, unreachable_ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        connection = fake_connection({ ensure_ok = false }),
      })
      unreachable:open()
      t.eq(1, unreachable_ctx.calls.picked)
      t.eq(nil, unreachable_ctx.ui)
    end)
  end)

  t.describe("session manager load", function()
    local function catalog_with(dir)
      local cwds = {}
      return {
        cwds = function()
          return cwds
        end,
      }, cwds
    end

    t.it("loads on the live connection when agent and directory match", function()
      local dir = tmpdir("same")
      local catalog, cwds = catalog_with(dir)
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        client = { cwd = dir },
        catalog = catalog,
        phase = "ready",
        cwd = dir,
        preopen = true,
      })
      instance:load({ agent = "alpha", sessionId = "sess1", cwd = dir })
      t.eq(1, #ctx.calls.loads)
      t.eq("sess1", ctx.calls.loads[1].id)
      t.eq(dir, ctx.calls.loads[1].opts.cwd)
      t.eq(dir, cwds.sess1, "the catalog must learn the session's directory")
      t.eq(0, #ctx.calls.setups)
      t.truthy(ctx.ui.closed, "the manager closes when the load starts")
    end)

    t.it("switches agent, cd's and leaves a one-shot pending load", function()
      local from, to = tmpdir("from"), tmpdir("to")
      vim.cmd("cd " .. vim.fn.fnameescape(from))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(original_cwd))
      end)
      local catalog = catalog_with(to)
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        client = { cwd = from },
        catalog = catalog,
        phase = "ready",
        cwd = from,
        preopen = true,
        flow = {
          pending_work = function()
            return 0, 0
          end,
        },
      })
      instance:open()
      instance:load({ agent = "beta", sessionId = "sess2", cwd = to })
      t.eq(1, #ctx.calls.setups)
      t.eq("beta", ctx.calls.setups[1].opts.agent)
      t.eq(true, ctx.calls.setups[1].action.discard_queued)
      t.eq(1, ctx.calls.opened)
      t.eq(to, vim.fn.getcwd(), "the editor must move to the session's folder")
      t.eq("sess2", ctx.state.conn.pending_load.id)
      t.eq(to, ctx.state.conn.pending_load.cwd)
      t.truthy(ctx.ui.closed)
      t.eq(0, #ctx.calls.loads, "the new connection must load it, not the old one")
    end)

    t.it("asks before dropping queued messages and honours Cancel", function()
      local from, to = tmpdir("askfrom"), tmpdir("askto")
      vim.cmd("cd " .. vim.fn.fnameescape(from))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(original_cwd))
      end)
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        client = { cwd = from },
        phase = "ready",
        cwd = from,
        preopen = true,
        flow = {
          pending_work = function()
            return 2, 1
          end,
        },
      })
      instance:open()
      instance:load({ agent = "beta", sessionId = "sess3", cwd = to })
      t.eq(1, #ctx.calls.presenter)
      local question = ctx.calls.presenter[1]
      t.truthy(question.title:find("Switch to beta in " .. to, 1, true), "the target agent and folder are named")
      t.match("drops 2 queued message", question.title)
      t.match("interrupts 1 running turn", question.title)
      t.eq(true, ctx.ui.busy, "the manager must stay open under the confirmation")
      t.eq(0, #ctx.calls.setups)

      question.on_choice("cancel")
      t.eq(false, ctx.ui.busy)
      t.eq(0, #ctx.calls.setups)
      t.eq(from, vim.fn.getcwd(), "Cancel must not move the editor")
    end)

    t.it("switches after the confirmation is accepted", function()
      local from, to = tmpdir("okfrom"), tmpdir("okto")
      vim.cmd("cd " .. vim.fn.fnameescape(from))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(original_cwd))
      end)
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        client = { cwd = from },
        phase = "ready",
        cwd = from,
        preopen = true,
        flow = {
          pending_work = function()
            return 1, 1
          end,
        },
      })
      instance:load({ agent = "beta", sessionId = "sess4", cwd = to })
      ctx.calls.presenter[1].on_choice("switch")
      t.eq(1, #ctx.calls.setups)
      t.eq(true, ctx.calls.setups[1].action.discard_queued)
      t.eq(to, vim.fn.getcwd())
      t.eq("sess4", ctx.state.conn.pending_load.id)
    end)

    t.it("refuses a pinned cwd and a missing directory", function()
      local dir, other = tmpdir("pin"), tmpdir("other")
      local pinned, pinned_ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }, { cwd = dir }),
        cwd = dir,
      })
      pinned:load({ agent = "alpha", sessionId = "sess5", cwd = other })
      t.eq(0, #pinned_ctx.calls.setups)
      t.match("pinned", pinned_ctx.calls.notifications[#pinned_ctx.calls.notifications].message)

      local missing, missing_ctx = manager({ cfg = config({ alpha = { command = "alpha-acp" } }), cwd = dir })
      missing:load({ agent = "alpha", sessionId = "sess6", cwd = dir .. "/gone" })
      t.eq(0, #missing_ctx.calls.setups)
      t.match("does not exist", missing_ctx.calls.notifications[#missing_ctx.calls.notifications].message)
    end)
  end)

  t.describe("session manager window", function()
    local dir_a, dir_b, dir_missing

    local function state(overrides)
      return vim.tbl_extend("force", {
        agents = { "alpha", "beta", "delta", "gamma" },
        entries = {
          {
            agent = "alpha",
            sessionId = "a1",
            cwd = dir_a,
            title = "Fix the toolbar badge",
            updatedAt = "2026-11-25T18:02:00Z",
          },
          {
            agent = "beta",
            sessionId = "b1",
            cwd = dir_b,
            title = "Session manager design",
            updatedAt = "2026-11-25T17:40:00Z",
          },
          {
            agent = "gamma",
            sessionId = "g1",
            cwd = dir_missing,
            title = "Migrate auth",
            updatedAt = "2026-11-20T09:13:00Z",
          },
          { agent = "alpha", sessionId = "a0", cwd = dir_a, title = "Undated session" },
        },
        agent_state = {
          alpha = { listed_at = 1 },
          beta = { error = { code = -32070, message = "auth required" } },
        },
        refreshing = { delta = true },
        unavailable = {},
        current_agent = "alpha",
        current_id = "a1",
        use_icons = true,
        is_dir = function(path)
          return path ~= dir_missing
        end,
      }, overrides or {})
    end

    local function open_window(view)
      vim.o.columns = 160
      local handle = ui.open(view)
      t.cleanup(function()
        pcall(handle.close, handle)
      end)
      return handle
    end

    local function key(sequence)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(sequence, true, false, true), "x", false)
    end

    t.it("draws the header states, the sorted rows and the picker chrome", function()
      dir_a = tmpdir("uia")
      dir_b = tmpdir("uib")
      dir_missing = tmpdir("uimissing")
      vim.fn.delete(dir_missing, "rf")
      local handle = open_window(state())
      t.eq("ade_session_manager", vim.bo[handle.buf].filetype)
      t.truthy(
        vim.api.nvim_get_option_value("winhighlight", { win = handle.win }):find("AdePickerBorder", 1, true),
        "the window must use the picker chrome"
      )

      local lines = handle:lines()
      t.match("alpha ✓ 2", lines[1])
      t.match("beta ✗ auth required", lines[1])
      t.match("delta ⟳", lines[1])
      local with_unavailable = open_window(state({ unavailable = { gamma = "not installed" } }))
      t.match("gamma – not installed", with_unavailable:lines()[1])
      t.truthy(with_unavailable)

      -- Sorted by updatedAt descending, undated last.
      t.truthy(line_index(lines, "Fix the toolbar badge") < line_index(lines, "Session manager design"))
      t.truthy(line_index(lines, "Session manager design") < line_index(lines, "Migrate auth"))
      t.truthy(line_index(lines, "Migrate auth") < line_index(lines, "Undated session"))
      t.match("2026%-11%-25 18:02", lines[3])
      t.match("%(missing%)", table.concat(lines, "\n"))
      t.truthy(
        vim.startswith(lines[3], require("ade.ui.icons").get(true).arrow_right .. " "),
        "the current session must carry the arrow"
      )
      t.falsy(table.concat(lines, "\n"):find("<C-d>", 1, true), "the footer must not advertise delete")
      t.match("<C%-r> refresh", table.concat(lines, "\n"))
      t.match("<Tab> agent filter", table.concat(lines, "\n"))
    end)

    t.it("filters by typing and cycles the agent filter with <Tab>", function()
      dir_a = tmpdir("uia2")
      dir_b = tmpdir("uib2")
      dir_missing = tmpdir("uimissing2")
      vim.fn.delete(dir_missing, "rf")
      local handle = open_window(state())
      for _, char in ipairs({ "d", "e", "s", "i", "g", "n" }) do
        key(char)
      end
      local lines = handle:lines()
      t.truthy(has_line(lines, "Session manager design"))
      t.falsy(has_line(lines, "Fix the toolbar badge"), "other rows must be filtered out")
      t.eq("design", handle:query())

      key("<C-u>")
      t.eq(4, #handle:visible())
      key("<Tab>")
      t.eq("alpha", handle:agent_filter())
      t.match("%[agent: alpha%]", table.concat(handle:lines(), "\n"))
      for _, row in ipairs(handle:visible()) do
        t.eq("alpha", row.agent)
      end
      for _ = 1, 4 do
        key("<Tab>")
      end
      t.eq(nil, handle:agent_filter(), "cycling past the last agent returns to all")
    end)

    t.it("opens the row under the cursor and closes, and refreshes with <C-r>", function()
      dir_a = tmpdir("uia3")
      dir_b = tmpdir("uib3")
      dir_missing = tmpdir("uimissing3")
      vim.fn.delete(dir_missing, "rf")
      local view = state()
      local handle
      local opened
      view.on_open = function(entry)
        opened = entry
        -- The application closes the window once the load starts; emulate that
        -- here to prove the callback receives the row under the cursor.
        handle:close()
      end
      local refreshed = 0
      view.on_refresh = function()
        refreshed = refreshed + 1
      end
      handle = open_window(view)
      t.eq(true, handle:is_open())
      key("<C-r>")
      t.eq(1, refreshed)
      key("<CR>")
      t.eq("a1", opened and opened.sessionId)
    end)

    t.it("keeps painting after late updates and ignores them once closed", function()
      dir_a = tmpdir("uia4")
      dir_b = tmpdir("uib4")
      dir_missing = tmpdir("uimissing4")
      vim.fn.delete(dir_missing, "rf")
      local handle = open_window(state())
      local next_view = state()
      next_view.entries = {
        { agent = "alpha", sessionId = "late", cwd = dir_a, title = "Late update", updatedAt = "2026-11-26T09:00:00Z" },
      }
      handle:update(next_view)
      t.truthy(has_line(handle:lines(), "Late update"))
      handle:close()
      t.eq(false, handle:is_open())
      handle:update(state())
    end)
  end)

  t.describe("session manager service", function()
    local function start_service(tag, opts)
      -- Wide enough that a row's title is not truncated before assertions can
      -- read it; the harness restores the option after each test.
      vim.o.columns = 160
      local dir = tmpdir(tag)
      local service = fake.new(vim.tbl_extend("force", {
        dir = dir,
        features = { "tunnel", "log", "sessions" },
        canned_agent = true,
      }, opts or {}))
      assert(service:listen(), "the stand-in service could not listen")
      t.cleanup(function()
        pcall(service.close, service)
      end)
      return service, dir
    end

    local function setup_service(t, dir, overrides)
      local saved_dir = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir
      local connection = ServiceConnection.new({
        resolve_binary = function()
          return { path = "/fake/nvim_ade_server", version = "0.9.0", api_version = 8 }
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
        agent = "opencode",
        agents = {
          opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } },
          -- Only opencode is listable: the header states of the other presets
          -- would make the refresh payload harder to read.
          claude = { command = "missing-binary" },
          pi = { command = "missing-binary" },
        },
        service = { keep_alive = true, idle_timeout = 60 },
        manager = { root = dir .. "/agents" },
        permissions = { prompt = "native", auto_allow = {} },
        ui = {},
        layout = { input_height = 6 },
      }, overrides or {}))
      return connection
    end

    local function wait(cond, timeout, label)
      if not vim.wait(timeout or 12000, cond, 20) then
        error("timed out: " .. (label or "condition"), 2)
      end
    end

    local function manager_window()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "ade_session_manager" then
          return win, buf
        end
      end
    end

    local function lines_of(buf)
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end

    t.it("lists cached rows without ever connecting the panel, then loads a row", function()
      local dir_a, dir_b = tmpdir("svca"), tmpdir("svcb")
      local service, service_dir = start_service("catalog", {
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_cached",
            cwd = dir_b,
            title = "Cached session",
            updatedAt = "2026-11-25T18:00:00Z",
          },
        },
        session_refresh = {
          opencode = {
            ok = true,
            sessions = {
              {
                agent = "opencode",
                sessionId = "sess_fresh",
                cwd = dir_b,
                title = "Fresh session",
                updatedAt = "2026-11-26T08:00:00Z",
              },
            },
          },
        },
        session_refresh_hold = true,
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir_a))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir)
      t.cleanup(close_manager_windows)

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Cached session")
      end, 8000, "the cached row")

      local S = controller.state()
      t.eq("stopped", S.conn.phase, "the manager must not start the panel")
      t.eq(1, #service.session_refreshes)
      local sent = service.session_refreshes[1]
      t.eq(1, #sent.agents)
      t.eq("opencode", sent.agents[1].agent)
      t.eq(dir_a, sent.agents[1].cwd, "the editor cwd is the listing cwd")
      t.eq("python3", sent.agents[1].command)
      t.truthy(sent.agents[1].env and sent.agents[1].env.PATH, "the child environment is complete")
      t.match("⟳", lines_of(buf)[1], "the header must say the agent is refreshing")

      t.truthy(service:finish_session_refresh())
      wait(function()
        return has_line(lines_of(buf), "Fresh session")
      end, 8000, "the refreshed row")
      t.falsy(has_line(lines_of(buf), "Cached session"), "the agent's rows are replaced")
      t.match("opencode ✓ 1", lines_of(buf)[1])

      -- Open the refreshed row: no connection exists yet, so this builds one
      -- and the pending load must be the requested session, not an empty one.
      local row = line_index(lines_of(buf), "Fresh session")
      t.truthy(row)
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        local state = controller.state()
        return state.conn.phase == "ready" and state.sess.current and state.sess.current.id == "sess_fresh"
      end, 20000, "the requested session to load")
      t.eq(dir_b, vim.fn.getcwd(), "the editor moved to the session's folder")
      t.eq(0, service.session_new_calls, "no empty session may be created on the way")
      t.eq(nil, manager_window(), "the manager closes when the load starts")
    end)

    t.it("asks before interrupting pending work and Cancel keeps everything", function()
      local dir_a, dir_b = tmpdir("svcpa"), tmpdir("svcpb")
      local service, service_dir = start_service("pending", {
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_other",
            cwd = dir_b,
            title = "Other folder session",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir_a))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir)
      controller.open()
      wait(function()
        local S = controller.state()
        return S.conn.phase == "ready" and S.sess.current ~= nil
      end, 25000, "the panel to be ready")
      t.cleanup(function()
        pcall(controller.hide)
      end)

      -- A running turn makes the switch destructive.
      local S = controller.state()
      S.sess.current.status = "running"

      local original = picker.select
      local asked
      picker.select = function(opts)
        asked = opts
      end
      t.cleanup(function()
        picker.select = original
      end)

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Other folder session")
      end, 8000, "the cached row")
      local row = line_index(lines_of(buf), "Other folder session")
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        return asked ~= nil
      end, 5000, "the confirmation")
      t.truthy(asked.title:find("Switch to opencode in " .. dir_b, 1, true), "the target and folder are named")
      t.match("interrupts 1 running turn", asked.title)
      t.match("drops 0 queued message", asked.title)
      asked.on_choice("cancel")
      t.eq(dir_a, vim.fn.getcwd(), "Cancel must not switch folders")
      t.truthy(manager_window(), "Cancel leaves the manager open")

      -- Accepting the second time performs the switch and the one-shot load.
      S.sess.current.status = "running"
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        return asked ~= nil and asked.on_choice ~= nil
      end, 5000, "the second confirmation")
      asked.on_choice("switch")
      wait(function()
        local state = controller.state()
        return state.conn.phase == "ready" and state.sess.current and state.sess.current.id == "sess_other"
      end, 20000, "the requested session to load")
      t.eq(dir_b, vim.fn.getcwd())
      t.eq(nil, manager_window())
    end)
  end)

  t.describe("session manager entry points", function()
    t.it("completes `all` after :Ade sessions", function()
      local matches = vim.fn.getcompletion("Ade sessions ", "cmdline")
      t.truthy(vim.tbl_contains(matches, "all"), "completion must offer all")
    end)

    t.it("exposes the Lua entry point", function()
      t.eq("function", type(ade.session_manager))
      t.eq("function", type(controller.session_manager))
    end)
  end)
end
