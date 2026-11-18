-- The team panel (PROTOCOL.md 18.5/18.9) and the read-only watch window.
--
-- Deliberately small and reusable: the panel is one scratch buffer with a
-- cursor-mapped list; the watch window renders a session from the ordinary
-- reducer, so a watched worker looks like a chat without owning one.
local Watch = require("ade.ui.team.watch")
local Board = require("ade.ui.team.board")
local Detail = require("ade.ui.team.detail")

local M = {}

local Panel = {}
Panel.__index = Panel

---@param opts {team: table, config: fun(): table}
---@return table
function M.new(opts)
  local panel = setmetatable({
    team = opts.team,
    config = opts.config,
    start_team = opts.start_team,
    leader_chat = opts.leader_chat,
    win = nil,
    buf = nil,
    watch_win = nil,
    watch_buf = nil,
    help = false,
  }, Panel)
  panel.watcher = Watch.new({
    team = opts.team,
    config = opts.config,
    leader_chat = opts.leader_chat,
    notify = function(message)
      panel:notify(message)
    end,
    on_change = function(watch)
      panel.watch_win, panel.watch_buf = watch.win, watch.buf
    end,
  })
  return panel
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
  if id:sub(1, 6) == "card:" then
    local team, card = id:sub(7):match("^([^|]+)|(.+)$")
    return "card", team, card
  end
  if id:sub(1, 6) == "stage:" then
    local team, stage = id:sub(7):match("^([^|]*)|(.*)$")
    return "stage", team, stage
  end
  if id:sub(1, 9) == "workflow:" then
    return "workflow", id:sub(10)
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
      { "<CR> / w", "watch the participant's transcript" },
      { "s", "start a worker from a template" },
      { "D", "remove an exited worker's worktree" },
      { "a / !", "answer a participant's pending choice / list them" },
      { "<CR>", "card detail or watch the participant" },
      { "R", "reset limits" },
      { "x", "close the team" },
      { "g?", "toggle this help" },
      { "q", "close this panel" },
    }) do
      add(string.format("    %-10s %s", entry[1], entry[2]), nil)
    end
    add("", nil)
  end
  if #rows == 0 then
    add(" ade.nvim · team", nil)
    add("", nil)
    add(" 还没有团队", nil)
    local workflows = self.team.workflows_list
    if workflows == nil then
      add(" 正在读取可用流程…", nil)
      self:load_workflows()
      workflows = {}
    end
    if #workflows == 0 then
      add(" 没有可用流程", nil)
    else
      add(" 可用流程（S 启动，<CR> 看全文）", nil)
      for _, workflow in ipairs(workflows) do
        add(
          string.format("   %-20s %s", tostring(workflow.name), tostring(workflow.summary or "")),
          "workflow:" .. tostring(workflow.name)
        )
      end
    end
    return lines, ids
  end
  for _, team in ipairs(rows) do
    add(string.format(" %s  %s  [%s]", team.id, tostring(team.cwd), tostring(team.state)), "team:" .. tostring(team.id))
    if team.stale then
      add("   connection lost; waiting for the service to reconnect", nil)
    end
    if team.state == "suspended" then
      local at = tonumber(team.suspended_at)
      local when = at and os.date("%Y-%m-%d %H:%M:%S", math.floor(at / 1000)) or "unknown"
      add("   suspended since " .. when .. "; waiting for the leader session to resume", nil)
    end
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
    local Members = require("ade.ui.team.members")
    local member_lines, member_ids = Members.lines(team, math.max(40, vim.o.columns - 8))
    for index, text in ipairs(member_lines) do
      add("   " .. text, member_ids[index])
    end
    local board = self.team:board(team.id)
    if board then
      add("", nil)
      add(string.format("   看板 · rev %s", tostring(board.rev or "?")), nil)
      local states = {}
      for _, participant in ipairs(team.participants or {}) do
        states[participant.name] =
          { icon = require("ade.ui.team.members").state_icon(participant), state = participant.state }
      end
      self.scrolls = self.scrolls or {}
      self.expanded_stages = self.expanded_stages or {}
      local board_lines, board_meta, board_ids = Board.lines(board, states, {
        scroll = self.scrolls[team.id] or 0,
        expanded = self.expanded_stages[team.id] or {},
        width = math.max(50, vim.o.columns - 8),
        team = team,
      })
      for index, text in ipairs(board_lines) do
        local id = board_ids[index]
        if not id and board_meta[index] then
          local info = board_meta[index]
          if info.kind == "archived_stage" then
            id = "stage:" .. team.id .. "|" .. tostring(info.stage or "")
          elseif info.kind == "board_row" and info.cells and #info.cells == 1 and info.cells[1].card then
            id = "card:" .. team.id .. "|" .. tostring(info.cells[1].card.id)
          end
        end
        if id and id:sub(1, 5) == "card:" then
          id = "card:" .. team.id .. "|" .. id:sub(6)
        end
        add("   " .. text, id)
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
  if self.watcher then
    self.watcher:update_header()
  end
  local rows = self.team:list_rows()
  if #rows == 0 and self.had_teams then
    self:close()
    return
  end
  if #rows > 0 then
    self.had_teams = true
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
    local kind, team, name = self:current()
    if kind == "participant" and name then
      require("ade.app.choices").answer_participant(team, name)
    else
      self:answer_current()
    end
  end)
  self:map("!", function()
    local team = self:team_of_current() or (self.team:list_rows()[1] or {}).id
    require("ade.app.choices").show_pending(team)
  end)
  self:map("A", function()
    self:answer_group_current()
  end)
  self:map("H", function()
    self:history_current()
  end)
  self:map("L", function()
    local chat = self.leader_chat and self.leader_chat() or nil
    if chat and chat.win and vim.api.nvim_win_is_valid(chat.win) then
      pcall(vim.api.nvim_set_current_win, chat.win)
    else
      self:notify("the leader chat window is not open")
    end
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
    if team and not self:refuse_stale(team) then
      self.team:reset_limits(team, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end
  end)
  self:map("<CR>", function()
    self:detail_current()
  end)
  self:map("zh", function()
    local team = self:team_of_current()
    if team then
      self.scrolls = self.scrolls or {}
      self.scrolls[team] = math.max(0, (self.scrolls[team] or 0) - 1)
      self:refresh()
    end
  end)
  self:map("zl", function()
    local team = self:team_of_current()
    if team then
      self.scrolls = self.scrolls or {}
      self.scrolls[team] = (self.scrolls[team] or 0) + 1
      self:refresh()
    end
  end)
  self:map("w", function()
    self:open_watch_current()
  end)
  self:map("<CR>", function()
    self:open_watch_current()
  end)
  self:map("S", function()
    self:start_workflow_current()
  end)
  self:map("s", function()
    self:spawn_current()
  end)
  self:map("D", function()
    self:remove_worktree_current()
  end)
  self:map("x", function()
    local team = self:team_of_current()
    if not team or self:refuse_stale(team) then
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
  if self.watcher then
    self.watcher:close()
  else
    self.team:unwatch()
  end
  self.watch_win, self.watch_buf = nil, nil
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win, self.buf = nil, nil
end

---Explain that a suspended team cannot take this operation yet.
function Panel:suspended_notice()
  self:notify("the team is suspended; wait for the leader session to resume or press x to close it")
end

---@param team string|nil
---@return boolean
function Panel:refuse_suspended(team)
  if team and self.team:is_suspended(team) then
    self:suspended_notice()
    return true
  end
  return false
end

---Refuse an operation on a team whose connection is gone.
---@param team string|nil
---@return boolean
function Panel:refuse_stale(team)
  if team and self.team:is_stale(team) then
    self:notify("the connection to the service is lost; wait for it to reconnect")
    return true
  end
  return false
end

---Pause/resume/cancel the participant under the cursor.
---@param body string
function Panel:control_current(body)
  local kind, team, name = self:current()
  if kind ~= "participant" or name == nil then
    return
  end
  if name == "human" or self:refuse_stale(team) or self:refuse_suspended(team) then
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
  if kind ~= "participant" or name == nil or name == "human" or self:refuse_stale(team) then
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
  if self:refuse_stale(team) or self:refuse_suspended(team) then
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
  if self:refuse_stale(team) then
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
  if self:refuse_stale(item.team) then
    return
  end
  if
    self.team:is_suspended(item.team)
    and item.kind ~= "question"
    and item.kind ~= "message"
    and item.kind ~= "limit"
  then
    self:suspended_notice()
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

---Render a watched session in the read-only watch view.
---
---Kept as the app's `on_watch` callback; the view itself owns the window,
---turn grouping and the read-only Chat instance.
---@param session table|nil
---@param title string|nil
function Panel:watch(session, title)
  self.watcher:on_watch(session, title)
  self.watch_win, self.watch_buf = self.watcher.win, self.watcher.buf
end

---Open (or close) the cursor participant's watch view. `<CR>` and `w` both
---use this.
---@return boolean
function Panel:open_watch_current()
  local kind, team, name = self:current()
  if kind ~= "participant" then
    return false
  end
  if self:refuse_stale(team) or self:refuse_suspended(team) then
    return false
  end
  self.watcher:open(team, name)
  self.watch_win, self.watch_buf = self.watcher.win, self.watcher.buf
  return true
end

function Panel:load_workflows()
  if self.loading_workflows then
    return
  end
  self.loading_workflows = true
  local cwd = self.team.resolve_cwd and self.team.resolve_cwd() or nil
  if not cwd then
    self.loading_workflows = false
    return
  end
  self.team:workflows(cwd, function(ok, value)
    self.loading_workflows = false
    self.team.workflows_list = ok and type(value) == "table" and value.workflows or {}
    self:refresh()
  end)
end

function Panel:start_workflow_current()
  local kind, id = self:current()
  if kind ~= "workflow" or not id then
    return
  end
  if self.start_team then
    self.start_team(id)
  end
end

function Panel:detail_current()
  local kind, team_id, obj = self:current()
  if kind == "card" and obj then
    local team = self.team:team(team_id)
    self:popup("卡片 " .. tostring(obj), Detail.card(team, self:find_card(team_id, obj)))
  elseif kind == "stage" and obj ~= nil then
    self.expanded_stages = self.expanded_stages or {}
    local expanded = self.expanded_stages[team_id] or {}
    expanded[obj] = not expanded[obj]
    self.expanded_stages[team_id] = expanded
    self:refresh()
  elseif kind == "workflow" and obj then
    for _, workflow in ipairs(self.team.workflows_list or {}) do
      if workflow.name == obj then
        self:popup("流程 " .. obj, Detail.workflow(workflow))
        return
      end
    end
  end
end

function Panel:find_card(team_id, card_id)
  local board = self.team:board(team_id)
  for _, card in ipairs(board and board.cards or {}) do
    if card.id == card_id then
      return card
    end
  end
end

function Panel:popup(title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.min(100, math.max(50, math.floor(vim.o.columns * 0.8)))
  local height = math.max(8, math.min(#lines, math.floor((vim.o.lines - vim.o.cmdheight) * 0.6)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. tostring(title) .. " ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true })
end

function Panel:answer_group_current()
  local kind, item_id = self:current()
  if kind ~= "item" or not item_id then
    return
  end
  local item = self.team:item(item_id)
  if not item then
    return
  end
  if not item.group then
    self:answer_current()
    return
  end
  self.team:answer_group(item.group, true, function(ok, value)
    self:report(ok, value)
    self.team:refresh()
  end)
end

function Panel:history_current()
  local kind, team_id, card_id = self:current()
  if kind ~= "card" or not card_id then
    return
  end
  self.team:card_history(team_id, card_id, function(ok, value)
    if self:report(ok, value) and type(value) == "table" then
      require("ade.ui.team.history").open(team_id, card_id, value.versions or {})
    end
  end)
end

M.Panel = Panel

return M
