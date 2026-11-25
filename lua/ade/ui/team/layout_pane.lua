-- The in-tab team panes: members and board open in the *current* tabpage.
--
-- Both panes are independent: each command opens or focuses only its own
-- pane, closing one leaves the other (and the ordinary chat panel) alone.
-- Wide terminals get native splits; narrow ones get floats sized to the pane
-- that was actually requested, never a forced second tabpage.
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

---@return integer
function Pane:wide()
  local cfg = self.dashboard.config() or {}
  return tonumber(((cfg.teams or {}).dashboard or {}).wide) or 160
end

---@return integer
function Pane:members_width()
  if tonumber(self.adopted_width) then
    return self.adopted_width
  end
  local cfg = self.dashboard.config() or {}
  return math.max(16, math.min(120, tonumber(((cfg.teams or {}).dashboard or {}).members_width) or 32))
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

---The window a new pane splits from.
---
---Always the widest ordinary window, never another pane and never a narrow
---leftover split: `:botright vsplit` from inside the members window puts the
---new pane *beside* it (squeezing members to its minimum and leaving the board
---a sliver), and splitting a thin stray window has the same effect.
---@return integer
function Pane:split_base()
  local widest
  local width = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if self:name_of(win) == nil and vim.api.nvim_win_get_config(win).relative == "" then
      local w = vim.api.nvim_win_get_width(win)
      if w > width then
        widest, width = win, w
      end
    end
  end
  return widest or vim.api.nvim_get_current_win()
end

---@param name string
---@return integer|nil win
function Pane:create_split(name)
  local previous = vim.api.nvim_get_current_win()
  local base = self:split_base()
  if base and base ~= previous and vim.api.nvim_win_is_valid(base) then
    pcall(vim.api.nvim_set_current_win, base)
  end
  -- Open panes carry `winfixwidth`, and Vim honours it while dividing the
  -- screen: the split would hand the new pane whatever columns are left over
  -- instead of its configured width. Release the pins for this one split.
  local fixed = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[win].winfixwidth then
      fixed[#fixed + 1] = win
      pcall(function()
        vim.wo[win].winfixwidth = false
      end)
    end
  end
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  local ok = pcall(vim.cmd, "botright vsplit")
  if not ok then
    vim.o.equalalways = equalalways
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  if name == "members" or name == "tree" then
    pcall(vim.api.nvim_win_set_width, win, self:members_width())
    vim.wo[win].winfixwidth = true
  end
  -- Pin the older panes again at their own width: the split is free to shrink
  -- a pane while its pin is released, so restoring the pin alone would keep the
  -- shrunken pane. Then the new pane takes every column they do not use.
  for _, fixed_win in ipairs(fixed) do
    if fixed_win ~= win and vim.api.nvim_win_is_valid(fixed_win) then
      local pane_name = self:name_of(fixed_win)
      pcall(vim.api.nvim_win_set_width, fixed_win, self:members_width())
      if pane_name then
        pcall(function()
          vim.wo[fixed_win].winfixwidth = true
        end)
      end
    end
  end
  if name ~= "members" and name ~= "tree" then
    local used = 0
    for _, other in ipairs(vim.api.nvim_list_wins()) do
      if other ~= win then
        used = used + vim.api.nvim_win_get_width(other)
      end
    end
    pcall(vim.api.nvim_win_set_width, win, math.max(24, vim.o.columns - used))
  end
  vim.o.equalalways = equalalways
  if not (previous and vim.api.nvim_win_is_valid(previous)) then
    previous = win
  end
  return win, previous
end

---@param name string
---@return integer|nil win
function Pane:create_float(name)
  local names = self:open_names()
  if not vim.tbl_contains(names, name) then
    names[#names + 1] = name
  end
  -- Keep PANES order so adding a pane never reshuffles the other float.
  local ordered = {}
  for _, candidate in ipairs(PANES) do
    if vim.tbl_contains(names, candidate) then
      ordered[#ordered + 1] = candidate
    end
  end
  local geometry = self:float_geometry(ordered)
  -- Reposition the floats that are already up: two requested panes must not
  -- overlap each other.
  for _, other in ipairs(ordered) do
    local win = self:win(other)
    local geo = geometry[other]
    if win and geo then
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
  local split = vim.o.columns >= self:wide()
  local win
  if split then
    win = self:create_split(name)
  else
    win = self:create_float(name)
  end
  if not (win and vim.api.nvim_win_is_valid(win)) then
    self.dashboard:notify("无法打开团队面板窗口")
    return false
  end
  self.windows[name] = win
  local buf = self:ensure_buffer(name)
  require("ade.layout").set_window_buffer(win, buf)
  self:apply_window_options(win, name)
  self.dashboard:attach_keys(buf, name)
  self:install_events()
  self:refresh()
  pcall(vim.api.nvim_set_current_win, win)
  return true
end

---Close one pane; the other pane and the ordinary panel stay untouched.
---@param name string
---@return boolean closed
function Pane:close_pane(name)
  local win = self:win(name)
  if not win then
    return false
  end
  self.windows[name] = nil
  local had_content = self.last_lines[name] ~= nil
  self.last_lines[name] = nil
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
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
      pcall(vim.api.nvim_win_close, win, true)
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
      if win and vim.api.nvim_win_get_width(win) ~= self:members_width() then
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
  local cfg = self.dashboard and self.dashboard.config and self.dashboard.config() or {}
  local layout = type(cfg) == "table" and cfg.layout or nil
  if type(layout) ~= "table" or layout.backend ~= "external" then
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
