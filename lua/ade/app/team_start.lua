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
local M = {}

local Flow = {}
Flow.__index = Flow

---@param deps {state: fun(): table, config: fun(): table, notify: fun(message: string, level: integer|nil),
---  resolve_cwd: fun(): string, open: fun(), new_session: fun(), connect: fun(),
---  pick_agent: fun(name: string)|nil, options: fun(): table|nil,
---  client: fun(): table|nil, generation: fun(): integer|nil,
---  report_error: fun(value: any)}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps, starting = false }, Flow)
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

---Poll until `predicate` holds, without blocking the editor.
---
---A callback rather than `vim.wait`: the flow runs from command callbacks and
---socket notifications, and `vim.wait` cannot be nested inside another one.
---@param predicate fun(): boolean
---@param label string
---@param done fun(ok: boolean)
function Flow:wait_for(predicate, label, done)
  local deadline = vim.uv.now() + 20000
  local function check()
    if predicate() then
      done(true)
      return
    end
    if vim.uv.now() >= deadline then
      self:notify("timed out waiting for " .. tostring(label), vim.log.levels.WARN)
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
  if self.starting then
    self:notify("a team start is already in progress", vim.log.levels.WARN)
    return
  end
  if not self:available() then
    self:notify("teams are not available: connect to the service and configure a template", vim.log.levels.WARN)
    return
  end
  self.starting = true
  local cwd = self:cwd()
  local team = self:team()
  team:workflows(cwd, function(ok, value)
    -- The callback runs in the socket's fast event context; the steps below
    -- prompt and wait, which is only legal on the main loop.
    vim.schedule(function()
      if self.starting == false then
        return
      end
      self:on_workflows(ok, value, name, cwd)
    end)
  end)
end

---Continue `start` once the workflow list is known.
---@param ok boolean
---@param value any
---@param name string|nil
---@param cwd string
function Flow:on_workflows(ok, value, name, cwd)
  if not ok then
    self.starting = false
    self:notify("cannot list workflows: " .. self.deps.report_error(value), vim.log.levels.WARN)
    return
  end
  local workflows = type(value) == "table" and type(value.workflows) == "table" and value.workflows or {}
  if #workflows == 0 then
    self.starting = false
    self:notify("no workflows are configured", vim.log.levels.WARN)
    return
  end
  if name == nil or name == "" then
    self:pick(workflows, function(workflow)
      if workflow then
        self:with_workflow(workflow, cwd)
      else
        self.starting = false
      end
    end)
  else
    local workflow
    for _, entry in ipairs(workflows) do
      if entry.name == name then
        workflow = entry
        break
      end
    end
    if not workflow then
      self.starting = false
      self:notify("unknown workflow " .. tostring(name), vim.log.levels.WARN)
      return
    end
    self:with_workflow(workflow, cwd)
  end
end

---@param workflows table[]
---@param on_choice fun(workflow: table|nil)
function Flow:pick(workflows, on_choice)
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
    on_choice(choice and by_name[choice] or nil)
  end)
end

---Continue once a workflow is known: leader agent, existing team, task.
---@param workflow table
---@param cwd string
function Flow:with_workflow(workflow, cwd)
  local leader = type(workflow.leader) == "table" and workflow.leader or {}
  local wanted = type(leader.agent) == "string" and leader.agent ~= "" and leader.agent or nil
  local cfg = self:config()
  local current_agent = cfg.agent
  local team = self:team_for_cwd(cwd)
  local workers = self:workers_of(team)
  local function proceed()
    if #workers > 0 then
      -- 2.7: an existing team with workers asks before it is touched.
      local restart = "close the team and start over"
      local append = "start only the missing members"
      local cancel = "cancel"
      vim.ui.select({ restart, append, cancel }, {
        prompt = "team already runs " .. table.concat(workers, ", "),
        format_item = function(item)
          return item
        end,
      }, function(choice)
        if choice == nil or choice == cancel then
          self.starting = false
          return
        end
        if choice == restart then
          self:team():close(team.id, function(ok, value)
            vim.schedule(function()
              if not ok then
                self.starting = false
                self:notify("cannot close the team: " .. self.deps.report_error(value), vim.log.levels.WARN)
                return
              end
              self:ensure_session(wanted, current_agent, function()
                self:ask_task(workflow, cwd, wanted)
              end)
            end)
          end)
          return
        end
        self:ask_task(workflow, cwd, wanted)
      end)
      return
    end
    self:ensure_session(wanted, current_agent, function()
      self:ask_task(workflow, cwd, wanted)
    end)
  end
  if wanted and team and wanted ~= current_agent then
    local switch = "open a " .. wanted .. " session as the leader (ends the current team)"
    local ignore = "ignore it and use the current leader"
    vim.ui.select({ switch, ignore }, {
      prompt = "the workflow wants a " .. wanted .. " leader; this is " .. tostring(current_agent or "?"),
      format_item = function(item)
        return item
      end,
    }, function(choice)
      if choice == nil then
        self.starting = false
        return
      end
      if choice == ignore then
        proceed()
        return
      end
      self:switch_agent(wanted, team, function()
        proceed()
      end)
    end)
    return
  end
  proceed()
end

---Close the team (if needed), switch the leader agent and open a new session.
---@param agent string
---@param team table|nil
---@param done fun()
function Flow:switch_agent(agent, team, done)
  local function switch()
    if self.deps.pick_agent then
      pcall(self.deps.pick_agent, agent)
    end
    pcall(self.deps.open)
    pcall(self.deps.new_session)
    done()
  end
  if team then
    self:team():close(team.id, function(ok, value)
      vim.schedule(function()
        if not ok then
          self.starting = false
          self:notify("cannot end the current team: " .. self.deps.report_error(value), vim.log.levels.WARN)
          return
        end
        switch()
      end)
    end)
    return
  end
  switch()
end

---Make sure the session that is about to lead exists and has bound its team.
---@param wanted_agent string|nil
---@param current_agent string|nil
---@param done fun()
function Flow:ensure_session(wanted_agent, current_agent, done)
  local cwd = self:cwd()
  if self:team_for_cwd(cwd) and self:team().bound[cwd] then
    done()
    return
  end
  if wanted_agent and current_agent and wanted_agent ~= current_agent then
    self:switch_agent(wanted_agent, nil, function()
      self:wait_for_leader(cwd, done)
    end)
    return
  end
  pcall(self.deps.open)
  local S = self.deps.state()
  if not (S and S.sess and S.sess.current) then
    pcall(self.deps.connect)
    pcall(self.deps.new_session)
  else
    -- A session without a team cannot become a leader: the MCP server is only
    -- injected while a session is created (18.2/19.8), so start a new one.
    pcall(self.deps.new_session)
  end
  self:wait_for_leader(cwd, done)
end

---Wait until the service reports a team for this cwd.
---@param cwd string
---@param done fun()
function Flow:wait_for_leader(cwd, done)
  self:wait_for(
    function()
      return self:team_for_cwd(cwd) ~= nil
    end,
    "the leader session",
    function(ok)
      if not ok then
        self.starting = false
        return
      end
      done()
    end
  )
end

---Ask for the task and start the workflow.
---@param workflow table
---@param cwd string
---@param wanted_agent string|nil
function Flow:ask_task(workflow, cwd, wanted_agent)
  vim.ui.input({ prompt = "task for " .. tostring(workflow.name) .. " (optional): " }, function(task)
    if task == nil then
      self.starting = false
      return
    end
    if task == "" then
      task = nil
    end
    self:launch(workflow, cwd, task, wanted_agent)
  end)
end

---@param workflow table
---@param cwd string
---@param task string|nil
---@param wanted_agent string|nil
function Flow:launch(workflow, cwd, task, wanted_agent)
  local entry = self:team_for_cwd(cwd)
  if not entry then
    self.starting = false
    self:notify("no team took the workflow: is the leader session connected?", vim.log.levels.WARN)
    return
  end
  self:team():start(entry.id, workflow.name, task, function(ok, value)
    self.starting = false
    if not ok then
      self:notify(
        "cannot start " .. tostring(workflow.name) .. ": " .. self.deps.report_error(value),
        vim.log.levels.WARN
      )
      return
    end
    self:apply_leader_model(workflow, wanted_agent)
    if self.deps.open_team then
      pcall(self.deps.open_team)
    else
      pcall(self.deps.open)
    end
  end)
end

---Switch the leader's model when the workflow asks for one (2.6).
---@param workflow table
---@param _wanted_agent string|nil
function Flow:apply_leader_model(workflow, _wanted_agent)
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
