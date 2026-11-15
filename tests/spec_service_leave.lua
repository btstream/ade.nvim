-- Leaving must not answer pending agent requests.
--
-- PROTOCOL.md 5.4 and 9.5: while an instance has no attached front end its
-- pending agent->client requests are kept and handed to the next front end that
-- attaches. Answering them `cancelled` on the way out destroys that: the service
-- has nothing left to deliver, and the user (or their colleague's Neovim) never
-- sees the permission prompt.
--
-- So `Client:leave()` — the deliberate exit path — abandons local interactions
-- without writing any response. Every path that actually stops the agent (or has
-- no agent to hand over) keeps answering `cancelled`.
return function(t)
  local client_mod = require("ade.protocol.client")
  local Interactions = require("ade.app.interactions")

  ---A process-like transport that records which path was taken.
  ---@param opts {detach?: boolean}|nil `detach` is what `will_detach()` answers
  local function fake_proc(opts)
    opts = opts or {}
    local proc = { calls = {}, may_detach = opts.detach == true }
    function proc:write()
      return true
    end
    function proc:stop(force)
      self.calls[#self.calls + 1] = force and "stop:force" or "stop"
    end
    function proc:leave()
      -- Mirrors `Channel:leave`: it detaches only when it may, otherwise stops.
      self.calls[#self.calls + 1] = self.may_detach and "leave" or "stop"
    end
    function proc:is_alive()
      return true
    end
    function proc:will_detach()
      return self.may_detach
    end
    function proc:mark_phase() end
    function proc:stderr()
      return ""
    end
    proc.stats = {}
    return proc
  end

  ---An interaction broker with a presenter that records dismissals.
  local function broker()
    local presented, dismissed, answers = {}, {}, {}
    local instance = Interactions.new({
      presenters = {
        permission = {
          present = function(interaction)
            presented[#presented + 1] = interaction.id
            return true
          end,
          dismiss = function(interaction)
            dismissed[#dismissed + 1] = interaction.id
          end,
        },
        elicitation = {
          present = function(interaction)
            presented[#presented + 1] = interaction.id
            return true
          end,
          dismiss = function(interaction)
            dismissed[#dismissed + 1] = interaction.id
          end,
        },
      },
      notify = function() end,
      on_changed = function() end,
    })
    return instance, presented, dismissed, answers
  end

  ---A client with an rpc that records every frame it would send.
  local function client_with(transport, interactions, initialized)
    local sent = {}
    local client = client_mod.new({
      agent = { command = "agent", args = {} },
      cwd = "/tmp",
      client_capabilities = {},
      interactions = interactions,
      on_event = function() end,
    })
    client.rpc = {
      close = function() end,
      write = function(_, payload)
        sent[#sent + 1] = payload
      end,
      respond = function(_, id, result)
        sent[#sent + 1] = { kind = "respond", id = id, result = result }
      end,
      respond_error = function(_, id, code, message)
        sent[#sent + 1] = { kind = "error", id = id, code = code }
      end,
      send = function(_, payload)
        sent[#sent + 1] = payload
        return true
      end,
    }
    client.proc = transport
    client.initialized = initialized ~= false
    return client, sent
  end

  t.describe("leaving keeps pending requests alive", function()
    t.it("abandons local interactions without answering the agent", function()
      local instance, presented, dismissed = broker()
      local answered = {}
      -- A pending permission request, exactly as `Client:handle_permission`
      -- registers one: the broker holds the only reference to `respond`.
      instance:open("permission", { sessionId = "s1" }, function(response)
        answered[#answered + 1] = response
      end, 41)
      t.eq(1, #presented, "the fixture did not present the request")

      local transport = fake_proc({ detach = true })
      local client, sent = client_with(transport, instance, true)
      client.permissions["perm:1"] = {
        session_id = "s1",
        respond = function(response)
          answered[#answered + 1] = response
        end,
      }

      client:leave(true)

      t.eq("leave", transport.calls[1], "leave() must detach, not stop")
      t.eq({}, answered, "a detachable leave must not answer the agent")
      t.eq(0, #sent, "no frame may be written while detaching")
      t.eq({}, instance:pending(), "the local interaction must be gone")
      t.eq(1, #dismissed, "the picker must be closed")
      t.eq({}, client.permissions, "the legacy permission map must be cleared")
    end)

    t.it("abandons an elicitation the same way", function()
      local instance, presented, dismissed = broker()
      local answered = {}
      instance:open("elicitation", { sessionId = "s1" }, function(response)
        answered[#answered + 1] = response
      end, 42)
      t.eq(1, #presented)

      local client = client_with(fake_proc({ detach = true }), instance, true)
      client:leave(true)

      t.eq({}, answered)
      t.eq({}, instance:pending())
      t.eq(1, #dismissed)
    end)

    t.it("still answers cancelled when the agent is stopped", function()
      -- keep_alive = false: the instance dies, so its requests can never be
      -- delivered again and answering them is the only honest thing left.
      local instance = broker()
      local answered = {}
      instance:open("permission", { sessionId = "s1" }, function(response)
        answered[#answered + 1] = response
      end, 43)

      -- `keep_alive = false`: the transport answers "I would stop".
      local transport = fake_proc({ detach = false })
      local client = client_with(transport, instance, true)
      client:leave(true)

      t.eq("stop", transport.calls[1], "a non-detachable leave must stop the agent")
      t.eq(1, #answered, "the agent must be told the request is cancelled")
      t.match("cancel", vim.inspect(answered[1]))
    end)

    t.it("still answers cancelled when the session was never initialized", function()
      local instance = broker()
      local answered = {}
      instance:open("permission", { sessionId = "s1" }, function(response)
        answered[#answered + 1] = response
      end, 44)

      -- Never initialized: the transport answers "I would stop".
      local transport = fake_proc({ detach = false })
      local client = client_with(transport, instance, false)
      client:leave(true)

      t.eq("stop", transport.calls[1], "an uninitialized session must be stopped")
      t.eq(1, #answered)
      t.match("cancel", vim.inspect(answered[1]))
    end)

    t.it("still answers cancelled for the direct backend", function()
      -- The direct transport has no `leave`: there is no service holding the
      -- request, so the local answer is the only one the agent will get.
      local instance = broker()
      local answered = {}
      instance:open("permission", { sessionId = "s1" }, function(response)
        answered[#answered + 1] = response
      end, 45)

      -- The direct transport has no `leave`, so `can_detach` is false and the
      -- fallback (keep_alive + initialized) is not consulted.
      local transport = fake_proc({ detach = false })
      transport.leave = nil
      local client = client_with(transport, instance, true)
      client:leave(true)

      t.eq("stop", transport.calls[1])
      t.eq(1, #answered, "a direct agent still needs its cancellation")
      t.match("cancel", vim.inspect(answered[1]))
    end)

    t.it("still answers cancelled on an explicit shutdown", function()
      local instance = broker()
      local answered = {}
      instance:open("permission", { sessionId = "s1" }, function(response)
        answered[#answered + 1] = response
      end, 46)

      local transport = fake_proc({ detach = true })
      local client = client_with(transport, instance, true)
      client:shutdown(true)

      t.eq("stop:force", transport.calls[1])
      t.eq(1, #answered, "shutdown must settle its pending requests")
      t.match("cancel", vim.inspect(answered[1]))
    end)
  end)

  t.describe("switching agents keeps pending requests", function()
    t.it("goes through leave, not shutdown, so the old request survives", function()
      -- Reconfiguring (`setup` with another agent) replaces the client. That path
      -- must leave, not shut down: the old agent may stay alive under the
      -- service, and its pending permission request has to survive for the next
      -- front end.
      local Connection = require("ade.app.connection")
      local calls = {}
      local client = {
        leave = function()
          calls[#calls + 1] = "leave"
        end,
        shutdown = function()
          calls[#calls + 1] = "shutdown"
        end,
      }
      local state = { conn = { client = client } }
      local conn = Connection.new({
        state = function()
          return state
        end,
        config = function()
          return { backend = "service", agents = {}, service = {} }
        end,
        locks = { unlease = function() end },
      })
      conn:terminate()
      t.eq({ "leave" }, calls, "reconfiguration must not kill the old agent")
      t.eq(nil, state.conn.client)
    end)

    t.it("keeps an abandoned interaction out of the answered set", function()
      -- What `leave` hands to the broker: the entry is gone, the picker is
      -- closed, and no response was produced — so a later attach can deliver the
      -- request again with a fresh `respond`.
      local instance = broker()
      local answered = {}
      instance:open("permission", { sessionId = "s1" }, function(response)
        answered[#answered + 1] = response
      end, 47)

      local client = client_with(fake_proc({ detach = true }), instance, true)
      client:leave(true)
      t.eq(0, #answered)
      t.eq(0, #instance:pending())
    end)
  end)
end
