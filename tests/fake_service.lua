-- In-process stand-in for nvim_ade_server, used by the channel tests.
--
-- It speaks the api_version 2 protocol from `service/PROTOCOL.md` over a real
-- unix socket: one JSON per line, `hello`, `ping`, `shutdown`, and the tunnel
-- methods (`agent.attach/detach/stop/list`, `tunnel.send/recv`, `agent.exited`,
-- `tunnel.error`). The ACP side can be a real child process (normally
-- `tests/mock_agent.py`) so a full conversation can run without the Rust
-- service.
--
-- Version numbers are passed in by the caller, which reads them from
-- `ade.service.version`; nothing here hardcodes the protocol version.
--
-- `tests/fake_service.py` is the same stand-in as a standalone process, used by
-- the launcher test.
local M = {}

local Framing = require("ade.transport.framing")

---@class FakeService
---@field dir string
---@field token string
---@field server table
---@field clients table[]
---@field instances table<string, table>
local Server = {}
Server.__index = Server

---@param opts {dir: string, token?: string, api_version?: number, server_version?: string,
---  wrong_token?: boolean, require_hello?: boolean, on_hello?: fun(params: table),
---  spawn_agent?: fun(instance: table): boolean|nil, exit_code?: integer,
---  stop_delay_ms?: integer, shutdown_delay_ms?: integer, shutdown_closes?: boolean,
---  shutdown_eof?: boolean, shutdown_error?: table, hello_delay_ms?: integer,
---  stop_agents_on_shutdown?: boolean,
---  features?: string[], install_version?: string, latest_version?: string,
---  install_fail?: boolean, install_log?: string, install_delay_ms?: integer,
---  install_busy?: boolean, uninstall_busy?: boolean, resolve_delay_ms?: integer,
---  policy_delay_ms?: integer, policy_error?: table,
---  teams?: table, team_watch?: table, team_leader_error?: table,
---  team_bind_error?: table,
---  run_error?: table, uninstall_error?: table, canned_agent?: boolean}|nil
---@return FakeService
function M.new(opts)
  opts = opts or {}
  -- Version numbers come from the plugin's own constants: the stand-in must keep
  -- handshaking after the version is bumped in the merge commit, without edits.
  local Version = require("ade.service.version")
  local self = setmetatable({
    dir = opts.dir,
    token = opts.token or "test-token",
    api_version = opts.api_version ~= nil and opts.api_version or Version.API_VERSION,
    server_version = opts.server_version or Version.VERSION,
    wrong_token = opts.wrong_token == true,
    require_hello = opts.require_hello == true,
    on_hello = opts.on_hello,
    spawn_agent = opts.spawn_agent,
    exit_code = opts.exit_code,
    -- Tests use this to prove `stop` does not block on the reply.
    stop_delay_ms = opts.stop_delay_ms,
    -- A `shutdown` answer that arrives after the caller's timeout. Proves the
    -- caller reports once and copes with the late reply.
    shutdown_delay_ms = opts.shutdown_delay_ms,
    -- The service really exits when asked: after the (possibly delayed) reply
    -- every socket closes, like a real `shutdown`.
    shutdown_closes = opts.shutdown_closes == true,
    -- A service that exits *without* replying: the caller sees EOF while it
    -- waits and must treat it as the stop taking effect, not as a failure.
    shutdown_eof = opts.shutdown_eof == true,
    -- An error response: the service refuses to stop and stays usable.
    shutdown_error = opts.shutdown_error,
    -- The real service stops its agents before exiting and announces each as
    -- `agent.exited`; a front end must not call that a disconnect.
    stop_agents_on_shutdown = opts.stop_agents_on_shutdown == true,
    -- Delay the hello reply, so a test can run a command while `ensure()` is
    -- blocked inside the handshake (`Connection.connecting` is true).
    hello_delay_ms = opts.hello_delay_ms,
    -- What the hello advertises. `install` is optional so the "old service"
    -- fallback can be tested (PROTOCOL.md 16).
    features = opts.features or { "tunnel" },
    -- Managed installs (section 16). The stand-in writes the same store layout
    -- as the Lua manager so both implementations read one disk.
    install_version = opts.install_version or "1.0.0",
    latest_version = opts.latest_version,
    install_fail = opts.install_fail == true,
    install_log = opts.install_log or "npm error boom",
    install_delay_ms = opts.install_delay_ms or 10,
    resolve_delay_ms = opts.resolve_delay_ms or opts.install_delay_ms or 10,
    -- How long `policy.set` waits before answering: the inline turn must wait
    -- for the reply before sending its prompt (PROTOCOL.md 17.3).
    policy_delay_ms = opts.policy_delay_ms or 20,
    policy_error = opts.policy_error,
    install_busy = opts.install_busy == true,
    uninstall_busy = opts.uninstall_busy == true,
    -- Scripted JSON-RPC errors, for the code-to-message mapping tests.
    run_error = opts.run_error,
    uninstall_error = opts.uninstall_error,
    install_jobs = {},
    install_locks = {},
    pending_installs = {},
    -- PROTOCOL.md 17: recorded rule sets, keyed by name.
    policy_sets = {},
    -- PROTOCOL.md 18: canned team state and the last configure/bind payloads.
    teams = opts.teams or {},
    team_configures = {},
    team_binds = {},
    team_sends = {},
    team_answers = {},
    team_watch = opts.team_watch,
    team_leader_error = opts.team_leader_error,
    team_bind_error = opts.team_bind_error,
    team_counter = 0,
    policy_responses = 0,
    policy_before_prompt = nil,
    -- Answer ACP requests with canned replies instead of spawning a child. Used
    -- by tests about notifications, where a real agent would only add noise.
    canned_agent = opts.canned_agent == true,
    clients = {},
    instances = {},
    -- Instances whose stop was requested but whose exit has not been announced
    -- yet (PROTOCOL.md 3.4). Listed with `stopping = true`.
    stopping = {},
    counter = 0,
    seq = {},
    -- Every `tunnel.send` frame, for assertions.
    sent = {},
    calls = {},
    attach_results = {},
  }, Server)
  vim.fn.mkdir(self.dir, "p", 448)
  local fh = assert(io.open(self.dir .. "/nvim_ade_server.token", "wb"))
  fh:write(self.token)
  fh:close()
  return self
end

---@return string
function Server:socket()
  return self.dir .. "/nvim_ade_server.sock"
end

---@param path string
---@return string|nil
local function read_token(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  return text
end

M.read_token = read_token

---Start listening. Returns false when the socket cannot be bound.
---@return boolean
function Server:listen()
  pcall(vim.fn.delete, self:socket())
  local server = vim.uv.new_pipe(false)
  self.server = server
  local ok = pcall(function()
    server:bind(self:socket())
  end)
  if not ok then
    return false
  end
  server:listen(16, function()
    local peer = vim.uv.new_pipe(false)
    server:accept(peer)
    self:serve(peer)
  end)
  return true
end

---@param peer table
function Server:serve(peer)
  local decoder = Framing.new_decoder()
  local client = { peer = peer, greeted = false, attached = {} }
  self.clients[#self.clients + 1] = client
  peer:read_start(function(err, data)
    if err or not data then
      pcall(peer.close, peer)
      self:detach_all(client)
      return
    end
    decoder:feed(data, function(line)
      local ok, message = pcall(vim.json.decode, line)
      if not ok or type(message) ~= "table" then
        return
      end
      local reply = self:dispatch(message, client)
      if reply then
        self:send(client, reply)
      end
    end)
  end)
end

---@param client table
---@param payload table
function Server:send(client, payload)
  if not client.peer or client.closed then
    return
  end
  pcall(function()
    client.peer:write(vim.json.encode(payload) .. "\n")
  end)
end

---@param client table
---@param method string
---@param params table
function Server:emit(client, method, params)
  self:send(client, { jsonrpc = "2.0", method = method, params = params })
end

---@param ident any
---@param code integer
---@param message string
---@param data table|nil
---@return table
local function error_reply(ident, code, message, data)
  local payload = { code = code, message = message }
  if data then
    payload.data = data
  end
  return { jsonrpc = "2.0", id = ident, error = payload }
end

---@param message table
---@param client table
---@return table|nil
function Server:dispatch(message, client)
  local method = message.method
  local ident = message.id
  local params = type(message.params) == "table" and message.params or {}
  if method then
    self.calls[#self.calls + 1] = { method = method, params = params, id = ident }
  end
  if method == "hello" then
    if self.wrong_token or params.token ~= self.token then
      return error_reply(ident, -32001, "invalid token")
    end
    if self.api_version ~= nil and params.api_version ~= self.api_version then
      return error_reply(ident, -32002, "incompatible api_version", { server_api_version = self.api_version })
    end
    client.greeted = true
    if self.on_hello then
      pcall(self.on_hello, params)
    end
    local reply = {
      jsonrpc = "2.0",
      id = ident,
      result = {
        server_version = self.server_version,
        api_version = self.api_version,
        features = self.features,
      },
    }
    if self.hello_delay_ms and self.hello_delay_ms > 0 then
      vim.defer_fn(function()
        self:send(client, reply)
      end, self.hello_delay_ms)
      return nil
    end
    return reply
  end
  if not client.greeted and self.require_hello then
    return error_reply(ident, -32003, "hello required")
  end
  if method == "ping" then
    return { jsonrpc = "2.0", id = ident, result = {} }
  end
  if method == "shutdown" then
    if self.shutdown_eof then
      -- Exit without answering: the caller sees EOF while it waits.
      self:close()
      return nil
    end
    if self.shutdown_error then
      return { jsonrpc = "2.0", id = ident, error = self.shutdown_error }
    end
    if self.stop_agents_on_shutdown then
      -- The real service stops every agent while shutting down and tells the
      -- attached front ends before the stop reply.
      for instance_id, record in pairs(self.instances) do
        for attached in pairs(record.attached) do
          self:emit(attached, "agent.exited", {
            instance = instance_id,
            code = self.exit_code or 0,
            signal = nil,
            stderr_tail = "",
          })
        end
      end
    end
    local reply = { jsonrpc = "2.0", id = ident, result = {} }
    if self.shutdown_delay_ms and self.shutdown_delay_ms > 0 then
      -- Deliberately late: the caller's timeout has already been reported.
      vim.defer_fn(function()
        self:send(client, reply)
        if self.shutdown_closes then
          -- Give the queued write one tick to flush before the peer closes.
          vim.defer_fn(function()
            self:close()
          end, 20)
        end
      end, self.shutdown_delay_ms)
      return nil
    end
    if self.shutdown_closes then
      -- Close after this reply has been written, so the caller sees the
      -- success answer and then the socket going away.
      vim.defer_fn(function()
        self:close()
      end, 20)
    end
    return reply
  end

  if method == "team.configure" then
    self.team_configures[#self.team_configures + 1] = vim.deepcopy(params)
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = {} })
    end, 5)
    return nil
  end
  if method == "team.leader_server" then
    if self.team_leader_error then
      return error_reply(ident, self.team_leader_error.code, self.team_leader_error.message)
    end
    for _, team in pairs(self.teams) do
      if
        team.cwd == params.cwd
        and team.state ~= "closed"
        and team.leader
        and team.leader.instance ~= params.instance
      then
        return error_reply(ident, -32061, "a team already exists for this cwd")
      end
    end
    local result = {
      server = {
        name = "ade-team",
        command = "/fake/nvim_ade_server",
        args = { "mcp" },
        env = { { name = "ADE_TEAM_TOKEN", value = "k-test-token" } },
      },
      token_id = "k1",
    }
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = result })
    end, 5)
    return nil
  end
  if method == "team.bind_leader" then
    if self.team_bind_error then
      return error_reply(ident, self.team_bind_error.code, self.team_bind_error.message)
    end
    self.team_binds[#self.team_binds + 1] = vim.deepcopy(params)
    local team = {
      id = "t1",
      cwd = params.cwd or "/",
      state = "active",
      leader = { instance = params.instance, sessionId = params.sessionId },
      participants = {},
      inbox = {},
      limits = { max_turns_per_task = 30, max_turns_total = 200, turns_total = 0 },
    }
    if not self.teams.t1 then
      self.teams.t1 = team
    end
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = { team = self.teams.t1 } })
    end, 5)
    return nil
  end
  if method == "team.list" then
    local teams = {}
    for _, team in pairs(self.teams) do
      if team.state ~= "closed" then
        teams[#teams + 1] = vim.deepcopy(team)
      end
    end
    table.sort(teams, function(a, b)
      return a.id < b.id
    end)
    return { jsonrpc = "2.0", id = ident, result = { teams = teams } }
  end
  if method == "team.send" then
    local kinds = {
      task = true,
      report = true,
      question = true,
      answer = true,
      review = true,
      notice = true,
      control = true,
    }
    if not kinds[params.kind] then
      return error_reply(ident, -32060, "kind is invalid: " .. tostring(params.kind))
    end
    if params.to == "human" and params.kind == "control" then
      return error_reply(ident, -32060, "control to human is refused")
    end
    self.team_sends[#self.team_sends + 1] = vim.deepcopy(params)
    self.team_counter = self.team_counter + 1
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = { id = self.team_counter } })
    end, 5)
    return nil
  end
  if method == "team.read" then
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = { messages = {}, turns = {} } })
    end, 5)
    return nil
  end
  if method == "team.answer" then
    self.team_answers[#self.team_answers + 1] = vim.deepcopy(params)
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = {} })
    end, 5)
    return nil
  end
  if method == "team.watch" then
    local watch = self.team_watch or {}
    local instance = watch.instance or "inst-1"
    local session_id = watch.sessionId or "watch-session"
    for _, foreign in ipairs(watch.foreign or {}) do
      self:send(client, {
        jsonrpc = "2.0",
        method = "tunnel.recv",
        params = {
          instance = foreign.instance or "inst-1",
          seq = 1,
          message = {
            jsonrpc = "2.0",
            method = "session/update",
            params = { sessionId = foreign.sessionId or "sess_mock", update = foreign.update },
          },
        },
      })
    end
    for _, update in ipairs(watch.replay or {}) do
      self:send(client, {
        jsonrpc = "2.0",
        method = "tunnel.recv",
        params = {
          instance = instance,
          seq = 1,
          message = { jsonrpc = "2.0", method = "session/update", params = { sessionId = session_id, update = update } },
        },
      })
    end
    vim.defer_fn(function()
      self:send(client, {
        jsonrpc = "2.0",
        id = ident,
        result = {
          instance = instance,
          sessionId = session_id,
          replayed = watch.replayed ~= false and #(watch.replay or {}) > 0,
        },
      })
    end, 5)
    return nil
  end
  if method == "team.unwatch" then
    self.team_unwatch = self.team_unwatch or {}
    self.team_unwatch[#self.team_unwatch + 1] = vim.deepcopy(params)
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = {} })
    end, 5)
    return nil
  end
  if method == "team.reset_limits" then
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = {} })
    end, 5)
    return nil
  end
  if method == "team.close" then
    local team = self.teams[params.team]
    if team then
      team.state = "closed"
      self:emit(client, "team.changed", { team = vim.deepcopy(team) })
      self.teams[params.team] = nil
    end
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = {} })
    end, 5)
    return nil
  end
  if method == "policy.set" then
    if self.policy_error then
      return error_reply(ident, self.policy_error.code or -32050, self.policy_error.message or "invalid rule set")
    end
    local set = params.set
    if type(set) ~= "table" or type(set.name) ~= "string" then
      return error_reply(ident, -32050, "set.name is required")
    end
    -- Minimal validation from section 17.1: enough for the front-end tests to
    -- catch malformed sets instead of silently accepting them.
    local kinds = {
      allow_once = true,
      allow_always = true,
      reject_once = true,
      reject_always = true,
    }
    local function absolute(path)
      return type(path) == "string" and (path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil)
    end
    if set["until"] and not set.session then
      return error_reply(ident, -32050, "until requires session")
    end
    if set.cwd ~= nil and not absolute(set.cwd) then
      return error_reply(ident, -32050, "cwd must be absolute")
    end
    for index, rule in ipairs(set.rules or {}) do
      if type(rule.choose) ~= "table" or #rule.choose == 0 then
        return error_reply(ident, -32050, "rules[" .. index .. "].choose is empty")
      end
      for _, kind in ipairs(rule.choose) do
        if not kinds[kind] then
          return error_reply(ident, -32050, "rules[" .. index .. "].choose has unknown kind " .. tostring(kind))
        end
        if kind == "allow_always" and set.allow_always ~= true then
          return error_reply(ident, -32050, "allow_always in choose requires allow_always = true")
        end
      end
      for _, list in ipairs({ rule.paths or {}, rule.paths_under or {} }) do
        for _, path in ipairs(list) do
          if not absolute(path) then
            return error_reply(ident, -32050, "rules[" .. index .. "] paths must be absolute")
          end
        end
      end
    end
    set = vim.deepcopy(set)
    set.owner = tostring(client)
    set.installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    self.policy_sets[set.name] = set
    vim.defer_fn(function()
      self.policy_responses = self.policy_responses + 1
      self:send(client, { jsonrpc = "2.0", id = ident, result = {} })
    end, self.policy_delay_ms or 20)
    return nil
  end
  if method == "policy.clear" then
    local removed = self.policy_sets[params.name] ~= nil
    self.policy_sets[params.name] = nil
    vim.defer_fn(function()
      self:send(client, { jsonrpc = "2.0", id = ident, result = { removed = removed } })
    end, self.policy_delay_ms or 20)
    return nil
  end
  if method == "policy.list" then
    local sets = {}
    for _, set in pairs(self.policy_sets) do
      sets[#sets + 1] = set
    end
    return { jsonrpc = "2.0", id = ident, result = { sets = sets } }
  end
  if method == "$/cancel_request" then
    -- This runs in the socket callback (a fast event context), where
    -- `vim.fn.delete` and friends are forbidden. Cleanup belongs on the main
    -- loop, like every other install step.
    vim.schedule(function()
      local job = self.pending_installs[params.id]
      if job then
        self:cancel_install(job)
      end
    end)
    return nil
  end
  if method == "install.resolve" then
    vim.defer_fn(function()
      local version = self:install_resolved_version(params)
      if not version then
        self:send(client, error_reply(ident, -32041, "npm view returned no version"))
        return
      end
      self:send(client, { jsonrpc = "2.0", id = ident, result = { version = version } })
    end, self.resolve_delay_ms)
    return nil
  end
  if method == "install.run" then
    return self:install_run(params, client, ident)
  end
  if method == "install.uninstall" then
    return self:install_uninstall(params, client, ident)
  end

  if method == "agent.attach" then
    -- Spawning the fake agent runs `jobstart`, which is forbidden in libuv's
    -- fast event context where socket reads arrive. Defer the whole attach one
    -- tick so a stand-in can start a real child process.
    vim.schedule(function()
      self:send(client, self:attach(params, client, ident))
    end)
    return nil
  elseif method == "agent.detach" then
    local instance = self.instances[params.instance]
    if not instance then
      return error_reply(ident, -32020, "unknown instance")
    end
    instance.attached[client] = nil
    client.attached[params.instance] = nil
    return { jsonrpc = "2.0", id = ident, result = {} }
  elseif method == "agent.stop" then
    local instance = self.instances[params.instance]
    if not instance then
      return error_reply(ident, -32020, "unknown instance")
    end
    self:stop_instance(instance, "stop")
    local reply = { jsonrpc = "2.0", id = ident, result = { exited = true, code = 0 } }
    if self.stop_delay_ms and self.stop_delay_ms > 0 then
      -- Deliberately slow: the client must not wait for this reply.
      vim.defer_fn(function()
        self:send(client, reply)
      end, self.stop_delay_ms)
      return nil
    end
    return reply
  elseif method == "agent.list" then
    local instances = {}
    for id, instance in pairs(self.instances) do
      instances[#instances + 1] = {
        instance = id,
        stopping = instance.stopping == true,
        agent = instance.key.agent,
        command = instance.key.command,
        args = instance.key.args,
        cwd = instance.key.cwd,
        pid = instance.pid or 0,
        started_at = instance.started_at,
        initialized = instance.initialized == true,
        attached = vim.tbl_count(instance.attached),
        turns_running = instance.turns_running or 0,
        pending_requests = #(instance.pending or {}),
        sessions = #(instance.sessions or {}),
        log_bytes = instance.log_bytes or 0,
      }
    end
    table.sort(instances, function(a, b)
      return a.instance < b.instance
    end)
    return { jsonrpc = "2.0", id = ident, result = { instances = instances } }
  elseif method == "tunnel.send" then
    self:on_tunnel_send(params, client)
    return nil
  end
  return error_reply(ident, -32601, "Method not found: " .. tostring(method))
end

---@param params table
---@param client table
---@param ident any
---@return table
function Server:attach(params, client, ident)
  local key = params.key or {}
  local canonical = vim.json.encode({
    agent = key.agent,
    command = key.command,
    args = key.args or {},
    cwd = key.cwd,
    client_capabilities = params.client_capabilities or {},
  })
  self.attach_results[#self.attach_results + 1] = {
    key = vim.deepcopy(key),
    env = vim.deepcopy(params.env),
    capabilities = vim.deepcopy(params.client_capabilities),
    -- PROTOCOL.md 16.4: the optional lease request for a managed release.
    launch = vim.deepcopy(params.launch),
  }
  local id, created = nil, false
  for existing, instance in pairs(self.instances) do
    if instance.canonical == canonical and not instance.stopping then
      id = existing
      break
    end
  end
  if not id then
    self.counter = self.counter + 1
    id = "inst-" .. tostring(self.counter)
    created = true
    local instance = {
      id = id,
      canonical = canonical,
      key = key,
      env = params.env,
      capabilities = params.client_capabilities or {},
      attached = {},
      started_at = math.floor(vim.uv.gettimeofday() * 1000),
      initialized = false,
      agent = nil,
      -- Agent -> client requests this instance has relayed and that nobody has
      -- answered yet, in arrival order (PROTOCOL.md 5.4).
      pending = {},
    }
    self.instances[id] = instance
    if self.spawn_agent then
      local ok = self.spawn_agent(instance)
      if ok == false then
        self.instances[id] = nil
        return error_reply(ident, -32022, "spawn failed")
      end
    end
  end
  local instance = self.instances[id]
  instance.attached[client] = true
  client.attached[id] = true
  -- Becoming (most recently attached) primary: hand over every request that no
  -- front end answered, in arrival order.
  for _, message in ipairs(instance.pending or {}) do
    self:emit(client, "tunnel.recv", {
      instance = id,
      seq = self.seq[id] or 0,
      message = message,
    })
  end
  return {
    jsonrpc = "2.0",
    id = ident,
    result = {
      instance = id,
      created = created,
      pid = instance.pid or 0,
      initialized = instance.initialized == true,
      attached = vim.tbl_count(instance.attached),
      -- PROTOCOL.md 3.2/10: the sessions this instance tracks, so a front end
      -- can reopen one instead of starting an empty session.
      sessions = instance.sessions or {},
      log_bytes = instance.log_bytes or 0,
    },
  }
end

---Handle one `tunnel.send` frame: route it to the fake agent.
---@param params table
---@param client table
function Server:on_tunnel_send(params, client)
  local instance = self.instances[params.instance]
  if not instance or not instance.attached[client] then
    self:emit(client, "tunnel.error", {
      instance = params.instance,
      code = -32024,
      message = "not attached",
    })
    return
  end
  local message = params.message
  if type(message) ~= "table" then
    self:emit(client, "tunnel.error", {
      instance = params.instance,
      code = -32025,
      message = "frame is not an object",
    })
    return
  end
  self.sent[#self.sent + 1] = { instance = params.instance, message = vim.deepcopy(message) }
  if type(message) == "table" and message.method == "session/prompt" then
    self.policy_before_prompt = self.policy_responses
  end
  -- A response from a front end answers a relayed agent request: forget it, so
  -- `agent.list` reports the same pending set the service would (PROTOCOL 5.1).
  if message.method == nil and message.id ~= nil and instance.pending then
    for index, pending in ipairs(instance.pending) do
      if pending.id == message.id then
        table.remove(instance.pending, index)
        break
      end
    end
  end
  -- Writing to a child's stdin uses Vimscript (`chansend`), which libuv's fast
  -- event context forbids, and socket reads arrive there. One scheduled hop is
  -- enough and keeps the frame order.
  vim.schedule(function()
    if not instance.handler and self.canned_agent then
      -- A minimal ACP answerer: `initialize`, `session/new`, `session/prompt`.
      local replies = {
        initialize = { protocolVersion = 1, agentCapabilities = { loadSession = true }, authMethods = {} },
        ["session/new"] = { sessionId = "sess_mock", configOptions = {} },
        ["session/load"] = { configOptions = {} },
        ["session/prompt"] = { stopReason = "end_turn" },
        ["session/close"] = {},
        ["session/delete"] = {},
      }
      local result = message.method and replies[message.method]
      if result and message.id ~= nil then
        -- Track session lifetimes exactly like the relay (PROTOCOL.md 11), and
        -- report them in the `agent.attach` shape (PROTOCOL.md 3.2): a test
        -- about restore must exercise `sessionId`, not a field the stand-in
        -- invented.
        self:track_message(instance, message, result)
        -- A JSON-RPC **response** wraps the payload in `result`.
        self:deliver(instance, {
          jsonrpc = "2.0",
          id = message.id,
          result = vim.deepcopy(result),
        })
      end
      return
    end
    if not instance.handler or not self.instances[instance.id] then
      return
    end
    instance.handler(message, function(reply)
      if reply then
        self:deliver(instance, reply)
      end
    end)
  end)
end

---Deliver one agent message to every attached connection as `tunnel.recv`.
---@param instance table
---@param message table
function Server:deliver(instance, message)
  if type(message) == "table" and message.method and message.id ~= nil then
    -- An agent request: keep it until some front end answers it.
    instance.pending = instance.pending or {}
    instance.pending[#instance.pending + 1] = message
  elseif type(message) == "table" and not message.method and message.id ~= nil then
    -- A response to one of those requests: forget it.
    for index, pending in ipairs(instance.pending or {}) do
      if pending.id == message.id then
        table.remove(instance.pending, index)
        break
      end
    end
  end
  self.seq[instance.id] = (self.seq[instance.id] or 0) + 1
  if message.method == "initialize" then
    instance.initialized = true
  end
  for client in pairs(instance.attached) do
    self:emit(client, "tunnel.recv", {
      instance = instance.id,
      seq = self.seq[instance.id],
      message = message,
    })
  end
end

---Mirror the relay's session tracking for one canned-agent exchange.
---
---Shape comes from PROTOCOL.md 3.2 (`sessionId`, `cwd`, `running`,
---`updated_at`); a stand-in that invents `id` would make a wrong reader look
---right, which is exactly how the restore defect survived the unit suite.
---@param instance table
---@param message table the ACP request
---@param result table the reply's `result`
function Server:track_message(instance, message, result)
  local method = message.method
  local params = type(message.params) == "table" and message.params or {}
  local cwd = params.cwd or (instance.key and instance.key.cwd) or ""
  instance.sessions = instance.sessions or {}
  local function put(session_id)
    for _, entry in ipairs(instance.sessions) do
      if entry.sessionId == session_id then
        entry.updated_at = vim.uv.gettimeofday() * 1000
        return
      end
    end
    instance.sessions[#instance.sessions + 1] = {
      sessionId = session_id,
      cwd = cwd,
      running = false,
      updated_at = math.floor(vim.uv.gettimeofday() * 1000),
    }
  end
  local function forget(session_id)
    local kept = {}
    for _, entry in ipairs(instance.sessions) do
      if entry.sessionId ~= session_id then
        kept[#kept + 1] = entry
      end
    end
    instance.sessions = kept
  end
  if method == "session/new" and type(result.sessionId) == "string" then
    put(result.sessionId)
  elseif method == "session/load" and type(params.sessionId) == "string" then
    put(params.sessionId)
  elseif (method == "session/close" or method == "session/delete") and params.sessionId ~= nil then
    forget(params.sessionId)
  end
end

---Give an instance a tracked session, as the relay would (PROTOCOL 11).
---@param instance string
---@param session {sessionId: string, cwd: string, running?: boolean, updated_at?: integer}
function Server:track_session(instance, session)
  local record = self.instances[instance]
  if not record then
    return nil
  end
  -- Always stored in the protocol shape, even when the caller omits a field:
  -- a stand-in with a partial entry teaches the reader wrong assumptions.
  local entry = {
    sessionId = session.sessionId,
    cwd = session.cwd,
    running = session.running == true,
    updated_at = session.updated_at or math.floor(vim.uv.gettimeofday() * 1000),
  }
  record.sessions = record.sessions or {}
  for index, existing in ipairs(record.sessions) do
    if existing.sessionId == entry.sessionId then
      record.sessions[index] = entry
      return entry
    end
  end
  record.sessions[#record.sessions + 1] = entry
  return entry
end

---Tell a connection it adopted an in-flight turn (PROTOCOL 13).
---@param instance string
---@param session_id string
function Server:adopt(instance, session_id)
  local record = self.instances[instance]
  if not record then
    return false
  end
  record.adopted = record.adopted or {}
  record.adopted[session_id] = true
  for client in pairs(record.attached) do
    self:emit(client, "tunnel.recv", {
      instance = instance,
      seq = self.seq[instance] or 0,
      message = { jsonrpc = "2.0", method = "_ade/turn_adopted", params = { sessionId = session_id } },
    })
  end
  return true
end

---Finish an adopted turn (PROTOCOL 13).
---@param instance string
---@param session_id string
---@param stop_reason string|nil
---@param err table|nil
function Server:finish_adopted(instance, session_id, stop_reason, err)
  local record = self.instances[instance]
  if not record then
    return false
  end
  local params = { sessionId = session_id, stopReason = stop_reason or "end_turn" }
  if err then
    params.stopReason = "error"
    params.error = err
  end
  if record.adopted then
    record.adopted[session_id] = nil
  end
  for client in pairs(record.attached) do
    self:emit(client, "tunnel.recv", {
      instance = instance,
      seq = self.seq[instance] or 0,
      message = { jsonrpc = "2.0", method = "_ade/turn_finished", params = params },
    })
  end
  return true
end

---Retract a pending agent request from every other connection (PROTOCOL 14).
---@param instance string
---@param request_id integer
---@param answered_by table|nil the connection that answered it
function Server:retract(instance, request_id, answered_by)
  local record = self.instances[instance]
  if not record then
    return false
  end
  for index, pending in ipairs(record.pending or {}) do
    if pending.id == request_id then
      table.remove(record.pending, index)
      break
    end
  end
  for client in pairs(record.attached) do
    if client ~= answered_by then
      self:emit(client, "tunnel.recv", {
        instance = instance,
        seq = self.seq[instance] or 0,
        message = {
          jsonrpc = "2.0",
          method = "$/cancel_request",
          params = { id = request_id },
        },
      })
    end
  end
  return true
end

---Stop an instance, notifying every attached connection.
---
---Per PROTOCOL.md 3.4 the instance leaves the identity lookup as soon as the
---request is processed, so an `agent.attach` with the same key right afterwards
---creates a new instance instead of reusing the dying one. The record itself
---stays listed (with `stopping = true`) until the exit is announced, so
---`agent.list` and in-flight `tunnel.send` still find it by id.
---@param instance table
---@param reason string
function Server:stop_instance(instance, reason)
  instance.stopping = true
  instance.canonical = nil -- no longer matches an attach
  self.stopping[instance.id] = instance
  local code = self.exit_code or 0
  for client in pairs(instance.attached) do
    self:emit(client, "agent.exited", {
      instance = instance.id,
      code = code,
      signal = nil,
      stderr_tail = "",
    })
  end
  if instance.stop_agent then
    pcall(instance.stop_agent)
  end
  self.instances[instance.id] = nil
  self.stopping[instance.id] = nil
  return reason
end

---Detach a client from everything (it disconnected).
---@param client table
function Server:detach_all(client)
  client.closed = true
  -- Keep `clients` to the live sockets: a test that wants "the connection the
  -- editor is using" must not pick a dead one left over from a reconnect.
  for index, entry in ipairs(self.clients) do
    if entry == client then
      table.remove(self.clients, index)
      break
    end
  end
  for id in pairs(client.attached or {}) do
    local instance = self.instances[id]
    if instance then
      instance.attached[client] = nil
    end
  end
  client.attached = {}
end

---Number of instances currently alive.
---@return integer
function Server:instance_count()
  return vim.tbl_count(self.instances)
end

---Close one client's socket, as a service dying mid-conversation would.
---@param client table
function Server:drop(client)
  client.closed = true
  if client.peer then
    pcall(function()
      client.peer:close()
    end)
  end
end

---Send a team.changed notification to every live connection (18.9).
---@param team table
function Server:team_changed(team)
  self.teams[team.id] = team
  self:broadcast("team.changed", { team = team })
end

---Send a team.inbox notification to every live connection (18.9).
---@param item table
function Server:team_inbox(item)
  self:broadcast("team.inbox", { item = item })
end

---Send one `_ade/turn_started` to the attached connection of an instance.
---@param instance string
---@param params table
function Server:turn_started(instance, params)
  self:broadcast("tunnel.recv", {
    instance = instance,
    seq = 1,
    message = { jsonrpc = "2.0", method = "_ade/turn_started", params = params },
  })
end

---Send one live `session/update` for a watched/attached instance.
---@param instance string
---@param sessionId string
---@param update table
function Server:watch_update(instance, sessionId, update)
  self:broadcast("tunnel.recv", {
    instance = instance,
    seq = 1,
    message = { jsonrpc = "2.0", method = "session/update", params = { sessionId = sessionId, update = update } },
  })
end

---Announce a policy decision the way the service does (PROTOCOL.md 17.4).
---@param payload table
function Server:policy_applied(payload)
  self:broadcast("policy.applied", payload)
end

---Broadcast one notification to every live connection.
---@param method string
---@param params table
function Server:broadcast(method, params)
  for _, client in ipairs(self.clients) do
    if not client.closed then
      self:emit(client, method, params)
    end
  end
end

---The version `install.resolve` reports (section 16.3).
---@param params table
---@return string|nil
function Server:install_resolved_version(params)
  local spec = params.spec or "latest"
  if spec ~= "latest" then
    return spec
  end
  return self.latest_version or self.install_version
end

---@param path string
---@return table|nil
local function read_json(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  local ok, value = pcall(vim.json.decode, text)
  return ok and type(value) == "table" and value or nil
end

---@param path string
---@param value table
local function write_json(path, value)
  local handle = assert(io.open(path, "wb"))
  handle:write(vim.json.encode(value))
  handle:close()
end

---A release id the store accepts: lowercase, no `..`, at most 96 bytes.
---@param version string
---@return string
local function install_id_for(version)
  local base = version:lower():gsub("[^%w%.%-]", "_"):sub(1, 64)
  return string.format("v%s-%s", base, tostring(vim.uv.hrtime() % 1e9))
end

---Send one `install.progress` event for a job to every connection.
---@param job table
---@param event table
function Server:emit_install(job, event)
  event.job = job.job
  event.agent = job.agent
  event.action = job.action or job.params.action or "uninstall"
  self:broadcast("install.progress", event)
end

---Forget a job and answer it once.
---@param job table
---@param reply table
function Server:finish_install(job, reply)
  self.install_locks[job.agent] = nil
  self.install_jobs[job.job] = nil
  self.pending_installs[job.id] = nil
  if not job.client.closed then
    self:send(job.client, reply)
  end
end

---`install.run` (section 16.3), staged over several ticks so progress is real.
---@param params table
---@param client table
---@param ident any
---@return table|nil
---Refuse a run/uninstall before it starts, with the terminal event section
---16.3 requires for early refusals.
---@param params table
---@param ident any
---@param code integer
---@param message string
---@param data table|nil
---@return table
function Server:install_refuse(params, ident, code, message, data)
  self:emit_install({
    job = params.job,
    agent = params.agent,
    params = { action = params.action },
  }, { phase = "failed", message = message })
  return error_reply(ident, code, message, data)
end

function Server:install_run(params, client, ident)
  if self.run_error then
    return self:install_refuse(params, ident, self.run_error.code, self.run_error.message, self.run_error.data)
  end
  local agent = params.agent
  local reason = "pid 4242 is running"
  if self.install_locks[agent] or self.install_busy then
    return self:install_refuse(
      params,
      ident,
      -32042,
      "another instance is using this agent: " .. reason,
      { reason = reason }
    )
  end
  if self.install_jobs[params.job] then
    -- -32040 is a validation failure: the request never passed validation, so
    -- it must not emit a terminal event (which would belong to the running job
    -- that already owns this id; PROTOCOL.md 16.3).
    return error_reply(ident, -32040, "job is already running")
  end
  local root = params.root
  local agent_dir = root .. "/" .. agent
  local current = read_json(agent_dir .. "/current.json")
  if params.action == "update" and current and current.version == params.version then
    self:emit_install({
      job = params.job,
      agent = agent,
      params = { action = params.action },
    }, { phase = "unchanged", version = current.version })
    return {
      jsonrpc = "2.0",
      id = ident,
      result = {
        status = "unchanged",
        installId = current.installId,
        version = current.version,
      },
    }
  end
  self.install_locks[agent] = true
  local job = {
    id = ident,
    job = params.job,
    agent = agent,
    client = client,
    params = params,
    cancelled = false,
  }
  self.install_jobs[params.job] = job
  self.pending_installs[ident] = job
  local delay = self.install_delay_ms or 10
  vim.defer_fn(function()
    if job.cancelled then
      return
    end
    self:emit_install(job, { phase = "checking" })
    vim.defer_fn(function()
      if job.cancelled then
        return
      end
      local install_id = install_id_for(params.version)
      local dir = agent_dir .. "/releases/" .. install_id
      job.dir = dir
      job.install_id = install_id
      vim.fn.mkdir(dir, "p")
      self:emit_install(job, { phase = "installing", version = params.version, dir = dir })
      vim.defer_fn(function()
        if job.cancelled then
          return
        end
        write_json(dir .. "/package.json", {
          name = "ade-nvim-managed",
          private = true,
          version = "0.0.0",
          description = "Installed by ade.nvim; do not edit.",
          dependencies = { [params.package] = params.version },
        })
        self:emit_install(job, {
          phase = "output",
          line = "$ npm install --no-audit --no-fund --omit=dev --loglevel=notice --progress=false",
        })
        if self.install_fail then
          self:emit_install(job, { phase = "output", line = self.install_log })
          vim.fn.delete(dir, "rf")
          self:emit_install(job, { phase = "failed", message = "npm install failed with exit code 1" })
          self:finish_install(
            job,
            error_reply(ident, -32043, "npm install failed with exit code 1", {
              log = self.install_log,
            })
          )
          return
        end
        self:emit_install(job, { phase = "output", line = "added 1 package in 1s" })
        -- Verification and the commit happen on a later tick, like the real
        -- service: a test can observe "output arrived, job still running".
        vim.defer_fn(function()
          if job.cancelled then
            return
          end
          local package_dir = dir .. "/node_modules/" .. params.package
          vim.fn.mkdir(package_dir .. "/" .. vim.fs.dirname(params.entry), "p")
          write_json(package_dir .. "/package.json", { name = params.package, version = params.version })
          local entry = assert(io.open(package_dir .. "/" .. params.entry, "wb"))
          entry:write("#!/usr/bin/env node\n")
          entry:close()
          self:emit_install(job, { phase = "verifying", version = params.version })
          write_json(dir .. "/receipt.json", {
            schemaVersion = 1,
            agentId = agent,
            installId = install_id,
            package = params.package,
            version = params.version,
            entry = "node_modules/" .. params.package .. "/" .. params.entry,
            bin = params.bin,
            runtime = "node",
            installedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            platform = jit and jit.os or nil,
            arch = jit and jit.arch or nil,
          })
          write_json(agent_dir .. "/current.json", {
            schemaVersion = 1,
            installId = install_id,
            updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            package = params.package,
            version = params.version,
          })
          self:emit_install(job, { phase = "committed", version = params.version })
          self:finish_install(job, {
            jsonrpc = "2.0",
            id = ident,
            result = {
              status = "committed",
              installId = install_id,
              version = params.version,
              dir = dir,
            },
          })
        end, delay)
      end, delay)
    end, delay)
  end, delay)
  return nil
end

---`install.uninstall` (section 16.3).
---@param params table
---@param client table
---@param ident any
---@return table|nil
function Server:install_uninstall(params, client, ident)
  if self.uninstall_error then
    return self:install_refuse(
      params,
      ident,
      self.uninstall_error.code,
      self.uninstall_error.message,
      self.uninstall_error.data
    )
  end
  local agent = params.agent
  if self.install_locks[agent] then
    return self:install_refuse(
      params,
      ident,
      -32042,
      "another instance is using this agent",
      { reason = "pid 4242 is running" }
    )
  end
  local agent_dir = params.root .. "/" .. agent
  local current = read_json(agent_dir .. "/current.json")
  if not current or type(current.installId) ~= "string" then
    return self:install_refuse(params, ident, -32045, "this agent has no manager-owned install")
  end
  if params.installId and params.installId ~= current.installId then
    return self:install_refuse(params, ident, -32042, "the installed release changed", { reason = "changed" })
  end
  if self.uninstall_busy then
    return self:install_refuse(params, ident, -32044, "the release is in use", { reason = "in use by pid 4242" })
  end
  self.install_locks[agent] = true
  local job = {
    id = ident,
    job = params.job,
    agent = agent,
    client = client,
    params = params,
    cancelled = false,
  }
  self.install_jobs[params.job] = job
  self.pending_installs[ident] = job
  vim.defer_fn(function()
    if job.cancelled then
      return
    end
    os.remove(agent_dir .. "/current.json")
    vim.fn.delete(agent_dir .. "/releases/" .. current.installId, "rf")
    self:emit_install(job, { phase = "removed" })
    self:finish_install(job, { jsonrpc = "2.0", id = ident, result = { installId = current.installId } })
  end, self.install_delay_ms or 10)
  return nil
end

---`$/cancel_request`: answer the request with -32800 after cleaning up.
---@param job table
function Server:cancel_install(job)
  job.cancelled = true
  if job.dir then
    vim.fn.delete(job.dir, "rf")
  end
  self:emit_install(job, { phase = "cancelled" })
  self:finish_install(job, error_reply(job.id, -32800, "request cancelled"))
end

---Drop every client and stop listening.
function Server:close()
  if self.server then
    pcall(function()
      self.server:close()
    end)
    self.server = nil
  end
  for _, client in ipairs(self.clients) do
    client.closed = true
    pcall(function()
      client.peer:close()
    end)
  end
  for _, instance in pairs(self.instances) do
    if instance.stop_agent then
      pcall(instance.stop_agent)
    end
  end
  self.clients = {}
  self.instances = {}
  pcall(vim.fn.delete, self:socket())
end

return M
