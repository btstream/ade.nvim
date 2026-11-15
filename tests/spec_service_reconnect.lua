-- Reconnecting after the service connection drops.
--
-- PROTOCOL.md 7 and 9: a front end that loses its connection reconnects and
-- re-attaches. Three cases have to be distinguished, and only one of them may
-- be permanent:
--
--   * the service died / the socket broke  -> the *socket client* is dead, the
--     shared connection object stays usable; the next ensure() starts the
--     service again and greets it;
--   * the user ran `:Ade service stop`     -> same: they stopped the service,
--     not the ability to use it later;
--   * the editor is exiting (close())      -> permanent.
--
-- Old instance channels never come back to life; the Client's reconnect flow
-- creates new ones.
return function(t)
  local Version = require("ade.service.version")
  local fake = require("tests.fake_service")
  local Connection = require("ade.service.connection")

  local counter = 0
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-reconnect-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.mkdir(dir, "p", 448)
    t.cleanup(function()
      vim.fn.delete(dir, "rf")
    end)
    return dir
  end

  ---A stand-in service on its own socket directory.
  local function start_service(tag)
    local dir = tmpdir(tag)
    local service = fake.new({ dir = dir })
    service.spawn_agent = function()
      return true
    end
    assert(service:listen())
    t.cleanup(function()
      service:close()
    end)
    return service, dir
  end

  ---A connection whose service is the stand-in: `ensure_service` succeeds as
  ---long as a stand-in is listening on the shared directory.
  local function new_connection(dir, service)
    local saved = vim.env.NVIM_ADE_SERVER_DIR
    vim.env.NVIM_ADE_SERVER_DIR = dir
    t.cleanup(function()
      vim.env.NVIM_ADE_SERVER_DIR = saved
    end)
    local starts = 0
    local connection = Connection.new({
      resolve_binary = function()
        return {
          path = "/fake/nvim_ade_server",
          version = Version.VERSION,
          api_version = Version.API_VERSION,
        }
      end,
      ensure_service = function()
        starts = starts + 1
        -- "Started" means the stand-in is still listening on the shared dir.
        local up = service and service.server ~= nil
        return up, up and nil or "nvim_ade_server is not installed"
      end,
      timeout = 3000,
    })
    t.cleanup(function()
      connection:close()
    end)
    return connection, function()
      return starts
    end
  end

  ---`ensure()` and report whether it succeeded.
  local function ensure(connection)
    local ok, err
    connection:ensure(function(result, reason)
      ok, err = result, reason
    end)
    return ok, err
  end

  t.describe("service reconnection", function()
    t.it("reconnects after the service dies", function()
      local service, dir = start_service("dead")
      local connection = new_connection(dir, service)
      local ok, err = ensure(connection)
      t.truthy(ok, tostring(err))
      t.truthy(connection:is_connected())

      -- The service is killed: the socket closes.
      service:close()
      vim.wait(2000, function()
        return not connection:is_connected()
      end, 10)
      t.falsy(connection:is_connected(), "the dropped connection is still reported as connected")

      -- A new service instance on the same directory: the next ensure() must
      -- start talking again, not answer "connection was closed".
      local again = fake.new({ dir = dir })
      again.spawn_agent = function()
        return true
      end
      assert(again:listen())
      t.cleanup(function()
        again:close()
      end)
      -- The injectable starter points at the object it was given; swap it for
      -- the replacement so "the service is up again" is observable.
      connection.ensure_service = function()
        return true
      end
      local reconnected, reconnect_err = ensure(connection)
      t.truthy(reconnected, tostring(reconnect_err))
      t.truthy(connection:is_connected(), "ensure() did not re-establish the connection")
      t.truthy(connection.client ~= nil)
    end)

    t.it("reconnects after the user stopped the service", function()
      local service, dir = start_service("stopped")
      local connection = new_connection(dir, service)
      assert(ensure(connection))
      -- `:Ade service stop` closes the connection from our side; that must not
      -- disable the editor for good.
      connection:shutdown(function() end)
      vim.wait(2000, function()
        return not connection:is_connected()
      end, 10)

      local restarted = fake.new({ dir = dir })
      restarted.spawn_agent = function()
        return true
      end
      assert(restarted:listen())
      t.cleanup(function()
        restarted:close()
      end)
      connection.ensure_service = function()
        return true
      end
      local ok, err = ensure(connection)
      t.truthy(ok, tostring(err))
      t.truthy(connection:is_connected(), "a stopped service could not be started again")
    end)

    t.it("stays closed after the editor exits", function()
      local service, dir = start_service("exiting")
      local connection = new_connection(dir, service)
      assert(ensure(connection))
      connection:close()
      local ok, err = ensure(connection)
      t.falsy(ok, "a closed connection must not reopen")
      t.match("closed", tostring(err))
    end)

    t.it("coalesces concurrent ensure() calls into one connection", function()
      local service, dir = start_service("concurrent")
      local connection, starts = new_connection(dir, service)
      local results = {}
      for index = 1, 5 do
        connection:ensure(function(ok)
          results[index] = ok
        end)
      end
      t.eq(5, #results, "all callers must be answered")
      for _, value in ipairs(results) do
        t.truthy(value)
      end
      t.eq(1, starts(), "the service must be started once, not once per caller")
      t.eq(1, #service.clients, "only one socket for concurrent callers")
    end)

    t.it("does not revive an old instance channel", function()
      -- Channels report their own exit when the connection drops, and the
      -- reconnect flow creates new ones; nothing may resurrect the old one.
      local service, dir = start_service("channels")
      local connection = new_connection(dir, service)
      assert(ensure(connection))
      local exits = 0
      connection:subscribe("old", "__disconnected", function()
        exits = exits + 1
      end)
      service:close()
      vim.wait(2000, function()
        return exits > 0
      end, 10)
      t.eq(1, exits)

      local again = fake.new({ dir = dir })
      assert(again:listen())
      t.cleanup(function()
        again:close()
      end)
      connection.ensure_service = function()
        return true
      end
      assert(ensure(connection))
      t.eq(1, exits, "reconnecting must not re-notify the old channel")
      -- The old subscription is still registered, but the channel itself is
      -- gone: a second drop is what would tell. Assert the state instead.
      t.truthy(connection:is_connected())
    end)
  end)
end
