-- Single-line fields and byte-accurate line building shared by every pane.
--
-- Neovim extmark columns and cursor columns are byte offsets, while layout and
-- truncation are display cells. Both are one line apart inside a `Line`, so no
-- caller has to mix them up.
local M = {}

---Collapse line breaks and carriage returns so the value can be placed in one
---buffer line.
---@param text any
---@return string
function M.one_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " "))
end

---@param text any
---@return integer
function M.width(text)
  local ok, width = pcall(vim.fn.strdisplaywidth, tostring(text or ""))
  return ok and width or #tostring(text or "")
end

---Truncate to at most `cells` display cells. Never splits a UTF-8 character.
---@param text any
---@param cells integer
---@return string
function M.truncate(text, cells)
  text = tostring(text or "")
  if M.width(text) <= cells then
    return text
  end
  local out = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if M.width(out .. char) > cells then
      break
    end
    out = out .. char
  end
  return out
end

---Truncate and append an ellipsis when something was dropped.
---@param text any
---@param cells integer
---@return string
function M.ellipsis(text, cells)
  text = tostring(text or "")
  if M.width(text) <= cells then
    return text
  end
  if cells <= 1 then
    return M.truncate("…", cells)
  end
  return M.truncate(text, cells - 1) .. "…"
end

---@param text any
---@param cells integer
---@return string
function M.pad(text, cells)
  text = M.truncate(text, cells)
  return text .. string.rep(" ", math.max(0, cells - M.width(text)))
end

local Line = {}
Line.__index = Line

---@return table
function M.new_line()
  return setmetatable({ parts = {}, segments = {}, spans = {}, bytes = 0, cells = 0 }, Line)
end

---Append text and remember the byte and cell ranges covered by `group`.
---@param text any
---@param group string|nil
---@return table
function Line:add(text, group)
  text = tostring(text or "")
  local start_byte, start_cell = self.bytes, self.cells
  self.parts[#self.parts + 1] = text
  self.segments[#self.segments + 1] = { text = text, group = group }
  self.bytes = self.bytes + #text
  self.cells = self.cells + M.width(text)
  if group and #text > 0 then
    self.spans[#self.spans + 1] = { start = start_byte, stop = self.bytes, group = group, cells = start_cell }
  end
  return self
end

---@param cells integer
---@param char string|nil
---@return table
function Line:fill(cells, char)
  if cells > 0 then
    self:add(string.rep(char or " ", cells))
  end
  return self
end

---Pad to an absolute number of display cells.
---@param cells integer
---@param char string|nil
---@return table
function Line:pad_to(cells, char)
  return self:fill(cells - self.cells, char)
end

---@return string
function Line:text()
  return table.concat(self.parts)
end

---@return table[]
function Line:marks()
  return self.spans
end

---The box drawing glyphs in use. `ambiwidth=double` makes the Unicode box
---characters two cells wide, so use plain ASCII there and keep alignment.
---@return table
function M.glyphs()
  if vim.o.ambiwidth == "double" then
    return {
      sep = "|",
      top_left = "+",
      top_right = "+",
      bottom_left = "+",
      bottom_right = "+",
      horizontal = "-",
      vertical = "|",
      bar = "|",
      leader = "*",
      worker = "o",
      waiting = "?",
    }
  end
  return {
    sep = "┃",
    top_left = "╭",
    top_right = "╮",
    bottom_left = "╰",
    bottom_right = "╯",
    horizontal = "─",
    vertical = "│",
    bar = "▌",
    leader = "★",
    worker = "◆",
    waiting = "◇",
  }
end

---Apply byte-accurate marks to a scratch buffer.
---@param buf integer
---@param ns integer
---@param marks table[]
function M.apply_marks(buf, ns, marks)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks or {}) do
    local line = tonumber(mark.line)
    if line and line >= 1 then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, mark.start or 0, {
        end_row = line - 1,
        end_col = mark.stop or -1,
        hl_group = mark.group,
        priority = mark.priority or 100,
      })
    end
  end
end

return M
