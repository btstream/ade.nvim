-- The team panel (PROTOCOL.md 18.5/18.9) and the read-only watch window.
--
-- Deliberately small and reusable: the panel is one scratch buffer with a
-- cursor-mapped list; the watch window renders a session from the ordinary
-- reducer, so a watched worker looks like a chat without owning one.
local M = {}

local Panel = {}
Panel.__index = Panel

---@param opts {team: table, config: fun(): table}
---@return table
function M.new(opts)
  return setmetatable({
    team = opts.team,
    config = opts.config,
    win = nil,
    buf = nil,
    watch_win = nil,
    watch_buf = nil,
    help = false,
  }, Panel)
end

function Panel:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---The cursor line's target: `team_id|participant` or `item:<id>`.
---@return string|nil kind
---@return string|nil a
---@return string|nil b
function Panel:current()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
  local id = self.ids and self.ids[lnum]
  if type(id) ~= "string" then
    return nil
  end
  if id:sub(1, 5) == "item:" then
    return "item", id:sub(6)
  end
  local team, name = id:match("^([^|]+)|(.+)$")
  return "participant", team, name
end

---@return string[]
function Panel:lines()
  local lines, ids = {}, {}
  local rows = self.team:list_rows()
  if #rows == 0 then
    return {}, {}
  end
  local function add(text, id)
    lines[#lines + 1] = text
    ids[#lines] = id
  end
  add(" ade.nvim · team", nil)
  add("", nil)
  if self.help then
    for _, entry in ipairs({
      { "m", "send a message to a participant" },
      { "p / r / c", "pause / resume / cancel the participant" },
      { "w", "watch the participant's transcript" },
      { "a", "answer the inbox item under the cursor" },
      { "R", "reset limits" },
      { "x", "close the team" },
      { "g?", "toggle this help" },
      { "q", "close this panel" },
    }) do
      add(string.format("    %-10s %s", entry[1], entry[2]), nil)
    end
    add("", nil)
  end
  for _, team in ipairs(rows) do
    add(string.format(" %s  %s  [%s]", team.id, tostring(team.cwd), tostring(team.state)), nil)
    local limits = team.limits or {}
    add(
      string.format(
        "   workers %s/%s · turns %s/%s",
        tostring(#(team.participants or {}) - 1),
        tostring(limits.max_workers or "?"),
        tostring(limits.turns_total or "?"),
        tostring(limits.max_turns_total or "?")
      ),
      nil
    )
    for _, entry in ipairs(team.participants or {}) do
      local turns = entry.turns or {}
      local marks = {}
      if entry.paused then
        marks[#marks + 1] = "paused"
      end
      add(
        string.format(
          "   %-10s %-13s task %-8s queued %d turns %s/%s%s",
          tostring(entry.name),
          tostring(entry.state),
          tostring(entry.task or "-"),
          tonumber(entry.queued) or 0,
          tostring(turns.task or 0),
          tostring(turns.total or 0),
          #marks > 0 and (" (" .. table.concat(marks, ",") .. ")") or ""
        ),
        team.id .. "|" .. tostring(entry.name)
      )
    end
    for _, item in ipairs(team.inbox or {}) do
      if item.state == "open" then
        add(
          string.format(
            "   inbox %-10s %-10s from %-10s %s",
            tostring(item.id),
            tostring(item.kind),
            tostring(item.from),
            (tostring(item.body or ""):gsub("%s+", " ")):sub(1, 60)
          ),
          "item:" .. tostring(item.id)
        )
      end
    end
    add("", nil)
  end
  return lines, ids
end

function Panel:refresh()
  if not self:is_open() then
    return
  end
  local rows = self.team:list_rows()
  if #rows == 0 then
    self:close()
    return
  end
  local lines, ids = self:lines()
  self.ids = ids
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
end

function Panel:open()
  if self:is_open() then
    self:refresh()
    return true
  end
  local rows = self.team:list_rows()
  if #rows == 0 then
    self.team:refresh()
    return false
  end
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "ade_team"
  vim.bo[self.buf].modifiable = false
  local width = math.min(110, math.max(60, math.floor(vim.o.columns * 0.8)))
  local height = math.max(10, math.floor((vim.o.lines - vim.o.cmdheight) * 0.7))
  self.win = vim.api.nvim_open_win(self.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Team ",
    title_pos = "center",
  })
  vim.wo[self.win].cursorline = true
  vim.wo[self.win].wrap = false
  self:map("g?", function()
    self.help = not self.help
    self:refresh()
  end)
  self:map("a", function()
    self:answer_current()
  end)
  self:map("p", function()
    self:control_current("pause")
  end)
  self:map("r", function()
    self:control_current("resume")
  end)
  self:map("c", function()
    self:control_current("cancel")
  end)
  self:map("R", function()
    local kind, team = self:current()
    if kind then
      self.team:reset_limits(team, function()
        self.team:refresh()
      end)
    end
  end)
  self:map("w", function()
    local kind, team, name = self:current()
    if kind == "participant" and name ~= "leader" then
      self.team:watch(team, name, true)
    end
  end)
  self:map("x", function()
    local kind, team = self:current()
    if kind then
      self.team:close(team, function()
        self.team:refresh()
      end)
    end
  end)
  self:map("m", function()
    self:send_current()
  end)
  self:map("q", function()
    self:close()
  end)
  self:map("<Esc>", function()
    self:close()
  end)
  self.augroup = vim.api.nvim_create_augroup("AdeTeam", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      self.win, self.buf = nil, nil
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      vim.schedule(function()
        if self:is_open() then
          self:close()
        end
      end)
    end,
  })
  self:refresh()
  return true
end

function Panel:map(lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true })
end

function Panel:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win, self.buf = nil, nil
end

---Pause/resume/cancel the participant under the cursor.
---@param body string
function Panel:control_current(body)
  local kind, team, name = self:current()
  if kind ~= "participant" or name == nil then
    return
  end
  if name == "human" then
    return
  end
  self.team:control(team, name, body, function()
    self.team:refresh()
  end)
end

---Send one message to the participant under the cursor.
function Panel:send_current()
  local kind, team, name = self:current()
  if kind ~= "participant" or name == nil or name == "human" then
    return
  end
  vim.ui.input({ prompt = "message to " .. name .. ": " }, function(body)
    if not body or body == "" then
      return
    end
    self.team:send(team, name, "message", body, nil, function()
      self.team:refresh()
    end)
  end)
end

---Answer the inbox item under the cursor.
function Panel:answer_current()
  local kind, item_id = self:current()
  if kind ~= "item" then
    return
  end
  local item = self.team:item(item_id)
  if not item or item.state ~= "open" then
    return
  end
  local function answer(fields)
    self.team:answer(item_id, fields, function()
      self.team:refresh()
    end)
  end
  if item.kind == "spawn" then
    vim.ui.select({ "allow", "refuse" }, { prompt = "spawn " .. tostring(item.name or item.template) }, function(choice)
      if choice then
        answer({ allow = choice == "allow" })
      end
    end)
    return
  end
  if item.kind == "permission" then
    local items = {}
    for _, option in ipairs(item.options or {}) do
      items[#items + 1] = { label = option.name or option.optionId, value = option.optionId }
    end
    items[#items + 1] = { label = "Cancel", value = false }
    vim.ui.select(items, {
      prompt = "permission",
      format_item = function(entry)
        return entry.label
      end,
    }, function(choice)
      if choice ~= nil then
        answer({ option = choice == false and nil or choice })
      end
    end)
    return
  end
  if item.kind == "question" and type(item.options) == "table" and #item.options > 0 then
    vim.ui.select(item.options, { prompt = item.body or "question" }, function(choice)
      if choice then
        answer({ text = choice })
      end
    end)
    return
  end
  if item.kind == "request" then
    vim.ui.input({ prompt = "JSON result: " }, function(text)
      if text and text ~= "" then
        answer({ text = text })
      end
    end)
    return
  end
  if item.kind == "question" then
    vim.ui.input({ prompt = item.body or "answer: " }, function(text)
      if text and text ~= "" then
        answer({ text = text })
      end
    end)
    return
  end
  -- message/limit items accept any answer as an acknowledgement.
  answer({})
end

---Render a watched session into a read-only split.
---@param session table|nil
---@param title string|nil
function Panel:watch(session, title)
  if not session then
    if self.watch_win and vim.api.nvim_win_is_valid(self.watch_win) then
      pcall(vim.api.nvim_win_close, self.watch_win, true)
    end
    self.watch_win, self.watch_buf = nil, nil
    return
  end
  if not self.watch_buf or not vim.api.nvim_buf_is_valid(self.watch_buf) then
    local previous = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    self.watch_win = vim.api.nvim_get_current_win()
    self.watch_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(self.watch_win, self.watch_buf)
    vim.bo[self.watch_buf].filetype = "ade_team_watch"
    vim.bo[self.watch_buf].modifiable = false
    vim.wo[self.watch_win].number = false
    vim.wo[self.watch_win].wrap = true
    vim.api.nvim_set_current_win(previous)
  end
  local lines = { " watching " .. tostring(title or session.id) .. " (read-only)" }
  for _, block in ipairs(session.blocks or {}) do
    local text = block.text
    if block.kind == "tool" then
      text = (block.status or "") .. " " .. tostring(block.title or block.name or "tool")
    end
    if type(text) == "string" and text ~= "" then
      for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        lines[#lines + 1] = (block.kind == "user" and "> " or "  ") .. line
      end
    end
  end
  vim.bo[self.watch_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.watch_buf, 0, -1, false, lines)
  vim.bo[self.watch_buf].modifiable = false
end

M.Panel = Panel

return M
