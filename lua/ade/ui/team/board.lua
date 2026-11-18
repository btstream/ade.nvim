-- Framed board layout for the unified team dashboard (v2).
local Roles = require("ade.ui.team.roles")
local one_line = require("ade.ui.team.text").one_line

local M = {}

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

local function content_width(width)
  return math.max(4, width - 4)
end

---@param card table
---@param states table<string, table>
---@param width integer|nil
---@return string[]
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
  if not card.owner or card.owner == "" then
    return "未分配"
  end
  local state = states[card.owner]
  local symbol = state and state.symbol or "◇"
  local st = state and state.state_text or ""
  return st ~= "" and string.format("%s %s %s", symbol, card.owner, st) or (symbol .. " " .. card.owner)
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
  local body = one_line(card.body or "")
  return body
end

local function card_block(card, states, width)
  local inner = content_width(width)
  local owner = card.owner and states[card.owner] or nil
  local border_group = owner and owner.role_hl or "AdeBoardCardBorder"
  local top = "╭" .. string.rep("─", inner + 2) .. "╮"
  local bottom = "╰" .. string.rep("─", inner + 2) .. "╯"
  local lines = { top }
  local marks = {
    { line = 1, start = 0, stop = width, group = border_group },
    { line = 5, start = 0, stop = width, group = border_group },
  }
  local first = string.format("%s %s", one_line(card.id), one_line(card.title))
  local second = string.format("%s · %s", one_line(card.stage ~= "" and card.stage or ""), owner_text(card, states))
  second = second:gsub("^ · ", "")
  local third = third_line(card)
  for index, text in ipairs({ first, second, third }) do
    lines[#lines + 1] = "│ " .. pad(text, inner) .. " │"
    if index == 1 then
      marks[#marks + 1] = { line = index + 1, start = 2, stop = 3 + #one_line(card.id), group = "AdeBold" }
    end
  end
  lines[#lines + 1] = bottom
  return lines, marks
end

---@param board table
---@param states table<string, table>
---@param opts {scroll: integer|nil, expanded: table<string, boolean>|nil, width: integer|nil, team: table|nil}
---@return string[] lines, table<integer, table> meta, table<integer, string> ids, table[] marks
function M.lines(board, states, opts)
  opts = opts or {}
  local width = math.max(20, tonumber(opts.width) or 80)
  local lines, meta, ids, all_marks = {}, {}, {}, {}
  local function add(text, info, id, marks)
    lines[#lines + 1] = text
    meta[#lines] = info or {}
    if id then
      ids[#lines] = id
    end
    for _, mark in ipairs(marks or {}) do
      all_marks[#all_marks + 1] = {
        line = #lines,
        start = mark.start,
        stop = mark.stop,
        group = mark.group,
      }
    end
  end
  if type(board) ~= "table" then
    add(" leader 还没有创建看板", { kind = "board_empty" })
    add(" 按 L 去和 leader 聊", { kind = "board_empty" })
    return lines, meta, ids, all_marks
  end
  if board.unavailable then
    add(" 看板不可用（存储读取失败）", { kind = "board_unavailable" })
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
  local scroll = math.max(0, tonumber(opts.scroll) or 0)
  local layout = {}
  for index, column in ipairs(columns) do
    local col_width = math.max(24, display_width(column) + 6)
    for _, card in ipairs(cards_by_column[column] or {}) do
      col_width = math.max(col_width, math.min(48, display_width(card.title) + 8))
    end
    layout[#layout + 1] = { column = column, width = col_width, cards = cards_by_column[column] or {}, index = index }
  end
  local visible = {}
  local total_width = 0
  for index = scroll + 1, #layout do
    if total_width + layout[index].width > width and #visible > 0 then
      break
    end
    visible[#visible + 1] = layout[index]
    total_width = total_width + layout[index].width + 1
  end
  if #visible > 0 then
    local header, header_cells, header_marks = {}, {}, {}
    local start_col = 0
    for _, item in ipairs(visible) do
      header[#header + 1] = "┃" .. pad(string.format(" %s %d", item.column, #item.cards), item.width - 1)
      header_cells[#header_cells + 1] = { column = item.column, start = start_col, stop = start_col + item.width }
      header_marks[#header_marks + 1] = {
        start = start_col,
        stop = start_col + item.width,
        group = "AdeBoardColumn" .. tostring(((item.index - 1) % 6) + 1),
      }
      start_col = start_col + item.width
    end
    add(table.concat(header), { kind = "board_header", cells = header_cells }, nil, header_marks)

    local max_cards = 0
    for _, item in ipairs(visible) do
      max_cards = math.max(max_cards, #item.cards)
    end
    for card_index = 1, max_cards do
      local blocks = {}
      for _, item in ipairs(visible) do
        local card = item.cards[card_index]
        if card then
          local block_lines, block_marks = card_block(card, states, item.width)
          blocks[#blocks + 1] = { block_lines, block_marks }
        else
          blocks[#blocks + 1] = { {}, {} }
        end
      end
      for row = 1, 5 do
        local text, cells = {}, {}
        local start_col = 0
        for index, item in ipairs(visible) do
          local block_lines = blocks[index][1]
          local cell_text = block_lines[row] or string.rep(" ", item.width)
          text[#text + 1] = "┃" .. cell_text
          cells[#cells + 1] = {
            start = start_col,
            stop = start_col + item.width,
            card = item.cards[card_index],
            column = item.column,
          }
          start_col = start_col + item.width
        end
        local id = #cells == 1 and cells[1].card and ("card:" .. tostring(cells[1].card.id)) or nil
        local marks = {}
        for index, block in ipairs(blocks) do
          for _, mark in ipairs(block[2] or {}) do
            if mark.line == row then
              local cell_start = 0
              for previous = 1, index - 1 do
                cell_start = cell_start + visible[previous].width
              end
              marks[#marks + 1] = {
                start = cell_start + mark.start + 1,
                stop = cell_start + mark.stop + 1,
                group = mark.group,
              }
            end
          end
        end
        add(table.concat(text), { kind = "board_row", cells = cells }, id, marks)
      end
      -- One blank line between cards (keeps a column separator).
      local blanks = {}
      for _, item in ipairs(visible) do
        blanks[#blanks + 1] = "┃" .. string.rep(" ", item.width - 1)
      end
      add(table.concat(blanks), { kind = "board_gap" })
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
      add(
        string.format("%s · 已提交 · %d 张%s", title, #stages[stage], collapsed and "" or " ▾"),
        { kind = "archived_stage", stage = stage }
      )
      if not collapsed then
        for _, card in ipairs(stages[stage]) do
          add("  " .. M.card_text(card, states), { kind = "card", card = card }, "card:" .. tostring(card.id))
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
M.display_width = display_width
M.truncate = truncate
M.pad = pad
return M
