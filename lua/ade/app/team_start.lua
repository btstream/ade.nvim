-- `:Ade team start`: start a workflow from the current session
-- (PROTOCOL.md 20.4).
--
-- The service owns team creation and leadership now, so the flow is straight
-- line: pick a workflow, make sure the session's tools are on, ask for the
-- task, call `team.start` on this session and let the service answer. No
-- polling and no leader-session juggling: an in-place reload (`session.teams`)
-- covers sessions created before teams were configured, and a `led_by` answer
-- becomes a choice card.
--
-- Everything that touches the editor is injected by the controller, so the
-- flow can be driven by tests with fake pickers and a fake team module.
--
-- A flow is identified by a generation: starting again, cancelling or a team
-- closing invalidates every pending continuation of the old flow.
local M = {}

local Flow = {}
Flow.__index = Flow

---cwd -> true while a start flow runs for it. Module level on purpose: the
---controller (and its Team/flow objects) is rebuilt when the leader agent is
---switched, but the start keeps running across that rebuild.
local active = {}

---cwd -> {flow, generation} for the flow that owns a start right now.
local running = {}

---Whether a start flow is running for `cwd`.
---@param cwd string
---@return boolean
function M.active(cwd)
  return active[cwd] == true
end

---Cancel the flow running for `cwd`, whichever module object owns it.
---@param cwd string
---@return boolean cancelled
function M.cancel_for(cwd)
  local state = running[cwd]
  if not state then
    return false
  end
  state.flow:cancel()
  return true
end

---@param deps {state: fun(): table, config: fun(): table, notify: fun(message: string, level: integer|nil),
---  resolve_cwd: fun(): string, open: fun(),
---  new_session: (fun(opts: table)|nil)|nil, connect: fun(),
---  pick_agent: fun(name: string)|nil, options: fun(): table|nil,
---  client: fun(): table|nil, generation: fun(): integer|nil,
---  report_error: fun(value: any), choices: (fun(): table|nil)|nil,
---  find_session: (fun(id: string): table|nil)|nil,
---  select_session: (fun(session: table)|nil)|nil,
---  submit: (fun(text: string, session: table|nil)|nil)|nil}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps, starting = false, generation = 0, cwd = nil }, Flow)
end

function Flow:notify(message, level)
  pcall(self.deps.notify, message, level)
end

---@return table|nil
function Flow:team()
  local S = self.deps.state()
  return S and S.view and S.view.team or nil
end

---@return table|nil
function Flow:choices()
  local ok, choices = pcall(self.deps.choices)
  return ok and choices or nil
end

---@return table
function Flow:config()
  local ok, cfg = pcall(self.deps.config)
  return ok and type(cfg) == "table" and cfg or {}
end

---@return string
function Flow:cwd()
  local ok, cwd = pcall(self.deps.resolve_cwd)
  if ok and type(cwd) == "string" and cwd ~= "" then
    return cwd
  end
  local cfg = self:config()
  return cfg.cwd or vim.fn.getcwd()
end

---The session the flow acts on, with its instance.
---
---`session` may be passed explicitly (the tree's `S` starts in the row's
---session); otherwise the session on screen is used. The instance is the one
---recorded for that session; a session owned by another (offline) instance is
---refused instead of being addressed through the live one.
---@param session table|nil
---@return table|nil session
---@return string|nil instance
function Flow:context(session)
  local S = self.deps.state()
  session = session or (S and S.sess and S.sess.current) or nil
  if not session then
    return nil, nil
  end
  local client = self.deps.client and self.deps.client() or nil
  local live = client and client.proc and client.proc.instance or nil
  local instance = session.instance
  if instance and live and instance ~= live then
    return session, nil
  end
  return session, instance or live
end

function Flow:available()
  local cfg = self:config()
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  if teams.enabled == false or cfg.backend == "direct" then
    return false
  end
  local team = self:team()
  return team ~= nil and team:available()
end

---End the flow and invalidate every continuation.
function Flow:finish()
  self.starting = false
  local cwd = self.cwd
  self.cwd = nil
  if not cwd then
    return
  end
  local state = running[cwd]
  if state and state.flow == self and state.generation == self.registered_generation then
    running[cwd] = nil
    active[cwd] = nil
  end
end

---Cancel a running flow (a second `:Ade team start`, `:Ade team close`, ...).
function Flow:cancel()
  if not self.starting then
    return
  end
  self.generation = self.generation + 1
  self:finish()
end

---Whether a continuation from `generation` may still run.
---@param generation integer
---@return boolean
function Flow:alive(generation)
  if not self.starting or generation ~= self.generation then
    return false
  end
  local cwd = self.cwd
  local state = cwd and running[cwd] or nil
  return state ~= nil and state.flow == self and state.generation == generation
end

---Entry point. `name` is a workflow name, or nil to select one.
---@param name string|nil
---@param target table|nil session to start in (the tree's `S`)
function Flow:start(name, target)
  local cfg = self:config()
  local teams = cfg.teams or {}
  if teams.enabled == false then
    self:notify("teams are disabled in the configuration (teams.enabled)", vim.log.levels.WARN)
    return
  end
  if cfg.backend == "direct" then
    self:notify("team start requires the service backend", vim.log.levels.WARN)
    return
  end
  local session, instance = self:context(target)
  if not session then
    self:notify("team start requires an open session connected to the service", vim.log.levels.WARN)
    return
  end
  if not instance then
    self:notify(
      "team start requires the service instance that owns that session; open it from the tree's service first",
      vim.log.levels.WARN
    )
    return
  end
  local cwd = session.cwd or self:cwd()
  if not self:available() then
    self:notify("teams need the service connection; open the panel first", vim.log.levels.WARN)
    return
  end
  local previous = running[cwd]
  if previous then
    previous.flow:cancel()
  end
  self.generation = (self.generation or 0) + 1
  local generation = self.generation
  self.starting = true
  self.cwd = cwd
  self.registered_generation = generation
  -- The model switch after a successful start belongs to this session and
  -- client, even if the person switches chats while `team.start` is in flight.
  local client = self.deps.client and self.deps.client() or nil
  self.target = { session = session, client = client }
  active[cwd] = true
  running[cwd] = { flow = self, generation = generation }
  self:load_workflows(name, session, instance, cwd, generation)
end

function Flow:load_workflows(name, session, instance, cwd, generation)
  local team = self:team()
  if not team then
    self:finish()
    return
  end
  team:workflows(cwd, function(ok, value)
    -- The callback runs in the socket's fast event context; the pickers below
    -- are only legal on the main loop.
    vim.schedule(function()
      if not self:alive(generation) then
        return
      end
      self:on_workflows(ok, value, name, session, instance, cwd, generation)
    end)
  end)
end

---@param ok boolean
---@param value any
---@param name string|nil
---@param session table
---@param instance string
---@param cwd string
---@param generation integer
function Flow:on_workflows(ok, value, name, session, instance, cwd, generation)
  if not ok then
    self:finish()
    self:notify("cannot list workflows: " .. self.deps.report_error(value), vim.log.levels.WARN)
    return
  end
  local workflows = type(value) == "table" and type(value.workflows) == "table" and value.workflows or {}
  if name == nil or name == "" then
    if #workflows == 0 then
      self:finish()
      self:notify("no workflow is available; save one with :Ade workflows", vim.log.levels.WARN)
      return
    end
    local default = (self:config().teams or {}).default or "default"
    local labels, by_label = {}, {}
    for _, workflow in ipairs(workflows) do
      labels[#labels + 1] = workflow.name
      by_label[workflow.name] = workflow
    end
    table.sort(labels, function(a, b)
      if a == default then
        return b ~= default
      end
      if b == default then
        return false
      end
      return a < b
    end)
    vim.ui.select(labels, {
      prompt = "workflow for the team:",
      format_item = function(item)
        local workflow = by_label[item]
        local summary = workflow and workflow.summary or ""
        return summary ~= "" and (item .. " — " .. summary) or item
      end,
    }, function(choice)
      if not self:alive(generation) then
        return
      end
      if not choice then
        self:finish()
        return
      end
      self:check_switch(by_label[choice], session, instance, cwd, generation)
    end)
    return
  end
  local workflow
  for _, entry in ipairs(workflows) do
    if entry.name == name then
      workflow = entry
      break
    end
  end
  if not workflow then
    self:finish()
    self:notify("unknown workflow " .. tostring(name), vim.log.levels.WARN)
    return
  end
  self:check_switch(workflow, session, instance, cwd, generation)
end

---Make sure the session's tools are on before asking for a task.
---@param workflow table
---@param session table
---@param instance string
---@param cwd string
---@param generation integer
---@param queried boolean|nil
function Flow:check_switch(workflow, session, instance, cwd, generation, queried)
  local team = self:team()
  local state = team and team:session_teams(instance, session.id) or nil
  if not state and not queried then
    team:query_session_teams(instance, session.id, cwd, function(ok, value)
      vim.schedule(function()
        if not self:alive(generation) then
          return
        end
        if not ok or type(value) ~= "table" then
          self:finish()
          self:notify("cannot read the teams switch: " .. self.deps.report_error(value), vim.log.levels.WARN)
          return
        end
        self:check_switch(workflow, session, instance, cwd, generation, true)
      end)
    end)
    return
  end
  if state and state.enabled and (state.injected ~= false) then
    self:ask_task(workflow, session, instance, cwd, generation)
    return
  end
  self:enable_tools(session, instance, function(ok, err, handled)
    if handled then
      -- Already reported (a replacement took over, or a known dead end).
      return
    end
    if not ok then
      self:finish()
      self:notify("cannot enable teams for this session: " .. self.deps.report_error(err), vim.log.levels.WARN)
      return
    end
    self:ask_task(workflow, session, instance, cwd, generation)
  end, { workflow = workflow, cwd = cwd, generation = generation })
end

---Enable the session's tools, running the front-end reload the service asks for
---(PROTOCOL.md 20.5). Shared by the pre-check and the `off`/`no_tools` retry so
---both apply the same `reload: true` rule.
---
---`cb(ok, err, handled)`: `handled` means the flow already reported the
---outcome (a replacement session took over, or a known dead end) and the caller
---must stay quiet.
---@param session table
---@param instance string
---@param cb fun(ok: boolean, err: any, handled: boolean|nil)
---@param ctx {workflow: table, cwd: string, generation: integer, replacement: boolean|nil}
function Flow:enable_tools(session, instance, cb, ctx)
  local team = self:team()
  if not team then
    cb(false, "teams are not available")
    return
  end
  team:set_session_teams(instance, session.id, true, false, function(ok, value)
    vim.schedule(function()
      if not self:alive(ctx.generation) then
        -- A newer start owns the flow: ignore silently, do not finish it.
        return
      end
      if not ok then
        local data = type(value) == "table" and type(value.data) == "table" and value.data or {}
        if data.reason == "reload_unsupported" then
          if type(ctx) == "table" and ctx.replacement then
            -- Already in the replacement session: replacing again would loop.
            cb(false, "this agent cannot reload teams in place")
            return
          end
          -- A new session would follow the same configuration; when that
          -- configuration starts sessions with teams off, injecting is
          -- impossible and offering "open a new session" would be a false
          -- promise.
          if self:session_default_off() then
            self:finish()
            self:notify(
              "this agent cannot reload teams in place, and new sessions start with teams off "
                .. "(teams.session_default = false); set teams.session_default = true and open a new session",
              vim.log.levels.WARN
            )
            cb(false, "reload_unsupported with session_default = false", true)
            return
          end
          self:offer_new_session(ctx.workflow, session, instance, ctx.cwd, ctx.generation, function(replaced, err2)
            cb(replaced, err2, true)
          end)
          return
        end
        cb(false, value)
        return
      end
      if type(value) == "table" and value.reload == true then
        -- The service marked the session one-shot forward; the front end runs
        -- the load that makes the agent replay and gets the tools injected.
        team:reload_session(instance, session.id, function(reloaded, err)
          vim.schedule(function()
            if not self:alive(ctx.generation) then
              return
            end
            if reloaded then
              cb(true, nil)
              return
            end
            cb(false, "cannot reload the session's team tools: " .. self.deps.report_error(err))
          end)
        end)
        return
      end
      cb(true, nil)
    end)
  end)
end

---Whether new sessions of this cwd start with their team switch off.
---@return boolean
function Flow:session_default_off()
  local cfg = self:config()
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  return teams.session_default == false
end

---A session that cannot reload has to be replaced; carry its conversation
---over as a summary.
---
---The replacement is bound to this exact `new_session` request: the flow only
---continues from that request's success callback, and a failure ends the flow
---with a message instead of leaving it waiting for some other session.
---@param workflow table
---@param session table
---@param instance string
---@param cwd string
---@param generation integer
function Flow:offer_new_session(workflow, session, instance, cwd, generation, cb)
  cb = cb or function() end
  local accept = "open a new session and hand over a summary"
  local cancel = "cancel"
  vim.ui.select({ accept, cancel }, {
    prompt = "this agent cannot reload tools in place",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not self:alive(generation) then
      cb(false, "the start was cancelled")
      return
    end
    if choice ~= accept then
      self:finish()
      cb(false, "cancelled")
      return
    end
    local summary = self:summary(session)
    if self.deps.open then
      pcall(self.deps.open)
    end
    if not self.deps.new_session then
      self:finish()
      self:notify("cannot open a replacement session here", vim.log.levels.WARN)
      cb(false, "cannot open a session here")
      return
    end
    self.deps.new_session({
      on_created = function(created)
        vim.schedule(function()
          if not self:alive(generation) then
            return
          end
          -- A terminal login during `session/new` restarts the agent: use the
          -- replacement's own instance, not the one captured before it.
          local owner = (type(created) == "table" and created.instance) or instance
          self:handover(workflow, created, owner, cwd, generation, summary, cb)
        end)
      end,
      on_failed = function(message)
        vim.schedule(function()
          if not self:alive(generation) then
            return
          end
          self:finish()
          self:notify("cannot open the replacement session: " .. tostring(message), vim.log.levels.WARN)
          cb(false, message)
        end)
      end,
    })
  end)
end

---A plain-text digest of the last exchanges, for the replacement session.
---@param session table
---@return string
function Flow:summary(session)
  local parts = {}
  for index = #(session.blocks or {}), 1, -1 do
    local block = session.blocks[index]
    if type(block) == "table" and type(block.text) == "string" and block.text ~= "" then
      if block.kind == "user" or block.kind == "agent" or block.kind == "assistant" then
        local text = vim.trim(block.text)
        if #text > 1200 then
          text = text:sub(1, 1200) .. "…"
        end
        local who = block.kind == "user" and "person: " or "assistant: "
        parts[#parts + 1] = who .. text
      end
      if #parts >= 12 then
        break
      end
    end
  end
  local out = {}
  for index = #parts, 1, -1 do
    out[#out + 1] = parts[index]
  end
  if #out == 0 then
    return "（上一会话没有可交接的对话）"
  end
  return "交接摘要（来自上一会话）:\n" .. table.concat(out, "\n\n")
end

---Continue in the replacement session: enable its teams, send the summary
---there, ask the task and start.
---@param workflow table
---@param session table the new session object from `new_session`'s callback
---@param instance string
---@param cwd string
---@param generation integer
---@param summary string|nil
---@param cb fun(ok: boolean, err: any)|nil
function Flow:handover(workflow, session, instance, cwd, generation, summary, cb)
  cb = cb or function() end
  local team = self:team()
  if not team or not session then
    cb(false, "no session to hand over to")
    return
  end
  self:enable_tools(session, instance, function(ok, err)
    if not ok then
      self:finish()
      self:notify("cannot enable teams in the new session: " .. self.deps.report_error(err), vim.log.levels.WARN)
      cb(false, err)
      return
    end
    if summary and summary ~= "" and self.deps.submit then
      -- Always addressed to the replacement session: the person may have
      -- switched elsewhere while the switch RPC was in flight.
      pcall(self.deps.submit, summary, session)
    end
    -- A login during `session/new` restarts the agent: the model write at the
    -- end of the start must use the replacement's current client, not the one
    -- captured before the restart.
    local client = self.deps.client and self.deps.client() or nil
    self.target = { session = session, client = client }
    self:ask_task(workflow, session, instance, cwd, generation)
    cb(true, nil)
  end, { workflow = workflow, cwd = cwd, generation = generation, replacement = true })
end

---Ask for the task, then start the workflow on this session.
---@param workflow table
---@param session table
---@param instance string
---@param cwd string
---@param generation integer
function Flow:ask_task(workflow, session, instance, cwd, generation)
  vim.ui.input({ prompt = "task for " .. tostring(workflow.name) .. " (optional): " }, function(task)
    if not self:alive(generation) then
      return
    end
    if task == nil then
      self:finish()
      return
    end
    if task == "" then
      task = nil
    end
    self:launch(workflow, session, instance, cwd, generation, task, false)
  end)
end

---@param workflow table
---@param session table
---@param instance string
---@param cwd string
---@param generation integer
---@param task string|nil
---@param retried boolean
function Flow:launch(workflow, session, instance, cwd, generation, task, retried)
  self:team():start_session(instance, session.id, workflow.name, task, function(ok, value)
    vim.schedule(function()
      if not self:alive(generation) then
        return
      end
      if ok then
        self:apply_leader_model(workflow, session, self.target and self.target.client or nil)
        self:finish()
        if self.deps.open_team then
          pcall(self.deps.open_team)
        else
          pcall(self.deps.open)
        end
        return
      end
      local data = type(value) == "table" and type(value.data) == "table" and value.data or {}
      if data.reason == "led_by" then
        self:offer_handover(value, workflow, session, instance, cwd, generation, task)
        return
      end
      if (data.reason == "off" or data.reason == "no_tools") and not retried then
        -- Same enable -> reload -> continue path as the pre-check: the service
        -- may answer `reload: true`, and a plain retry would come back
        -- `no_tools` again.
        self:enable_tools(session, instance, function(ok2, err2, handled)
          if handled then
            return
          end
          if ok2 then
            self:launch(workflow, session, instance, cwd, generation, task, true)
            return
          end
          self:finish()
          self:notify(
            "cannot start " .. tostring(workflow.name) .. ": " .. self.deps.report_error(err2),
            vim.log.levels.WARN
          )
        end, { workflow = workflow, cwd = cwd, generation = generation })
        return
      end
      self:finish()
      self:notify(
        "cannot start " .. tostring(workflow.name) .. ": " .. self.deps.report_error(value),
        vim.log.levels.WARN
      )
    end)
  end)
end

---Another chat leads this cwd's team: jump there, move the team here, or stop.
---@param value any the `-32061` error
---@param workflow table
---@param session table
---@param instance string
---@param cwd string
---@param generation integer
---@param task string|nil
function Flow:offer_handover(value, workflow, session, instance, cwd, generation, task)
  local data = type(value) == "table" and type(value.data) == "table" and value.data or {}
  local leader = type(data.leader) == "table" and data.leader or {}
  local team_id = type(data.team) == "table" and data.team.id or data.team
  local choices = self:choices()
  local function choose(choice)
    if not self:alive(generation) then
      return
    end
    if choice == "jump" then
      local target = self.deps.find_session and self.deps.find_session(leader.sessionId) or nil
      if target and self.deps.select_session then
        self.deps.select_session(target)
        self:finish()
      else
        self:notify("the leader session is not open in this front end", vim.log.levels.WARN)
        self:finish()
      end
      return
    end
    if choice == "move" then
      if not team_id then
        self:finish()
        self:notify("the service did not name the team to take over", vim.log.levels.WARN)
        return
      end
      self:team():set_leader(team_id, instance, session.id, function(ok, err)
        vim.schedule(function()
          if not self:alive(generation) then
            return
          end
          if not ok then
            self:finish()
            self:notify("cannot take the team over: " .. self.deps.report_error(err), vim.log.levels.WARN)
            return
          end
          self:launch(workflow, session, instance, cwd, generation, task, true)
        end)
      end)
      return
    end
    self:finish()
  end
  if choices and type(choices.ask) == "function" then
    choices:ask({
      title = "团队已有 leader",
      question = "这个项目已有团队，leader 是会话 "
        .. tostring(leader.sessionId or "?")
        .. "。要跳到那里，还是把团队移交到本会话？",
      options = {
        { label = "跳到 leader 会话", value = "jump" },
        { label = "移交到本会话", value = "move" },
        { label = "取消", value = "cancel" },
      },
      on_choice = choose,
    })
    return
  end
  vim.ui.select({ "跳到 leader 会话", "移交到本会话", "取消" }, {
    prompt = "团队已有 leader",
    format_item = function(item)
      return item
    end,
  }, function(item)
    choose(item == "跳到 leader 会话" and "jump" or (item == "移交到本会话" and "move" or "cancel"))
  end)
end

---Switch the leader's model when the workflow asks for one (2.6).
---
---Acts on the session the workflow was started in, with the client that served
---that request: a slow reply must not retarget a chat the person switched to.
---@param workflow table
---@param session table|nil the start target
---@param client table|nil
function Flow:apply_leader_model(workflow, session, client)
  local leader = type(workflow.leader) == "table" and workflow.leader or {}
  local model = type(leader.model) == "string" and leader.model ~= "" and leader.model or nil
  if not model then
    return
  end
  session = session or (self.target and self.target.session)
  client = client or (self.target and self.target.client)
  if not session then
    return
  end
  -- Resolve the canonical object first: after a reload the original is a stale
  -- projection, and its controls may not list the model the new one offers.
  local target = session
  if self.deps.canonical_session then
    target = self.deps.canonical_session(session.instance, session.id) or nil
    if not target then
      self:notify(
        "could not switch the leader model to " .. model .. ": the started session is no longer available",
        vim.log.levels.WARN
      )
      return
    end
  end
  if not target.controls and type(target.refresh_controls) == "function" then
    target:refresh_controls()
  end
  local control = target.controls and target.controls.model or nil
  local offered = false
  for _, entry in ipairs(control and control.options or {}) do
    if entry.value == model then
      offered = true
      break
    end
  end
  if not offered then
    self:notify(
      "the workflow wants leader model " .. model .. ", but this agent does not offer it",
      vim.log.levels.WARN
    )
    return
  end
  local options = self.deps.options and self.deps.options() or nil
  if not options or client == nil or type(options.set_for) ~= "function" then
    return
  end
  local generation = self.deps.generation and self.deps.generation() or 0
  options:set_for(control, model, client, generation, target, function(ok, err)
    vim.schedule(function()
      if ok then
        self:notify("leader model switched to " .. model, vim.log.levels.INFO)
      else
        self:notify(
          "could not switch the leader model to " .. model .. ": " .. self.deps.report_error(err),
          vim.log.levels.WARN
        )
      end
    end)
  end)
end

M.Flow = Flow

return M
