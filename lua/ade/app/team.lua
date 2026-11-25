-- Teams: the front end's half of the service-owned team bus (PROTOCOL.md 20).
--
-- The service owns the bus, participants, delivery, limits and the session
-- tools injection. This module sends the per-cwd configuration, caches the
-- `team.list` snapshot per cwd, tracks each session's `session.teams` switch,
-- and exposes the methods the panel uses. No session request carries an
-- `ade-team` server any more: the service appends it.
local log = require("ade.log")
local Resolve = require("ade.manager.resolve")
local State = require("ade.session.state")
local reducer = require("ade.session.reducer")
local async = require("ade.async")
local transport = require("ade.service.transport")

local M = {}

---Message for a failed team request, including git's stderr when present.
---@param value any
---@return string
function M.error_text(value)
  local message = type(value) == "table" and (value.message or value.code) or tostring(value)
  if type(value) == "table" and type(value.data) == "table" then
    local stderr = value.data.stderr
    if type(stderr) == "string" and stderr ~= "" then
      return tostring(message) .. ": " .. stderr
    end
  end
  return tostring(message)
end

---Turn-on rules shared with the start flow and the tree (`ade.app.team_enable`).
---
---They live in their own module because the flow must not `require` this one
---(the flow reads the team module through the controller: a require cycle).
local Enable = require("ade.app.team_enable")

---What one `session.teams {enabled: true}` answer means (PROTOCOL.md 20.5).
---@param value any
---@return "reload"|"on"|"off"|"uninjected"
function M.enable_outcome(value)
  return Enable.outcome(value)
end

---The error value for a failed enable.
---@param value any
---@param outcome string|nil
---@return table
function M.enable_error(value, outcome)
  return Enable.error(value, outcome)
end

---The text to show for a failed enable.
---@param value any
---@param report fun(value: any): string|nil
---@param prefix string|nil
---@return string
function M.enable_error_text(value, report, prefix)
  return Enable.error_text(value, report, prefix)
end

---The notice shown while `session.teams` is still unanswered.
M.ENABLE_WAIT_TEXT = Enable.WAIT_TEXT

---Turn one session's tools on, coalescing a pending enable (see
---`ade.app.team_enable`). Module form so it can be injected into the start flow.
---@param team table
---@param instance string
---@param session_id string
---@param cb fun(ok: boolean, value: any)|nil
---@param opts {notify: fun(message: string, level: integer|nil)|nil, join: boolean|nil}|nil
function M.enable_session(team, instance, session_id, cb, opts)
  return Enable.run(team, instance, session_id, cb, opts)
end

local Team = {}
Team.__index = Team

---@param opts {config: fun(): table, connection: fun(): table|nil,
---  resolve_cwd: fun(): string, store: fun(): table|nil,
---  notify: fun(message: string, level: integer|nil),
---  on_changed: fun(), on_inbox: fun(item: table)|nil,
---  on_watch: fun(session: table|nil, title: string|nil)|nil,
---  on_closed: fun(team_id: string)|nil,
---  reload_session: (fun(instance: string, session_id: string, cb: fun(ok: boolean, value: any))|nil),
---  runtime: fun(): table|nil, current: (fun(): table|nil)|nil}
---@return table
function M.new(opts)
  local self = setmetatable({
    config = opts.config,
    connection = opts.connection,
    resolve_cwd = opts.resolve_cwd,
    store = opts.store,
    notify = opts.notify or function() end,
    on_changed = opts.on_changed or function() end,
    on_inbox = opts.on_inbox,
    on_watch = opts.on_watch,
    on_closed = opts.on_closed,
    on_turn = opts.on_turn,
    get_runtime = opts.runtime,
    current = opts.current,
    reload_session_fn = opts.reload_session,
    teams = {},
    inbox = {},
    -- cwd -> the exact config sent (so a rebuild/hello can re-send it).
    sent_config = {},
    resolved_config = {},
    configure_jobs = {},
    warned_skipped = {},
    -- cwd -> array of `team.list` entries, newest snapshot only.
    list_by_cwd = {},
    -- True once a full `team.list` answered successfully on this connection.
    -- "An empty snapshot" and "no snapshot yet" are different facts, and only
    -- the former may let auto-start decide a cwd has no team.
    list_ready = false,
    -- "instance\0sessionId" -> {enabled, injected, leader} from session.teams
    -- and `session.teams_changed`.
    session_states = {},
    session_seq = {},
    session_applied = {},
    session_queries = {},
    -- cwd -> {instance, session_id, team} derived from a session state whose
    -- `leader` names a team (router/bootstrap read it).
    bound = {},
    warned_suspended = {},
    notified = {},
    -- session key -> true once auto_start asked for a team there.
    auto_started = {},
    -- session key -> true when the current session itself learned its switch
    -- (a session event), not merely from a tree read. Auto-start needs this.
    auto_eligible = {},
    -- team id -> {board, inflight, again, seq} for the board cache (19.2).
    boards = {},
    -- team id -> the board_rev whose fetch was already attempted (19.2): a
    -- failed or unavailable board must not be refetched on every team.changed.
    board_requested = {},
    -- "instance\0sessionId" -> list of one-shot state listeners. Used by an
    -- enable waiting for the MCP injection (`session.teams_changed`).
    session_listeners = {},
    watching = nil,
    raw = nil,
  }, Team)
  return self
end

---@return table|nil
function Team:_raw()
  local app = self.connection()
  if not app or type(app.service_connection) ~= "function" then
    return nil
  end
  local ok, raw = pcall(app.service_connection, app)
  if not ok or type(raw) ~= "table" then
    return nil
  end
  return raw
end

---The name of the worker template teams use when `teams.templates` is empty.
---
---It is not a configuration key: the front end derives the entry itself from
---the leader's own launch, so nothing a person writes (or a tool argument
---names) can point a worker at another command. The name is shared with the
---configuration validator so a workflow may ask for it.
M.BUILTIN_TEMPLATE = require("ade.config").BUILTIN_TEMPLATE

---Whether any template can be offered: explicit ones, or the service's
---built-in worker (created from the leader's own launch when the list is
---empty, PROTOCOL.md 20.4).
---@param cfg table
---@param teams table
---@return boolean
local function templates_possible(cfg, teams)
  if next(teams.templates or {}) ~= nil then
    return true
  end
  return type(cfg.agent) == "string" and type(cfg.agents) == "table" and type(cfg.agents[cfg.agent]) == "table"
end

---Whether this editor should use service teams at all.
---
---This is only the backend/connection gate: the global switch (`teams.enabled`)
---is part of the configuration sent to the service, and the per-session switch
---decides what a session may do.
---@return boolean
function Team:available()
  local cfg = self.config() or {}
  if cfg.backend == "direct" then
    return false
  end
  local raw = self:_raw()
  if not raw then
    return false
  end
  self:_attach(raw)
  return raw:is_connected() and raw:has_feature("teams")
end

---@param raw table
function Team:_attach(raw)
  if self.raw == raw then
    return
  end
  self.raw = raw
  self.sent_config = {}
  if type(raw.on_hello) == "function" then
    raw:on_hello("teams", function()
      self:on_hello()
    end)
  end
  if type(raw.subscribe) == "function" then
    raw:subscribe("teams", "team.changed", function(payload)
      self:on_changed_payload(payload)
    end)
    raw:subscribe("teams", "team.inbox", function(payload)
      self:on_inbox_payload(payload)
    end)
    raw:subscribe("teams", "team.board_changed", function(payload)
      self:on_board_changed_payload(payload)
    end)
    raw:subscribe("teams", "session.teams_changed", function(payload)
      self:on_session_teams_changed(payload)
    end)
    raw:subscribe("teams", "__disconnected", function()
      self:forget_connection()
    end)
  end
end

---Forget connection-scoped state; stored teams stay visible.
function Team:forget_connection()
  for _, team in pairs(self.teams) do
    if type(team) == "table" then
      team.stale = true
    end
  end
  local inflight_config = self.configure_jobs
  self.configure_jobs = {}
  for _, entry in pairs(inflight_config or {}) do
    for _, waiter in ipairs(entry.waiters or {}) do
      pcall(waiter, false, "the service connection was lost")
    end
  end
  self.sent_config = {}
  self.session_states = {}
  self.session_queries = {}
  self.auto_eligible = {}
  self.bound = {}
  self.list_ready = false
  self.session_listeners = {}
  -- A held enable reply from the old connection will never arrive; settle its
  -- callers instead of leaving a start flow waiting forever.
  Enable.cancel_all(self, "the service connection was lost")
  -- A board request that was in flight when the connection died may still
  -- call back; bumping its token makes that late reply a no-op while the next
  -- `team.changed` can start a fresh request.
  for _, entry in pairs(self.boards) do
    if type(entry) == "table" then
      entry.seq = (entry.seq or 0) + 1
      entry.inflight = false
      entry.again = false
    end
  end
  -- A reconnect may reach a different service; let revisions be tried again.
  self.board_requested = {}
  -- `warned_suspended` / `notified` survive a reconnect: a conflict that was
  -- already announced must not be announced again.
  self:unwatch(true)
  self:changed()
end

---Forget everything, including the team list (service gone/teams unavailable).
function Team:reset()
  self.teams = {}
  self.inbox = {}
  self.boards = {}
  self:forget_connection()
end

---A service restart leaves teams suspended until their leader session returns.
function Team:on_hello()
  -- A new handshake may be a newer service.
  self.old_service = false
  self.warned_old_service = false
  self:forget_connection()
  local cwd = self.resolve_cwd and self.resolve_cwd() or nil
  if cwd then
    self:configure(cwd, true)
  end
  self:refresh()
  -- Warm the workflow cache for completion; failure only means the list stays
  -- as it was, never an error the person has to read.
  self:refresh_workflows()
end

---Whether a known team is suspended (waiting for its leader session).
---@param team_id string|nil
---@return boolean
function Team:is_suspended(team_id)
  local team = type(team_id) == "string" and self.teams[team_id] or nil
  return type(team) == "table" and team.state == "suspended"
end

---Whether a team is from before a lost connection and not refreshed yet.
---@param team_id string|nil
---@return boolean
function Team:is_stale(team_id)
  local team = type(team_id) == "string" and self.teams[team_id] or nil
  return type(team) == "table" and team.stale == true
end

---Whether a team entry carries no work at all.
---
---A team of a chat session has only its leader and no worker, inbox item,
---workflow or card. The tree can still show it, but the start flow treats it
---like any other team the service answers `led_by` for.
---@param entry table|nil team.list entry
---@return boolean
function M.inactive(entry)
  if type(entry) ~= "table" or entry.state ~= "active" then
    return false
  end
  for _, participant in ipairs(entry.participants or {}) do
    local name = type(participant) == "table" and participant.name or nil
    if name ~= nil and name ~= "leader" and name ~= "human" then
      return false
    end
  end
  for _, item in ipairs(entry.inbox or {}) do
    if type(item) == "table" and (item.state == nil or item.state == "open") then
      return false
    end
  end
  if type(entry.workflow_name) == "string" and entry.workflow_name ~= "" then
    return false
  end
  if tonumber(entry.board_rev) ~= nil and tonumber(entry.board_rev) > 0 then
    return false
  end
  return true
end

---The team of a cwd from the last snapshot, in any state but closed.
---@param cwd string|nil
---@return table|nil
function Team:team_for_cwd(cwd)
  if type(cwd) ~= "string" then
    return nil
  end
  for _, entry in ipairs(self.list_by_cwd[cwd] or {}) do
    if entry.state ~= "closed" then
      return entry
    end
  end
end

---The leader instance a cwd's team runs on, for callers that need one before
---an agent client attaches.
---@param cwd string|nil
---@return string|nil
function Team:leader_instance(cwd)
  local team = self:team_for_cwd(cwd)
  local leader = type(team) == "table" and type(team.leader) == "table" and team.leader or nil
  return leader and leader.instance or nil
end

---Whether `session` still leads a team, so it must not be closed as idle.
---@param session table|nil
---@return boolean
function Team:leads_team(session)
  if not session or type(session.id) ~= "string" then
    return false
  end
  for _, team in pairs(self.teams) do
    local leader = type(team) == "table" and type(team.leader) == "table" and team.leader or nil
    if
      leader
      and leader.sessionId == session.id
      and team.state ~= "closed"
      and (leader.instance == nil or session.instance == nil or leader.instance == session.instance)
    then
      return true
    end
  end
  for _, state in pairs(self.session_states) do
    if type(state) == "table" and type(state.leader) == "table" and state.leader.sessionId == session.id then
      return true
    end
  end
  return false
end

---The absolute directory the service creates worker worktrees under (18.12).
---@return string
function M.worktree_root()
  local path = vim.fn.stdpath("data") .. "/ade/worktrees"
  path = vim.fn.fnamemodify(path, ":p")
  if #path > 1 then
    path = path:gsub("/+$", "")
  end
  return path
end

---Turn one resolved template into the wire entry of `team.configure` (19.1).
---@param cfg table
---@param agent_id string
---@param launch table result of `Resolve.resolve`
---@param template table `{model?, models?, role?, worktree?}`
---@return table
local function wire_template(cfg, agent_id, launch, template)
  local agents = require("ade.agents")
  local models = template.models
  if type(models) == "table" and #models == 0 then
    models = nil
  end
  local profile = agents.get(cfg.agents and cfg.agents[agent_id] or nil, agent_id)
  local entry = {
    key = { agent = agent_id, command = launch.command, args = launch.args or {} },
    env = transport.child_env(launch.env or (cfg.agents[agent_id] or {}).env),
    model = template.model,
    role = template.role or "",
    models = models,
    -- pi reaches MCP tools through its own `mcp` proxy (19.6).
    tool_style = profile and profile.name == "pi" and "mcp_proxy" or "direct",
    worktree = template.worktree == true,
  }
  if launch.source == "managed" and launch.install_id then
    entry.launch = {
      root = Resolve.manager_root(cfg),
      agent = agent_id,
      installId = launch.install_id,
    }
  end
  return entry
end

---Resolve the configuration the service expects (18.2, 19.1, 20.2).
---
---With no `teams.templates` the list stays empty: the service builds its one
---`worker` template from the leader instance's own `key`, `env` and `launch`
---(PROTOCOL.md 20.4). An `inherit` template is resolved from the current agent
---here because it still has to name a concrete launch on the wire.
---@param cwd string
---@return table|nil config
---@return table|nil skipped
function Team:service_config(cwd)
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  local store = self.store and self.store() or nil
  local templates = {}
  -- Problems that keep a template from starting, in the order they were found.
  local skipped = {}
  for name, template in pairs(teams.templates or {}) do
    local agent_id = template.agent
    if agent_id == "inherit" then
      agent_id = type(cfg.agent) == "string" and cfg.agent or nil
    end
    if type(agent_id) ~= "string" or agent_id == "" then
      skipped[#skipped + 1] = { name = name, text = string.format("%s: no agent to inherit", name) }
    else
      local launch, err = Resolve.resolve(cfg, agent_id, cfg.launch_origin, store)
      if not launch then
        skipped[#skipped + 1] = { name = name, text = string.format("%s: %s", name, tostring(err)) }
      else
        templates[name] = wire_template(cfg, agent_id, launch, template)
      end
    end
  end
  local confirm = type(teams.spawn_confirm) == "table" and teams.spawn_confirm or {}

  local limits = type(teams.limits) == "table" and teams.limits or {}
  local workflows = {}
  for name, workflow in pairs(teams.workflows or {}) do
    local copy = vim.deepcopy(workflow)
    if type(copy.leader) == "table" and next(copy.leader) == nil then
      -- An empty Lua table encodes as `[]`; `leader` must be an object.
      copy.leader = nil
    end
    if type(copy.summary) ~= "string" or copy.summary == "" then
      -- 19.1 requires a summary on the wire; a config entry may rely on its
      -- text's first line instead (the draft's `default = { text = ... }`).
      local first = tostring(copy.text or ""):match("^[^\r\n]*") or ""
      first = vim.trim(first)
      if vim.fn.strchars(first) > 120 then
        first = vim.fn.strcharpart(first, 0, 120)
      end
      copy.summary = first ~= "" and first or name
    end
    workflows[name] = copy
  end
  return {
    enabled = teams.enabled ~= false,
    session_default = teams.session_default ~= false,
    max_workers = teams.max_workers or 3,
    worktree_root = M.worktree_root(),
    spawn_confirm = { auto = vim.deepcopy(confirm.auto or {}) },
    limits = {
      max_turns_per_task = limits.max_turns_per_task or 30,
      max_turns_total = limits.max_turns_total or 200,
    },
    templates = next(templates) and templates or vim.empty_dict(),
    -- An empty Lua table encodes as a JSON array; the service expects an
    -- object for `workflows` (19.1).
    workflows = next(workflows) and workflows or vim.empty_dict(),
    default_workflow = teams.default,
  },
    skipped
end

---Whether the service has a template to work with: our explicit ones or its
---built-in worker. An explicit configuration whose every template failed is
---not usable.
---@param cwd string
---@return boolean
function Team:has_usable_templates(cwd)
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  if next(teams.templates or {}) == nil then
    return templates_possible(cfg, teams)
  end
  local config = self:service_config(cwd)
  return config ~= nil and next(config.templates or {}) ~= nil
end

---Names of the templates this editor can start, for pickers and completion.
---
---With no `teams.templates` this is the single built-in name, so a UI can offer
---it without knowing the fallback rule. It never resolves an agent: a template
---whose agent is broken still appears here and fails with its own error when
---started.
---@return string[]
function Team:template_names()
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  local names, seen = {}, {}
  for name in pairs(teams.templates or {}) do
    if type(name) == "string" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  if #names == 0 and templates_possible(cfg, teams) then
    names[1] = M.BUILTIN_TEMPLATE
  end
  table.sort(names)
  return names
end

---Why no template can be started, for a request that must explain a failure.
---
---The same strings `configure` warns about, joined; nil when at least one
---template resolved.
---@param cwd string
---@return string|nil
function Team:template_error(cwd)
  local config, skipped = self:service_config(cwd)
  if config == nil then
    return nil
  end
  if next(config.templates or {}) ~= nil then
    return nil
  end
  if type(skipped) == "table" and #skipped > 0 then
    local parts = {}
    for _, problem in ipairs(skipped) do
      parts[#parts + 1] = tostring(problem.text or problem)
    end
    return table.concat(parts, "; ")
  end
  return "no template is configured"
end

---Send `team.configure` for a cwd when the resolved config changed.
---
---Requests are serialized per cwd: a configuration that becomes ready while an
---older one is in flight is sent afterwards, so the last request always carries
---the newest configuration (PROTOCOL.md 20.2 needs the service to hold it
---before the session request).
---@param cwd string
---@param force boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:configure(cwd, force, cb)
  cb = cb or function() end
  if not self:available() then
    cb(false, "teams are not available")
    return
  end
  local config, skipped = self:service_config(cwd)
  local changed = not vim.deep_equal(config, self.resolved_config[cwd])
  if changed then
    -- A new configuration is a fresh reason to explain its broken templates.
    self.warned_skipped[cwd] = {}
    self.resolved_config[cwd] = config
  end
  local warned = self.warned_skipped[cwd] or {}
  for _, problem in ipairs(skipped or {}) do
    -- A zero-config editor has no template the person wrote: an unresolvable
    -- leader launch is already visible from the session failing, so the derived
    -- template stays quiet here. An explicit `:Ade team start` still reports it
    -- (`template_error`), because there the person asked for a team.
    if not problem.builtin then
      -- The same name+error is announced once per configuration, not on every
      -- hello/reconcile pass.
      local key = tostring(problem.text)
      if not warned[key] then
        warned[key] = true
        self.notify("team template skipped: " .. key, vim.log.levels.WARN)
      end
    end
  end
  self.warned_skipped[cwd] = warned
  local explicit = next(((self.config() or {}).teams or {}).templates or {}) ~= nil
  if explicit and next(config.templates or {}) == nil then
    -- Every explicitly configured template failed to resolve: behave as if
    -- teams were unavailable.
    self.sent_config[cwd] = nil
    cb(false, "no usable team templates")
    return
  end
  local job = self.configure_jobs[cwd]
  if not job then
    job = { waiters = {}, generation = 0 }
    self.configure_jobs[cwd] = job
  end
  job.config = config
  job.force = job.force == true or force == true
  job.generation = job.generation + 1
  job.waiters[#job.waiters + 1] = cb
  self:_flush_configure(cwd)
end

---Send the newest queued configuration, once per in-flight request.
---@param cwd string
function Team:_flush_configure(cwd)
  local job = self.configure_jobs[cwd]
  if not job or job.inflight then
    return
  end
  if not job.force and vim.deep_equal(job.config, self.sent_config[cwd]) then
    self.configure_jobs[cwd] = nil
    for _, waiter in ipairs(job.waiters) do
      pcall(waiter, true, nil)
    end
    return
  end
  local raw = self:_raw()
  if not raw then
    self.configure_jobs[cwd] = nil
    for _, waiter in ipairs(job.waiters) do
      pcall(waiter, false, "teams are not available")
    end
    return
  end
  local config = job.config
  job.inflight = true
  job.force = false
  job.sent_generation = job.generation
  raw:request_tracked("team.configure", { cwd = cwd, config = config }, function(ok, value)
    job.inflight = false
    if self.configure_jobs[cwd] ~= job then
      -- The connection was lost; its waiters were already told.
      return
    end
    if ok then
      self.sent_config[cwd] = config
    else
      local message = type(value) == "table" and (value.message or value.code) or tostring(value)
      log.warn("team.configure failed: %s", tostring(message))
    end
    if not vim.deep_equal(job.config, config) then
      -- A newer configuration arrived while this one was in flight.
      self:_flush_configure(cwd)
      return
    end
    self.configure_jobs[cwd] = nil
    for _, waiter in ipairs(job.waiters) do
      pcall(waiter, ok, value)
    end
  end)
end

---@param instance string|nil
---@param session_id string|nil
---@return string|nil
local function session_key(instance, session_id)
  if not instance or not session_id then
    return nil
  end
  return tostring(instance) .. "\0" .. tostring(session_id)
end

---Prepare a cwd before its first session request (PROTOCOL.md 20.2): the
---configuration must reach the service before it augments `mcpServers`.
---
---Blocks the session task through the async scope; a cached, unchanged
---configuration returns immediately. A failure is reported but never stops the
---session request: the session simply gets no team tools (single chat).
---@param cwd string
---@param client table|nil the client that will own the session
function Team:prepare(cwd, client)
  local attach_cwd = client and client.proc and client.proc.key and client.proc.key.cwd or cwd
  if not self:available() then
    return
  end
  local ok, value = async.await(function(settled)
    self:configure(attach_cwd, false, function(configured, err)
      settled(configured, err)
    end)
  end)
  if not ok then
    local message = type(value) == "table" and (value.message or value.code) or tostring(value)
    -- We cannot opt this one request out of a configuration the service already
    -- holds, so do not promise "no tools": say the configuration failed and the
    -- session may miss them.
    self.notify(
      "team configuration did not apply; this session may not get team tools: " .. tostring(message),
      vim.log.levels.WARN
    )
  end
end

---The known `session.teams` state of a session.
---@param instance string|nil
---@param session_id string|nil
---@return table|nil
function Team:session_teams(instance, session_id)
  local key = session_key(instance, session_id)
  local state = key and self.session_states[key] or nil
  return type(state) == "table" and state or nil
end

---Whether the cached state of `(instance, sessionId)` can be acted on.
---`nil` means "not known yet" and callers must query instead of assuming off.
---@param instance string|nil
---@param session_id string|nil
---@return table|nil
function Team:known_session_teams(instance, session_id)
  return self:session_teams(instance, session_id)
end

---Record one `session.teams` state and keep the router's leader shortcut warm.
---
---`seq` is the request generation for a reply: a reply older than one already
---applied (a newer notification, or a newer request's reply) is ignored.
---@param instance string
---@param session_id string
---@param value table
---@param seq integer|nil
---@param opts {evaluate: boolean|nil}|nil `evaluate = false` is a pure read:
---  it caches the state but never lets it start a team (tree queries).
function Team:apply_session_teams(instance, session_id, value, seq, opts)
  local key = session_key(instance, session_id)
  if not key or type(value) ~= "table" then
    return
  end
  local applied = self.session_applied[key] or 0
  if seq ~= nil then
    if applied > seq then
      return
    end
  else
    -- A notification or a locally applied switch is the newest word: bump the
    -- generation so an outstanding query's reply cannot overwrite it.
    local next_seq = math.max(applied, self.session_seq[key] or 0) + 1
    self.session_seq[key] = next_seq
    seq = next_seq
  end
  self.session_applied[key] = seq
  local state = {
    enabled = value.enabled == true,
    injected = value.injected == true,
    leader = type(value.leader) == "table" and value.leader or nil,
    seq = seq,
  }
  self.session_states[key] = state
  -- Tell an enable that is waiting for the injection (a forwarded load only
  -- restarts the log; the MCP process may still be connecting).
  local listeners = self.session_listeners and self.session_listeners[key]
  for _, listener in ipairs(listeners or {}) do
    pcall(listener, state)
  end
  for cwd, bound in pairs(self.bound) do
    if bound.session_id == session_id and bound.instance == instance then
      self.bound[cwd] = nil
    end
  end
  if state.leader then
    local cwd = state.leader.cwd or (self.teams[state.leader.id] or {}).cwd
    if cwd then
      self.bound[cwd] = { instance = instance, session_id = session_id, team = state.leader.id }
    end
  end
  -- Only a real state change of the session on screen may auto-start, and only
  -- once the authoritative team snapshot is in. A tree query passes
  -- `evaluate = false`, so merely browsing never starts anything.
  if not opts or opts.evaluate ~= false then
    -- Only a session event that itself reports the tools injected may enable
    -- auto-start. A tree read (or a session event that still says "not
    -- injected") must never become the trigger, not even via a later refresh.
    self.auto_eligible[key] = state.enabled == true and state.injected == true
    self:_maybe_auto_start(instance, session_id)
  end
  self:changed()
end

---@param payload table
function Team:on_session_teams_changed(payload)
  if type(payload) ~= "table" then
    return
  end
  self:apply_session_teams(payload.instance, payload.sessionId, payload)
end

---Whether `(instance, sessionId)` is the session on screen.
---@param instance string|nil
---@param session_id string|nil
---@return boolean
function Team:is_current(instance, session_id)
  local session
  if self.current then
    local ok, value = pcall(self.current)
    session = ok and value or nil
  else
    local runtime = self.get_runtime and self.get_runtime() or nil
    session = runtime and runtime.current or nil
  end
  if not session or session.id ~= session_id then
    return false
  end
  return not instance or not session.instance or session.instance == instance
end

---@param key string
---@return integer
function Team:next_session_seq(key)
  self.session_seq[key] = (self.session_seq[key] or 0) + 1
  return self.session_seq[key]
end

---Query the switch and leadership of one session.
---
---`opts.source` says who asked: `"tree"` is a pure read (browsing), and only a
---current-session event (`"session"`, the default) may evaluate auto-start. The
---source is fixed at request time, never inferred from the reply.
---@param instance string|nil
---@param session_id string|nil
---@param cwd string|nil known cwd, for the error text only
---@param cb fun(ok: boolean, value: any)|nil
---@param opts {source: string|nil}|nil
function Team:query_session_teams(instance, session_id, cwd, cb, opts)
  cb = cb or function() end
  local key = session_key(instance, session_id)
  if not key or not self:available() then
    cb(false, "teams are not available")
    return
  end
  local query = self.session_queries[key]
  if not query then
    query = { inflight = false, again = false }
    self.session_queries[key] = query
  end
  if query.inflight then
    query.again = true
    -- Keep every source that joined this in-flight request: a tree read must
    -- not swallow the real session event that arrives while it runs, or the
    -- re-sent query would stay a pure read and never evaluate auto-start.
    local source = type(opts) == "table" and opts.source or "session"
    if source ~= "tree" or query.again_source == "session" then
      query.again_source = "session"
    else
      query.again_source = "tree"
    end
    query.waiters = query.waiters or {}
    query.waiters[#query.waiters + 1] = cb
    return
  end
  query.inflight = true
  local seq = self:next_session_seq(key)
  self:_call("session.teams", { instance = instance, sessionId = session_id }, function(ok, value)
    query.inflight = false
    if ok and type(value) == "table" then
      -- A pure read (the tree) never evaluates auto-start. A session event may,
      -- for the session on screen only.
      local source = type(opts) == "table" and opts.source or "session"
      local evaluate = source ~= "tree" and self:is_current(instance, session_id)
      self:apply_session_teams(instance, session_id, value, seq, { evaluate = evaluate })
    elseif self.session_queries[key] == query then
      -- A failed query must not poison the cache: a later attempt may retry.
      self.session_queries[key] = nil
    end
    cb(ok, value)
    for _, waiter in ipairs(query.waiters or {}) do
      pcall(waiter, ok, value)
    end
    query.waiters = nil
    local again = query.again
    local again_source = query.again_source
    query.again = false
    query.again_source = nil
    if again and self.session_queries[key] == query then
      -- Re-send with the strongest source that joined the in-flight request.
      self:query_session_teams(instance, session_id, cwd, function() end, {
        source = again_source or "session",
      })
    end
  end)
end

---A session was created or restored: learn its switch state.
---@param instance string|nil
---@param session_id string|nil
---@param cwd string|nil
function Team:session_opened(instance, session_id, cwd)
  if not self:available() or not instance or not session_id then
    return
  end
  self:query_session_teams(instance, session_id, cwd, function() end)
end

---The raw `session.teams` write, without coalescing or outcome evaluation.
---@param team table
---@param instance string
---@param session_id string
---@param enabled boolean
---@param close boolean|nil
---@param cb fun(ok: boolean, value: any)
local function _write_session_teams(team, instance, session_id, enabled, close, cb)
  local key = session_key(instance, session_id)
  local params = { instance = instance, sessionId = session_id, enabled = enabled }
  if close then
    params.close = true
  end
  local seq = key and team:next_session_seq(key) or nil
  team:_call("session.teams", params, function(ok, value)
    if ok and type(value) == "table" then
      -- `reload: true` means the service marked the session for a forwarded
      -- load and its `injected` is not true yet; keep that in the cache so the
      -- tree does not claim the tools are there.
      if value.reload ~= true then
        team:apply_session_teams(instance, session_id, value, seq)
      end
    end
    -- A closed team disappears from the snapshot only after `team.changed`.
    if ok and close then
      team:refresh()
    end
    cb(ok, value)
  end)
end

---Flip the per-session switch (PROTOCOL.md 20.5).
---
---`enabled: true` against a session whose tools were never injected answers
---`reload: true`: the service marks the session one-shot forward and the front
---end must run its normal load path (`Sessions:load`) to get the tools. The
---`value` passed to `cb` carries that flag; `Team:reload_session` does the load.
---
---This is the raw write: exactly one request per call and the reply passed
---through untouched. The user-facing "turn teams on" paths go through
---`M.enable_session`, which coalesces concurrent enables and evaluates the
---three outcomes.
---@param instance string
---@param session_id string
---@param enabled boolean
---@param close boolean|nil close a led team first
---@param cb fun(ok: boolean, value: any)|nil
function Team:set_session_teams(instance, session_id, enabled, close, cb)
  cb = cb or function() end
  if enabled and close then
    -- Only an enable that also closes a led team is a write of its own: settle
    -- a pending plain enable so both replies cannot race a reload. A plain
    -- enable here is `team_enable`'s own write and must not cancel itself.
    Enable.cancel(self, instance, session_id, { message = "superseded by a closing enable" })
  end
  if enabled == false then
    -- The person explicitly turned the tools off while an enable→reload is in
    -- flight. Do not cancel the enable (its load is still running and the
    -- session must settle), but mark it: the late load must not report success
    -- and a start flow must not continue. A failed off restore the enable.
    Enable.supersede(self, instance, session_id, "off")
    _write_session_teams(self, instance, session_id, enabled, close, function(ok, value)
      if not ok then
        Enable.resume(self, instance, session_id)
      end
      cb(ok, value)
    end)
    return
  end
  _write_session_teams(self, instance, session_id, enabled, close, cb)
end

---Turn this session's tools on, coalescing a pending enable (`team_enable`).
---@param instance string
---@param session_id string
---@param cb fun(ok: boolean, value: any)|nil
---@param opts {notify: fun(message: string, level: integer|nil)|nil, join: boolean|nil}|nil
function Team:enable_session(instance, session_id, cb, opts)
  return M.enable_session(self, instance, session_id, cb, opts)
end

---Run the front-end half of the in-place reload (PROTOCOL.md 20.5).
---
---The service marks the session one-shot forward and answers `reload: true`;
---the load must be a real `session/load` (or `session/resume`) so the agent
---replays and the injection happens. `Sessions:load` is the normal path: it
---clears and re-renders the transcript, so the reload is visible, not a silent
---flag flip.
---Watch one `(instance, sessionId)` switch until `cb` is called once.
---
---The enable that follows a forwarded load needs the *real* injection state:
---a successful load restarts the transcript, but the agent's MCP process may
---connect later (or never). This registers a one-shot listener fed by
---`apply_session_teams`; the caller races it against its own timeout.
---@param instance string
---@param session_id string
---@param cb fun(state: table)
---@return fun() unsubscribe
function Team:watch_session_state(instance, session_id, cb)
  local key = session_key(instance, session_id)
  if not key then
    return function() end
  end
  self.session_listeners = self.session_listeners or {}
  local list = self.session_listeners[key] or {}
  self.session_listeners[key] = list
  local listener = function(state)
    if self.session_listeners[key] == list then
      for index, entry in ipairs(list) do
        if entry == listener then
          table.remove(list, index)
          break
        end
      end
      if #list == 0 then
        self.session_listeners[key] = nil
      end
    end
    pcall(cb, state)
  end
  list[#list + 1] = listener
  return function()
    local current = self.session_listeners and self.session_listeners[key]
    if not current then
      return
    end
    for index, entry in ipairs(current) do
      if entry == listener then
        table.remove(current, index)
        break
      end
    end
    if #current == 0 and self.session_listeners then
      self.session_listeners[key] = nil
    end
  end
end

---@param instance string
---@param session_id string
---@param cb fun(ok: boolean, value: any)|nil
function Team:reload_session(instance, session_id, cb)
  cb = cb or function() end
  if not self.reload_session_fn then
    cb(false, "this front end cannot reload a session")
    return
  end
  -- A reload that the loader refuses (busy session, another replay) never
  -- occupies the pair: bumping its generation would wrongly cancel the valid
  -- load already running for the same session.
  local key = session_key(instance, session_id)
  local reloads = self.reload_attempts or {}
  local attempt = (reloads[key] or 0) + 1
  local claimed = false
  local ok, err = pcall(self.reload_session_fn, instance, session_id, function(reloaded, value)
    if claimed and (reloads[key] or 0) ~= attempt then
      -- A newer reload of the same pair owns the outcome now.
      cb(false, "the reload was superseded")
      return
    end
    if not claimed then
      if not reloaded then
        -- Rejected before it could run: this attempt is over and must not have
        -- invalidated anything.
        cb(false, value)
        return
      end
      claimed = true
      reloads[key] = attempt
      self.reload_attempts = reloads
    end
    if not self:available() then
      cb(false, "the reload was cancelled")
      return
    end
    if reloaded then
      -- The load's own bind reports the fresh switch; query it so the cache
      -- carries `injected: true` rather than the pre-load answer.
      self:query_session_teams(instance, session_id, nil, function() end)
    end
    cb(reloaded, value)
  end)
  if not ok then
    cb(false, tostring(err))
  end
end

---Move a team's leadership to a session (PROTOCOL.md 20.4).
---@param team string
---@param instance string
---@param session_id string
---@param cb fun(ok: boolean, value: any)|nil
function Team:set_leader(team, instance, session_id, cb)
  cb = cb or function() end
  self:_call("team.set_leader", { team = team, instance = instance, sessionId = session_id }, function(ok, value)
    if ok then
      self:refresh()
    end
    cb(ok, value)
  end)
end

---Stop one worker; `remove` drops it from the team afterwards (20.6).
---@param team string
---@param name string
---@param remove boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:stop_worker(team, name, remove, cb)
  cb = cb or function() end
  local params = { team = team, name = name }
  if remove then
    params.remove = true
  end
  self:_call("team.stop_worker", params, function(ok, value)
    if ok then
      self:refresh()
    end
    cb(ok, value)
  end)
end

---Start a workflow in one session (PROTOCOL.md 20.4).
---@param instance string
---@param session_id string
---@param workflow string
---@param task string|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:start_session(instance, session_id, workflow, task, cb)
  cb = cb or function() end
  self:_call(
    "team.start",
    { instance = instance, sessionId = session_id, workflow = workflow, task = task },
    function(ok, value)
      if ok then
        self:refresh()
      end
      cb(ok, value)
    end
  )
end

---Start the configured default workflow for the session on screen, once its
---switch is on, tools are injected and the cwd has no team.
---
---Triggered only by current-session events (`session.teams_changed` or a query
---about the session on screen), never by browsing the tree. The decision waits
---for a complete `team.list` on this connection: "no snapshot yet" and "the
---snapshot lists no team for this cwd" are different facts.
---@param instance string|nil
---@param session_id string|nil
function Team:_maybe_auto_start(instance, session_id)
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  if teams.enabled == false or teams.auto_start ~= true then
    return
  end
  if self.auto_starting then
    return
  end
  if not self:is_current(instance, session_id) then
    return
  end
  local session
  if self.current then
    local ok, value = pcall(self.current)
    session = ok and value or nil
  else
    local runtime = self.get_runtime and self.get_runtime() or nil
    session = runtime and runtime.current or nil
  end
  if not session then
    return
  end
  local key = session_key(instance, session_id)
  local state = key and self.session_states[key] or nil
  if not state or state.enabled ~= true or state.injected ~= true or state.leader ~= nil then
    return
  end
  if not key or self.auto_started[key] or not self.auto_eligible[key] then
    return
  end
  local cwd = session.cwd
  if not cwd or not self.list_ready then
    -- A complete snapshot has not arrived yet; `refresh`'s completion re-runs
    -- this decision. An empty snapshot does set `list_ready`, so a project
    -- with no team at all can still auto-start.
    return
  end
  if self:team_for_cwd(cwd) then
    return
  end
  if require("ade.app.team_start").active(cwd) then
    return
  end
  self.auto_started[key] = true
  self.auto_starting = true
  local workflow = teams.default or "default"
  self:start_session(instance, session_id, workflow, nil, function(ok, err)
    self.auto_starting = false
    if not ok then
      self.notify("could not start workflow " .. tostring(workflow) .. ": " .. M.error_text(err), vim.log.levels.WARN)
    end
  end)
end

---Re-evaluate auto-start with the state of the current session.
function Team:_reconsider_auto_start()
  local ok, session = pcall(function()
    if self.current then
      return self.current()
    end
    local runtime = self.get_runtime and self.get_runtime() or nil
    return runtime and runtime.current or nil
  end)
  session = ok and session or nil
  if not session then
    return
  end
  self:_maybe_auto_start(session.instance, session.id)
end

---Refresh the whole team list.
---@param cb fun()|nil
function Team:refresh(cb)
  if not self:available() then
    self.teams = {}
    self.inbox = {}
    self.list_by_cwd = {}
    self.list_ready = false
    self:changed()
    if cb then
      cb()
    end
    return
  end
  local raw = self:_raw()
  raw:request_tracked("team.list", {}, function(ok, value)
    if ok and type(value) == "table" and type(value.teams) == "table" then
      local teams = {}
      local by_cwd = {}
      for _, team in ipairs(value.teams) do
        team.stale = false
        teams[team.id] = team
        local cwd = team.cwd
        if type(cwd) == "string" then
          by_cwd[cwd] = by_cwd[cwd] or {}
          by_cwd[cwd][#by_cwd[cwd] + 1] = team
        end
      end
      self.list_by_cwd = by_cwd
      self.list_ready = true
      -- Keep open items announced by `team.inbox` when an older snapshot does
      -- not list them yet: the list and the notification stream race.
      local announced = {}
      for id, item in pairs(self.inbox) do
        if item.state == "open" then
          announced[id] = item
        end
      end
      self.teams = teams
      self.inbox = {}
      for id, team in pairs(teams) do
        for _, item in ipairs(team.inbox or {}) do
          item.team = item.team or id
          self.inbox[item.id] = item
          if item.state == "open" then
            -- Items first seen through refresh were already announced by the
            -- service; do not notify them again after a reconnect.
            self.notified[item.id] = item.team
          end
        end
      end
      for id, item in pairs(announced) do
        if self.inbox[id] == nil and teams[item.team] ~= nil then
          self.inbox[id] = item
        end
      end
      -- The snapshot is authoritative now: a pending auto-start may decide.
      self:_reconsider_auto_start()
      self:changed()
    else
      -- A failed refresh means the stored list can no longer be trusted.
      self.teams = {}
      self.inbox = {}
      self.list_by_cwd = {}
      self.list_ready = false
      self:changed()
    end
    self:_sync_boards()
    if cb then
      cb()
    end
  end)
end

---Fetch the board of `team` when its cached revision is stale (19.2).
function Team:_fetch_board_if_needed(team)
  local rev = tonumber(type(team) == "table" and team.board_rev or nil)
  if rev == nil or self.old_service then
    return
  end
  local cached = self.boards[team.id]
  if cached and type(cached.board) == "table" and tonumber(cached.board.rev) == rev then
    return
  end
  if self.board_requested[team.id] == rev then
    -- Already tried this revision (a failure or an unavailable board waits for
    -- the next `team.board_changed`).
    return
  end
  self.board_requested[team.id] = rev
  self:request_board(team.id)
end

---Ask for the board of every known team whose cached revision is stale (19.2).
function Team:_sync_boards()
  if self.old_service then
    return
  end
  for _, team in pairs(self.teams) do
    self:_fetch_board_if_needed(team)
  end
end

---The cached board of a team (19.2), or nil before the first fetch.
---@param team_id string
---@return table|nil
function Team:board(team_id)
  local entry = self.boards[team_id]
  return type(entry) == "table" and entry.board or nil
end

---Fetch `team.board` once per team at a time.
---
---A `team.board_changed` that arrives while a request is in flight sets a latch;
---the request's completion then fetches the current revision once more, so the
---cache ends up at the latest state, never at an intermediate one.
---@param team_id string
---@param cb fun(ok: boolean, board: table|nil)|nil
function Team:request_board(team_id, cb)
  cb = cb or function() end
  if type(team_id) ~= "string" then
    cb(false, nil)
    return
  end
  if self.old_service then
    -- An api-5 service has no team.board; never retry it in a loop.
    cb(false, nil)
    return
  end
  local entry = self.boards[team_id]
  if type(entry) ~= "table" then
    entry = { board = nil, inflight = false, again = false, seq = 0 }
    self.boards[team_id] = entry
  end
  if entry.inflight then
    entry.again = true
    return
  end
  if not self:available() then
    cb(false, nil)
    return
  end
  entry.inflight = true
  -- A per-request token: a reply that arrives after the team was closed, the
  -- cache reset or the connection dropped must not touch a newer request.
  entry.seq = (entry.seq or 0) + 1
  local seq = entry.seq
  self:_call("team.board", { team = team_id }, function(ok, value)
    if self.boards[team_id] ~= entry or entry.seq ~= seq then
      cb(ok, nil)
      return
    end
    entry.inflight = false
    if ok and type(value) == "table" and type(value.board) == "table" then
      entry.board = value.board
      self:changed()
    end
    cb(ok, ok and entry.board or nil)
    if entry.again then
      entry.again = false
      self:request_board(team_id)
    end
  end)
end

function Team:changed()
  pcall(self.on_changed)
end

---A team disappeared: closed here, by another front end, or by the service.
---The local caches are already updated; the panel uses this to close or move
---to the next team.
---
---`entry` is the closed team's last known row. The caches no longer have it, so
---the panel needs it to know which project lost its team and which session was
---its leader (the router has to return there before the pane goes away).
---@param team_id string
---@param entry table|nil
function Team:closed(team_id, entry)
  if type(self.on_closed) == "function" then
    pcall(self.on_closed, team_id, entry)
  end
end

---@param payload table
function Team:on_changed_payload(payload)
  local team = type(payload) == "table" and (payload.team or payload) or nil
  if type(team) ~= "table" or type(team.id) ~= "string" then
    return
  end
  if team.state == "closed" then
    local entry = vim.deepcopy(self.teams[team.id] or team)
    self:forget_team(team.id)
    for cwd, bound in pairs(self.bound) do
      if bound.team == team.id or team.cwd == cwd then
        self.bound[cwd] = nil
      end
    end
    if self.watching and self.watching.team_id == team.id then
      -- The team is gone; there is nothing left to unwatch on the service.
      -- Release the subscription **silently**: `team_closed` below is the one
      -- UI event that settles routing. A generic `on_watch(nil)` would first
      -- restore whichever chat the panel showed before the worker (often not
      -- the team's leader) and clear the router target, so the close handler
      -- could no longer tell that a worker of this team was on screen.
      self:unwatch(true, true)
    end
    -- One event with the team id and its last known row (leader pair, cwd):
    -- the panel returns to that leader and decides about its panes.
    self:closed(team.id, entry)
  else
    self.teams[team.id] = team
    -- Keep the per-cwd snapshot in step with the notification stream so the
    -- tree does not wait for a full refresh.
    local cwd = team.cwd
    if type(cwd) == "string" then
      local rows = self.list_by_cwd[cwd] or {}
      local found = false
      for index, entry in ipairs(rows) do
        if entry.id == team.id then
          rows[index] = team
          found = true
          break
        end
      end
      if not found then
        rows[#rows + 1] = team
      end
      self.list_by_cwd[cwd] = rows
    end
    -- A team created after the cache was cleared (or a reconnect) gets its
    -- board when its revision differs from the cache.
    self:_fetch_board_if_needed(team)
  end
  self:changed()
end

---@param payload table
function Team:on_inbox_payload(payload)
  local item = type(payload) == "table" and (payload.item or payload) or nil
  if type(item) ~= "table" or type(item.id) ~= "string" then
    return
  end
  local fresh = self.inbox[item.id] == nil and item.state == "open"
  self.inbox[item.id] = item
  if fresh and self.notified[item.id] ~= item.team then
    self.notified[item.id] = item.team
    local message = string.format("team inbox: %s from %s", tostring(item.kind), tostring(item.from))
    self.notify(message, vim.log.levels.INFO)
  end
  if self.on_inbox then
    pcall(self.on_inbox, item)
  end
  self:changed()
end

---@param payload table
function Team:on_board_changed_payload(payload)
  local team_id = type(payload) == "table" and (payload.team or (payload.board and payload.board.id)) or nil
  if type(team_id) ~= "string" then
    return
  end
  if self.old_service or not self.teams[team_id] then
    -- An api-5 service has no board, and a late notification for a closed (or
    -- not yet listed) team must not recreate its cache entry.
    return
  end
  local entry = self.boards[team_id]
  if type(entry) == "table" and type(entry.board) == "table" then
    local rev = tonumber(payload.rev)
    if rev ~= nil and tonumber(entry.board.rev) == rev then
      -- Already at this revision (a duplicate notification).
      return
    end
  end
  -- A real notification is a fresh reason to fetch, even when an earlier
  -- revision failed.
  self.board_requested[team_id] = nil
  self:request_board(team_id)
end

---Every team, flattened for the panel.
---@return table[]
function Team:list_rows()
  local out = {}
  for _, team in pairs(self.teams) do
    out[#out + 1] = team
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---@param item_id string
---@return table|nil
function Team:item(item_id)
  return self.inbox[item_id]
end

---@param team_id string
---@return table|nil
function Team:team(team_id)
  return self.teams[team_id]
end

---@param team_id string
---@return table|nil
function Team:participant(team_id, name)
  local team = self.teams[team_id]
  for _, entry in ipairs(team and team.participants or {}) do
    if entry.name == name then
      return entry
    end
  end
end

---Methods that only exist at api_version 6 (19.5/19.7). An older service
---answers -32601 for them; that is a version problem, not a bug in the call.
local NEW_METHODS = {
  ["team.start"] = true,
  ["team.answer_group"] = true,
  ["team.board"] = true,
  ["team.card_history"] = true,
  ["team.workflows"] = true,
  ["team.workflow_delete"] = true,
  ["team.set_leader"] = true,
  ["team.stop_worker"] = true,
  ["session.teams"] = true,
}

---Explain that the running service predates boards/workflows, once.
function Team:_warn_old_service()
  if self.warned_old_service then
    return
  end
  self.warned_old_service = true
  self.notify(
    "the running service is too old for team boards and workflows; "
      .. "it restarts automatically when idle, or run :Ade service stop",
    vim.log.levels.WARN
  )
end

---@param method string
---@param params table
---@param cb fun(ok: boolean, value: any)|nil
function Team:_call(method, params, cb)
  cb = cb or function() end
  if not self:available() then
    cb(false, "teams are not available")
    return
  end
  local raw = self:_raw()
  raw:request_tracked(method, params, function(ok, value)
    if not ok and type(value) == "table" and value.code == -32601 and NEW_METHODS[method] then
      self.old_service = true
      self:_warn_old_service()
      value = {
        code = -32601,
        message = "the running service is too old for "
          .. method
          .. "; it restarts automatically when idle, or run :Ade service stop",
        data = { old_service = true, method = method },
      }
    end
    cb(ok, value)
  end)
end

---@param team string
---@param to string
---@param kind string
---@param body string
---@param extra table|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:send(team, to, kind, body, extra, cb)
  extra = extra or {}
  self:_call("team.send", {
    team = team,
    to = to,
    kind = kind,
    body = body,
    task = extra.task,
    refs = extra.refs,
    interrupt = extra.interrupt,
    cc = extra.cc,
    -- 19.3: the service prefixes the card's summary line and uses `card` as
    -- the task when `task` is absent.
    card = extra.card,
  }, cb)
end

---@param team string
---@param to string
---@param body string "pause"|"resume"|"cancel"
---@param cb fun(ok: boolean, value: any)|nil
function Team:control(team, to, body, cb)
  self:send(team, to, "control", body, nil, cb)
end

---@param item_id string
---@param fields table
---@param cb fun(ok: boolean, value: any)|nil
function Team:answer(item_id, fields, cb)
  local params = vim.tbl_extend("force", { request = item_id }, fields or {})
  self:_call("team.answer", params, cb)
end

---Start a worker on behalf of the person (18.13).
---@param team string
---@param template string
---@param name string|nil
---@param task string|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:spawn(team, template, name, task, cb)
  cb = cb or function() end
  self:_call("team.spawn", { team = team, template = template, name = name, task = task }, function(ok, value)
    if ok and type(value) == "table" and value.warning == "dirty_tree" then
      self.notify(
        "worker "
          .. tostring(value.name or name or template)
          .. " starts from the last commit; uncommitted changes are not in its worktree",
        vim.log.levels.WARN
      )
    end
    cb(ok, value)
  end)
end

---Start a worker from a session pair (PROTOCOL.md 20.4): the service calls
---`ensure_team` first and answers a structured `-32061` (`led_by`, `off`,
---`no_tools`) instead of creating a spawn inbox item.
---@param instance string
---@param session_id string
---@param template string
---@param name string|nil
---@param task string|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:spawn_pair(instance, session_id, template, name, task, cb)
  cb = cb or function() end
  self:_call(
    "team.spawn",
    { instance = instance, sessionId = session_id, template = template, name = name, task = task },
    function(ok, value)
      if ok then
        self:refresh()
      end
      cb(ok, value)
    end
  )
end

---Remove an exited worker's worktree (18.12).
---@param team string
---@param participant string
---@param force boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:remove_worktree(team, participant, force, cb)
  cb = cb or function() end
  local params = { team = team, participant = participant }
  if force then
    params.force = true
  end
  self:_call("team.remove_worktree", params, function(ok, value)
    if ok and type(value) == "table" and value.branch_kept then
      self.notify(
        "branch " .. tostring(value.branch or "?") .. " was kept (it is not merged into HEAD)",
        vim.log.levels.INFO
      )
    end
    cb(ok, value)
  end)
end

---@param team string
---@param participant string
---@param since integer|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:read(team, participant, since, cb)
  self:_call("team.read", { team = team, participant = participant, since = since }, cb)
end

---Remove a team from the local caches (a close reply, or `team.changed`
---closed). A board request still in flight must not recreate its entry.
---@param team_id string
function Team:forget_team(team_id)
  if type(team_id) ~= "string" then
    return
  end
  local entry = self.boards[team_id]
  if type(entry) == "table" then
    entry.seq = (entry.seq or 0) + 1
    entry.inflight = false
    entry.again = false
  end
  self.boards[team_id] = nil
  self.board_requested[team_id] = nil
  local known = self.teams[team_id]
  local cwd = type(known) == "table" and known.cwd or nil
  self.teams[team_id] = nil
  if cwd then
    local rows = self.list_by_cwd[cwd]
    if rows then
      local kept = {}
      for _, row in ipairs(rows) do
        if row.id ~= team_id then
          kept[#kept + 1] = row
        end
      end
      self.list_by_cwd[cwd] = #kept > 0 and kept or nil
    end
  end
  for id, item in pairs(self.inbox) do
    if item.team == team_id then
      self.inbox[id] = nil
      self.notified[id] = nil
    end
  end
  for bound_cwd, bound in pairs(self.bound) do
    if bound.team == team_id then
      self.bound[bound_cwd] = nil
    end
  end
  -- Clear the cached leadership too: a switch notification may arrive after
  -- `team.changed(closed)`, and a stale `leader` would ask to close it again.
  for _, state in pairs(self.session_states) do
    if type(state) == "table" and type(state.leader) == "table" and state.leader.id == team_id then
      state.leader = nil
    end
  end
end

---@param team string
---@param cb fun(ok: boolean, value: any)|nil
function Team:close(team, cb)
  self:_call("team.close", { team = team }, function(ok, value)
    if ok then
      -- The reply may arrive before `team.changed(closed)`; the local state
      -- must not keep a team that is already gone (19.7 "start over").
      local entry = vim.deepcopy(self.teams[team] or { id = team })
      self:forget_team(team)
      if self.watching and self.watching.team_id == team then
        -- Same single-event rule as `team.changed(closed)`: release the watch
        -- silently and let `team_closed` settle the routing.
        self:unwatch(true, true)
      end
      self:closed(team, entry)
      self:changed()
    end
    if cb then
      cb(ok, value)
    end
  end)
end

---@param team string
---@param cb fun(ok: boolean, value: any)|nil
function Team:reset_limits(team, cb)
  self:_call("team.reset_limits", { team = team }, cb)
end

---Start a named workflow on behalf of the person (19.7).
---@param team string
---@param workflow string
---@param task string|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:start(team, workflow, task, cb)
  self:_call("team.start", { team = team, workflow = workflow, task = task }, cb)
end

---Answer every open inbox item of a spawn group (19.6).
---
---A partially failed group is still a success: `value.failed` lists the items
---that stayed open, for the caller (the panel) to show.
---@param group string
---@param allow boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:answer_group(group, allow, cb)
  self:_call("team.answer_group", { group = group, allow = allow }, function(ok, value)
    if ok and type(value) == "table" then
      if type(value.failed) ~= "table" then
        value.failed = {}
      end
    end
    if cb then
      cb(ok, value)
    end
  end)
end

---Read a card's stored versions, newest first (19.4).
---@param team string
---@param card string
---@param cb fun(ok: boolean, value: any)|nil
function Team:card_history(team, card, cb)
  self:_call("team.card_history", { team = team, card = card }, cb)
end

---List every workflow visible from a cwd, resolved (19.5).
---@param cwd string
---@param cb fun(ok: boolean, value: any)|nil
function Team:workflows(cwd, cb)
  self:_call("team.workflows", { cwd = cwd }, function(ok, value)
    if ok and type(value) == "table" and type(value.workflows) == "table" then
      local names = {}
      for _, workflow in ipairs(value.workflows) do
        if type(workflow.name) == "string" then
          names[#names + 1] = workflow.name
        end
      end
      self.workflow_names = names
    end
    if cb then
      cb(ok, value)
    end
  end)
end

---Workflow names known without asking the service again (completion).
---@return string[]
function Team:known_workflows()
  local names, seen = {}, {}
  local function add(name)
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(self.workflow_names or {}) do
    add(name)
  end
  local cfg = self.config() or {}
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  for name in pairs(teams.workflows or {}) do
    add(name)
  end
  add("default")
  table.sort(names)
  return names
end

---Ask the service for the workflow list once (completion cache warm-up).
---@param cb fun()|nil
function Team:refresh_workflows(cb)
  cb = cb or function() end
  if not self:available() then
    cb()
    return
  end
  local cwd = self.resolve_cwd and self.resolve_cwd() or nil
  if not cwd then
    cb()
    return
  end
  self:workflows(cwd, function()
    cb()
  end)
end

---Delete a stored (project or user) workflow by name and scope (19.5).
---@param cwd string
---@param name string
---@param scope "project"|"user"
---@param cb fun(ok: boolean, value: any)|nil
function Team:workflow_delete(cwd, name, scope, cb)
  self:_call("team.workflow_delete", { cwd = cwd, name = name, scope = scope }, cb)
end

---@param payload table
---@return string
local function epoch_ms()
  if vim.uv and vim.uv.gettimeofday then
    local seconds, micros = vim.uv.gettimeofday()
    return seconds * 1000 + math.floor(micros / 1000)
  end
  return os.time() * 1000
end

local function prompt_text(payload)
  local parts = {}
  for _, block in ipairs(type(payload) == "table" and payload.prompt or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts, "\n")
end

---Mark a bus turn on a session and render it as user-side content.
---@param session table|nil
---@param payload table
---@return table|nil block the bus prompt block
function M.apply_turn_started(session, payload)
  if not session then
    return nil
  end
  local text = prompt_text(payload)
  local origin = type(payload) == "table" and payload.origin or "bus"
  session.status = "running"
  session.turn = (session.turn or 0) + 1
  session.bus_turn = session.turn
  return session:append({
    id = require("ade.session.state").next_id("bus"),
    kind = "user",
    text = "[" .. tostring(origin) .. "] " .. text,
    bus = { origin = origin },
  })
end

---@param session table|nil
---@return table|nil block the bus prompt block the turn ended on
function M.apply_turn_finished(session, payload)
  if not session or not session.bus_turn then
    return nil
  end
  local bus_turn = session.bus_turn
  session.bus_turn = nil
  local block
  for i = #session.blocks, 1, -1 do
    if session.blocks[i].bus then
      block = session.blocks[i]
      break
    end
  end
  -- A person's prompt may have replaced the bus turn while it was cancelling;
  -- its late finish must not end the user's (newer) turn.
  if session.turn == bus_turn then
    session:finish_turn(type(payload) == "table" and payload.stopReason or "end_turn")
  end
  return block
end

---The main (attached) session a notification is about.
---@param session_id string
---@return table|nil
function Team:session_of(session_id)
  local runtime = self.get_runtime and self.get_runtime() or nil
  if runtime and runtime.sessions then
    local session = runtime.sessions[session_id]
    if session then
      return session
    end
  end
  if self.watching and self.watching.session and self.watching.session.id == session_id then
    return self.watching.session
  end
end

---Handle `_ade/turn_started` (bus turn).
---@param payload table
function Team:turn_started(payload)
  payload = type(payload) == "table" and payload or {}
  local session = self:session_of(payload.sessionId or payload.session_id)
  if not session then
    return
  end
  if M.apply_turn_started(session, payload) then
    self:changed()
    self:_watch_rendered()
    if self.on_turn then
      pcall(self.on_turn, session)
    end
  end
end

---Handle `_ade/turn_finished` for a bus turn. Adoption keeps its own turns.
---@param payload table
function Team:turn_finished(payload)
  payload = type(payload) == "table" and payload or {}
  local session = self:session_of(payload.sessionId or payload.session_id)
  if session and session.bus_turn then
    -- Even without a bus block to attach the finish to, the turn still ended.
    M.apply_turn_finished(session, payload)
    self:changed()
    self:_watch_rendered()
    if self.on_turn then
      pcall(self.on_turn, session)
    end
  end
end

---Coalesce live watch frames: reducer.apply is cheap, rendering the whole
---transcript is not. At most one render is scheduled per window.
---@param entry table
function Team:_watch_schedule(entry)
  if self.watching ~= entry or entry.render_scheduled then
    return
  end
  entry.render_scheduled = true
  vim.defer_fn(function()
    entry.render_scheduled = false
    if self.watching == entry then
      local ok, err = pcall(self._watch_rendered, self)
      if not ok then
        log.error("watch render failed: %s", tostring(err))
      end
    end
  end, 50)
end

function Team:_watch_rendered()
  if self.watching and self.on_watch then
    pcall(self.on_watch, self.watching.session, self.watching.title)
  end
end

---Watch a worker's transcript (18.7). Replays through tunnel.recv frames.
---@param team string
---@param participant string
---@param replay boolean|nil
---@param cb fun(ok: boolean, value: any)|nil
function Team:watch(team, participant, replay, cb)
  cb = cb or function() end
  if not self:available() then
    cb(false, "teams are not available")
    return
  end
  -- A real unwatch for the previous worker while the connection is still up.
  self:unwatch(false)
  local raw = self:_raw()
  local session = State.new("watch:" .. tostring(participant), self.resolve_cwd())
  session.historical = true
  local channel = "team-watch-" .. tostring(vim.uv.hrtime())
  local entry = {
    channel = channel,
    session = session,
    title = team .. "/" .. participant,
    team_id = team,
    participant = participant,
    buffer = {},
    ready = false,
    -- Display-only turn timings, keyed by the bus prompt block id.
    turn_times = {},
  }
  self.watching = entry
  local function apply(payload, schedule)
    if type(payload) ~= "table" or not entry.ready then
      return
    end
    if entry.instance and payload.instance ~= entry.instance then
      return
    end
    local message = payload.message
    if type(message) ~= "table" then
      return
    end
    if message.method == "_ade/turn_started" then
      local block = M.apply_turn_started(session, message.params or {})
      if block then
        entry.turn_times[block.id] = { started_at = epoch_ms() }
      end
      if schedule ~= false then
        self:_watch_schedule(entry)
      end
      return
    end
    if message.method == "_ade/turn_finished" then
      local block = M.apply_turn_finished(session, message.params or {})
      if block then
        local timing = entry.turn_times[block.id] or {}
        timing.ended_at = epoch_ms()
        entry.turn_times[block.id] = timing
      end
      if schedule ~= false then
        self:_watch_schedule(entry)
      end
      return
    end
    if message.method == "session/update" and type(message.params) == "table" then
      if message.params.sessionId ~= session.id then
        return
      end
      if reducer.apply(session, message.params.update or {}) then
        if schedule ~= false then
          self:_watch_schedule(entry)
        end
      end
    end
  end
  raw:subscribe(channel, "tunnel.recv", function(payload)
    if self.watching ~= entry then
      return
    end
    -- Replay frames arrive before the response names the instance/session;
    -- buffer them so a leader's update cannot leak into the watch.
    if not entry.ready then
      entry.buffer[#entry.buffer + 1] = payload
      return
    end
    apply(payload, true)
  end)
  raw:request_tracked(
    "team.watch",
    { team = team, participant = participant, replay = replay == true },
    function(ok, value)
      if self.watching ~= entry then
        -- This watch was superseded/abandoned while its request was in flight.
        -- The switch/close that superseded it already released that watch; a
        -- late success must not send another unwatch that could cancel a newer
        -- watch of the same participant.
        cb(ok, value)
        return
      end
      if not ok then
        self:unwatch(true)
        cb(false, value)
        return
      end
      if type(value) == "table" then
        entry.instance = value.instance
        entry.replayed = value.replayed ~= false
        if type(value.sessionId) == "string" then
          session.id = value.sessionId
        end
      end
      entry.ready = true
      -- Replay is a batch: reduce every frame first, render the final session
      -- once. Rendering per frame is quadratic on a long transcript.
      local started = vim.uv.hrtime()
      local frames = #entry.buffer
      for _, payload in ipairs(entry.buffer) do
        local ok, err = pcall(apply, payload, false)
        if not ok then
          log.error("dropping a watch replay frame: %s", tostring(err))
        end
      end
      entry.buffer = {}
      local after_apply = vim.uv.hrtime()
      self:_watch_rendered()
      local after_render = vim.uv.hrtime()
      log.debug(
        "watch replay frames=%d apply_ms=%.1f render_ms=%.1f",
        frames,
        (after_apply - started) / 1e6,
        (after_render - after_apply) / 1e6
      )
      cb(true, value)
    end
  )
end

---@param quiet boolean|nil no team.unwatch request (connection already gone)
---@param silent boolean|nil do not fire `on_watch(nil)`; the caller owns routing.
function Team:unwatch(quiet, silent)
  local entry = self.watching
  if not entry then
    return
  end
  entry.render_scheduled = false
  self.watching = nil
  local raw = self:_raw()
  if raw and type(raw.unsubscribe) == "function" then
    pcall(raw.unsubscribe, raw, entry.channel, "tunnel.recv")
  end
  if not quiet and raw and entry.team_id and entry.participant then
    raw:request_tracked("team.unwatch", { team = entry.team_id, participant = entry.participant }, function() end)
  end
  if self.on_watch and not silent then
    pcall(self.on_watch, nil, nil)
  end
end

M.Team = Team

return M
