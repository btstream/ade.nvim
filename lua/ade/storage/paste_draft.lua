-- The complete payload must travel with any persisted paste label. Bound both
-- live payloads and untrusted draft data without ever clipping a payload.
local M = { max_bytes = 200 * 1024, max_items = 100, max_draft_bytes = 200 * 1024 }
-- Undo can keep deleted pastes alive, independently of the active quota.
M.max_retained_bytes = 4 * M.max_bytes
M.max_retained_items = 4 * M.max_items

function M.label(text)
  local _, newlines = text:gsub("\n", "")
  if newlines > 0 then
    return string.format("[Pasted %d lines]", newlines + 1)
  end
  return string.format("[Pasted %d bytes]", #text)
end

function M.valid(items, lines)
  local out, bytes, ends = {}, 0, {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if type(item) == "table" and type(item.text) == "string" and #item.text > 0 and #item.text <= M.max_bytes then
      local row, col = item.row, item.col
      local line = type(row) == "number" and row >= 0 and row % 1 == 0 and lines[row + 1]
      if line and type(col) == "number" and col >= (ends[row] or 0) and col % 1 == 0 then
        local label = M.label(item.text)
        if line:sub(col + 1, col + #label) == label and bytes + #item.text <= M.max_bytes then
          out[#out + 1] = { row = row, col = col, text = item.text }
          ends[row], bytes = col + #label, bytes + #item.text
          if #out >= M.max_items then
            break
          end
        end
      end
    end
  end
  return out
end

return M
