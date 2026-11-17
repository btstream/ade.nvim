-- `:Ade workflows`: the list of named workflows (PROTOCOL.md 19.5).
--
-- A small floating list: name, scope and the one-line summary, with the
-- workflow's members under it. <CR> shows the flow text, `d` deletes a stored
-- workflow (project or user), `q` closes. Configured (`config`) and built-in
-- ones are read-only and say so.
local M = {}

local Panel = {}
Panel.__index = Panel

---@param opts {team: fun(): table, config: fun(): table, resolve_cwd: fun(): string,
---  notify: fun(message: string, level: integer|nil), error_text: fun(value: any): string}
---@return table
function M.new(opts)
  return setmetatable({
    team = opts.team,
    config = opts.config,
    resolve_cwd = opts.resolve_cwd,
    notify = opts.notify or function() end,
    error_text = opts.error_text or tostring,
    entries = {},
    win = nil,
    buf = nil,
    detail_win = nil,
    detail_buf = nil,
  }, Panel)
end

function Panel:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---@return string
function Panel:cwd()
  local ok, cwd = pcall(self.resolve_cwd)
  if ok and type(cwd) == "string" and cwd ~= "" then
    return cwd
  end
  local cfg = self.config()
  return cfg.cwd or vim.fn.getcwd()
end

function Panel:notify_message(message, level)
  pcall(self.notify, message, level)
end

---Fetch the workflows and show them. Returns whether a window opened.
---@param cb fun(ok: boolean)|nil
---@return boolean opening
function Panel:open(cb)
  local team = self.team()
  if not team or not team:available() then
    self:notify_message("workflows need the service and a configured template", vim.log.levels.WARN)
    if cb then
      cb(false)
    end
    return false
  end
  team:workflows(self:cwd(), function(ok, value)
    if not ok then
      self:notify_message("cannot list workflows: " .. self.error_text(value), vim.log.levels.WARN)
      if cb then
        cb(false)
      end
      return
    end
    self:set_entries(type(value) == "table" and value.workflows or {})
    self:show()
    if cb then
      cb(true)
    end
  end)
  return true
end

---@param workflows table[]
function Panel:set_entries(workflows)
  self.entries = {}
  for _, workflow in ipairs(workflows or {}) do
    self.entries[#self.entries + 1] = workflow
  end
  table.sort(self.entries, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)
end

---@return string[]
function Panel:lines()
  local lines, ids = {}, {}
  lines[#lines + 1] = " ade.nvim · workflows"
  lines[#lines + 1] = ""
  if #self.entries == 0 then
    lines[#lines + 1] = "   no workflows"
    return lines, ids
  end
  for _, workflow in ipairs(self.entries) do
    local scope = tostring(workflow.scope or "?")
    local summary = tostring(workflow.summary or ""):gsub("%s+", " ")
    lines[#lines + 1] = string.format(" %-18s [%-7s] %s", tostring(workflow.name), scope, summary)
    ids[#lines] = workflow
    local members = {}
    for _, member in ipairs(workflow.team or {}) do
      local entry = tostring(member.name) .. ":" .. tostring(member.template)
      if member.model then
        entry = entry .. "(" .. tostring(member.model) .. ")"
      end
      members[#members + 1] = entry
    end
    if #members > 0 then
      lines[#lines + 1] = "   members " .. table.concat(members, ", ")
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " <CR> open  d delete (project/user)  q close"
  return lines, ids
end

---The workflow under the cursor.
---@return table|nil
function Panel:current()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, self.win)
  if not ok then
    return nil
  end
  return self.ids and self.ids[cursor[1]] or nil
end

function Panel:show()
  local width = math.min(100, math.max(60, vim.o.columns - 10))
  local height = math.min(#self.entries * 2 + 8, math.max(10, vim.o.lines - 8))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    self.buf = vim.api.nvim_create_buf(false, true)
  end
  local lines, ids = self:lines()
  self.ids = ids
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].filetype = "ade-workflows"
  if not self:is_open() then
    self.win = vim.api.nvim_open_win(self.buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " workflows ",
    })
    vim.keymap.set("n", "q", function()
      self:close()
    end, { buffer = self.buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", function()
      self:close()
    end, { buffer = self.buf, nowait = true, silent = true })
    vim.keymap.set("n", "<CR>", function()
      self:detail()
    end, { buffer = self.buf, nowait = true, silent = true })
    vim.keymap.set("n", "d", function()
      self:delete_current()
    end, { buffer = self.buf, nowait = true, silent = true })
  else
    vim.api.nvim_win_set_cursor(self.win, { 1, 0 })
  end
  return true
end

---Show the flow text of the workflow under the cursor.
function Panel:detail()
  local workflow = self:current()
  if not workflow then
    return
  end
  local lines = {
    " workflow: " .. tostring(workflow.name),
    " scope:    " .. tostring(workflow.scope or "?"),
    " summary:  " .. tostring(workflow.summary or ""),
    "",
  }
  -- `gmatch("[^\r\n]*")` yields an extra empty string after every line on
  -- LuaJIT (and one for the empty text), which showed the flow double spaced.
  for _, line in ipairs(vim.split(tostring(workflow.text or ""), "\r?\n")) do
    lines[#lines + 1] = line
  end
  if type(workflow.leader) == "table" then
    local parts = {}
    for _, key in ipairs({ "agent", "model", "role" }) do
      if workflow.leader[key] then
        parts[#parts + 1] = key .. "=" .. tostring(workflow.leader[key])
      end
    end
    if #parts > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "leader: " .. table.concat(parts, " ")
    end
  end
  if type(workflow.columns) == "table" and #workflow.columns > 0 then
    lines[#lines + 1] = "columns: " .. table.concat(workflow.columns, " / ")
  end
  local width = math.min(110, math.max(60, vim.o.columns - 10))
  local height = math.max(6, math.min(#lines + 2, vim.o.lines - 8))
  if not self.detail_buf or not vim.api.nvim_buf_is_valid(self.detail_buf) then
    self.detail_buf = vim.api.nvim_create_buf(false, true)
  end
  vim.bo[self.detail_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.detail_buf, 0, -1, false, lines)
  vim.bo[self.detail_buf].modifiable = false
  vim.bo[self.detail_buf].filetype = "markdown"
  if self.detail_win and vim.api.nvim_win_is_valid(self.detail_win) then
    vim.api.nvim_win_close(self.detail_win, true)
  end
  self.detail_win = vim.api.nvim_open_win(self.detail_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. tostring(workflow.name) .. " ",
  })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      self:close_detail()
    end, { buffer = self.detail_buf, nowait = true, silent = true })
  end
end

function Panel:close_detail()
  if self.detail_win and vim.api.nvim_win_is_valid(self.detail_win) then
    vim.api.nvim_win_close(self.detail_win, true)
  end
  self.detail_win, self.detail_buf = nil, nil
  if self:is_open() then
    pcall(vim.api.nvim_set_current_win, self.win)
  end
end

---Delete the stored workflow under the cursor; configured and built-in ones
---are read-only.
function Panel:delete_current()
  local workflow = self:current()
  if not workflow then
    self:notify_message("put the cursor on a workflow first", vim.log.levels.WARN)
    return
  end
  local scope = workflow.scope
  if scope == "config" then
    self:notify_message("this workflow comes from your setup; change it there", vim.log.levels.WARN)
    return
  end
  if scope == "builtin" then
    self:notify_message("the built-in default workflow cannot be deleted", vim.log.levels.WARN)
    return
  end
  if scope ~= "project" and scope ~= "user" then
    self:notify_message("this workflow cannot be deleted", vim.log.levels.WARN)
    return
  end
  local presenter = require("ade.app.presenter")
  presenter.confirm(
    string.format("Delete workflow %s (%s)?", tostring(workflow.name), tostring(scope)),
    function(choice)
      if choice ~= "yes" then
        return
      end
      local team = self.team()
      team:workflow_delete(self:cwd(), workflow.name, scope, function(ok, value)
        if not ok then
          self:notify_message(
            "cannot delete " .. tostring(workflow.name) .. ": " .. self.error_text(value),
            vim.log.levels.WARN
          )
          return
        end
        if not self:is_open() then
          -- The person closed the window while the request was in flight; a
          -- late reply must not reopen it.
          return
        end
        -- Refetch: deleting a project workflow can reveal a user one.
        self:open()
      end)
    end
  )
end

function Panel:close()
  self:close_detail()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win, self.buf = nil, nil
end

M.Panel = Panel

return M
