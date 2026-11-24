-- `:Ade team start`: start a named workflow on behalf of the person
-- (PROTOCOL.md 19.7, docs/w0-team-dashboard-draft.md 2.7).
--
-- The steps are the ones the draft fixes: pick a workflow, make sure its leader
-- session exists (the service only injects the leader MCP server while a
-- session is created), confirm the extras the workflow asks for, ask for the
-- task, let the service start the members and open the panel.
--
-- Everything that touches the editor is injected by the controller, so the
-- flow can be driven by tests with fake pickers and a fake team module.
--
-- A flow is identified by a generation: starting again, cancelling, timing out
-- or a team closing invalidates every pending continuation of the old flow, so
-- a stale `team.changed`/`team.board` callback can never drive a new start.
local M = {}

local Flow = {}
Flow.__index = Flow

---How long a continuation waits for the leader session or a team to close.
---Tests shorten it through `deps.timeout` or this field.
M.wait_timeout_ms = 20000

---cwd -> true while a start flow runs for it. Module level on purpose: the
---controller (and its Team/flow objects) is rebuilt when the leader agent is
---switched, but the start keeps running across that rebuild.
local active = {}

---cwd -> {flow, generation} for the flow that owns a start right now. Module
---level for the same reason as `active`: `pick_agent` rebuilds the controller
---(and TeamCommands and its Flow), and the new modules must still be able to
---cancel the flow the old ones started.
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
---  resolve_cwd: fun(): string, open: fun(), new_session: fun(), connect: fun(),
---  pick_agent: fun(name: string)|nil, options: fun(): table|nil,
---  client: fun(): table|nil, generation: fun(): integer|nil,
---  report_error: fun(value: any)}
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

function Flow:available()
  local cfg = self:config()
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  if teams.spawn_from_chat == false or cfg.backend == "direct" then
    return false
  end
  local team = self:team()
  return team ~= nil and team:available()
end

---Whether teams exist but the built-in template cannot start right now.
---
---Only a zero-config editor is reported here: with explicit templates the
---service answers per template when a start needs one (`unknown template x`),
---and a workflow with no members does not need any. Without `teams.templates`
---the worker template is derived from the leader's own launch, so a broken
---launch would otherwise surface only as a timeout waiting for the leader;
---`:Ade team start` is an explicit request and says what is wrong instead.
---@param cwd string
---@return string|nil problem
function Flow:template_problem(cwd)
  local cfg = self:config()
  local teams = type(cfg.teams) == "table" and cfg.teams or {}
  if next(teams.templates or {}) ~= nil then
    return nil
  end
  local team = self:team()
  if not team or type(team.has_usable_templates) ~= "function" then
    return nil
  end
  local ok, usable = pcall(team.has_usable_templates, team, cwd)
  if not ok or usable then
    return nil
  end
  local detail
  if type(team.template_error) == "function" then
    local got, message = pcall(team.template_error, team, cwd)
    if got and type(message) == "string" and message ~= "" then
      detail = message
    end
  end
  return "cannot start a team: the built-in worker template cannot be started"
    .. (detail and (": " .. detail) or " (fix the leader agent's launch or configure teams.templates)")
end

---The team the service owns for this cwd, in any state but closed.
---@param cwd string
---@return table|nil
function Flow:team_for_cwd(cwd)
  local team = self:team()
  if not team then
    return nil
  end
  for _, entry in ipairs(team:list_rows()) do
    if entry.cwd == cwd and entry.state ~= "closed" then
      return entry
    end
  end
  return nil
end

---@param team table|nil
---@return string[]
function Flow:workers_of(team)
  local names = {}
  for _, participant in ipairs(type(team) == "table" and team.participants or {}) do
    if participant.name ~= "leader" and participant.name ~= "human" then
      names[#names + 1] = tostring(participant.name)
    end
  end
  return names
end

---End the flow: clear `starting`, release the cwd and invalidate every
---continuation. Safe to call more than once.
function Flow:finish()
  self.starting = false
  local cwd = self.cwd
  self.cwd = nil
  if not cwd then
    return
  end
  local state = running[cwd]
  -- Compare against the registration, not the live counter: `cancel` bumps the
  -- generation before finishing, and a newer start on this same object must
  -- not be cleared by the older registration's finish.
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

---Poll until `predicate` holds, without blocking the editor and while staying
---cancellable. A callback rather than `vim.wait`: the flow runs from command
---callbacks and socket notifications, and `vim.wait` cannot be nested.
---@param predicate fun(): boolean
---@param label string
---@param done fun(ok: boolean)
function Flow:wait_for(predicate, label, done)
  local generation = self.generation
  local timeout = M.wait_timeout_ms
  if type(self.deps.timeout) == "function" then
    local ok, value = pcall(self.deps.timeout)
    if ok and type(value) == "number" and value >= 0 then
      timeout = value
    end
  end
  local deadline = vim.uv.now() + timeout
  local function check()
    if not self:alive(generation) then
      return
    end
    if predicate() then
      done(true)
      return
    end
    if vim.uv.now() >= deadline then
      self:notify("timed out waiting for " .. tostring(label), vim.log.levels.WARN)
      self:finish()
      done(false)
      return
    end
    vim.defer_fn(check, 50)
  end
  check()
end

---Entry point. `name` is a workflow name, or nil to pick one.
---@param name string|nil
function Flow:start(name)
  local cwd = self:cwd()
  -- Check first: a switch flow waits for the rebuilt Team to reconnect, and an
  -- extra start while that Team is not available yet must not kill it.
  if not self:available() then
    self:notify("teams are not available: connect to the service and configure a template", vim.log.levels.WARN)
    return
  end
  local problem = self:template_problem(cwd)
  if problem then
    -- An explicit request must name the concrete failure instead of waiting for
    -- a leader that will never create a team. An already running flow is left
    -- alone: this request never took over, so it cannot end the other one.
    self:notify(problem, vim.log.levels.WARN)
    return
  end
  local previous = running[cwd]
  if previous then
    -- Starting again replaces the old flow instead of leaving it wedged; the
    -- old flow may belong to a controller that `pick_agent` rebuilt.
    previous.flow:cancel()
  end
  self.generation = (self.generation or 0) + 1
  local generation = self.generation
  self.starting = true
  self.cwd = cwd
  self.registered_generation = generation
  active[cwd] = true
  running[cwd] = { flow = self, generation = generation }
  local team = self:team()
  team:workflows(cwd, function(ok, value)
    -- The callback runs in the socket's fast event context; the steps below
    -- prompt and poll, which is only legal on the main loop.
    vim.schedule(function()
      if not self:alive(generation) then
        return
      end
      self:on_workflows(ok, value, name, cwd, generation)
    end)
  end)
end

---Continue `start` once the workflow list is known.
---@param ok boolean
---@param value any
---@param name string|nil
---@param cwd string
---@param generation integer
function Flow:on_workflows(ok, value, name, cwd, generation)
  if not ok then
    self:finish()
    self:notify("cannot list workflows: " .. self.deps.report_error(value), vim.log.levels.WARN)
    return
  end
  local workflows = type(value) == "table" and type(value.workflows) == "table" and value.workflows or {}
  if #workflows == 0 then
    self:finish()
    self:notify("no workflows are configured", vim.log.levels.WARN)
    return
  end
  if name == nil or name == "" then
    self:pick(workflows, generation, function(workflow)
      if not self:alive(generation) then
        return
      end
      if workflow then
        self:with_workflow(workflow, cwd, generation)
      else
        self:finish()
      end
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
  self:with_workflow(workflow, cwd, generation)
end

---@param workflows table[]
---@param generation integer
---@param on_choice fun(workflow: table|nil)
function Flow:pick(workflows, generation, on_choice)
  local items = {}
  local by_name = {}
  for _, workflow in ipairs(workflows) do
    local label = string.format("%-16s %s", tostring(workflow.name), tostring(workflow.summary or ""))
    if workflow.scope and workflow.scope ~= "builtin" then
      label = label .. "  [" .. tostring(workflow.scope) .. "]"
    end
    items[#items + 1] = label
    by_name[label] = workflow
  end
  vim.ui.select(items, {
    prompt = "workflow",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not self:alive(generation) then
      return
    end
    on_choice(choice and by_name[choice] or nil)
  end)
end

---Continue once a workflow is known: leader agent, existing team, task.
---@param workflow table
---@param cwd string
---@param generation integer
function Flow:with_workflow(workflow, cwd, generation)
  local leader = type(workflow.leader) == "table" and workflow.leader or {}
  local wanted = type(leader.agent) == "string" and leader.agent ~= "" and leader.agent or nil
  local entry = self:team_for_cwd(cwd)
  local current_agent = self:config().agent
  if wanted and wanted ~= current_agent then
    local team = self:team()
    local blocked = team and team.blocked or {}
    local why
    if entry then
      if blocked[cwd] then
        why = "another session leads this team; close it there first"
      elseif entry.state == "suspended" then
        why = "the team is suspended; resume it with its leader session first"
      elseif entry.stale then
        why = "the connection to the service is lost; wait for it to reconnect"
      end
    end
    if why then
      -- Switching would close a team this front end does not lead; refuse
      -- before promising an option that cannot be carried out.
      self:finish()
      self:notify(why, vim.log.levels.WARN)
      return
    end
    local switch = "open a " .. wanted .. " session as the leader"
    if entry then
      switch = switch .. " (ends the current team)"
    end
    local ignore = "ignore it and use the current leader"
    vim.ui.select({ switch, ignore }, {
      prompt = "the workflow wants a " .. wanted .. " leader; this is " .. tostring(current_agent or "?"),
      format_item = function(item)
        return item
      end,
    }, function(choice)
      if not self:alive(generation) then
        return
      end
      if choice == nil then
        self:finish()
        return
      end
      if choice == ignore then
        self:proceed(workflow, cwd, generation)
        return
      end
      -- Ask for the task before closing/switching: cancelling the input must
      -- leave the running team (and the current agent) untouched.
      self:ask_task(workflow, cwd, generation, {
        switch_agent = wanted,
        team = entry and entry.id or nil,
      })
    end)
    return
  end
  self:proceed(workflow, cwd, generation)
end

---Ask about an existing team with workers, then continue.
---@param workflow table
---@param cwd string
---@param generation integer
function Flow:proceed(workflow, cwd, generation)
  local entry = self:team_for_cwd(cwd)
  local workers = self:workers_of(entry)
  if #workers == 0 then
    self:ask_task(workflow, cwd, generation, nil)
    return
  end
  local restart = "close the team and start over"
  local append = "start only the missing members"
  local cancel = "cancel"
  vim.ui.select({ restart, append, cancel }, {
    prompt = "team already runs " .. table.concat(workers, ", "),
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not self:alive(generation) then
      return
    end
    if choice == nil or choice == cancel then
      self:finish()
      return
    end
    if choice == restart then
      -- Ask for the task first: cancelling the input must leave the running
      -- team untouched.
      self:ask_task(workflow, cwd, generation, { restart = true, team = entry.id })
      return
    end
    self:ask_task(workflow, cwd, generation, nil)
  end)
end

---Close `team_id` and continue, treating a team that disappeared while the
---task prompt was open as already closed.
---@param team_id string
---@param cwd string
---@param generation integer
---@param on_closed fun()
function Flow:close_team(team_id, cwd, generation, on_closed)
  local entry = self:team_for_cwd(cwd)
  if not entry or entry.id ~= team_id then
    on_closed()
    return
  end
  self:team():close(team_id, function(ok, value)
    vim.schedule(function()
      if not self:alive(generation) then
        return
      end
      -- -32064: the team was closed from somewhere else in the meantime.
      local gone = type(value) == "table" and value.code == -32064
      if not ok and not gone then
        self:finish()
        self:notify("cannot end the current team: " .. self.deps.report_error(value), vim.log.levels.WARN)
        return
      end
      local team = self:team()
      if type(team.forget_team) == "function" and (ok or gone) then
        team:forget_team(team_id)
      end
      self:wait_for(
        function()
          local now = self:team_for_cwd(cwd)
          return now == nil or now.id ~= team_id
        end,
        "the old team to close",
        function(closed)
          if closed and self:alive(generation) then
            on_closed()
          end
        end
      )
    end)
  end)
end

---Close the current team (if any), switch the leader agent, open a new
---session and start the workflow there.
---@param workflow table
---@param cwd string
---@param generation integer
---@param agent string
---@param team_id string|nil
---@param task string|nil
function Flow:switch_and_launch(workflow, cwd, generation, agent, team_id, task)
  local function switch()
    if not self:alive(generation) then
      return
    end
    if self.deps.pick_agent then
      pcall(self.deps.pick_agent, agent)
    end
    if not self:alive(generation) then
      return
    end
    if self:config().agent ~= agent then
      -- pick_agent refused (unknown agent, or the setup failed): do not go on
      -- with a leader the person did not choose.
      self:finish()
      self:notify("cannot switch the leader agent to " .. tostring(agent), vim.log.levels.WARN)
      return
    end
    pcall(self.deps.open)
    pcall(self.deps.new_session)
    self:wait_for_leader(cwd, team_id, generation, function(ok)
      if ok then
        self:launch(workflow, cwd, task, generation)
      end
    end)
  end
  if not team_id then
    switch()
    return
  end
  self:close_team(team_id, cwd, generation, switch)
end

---Make sure the session that is about to lead exists and has bound its team.
---Never switches the agent: that decision was made (or declined) already.
---@param cwd string
---@param team_id string|nil the team being replaced, must not be accepted
---@param generation integer
---@param done fun()
function Flow:ensure_session(cwd, team_id, generation, done)
  local team = self:team()
  local entry = self:team_for_cwd(cwd)
  if entry then
    local blocked = (team and team.blocked) or {}
    if blocked[cwd] then
      self:finish()
      self:notify("another session leads this team; close it there first", vim.log.levels.WARN)
      return
    end
    if entry.state == "suspended" then
      self:finish()
      self:notify("the team is suspended; resume it with its leader session first", vim.log.levels.WARN)
      return
    end
    if entry.stale then
      self:finish()
      self:notify("the connection to the service is lost; wait for it to reconnect", vim.log.levels.WARN)
      return
    end
    local bound = team and team.bound and team.bound[cwd] or nil
    if bound and bound.team == entry.id then
      done()
      return
    end
    if not bound then
      -- `team.changed` can arrive a few milliseconds before the bind reply;
      -- wait for the binding instead of claiming this session is not the
      -- leader.
      self:wait_for_leader(cwd, nil, generation, function(ok)
        if ok then
          done()
        end
      end)
      return
    end
    self:finish()
    self:notify("this session is not the leader of the team for this cwd", vim.log.levels.WARN)
    return
  end
  pcall(self.deps.open)
  local S = self.deps.state()
  if not (S and S.sess and S.sess.current) then
    pcall(self.deps.connect)
  end
  -- A session without a team cannot become a leader: the MCP server is only
  -- injected while a session is created (18.2/19.8), so start a new one.
  pcall(self.deps.new_session)
  self:wait_for_leader(cwd, team_id, generation, function(ok)
    if ok then
      done()
    end
  end)
end

---Wait until the service reports a team for this cwd, not `except_id`.
---@param cwd string
---@param except_id string|nil
---@param generation integer
---@param done fun(ok: boolean)
function Flow:wait_for_leader(cwd, except_id, generation, done)
  self:wait_for(
    function()
      local entry = self:team_for_cwd(cwd)
      if not entry or (except_id and entry.id == except_id) then
        return false
      end
      local team = self:team()
      local bound = team and team.bound[cwd] or nil
      return bound ~= nil and bound.team == entry.id
    end,
    "the leader session",
    function(ok)
      if not self:alive(generation) then
        return
      end
      done(ok)
    end
  )
end

---Ask for the task, then start (or restart) the workflow.
---@param workflow table
---@param cwd string
---@param generation integer
---@param restart {restart: boolean, team: string}|nil
function Flow:ask_task(workflow, cwd, generation, restart)
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
    if restart and restart.switch_agent then
      self:switch_and_launch(workflow, cwd, generation, restart.switch_agent, restart.team, task)
      return
    end
    if restart then
      self:close_and_relaunch(workflow, cwd, generation, restart.team, task)
      return
    end
    self:ensure_session(cwd, nil, generation, function()
      if self:alive(generation) then
        self:launch(workflow, cwd, task, generation)
      end
    end)
  end)
end

---Close `team_id` and continue on the team the new session creates.
---@param workflow table
---@param cwd string
---@param generation integer
---@param team_id string
---@param task string|nil
function Flow:close_and_relaunch(workflow, cwd, generation, team_id, task)
  -- The close reply may arrive before `team.changed(closed)`, so close_team
  -- waits until the old team is really gone instead of trusting list order.
  self:close_team(team_id, cwd, generation, function()
    self:ensure_session(cwd, team_id, generation, function()
      if self:alive(generation) then
        self:launch(workflow, cwd, task, generation)
      end
    end)
  end)
end

---@param workflow table
---@param cwd string
---@param task string|nil
---@param generation integer
function Flow:launch(workflow, cwd, task, generation)
  local entry = self:team_for_cwd(cwd)
  if not entry then
    self:finish()
    self:notify("no team took the workflow: is the leader session connected?", vim.log.levels.WARN)
    return
  end
  self:team():start(entry.id, workflow.name, task, function(ok, value)
    if not self:alive(generation) then
      return
    end
    if not ok then
      self:finish()
      self:notify(
        "cannot start " .. tostring(workflow.name) .. ": " .. self.deps.report_error(value),
        vim.log.levels.WARN
      )
      return
    end
    self:apply_leader_model(workflow)
    self:finish()
    if self.deps.open_team then
      pcall(self.deps.open_team)
    else
      pcall(self.deps.open)
    end
  end)
end

---Switch the leader's model when the workflow asks for one (2.6).
---@param workflow table
function Flow:apply_leader_model(workflow)
  local leader = type(workflow.leader) == "table" and workflow.leader or {}
  local model = type(leader.model) == "string" and leader.model ~= "" and leader.model or nil
  if not model then
    return
  end
  local S = self.deps.state()
  local session = S and S.sess and S.sess.current or nil
  if not session then
    return
  end
  if not session.controls then
    session:refresh_controls()
  end
  local control = session.controls and session.controls.model or nil
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
  if not options or type(options.apply) ~= "function" then
    return
  end
  local client = self.deps.client and self.deps.client() or nil
  local generation = self.deps.generation and self.deps.generation() or 0
  options:apply(control, model, client, generation, session)
  self:notify("leader model switched to " .. model, vim.log.levels.INFO)
end

M.Flow = Flow

return M
