-- The team panes (`:Ade team`, `:Ade team agents`, `:Ade team board`).
--
-- Members and board are two independent panes inside the *current* tabpage:
-- each command opens or focuses only its own pane, and closing one leaves the
-- other, the ordinary chat panel and the running team untouched. Wide
-- terminals get native splits; narrow ones get a float for the pane that was
-- actually asked for.
--
-- Selecting the leader or a worker does not open a dedicated worker window:
-- the router reuses the single ordinary `ade_chat`/`ade_input` pair.
local Pane = require("ade.ui.team.layout_pane")
local Router = require("ade.ui.team.router")
local Members = require("ade.ui.team.members")
local Board = require("ade.ui.team.board")
local Roles = require("ade.ui.team.roles")
local Detail = require("ade.ui.team.detail")
local History = require("ade.ui.team.history")
local Text = require("ade.ui.team.text")

local M = {}

local Dashboard = {}
Dashboard.__index = Dashboard

local REFRESH_MS = 50

local function one_line(text)
  return (tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param opts {team: table, config: fun(): table, notify: fun(message: string, level: integer|nil)|nil,
---  panel: (fun(): table|nil)|nil, leader_chat: (fun(): table|nil)|nil,
---  leader_input: (fun(): table|nil)|nil, current_session: (fun(): table|nil)|nil,
---  find_session: (fun(id: string): table|nil)|nil, instance: (fun(): string|nil)|nil,
---  start_team: (fun(workflow: string)|nil)|nil, select_session: (fun(session: table)|nil)|nil}
---@return table
function M.dashboard(opts)
  local self = setmetatable({
    team = opts.team,
    config = opts.config,
    notify_fn = opts.notify,
    leader_chat = opts.leader_chat,
    leader_input = opts.leader_input,
    current_session = opts.current_session,
    find_session = opts.find_session,
    select_session = opts.select_session,
    instance_of = opts.instance,
    panel = opts.panel,
    start_team = opts.start_team,
    layout = nil,
    index = 1,
    selected_id = nil,
    help = false,
    cwd = nil,
    refresh_timer = nil,
    pending = false,
    requested = {},
  }, Dashboard)
  self.layout = Pane.new(self)
  self.router = Router.new({
    team = opts.team,
    config = opts.config,
    notify = function(message, level)
      self:notify(message, level)
    end,
    panel = opts.panel,
    leader_chat = opts.leader_chat,
    leader_input = opts.leader_input,
    current_session = opts.current_session,
    find_session = opts.find_session,
    select_session = opts.select_session,
    instance = opts.instance,
    on_change = function()
      self:update_headers()
      self:sync_aliases()
      self:refresh()
    end,
  })
  -- The old name still appears in `:Ade debug` mirrors and third-party hooks.
  self.watcher = self.router
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

---@param kind string|nil "members", "board", "all" or nil (members)
---@return boolean
function Dashboard:is_open(kind)
  if kind == "all" then
    return self.layout:is_open()
  end
  if kind then
    return self.layout:is_open_pane(kind)
  end
  return self.layout:is_open()
end

function Dashboard:has_content()
  return #self.team:list_rows() > 0
end

---Rows to paint.
---
---`team.list` can transiently come back empty (a lost connection, a racing
---refresh). Keep the last known rows on screen, marked stale, until a later
---refresh returns real data or the team is explicitly closed — otherwise the
---panel would blink through a misleading "no team" state.
---@return table[]
function Dashboard:paint_rows()
  local rows = self.team:list_rows()
  if #rows > 0 then
    self.snapshot = rows
    return rows
  end
  if self.snapshot then
    for _, row in ipairs(self.snapshot) do
      row.stale = true
    end
    return self.snapshot
  end
  return rows
end

function Dashboard:current_team()
  local rows = self:paint_rows()
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

---The project these panes belong to.
---@return string|nil
function Dashboard:project_cwd()
  local ok, cwd = pcall(function()
    return self.team.resolve_cwd and self.team.resolve_cwd() or nil
  end)
  if ok and type(cwd) == "string" and cwd ~= "" then
    return cwd
  end
  return self.resolved_cwd
end

---The team whose board the board pane shows.
---
---`:Ade team board` means *this project's* board: the team of the resolved
---cwd, never whichever team happens to be first in the service list. When the
---cwd has no team the pane shows its empty state instead of another project's
---cards.
---@return table|nil
function Dashboard:board_team()
  local rows = self:paint_rows()
  if #rows == 0 then
    return nil
  end
  local cwd = self:project_cwd()
  if cwd then
    -- Resolve by cwd every time: the board pane follows the project, so a cwd
    -- change must not keep a previously cached team from another project.
    for _, row in ipairs(rows) do
      if row.cwd == cwd and row.state ~= "closed" then
        self.board_selected_id = row.id
        return row
      end
    end
    -- No team for this project: do not borrow another cwd's cards.
    self.board_selected_id = nil
    return nil
  end
  if self.board_selected_id then
    for _, row in ipairs(rows) do
      if row.id == self.board_selected_id then
        return row
      end
    end
    self.board_selected_id = nil
  end
  local row = self:current_team()
  self.board_selected_id = row and row.id or nil
  return row
end

---The team a pane's keys act on.
---@param pane string|nil
---@return table|nil
function Dashboard:pane_team(pane)
  if pane == "board" then
    return self:board_team()
  end
  return self:current_team()
end

---@param id string
---@return table|nil
function Dashboard:visible_team(id)
  for _, row in ipairs(self:paint_rows()) do
    if row.id == id then
      return row
    end
  end
end

---@param team table|nil
---@return table|nil
function Dashboard:board(team)
  local row = team
  if type(team) == "string" then
    row = self:visible_team(team)
  end
  return row and self.team:board(row.id) or nil
end

function Dashboard:team_by_id(id)
  for _, team in ipairs(self.team:list_rows()) do
    if team.id == id then
      return team
    end
  end
end

---The inline choice queue, built by bootstrap.
---@return table|nil
function Dashboard:choices()
  local ok, controller = pcall(require, "ade.controller")
  if not ok then
    return nil
  end
  local state = controller.state()
  return state and state.view and state.view.choices or nil
end

function Dashboard:states(team)
  local out = {}
  local palette = Roles.palette(team and team.participants)
  for _, participant in ipairs(team and team.participants or {}) do
    out[participant.name] = {
      icon = Members.state_icon(participant),
      symbol = Roles.symbol(participant),
      state = participant.state,
      state_text = Members.state_label(participant),
      role_hl = Roles.hl(participant, palette),
      label = Roles.label(participant),
      agent = participant.agent,
      model = participant.model,
      template = participant.template,
    }
  end
  return out
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

---@param name string
---@return string[] lines, table<integer, string> ids, table<integer, table> meta, table[] marks
function Dashboard:render_pane(name)
  if name == "board" then
    return self:render_board()
  end
  return self:render_members()
end

function Dashboard:render_members()
  local lines, ids, meta, marks = {}, {}, {}, {}
  local team = self:current_team()
  local width = 40
  local win = self.layout:win("members")
  if win then
    width = math.max(8, vim.api.nvim_win_get_width(win) - 1)
  end
  if not team then
    lines[#lines + 1] = " 还没有团队"
    lines[#lines + 1] = ""
    local workflows = self.team.workflows_list
    if workflows == nil then
      lines[#lines + 1] = " 正在读取可用流程…"
      self:load_workflows()
      workflows = {}
    end
    if #workflows == 0 then
      lines[#lines + 1] = " 没有可用流程；在普通对话里让 leader 组队即可"
      return lines, ids, meta, marks
    end
    lines[#lines + 1] = " 可用流程（S 启动，<CR> 看全文）"
    for _, workflow in ipairs(workflows) do
      lines[#lines + 1] = string.format("   %-20s %s", tostring(workflow.name), one_line(workflow.summary or ""))
      meta[#lines] = { kind = "workflow", workflow = workflow }
      ids[#lines] = "workflow:" .. tostring(workflow.name)
    end
    return lines, ids, meta, marks
  end
  local messages = {}
  for _, item in pairs(self.team.inbox) do
    if item.team == team.id and item.state == "open" and item.kind == "message" then
      messages[item.from] = (messages[item.from] or 0) + 1
    end
  end
  local cfg = self.config() or {}
  local workers_max = tonumber((type(cfg.teams) == "table" and cfg.teams.max_workers) or 3) or 3
  -- A team row first so the team-level keys (`s`, `x`, `R`) have a target and
  -- a suspended or stale team explains itself before any member does.
  lines[#lines + 1] = string.format(" %s  %s  [%s]", tostring(team.id), tostring(team.cwd), tostring(team.state))
  ids[#lines] = "team:" .. tostring(team.id)
  meta[#lines] = { kind = "team", team = team.id }
  if team.stale or self.team:is_stale(team.id) then
    lines[#lines + 1] = "   connection lost; waiting for the service to reconnect"
    meta[#lines] = { kind = "team_hint", team = team.id }
  end
  if team.state == "suspended" then
    local at = tonumber(team.suspended_at)
    local when = at and os.date("%Y-%m-%d %H:%M:%S", math.floor(at / 1000)) or "unknown"
    lines[#lines + 1] = "   suspended since "
      .. when
      .. "; waiting for the leader session to resume or press x to close"
    meta[#lines] = { kind = "team_hint", team = team.id }
  end
  local member_lines, member_ids, member_meta, member_marks =
    Members.lines(team, width, { messages = messages, max_workers = workers_max })
  local offset = #lines
  for index, text in ipairs(member_lines) do
    lines[offset + index] = text
    ids[offset + index] = member_ids[index]
    meta[offset + index] = member_meta[index]
  end
  for _, mark in ipairs(member_marks or {}) do
    marks[#marks + 1] = {
      line = offset + mark.line,
      start = mark.start,
      stop = mark.stop,
      group = mark.group,
    }
  end
  return lines, ids, meta, marks
end

function Dashboard:render_board()
  local lines, ids, meta, marks = {}, {}, {}, {}
  local team = self:board_team()
  if not team then
    lines[#lines + 1] = " 暂无团队任务"
    lines[#lines + 1] = ""
    if #self:paint_rows() > 0 then
      lines[#lines + 1] = " 当前项目没有团队；团队面板（:Ade team agents）可看别的项目。"
    else
      lines[#lines + 1] = " leader 组队后，这里的看板会显示任务。"
    end
    return lines, ids, meta, marks
  end
  local width = 60
  local win = self.layout:win("board")
  if win then
    width = math.max(24, vim.api.nvim_win_get_width(win))
  end
  local board = self:board(team)
  local board_lines, board_meta, board_ids, board_marks = Board.lines(board, self:states(team), {
    scroll = self:scroll(team.id),
    expanded = self:expanded(team.id),
    width = width,
    team = team,
  })
  return board_lines, board_ids, board_meta, board_marks or {}
end

---The one-line summary for a pane's winbar.
---@param pane string|nil
---@return string
function Dashboard:summary(pane)
  local team = self:pane_team(pane)
  if not team then
    return ""
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
  local state = (team.stale or self.team:is_stale(team.id)) and "stale" or tostring(team.state)
  local flow = team.workflow_name and tostring(team.workflow_name) or "default"
  local progress = Board.stage_progress(team.stages) or ""
  local queue = self:choices()
  local counts = queue and queue:pending_counts(team.id) or {}
  local q = tonumber(counts.question) or 0
  local a = tonumber(counts.approval) or 0
  return string.format(
    " %s · %s · workers %d/%d · turns %s/%s · 流程 %s%s · ? %d ⚑ %d ",
    tostring(team.id),
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

function Dashboard:update_headers()
  if not self.layout:is_open() then
    return
  end
  for _, name in ipairs(Pane.PANES) do
    local win = self.layout:win(name)
    if win then
      local title = Pane.TITLES[name] or ""
      local text = title .. "│" .. self:summary(name)
      local width = vim.api.nvim_win_get_width(win)
      pcall(vim.api.nvim_set_option_value, "winbar", Text.truncate(text, math.max(1, width)), { win = win })
    end
  end
end

---Open or focus one pane. `nil` means the members pane (compat entry).
---@param kind string|nil "members", "board" or "all"
---@return boolean
function Dashboard:open(kind)
  kind = kind or "members"
  self.resolved_cwd = self.team.resolve_cwd and self.team.resolve_cwd() or nil
  if not self.selected_id then
    local rows = self.team:list_rows()
    if #rows > 0 then
      self.selected_id = rows[1].id
    end
  end
  if #self.team:list_rows() == 0 then
    self:load_workflows()
  end
  if kind == "all" then
    for _, name in ipairs(Pane.PANES) do
      if not self.layout:show(name) then
        return false
      end
    end
    self:refresh()
    return true
  end
  if not (kind == "members" or kind == "board") then
    return false
  end
  local ok = self.layout:show(kind)
  if ok then
    self:refresh()
  end
  return ok
end

---Close one pane; the other pane and the ordinary panel stay as they are.
---@param kind string|nil
---@return boolean
function Dashboard:close(kind)
  if kind == "all" or kind == nil then
    if self.refresh_timer then
      pcall(function()
        self.refresh_timer:stop()
        self.refresh_timer:close()
      end)
      self.refresh_timer = nil
    end
    self.pending = false
    if self.router and self.router:is_worker() then
      self.router:restore_leader(false)
    end
    self.layout:close()
    return true
  end
  if self.layout:is_open_pane(kind) then
    self.layout:close_pane(kind)
    return true
  end
  return false
end

---Aliases the rest of the app (and tests) use for the primary pane.
function Dashboard:sync_aliases()
  local name
  for _, candidate in ipairs({ "members", "board" }) do
    if self.layout:is_open_pane(candidate) then
      name = candidate
      break
    end
  end
  self.win = name and self.layout:win(name) or nil
  self.buf = name and self.layout:buf(name) or nil
  self.ids = name and self.layout.ids[name] or nil
  -- The worker transcript lives in the ordinary chat now; the old names point
  -- at the shared pair so callers keep observing the same thing.
  local chat = self.router.chat
  local worker = self.router:is_worker()
  self.watch_win = worker and chat and chat.win or nil
  self.watch_buf = worker and chat and chat.buf or nil
end

function Dashboard:refresh()
  if not self.layout:is_open() then
    return
  end
  self.layout:refresh()
  self:update_headers()
  self:sync_aliases()
end

---Merge frequent `team.changed`/`inbox`/`board_changed` redraws.
function Dashboard:schedule_refresh()
  if self.refresh_timer then
    self.pending = true
    return
  end
  local function paint()
    self.pending = false
    self:refresh()
  end
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

---The router's chat target, for the transcript winbar.
---@return table|nil
function Dashboard:chat_target()
  return self.router:chat_target()
end

---Whether the composer currently submits to a worker.
---@return boolean
function Dashboard:is_worker_target()
  return self.router:is_worker()
end

---Interrupt a worker from the composer: `<C-c>` must never cancel the
---leader's own turn while the composer sends to someone else.
---An empty submit / `<C-c>` while a worker is the target.
---
---The worker has no local turn to stop and cancelling the leader's turn would
---be wrong, so this only explains the state. Cancelling a worker's own turn
---stays an explicit `c` in the members pane.
function Dashboard:cancel_target()
  self:notify(
    "当前输入发往 worker "
      .. tostring(self.router:current_participant() or "?")
      .. "：按成员面板里的 c 取消它的回合，gl 返回普通会话",
    vim.log.levels.INFO
  )
end

---The composer bar text while a worker is the target.
---@param win integer|nil
---@return string
function Dashboard:worker_bar(win)
  if not self.router:is_worker() then
    return ""
  end
  return self.router:input_winbar(win)
end

---Send from the ordinary composer to the selected worker, when one is shown.
---@param text string
---@param attachments table[]|nil
---@return boolean handled
function Dashboard:route_submit(text, attachments)
  return self.router:route_submit(text, attachments)
end

---Switch the shared chat to a participant, or back to the leader.
---@param team string|nil
---@param participant string|nil
---@return boolean
function Dashboard:select(team, participant)
  return self.router:select(team, participant)
end

---Selecting the leader needs the *team's* project: falling back to whatever
---session happens to be current could present another project or agent.
---@param team string|nil
---@return boolean
function Dashboard:select_leader(team)
  return self.router:restore_leader(true, team)
end

---`gl` in a worker transcript: leave the worker for the ordinary session the
---panel showed before. This makes no claim to be the team's leader.
---@param focus boolean|nil
---@return boolean
function Dashboard:leave_worker(focus)
  return self.router:leave_worker(focus)
end

---The session picker or `:Ade open` took over: stop routing.
function Dashboard:detach()
  self.router:detach()
end

---A watch frame from the team subscription.
---@param session table|nil
---@param title string|nil
function Dashboard:watch(session, title)
  self.router:on_watch(session, title)
  self:sync_aliases()
end

function Dashboard:load_workflows()
  if self.workflows_requested then
    return
  end
  self.workflows_requested = true
  local cwd = self:project_cwd()
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

---A team disappeared: closed here, by another front end, or by the service.
---@param team_id string
function Dashboard:team_closed(team_id)
  if type(team_id) ~= "string" then
    return
  end
  local router = self.router
  if router:current() and router:current().team == team_id then
    router:restore_leader(false)
  end
  -- Drop the closed team from the kept rows so it cannot come back as stale.
  if self.snapshot then
    local kept = {}
    for _, row in ipairs(self.snapshot) do
      if row.id ~= team_id then
        kept[#kept + 1] = row
      end
    end
    self.snapshot = #kept > 0 and kept or nil
  end
  if not self.layout:is_open() then
    return
  end
  local rows = self:paint_rows()
  if #rows == 0 then
    self:refresh()
    return
  end
  if self.selected_id and self.selected_id ~= team_id and self:team_by_id(self.selected_id) then
    return
  end
  self.index = math.max(1, math.min(self.index or 1, #rows))
  self.selected_id = rows[self.index].id
  if self.board_selected_id == team_id then
    self.board_selected_id = nil
  end
  self:refresh()
end

---The cursor's target in whichever pane is focused.
---@return string|nil kind, string|nil team, string|nil obj, table|nil info
function Dashboard:current()
  return self.layout:current()
end

function Dashboard:home_team()
  local kind, team = self.layout:current()
  if team then
    return team
  end
  local row = self:current_team()
  return row and row.id or nil
end

---@param buf integer
---@param pane string|nil
function Dashboard:attach_keys(buf, pane)
  local function map(lhs, key)
    vim.keymap.set("n", lhs, function()
      self:handle_key(key)
    end, { buffer = buf, nowait = true, silent = true })
  end
  self.key_pane = pane
  for lhs, key in pairs({
    ["<CR>"] = "cr",
    ["m"] = "m",
    ["a"] = "a",
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
---@return boolean
function Dashboard:refuse_stale(team)
  if not team then
    return false
  end
  -- The team module drops its list on a lost connection while the pane keeps
  -- the last rows on screen. Either signal means "don't act on this".
  local row = self:visible_team(team)
  if (row and row.stale) or self.team:is_stale(team) then
    self:notify("the connection to the service is lost; wait for it to reconnect")
    return true
  end
  return false
end

---@param team string|nil
---@return boolean
function Dashboard:refuse_suspended(team)
  if not team then
    return false
  end
  local row = self:visible_team(team)
  if (row and row.state == "suspended") or self.team:is_suspended(team) then
    self:notify("the team is suspended; wait for the leader session to resume or press x to close it")
    return true
  end
  return false
end

function Dashboard:handle_key(key)
  local kind, team_id, obj, info = self.layout:current()
  local pane = self.layout:name_of()
  local team = team_id or (self:pane_team(pane) and self:pane_team(pane).id) or self:home_team()
  if key == "next" then
    self.layout:cycle(1)
    return
  end
  if key == "prev" then
    self.layout:cycle(-1)
    return
  end
  if key == "]t" or key == "[t" then
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
    local pane = self.layout:name_of()
    self:close(pane or "all")
    return
  end
  if key == "help" then
    self:notify(
      "team: <CR> card/member · a/! pending choice · m message · H history · s spawn · L leader · x close"
    )
    return
  end
  if key == "zh" or key == "zl" then
    if team then
      self.scrolls = self.scrolls or {}
      local board = self:board(self:team_by_id(team)) or {}
      local columns = #(board.columns or {})
      local width = 80
      local win = self.layout:win("board")
      if win then
        width = vim.api.nvim_win_get_width(win)
      end
      local visible = Board.visible_columns(width, columns, false)
      local max_columns = math.max(0, columns - visible)
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
    elseif kind == "archived_stage" then
      local expanded = self:expanded(team)
      expanded[obj or ""] = not expanded[obj or ""]
      self:refresh()
    elseif kind == "workflow" and info then
      self:show_detail(Detail.workflow(info.workflow), "流程 " .. tostring(info.workflow.name))
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
  if key == "a" or key == "choices" then
    local queue = self:choices()
    if not queue then
      self:notify("选择组件尚未就绪", vim.log.levels.WARN)
      return
    end
    if key == "a" and kind == "participant" and obj and team then
      queue:answer_participant(team, obj)
    else
      queue:show_pending(team)
      if team then
        local ok, pending = pcall(queue.selectable_count, queue, team)
        if not ok then
          local counts = queue:pending_counts(team) or {}
          pending = (counts.question or 0) + (counts.approval or 0)
        end
        if pending > 0 and not queue:is_open() then
          self:notify("打开聊天面板（:Ade open）后可按 ! 显示选择组件")
        end
      end
    end
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
    self:select_leader()
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
  self.layout:update_cursor()
  self:popup(title or "详情", lines)
end

function Dashboard:popup(title, lines)
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
  -- Worker 1's zero-config default: ask the team module for the template names
  -- first so no templates configured still offers the builtin worker.
  local names = {}
  if type(self.team.template_names) == "function" then
    local ok, list = pcall(self.team.template_names, self.team)
    if ok and type(list) == "table" then
      names = vim.deepcopy(list)
    end
  end
  if #names == 0 then
    for name in pairs(teams_cfg.templates or {}) do
      names[#names + 1] = name
    end
    table.sort(names)
  end
  if #names == 0 then
    -- Not a configuration complaint: `template_names` already accounts for the
    -- builtin default. An explicit failure reason is worth showing; nothing
    -- else is.
    local reason
    if type(self.team.template_error) == "function" then
      local cwd = self:project_cwd()
      local ok, value = pcall(self.team.template_error, self.team, cwd)
      reason = ok and value or nil
    end
    self:notify(reason and ("无法启动 worker：" .. tostring(reason)) or "当前没有可启动的团队模板")
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

---Open a participant in the ordinary chat panel. The leader returns to its own
---session; a worker replays into the shared transcript.
function Dashboard:open_watch(team, participant)
  if not team or self:refuse_stale(team) or self:refuse_suspended(team) then
    return
  end
  if participant == "leader" then
    self:select_leader(team)
    return
  end
  self.router:select(team, participant)
end

M.Dashboard = Dashboard

---Compatibility facade kept for callers that only know `TeamUI.new`.
---@param opts table
---@return table
function M.new(opts)
  return M.dashboard(opts)
end

M.Refresh = REFRESH_MS

return M
