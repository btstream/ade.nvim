-- Leaving Neovim must not forget the sessions in the service.
--
-- A session the service forgets (a successful `session/close`, PROTOCOL.md 11)
-- can never be reopened: the event log still has the events, but `attach` no
-- longer lists it and `session/load` is forwarded to an agent that has no such
-- session. Exiting the editor is not the user saying "I do not want this
-- conversation any more" — it is the same intent as `:qa`, and the agent was
-- kept alive on purpose (`keep_alive`), precisely so it could be reopened.
--
-- So the exit path only sends `session/close` when the client is *not* going to
-- detach: the direct backend, `keep_alive = false`, and any failure path where
-- the agent is actually stopped. Explicit switching and deleting are unchanged:
-- there the user asked for the session to be released.
return function(t)
  local Sessions = require("ade.app.sessions")

  ---A `Sessions` object over a fake client and runtime.
  ---@param opts {detach: boolean, close_capability?: boolean, sessions?: table[]}
  local function harness(opts)
    opts = opts or {}
    local record = { closed = {}, calls = {} }
    local runtime = { sessions = {} }
    function runtime:remove(session_id)
      self.sessions[session_id] = nil
    end
    for _, session in ipairs(opts.sessions or {}) do
      runtime.sessions[session.id] = session
    end
    local client = {
      close_session = function(_, session_id)
        record.closed[#record.closed + 1] = session_id
        return true, {}
      end,
      will_detach = function(_)
        return opts.detach == true
      end,
      has_session_capability = function(_, name)
        if name == "loadSession" then
          return true
        end
        if name == "close" then
          return opts.close_capability ~= false
        end
        return false
      end,
      agent_capabilities = function(_)
        return { loadSession = true, sessionCapabilities = { close = {} } }
      end,
    }
    local service = Sessions.new({
      config = function()
        return { backend = "service" }
      end,
      runtime = function()
        return runtime
      end,
      catalog = {
        session_cwd = function()
          return "/tmp"
        end,
        cwds = function()
          return {}
        end,
        refresh_title = function() end,
        apply_title = function() end,
        forget = function() end,
        list = function(_, cb)
          cb(true, {})
        end,
      },
      client = function()
        return client
      end,
      connection = function()
        return "ready"
      end,
      generation = function()
        return 1
      end,
      new_local = function(id, cwd)
        return { id = id, cwd = cwd, blocks = {}, queue = {} }
      end,
      resolve_cwd = function()
        return "/tmp"
      end,
      run = function(_, _, _, fn, _, on_finally)
        local task = {}
        -- `task:call(...)` passes the task as the first argument.
        function task.call(_, method, session_id, ...)
          record.calls[#record.calls + 1] = method
          -- Route the two calls this module makes back to the fake client, so
          -- "which session/close was sent" is asserted on the real path.
          if method == "close_session" and client.close_session then
            return client.close_session(client, session_id)
          end
          return true, {}
        end
        fn(task)
        if on_finally then
          on_finally(task, true)
        end
      end,
      cancel_session = function() end,
      current = function()
        return nil
      end,
      activate = function() end,
      render = function() end,
      dispatch_queued = function() end,
      on_changed = function() end,
      on_replaying = function() end,
      on_creating = function() end,
      prune = function() end,
      notify = function() end,
    })
    return service, record, client
  end

  local function two_sessions()
    return {
      { id = "s1", status = "idle", blocks = {}, queue = {} },
      { id = "s2", status = "idle", blocks = {}, queue = {} },
    }
  end

  t.describe("sessions on editor exit", function()
    t.it("are not closed when the client will detach", function()
      local service, record = harness({ detach = true, sessions = two_sessions() })
      service:close_all_on_exit()
      t.eq({}, record.closed, "exiting must not forget the sessions")
    end)

    t.it("are closed when the agent will be stopped", function()
      -- `keep_alive = false`, the direct backend and every failure path leave a
      -- dead agent behind: its sessions cannot be reopened, so releasing them
      -- is still correct.
      local service, record = harness({ detach = false, sessions = two_sessions() })
      service:close_all_on_exit()
      table.sort(record.closed)
      t.eq({ "s1", "s2" }, record.closed)
    end)

    t.it("are closed when an agent has no close capability to begin with", function()
      local service, record = harness({ detach = false, sessions = two_sessions(), close_capability = false })
      service:close_all_on_exit()
      t.eq({}, record.closed)
    end)
  end)

  t.describe("explicit session operations", function()
    t.it("still close the session being deleted", function()
      local service, record = harness({ detach = true, sessions = two_sessions() })
      local done
      service:delete("s1", function(ok)
        done = ok
      end)
      t.eq(true, done)
      t.eq({ "s1" }, record.closed, "deleting is an explicit close")
    end)

    t.it("still close the previous session when switching away", function()
      local service, record = harness({ detach = true, sessions = two_sessions() })
      -- `Sessions:close` is what the switch path uses.
      service:close("s2")
      t.eq({ "s2" }, record.closed)
    end)
  end)
end
