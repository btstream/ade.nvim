-- Framed board layout for the unified team dashboard.
--
-- Every line is composed from byte-accurate segments: extmarks and cursor
-- hit-tests use bytes, column layout uses display cells. Card rows, headers and
-- filler rows all use the same per-column width including the `┃` separator.
local Roles = require("ade.ui.team.roles")
local Text = require("ade.ui.team.text")
local one_line = Text.one_line

local M = {}

local COLUMN_MIN = 24
local COLUMN_MAX = 44

local function content_width(width)
  return math.max(4, width - 4)
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

local function owner_text(card, states)
  local state = card.owner and states[card.owner] or nil
  local symbol = state and state.symbol or Text.glyphs().waiting
  if not card.owner or card.owner == "" then
    return "未分配", "AdeMuted"
  end
  local st = state and state.state_text or ""
  local text = st ~= "" and string.format("%s %s %s", symbol, card.owner, st)
    or string.format("%s %s", symbol, card.owner)
  return text, state and state.role_hl or "AdeMuted"
end

local function third_line(card)
  local keys = {}
  for key in pairs(card.fields or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  if keys[1] then
    return string.format("%s=%s", keys[1], one_line(card.fields[keys[1]]))
  end
  return one_line(card.body or "")
end

---Five byte-accurate lines, each exactly `width` cells.
---@param card table
---@param states table<string, table>
---@param width integer
---@return table[]
local function card_block(card, states, width)
  local glyphs = Text.glyphs()
  local inner = content_width(width)
  local state = card.owner and states[card.owner] or nil
  local border = state and state.role_hl or "AdeBoardCardBorder"
  local lines = {}

  local top = Text.new_line()
  top:add(glyphs.top_left .. string.rep(glyphs.horizontal, inner + 2) .. glyphs.top_right, border)
  lines[#lines + 1] = top

  local first = Text.new_line()
  first:add(glyphs.vertical, border)
  first:add(" ")
  first:add(Text.ellipsis(one_line(card.id), math.max(1, inner)), "AdeBold")
  local id_width = Text.width(one_line(card.id))
  first:add(" ")
  first:add(Text.ellipsis(one_line(card.title), math.max(0, inner - id_width - 1)))
  first:pad_to(inner + 2)
  first:add(" ")
  first:add(glyphs.vertical, border)
  lines[#lines + 1] = first

  local second = Text.new_line()
  second:add(glyphs.vertical, border)
  second:add(" ")
  local used = 0
  local stage = one_line(card.stage or "")
  if stage ~= "" then
    second:add(Text.ellipsis(stage, inner), "AdeMuted")
    used = Text.width(Text.ellipsis(stage, inner))
    second:add(" · ")
    used = used + 3
  end
  local owner, owner_group = owner_text(card, states)
  second:add(Text.ellipsis(owner, math.max(0, inner - used)), owner_group)
  second:pad_to(inner + 2)
  second:add(" ")
  second:add(glyphs.vertical, border)
  lines[#lines + 1] = second

  local third = Text.new_line()
  third:add(glyphs.vertical, border)
  third:add(" ")
  third:add(Text.ellipsis(third_line(card), inner), "AdeMuted")
  third:pad_to(inner + 2)
  third:add(" ")
  third:add(glyphs.vertical, border)
  lines[#lines + 1] = third

  local bottom = Text.new_line()
  bottom:add(glyphs.bottom_left .. string.rep(glyphs.horizontal, inner + 2) .. glyphs.bottom_right, border)
  lines[#lines + 1] = bottom
  return lines
end

---Pick how many columns fit and the width each one gets. Widths depend only
---on the window, never on card content, so columns do not jump on refresh.
---@param available integer
---@param count integer
---@param single boolean|nil
---@return integer visible, integer width
local function column_layout(available, count, single)
  if count <= 0 then
    return 0, COLUMN_MIN
  end
  if single then
    return 1, math.max(COLUMN_MIN, math.min(COLUMN_MAX, available - 2))
  end
  for n = count, 1, -1 do
    local width = math.min(COLUMN_MAX, math.floor((available - 1) / n) - 1)
    if width >= COLUMN_MIN then
      return n, width
    end
  end
  return 1, math.max(20, math.min(COLUMN_MAX, available - 2))
end

---How many columns fit in `available` cells (used by the scroll clamp).
---@param available integer
---@param count integer
---@param single boolean|nil
---@return integer
function M.visible_columns(available, count, single)
  return (column_layout(available, count, single))
end

---@param board table
---@param states table<string, table>
---@param opts {scroll: integer|nil, expanded: table<string, boolean>|nil, width: integer|nil, team: table|nil, single_column: boolean|nil}
---@return string[] lines, table<integer, table> meta, table<integer, string> ids, table[] marks
function M.lines(board, states, opts)
  opts = opts or {}
  local width = math.max(24, tonumber(opts.width) or 80)
  local lines, meta, ids, all_marks = {}, {}, {}, {}
  local function add(line, info, id)
    local byte_starts = {}
    for _, mark in ipairs(line:marks()) do
      byte_starts[#byte_starts + 1] = { start = mark.start, stop = mark.stop, group = mark.group }
    end
    lines[#lines + 1] = line:text()
    meta[#lines] = info or {}
    if id then
      ids[#lines] = id
    end
    for _, mark in ipairs(byte_starts) do
      all_marks[#all_marks + 1] = {
        line = #lines,
        start = mark.start,
        stop = mark.stop,
        group = mark.group,
      }
    end
  end
  if type(board) ~= "table" then
    add(Text.new_line():add(" leader 还没有创建看板"), { kind = "board_empty" })
    add(Text.new_line():add(" 按 L 去和 leader 聊"), { kind = "board_empty" })
    return lines, meta, ids, all_marks
  end
  if board.unavailable then
    add(Text.new_line():add(" 看板不可用（存储读取失败）"), { kind = "board_unavailable" })
    return lines, meta, ids, all_marks
  end

  local columns = board.columns or {}
  local cards_by_column = {}
  for _, column in ipairs(columns) do
    cards_by_column[column] = {}
  end
  local archived = {}
  for _, card in ipairs(board.cards or {}) do
    if card.archived then
      archived[#archived + 1] = card
    elseif cards_by_column[card.column] then
      cards_by_column[card.column][#cards_by_column[card.column] + 1] = card
    end
  end

  local visible_count, cell_width = column_layout(width, #columns, opts.single_column)
  local scroll = math.max(0, math.min(tonumber(opts.scroll) or 0, math.max(0, #columns - visible_count)))
  local visible = {}
  for index = scroll + 1, math.min(#columns, scroll + visible_count) do
    visible[#visible + 1] = {
      column = columns[index],
      index = index,
      cards = cards_by_column[columns[index]] or {},
    }
  end

  if #visible > 0 then
    local glyphs = Text.glyphs()
    local cells = {}
    if visible_count < #columns then
      local first, last = scroll + 1, scroll + #visible
      local position = first == last and string.format("列 %d/%d · %s", first, #columns, columns[first])
        or string.format("列 %d-%d/%d", first, last, #columns)
      add(Text.new_line():add(string.format("‹ %s · zh/zl ›", position)), { kind = "board_hint" })
    end

    local header = Text.new_line()
    for _, item in ipairs(visible) do
      local group = "AdeBoardColumn" .. tostring(((item.index - 1) % 6) + 1)
      header:add(glyphs.sep, group)
      local start_byte, start_cell = header.bytes, header.cells
      header:add(Text.pad(string.format(" %s %d", item.column, #item.cards), cell_width), group)
      cells[#cells + 1] = {
        start = start_byte,
        stop = header.bytes,
        cell_start = start_cell,
        cell_stop = header.cells,
        column = item.column,
      }
    end
    header:add(glyphs.sep)
    add(header, { kind = "board_header", cells = cells })

    local max_cards = 0
    for _, item in ipairs(visible) do
      max_cards = math.max(max_cards, #item.cards)
    end
    for card_index = 1, max_cards do
      local blocks = {}
      for index, item in ipairs(visible) do
        local card = item.cards[card_index]
        blocks[index] = card and card_block(card, states, cell_width) or nil
      end
      for row = 1, 5 do
        local line = Text.new_line()
        local cells_row = {}
        for index, item in ipairs(visible) do
          line:add(glyphs.sep)
          local start_byte, start_cell = line.bytes, line.cells
          local block = blocks[index]
          if block and block[row] then
            for _, segment in ipairs(block[row].segments) do
              line:add(segment.text, segment.group)
            end
          end
          line:pad_to(start_cell + cell_width)
          cells_row[#cells_row + 1] = {
            start = start_byte,
            stop = line.bytes,
            cell_start = start_cell,
            cell_stop = line.cells,
            card = item.cards[card_index],
            column = item.column,
          }
        end
        line:add(glyphs.sep)
        local id = nil
        if #visible == 1 and cells_row[1] and cells_row[1].card then
          id = "card:" .. tostring(cells_row[1].card.id)
        end
        add(line, { kind = "board_row", cells = cells_row }, id)
      end
      local gap = Text.new_line()
      for _ = 1, #visible do
        gap:add(glyphs.sep)
        gap:fill(cell_width)
      end
      gap:add(glyphs.sep)
      add(gap, { kind = "board_gap" })
    end
  end

  if #archived > 0 then
    add(Text.new_line():add(string.format("已归档 %d 张（<CR> 展开）", #archived)), { kind = "archived_total" })
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
      add(
        Text.new_line()
          :add(string.format("%s · 已提交 · %d 张%s", title, #stages[stage], collapsed and "" or " ▾")),
        { kind = "archived_stage", stage = stage }
      )
      if not collapsed then
        for _, card in ipairs(stages[stage]) do
          add(
            Text.new_line():add("  " .. M.card_text(card, states)),
            { kind = "card", card = card },
            "card:" .. tostring(card.id)
          )
        end
      end
    end
  end
  return lines, meta, ids, all_marks
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
M.display_width = Text.width
M.truncate = Text.truncate
M.pad = Text.pad
return M
