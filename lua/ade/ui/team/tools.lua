-- Human summaries for ade-team MCP tool calls (dashboard v2 section 6).
--
-- Only a confirmed ade-team server may produce a summary: claude's
-- `mcp__ade-team__*`, opencode's `ade-team_*`, or pi's `mcp` proxy with a bare
-- tool name. A free-form title that merely mentions one of these names (a
-- `Read board_update.lua` call, say) is deliberately ignored.
local text = require("ade.ui.team.text")
local one_line = text.one_line

local M = {}

---@type table<string, fun(args: table): boolean>
local SHAPE = {
  bus_send = function(args)
    return type(args.to) == "string" and args.to ~= ""
  end,
  bus_ask_human = function(args)
    return type(args.question) == "string" or (type(args.questions) == "table" and #args.questions > 0)
  end,
  team_spawn = function(args)
    return type(args.name) == "string" and type(args.template) == "string"
  end,
  board_update = function(args)
    return type(args.columns) == "table"
      or type(args.upsert) == "table"
      or type(args.archive) == "table"
      or type(args.remove) == "table"
      or type(args.workflow) == "table"
      or type(args.workflow_name) == "string"
  end,
  card_update = function(args)
    return type(args.card) == "string" or type(args.id) == "string"
  end,
  workflow_save = function(args)
    return type(args.workflow) == "table"
  end,
  workflow_get = function(args)
    return type(args.name) == "string"
  end,
  workflow_delete = function(args)
    return type(args.name) == "string"
  end,
  bus_status = function()
    return true
  end,
  bus_read = function(args)
    return type(args.participant) == "string"
  end,
}

---@param block table
---@param raw table
---@return boolean|nil confirmed true, false when another server is named
local function server_ok(block, raw)
  local candidates = {
    raw.server,
    raw.mcpServer,
    raw.mcp_server,
    type(raw._meta) == "table" and (raw._meta.server or raw._meta.mcpServer) or nil,
    type(block._meta) == "table" and (block._meta.server or block._meta.mcpServer) or nil,
    type(block.meta) == "table" and (block.meta.server or block.meta.mcpServer) or nil,
    block.server,
  }
  -- Fixed indices: the list intentionally has holes (a missing `_meta`),
  -- and `ipairs` would stop at the first nil.
  for index = 1, 7 do
    local value = candidates[index]
    if type(value) == "string" and value ~= "" then
      local server = value:lower():gsub("^mcp__", ""):gsub("__$", "")
      return server == "ade-team" or server == "ade_team"
    end
  end
  return nil
end

---Only an explicit `mcp__ade-team__` / `ade-team_` name counts here.
local function canonical(name)
  name = tostring(name or ""):lower()
  local server, rest = name:match("^mcp__([^_]+)__(.+)$")
  if server then
    if server ~= "ade-team" then
      return nil
    end
    rest = rest:gsub("%.", "_")
    return SHAPE[rest] and rest or nil
  end
  local prefixed = name:match("^ade%-team[_%:](.+)$")
  if prefixed then
    prefixed = prefixed:gsub("%.", "_")
    return SHAPE[prefixed] and prefixed or nil
  end
  return nil
end

---A bare tool name is only accepted with source evidence (`_meta.server`).
---@param block table
---@param raw table
---@return string|nil
local function bare_name(block, raw)
  local name = block.tool_name or block.name
  if type(name) ~= "string" then
    local title = one_line(block.title or "")
    if title:find("%s") then
      return nil
    end
    name = title
  end
  name = tostring(name or ""):lower():gsub("%.", "_")
  if not SHAPE[name] then
    return nil
  end
  if server_ok(block, raw) == true then
    return name
  end
  return nil
end

---The proxy (`mcp({tool=..., args=...})`) wraps the real call. A named
---`server` field must be ade-team; without one the argument shape must match.
---@param block table
---@return string|nil name, table args
local function proxy(block)
  local raw = type(block.raw_input) == "table" and block.raw_input or {}
  if type(raw.tool) ~= "string" or type(raw.args) ~= "table" then
    return nil, raw
  end
  local explicit = canonical(raw.tool)
  local name = explicit or raw.tool:lower():gsub("%.", "_")
  if not SHAPE[name] then
    return nil, raw
  end
  local server = server_ok(block, raw)
  if server == false then
    return nil, raw
  end
  if explicit then
    return name, raw.args
  end
  -- No explicit server: the proxy structure plus the expected arguments is
  -- the evidence available to us.
  return name, raw.args
end

---@param block table
---@return string|nil name, table args
local function identify(block)
  if type(block) ~= "table" or block.kind ~= "tool" then
    return nil, {}
  end
  local raw = type(block.raw_input) == "table" and block.raw_input or {}
  local name = canonical(block.tool_name) or canonical(block.name) or canonical(one_line(block.title or ""))
  if name then
    return name, raw
  end
  name = bare_name(block, raw)
  if name then
    return name, raw
  end
  -- pi's MCP proxy: `mcp({server = "ade-team", tool = "bus_send", args = {}})`.
  local proxy_name, proxy_args = proxy(block)
  if proxy_name then
    local is_proxy = block.tool_name == "mcp"
      or block.name == "mcp"
      or one_line(block.title or "") == "mcp"
      or type(raw.tool) == "string"
    if is_proxy and SHAPE[proxy_name](proxy_args) then
      return proxy_name, proxy_args
    end
  end
  return nil, {}
end

local function first(value)
  return one_line(value):match("^[^\n]*") or ""
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
  local name, a = identify(block)
  if not name or not SHAPE[name](a) then
    return nil
  end
  if name == "bus_send" then
    local task = a.task and a.task ~= "_" and (" " .. tostring(a.task)) or ""
    return {
      title = string.format("→ %s %s%s", tostring(a.to), tostring(a.kind or "message"), task),
      text = first(a.body),
    }
  end
  if name == "bus_ask_human" then
    local questions = a.questions
    local question = questions and questions[1] and questions[1].question or a.question
    return { title = "提问", text = first(question) }
  end
  if name == "team_spawn" then
    local model = a.model and ("，" .. tostring(a.model)) or ""
    return {
      title = "组队",
      text = string.format("申请 %s（%s%s）", tostring(a.name), tostring(a.template), model),
    }
  end
  if name == "board_update" then
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
  if name == "card_update" then
    return {
      title = "卡片",
      text = string.format("%s %s", tostring(a.card or a.id), a.archive == true and "归档" or "更新"),
    }
  end
  if name == "workflow_save" then
    local workflow = type(a.workflow) == "table" and a.workflow or {}
    return { title = "流程", text = "保存 " .. tostring(workflow.name or "?") }
  end
  if name == "workflow_get" then
    return { title = "流程", text = "读取 " .. tostring(a.name) }
  end
  if name == "workflow_delete" then
    return { title = "流程", text = "删除 " .. tostring(a.name) }
  end
  if name == "bus_status" then
    return { title = "总线", text = "查看团队状态" }
  end
  if name == "bus_read" then
    return { title = "总线", text = "读取 " .. tostring(a.participant) }
  end
  return nil
end

return M
