-- Permission policy installed into the service (PROTOCOL.md section 17).
--
-- Everything goes through `require("ade").setup`, the public controller and
-- the real service connection layer; the service itself is the in-process
-- stand-in.
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local Config = require("ade.config")
  local ade = require("ade")
  local async = require("ade.async")
  local Framing = require("ade.transport.framing")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-s3-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  ---A stand-in service with a real mock agent, so sessions can be created.
  local function start_service(t, tag, opts)
    local dir = tmpdir(tag)
    local service = fake.new(vim.tbl_extend("force", {
      dir = dir,
      features = { "tunnel", "policy" },
    }, opts or {}))
    local jobs = {}
    service.spawn_agent = function(instance)
      local decoder = Framing.new_decoder()
      local job = vim.fn.jobstart({ "python3", root .. "tests/mock_agent.py" }, {
        stdin = "pipe",
        stdout_buffered = false,
        on_stdout = function(_, data)
          for _, chunk in ipairs(data or {}) do
            if chunk ~= "" then
              decoder:feed(chunk .. "\n", function(line)
                if line == "" then
                  return
                end
                local ok, message = pcall(vim.json.decode, line)
                if ok and type(message) == "table" then
                  service:deliver(instance, message)
                end
              end)
            end
          end
        end,
      })
      jobs[#jobs + 1] = job
      instance.handler = function(message)
        pcall(vim.fn.chansend, job, vim.json.encode(message) .. "\n")
      end
      instance.stop_agent = function()
        pcall(vim.fn.jobstop, job)
      end
      return job > 0
    end
    assert(service:listen(), "the stand-in service could not listen")
    t.cleanup(function()
      for _, job in ipairs(jobs) do
        pcall(vim.fn.jobstop, job)
      end
      pcall(service.close, service)
    end)
    return service, dir
  end

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
    ade.setup(vim.tbl_deep_extend("force", {
      backend = "service",
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      service = { keep_alive = true, idle_timeout = 60 },
      manager = { root = dir .. "/agents" },
      permissions = { auto_allow = { "allow_once", "allow_always" } },
      ui = {},
      layout = { input_height = 6 },
    }, overrides or {}))
    return connection
  end

  local function state()
    return controller.state()
  end

  local function wait(cond, timeout, label)
    local ok = vim.wait(timeout or 20000, cond, 20)
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

  local function ensure(connection)
    local ready = false
    connection:ensure(function(ok)
      ready = ok == true
    end)
    t.truthy(ready, "the stand-in service did not accept the connection")
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

  local function set_for(service, name)
    return service.policy_sets[name]
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

  local function transcript()
    local lines = {}
    local S = state()
    if S.sess.current then
      for _, block in ipairs(S.sess.current.blocks or {}) do
        if block.kind == "notice" and type(block.text) == "string" then
          lines[#lines + 1] = block.text
        end
      end
    end
    return table.concat(lines, "\n")
  end

  t.describe("service permission policy", function()
    t.it("installs the config set after hello with the exact rule shape", function()
      local service, dir = start_service(t, "config", { install_version = "0.4.0" })
      local connection = setup(t, "config", service, dir)
      ensure(connection)
      wait(function()
        return set_for(service, "config") ~= nil
      end, 5000, "the config policy set")

      local set = set_for(service, "config")
      t.eq("config", set.name)
      t.eq("service", set.keep)
      t.eq(0, set.priority)
      t.eq(true, set.allow_always)
      t.eq(1, #set.rules)
      t.eq({ "allow_once", "allow_always" }, set.rules[1].choose)
      t.eq("offered", set.rules[1].pick)
      t.truthy(set.owner, "the stand-in records an owner")
    end)

    t.it("clears the config set when auto_allow becomes empty and re-sends later", function()
      local service, dir = start_service(t, "config-change", { install_version = "0.4.0" })
      local connection = setup(t, "config-change", service, dir)
      ensure(connection)
      wait(function()
        return set_for(service, "config") ~= nil
      end, 5000, "the first config set")

      local empty = vim.deepcopy(state().config)
      empty.permissions.auto_allow = {}
      controller.setup(empty, { discard_queued = true })
      wait(function()
        return set_for(service, "config") == nil
      end, 5000, "the config set to be cleared")
      t.truthy(#calls_of(service, "policy.clear") >= 1)

      local again = vim.deepcopy(state().config)
      again.permissions.auto_allow = { "allow_once" }
      controller.setup(again, { discard_queued = true })
      wait(function()
        return set_for(service, "config") ~= nil
      end, 5000, "the config set to be re-installed")
      t.eq({ "allow_once" }, set_for(service, "config").rules[1].choose)
      t.eq(false, set_for(service, "config").allow_always)
    end)

    t.it("installs the inline set with 17.6 ordering", function()
      local service, dir = start_service(t, "inline-set", { install_version = "0.4.0" })
      local connection = setup(t, "inline-set", service, dir, {
        inline = { allow_writes = true, allow_commands = true, allow_kinds = { "delete" } },
      })
      ensure(connection)
      local S = state()
      local inv = {
        session = { id = "sess-1", cwd = "/tmp/work" },
        copy = "/tmp/work/.ade-inline-1.lua",
        config = S.config,
        phase = "running",
      }
      local done = false
      async.run(function()
        done = true
        S.conn.policy:prepare_inline(inv)
      end)
      wait(function()
        return done and set_for(service, "inline:sess-1") ~= nil
      end, 5000, "the inline set")

      local set = set_for(service, "inline:sess-1")
      t.eq("inline:sess-1", set.name)
      t.eq("sess-1", set.session)
      t.eq("turn_end", set["until"])
      t.eq(100, set.priority)
      t.eq("cancelled", set.fallback)
      t.eq("/tmp/work", set.cwd)
      t.eq(4, #set.rules)
      -- 1. the private copy only
      t.eq({ "edit" }, set.rules[1].kinds)
      t.eq({ inv.copy }, set.rules[1].paths)
      t.eq({ "allow_once", "reject_once" }, set.rules[1].choose)
      -- 2. allow_writes makes every edit acceptable
      t.eq({ "edit" }, set.rules[2].kinds)
      t.eq(nil, set.rules[2].paths)
      -- 3. the always-allowed, configured extra kinds (and execute)
      local kinds = set.rules[3].kinds
      local seen = {}
      for _, kind in ipairs(kinds) do
        seen[kind] = true
      end
      t.truthy(seen.read and seen.search and seen.think and seen.fetch and seen.delete and seen.execute)
      -- 4. everything else is refused
      t.eq({ "reject_once" }, set.rules[4].choose)
      t.eq(nil, set.rules[4].kinds)
    end)

    t.it("omits the allow_writes rule when writes are not allowed", function()
      local service, dir = start_service(t, "inline-nowrites", { install_version = "0.4.0" })
      local connection = setup(t, "inline-nowrites", service, dir)
      ensure(connection)
      local S = state()
      local inv = {
        session = { id = "sess-2", cwd = "/tmp/work" },
        copy = "/tmp/work/.ade-inline-2.lua",
        config = S.config,
        phase = "running",
      }
      local done = false
      async.run(function()
        done = true
        S.conn.policy:prepare_inline(inv)
      end)
      wait(function()
        return done and set_for(service, "inline:sess-2") ~= nil
      end, 5000, "the inline set")
      local set = set_for(service, "inline:sess-2")
      t.eq(3, #set.rules)
      t.eq({ "edit" }, set.rules[1].kinds)
      t.eq(nil, set.rules[2].paths)
      t.eq({ "reject_once" }, set.rules[3].choose)
      t.eq(nil, inv.policy_fallback)
    end)

    t.it("waits for the policy.set reply before sending session/prompt", function()
      local Prompts = require("ade.app.prompts")
      local Tasks = require("ade.tasks")
      local order = {}
      local client = {
        generation = 1,
        is_ready = function()
          return true
        end,
        prompt = function()
          order[#order + 1] = "prompt"
          return true, { stopReason = "end_turn" }
        end,
      }
      local session = { id = "sess-order", cwd = "/tmp", status = "idle", queue = {}, blocks = {}, turn = 0 }
      local runtime = {
        replays = {},
        owns = function()
          return true
        end,
        begin_turn = function(_, target)
          target.turn = target.turn + 1
          target.status = "running"
          return target.turn
        end,
        finish_turn = function(_, target)
          target.status = "idle"
        end,
        enqueue = function()
          return true
        end,
      }
      local policy = {
        prepare_inline = function()
          return async.await(function(done)
            order[#order + 1] = "policy-sent"
            vim.defer_fn(function()
              order[#order + 1] = "policy-replied"
              done(true)
            end, 30)
          end)
        end,
      }
      local scope = Tasks.new(function()
        return { client = client, sessions = { [session.id] = session }, runtime = runtime }
      end)
      local prompts = Prompts.new({
        config = function()
          return Config.defaults
        end,
        runtime = function()
          return runtime
        end,
        client = function()
          return client
        end,
        connection = function()
          return "ready"
        end,
        run = function(key, c, s, fn, on_error, on_finally)
          return scope:run(key, c, s, fn, on_error, on_finally)
        end,
        policy = function()
          return policy
        end,
        selected = function()
          return true
        end,
        on_turn_start = function() end,
        on_turn_end = function() end,
        on_changed = function() end,
        on_render = function() end,
        add_block = function() end,
        prune = function() end,
        dispatch_queued = function() end,
        refresh_title = function() end,
        notify = function() end,
      })
      local accepted = prompts:send(session, "hello", nil, { inline = { session = session } })
      t.eq(true, accepted)
      wait(function()
        return order[#order] == "prompt" and session.status == "idle"
      end, 5000, "the prompt to be sent")
      t.eq({ "policy-sent", "policy-replied", "prompt" }, order)
    end)

    t.it("falls back to the Lua inline policy when policy.set fails", function()
      local service, dir = start_service(t, "inline-fail", {
        install_version = "0.4.0",
        policy_error = { code = -32050, message = "invalid rule set: cwd" },
      })
      local connection = setup(t, "inline-fail", service, dir)
      ensure(connection)
      local S = state()
      local inv = {
        session = { id = "sess-3", cwd = "/tmp/work" },
        copy = "/tmp/work/.ade-inline-3.lua",
        config = S.config,
        phase = "running",
      }
      local done, ok = false, true
      async.run(function()
        ok = S.conn.policy:prepare_inline(inv)
        done = true
      end)
      wait(function()
        return done
      end, 5000, "the failed policy.set")
      t.eq(false, ok)
      t.eq(true, inv.policy_fallback, "the turn must fall back to the Lua inline policy")
    end)

    t.it("does not run the Lua auto policy while the service provides policy", function()
      local service, dir = start_service(t, "gate", { install_version = "0.4.0" })
      local connection = setup(t, "gate", service, dir)
      ensure(connection)
      local interaction = {
        type = "permission",
        session_id = "sess-gate",
        request = {
          options = { { kind = "allow_once", optionId = "a" }, { kind = "reject_once", optionId = "r" } },
          toolCall = { kind = "read" },
        },
      }
      local policies = state().view.interactions.policies
      t.eq(nil, policies[2](interaction), "the service owns auto_allow when it provides policy")

      -- Without the feature the Lua policy keeps answering, exactly as before.
      local old_service, old_dir = start_service(t, "gate-old", {
        install_version = "0.4.0",
        features = { "tunnel" },
      })
      local old_connection = setup(t, "gate-old", old_service, old_dir)
      ensure(old_connection)
      interaction.session_id = "sess-old"
      local old_policies = state().view.interactions.policies
      local response = old_policies[2](interaction)
      t.truthy(response, "without policy the Lua auto_allow must still answer")
      t.eq("selected", response.outcome.outcome)
    end)

    t.it("shows policy.applied and replays _ade_policy without errors", function()
      local service, dir = start_service(t, "applied", { install_version = "0.4.0" })
      setup(t, "applied", service, dir)
      local S = state()
      controller.connect()
      wait_ready()
      local session = assert(S.sess.current)

      service:policy_applied({
        instance = "inst-1",
        sessionId = session.id,
        set = { name = "config" },
        outcome = "selected",
        optionId = "allow_once",
        kind = "read",
        toolCall = { toolCallId = "tool-1", kind = "read", title = "Read notes.txt" },
      })
      wait(function()
        return transcript():find("auto%-allowed read") ~= nil
      end, 5000, "the live policy notice")
      t.match("Read notes%.txt", transcript())

      local before = #session.blocks
      local applied = { sessionUpdate = "_ade_policy", set = { name = "inline:" .. session.id }, outcome = "cancelled" }
      local _, changed = S.sess.runtime:apply(session.id, applied)
      t.eq(true, changed, "the reducer must accept _ade_policy")
      t.eq(before + 1, #session.blocks)
      t.match("auto%-cancelled", transcript())

      -- A genuinely unknown update is still ignored quietly.
      local _, unknown_changed = S.sess.runtime:apply(session.id, { sessionUpdate = "_ade_unknown", x = 1 })
      t.eq(false, unknown_changed)
    end)

    t.it("an inline turn installs its set before the prompt (public entry)", function()
      local service, dir = start_service(t, "inline-e2e", {
        install_version = "0.4.0",
        policy_delay_ms = 80,
      })
      setup(t, "inline-e2e", service, dir)
      ade.open()
      controller.connect()
      wait_ready()
      local file = dir .. "/sample.lua"
      local handle = assert(io.open(file, "wb"))
      handle:write("local marker = 1\n")
      handle:close()
      vim.cmd("tabnew " .. vim.fn.fnameescape(file))
      local buf = vim.api.nvim_get_current_buf()
      t.cleanup(function()
        pcall(function()
          require("ade.inline").stop()
        end)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      require("ade.inline").open({
        review = "write",
        mode = "V",
        pos1 = { 0, 1, 1, 0 },
        pos2 = { 0, 1, 1, 0 },
      })
      wait(function()
        return vim.bo[vim.api.nvim_get_current_buf()].filetype == "ade_inline"
      end, 5000, "the inline prompt")
      vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "replace the marker" })
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
      wait(function()
        return service.policy_before_prompt ~= nil
      end, 15000, "the session/prompt frame")
      t.truthy(service.policy_before_prompt >= 1, "session/prompt was sent before the policy.set reply")
      local session_id = state().sess.current.id
      local set = set_for(service, "inline:" .. session_id)
      t.truthy(set, "the inline set was not installed")
      t.eq(session_id, set.session)
      t.eq("turn_end", set["until"])
      t.eq(100, set.priority)
      t.eq({ "reject_once" }, set.rules[#set.rules].choose)
    end)

    t.it("defaults the backend to auto and falls back to direct", function()
      t.eq("auto", Config.defaults.backend)
      local notices = capture(t)
      local dir = tmpdir("direct")
      local saved_dir = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir .. "/server"
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved_dir
      end)
      local ServiceConnection = require("ade.service.connection")
      local previous = ServiceConnection.shared()
      ServiceConnection.set_shared(ServiceConnection.new({
        resolve_binary = function()
          return nil, "nvim_ade_server is not installed"
        end,
      }))
      t.cleanup(function()
        pcall(function()
          ServiceConnection.set_shared(previous)
        end)
      end)
      ade.setup({
        backend = "auto",
        agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
        service = { path = "/nonexistent/nvim_ade_server" },
        ui = {},
        layout = { input_height = 6 },
        manager = { root = dir .. "/agents" },
      })
      controller.connect()
      wait(function()
        return state().conn.phase == "ready"
      end, 20000, "the direct fallback to connect")
      local text = {}
      for _, note in ipairs(notices) do
        text[#text + 1] = note.message
      end
      t.match("using the direct backend", table.concat(text, "\n"))
    end)
  end)
end
