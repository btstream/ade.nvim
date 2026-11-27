-- Built-in floating backend for the unified session browser.
--
-- This is the superset of the old session picker and cross-agent manager: one
-- window, scopes on the first line (`here`, `agent`, `all`), the per-agent
-- status line below it, and the same rows, keys and highlight groups the two
-- dialogs used before. The owner supplies a plain state table and replaces it
-- as sources update, so the window never has to be reopened for a refresh.
local icons = require("ade.ui.icons")
local highlights = require("ade.ui.highlights")
local picker = require("ade.ui.picker")
local model = require("ade.ui.session_browser.model")

local HL = highlights.picker

local M = {}

---@class AdeSessionBrowserView
---@field scopes string[] available scopes in cycle order
---@field scope string the active scope
---@field entries table[] rows for the current scope
---@field agents string[] agents shown in the status line (and filtrable)
---@field agent_state table<string, table> `{listed_at, error, can_delete}`
---@field refreshing table<string, boolean>
---@field unavailable table<string, string> agent -> why it is not listed
---@field current_agent string|nil
---@field current_id string|nil
---@field use_icons boolean|nil
---@field status string|nil transient text in the footer
---@field can_delete fun(entry: table): boolean
---@field on_open fun(entry: table)
---@field on_delete fun(entry: table, done: fun(ok: boolean))
---@field on_refresh fun()
---@field on_cycle_scope fun()
---@field on_close fun()
---@field is_dir fun(path: string): boolean

---Open the session browser.
---@param view AdeSessionBrowserView
---@return table handle
function M.open(view)
  local icon_set = icons.get(view.use_icons)
  local state = view
  local query = ""
  -- nil means "all agents"; only applies to the `all` scope.
  local agent_filter = nil
  local visible = {}
  local settled = false
  local busy = false
  local status = ""
  local ns = vim.api.nvim_create_namespace("ade_session_browser")
  local prev_win = vim.api.nvim_get_current_win()

  local width = math.max(62, math.min(120, vim.o.columns - 12))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ade_sessions"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Sessions ",
    title_pos = "center",
    width = width,
    height = 9,
    row = math.max(0, math.floor((vim.o.lines - 9) / 2) - 1),
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
    -- Tell the owner the window is gone before running a load callback: the
    -- browser must drop its listeners and in-flight requests either way.
    if type(state.on_close) == "function" then
      pcall(state.on_close)
    end
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

  local function recompute()
    if state.scope ~= "all" then
      agent_filter = nil
    end
    visible = model.visible(state.entries, query, agent_filter, state.scope)
  end

  ---@param entry table
  ---@param line string
  ---@param marker_len integer
  ---@param time_width integer
  ---@return table row
  local function row_meta(entry, line, marker_len, time_width)
    local current = entry.agent == state.current_agent and entry.sessionId == state.current_id
    return {
      entry = entry,
      line = line,
      marker_len = marker_len,
      -- The trailing timestamp, painted with the muted metadata group.
      time_start = math.max(0, #line - (time_width or 0)),
      time_width = time_width or 0,
      current = current,
      missing = is_missing(entry),
    }
  end

  local function footer_text(content)
    local hints = "<CR> open  <C-d> delete  <C-r> refresh  <Tab> scope"
    if state.scope == "all" then
      hints = hints .. "  <S-Tab> agent"
    end
    hints = hints .. "  q close"
    local prefix = query ~= "" and ("Search: " .. query) or "Type to filter"
    -- Transient messages come before the key hints: at a narrow width the
    -- hints are the part that may be cut, never "cannot delete sessions".
    local messages = {}
    if type(status) == "string" and status ~= "" then
      messages[#messages + 1] = status
    end
    if type(state.status) == "string" and state.status ~= "" then
      messages[#messages + 1] = state.status
    end
    local text = prefix
    if #messages > 0 then
      text = text .. "   " .. table.concat(messages, "   ")
    end
    text = text .. "   " .. hints
    return model.truncate(text, content)
  end

  local function render()
    local content = width - 2
    local scope_text = model.scope_line(state)
    if agent_filter then
      scope_text = scope_text .. "   agent: " .. agent_filter
    end
    local lines = {
      scope_text,
      model.agent_header_text(state, icon_set, content),
      string.rep("─", content),
    }
    local rows = {}
    local first_row_line = 4

    -- Stable columns: derived from every row, not only the filtered ones, so
    -- typing does not make the table jump sideways.
    local agent_width = 6
    for _, entry in ipairs(state.entries or {}) do
      agent_width = math.max(agent_width, math.min(12, vim.fn.strdisplaywidth(tostring(entry.agent or ""))))
    end
    agent_width = math.min(12, agent_width) + 2
    -- The title is what the user reads; the cwd is supporting context. Cap the
    -- path column at roughly a third of the row and give the rest to the title.
    local cwd_width = math.max(12, math.min(32, math.floor(content * 0.30)))
    local title_room = content - (2 + agent_width + cwd_width + 1 + 18)
    if title_room < 12 then
      cwd_width = math.max(8, cwd_width - (12 - title_room))
    end

    for _, entry in ipairs(visible) do
      local current = entry.agent == state.current_agent and entry.sessionId == state.current_id
      local marker = current and (icon_set.arrow_right .. " ") or "  "
      local cwd_text = model.short_path(entry.cwd)
      if is_missing(entry) then
        cwd_text = cwd_text .. " (missing)"
      end
      local when_text = model.short_time(entry.updatedAt)
      local left = marker
        .. model.pad_right(model.truncate(tostring(entry.agent or ""), agent_width - 1), agent_width)
        .. model.pad_right(model.truncate_left(cwd_text, cwd_width), cwd_width + 1)
      local remaining = content - vim.fn.strdisplaywidth(left)
      local time_part = when_text ~= "" and ("  " .. when_text) or ""
      local time_width = vim.fn.strdisplaywidth(time_part)
      local title_width = math.max(4, remaining - time_width)
      local title_text = model.truncate(model.label_of(entry), title_width)
      local line = left .. model.pad_right(title_text, math.max(0, remaining - time_width)) .. time_part
      line = model.truncate(line, content)
      rows[#rows + 1] = row_meta(entry, line, #marker, #time_part)
      lines[#lines + 1] = line
    end

    if #rows == 0 then
      lines[#lines + 1] = "  no matching sessions"
    end
    lines[#lines + 1] = string.rep("─", content)
    local footer = footer_text(content)
    lines[#lines + 1] = footer

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    local shown = math.max(1, math.min(#rows, 18))
    pcall(vim.api.nvim_win_set_height, win, shown + 5)

    local cursor_line
    if #rows > 0 then
      cursor_line = math.max(first_row_line, math.min(vim.api.nvim_win_get_cursor(win)[1], first_row_line + #rows - 1))
      pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    else
      cursor_line = first_row_line
      pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    end

    -- Scope tabs: the active one is emphasised.
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      end_col = #(lines[1] or ""),
      hl_group = HL.item,
    })
    local from, to = model.scope_active_range(state)
    if from then
      vim.api.nvim_buf_set_extmark(buf, ns, 0, from, {
        end_col = to,
        hl_group = HL.current,
        priority = 20,
      })
    end
    -- Agent status line and the rule below it.
    vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, {
      end_col = #(lines[2] or ""),
      hl_group = HL.item,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, 2, 0, {
      end_col = #(lines[3] or ""),
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
      if meta.time_width > 0 and meta.time_start + meta.time_width <= #meta.line + 1 then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, meta.time_start, {
          end_col = #meta.line,
          hl_group = HL.meta,
          priority = 6,
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

    for index, meta in ipairs(rows) do
      paint_row(index, meta)
    end

    vim.api.nvim_buf_set_extmark(buf, ns, #lines - 2, 0, {
      end_col = #(lines[#lines - 1] or ""),
      hl_group = HL.separator,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, {
      end_col = #footer,
      hl_group = HL.footer,
    })
    if query ~= "" then
      -- The typed query is live input, so it gets the prompt colour.
      local prompt = model.truncate("Search: " .. query, content)
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
    return visible[line - 3]
  end

  local function move(delta)
    if busy or #visible == 0 then
      return
    end
    local line = vim.api.nvim_win_get_cursor(win)[1] + delta
    if line >= 4 and line <= #visible + 3 then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      render()
    end
  end

  ---Delete the session under the cursor, asking for confirmation first.
  local function delete_current()
    if busy then
      return
    end
    local entry = current_entry()
    if not entry then
      return
    end
    local allowed = true
    if type(state.can_delete) == "function" then
      allowed = state.can_delete(entry) == true
    end
    if not allowed then
      status = "this agent cannot delete sessions"
      render()
      return
    end

    local target = entry
    local target_label = model.label_of(entry)

    -- Keep the browser alive while an asynchronous confirmation owns focus.
    busy = true
    vim.ui.select({ "Delete", "Cancel" }, {
      prompt = string.format('Delete "%s"?', target_label),
      kind = "ade_confirm_delete",
    }, function(choice)
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(win) then
          return
        end
        busy = false
        pcall(vim.api.nvim_set_current_win, win)
        if choice ~= "Delete" then
          status = ""
          render()
          return
        end

        busy = true
        status = "deleting..."
        render()
        if type(state.on_delete) ~= "function" then
          busy = false
          status = "delete failed"
          render()
          return
        end
        state.on_delete(target, function(ok)
          if not vim.api.nvim_win_is_valid(win) then
            return
          end
          busy = false
          status = ok and "deleted" or "delete failed"
          render()
        end)
      end)
    end)
  end

  ---Cycle the agent filter: all -> each configured agent -> all.
  local function cycle_agent()
    if busy or state.scope ~= "all" then
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
  map("<C-d>", delete_current, "delete session")
  map("<C-r>", function()
    if busy then
      return
    end
    if type(state.on_refresh) == "function" then
      state.on_refresh()
    end
  end, "refresh")
  map("<Tab>", function()
    if busy then
      return
    end
    if type(state.on_cycle_scope) == "function" then
      state.on_cycle_scope()
    end
  end, "next scope")
  map("<S-Tab>", cycle_agent, "filter by agent")
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
      vim.api.nvim_win_set_cursor(win, { #visible + 3, 0 })
      render()
    end
  end, "last")
  map("gg", function()
    if #visible > 0 then
      vim.api.nvim_win_set_cursor(win, { 4, 0 })
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
      -- closes the browser.
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
  handle.delete_current = delete_current
  return handle
end

return M
