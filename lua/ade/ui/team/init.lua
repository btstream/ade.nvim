-- The unified team dashboard (`:Ade team`, W0f).
--
-- One controller drives two layouts: a wide tabpage with members and board and
-- the narrow centred float. Card details are popups, not a permanent pane.
local Float = require("ade.ui.team.layout_float")
local Tab = require("ade.ui.team.layout_tab")
local Watch = require("ade.ui.team.watch")
local Members = require("ade.ui.team.members")
local Board = require("ade.ui.team.board")
local Roles = require("ade.ui.team.roles")
local Choices = require("ade.app.choices")
local Detail = require("ade.ui.team.detail")
local History = require("ade.ui.team.history")

local M = {}

local Dashboard = {}
Dashboard.__index = Dashboard

local REFRESH_MS = 50

local function one_line(text)
  return (tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param opts {team: table, config: fun(): table, notify: fun(message: string, level: integer|nil)|nil,
---  leader_chat: (fun(): table|nil)|nil, leader_input: (fun(): table|nil)|nil,
---  start_team: (fun(workflow: string)|nil)|nil, workflows: (fun(): table[]|nil)|nil}
---@return table
function M.dashboard(opts)
  local self = setmetatable({
    team = opts.team,
    config = opts.config,
    notify_fn = opts.notify,
    leader_chat = opts.leader_chat,
    leader_input = opts.leader_input,
    panel = opts.panel,
    start_team = opts.start_team,
    layout = nil,
    float = nil,
    tab = nil,
    watcher = nil,
    index = 1,
    selected_id = nil,
    help = false,
    replies = {},
    cwd = nil,
    refresh_timer = nil,
    pending = false,
    link_ns = vim.api.nvim_create_namespace("ade-team-link"),
    follower = nil,
  }, Dashboard)
  self.watcher = Watch.new({
    team = opts.team,
    config = opts.config,
    notify = function(message)
      self:notify(message)
    end,
    leader_chat = opts.leader_chat,
    on_change = function(watch)
      self.watch_win, self.watch_buf = watch.win, watch.buf
    end,
  })
  return self
end

function Dashboard:notify(message, level)
  if self.notify_fn then
    self.notify_fn(tostring(message), level)
  else
    vim.notify("ade.nvim: " .. tostring(message), level or vim.log.levels.WARN)
  end
end

function Dashboard:report(ok, value)
  if ok then
    return true
  end
  local message = type(value) == "table" and (value.message or value.code) or tostring(value)
  if type(value) == "table" and type(value.data) == "table" and value.data.stderr then
    message = tostring(message) .. ": " .. tostring(value.data.stderr)
  end
  self:notify(message)
  return false
end

function Dashboard:is_open()
  if self.tab then
    return self.tab:is_open()
  end
  return self.float ~= nil and self.float:is_open()
end

function Dashboard:has_content()
  return #self.team:list_rows() > 0
end

function Dashboard:current_team()
  local rows = self.team:list_rows()
  if #rows == 0 then
    return nil
  end
  if self.selected_id then
    for index, row in ipairs(rows) do
      if row.id == self.selected_id then
        self.index = index
        return row
      end
    end
  end
  self.index = math.max(1, math.min(self.index, #rows))
  self.selected_id = rows[self.index].id
  return rows[self.index]
end

function Dashboard:team_by_id(id)
  for _, team in ipairs(self.team:list_rows()) do
    if team.id == id then
      return team
    end
  end
end

function Dashboard:states(team)
  local out = {}
  for _, participant in ipairs(team and team.participants or {}) do
    out[participant.name] = {
      icon = Members.state_icon(participant),
      symbol = Roles.symbol(participant),
      state = participant.state,
      state_text = Members.state_label(participant),
      role_hl = Roles.hl(participant),
      label = Roles.label(participant),
      agent = participant.agent,
      model = participant.model,
      template = participant.template,
    }
  end
  return out
end

function Dashboard:board(team)
  return team and self.team:board(team.id) or nil
end

function Dashboard:expanded(team_id)
  self.expanded_stages = self.expanded_stages or {}
  self.expanded_stages[team_id] = self.expanded_stages[team_id] or {}
  return self.expanded_stages[team_id]
end

function Dashboard:scroll(team_id)
  self.scrolls = self.scrolls or {}
  self.scrolls[team_id] = self.scrolls[team_id] or 0
  return self.scrolls[team_id]
end

function Dashboard:title(team)
  local rows = self.team:list_rows()
  local cfg = self.config() or {}
  local teams_cfg = type(cfg.teams) == "table" and cfg.teams or {}
  local state = tostring(team.state)
  if self.team:is_stale(team.id) then
    state = "stale"
  end
  local workers, max_workers = 0, tonumber(teams_cfg.max_workers) or 3
  for _, participant in ipairs(team.participants or {}) do
    if participant.name ~= "leader" and participant.name ~= "human" and participant.state ~= "exited" then
      workers = workers + 1
    end
  end
  local limits = team.limits or {}
  local selected = ""
  if #rows > 1 then
    local index = 1
    for position, row in ipairs(rows) do
      if row.id == team.id then
        index = position
      end
    end
    selected = string.format(" [%d/%d] ", index, #rows)
  end
  return string.format(
    " ade.nvim · team %s · %s%s  %s · workers %d/%d · turns %s/%s · board rev %s",
    tostring(team.id),
    tostring(team.cwd),
    selected,
    state,
    workers,
    max_workers,
    tostring(limits.turns_total or 0),
    tostring(limits.max_turns_total or "?"),
    tostring(team.board_rev or 0)
  )
end

function Dashboard:workflow_line(team)
  local name = team.workflow_name
  local label = name and tostring(name) or (team.board_rev and tonumber(team.board_rev) > 0 and "自定义" or "默认")
  local progress = Board.stage_progress(team.stages)
  local line = " 流程：" .. label
  if progress then
    line = line .. " · " .. progress
  end
  return line
end

function Dashboard:render_tab(tab)
  local team = self:current_team()
  local rendered = { members = {}, board = {}, meta = {}, ids = {}, marks = {} }
  if not team then
    rendered.members = { " ade.nvim · team", "", " 还没有团队" }
    rendered.meta.members = { {}, {}, {} }
    rendered.ids.members = {}
    local workflows = self.team.workflows_list
    if workflows == nil then
      rendered.members[#rendered.members + 1] = " 正在读取可用流程…"
      rendered.meta.members[#rendered.members] = {}
      self:load_workflows()
      workflows = {}
    end
    if #workflows == 0 then
      rendered.members[#rendered.members + 1] = " 没有可用流程"
      rendered.meta.members[#rendered.members] = {}
    else
      rendered.members[#rendered.members + 1] = " 可用流程（S 启动，<CR> 看全文）"
      rendered.meta.members[#rendered.members] = {}
      for _, workflow in ipairs(workflows) do
        rendered.members[#rendered.members + 1] =
          string.format("   %-20s %s", tostring(workflow.name), one_line(workflow.summary or ""))
        rendered.meta.members[#rendered.members] = { kind = "workflow", workflow = workflow }
        rendered.ids.members[#rendered.members] = "workflow:" .. tostring(workflow.name)
      end
    end
    return rendered
  end
  local members_width = 32
  if tab.panels.members and vim.api.nvim_win_is_valid(tab.panels.members) then
    members_width = vim.api.nvim_win_get_width(tab.panels.members)
  end
  local messages = {}
  for _, item in pairs(self.team.inbox) do
    if item.team == team.id and item.state == "open" and item.kind == "message" then
      messages[item.from] = (messages[item.from] or 0) + 1
    end
  end
  local cfg = self.config() or {}
  local workers_max = tonumber((type(cfg.teams) == "table" and cfg.teams.max_workers) or 3) or 3
  local lines, ids, meta, marks = Members.lines(team, members_width - 1, {
    messages = messages,
    max_workers = workers_max,
  })
  rendered.members = lines
  rendered.meta.members = meta
  rendered.ids.members = ids
  rendered.marks = (rendered.marks or {})
  for _, mark in ipairs(marks or {}) do
    rendered.marks[#rendered.marks + 1] = {
      line = mark.line,
      start = mark.start,
      stop = mark.stop,
      group = mark.group,
      panel = "members",
    }
  end
  local board_width = 60
  if tab.panels.board and vim.api.nvim_win_is_valid(tab.panels.board) then
    board_width = math.max(24, vim.api.nvim_win_get_width(tab.panels.board) - 2)
  end
  local board = self:board(team)
  local board_lines, board_meta, board_ids, board_marks = Board.lines(board, self:states(team), {
    scroll = self:scroll(team.id),
    expanded = self:expanded(team.id),
    width = board_width,
    team = team,
  })
  rendered.board = board_lines
  rendered.meta.board = board_meta
  rendered.ids.board = board_ids
  for _, mark in ipairs(board_marks or {}) do
    rendered.marks[#rendered.marks + 1] =
      { line = mark.line, start = mark.start, stop = mark.stop, group = mark.group, panel = "board" }
  end
  self:update_tabline()
  return rendered
end

---No permanent detail window in v2: refresh the board cursor highlight only.
function Dashboard:update_detail()
  self:update_board_cursor()
end

function Dashboard:layout_current()
  if self.tab and self.tab:is_open() then
    return self.tab:current()
  end
  if self.float and self.float.current then
    return self.float:current()
  end
  return nil
end

function Dashboard:update_board_cursor()
  if not (self.tab and self.tab:is_open()) then
    return
  end
  local buf = self.tab.buffers.board
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, self.tab.cursor_ns, 0, -1)
  local kind, _, card = self:layout_current()
  if kind ~= "card" or type(card) ~= "table" then
    return
  end
  local meta = self.tab.meta.board or {}
  for line, info in pairs(meta) do
    for _, cell in ipairs(info.cells or {}) do
      if cell.card == card then
        pcall(vim.api.nvim_buf_set_extmark, buf, self.tab.cursor_ns, line - 1, cell.start, {
          end_row = line - 1,
          end_col = cell.stop,
          hl_group = "AdeBoardCardCursor",
          priority = 120,
        })
      end
    end
  end
end

function Dashboard:tabline_prefix()
  return " ade.nvim · team "
end

function Dashboard:tabline_text()
  local team = self:current_team()
  if not team then
    return " ade.nvim · team"
  end
  local rows = self.team:list_rows()
  local index = 1
  for position, row in ipairs(rows) do
    if row.id == team.id then
      index = position
    end
  end
  local cfg = self.config() or {}
  local teams_cfg = type(cfg.teams) == "table" and cfg.teams or {}
  local workers, max_workers = 0, tonumber(teams_cfg.max_workers) or 3
  for _, participant in ipairs(team.participants or {}) do
    if participant.name ~= "leader" and participant.name ~= "human" and participant.state ~= "exited" then
      workers = workers + 1
    end
  end
  local limits = team.limits or {}
  local state = self.team:is_stale(team.id) and "stale" or tostring(team.state)
  local flow = team.workflow_name and tostring(team.workflow_name) or "default"
  local progress = Board.stage_progress(team.stages) or ""
  local counts = Choices.pending_counts(team.id) or {}
  local q = tonumber(counts.question) or 0
  local a = tonumber(counts.approval) or 0
  local suffix = ""
  if #rows > 1 then
    suffix = string.format(" [%d/%d]", index, #rows)
  end
  return string.format(
    " ade.nvim · team %s · %s%s · %s · workers %d/%d · turns %s/%s │ 流程 %s%s │ ? 待回答 %d  ⚑ 待批准 %d ",
    tostring(team.id),
    tostring(team.cwd),
    suffix,
    state,
    workers,
    max_workers,
    tostring(limits.turns_total or 0),
    tostring(limits.max_turns_total or "?"),
    flow,
    progress ~= "" and (" · " .. progress) or "",
    q,
    a
  )
end

function Dashboard:install_tabline()
  self.saved_tabline = self.saved_tabline or vim.o.tabline
  self:update_tabline()
  if not self.tabline_group then
    self.tabline_group = vim.api.nvim_create_augroup("AdeTeamTabline" .. tostring(vim.uv.hrtime()), { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = self.tabline_group,
      pattern = "AdeChoicesChanged",
      callback = function()
        if self:is_open() then
          self:update_tabline()
        end
      end,
    })
  end
end

function Dashboard:update_tabline()
  if not (self.tab and self.tab:is_open()) then
    return
  end
  local text = self:tabline_text():gsub("%%", "%%%%")
  pcall(function()
    vim.o.tabline = text
  end)
end

function Dashboard:restore_tabline()
  if self.saved_tabline then
    pcall(function()
      vim.o.tabline = self.saved_tabline
    end)
    self.saved_tabline = nil
  end
  if self.tabline_group then
    pcall(vim.api.nvim_del_augroup_by_id, self.tabline_group)
    self.tabline_group = nil
  end
end

function Dashboard:attach_keys(buf)
  local function map(lhs, key)
    vim.keymap.set("n", lhs, function()
      self:handle_key(key)
    end, { buffer = buf, nowait = true, silent = true })
  end
  for lhs, key in pairs({
    ["<CR>"] = "cr",
    ["m"] = "m",
    ["a"] = "a",
    ["A"] = "A",
    ["!"] = "choices",
    ["w"] = "w",
    ["p"] = "p",
    ["r"] = "r",
    ["c"] = "c",
    ["D"] = "D",
    ["H"] = "H",
    ["L"] = "L",
    ["s"] = "s",
    ["R"] = "R",
    ["x"] = "x",
    ["S"] = "S",
    ["g?"] = "help",
    ["q"] = "q",
    ["zh"] = "zh",
    ["zl"] = "zl",
    ["]t"] = "]t",
    ["[t"] = "[t",
    ["<Tab>"] = "next",
    ["<S-Tab>"] = "prev",
  }) do
    map(lhs, key)
  end
end

---@param team string|nil
function Dashboard:refuse_stale(team)
  if team and self.team:is_stale(team) then
    self:notify("the connection to the service is lost; wait for it to reconnect")
    return true
  end
  return false
end

function Dashboard:refuse_suspended(team)
  if team and self.team:is_suspended(team) then
    self:notify("the team is suspended; wait for the leader session to resume or press x to close it")
    return true
  end
  return false
end

function Dashboard:handle_key(key)
  local kind, team_id, obj, info = self:layout_current()
  local team = team_id or (self:current_team() and self:current_team().id)
  if key == "next" then
    if self.tab and self.tab:is_open() then
      self.tab:cycle(1)
    end
    return
  end
  if key == "prev" then
    if self.tab and self.tab:is_open() then
      self.tab:cycle(-1)
    end
    return
  end
  if key == "]" or key == "[t" or key == "]t" then
    local rows = self.team:list_rows()
    if #rows == 0 then
      return
    end
    self.index = ((self.index - 1 + (key == "[t" and -1 or 1)) % #rows) + 1
    self.selected_id = rows[self.index].id
    self:refresh()
    return
  end
  if key == "q" then
    self:close()
    return
  end
  if key == "help" then
    if self.float and self.float:is_open() then
      self.float.help = not self.float.help
      self.float:refresh()
    else
      self:notify("team: <CR> card/member · a/! pending choice · m message · H history · s spawn · x close")
    end
    return
  end
  if key == "zh" or key == "zl" then
    if team then
      self.scrolls = self.scrolls or {}
      local max_columns = math.max(0, #((self:board(self:team_by_id(team)) or {}).columns or {}) - 1)
      local value = (self.scrolls[team] or 0) + (key == "zl" and 1 or -1)
      self.scrolls[team] = math.max(0, math.min(max_columns, value))
      self:refresh()
    end
    return
  end
  if key == "cr" then
    if kind == "participant" and obj then
      self:open_watch(team, obj)
    elseif kind == "card" and obj then
      self:show_detail(Detail.card(self:team_by_id(team), obj), "卡片 " .. tostring(obj.id))
    elseif kind == "archived_stage" and info then
      local expanded = self:expanded(team)
      expanded[info.stage] = not expanded[info.stage]
      self:refresh()
    elseif kind == "workflow" and info then
      self:show_detail(Detail.workflow(info.workflow), "流程 " .. tostring(info.workflow.name))
    elseif kind == "title" and team then
      self:show_detail({ self:title(self:team_by_id(team)), self:workflow_line(self:team_by_id(team)) }, "团队")
    end
    return
  end
  if key == "w" then
    if kind == "participant" and obj then
      self:open_watch(team, obj)
    end
    return
  end
  if key == "m" then
    if kind == "participant" and obj then
      self:send_to_participant(team, obj)
    elseif kind == "card" and obj then
      self:send_card(team, obj)
    end
    return
  end
  if key == "a" then
    if kind == "participant" and obj and team then
      Choices.answer_participant(team, obj)
    else
      self:answer_current(false)
    end
    return
  end
  if key == "A" then
    self:answer_current(true)
    return
  end
  if key == "choices" then
    Choices.show_pending(team)
    self:update_tabline()
    return
  end
  if key == "p" or key == "r" or key == "c" then
    if
      kind == "participant"
      and obj
      and obj ~= "human"
      and not self:refuse_stale(team)
      and not self:refuse_suspended(team)
    then
      local body = key == "p" and "pause" or key == "r" and "resume" or "cancel"
      self.team:control(team, obj, body, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end
    return
  end
  if key == "D" then
    if kind == "participant" and obj and obj ~= "leader" and obj ~= "human" then
      self:remove_worktree(team, obj)
    end
    return
  end
  if key == "H" then
    if kind == "card" and obj then
      self.team:card_history(team, obj.id, function(ok, value)
        if self:report(ok, value) and type(value) == "table" then
          History.open(team, obj.id, value.versions or {})
        end
      end)
    end
    return
  end
  if key == "L" then
    self:open_leader()
    return
  end
  if key == "s" then
    self:spawn_current(team)
    return
  end
  if key == "R" then
    if team and not self:refuse_stale(team) then
      self.team:reset_limits(team, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end
    return
  end
  if key == "x" then
    self:close_team(team)
    return
  end
  if key == "S" then
    if kind == "workflow" and info and info.workflow and self.start_team then
      self.start_team(info.workflow.name)
    elseif team and self.start_team then
      local workflows = self.team.workflows_list or {}
      if #workflows > 0 then
        self.start_team(workflows[1].name)
      end
    end
    return
  end
end

function Dashboard:show_detail(lines, title)
  self:popup(title or "详情", lines)
end

function Dashboard:popup(title, lines)
  local previous = vim.api.nvim_get_current_win()
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
    title = " " .. tostring(title or "详情") .. " ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true })
  pcall(vim.api.nvim_set_current_win, previous)
end

function Dashboard:send_to_participant(team, name)
  if self:refuse_stale(team) then
    return
  end
  local kinds = { "notice", "task", "question", "answer", "review" }
  self.interacting = true
  vim.ui.select(kinds, {
    prompt = "kind for " .. name,
    format_item = tostring,
  }, function(choice)
    if choice == nil then
      self.interacting = false
      return
    end
    vim.ui.input({ prompt = choice .. " to " .. name .. ": " }, function(body)
      self.interacting = false
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

function Dashboard:send_card(team, card)
  if self:refuse_stale(team) then
    return
  end
  vim.ui.input({ prompt = "message about " .. tostring(card.id) .. ": " }, function(body)
    if not body or body == "" then
      return
    end
    self.team:send(team, "leader", "notice", body, { card = card.id }, function(ok, value)
      self:report(ok, value)
      self.team:refresh()
    end)
  end)
end

function Dashboard:answer_current(group)
  local kind, team_id, obj, info = self:layout_current()
  if kind == "inbox_group" and info then
    if group then
      self.team:answer_group(info.group, true, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    else
      local item = self.team:item(info.item_ids[1])
      if item then
        self:answer_item(item)
      end
    end
    return
  end
  if kind ~= "inbox" or type(obj) ~= "table" then
    return
  end
  self:answer_item(obj)
end

function Dashboard:answer_item(item)
  if self:refuse_stale(item.team) then
    return
  end
  local function answer(fields)
    self.team:answer(item.id, fields, function(ok, value)
      self:report(ok, value)
      self.team:refresh()
    end)
  end
  if item.kind == "spawn" then
    vim.ui.select({ { label = "allow", value = true }, { label = "refuse", value = false } }, {
      prompt = "spawn " .. tostring(item.name or item.template),
      format_item = function(entry)
        return entry.label
      end,
    }, function(choice)
      if choice ~= nil then
        answer({ allow = choice.value == true })
      end
    end)
  elseif item.kind == "permission" then
    local choices = {}
    for _, option in ipairs(item.options or {}) do
      choices[#choices + 1] = { label = option.name or option.optionId, value = option.optionId }
    end
    choices[#choices + 1] = { label = "Cancel", value = false }
    vim.ui.select(choices, {
      prompt = "permission",
      format_item = function(entry)
        return entry.label
      end,
    }, function(choice)
      if choice == nil then
        return
      end
      if choice.value == false then
        answer({})
      else
        answer({ option = choice.value })
      end
    end)
  elseif item.kind == "question" and type(item.options) == "table" and #item.options > 0 then
    vim.ui.select(item.options, {
      prompt = item.body or "question",
      format_item = tostring,
    }, function(choice)
      if choice ~= nil then
        answer({ text = choice })
      end
    end)
  elseif item.kind == "request" then
    vim.ui.input({ prompt = "JSON result: " }, function(text)
      if not text or text == "" then
        return
      end
      local ok, parsed = pcall(vim.json.decode, text)
      if not ok or type(parsed) ~= "table" then
        self:notify("the result must be a JSON object or array")
        return
      end
      answer({ text = vim.json.encode(parsed) })
    end)
  elseif item.kind == "question" then
    vim.ui.input({ prompt = item.body or "answer: " }, function(text)
      if text and text ~= "" then
        answer({ text = text })
      end
    end)
  else
    answer({})
  end
end

function Dashboard:remove_worktree(team, name)
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
  vim.ui.select({
    { label = "Remove worktree (an unmerged branch is kept)", value = false },
    { label = "Force remove worktree", value = true },
  }, {
    prompt = "remove " .. tostring(worktree.branch or worktree.path) .. "?",
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    self.team:remove_worktree(team, name, choice.value, function(ok, value)
      self:report(ok, value)
      self.team:refresh()
    end)
  end)
end

function Dashboard:spawn_current(team)
  if not team then
    return
  end
  if self:refuse_stale(team) or self:refuse_suspended(team) then
    return
  end
  local cfg = self.config() or {}
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
    vim.ui.input({ prompt = "task label (optional): " }, function(task)
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
    vim.ui.input({ prompt = "worker name (blank: next free wN): " }, function(name)
      if name == nil then
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
  vim.ui.select(names, { prompt = "template for the new worker", format_item = tostring }, function(template)
    if template == nil then
      return
    end
    ask_name(template)
  end)
end

function Dashboard:close_team(team)
  if not team or self:refuse_stale(team) then
    return
  end
  vim.ui.select({ { label = "Close the team", value = true }, { label = "Cancel", value = false } }, {
    prompt = "close " .. team .. "?",
    format_item = function(entry)
      return entry.label
    end,
  }, function(choice)
    if choice and choice.value then
      self.team:close(team, function(ok, value)
        self:report(ok, value)
        self.team:refresh()
      end)
    end
  end)
end

---Open a participant's watch (worker) or move the leader chat into the right
---column (wide) / focus it (narrow).
function Dashboard:open_watch(team, participant)
  if not team or self:refuse_stale(team) or self:refuse_suspended(team) then
    return
  end
  if participant == "leader" then
    self:open_leader(team)
    return
  end
  if self.leader_mounted then
    self:unmount_leader()
  end
  if self.tab and self.tab:is_open() then
    local host = self.tab:open_watch_host()
    self.watcher.host_win = host
    self.watcher.keep_focus = true
  else
    self.watcher.host_win = nil
    self.watcher.keep_focus = false
  end
  self.watcher:open(team, participant)
  self.watch_win, self.watch_buf = self.watcher.win, self.watcher.buf
end

function Dashboard:open_leader(team)
  if self.tab and self.tab:is_open() then
    if self.watcher:is_open() or self.watcher.participant then
      self.watcher:close()
    end
    pcall(self.mount_leader, self)
  else
    local chat = self.leader_chat and self.leader_chat() or nil
    if chat and chat.win and vim.api.nvim_win_is_valid(chat.win) then
      pcall(vim.api.nvim_set_current_win, chat.win)
    else
      self:notify("the leader chat window is not open")
    end
  end
end

---Move the existing chat/input into the right column of the wide tab.
---
---Uses the normal panel window path (`layout.create_chat_win` /
---`create_input_win`) so wrap, conceal, winfixbuf, width and keys match the
---regular panel. The original panel windows are closed first, never duplicated.
function Dashboard:mount_leader()
  if not (self.tab and self.tab:is_open()) then
    return
  end
  local chat = self.leader_chat and self.leader_chat() or nil
  local input = self.leader_input and self.leader_input() or nil
  if not (chat and chat.buf and input and input.buf) then
    self:notify("the leader chat is not available")
    return
  end
  if self.leader_mounted then
    return
  end
  local panel = self.panel and self.panel() or nil
  local was_visible = chat.win ~= nil and vim.api.nvim_win_is_valid(chat.win)
  local original_tab = nil
  if was_visible then
    original_tab = vim.api.nvim_win_get_tabpage(chat.win)
  end
  if panel then
    -- Closes the original chat/input windows without losing drafts.
    panel:hide()
    -- A previously hidden panel stays hidden after unmount.
    panel.requested = was_visible
  end
  -- `panel:hide()` may focus the tab that held the old windows.
  if self.tab and self.tab:is_open() then
    pcall(vim.api.nvim_set_current_tabpage, self.tab.tab)
  end
  local layout = require("ade.layout")
  local chat_win = layout.create_chat_win(chat.buf, nil)
  local input_win = chat_win and layout.create_input_win(input.buf, chat_win) or nil
  if not (chat_win and input_win) then
    self:notify("unable to move the leader chat to the watch column")
    if panel then
      panel:show()
    end
    return
  end
  chat.win = chat_win
  input.win = input_win
  self.leader_mounted = {
    chat_win = chat_win,
    input_win = input_win,
    original_tab = original_tab,
    panel = panel,
  }
  self.leader_unmounting = false
  local group = vim.api.nvim_create_augroup("AdeTeamLeaderMount" .. tostring(chat_win), { clear = true })
  self.leader_mounted.group = group
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local win = tonumber(args.match)
      local mounted = self.leader_mounted
      if not mounted or self.leader_unmounting then
        return
      end
      if win == mounted.chat_win or win == mounted.input_win then
        vim.schedule(function()
          self:unmount_leader()
        end)
      end
    end,
  })
  vim.api.nvim_set_current_win(input_win)
end

function Dashboard:unmount_leader()
  local mounted = self.leader_mounted
  if not mounted or self.leader_unmounting then
    return
  end
  self.leader_mounted = nil
  self.leader_unmounting = true
  if mounted.group then
    pcall(vim.api.nvim_del_augroup_by_id, mounted.group)
  end
  local chat = self.leader_chat and self.leader_chat() or nil
  local input = self.leader_input and self.leader_input() or nil
  if chat then
    chat.win = nil
  end
  if input then
    input.win = nil
  end
  for _, win in ipairs({ mounted.input_win, mounted.chat_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local panel = mounted.panel or (self.panel and self.panel() or nil)
  local show = panel ~= nil and panel.requested ~= false
  local target = mounted.original_tab
  if not (target and vim.api.nvim_tabpage_is_valid(target)) then
    target = vim.api.nvim_get_current_tabpage()
    if not (target and vim.api.nvim_tabpage_is_valid(target)) then
      vim.cmd("tabnew")
      target = vim.api.nvim_get_current_tabpage()
    end
  end
  pcall(vim.api.nvim_set_current_tabpage, target)
  if show and panel then
    panel:set_views(chat, input)
    if not panel:show() then
      self:notify("unable to restore the leader chat window")
    end
  end
  self.leader_unmounting = false
end

function Dashboard:open()
  self.interacting = false
  if not self.selected_id then
    local rows = self.team:list_rows()
    if #rows > 0 then
      self.selected_id = rows[1].id
    end
  end
  self.cwd = self.team.resolve_cwd and self.team.resolve_cwd() or nil
  local cfg = self.config() or {}
  local wide = tonumber((cfg.teams or {}).dashboard and (cfg.teams or {}).dashboard.wide) or 160
  local use_tab = vim.o.columns >= wide and (cfg.layout or {}).backend ~= "external"
  if self:is_open() then
    if use_tab ~= (self.tab ~= nil) then
      self:close(true)
    else
      if self.tab and self.tab:is_open() then
        pcall(vim.api.nvim_set_current_tabpage, self.tab.tab)
      end
      self:refresh()
      return true
    end
  end
  if #self.team:list_rows() == 0 then
    self:load_workflows()
  end
  if use_tab then
    self:install_tabline()
    self.tab = Tab.new(self)
    self.float = nil
    self.tab:open()
  else
    self.float = Float.new({
      team = self.team,
      config = self.config,
      leader_chat = self.leader_chat,
      start_team = self.start_team,
    })
    self.float.watcher = self.watcher
    self.tab = nil
    self.float:open()
  end
  self:sync_aliases()
  self:update_detail()
  return true
end

function Dashboard:sync_aliases()
  if self.float and self.float:is_open() then
    self.win, self.buf, self.ids = self.float.win, self.float.buf, self.float.ids
  elseif self.tab and self.tab:is_open() then
    self.win, self.buf = self.tab.panels.members, self.tab.buffers.members
    self.ids = self.tab.ids
  else
    self.win, self.buf, self.ids = nil, nil, nil
  end
  self.watch_win = self.watcher.win
  self.watch_buf = self.watcher.buf
end

function Dashboard:refresh()
  if not self:is_open() then
    return
  end
  if self.float then
    self.float:refresh()
    self.watch_win, self.watch_buf = self.watcher.win, self.watcher.buf
  elseif self.tab then
    self.tab:refresh()
    self:update_detail()
  end
  self:sync_aliases()
end

---Merge frequent `team.changed`/`inbox`/`board_changed` redraws.
function Dashboard:schedule_refresh()
  -- Paint the first change immediately (tests and cursor actions need the new
  -- rows right away); further changes inside the window coalesce into one
  -- trailing paint.
  if self.refresh_timer then
    self.pending = true
    return
  end
  local function paint()
    self.pending = false
    self:refresh()
  end
  -- `team.changed` can arrive from the socket's fast event context, where
  -- buffer APIs are illegal; never lose the paint (and its trailing timer).
  if vim.in_fast_event() then
    vim.schedule(paint)
  else
    paint()
  end
  self.refresh_timer = vim.defer_fn(function()
    self.refresh_timer = nil
    if self.pending then
      paint()
    end
  end, REFRESH_MS)
end

function Dashboard:watch(session, title)
  self.watcher:on_watch(session, title)
  self.watch_win, self.watch_buf = self.watcher.win, self.watcher.buf
end

function Dashboard:load_workflows()
  if self.workflows_requested then
    return
  end
  self.workflows_requested = true
  local cwd = self.cwd or (self.team.resolve_cwd and self.team.resolve_cwd())
  if not cwd then
    self.workflows_requested = false
    self.team.workflows_list = {}
    return
  end
  local token = {}
  self.workflow_token = token
  vim.defer_fn(function()
    if self.workflow_token == token and self.workflows_requested then
      self.workflows_requested = false
      self.workflow_token = nil
      self.team.workflows_list = {}
      self:notify("cannot load workflows (timed out)")
      self:schedule_refresh()
    end
  end, 5000)
  self.team:workflows(cwd, function(ok, value)
    if self.workflow_token ~= token and self.workflow_token ~= nil then
      return
    end
    self.workflow_token = nil
    if ok and type(value) == "table" then
      self.team.workflows_list = value.workflows or {}
    else
      self.team.workflows_list = {}
      self:notify("cannot load workflows")
    end
    self.workflows_requested = false
    self:schedule_refresh()
  end)
end

function Dashboard:close(quiet)
  if self.refresh_timer then
    pcall(function()
      self.refresh_timer:stop()
      self.refresh_timer:close()
    end)
    self.refresh_timer = nil
  end
  if self.unmount_leader then
    self:unmount_leader()
  end
  self.watcher:close()
  if not quiet then
    self.watcher.host_win = nil
  end
  if self.tab then
    self.tab:close()
  end
  if self.float then
    local panel = self.float
    self.float = nil
    panel:close()
  end
  self.tab, self.float, self.layout = nil, nil, nil
  self.win, self.buf, self.ids = nil, nil, nil
  self.watch_win, self.watch_buf = nil, nil
  self:restore_tabline()
end

M.Dashboard = Dashboard

---Public facade. Narrow mode delegates to the mature float panel; wide mode to
---the tabpage dashboard. Keeping the facade stable preserves the existing
---callers (`:Ade team`, on_changed/on_watch) across a width change.
---@param opts table
---@return table
function M.new(opts)
  local proxy = { _opts = opts, _impl = nil, _mode = nil, team = opts.team, config = opts.config }
  local watcher
  watcher = Watch.new({
    team = opts.team,
    config = opts.config,
    leader_chat = opts.leader_chat,
    notify = function(message)
      if opts.notify then
        opts.notify(message)
      else
        vim.notify("ade.nvim: " .. tostring(message), vim.log.levels.WARN)
      end
    end,
    on_change = function(watch)
      rawset(proxy, "watch_win", watch.win)
      rawset(proxy, "watch_buf", watch.buf)
      if proxy._impl then
        proxy._impl.watch_win, proxy._impl.watch_buf = watch.win, watch.buf
      end
    end,
  })
  proxy.watcher = watcher
  local mt = {}
  function mt.__index(_, key)
    local impl = rawget(proxy, "_impl")
    if not impl then
      return nil
    end
    local value = impl[key]
    if type(value) == "function" then
      return function(_, ...)
        return value(impl, ...)
      end
    end
    return value
  end
  function mt.__newindex(_, key, value)
    local impl = rawget(proxy, "_impl")
    if impl then
      impl[key] = value
    else
      rawset(proxy, key, value)
    end
  end
  setmetatable(proxy, mt)

  local function wide_wanted()
    local cfg = opts.config() or {}
    local wide = tonumber((cfg.teams or {}).dashboard and (cfg.teams or {}).dashboard.wide) or 160
    return vim.o.columns >= wide and (cfg.layout or {}).backend ~= "external"
  end

  function proxy:open()
    local mode = wide_wanted() and "tab" or "float"
    if self._mode ~= mode then
      if self._impl then
        pcall(self._impl.close, self._impl, true)
      end
      if mode == "tab" then
        self._impl = M.dashboard(opts)
        self._impl.watcher = watcher
      else
        self._impl = Float.new({
          team = opts.team,
          config = opts.config,
          leader_chat = opts.leader_chat,
          start_team = opts.start_team,
        })
        self._impl.watcher = watcher
      end
      self._mode = mode
    end
    return self._impl:open()
  end
  function proxy:close(quiet)
    -- The watch view can exist before the dashboard does (`ui:watch` is called
    -- by `on_watch` even when the panel was never opened).
    watcher:close()
    if self._impl then
      return self._impl:close(quiet)
    end
  end
  function proxy:is_open()
    return self._impl ~= nil and self._impl:is_open()
  end
  function proxy:refresh()
    if self._impl then
      self._impl:refresh()
    end
  end
  function proxy:schedule_refresh()
    if not self._impl then
      return
    end
    if self._mode == "float" then
      -- The float panel is cheap and its existing tests rely on the rows being
      -- current right after a notification.
      self._impl:refresh()
    else
      self._impl:schedule_refresh()
    end
  end
  function proxy:watch(session, title)
    watcher:on_watch(session, title)
    rawset(self, "watch_win", watcher.win)
    rawset(self, "watch_buf", watcher.buf)
  end
  return proxy
end

return M
