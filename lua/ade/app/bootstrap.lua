-- Service construction for `controller.setup`.
--
-- This used to be a 500-line function inside the controller. It is not logic —
-- every branch is "build this service, give it these callbacks" — so it lives
-- here and receives the controller's helpers through `ctx`. Keeping it in a
-- separate module is what lets the controller itself stay small.
local config_mod = require("ade.config")
local log = require("ade.log")
local work = require("ade.ui.work_scheduler")
local highlights = require("ade.ui.highlights")
local layout = require("ade.layout")
local drafts = require("ade.storage.drafts")
local Runtime = require("ade.session.runtime")
local Catalog = require("ade.app.catalog")
local Permissions = require("ade.app.permissions")
local Elicitation = require("ade.app.elicitation")
local Choices = require("ade.app.choices")
local Interactions = require("ade.app.interactions")
local Options = require("ade.app.options")
local Chrome = require("ade.ui.chrome")
local Resolve = require("ade.manager.resolve")
local Lock = require("ade.manager.lock")
local AgentManager = require("ade.app.agent_manager")
local AgentManagerUI = require("ade.ui.agent_manager")
local Sessions = require("ade.app.sessions")
local Prompts = require("ade.app.prompts")
local PermissionPolicy = require("ade.service.policy")
local Team = require("ade.app.team")
local TeamUI = require("ade.ui.team")
local TeamCommands = require("ade.app.team_commands")
local Auth = require("ade.app.auth")
local Connection = require("ade.app.connection")
local Panel = require("ade.ui.panel")
local Chat = require("ade.ui.chat")
local Input = require("ade.ui.input")
local Status = require("ade.app.status")
local Attachments = require("ade.app.attachments")
local Events = require("ade.app.events")
local Adoption = require("ade.app.adoption")
local Restore = require("ade.app.restore")
local Reconnector = require("ade.app.reconnector")
local ConnectionFlow = require("ade.app.connection_flow")
local SessionManager = require("ade.app.session_manager")

local M = {}

---Whether a one-shot session manager load still describes this connection.
---
---The intent names the agent and the directory it was written for. A
---reconfiguration clears it explicitly, but the editor's cwd can also change
---between `setup` and the ready callback; loading through a connection that is
---not in that folder would target the wrong agent process.
---@param pending any
---@param client table|nil
---@param agent string|nil
---@return boolean
local function pending_load_applies(pending, client, agent)
  if type(pending) ~= "table" or type(pending.id) ~= "string" then
    return false
  end
  if agent ~= pending.agent then
    return false
  end
  local cwd = client and client.cwd
  if type(cwd) ~= "string" or type(pending.cwd) ~= "string" then
    return false
  end
  return vim.fs.normalize(cwd) == vim.fs.normalize(pending.cwd)
end

---Reconfigure everything: state, services, views and keymaps.
---
---@param ctx table controller helpers and entry points
---@param opts table|nil user configuration
---@param action {discard_queued?: boolean}|nil
function M.build(ctx, opts, action)
  local S = ctx.state
  local cfg = ctx.cfg
  local notify = ctx.notify

  -- A session manager switch carries its one-shot load in the setup action.
  -- Clear the previous intent first: every reconfiguration that does not name
  -- one (an agent switch, a plain setup, a second manager action) or that fails
  -- before it is built must leave nothing behind for a later connection.
  S.conn.pending_load = nil

  -- Provenance comes from the raw input, before `merge` erases which fields the
  -- user actually wrote. Without it a preset command is indistinguishable from
  -- an override.
  -- A reconfiguration from an already merged config (agent switch) carries the
  -- provenance computed from the original input; recomputing it from the merged
  -- table would mark every preset command as a user override.
  local launch_origin = type(opts) == "table" and type(opts.launch_origin) == "table" and opts.launch_origin
    or Resolve.provenance(opts)
  local merged = config_mod.merge(config_mod.defaults, opts or {})
  merged.launch_origin = launch_origin
  local ok, err = pcall(config_mod.validate, merged)
  if not ok then
    error(err, 0)
  end
  config_mod.remember(merged)
  if not (action and action.discard_queued == true) then
    for _, session in pairs(S.sess.all) do
      if #session.queue > 0 or (session.outbox and session.outbox.reserved) then
        error(
          "ade.nvim: cannot reconfigure with queued messages; drain them first or explicitly pass { discard_queued = true } as the second setup argument",
          0
        )
      end
    end
  end
  if S.view.input then
    pcall(S.view.input.save_draft, S.view.input)
  end
  -- Validation and the queue guard passed: this build really happens, so the
  -- action's intent (if any) describes the connection it will start.
  S.conn.pending_load = type(action) == "table" and action.pending_load or nil
  ctx.invalidate_operations()
  S.config = merged

  S.conn.flow = ConnectionFlow.new({
    state = function()
      return S
    end,
    config = cfg,
    notify = notify,
    connect = ctx.connect,
    disconnect = ctx.disconnect,
    cwd = ctx.resolve_cwd,
    open = ctx.open,
    hide = ctx.hide,
    dispatch = ctx.dispatch_queued,
    setup = ctx.setup or function(next_opts, next_action)
      return M.build(ctx, next_opts, next_action)
    end,
  })

  S.view.status = Status.new({
    state = function()
      return S
    end,
    config = cfg,
    chrome = function()
      return S.view.chrome
    end,
  })

  log.setup(merged.log)
  -- After `log.setup` (which only creates the log *directory*) and before
  -- anything writes a line or reads drafts/installs: the log file itself is one
  -- of the migrated paths, and creating it first would turn the move into a
  -- conflict. `run` only logs once every path has been moved.
  require("ade.migrate").run()
  work.configure(merged.ui.render.budget_ms)
  highlights.setup(merged.ui.highlights)
  layout.setup(merged)

  -- Reconfiguring means a different agent, cwd or UI: drop the old runtime
  -- state instead of mixing sessions from two configurations.
  ctx.stop_spinner()
  if S.view.chrome then
    S.view.chrome:destroy()
  end

  -- Release the previous panel: windows belong to the previous Chat/Input
  -- objects, which are replaced below. Leaving them open would strand windows
  -- that nothing tracks.
  if S.view.panel then
    S.view.panel:set_views(S.view.chat, S.view.input)
    S.view.panel:destroy()
  end

  -- Reconfiguring replaces the connection and its lock: release the managed
  -- launch lease and stop the old heartbeat, or `:Ade uninstall` keeps
  -- reporting the replaced release as in use by this pid for the rest of the
  -- session.
  if S.conn.service then
    pcall(S.conn.service.terminate, S.conn.service)
  end
  if S.conn.locks then
    pcall(S.conn.locks.close, S.conn.locks)
  end

  if S.conn.client then
    -- Reconfiguring switches agent (or wiring): the old agent may keep running
    -- under the service backend, so leave rather than kill it.
    pcall(S.conn.client.leave, S.conn.client, true)
    S.conn.client = nil
  end
  S.sess.current = nil
  S.conn.skip_auto_restore = nil
  S.sess.all = {}
  S.sess.runtime = Runtime.new(
    merged.memory,
    S.sess.all,
    merged.ui.thoughts,
    require("ade.agents").get(merged.agents[merged.agent], merged.agent)
  )
  S.sess.titles, S.sess.cwds = {}, {}
  -- Titles and cwds are cached per agent: switching agents must not show one
  -- agent's session titles for another's sessions, and switching back restores
  -- what was already learned.
  S.sess.agent_store = S.sess.agent_store or {}
  local store = S.sess.agent_store[merged.agent]
  if not store then
    store = { titles = {}, cwds = {} }
    S.sess.agent_store[merged.agent] = store
  end
  S.sess.titles, S.sess.cwds = store.titles, store.cwds
  S.sess.catalog = Catalog.new({
    titles = function()
      return S.sess.titles
    end,
    cwds = function()
      return S.sess.cwds
    end,
    client = function()
      return S.conn.client
    end,
    connection = function()
      return S.conn.phase
    end,
    run = function(key, client, session, fn, on_error, on_finally)
      return ctx.Operations:run(key, client, session, fn, on_error, on_finally)
    end,
    on_changed = ctx.refresh_chrome,
    notify = notify,
  })
  S.view.permissions = Permissions.new({
    config = cfg,
    valid = function(interaction)
      return interaction ~= nil
        and interaction.state == "pending"
        and ctx.ui_current(S.conn.client, ctx.Operations.generation)
    end,
    answer = function(interaction, option_id)
      ctx.resolve_permission(interaction.id, option_id, false)
    end,
    dismiss = function(interaction)
      ctx.resolve_permission(interaction.id, nil, true)
    end,
    notify = notify,
    session = function()
      return S.sess.current
    end,
    replacing = function()
      return (S.view.choices ~= nil and S.view.choices.replacing == true)
        or (S.view.panel ~= nil and S.view.panel.showing == true)
    end,
    focus_ok = function()
      local win = vim.api.nvim_get_current_win()
      if not win or not vim.api.nvim_win_is_valid(win) then
        return false
      end
      local buf = vim.api.nvim_win_get_buf(win)
      local ft = vim.bo[buf].filetype
      return ft == "ade_chat"
        or ft == "ade_input"
        or vim.b[buf].ade_picker == true
        or (S.view.input ~= nil and S.view.input.win == win)
        or (S.view.chat ~= nil and S.view.chat.win == win)
    end,
  })
  S.view.elicitation = Elicitation.new({
    answer = function(interaction, response)
      S.view.interactions:answer(interaction.id, response)
    end,
    notify = notify,
    focus_ok = function()
      local win = vim.api.nvim_get_current_win()
      if not win or not vim.api.nvim_win_is_valid(win) then
        return false
      end
      local buf = vim.api.nvim_win_get_buf(win)
      local ft = vim.bo[buf].filetype
      return ft == "ade_chat" or ft == "ade_input" or vim.b[buf].ade_picker == true
    end,
  })
  -- The choice card floats over the bottom of the chat window; the queue also
  -- owns team questions/spawn/permission/limit items (draft 8).
  S.view.choices = Choices.new({
    team = function()
      return S.view.team
    end,
    interactions = function()
      return S.view.interactions
    end,
    config = function()
      return S.config or merged
    end,
    notify = notify,
    find_session = function(id)
      return S.sess.all and S.sess.all[id] or nil
    end,
    select_session = function(session)
      if S.sess.service then
        S.sess.service:open(session, {
          on_failed = function(message)
            notify("cannot open that session: " .. tostring(message), vim.log.levels.WARN)
          end,
        })
      end
    end,
    input_win = function()
      return S.view.input and S.view.input.win or nil
    end,
    chat_win = function()
      return S.view.chat and S.view.chat.win or nil
    end,
    reserve = function(rows)
      if S.view.chat then
        S.view.chat:set_bottom_reserve(rows)
      end
    end,
    focus_hint = function()
      local keys = require("ade.ui.keymaps").expand(((S.config or merged).keymaps.chat or {}).focus_choice, { "n" })
      return keys[1] and keys[1].lhs or nil
    end,
    panel_visible = function()
      return (S.view.panel ~= nil and S.view.panel:is_visible()) or (S.view.team_ui ~= nil and S.view.team_ui:is_open())
    end,
    open = function()
      ctx.open()
    end,
    permission_present = function(interaction)
      if not S.view.permissions.valid(interaction) then
        return false
      end
      return S.view.permissions:present(interaction)
    end,
    permission_dismiss = function()
      S.view.permissions:dismiss_presented()
    end,
    elicitation_dismiss = function()
      S.view.elicitation:dismiss()
    end,
    permission_details = function(interaction)
      local request = interaction.request or {}
      local tool = request.toolCall or request.tool_call or {}
      require("ade.app.presenter").details.open(request, {
        title = tool.title or "Permission required",
        cwd = tool.locations and tool.locations[1] and tool.locations[1].path or nil,
      })
    end,
    elicitation_present = function(interaction)
      return S.view.elicitation:present(interaction)
    end,
  })
  local choice_group = vim.api.nvim_create_augroup("AdeChoices", { clear = true })
  vim.api.nvim_create_autocmd({ "InsertLeave", "CursorHold", "WinClosed", "WinNew", "BufWinEnter", "TabEnter" }, {
    group = choice_group,
    callback = function()
      vim.schedule(function()
        if S.view.choices then
          S.view.choices:refresh()
        end
      end)
    end,
  })
  -- The service-side rule sets (PROTOCOL.md 17). Created before the policy
  -- chain because the chain asks it whether Lua may answer at all; it resolves
  -- the connection lazily, so the order of construction does not matter.
  S.conn.policy = PermissionPolicy.new({
    config = function()
      return S.config or merged
    end,
    connection = function()
      return S.conn.service
    end,
    has_agent = function()
      return S.conn.client ~= nil
    end,
    notify = notify,
    on_applied = function(payload)
      if not payload or type(payload.sessionId) ~= "string" then
        return
      end
      -- The same shape the replay uses, so live and restored turns render
      -- through one reducer branch (PROTOCOL.md 17.4).
      local update = {
        sessionUpdate = "_ade_policy",
        set = payload.set,
        outcome = payload.outcome,
        optionId = payload.optionId,
        kind = payload.kind,
        toolCall = payload.toolCall,
      }
      local session, changed = S.sess.runtime:apply(payload.sessionId, update)
      if session and changed and session == S.sess.current and S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
  })
  S.view.interactions = Interactions.new({
    on_open = function(interaction)
      local session = interaction.session_id and S.sess.all[interaction.session_id] or nil
      local block = session and interaction.tool_call_id and session.tools[interaction.tool_call_id] or nil
      if not block then
        return
      end
      block.awaiting = interaction.type == "elicitation" and "answer" or "approval"
      block.interaction_id = interaction.id
      session:touch(block, false)
      if session == S.sess.current and S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
    on_settle = function(interaction)
      local session = interaction.session_id and S.sess.all[interaction.session_id] or nil
      local block = session and interaction.tool_call_id and session.tools[interaction.tool_call_id] or nil
      if not block then
        return
      end
      block.awaiting, block.interaction_id = nil, nil
      session:touch(block, false)
      if session == S.sess.current and S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
    policies = {
      -- When the service provides `policy`, it answers these itself; the Lua
      -- policies must stay out of the way, including the inline turn policy,
      -- unless installing that turn's set failed (then the Lua policy is the
      -- fallback).
      function(interaction)
        if S.conn.policy and S.conn.policy:active() and require("ade.inline").service_owned(interaction) then
          return nil
        end
        return require("ade.inline").policy(interaction)
      end,
      function(interaction)
        if S.conn.policy and S.conn.policy:active() then
          return nil
        end
        return S.view.permissions:auto(interaction)
      end,
    },
    presenters = {
      permission = {
        present = function(interaction)
          if not S.view.permissions.valid(interaction) then
            return false
          end
          return S.view.choices:present_interaction(interaction)
        end,
        dismiss = function()
          S.view.choices:dismiss()
        end,
      },
      elicitation = {
        present = function(interaction)
          return S.view.choices:present_interaction(interaction)
        end,
        dismiss = function()
          S.view.choices:dismiss()
        end,
      },
    },
    on_changed = function()
      if S.view.choices then
        S.view.choices:refresh()
      end
      ctx.refresh_chrome()
    end,
    notify = notify,
  })

  S.view.options = Options.new({
    config = cfg,
    current = ctx.current,
    client = function()
      return S.conn.client
    end,
    generation = function()
      return ctx.Operations.generation
    end,
    ui_current = ctx.ui_current,
    run = function(key, client, session, fn, on_error, on_finally)
      return ctx.Operations:run(key, client, session, fn, on_error, on_finally)
    end,
    on_changed = ctx.refresh_chrome,
    notify = notify,
  })
  S.view.chrome = Chrome.new({
    config = cfg,
    current = ctx.current,
    session_label = ctx.session_label,
    waiting = ctx.waiting_permission,
    team_target = function()
      return S.view.team_ui and S.view.team_ui.chat_target and S.view.team_ui:chat_target() or nil
    end,
    chat = function()
      return S.view.chat
    end,
    input = function()
      return S.view.input
    end,
  })
  -- Teams (PROTOCOL.md 20). Created before sessions because the cwd
  -- configuration must reach the service before its session requests.
  S.view.team = Team.new({
    config = function()
      return S.config or merged
    end,
    connection = function()
      return S.conn.service
    end,
    resolve_cwd = ctx.resolve_cwd,
    store = function()
      return S.conn.store
    end,
    notify = notify,
    on_changed = function()
      if S.view.team_ui then
        S.view.team_ui:schedule_refresh()
      end
      if S.view.choices then
        S.view.choices:refresh()
      end
      ctx.refresh_chrome()
    end,
    on_watch = function(session, title)
      -- Called from the socket dispatch (fast event context); window APIs are
      -- only legal on the main loop.
      vim.schedule(function()
        if S.view.team_ui then
          S.view.team_ui:watch(session, title)
        end
      end)
    end,
    on_closed = function(team_id, entry)
      vim.schedule(function()
        if S.view.team_ui then
          pcall(S.view.team_ui.team_closed, S.view.team_ui, team_id, entry)
        end
        if S.view.choices then
          S.view.choices:refresh()
        end
      end)
    end,
    runtime = function()
      return S.sess.runtime
    end,
    current = function()
      return S.sess.current
    end,
    -- `session.teams {enabled:true}` answering `reload: true`: the front end
    -- runs its normal load path so the agent replays under the new injection.
    reload_session = function(instance, session_id, cb)
      if not S.sess.service then
        cb(false, "no session service")
        return
      end
      -- Bind the reload to the client that answered `session.teams`: on a new
      -- connection the one-shot forward marker belongs to the old instance.
      local client = S.conn.client
      local live = client and client.proc and client.proc.instance or nil
      if instance and live and instance ~= live then
        cb(false, "the service connection changed before the reload")
        return
      end
      local generation = ctx.Operations.generation
      local done = false
      local function finish(ok, value)
        if done then
          return
        end
        done = true
        if ctx.Operations.generation ~= generation then
          cb(false, "the reload was cancelled")
          return
        end
        cb(ok, value)
      end
      -- Only a reload of the chat on screen may change the display: a flow
      -- starting a background session must not switch the person's chat (and so
      -- must not let the idle-close of a switch fire on it).
      local current = S.sess.current
      local select = current ~= nil and current.id == session_id
      local ok, err = pcall(S.sess.service.load, S.sess.service, session_id, {
        kind = "reload",
        reload = true,
        select = select,
        client = client,
        on_restored = function()
          finish(true, { reloaded = true })
        end,
        on_failed = function(message)
          finish(false, message)
        end,
      })
      if not ok then
        finish(false, tostring(err))
      end
    end,
    on_turn = function(session)
      if session == S.sess.current and S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
  })
  -- Switching a session is also when the per-session team switch is read, so
  -- the tree can mark a session `[team off]` before the person acts on it.
  local function activate_session(session, opts)
    ctx.activate_session(session, opts)
    if session and S.view.team then
      local client = S.conn.client
      local live = client and client.proc and client.proc.instance or nil
      local instance = session.instance or live
      if instance and not session.instance then
        session.instance = live
      end
      S.view.team:session_opened(instance, session.id, session.cwd or ctx.resolve_cwd())
    end
  end

  S.sess.service = Sessions.new({
    config = cfg,
    runtime = function()
      return S.sess.runtime
    end,
    catalog = S.sess.catalog,
    client = function()
      return S.conn.client
    end,
    connection = function()
      return S.conn.phase
    end,
    generation = function()
      return ctx.Operations.generation
    end,
    new_local = ctx.new_local_session,
    resolve_cwd = ctx.resolve_cwd,
    run = function(key, client, session, fn, on_error, on_finally)
      return ctx.Operations:run(key, client, session, fn, on_error, on_finally)
    end,
    cancel_session = function(session, except)
      return ctx.Operations:cancel_session(session, except)
    end,
    current = ctx.current,
    activate = activate_session,
    render = function()
      if S.view.chat then
        S.view.chat:render(true)
      end
    end,
    dispatch_queued = ctx.dispatch_queued,
    on_changed = ctx.refresh_chrome,
    on_replaying = function(value)
      S.conn.replaying = value
      if S.conn.client and S.conn.client.mark_phase then
        S.conn.client:mark_phase(value and "replay" or nil)
      end
      if not value then
        ctx.flush_auth_retry()
      end
    end,
    on_creating = function(value)
      S.conn.creating_session = value
    end,
    prune = ctx.prune_sessions,
    -- Teams (PROTOCOL.md 20.2): configure the cwd before the first session
    -- request, then ask the service for the new session's switch state.
    before_session = function(cwd, client)
      if S.view.team then
        S.view.team:prepare(cwd, client)
      end
    end,
    after_session = function(cwd, session_id, instance)
      if S.view.team then
        S.view.team:session_opened(instance, session_id, cwd)
      end
    end,
    -- PROTOCOL.md 13: the adoption notification precedes the committed replay,
    -- so it is deferred until the session exists, then applied from here.
    session_ready = function(session)
      if S.conn.adoption then
        pcall(S.conn.adoption.session_ready, S.conn.adoption, session)
      end
    end,
    session_forget = function(session_id)
      if S.conn.adoption then
        -- The replay ended without committing this id: drop the deferred
        -- adoption (and, when the old object is still current, restore its
        -- marker), so no stale adoption survives to the next load.
        pcall(S.conn.adoption.forget_pending, S.conn.adoption, session_id)
      end
    end,
    auth = function()
      return S.view.auth
    end,
    notify = notify,
  })
  S.sess.prompts = Prompts.new({
    config = cfg,
    runtime = function()
      return S.sess.runtime
    end,
    client = function()
      return S.conn.client
    end,
    connection = function()
      return S.conn.phase
    end,
    run = function(key, client, session, fn, on_error, on_finally)
      return ctx.Operations:run(key, client, session, fn, on_error, on_finally)
    end,
    policy = function()
      return S.conn.policy
    end,
    auth = function()
      return S.view.auth
    end,
    auth_pending = function()
      local pending = S.conn.pending_auth_retries
      return pending ~= nil and #pending > 0
    end,
    retry = function(session_id, text, attachments)
      -- Never send from inside the failed turn: the client may be about to be
      -- replaced (a terminal login restarts it) and the captured session is
      -- stale. Park the message and flush it as soon as the session is usable.
      S.conn.flow:park_for_retry(session_id, text, attachments)
      return true
    end,
    selected = function(session)
      return S.sess.current == session
    end,
    on_turn_start = function(session)
      if S.view.chat and S.sess.current == session then
        S.view.chat.follow = true
        S.view.chat:schedule_render()
      end
    end,
    on_turn_end = function(session)
      if S.sess.current == session then
        ctx.stop_spinner()
      end
    end,
    on_changed = ctx.refresh_chrome,
    on_render = function(session)
      if S.view.chat and S.sess.current == session then
        S.view.chat:schedule_render()
      end
    end,
    add_block = ctx.add_system_block,
    prune = ctx.prune_sessions,
    dispatch_queued = ctx.dispatch_queued,
    refresh_title = ctx.refresh_session_title,
    notify = notify,
  })
  S.view.auth = Auth.new({
    config = cfg,
    client = function()
      return S.conn.client
    end,
    notify = notify,
    restart = function()
      S.conn.service:restart()
    end,
    base_window = function()
      return layout.saved_focus()
    end,
    after_ready = function(fn)
      -- The reconnect may already have finished by the time the login terminal
      -- exits (a fast agent, or a synchronous start); run immediately then.
      if S.conn.phase == "ready" and S.conn.client and S.conn.client:is_ready() then
        pcall(fn)
        return
      end
      S.conn.auth_after_ready = S.conn.auth_after_ready or {}
      S.conn.auth_after_ready[#S.conn.auth_after_ready + 1] = fn
    end,
    on_changed = ctx.refresh_chrome,
  })
  -- The manager owns installer state and launch leases; the connection only
  -- asks it what to start. `rawget` is required here: the controller's ctx
  -- metatable answers every unknown key with a function, so a plain
  -- `ctx.resolve_store and ...` would always take the "provided" branch.
  local provided_store = rawget(ctx, "resolve_store")
  local provided_locks = rawget(ctx, "locks")
  S.conn.store = provided_store and provided_store() or Resolve.new_store(merged)
  S.conn.locks = provided_locks and provided_locks()
    or Lock.new({
      root = function()
        return Resolve.manager_root(merged)
      end,
    })
  S.conn.service = Connection.new({
    config = cfg,
    store = function()
      return S.conn.store
    end,
    locks = S.conn.locks,
    resolve_cwd = ctx.resolve_cwd,
    state = function()
      return S
    end,
    generation = function()
      return ctx.Operations.generation
    end,
    reset_operations = ctx.invalidate_operations,
    on_event = function(name, payload)
      return ctx.on_client_event(name, payload)
    end,
    notify = notify,
    on_changed = ctx.refresh_chrome,
    on_ready = function()
      -- `backend_service` is fixed when the client is created, which is after
      -- the hello; install the config set now that the connection is really
      -- carrying this agent.
      if S.conn.policy then
        pcall(S.conn.policy.reconcile, S.conn.policy, true)
      end
      local reload_id = S.conn.service:take_pending_reload()
      -- A session manager row was chosen: load that exact session in its own
      -- directory instead of auto-restoring another one or creating an empty
      -- session. The request is one-shot, so a later reconnect behaves normally.
      local pending_load = S.conn.pending_load
      S.conn.pending_load = nil
      local skip_restore = S.conn.skip_auto_restore
      S.conn.skip_auto_restore = nil
      local client, current = S.conn.client, S.sess.current
      if pending_load and not pending_load_applies(pending_load, client, S.config and S.config.agent) then
        -- This is not the connection the intent was written for: drop it and
        -- behave like any other ready connection (restore or start fresh).
        pending_load = nil
      end
      reload_id = reload_id or (current and current.needs_load and current.id)
      if pending_load then
        -- `session/load` must use the directory the agent reported, and the
        -- catalog was rebuilt by the switch, so seed it before loading.
        if S.sess.catalog then
          S.sess.catalog:cwds()[pending_load.id] = pending_load.cwd
        end
        if S.sess.service then
          -- `kind = "restore"` keeps the normal failed-load behaviour: a
          -- failure reports and starts a fresh session in the new folder.
          S.sess.service:load(pending_load.id, { kind = "restore", cwd = pending_load.cwd })
        else
          ctx.new_session()
        end
      elseif reload_id then
        local session = S.sess.all[reload_id] or (current and current.id == reload_id and current)
        if not (client and client.created == true and session and S.conn.restore:after_restart(session)) then
          ctx.reload_session(reload_id)
        end
      elseif not S.sess.current and (skip_restore or not S.conn.auth_after_ready) then
        -- Reopening a Neovim whose agent kept running: the service reports the
        -- sessions it holds and, when one belongs to this cwd, that session is
        -- loaded instead of starting an empty one (PROTOCOL.md 3.2).
        local restored = not skip_restore
          and S.conn.restore
          and S.conn.restore:after_ready({
            created = client and client.created,
            sessions = client and client.sessions,
          })
        if not restored then
          ctx.new_session()
        end
      end
      local queued = S.conn.auth_after_ready
      S.conn.auth_after_ready = nil
      for _, fn in ipairs(queued or {}) do
        pcall(fn)
      end
      ctx.flush_auth_retry()
    end,
    on_start_failed = function(err)
      if
        S.view.auth
        and S.view.auth:require(err, {
          retry = function()
            ctx.connect()
          end,
        })
      then
        -- The login retries this same connection; the pending load still
        -- describes it.
        return
      end
      -- This connection will not come up. A later, unrelated connection (another
      -- agent, another folder) must never load the abandoned session.
      S.conn.pending_load = nil
      local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
      -- The common first-run failure: the preset command is not on PATH and
      -- the adapter has not been installed by the manager either.
      local id = merged.agent
      if
        message:find("not executable", 1, true)
        and require("ade.manager.registry").package_of(id)
        and S.view.agent_manager_service
        and S.view.agent_manager_service:store():state(id).status == "not_installed"
      then
        message = message .. string.format(" — install it with :Ade install %s (or press i in :Ade agents)", id)
      end
      notify("failed to start agent: " .. message, vim.log.levels.ERROR)
    end,
    runtime_lost = function()
      S.sess.runtime:connection_lost()
    end,
    reset_permissions = function()
      if S.view.interactions then
        S.view.interactions:cancel_all("connection reset")
      end
    end,
    interactions = function()
      return S.view.interactions
    end,
    stop_animation = ctx.stop_spinner,
    on_render = function()
      if S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
  })
  S.conn.phase = "stopped"
  S.conn.replaying = false
  S.conn.creating_session = false

  -- The manager service and its window. The window is created lazily on first
  -- open, so a user who never runs `:Ade agents` pays nothing for it.
  local manager_presenter = require("ade.app.presenter")
  local previous_service = S.view.agent_manager_service
  S.view.agent_manager_service = AgentManager.new({
    config = cfg,
    notify = notify,
    presenter = manager_presenter,
    store = rawget(ctx, "resolve_store") and rawget(ctx, "resolve_store")() or nil,
    locks = S.conn.locks,
    npm = rawget(ctx, "manager_npm") and rawget(ctx, "manager_npm")() or nil,
    -- Service mode runs installs in the service when its hello offers the
    -- `install` feature (PROTOCOL.md 16); the manager decides per operation.
    service = S.conn.service,
    on_changed = function()
      if S.view.agent_manager and S.view.agent_manager:is_open() then
        S.view.agent_manager:refresh()
      end
    end,
  })
  -- A reconfiguration (switching agents) must not forget installs still
  -- running: share the per-agent tables so their callbacks land in the window.
  if previous_service then
    S.view.agent_manager_service:adopt(previous_service)
  end
  local wanted = type(merged.manager) == "table" and merged.manager.ensure_installed or nil
  if type(wanted) == "table" and #wanted > 0 then
    local service = S.view.agent_manager_service
    vim.schedule(function()
      if S.view.agent_manager_service == service then
        service:ensure_installed(wanted)
      end
    end)
  end
  -- The configuration (auto_allow, manager settings) may have changed; the
  -- service keeps `config` as a keep = "service" set, so reconcile after every
  -- rebuild. Scheduled so the connection object from this build exists first.
  vim.schedule(function()
    if S.conn.policy then
      pcall(S.conn.policy.reconcile, S.conn.policy, true)
    end
    if S.view.team and S.view.team:available() then
      local cwd = S.view.team.resolve_cwd and S.view.team.resolve_cwd() or nil
      if cwd then
        -- Re-send only when the resolved config actually changed; on_hello
        -- owns the forced re-send for a (re)started service.
        pcall(S.view.team.configure, S.view.team, cwd, false)
      end
    end
  end)
  S.view.agent_manager = AgentManagerUI.new({
    manager = S.view.agent_manager_service,
    config = cfg,
    on_use = function(id)
      ctx.pick_agent(id)
    end,
  })

  -- Cross-agent session manager (`:Ade sessions all`), docs/session-manager.md.
  -- It uses the shared service connection, not the panel's client, so it works
  -- before the panel has ever connected. A replaced manager must drop its
  -- `sessions.updated` listener and its in-flight requests.
  local previous_session_manager = S.view.session_manager
  if previous_session_manager and type(previous_session_manager.dispose) == "function" then
    pcall(previous_session_manager.dispose, previous_session_manager)
  end
  S.view.session_manager = SessionManager.new({
    state = function()
      return S
    end,
    config = cfg,
    notify = notify,
    setup = ctx.setup,
    open = ctx.open,
    pick_session = ctx.pick_session,
    resolve_cwd = ctx.resolve_cwd,
    presenter = manager_presenter,
  })

  S.view.attachments = Attachments.new({
    state = function()
      return S
    end,
    config = cfg,
    notify = notify,
    refresh_chrome = ctx.refresh_chrome,
    focus = ctx.focus,
  })
  -- Turn adoption (PROTOCOL.md 13): a turn the service kept alive for us.
  S.conn.adoption = Adoption.new({
    state = function()
      return S
    end,
    refresh_chrome = ctx.refresh_chrome,
    schedule_render = function()
      if S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
    dispatch_queued = ctx.dispatch_queued,
    add_block = ctx.add_system_block,
    notify = notify,
  })

  S.conn.events = Events.new({
    state = function()
      return S
    end,
    refresh_chrome = ctx.refresh_chrome,
    notify = notify,
    add_block = ctx.add_system_block,
    prune = ctx.prune_sessions,
    adoption = S.conn.adoption,
    team = S.view.team,
    on_exit = function(payload)
      return S.conn.service:lost(payload)
    end,
  })

  -- Automatic reconnection after an *unexpected* drop. The loop itself lives in
  -- `app/reconnector`; `ensure` restarts the service when needed and `reconnect`
  -- is the same path `:Ade reconnect` takes.
  S.conn.reconnector = Reconnector.new({
    config = function()
      return S.config or merged
    end,
    ensure = function(cb)
      S.conn.service:ensure(cb)
    end,
    reconnect = function()
      S.conn.service:reconnect()
    end,
    -- `lost()` runs in the socket EOF callback (a libuv fast event context)
    -- when the service dies, and `vim.notify` raises E5560 there; the give-up
    -- notice would be swallowed by the `pcall` around it. Defer only in that
    -- case: the loop's timer callbacks already run on the main loop, and
    -- scheduling those too would let "reconnected" drift behind the notices
    -- the reconnect itself produces right after it (e.g. the session restore).
    notify = function(message, level)
      if vim.in_fast_event() then
        vim.schedule(function()
          notify(message, level)
        end)
      else
        notify(message, level)
      end
    end,
    set_status = function(text)
      S.conn.reconnect_status = text
      -- Same fast-context problem: the chrome refresh reaches window APIs. The
      -- repaint is asynchronous anyway, so schedule it.
      vim.schedule(ctx.refresh_chrome)
    end,
  })

  -- One subscription for the whole panel: an unexpected drop starts the retry
  -- loop, a deliberate one (`:Ade service stop`, `:Ade disconnect`, editor exit)
  -- cancels it.
  local function on_service_lost(payload)
    local intentional = type(payload) == "table" and payload.intentional == true
    if intentional or S.conn.service.closed then
      pcall(S.conn.reconnector.cancel, S.conn.reconnector, "deliberate disconnect")
      return
    end
    -- Only the service backend can reconnect automatically: the direct backend
    -- has no service to restart.
    local backend = (S.config or merged).backend
    if backend ~= "service" and backend ~= "auto" then
      return
    end
    pcall(S.conn.reconnector.lost, S.conn.reconnector)
  end
  -- `Connection:subscribe` forwards to the shared *service* connection, which is
  -- what actually receives `__disconnected`. Talking to `S.conn.service` used
  -- to be a silent no-op — the app-level object had no `subscribe`, a
  -- `type(...) == "function"` guard swallowed the mistake, and automatic
  -- reconnection was never wired at all. A missing method is a wiring bug, not
  -- an optional capability, so it must fail loudly.
  if type(S.conn.service.subscribe) ~= "function" then
    local message = "ade.nvim: the connection object cannot subscribe; automatic reconnection is disabled"
    log.error(message)
    -- Report it, but do not abort setup: the rest of the panel still works.
    pcall(notify, message, vim.log.levels.ERROR)
  else
    local ok, err = pcall(S.conn.service.subscribe, S.conn.service, "panel", "__disconnected", on_service_lost)
    if ok then
      -- `:Ade service stop` while the loop is between attempts has no live
      -- socket and therefore no EOF to carry the intent; the command announces
      -- it separately so the retry loop still stops.
      ok, err = pcall(S.conn.service.subscribe, S.conn.service, "panel", "__stopped", on_service_lost)
    end
    if not ok then
      log.error("subscribing to service stop/loss failed: %s", tostring(err))
      pcall(notify, "ade.nvim: automatic reconnection is disabled: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  S.conn.restore = Restore.new({
    config = cfg,
    cwd = function()
      return S.conn.service and S.conn.service.cwd_hint and S.conn.service.cwd_hint() or ctx.resolve_cwd()
    end,
    supported = function(allow_resume)
      local client = S.conn.client
      if not client then
        return false
      end
      local supports = require("ade.protocol.capabilities").supports
      local agent = require("ade.protocol.capabilities").agent(client)
      return supports(agent, "loadSession") or (allow_resume and supports(agent, "sessionCapabilities.resume"))
    end,
    -- The outcome callbacks travel through `Sessions:load`: without them
    -- `restore.lua` cannot tell the user "restored session X" or why it fell
    -- back, which is the whole difference between a restore and a fresh start
    -- as far as the user can see.
    load = function(session_id, load_opts)
      S.sess.service:load(session_id, load_opts)
    end,
    create = function()
      ctx.new_session()
    end,
    notify = notify,
  })

  S.view.panel = Panel.new({
    config = cfg,
    notify = notify,
    on_windows_ready = function()
      ctx.update_chat_title()
      ctx.refresh_chrome()
    end,
    on_visibility = function()
      if S.view.choices then
        vim.schedule(function()
          S.view.choices:refresh()
        end)
      end
    end,
  })

  if S.view.team_ui then
    pcall(S.view.team_ui.close, S.view.team_ui)
  end
  S.view.team_ui = TeamUI.new({
    team = S.view.team,
    config = cfg,
    notify = notify,
    panel = function()
      return S.view.panel
    end,
    -- Selecting the leader or a worker reuses the ordinary chat/input pair:
    -- there is no second Chat and no dedicated worker window.
    leader_chat = function()
      return S.view.chat
    end,
    leader_input = function()
      return S.view.input
    end,
    current_session = function()
      return S.sess.current
    end,
    sessions = function()
      return S.sess.all or {}
    end,
    connection_generation = function()
      return ctx.Operations.generation
    end,
    find_session = function(id)
      if type(id) ~= "string" then
        return nil
      end
      local session = S.sess.all and S.sess.all[id] or nil
      if session then
        return session
      end
      -- A session that exists on the agent but was never loaded here is not
      -- addressable as a transcript, so it does not count.
      return nil
    end,
    select_session = activate_session,
    -- The tree's `<CR>` opens a session the way `:Ade sessions` does: a released
    -- or `needs_load` session is replayed first, not merely selected.
    open_session = function(session, opts)
      if not session then
        return
      end
      if S.sess.service then
        opts = opts or {}
        S.sess.service:open(session, {
          instance = opts.instance,
          cwd = opts.cwd,
          on_failed = function(message)
            notify("cannot open that session: " .. tostring(message), vim.log.levels.WARN)
          end,
        })
      else
        activate_session(session)
      end
    end,
    instance = function()
      -- The router's cached fallback: after a reconnect it needs to know which
      -- instance this editor used before the agent client re-attached.
      local client = S.conn.client
      local instance = client and client.proc and client.proc.instance or nil
      if instance then
        return instance
      end
      local cwd = ctx.resolve_cwd()
      local bound = cwd and S.view.team and S.view.team.bound and S.view.team.bound[cwd] or nil
      if bound and bound.instance then
        return bound.instance
      end
      return cwd and S.view.team and S.view.team:leader_instance(cwd) or nil
    end,
    live_instance = function()
      -- Strict: only a ready client's instance may certify a row as online or
      -- receive a row's action. Cached bindings are a display/route hint, never
      -- a liveness signal.
      if S.conn.phase ~= "ready" then
        return nil
      end
      local client = S.conn.client
      return client and client.proc and client.proc.instance or nil
    end,
    start_team = function(workflow, session)
      if S.view.team_commands then
        S.view.team_commands:start(workflow, session)
      end
    end,
  })

  S.view.team_commands = TeamCommands.new({
    state = function()
      return S
    end,
    config = cfg,
    notify = notify,
    resolve_cwd = ctx.resolve_cwd,
    open = function()
      ctx.open()
    end,
    new_session = function(opts)
      ctx.new_session(opts)
    end,
    connect = function()
      ctx.connect()
    end,
    pick_agent = function(name)
      ctx.pick_agent(name)
    end,
    options = function()
      return S.view.options
    end,
    client = function()
      return S.conn.client
    end,
    generation = function()
      return ctx.Operations.generation
    end,
    report_error = Team.error_text,
    choices = function()
      return S.view.choices
    end,
    find_session = function(id)
      return S.sess.all and S.sess.all[id] or nil
    end,
    select_session = function(session)
      -- A leader found by id may have been released: open it the normal way so
      -- `session/load` restores it instead of showing an empty transcript.
      if session and S.sess.service then
        S.sess.service:open(session, {
          on_failed = function(message)
            notify("cannot open the leader session: " .. tostring(message), vim.log.levels.WARN)
          end,
        })
        return
      end
      return activate_session(session)
    end,
    -- One enable in flight per `(instance, sessionId)`: a start joining a
    -- `:Ade team on` (or another start) waits for that attempt instead of
    -- sending a second held `session.teams` write (PROTOCOL.md 20.5).
    enable_session = Team.enable_session,
    canonical_session = function(instance, session_id)
      -- The runtime holds one canonical object per session id; a reload
      -- replaces it, so a flow must look it up again for (instance, id).
      local session = S.sess.all and S.sess.all[session_id] or nil
      if not session then
        return nil
      end
      if instance and session.instance and session.instance ~= instance then
        return nil
      end
      return session
    end,
    submit = function(text, session)
      -- Address the replacement session when one is given; never the composer's
      -- current target, which may have changed while RPCs were in flight.
      if session and S.sess.prompts then
        S.sess.prompts:send(session, text, nil)
        return
      end
      ctx.submit(text, nil)
    end,
    open_team = function()
      return ctx.open_team()
    end,
  })

  S.view.chat = Chat.new({ config = merged })
  S.view.chat.on_pending_new = function()
    ctx.update_chat_title()
  end
  S.view.input = Input.new({
    config = merged,
    on_submit = function(text, attachments)
      local ui = S.view.team_ui
      if ui and ui.route_submit and ui:route_submit(text, attachments) then
        return
      end
      ctx.submit(text, attachments)
    end,
    on_cancel = function()
      local ui = S.view.team_ui
      if ui and ui.is_worker_target and ui:is_worker_target() then
        ui:cancel_target()
        return
      end
      ctx.cancel()
    end,
  })
  S.view.input.on_refresh = function()
    ctx.update_input_toolbar()
  end
  S.view.input.on_draft = function(key, text, attachments, owner, pastes)
    local session = owner or S.sess.all[key]
    if not session then
      return
    end
    drafts.put(session.cwd, session.id, text, attachments, pastes)
  end
  S.view.attachments:flush(S.view.input)

  -- Mappings and completion belong to buffers, not windows. Hiding, reopening
  -- or repairing a missing view reuses these buffers and needs no reattachment.
  local window = ctx.install_window({
    state = function()
      return S
    end,
    config = cfg,
    refresh_chrome = ctx.refresh_chrome,
    stop_spinner = ctx.stop_spinner,
    update_title = ctx.update_chat_title,
    prune_sessions = ctx.prune_sessions,
    sync_spinner = ctx.sync_spinner,
  })
  -- The inline editor is a leaf module: give it the application hooks it needs
  -- instead of letting it require the controller back.
  require("ade.inline").setup({
    state = function()
      return S
    end,
    send = function(session, text, hooks)
      return ctx.send_inline(session, text, hooks)
    end,
    is_question = function(interaction)
      return Permissions.question(interaction)
    end,
  })
  S.view.panel:set_views(S.view.chat, S.view.input)

  -- Re-attach the active session to the freshly created views.
  if S.sess.current then
    S.view.chat:set_session(S.sess.current)
    S.view.input:switch_session(S.sess.current.id, nil, S.sess.current)
  end

  -- Click regions in the winbar only respond when the mouse is enabled. Say so
  -- once instead of leaving the user with a toolbar that looks clickable but
  -- is not.
  if merged.ui.toolbar.placement ~= "off" and not S.view.click_hint_shown then
    S.view.click_hint_shown = true
    vim.schedule(function()
      if not vim.o.mouse:find("[anvi]") then
        vim.notify(
          string.format(
            "ade.nvim: 'mouse' is %q, so the model/mode toolbar is not clickable. "
              .. "Enable mouse support (e.g. set mouse=nvi) or use <M-m> / <M-b>.",
            vim.o.mouse
          ),
          vim.log.levels.INFO
        )
      end
    end)
  end
end

return M
