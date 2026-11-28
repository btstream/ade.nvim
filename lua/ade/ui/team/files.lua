-- The files pane of the unified team dashboard.
--
-- One group per worker worktree: the git inspection itself lives in
-- `ade.app.team_files` (async scan/read_base), this module owns the layout, the
-- per-team cache and the request guards. A group is expensive to inspect, so a
-- request is only repeated by an explicit `r`, a low-frequency timer while the
-- pane is open, or a change of team/worker/worktree identity.
local Roles = require("ade.ui.team.roles")
local Text = require("ade.ui.team.text")
local Members = require("ade.ui.team.members")
local glyph = require("ade.ui.icons").glyph

local M = {}

local Files = {}
Files.__index = Files

M.Files = Files
-- Internal key for the group of workers without an own worktree. Worker names
-- cannot start with "@", so this can never collide with a real worker (a
-- worker literally named "shared" keeps its own group).
local SHARED_KEY = "@shared"
-- Low-frequency: both scan and read_base are asynchronous, and a worktree can
-- be large. 15s is frequent enough to notice new edits without polling git.
M.REFRESH_MS = 15000
-- Longer than the data module's own git timeout: only a scan that never calls
-- back at all is failed here, so a slow git call is not cut short.
M.REQUEST_TIMEOUT_MS = 90000
M.HELP = "files: <CR> 展开/打开文件 · r 刷新 · q 关闭"

local STATUS_HL = {
  M = "AdeDiffModify",
  A = "AdeDiffAdd",
  D = "AdeDiffDelete",
  R = "AdeDiffModify",
  C = "AdeDiffModify",
  U = "AdeNoticeWarn",
  ["??"] = "AdeMuted",
}

---@param status string
---@return string
local function status_hl(status)
  status = tostring(status or "?")
  return STATUS_HL[status] or STATUS_HL[status:sub(1, 1)] or "AdeMuted"
end

---@param entry table
---@return table|nil
local function worktree_of(entry)
  local worktree = type(entry.worktree) == "table" and entry.worktree or nil
  if worktree and type(worktree.path) == "string" and worktree.path ~= "" then
    return worktree
  end
  return nil
end

---Everything that changes which worktree a group reads. A worker that keeps
---its worktree keeps its cached files across refreshes; a renamed branch, a
---new base or a removed worktree invalidates them.
---@param name string
---@param worktree table
---@return string
local function identity_of(name, worktree)
  return table.concat({
    name,
    worktree.path,
    tostring(worktree.branch or ""),
    tostring(worktree.base or ""),
  }, "\0")
end

---@param group table
local function stop_watchdog(group)
  if group.watchdog then
    pcall(function()
      group.watchdog:stop()
      group.watchdog:close()
    end)
    group.watchdog = nil
  end
end

---@param dashboard table
---@return table
function M.new(dashboard)
  return setmetatable({
    dashboard = dashboard,
    team_id = nil,
    groups = {},
    order = {},
    expanded = {},
    selected_id = nil,
    pending_focus = nil,
    timer = nil,
    -- Incremented by every user file/base open. A slow read_base answer only
    -- gets to move focus when it is still the newest open.
    open_token = 0,
  }, Files)
end

---Forget the cache when the pane starts showing another team.
---@param team_id string|nil
---@return boolean changed
function Files:reset(team_id)
  if team_id == self.team_id then
    return false
  end
  self.team_id = team_id
  for _, group in pairs(self.groups) do
    stop_watchdog(group)
  end
  self.groups = {}
  self.order = {}
  self.expanded = {}
  self.selected_id = nil
  self:invalidate_open()
  return true
end

---Drop any in-flight `read_base` answer: its open no longer owns the focus.
function Files:invalidate_open()
  self.open_token = (self.open_token or 0) + 1
end

---Ask for one worktree scan.
---
---Single-flight per group: a `refresh` that arrives while the group is
---already scanning only marks it for one follow-up, so a slow git call is never
---starved by the 15s timer or by repeated `r` presses.
---@param group table
---@return boolean started
function Files:request(group)
  if group.pending then
    return false
  end
  local ok, module = pcall(require, "ade.app.team_files")
  if not ok or type(module) ~= "table" or type(module.scan) ~= "function" then
    group.pending = false
    group.queued = false
    group.status = "error"
    group.err = "文件数据模块未就绪"
    return false
  end
  stop_watchdog(group)
  group.request = (group.request or 0) + 1
  group.pending = true
  group.queued = false
  local request = group.request
  if group.status == nil then
    group.status = "loading"
  end
  local worktree = {
    path = group.worktree.path,
    branch = group.worktree.branch,
    base = group.worktree.base,
  }
  local called = false
  local function done(err, files)
    if called then
      return
    end
    called = true
    local snapshot = { err = err, files = files, request = request, identity = group.identity }
    vim.schedule(function()
      self:apply(group, snapshot)
    end)
  end
  group.watchdog = vim.defer_fn(function()
    group.watchdog = nil
    if self.groups[group.key] ~= group or group.request ~= request or not group.pending then
      return
    end
    group.pending = false
    group.queued = false
    group.status = "error"
    group.err = "读取超时"
    self.dashboard:schedule_refresh()
  end, M.REQUEST_TIMEOUT_MS)
  local scan_ok, err = pcall(module.scan, worktree, done)
  if not scan_ok and not called then
    called = true
    stop_watchdog(group)
    group.pending = false
    group.queued = false
    group.status = "error"
    group.err = tostring(err)
  end
  return true
end

---Apply one async answer, dropping it when the group it was asked for is no
---longer the one on screen (team switch, worktree change, newer request).
---@param group table
---@param snapshot table
function Files:apply(group, snapshot)
  if self.groups[group.key] ~= group then
    return
  end
  if not group.pending or group.identity ~= snapshot.identity or group.request ~= snapshot.request then
    return
  end
  stop_watchdog(group)
  group.pending = false
  if not self.dashboard:is_open("files") then
    group.queued = false
    return
  end
  if snapshot.err ~= nil then
    group.status = "error"
    group.err = tostring(snapshot.err)
    group.files = {}
  elseif type(snapshot.files) ~= "table" then
    group.status = "error"
    group.err = "无法读取工作区文件"
    group.files = {}
  else
    local files = {}
    for _, file in ipairs(snapshot.files) do
      if type(file) == "table" and type(file.path) == "string" and file.path ~= "" then
        files[#files + 1] = {
          status = tostring(file.status or "?"),
          path = file.path,
          old_path = type(file.old_path) == "string" and file.old_path or nil,
        }
      end
    end
    group.files = files
    group.err = nil
    group.status = #files == 0 and "empty" or "ready"
  end
  if group.queued then
    -- One coalesced follow-up for every `r` pressed while this scan ran.
    group.queued = false
    self:request(group)
  end
  self.dashboard:schedule_refresh()
end

---Re-read every worktree group. Used by `r` (manual = true) and the
---low-frequency timer (manual = false). A group that is still scanning only
---queues one follow-up for an explicit refresh; the timer leaves it alone.
---@param manual boolean|nil
---@return boolean
function Files:refresh(manual)
  if not self.dashboard:is_open("files") then
    self:stop_timer()
    return false
  end
  for _, group in pairs(self.groups) do
    if group.scannable then
      if group.pending then
        if manual then
          group.queued = true
        end
      else
        self:request(group)
      end
    end
  end
  self.dashboard:schedule_refresh()
  return true
end

---Only while the pane is open: the timer stops itself on the first tick after
---the pane went away.
function Files:ensure_timer()
  if self.timer or not self.dashboard:is_open("files") then
    return
  end
  self.timer = vim.defer_fn(function()
    self.timer = nil
    if self.dashboard:is_open("files") then
      self:refresh()
      self:ensure_timer()
    end
  end, M.REFRESH_MS)
end

function Files:stop_timer()
  if self.timer then
    pcall(function()
      self.timer:stop()
      self.timer:close()
    end)
  end
  self.timer = nil
  self:invalidate_open()
end

---@param team table|nil
---@return table[]
function Files:descriptors(team)
  local seen, order, shared = {}, {}, {}
  for _, entry in ipairs(team and team.participants or {}) do
    local name = tostring(entry.name or "")
    if name ~= "" and name ~= "leader" and name ~= "human" and not seen[name] then
      seen[name] = true
      local worktree = worktree_of(entry)
      if worktree then
        order[#order + 1] = {
          key = name,
          entry = entry,
          worktree = worktree,
          identity = identity_of(name, worktree),
        }
      else
        shared[#shared + 1] = name
      end
    end
  end
  if #shared > 0 then
    order[#order + 1] = {
      key = SHARED_KEY,
      shared = shared,
      identity = "shared\0" .. table.concat(shared, "\0"),
    }
  end
  return order
end

---Reconcile the cached groups with the team that is on screen.
---@param team table
function Files:sync(team)
  local keep, order = {}, {}
  for _, descriptor in ipairs(self:descriptors(team)) do
    local group = self.groups[descriptor.key]
    if not group or group.identity ~= descriptor.identity then
      group = {
        key = descriptor.key,
        identity = descriptor.identity,
        entry = descriptor.entry,
        worktree = descriptor.worktree,
        shared = descriptor.shared,
        status = descriptor.shared and "shared" or nil,
        files = {},
        request = 0,
        scannable = descriptor.worktree ~= nil,
      }
    else
      group.entry = descriptor.entry
      group.worktree = descriptor.worktree
      group.shared = descriptor.shared
    end
    keep[descriptor.key] = group
    order[#order + 1] = group
  end
  for key, old in pairs(self.groups) do
    if keep[key] ~= old then
      stop_watchdog(old)
    end
  end
  self.groups = keep
  self.order = order
  for _, group in ipairs(order) do
    if
      group.scannable
      and not group.pending
      and (group.status == nil or (group.status == "loading" and #group.files == 0))
    then
      self:request(group)
    end
  end
end

---@param group table
---@param width integer
---@return string
function Files:identity_text(group, width)
  if group.shared then
    return "共享目录 · 无法归属：" .. table.concat(group.shared, ", ")
  end
  local branch = type(group.worktree.branch) == "string" and Text.one_line(group.worktree.branch) or ""
  local path = Text.one_line(group.worktree.path)
  local text = branch ~= "" and ("wt " .. branch .. " · " .. path) or ("wt " .. path)
  return Text.truncate(text, math.max(4, width))
end

---The absolute path of `relative` inside a worker worktree.
---@param root string
---@param relative string
---@return string
local function worktree_path(root, relative)
  if relative:sub(1, 1) == "/" then
    return relative
  end
  local base = root:gsub("/+$", "")
  if base == "" then
    return "/" .. relative
  end
  return base .. "/" .. relative
end

---@param group table
---@return string
function Files:count_text(group)
  if group.status == "shared" then
    return ""
  end
  if group.status == "loading" and #group.files == 0 then
    return "读取中"
  end
  if group.status == "error" then
    return "读取失败"
  end
  return tostring(#group.files)
end

---Build the pane's lines and hit-test metadata.
---@param team table|nil
---@param opts {width: integer|nil}|nil
---@return string[] lines, table<integer, string> ids, table<integer, table> meta, table[] marks
function Files:lines(team, opts)
  opts = opts or {}
  local changed = self:reset(team and team.id or nil)
  local dashboard = self.dashboard
  local win = dashboard.layout:win("files")
  -- Keep the row the person is on before the new lines replace the old ones.
  if win and not changed then
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local ids = dashboard.layout.ids["files"] or {}
    self.selected_id = ids[line]
  end
  if self.pending_focus then
    self.expanded[self.pending_focus] = true
    self.selected_id = "file_group:" .. self.pending_focus
    self.pending_focus = nil
  end
  local width = math.max(20, tonumber(opts.width) or (win and vim.api.nvim_win_get_width(win)) or 60)
  local lines, ids, meta, marks = {}, {}, {}, {}
  ---@param line table
  ---@param id string|nil
  ---@param info table
  local function add(line, id, info)
    lines[#lines + 1] = line:text()
    if id then
      ids[#lines] = id
    end
    meta[#lines] = info or {}
    for _, mark in ipairs(line:marks()) do
      marks[#marks + 1] = { line = #lines, start = mark.start, stop = mark.stop, group = mark.group }
    end
  end

  if not team then
    add(Text.new_line():add(" 还没有团队"), nil, { kind = "files_empty" })
    add(Text.new_line():add(" 按 :Ade team agents 查看团队"), nil, { kind = "files_hint" })
    return lines, ids, meta, marks
  end

  self:sync(team)
  if #self.order == 0 then
    add(Text.new_line():add(" 团队没有可显示文件的 worker"), nil, { kind = "files_empty" })
    add(Text.new_line():add(" worker 需要独立 worktree 才能归属改动"), "files_hint", { kind = "files_hint" })
    return lines, ids, meta, marks
  end

  local glyphs = Text.glyphs()
  local palette = Roles.palette(team.participants)
  for _, group in ipairs(self.order) do
    local entry = group.entry
    local role_hl = entry and Roles.hl(entry, palette) or "AdeTeamRole1"
    local collapsed = self.expanded[group.key] == false
    local header = Text.new_line()
    header:add(glyphs.bar, role_hl)
    header:add(collapsed and glyph("team_tree_project") or glyph("team_collapse"), "AdeMuted")
    header:add(" ")
    if group.shared then
      header:add(glyph("team_worker"), "AdeMuted")
      header:add(" 共享 cwd", "AdeBold")
    else
      header:add(Roles.symbol(entry), role_hl)
      header:add(" ")
      header:add(Text.one_line(entry.name), "AdeBold")
      header:add(" ")
      header:add(Members.state_icon(entry), "AdeMuted")
      header:add(" " .. Text.one_line(Members.state_label(entry)), entry.paused and "AdeNoticeWarn" or "AdeMuted")
    end
    local count = self:count_text(group)
    if count ~= "" then
      header:add(" · ", "AdeMuted")
      header:add(count, group.status == "error" and "AdeNoticeWarn" or "AdeMuted")
    end
    add(
      header,
      "file_group:" .. group.key,
      { kind = "file_group", group = group.key, worker = not group.shared and group.key or nil }
    )

    local wt = Text.new_line()
    wt:add("   ")
    wt:add(Text.truncate(self:identity_text(group, width - 4), math.max(4, width - 4)), "AdeMuted")
    add(wt, nil, { kind = "file_group", group = group.key })

    if not collapsed then
      if group.status == "shared" then
        -- The identity line above already explains the missing attribution.
      elseif group.status == "loading" and #group.files == 0 then
        add(Text.new_line():add("   读取中…", "AdeMuted"), nil, { kind = "files_note", group = group.key })
      elseif group.status == "error" then
        add(
          Text.new_line():add("   读取失败：" .. Text.one_line(group.err or "未知错误"), "AdeNoticeWarn"),
          nil,
          { kind = "files_note", group = group.key }
        )
      elseif group.status == "empty" then
        add(Text.new_line():add("   没有改动", "AdeMuted"), nil, { kind = "files_note", group = group.key })
      else
        for _, file in ipairs(group.files) do
          local status = tostring(file.status or "?")
          local row = Text.new_line()
          row:add("   ")
          row:add(Text.pad(status, 2), status_hl(status))
          row:add(" ")
          local name = Text.one_line(file.path)
          if file.old_path then
            name = name .. " ← " .. Text.one_line(file.old_path)
          end
          row:add(Text.ellipsis(name, math.max(4, width - 7)), "AdeNormal")
          add(row, "file:" .. group.key .. "\0" .. file.path, {
            kind = "file",
            group = group.key,
            worker = not group.shared and group.key or nil,
            file = file,
            worktree = group.worktree,
          })
        end
      end
    end
  end
  return lines, ids, meta, marks
end

---Move the cursor back to the selected row after a repaint.
function Files:restore_cursor()
  local win = self.dashboard.layout:win("files")
  if not win or not self.selected_id then
    return
  end
  local ids = self.dashboard.layout.ids["files"] or {}
  local target
  for line, id in pairs(ids) do
    if id == self.selected_id then
      target = line
      break
    end
  end
  if not target then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  if cursor[1] ~= target then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end
end

---Expand and select one worker group (`f` in the Agents pane).
---@param key string|nil worker name; nil means the whole team
---@return boolean focused
function Files:focus(key)
  if not self.dashboard:is_open("files") then
    return false
  end
  if key == nil then
    -- `f` on the team row: focus the pane, keep the current selection.
    self.dashboard:refresh()
    return true
  end
  local group_key
  if self.groups[key] then
    group_key = key
  elseif self.groups[SHARED_KEY] then
    -- A worker without its own worktree lands on the shared group. A real
    -- worker named "shared" was found above and keeps its own group.
    group_key = SHARED_KEY
  end
  if not group_key then
    self.dashboard:refresh()
    return true
  end
  self.expanded[group_key] = true
  self.pending_focus = group_key
  self.dashboard:refresh()
  return true
end

---An ordinary editor window that may show a file: not a float and not one of
---ade's own pane buffers. Prefer a window without unsaved changes, so setting
---its buffer cannot fail with E37; when none exists a fresh split is created.
---@param force_new boolean|nil
---@return integer|nil
function Files:normal_window(force_new)
  local layout = require("ade.layout")
  local current = vim.api.nvim_get_current_win()
  local function ordinary(win)
    if not vim.api.nvim_win_is_valid(win) then
      return false
    end
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    return not layout.is_panel_filetype(vim.bo[buf].filetype)
  end
  local function clean(win)
    return ordinary(win) and not vim.bo[vim.api.nvim_win_get_buf(win)].modified
  end
  if not force_new then
    if clean(current) then
      return current
    end
    local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, vim.api.nvim_get_current_tabpage())
    for _, win in ipairs(ok and wins or {}) do
      if clean(win) then
        return win
      end
    end
    -- With 'hidden' a modified buffer is simply hidden by the switch.
    if vim.o.hidden then
      if ordinary(current) then
        return current
      end
      for _, win in ipairs(ok and wins or {}) do
        if ordinary(win) then
          return win
        end
      end
    end
  end
  -- No ordinary window (or only modified ones): split away from the pane. The
  -- lock guard turns a split of a panel window into a scratch window, which is
  -- exactly a normal editor window.
  local pane = self.dashboard.layout:win("files") or current
  if vim.api.nvim_win_is_valid(pane) then
    pcall(vim.api.nvim_set_current_win, pane)
  end
  if not pcall(vim.cmd, "botright split") then
    return nil
  end
  return vim.api.nvim_get_current_win()
end

---Show `buf` in a normal editor window, creating one when every ordinary
---window holds unsaved changes.
---@param buf integer
---@return boolean shown
function Files:show_buffer(buf)
  local win = self:normal_window()
  if win then
    pcall(vim.api.nvim_set_current_win, win)
    if pcall(vim.api.nvim_win_set_buf, win, buf) then
      return true
    end
  end
  local fallback = self:normal_window(true)
  if fallback then
    pcall(vim.api.nvim_set_current_win, fallback)
    if pcall(vim.api.nvim_win_set_buf, fallback, buf) then
      return true
    end
  end
  self.dashboard:notify("没有可用于打开文件的普通窗口")
  return false
end

---Open `abs` in an ordinary editor buffer without letting Ex parse the path.
---A path that disappeared between the scan and the click is reported, never
---opened as an empty buffer.
---@param abs string
---@return boolean opened
function Files:open_path(abs)
  if vim.fn.filereadable(abs) ~= 1 then
    self.dashboard:notify("文件已不存在或不可读，按 r 刷新：" .. abs)
    return false
  end
  local ok, buf = pcall(vim.fn.bufadd, abs)
  if not ok or type(buf) ~= "number" or buf == 0 then
    self.dashboard:notify("无法打开文件 " .. abs)
    return false
  end
  -- Reading the file here also reuses an already loaded buffer for this path.
  pcall(vim.fn.bufload, buf)
  return self:show_buffer(buf)
end

---@param group table
---@param abs string
---@param content string|nil
function Files:show_base(group, abs, content)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  pcall(vim.api.nvim_buf_set_name, buf, "ade-base://" .. abs)
  local lines = vim.split(tostring(content or ""), "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { "" }
  end
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  local filetype = vim.filetype.match({ filename = abs })
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  if not self:show_buffer(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---@param group table
---@param file table
---@param token integer the open that asked for this base
---@param pane_win integer|nil the files window at that moment
---@param team_id string|nil the team at that moment
function Files:open_deleted(group, file, token, pane_win, team_id)
  local ok, module = pcall(require, "ade.app.team_files")
  if not ok or type(module) ~= "table" or type(module.read_base) ~= "function" then
    self.dashboard:notify("文件数据模块未就绪，无法读取基线版本")
    return
  end
  local abs = worktree_path(group.worktree.path, file.path)
  local identity = group.identity
  local worktree = {
    path = group.worktree.path,
    branch = group.worktree.branch,
    base = group.worktree.base,
  }
  local called = false
  local function done(err, content)
    if called then
      return
    end
    called = true
    vim.schedule(function()
      -- A newer open, a team switch, a closed (or recreated) files pane, or a
      -- worktree change owns the focus now; this answer must not move it.
      if token ~= self.open_token then
        return
      end
      if self.dashboard.layout:win("files") ~= pane_win or not self.dashboard:is_open("files") then
        return
      end
      if self.team_id ~= team_id then
        return
      end
      if self.groups[group.key] ~= group or group.identity ~= identity then
        return
      end
      if err ~= nil then
        self.dashboard:notify("无法读取基线版本 " .. file.path .. "：" .. tostring(err))
        return
      end
      self:show_base(group, abs, content)
    end)
  end
  local call_ok, err = pcall(module.read_base, worktree, file.path, done)
  if not call_ok and not called then
    called = true
    self.dashboard:notify("无法读取基线版本 " .. file.path .. "：" .. tostring(err))
  end
end

---Open the file row under the cursor in a normal editor window.
---@param info table meta of a file row
---@return boolean handled
function Files:open(info)
  local group = self.groups[info.group]
  if not group or not group.worktree or type(info.file) ~= "table" then
    return false
  end
  self.open_token = (self.open_token or 0) + 1
  local token = self.open_token
  local status = tostring(info.file.status or "?")
  if status:sub(1, 1) == "D" then
    self:open_deleted(group, info.file, token, self.dashboard.layout:win("files"), self.team_id)
    return true
  end
  local abs = worktree_path(group.worktree.path, info.file.path)
  return self:open_path(abs)
end

return M
