-- Board layout for the unified team dashboard (W0f, PROTOCOL.md 19.2).
local M = {}

local one_line = require("ade.ui.team.text").one_line

local function display_width(text)
  local ok, width = pcall(vim.fn.strdisplaywidth, tostring(text or ""))
  return ok and width or #tostring(text or "")
end

local function truncate(text, width)
  text = tostring(text or "")
  if display_width(text) <= width then
    return text
  end
  local out = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if display_width(out .. char) > width then
      break
    end
    out = out .. char
  end
  return out
end

local function pad(text, width)
  text = truncate(text, width)
  return text .. string.rep(" ", math.max(0, width - display_width(text)))
end

---@param card table
---@param states table<string, table>
---@return string
function M.card_text(card, states)
  local owner = card.owner and one_line(card.owner) or "-"
  local state = ""
  if card.owner and states[card.owner] then
    state = " " .. (states[card.owner].icon or "")
  end
  local fields = {}
  for key, value in pairs(card.fields or {}) do
    fields[#fields + 1] = one_line(key) .. "=" .. one_line(value)
  end
  table.sort(fields)
  local suffix = ""
  if #fields > 0 then
    suffix = "  " .. table.concat(fields, " ", 1, math.min(2, #fields))
  end
  return string.format("%s %s · %s%s%s", one_line(card.id), one_line(card.title), owner, state, suffix)
end

---@param board table
---@param states table<string, table> participant name -> {icon, state}
---@param opts {scroll: integer|nil, expanded: table<string, boolean>|nil, width: integer|nil, team: table|nil}
---@return string[] lines, table<integer, table> meta, table<integer, string> ids
function M.lines(board, states, opts)
  opts = opts or {}
  local width = math.max(20, tonumber(opts.width) or 80)
  local lines, meta, ids = {}, {}, {}
  local function add(text, info, id)
    lines[#lines + 1] = text
    meta[#lines] = info or {}
    if id then
      ids[#lines] = id
    end
  end
  if type(board) ~= "table" then
    add(" leader 还没有创建看板", { kind = "board_empty" })
    add(" 按 L 去和 leader 聊", { kind = "board_empty" })
    return lines, meta, ids
  end
  if board.unavailable then
    add(" 看板不可用（存储读取失败）", { kind = "board_unavailable" })
    return lines, meta, ids
  end
  local columns = board.columns or {}
  local active = {}
  local cards_by_column = {}
  for _, column in ipairs(columns) do
    cards_by_column[column] = {}
  end
  local archived = {}
  for _, card in ipairs(board.cards or {}) do
    if card.archived then
      archived[#archived + 1] = card
    else
      active[#active + 1] = card
      if cards_by_column[card.column] then
        cards_by_column[card.column][#cards_by_column[card.column] + 1] = card
      end
    end
  end
  local scroll = math.max(0, tonumber(opts.scroll) or 0)
  local visible = {}
  local total_width = 0
  local layout = {}
  for index, column in ipairs(columns) do
    local column_width = math.max(10, display_width(column))
    local card_texts = {}
    for _, card in ipairs(cards_by_column[column] or {}) do
      local text = M.card_text(card, states)
      card_texts[#card_texts + 1] = text
      column_width = math.max(column_width, math.min(32, display_width(text) + 2))
    end
    layout[#layout + 1] = {
      column = column,
      width = math.min(40, column_width + 2),
      cards = cards_by_column[column] or {},
      texts = card_texts,
      index = index,
    }
  end
  for index = scroll + 1, #layout do
    if total_width + layout[index].width > width and #visible > 0 then
      break
    end
    visible[#visible + 1] = layout[index]
    total_width = total_width + layout[index].width
  end

  if #visible > 0 then
    local header = {}
    local header_cells = {}
    local start_col = 0
    for _, item in ipairs(visible) do
      header[#header + 1] = pad(one_line(item.column), item.width)
      header_cells[#header_cells + 1] = { column = item.column, start = start_col, stop = start_col + item.width }
      start_col = start_col + item.width
    end
    add(table.concat(header), { kind = "board_header", cells = header_cells })
    local rows = 0
    for _, item in ipairs(visible) do
      rows = math.max(rows, #item.cards)
    end
    for row = 1, rows do
      local text, cells = {}, {}
      local start_col = 0
      for _, item in ipairs(visible) do
        local card = item.cards[row]
        local cell = card and truncate(M.card_text(card, states), item.width - 2) or ""
        text[#text + 1] = pad(cell, item.width)
        cells[#cells + 1] = { start = start_col, stop = start_col + item.width, card = card, column = item.column }
        start_col = start_col + item.width
      end
      local id
      if #cells == 1 and cells[1].card then
        id = "card:" .. tostring(cells[1].card.id)
      end
      add(table.concat(text), { kind = "board_row", cells = cells }, id)
    end
  end

  if #archived > 0 then
    add(string.format("已归档 %d 张（<CR> 展开）", #archived), { kind = "archived_total" })
    local stages, order = {}, {}
    for _, card in ipairs(archived) do
      local stage = card.stage or ""
      if not stages[stage] then
        stages[stage] = {}
        order[#order + 1] = stage
      end
      table.insert(stages[stage], card)
    end
    for _, stage in ipairs(order) do
      local title = stage ~= "" and stage or "无阶段"
      local collapsed = not (opts.expanded and opts.expanded[stage])
      local label = string.format("%s · 已提交 · %d 张", title, #stages[stage])
      if not collapsed then
        label = label .. " ▾"
      end
      add(label, { kind = "archived_stage", stage = stage })
      if not collapsed then
        for _, card in ipairs(stages[stage]) do
          add("  " .. M.card_text(card, states), { kind = "card", card = card }, "card:" .. tostring(card.id))
        end
      end
    end
  end
  return lines, meta, ids
end

---The first stage and its progress from `team.list.stages`.
---@param stages table|nil
---@return string|nil
function M.stage_progress(stages)
  for _, entry in ipairs(stages or {}) do
    local open = tonumber(entry.open) or 0
    local archived = tonumber(entry.archived) or 0
    local total = open + archived
    if total > 0 then
      local stage = entry.stage ~= "" and entry.stage or "无阶段"
      return string.format("阶段 %s · %d/%d 已完成", stage, archived, total)
    end
  end
  return nil
end

M.one_line = one_line
M.display_width = display_width
M.truncate = truncate
M.pad = pad
return M
