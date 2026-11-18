-- Member rows for the unified team dashboard (v2: roles and fixed width).
local Board = require("ade.ui.team.board")
local Roles = require("ade.ui.team.roles")
local one_line = require("ade.ui.team.text").one_line

local M = {}

local ICONS = {
  working = "●",
  idle = "○",
  waiting_human = "?",
  exited = "✕",
}

local LABELS = {
  working = "工作中",
  idle = "空闲",
  waiting_human = "等你回答",
  exited = "退出",
}

---@param ms integer|nil
---@return string
function M.duration(ms)
  ms = tonumber(ms) or 0
  local now = os.time() * 1000
  local seconds = math.max(0, math.floor((now - ms) / 1000))
  if seconds < 60 then
    return "0:" .. string.format("%02d", seconds)
  end
  if seconds < 3600 then
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
  end
  return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

---@param entry table
---@return string
function M.state_icon(entry)
  local icon = ICONS[entry.state] or "○"
  if entry.paused and entry.state ~= "exited" then
    icon = "⏸"
  end
  return icon
end

---@param entry table
---@return string
function M.state_label(entry)
  local label = LABELS[entry.state] or tostring(entry.state or "?")
  if entry.paused then
    label = "暂停(paused) · " .. label
  end
  return label
end

local function role_text(entry)
  local label = Roles.label(entry)
  local agent = entry.agent and one_line(entry.agent) or ""
  local model = Roles.short_model(entry.model)
  local who = agent
  if model ~= "" then
    who = who ~= "" and (who .. "/" .. model) or model
  end
  if who == "" then
    return label
  end
  return string.format("%s %s", label, who)
end

---Shorten the role cell so state and task always survive on a narrow pane.
---@param head string
---@param role string
---@param tail string
---@param width integer
---@return string
local function join_row(head, role, tail, width)
  local budget = width - Board.display_width(head) - Board.display_width(tail)
  if tail ~= "" then
    budget = budget - 2
  end
  if budget < 8 then
    return Board.truncate(head .. tail, width)
  end
  local shown = Board.truncate(role, budget)
  local gap = tail ~= "" and "  " or ""
  return head .. shown .. gap .. tail
end

local function member_line(entry, width, messages)
  local head = string.format("▌%s  %s  ", Roles.symbol(entry), one_line(entry.name))
  local role = role_text(entry)
  local state
  if entry.paused then
    state = string.format("%s paused %s", M.state_icon(entry), M.duration(entry.state_since))
  else
    state = string.format("%s %s", M.state_icon(entry), M.duration(entry.state_since))
  end
  local task = entry.task and entry.task ~= "_" and one_line(entry.task) or ""
  local parts = { state }
  if task ~= "" then
    parts[#parts + 1] = task
  end
  if (tonumber(messages) or 0) > 0 then
    parts[#parts + 1] = "✉ " .. tostring(messages)
  end
  return Board.truncate(join_row(head, role, table.concat(parts, "  "), width), width)
end

---@param entry table
---@param limits table|nil
---@param width integer|nil
---@param messages integer|nil
---@return string[] lines, table[] marks
function M.entry_lines(entry, limits, width, messages)
  width = math.max(16, tonumber(width) or 32)
  local lines = { member_line(entry, width, messages) }
  local marks = {
    { line = 1, start = 0, stop = 1, group = Roles.hl(entry) },
    { line = 1, start = 1, stop = 2, group = Roles.hl(entry) },
  }
  local activity = entry.activity and entry.activity.text
  if type(activity) == "string" and activity ~= "" then
    lines[#lines + 1] = Board.truncate("▌   ↳ " .. one_line(activity), width)
    marks[#marks + 1] = { line = #lines, start = 0, stop = 1, group = Roles.hl(entry) }
  end
  local worktree = entry.worktree
  if type(worktree) == "table" and worktree.branch then
    lines[#lines + 1] = Board.truncate("▌   wt " .. one_line(worktree.branch), width)
    marks[#marks + 1] = { line = #lines, start = 0, stop = 1, group = Roles.hl(entry) }
  end
  return lines, marks
end

---Build all member rows for one team.
---@param team table
---@param width integer|nil
---@param opts {messages: table<string, integer>|nil, max_workers: integer|nil}|nil
---@return string[] lines, table<integer, table> ids, table<integer, table> meta, table[] marks
function M.lines(team, width, opts)
  opts = opts or {}
  width = math.max(16, tonumber(width) or 32)
  local lines, ids, meta, marks = {}, {}, {}, {}
  local participants = {}
  for _, entry in ipairs(team.participants or {}) do
    if entry.name == "leader" then
      table.insert(participants, 1, entry)
    else
      participants[#participants + 1] = entry
    end
  end
  local saw_leader = false
  for _, entry in ipairs(participants) do
    if entry.name == "leader" then
      saw_leader = true
    elseif saw_leader then
      local label = " workers "
      local line = string.rep("─", math.max(2, math.floor((width - #label) / 2))) .. label
      line = line .. string.rep("─", math.max(0, width - Board.display_width(line)))
      lines[#lines + 1] = line
      meta[#lines] = { kind = "separator", team = team.id }
      saw_leader = false
    end
    local rows, row_marks = M.entry_lines(entry, team.limits, width, (opts.messages or {})[entry.name])
    for index, text in ipairs(rows) do
      lines[#lines + 1] = text
      if index == 1 then
        ids[#lines] = team.id .. "|" .. tostring(entry.name)
        meta[#lines] = { kind = "participant", team = team.id, name = entry.name }
      else
        meta[#lines] = { kind = "participant_detail", team = team.id, name = entry.name }
      end
    end
    for _, mark in ipairs(row_marks) do
      marks[#marks + 1] = {
        line = #lines - #rows + mark.line,
        start = mark.start,
        stop = mark.stop,
        group = mark.group,
      }
    end
  end
  return lines, ids, meta, marks
end

M.ICONS = ICONS
return M
