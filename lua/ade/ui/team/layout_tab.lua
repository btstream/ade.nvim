-- The wide team dashboard: a tabpage with members, inbox, board and detail
-- (W0f 6.1), plus a right-hand watch column.
local M = {}

local Tab = {}
Tab.__index = Tab

local PANELS = { "members", "inbox", "board", "detail" }

---@param dashboard table
---@return table
function M.new(dashboard)
  return setmetatable({
    dashboard = dashboard,
    tab = nil,
    original_tab = nil,
    panels = {},
    buffers = {},
    meta = {},
    ids = {},
    active = "members",
    watch_win = nil,
    group = nil,
    closing = false,
  }, Tab)
end

function Tab:is_open()
  return self.tab ~= nil and vim.api.nvim_tabpage_is_valid(self.tab)
end

function Tab:buf(name)
  return self.buffers[name]
end

function Tab:win(name)
  return self.panels[name]
end

function Tab:ensure_buffer(name)
  local buf = self.buffers[name]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "ade_team_" .. name
  self.buffers[name] = buf
  return buf
end

function Tab:make_window(name)
  local win = vim.api.nvim_get_current_win()
  local buf = self:ensure_buffer(name)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = name == "detail"
  vim.wo[win].cursorline = true
  self.panels[name] = win
  return win
end

function Tab:open()
  self.dashboard.layout = self
  if self:is_open() then
    vim.api.nvim_set_current_tabpage(self.tab)
    self:refresh()
    return true
  end
  self.original_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  self.tab = vim.api.nvim_get_current_tabpage()
  local scratch = vim.api.nvim_get_current_buf()
  local members = self:make_window("members")
  if scratch ~= self.buffers.members and vim.api.nvim_buf_is_valid(scratch) then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
  vim.cmd("vsplit")
  local board = self:make_window("board")
  vim.api.nvim_set_current_win(members)
  vim.cmd("split")
  local inbox = self:make_window("inbox")
  vim.cmd("botright split")
  local detail = self:make_window("detail")
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  local width = vim.o.columns
  pcall(vim.api.nvim_win_set_width, members, math.floor(width * 0.4))
  pcall(vim.api.nvim_win_set_width, inbox, math.floor(width * 0.4))
  pcall(vim.api.nvim_win_set_height, detail, math.max(6, math.floor((vim.o.lines - vim.o.cmdheight) * 0.25)))
  vim.o.equalalways = equalalways
  for _, name in ipairs(PANELS) do
    self.dashboard:attach_keys(self.buffers[name])
  end
  self.group = vim.api.nvim_create_augroup("AdeTeamTab" .. self.tab, { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = self.group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      for _, name in ipairs(PANELS) do
        if self.panels[name] == win then
          self.active = name
          self.dashboard:update_detail()
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self.group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      for _, name in ipairs(PANELS) do
        if self.panels[name] == win then
          self.active = name
          self.dashboard:update_detail()
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.group,
    callback = function()
      vim.schedule(function()
        self:resize()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    callback = function(args)
      local closed = tonumber(args.match)
      if self.closing then
        return
      end
      for _, name in ipairs(PANELS) do
        if self.panels[name] == closed then
          vim.schedule(function()
            if not self.closing then
              self.dashboard:close(true)
            end
          end)
          return
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = self.group,
    callback = function()
      vim.schedule(function()
        if not self:is_open() then
          self.dashboard:close(true)
        end
      end)
    end,
  })
  self:resize()
  self:refresh()
  vim.api.nvim_set_current_win(members)
  self.dashboard:update_detail()
  return true
end

function Tab:resize()
  if not self:is_open() then
    return
  end
  local width = vim.o.columns
  local watch = self.watch_win and vim.api.nvim_win_is_valid(self.watch_win)
  local left = watch and math.floor(width * 0.30) or math.floor(width * 0.40)
  if self.panels.members and vim.api.nvim_win_is_valid(self.panels.members) then
    pcall(vim.api.nvim_win_set_width, self.panels.members, left)
  end
  if self.panels.inbox and vim.api.nvim_win_is_valid(self.panels.inbox) then
    pcall(vim.api.nvim_win_set_width, self.panels.inbox, left)
  end
  if watch then
    pcall(vim.api.nvim_win_set_width, self.watch_win, math.floor(width * 0.34))
  end
  if self.panels.detail and vim.api.nvim_win_is_valid(self.panels.detail) then
    pcall(
      vim.api.nvim_win_set_height,
      self.panels.detail,
      math.max(6, math.floor((vim.o.lines - vim.o.cmdheight) * 0.25))
    )
  end
end

function Tab:set_lines(name, lines)
  local buf = self.buffers[name]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function Tab:refresh()
  if not self:is_open() then
    return
  end
  local ok, rendered = pcall(self.dashboard.render_tab, self.dashboard, self)
  if not ok then
    local message = "dashboard error: " .. tostring(rendered)
    vim.notify(message, vim.log.levels.ERROR)
    rendered =
      { members = { message }, inbox = { message }, board = { message }, detail = { message }, meta = {}, ids = {} }
  end
  self.meta = rendered.meta
  self.ids = rendered.ids
  self.last_lines = self.last_lines or {}
  local detail_win = self.panels.detail
  local detail_cursor
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    detail_cursor = vim.api.nvim_win_get_cursor(detail_win)
  end
  for _, name in ipairs(PANELS) do
    local lines = rendered[name] or {}
    if not vim.deep_equal(self.last_lines[name], lines) then
      self:set_lines(name, lines)
      self.last_lines[name] = vim.deepcopy(lines)
    end
  end
  if detail_cursor and detail_win and vim.api.nvim_win_is_valid(detail_win) then
    local count = vim.api.nvim_buf_line_count(self.buffers.detail)
    pcall(vim.api.nvim_win_set_cursor, detail_win, { math.min(detail_cursor[1], count), detail_cursor[2] })
  end
  self:resize()
end

function Tab:cursor_panel()
  local win = vim.api.nvim_get_current_win()
  for _, name in ipairs(PANELS) do
    if self.panels[name] == win then
      return name, win
    end
  end
  return nil, win
end

function Tab:current()
  local panel, win = self:cursor_panel()
  if not panel then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local entries = self.meta[panel] or {}
  local info = entries[line]
  if not info then
    return nil
  end
  if panel == "board" and info.cells then
    local column = vim.api.nvim_win_get_cursor(win)[2] + 1
    for _, cell in ipairs(info.cells) do
      if column >= cell.start + 1 and column <= cell.stop then
        if cell.card then
          return "card", nil, cell.card, cell
        end
        return "board_cell", nil, nil, cell
      end
    end
  end
  return info.kind, info.team, info.name or info.item or info.card or info.stage, info
end

function Tab:cycle(direction)
  local _, win = self:cursor_panel()
  local index = 1
  for position, name in ipairs(PANELS) do
    if self.panels[name] == win then
      index = position
    end
  end
  index = ((index - 1 + direction) % #PANELS) + 1
  local target = self.panels[PANELS[index]]
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
    self.active = PANELS[index]
    self.dashboard:update_detail()
  end
end

function Tab:focus(name)
  local win = self.panels[name]
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    self.active = name
  end
end

---Create the host window for the watch column (right side of the tab).
---@return integer|nil
function Tab:open_watch_host()
  if self.watch_win and vim.api.nvim_win_is_valid(self.watch_win) then
    return self.watch_win
  end
  local board = self.panels.board
  if not (board and vim.api.nvim_win_is_valid(board)) then
    return nil
  end
  vim.api.nvim_set_current_win(board)
  vim.cmd("botright vsplit")
  self.watch_win = vim.api.nvim_get_current_win()
  self:resize()
  return self.watch_win
end

function Tab:close_watch_host()
  local win = self.watch_win
  self.watch_win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

function Tab:close()
  local original = self.original_tab
  local tab = self.tab
  local panels = self.panels
  self.closing = true
  self.tab, self.original_tab = nil, nil
  self.panels, self.buffers, self.meta, self.ids = {}, {}, {}, {}
  self.last_lines = {}
  self.watch_win = nil
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
  local tabs = vim.api.nvim_list_tabpages()
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    if #tabs > 1 then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
    else
      -- Closing the last tab is E784. Close only the dashboard windows and
      -- keep one normal window alive.
      local current = vim.api.nvim_get_current_win()
      for _, win in ipairs(panels) do
        if win and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      if current and vim.api.nvim_win_is_valid(current) then
        pcall(vim.api.nvim_set_current_win, current)
      end
    end
  end
  if original and vim.api.nvim_tabpage_is_valid(original) then
    pcall(vim.api.nvim_set_current_tabpage, original)
  end
  if #vim.api.nvim_list_wins() == 0 then
    vim.cmd("enew")
  end
  self.closing = false
end

M.Tab = Tab
M.PANELS = PANELS
return M
