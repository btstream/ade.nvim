-- Member rows for the unified team dashboard (W0f).
local Board = require("ade.ui.team.board")

local M = {}

local one_line = require("ade.ui.team.text").one_line

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
    return string.format("%d 分钟", math.floor(seconds / 60))
  end
  return string.format("%d 小时 %d 分", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
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

---Render a participant as three rows.
---@param entry table
---@param limits table|nil
---@param width integer|nil
---@return string[] lines
function M.entry_lines(entry, limits, width)
  width = math.max(40, tonumber(width) or 80)
  local max_task = tonumber(limits and limits.max_turns_per_task) or 30
  local max_total = tonumber(limits and limits.max_turns_total) or 200
  local turns = entry.turns or {}
  local task = entry.task and entry.task ~= "_" and entry.task or "-"
  local queued = tonumber(entry.queued) or 0
  local parts = {
    string.format(
      "%-10s %s %s %s",
      one_line(entry.name),
      M.state_icon(entry),
      M.state_label(entry),
      M.duration(entry.state_since)
    ),
    string.format(
      "task %s · 回合 %s/%s/%s",
      one_line(task),
      tostring(turns.task or 0),
      tostring(max_task),
      tostring(max_total)
    ),
  }
  if queued > 0 then
    parts[#parts + 1] = "队列 " .. tostring(queued)
  end
  local first = table.concat(parts, "  ")
  local lines = { Board.truncate(first, width) }
  local activity = entry.activity and entry.activity.text
  if type(activity) == "string" and activity ~= "" then
    lines[#lines + 1] = Board.truncate("  ↳ " .. one_line(activity), width)
  end
  local worktree = entry.worktree
  if type(worktree) == "table" and worktree.branch then
    lines[#lines + 1] = Board.truncate("  wt " .. one_line(worktree.branch), width)
  end
  if type(worktree) == "table" and worktree.path and not worktree.branch then
    lines[#lines + 1] = Board.truncate("  wt " .. one_line(worktree.path), width)
  end
  return lines
end

---Build all member rows for one team.
---@param team table
---@param width integer|nil
---@return string[] lines, table<integer, table> ids, table<integer, table> meta
function M.lines(team, width)
  local lines, ids, meta = {}, {}, {}
  for _, entry in ipairs(team.participants or {}) do
    local rows = M.entry_lines(entry, team.limits, width)
    for index, text in ipairs(rows) do
      lines[#lines + 1] = text
      if index == 1 then
        ids[#lines] = team.id .. "|" .. tostring(entry.name)
        meta[#lines] = { kind = "participant", team = team.id, name = entry.name }
      else
        meta[#lines] = { kind = "participant_detail", team = team.id, name = entry.name }
      end
    end
  end
  return lines, ids, meta
end

M.ICONS = ICONS
return M
