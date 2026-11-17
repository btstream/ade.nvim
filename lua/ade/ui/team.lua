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
  if id:sub(1, 5) == "team:" then
    return "team", id:sub(6)
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
      { "s", "start a worker from a template" },
      { "D", "remove an exited worker's worktree" },
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
    add(string.format(" %s  %s  [%s]", team.id, tostring(team.cwd), tostring(team.state)), "team:" .. tostring(team.id))
    local limits = team.limits or {}
    local cfg_teams = (self.config and self.config().teams) or {}
    local live, total = 0, 0
    for _, entry in ipairs(team.participants or {}) do
      if entry.name ~= "leader" and entry.name ~= "human" then
        total = total + 1
        if entry.state ~= "exited" then
          live = live + 1
        end
      end
    end
    add(
      string.format(
        "   workers %s/%s · turns %s/%s",
        tostring(live),
        tostring(cfg_teams.max_workers or total),
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
      local worktree = entry.worktree
      local branch = type(worktree) == "table" and worktree.branch or nil
      add(
        string.format(
          "   %-10s %-13s task %-8s queued %d turns %s/%s%s%s",
          tostring(entry.name),
          tostring(entry.state),
          tostring(entry.task or "-"),
          tonumber(entry.queued) or 0,
          tostring(turns.task or 0),
          tostring(turns.total or 0),
          #marks > 0 and (" (" .. table.concat(marks, ",") .. ")") or "",
          branch and ("  wt " .. tostring(branch)) or ""
        ),
        team.id .. "|" .. tostring(entry.name)
      )
    end
    -- Follow `team.inbox` (the notification stream), not the inbox snapshot
    -- that happened to be inside the last `team.changed`.
    local items = {}
    for _, item in pairs(self.team.inbox) do
      if item.team == team.id and item.state == "open" then
        items[#items + 1] = item
      end
    end
    table.sort(items, function(a, b)
      return tostring(a.id) < tostring(b.id)
    end)
    for _, item in ipairs(items) do
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

---The team id for the cursor line, whether it is a team, participant or item.
---@return string|nil
function Panel:team_of_current()
  local kind, a, b = self:current()
  if kind == "participant" or kind == "team" then
    return a
  end
  if kind == "item" then
    local item = self.team:item(a)
    return item and item.team or nil
  end
  return nil
end

function Panel:open()
  self.interacting = false
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
    local team = self:team_of_current()
    if team then
      self.team:reset_limits(team, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end
  end)
  self:map("w", function()
    local kind, team, name = self:current()
    if kind == "participant" and name ~= "leader" then
      self.team:watch(team, name, true, function(ok, value)
        self:report(ok, value)
      end)
    end
  end)
  self:map("s", function()
    self:spawn_current()
  end)
  self:map("D", function()
    self:remove_worktree_current()
  end)
  self:map("x", function()
    local team = self:team_of_current()
    if not team then
      return
    end
    local function close_it()
      self.team:close(team, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end
    self.interacting = true
    vim.ui.select({ { label = "Close the team", value = true }, { label = "Cancel", value = false } }, {
      prompt = "close " .. team .. "?",
      format_item = function(entry)
        return entry.label
      end,
    }, function(choice)
      self:interaction_done()
      if choice and choice.value then
        close_it()
      end
    end)
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
        if self.interacting then
          return
        end
        if not self:is_open() then
          return
        end
        -- A programmatic split or the watch window is a deliberate stop, not
        -- the user leaving the panel; closing the panel would close the watch
        -- right away.
        local current = vim.api.nvim_get_current_win()
        if current == self.win or (self.watch_win and current == self.watch_win) then
          return
        end
        self:close()
      end)
    end,
  })
  self:refresh()
  return true
end

function Panel:map(lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true })
end

function Panel:notify(message, level)
  vim.notify("ade.nvim: " .. tostring(message), level or vim.log.levels.WARN)
end

---Report a team call failure instead of silently dropping it.
---@param ok boolean
---@param value any
---@return boolean ok
function Panel:report(ok, value)
  if ok then
    return true
  end
  local message = type(value) == "table" and (value.message or value.code) or tostring(value)
  if type(value) == "table" and type(value.data) == "table" then
    local stderr = value.data.stderr
    if type(stderr) == "string" and stderr ~= "" then
      message = tostring(message) .. ": " .. stderr
    end
  end
  self:notify(message)
  return false
end

---A UI prompt ended: re-check whether the user left the panel meanwhile.
function Panel:interaction_done()
  self.interacting = false
  vim.schedule(function()
    if self.interacting or not self:is_open() then
      return
    end
    local current = vim.api.nvim_get_current_win()
    if current == self.win or (self.watch_win and current == self.watch_win) then
      return
    end
    self:close()
  end)
end

function Panel:close()
  self.interacting = false
  self.watch_pending = false
  self.team:unwatch()
  self:watch(nil)
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
  self.team:control(team, name, body, function(ok, value)
    self:report(ok, value)
    self.team:refresh()
  end)
end

---Send one message to the participant under the cursor.
function Panel:send_current()
  local kind, team, name = self:current()
  if kind ~= "participant" or name == nil or name == "human" then
    return
  end
  -- `message` is an inbox kind, not a bus kind (PROTOCOL.md 18.1); control
  -- goes through p/r/c and the service refuses it from a normal send here.
  local kinds = { "notice", "task", "question", "answer", "review" }
  self.interacting = true
  vim.ui.select(kinds, {
    prompt = "kind for " .. name,
    format_item = function(entry)
      return entry
    end,
  }, function(choice)
    if choice == nil then
      self:interaction_done()
      return
    end
    self.interacting = true
    vim.ui.input({ prompt = choice .. " to " .. name .. ": " }, function(body)
      self:interaction_done()
      if not body or body == "" then
        return
      end
      self.team:send(team, name, choice, body, nil, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end)
  end)
end

---Start a worker from a configured template (18.13).
function Panel:spawn_current()
  local team = self:team_of_current()
  if not team then
    self:notify("put the cursor on a team or participant first")
    return
  end
  local cfg = self.config and self.config() or {}
  local teams_cfg = type(cfg.teams) == "table" and cfg.teams or {}
  local names = {}
  for name in pairs(teams_cfg.templates or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  if #names == 0 then
    self:notify("no team templates are configured")
    return
  end
  local function ask_task(template, name)
    self.interacting = true
    vim.ui.input({ prompt = "task label (optional): " }, function(task)
      self:interaction_done()
      if task == nil then
        return
      end
      if task == "" then
        task = nil
      end
      self.team:spawn(team, template, name, task, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end)
  end
  local function ask_name(template)
    self.interacting = true
    vim.ui.input({ prompt = "worker name (blank: next free wN): " }, function(name)
      if name == nil then
        self:interaction_done()
        return
      end
      if name == "" then
        ask_task(template, nil)
        return
      end
      local valid = #name <= 32 and name:match("^[a-z0-9][a-z0-9_%-]*$") ~= nil and name ~= "leader" and name ~= "human"
      if not valid then
        self:notify("worker names must match [a-z0-9][a-z0-9_-]{0,31} and not be leader or human")
        ask_name(template)
        return
      end
      ask_task(template, name)
    end)
  end
  self.interacting = true
  vim.ui.select(names, {
    prompt = "template for the new worker",
    format_item = function(entry)
      return entry
    end,
  }, function(template)
    if template == nil then
      self:interaction_done()
      return
    end
    ask_name(template)
  end)
end

---Remove an exited worker's worktree (18.12).
function Panel:remove_worktree_current()
  local kind, team, name = self:current()
  if kind ~= "participant" or name == nil or name == "leader" or name == "human" then
    return
  end
  local entry = self.team:participant(team, name)
  if not entry then
    return
  end
  if entry.state ~= "exited" then
    self:notify("the worker must have exited before its worktree can be removed")
    return
  end
  local worktree = entry.worktree
  if type(worktree) ~= "table" or type(worktree.path) ~= "string" or worktree.path == "" then
    self:notify("this worker has no worktree")
    return
  end
  self.interacting = true
  vim.ui.select({
    { label = "Remove worktree (an unmerged branch is kept)", value = false },
    { label = "Force remove worktree", value = true },
  }, {
    prompt = "remove " .. tostring(worktree.branch or worktree.path) .. "?",
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    self:interaction_done()
    if not choice then
      return
    end
    self.team:remove_worktree(team, name, choice.value, function(ok, value)
      self:report(ok, value)
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
    self.team:answer(item_id, fields, function(ok, value)
      self:report(ok, value)
      self.team:refresh()
    end)
  end
  local function select(opts, cb)
    self.interacting = true
    vim.ui.select(opts.items, opts, function(choice)
      self:interaction_done()
      cb(choice)
    end)
  end
  local function input(prompt, cb)
    self.interacting = true
    vim.ui.input({ prompt = prompt }, function(text)
      self:interaction_done()
      cb(text)
    end)
  end
  if item.kind == "spawn" then
    select({
      prompt = "spawn " .. tostring(item.name or item.template),
      items = { { label = "allow", value = true }, { label = "refuse", value = false } },
      format_item = function(entry)
        return entry.label
      end,
    }, function(choice)
      if choice ~= nil then
        answer({ allow = choice.value == true })
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
    select({
      prompt = "permission",
      items = items,
      format_item = function(entry)
        return entry.label
      end,
    }, function(choice)
      if choice == nil then
        return
      end
      if choice.value == false then
        -- Cancelled: the answer carries no option at all.
        answer({})
      else
        answer({ option = choice.value })
      end
    end)
    return
  end
  if item.kind == "question" and type(item.options) == "table" and #item.options > 0 then
    select({
      prompt = item.body or "question",
      items = item.options,
      format_item = function(entry)
        return tostring(entry)
      end,
    }, function(choice)
      if choice ~= nil then
        answer({ text = choice })
      end
    end)
    return
  end
  if item.kind == "request" then
    local function ask()
      input("JSON result: ", function(text)
        if not text or text == "" then
          return
        end
        local ok, parsed = pcall(vim.json.decode, text)
        if not ok or type(parsed) ~= "table" then
          self:notify("the result must be a JSON object or array")
          ask()
          return
        end
        answer({ text = vim.json.encode(parsed) })
      end)
    end
    ask()
    return
  end
  if item.kind == "question" then
    input(item.body or "answer: ", function(text)
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
  if self.watch_win and not vim.api.nvim_win_is_valid(self.watch_win) then
    self.watch_win = nil
  end
  if self.watch_buf and not vim.api.nvim_buf_is_valid(self.watch_buf) then
    self.watch_buf = nil
  end
  if not self.watch_win then
    self.watch_buf = nil
  end
  if not self.watch_buf or not vim.api.nvim_buf_is_valid(self.watch_buf) then
    local previous = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    self.watch_win = vim.api.nvim_get_current_win()
    self.watch_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(self.watch_win, self.watch_buf)
    vim.bo[self.watch_buf].filetype = "ade_team_watch"
    vim.bo[self.watch_buf].bufhidden = "wipe"
    vim.bo[self.watch_buf].modifiable = false
    local group = vim.api.nvim_create_augroup("AdeTeamWatch", { clear = true })
    -- `bufhidden=wipe` wipes this buffer when the user closes the window, so
    -- BufWipeout is the reliable "watch window is gone" event (WinClosed has
    -- no buffer-local meaning). Capture this view's session/buffer: switching
    -- workers wipes the old buffer while a newer watch is already current.
    local watched, wiped = session, self.watch_buf
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = wiped,
      callback = function()
        vim.schedule(function()
          if self.watch_buf ~= wiped then
            return
          end
          if not self.team.watching or self.team.watching.session ~= watched then
            return
          end
          self.watch_win, self.watch_buf = nil, nil
          self.team:unwatch()
        end)
      end,
    })
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
  if not self.watch_pending then
    self.watch_pending = true
    vim.schedule(function()
      self.watch_pending = false
      if not self.watch_buf or not vim.api.nvim_buf_is_valid(self.watch_buf) then
        return
      end
      if self.watch_lines then
        vim.bo[self.watch_buf].modifiable = true
        vim.api.nvim_buf_set_lines(self.watch_buf, 0, -1, false, self.watch_lines)
        vim.bo[self.watch_buf].modifiable = false
      end
    end)
  end
  self.watch_lines = lines
end

M.Panel = Panel

return M
