-- Row model for the unified session browser.
--
-- Both backends (the built-in float and snacks) need the same labels, sort
-- order, fuzzy match and width-aware truncation; keeping them here means a row
-- looks the same whichever picker is configured.
local picker = require("ade.ui.picker")
local time = require("ade.ui.time")

local M = {}

---@type table<string, string>
M.scope_titles = {
  here = "current folder",
  agent = "current agent",
  all = "all agents",
}

---Case-insensitive subsequence match.
---@param needle string
---@param haystack string
---@return boolean
function M.fuzzy(needle, haystack)
  return picker.fuzzy_ranges(needle, haystack) ~= nil
end

---Format an ISO-ish timestamp in local time for display.
---@param value any
---@return string
function M.short_time(value)
  return time.short(value)
end

---@param entry table
---@return boolean
function M.has_time(entry)
  return type(entry.updatedAt) == "string" and entry.updatedAt ~= ""
end

---A row's display label: its title, or the session id when there is none.
---@param entry table
---@return string
function M.label_of(entry)
  if type(entry.title) == "string" and entry.title ~= "" then
    -- A buffer line cannot contain a newline; agent supplied titles may.
    return (entry.title:gsub("[\r\n]", " "))
  end
  return tostring(entry.sessionId or "")
end

---Split a string into user-perceived characters for width-aware truncation.
---@param text string
---@return string[]
local function chars_of(text)
  return vim.fn.split(text, "\\zs")
end

---Keep the beginning of `text`, adding an ellipsis when it does not fit.
---@param text any
---@param max integer
---@return string
function M.truncate(text, max)
  text = tostring(text or "")
  if max <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max then
    return text
  end
  local out, width = {}, 0
  for _, char in ipairs(chars_of(text)) do
    local char_width = vim.fn.strdisplaywidth(char)
    if width + char_width > max - 1 then
      break
    end
    out[#out + 1] = char
    width = width + char_width
  end
  return table.concat(out) .. "…"
end

---Keep the end of `text`, adding a leading ellipsis. Paths are read from the
---right: the leaf directory says where a session lives, the prefix does not.
---@param text any
---@param max integer
---@return string
function M.truncate_left(text, max)
  text = tostring(text or "")
  if max <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max then
    return text
  end
  local out, width = {}, 0
  local chars = chars_of(text)
  for index = #chars, 1, -1 do
    local char_width = vim.fn.strdisplaywidth(chars[index])
    if width + char_width > max - 1 then
      break
    end
    table.insert(out, 1, chars[index])
    width = width + char_width
  end
  return "…" .. table.concat(out)
end

---@param text string
---@param width integer
---@return string
function M.pad_right(text, width)
  local missing = width - vim.fn.strdisplaywidth(text)
  if missing <= 0 then
    return text
  end
  return text .. string.rep(" ", missing)
end

---Shorten an absolute path to `~` form.
---@param path any
---@return string
function M.short_path(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  local ok, value = pcall(vim.fn.fnamemodify, path, ":~")
  return ok and value or path
end

---@param err any
---@return string
function M.error_text(err)
  if type(err) == "table" then
    return tostring(err.message or err.code or "failed")
  end
  return tostring(err or "failed")
end

---Sort rows by `updatedAt` descending, with undated rows last, then by agent
---and title. ISO 8601 timestamps compare correctly as strings.
---@param a table
---@param b table
---@return boolean
function M.compare_entries(a, b)
  local at, bt = M.has_time(a), M.has_time(b)
  if at ~= bt then
    return at
  end
  if at and a.updatedAt ~= b.updatedAt then
    return a.updatedAt > b.updatedAt
  end
  local aa, ba = tostring(a.agent or ""), tostring(b.agent or "")
  if aa ~= ba then
    return aa < ba
  end
  return M.label_of(a):lower() < M.label_of(b):lower()
end

---The text a query is matched against for one scope.
---
---`here` keeps the old session picker's semantics: only the title and the
---session id, because every row shares the editor's cwd and a fuzzy
---subsequence over a long absolute path would match almost any short query.
---`agent`/`all` keep the old cross-agent manager's agent + cwd + title.
---@param entry table
---@param scope string|nil
---@return string
function M.haystack(entry, scope)
  if scope == "here" or scope == nil then
    return M.label_of(entry) .. " " .. tostring(entry.sessionId or "")
  end
  return tostring(entry.agent or "") .. " " .. tostring(entry.cwd or "") .. " " .. M.label_of(entry)
end

---Filter then sort the rows for display.
---@param entries table[]
---@param query string
---@param agent_filter string|nil
---@param scope string|nil
---@return table[]
function M.visible(entries, query, agent_filter, scope)
  local list = {}
  for _, entry in ipairs(entries or {}) do
    local matches_agent = agent_filter == nil or entry.agent == agent_filter
    if matches_agent then
      local haystack = M.haystack(entry, scope)
      if query == "" or M.fuzzy(query, haystack) then
        list[#list + 1] = entry
      end
    end
  end
  table.sort(list, M.compare_entries)
  return list
end

---One agent's entry in the status header.
---@param agent string
---@param state table
---@param icons table
---@return string
function M.agent_header(agent, state, icons)
  local reason = state.unavailable and state.unavailable[agent]
  if type(reason) == "string" and reason ~= "" then
    return agent .. " " .. icons.agent_unavailable .. " " .. M.truncate(reason, 22)
  end
  if state.refreshing and state.refreshing[agent] then
    return agent .. " " .. icons.agent_refreshing
  end
  local agent_state = state.agent_state and state.agent_state[agent]
  if agent_state and agent_state.error then
    return agent .. " " .. icons.agent_error .. " " .. M.truncate(M.error_text(agent_state.error), 22)
  end
  local count = 0
  for _, entry in ipairs(state.entries or {}) do
    if entry.agent == agent then
      count = count + 1
    end
  end
  return agent .. " " .. icons.agent_installed .. " " .. tostring(count)
end

---The per-agent status line.
---@param state table
---@param icons table
---@param width integer
---@return string
function M.agent_header_text(state, icons, width)
  local parts = {}
  for _, agent in ipairs(state.agents or {}) do
    parts[#parts + 1] = M.agent_header(agent, state, icons)
  end
  if #parts == 0 then
    return "no agents configured"
  end
  return M.truncate(table.concat(parts, "   "), width)
end

---The scope tab line, e.g. `[here]  agent  all`.
---@param state table
---@return string
function M.scope_line(state)
  local parts = {}
  for _, scope in ipairs(state.scopes or {}) do
    parts[#parts + 1] = scope == state.scope and ("[" .. scope .. "]") or scope
  end
  local text = table.concat(parts, "  ")
  if state.scope == "all" and type(state.agent_filter) == "string" then
    text = text .. "   agent: " .. state.agent_filter
  end
  return text
end

---Byte range of the active scope label inside `scope_line`, for highlighting.
---@param state table
---@return integer|nil
function M.scope_active_range(state)
  local offset = 0
  for _, scope in ipairs(state.scopes or {}) do
    if scope == state.scope then
      return offset, offset + #scope + 1
    end
    offset = offset + #scope + 2
  end
end

return M
