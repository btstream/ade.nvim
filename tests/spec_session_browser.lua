-- Cross-agent session manager (docs/session-manager.md, PROTOCOL.md 21).
--
-- Three layers are covered: the app module's catalog/refresh/load decisions
-- (with a fake connection and a fake window), the window itself (header,
-- sorting, filtering and keys) and a real service backend run through
-- `tests/fake_service.lua`, including the one-shot pending load.
return function(t)
  local SessionBrowser = require("ade.app.session_browser")
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
      ensure_pending = opts.ensure_pending == true,
      hellos = {},
    }
    function connection:ensure(cb)
      if self.ensure_pending then
        -- Simulates a handshake that is still running (a version restart).
        self.ensure_cb = cb
        return
      end
      cb(self.ensure_ok, self.ensure_ok and nil or "the service is unavailable")
    end
    function connection:has_feature(name)
      return self.features[name] == true
    end
    function connection:subscribe(channel, method, fn)
      self.listeners[method] = self.listeners[method] or {}
      self.listeners[method][channel] = fn
      self.channel = channel
    end
    function connection:unsubscribe(channel, method)
      local list = self.listeners[method]
      if list then
        list[channel] = nil
      end
      self.unsubscribed = { channel = channel, method = method }
    end
    function connection:subscriber_count(method)
      local count = 0
      for _ in pairs(self.listeners[method] or {}) do
        count = count + 1
      end
      return count
    end
    function connection:on_hello(channel, fn)
      self.hellos[channel] = fn
    end
    function connection:hello_count()
      local count = 0
      for _ in pairs(self.hellos) do
        count = count + 1
      end
      return count
    end
    function connection:hello(channel)
      local fn
      if channel then
        fn = self.hellos[channel]
      else
        local _, value = next(self.hellos)
        fn = value
      end
      if type(fn) == "function" then
        fn()
      end
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
      for _, fn in pairs(self.listeners["sessions.updated"] or {}) do
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
          if self.closed then
            return
          end
          self.closed = true
          -- Mirror the real window: the owner hears about a close exactly once.
          if type(self.view.on_close) == "function" then
            pcall(self.view.on_close)
          end
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
      deletes = {},
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
          delete = function(_, id, done)
            calls.deletes[#calls.deletes + 1] = { id = id }
            if opts.on_delete then
              opts.on_delete(id, done)
            else
              done(true)
            end
          end,
          is_replaying = function()
            return opts.replaying == true
          end,
        },
      },
    }
    local instance = SessionBrowser.new({
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
      resolve_cwd = function()
        return opts.cwd or original_cwd
      end,
      presenter = {
        select = function(select_opts)
          calls.presenter[#calls.presenter + 1] = select_opts
        end,
      },
      ui = ui_module,
      catalog = opts.catalog,
      generation = function()
        return 0
      end,
      is_dir = opts.is_dir,
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
      if vim.bo[buf].filetype == "ade_sessions" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  t.describe("session browser catalog", function()
    t.it("shows cached rows before the refresh finishes", function()
      local dir = tmpdir("cache")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      instance:open("all")
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
      instance:open("all")
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

    t.it("keeps an error that arrives before the cache reply", function()
      local dir = tmpdir("errcache")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        cwd = dir,
      })
      instance:open("all")
      ctx.connection:updated({ agent = "beta", error = { code = -32070, message = "auth required" } })
      ctx.connection:reply("sessions.cached", true, {
        sessions = {
          { agent = "alpha", sessionId = "a1", cwd = dir, title = "Alpha cached" },
          { agent = "beta", sessionId = "b1", cwd = dir, title = "Beta cached" },
        },
        agents = { alpha = { listed_at = 11 }, beta = { listed_at = 12 } },
      })
      local titles = {}
      for _, entry in ipairs(ctx.ui.view.entries) do
        titles[entry.title] = true
      end
      t.truthy(titles["Beta cached"], "a failed agent still gets its cached rows")
      t.truthy(titles["Alpha cached"])
      t.eq("auth required", ctx.ui.view.agent_state.beta.error.message, "the failure must survive the cache merge")
      t.eq(12, ctx.ui.view.agent_state.beta.listed_at)
      t.eq(11, ctx.ui.view.agent_state.alpha.listed_at)
    end)

    t.it("fills cached rows when the refresh reply lands first", function()
      local dir = tmpdir("replycache")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      instance:open("all")
      local initial_cached = ctx.connection.requests[1]
      ctx.connection:reply("sessions.refresh", true, { agents = { alpha = { ok = true, count = 1 } } })
      t.eq(0, #ctx.ui.view.entries)
      t.eq(nil, ctx.ui.view.refreshing.alpha)
      -- The refresh also re-reads the cache for can_delete; answer that one
      -- first, then the original cache request with the old rows.
      ctx.connection:reply("sessions.cached", true, { sessions = {}, agents = {} })
      initial_cached.cb(true, {
        sessions = { { agent = "alpha", sessionId = "a1", cwd = dir, title = "Cached later" } },
        agents = { alpha = { listed_at = 5 } },
      })
      t.eq(1, #ctx.ui.view.entries)
      t.eq("Cached later", ctx.ui.view.entries[1].title)
      t.eq(5, ctx.ui.view.agent_state.alpha.listed_at)
    end)

    t.it("unsubscribes on close and drops callbacks from an earlier opening", function()
      local dir = tmpdir("lifecycle")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      t.eq(0, ctx.connection:subscriber_count("sessions.updated"))
      instance:open("all")
      t.eq(1, ctx.connection:subscriber_count("sessions.updated"))
      local first_cached = ctx.connection.requests[#ctx.connection.requests - 1]
      local first_refresh = ctx.connection.requests[#ctx.connection.requests]
      ctx.ui:close()
      t.eq(0, ctx.connection:subscriber_count("sessions.updated"), "closing the window must drop the listener")

      instance:open("all")
      t.eq(1, ctx.connection:subscriber_count("sessions.updated"))
      local second_cached = ctx.connection.requests[#ctx.connection.requests - 1]
      -- Replies from the closed round must not touch the new window.
      first_cached.cb(true, {
        sessions = { { agent = "alpha", sessionId = "stale", cwd = dir, title = "Stale round" } },
      })
      t.eq(0, #ctx.ui.view.entries)
      first_refresh.cb(true, { agents = { alpha = { ok = true, count = 1 } } })
      t.truthy(ctx.ui.view.refreshing.alpha, "a stale refresh reply must not settle the new round")
      second_cached.cb(true, {
        sessions = { { agent = "alpha", sessionId = "fresh", cwd = dir, title = "Fresh round" } },
      })
      t.eq(1, #ctx.ui.view.entries)
      t.eq("Fresh round", ctx.ui.view.entries[1].title)
      instance:close_window()
      t.eq(0, ctx.connection:subscriber_count("sessions.updated"))
    end)

    t.it("drops a refresh reply from an older <C-r>", function()
      local dir = tmpdir("refreshseq")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      instance:open("all")
      local first_reply = ctx.connection.requests[#ctx.connection.requests]
      instance:refresh()
      local second_reply = ctx.connection.requests[#ctx.connection.requests]
      t.truthy(first_reply ~= second_reply)
      first_reply.cb(true, { agents = { alpha = { ok = true } } })
      t.truthy(ctx.ui.view.refreshing.alpha, "the older reply must not clear the newer refresh")
      second_reply.cb(true, { agents = { alpha = { ok = true } } })
      t.eq(nil, ctx.ui.view.refreshing.alpha)
    end)

    t.it("keeps the latest successful rows when a later refresh fails", function()
      local dir = tmpdir("multiround")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      instance:open("all")
      local initial_cached = ctx.connection.requests[1]
      t.eq("sessions.cached", initial_cached.method)
      ctx.connection:updated({
        agent = "alpha",
        sessions = { { agent = "alpha", sessionId = "fresh", cwd = dir, title = "Fresh row" } },
      })
      instance:refresh()
      ctx.connection:updated({ agent = "alpha", error = { code = -32071, message = "listing timed out" } })
      -- The initial cache request answers very late with the old snapshot.
      initial_cached.cb(true, {
        sessions = { { agent = "alpha", sessionId = "old", cwd = dir, title = "Old row" } },
        agents = { alpha = { listed_at = 1 } },
      })
      t.eq(1, #ctx.ui.view.entries)
      t.eq("Fresh row", ctx.ui.view.entries[1].title, "a failure must keep the latest successful rows")
      t.eq("listing timed out", ctx.ui.view.agent_state.alpha.error.message)
    end)

    t.it("a disposed manager never opens from a late handshake", function()
      local connection = fake_connection({ ensure_pending = true })
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        connection = connection,
      })
      instance:open("all")
      t.eq(1, connection:hello_count(), "the wait registers one hello listener")
      t.eq(0, #ctx.handles)
      -- Capture the callback before dispose removes it: a dispatch already in
      -- flight must still not open a window from a disposed manager.
      local pending
      for _, fn in pairs(connection.hellos) do
        pending = fn
      end
      t.eq("function", type(pending))
      instance:dispose()
      t.eq(0, connection:hello_count(), "dispose removes the hello listener")
      pending()
      vim.wait(60)
      t.eq(0, #ctx.handles, "the scheduled open must be dropped with the manager")
      instance:open("all")
      t.eq(0, #ctx.handles, "a disposed manager cannot be reopened")
    end)

    t.it("keeps cached rows and shows the error when an agent fails", function()
      local dir = tmpdir("failed")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        cwd = dir,
      })
      instance:open("all")
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

    t.it("re-reads can_delete from the cache after a refresh", function()
      local dir = tmpdir("can-refresh")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      instance:open("all")
      ctx.connection:reply("sessions.cached", true, {
        sessions = {},
        agents = { alpha = { listed_at = 1, can_delete = false } },
      })
      t.eq(false, instance:can_delete({ agent = "alpha", sessionId = "x" }))

      -- The refresh reply itself has no can_delete (real wire); the browser
      -- must re-read the cache to learn the new capability.
      ctx.connection:reply("sessions.refresh", true, { agents = { alpha = { ok = true, count = 0 } } })
      local recheck
      for _, request in ipairs(ctx.connection.requests) do
        if request.method == "sessions.cached" and not request.replied then
          recheck = request
        end
      end
      t.truthy(recheck, "a successful refresh must re-read the cache")
      ctx.connection:reply("sessions.cached", true, {
        sessions = {},
        agents = { alpha = { listed_at = 2, can_delete = true } },
      })
      t.eq(true, instance:can_delete({ agent = "alpha", sessionId = "x" }))

      -- And the reverse: a capability removed by the next refresh.
      instance:refresh()
      ctx.connection:reply("sessions.refresh", true, { agents = { alpha = { ok = true, count = 0 } } })
      ctx.connection:reply("sessions.cached", true, {
        sessions = {},
        agents = { alpha = { listed_at = 3, can_delete = false } },
      })
      t.eq(false, instance:can_delete({ agent = "alpha", sessionId = "x" }))
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
      instance:open("all")
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

    local function live_catalog(sessions)
      return {
        list = function(_, _, cb)
          cb(true, sessions or {})
        end,
        cwds = function()
          return {}
        end,
      }
    end

    t.it("keeps only here without the sessions feature and explains Tab once", function()
      local dir = tmpdir("nofeature")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        connection = fake_connection({ features = {} }),
        client = {
          is_ready = function()
            return true
          end,
          cwd = dir,
        },
        catalog = live_catalog({
          { sessionId = "live1", title = "Live one", cwd = dir, updatedAt = "2026-11-26T08:00:00Z" },
        }),
        cwd = dir,
      })
      instance:open("all")
      t.truthy(ctx.ui, "the live scope must still open")
      t.eq("here", ctx.ui.view.scope)
      t.eq({ "here" }, ctx.ui.view.scopes)
      t.eq(1, #ctx.ui.view.entries)
      instance:cycle_scope()
      instance:cycle_scope()
      t.eq(1, #ctx.calls.notifications, "the service hint is shown once")
      t.match("needs the ade service", ctx.calls.notifications[1].message)
    end)

    t.it("notifies when neither the panel nor the service is available", function()
      local direct, direct_ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }, { backend = "direct" }),
      })
      direct:open("all")
      t.eq(nil, direct_ctx.ui)
      t.match("No agent process is running", direct_ctx.calls.notifications[1].message)

      local unreachable, unreachable_ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        connection = fake_connection({ ensure_ok = false }),
      })
      unreachable:open("all")
      t.eq(nil, unreachable_ctx.ui)
      t.match("No agent process is running", unreachable_ctx.calls.notifications[1].message)
    end)

    t.it("skips here without a panel and opens the catalog at the agent scope", function()
      local dir = tmpdir("nopanel")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        cwd = dir,
      })
      instance:open("here")
      t.truthy(ctx.ui, "the catalog must open without a panel")
      t.eq("agent", ctx.ui.view.scope)
      t.eq({ "agent", "all" }, ctx.ui.view.scopes)
      -- The scope that is shown, not the requested one, decides whether the
      -- catalog starts: here was skipped, so agent must really be loaded.
      t.eq(2, #ctx.connection.requests)
      t.eq("sessions.cached", ctx.connection.requests[1].method)
      t.eq("sessions.refresh", ctx.connection.requests[2].method)
      local params = ctx.connection.requests[2].params.agents
      t.eq(1, #params)
      t.eq("alpha", params[1].agent)
      t.eq(1, ctx.connection:subscriber_count("sessions.updated"))
      ctx.connection:updated({
        agent = "alpha",
        sessions = { { agent = "alpha", sessionId = "a1", cwd = dir, title = "Agent row" } },
      })
      t.eq(1, #ctx.ui.view.entries)
      t.eq("Agent row", ctx.ui.view.entries[1].title)
    end)

    t.it("starts the catalog after an asynchronous hello", function()
      local dir = tmpdir("async-hello")
      local connection = fake_connection({ ensure_pending = true })
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        connection = connection,
        cwd = dir,
      })
      instance:open("all")
      t.eq(nil, ctx.ui, "the window waits for the handshake")
      t.eq(0, #connection.requests)

      -- The handshake completes; the deferred open must now start the catalog.
      connection.ensure_pending = false
      connection.ensure_cb(true)
      connection:hello()
      vim.wait(80)

      t.truthy(ctx.ui, "the window must open when the service is ready")
      t.eq("all", ctx.ui.view.scope)
      t.eq(2, #connection.requests)
      t.eq("sessions.cached", connection.requests[1].method)
      t.eq("sessions.refresh", connection.requests[2].method)
      t.eq(1, connection:subscriber_count("sessions.updated"))
      connection:updated({
        agent = "alpha",
        sessions = { { agent = "alpha", sessionId = "a2", cwd = dir, title = "After hello" } },
      })
      t.eq(1, #ctx.ui.view.entries)
    end)

    t.it("cycles here, agent and all with their sources", function()
      local dir = tmpdir("scopes")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        client = {
          is_ready = function()
            return true
          end,
          cwd = dir,
        },
        catalog = live_catalog({
          { sessionId = "live1", title = "Live one", cwd = dir, updatedAt = "2026-11-26T08:00:00Z" },
        }),
        cwd = dir,
      })
      instance:open("here")
      t.eq("here", ctx.ui.view.scope)
      t.eq({ "here", "agent", "all" }, ctx.ui.view.scopes)

      -- The catalog is prepared on the first Tab; the agent scope keeps only
      -- the current agent's rows.
      instance:cycle_scope()
      t.eq("agent", ctx.ui.view.scope)
      -- Tab into a catalog scope starts the source once (cached + refresh).
      t.eq(2, #ctx.connection.requests)
      t.eq("sessions.cached", ctx.connection.requests[1].method)
      t.eq("sessions.refresh", ctx.connection.requests[2].method)
      t.eq(1, ctx.connection:subscriber_count("sessions.updated"))
      ctx.connection:updated({
        agent = "alpha",
        sessions = { { agent = "alpha", sessionId = "a1", cwd = dir, title = "Alpha row" } },
      })
      ctx.connection:updated({
        agent = "beta",
        sessions = { { agent = "beta", sessionId = "b1", cwd = dir, title = "Beta row" } },
      })
      local titles = {}
      for _, entry in ipairs(ctx.ui.view.entries) do
        titles[entry.title] = true
      end
      t.truthy(titles["Alpha row"])
      t.falsy(titles["Beta row"], "the agent scope must only show the current agent")

      instance:cycle_scope()
      t.eq("all", ctx.ui.view.scope)
      t.eq(2, #ctx.connection.requests, "cycling must not start a second round")
      titles = {}
      for _, entry in ipairs(ctx.ui.view.entries) do
        titles[entry.title] = true
      end
      t.truthy(titles["Alpha row"])
      t.truthy(titles["Beta row"])

      instance:cycle_scope()
      t.eq("here", ctx.ui.view.scope)
      t.eq(1, #ctx.ui.view.entries, "the live scope lists the panel's sessions")
    end)
  end)

  t.describe("session browser load", function()
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
      instance:open_row({ source = "catalog", agent = "alpha", sessionId = "sess1", cwd = dir })
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
      instance:open_row({ source = "catalog", agent = "beta", sessionId = "sess2", cwd = to })
      t.eq(1, #ctx.calls.setups)
      t.eq("beta", ctx.calls.setups[1].opts.agent)
      t.eq(true, ctx.calls.setups[1].action.discard_queued)
      t.eq(1, ctx.calls.opened)
      t.eq(to, vim.fn.getcwd(), "the editor must move to the session's folder")
      -- The intent travels in the setup action, scoped to the target connection.
      local intent = ctx.calls.setups[1].action.pending_load
      t.eq("beta", intent.agent)
      t.eq("sess2", intent.id)
      t.eq(to, intent.cwd)
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
      instance:open_row({ source = "catalog", agent = "beta", sessionId = "sess3", cwd = to })
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

    t.it("clears the busy wait when the confirmation is dismissed", function()
      local from, to = tmpdir("disfrom"), tmpdir("disto")
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
            return 0, 1
          end,
        },
      })
      instance:open_row({ source = "catalog", agent = "beta", sessionId = "sess5", cwd = to })
      t.eq(true, ctx.ui.busy)
      local question = ctx.calls.presenter[1]
      t.eq("function", type(question.on_cancel))
      question.on_cancel()
      t.eq(false, ctx.ui.busy, "a dismissed confirmation must clear the wait")
      t.eq(0, #ctx.calls.setups)
      t.eq(from, vim.fn.getcwd())
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
      instance:open_row({ source = "catalog", agent = "beta", sessionId = "sess4", cwd = to })
      ctx.calls.presenter[1].on_choice("switch")
      t.eq(1, #ctx.calls.setups)
      t.eq(true, ctx.calls.setups[1].action.discard_queued)
      t.eq(to, vim.fn.getcwd())
      t.eq("sess4", ctx.calls.setups[1].action.pending_load.id)
    end)

    t.it("refuses a pinned cwd and a missing directory", function()
      local dir, other = tmpdir("pin"), tmpdir("other")
      local pinned, pinned_ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }, { cwd = dir }),
        cwd = dir,
      })
      pinned:open_row({ source = "catalog", agent = "alpha", sessionId = "sess5", cwd = other })
      t.eq(0, #pinned_ctx.calls.setups)
      t.match("pinned", pinned_ctx.calls.notifications[#pinned_ctx.calls.notifications].message)

      local missing, missing_ctx = manager({ cfg = config({ alpha = { command = "alpha-acp" } }), cwd = dir })
      missing:open_row({ source = "catalog", agent = "alpha", sessionId = "sess6", cwd = dir .. "/gone" })
      t.eq(0, #missing_ctx.calls.setups)
      t.match("does not exist", missing_ctx.calls.notifications[#missing_ctx.calls.notifications].message)
    end)
  end)

  t.describe("session browser delete and can_delete", function()
    local function live_catalog(sessions)
      return {
        list = function(_, _, cb)
          cb(true, sessions or {})
        end,
        cwds = function()
          return {}
        end,
      }
    end

    local function service_features()
      return { sessions = true, ["sessions.delete"] = true }
    end

    t.it("deletes a panel row through the panel session service", function()
      local dir = tmpdir("del-panel")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" } }),
        client = {
          is_ready = function()
            return true
          end,
          cwd = dir,
        },
        catalog = live_catalog({
          { sessionId = "live1", title = "Live one", cwd = dir, updatedAt = "2026-11-26T08:00:00Z" },
        }),
        cwd = dir,
      })
      instance:open("here")
      local row = ctx.ui.view.entries[1]
      t.truthy(row)
      local results = {}
      instance:delete_row(row, function(ok)
        results[#results + 1] = ok
      end)
      t.eq({ true }, results)
      t.eq("live1", ctx.calls.deletes[1].id)
      t.eq(0, #ctx.connection.requests, "the panel path must not hit sessions.delete")
      t.eq(0, #ctx.ui.view.entries, "the deleted row must leave the view")
    end)

    t.it("deletes another agent's row through sessions.delete", function()
      local dir = tmpdir("del-remote")
      local forgotten = {}
      local last_sessions = require("ade.storage.last_sessions")
      local original_forget = last_sessions.forget_session
      last_sessions.forget_session = function(agent, id)
        forgotten[#forgotten + 1] = { agent = agent, id = id }
      end
      t.cleanup(function()
        last_sessions.forget_session = original_forget
      end)

      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        connection = fake_connection({ features = service_features() }),
        cwd = dir,
      })
      instance:open("all")
      ctx.connection:updated({
        agent = "beta",
        sessions = { { agent = "beta", sessionId = "b1", cwd = dir, title = "Beta row" } },
      })
      local row
      for _, entry in ipairs(ctx.ui.view.entries) do
        if entry.sessionId == "b1" then
          row = entry
        end
      end
      t.truthy(row)
      local results = {}
      instance:delete_row(row, function(ok)
        results[#results + 1] = ok
      end)
      local request
      for _, candidate in ipairs(ctx.connection.requests) do
        if candidate.method == "sessions.delete" then
          request = candidate
        end
      end
      t.truthy(request, "no sessions.delete was sent")
      t.eq("beta", request.params.agent.agent)
      t.eq(dir, request.params.agent.cwd)
      t.eq("b1", request.params.sessionId)
      t.eq({}, results, "the row stays until the service answers")
      ctx.connection:reply("sessions.delete", true, {})
      t.eq({ true }, results)
      t.eq("beta", forgotten[1].agent)
      t.eq("b1", forgotten[1].id)
      t.eq(0, #ctx.ui.view.entries)
    end)

    t.it("explains -32073 and -32074 delete failures", function()
      local dir = tmpdir("del-errors")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        connection = fake_connection({ features = service_features() }),
        cwd = dir,
      })
      instance:open("all")
      ctx.connection:updated({
        agent = "beta",
        sessions = { { agent = "beta", sessionId = "b1", cwd = dir, title = "Beta row" } },
      })
      local row = ctx.ui.view.entries[1]
      instance:delete_row(row, function() end)
      ctx.connection:reply("sessions.delete", false, { code = -32073, message = "no delete" })
      t.match("cannot delete", ctx.calls.notifications[#ctx.calls.notifications].message)

      instance:delete_row(row, function() end)
      ctx.connection:reply("sessions.delete", false, { code = -32074, message = "in use" })
      t.match("open in a running agent", ctx.calls.notifications[#ctx.calls.notifications].message)
      t.eq(1, #ctx.ui.view.entries, "a failed delete keeps the row")
    end)

    t.it("explains a service too old for sessions.delete", function()
      local dir = tmpdir("del-old")
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        connection = fake_connection({ features = { sessions = true } }),
        cwd = dir,
      })
      instance:open("all")
      ctx.connection:updated({
        agent = "beta",
        sessions = { { agent = "beta", sessionId = "b1", cwd = dir, title = "Beta row" } },
      })
      instance:delete_row(ctx.ui.view.entries[1], function() end)
      t.match("too old", ctx.calls.notifications[#ctx.calls.notifications].message)
      t.falsy(ctx.connection.requests[#ctx.connection.requests].method == "sessions.delete")
    end)

    t.it("reads can_delete from the panel capability and the catalog state", function()
      local dir = tmpdir("can-delete")
      local client = {
        is_ready = function()
          return true
        end,
        cwd = dir,
        has_session_capability = function(_, name)
          return name ~= "delete"
        end,
      }
      local instance, ctx = manager({
        cfg = config({ alpha = { command = "alpha-acp" }, beta = { command = "beta-acp" } }),
        client = client,
        catalog = live_catalog({
          { sessionId = "live1", title = "Live one", cwd = dir },
        }),
        cwd = dir,
        connection = fake_connection({ features = service_features() }),
      })
      instance:open("all")
      -- Panel agent: the client capability wins.
      t.eq(false, instance:can_delete({ agent = "alpha", sessionId = "x" }))

      -- Another agent: the catalog's can_delete, unknown allows.
      t.eq(true, instance:can_delete({ agent = "beta", sessionId = "x" }))
      ctx.connection:reply("sessions.cached", true, {
        sessions = {},
        agents = { beta = { listed_at = 1, can_delete = false } },
      })
      t.eq(false, instance:can_delete({ agent = "beta", sessionId = "x" }))
    end)
  end)

  t.describe("session browser window", function()
    local dir_a, dir_b, dir_missing
    local internal = require("ade.ui.session_browser.internal")

    local function state(overrides)
      return vim.tbl_extend("force", {
        scopes = { "here", "agent", "all" },
        scope = "here",
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
        can_delete = function()
          return true
        end,
        on_open = function() end,
        on_delete = function(_, done)
          done(true)
        end,
        on_refresh = function() end,
        on_cycle_scope = function() end,
        on_close = function() end,
        is_dir = function(path)
          return path ~= dir_missing
        end,
      }, overrides or {})
    end

    local function open_window(view)
      vim.o.columns = 160
      local handle = internal.open(view)
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
      t.eq("ade_sessions", vim.bo[handle.buf].filetype)
      t.truthy(
        vim.api.nvim_get_option_value("winhighlight", { win = handle.win }):find("AdePickerBorder", 1, true),
        "the window must use the picker chrome"
      )

      local lines = handle:lines()
      t.match("alpha ✓ 2", lines[2])
      t.match("beta ✗ auth required", lines[2])
      t.match("delta ⟳", lines[2])
      local with_unavailable = open_window(state({ unavailable = { gamma = "not installed" } }))
      t.match("gamma – not installed", with_unavailable:lines()[2])
      t.truthy(with_unavailable)

      -- Sorted by updatedAt descending, undated last.
      t.truthy(line_index(lines, "Fix the toolbar badge") < line_index(lines, "Session manager design"))
      t.truthy(line_index(lines, "Session manager design") < line_index(lines, "Migrate auth"))
      t.truthy(line_index(lines, "Migrate auth") < line_index(lines, "Undated session"))
      -- Local time, computed rather than hardcoded: the machine's zone is
      -- whatever the person running the suite uses.
      local expected_time = require("ade.ui.time").short("2026-11-25T18:02:00Z")
      t.truthy(lines[4]:find(expected_time, 1, true), "the row must show " .. expected_time)
      t.match("%(missing%)", table.concat(lines, "\n"))
      t.truthy(
        vim.startswith(lines[4], require("ade.ui.icons").get(true).arrow_right .. " "),
        "the current session must carry the arrow"
      )
      t.match("<C%-d> delete", table.concat(lines, "\n"))
      t.match("<C%-r> refresh", table.concat(lines, "\n"))
      t.match("<Tab> scope", table.concat(lines, "\n"))
    end)

    t.it("filters by typing and cycles the agent filter with <Tab>", function()
      dir_a = tmpdir("uia2")
      dir_b = tmpdir("uib2")
      dir_missing = tmpdir("uimissing2")
      vim.fn.delete(dir_missing, "rf")
      local handle = open_window(state({ scope = "all" }))
      for _, char in ipairs({ "d", "e", "s", "i", "g", "n" }) do
        key(char)
      end
      local lines = handle:lines()
      t.truthy(has_line(lines, "Session manager design"))
      t.falsy(has_line(lines, "Fix the toolbar badge"), "other rows must be filtered out")
      t.eq("design", handle:query())

      key("<C-u>")
      t.eq(4, #handle:visible())
      key("<S-Tab>")
      t.eq("alpha", handle:agent_filter())
      t.match("agent: alpha", table.concat(handle:lines(), "\n"))
      for _, row in ipairs(handle:visible()) do
        t.eq("alpha", row.agent)
      end
      for _ = 1, 4 do
        key("<S-Tab>")
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

    t.it("shows timestamps in local time, not in the agent's UTC", function()
      local dir = tmpdir("uia5")
      dir_b = tmpdir("uib5")
      dir_missing = tmpdir("uimissing5")
      vim.fn.delete(dir_missing, "rf")
      local time = require("ade.ui.time")
      local epoch = assert(time.parse("2026-11-26T15:48:00Z"))
      local expected = os.date("%Y-%m-%d %H:%M", epoch)
      local handle = open_window(state({
        entries = {
          {
            agent = "alpha",
            sessionId = "t1",
            cwd = dir,
            title = "Timed session",
            updatedAt = "2026-11-26T15:48:00Z",
          },
        },
        current_agent = nil,
        current_id = nil,
      }))
      t.truthy(has_line(handle:lines(), expected), "the row must show " .. expected)
      -- The parse is zone-aware even when this machine runs in UTC.
      t.eq("2026-11-26 07:48", os.date("!%Y-%m-%d %H:%M", assert(time.parse("2026-11-26T15:48:00+08:00"))))
    end)

    t.it("gives the title most of an 80-column row", function()
      local dir = tmpdir("uinarrow")
      local deep = dir .. "/very/deep/project/folder"
      vim.fn.mkdir(deep, "p")
      vim.o.columns = 80
      local view = state({
        entries = {
          {
            agent = "alpha",
            sessionId = "a1",
            cwd = deep,
            title = "Session catalog view",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
        agent_state = {},
        refreshing = {},
        current_agent = nil,
        current_id = nil,
      })
      local handle = internal.open(view)
      t.cleanup(function()
        pcall(handle.close, handle)
      end)
      local row = handle:lines()[4]
      -- The old 34% cwd column left about 13 title characters here; the title
      -- now keeps the remaining width.
      t.match("Session catalog v", row)
      t.truthy(row:find("project/folder", 1, true), "the cwd suffix stays readable")
      t.falsy(row:find(deep, 1, true), "the cwd is truncated")
    end)
  end)

  t.describe("session timestamps", function()
    local time = require("ade.ui.time")

    t.it("parses ISO 8601 with Z, offsets and fractions", function()
      t.eq("2026-11-26 15:48", os.date("!%Y-%m-%d %H:%M", assert(time.parse("2026-11-26T15:48:00Z"))))
      t.eq("2026-11-26 07:48", os.date("!%Y-%m-%d %H:%M", assert(time.parse("2026-11-26T15:48:00+08:00"))))
      t.eq("2026-11-26 16:48", os.date("!%Y-%m-%d %H:%M", assert(time.parse("2026-11-26T15:48:00-0100"))))
      t.eq("2026-11-26 15:48", os.date("!%Y-%m-%d %H:%M", assert(time.parse("2026-11-26T15:48:33.899Z"))))
      t.eq("2026-11-26 15:48", os.date("!%Y-%m-%d %H:%M", assert(time.parse("2026-11-26 15:48Z"))))
      t.eq(nil, time.parse("yesterday"))
      t.eq(nil, time.parse("2026-13-01T00:00:00Z"))
    end)

    t.it("keeps a zone-less timestamp local and falls back to raw text", function()
      local epoch = assert(time.parse("2026-11-26T15:48:00"))
      t.eq("2026-11-26 15:48", os.date("%Y-%m-%d %H:%M", epoch))
      local utc = assert(time.parse("2026-11-26T15:48:00Z"))
      t.eq(os.date("%Y-%m-%d %H:%M", utc), time.short("2026-11-26T15:48:00Z"))
      t.eq("not a time", time.short("not a time"))
      t.eq("2026-02-31T00:00", time.short("2026-02-31T00:00:00Z"), "invalid input falls back to the raw text")
      t.eq("", time.short(nil))
    end)

    t.it("rejects calendar-invalid dates, times and offsets", function()
      t.eq(nil, time.parse("2026-02-31T00:00:00Z"), "February has 28 days in 2026")
      t.truthy(time.parse("2024-02-29T00:00:00Z"), "2024 is a leap year")
      t.eq(nil, time.parse("2026-02-29T00:00:00Z"), "2026 is not a leap year")
      t.eq(nil, time.parse("2026-04-31T00:00:00Z"))
      t.eq(nil, time.parse("2026-01-01T24:00:00Z"))
      t.eq(nil, time.parse("2026-01-01T00:60:00Z"))
      t.eq(nil, time.parse("2026-01-01T00:00:60Z"))
      t.eq(nil, time.parse("2026-01-01T00:00:00+99:99"))
      t.eq(nil, time.parse("2026-01-01T00:00:00+24:00"))
    end)
  end)

  t.describe("session timestamps under other zones", function()
    ---Run one expression in a child Neovim with TZ set.
    ---
    ---Changing TZ inside a running process needs `tzset` and is not portable, so
    ---the DST cases get their own process.
    ---@param tz string
    ---@param script string
    ---@return string
    local function in_zone(tz, script)
      local result = vim
        .system({
          vim.v.progpath,
          "--headless",
          "-u",
          "NONE",
          "--cmd",
          "set runtimepath+=" .. root,
          "-c",
          "lua " .. script,
          "-c",
          "qa!",
        }, { env = { TZ = tz }, text = true })
        :wait()
      return (result.stdout or ""):gsub("%s+$", "")
    end

    local function unix_only()
      return vim.fn.has("unix") == 1
    end

    t.it("keeps a UTC instant across the New York DST transitions", function()
      if not unix_only() then
        io.write("SKIP: TZ child test needs unix\n")
        return
      end
      t.eq(
        "2026-03-08 01:30",
        in_zone("America/New_York", 'print(require("ade.ui.time").short("2026-03-08T06:30:00Z"))')
      )
      t.eq(
        "2026-11-01 01:30",
        in_zone("America/New_York", 'print(require("ade.ui.time").short("2026-11-01T06:30:00Z"))')
      )
    end)

    t.it("converts a +08:00 timestamp to the local zone of the process", function()
      if not unix_only() then
        io.write("SKIP: TZ child test needs unix\n")
        return
      end
      t.eq("2026-11-26 07:48", in_zone("UTC", 'print(require("ade.ui.time").short("2026-11-26T15:48:00+08:00"))'))
      t.eq("2026-11-26 23:48", in_zone("Asia/Shanghai", 'print(require("ade.ui.time").short("2026-11-26T15:48:00Z"))'))
    end)
  end)

  t.describe("session browser service", function()
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
        -- The service tests drive the built-in window; the snacks backend has
        -- its own spec.
        ui = { session_picker = "internal" },
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
        if vim.bo[buf].filetype == "ade_sessions" then
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
      t.match("⟳", lines_of(buf)[2], "the header must say the agent is refreshing")

      t.truthy(service:finish_session_refresh())
      wait(function()
        return has_line(lines_of(buf), "Fresh session")
      end, 8000, "the refreshed row")
      t.falsy(has_line(lines_of(buf), "Cached session"), "the agent's rows are replaced")
      t.match("opencode ✓ 1", lines_of(buf)[2])

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

    t.it("deletes another agent's row through sessions.delete", function()
      local dir = tmpdir("svcdelete")
      local service, service_dir = start_service("catalog-delete", {
        features = { "tunnel", "log", "sessions", "sessions.delete" },
        session_catalog = {
          {
            agent = "beta",
            sessionId = "sess_beta",
            cwd = dir,
            title = "Beta session",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir, {
        agents = { beta = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      })
      t.cleanup(close_manager_windows)

      local forgotten = {}
      local last_sessions = require("ade.storage.last_sessions")
      local original_forget = last_sessions.forget_session
      last_sessions.forget_session = function(agent, id)
        forgotten[#forgotten + 1] = { agent = agent, id = id }
      end
      t.cleanup(function()
        last_sessions.forget_session = original_forget
      end)

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Beta session")
      end, 8000, "the cached row")
      local row = line_index(lines_of(buf), "Beta session")
      t.truthy(row)
      vim.api.nvim_win_set_cursor(win, { row, 0 })

      local original_select = vim.ui.select
      vim.ui.select = function(_, _, cb)
        cb("Delete")
      end
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)

      wait(function()
        return #service.session_deletes == 1
      end, 10000, "sessions.delete")
      local sent = service.session_deletes[1]
      t.eq("beta", sent.agent.agent)
      t.eq("sess_beta", sent.sessionId)
      wait(function()
        return line_index(lines_of(buf), "Beta session") == nil
      end, 5000, "the row to disappear")
      t.eq("beta", forgotten[1].agent)
      t.eq("sess_beta", forgotten[1].id)
      local refreshes = 0
      for _, call in ipairs(service.calls) do
        if call.method == "sessions.refresh" then
          refreshes = refreshes + 1
        end
      end
      t.eq(1, refreshes, "the delete must not add a refresh")
    end)

    t.it("deletes the panel agent's row through the tunnel", function()
      local dir = tmpdir("panedelete")
      local service, service_dir = start_service("panel-delete", {
        features = { "tunnel", "log", "sessions" },
        canned_capabilities = { loadSession = true, sessionCapabilities = { delete = {}, list = {} } },
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_panel_old",
            cwd = dir,
            title = "Panel old session",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir)
      controller.open()
      wait(function()
        local state = controller.state()
        return state.conn.phase == "ready" and state.sess.current ~= nil
      end, 25000, "the panel to be ready")
      t.cleanup(close_manager_windows)
      t.cleanup(function()
        pcall(controller.hide)
      end)

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Panel old session")
      end, 8000, "the cached row")
      local row = line_index(lines_of(buf), "Panel old session")
      vim.api.nvim_win_set_cursor(win, { row, 0 })

      local original_select = vim.ui.select
      vim.ui.select = function(_, _, cb)
        cb("Delete")
      end
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)

      wait(function()
        for _, frame in ipairs(service.sent) do
          local message = frame.message
          if
            type(message) == "table"
            and message.method == "session/delete"
            and message.params.sessionId == "sess_panel_old"
          then
            return true
          end
        end
        return false
      end, 10000, "session/delete on the tunnel")
      t.eq(0, #service.session_deletes, "the panel path must not use sessions.delete")
      wait(function()
        return line_index(lines_of(buf), "Panel old session") == nil
      end, 5000, "the row to disappear")
    end)

    local function snacks_browser()
      local ok, sp = pcall(require, "snacks.picker")
      if not ok then
        return nil
      end
      for _, candidate in ipairs(sp.get()) do
        if type(candidate.title) == "string" and candidate.title:find("Sessions", 1, true) then
          return candidate
        end
      end
    end

    local function close_snacks(t)
      t.cleanup(function()
        local ok, sp = pcall(require, "snacks.picker")
        if ok then
          for _, candidate in ipairs(sp.get()) do
            pcall(function()
              candidate:close()
            end)
          end
        end
        -- Let snacks tear its layout down before the harness resets the
        -- options; closing during a VimResized callback is its known race.
        vim.wait(100)
      end)
    end

    local function row_of(picker, id)
      for _, item in ipairs(picker:items()) do
        if item.session.sessionId == id then
          return item
        end
      end
    end

    t.it("keeps the snacks browser open when the row's directory is gone", function()
      if not require("ade.ui.session_browser.snacks").available() then
        io.write("SKIP: snacks.nvim is not installed\n")
        return
      end
      local dir_a, missing = tmpdir("snacka"), tmpdir("snackm")
      vim.fn.delete(missing, "rf")
      local service, service_dir = start_service("snacks-missing", {
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_gone",
            cwd = missing,
            title = "Gone session",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir_a))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir, { ui = { session_picker = "snacks" } })
      close_snacks(t)
      ade.session_manager()
      local picker
      wait(function()
        picker = snacks_browser()
        return picker ~= nil and row_of(picker, "sess_gone") ~= nil
      end, 10000, "the snacks browser")
      picker:action("ade_open", row_of(picker, "sess_gone"))
      vim.wait(600)
      t.falsy(picker.closed, "a missing directory must keep the browser open")
      t.truthy(snacks_browser(), "the picker is still the session browser")
    end)

    t.it("keeps the snacks browser open on a pinned cwd refusal", function()
      if not require("ade.ui.session_browser.snacks").available() then
        io.write("SKIP: snacks.nvim is not installed\n")
        return
      end
      local dir_a, dir_b = tmpdir("snackpina"), tmpdir("snackpinb")
      local service, service_dir = start_service("snacks-pinned", {
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_other",
            cwd = dir_b,
            title = "Other folder",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir_a))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir, { cwd = dir_a, ui = { session_picker = "snacks" } })
      close_snacks(t)
      ade.session_manager()
      local picker
      wait(function()
        picker = snacks_browser()
        return picker ~= nil and row_of(picker, "sess_other") ~= nil
      end, 10000, "the snacks browser")
      picker:action("ade_open", row_of(picker, "sess_other"))
      vim.wait(600)
      t.falsy(picker.closed, "a pinned cwd must keep the browser open")
      t.eq(dir_a, vim.fn.getcwd())
    end)

    t.it("keeps the snacks browser open when the switch is cancelled", function()
      if not require("ade.ui.session_browser.snacks").available() then
        io.write("SKIP: snacks.nvim is not installed\n")
        return
      end
      local dir_a, dir_b = tmpdir("snackcancela"), tmpdir("snackcancelb")
      local service, service_dir = start_service("snacks-cancel", {
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_other",
            cwd = dir_b,
            title = "Other folder",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir_a))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir, {
        ui = { session_picker = "snacks", picker = "internal" },
      })
      close_snacks(t)
      controller.open()
      wait(function()
        local state = controller.state()
        return state.conn.phase == "ready" and state.sess.current ~= nil
      end, 25000, "the panel to be ready")
      t.cleanup(function()
        pcall(controller.hide)
      end)
      local S = controller.state()
      S.sess.current.status = "running"

      ade.session_manager()
      local picker
      wait(function()
        picker = snacks_browser()
        return picker ~= nil and row_of(picker, "sess_other") ~= nil
      end, 10000, "the snacks browser")
      picker:action("ade_open", row_of(picker, "sess_other"))

      local confirm
      wait(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.b[vim.api.nvim_win_get_buf(win)].ade_picker == true then
            confirm = win
            return true
          end
        end
        return false
      end, 5000, "the switch confirmation")
      vim.api.nvim_set_current_win(confirm)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      vim.wait(600)
      t.falsy(picker.closed, "Cancel must keep the snacks browser open")
      t.eq(dir_a, vim.fn.getcwd(), "Cancel must not switch folders")
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

    t.it("drops the one-shot load when the target agent fails to start", function()
      local dir_a, dir_b = tmpdir("faila"), tmpdir("failb")
      local service, service_dir = start_service("failed-start", {
        session_catalog = {
          {
            agent = "beta",
            sessionId = "sess_stale",
            cwd = dir_b,
            title = "Stale session",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
        -- Attaching beta fails with -32022 (the launch is broken); every other
        -- agent works. This is the non-auth start failure the leak was about.
        spawn_agent = function(instance)
          if type(instance.key) == "table" and instance.key.agent == "beta" then
            return false
          end
        end,
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir_a))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir, {
        agents = {
          beta = { command = "/bin/false" },
        },
      })
      t.cleanup(close_manager_windows)
      t.cleanup(function()
        pcall(controller.hide)
      end)

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Stale session")
      end, 8000, "the cached row")
      local row = line_index(lines_of(buf), "Stale session")
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

      local S = controller.state()
      wait(function()
        return S.conn.phase == "disconnected"
      end, 20000, "the failed start")
      t.eq(nil, S.conn.pending_load, "a failed start must drop the one-shot load")

      -- An ordinary agent switch afterwards must behave normally, not load the
      -- abandoned session through the new connection.
      controller.pick_agent("opencode")
      wait(function()
        local state = controller.state()
        return state.conn.phase == "ready" and state.sess.current ~= nil
      end, 25000, "the next agent")
      t.truthy(S.sess.current.id ~= "sess_stale", "the abandoned session must not load")
      t.eq("sess_mock", S.sess.current.id, "the ordinary path starts fresh")
      for _, frame in ipairs(service.sent) do
        local message = frame.message
        if type(message) == "table" and message.method == "session/load" then
          t.truthy(message.params.sessionId ~= "sess_stale", "the abandoned session was loaded")
        end
      end
    end)

    t.it("a reconfiguration closes the manager and drops its listener", function()
      local service, service_dir = start_service("dispose", {})
      setup_service(t, service_dir, {
        agents = { alpha = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      })
      t.cleanup(close_manager_windows)

      ade.session_manager()
      wait(function()
        return manager_window() ~= nil
      end, 8000, "the manager window")
      local S = controller.state()
      local old_manager = S.view.session_browser
      local connection = ServiceConnection.shared()
      local unsubscribed = 0
      local original_unsubscribe = connection.unsubscribe
      connection.unsubscribe = function(self, ...)
        unsubscribed = unsubscribed + 1
        return original_unsubscribe(self, ...)
      end
      t.cleanup(function()
        connection.unsubscribe = original_unsubscribe
        pcall(controller.hide)
      end)

      controller.pick_agent("alpha")
      t.truthy(S.view.session_browser ~= old_manager, "a reconfiguration must build a fresh manager")
      t.eq(nil, manager_window(), "the replaced manager's window must close")
      t.truthy(unsubscribed >= 1, "the replaced manager must unsubscribe its listener")
    end)

    t.it("cancelling the switch in the real picker clears the wait", function()
      local dir_a, dir_b = tmpdir("reala"), tmpdir("realb")
      local service, service_dir = start_service("real-picker", {
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
      setup_service(t, service_dir, { ui = { picker = "internal" } })
      controller.open()
      wait(function()
        local state = controller.state()
        return state.conn.phase == "ready" and state.sess.current ~= nil
      end, 25000, "the panel to be ready")
      t.cleanup(function()
        pcall(controller.hide)
      end)
      local S = controller.state()
      S.sess.current.status = "running"

      local function picker_window()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local picker_buf = vim.api.nvim_win_get_buf(win)
          if vim.b[picker_buf].ade_picker == true then
            return win
          end
        end
      end

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Other folder session")
      end, 8000, "the cached row")
      t.cleanup(close_manager_windows)
      local row = line_index(lines_of(buf), "Other folder session")
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      local picker_win
      wait(function()
        picker_win = picker_window()
        return picker_win ~= nil
      end, 5000, "the real confirmation picker")
      vim.api.nvim_set_current_win(picker_win)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      wait(function()
        return picker_window() == nil
      end, 3000, "the picker to close")
      t.eq(dir_a, vim.fn.getcwd(), "dismissing the picker must not switch folders")
      t.truthy(manager_window(), "the manager stays open")

      -- Not stuck busy: the same row can ask again.
      win = manager_window()
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      wait(function()
        return picker_window() ~= nil
      end, 3000, "a second confirmation")
      t.eq(S.conn.phase, "ready", "no switch happened")
      -- Leave cleanly.
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      wait(function()
        return picker_window() == nil
      end, 3000, "the second picker to close")
      win = manager_window()
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_feedkeys("q", "x", false)
      wait(function()
        return manager_window() == nil
      end, 3000, "the manager to close")
    end)

    t.it("a first-time terminal login creates one session on normal startup", function()
      local dir = tmpdir("login-start")
      local service, service_dir = start_service("login-start", {
        -- The very first initialize asks for a login; the restart succeeds.
        canned_init_auth_error = 1,
        canned_auth_methods = { { id = "terminal", name = "Terminal", type = "terminal" } },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)

      -- Patch before setup: Auth captures open_terminal when it is built and
      -- this path does not rebuild it later.
      local AuthModule = require("ade.app.auth")
      local original_open = AuthModule.open_terminal
      local logins = 0
      AuthModule.open_terminal = function(_, opts)
        logins = logins + 1
        vim.defer_fn(function()
          pcall(opts.on_exit, 0)
        end, 10)
        return true
      end
      t.cleanup(function()
        AuthModule.open_terminal = original_open
      end)

      setup_service(t, service_dir)
      t.cleanup(function()
        pcall(controller.hide)
      end)

      controller.open()
      local S = controller.state()
      wait(function()
        return S.conn.phase == "ready" and S.sess.current ~= nil
      end, 30000, "the session after the first-time login")
      t.eq(1, logins, "the login ran once")
      t.eq(1, service.session_new_calls, "exactly one session must be created or restored")
      t.eq("sess_mock", S.sess.current.id)
    end)

    t.it("an auth retry loads the pending session exactly once", function()
      local dir_a, dir_b = tmpdir("autha"), tmpdir("authb")
      local service, service_dir = start_service("auth-load", {
        canned_init_auth_error = 1,
        canned_auth_methods = { { id = "terminal", name = "Terminal", type = "terminal" } },
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_chosen",
            cwd = dir_b,
            title = "Chosen session",
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
      t.cleanup(close_manager_windows)
      t.cleanup(function()
        pcall(controller.hide)
      end)

      local S = controller.state()
      -- The real Auth flow, but an instant, successful terminal login. Patch
      -- the module: the session manager's switch rebuilds the Auth object, so
      -- patching the current instance would be lost.
      local AuthModule = require("ade.app.auth")
      local original_open = AuthModule.open_terminal
      local logins = 0
      AuthModule.open_terminal = function(_, opts)
        logins = logins + 1
        vim.defer_fn(function()
          pcall(opts.on_exit, 0)
        end, 10)
        return true
      end
      t.cleanup(function()
        AuthModule.open_terminal = original_open
      end)

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Chosen session")
      end, 8000, "the cached row")
      local row = line_index(lines_of(buf), "Chosen session")
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

      wait(function()
        return S.conn.phase == "ready" and S.sess.current and S.sess.current.id == "sess_chosen"
      end, 30000, "the chosen session after the login")
      t.eq(1, logins, "the login ran once")
      t.eq(0, service.session_new_calls, "the auth retry must not create an empty session")
      local loads = 0
      for _, frame in ipairs(service.sent) do
        local message = frame.message
        if
          type(message) == "table"
          and message.method == "session/load"
          and type(message.params) == "table"
          and message.params.sessionId == "sess_chosen"
        then
          loads = loads + 1
        end
      end
      t.eq(1, loads, "the chosen session must be loaded exactly once")
    end)

    t.it("cancelling the login after a failed start drops the pending load", function()
      local dir_a, dir_b = tmpdir("authca"), tmpdir("authcb")
      local service, service_dir = start_service("auth-cancel", {
        canned_init_auth_error = 1,
        canned_auth_methods = {
          { id = "one", name = "First method", type = "terminal" },
          { id = "two", name = "Second method", type = "terminal" },
        },
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_cancelled",
            cwd = dir_b,
            title = "Cancelled session",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir_a))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir, { ui = { picker = "internal" } })
      t.cleanup(close_manager_windows)
      t.cleanup(function()
        pcall(controller.hide)
      end)

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Cancelled session")
      end, 8000, "the cached row")
      local row = line_index(lines_of(buf), "Cancelled session")
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

      local picker_win
      wait(function()
        for _, candidate in ipairs(vim.api.nvim_list_wins()) do
          if vim.b[vim.api.nvim_win_get_buf(candidate)].ade_picker == true then
            picker_win = candidate
            return true
          end
        end
      end, 10000, "the login method picker")
      vim.api.nvim_set_current_win(picker_win)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      local S = controller.state()
      wait(function()
        return S.conn.pending_load == nil
      end, 5000, "the cancelled login to drop the pending load")
      local loads = 0
      for _, frame in ipairs(service.sent) do
        local message = frame.message
        if type(message) == "table" and message.method == "session/load" then
          loads = loads + 1
        end
      end
      t.eq(0, loads, "a cancelled login must not load the session")
    end)

    t.it("a login terminal that fails drops the pending load", function()
      local dir_a, dir_b = tmpdir("authfa"), tmpdir("authfb")
      local service, service_dir = start_service("auth-failed", {
        canned_init_auth_error = 1,
        canned_auth_methods = { { id = "terminal", name = "Terminal", type = "terminal" } },
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_refused",
            cwd = dir_b,
            title = "Refused session",
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
      t.cleanup(close_manager_windows)
      t.cleanup(function()
        pcall(controller.hide)
      end)

      local S = controller.state()
      local AuthModule = require("ade.app.auth")
      local original_open = AuthModule.open_terminal
      local logins = 0
      AuthModule.open_terminal = function(_, opts)
        logins = logins + 1
        vim.defer_fn(function()
          pcall(opts.on_exit, 1)
        end, 10)
        return true
      end
      t.cleanup(function()
        AuthModule.open_terminal = original_open
      end)

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Refused session")
      end, 8000, "the cached row")
      local row = line_index(lines_of(buf), "Refused session")
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

      wait(function()
        return logins == 1 and S.conn.pending_load == nil
      end, 15000, "the failed login to drop the pending load")
      local loads = 0
      for _, frame in ipairs(service.sent) do
        local message = frame.message
        if type(message) == "table" and message.method == "session/load" then
          loads = loads + 1
        end
      end
      t.eq(0, loads, "a failed login must not load the session")
    end)

    t.it("a cancelled pending-load login cannot block a later first-time login", function()
      local dir_a, dir_b = tmpdir("stalela"), tmpdir("stalelb")
      local service, service_dir = start_service("stale-login", {
        -- The connection starts fine; the chosen session's load asks for a
        -- login, which the person cancels. That must not leave state behind
        -- that suppresses an unrelated later first-time login.
        canned_auth_methods = { { id = "terminal", name = "Terminal", type = "terminal" } },
        canned_load_error = {
          code = -32000,
          message = "Authentication required",
          data = {
            authMethods = {
              { id = "one", name = "First method" },
              { id = "two", name = "Second method" },
            },
          },
        },
        session_catalog = {
          {
            agent = "opencode",
            sessionId = "sess_stale",
            cwd = dir_b,
            title = "Stale session",
            updatedAt = "2026-11-26T08:00:00Z",
          },
        },
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir_a))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir, { ui = { picker = "internal" } })
      t.cleanup(close_manager_windows)
      t.cleanup(function()
        pcall(controller.hide)
      end)

      local S = controller.state()
      local AuthModule = require("ade.app.auth")
      local original_open = AuthModule.open_terminal
      local logins = 0
      AuthModule.open_terminal = function(_, opts)
        logins = logins + 1
        vim.defer_fn(function()
          pcall(opts.on_exit, 0)
        end, 10)
        return true
      end
      t.cleanup(function()
        AuthModule.open_terminal = original_open
      end)

      local function picker_window()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.b[vim.api.nvim_win_get_buf(win)].ade_picker == true then
            return win
          end
        end
      end

      ade.session_manager()
      local win, buf
      wait(function()
        win, buf = manager_window()
        return win ~= nil and has_line(lines_of(buf), "Stale session")
      end, 8000, "the cached row")
      local row = line_index(lines_of(buf), "Stale session")
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

      local picker_win
      wait(function()
        picker_win = picker_window()
        return picker_win ~= nil
      end, 15000, "the session/load login picker")
      vim.api.nvim_set_current_win(picker_win)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      wait(function()
        return picker_window() == nil and S.conn.phase == "ready" and S.sess.current == nil
      end, 10000, "the cancelled load login")

      -- Drop the connection, then make the next startup a first-time terminal
      -- login. Nothing from the cancelled load may suppress its retry.
      controller.disconnect()
      wait(function()
        return S.conn.phase == "stopped"
      end, 5000, "the disconnect")
      service.canned_load_error = nil
      service.canned_init_auth_error = 1

      controller.open()
      wait(function()
        return S.conn.phase == "ready" and S.sess.current ~= nil
      end, 30000, "the session after the next first-time login")
      t.eq(1, logins, "the terminal login ran once")
      t.eq(1, service.session_new_calls, "exactly one session must be created")
      t.eq("sess_mock", S.sess.current.id)
    end)

    t.it("manual :Ade login on a ready client with no session creates one", function()
      local dir = tmpdir("manual-login")
      local service, service_dir = start_service("manual-login", {
        -- Two non-terminal methods, so both the initial failure and the manual
        -- login raise the method picker.
        canned_auth_methods = {
          { id = "first", name = "First method" },
          { id = "second", name = "Second method" },
        },
        session_new_auth_error = true,
      })
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(dir))
      t.cleanup(function()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
      end)
      setup_service(t, service_dir, { ui = { picker = "internal" } })
      t.cleanup(function()
        pcall(controller.hide)
      end)

      local function picker_window()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.b[vim.api.nvim_win_get_buf(win)].ade_picker == true then
            return win
          end
        end
      end

      controller.open()
      local first_picker
      wait(function()
        first_picker = picker_window()
        return first_picker ~= nil
      end, 20000, "the initial login picker")
      vim.api.nvim_set_current_win(first_picker)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      local S = controller.state()
      wait(function()
        return S.conn.phase == "ready" and S.sess.current == nil and picker_window() == nil
      end, 10000, "a ready client with no session after the cancel")

      -- The person logs in for real; the next session/new succeeds.
      service.session_new_auth_error = false
      controller.login()
      local second_picker
      wait(function()
        second_picker = picker_window()
        return second_picker ~= nil
      end, 10000, "the manual login picker")
      vim.api.nvim_set_current_win(second_picker)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

      -- The retry must re-run on_ready on the ready client and create a
      -- session instead of leaving `current` nil forever.
      wait(function()
        local state = controller.state()
        return state.sess.current ~= nil
      end, 20000, "the session after the manual login")
      t.eq("sess_mock", S.sess.current.id)
      t.eq(2, service.session_new_calls, "one failed creation and one after the manual login")
    end)
  end)

  t.describe("session browser entry points", function()
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
