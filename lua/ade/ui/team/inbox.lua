-- The dashboard inbox: open items, with spawn groups collapsed to one row.
local Board = require("ade.ui.team.board")

local M = {}

local ICONS = {
  question = "?",
  permission = "⚑",
  spawn = "+",
  message = "✉",
  limit = "⏱",
  request = "⚑",
}

local one_line = require("ade.ui.team.text").one_line

local function numeric_id(id)
  return tonumber(tostring(id):match("(%d+)$")) or 0
end

---@param team table
---@param items table[]
---@param width integer|nil
---@return string[] lines, table<integer, string> ids, table<integer, table> meta
function M.lines(team, items, width)
  width = math.max(40, tonumber(width) or 80)
  items = vim.deepcopy(items or {})
  table.sort(items, function(a, b)
    return numeric_id(a.id) < numeric_id(b.id)
  end)
  local lines, ids, meta = {}, {}, {}
  local index = 1
  local function add(text, id, info)
    lines[#lines + 1] = Board.truncate(one_line(text), width)
    if id then
      ids[#lines] = id
    end
    meta[#lines] = info
  end
  while index <= #items do
    local item = items[index]
    local group = item.kind == "spawn" and item.group
    if group then
      local rows = {}
      while index <= #items and items[index].kind == "spawn" and items[index].group == group do
        rows[#rows + 1] = items[index]
        index = index + 1
      end
      if #rows > 1 then
        local members = {}
        for _, row in ipairs(rows) do
          local agent = row.agent or row.template or "?"
          local model = row.model and ("/" .. tostring(row.model)) or ""
          members[#members + 1] =
            string.format("%s %s%s", tostring(row.name or row.template or "?"), tostring(agent), model)
        end
        local first, last = rows[1].id, rows[#rows].id
        add(
          string.format(
            "+ %s–%s %s 申请启动 %d 个 worker：%s",
            first,
            last,
            tostring(rows[1].from or "?"),
            #rows,
            table.concat(members, "、")
          ),
          "item:" .. tostring(rows[1].id),
          {
            kind = "inbox_group",
            team = team.id,
            group = group,
            item_ids = vim.tbl_map(function(row)
              return row.id
            end, rows),
          }
        )
      else
        for _, row in ipairs(rows) do
          add(
            string.format(
              "%s %-10s %-10s from %-10s %s",
              ICONS.spawn,
              tostring(row.id),
              tostring(row.name or row.template or ""),
              tostring(row.from or ""),
              one_line(row.body)
            ),
            "item:" .. tostring(row.id),
            { kind = "inbox", team = team.id, item = row }
          )
        end
      end
    else
      add(
        string.format(
          "%s %-10s %-10s from %-10s %s",
          ICONS[item.kind] or "✉",
          tostring(item.id),
          tostring(item.kind),
          tostring(item.from),
          one_line(item.body)
        ),
        "item:" .. tostring(item.id),
        { kind = "inbox", team = team.id, item = item }
      )
      index = index + 1
    end
  end
  return lines, ids, meta
end

M.ICONS = ICONS
return M
