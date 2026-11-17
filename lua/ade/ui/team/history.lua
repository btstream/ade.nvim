-- Card history window (PROTOCOL.md 19.4).
local M = {}

local function fields_text(fields)
  local out = {}
  for key, value in pairs(fields or {}) do
    out[#out + 1] = key .. "=" .. tostring(value)
  end
  table.sort(out)
  return table.concat(out, " · ")
end

local function body(card)
  return tostring(card.body or "")
end

local function unified(old, new)
  if vim.diff then
    local ok, diff = pcall(vim.diff, old or "", new or "", { result_type = "unified", ctxlen = 2 })
    if ok and type(diff) == "string" then
      return diff
    end
  end
  return (old or "") .. "\n---\n" .. (new or "")
end

---@param team string
---@param card string
---@param versions table[] newest first
---@return integer buf
function M.open(team, card, versions)
  local previous = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "ade_team_history"
  local lines = {
    string.format(
      "卡片 %s 历史 · team %s · %d 个版本（新到旧）",
      tostring(card),
      tostring(team),
      #(versions or {})
    ),
  }
  for index, version in ipairs(versions or {}) do
    lines[#lines + 1] = ""
    lines[#lines + 1] =
      string.format("── 版本 %d/%d · %s", index, #versions, tostring(version.updated_by or "?"))
    lines[#lines + 1] = string.format(
      "%s · %s · owner %s · stage %s",
      tostring(version.title or ""),
      tostring(version.column or ""),
      tostring(version.owner or "-"),
      tostring(version.stage or "-")
    )
    local fields = fields_text(version.fields)
    if fields ~= "" then
      lines[#lines + 1] = fields
    end
    for _, line in ipairs(vim.split(body(version), "\n", { plain = true })) do
      lines[#lines + 1] = "  " .. line
    end
    local older = versions[index + 1]
    if older then
      lines[#lines + 1] = "  --- 与上一版对比 ---"
      for _, line in ipairs(vim.split(unified(body(older), body(version)), "\n", { plain = true })) do
        lines[#lines + 1] = "  " .. line
      end
      local old_fields, new_fields = fields_text(older.fields), fields_text(version.fields)
      if old_fields ~= new_fields then
        lines[#lines + 1] = "  fields: " .. old_fields .. "  ->  " .. new_fields
      end
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.min(100, math.max(50, math.floor(vim.o.columns * 0.8)))
  local height = math.max(10, math.floor((vim.o.lines - vim.o.cmdheight) * 0.7))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Card history ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true })
  pcall(vim.api.nvim_set_current_win, previous)
  return buf
end

return M
