-- Agent connection lifecycle: create the client, start it, disconnect and
-- reconnect. Session restoration is delegated back to the controller, because
-- the decision depends on the currently selected session.
local log = require("ade.log")
local client_mod = require("ade.protocol.client")
local capabilities = require("ade.protocol.capabilities")
local work_scheduler = require("ade.ui.work_scheduler")
local Resolve = require("ade.manager.resolve")
local ServiceConnection = require("ade.service.connection")
local service_transport = require("ade.service.transport")

local Connection = {}
Connection.__index = Connection

---One auto-fallback notice per shared service connection (editor session).
---
---Keyed weakly by the shared object: a reconfiguration builds a new app
---`Connection` around the same socket and must not repeat the notice, while a
---test that injects a fresh stand-in gets its own.
local auto_notice_shown = setmetatable({}, { __mode = "k" })

---@param opts {config: fun(): table, resolve_cwd: fun(): string,
---  state: fun(): table, generation: fun(): integer, reset_operations: fun(),
---  on_event: fun(name: string, payload: any, client: table),
---  notify: fun(message: string, level: integer|nil), on_changed: fun(),
---  on_ready: fun(), on_start_failed: fun(err: any), on_stopped: fun(),
---  runtime_lost: fun(), reset_permissions: fun(), stop_animation: fun(),
---  interactions: fun(): table|nil, on_render: fun(), store: fun(): table|nil,
---  locks: table|nil}
function Connection.new(opts)
  return setmetatable({
    config = opts.config,
    resolve_cwd = opts.resolve_cwd,
    state = opts.state,
    generation = opts.generation,
    reset_operations = opts.reset_operations,
    on_event = opts.on_event,
    notify = opts.notify,
    on_changed = opts.on_changed,
    on_ready = opts.on_ready,
    on_start_failed = opts.on_start_failed,
    on_stopped = opts.on_stopped,
    runtime_lost = opts.runtime_lost,
    reset_permissions = opts.reset_permissions,
    stop_animation = opts.stop_animation,
    interactions = opts.interactions,
    on_render = opts.on_render,
    store = opts.store,
    locks = opts.locks,
    service = opts.service,
    lease = nil,
    -- Set per connection attempt: a service that offers the `install` feature
    -- holds the lease for the agents it runs, so this object must not take one
    -- of its own (PROTOCOL.md 16.4).
    backend_service = false,
    service_lease = false,
    pending_reload = nil,
  }, Connection)
end

local function build_client_capabilities(config)
  return capabilities.client(config)
end

-- Exposed for the protocol conformance tests.
Connection.client_capabilities = build_client_capabilities

---The shared service connection, created on first use.
---
---It is created with the connection's own config function so `service.path` and
---`service.idle_timeout` are read from the live configuration rather than from
---defaults.
---@return table
function Connection:service_connection()
  if not self.service then
    local service = ServiceConnection.shared()
    -- Fill in what the shared object could not know when it was created first:
    -- whoever gets here first supplies the config accessor, and later panels
    -- reuse the same socket. An explicitly injected connection is left alone.
    if service.opts and not service.opts.config then
      service.opts.config = self.config
    end
    -- Inbound frames use the same bounded dispatch as the direct transport, so
    -- a streaming agent cannot starve timers or input on either backend.
    if service.opts and not service.opts.scheduler then
      service.opts.scheduler = work_scheduler.shared
    end
    if type(self.config) == "function" then
      local ok, cfg = pcall(self.config)
      if ok and type(cfg) == "table" and type(cfg.service) == "table" then
        service.idle_timeout = cfg.service.idle_timeout
      end
    end
    self.service = service
  end
  return self.service
end

---Subscribe to a service notification, on the real service connection.
---
---The app-level `Connection` is *not* the thing that receives socket events:
---the shared `ade.service.connection` is. Wiring that called
---`S.conn.service:subscribe(...)` directly silently did nothing, so automatic
---reconnection was never registered. This forwarder exists so callers can stay
---on the app object without guessing which layer to talk to.
---@param channel_id string
---@param method string
---@param fn fun(payload: any)
function Connection:subscribe(channel_id, method, fn)
  local service = self:service_connection()
  if type(service.subscribe) ~= "function" then
    error("ade.nvim: the service connection has no subscribe(); the wiring is broken", 2)
  end
  return service:subscribe(channel_id, method, fn)
end

---Start the service and connect, when it is not connected already.
---
---Forwards to the shared service connection: the app-level object owns the
---*agent* lifecycle, not the socket. Automatic reconnection needs exactly this
---(start the service again, then re-attach), so it belongs here as a named
---forwarder rather than as a second implementation.
---@param cb fun(ok: boolean, err: string|nil)
function Connection:ensure(cb)
  return self:service_connection():ensure(cb)
end

---@return boolean
function Connection:is_service_connected()
  local service = self.service
  return service ~= nil and service:is_connected()
end

---@param channel_id string
---@param method string
function Connection:unsubscribe(channel_id, method)
  local service = self:service_connection()
  if type(service.unsubscribe) == "function" then
    service:unsubscribe(channel_id, method)
  end
end

---Whether the agent may outlive this Neovim.
---@param cfg table
---@return boolean
function Connection:service_keep_alive(cfg)
  local service = type(cfg.service) == "table" and cfg.service or {}
  return service.keep_alive ~= false
end

---Decide the backend for one connection attempt.
---
---Returns `true` for the service, `false` for direct, and `nil, reason` when an
---explicit `backend = "service"` cannot be satisfied. `auto` warns once and
---falls back, which is why the warning is latched on the connection rather than
---repeated on every reconnect.
---@param cfg table
---@return boolean|nil use_service
---@return string|nil err
function Connection:use_service(cfg)
  local backend = cfg.backend or "direct"
  if backend == "direct" then
    return false, nil
  end
  local connection = self:service_connection()
  -- Keep the idle timeout in step with the config; the service picks it up when
  -- it starts.
  connection.idle_timeout = type(cfg.service) == "table" and cfg.service.idle_timeout or nil
  local ok, err
  connection:ensure(function(result, reason)
    ok, err = result, reason
  end)
  if ok == nil then
    -- `ensure()` can still be waiting on the handshake (a version restart does
    -- not finish synchronously). Treating nil as failure made `auto` fall back
    -- to direct while the service was already connecting.
    local timeout = type(cfg.service) == "table" and cfg.service.start_timeout or nil
    vim.wait(timeout or 5000, function()
      return ok ~= nil
    end, 10)
    if ok == nil then
      ok, err = false, err or "the service did not finish connecting"
    end
  end
  if ok then
    return true, nil
  end
  if backend == "service" then
    return nil,
      'ade.nvim: backend = "service" but the service is unavailable: '
        .. tostring(err)
        .. '. Run :Ade service install, or set backend = "direct".'
  end
  if not self.auto_notified and not auto_notice_shown[connection] then
    self.auto_notified = true
    auto_notice_shown[connection] = true
    self.notify(
      "ade.nvim: the service is unavailable (" .. tostring(err) .. "); using the direct backend",
      vim.log.levels.INFO
    )
  end
  return false, nil
end

---Take a lease on the release this launch uses, if it is a managed one.
---
---External installs are not owned by the manager, so there is nothing to
---protect; managed installs are pinned so update/uninstall in any instance can
---see that the release is live.
---@param launch table|nil
function Connection:hold_lease(launch)
  if self.service_lease then
    -- The agent runs in a service that writes its own lease (PROTOCOL.md
    -- 16.4). A Neovim lease would vanish on exit while the agent keeps
    -- running, which is exactly when another instance could prune it.
    return
  end
  if not launch or launch.source ~= "managed" or not launch.install_id then
    return
  end
  if not self.locks then
    return
  end
  if self.lease and self.lease.install_id == launch.install_id then
    return
  end
  self:release_lease()
  local lease = self.locks:lease(launch.agent_id or "", launch.install_id)
  if lease then
    self.lease = lease
  end
end

---Drop the lease held for the running client.
function Connection:release_lease()
  if self.lease and self.locks then
    self.locks:unlease(self.lease)
  end
  self.lease = nil
end

---Open the panel's agent process, starting it when needed.
function Connection:connect()
  local S = self.state()
  if S.conn.phase == "starting" then
    return
  end
  -- An auth retry can call `connect()` after the restarted client is already
  -- ready and `on_ready` has run. Re-entering `on_ready` would consume a
  -- session manager's pending load twice (or start an empty session while the
  -- load it just started is still in flight), so a ready connection has
  -- nothing left to do here.
  if S.conn.phase == "ready" and S.conn.client and S.conn.client:is_ready() then
    return
  end
  -- A stopped client carries old event bindings and an old RPC generation.
  -- Reopening after a crash uses a fresh client just like explicit reconnect.
  if S.conn.client and not S.conn.client:is_ready() then
    local previous = S.conn.client
    self.reset_operations()
    self.runtime_lost()
    S.conn.client = nil
    self:release_lease()
    -- Not-ready means there is no ACP session to preserve; a service instance
    -- in that state must be killed, not detached.
    previous:shutdown(true)
  end
  S.conn.phase = "starting"
  self.on_changed()

  local cfg = self.config()
  if not S.conn.client then
    local client
    local generation = self.generation()
    -- Resolve once, here: the conversation, the terminal login and the health
    -- check all use this spec, so a managed install never runs two versions.
    local launch, launch_err = Resolve.resolve(cfg, cfg.agent, cfg.launch_origin, self.store and self.store())
    if not launch then
      S.conn.phase = "disconnected"
      self.on_changed()
      self.on_start_failed({ message = launch_err })
      return
    end
    local use_service, backend_err = self:use_service(cfg)
    if use_service == nil then
      -- An explicit service backend that is unusable: report it and stay
      -- disconnected. Falling back silently would run an agent the user did not
      -- ask for in a mode they did not choose.
      self:release_lease()
      S.conn.phase = "disconnected"
      self.on_changed()
      self.on_start_failed({ message = backend_err or "the service is unavailable" })
      return
    end
    -- Who holds the lease depends on whether the *service* can write one. A
    -- service backend without the `install` feature (an older service on any
    -- platform, or Windows where the feature is absent) ignores `attach.launch`
    -- and writes no lease, so Neovim has to keep its own. Only a service that
    -- advertises `install` takes over (PROTOCOL.md 16.4).
    self.backend_service = use_service == true
    self.service_lease = self.backend_service
      and type(self:service_connection().has_feature) == "function"
      and self:service_connection():has_feature("install")
    if self.service_lease then
      self:release_lease()
    else
      -- Pin the release before the process exists: initialize can take seconds,
      -- and a prune in another instance would otherwise delete the files while
      -- they are being loaded. A failed start releases it again below.
      self:hold_lease(launch)
    end
    client = client_mod.new({
      agent = vim.tbl_extend("force", {}, cfg.agents[cfg.agent], {
        command = launch.command,
        args = launch.args,
        env = launch.env or cfg.agents[cfg.agent].env,
      }),
      launch = launch,
      -- The service needs the store root to write the lease for a managed
      -- release in `agent.attach.launch` (PROTOCOL.md 16.4). Without the
      -- `install` feature it ignores launch, so it is not sent.
      manager_root = self.service_lease and Resolve.manager_root(cfg) or nil,
      cwd = self.resolve_cwd(),
      client_capabilities = build_client_capabilities(cfg),
      mcp_servers = cfg.mcp_servers,
      scheduler = work_scheduler.shared,
      interactions = self.interactions and self.interactions() or nil,
      limits = cfg.transport,
      agent_id = cfg.agent,
      keep_alive = self:service_keep_alive(cfg),
      -- The backend only changes how frames reach the agent; the Client's ACP
      -- logic, timeouts and permission handling are the same in both.
      transport = use_service and service_transport or nil,
      connection = use_service and self:service_connection() or nil,
      on_event = function(name, payload)
        local function dispatch()
          if self.state().conn.client == client and self.generation() == generation then
            self.on_event(name, payload, client)
          end
        end
        -- Notifications reduce state within the transport's dispatch budget.
        -- Exit is deferred once so already-settled RPC continuations run first.
        if name == "exit" then
          vim.schedule(dispatch)
        else
          dispatch()
        end
      end,
    })
    S.conn.client = client
  end

  if not S.conn.client:is_ready() then
    local client = S.conn.client
    local generation = self.generation()
    S.conn.client:start(function(ok, err)
      vim.schedule(function()
        -- The connection may have been replaced or torn down between `start`
        -- and this callback; adopt the result only for the live client.
        if self.state().conn.client ~= client or self.generation() ~= generation then
          return
        end
        if ok then
          self.state().conn.phase = "ready"
          -- Pin the exact release this client runs: an install or update in any
          -- instance must not delete files under a live conversation.
          self:hold_lease(client.launch)
          self.on_changed()
          self.on_ready()
        else
          -- The lease was taken before the spawn; a failed start has no turn to
          -- protect and must not block uninstall/update.
          self:release_lease()
          self.state().conn.phase = "disconnected"
          self.on_changed()
          self.on_start_failed(err)
        end
      end)
    end)
  else
    S.conn.phase = "ready"
    self:hold_lease(S.conn.client and S.conn.client.launch)
    self.on_changed()
    self.on_ready()
  end
end

---Stop the agent process without closing the panel.
function Connection:disconnect()
  local S = self.state()
  -- An explicit disconnect cancels any pending session manager load: the next
  -- connection is a fresh decision, not the interrupted switch.
  S.conn.pending_load = nil
  self.reset_operations()
  self.runtime_lost()
  self.reset_permissions()
  local client = S.conn.client
  S.conn.client = nil
  if client then
    -- `:Ade disconnect` is an explicit stop: never leave the agent running.
    client:shutdown()
  end
  self:release_lease()
  S.conn.phase = "stopped"
  self.stop_animation()
  self.on_render()
  self.on_changed()
end

---Reconnect after a crash or an explicit disconnect.
function Connection:reconnect()
  local S = self.state()
  if S.conn.phase == "starting" or S.conn.phase == "ready" then
    return
  end
  self:restart()
end

---Replace the agent process unconditionally.
---
---A terminal login changes credentials on disk, so the running process must be
---restarted even though the connection is still healthy. `reconnect` is a no-op
---in that state, which is why this path exists separately.
function Connection:restart()
  local S = self.state()
  local previous = S.sess.current
  self.reset_operations()
  self.runtime_lost()
  self.reset_permissions()
  self.pending_reload = previous and previous.id or nil
  if S.conn.client then
    -- A login changed credentials on disk, so the next attach must create a new
    -- process instead of reusing the old one: stop, never detach.
    S.conn.client:shutdown(true)
    S.conn.client = nil
  end
  S.conn.phase = "stopped"
  self:connect()
end

---Take and clear the session id that must be restored when ready.
---@return string|nil
function Connection:take_pending_reload()
  local id = self.pending_reload
  self.pending_reload = nil
  return id
end

---Handle the transport reporting that the agent process is gone.
---
---Returns whether a turn was interrupted, so the caller can surface the
---condition with its own user-facing wording.
---@param payload table|nil
---@return boolean interrupted
function Connection:lost(payload)
  local S = self.state()
  local session = S.sess.current
  local interrupted = session and session.status ~= "idle" or false
  self.reset_operations()
  self.runtime_lost()
  S.conn.phase = "disconnected"
  self:release_lease()
  self.stop_animation()
  -- The agent is gone: its pending permission prompts can never be answered,
  -- so clear them instead of leaving the picker (and the toolbar badge) up.
  self.reset_permissions()
  -- An adopted turn belonged to a client that is gone: settle it so no spinner
  -- or cancel key outlives the connection.
  if S.conn.adoption then
    pcall(S.conn.adoption.reset, S.conn.adoption, "connection lost")
  end
  if payload and payload.stderr and payload.stderr ~= "" then
    log.info("agent stderr:\n%s", payload.stderr)
  end
  self.on_changed()
  self.on_render()
  return interrupted
end

---Leaving Neovim (or switching agent): detach when the backend allows it.
---
---The service backend keeps the agent running so a later Neovim can attach to
---the same instance; the direct backend has nothing to detach, so `leave` stops
---the child exactly like the old `shutdown(true)` did.
function Connection:terminate()
  local S = self.state()
  if S.conn.client then
    S.conn.client:leave(true)
    S.conn.client = nil
  end
  self:release_lease()
  log.debug("agent connection terminated")
end

return Connection
