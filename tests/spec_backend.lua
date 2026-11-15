-- Backend selection: direct, service and auto.
--
-- `service` is explicit, so an unusable service is an error and never a silent
-- fallback. `auto` warns exactly once and falls back. Direct never touches the
-- service. The chat behaviour of the direct backend is covered by the existing
-- specs; these cases only check which one is chosen.
return function(t)
  local Connection = require("ade.app.connection")

  ---A connection object with no real dependencies beyond what selection needs.
  local function harness(service)
    local notified = {}
    local conn
    conn = Connection.new({
      config = function()
        return { backend = "service", agents = {}, service = {} }
      end,
      service = service,
      state = function()
        return { conn = {} }
      end,
      resolve_cwd = function()
        return "/tmp"
      end,
      generation = function()
        return 1
      end,
      reset_operations = function() end,
      on_event = function() end,
      notify = function(message, level)
        notified[#notified + 1] = { message = message, level = level }
      end,
      on_changed = function() end,
      on_ready = function() end,
      on_start_failed = function() end,
      on_stopped = function() end,
      runtime_lost = function() end,
      reset_permissions = function() end,
      stop_animation = function() end,
      interactions = function()
        return nil
      end,
      on_render = function() end,
      store = function()
        return {}
      end,
    })
    return conn, notified
  end

  local function service_that(ok, err)
    return {
      ensure = function(_, cb)
        cb(ok, err)
      end,
      idle_timeout = nil,
    }
  end

  t.describe("backend selection", function()
    t.it("never touches the service for the direct backend", function()
      local touched = false
      local conn = harness({
        ensure = function()
          touched = true
        end,
      })
      local use_service, err = conn:use_service({ backend = "direct" })
      t.eq(false, use_service)
      t.eq(nil, err)
      t.eq(false, touched, "direct must not resolve or start the service")
    end)

    t.it("uses the service when it is available", function()
      local conn = harness(service_that(true))
      local use_service, err = conn:use_service({ backend = "service", service = {} })
      t.eq(true, use_service)
      t.eq(nil, err)

      local auto, auto_err = conn:use_service({ backend = "auto", service = {} })
      t.eq(true, auto)
      t.eq(nil, auto_err)
    end)

    t.it("fails loudly for backend = service when it is unusable", function()
      local conn, notified = harness(service_that(false, "nvim_ade_server is not installed"))
      local use_service, err = conn:use_service({ backend = "service", service = {} })
      t.eq(nil, use_service, "an explicit service backend must not fall back")
      t.truthy(err)
      t.match('backend = "service"', err)
      t.match("Ade service install", err)
      t.match("not installed", err)
      t.eq(0, #notified, "the error is reported by the caller, not as a fallback notice")
    end)

    t.it("falls back to direct for auto, warning only once", function()
      local conn, notified = harness(service_that(false, "nvim_ade_server is not installed"))
      local cfg = { backend = "auto", service = {} }
      local first, err = conn:use_service(cfg)
      t.eq(false, first)
      t.eq(nil, err)
      t.eq(1, #notified)
      t.match("direct backend", notified[1].message)
      t.eq(vim.log.levels.WARN, notified[1].level)

      -- A reconnect must not repeat the same warning every time.
      local second = conn:use_service(cfg)
      t.eq(false, second)
      t.eq(1, #notified, "the auto fallback notice is a one-off")
    end)

    t.it("reuses the shared connection across selections", function()
      local conn = harness(nil)
      local shared = conn:service_connection()
      t.truthy(shared)
      t.eq(shared, conn:service_connection(), "one socket per editor")
    end)
  end)
end
