-- The wide dashboard: members and board, plus an optional right column
-- (watch window or the mounted leader chat/input). Widths are byte-agnostic;
-- window widths are display cells by definition.
local Text = require("ade.ui.team.text")

local M = {}

local Tab = {}
Tab.__index = Tab

local PANELS = { "members", "board" }

---@param dashboard table
function M.new(dashboard)
  return setmetatable({
    dashboard = dashboard,
    tab = nil,
    original_tab = nil,
    panels = {},
    buffers = {},
    meta = {},
    ids = {},
    marks = {},
    mark_ns = vim.api.nvim_create_namespace("ade-team-board-marks"),
    cursor_ns = vim.api.nvim_create_namespace("ade-team-board-cursor"),
    active = "members",
    watch_win = nil,
    leader_windows = nil,
    group = nil,
    closing = false,
    members_width = nil,
    watch_width = nil,
    resizing = false,
    resize_token = 0,
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
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  if name == "members" then
    pcall(function()
      vim.wo[win].winfixwidth = true
    end)
  end
  self.panels[name] = win
  return win
end

---Our own resizes must not be mistaken for a user drag.
function Tab:begin_resize()
  self.resizing = true
  self.resize_token = (self.resize_token or 0) + 1
  -- `WinResized` can arrive a tick after a programmatic split; keep a small
  -- window in which such events are our own, not a user drag (M1).
  self.ignore_until = (vim.uv.now() or 0) + 200
end

function Tab:end_resize()
  self.resize_token = (self.resize_token or 0) + 1
  local token = self.resize_token
  vim.schedule(function()
    if self.resize_token == token then
      self.resizing = false
    end
  end)
end

---@param win integer|nil
---@param width integer
function Tab:set_width(win, width)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if vim.api.nvim_win_get_width(win) == width then
    return
  end
  pcall(vim.api.nvim_win_set_width, win, width)
end

function Tab:open()
  self.dashboard.layout = self
  if self:is_open() then
    vim.api.nvim_set_current_tabpage(self.tab)
    self:refresh()
    return true
  end
  local cfg = self.dashboard.config() or {}
  local dashboard_cfg = type(cfg.teams) == "table" and (cfg.teams.dashboard or {}) or {}
  self.members_width = math.max(16, math.min(120, tonumber(dashboard_cfg.members_width) or 32))
  self.watch_width = nil
  self.original_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  self.tab = vim.api.nvim_get_current_tabpage()
  local scratch = vim.api.nvim_get_current_buf()
  local members = self:make_window("members")
  if scratch ~= self.buffers.members and vim.api.nvim_buf_is_valid(scratch) then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
  self:begin_resize()
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  vim.cmd("vsplit")
  self:make_window("board")
  self:set_width(members, self.members_width)
  vim.o.equalalways = equalalways
  self:end_resize()
  for _, name in ipairs(PANELS) do
    self.dashboard:attach_keys(self.buffers[name])
  end
  self.group = vim.api.nvim_create_augroup("AdeTeamTab" .. self.tab, { clear = true })
  local function enter()
    local win = vim.api.nvim_get_current_win()
    for _, name in ipairs(PANELS) do
      if self.panels[name] == win then
        self.active = name
        self.dashboard:update_board_cursor()
        break
      end
    end
  end
  vim.api.nvim_create_autocmd("WinEnter", { group = self.group, callback = enter })
  vim.api.nvim_create_autocmd("CursorMoved", { group = self.group, callback = enter })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.group,
    callback = function()
      vim.schedule(function()
        local cfg = self.dashboard.config() or {}
        local wide = tonumber(((cfg.teams or {}).dashboard or {}).wide) or 160
        if vim.o.columns < wide then
          pcall(function()
            require("ade.controller").open_team()
          end)
          return
        end
        self:refresh()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = self.group,
    callback = function()
      if self.closing then
        return
      end
      if self.ignore_until and (vim.uv.now() or 0) < self.ignore_until then
        -- A split/close is still settling; this is our own rounding, not a
        -- user drag. `resize()` already reasserted the recorded widths.
        return
      end
      local changed = false
      local members = self.panels.members
      if members and vim.api.nvim_win_is_valid(members) then
        local width = vim.api.nvim_win_get_width(members)
        if width ~= self.members_width then
          self.members_width = width
          changed = true
        end
      end
      local right = self:right_win()
      if right then
        local width = vim.api.nvim_win_get_width(right)
        if width ~= self.watch_width then
          self.watch_width = width
          changed = true
        end
      end
      if changed then
        -- Re-render with the new width so truncation follows the user's drag.
        vim.schedule(function()
          self:refresh()
        end)
      end
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
  self:refresh()
  vim.api.nvim_set_current_win(members)
  return true
end

---@return integer|nil
function Tab:right_win()
  if self.watch_win and vim.api.nvim_win_is_valid(self.watch_win) then
    return self.watch_win
  end
  local mounted = self.leader_windows
  if mounted then
    for _, win in ipairs({ mounted.chat, mounted.input }) do
      if win and vim.api.nvim_win_is_valid(win) then
        return win
      end
    end
  end
  return nil
end

function Tab:right_windows()
  local out = {}
  if self.watch_win and vim.api.nvim_win_is_valid(self.watch_win) then
    out[#out + 1] = self.watch_win
  end
  local mounted = self.leader_windows
  if mounted then
    for _, win in ipairs({ mounted.chat, mounted.input }) do
      if win and vim.api.nvim_win_is_valid(win) then
        out[#out + 1] = win
      end
    end
  end
  return out
end

---Register the leader chat/input windows as the right column (B3).
---@param chat integer
---@param input integer
function Tab:set_leader_windows(chat, input)
  self.leader_windows = { chat = chat, input = input }
  self:resize()
  self:refresh()
end

function Tab:clear_leader_windows()
  self.leader_windows = nil
  self:resize()
end

---Only set widths we own. The board fills whatever remains, so a refresh can
---never squeeze a mounted leader chat (B3).
function Tab:resize()
  if not self:is_open() then
    return
  end
  local members = math.max(4, math.min(tonumber(self.members_width) or 32, math.max(4, vim.o.columns - 20)))
  local rights = self:right_windows()
  if #rights > 0 then
    local available = math.max(24, vim.o.columns - members - 2)
    local right_width = self.watch_width or math.max(20, math.floor(available * 0.48))
    right_width = math.max(16, math.min(right_width, available - 20))
    for _, win in ipairs(rights) do
      self:set_width(win, right_width)
    end
  end
  -- Last: resizing the right column can shave a cell off a fixed-width member
  -- pane, and that rounding must not become the recorded width (M1).
  self:set_width(self.panels.members, members)
end

function Tab:set_lines(name, lines, marks)
  local buf = self.buffers[name]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  Text.apply_marks(buf, self.mark_ns, marks)
end

function Tab:refresh()
  if not self:is_open() then
    return
  end
  -- Sizes first: the board renders to the window width it is about to get.
  self:resize()
  local ok, rendered = pcall(self.dashboard.render_tab, self.dashboard, self)
  if not ok then
    local message = "dashboard error: " .. tostring(rendered)
    vim.notify(message, vim.log.levels.ERROR)
    rendered = { members = { message }, board = { message }, meta = {}, ids = {}, marks = {} }
  end
  self.meta = rendered.meta
  self.ids = rendered.ids
  self.marks = rendered.marks or {}
  self.last_lines = self.last_lines or {}
  for _, name in ipairs(PANELS) do
    local lines = rendered[name] or {}
    if not vim.deep_equal(self.last_lines[name], lines) then
      local marks = {}
      for _, mark in ipairs(rendered.marks or {}) do
        if mark.panel == name then
          marks[#marks + 1] = mark
        end
      end
      self:set_lines(name, lines, marks)
      self.last_lines[name] = vim.deepcopy(lines)
    end
  end
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

---Current object under the cursor. Board cells use byte offsets.
function Tab:current()
  local panel, win = self:cursor_panel()
  if not panel then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = cursor[1]
  local column = cursor[2] -- already a byte offset
  local entries = self.meta[panel] or {}
  local info = entries[line]
  if not info then
    return nil
  end
  if panel == "board" and info.cells then
    for _, cell in ipairs(info.cells) do
      if column >= cell.start and column < cell.stop then
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
  end
end

function Tab:focus(name)
  local win = self.panels[name]
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    self.active = name
  end
end

function Tab:open_watch_host()
  if self.watch_win and vim.api.nvim_win_is_valid(self.watch_win) then
    return self.watch_win
  end
  local board = self.panels.board
  if not (board and vim.api.nvim_win_is_valid(board)) then
    return nil
  end
  self:begin_resize()
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  vim.api.nvim_set_current_win(board)
  vim.cmd("botright vsplit")
  self.watch_win = vim.api.nvim_get_current_win()
  self:resize()
  vim.o.equalalways = equalalways
  self:end_resize()
  return self.watch_win
end

function Tab:close_watch_host()
  local win = self.watch_win
  self.watch_win = nil
  self:begin_resize()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  -- Closing the right column must not let the members pane absorb a rounding
  -- cell and persist it as a user choice (M1).
  self:resize()
  self:end_resize()
end

function Tab:close()
  local original = self.original_tab
  local tab = self.tab
  local buffers = self.buffers
  self.closing = true
  self.tab, self.original_tab = nil, nil
  self.panels, self.buffers, self.meta, self.ids, self.marks = {}, {}, {}, {}, {}
  self.last_lines = {}
  self.watch_win, self.leader_windows = nil, nil
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
  local tabs = vim.api.nvim_list_tabpages()
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    if #tabs > 1 then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
    else
      local wins = vim.api.nvim_tabpage_list_wins(tab)
      local keep = {}
      for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
          local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
          if ft == "ade_chat" or ft == "ade_input" then
            keep[win] = true
          end
        end
      end
      local kept = 0
      for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
          if keep[win] then
            kept = kept + 1
          else
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
      end
      if kept == 0 then
        local remaining = vim.api.nvim_tabpage_list_wins(tab)
        local win = remaining[1]
        if win and vim.api.nvim_win_is_valid(win) then
          local buf = vim.api.nvim_create_buf(true, false)
          require("ade.layout").set_window_buffer(win, buf)
          pcall(vim.api.nvim_set_current_win, win)
        else
          vim.cmd("enew")
        end
      end
    end
  end
  if original and vim.api.nvim_tabpage_is_valid(original) then
    pcall(vim.api.nvim_set_current_tabpage, original)
  end
  for _, buf in pairs(buffers) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if #vim.api.nvim_list_wins() == 0 then
    vim.cmd("enew")
  end
  self.closing = false
end

M.Tab = Tab
M.PANELS = PANELS
return M
