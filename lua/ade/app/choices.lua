-- Choice queue integration points (worker2 owns the real component).
--
-- This stub keeps the dashboard usable before `lua/ade/ui/choice/` and the real
-- app/choices.lua land. Tests replace these functions.
local M = {}

---@param team_id string|nil
---@return {question: integer, approval: integer}
function M.pending_counts(team_id)
  return { question = 0, approval = 0 }
end

---@param team_id string|nil
---@return boolean
function M.show_pending(team_id)
  return false
end

---@param team_id string
---@param name string
---@return boolean
function M.answer_participant(team_id, name)
  return false
end

return M
