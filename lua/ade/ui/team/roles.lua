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

---Stable 1..6 index for one label.
---@param label string
---@return integer
function M.index(label)
  local hash = 0
  for byte in tostring(label or ""):gmatch(".") do
    hash = (hash * 31 + byte:byte()) % 997
  end
  return hash % 6 + 1
end

---@param entry table|nil
---@return string
function M.hl(entry)
  if type(entry) == "table" and entry.name == "leader" then
    return "AdeTeamLeader"
  end
  return "AdeTeamRole" .. tostring(M.index(M.label(entry)))
end

---@param entry table|nil
---@return string
function M.symbol(entry)
  if type(entry) ~= "table" then
    return "◇"
  end
  if entry.name == "leader" or entry.role == "leader" then
    return "★"
  end
  if entry.state == "waiting_human" then
    return "◇"
  end
  return "◆"
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
