-- The team view router: one ordinary chat panel, many targets.
--
-- Selecting the leader or a worker never creates a second Chat or a second
-- composer. This module swaps which session the existing `ade_chat` shows and
-- what the existing `ade_input` submits, while the team subscription keeps its
-- replay and live updates. Worker messages keep the bus semantics of the old
-- watch composer: queued `notice`, cc to the leader, and a two-step explicit
-- interrupt.
--
-- Two invariants hold throughout:
--
--  * Every asynchronous callback belongs to a *request generation*. A late
--    frame or a late send callback from a superseded request must not touch
--    the newer request's state, the transcript, or the composer.
--  * The shared chat/input objects are borrowed, never reconfigured. The
--    worker view gets its own config and mapping layer and restores both on
--    release, so ordinary sessions cannot inherit paging or keys.
local Watch = require("ade.ui.team.watch")
local drafts = require("ade.storage.drafts")

local M = {}

local Router = {}
Router.__index = Router

local INTERRUPT_MS = 5000

---@param opts {team: table, config: fun(): table, notify: fun(message: string, level: integer|nil),
---  panel: (fun(): table|nil)|nil, leader_chat: (fun(): table|nil)|nil,
---  leader_input: (fun(): table|nil)|nil, current_session: (fun(): table|nil)|nil,
---  find_session: (fun(id: string): table|nil)|nil,
---  select_session: (fun(session: table)|nil)|nil,
---  instance: (fun(): string|nil)|nil,
---  on_change: (fun()|nil)}
---@return table
function M.new(opts)
  return setmetatable({
    team = opts.team,
    config = opts.config,
    notify_fn = opts.notify,
    panel = opts.panel,
    leader_chat = opts.leader_chat,
    leader_input = opts.leader_input,
    current_session = opts.current_session,
    find_session = opts.find_session,
    select_session = opts.select_session,
    instance_of = opts.instance,
    on_change = opts.on_change,
    target = nil,
    display = nil,
    source = nil,
    title = nil,
    request_id = 0,
    pending_target = nil,
    active_target = nil,
    inflight_request = nil,
    watch_inflight = false,
    interrupt_armed = false,
    interrupt_timer = nil,
    interrupt_win = nil,
    mappings = {},
    bindings = {},
    collapsed = {},
    expanded = {},
    turn_times = {},
    saved_chat_config = nil,
    saved_leader = nil,
    view_config = nil,
    chat = nil,
    input = nil,
  }, Router)
end

function Router:notify(message, level)
  if self.notify_fn then
    self.notify_fn(tostring(message), level)
  else
    vim.notify("ade.nvim: " .. tostring(message), level or vim.log.levels.WARN)
  end
end

function Router:changed()
  if self.on_change then
    pcall(self.on_change)
  end
end

---@return boolean
function Router:is_worker()
  return self.target ~= nil
end

---@return {team: string, participant: string}|nil
function Router:current()
  return self.target
end

---@return string|nil
function Router:current_team()
  return self.target and self.target.team or nil
end

---@return string|nil
function Router:current_participant()
  return self.target and self.target.participant or nil
end

---@return boolean
function Router:is_open()
  return self.target ~= nil
end

---The participant record of the current target (or an explicit one).
---@param team string|nil
---@param participant string|nil
---@return table|nil entry
function Router:entry(team, participant)
  team = team or (self.target and self.target.team)
  participant = participant or (self.target and self.target.participant)
  if not (team and participant) then
    return nil
  end
  return self.team:participant(team, participant)
end

---@param team string|nil
---@return table|nil row
function Router:row(team)
  return self.team:team(team or (self.target and self.target.team))
end

---What the transcript winbar should say while a worker is shown.
---@return {agent: string, title: string}|nil
function Router:chat_target()
  if not self.target then
    return nil
  end
  local entry = self:entry() or {}
  local state = require("ade.ui.team.members").state_label(entry)
  local task = entry.task and entry.task ~= "_" and tostring(entry.task) or nil
  local parts = { "worker", state }
  if task then
    parts[#parts + 1] = task
  end
  return {
    agent = tostring(self.target.participant),
    title = table.concat(parts, " · "),
  }
end

---@param win integer|nil
---@return string
function Router:input_winbar(win)
  local cfg = self.config() or {}
  local keys = require("ade.ui.keymaps")
  local send_cfg = (cfg.keymaps or {}).input or {}
  local send = (keys.expand(send_cfg.send or "<C-s>", { "n" })[1] or {}).lhs or "<C-s>"
  local interrupt = ((cfg.teams or {}).dashboard or {}).keys
  interrupt = interrupt and interrupt.interrupt or "<M-CR>"
  local entry = self:entry() or {}
  local parts = {
    require("ade.ui.icons").glyph("team_send"),
    tostring(self.target and self.target.participant or "?"),
  }
  local state = require("ade.ui.team.members").state_label(entry)
  if state and state ~= "" then
    parts[#parts + 1] = state
  end
  parts[#parts + 1] = send .. " 发送(排队)+抄送 leader"
  parts[#parts + 1] = interrupt .. " 打断"
  parts[#parts + 1] = "gl 返回 leader"
  local text = " " .. table.concat(parts, " · ") .. " "
  local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 0
  if width > 0 then
    text = require("ade.ui.toolbar").truncate(text, width)
  end
  return text
end

---Find the buffer-local mapping `lhs` currently has, as maparg-style fields.
---@param buf integer
---@param mode string
---@param lhs string
---@return table|nil
local function buffer_map(buf, mode, lhs)
  local wanted = vim.keycode(lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    local ok, code = pcall(vim.keycode, map.lhs)
    if ok and code == wanted then
      return map
    end
  end
  return nil
end

---Bind a buffer-local key, remembering whatever it replaced.
---
---`unbind` restores that mapping, so the ordinary transcript/composer keep the
---keys other modules installed instead of losing them.
---@param buf integer|nil
---@param mode string
---@param lhs string
---@param fn function
function Router:bind_key(buf, mode, lhs, fn)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  if self.bindings[buf] and self.bindings[buf][mode] and self.bindings[buf][mode][lhs] then
    return
  end
  local previous = buffer_map(buf, mode, lhs)
  vim.keymap.set(mode, lhs, fn, { buffer = buf, silent = true, nowait = true })
  self.bindings[buf] = self.bindings[buf] or {}
  self.bindings[buf][mode] = self.bindings[buf][mode] or {}
  self.bindings[buf][mode][lhs] = { previous = previous }
end

---Restore every mapping this router replaced.
function Router:unbind()
  for buf, modes in pairs(self.bindings or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      for mode, keys in pairs(modes) do
        for lhs, saved in pairs(keys) do
          pcall(vim.keymap.del, mode, lhs, { buffer = buf })
          local previous = saved.previous
          if type(previous) == "table" and previous.lhs and previous.lhs ~= "" then
            if type(previous.callback) == "function" then
              -- A Lua callback mapping: `set_keymap` cannot restore it, so put
              -- the same callback back through the API.
              pcall(vim.keymap.set, mode, previous.lhs, previous.callback, {
                buffer = buf,
                silent = previous.silent == 1,
                expr = previous.expr == 1,
                nowait = previous.nowait == 1,
                desc = previous.desc ~= nil and previous.desc ~= "" and previous.desc or nil,
              })
            elseif (previous.rhs or "") ~= "" then
              pcall(vim.api.nvim_buf_set_keymap, buf, mode, previous.lhs, previous.rhs, {
                noremap = previous.noremap == 1,
                silent = previous.silent == 1,
                expr = previous.expr == 1,
                nowait = previous.nowait == 1,
                desc = previous.desc,
              })
            end
          end
        end
      end
    end
  end
  self.bindings = {}
end

---The chat config used while a worker is shown: the app's config with the
---worker's own paging. The ordinary config object is never mutated.
---@return table
function Router:worker_config()
  if self.view_config then
    return self.view_config
  end
  local ok, cfg = pcall(self.config)
  cfg = ok and type(cfg) == "table" and vim.deepcopy(cfg) or {}
  cfg.ui = cfg.ui or {}
  cfg.ui.separator = cfg.ui.separator or {}
  cfg.ui.separator.form = "off"
  cfg.ui.render = cfg.ui.render or {}
  cfg.ui.render.pagination = vim.tbl_extend("force", cfg.ui.render.pagination or {}, {
    enabled = true,
    page_blocks = 24,
    -- The display session marks each turn with a synthetic `watch-turn-N`
    -- block; without these hooks turn alignment and page boundaries drift.
    turn_start = function(block)
      return type(block.id) == "string" and block.id:match("^watch%-turn%-%d+$") ~= nil
    end,
    turn_name = function(block)
      local number = type(block.id) == "string" and block.id:match("^watch%-turn%-(%d+)$")
      return number and ("回合 " .. number) or nil
    end,
  })
  self.view_config = cfg
  return cfg
end

---@param chat table
function Router:install_view_config(chat)
  if self.saved_chat_config then
    return
  end
  self.saved_chat_config = chat.config
  chat.config = self:worker_config()
end

function Router:restore_view_config()
  local chat = self.chat
  if chat and self.saved_chat_config then
    chat.config = self.saved_chat_config
  end
  self.saved_chat_config = nil
  self.view_config = nil
end

---Bind the worker-only keys: leave the worker, the explicit interrupt, and
---turn folding/jumps in the transcript.
---
---Each binding remembers the mapping it replaced (`bind_key`), so returning to
---the leader restores the ordinary chat/composer behaviour instead of leaving
---a hole where these keys used to be.
function Router:bind_keys()
  local chat, input = self.chat, self.input
  if not self.target then
    return
  end
  local cfg = self.config() or {}
  local function bind_leader(buf)
    for _, lhs in ipairs({ "gl" }) do
      self:bind_key(buf, "n", lhs, function()
        -- `gl` leaves the worker transcript: it goes back to the ordinary
        -- session the panel showed before, which is not claimed to be the
        -- team's leader (that is `L` in the pane).
        self:leave_worker(true)
      end)
    end
  end
  bind_leader(chat and chat.buf)
  bind_leader(input and input.buf)
  local interrupt = ((cfg.teams or {}).dashboard or {}).keys
  interrupt = interrupt and interrupt.interrupt or "<M-CR>"
  for _, pair in ipairs(require("ade.ui.keymaps").expand(interrupt, { "n", "i" })) do
    self:bind_key(input and input.buf, pair.mode, pair.lhs, function()
      self:interrupt()
    end)
  end
  local chat_buf = chat and chat.buf
  self:bind_key(chat_buf, "n", "za", function()
    self:toggle_at_cursor()
  end)
  self:bind_key(chat_buf, "n", "zA", function()
    self:toggle_at_cursor()
  end)
  self:bind_key(chat_buf, "n", "[[", function()
    self:jump_turn(-1)
  end)
  self:bind_key(chat_buf, "n", "]]", function()
    self:jump_turn(1)
  end)
end

---Repaint the composer bar after the target changed.
function Router:apply_input_bar()
  if not self.target then
    return
  end
  self:refresh_bar()
end

---Repaint the composer bar after the target's state changed.
---
---No direct redraw here: `ade.app.status` owns the winbar repaint and already
---runs on every team change. Calling the redraw API from the router as well
---duplicated it and made headless runs unreliable.
function Router:refresh_bar()
  return
end

---@param first boolean|nil
function Router:render(first)
  if not (self.source and self.chat) then
    return
  end
  local display = Watch.build_session(self.source, {
    collapsed = self.collapsed,
    expanded = self.expanded,
    turn_times = self.turn_times,
    supplement = self.supplement,
    title = self.title or (self.target and (self.target.team .. "/" .. self.target.participant)),
    target = self.target and self.target.participant or nil,
    version = self.display and self.display.version or 0,
    on_toggle = function(block)
      self.expanded[block.id] = block.expanded
    end,
  })
  self.display = display
  local chat = self.chat
  self:install_view_config(chat)
  if first or not chat.session or chat._ade_team_display ~= true then
    chat:set_session(display)
  else
    chat.session = display
    chat:schedule_render("content")
  end
  chat._ade_team_display = true
  self:changed()
end

---A new frame from the team subscription.
---@param session table|nil
---@param title string|nil
function Router:on_watch(session, title)
  if not session then
    if self.releasing then
      return
    end
    -- `team:watch` releases the previous watch first, so a switch or a replay
    -- in flight legitimately emits `on_watch(nil)`; only a release with no
    -- successor means the service dropped this transcript.
    if self.watch_inflight or self.pending_target then
      return
    end
    if self.target then
      self:leave_worker(false)
    end
    return
  end
  local team, participant
  if title then
    team, participant = tostring(title):match("^([^/]+)/(.+)$")
  end
  if not self.target then
    -- Adopt only a watch the team module still holds and that belongs to this
    -- frame. After `release()` the team holds no watch, so a late frame from a
    -- superseded worker can never reopen it.
    local holding = self.team.watching
    if not (team and participant and participant ~= "leader") then
      return
    end
    if not (holding and holding.participant == participant and holding.team_id == team) then
      return
    end
    if holding.session ~= session then
      return
    end
    self:adopt(team, participant, session, title)
    return
  end
  if team and (team ~= self.target.team or participant ~= self.target.participant) then
    return
  end
  local frame = self.team.watching
  if not (frame and frame.participant == self.target.participant and frame.team_id == self.target.team) then
    return
  end
  if self.source ~= session then
    self.source = session
    self.collapsed, self.expanded, self.turn_times = {}, {}, {}
    self.turn_times = frame.turn_times or {}
    self:render(true)
    self:load_supplement(session)
    return
  end
  if frame.turn_times then
    self.turn_times = frame.turn_times
  end
  self:render(false)
  self:load_supplement(session)
end

---A long session the service could not replay: fetch the tail from team.read
---once and render it above the live part (same rule as the old watch view).
---@param session table
function Router:load_supplement(session)
  local frame = self.team.watching
  if not (frame and self.target) or frame.replayed ~= false then
    return
  end
  if self.supplement_for == session or type(self.team.read) ~= "function" then
    return
  end
  self.supplement_for = session
  local target = self.target
  local request = self.request_id
  self.team:read(target.team, target.participant, nil, function(ok, value)
    if request ~= self.request_id then
      return
    end
    if not ok or self.source ~= session or not self.target then
      return
    end
    self.supplement = type(value) == "table" and value or nil
    self:render(false)
  end)
end

---Show an already-running watch without asking the service again.
---@param team string
---@param participant string
---@param session table
---@param title string|nil
---@return boolean
function Router:adopt(team, participant, session, title)
  if not self:ensure_panel() then
    return false
  end
  local row = self.team:team(team)
  local cwd = (row and row.cwd) or (self.team.resolve_cwd and self.team.resolve_cwd()) or vim.fn.getcwd()
  local chat, input = self.chat, self.input
  self:remember_leader_slot()
  self.target = { team = team, participant = participant }
  self.title = title or (team .. "/" .. participant)
  self.source = session
  self.collapsed, self.expanded, self.turn_times = {}, {}, {}
  self.turn_times = (self.team.watching and self.team.watching.turn_times) or {}
  self.supplement, self.supplement_for = nil, nil
  local key = self.draft_key(team, participant)
  local restored = drafts.get(cwd, key)
  input:switch_session(key, restored, { id = key, cwd = cwd, team = team, participant = participant })
  input.attachments = {}
  self:bind_keys()
  self:apply_input_bar()
  self:render(true)
  self.win = chat.win
  self.buf = chat.buf
  self:changed()
  return true
end

---@param team string
---@param participant string
---@return string
function Router:draft_key(team, participant)
  return "team:" .. tostring(team) .. ":" .. tostring(participant)
end

---Start the next queued watch. One replay per connection, so intermediate
---targets are skipped; the callback only owns the request that started it.
function Router:pump()
  if self.watch_inflight then
    return
  end
  local target = self.pending_target
  if not target then
    return
  end
  self.pending_target = nil
  self.active_target = target
  self.watch_inflight = true
  local request = self.request_id
  self.inflight_request = request
  self.team:watch(target.team, target.participant, true, function(ok, value)
    if self.inflight_request ~= request then
      -- A newer request owns the in-flight state; this answer is stale and
      -- must not clear it, reopen a transcript, or start another watch.
      return
    end
    self.inflight_request = nil
    self.watch_inflight = false
    if request ~= self.request_id then
      if self.pending_target then
        self:pump()
      end
      return
    end
    if not ok then
      local message = type(value) == "table" and (value.message or value.code) or tostring(value)
      self:notify("无法查看 " .. tostring(target.participant) .. "：" .. tostring(message))
      self:leave_worker(true)
      return
    end
    if self.pending_target then
      self:pump()
    end
  end)
end

---@return boolean
function Router:ensure_panel()
  local panel = self.panel and self.panel() or nil
  if panel then
    local ok = panel:show()
    if not ok then
      return false
    end
  end
  self.chat = self.leader_chat and self.leader_chat() or nil
  self.input = self.leader_input and self.leader_input() or nil
  if not (self.chat and self.input) then
    self:notify("聊天面板不可用", vim.log.levels.WARN)
    return false
  end
  return true
end

---Remember which session and composer slot the leader used before a worker
---took the panel over. Restoring falls back to these when the app's current
---session is gone (a session switch, a dropped session), so a worker visit
---never strands the composer on the worker's slot.
function Router:remember_leader_slot()
  if self.saved_leader then
    return
  end
  local input = self.input
  self.saved_leader = {
    key = input and input.session_key or nil,
    owner = input and input.draft_owner or nil,
    session = self.current_session and self.current_session() or nil,
  }
end

---Point the shared chat at `participant`, or restore the leader.
---@param team string|nil
---@param participant string|nil
---@return boolean ok
function Router:select(team, participant)
  if not participant or participant == "leader" then
    return self:restore_leader(true, team)
  end
  -- The team row is optional: the service owns the watch and may know the team
  -- before a `team.changed` reached this front end. Only the draft location
  -- needs a cwd.
  local row = self.team:team(team)
  if self.target and self.target.team == team and self.target.participant == participant then
    -- Re-selecting the same worker only re-focuses its transcript.
    if self.chat and self.chat.win and vim.api.nvim_win_is_valid(self.chat.win) then
      pcall(vim.api.nvim_set_current_win, self.chat.win)
      pcall(self.refresh_bar, self)
    end
    return true
  end
  if not self:ensure_panel() then
    return false
  end
  local cwd = (row and row.cwd) or (self.team.resolve_cwd and self.team.resolve_cwd()) or vim.fn.getcwd()
  local chat, input = self.chat, self.input
  self:remember_leader_slot()
  self.request_id = self.request_id + 1
  self.target = { team = team, participant = participant }
  self.title = team .. "/" .. participant
  self.source, self.display = nil, nil
  self.collapsed, self.expanded, self.turn_times = {}, {}, {}
  self.supplement, self.supplement_for = nil, nil
  self:clear_interrupt()
  local key = self:draft_key(team, participant)
  local owner = { id = key, cwd = cwd, team = team, participant = participant }
  local restored = drafts.get(cwd, key)
  input:switch_session(key, restored, owner)
  input.attachments = {}
  self:bind_keys()
  self:apply_input_bar()
  -- Show what is already known while the replay is on its way.
  if not (chat.session and chat.session.id == key) then
    chat:set_session(nil)
    chat.pending_new = false
  end
  self:changed()
  if
    self.watch_inflight
    and self.active_target
    and self.active_target.team == team
    and self.active_target.participant == participant
  then
    self.pending_target = nil
  else
    self.pending_target = { team = team, participant = participant }
  end
  self:pump()
  self.win = chat.win
  self.buf = chat.buf
  return true
end

---Normalized absolute path for comparison.
---@param path string
---@return string
local function normalize_path(path)
  local value = vim.fn.fnamemodify(tostring(path), ":p")
  if #value > 1 then
    value = value:gsub("/+$", "")
  end
  return value
end

---Whether `session` is this front end's own leader of `team`.
---
---Being in the same cwd and agent is not enough: one project routinely has
---several sessions, and only the one the service bound as the leader
---(`team.list[].leader.sessionId`, on our own instance) is *the* leader.
---@param session table|nil
---@param row table|nil
---@return boolean
function Router:is_leader_session(session, row)
  if not (session and type(row) == "table") then
    return false
  end
  local leader = type(row.leader) == "table" and row.leader or nil
  if not (leader and type(leader.sessionId) == "string" and leader.sessionId ~= "") then
    return false
  end
  if tostring(session.id) ~= leader.sessionId then
    return false
  end
  -- Another instance may lead this cwd's team; its session id is not ours.
  local ours = self.instance_of and self.instance_of() or nil
  if type(leader.instance) == "string" and leader.instance ~= "" and ours and leader.instance ~= ours then
    return false
  end
  local ok, cfg = pcall(self.config)
  local agent = ok and type(cfg) == "table" and cfg.agent or nil
  if agent and session.agent_name and session.agent_name ~= agent then
    return false
  end
  if row.cwd and session.cwd then
    if normalize_path(session.cwd) ~= normalize_path(row.cwd) then
      return false
    end
  end
  return true
end

---The exact leader session of `team`, or nil when this front end cannot prove
---one (another instance leads it, the session is gone, or the team is suspended).
---@param team string|nil
---@return table|nil session
function Router:leader_session(team)
  if not team then
    return nil
  end
  local row = self.team:team(team)
  local leader = type(row) == "table" and type(row.leader) == "table" and row.leader or nil
  if not (leader and type(leader.sessionId) == "string" and leader.sessionId ~= "") then
    return nil
  end
  local session = self.current_session and self.current_session() or nil
  if session and self:is_leader_session(session, row) then
    return session
  end
  -- The leader exists but is not the session on screen: find it by id.
  local found = self.find_session and self.find_session(leader.sessionId) or nil
  if found and self:is_leader_session(found, row) then
    return found
  end
  return nil
end

---Tell the person why the team's leader cannot be shown here.
---@param team string|nil
function Router:leader_unavailable(team)
  local row = self.team:team(team)
  local leader = type(row) == "table" and type(row.leader) == "table" and row.leader or nil
  local message
  if not leader or type(leader.sessionId) ~= "string" or leader.sessionId == "" then
    message = "这个团队还没有可切换的 leader 会话"
  else
    local ours = self.instance_of and self.instance_of() or nil
    if type(leader.instance) == "string" and leader.instance ~= "" and ours and leader.instance ~= ours then
      message = "这个团队的 leader 属于另一个服务实例，本窗口无法切换"
    else
      message = "团队 leader 会话（"
        .. leader.sessionId
        .. "）不在本前端，无法切换；当前目标保持不变"
    end
  end
  self:notify(message, vim.log.levels.WARN)
end

---Put the shared transcript back on the leader.
---
---Two distinct intents share this path:
---
---  * `select("leader")` / `L` in a pane: talk to *the team's leader*. That is
---    the exact session the service bound (`team.list[].leader`), not merely
---    any session in the same cwd. When it cannot be shown here (another
---    instance, a session this front end does not have), nothing changes: the
---    worker stays on screen with its draft, and the person is told why.
---  * `gl` from a worker transcript: leave the worker and go back to the
---    ordinary session the panel showed before the worker replaced it. That is
---    not necessarily the team leader and does not claim to be.
---@param focus boolean|nil
---@param team string|nil the team whose leader is meant
---@param mode string|nil "leader" (default) or "previous"
---@return boolean
function Router:restore_leader(focus, team, mode)
  mode = mode or "leader"
  local team_id = team or (self.target and self.target.team)
  local previous = self.saved_leader
  local session
  if mode == "previous" then
    -- Leave the worker: go back to exactly what the composer showed before.
    session = previous and previous.session or nil
    if session and self.find_session and not self.find_session(session.id) then
      -- The session the panel came from is gone; fall back to the app's own.
      session = nil
    end
    if not session then
      session = self.current_session and self.current_session() or nil
    end
  else
    session = self:leader_session(team_id)
    if not session then
      -- Leave everything as it is: the worker, its draft and its send target.
      if focus then
        pcall(self.refresh_bar, self)
      end
      self:leader_unavailable(team_id)
      return false
    end
  end
  local was_worker = self.target ~= nil
  if focus then
    self:ensure_panel()
  end
  self:release()
  local chat = self.leader_chat and self.leader_chat() or self.chat
  local input = self.leader_input and self.leader_input() or self.input
  self.chat, self.input = chat, input
  local same = chat and chat.session == session
  if chat and session then
    if not same then
      if self.select_session then
        -- Let the app switch, so `S.sess.current`, the transcript and the
        -- composer all follow the same session instead of drifting apart.
        pcall(self.select_session, session)
      end
      if self.chat and self.chat.session ~= session then
        self.chat:set_session(session)
      end
    end
    chat.pending_new = false
  elseif chat and not session then
    chat:set_session(nil)
  end
  if input and session and input.session_key ~= session.id then
    local restored = drafts.get(session.cwd, session.id)
    input:switch_session(session.id, restored, session)
  elseif input and not session and was_worker then
    -- The panel can inspect a worker before this editor has connected an
    -- ordinary session. Do not leave that worker's draft in the newly
    -- restored ordinary composer, where it would be sent to a different agent.
    local key = previous and previous.key or nil
    local owner = previous and previous.owner or nil
    local restored = key and owner and drafts.get(owner.cwd, key) or nil
    input:switch_session(key, restored, owner)
  end
  if focus and chat and chat.win and vim.api.nvim_win_is_valid(chat.win) then
    pcall(vim.api.nvim_set_current_win, chat.win)
  end
  if was_worker then
    self:changed()
  end
  return true
end

---Drop the worker target without touching which session the chat shows.
---
---The app calls this when it replaces the transcript itself (session picker,
---new session, restore) so team routing can never outlive its target.
function Router:release()
  self.releasing = true
  self.request_id = self.request_id + 1
  self.pending_target = nil
  self.active_target = nil
  self.inflight_request = nil
  self.watch_inflight = false
  self.target = nil
  self.title = nil
  self.source, self.display = nil, nil
  self.collapsed, self.expanded, self.turn_times = {}, {}, {}
  self.supplement, self.supplement_for = nil, nil
  self.saved_leader = nil
  self.win, self.buf = nil, nil
  self:clear_interrupt()
  self:unbind()
  self:restore_view_config()
  self.team:unwatch()
  self.releasing = false
  local chat = self.leader_chat and self.leader_chat() or self.chat
  local input = self.leader_input and self.leader_input() or self.input
  if chat then
    chat._ade_team_display = nil
  end
  if input then
    pcall(input.apply_winbar, input)
    self:refresh_bar()
  end
end

---Drop the team routing because the app is switching sessions itself.
function Router:detach()
  if self:is_worker() then
    self:release()
    self:changed()
  end
end

---@return boolean handled
function Router:route_submit(text, attachments)
  if not self.target then
    return false
  end
  self:submit(text, attachments)
  return true
end

---Send from the ordinary composer to the selected worker.
---@param text string
---@param attachments table[]|nil
function Router:submit(text, attachments)
  local target = self.target
  if not target then
    return
  end
  text = tostring(text or "")
  if not text:match("%S") then
    return
  end
  if #(attachments or {}) > 0 then
    -- The bus carries text; refuse instead of silently dropping the chips.
    self:notify("团队通道暂不支持附件：已保留草稿，请先移除附件再发送", vim.log.levels.WARN)
    return
  end
  local entry = self:entry()
  if entry and entry.state == "exited" then
    self:notify("worker " .. tostring(target.participant) .. " 已退出，只能回看", vim.log.levels.WARN)
    return
  end
  local interrupt = self.interrupt_armed
  self.interrupt_armed = false
  self:clear_interrupt()
  local input = self.input
  local key = input and input.session_key or nil
  -- The composer's identity plus its changedtick: if the person edits, switches
  -- targets, or the buffer is replaced before the answer arrives, the late
  -- success must not wipe the newer text.
  local tick = input
      and input.buf
      and vim.api.nvim_buf_is_valid(input.buf)
      and vim.api.nvim_buf_get_changedtick(input.buf)
    or nil
  local request = self.request_id
  self.team:send(target.team, target.participant, "notice", text, {
    cc = { "leader" },
    interrupt = interrupt,
  }, function(ok, value)
    if not ok then
      local message = type(value) == "table" and (value.message or value.code) or tostring(value)
      self:notify("发送失败：" .. tostring(message), vim.log.levels.WARN)
      return
    end
    -- Only clear the composer that submitted this message, and only while it
    -- still shows the same untouched draft for the same target.
    if
      input
      and input == self.input
      and self.target
      and self.target.team == target.team
      and self.target.participant == target.participant
      and request == self.request_id
      and input.session_key == key
      and tick
      and vim.api.nvim_buf_is_valid(input.buf)
      and vim.api.nvim_buf_get_changedtick(input.buf) == tick
    then
      pcall(input.clear, input)
    end
    if type(value) == "table" and value.cc_failed then
      self:notify("消息已发出，但抄送 leader 失败：" .. tostring(value.cc_failed), vim.log.levels.WARN)
    end
  end)
end

function Router:clear_interrupt()
  self.interrupt_armed = false
  if self.interrupt_timer then
    pcall(function()
      self.interrupt_timer:stop()
      self.interrupt_timer:close()
    end)
    self.interrupt_timer = nil
  end
  if self.interrupt_win and vim.api.nvim_win_is_valid(self.interrupt_win) then
    pcall(vim.api.nvim_win_close, self.interrupt_win, true)
  end
  self.interrupt_win = nil
end

function Router:show_interrupt_hint()
  local input = self.input
  if not (input and input.win and vim.api.nvim_win_is_valid(input.win)) then
    return
  end
  local text = "再按一次确认打断 " .. tostring(self.target and self.target.participant or "") .. " 当前回合"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " " .. text })
  local width = math.max(20, vim.api.nvim_strwidth(text) + 2)
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "win",
    win = input.win,
    row = -1,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
  })
  if ok then
    self.interrupt_win = win
  end
end

---Arm, then send with `interrupt = true` on the second press.
function Router:interrupt()
  if not self.target then
    return
  end
  local input = self.input
  local text = input and input:text() or ""
  if not text:match("%S") then
    self:notify("先输入要发给 " .. tostring(self.target.participant) .. " 的内容")
    return
  end
  if self.interrupt_armed then
    -- Second press: submit with `interrupt = true`.
    self:submit(text, input and input.attachments or {})
    return
  end
  self.interrupt_armed = true
  self:show_interrupt_hint()
  self.interrupt_timer = vim.uv.new_timer()
  if self.interrupt_timer then
    self.interrupt_timer:start(
      INTERRUPT_MS,
      0,
      vim.schedule_wrap(function()
        self:clear_interrupt()
      end)
    )
  end
end

---Turn headings, read back from the buffer so folding follows what is shown.
---@return {line: integer, number: integer, id: string}[]
function Router:turn_lines()
  local chat = self.chat
  if not (chat and chat.buf and vim.api.nvim_buf_is_valid(chat.buf)) then
    return {}
  end
  local out = {}
  for index, line in ipairs(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)) do
    local number = tonumber(line:match("^── turn (%d+)"))
    if number then
      out[#out + 1] = { line = index, number = number, id = "watch-turn-" .. number }
    end
  end
  return out
end

---Move the cursor to the previous or next turn heading in the transcript.
---@param direction integer
---@return boolean moved
function Router:jump_turn(direction)
  local chat = self.chat
  if not (chat and chat.win and vim.api.nvim_win_is_valid(chat.win)) then
    return false
  end
  local current = vim.api.nvim_win_get_cursor(chat.win)[1]
  local turns = self:turn_lines()
  local target
  if direction > 0 then
    for _, entry in ipairs(turns) do
      if entry.line > current then
        target = entry
        break
      end
    end
  else
    for index = #turns, 1, -1 do
      if turns[index].line < current then
        target = turns[index]
        break
      end
    end
    if not target and turns[1] then
      target = turns[1]
    end
  end
  if target then
    pcall(vim.api.nvim_win_set_cursor, chat.win, { target.line, 0 })
    chat.follow = false
    return true
  end
  if direction > 0 or not (chat.page and chat.session) then
    return false
  end
  -- The previous turn is on an older page: hand it to the chat's pagination.
  local blocks = chat.session.blocks or {}
  local function is_turn(block)
    return type(block.id) == "string" and block.id:match("^watch%-turn%-%d+$") ~= nil
  end
  local index = (chat.page.first or 1) - 1
  if chat.page.continuation then
    local heading = chat.page.first or 1
    while heading >= 1 and not is_turn(blocks[heading]) do
      heading = heading - 1
    end
    index = heading - 1
  end
  while index >= 1 and not is_turn(blocks[index]) do
    index = index - 1
  end
  if index < 1 then
    return false
  end
  chat.follow = false
  self:_load_turn_page(blocks[index].id, 0)
  return true
end

---Load older pages until `target_id` is inside the page (a very long turn can
---span several), then let the chat's `page_target` place the cursor.
---@param target_id string
---@param attempts integer|nil
function Router:_load_turn_page(target_id, attempts)
  local chat = self.chat
  if not (chat and chat.page and chat.session) then
    return
  end
  if chat.commit_job or chat.layout_job then
    vim.defer_fn(function()
      if self.chat == chat then
        self:_load_turn_page(target_id, attempts)
      end
    end, 50)
    return
  end
  local index
  for position, block in ipairs(chat.session.blocks) do
    if block.id == target_id then
      index = position
      break
    end
  end
  if not index or index >= chat.page.first then
    return
  end
  if chat.page.first <= 1 or (attempts or 0) >= 100 then
    return
  end
  if chat:load_page(-1, target_id) then
    vim.defer_fn(function()
      if self.chat == chat then
        self:_load_turn_page(target_id, (attempts or 0) + 1)
      end
    end, 50)
  end
end

---Toggle the block under the cursor, or fold an entire turn when the cursor
---sits on its heading.
function Router:toggle_at_cursor()
  local chat = self.chat
  if not chat then
    return
  end
  local win = chat.win
  if win and vim.api.nvim_win_is_valid(win) then
    local line = vim.api.nvim_win_get_cursor(win)[1]
    for _, entry in ipairs(self:turn_lines()) do
      if entry.line == line then
        self.collapsed[entry.number] = not self.collapsed[entry.number]
        self:render(false)
        if self.display and chat.session ~= self.display then
          chat.session = self.display
          chat:schedule_render("content")
        end
        return
      end
    end
  end
  chat:toggle_current()
end

---@return boolean
function Router:focus_input()
  local input = self.input
  if input and input.win and vim.api.nvim_win_is_valid(input.win) then
    pcall(vim.api.nvim_set_current_win, input.win)
    return true
  end
  return false
end

---The worker disappeared from the team; close the transcript it owned.
---@param team string
---@param participant string
function Router:participant_gone(team, participant)
  if self.target and self.target.team == team and self.target.participant == participant then
    self:leave_worker(false)
  end
end

---Leave the worker transcript and go back to the ordinary session it replaced
---(`gl`). Unlike `L`, this makes no claim that the session is the team leader.
---@param focus boolean|nil
---@return boolean
function Router:leave_worker(focus)
  return self:restore_leader(focus, self.target and self.target.team or nil, "previous")
end

---Compatibility entry the panes and older callers use: open a participant.
---
---The leader returns to its own session (and reveals the ordinary panel); a
---worker replays into the shared transcript.
---@param team string
---@param participant string
---@return boolean
function Router:open(team, participant)
  if not participant or participant == "leader" then
    return self:restore_leader(true, team)
  end
  return self:select(team, participant)
end

---Drop the worker target and go back to where the composer was before.
function Router:close()
  self:restore_leader(false, nil, "previous")
end

function Router:close_view()
  self:close()
end

M.Router = Router

return M
