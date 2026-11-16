-- Managed installs routed through nvim_ade_server (PROTOCOL.md section 16).
--
-- Everything here goes through `require("ade").setup`, the public controller
-- entry points and the real service connection layer; only "the service" is the
-- in-process stand-in. The direct-mode installer keeps its own suite
-- (`spec_agent_install`, `spec_agent_manager_service`).
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local fake_npm = require("tests.fake_npm")
  local npm_mod = require("ade.manager.npm")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local AgentManagerUI = require("ade.ui.agent_manager")
  local ade = require("ade")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-s2-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  local function start_service(t, tag, opts)
    local dir = tmpdir(tag)
    local service = fake.new(vim.tbl_extend("force", {
      dir = dir,
      features = { "tunnel", "install" },
    }, opts or {}))
    assert(service:listen(), "the stand-in service could not listen")
    t.cleanup(function()
      pcall(service.close, service)
    end)
    return service, dir
  end

  ---Install an isolated service connection and `ade.setup` over it.
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
    local manager_root = dir .. "/agents"
    ade.setup(vim.tbl_deep_extend("force", {
      backend = "service",
      agent = "opencode",
      agents = {
        opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } },
        pi = { source = "managed" },
      },
      service = { keep_alive = true, idle_timeout = 60 },
      manager = { root = manager_root },
      ui = {},
      layout = { input_height = 6 },
    }, overrides or {}))
    return connection, manager_root
  end

  local function state()
    return controller.state()
  end

  local function manager()
    return state().view.agent_manager_service
  end

  local function wait(cond, timeout, label)
    local ok = vim.wait(timeout or 20000, cond, 20)
    if not ok then
      error("timed out: " .. (label or "condition"), 2)
    end
  end

  local function wait_idle(m, label)
    wait(function()
      return not m:busy()
    end, 20000, label or "the install task")
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
    return notices,
      function()
        local lines = {}
        for _, note in ipairs(notices) do
          lines[#lines + 1] = note.message
        end
        return table.concat(lines, "\n")
      end
  end

  local function row_for(m, id)
    for _, row in ipairs(m:list()) do
      if row.id == id then
        return row
      end
    end
  end

  local function methods(service, prefix)
    local out = {}
    for _, call in ipairs(service.calls) do
      if not prefix or call.method:sub(1, #prefix) == prefix then
        out[#out + 1] = call.method
      end
    end
    return out
  end

  t.describe("service installs through ade.setup", function()
    t.it("resolves, confirms and runs one install with live progress", function()
      local service, dir = start_service(t, "ok", { install_version = "0.4.0" })
      local _, manager_root = setup(t, "ok", service, dir)
      local notes, text = capture(t)
      local m = manager()

      local order = {}
      m.confirm = function(details)
        -- The confirmation must sit between resolve and run (PROTOCOL 16.3:
        -- no lock is held while a person decides).
        for _, call in ipairs(service.calls) do
          if call.method == "install.run" then
            error("install.run started before the confirmation")
          end
        end
        order[#order + 1] = "confirm:" .. tostring(details.version)
        return true
      end

      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)

      t.eq({ "install.resolve", "install.run" }, methods(service, "install."))
      t.eq("confirm:0.4.0", order[1])
      t.match("pi 0.4.0 installed", text())

      local row = row_for(m, "pi")
      t.eq("installed", row.status)
      t.eq("0.4.0", row.install.version)
      t.eq(nil, row.error)
      local log = table.concat(m.logs.pi or {}, "\n")
      t.match("%$ npm install", log)
      t.match("added 1 package", log)

      local run
      for _, call in ipairs(service.calls) do
        if call.method == "install.run" then
          run = call.params
        end
      end
      t.truthy(run, "install.run was never sent")
      t.eq("pi", run.agent)
      t.eq("install", run.action)
      t.eq("0.4.0", run.version)
      t.eq("@geohar/pi-acp", run.package)
      t.eq("dist/index.js", run.entry)
      t.eq(manager_root, run.root)
      t.match("^[A-Za-z0-9_%-]+$", run.job)
      t.truthy(type(run.env) == "table" and type(run.env.PATH) == "string", "the full environment must be sent")
      local expected_npm = vim.fn.exepath("npm")
      t.eq(expected_npm ~= "" and expected_npm or "npm", run.npm)
      t.eq(#notes > 0, true)
    end)

    t.it("update to the installed version is unchanged and writes no second release", function()
      local service, dir = start_service(t, "unchanged", { install_version = "0.4.0" })
      setup(t, "unchanged", service, dir)
      local _, text = capture(t)
      local m = manager()

      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      t.eq("installed", row_for(m, "pi").status)
      local releases_before = #m:store():list_install_ids("pi")

      t.eq(true, controller.update_agent("pi"))
      wait_idle(m)
      t.match("pi is already up to date %(0.4.0%)", text())
      t.eq("unchanged", row_for(m, "pi").outcome.phase)
      t.eq(releases_before, #m:store():list_install_ids("pi"), "an unchanged update must not build a release")
      local runs = 0
      for _, method in ipairs(methods(service, "install.")) do
        if method == "install.run" then
          runs = runs + 1
        end
      end
      t.eq(1, runs, "the unchanged update must not send install.run")
    end)

    t.it("shows the npm failure log", function()
      local service, dir = start_service(t, "fail", {
        install_version = "0.4.0",
        install_fail = true,
        install_log = "npm error boom",
      })
      setup(t, "fail", service, dir)
      local _, text = capture(t)
      local m = manager()

      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      t.match("install pi failed", text())
      local row = row_for(m, "pi")
      t.eq("failed", row.outcome.phase)
      t.eq("not_installed", row.status)
      local log = table.concat(m.logs.pi or {}, "\n")
      t.match("npm error boom", log)
    end)

    t.it("maps -32042 to the busy message", function()
      local service, dir = start_service(t, "busy", {
        install_version = "0.4.0",
        run_error = {
          code = -32042,
          message = "another instance is using this agent",
          data = { reason = "pid 99 is running" },
        },
      })
      setup(t, "busy", service, dir)
      local _, text = capture(t)
      local m = manager()

      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      t.match("pi: another instance is using this agent: pid 99 is running", text())
    end)

    t.it("maps -32044 to the cannot-remove message", function()
      local service, dir = start_service(t, "in-use", { install_version = "0.4.0" })
      setup(t, "in-use", service, dir)
      local m = manager()
      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)

      service.uninstall_error = {
        code = -32044,
        message = "the release is in use",
        data = { reason = "in use by pid 77" },
      }
      local _, text = capture(t)
      t.eq(true, controller.uninstall_agent("pi"))
      wait_idle(m)
      t.match("uninstall failed: cannot remove pi: in use by pid 77", text())
      t.eq("installed", row_for(m, "pi").status)
    end)

    t.it("maps -32045 to no manager-owned install", function()
      local service, dir = start_service(t, "nothing", { install_version = "0.4.0" })
      setup(t, "nothing", service, dir)
      local m = manager()
      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)

      service.uninstall_error = { code = -32045, message = "not installed" }
      local _, text = capture(t)
      t.eq(true, controller.uninstall_agent("pi"))
      wait_idle(m)
      t.match("uninstall failed: pi has no manager%-owned install", text())
    end)

    t.it("cancels a running install through the manager", function()
      local service, dir = start_service(t, "cancel", {
        install_version = "0.4.0",
        install_delay_ms = 4000,
      })
      setup(t, "cancel", service, dir)
      local m = manager()

      t.eq(true, controller.install_agent("pi"))
      wait(function()
        return next(service.install_jobs) ~= nil
      end, 10000, "the install job to reach the service")
      t.eq(true, m:can_cancel())
      t.eq(true, m:cancel("pi"))
      wait_idle(m)
      t.eq("cancelled", row_for(m, "pi").outcome.phase)
      t.eq("not_installed", row_for(m, "pi").status)
      t.eq(0, #m:store():list_install_ids("pi"), "the half-built release must be removed")
    end)

    t.it("shows another front end's job as busy", function()
      local service, dir = start_service(t, "foreign", { install_version = "0.4.0" })
      setup(t, "foreign", service, dir)
      local m = manager()
      -- Building the installer is what subscribes to install.progress.
      m:installer()

      service:broadcast("install.progress", {
        job = "other-front-end-1",
        agent = "pi",
        action = "install",
        phase = "installing",
        version = "0.4.0",
      })
      wait(function()
        return m:busy("pi") and m:busy()
      end, 5000, "the foreign job to show as busy")
      local row = row_for(m, "pi")
      t.eq("other-front-end-1", row.task.job)
      t.eq("installing", row.task.phase)
      t.truthy(row.task.foreign)

      service:broadcast("install.progress", {
        job = "other-front-end-1",
        agent = "pi",
        action = "install",
        phase = "committed",
        version = "0.4.0",
      })
      wait(function()
        return not m:busy("pi")
      end, 5000, "the foreign job to clear")
    end)

    t.it("checks outdated versions through install.resolve", function()
      local service, dir = start_service(t, "outdated", { install_version = "0.4.0" })
      setup(t, "outdated", service, dir)
      local m = manager()
      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      local latest_before = 0
      for _, call in ipairs(service.calls) do
        if call.method == "install.resolve" and call.params.spec == "latest" then
          latest_before = latest_before + 1
        end
      end
      service.latest_version = "0.5.0"

      local done = false
      m:check_outdated(function()
        done = true
      end)
      wait(function()
        return done
      end, 10000, "the outdated check")
      local row = row_for(m, "pi")
      t.eq("0.5.0", row.latest)
      t.eq(true, row.outdated)
      local latest_requests = 0
      for _, call in ipairs(service.calls) do
        if call.method == "install.resolve" and call.params.spec == "latest" then
          latest_requests = latest_requests + 1
          t.eq(60000, call.params.timeout_ms)
        end
      end
      t.eq(latest_before + 1, latest_requests)
    end)

    t.it("sends launch with attach and writes no Lua lease in service mode", function()
      local service, dir = start_service(t, "launch", { install_version = "0.4.0" })
      local _, manager_root = setup(t, "launch", service, dir, { agent = "pi" })
      local m = manager()
      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      local installed = assert(row_for(m, "pi").install)

      -- Count the Lua leases this connection asks for. The service writes its
      -- own lease before spawning (16.4); a second one from Neovim would keep
      -- the release alive after the editor exits, and would disappear exactly
      -- when the agent keeps running.
      local lease_calls = 0
      local locks = state().conn.locks
      local original_lease = locks.lease
      locks.lease = function(...)
        lease_calls = lease_calls + 1
        return original_lease(...)
      end
      t.cleanup(function()
        locks.lease = original_lease
      end)

      -- Connect the managed agent; the stand-in records the attach parameters.
      controller.connect()
      wait(function()
        return #service.attach_results > 0
      end, 10000, "agent.attach")
      local attach = service.attach_results[#service.attach_results]
      t.truthy(attach.launch, "agent.attach must carry the launch spec: " .. vim.inspect(attach))
      t.eq(manager_root, attach.launch.root)
      t.eq("pi", attach.launch.agent)
      t.eq(installed.installId, attach.launch.installId)
      -- The service writes the lease; Neovim must not keep a second one.
      t.eq(0, lease_calls, "service mode must not take a Lua lease")
      local leases = vim.fn.glob(manager_root .. "/.leases/pi/*", false, true)
      t.eq(0, #leases, "service mode must not write a Neovim lease: " .. vim.inspect(leases))
    end)

    t.it("falls back to the Lua installer when the service has no install feature", function()
      local service, dir = start_service(t, "old-service", {
        features = { "tunnel" },
        install_version = "0.4.0",
      })
      setup(t, "old-service", service, dir)
      local m = manager()
      -- The Lua installer would spawn the real npm; a scripted one keeps this
      -- offline while still proving which implementation ran.
      local runner = fake_npm.new({ version = "0.4.0" })
      m.injected.npm = npm_mod.new({
        run = runner.run,
        node = function()
          return "node"
        end,
        npm = function()
          return "npm"
        end,
      })

      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      t.eq({}, methods(service, "install."), "an old service must not receive install requests")
      local calls = {}
      for _, call in ipairs(runner.calls) do
        calls[#calls + 1] = call.argv[2]
      end
      t.eq({ "view", "install" }, calls)
      t.eq("installed", row_for(m, "pi").status)
      t.eq(false, m:can_cancel())
      t.eq(false, m:cancel("pi"))
    end)

    t.it("offers x as the cancel key in the window", function()
      local service, dir = start_service(t, "key", {
        install_version = "0.4.0",
        install_delay_ms = 4000,
      })
      setup(t, "key", service, dir)
      local m = manager()
      t.eq(true, controller.install_agent("pi"))
      wait(function()
        return next(service.install_jobs) ~= nil
      end, 10000, "the install job to reach the service")

      local ui = state().view.agent_manager
      ui:open()
      local found = false
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(ui.buf, "n")) do
        if map.lhs == "x" then
          found = true
        end
      end
      t.truthy(found, "the agents window has no x (cancel) mapping")
      ui.help = true
      ui:refresh()
      local rendered =
        table.concat(AgentManagerUI.render(m:list(), { help = true, expanded = {}, spinner = "-" }).lines, "\n")
      t.match("cancel", rendered)
      ui:close()
      t.eq(true, m:cancel("pi"))
      wait_idle(m)
    end)

    t.it("clears another front end's busy state on an unchanged update", function()
      local service, dir = start_service(t, "foreign-unchanged", { install_version = "0.4.0" })
      setup(t, "foreign-unchanged", service, dir)
      local m = manager()
      m:installer()

      service:broadcast("install.progress", {
        job = "other-front-end-2",
        agent = "pi",
        action = "update",
        phase = "checking",
      })
      wait(function()
        return m:busy("pi")
      end, 5000, "the foreign update to show as busy")

      -- `unchanged` is a terminal phase too (PROTOCOL.md 16.3):
      -- the other front end never gets a "committed" event for it.
      service:broadcast("install.progress", {
        job = "other-front-end-2",
        agent = "pi",
        action = "update",
        phase = "unchanged",
        version = "0.4.0",
      })
      wait(function()
        return not m:busy("pi")
      end, 5000, "the unchanged event to clear the busy state")
      t.eq(nil, m.foreign.pi)
    end)

    t.it("clears another front end's busy state when the service disconnects", function()
      local service, dir = start_service(t, "foreign-disconnect", { install_version = "0.4.0" })
      local connection = setup(t, "foreign-disconnect", service, dir)
      local m = manager()
      m:installer()

      service:broadcast("install.progress", {
        job = "other-front-end-3",
        agent = "pi",
        action = "install",
        phase = "installing",
      })
      wait(function()
        return m:busy("pi")
      end, 5000, "the foreign job to show as busy")

      -- A deliberate disconnect so the panel's own reconnect loop stays out of
      -- the way; no terminal event can arrive for the other front end's job.
      connection:on_disconnect("socket lost", true)
      wait(function()
        return not m:busy("pi")
      end, 5000, "the disconnect to clear the foreign job")
      t.eq(nil, m.foreign.pi)
      t.eq(nil, m._service_installer and m._service_installer.foreign.pi)
    end)

    t.it("cancels during resolve", function()
      local service, dir = start_service(t, "cancel-resolve", {
        install_version = "0.4.0",
        resolve_delay_ms = 2000,
      })
      setup(t, "cancel-resolve", service, dir)
      local m = manager()

      t.eq(true, controller.install_agent("pi"))
      wait(function()
        return m.tasks.pi ~= nil
      end, 5000, "the task to start")
      t.eq(true, m:cancel("pi"))
      wait_idle(m)
      t.eq("cancelled", row_for(m, "pi").outcome.phase)
      local cancel_requests = 0
      for _, call in ipairs(service.calls) do
        if call.method == "$/cancel_request" then
          cancel_requests = cancel_requests + 1
        end
      end
      t.truthy(cancel_requests >= 1, "cancelling during resolve must send $/cancel_request")
    end)

    t.it("cancels during confirmation and closes the picker", function()
      local service, dir = start_service(t, "cancel-confirm", { install_version = "0.4.0" })
      setup(t, "cancel-confirm", service, dir, { manager = { confirm = true } })
      local m = manager()

      local opened, closed = nil, false
      m.presenter = {
        select = function(opts)
          opened = opts
          return {
            close = function()
              closed = true
              if opts.on_cancel then
                opts.on_cancel()
              end
            end,
          }
        end,
      }

      t.eq(true, controller.install_agent("pi"))
      wait(function()
        return m.asking == 1 and opened ~= nil
      end, 10000, "the confirmation picker")
      t.eq(true, m:cancel("pi"))
      wait_idle(m)
      t.eq("cancelled", row_for(m, "pi").outcome.phase)
      t.eq(0, m.asking, "the asking counter must drop in the same tick")
      t.eq(true, closed, "the picker must be closed")
      t.eq(nil, m.pending_ask)
    end)

    t.it("remembers a cancel issued while ensure() is still connecting", function()
      local ServiceConnection = require("ade.service.connection")
      local sent, cancelled = nil, nil
      local connection = ServiceConnection.new()
      connection.client = {
        request = function(_, method, params)
          sent = { method = method, params = params }
          return 7
        end,
        notify = function(_, method, params)
          cancelled = { method = method, params = params }
          return true
        end,
        is_ready = function()
          return true
        end,
      }
      local resume
      connection.ensure = function(_, cb)
        resume = cb
      end

      local handle = connection:request_tracked("install.run", { job = "queued" }, function() end)
      t.eq(nil, handle.id)
      t.eq(true, connection:cancel_request(handle), "the intent is accepted before the id exists")
      t.eq(nil, cancelled)
      assert(resume, "ensure() was never called")
      resume(true)
      t.eq(7, handle.id)
      t.truthy(sent, "the request must still be sent")
      t.eq("$/cancel_request", cancelled and cancelled.method)
      t.eq(7, cancelled and cancelled.params.id)
    end)

    t.it("keeps a running install cancellable and logged after adopt()", function()
      local service, dir = start_service(t, "adopt", {
        install_version = "0.4.0",
        install_delay_ms = 1200,
      })
      setup(t, "adopt", service, dir)
      local m = manager()
      t.eq(true, controller.install_agent("pi"))
      wait(function()
        return next(service.install_jobs) ~= nil and m.logs.pi and #m.logs.pi > 0
      end, 15000, "the install to produce output")
      local logged = #m.logs.pi

      -- Reconfiguration builds a new Manager; the install is still running in
      -- the service under the same connection.
      local copy = vim.deepcopy(state().config)
      copy.agent = "opencode"
      controller.setup(copy, { discard_queued = true })
      local m2 = manager()
      t.truthy(m2._service_installer, "the new manager did not adopt the running installer")
      t.eq(true, m2:can_cancel("pi"), "the adopted task must still be cancellable")
      t.eq(logged, #m2.logs.pi, "the shared log must survive the reconfiguration")

      t.eq(true, m2:cancel("pi"))
      wait_idle(m2)
      t.eq("cancelled", row_for(m2, "pi").outcome.phase)
    end)

    t.it("the auto backend does not start the service to check versions", function()
      local service, dir = start_service(t, "auto", { install_version = "0.4.0" })
      local connection = setup(t, "auto", service, dir, { backend = "auto" })
      local m = manager()
      t.falsy(connection:is_connected(), "setup must not connect a service by itself")
      local done = false
      m:check_outdated(function()
        done = true
      end)
      wait(function()
        return done
      end, 5000, "the outdated check")
      t.falsy(connection:is_connected(), "check_outdated must not start the service in auto mode")
      t.eq(nil, m._service_installer)
      t.eq(0, #service.calls)
    end)

    t.it("keeps the Lua lease and sends no launch when the feature is missing", function()
      local service, dir = start_service(t, "no-feature", {
        features = { "tunnel" },
        install_version = "0.4.0",
      })
      local connection = setup(t, "no-feature", service, dir, { agent = "pi" })
      local m = manager()
      local runner = fake_npm.new({ version = "0.4.0" })
      m.injected.npm = npm_mod.new({
        run = runner.run,
        node = function()
          return "node"
        end,
        npm = function()
          return "npm"
        end,
      })
      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      t.eq("installed", row_for(m, "pi").status)

      local lease_calls = 0
      local locks = state().conn.locks
      local original_lease = locks.lease
      locks.lease = function(...)
        lease_calls = lease_calls + 1
        return original_lease(...)
      end
      t.cleanup(function()
        locks.lease = original_lease
      end)

      controller.connect()
      wait(function()
        return #service.attach_results > 0
      end, 10000, "agent.attach")
      local attach = service.attach_results[#service.attach_results]
      t.eq(nil, attach.launch, "a service without install must not receive launch")
      t.truthy(lease_calls >= 1, "Neovim must keep its own lease when the service cannot write one")
      t.truthy(connection:is_connected())
    end)

    t.it("generates a distinct job id per installer", function()
      local Config = require("ade.config")
      local Resolve = require("ade.manager.resolve")
      local JobInstaller = require("ade.service.installer")
      local cfg = Config.validate(Config.merge(Config.defaults, { manager = { root = tmpdir("jobs") } }))
      local jobs = {}
      local function installer()
        local connection = {
          subscribe = function() end,
          request_tracked = function(_, method, params, cb)
            if method == "install.resolve" then
              cb(true, { version = "0.4.0" })
              return { id = 0 }
            end
            jobs[#jobs + 1] = params.job
            return { id = #jobs }
          end,
          cancel_request = function() end,
        }
        return JobInstaller.new({
          config = function()
            return cfg
          end,
          connection = connection,
          store = Resolve.new_store(cfg),
        })
      end
      installer():install("pi", {
        confirm = function(_, answer)
          answer(true)
        end,
      }, function() end)
      installer():install("pi", {
        confirm = function(_, answer)
          answer(true)
        end,
      }, function() end)
      t.eq(2, #jobs)
      t.truthy(jobs[1] and jobs[2] and jobs[1] ~= jobs[2], "two installers must not generate the same job id")
      t.match("^[A-Za-z0-9_%-]+$", jobs[1])
      t.truthy(#jobs[1] <= 64 and #jobs[2] <= 64)
    end)

    t.it("adopting while a confirmation is open keeps asking and cancellation in sync", function()
      local service, dir = start_service(t, "adopt-ask", { install_version = "0.4.0" })
      setup(t, "adopt-ask", service, dir, { manager = { confirm = true } })
      local m = manager()
      local opened = nil
      m.presenter = {
        select = function(opts)
          opened = opts
          return { close = function() end }
        end,
      }

      t.eq(true, controller.install_agent("pi"))
      wait(function()
        return m.asking == 1 and opened ~= nil
      end, 10000, "the confirmation picker")

      -- Reconfiguration replaces the manager while the picker is open. The
      -- answer closure and the counter now live in the shared state.
      local copy = vim.deepcopy(state().config)
      copy.agent = "opencode"
      controller.setup(copy, { discard_queued = true })
      local m2 = manager()
      t.eq(1, m2.asking, "the open confirmation must be visible to the new manager")
      t.truthy(m2.pending_ask, "the new manager must own the pending confirmation")

      opened.on_choice(true)
      wait_idle(m2)
      t.eq(0, m2.asking, "answering must decrement the shared counter")
      t.eq(nil, m2.pending_ask, "the finished confirmation must be cleared")
      t.eq("done", row_for(m2, "pi").outcome.phase)

      -- `x` after the adopt must still cancel a real task (not be swallowed by
      -- a stale confirmation record).
      m2.confirm = function()
        return true
      end
      service.install_delay_ms = 3000
      t.eq(true, controller.install_agent("pi"))
      wait(function()
        return next(service.install_jobs) ~= nil
      end, 15000, "the second install job")
      t.eq(true, m2:cancel("pi"))
      wait_idle(m2)
      t.eq("cancelled", row_for(m2, "pi").outcome.phase)
    end)

    t.it("clears foreign busy state after adopt and disconnect", function()
      local service, dir = start_service(t, "adopt-disconnect", { install_version = "0.4.0" })
      local connection = setup(t, "adopt-disconnect", service, dir)
      local m = manager()
      m:installer()

      local copy = vim.deepcopy(state().config)
      copy.agent = "opencode"
      controller.setup(copy, { discard_queued = true })
      local m2 = manager()
      t.truthy(m2._service_installer)
      t.truthy(rawequal(m.state, m2.state), "the two managers must share the state table")

      service:broadcast("install.progress", {
        job = "other-front-end-4",
        agent = "pi",
        action = "install",
        phase = "installing",
      })
      wait(function()
        return m2:busy("pi")
      end, 5000, "the foreign job on the adopted manager")
      t.truthy(m2.foreign.pi)
      local foreign = m2.foreign
      m2.foreign = foreign

      connection:on_disconnect("lost after adopt", true)
      wait(function()
        return not m2:busy("pi")
      end, 5000, "the disconnect to clear the adopted foreign job")
      t.eq(nil, m2.foreign.pi)
      t.truthy(rawequal(foreign, m2.foreign), "foreign must be cleared in place, not replaced")
    end)

    t.it("a presenter that answers synchronously leaves no pending confirmation", function()
      local service, dir = start_service(t, "sync-presenter", { install_version = "0.4.0" })
      setup(t, "sync-presenter", service, dir, { manager = { confirm = true } })
      local m = manager()
      m.presenter = {
        select = function(opts)
          opts.on_choice(true)
          return nil
        end,
      }

      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      t.eq(0, m.asking)
      t.eq(nil, m.pending_ask, "a synchronous answer must not leave a finished record behind")

      service.install_delay_ms = 3000
      t.eq(true, controller.install_agent("pi"))
      wait(function()
        return next(service.install_jobs) ~= nil
      end, 15000, "the second install job")
      t.eq(true, m:cancel("pi"))
      wait_idle(m)
      t.eq("cancelled", row_for(m, "pi").outcome.phase)
    end)

    t.it("the installer itself can cancel during an uninstall confirmation", function()
      local service, dir = start_service(t, "uninstall-confirm", { install_version = "0.4.0" })
      setup(t, "uninstall-confirm", service, dir, { manager = { confirm = true } })
      local m = manager()
      m.confirm = function()
        return true
      end
      t.eq(true, controller.install_agent("pi"))
      wait_idle(m)
      t.eq("installed", row_for(m, "pi").status)

      local opened = nil
      m.confirm = nil
      m.presenter = {
        select = function(opts)
          opened = opts
          return { close = function() end }
        end,
      }
      t.eq(true, controller.uninstall_agent("pi"))
      wait(function()
        return m.asking == 1 and opened ~= nil
      end, 10000, "the uninstall confirmation")
      -- `x` goes through Manager:close_ask first; this covers the installer's
      -- own confirming branch, which must end the task without a request.
      t.eq(true, m._service_installer:cancel("pi"))
      wait_idle(m)
      t.eq("cancelled", row_for(m, "pi").outcome.phase)
      t.eq("installed", row_for(m, "pi").status, "cancelling the confirmation must not uninstall")
      t.eq(true, m:close_ask("pi"))
      t.eq(0, m.asking)
    end)
  end)
end
