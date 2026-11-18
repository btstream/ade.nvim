-- Role labels, colours and short names shared by the member and board panes.
local M = {}

---@param entry table|nil
---@return string
function M.label(entry)
  if type(entry) ~= "table" then
    return ""
  end
  return require("ade.ui.team.text").one_line(entry.label or entry.template or entry.name or "")
end

---Stable 1..6 index for one label (fallback when no palette is available).
---@param label string
---@return integer
function M.index(label)
  local hash = 0
  for byte in tostring(label or ""):gmatch(".") do
    hash = (hash * 31 + byte:byte()) % 997
  end
  return hash % 6 + 1
end

---Assign `AdeTeamRole1..6` by first appearance so a team's labels never
---collide until there are more than six distinct labels.
---@param participants table[]|nil
---@return table<string, integer>
function M.palette(participants)
  local out, next_index = {}, 0
  for _, entry in ipairs(participants or {}) do
    if entry.name ~= "leader" and entry.role ~= "leader" then
      local label = M.label(entry)
      if label ~= "" and not out[label] then
        next_index = next_index % 6 + 1
        out[label] = next_index
      end
    end
  end
  return out
end

---@param entry table|nil
---@param palette table<string, integer>|nil
---@return string
function M.hl(entry, palette)
  if type(entry) == "table" and (entry.name == "leader" or entry.role == "leader") then
    return "AdeTeamLeader"
  end
  local label = M.label(entry)
  local index = palette and palette[label] or M.index(label)
  return "AdeTeamRole" .. tostring(index)
end

---@param entry table|nil
---@return string
function M.symbol(entry)
  local glyphs = require("ade.ui.team.text").glyphs()
  if type(entry) ~= "table" then
    return glyphs.waiting
  end
  if entry.name == "leader" or entry.role == "leader" then
    return glyphs.leader
  end
  if entry.state == "waiting_human" then
    return glyphs.waiting
  end
  return glyphs.worker
end

---Short model name: the part after the provider slash.
---@param model string|nil
---@return string
function M.short_model(model)
  if type(model) ~= "string" or model == "" then
    return ""
  end
  return model:match("([^/]+)$") or model
end

return M
