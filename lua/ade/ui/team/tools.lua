-- Human summaries for ade-team MCP tool calls (dashboard v2 section 6).
local text = require("ade.ui.team.text")
local one_line = text.one_line

local M = {}

local function tool_name(block)
  local raw = type(block.raw_input) == "table" and block.raw_input or {}
  local name = raw.tool or block.tool_name or block.name or block.title or ""
  name = tostring(name):lower()
  name = name:gsub("^mcp__ade[-_]team__", "")
  name = name:gsub("^mcp__ade%-team__", "")
  name = name:gsub("^ade[-_]team_", "")
  name = name:gsub("^ade[-_]team:", "")
  return name
end

local function args(block)
  local raw = type(block.raw_input) == "table" and block.raw_input or {}
  if type(raw.tool) == "string" and type(raw.args) == "table" then
    return raw.args
  end
  return raw
end

local function first(text_value)
  return one_line(text_value):match("^[^\n]*") or ""
end

local function range(ids)
  if type(ids) ~= "table" or #ids == 0 then
    return nil
  end
  if #ids == 1 then
    return tostring(ids[1])
  end
  return string.format("%s–%s", tostring(ids[1]), tostring(ids[#ids]))
end

---@param block table
---@return {title: string, text: string}|nil
function M.describe(block)
  if type(block) ~= "table" or block.kind ~= "tool" then
    return nil
  end
  local name = tool_name(block)
  local a = args(block)
  if name:find("bus_send", 1, true) or name:find("bus send", 1, true) then
    local task = a.task and a.task ~= "_" and (" " .. tostring(a.task)) or ""
    return {
      title = string.format("→ %s %s%s", tostring(a.to or "?"), tostring(a.kind or "message"), task),
      text = first(a.body),
    }
  end
  if name:find("bus_ask_human", 1, true) or name:find("bus ask human", 1, true) then
    local questions = a.questions
    local question = questions and questions[1] and questions[1].question or a.question
    return { title = "提问", text = first(question) }
  end
  if name:find("team_spawn", 1, true) or name == "spawn" or name:find("bus.spawn", 1, true) then
    local model = a.model and ("，" .. tostring(a.model)) or ""
    return {
      title = "组队",
      text = string.format("申请 %s（%s%s）", tostring(a.name or "?"), tostring(a.template or "?"), model),
    }
  end
  if name:find("board_update", 1, true) or name:find("board update", 1, true) then
    local parts = {}
    if type(a.columns) == "table" then
      parts[#parts + 1] = string.format("设列 %d 个", #a.columns)
    end
    if type(a.upsert) == "table" and #a.upsert > 0 then
      local ids = {}
      for _, card in ipairs(a.upsert) do
        if card.id then
          ids[#ids + 1] = card.id
        end
      end
      if #ids > 0 then
        parts[#parts + 1] = "新建/更新 " .. tostring(range(ids))
      end
    end
    if type(a.archive) == "table" and #a.archive > 0 then
      parts[#parts + 1] = "归档 " .. tostring(range(a.archive))
    end
    if type(a.remove) == "table" and #a.remove > 0 then
      parts[#parts + 1] = "删除 " .. tostring(range(a.remove))
    end
    if a.workflow_name then
      parts[#parts + 1] = "流程 " .. tostring(a.workflow_name)
    end
    return { title = "看板", text = table.concat(parts, " / ") }
  end
  if name:find("card_update", 1, true) or name:find("card update", 1, true) then
    return {
      title = "卡片",
      text = string.format("%s %s", tostring(a.card or "?"), a.archive == true and "归档" or "更新"),
    }
  end
  if name:find("workflow_save", 1, true) then
    local workflow = type(a.workflow) == "table" and a.workflow or {}
    return { title = "流程", text = "保存 " .. tostring(workflow.name or "?") }
  end
  if name:find("workflow_get", 1, true) then
    return { title = "流程", text = "读取 " .. tostring(a.name or "?") }
  end
  if name:find("workflow_delete", 1, true) then
    return { title = "流程", text = "删除 " .. tostring(a.name or "?") }
  end
  if name:find("bus_status", 1, true) then
    return { title = "总线", text = "查看团队状态" }
  end
  if name:find("bus_read", 1, true) then
    return { title = "总线", text = "读取 " .. tostring(a.participant or "?") }
  end
  return nil
end

return M
