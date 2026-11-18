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
    ns = vim.api.nvim_create_namespace("ade-team-float-marks"),
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

---The cursor line's target: `team_id|participant`, `card:<team>|<id>`, ...
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
  if id:sub(1, 5) == "card:" then
    local team, card = id:sub(6):match("^([^|]+)|(.+)$")
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

---@return string[], table<integer, string>, table[]
function Panel:lines()
  local lines, ids, marks = {}, {}, {}
  local rows = self.team:list_rows()
  local width = 80
  if self:is_open() then
    width = vim.api.nvim_win_get_width(self.win)
  end
  local function add(text, id, relative)
    lines[#lines + 1] = text
    ids[#lines] = id
    for _, mark in ipairs(relative or {}) do
      marks[#marks + 1] = {
        line = #lines,
        start = (mark.start or 0) + 3,
        stop = (mark.stop or 0) + 3,
        group = mark.group,
      }
    end
  end
  add(" ade.nvim · team", nil)
  add("", nil)
  if self.help then
    for _, entry in ipairs({
      { "m", "send a message to a participant" },
      { "p / r / c", "pause / resume / cancel the participant" },
      { "<CR> / w", "card detail / watch the participant" },
      { "s", "start a worker from a template" },
      { "D", "remove an exited worker's worktree" },
      { "a / !", "answer a participant's pending choice / list them" },
      { "m", "message a participant or the leader about a card" },
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
    local Roles = require("ade.ui.team.roles")
    local palette = Roles.palette(team.participants)
    local member_lines, member_ids, _, member_marks = Members.lines(team, math.max(8, width - 4), {
      messages = {},
      max_workers = cfg_teams.max_workers,
    })
    local member_line_of = {}
    for index, text in ipairs(member_lines) do
      member_line_of[index] = #lines + 1
      add("   " .. text, member_ids[index])
    end
    for _, mark in ipairs(member_marks) do
      marks[#marks + 1] = {
        line = member_line_of[mark.line] or mark.line,
        start = (mark.start or 0) + 3,
        stop = (mark.stop or 0) + 3,
        group = mark.group,
      }
    end
    local board = self.team:board(team.id)
    if board then
      add("", nil)
      local rev = tonumber(board.rev)
      local label = rev and ("看板 · rev " .. rev) or "看板"
      if board.unavailable then
        label = "看板"
      end
      add("   " .. label, nil)
      local states = {}
      for _, participant in ipairs(team.participants or {}) do
        states[participant.name] = {
          icon = Members.state_icon(participant),
          symbol = Roles.symbol(participant),
          state = participant.state,
          state_text = Members.state_label(participant),
          role_hl = Roles.hl(participant, palette),
        }
      end
      self.scrolls = self.scrolls or {}
      self.expanded_stages = self.expanded_stages or {}
      local board_lines, board_meta, board_ids, board_marks = Board.lines(board, states, {
        scroll = self.scrolls[team.id] or 0,
        expanded = self.expanded_stages[team.id] or {},
        width = math.max(24, width - 4),
        team = team,
        single_column = true,
      })
      local board_line_of = {}
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
        board_line_of[index] = #lines + 1
        add("   " .. text, id)
      end
      for _, mark in ipairs(board_marks) do
        marks[#marks + 1] = {
          line = board_line_of[mark.line] or mark.line,
          start = (mark.start or 0) + 3,
          stop = (mark.stop or 0) + 3,
          group = mark.group,
        }
      end
    end
    add("", nil)
  end
  return lines, ids, marks
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
  local lines, ids, marks = self:lines()
  self.ids = ids
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  require("ade.ui.team.text").apply_marks(self.buf, self.ns, marks)
end

---The team id for the cursor line, including board cards and archived stages.
---@return string|nil
function Panel:team_of_current()
  local kind, a = self:current()
  if kind == "team" or kind == "participant" or kind == "card" or kind == "stage" then
    return a
  end
  if kind == "workflow" then
    local row = self.team:list_rows()[1]
    return row and row.id or nil
  end
  return nil
end

---The team that owns `line`, from the nearest preceding id. Hint and spacer
---lines have no id, so this must not fall back to an unrelated team (B3).
---@param line integer
---@return string|nil
function Panel:team_at_line(line)
  for index = line, 1, -1 do
    local id = self.ids and self.ids[index]
    if type(id) == "string" then
      local team = id:match("^team:(.+)$")
      if team then
        return team
      end
      team = id:match("^card:([^|]+)|") or id:match("^stage:([^|]*)|") or id:match("^([^|]+)|")
      if team then
        return team
      end
    end
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
  local function choices()
    local controller = require("ade.controller")
    local state = controller.state()
    return state and state.view and state.view.choices or nil
  end
  self:map("a", function()
    local queue = choices()
    if not queue then
      self:notify("选择组件尚未就绪")
      return
    end
    local kind, team, name = self:current()
    if kind == "participant" and name then
      queue:answer_participant(team, name)
      return
    end
    local team_id = self:team_of_current() or (self.team:list_rows()[1] or {}).id
    local pending = queue.selectable_count and queue:selectable_count(team_id) or 0
    queue:show_pending(team_id)
    if pending > 0 and not queue:is_open() then
      self:notify("先打开聊天窗口（:Ade open）再显示选择组件")
    end
  end)
  self:map("!", function()
    local queue = choices()
    if not queue then
      self:notify("选择组件尚未就绪")
      return
    end
    local team_id = self:team_of_current() or (self.team:list_rows()[1] or {}).id
    local pending = queue.selectable_count and queue:selectable_count(team_id) or 0
    queue:show_pending(team_id)
    if pending > 0 and not queue:is_open() then
      self:notify("先打开聊天窗口（:Ade open）再显示选择组件")
    end
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
  local function scroll_board(delta)
    local line = self:is_open() and vim.api.nvim_win_get_cursor(self.win)[1] or 1
    local team = self:team_at_line(line)
    if not team then
      return
    end
    local board = self.team:board(team)
    local columns = board and #(board.columns or {}) or 1
    local max_scroll = math.max(0, columns - 1)
    self.scrolls = self.scrolls or {}
    self.scrolls[team] = math.max(0, math.min(max_scroll, (self.scrolls[team] or 0) + delta))
    self:refresh()
  end
  self:map("zh", function()
    scroll_board(-1)
  end)
  self:map("zl", function()
    scroll_board(1)
  end)
  self:map("w", function()
    self:open_watch_current()
  end)
  self:map("<CR>", function()
    local kind = self:current()
    if kind == "participant" then
      self:open_watch_current()
    else
      self:detail_current()
    end
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
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      vim.schedule(function()
        local cfg = self.config and self.config() or {}
        local wide = tonumber(((cfg.teams or {}).dashboard or {}).wide) or 160
        if vim.o.columns >= wide then
          pcall(function()
            require("ade.controller").open_team()
          end)
        end
      end)
    end,
  })
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
  if kind == "card" and name then
    if self:refuse_stale(team) then
      return
    end
    vim.ui.input({ prompt = "message about " .. tostring(name) .. ": " }, function(body)
      if not body or body == "" then
        return
      end
      self.team:send(team, "leader", "notice", body, { card = name }, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end)
    return
  end
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
  vim.bo[buf].filetype = "ade_team_detail"
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
