-- The in-tab team panes: tree, members and board open in the *current*
-- tabpage.
--
-- Placement comes from `teams.layout.panes`: left/right/top/bottom splits
-- (pinned to their configured size) or `float`. With the external backend a
-- layout manager owns the geometry, so the panes are only opened as plain
-- splits; below `teams.layout.float_below` columns (native only) every pane is
-- a float sized to the pane that was actually requested, never a forced second
-- tabpage.
local M = {}

local Pane = {}
Pane.__index = Pane

local PANES = { "tree", "members", "board" }

local TITLES = {
  tree = " ade.nvim · team · 项目与会话 ",
  members = " ade.nvim · team · 成员 ",
  board = " ade.nvim · team · 看板 ",
}

local FILETYPES = {
  tree = "ade_team_tree",
  members = "ade_team_members",
  board = "ade_team_board",
}

---Whether a position shares the editor's columns (left/right) instead of its
---lines (top/bottom).
---@param position string
---@return boolean
local function horizontal(position)
  return position == "left" or position == "right"
end

---@param horizontal_axis boolean
---@return "winfixwidth"|"winfixheight"
local function pin_option(horizontal_axis)
  return horizontal_axis and "winfixwidth" or "winfixheight"
end

---@param horizontal_axis boolean
---@param win integer
---@return integer
local function win_size(horizontal_axis, win)
  if horizontal_axis then
    return vim.api.nvim_win_get_width(win)
  end
  return vim.api.nvim_win_get_height(win)
end

---@param horizontal_axis boolean
---@param win integer
---@param value integer
local function set_win_size(horizontal_axis, win, value)
  if horizontal_axis then
    pcall(vim.api.nvim_win_set_width, win, value)
  else
    pcall(vim.api.nvim_win_set_height, win, value)
  end
end

---@param dashboard table
---@return table
function M.new(dashboard)
  local self = setmetatable({
    dashboard = dashboard,
    windows = {},
    buffers = {},
    meta = {},
    ids = {},
    marks = {},
    last_lines = {},
    mark_ns = vim.api.nvim_create_namespace("ade-team-pane-marks"),
    cursor_ns = vim.api.nvim_create_namespace("ade-team-pane-cursor"),
    group = nil,
    closing = false,
    floats = {},
    -- The person-dragged width, if any. Kept apart from `members_width()`
    -- below: a field of the same name would be read back as the method through
    -- `__index`, and `nvim_win_set_width` would silently reject a function.
    adopted_width = nil,
    resizing = false,
    resize_token = 0,
  }, Pane)
  -- `Dashboard` and its callers read `layout.panels`/`layout.buffers`.
  self.panels = self.windows
  return self
end

---The effective placement backend: `teams.layout.backend = "inherit"` follows
---`layout.backend`.
---@return "native"|"external"
function Pane:backend()
  return require("ade.config").team_backend(self.dashboard.config() or {})
end

---Where a pane asks to be placed.
---@param name string
---@return string
function Pane:position(name)
  local cfg = self.dashboard.config() or {}
  local teams = cfg.teams or {}
  local pane = ((teams.layout or {}).panes or {})[name]
  local position = type(pane) == "table" and pane.position or nil
  if position == "left" or position == "right" or position == "top" or position == "bottom" or position == "float" then
    return position
  end
  return "right"
end

---The configured size of a pane on its axis, in cells; nil means "take the
---free space".
---
---A number up to 1 is a fraction of the editor, as with `layout.width`.
---@param name string
---@param position string|nil
---@return integer|nil
function Pane:size(name, position)
  position = position or self:position(name)
  local cfg = self.dashboard.config() or {}
  local teams = cfg.teams or {}
  local pane = ((teams.layout or {}).panes or {})[name]
  local size = type(pane) == "table" and tonumber(pane.size) or nil
  if size == nil and (name == "tree" or name == "members") then
    -- A configuration table that only carries the deprecated key. A
    -- normalised configuration already has it under `teams.layout`.
    local legacy = teams.dashboard
    size = type(legacy) == "table" and tonumber(legacy.members_width) or nil
  end
  if size == nil then
    return nil
  end
  local horizontal_axis = horizontal(position)
  local total = horizontal_axis and vim.o.columns or (vim.o.lines - vim.o.cmdheight)
  local cells = size <= 1 and math.floor(total * size + 0.5) or math.floor(size)
  if horizontal_axis then
    -- The configured clamp. Vim still keeps the focused window at least
    -- 'winwidth' wide, so a pane asking for less opens that wide.
    return math.max(16, math.min(120, cells))
  end
  -- Never take the whole height: the ordinary windows above/below need lines.
  return math.max(3, math.min(math.max(3, total - 4), cells))
end

---Whether same-side panes share one column/row (`teams.layout.stack`).
---@return boolean
function Pane:stack()
  local cfg = self.dashboard.config() or {}
  local layout = ((cfg.teams or {}).layout or {})
  return layout.stack == true
end

---@return integer
function Pane:wide()
  local cfg = self.dashboard.config() or {}
  local teams = cfg.teams or {}
  local value = tonumber((teams.layout or {}).float_below)
  if not value then
    value = tonumber((teams.dashboard or {}).wide)
  end
  return value or 160
end

---@return integer
function Pane:members_width()
  if tonumber(self.adopted_width) then
    return self.adopted_width
  end
  return self:size("members", "right") or 32
end

function Pane:is_open_pane(name)
  local win = self.windows[name]
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function Pane:is_open()
  for _, name in ipairs(PANES) do
    if self:is_open_pane(name) then
      return true
    end
  end
  return false
end

---@param name string
---@return integer|nil
function Pane:win(name)
  return self:is_open_pane(name) and self.windows[name] or nil
end

---@param name string
---@return integer|nil
function Pane:buf(name)
  local buf = self.buffers[name]
  return buf and vim.api.nvim_buf_is_valid(buf) and buf or nil
end

---@param name string
---@return integer
function Pane:ensure_buffer(name)
  local buf = self:buf(name)
  if buf then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = FILETYPES[name] or "ade_team"
  self.buffers[name] = buf
  return buf
end

function Pane:begin_resize()
  self.resizing = true
  self.resize_token = (self.resize_token or 0) + 1
  self.ignore_until = (vim.uv and vim.uv.now() or 0) + 200
end

function Pane:end_resize()
  self.resize_token = (self.resize_token or 0) + 1
  local token = self.resize_token
  vim.schedule(function()
    if self.resize_token == token then
      self.resizing = false
    end
  end)
end

---Panes currently on screen, in their layout order.
---@return string[]
function Pane:open_names()
  local names = {}
  for _, name in ipairs(PANES) do
    if self:is_open_pane(name) then
      names[#names + 1] = name
    end
  end
  return names
end

---Float geometry for the panes that are open (or about to be).
---@param names string[]
---@return table<string, table>
function Pane:float_geometry(names)
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.min(110, math.max(50, math.floor(columns * 0.8)))
  local total = math.max(10, math.floor(lines * 0.75))
  local each = math.max(7, math.floor(total / math.max(1, #names)))
  local top = math.max(1, math.floor((lines - each * #names) / 2))
  local out = {}
  for index, name in ipairs(names) do
    out[name] = {
      width = width,
      height = each,
      row = top + (index - 1) * each,
      col = math.max(0, math.floor((columns - width) / 2)),
    }
  end
  return out
end

---The windows of the current tabpage.
---@return integer[]
local function tab_windows()
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, vim.api.nvim_get_current_tabpage())
  return ok and wins or vim.api.nvim_list_wins()
end

---The window a new pane splits from.
---
---Always the widest (left/right) or tallest (top/bottom) ordinary window **of
---this tabpage**, never another pane and never a narrow leftover split:
---`:botright vsplit` from inside the members window puts the new pane *beside*
---it (squeezing members to its minimum and leaving the board a sliver), and
---splitting a thin stray window has the same effect. Another tab's window would
---put the new pane in the wrong tab.
---@param position string|nil
---@return integer
function Pane:split_base(position)
  local horizontal_axis = not position or horizontal(position)
  local pin = pin_option(horizontal_axis)
  -- Prefer an unpinned window: a pinned one (ade's chat, a fixed sidebar)
  -- keeps its size across the split, so it is a base only when nothing else is.
  local largest, pinned
  local size, pinned_size = 0, 0
  for _, win in ipairs(tab_windows()) do
    if self:name_of(win) == nil and vim.api.nvim_win_get_config(win).relative == "" then
      local current = win_size(horizontal_axis, win)
      if vim.wo[win][pin] then
        if current > pinned_size then
          pinned, pinned_size = win, current
        end
      elseif current > size then
        largest, size = win, current
      end
    end
  end
  return largest or pinned or vim.api.nvim_get_current_win()
end

---Pinned sizes of the ordinary (`winfixwidth`/`winfixheight`) windows of `tab`
---on one axis: ade's own chat/composer or a person's fixed split. Team panes and
---floats are left out.
---@param tab integer|nil default: the current tabpage
---@param except integer|nil a window to leave out (the one being split)
---@param horizontal_axis boolean
---@return { win: integer, size: integer }[]
function Pane:pinned_sizes(tab, except, horizontal_axis)
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, tab or vim.api.nvim_get_current_tabpage())
  local pin = pin_option(horizontal_axis)
  local out = {}
  for _, win in ipairs(ok and wins or {}) do
    if
      win ~= except
      and self:name_of(win) == nil
      and vim.api.nvim_win_get_config(win).relative == ""
      and vim.wo[win][pin]
    then
      out[#out + 1] = { win = win, size = win_size(horizontal_axis, win) }
    end
  end
  return out
end

---Widths of the pinned (`winfixwidth`) ordinary windows of `tab`.
---@param tab integer|nil
---@param except integer|nil
---@return { win: integer, size: integer }[]
function Pane:pinned_widths(tab, except)
  return self:pinned_sizes(tab, except, true)
end

---Heights of the pinned (`winfixheight`) ordinary windows of `tab`.
---@param tab integer|nil
---@param except integer|nil
---@return { win: integer, size: integer }[]
function Pane:pinned_heights(tab, except)
  return self:pinned_sizes(tab, except, false)
end

---Put pinned windows back at the sizes `pinned_sizes` saw. Opening or closing a
---team pane must not move them: Vim may hand a closed pane's cells to a pinned
---neighbour, or pull a larger pane's cells out of one.
---@param pinned { win: integer, size: integer }[]
---@param horizontal_axis boolean
local function restore_pinned(pinned, horizontal_axis)
  for _, entry in ipairs(pinned) do
    local valid = vim.api.nvim_win_is_valid(entry.win)
    if valid and win_size(horizontal_axis, entry.win) ~= entry.size then
      set_win_size(horizontal_axis, entry.win, entry.size)
    end
  end
end

---Close a team pane window without moving the pinned windows of its tab.
---
---The external backend owns the geometry, so there it only closes the window.
---@param win integer
local function close_keeping_pins(self, win)
  if self:backend() == "external" then
    pcall(vim.api.nvim_win_close, win, true)
    return
  end
  local ok, tab = pcall(vim.api.nvim_win_get_tabpage, win)
  local widths = ok and self:pinned_widths(tab) or {}
  local heights = ok and self:pinned_heights(tab) or {}
  pcall(vim.api.nvim_win_close, win, true)
  restore_pinned(widths, true)
  restore_pinned(heights, false)
end

---The open pane of the same side a new one is inserted next to, when
---`teams.layout.stack` is on.
---
---Panes on one side share a column (left/right) or a row (top/bottom) and are
---ordered by `PANES` (tree, members, board), whatever order they were opened
---in. A new pane goes before its next open successor when there is one,
---otherwise after its previous open predecessor.
---@param name string
---@param position string
---@return { win: integer, before: boolean }|nil
function Pane:side_neighbour(name, position)
  if position == "float" then
    return nil
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local index = #PANES + 1
  for position_index, candidate in ipairs(PANES) do
    if candidate == name then
      index = position_index
    end
  end
  ---@param candidate string
  ---@return integer|nil
  local function usable(candidate)
    if candidate == name or not self:is_open_pane(candidate) then
      return nil
    end
    local win = self.windows[candidate]
    local ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, win)
    if
      ok
      and win_tab == tab
      and vim.api.nvim_win_get_config(win).relative == ""
      and self:position(candidate) == position
    then
      return win
    end
    return nil
  end
  for successor = index + 1, #PANES do
    local win = usable(PANES[successor])
    if win then
      return { win = win, before = true }
    end
  end
  for predecessor = index - 1, 1, -1 do
    local win = usable(PANES[predecessor])
    if win then
      return { win = win, before = false }
    end
  end
  return nil
end

---Widen/heighten a fresh pane into the space the pinned windows leave free.
---@param win integer
---@param horizontal_axis boolean
function Pane:fill_free_space(win, horizontal_axis)
  if horizontal_axis then
    local used = 0
    for _, other in ipairs(tab_windows()) do
      if other ~= win then
        used = used + vim.api.nvim_win_get_width(other)
      end
    end
    local target = math.max(24, vim.o.columns - used)
    if target > vim.api.nvim_win_get_width(win) then
      pcall(vim.api.nvim_win_set_width, win, target)
    end
    return
  end
  -- Only windows in the new pane's own column share its lines; side-by-side
  -- windows keep their full height.
  local column = vim.api.nvim_win_get_position(win)[2]
  local used = 0
  for _, other in ipairs(tab_windows()) do
    if other ~= win and vim.api.nvim_win_get_position(other)[2] == column then
      used = used + vim.api.nvim_win_get_height(other)
    end
  end
  local target = math.max(3, vim.o.lines - vim.o.cmdheight - used)
  if target > vim.api.nvim_win_get_height(win) then
    pcall(vim.api.nvim_win_set_height, win, target)
  end
end

---Open a pane as a plain split by position.
---
---This is what the external backend does: the layout manager owns the geometry,
---so nothing is sized, pinned, adopted or restored (no width/height, no
---`winfixwidth`, no pinned restore, no float fallback).
---@param name string
---@param position string
---@return integer|nil win
---@return integer|nil previous
function Pane:create_plain_split(name, position)
  local previous = vim.api.nvim_get_current_win()
  local cmd
  if position == "left" then
    cmd = "topleft vsplit"
  elseif position == "top" then
    cmd = "topleft split"
  elseif position == "bottom" then
    cmd = "botright split"
  else
    cmd = "botright vsplit"
  end
  local ok = pcall(vim.cmd, cmd)
  if not ok then
    if previous and vim.api.nvim_win_is_valid(previous) then
      pcall(vim.api.nvim_set_current_win, previous)
    end
    return nil
  end
  return vim.api.nvim_get_current_win(), previous
end

---@param name string
---@param position string|nil
---@return integer|nil win, integer|nil previous
function Pane:create_split(name, position)
  position = position or self:position(name)
  if self:backend() == "external" then
    return self:create_plain_split(name, position)
  end
  local horizontal_axis = horizontal(position)
  local pin = pin_option(horizontal_axis)
  local previous = vim.api.nvim_get_current_win()
  -- With `teams.layout.stack` on, several panes on one side share a column/
  -- row and are inserted in `PANES` order. Off (the default) every pane opens
  -- its own column/row from the ordinary split base.
  local neighbour = self:stack() and self:side_neighbour(name, position) or nil
  local base = neighbour and neighbour.win or self:split_base(position)
  if base and base ~= previous and vim.api.nvim_win_is_valid(base) then
    pcall(vim.api.nvim_set_current_win, base)
  end
  -- Open panes carry the pin, and Vim honours it while dividing the screen:
  -- the split would hand the new pane whatever is left over instead of its
  -- configured size. Release the pins for this one split — but only this tab's
  -- team panes, and remember each one's size to restore.
  local fixed = {}
  for _, win in ipairs(tab_windows()) do
    if self:name_of(win) ~= nil and vim.wo[win][pin] then
      fixed[#fixed + 1] = { win = win, size = win_size(horizontal_axis, win) }
      pcall(function()
        vim.wo[win][pin] = false
      end)
    end
  end
  local function restore_fixed(skip, reset_size)
    for _, entry in ipairs(fixed) do
      local fixed_win = entry.win
      if fixed_win ~= skip and vim.api.nvim_win_is_valid(fixed_win) then
        if reset_size then
          -- Its own size, not the configured one: the split may have run a
          -- `WinResized` handler that adopted the squeezed size meanwhile.
          set_win_size(horizontal_axis, fixed_win, entry.size)
        end
        pcall(function()
          vim.wo[fixed_win][pin] = true
        end)
      end
    end
  end
  -- Every other pinned window of this tab (ade's own chat/composer, a
  -- person's fixed split) keeps its size: the team panes take what the split
  -- and the free cells give them, never cells Vim would pull out of a pinned
  -- window when a pane asks for more than is free. The window being split is
  -- the exception: it is where the new pane's cells come from.
  local current = vim.api.nvim_get_current_win()
  local pinned = self:pinned_sizes(nil, current, horizontal_axis)
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  local cmd
  if neighbour then
    -- Insert before the next open successor (above/left of it) or after the
    -- previous open predecessor (below/right of it), so the visual order stays
    -- tree, members, board.
    local side = neighbour.before and "aboveleft " or "belowright "
    cmd = side .. (horizontal_axis and "split" or "vsplit")
  elseif position == "left" then
    cmd = "topleft vsplit"
  elseif position == "top" then
    cmd = "topleft split"
  elseif position == "bottom" then
    cmd = "botright split"
  else
    cmd = "botright vsplit"
  end
  local ok = pcall(vim.cmd, cmd)
  if not ok then
    -- No new pane: only the pin is ours to restore; no size was touched.
    -- Restore it while 'equalalways' is still off, or re-pinning would make
    -- Vim rebalance and move the very size we are preserving.
    restore_fixed(nil, false)
    vim.o.equalalways = equalalways
    if previous and vim.api.nvim_win_is_valid(previous) then
      pcall(vim.api.nvim_set_current_win, previous)
    end
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  local size = self:size(name, position)
  if size then
    -- The new pane is current here; sizing it while pinned takes effect and
    -- survives the 'equalalways' restore below. A failed size call must not
    -- skip the restore, so both are guarded and nothing throws.
    set_win_size(horizontal_axis, win, size)
    pcall(function()
      vim.wo[win][pin] = true
    end)
  end
  -- Pin the older panes again at their own size: the split is free to shrink
  -- a pane while its pin is released, so restoring the pin alone would keep the
  -- shrunken pane. A stacked pane shares the split's axis with its neighbour,
  -- so there is nothing to restore there.
  restore_fixed(win, not neighbour)
  if not neighbour and size == nil then
    -- Fill the cells the pinned windows leave free, but never shrink below the
    -- size the split itself gave: the ordinary chat may carry the pin, so a
    -- smaller target could only squeeze this pane into a sliver.
    self:fill_free_space(win, horizontal_axis)
  end
  restore_pinned(pinned, horizontal_axis)
  vim.o.equalalways = equalalways
  if not (previous and vim.api.nvim_win_is_valid(previous)) then
    previous = win
  end
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end
  return win, previous
end

---True when `win` is a real floating window (not a split).
---@param win integer|nil
---@return boolean
local function is_float(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= ""
end

---@param name string
---@return integer|nil win
function Pane:create_float(name)
  -- Only real floats share the float geometry. A pane that is currently a
  -- split must never be turned into a float (explicit position = "float" for
  -- one pane must leave another split pane alone), so splits are not
  -- repositioned and take no space in the stack.
  local floating = {}
  for _, candidate in ipairs(PANES) do
    if is_float(self:win(candidate)) then
      floating[#floating + 1] = candidate
    end
  end
  if not vim.tbl_contains(floating, name) then
    floating[#floating + 1] = name
  end
  -- Keep PANES order so adding a pane never reshuffles the other float.
  local ordered = {}
  for _, candidate in ipairs(PANES) do
    if vim.tbl_contains(floating, candidate) then
      ordered[#ordered + 1] = candidate
    end
  end
  local geometry = self:float_geometry(ordered)
  -- Reposition the floats that are already up: two requested panes must not
  -- overlap each other.
  for _, other in ipairs(ordered) do
    local win = self:win(other)
    local geo = geometry[other]
    if is_float(win) and geo then
      pcall(vim.api.nvim_win_set_config, win, {
        relative = "editor",
        width = geo.width,
        height = geo.height,
        row = geo.row,
        col = geo.col,
        style = "minimal",
        border = "rounded",
      })
    end
  end
  local geo = geometry[name]
  local buf = self:ensure_buffer(name)
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = geo.width,
    height = geo.height,
    row = geo.row,
    col = geo.col,
    style = "minimal",
    border = "rounded",
    title = TITLES[name] or nil,
    title_pos = "center",
  })
  if not ok then
    return nil
  end
  self.floats[name] = true
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  return win
end

function Pane:apply_window_options(win, name)
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
    if not self.floats[name] then
      vim.wo[win].winbar = TITLES[name] or ""
    end
  end)
end

---@param name string
---@return boolean
function Pane:show(name)
  if name ~= "members" and name ~= "board" and name ~= "tree" then
    return false
  end
  local existing = self:win(name)
  if existing then
    pcall(vim.api.nvim_set_current_win, existing)
    self:refresh()
    return true
  end
  local position = self:position(name)
  local external = self:backend() == "external"
  local win
  if position == "float" then
    -- `position = "float"` always floats, whatever the backend or width.
    win = self:create_float(name)
  elseif external then
    -- The layout manager decides; no float fallback for narrow editors.
    win = self:create_split(name, position)
  elseif vim.o.columns >= self:wide() then
    win = self:create_split(name, position)
  else
    win = self:create_float(name)
  end
  if not (win and vim.api.nvim_win_is_valid(win)) then
    self.dashboard:notify("无法打开团队面板窗口")
    return false
  end
  local layout = require("ade.layout")
  self.windows[name] = win
  -- Register before the buffer is set: the lock guard fires on WinNew, and a
  -- pane window that inherits a locked team buffer must be recognised as ours.
  layout.track_window(win, "team_" .. name)
  local buf = self:ensure_buffer(name)
  layout.set_window_buffer(win, buf)
  self:apply_window_options(win, name)
  layout.lock_window(win)
  self.dashboard:attach_keys(buf, name)
  self:install_events()
  self:refresh()
  if external then
    -- A layout manager in external mode needs a view for the pane fts too;
    -- warn once when the user's configuration has none.
    pcall(function()
      require("ade.integrations.edgy").check_team_registered()
    end)
  end
  pcall(vim.api.nvim_set_current_win, win)
  return true
end

---Close one pane; the other pane and the ordinary panel stay untouched.
---@param name string
---@return boolean closed
function Pane:close_pane(name)
  -- Read the recorded window, not `win()`: a pane closed from outside (edgy,
  -- `:close`) is already invalid when the scheduled WinClosed handler runs, and
  -- its buffer and layout registration still need cleaning up.
  local win = self.windows[name]
  if not win then
    return false
  end
  self.windows[name] = nil
  local had_content = self.last_lines[name] ~= nil
  self.last_lines[name] = nil
  self.floats[name] = nil
  if vim.api.nvim_win_is_valid(win) then
    close_keeping_pins(self, win)
  end
  require("ade.layout").forget_window(win)
  if not self:is_open() then
    self:remove_events()
    local buf = self:buf(name)
    if buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    self.buffers[name] = nil
    -- Never leave the editor without a usable window.
    if #vim.api.nvim_list_wins() == 0 then
      vim.cmd("enew")
    end
  end
  return had_content
end

function Pane:close()
  self.closing = true
  for _, name in ipairs(PANES) do
    local win = self.windows[name]
    self.windows[name] = nil
    if win and vim.api.nvim_win_is_valid(win) then
      close_keeping_pins(self, win)
    end
    if win then
      require("ade.layout").forget_window(win)
    end
  end
  self:remove_events()
  for _, name in ipairs(PANES) do
    local buf = self.buffers[name]
    self.buffers[name] = nil
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  self.meta, self.ids, self.marks = {}, {}, {}
  self.last_lines = {}
  self.floats = {}
  if #vim.api.nvim_list_wins() == 0 then
    vim.cmd("enew")
  end
  self.closing = false
end

function Pane:install_events()
  if self.group then
    return
  end
  self:begin_resize()
  self.group = vim.api.nvim_create_augroup("AdeTeamPane", { clear = true })
  vim.api.nvim_create_autocmd("WinResized", {
    group = self.group,
    callback = function()
      if self.closing or not self:is_open() then
        return
      end
      if self.ignore_until and (vim.uv.now() or 0) < self.ignore_until then
        return
      end
      local win = self:win("members")
      local adopt = self:backend() ~= "external" and horizontal(self:position("members"))
      if adopt and win and vim.api.nvim_win_get_width(win) ~= self:members_width() then
        -- The person dragged the members pane: keep that width for this open.
        -- External managers own the geometry, and a top/bottom or float pane
        -- has no meaningful members *width*, so nothing is adopted there.
        self.adopted_width = vim.api.nvim_win_get_width(win)
      end
      vim.schedule(function()
        if not self.closing then
          self:refresh()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.group,
    callback = function()
      vim.schedule(function()
        if self.closing or not self:is_open() then
          return
        end
        local name = self.dashboard and self.dashboard.selected_pane
        if name and self:is_open_pane(name) then
          local win = self:win(name)
          if win then
            pcall(vim.api.nvim_set_current_win, win)
          end
        end
        self:refresh()
      end)
    end,
  })
  for _, name in ipairs(PANES) do
    local win = self:win(name)
    if win then
      vim.api.nvim_create_autocmd("WinClosed", {
        group = self.group,
        callback = function(args)
          local closed = tonumber(args.match)
          if self.closing then
            return
          end
          for _, candidate in ipairs(PANES) do
            if self.windows[candidate] == closed then
              vim.schedule(function()
                if not self.closing then
                  self:close_pane(candidate)
                end
              end)
              return
            end
          end
        end,
      })
    end
  end
  self:end_resize()
end

function Pane:remove_events()
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
end

---Tell an external layout manager that the pane windows are gone.
---
---The team panes are ordinary splits/floats with their own filetypes, so edgy
---never owns them; but closing them changes the window layout edgy has to lay
---out, and a stale update would leave the ordinary chat/composer pair sized for
---the old split. Only a loaded edgy is touched (never a lazy-load), and an
---update failure is not the panel's to report.
function Pane:release_external()
  if self:backend() ~= "external" then
    return
  end
  if package.loaded["edgy.layout"] == nil and package.loaded["edgy"] == nil then
    return
  end
  local ok, module = pcall(require, "edgy.layout")
  if not ok or type(module) ~= "table" or type(module.update) ~= "function" then
    return
  end
  vim.schedule(function()
    pcall(module.update)
  end)
end

---@param name string
---@param lines string[]
---@param marks table[]
function Pane:set_lines(name, lines, marks)
  local buf = self:buf(name)
  if not buf then
    return
  end
  vim.bo[buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  require("ade.ui.team.text").apply_marks(buf, self.mark_ns, marks or {})
end

function Pane:refresh()
  if not self:is_open() then
    return
  end
  for _, name in ipairs(PANES) do
    if self:is_open_pane(name) then
      local ok, lines, ids, meta, marks = pcall(self.dashboard.render_pane, self.dashboard, name)
      if not ok then
        lines = { " dashboard error: " .. tostring(ids) }
        ids, meta, marks = {}, {}, {}
      end
      self.ids[name] = ids or {}
      self.meta[name] = meta or {}
      self.marks[name] = marks or {}
      if not vim.deep_equal(self.last_lines[name], lines) then
        self:set_lines(name, lines, marks)
        self.last_lines[name] = vim.deepcopy(lines)
      end
    end
  end
  self:update_cursor()
end

---The pane window that owns `win`.
---@param win integer|nil
---@return string|nil
function Pane:name_of(win)
  win = win or vim.api.nvim_get_current_win()
  for _, name in ipairs(PANES) do
    if self.windows[name] == win then
      return name
    end
  end
  return nil
end

---What is under the cursor: the same vocabulary as the tab layout.
---@return string|nil kind, string|nil team, string|nil obj, table|nil info
function Pane:current()
  local name = self:name_of()
  if not name then
    return nil
  end
  local buf = self:buf(name)
  local win = self:win(name)
  if not (buf and win) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = cursor[1]
  local column = cursor[2]
  local ids = self.ids[name] or {}
  local meta = self.meta[name] or {}
  local id = ids[line]
  local info = meta[line]
  if not id and not info then
    return nil
  end
  if type(info) == "table" and info.kind == "board_row" and info.cells then
    for _, cell in ipairs(info.cells) do
      if column >= cell.start and column < cell.stop then
        if cell.card then
          return "card", nil, cell.card, cell
        end
        return "board_cell", nil, nil, cell
      end
    end
    return "board_row", nil, nil, info
  end
  if type(id) == "string" then
    if id:sub(1, 6) == "stage:" then
      local team, stage = id:sub(7):match("^([^|]*)|(.*)$")
      return "archived_stage", team, stage, info
    end
    if id:sub(1, 5) == "card:" then
      local team, card = id:sub(6):match("^([^|]+)|(.+)$")
      return "card", team, card, info
    end
    if id:sub(1, 9) == "workflow:" then
      return "workflow", nil, id:sub(10), info
    end
    local team, participant = id:match("^([^|]+)|(.+)$")
    if team then
      return "participant", team, participant, info
    end
  end
  if type(info) == "table" then
    if info.kind == "card" and info.card then
      return "card", nil, info.card, info
    end
    if info.kind == "archived_stage" then
      return "archived_stage", nil, info.stage, info
    end
    return info.kind, info.team, info.name or info.item or info.card or info.stage, info
  end
  return nil
end

function Pane:update_cursor()
  local name = self:name_of()
  local win = name and self:win(name)
  local buf = name and self:buf(name)
  if not (buf and win) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, self.cursor_ns, 0, -1)
  if name ~= "board" then
    return
  end
  local kind, _, card = self:current()
  if kind ~= "card" or type(card) ~= "table" then
    return
  end
  for line, info in pairs(self.meta.board or {}) do
    for _, cell in ipairs(info.cells or {}) do
      if cell.card == card then
        pcall(vim.api.nvim_buf_set_extmark, buf, self.cursor_ns, line - 1, cell.start, {
          end_row = line - 1,
          end_col = cell.stop,
          hl_group = "AdeBoardCardCursor",
          priority = 120,
        })
      end
    end
  end
end

---Cycle the cursor through the panes that are on screen.
---@param direction integer
function Pane:cycle(direction)
  local names = self:open_names()
  if #names < 2 then
    return
  end
  local current = self:name_of()
  local index = 1
  for position, name in ipairs(names) do
    if name == current then
      index = position
    end
  end
  index = ((index - 1 + direction) % #names) + 1
  local win = self:win(names[index])
  if win then
    pcall(vim.api.nvim_set_current_win, win)
  end
end

function Pane:focus(name)
  local win = self:win(name)
  if win then
    pcall(vim.api.nvim_set_current_win, win)
    return true
  end
  return false
end

M.Pane = Pane
M.PANES = PANES
M.TITLES = TITLES

return M
