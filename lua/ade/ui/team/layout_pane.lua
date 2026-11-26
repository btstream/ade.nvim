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
    -- Columns borrowed from ade's own chat/composer, per pane name, so closing
    -- the pane can give them back.
    loans = {},
    -- The panel's width before each pane opened.
    panel_before = {},
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

---The windows of the current tabpage.
---@return integer[]
local function tab_windows()
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, vim.api.nvim_get_current_tabpage())
  return ok and wins or vim.api.nvim_list_wins()
end

---Whether `win` shows one of ade.nvim's own buffers (chat, composer, a pane).
---
---These are this plugin's windows, so a team split may borrow their columns and
---put the pin back afterwards. A user's window is never treated this way: its
---width and `winfixwidth` must stay exactly as the person left them.
---@param win integer
---@return boolean
local function is_ade_window(win)
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then
    return false
  end
  local ok_ft, ft = pcall(function()
    return vim.bo[buf].filetype
  end)
  return ok_ft and type(ft) == "string" and ft:sub(1, 4) == "ade_"
end

---The window a new pane splits from.
---
---Always the widest ordinary window **of this tabpage**, never another pane and
---never a narrow leftover split: `:botright vsplit` from inside the members
---window puts the new pane *beside* it (squeezing members to its minimum and
---leaving the board a sliver), and splitting a thin stray window has the same
---effect. Another tab's widest window would put the new pane in the wrong tab.
---@return integer
function Pane:split_base()
  local widest
  local width = 0
  for _, win in ipairs(tab_windows()) do
    if self:name_of(win) == nil and vim.api.nvim_win_get_config(win).relative == "" then
      local w = vim.api.nvim_win_get_width(win)
      if w > width then
        widest, width = win, w
      end
    end
  end
  return widest or vim.api.nvim_get_current_win()
end

---The width ade's own panel (chat/composer) is configured to have here.
---
---This is the floor a team split may borrow down to: ade's panel may give up
---columns to a teammate pane, but never shrink below the size the person's
---layout gives it.
---@return integer|nil
local function configured_panel_width()
  local ok_cfg, cfg = pcall(require, "ade.config")
  if not ok_cfg then
    return nil
  end
  local ok_w, w = pcall(function()
    return cfg.panel_width(cfg.effective(), vim.o.columns)
  end)
  if ok_w and type(w) == "number" and w > 0 then
    return w
  end
  return nil
end

---Whether a layout manager (edgy) owns window placement here.
---
---Under the external backend the plugin must not borrow or narrow ade's own
---windows: edgy decides where every window goes, and touching widths behind its
---back fights it.
---@return boolean
local function external_layout()
  local ok, layout = pcall(require, "ade.layout")
  if not ok then
    return false
  end
  local ok_b, backend = pcall(layout.backend)
  return ok_b and backend ~= "native"
end

---Columns a pane of `name` needs at minimum: the members width for the side
---panes, and enough for a board column for the board.
---@param name string
---@return integer
function Pane:pane_min_width(name)
  if name == "board" then
    -- `board.COLUMN_MIN` is 24 content cells and the board only lays out the
    -- columns that fit; below roughly 56 a two-column board drops its second
    -- column, and its cards silently disappear. This is the floor, not a
    -- target: more space still shows more columns.
    return 56
  end
  local ok, width = pcall(self.members_width, self)
  return ok and tonumber(width) or 32
end

---Remember how wide ade's own panel is before a split, so closing the pane can
---put it back.
---
---The split itself, and 'equalalways' coming back on, can both leave the panel
---narrower than the person had it. Nothing here touches a user's window.
---@param skip integer|nil the window about to be split (it is not a panel)
---@return table[] before
function Pane:remember_panel(skip)
  local before = {}
  for _, win in ipairs(tab_windows()) do
    if win ~= skip and self:name_of(win) == nil and is_ade_window(win) then
      before[#before + 1] = { win = win, width = vim.api.nvim_win_get_width(win) }
    end
  end
  return before
end

---Put ade's own panel back to the width it had before the split, unless the
---person changed it in the meantime.
---@param before table[]
---@param panes table<string, integer> the team panes still open
function Pane:restore_panel(before, panes)
  if type(before) ~= "table" then
    return
  end
  for _, entry in ipairs(before) do
    local win = entry.win
    if win and vim.api.nvim_win_is_valid(win) and is_ade_window(win) then
      -- A pane still open is using these columns; give them back only when the
      -- team panes are gone.
      if next(panes) == nil and vim.api.nvim_win_get_width(win) < entry.width then
        pcall(vim.api.nvim_win_set_width, win, entry.width)
      end
    end
  end
end

---Borrow at most `want` columns from ade's own pinned windows, never past the
---panel's configured width, and remember the loan so the pane can give it back
---when it closes. A user's window is never touched.
---@param want integer
---@return table[] loans
function Pane:borrow_columns(want)
  if want <= 0 or external_layout() then
    return {}
  end
  local panel_width = configured_panel_width()
  if not panel_width then
    return {}
  end
  local loans = {}
  local remaining = want
  for _, win in ipairs(tab_windows()) do
    if remaining <= 0 then
      break
    end
    if self:name_of(win) == nil and is_ade_window(win) then
      local width = vim.api.nvim_win_get_width(win)
      -- The panel keeps its own size: only the columns above the configured
      -- width may be lent, and only as many as the new pane is short of.
      local floor = math.min(width, panel_width)
      local spare = width - floor
      if spare > 0 then
        local take = math.min(spare, remaining)
        -- Chat and composer are stacked, so they share one column band; one
        -- entry per window is enough to give each its own width back.
        pcall(vim.api.nvim_win_set_width, win, width - take)
        loans[#loans + 1] = { win = win, width = width, taken = take }
        remaining = remaining - take
      end
    end
  end
  return loans
end

---Give borrowed columns back to ade's own windows, unless the person has
---changed the width themselves in the meantime.
---@param loans table[]
function Pane:return_columns(loans)
  if type(loans) ~= "table" then
    return
  end
  for _, loan in ipairs(loans) do
    local win = loan.win
    if win and vim.api.nvim_win_is_valid(win) and (loan.taken or 0) > 0 then
      local lent = loan.width - (loan.taken or 0)
      -- Only undo our own narrowing: if the width is no longer what we left it
      -- at, the person (or the layout manager) owns it now.
      if vim.api.nvim_win_get_width(win) == lent then
        pcall(vim.api.nvim_win_set_width, win, loan.width)
      end
    end
  end
end

---@param name string
---@return integer|nil win
function Pane:create_split(name)
  local previous = vim.api.nvim_get_current_win()
  -- The panel's width before any split: closing the pane puts it back.
  local panel_before = self:remember_panel()
  local base = self:split_base()
  if base and base ~= previous and vim.api.nvim_win_is_valid(base) then
    pcall(vim.api.nvim_set_current_win, base)
  end
  -- Open panes carry `winfixwidth`, and Vim honours it while dividing the
  -- screen: the split would hand the new pane whatever columns are left over
  -- instead of its configured width. Release the pins for this one split. The
  -- set is the current tab's team panes plus ade's own chat/composer windows:
  -- the chat is pinned under the native backend and would otherwise keep the
  -- split down to its minimum. A user's window is never unlocked or resized.
  local fixed = {}
  -- ade's own chat/composer are kept apart: they go back to the width the panel
  -- layout gives them, never to whatever they happened to span while the person
  -- had no document open.
  local ade_own = {}
  for _, win in ipairs(tab_windows()) do
    if vim.wo[win].winfixwidth and (self:name_of(win) ~= nil or is_ade_window(win)) then
      local entry = { win = win, width = vim.api.nvim_win_get_width(win) }
      if self:name_of(win) ~= nil then
        fixed[#fixed + 1] = entry
      else
        ade_own[#ade_own + 1] = entry
      end
      pcall(function()
        vim.wo[win].winfixwidth = false
      end)
    end
  end
  local panel_width = configured_panel_width()
  ---Put every released window back to its own width and pin, except the new one.
  ---@param skip integer|nil
  ---@param reset_width boolean
  local function restore_fixed(skip, reset_width)
    for _, entry in ipairs(fixed) do
      local fixed_win = entry.win
      if fixed_win ~= skip and vim.api.nvim_win_is_valid(fixed_win) then
        if reset_width then
          -- Its own width, not the configured one: the split may have run a
          -- `WinResized` handler that adopted the squeezed width meanwhile.
          pcall(vim.api.nvim_win_set_width, fixed_win, entry.width)
        end
        -- Only pin what is still one of our panes. A window can be reused for
        -- an ordinary buffer after the pane closed, and pinning that would lock
        -- the person's own document at an ade width.
        if self:name_of(fixed_win) ~= nil then
          pcall(function()
            vim.wo[fixed_win].winfixwidth = true
          end)
        end
      end
    end
    for _, entry in ipairs(ade_own) do
      local own = entry.win
      if own ~= skip and vim.api.nvim_win_is_valid(own) then
        if reset_width and vim.api.nvim_win_get_width(own) ~= entry.width then
          -- Put back the width it had: ade's own panel is only ever narrowed by
          -- `borrow_columns`, and only as far as the new pane needs.
          pcall(vim.api.nvim_win_set_width, own, entry.width)
        end
        if is_ade_window(own) then
          pcall(function()
            vim.wo[own].winfixwidth = true
          end)
        end
      end
    end
  end
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  local ok = pcall(vim.cmd, "botright vsplit")
  if not ok then
    -- No new pane: only the pin is ours to restore; no width was touched.
    -- Restore it while 'equalalways' is still off, or re-pinning would make
    -- Vim rebalance and move the very width we are preserving.
    restore_fixed(nil, false)
    vim.o.equalalways = equalalways
    if previous and vim.api.nvim_win_is_valid(previous) then
      pcall(vim.api.nvim_set_current_win, previous)
    end
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  self.panel_before = self.panel_before or {}
  if self.panel_before[name] == nil then
    self.panel_before[name] = panel_before
  end
  if name == "members" or name == "tree" then
    -- The width setting only applies to this new team pane; a failed width call
    -- must not skip the restore below, so both are guarded and nothing throws.
    local width_ok, width = pcall(self.members_width, self)
    if width_ok then
      pcall(vim.api.nvim_win_set_width, win, width)
    end
    pcall(function()
      vim.wo[win].winfixwidth = true
    end)
  end
  ---Fill the columns the pinned panes leave free, but never shrink below the
  ---width the split itself gave.
  local function fill_columns()
    -- Count columns, not windows: the chat and its composer are stacked, and
    -- summing their widths would double-count the same columns.
    local spans = {}
    for _, other in ipairs(tab_windows()) do
      if other ~= win then
        local ok, pos = pcall(vim.api.nvim_win_get_position, other)
        local col = ok and pos[2] or 0
        spans[#spans + 1] = { col, col + vim.api.nvim_win_get_width(other) }
      end
    end
    table.sort(spans, function(a, b)
      return a[1] < b[1]
    end)
    local used, edge = 0, 0
    for _, span in ipairs(spans) do
      local first = math.max(span[1], edge)
      if span[2] > first then
        used = used + span[2] - first
      end
      edge = math.max(edge, span[2])
    end
    -- Every column the pinned windows do not hold is this pane's, but never
    -- below the readable floor. 'equalalways' may already have shared the
    -- space with an ordinary document window, and that split is left alone:
    -- only a pane squeezed under the floor is widened back to it.
    local floor = self:pane_min_width(name)
    local target = math.max(floor, vim.o.columns - used)
    local now = vim.api.nvim_win_get_width(win)
    if target > now then
      pcall(vim.api.nvim_win_set_width, win, target)
    end
  end
  local fills = name ~= "members" and name ~= "tree"
  if fills then
    fill_columns()
  end
  vim.o.equalalways = equalalways
  if equalalways then
    -- Turning 'equalalways' back on rebalances every window and can undo the
    -- widths just restored; assert our own panes' widths once more with the
    -- option already back, so the final layout is the one promised above.
    restore_fixed(win, true)
    -- The rebalance also squeezes the new pane back down, so give it its
    -- columns again while everyone else keeps the width just restored.
    if fills then
      fill_columns()
    end
  end
  -- Our own resizes above (restore, 'equalalways', the fill) fire `WinResized`
  -- and would be read as the person dragging the members pane, freezing its
  -- width at whatever the rebalance produced. Keep treating them as ours.
  self:begin_resize()
  -- Only now, with every pin and width back in place, can the pane tell whether
  -- it is short: when it is, it borrows the gap from ade's own panel and nothing
  -- else moves. With room to spare the panel is left exactly as it was.
  local need = self:pane_min_width(name)
  local short = need - vim.api.nvim_win_get_width(win)
  if short > 0 then
    local loans = self:borrow_columns(short)
    if #loans > 0 then
      pcall(vim.api.nvim_win_set_width, win, vim.api.nvim_win_get_width(win) + short)
      self.loans[name] = self.loans[name] or {}
      for _, loan in ipairs(loans) do
        self.loans[name][#self.loans[name] + 1] = loan
      end
    end
  end
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
  local by_pane = {}
  for _, other_name in ipairs(PANES) do
    if other_name ~= name and self:is_open_pane(other_name) then
      by_pane[other_name] = self:win(other_name)
    end
  end
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
  -- Give back any columns this pane borrowed from ade's own panel.
  local loans = self.loans and self.loans[name]
  self.loans[name] = nil
  self:return_columns(loans)
  -- And the width the panel had before this pane opened, once no team pane is
  -- left to use it.
  local before = self.panel_before and self.panel_before[name]
  self.panel_before[name] = nil
  if by_pane then
    self:restore_panel(before, by_pane)
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
  -- Every pane is gone, so every borrowed column goes back too.
  local loans = self.loans
  local before = self.panel_before
  self.loans = {}
  self.panel_before = {}
  for _, name in ipairs(PANES) do
    self:return_columns(loans[name])
  end
  -- With no team pane left, the panel returns to the width it had before any
  -- of them opened.
  for _, name in ipairs(PANES) do
    self:restore_panel(before[name], {})
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
