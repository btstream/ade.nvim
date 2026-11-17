-- Detail pane contents for the unified dashboard.
local members = require("ade.ui.team.members")
local M = {}

local function one_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " "))
end

local function time_text(ms)
  local value = tonumber(ms)
  if not value or value <= 0 then
    return "?"
  end
  return os.date("%Y-%m-%d %H:%M:%S", math.floor(value / 1000))
end

---@param team table
---@param card table
---@return string[]
function M.card(team, card)
  local owner = card.owner or "-"
  local entry
  if team then
    for _, participant in ipairs(team.participants or {}) do
      if participant.name == owner then
        entry = participant
      end
    end
  end
  local state = entry and string.format("%s %s", members.state_icon(entry), members.state_label(entry)) or "-"
  local lines = {
    "卡片 " .. one_line(card.id) .. " · " .. one_line(card.title),
    string.format(
      "%s · 负责 %s %s · %s 更新于 %s",
      one_line(card.column),
      one_line(owner),
      state,
      one_line(card.updated_by or "?"),
      time_text(card.updated_at)
    ),
  }
  if card.stage and card.stage ~= "" then
    lines[2] = lines[2] .. " · 阶段 " .. one_line(card.stage)
  end
  local fields = {}
  for key, value in pairs(card.fields or {}) do
    fields[#fields + 1] = one_line(key) .. "=" .. one_line(value)
  end
  table.sort(fields)
  if #fields > 0 then
    lines[#lines + 1] = table.concat(fields, " · ")
  end
  lines[#lines + 1] = ""
  for _, line in ipairs(vim.split(card.body or "", "\n", { plain = true })) do
    lines[#lines + 1] = line
  end
  return lines
end

---@param team table
---@param name string
---@param board table|nil
---@return string[]
function M.participant(team, name, board)
  local entry
  for _, participant in ipairs(team and team.participants or {}) do
    if participant.name == name then
      entry = participant
    end
  end
  if not entry then
    return { "成员 " .. tostring(name) .. "（已离开）" }
  end
  local lines = {
    string.format(
      "%s %s %s · task %s · 回合 %s",
      one_line(entry.name),
      members.state_icon(entry),
      members.state_label(entry),
      one_line(entry.task or "-"),
      tostring((entry.turns or {}).task or 0)
    ),
  }
  if entry.activity and entry.activity.text then
    lines[#lines + 1] = "最近动态：" .. one_line(entry.activity.text)
  end
  local worktree = entry.worktree
  if type(worktree) == "table" and worktree.branch then
    lines[#lines + 1] = "worktree " .. one_line(worktree.branch)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "负责的卡片"
  local found = 0
  for _, card in ipairs(board and board.cards or {}) do
    if card.owner == name and not card.archived then
      found = found + 1
      lines[#lines + 1] = "  " .. tostring(card.id) .. " " .. tostring(card.title)
    end
  end
  if found == 0 then
    lines[#lines + 1] = "  （无）"
  end
  return lines
end

---@param item table
---@return string[]
function M.inbox(item)
  local lines = {
    string.format(
      "%s %s · %s · from %s",
      tostring(item.kind),
      tostring(item.id),
      tostring(item.state),
      tostring(item.from)
    ),
    "",
  }
  for _, line in ipairs(vim.split(item.body or "", "\n", { plain = true })) do
    lines[#lines + 1] = line
  end
  if type(item.options) == "table" and #item.options > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "选项：" .. table.concat(vim.tbl_map(tostring, item.options), " / ")
  end
  if item.template then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "模板 %s · 名字 %s · 模型 %s",
      one_line(item.template),
      one_line(item.name or "-"),
      one_line(item.model or "-")
    )
  end
  return lines
end

---@param workflow table
---@return string[]
function M.workflow(workflow)
  local lines = {
    string.format(
      "%s · %s · %s",
      tostring(workflow.name),
      tostring(workflow.scope or "?"),
      tostring(workflow.summary or "")
    ),
    "",
  }
  if type(workflow.text) == "string" and workflow.text ~= "" then
    for _, line in ipairs(vim.split(workflow.text, "\n", { plain = true })) do
      lines[#lines + 1] = line
    end
  end
  if type(workflow.columns) == "table" and #workflow.columns > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "列：" .. table.concat(workflow.columns, " / ")
  end
  if type(workflow.team) == "table" and #workflow.team > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "成员："
    for _, member in ipairs(workflow.team) do
      lines[#lines + 1] = string.format(
        "  %s · %s · %s · %s",
        tostring(member.name),
        tostring(member.template),
        tostring(member.model or "-"),
        tostring(member.role or "")
      )
    end
  end
  return lines
end

M.time_text = time_text
return M
