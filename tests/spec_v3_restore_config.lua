-- Restored teams v3 coverage: the cwd configuration and the order it must
-- reach the service in before a session request (PROTOCOL.md 20.2).
--
-- Ported from `feat/teams-v3:tests/spec_s4_team.lua` (configure rejection,
-- in-flight serialization, missing feature/direct) and
-- `feat/teams-v3:tests/spec_w0e_team.lua` (the workflow/model/tool_style wire
-- shape and leader validation). The old leader_server/bind fixtures are gone:
-- v3 never injects an MCP server from the front end.
return function(t)
  local Version = require("ade.service.version")
  local Config = require("ade.config")
  local Team = require("ade.app.team")
  local fake = require("tests.fake_service")
  local ServiceConnection = require("ade.service.connection")
  local controller = require("ade.controller")
  local ade = require("ade")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local counter = 0

  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-v3cfg-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
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
      teams = { max_workers = 3, spawn_confirm = { auto = {} } },
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

  local function capture_notices(t)
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

  local function teams_config(over)
    return vim.tbl_deep_extend("force", {
      max_workers = 3,
      spawn_confirm = { auto = {} },
      templates = {},
      workflows = {},
    }, over or {})
  end

  local function offline_team(over)
    local cfg = Config.validate(vim.tbl_deep_extend("force", Config.defaults, {
      agents = {
        opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } },
        pi = { command = "pi-acp" },
      },
      teams = teams_config(over),
    }))
    return Team.new({
      config = function()
        return cfg
      end,
      connection = function()
        return nil
      end,
      resolve_cwd = function()
        return "/tmp/opencode/ade-v3cfg-offline"
      end,
      notify = function() end,
      on_changed = function() end,
    })
  end

  t.describe("teams v3 configuration", function()
    t.it("sends workflows, models and the tool style in team.configure", function()
      local team = offline_team({
        default = "dev",
        templates = {
          worker = { agent = "opencode", role = "plain", models = { "m1", "m2" } },
          reviewer = { agent = "pi" },
        },
        workflows = {
          dev = {
            text = "1. write\n2. review",
            team = { { name = "w1", template = "worker", model = "m1", task = "T1" } },
            columns = { "todo", "review" },
          },
        },
      })
      local config = team:service_config("/tmp/opencode/ade-v3cfg-offline")
      t.eq("dev", config.default_workflow)
      t.eq("1. write\n2. review", config.workflows.dev.text)
      -- 19.1 requires a summary on the wire; the first text line stands in.
      t.eq("1. write", config.workflows.dev.summary)
      t.eq("todo", config.workflows.dev.columns[1])
      t.eq({ "m1", "m2" }, config.templates.worker.models)
      t.eq("plain", config.templates.worker.role)
      t.eq("", config.templates.reviewer.role)
      t.eq("direct", config.templates.worker.tool_style)
      t.eq("mcp_proxy", config.templates.reviewer.tool_style, "pi reaches tools through its mcp proxy")
      -- The service owns the injection now: nothing about it is on this wire.
      t.eq(nil, config.derived)
    end)

    t.it("validates the leader fields and omits an empty leader", function()
      local function validate(over)
        return Config.validate(vim.tbl_deep_extend("force", Config.defaults, over or {}))
      end
      t.raises(function()
        validate({
          teams = teams_config({
            workflows = { dev = { summary = "x", leader = { agent = "not-an-agent" } } },
          }),
        })
      end)
      t.raises(function()
        validate({
          teams = teams_config({
            workflows = { dev = { summary = "x", leader = { role = string.rep("r", 4 * 1024 + 1) } } },
          }),
        })
      end)
      local cfg = validate({
        teams = teams_config({
          workflows = {
            dev = { summary = "x", leader = { agent = "claude", role = string.rep("r", 4 * 1024) } },
            empty = { summary = "y", leader = {} },
          },
        }),
      })
      t.eq(4 * 1024, #cfg.teams.workflows.dev.leader.role)
      local team = Team.new({
        config = function()
          return cfg
        end,
        connection = function()
          return nil
        end,
        resolve_cwd = function()
          return "/tmp/opencode/ade-v3cfg-leader"
        end,
        notify = function() end,
        on_changed = function() end,
      })
      local service_config = team:service_config("/tmp/opencode/ade-v3cfg-leader")
      t.eq("claude", service_config.workflows.dev.leader.agent)
      t.eq(nil, service_config.workflows.empty.leader, "an empty leader is omitted, not encoded as []")
    end)

    t.it("resolves an inherited template through the leader agent", function()
      local team = offline_team({
        templates = { worker = { agent = "inherit", role = "Inspect the code." } },
      })
      local config = team:service_config("/tmp/opencode/ade-v3cfg-offline")
      t.eq("opencode", config.templates.worker.key.agent)
      t.eq("Inspect the code.", config.templates.worker.role)
      t.eq("direct", config.templates.worker.tool_style)
    end)

    t.it("sends the configuration before the session request it configures", function()
      local service, dir = start_service(t, "configure-order")
      -- Record how many `team.configure` requests had been processed when each
      -- ACP frame was handed to the relay: PROTOCOL.md 20.2 needs the config in
      -- place *before* the session request, so the count must be non-zero.
      local configured_at_send = {}
      local raw_send = service.on_tunnel_send
      service.on_tunnel_send = function(self, params, client)
        local method = type(params) == "table" and type(params.message) == "table" and params.message.method or nil
        if method then
          local n = 0
          for _, call in ipairs(self.calls) do
            if call.method == "team.configure" then
              n = n + 1
            end
          end
          configured_at_send[method] = configured_at_send[method] or n
        end
        return raw_send(self, params, client)
      end
      t.cleanup(function()
        service.on_tunnel_send = raw_send
      end)
      setup(t, dir)
      controller.connect()
      wait_ready()
      wait(function()
        return #sent_frames(service, "session/new") == 1
      end, 10000, "the session request")
      t.truthy((configured_at_send["session/new"] or 0) >= 1, "team.configure preceded session/new")
    end)

    t.it("treats an all-unresolvable template set as unavailable and says why once", function()
      local service, dir = start_service(t, "all-skipped")
      setup(t, dir, {
        agents = { broken = { command = "broken", source = "managed" } },
        teams = teams_config({ templates = { broken = { agent = "broken", role = "You are broken." } } }),
      })
      local notices = capture_notices(t)
      controller.connect()
      wait_ready()
      vim.wait(100)
      t.eq(0, #calls_of(service, "team.configure"), "no configure request when every template is skipped")
      t.eq(0, #sent_frames(service, "session/new")[1].params.mcpServers)
      local skipped = 0
      for _, note in ipairs(notices) do
        if note.message:find("team template skipped", 1, true) then
          skipped = skipped + 1
        end
      end
      t.eq(1, skipped, "the broken template is explained exactly once")
      -- A second configure with the same broken template must not repeat it.
      state().view.team:configure(dir, true)
      vim.wait(100)
      skipped = 0
      for _, note in ipairs(notices) do
        if note.message:find("team template skipped", 1, true) then
          skipped = skipped + 1
        end
      end
      t.eq(1, skipped)
    end)

    t.it("reports a refused team.configure and still starts the session", function()
      local service, dir = start_service(t, "configure-failed", {
        team_configure_error = { code = -32060, message = "invalid configuration" },
      })
      setup(t, dir)
      local notices = capture_notices(t)
      controller.connect()
      wait_ready()
      wait(function()
        return #sent_frames(service, "session/new") == 1
      end, 10000, "the session request")
      local frames = sent_frames(service, "session/new")
      t.eq(1, #frames, "exactly one session/new")
      t.eq(0, #(frames[1].params.mcpServers or {}), "a refused configure injects nothing")
      wait(function()
        return joined(notices):find("will not get team tools", 1, true) ~= nil
      end, 5000, "the refused-configure notice")
      t.match("invalid configuration", joined(notices))
    end)

    t.it("keeps the newest configuration when one changes while it is in flight", function()
      local service, dir = start_service(t, "configure-slow", { team_configure_delay = 300 })
      setup(t, dir)
      controller.connect()
      wait(function()
        return #calls_of(service, "team.configure") == 1
      end, 5000, "the slow configure")
      -- Change the configuration while the first request is still unanswered.
      state().config.teams.templates = { reviewer = { agent = "opencode", role = "you review" } }
      state().view.team:configure(dir, true)
      wait(function()
        return #calls_of(service, "team.configure") == 2
      end, 10000, "the serialized configuration")
      local first = calls_of(service, "team.configure")[1].params.config
      local second = calls_of(service, "team.configure")[2].params.config
      t.eq(nil, first.templates.reviewer)
      t.truthy(second.templates.reviewer, "the reply carries the newest configuration")
      t.eq("you review", second.templates.reviewer.role)
    end)

    t.it("does not touch the service without the teams feature", function()
      local service, dir = start_service(t, "no-feature", { features = { "tunnel", "log" } })
      setup(t, dir)
      controller.connect()
      wait_ready()
      vim.wait(100)
      for _, call in ipairs(service.calls) do
        t.falsy(
          type(call.method) == "string" and call.method:sub(1, 5) == "team.",
          "no team request without the feature: " .. tostring(call.method)
        )
      end
      t.eq(0, #(sent_frames(service, "session/new")[1].params.mcpServers or {}))
    end)

    t.it("sends no team request on the direct backend", function()
      local service, dir = start_service(t, "direct")
      setup(t, dir, { backend = "direct" })
      controller.connect()
      wait_ready()
      vim.wait(100)
      t.eq(0, #service.calls, "direct mode never contacts the service")
      t.eq(0, #service.sent)
    end)

    t.it("sends enabled = false instead of going quiet when teams are disabled", function()
      local service, dir = start_service(t, "disabled")
      setup(t, dir, { teams = teams_config({ enabled = false }) })
      controller.connect()
      wait_ready()
      wait(function()
        return #calls_of(service, "team.configure") >= 1
      end, 5000, "the configuration")
      local config = calls_of(service, "team.configure")[1].params.config
      t.eq(false, config.enabled)
      t.eq(0, #service.team_starts, "a disabled configuration starts nothing")
    end)
  end)
end
