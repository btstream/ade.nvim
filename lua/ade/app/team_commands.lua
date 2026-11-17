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
  local cwd = self:cwd()
  for _, entry in ipairs(team:list_rows()) do
    if entry.cwd == cwd and entry.state ~= "closed" then
      return entry
    end
  end
  return nil
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
