-- Cross-agent session browser: every configured agent, every directory.
--
-- Like `ade.ui.session_picker` this owns a buffer instead of `vim.ui.select`,
-- because the window has per-row state (the current session marker, missing
-- directories) and its own keys (`<C-r>` refresh, `<Tab>` agent filter). It is
-- drawn from a plain state table so the caller can replace rows as
-- `sessions.updated` arrives without reopening the window.
local icons = require("ade.ui.icons")
local highlights = require("ade.ui.highlights")
local picker = require("ade.ui.picker")

local HL = highlights.picker

local M = {}

---Case-insensitive subsequence match.
---@param needle string
---@param haystack string
---@return boolean
local function fuzzy(needle, haystack)
  return picker.fuzzy_ranges(needle, haystack) ~= nil
end

---Format an ISO-ish timestamp for display.
---@param value any
---@return string
local function short_time(value)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  -- "2026-11-07T10:49:33.899Z" -> "2026-11-07 10:49"
  local date, time = value:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
  if date and time then
    return date .. " " .. time
  end
  return value:sub(1, 16)
end

---@param entry table
---@return boolean
local function has_time(entry)
  return type(entry.updatedAt) == "string" and entry.updatedAt ~= ""
end

---A row's display label: its title, or the session id when there is none.
---@param entry table
---@return string
local function label_of(entry)
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
---@param text string
---@param max integer
---@return string
local function truncate(text, max)
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
---@param text string
---@param max integer
---@return string
local function truncate_left(text, max)
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
local function pad_right(text, width)
  local missing = width - vim.fn.strdisplaywidth(text)
  if missing <= 0 then
    return text
  end
  return text .. string.rep(" ", missing)
end

---Shorten an absolute path to `~` form, as the session picker does.
---@param path any
---@return string
local function short_path(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  local ok, value = pcall(vim.fn.fnamemodify, path, ":~")
  return ok and value or path
end

---@param err any
---@return string
local function error_text(err)
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
local function compare_entries(a, b)
  local at, bt = has_time(a), has_time(b)
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
  return label_of(a):lower() < label_of(b):lower()
end

---@class AdeSessionManagerView
---@field agents string[] every configured agent, sorted
---@field entries table[] catalog entries (`agent, sessionId, cwd, title, updatedAt`)
---@field agent_state table<string, table> `{listed_at, error}` per agent
---@field refreshing table<string, boolean>
---@field unavailable table<string, string> agent -> why it is not listed
---@field current_agent string|nil
---@field current_id string|nil
---@field use_icons boolean|nil
---@field status string|nil transient text in the footer
---@field on_open fun(entry: table)
---@field on_refresh fun()
---@field is_dir fun(path: string): boolean

---Open the cross-agent browser.
---@param view AdeSessionManagerView
---@return table handle
function M.open(view)
  local icon_set = icons.get(view.use_icons)
  local state = view
  local query = ""
  -- nil means "all agents"; otherwise one configured agent id.
  local agent_filter = nil
  local visible = {}
  local settled = false
  local busy = false
  local ns = vim.api.nvim_create_namespace("ade_session_manager")
  local prev_win = vim.api.nvim_get_current_win()

  local width = math.max(62, math.min(120, vim.o.columns - 12))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ade_session_manager"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Sessions (all agents) ",
    title_pos = "center",
    width = width,
    height = 8,
    row = math.max(0, math.floor((vim.o.lines - 8) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  -- `style = "minimal"` installs its own Normal/FloatBorder mapping, so the
  -- picker groups have to be applied after the window exists.
  vim.wo[win].winhighlight = highlights.picker_winhl()

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if prev_win and vim.api.nvim_win_is_valid(prev_win) and prev_win ~= win then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
  end

  local function finish(fn, ...)
    if settled then
      return
    end
    settled = true
    close()
    if fn then
      fn(...)
    end
  end

  ---@param entry table
  ---@return boolean
  local function is_missing(entry)
    if type(state.is_dir) ~= "function" then
      return false
    end
    return not state.is_dir(entry.cwd or "")
  end

  ---@param agent string
  ---@return string
  local function agent_header(agent)
    local reason = state.unavailable and state.unavailable[agent]
    if type(reason) == "string" and reason ~= "" then
      return agent .. " " .. icon_set.agent_unavailable .. " " .. truncate(reason, 22)
    end
    if state.refreshing and state.refreshing[agent] then
      return agent .. " " .. icon_set.agent_refreshing
    end
    local agent_state = state.agent_state and state.agent_state[agent]
    if agent_state and agent_state.error then
      return agent .. " " .. icon_set.agent_error .. " " .. truncate(error_text(agent_state.error), 22)
    end
    local count = 0
    for _, entry in ipairs(state.entries or {}) do
      if entry.agent == agent then
        count = count + 1
      end
    end
    return agent .. " " .. icon_set.agent_installed .. " " .. tostring(count)
  end

  local function header_text()
    local parts = {}
    for _, agent in ipairs(state.agents or {}) do
      parts[#parts + 1] = agent_header(agent)
    end
    if #parts == 0 then
      return "no agents configured"
    end
    return truncate(table.concat(parts, "   "), width - 2)
  end

  local function recompute()
    local list = {}
    for _, entry in ipairs(state.entries or {}) do
      local matches_agent = agent_filter == nil or entry.agent == agent_filter
      if matches_agent then
        local haystack = tostring(entry.agent or "") .. " " .. tostring(entry.cwd or "") .. " " .. label_of(entry)
        if query == "" or fuzzy(query, haystack) then
          list[#list + 1] = entry
        end
      end
    end
    table.sort(list, compare_entries)
    visible = list
  end

  ---@param entry table
  ---@param line string
  ---@param marker_len integer
  ---@return table row
  local function row_meta(entry, line, marker_len)
    local current = entry.agent == state.current_agent and entry.sessionId == state.current_id
    return {
      entry = entry,
      line = line,
      marker_len = marker_len,
      current = current,
      missing = is_missing(entry),
    }
  end

  local function render()
    local content = width - 2
    local lines = { header_text(), string.rep("─", content) }
    local rows = {}
    local first_row_line = 3

    -- Stable columns: derived from every row, not only the filtered ones, so
    -- typing does not make the table jump sideways.
    local agent_width = 6
    for _, entry in ipairs(state.entries or {}) do
      agent_width = math.max(agent_width, math.min(12, vim.fn.strdisplaywidth(tostring(entry.agent or ""))))
    end
    agent_width = math.min(12, agent_width) + 2
    local cwd_width = math.max(16, math.min(40, math.floor(content * 0.34)))

    for _, entry in ipairs(visible) do
      local current = entry.agent == state.current_agent and entry.sessionId == state.current_id
      local marker = current and (icon_set.arrow_right .. " ") or "  "
      local cwd_text = short_path(entry.cwd)
      if is_missing(entry) then
        cwd_text = cwd_text .. " (missing)"
      end
      local when_text = short_time(entry.updatedAt)
      local left = marker
        .. pad_right(truncate(tostring(entry.agent or ""), agent_width - 1), agent_width)
        .. pad_right(truncate_left(cwd_text, cwd_width), cwd_width + 1)
      local remaining = content - vim.fn.strdisplaywidth(left)
      local time_part = when_text ~= "" and ("  " .. when_text) or ""
      local time_width = vim.fn.strdisplaywidth(time_part)
      local title_width = math.max(4, remaining - time_width)
      local title_text = truncate(label_of(entry), title_width)
      local line = left .. pad_right(title_text, math.max(0, remaining - time_width)) .. time_part
      line = truncate(line, content)
      rows[#rows + 1] = row_meta(entry, line, #marker)
      lines[#lines + 1] = line
    end

    if #rows == 0 then
      lines[#lines + 1] = "  no matching sessions"
    end
    lines[#lines + 1] = string.rep("─", content)

    local filter_label = agent_filter and ("[agent: " .. agent_filter .. "]") or nil
    local prefix = query ~= "" and ("Search: " .. query) or "Type to filter"
    if filter_label then
      prefix = prefix .. "   " .. filter_label
    end
    local footer = prefix .. "   <CR> open  <C-r> refresh  <Tab> agent filter  q close"
    if type(state.status) == "string" and state.status ~= "" then
      footer = footer .. "   " .. state.status
    end
    footer = truncate(footer, content)
    lines[#lines + 1] = footer

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    local shown = math.max(1, math.min(#rows, 18))
    pcall(vim.api.nvim_win_set_height, win, shown + 4)

    local cursor_line
    if #rows > 0 then
      cursor_line = math.max(first_row_line, math.min(vim.api.nvim_win_get_cursor(win)[1], first_row_line + #rows - 1))
      pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    else
      cursor_line = first_row_line
      pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    end

    -- Header: agent names in the item colour, their state in the muted one.
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      end_col = #(lines[1] or ""),
      hl_group = HL.item,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, {
      end_col = #(lines[2] or ""),
      hl_group = HL.separator,
    })

    if #rows == 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, first_row_line - 1, 0, {
        end_col = #(lines[first_row_line] or ""),
        hl_group = HL.empty,
      })
    end

    local function paint_row(index, meta)
      local row = first_row_line + index - 1
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        end_row = row - 1,
        end_col = #meta.line,
        hl_group = HL.item,
        priority = 5,
      })
      if row == cursor_line then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
          end_row = row - 1,
          end_col = #meta.line,
          hl_group = HL.selection,
          priority = 10,
        })
      end
      if meta.missing then
        -- Dim a row whose directory is gone: it cannot be opened, and the
        -- `(missing)` suffix says why.
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
          end_row = row - 1,
          end_col = #meta.line,
          hl_group = HL.description,
          priority = 12,
        })
      end
      if meta.current then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
          end_col = meta.marker_len,
          hl_group = HL.current,
          priority = 20,
        })
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, meta.marker_len, {
          end_col = #meta.line,
          hl_group = HL.current_item,
          priority = 15,
        })
      end
      for _, range in ipairs(picker.fuzzy_ranges(query, meta.line) or {}) do
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, range.s, {
          end_col = range.e,
          hl_group = HL.match,
          priority = 30,
        })
      end
    end

    if #rows > 0 then
      for index, meta in ipairs(rows) do
        paint_row(index, meta)
      end
    end

    vim.api.nvim_buf_set_extmark(buf, ns, #lines - 2, 0, {
      end_col = #(lines[#lines - 1] or ""),
      hl_group = HL.separator,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, {
      end_col = #(lines[#lines] or ""),
      hl_group = HL.footer,
    })
    if query ~= "" then
      -- The typed query is live input, so it gets the prompt colour.
      local prompt = truncate("Search: " .. query, content)
      vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, {
        end_col = #prompt,
        hl_group = HL.prompt,
        priority = 20,
      })
    end
  end

  ---@return table|nil
  local function current_entry()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    return visible[line - 2]
  end

  local function move(delta)
    if busy or #visible == 0 then
      return
    end
    local line = vim.api.nvim_win_get_cursor(win)[1] + delta
    if line >= 3 and line <= #visible + 2 then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      render()
    end
  end

  ---Cycle the agent filter: all -> each configured agent -> all.
  local function cycle_agent()
    if busy then
      return
    end
    local agents = state.agents or {}
    if #agents == 0 then
      return
    end
    local index = 0
    if agent_filter then
      for position, agent in ipairs(agents) do
        if agent == agent_filter then
          index = position
          break
        end
      end
    end
    agent_filter = agents[index + 1]
    recompute()
    render()
  end

  -- Install text mappings first so navigation/close bindings below win.
  for _, char in ipairs(vim.fn.split("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-_.@", "\\zs")) do
    vim.keymap.set("n", char, function()
      if busy then
        return
      end
      query = query .. char:lower()
      recompute()
      render()
    end, { buffer = buf, nowait = char ~= "g", silent = true })
  end

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map("<CR>", function()
    if busy then
      return
    end
    local entry = current_entry()
    if entry and type(state.on_open) == "function" then
      -- The app closes the window when a load really starts: a refusal (missing
      -- directory, pinned cwd) leaves it open, as does a cancelled switch.
      state.on_open(entry)
    end
  end, "open session")
  map("<C-r>", function()
    if busy then
      return
    end
    if type(state.on_refresh) == "function" then
      state.on_refresh()
    end
  end, "refresh")
  map("<Tab>", cycle_agent, "filter by agent")
  map("<Esc>", function()
    finish(nil)
  end, "close")
  map("q", function()
    finish(nil)
  end, "close")
  map("<C-c>", function()
    finish(nil)
  end, "close")
  map("j", function()
    move(1)
  end, "next")
  map("k", function()
    move(-1)
  end, "previous")
  map("<C-n>", function()
    move(1)
  end, "next")
  map("<C-p>", function()
    move(-1)
  end, "previous")
  map("G", function()
    if #visible > 0 then
      vim.api.nvim_win_set_cursor(win, { #visible + 2, 0 })
      render()
    end
  end, "last")
  map("gg", function()
    if #visible > 0 then
      vim.api.nvim_win_set_cursor(win, { 3, 0 })
      render()
    end
  end, "first")
  map("<BS>", function()
    if query ~= "" then
      query = query:sub(1, -2)
      recompute()
      render()
    end
  end, "erase filter")
  map("<C-u>", function()
    query = ""
    recompute()
    render()
  end, "clear filter")

  recompute()
  render()

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    callback = function()
      -- A confirmation picker takes focus away on purpose; only a real leave
      -- closes the manager.
      if not busy then
        finish(nil)
      end
    end,
  })

  local handle = { win = win, buf = buf }
  ---Replace the state and repaint. A closed window ignores late updates.
  function handle:update(next_state)
    if settled then
      return
    end
    if next_state then
      state = next_state
    end
    recompute()
    render()
  end
  ---Keep the window open while a modal confirmation owns focus.
  function handle:set_busy(value)
    busy = value == true
  end
  function handle:close()
    finish(nil)
  end
  function handle:is_open()
    return not settled and vim.api.nvim_win_is_valid(win)
  end
  -- Test hooks: the filtered rows and the rendered buffer.
  function handle:visible()
    local out = {}
    for _, entry in ipairs(visible) do
      out[#out + 1] = entry
    end
    return out
  end
  function handle:lines()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  function handle:query()
    return query
  end
  function handle:agent_filter()
    return agent_filter
  end
  return handle
end

return M
