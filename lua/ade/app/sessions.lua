-- Session lifecycle: create, load, restore, delete and browse.
--
-- The runtime still owns the registry, replay staging and the outbox. This
-- module orchestrates the user-visible flow and reports activation through
-- callbacks, so it never touches the panel or the composer directly.
local presenter = require("ade.app.presenter")
local capabilities = require("ade.protocol.capabilities")
local log = require("ade.log")
local last_sessions = require("ade.storage.last_sessions")

local Sessions = {}
Sessions.__index = Sessions

---@param opts {config: fun(): table, runtime: fun(): table, catalog: table,
---  client: fun(): table|nil, connection: fun(): string,
---  generation: fun(): integer, new_local: fun(id: string, cwd: string, result: table): table,
---  resolve_cwd: fun(): string, run: fun(key: string, client: table|nil,
---  session: table|nil, fn: fun(task: table), on_error: fun(any)|nil,
---  on_finally: fun(task: table, owned: boolean)|nil): table,
---  cancel_session: fun(session: table, except: table|nil),
---  current: fun(): table|nil, activate: fun(session: table|nil), render: fun(),
---  dispatch_queued: fun(session: table), on_changed: fun(),
---  on_replaying: fun(value: boolean), on_creating: fun(value: boolean),
---  prune: fun(), auth: fun(): table|nil,
---  session_ready: fun(session: table)|nil,
---  session_forget: fun(session_id: string)|nil,
---  notify: fun(message: string, level: integer|nil)}
function Sessions.new(opts)
  return setmetatable({
    config = opts.config,
    get_runtime = opts.runtime,
    catalog = opts.catalog,
    get_client = opts.client,
    connection = opts.connection,
    generation = opts.generation,
    new_local = opts.new_local,
    resolve_cwd = opts.resolve_cwd,
    run = opts.run,
    cancel_session = opts.cancel_session,
    current = opts.current,
    activate = opts.activate,
    render = opts.render,
    dispatch_queued = opts.dispatch_queued,
    get_auth = opts.auth,
    on_session_ready = opts.session_ready,
    on_session_forget = opts.session_forget,
    on_changed = opts.on_changed,
    on_replaying = opts.on_replaying,
    on_creating = opts.on_creating,
    -- Teams (PROTOCOL.md 20.2): the service appends its session MCP server, so
    -- the front end only sends the configuration first and learns the new
    -- session's switch afterwards.
    before_session = opts.before_session,
    after_session = opts.after_session,
    prune = opts.prune,
    notify = opts.notify,
    creating = false,
    replaying = false,
  }, Sessions)
end

function Sessions:ready()
  return self.connection() == "ready" and self.get_client() ~= nil
end

---Make sure the cwd configuration reached the service before the session
---request (PROTOCOL.md 20.2). Nothing is injected into `mcpServers` here.
---@param client table
---@param cwd string
function Sessions:prepare_team(client, cwd)
  if self.before_session then
    self.before_session(cwd, client)
  end
end

---Learn the new session's `session.teams` switch after a successful request.
---@param client table
---@param cwd string
---@param session_id string
function Sessions:bind_team(client, cwd, session_id)
  local instance = client and client.proc and client.proc.instance or nil
  if not self.after_session then
    return instance
  end
  local runtime = self.get_runtime()
  local session = runtime and runtime.sessions and runtime.sessions[session_id] or nil
  if session and instance then
    session.instance = instance
  end
  self.after_session(cwd, session_id, instance)
  return instance
end

---Open a cached or released session the way `:Ade sessions` does.
---
---`<CR>` in the team tree must not merely set `current`: a released session has
---to be loaded/replayed first, exactly as the normal picker would.
---
---`opts.instance` / `opts.cwd` are the tree row's values: a row of another
---instance (or another cwd) is refused instead of being loaded through the
---current agent, where a same-named session could be a different conversation.
---@param session table|nil
---@param opts {instance: string|nil, cwd: string|nil,
---  on_failed: (fun(err: string)|nil)|nil}|nil
---@return boolean opened
function Sessions:open(session, opts)
  opts = opts or {}
  if not session then
    return false
  end
  local client = self.get_client()
  local live = client and client.proc and client.proc.instance or nil
  local own = session.instance
  if opts.instance and own and opts.instance ~= own then
    if opts.on_failed then
      pcall(opts.on_failed, "that session belongs to another service instance")
    end
    return false
  end
  local wanted = opts.instance or own
  if wanted and live and wanted ~= live then
    if opts.on_failed then
      pcall(opts.on_failed, "that session's service instance is not connected here")
    end
    return false
  end
  local row_cwd = opts.cwd or session.cwd
  if opts.cwd and session.cwd and opts.cwd ~= session.cwd then
    if opts.on_failed then
      pcall(opts.on_failed, "that session belongs to another project")
    end
    return false
  end
  local runtime = self.get_runtime()
  local cached = runtime and runtime.sessions and runtime.sessions[session.id] or nil
  if cached and not cached.needs_load and (cached.status ~= "idle" or #(cached.queue or {}) > 0) then
    runtime:intend()
    self.activate(cached)
    self.dispatch_queued(cached)
    return true
  end
  self:load(session.id, { kind = "load", cwd = row_cwd, on_failed = opts.on_failed })
  return true
end

---Request a new session from the agent.
---@param on_missing fun() invoked when there is no live connection
---@param opts {on_created: (fun(session: table)|nil)|nil, on_failed: (fun(err: string)|nil)|nil}|nil
function Sessions:create(on_missing, opts)
  opts = opts or {}
  local failed = false
  local function fail(message)
    if failed then
      return
    end
    failed = true
    if opts.on_failed then
      pcall(opts.on_failed, tostring(message))
    end
  end
  if not self:ready() then
    if on_missing then
      on_missing()
    end
    fail("no agent process is running")
    return
  end
  local cwd = self.resolve_cwd()
  -- Guard against overlapping creations (e.g. a double `new_session` from a
  -- fast toggle): the last response would otherwise win and orphan a session.
  if self.creating then
    fail("another session is already being created")
    return
  end
  self.creating = true
  self.creation_seq = (self.creation_seq or 0) + 1
  local creation = self.creation_seq
  self.on_creating(true)
  local runtime, client = self.get_runtime(), self.get_client()
  local intent = runtime:intend()
  local token = runtime:expect_create()
  self.run("create", client, nil, function(task)
    self:prepare_team(client, cwd)
    local ok, result = task:call("new_session", cwd)
    if not ok then
      task.status = "failed"
      runtime:drop_create(token)
      local auth = self.get_auth and self.get_auth()
      if
        auth
        and auth:require(result, {
          retry = function()
            -- The retry is the same request from the caller's point of view: keep
            -- its `on_created` / `on_failed` so a start flow still learns how the
            -- replacement session ended.
            self:create(on_missing, opts)
          end,
        })
      then
        return
      end
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      fail("unable to create a session: " .. message)
      self.notify("unable to create a session: " .. message, vim.log.levels.ERROR)
      return
    end
    if type(result) ~= "table" or type(result.sessionId) ~= "string" or result.sessionId == "" then
      runtime:drop_create(token)
      fail("invalid session/new response")
      error("invalid session/new response")
    end
    self:bind_team(client, cwd, result.sessionId)
    local instance = client and client.proc and client.proc.instance or nil
    local session, replayed = runtime:commit_create(token, result.sessionId, cwd, result)
    if not session then
      runtime:drop_create(token)
      session = self.new_local(result.sessionId, cwd, result)
      replayed = 0
    end
    if instance then
      session.instance = instance
    end
    self.catalog:cwds()[session.id] = cwd
    if replayed > 0 then
      self.on_changed()
    end
    if runtime.selection == intent then
      self.activate(session)
      self.render()
    end
    self.notify("Session started", vim.log.levels.INFO)
    self.catalog:refresh_title(session)
    if not failed and opts.on_created then
      pcall(opts.on_created, session)
    end
  end, function(err)
    runtime:drop_create(token)
    fail("unable to create a session: " .. tostring(err))
    self.notify("unable to create a session: " .. tostring(err), vim.log.levels.ERROR)
  end, function(_, owned)
    -- Even an abandoned creation must release the guard: a reconnect cancels
    -- the scoped task, and leaving `creating` set wedged every later
    -- `session/new` (for example after logging in).
    if self.creation_seq == creation then
      self.creating = false
      self.on_creating(false)
    end
    if not owned then
      runtime:drop_create(token)
      fail("the session creation was abandoned")
    end
  end)
end

---Resume `session_id` without replaying its history.
---
-- The callback distinguishes a missing conversation from a retryable error.
-- Never create a replacement after a newer selection already won.
function Sessions:cold_restore_failed(opts, runtime, intent, message, err)
  if runtime.selection == intent and opts.on_failed and opts.on_failed(message, err) then
    self:create()
  end
end

---The fallback when the agent supports `session/resume` but not `session/load`:
---the agent-side context comes back, the transcript does not. The user is told,
---because an empty transcript after "open session" otherwise looks like a bug.
---@param session_id string
---@param opts {kind: string|nil, on_failed: fun(err: string)|nil, on_restored: fun()|nil}|nil
function Sessions:resume(session_id, opts)
  opts = opts or {}
  local client = self.get_client()
  if not self:ready() or not client then
    self.notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  local runtime = self.get_runtime()
  local cwd = opts.cwd or self.catalog:session_cwd(session_id, self.resolve_cwd())
  local entry = runtime:stage(session_id, cwd)
  local intent = opts.intent or runtime:intend()
  opts.intent = intent
  -- Whether the caller was told how this attempt ended: a cancelled attempt
  -- still has to settle the flow waiting on it (`on_failed`), exactly once.
  local settled = false
  local function settle(ok, message)
    if settled then
      return
    end
    settled = true
    if ok then
      if opts.on_restored and (not opts.cold_restore or runtime.selection == intent) then
        pcall(opts.on_restored)
      end
    elseif opts.on_failed then
      pcall(opts.on_failed, tostring(message))
    end
  end
  -- Hold the same replay lock as `replay`: a second load while this request is
  -- in flight would stage a second projection for the same session id.
  self.replaying = true
  self.on_replaying(true)
  self.run("resume", client, entry, function(task)
    self:prepare_team(client, cwd)
    local ok, result = task:call("resume_session", session_id, cwd)
    if not ok then
      task.status = "failed"
      runtime:rollback(entry)
      local auth = self.get_auth and self.get_auth()
      if
        auth
        and auth:require(result, {
          retry = function()
            if not opts.cold_restore or runtime.selection == intent then
              self:resume(session_id, opts)
            end
          end,
        })
      then
        return
      end
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      if opts.cold_restore then
        self:cold_restore_failed(opts, runtime, intent, message, result)
        return
      end
      if opts.kind == "restore" and tostring(message):lower():match("shutdown") then
        -- Expected during teardown; do not alarm the user.
        self:create()
        return
      end
      self.notify(
        "unable to resume the session: " .. message,
        opts.kind == "restore" and vim.log.levels.WARN or vim.log.levels.ERROR
      )
      if opts.on_failed then
        pcall(opts.on_failed, message)
      end
      -- Restoring has no session to fall back on: the old one is already gone.
      if opts.kind == "restore" then
        self:create()
      end
      return
    end
    if type(result) ~= "table" then
      error("invalid session/resume response")
    end
    self:bind_team(client, cwd, session_id)
    entry.instance = (client and client.proc and client.proc.instance) or entry.instance
    entry:configure(result)
    entry.needs_load = false
    if not runtime:commit(entry) then
      return
    end
    if self.catalog:apply_title(entry) then
      self.on_changed()
    end
    if runtime.selection == intent then
      self.activate(entry)
      self.render()
    end
    self.prune()
    self.on_changed()
    self.notify("Session resumed (history is not replayed)")
    self.catalog:refresh_title(entry)
    settle(true)
  end, function(err)
    runtime:rollback(entry)
    if opts.cold_restore then
      settled = true
      self:cold_restore_failed(opts, runtime, intent, tostring(err), err)
      return
    end
    self.notify("unable to resume the session: " .. tostring(err), vim.log.levels.ERROR)
    settle(false, err)
  end, function(_, owned)
    if not owned then
      -- A reconnect cancelled the attempt: the caller must not wait forever.
      settle(false, "the resume was cancelled")
      return
    end
    runtime:rollback(entry)
    self.replaying = false
    self.on_replaying(false)
    if runtime.sessions[entry.id] == entry then
      self.dispatch_queued(entry)
    end
  end)
end

---Load `session_id`, replaying the agent's history into the transcript.
---
---Used both when switching sessions and when restoring the current one after a
---reconnect.
---@param session_id string
---@param opts {kind: string|nil, intent: integer|nil}
function Sessions:replay(session_id, opts)
  local runtime = self.get_runtime()
  local cwd = opts.cwd or self.catalog:session_cwd(session_id, self.resolve_cwd())
  local entry = runtime:stage(session_id, cwd)
  local intent = opts.intent or runtime:intend()
  opts.intent = intent
  local client = self.get_client()
  local settled = false
  local function settle(ok, message)
    if settled then
      return
    end
    settled = true
    if ok then
      if opts.on_restored and (not opts.cold_restore or runtime.selection == intent) then
        pcall(opts.on_restored)
      end
    elseif opts.on_failed then
      pcall(opts.on_failed, tostring(message))
    end
  end
  -- Identifies this attempt so a cancelled/superseded replay's cleanup does not
  -- clear the flag of a newer one.
  self.replay_seq = (self.replay_seq or 0) + 1
  local replay_seq = self.replay_seq
  self.replaying = true
  self.on_replaying(true)
  self.run("replay", client, entry, function(task)
    self:prepare_team(client, cwd)
    local ok, result = task:call("load_session", session_id, cwd)
    if not ok then
      task.status = "failed"
      -- No rollback here: `on_finally` always runs and is the single cleanup
      -- point, including when the auth retry returns early.
      local auth = self.get_auth and self.get_auth()
      if
        auth
        and auth:require(result, {
          retry = function()
            if not opts.cold_restore or runtime.selection == intent then
              self:replay(session_id, opts)
            end
          end,
        })
      then
        return
      end
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      if opts.cold_restore then
        self:cold_restore_failed(opts, runtime, intent, message, result)
        return
      end
      if opts.kind == "restore" and tostring(message):lower():match("shutdown") then
        -- Expected during teardown; do not alarm the user.
        self:create()
        return
      end
      self.notify(
        "unable to " .. (opts.kind or "load") .. " the session: " .. message,
        opts.kind == "restore" and vim.log.levels.WARN or vim.log.levels.ERROR
      )
      if opts.on_failed then
        pcall(opts.on_failed, message)
      end
      if opts.kind == "restore" then
        self:create()
      end
      return
    end

    if type(result) ~= "table" then
      error("invalid session/load response")
    end
    self:bind_team(client, cwd, session_id)
    entry.instance = (client and client.proc and client.proc.instance) or entry.instance
    entry:configure(result)
    entry:finish_turn("end_turn")
    if not runtime:commit(entry) then
      return
    end
    -- PROTOCOL.md 13: the service sends `_ade/turn_adopted` right after this
    -- load reply, so the notification can arrive before the replay is committed
    -- and the session is visible. `Adoption` keeps it pending; hand it the
    -- committed session now so the adopted turn shows as running.
    if self.on_session_ready then
      local applied, apply_err = pcall(self.on_session_ready, entry)
      if not applied then
        -- Do not leave the deferred adoption behind: a later load of this id
        -- would apply it to the wrong session. The commit already replaced the
        -- object, so `forget_pending` only drops the pending entry.
        log.error("applying the deferred turn adoption to %s failed: %s", entry.id, tostring(apply_err))
        if self.on_session_forget then
          pcall(self.on_session_forget, entry.id)
        end
      end
    end
    if self.catalog:apply_title(entry) then
      self.on_changed()
    end
    if runtime.selection == intent then
      self.activate(entry)
      self.render()
    end
    self.prune()
    self.on_changed()
    self.catalog:refresh_title(entry)
    settle(true)
  end, function(err)
    -- `on_finally` owns the rollback and the pending cleanup for every ending.
    if opts.cold_restore then
      settled = true
      self:cold_restore_failed(opts, runtime, intent, tostring(err), err)
      return
    end
    self.notify("unable to load the session: " .. tostring(err), vim.log.levels.ERROR)
    settle(false, err)
  end, function(_, owned)
    -- Cleanup is per id: a newer attempt for the same id owns the bookkeeping;
    -- one for a different id must not keep this id's staging record alive.
    local newer_same_id = runtime.replays[entry.id]
    if not newer_same_id or newer_same_id.session == entry then
      if self.on_session_forget then
        pcall(self.on_session_forget, entry.id)
      end
      runtime:rollback(entry)
    end
    -- The `replaying` flag is global: only the newest attempt may clear it.
    if self.replay_seq == replay_seq then
      self.replaying = false
      self.on_replaying(false)
    end
    if not owned then
      -- A reconnect/supersession cancelled the attempt: settle the caller so a
      -- start flow waiting on the reload does not hang.
      settle(false, "the load was cancelled")
      return
    end
    if runtime.sessions[entry.id] == entry then
      self.dispatch_queued(entry)
    end
  end)
end

---Restore the current session after a reconnect.
---@param session_id string
function Sessions:restore(session_id)
  local client = self.get_client()
  if not self:ready() then
    return
  end
  if self.replaying then
    return
  end
  if not capabilities.supports(capabilities.agent(client), "loadSession") then
    if capabilities.supports(capabilities.agent(client), "sessionCapabilities.resume") then
      self:resume(session_id, { kind = "restore" })
      return
    end
    self:create()
    return
  end
  -- Start from a clean transcript: the agent replays its authoritative history.
  self:replay(session_id, { kind = "restore" })
end

---Load a previous session, replaying its history.
---
---`opts.on_failed` / `opts.on_restored` let the caller report the outcome of an
---automatic restore: the user must be able to tell "reopened your conversation"
---from "started a new one because X".
---@param session_id string
---@param opts {kind: string|nil, reload: boolean|nil, client: table|nil, cwd: string|nil,
---  on_failed: fun(err: string)|nil, on_restored: fun()|nil}|nil
function Sessions:load(session_id, opts)
  opts = opts or {}
  local function failed(message)
    if opts.on_failed then
      pcall(opts.on_failed, message)
    end
  end
  if not self:ready() then
    self.notify("No agent process is running", vim.log.levels.WARN)
    failed("no agent process is running")
    return
  end
  if opts.client and opts.client ~= self.get_client() then
    -- The reload belonged to the connection that answered `session.teams`; on a
    -- new connection the marked load would be sent to a different instance.
    failed("the service connection changed before the reload")
    return
  end
  local runtime = self.get_runtime()
  local cached = runtime.sessions[session_id]
  -- A team reload must really reach the agent: the service marks one forwarded
  -- load and injects the tools on it, so a cached, idle session cannot just be
  -- re-activated here (PROTOCOL.md 20.5).
  local forced = opts.reload == true or opts.kind == "reload"
  if forced and cached and (cached.status ~= "idle" or #cached.queue > 0) then
    -- Reloading flushes the transcript; doing that under a running turn would
    -- replace what the agent is still writing.
    self.notify("Finish or cancel the turn before reloading this session's team tools", vim.log.levels.WARN)
    failed("a turn is still running")
    return
  end
  if not forced and cached and not cached.needs_load and (cached.status ~= "idle" or #cached.queue > 0) then
    runtime:intend()
    self.activate(cached)
    self.dispatch_queued(cached)
    if opts.on_restored then
      pcall(opts.on_restored)
    end
    return
  end
  if self.replaying then
    self.notify("Wait for the session to finish before loading its history", vim.log.levels.WARN)
    failed("another replay is in progress")
    return
  end
  local client = self.get_client()
  if not capabilities.supports(capabilities.agent(client), "loadSession") then
    -- Resuming restores the agent-side context without replaying history; it is
    -- the closest this agent can get to "open that session".
    if capabilities.supports(capabilities.agent(client), "sessionCapabilities.resume") then
      self:resume(session_id, opts)
      return
    end
    self.notify("This agent cannot load sessions; starting a new one", vim.log.levels.WARN)
    failed("the agent cannot load sessions")
    self:create()
    return
  end
  -- Agents reject session/load when the cwd does not match the session.
  -- Loading replays authoritative history, even for a cached session; appending
  -- to the cached object would duplicate every message on subsequent visits.
  opts.kind = opts.kind or "load"
  self:replay(session_id, opts)
end

---Whether the client can be asked to close a session.
---
---Both the advertised capability and the local method are required: a test
---double may advertise through the predicate without implementing the call.
---@param client table|nil
---@return boolean
local function can_close(client)
  return client ~= nil
    and type(client.close_session) == "function"
    and capabilities.supports(capabilities.agent(client), "sessionCapabilities.close")
end

---Ask the agent to release a session it no longer needs to keep active.
---
---Best effort: `session/close` only exists on agents that advertise it, and a
---failure must not block switching, deleting or quitting.
---@param session_id string|nil
function Sessions:close(session_id)
  if not session_id then
    return
  end
  local client = self.get_client()
  if not can_close(client) then
    return
  end
  local runtime = self.get_runtime()
  local session = runtime.sessions[session_id]
  self.run("close:" .. session_id, client, session, function(task)
    task:call("close_session", session_id)
  end)
end

---Whether leaving the editor will detach instead of stopping the agent.
---
---The transport owns this decision (`Channel:will_detach`, which folds in
---`keep_alive`, a successful `initialize` and "nothing went wrong"); asking it
---rather than re-deriving the rule here keeps the exit path and the actual
---detach/stop in step.
---@param client table|nil
---@return boolean
local function will_detach_on_exit(client)
  if not client then
    return false
  end
  if type(client.will_detach) ~= "function" then
    -- The direct backend has no `leave`: its agent is a child process that dies
    -- with the editor, so nothing can be reopened anyway.
    return false
  end
  local ok, value = pcall(client.will_detach, client)
  return ok and value == true
end

---Close every active session synchronously, for editor exit.
---
---The process is killed right after this runs, so the request has to complete
---on this turn of the event loop; a fire-and-forget coroutine would leave the
---notification unsent.
---
---A detachable exit sends nothing. The service treats a successful
---`session/close` as "forget this session" (PROTOCOL.md 11): after it, the
---sessions are missing from `agent.attach` and the event log can never be
---replayed for them, so closing here would defeat the whole point of keeping
---the agent alive. The agent is going to outlive the editor, and the next one
---must be able to reopen the conversation.
function Sessions:close_all_on_exit()
  local client = self.get_client()
  if not can_close(client) then
    return
  end
  if will_detach_on_exit(client) then
    return
  end
  local runtime = self.get_runtime()
  local async = require("ade.async")
  for id in pairs(runtime.sessions) do
    local done = false
    local co = async.run(function()
      client:close_session(id)
      done = true
    end)
    vim.wait(200, function()
      return done
    end, 10)
    if not done then
      pcall(async.cancel, co)
    end
  end
end

---Delete a session through the agent and drop it from local state.
---@param session_id string
---@param done fun(ok: boolean)
function Sessions:delete(session_id, done)
  local client = self.get_client()
  if not client then
    done(false)
    return
  end
  local runtime = self.get_runtime()
  local agent = self.config().agent
  local settled = false
  local function finish(ok)
    if settled then
      return
    end
    settled = true
    done(ok)
  end
  local session = runtime.sessions[session_id]
  self.run("delete:" .. session_id, client, session, function(task)
    -- Release agent-side resources first. Not every agent has `session/close`,
    -- and a failed close must not prevent the delete.
    if can_close(client) then
      task:call("close_session", session_id)
    end
    local ok, result = task:call("delete_session", session_id)
    if not ok then
      task.status = "failed"
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      self.notify(string.format("Unable to delete the session: %s", message), vim.log.levels.ERROR)
      finish(false)
      return
    end
    runtime:remove(session_id)
    self.cancel_session(session or { id = session_id }, task)
    self.catalog:forget(session_id)
    if agent then
      last_sessions.forget_session(agent, session_id)
    end
    local current = self.current()
    if current and current.id == session_id then
      -- The active conversation is gone; start a fresh one.
      self.activate(nil)
      self.render()
      self:create()
    else
      self.on_changed()
    end
    self.notify("Session deleted", vim.log.levels.INFO)
    finish(true)
  end, function(err)
    self.notify("Unable to delete the session: " .. tostring(err), vim.log.levels.ERROR)
    finish(false)
  end, function()
    finish(false) -- cancelled picker operations also have a terminal outcome
  end)
end

---Browse stored sessions. <CR> opens, <C-d> deletes, typing filters.
function Sessions:pick()
  if not self:ready() then
    self.notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  local client, generation = self.get_client(), self.generation()
  local function ui_current()
    return self.get_client() == client and self.generation() == generation
  end
  self.catalog:list(self.resolve_cwd(), function(ok, sessions)
    if not ok then
      return
    end
    if #sessions == 0 then
      self.notify("No stored sessions found", vim.log.levels.INFO)
      return
    end
    local active = self.current()
    local picker_opts = {
      sessions = sessions,
      current_id = active and active.id or nil,
      can_delete = capabilities.supports(capabilities.agent(client), "sessionCapabilities.delete"),
      use_icons = self.config().ui.icons,
      on_open = function(session_id)
        if ui_current() then
          self:load(session_id)
        end
      end,
      on_delete = function(session_id, done)
        if ui_current() then
          self:delete(session_id, done)
        else
          done(false)
        end
      end,
    }

    -- snacks is the default when it is installed; the presenter falls back to
    -- the built-in window instead of failing.
    presenter.open_session_browser(picker_opts, self.config().ui.session_picker)
  end)
end

---Remember a replay failure/teardown in one place for diagnostics.
---@return boolean
function Sessions:is_replaying()
  return self.replaying
end

return Sessions
