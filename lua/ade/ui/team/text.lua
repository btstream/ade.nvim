-- Single-line fields shared by every team dashboard pane.
local M = {}

---Collapse line breaks and carriage returns so the value can be placed in one
---buffer line.
---@param text any
---@return string
function M.one_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " "))
end

return M
