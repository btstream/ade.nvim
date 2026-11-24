-- The team commands: `:Ade team start [workflow]`, `:Ade team close` and
-- `:Ade workflows` (PROTOCOL.md 19.7, PROTOCOL.md 19.5).
--
-- The controller keeps only the one-line entry points; the flows and the
-- prompts live here so app/team.lua stays the state module and the controller
-- stays a coordinator.
local TeamStart = require("ade.app.team_start")
local Workflows = require("ade.ui.workflows")
local presenter = require("ade.app.presenter")

local M = {}

local Commands = {}
Commands.__index = Commands

---@param deps table the controller wiring context (state, config, notify, ...)
---@return table
function M.new(deps)
  local self = setmetatable({ deps = deps }, Commands)
  self.start_flow = TeamStart.new({
    state = deps.state,
    config = deps.config,
    notify = deps.notify,
    resolve_cwd = deps.resolve_cwd,
    open = deps.open,
    new_session = deps.new_session,
    connect = deps.connect,
    pick_agent = deps.pick_agent,
    options = deps.options,
    client = deps.client,
    generation = deps.generation,
    report_error = deps.report_error,
    open_team = deps.open_team,
    choices = deps.choices,
    find_session = deps.find_session,
    select_session = deps.select_session,
    submit = deps.submit,
  })
  return self
end

function Commands:team()
  local S = self.deps.state()
  return S and S.view and S.view.team or nil
end

---@return string
function Commands:cwd()
  local ok, cwd = pcall(self.deps.resolve_cwd)
  if ok and type(cwd) == "string" and cwd ~= "" then
    return cwd
  end
  local cfg = self.deps.config() or {}
  return cfg.cwd or vim.fn.getcwd()
end

---@param workflow string|nil
function Commands:start(workflow)
  self.start_flow:start(workflow)
end

---The team of this cwd. Never another cwd's team: `:Ade team close` must not
---close something the person cannot see.
---@return table|nil
function Commands:current_team()
  local team = self:team()
  if not team then
    return nil
  end
  return team:team_for_cwd(self:cwd())
end

---The current session and its service instance.
---@return table|nil session
---@return string|nil instance
function Commands:context()
  local S = self.deps.state()
  local session = S and S.sess and S.sess.current or nil
  local client = self.deps.client and self.deps.client() or nil
  local instance = client and client.proc and client.proc.instance or nil
  return session, instance
end

---Turn teams on for the current session (`:Ade team on`).
function Commands:on()
  local team = self:team()
  local session, instance = self:context()
  if not team or not session or not instance then
    self.deps.notify("team on requires an open session", vim.log.levels.WARN)
    return
  end
  team:set_session_teams(instance, session.id, true, false, function(ok, value)
    if not ok then
      self.deps.notify("cannot turn teams on: " .. self.deps.report_error(value), vim.log.levels.WARN)
    else
      self.deps.notify("teams are on for this chat", vim.log.levels.INFO)
    end
  end)
end

---Turn teams off for the current session (`:Ade team off`). A session that
---leads a team is asked first; the team is closed with it.
function Commands:off()
  local team = self:team()
  local session, instance = self:context()
  if not team or not session or not instance then
    self.deps.notify("team off requires an open session", vim.log.levels.WARN)
    return
  end
  local state = team:session_teams(instance, session.id)
  local function apply(close)
    team:set_session_teams(instance, session.id, false, close, function(ok, value)
      if not ok then
        local data = type(value) == "table" and type(value.data) == "table" and value.data or {}
        if data.reason == "leads_team" and not close then
          presenter.confirm("This chat leads a team. Close it too?", function(choice)
            if choice == "yes" then
              apply(true)
            end
          end)
          return
        end
        self.deps.notify("cannot turn teams off: " .. self.deps.report_error(value), vim.log.levels.WARN)
      else
        self.deps.notify("teams are off for this chat", vim.log.levels.INFO)
      end
    end)
  end
  if state and state.leader then
    presenter.confirm(
      "This chat leads team " .. tostring(state.leader.id) .. ". Turn teams off and close it?",
      function(choice)
        if choice == "yes" then
          apply(true)
        end
      end
    )
    return
  end
  apply(false)
end

---Stop one worker of this cwd's team (`:Ade team stop <worker>`); `remove`
---also drops it from the team.
---@param name string|nil
---@param remove boolean|nil
function Commands:stop_worker(name, remove)
  local team = self:team()
  local entry = self:current_team()
  if not team or not entry then
    self.deps.notify("no team for this cwd", vim.log.levels.WARN)
    return
  end
  if not name or name == "" then
    self.deps.notify("usage: :Ade team stop[!] <worker>", vim.log.levels.WARN)
    return
  end
  local known = team:participant(entry.id, name)
  if not known then
    self.deps.notify("no worker named " .. name, vim.log.levels.WARN)
    return
  end
  team:stop_worker(entry.id, name, remove, function(ok, value)
    if not ok then
      self.deps.notify("cannot stop " .. name .. ": " .. self.deps.report_error(value), vim.log.levels.WARN)
      return
    end
    self.deps.notify((remove and "worker " or "stopping worker ") .. name, vim.log.levels.INFO)
  end)
end

---Move this cwd's team leadership to the current session (`:Ade team leader`).
function Commands:leader()
  local team = self:team()
  local entry = self:current_team()
  local session, instance = self:context()
  if not team or not entry or not session or not instance then
    self.deps.notify("no team and session to lead for this cwd", vim.log.levels.WARN)
    return
  end
  if entry.leader and entry.leader.sessionId == session.id and entry.leader.instance == instance then
    self.deps.notify("this chat already leads the team", vim.log.levels.INFO)
    return
  end
  team:set_leader(entry.id, instance, session.id, function(ok, value)
    if not ok then
      self.deps.notify("cannot take the lead: " .. self.deps.report_error(value), vim.log.levels.WARN)
      return
    end
    self.deps.notify("this chat now leads the team", vim.log.levels.INFO)
  end)
end

---Close the team of this cwd after a confirmation.
function Commands:close(cb)
  local team = self:team()
  local entry = self:current_team()
  if not team or not entry then
    self.deps.notify("no team to close for this cwd", vim.log.levels.WARN)
    return
  end
  presenter.confirm(string.format("Close team %s (%s)?", tostring(entry.id), tostring(entry.cwd)), function(choice)
    if choice ~= "yes" then
      return
    end
    -- A running `:Ade team start` would otherwise keep going against a team
    -- that is being closed. Cancel it only now: a refused confirmation must
    -- leave everything as it was, and the flow may belong to a controller
    -- that `pick_agent` rebuilt.
    TeamStart.cancel_for(entry.cwd)
    team:close(entry.id, function(ok, value)
      if not ok then
        self.deps.notify("cannot close the team: " .. self.deps.report_error(value), vim.log.levels.WARN)
      end
      if cb then
        pcall(cb, ok, value)
      end
    end)
  end)
end

---Open the workflows window. Returns whether it started opening.
---@param cb fun(ok: boolean)|nil
---@return boolean
function Commands:workflows(cb)
  local team = self:team()
  if not self.workflows_ui then
    self.workflows_ui = Workflows.new({
      team = function()
        return self:team()
      end,
      config = self.deps.config,
      resolve_cwd = self.deps.resolve_cwd,
      notify = self.deps.notify,
      error_text = self.deps.report_error,
    })
  end
  if not team then
    self.deps.notify("workflows need the service and a configured template", vim.log.levels.WARN)
    return false
  end
  return self.workflows_ui:open(cb)
end

---Refresh an open workflows window after a helper changed something.
function Commands:refresh_workflows()
  if self.workflows_ui and self.workflows_ui:is_open() then
    self.workflows_ui:open()
  end
end

M.Commands = Commands

return M
