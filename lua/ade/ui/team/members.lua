-- Member rows for the unified team dashboard: roles, fixed width and bytes.
local Roles = require("ade.ui.team.roles")
local Text = require("ade.ui.team.text")
local glyph = require("ade.ui.icons").glyph
local one_line = Text.one_line

local M = {}

local ICONS = {
  working = "team_working",
  idle = "team_idle",
  waiting_human = "team_waiting",
  exited = "team_exited",
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
  local icon = glyph(ICONS[entry.state] or "team_idle")
  if entry.paused and entry.state ~= "exited" then
    icon = glyph("team_paused")
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

---State cell, shortest useful form first.
---@param entry table
---@return string
local function state_text(entry)
  local parts = { M.state_icon(entry) }
  if entry.paused then
    parts[#parts + 1] = "paused"
  end
  parts[#parts + 1] = M.duration(entry.state_since)
  return table.concat(parts, " ")
end

---@param entry table
---@param name string
---@return string, string
local function role_parts(entry, name)
  local label = Roles.label(entry)
  if label == name then
    -- The leader has no label of its own; showing `leader leader` is noise.
    label = ""
  end
  local agent = entry.agent and one_line(entry.agent) or ""
  local model = Roles.short_model(entry.model)
  local detail = agent
  if model ~= "" then
    detail = detail ~= "" and (detail .. "/" .. model) or model
  end
  return label, detail
end

---Add the role cell within `budget`, keeping the label before agent/model.
---@param line table
---@param entry table
---@param name string
---@param budget integer
---@return string|nil dropped detail for a second line
local function add_role(line, entry, name, budget, role_hl)
  local label, detail = role_parts(entry, name)
  if budget <= 0 then
    return detail ~= "" and detail or nil
  end
  if label == "" and detail == "" then
    return nil
  end
  local full = label
  if detail ~= "" then
    full = full ~= "" and (full .. " " .. detail) or detail
  end
  if Text.width(full) <= budget then
    if label ~= "" then
      line:add(label, role_hl)
      line:add(" ")
    end
    line:add(detail, "AdeMuted")
    return nil
  end

  local used = 0
  if label ~= "" then
    if Text.width(label) >= budget then
      line:add(Text.ellipsis(label, budget), role_hl)
      local combined = detail ~= "" and (label .. " " .. detail) or label
      return combined ~= "" and combined or nil
    end
    line:add(label, role_hl)
    used = Text.width(label) + 1
    line:add(" ")
  end
  local left = budget - used
  if left <= 0 then
    return detail ~= "" and detail or nil
  end
  local agent, model = detail, ""
  local slash = agent:find("/", 1, true)
  if slash then
    agent, model = agent:sub(1, slash - 1), agent:sub(slash + 1)
  end
  if agent ~= "" and Text.width(agent) <= left then
    line:add(agent, "AdeMuted")
    left = left - Text.width(agent)
    if model ~= "" and left >= 2 then
      line:add("/" .. Text.ellipsis(model, left - 1), "AdeMuted")
      -- The model was shortened: show it in full on the detail line.
      return detail
    end
    return model ~= "" and detail or nil
  end
  if left >= 2 then
    line:add(Text.ellipsis(agent ~= "" and agent or model, left), "AdeMuted")
  end
  return detail ~= "" and detail or nil
end

---Build one member row, returning its second-line detail lines too.
---@param entry table
---@param width integer
---@param messages integer|nil
---@param palette table<string, integer>|nil
---@return table line, table[] extra, string[] details
function M.row(entry, width, messages, palette)
  local glyphs = Text.glyphs()
  local role_hl = entry.role_hl or Roles.hl(entry, palette)
  local name = one_line(entry.name)
  local line = Text.new_line()
  line:add(glyphs.bar, role_hl)
  line:add(Roles.symbol(entry), role_hl)
  line:add(" ")
  line:add(name, "AdeBold")
  line:add(" ")

  local task = entry.task and entry.task ~= "_" and one_line(entry.task) or ""
  local mail = (tonumber(messages) or 0) > 0 and (glyph("team_mail") .. " " .. tostring(messages)) or ""
  local state = state_text(entry)
  local role_min = 6
  local available = width - line.cells - 1 - role_min
  local tail = ""
  local function add_tail(text)
    if text == "" then
      return
    end
    tail = tail == "" and text or (tail .. " " .. text)
  end
  add_tail(state)
  if task ~= "" and Text.width(tail .. " " .. task) <= math.max(0, available) then
    add_tail(task)
  elseif task ~= "" then
    local room = math.max(0, available - Text.width(tail) - 1)
    if room >= 4 then
      add_tail(Text.ellipsis(task, room))
    end
  end
  if mail ~= "" and Text.width(tail .. " " .. mail) <= math.max(0, available) then
    add_tail(mail)
  end
  if tail ~= "" and line.cells + 1 + Text.width(tail) > width then
    tail = Text.truncate(tail, math.max(0, width - line.cells - 1))
  end

  local gap = tail ~= "" and 1 or 0
  local budget = width - line.cells - Text.width(tail) - gap
  local dropped = add_role(line, entry, name, budget, role_hl)
  if tail ~= "" then
    line:add(" ")
    line:add(tail, entry.paused and "AdeNoticeWarn" or "AdeMuted")
  end

  local extras, details = {}, {}
  if dropped then
    details[#details + 1] = dropped
  end
  local activity = entry.activity and entry.activity.text
  if type(activity) == "string" and activity ~= "" then
    details[#details + 1] = glyph("team_activity") .. " " .. one_line(activity)
  end
  local worktree = entry.worktree
  if type(worktree) == "table" and worktree.branch then
    details[#details + 1] = "wt " .. one_line(worktree.branch)
  end
  for _, text in ipairs(details) do
    local extra = Text.new_line()
    extra:add(glyphs.bar, role_hl)
    extra:add("  " .. Text.ellipsis(text, math.max(1, width - 3)))
    extras[#extras + 1] = extra
  end
  return line, extras
end

---@param entry table
---@param limits table|nil
---@param width integer|nil
---@param messages integer|nil
---@param palette table<string, integer>|nil
---@return string[] lines, table[] marks
function M.entry_lines(entry, limits, width, messages, palette)
  width = math.max(8, tonumber(width) or 32)
  local line, extras = M.row(entry, width, messages, palette)
  local lines = { line:text() }
  local marks = {}
  local function add_marks(source, line_no)
    for _, mark in ipairs(source:marks()) do
      marks[#marks + 1] = { line = line_no, start = mark.start, stop = mark.stop, group = mark.group }
    end
  end
  add_marks(line, 1)
  for _, extra in ipairs(extras) do
    lines[#lines + 1] = extra:text()
    add_marks(extra, #lines)
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
  width = math.max(8, tonumber(width) or 32)
  local palette = Roles.palette(team.participants)
  local lines, ids, meta, marks = {}, {}, {}, {}
  local participants = {}
  local workers, live = 0, 0
  for _, entry in ipairs(team.participants or {}) do
    if entry.name == "leader" then
      table.insert(participants, 1, entry)
    else
      participants[#participants + 1] = entry
      if entry.name ~= "human" then
        workers = workers + 1
        if entry.state ~= "exited" then
          live = live + 1
        end
      end
    end
  end
  local max_workers = tonumber(opts.max_workers) or workers
  local saw_leader = false
  for _, entry in ipairs(participants) do
    if entry.name == "leader" then
      saw_leader = true
    elseif saw_leader then
      local label = string.format(" workers %d/%d ", live, max_workers)
      local rule = Text.glyphs().horizontal
      local left = math.max(2, math.floor((width - Text.width(label)) / 2))
      local line = string.rep(rule, left) .. label
      line = line .. string.rep(rule, math.max(0, width - Text.width(line)))
      lines[#lines + 1] = Text.truncate(line, width)
      meta[#lines] = { kind = "separator", team = team.id }
      saw_leader = false
    end
    local rows, row_marks = M.entry_lines(entry, team.limits, width, (opts.messages or {})[entry.name], palette)
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
