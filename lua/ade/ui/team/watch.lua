-- The read-only participant watch view (W0g).
--
-- A worker is rendered by an ordinary `Chat` over a display-only session: the
-- reducer still owns the watched session, while this module groups its blocks
-- into turns, renders bus traffic as messages, and keeps the role card
-- collapsed. The leader uses the existing chat window (no second Chat/input).
local Chat = require("ade.ui.chat")
local keymaps = require("ade.ui.keymaps")

local M = {}

local Watch = {}
Watch.__index = Watch

local function unescape(text)
  return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&"))
end

local function one_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " "):gsub("%s+$", ""))
end

---The first `<bus ...>` tag in a prompt.
---@param text string
---@return {from: string|nil, kind: string|nil, task: string|nil, body: string, at: integer}|nil
local function parse_bus(text)
  local from, kind, task = text:match('<bus from="([^"]*)" kind="([^"]*)" task="([^"]*)"')
  if not from then
    from, kind = text:match('<bus from="([^"]*)" kind="([^"]*)"')
  end
  if not from then
    return nil
  end
  local body = text:match("^.-<bus[^>]*>(.-)</bus>") or ""
  return { from = from, kind = kind, task = task, body = unescape(body), at = text:find("<bus", 1, true) or 1 }
end

---Split a first prompt into its role card and its initial bus message.
---@param text string
---@return string|nil role, string message
local function split_role(text)
  local bus_at = text:find("<bus", 1, true)
  if not bus_at then
    -- Only a bus prompt can carry a role-card prefix; an ordinary prompt that
    -- happens to start with "You are" is a normal message.
    return nil, text
  end
  local before = text:sub(1, bus_at - 1)
  if before:find("You are ", 1, true) or before:find("<team_role>", 1, true) then
    return before, text:sub(bus_at)
  end
  return nil, text
end

---The tool's most descriptive name/title.
---@param block table
---@return string
local function typesafe_title(block)
  local value = block.tool_name or block.name or block.title or ""
  if type(value) ~= "string" then
    return ""
  end
  return value:lower()
end

---A `bus_send` / `bus_ask_human` tool card becomes a message line.
---@param block table
---@return {title: string, text: string}|nil
local function bus_tool(block)
  if block.kind ~= "tool" then
    return nil
  end
  local input = type(block.raw_input) == "table" and block.raw_input or {}
  local title = typesafe_title(block)
  -- The pi adapter calls a generic `mcp` tool with `{tool="bus_send", args=...}`;
  -- direct agents expose `bus_send` or `mcp__ade-team__bus_send`.
  local proxy = type(input.tool) == "string" and input.tool:lower() or nil
  local name = proxy or title
  local args = proxy and type(input.args) == "table" and input.args or input
  local is_send = name:find("bus_send", 1, true) ~= nil or name:find("bus send", 1, true) ~= nil
  local is_ask = name:find("bus_ask_human", 1, true) ~= nil or name:find("bus ask human", 1, true) ~= nil
  if not is_send and not is_ask then
    -- A tool that happens to have a `body`/`question` argument is not a bus
    -- message (create-issue and ask-user tools are common false positives).
    return nil
  end
  local body
  if is_send then
    local to = args.to or "?"
    local kind = args.kind or "message"
    local task = args.task
    local suffix = task and task ~= "" and task ~= "_" and (" " .. task) or ""
    body = string.format("→ %s %s%s：%s", to, kind, suffix, tostring(args.body or ""))
  else
    body = "asks: " .. tostring(args.question or "")
  end
  return { title = title, text = body }
end

---A display-only session for Chat: the source blocks grouped into turns.
---@param source table
---@param opts {collapsed: table<integer, boolean>, expanded: table<string, boolean>,
---  turn_times: table<string, {started_at: integer|nil, ended_at: integer|nil}>|nil,
---  supplement: table|nil, version: integer|nil, on_toggle: (fun(block: table)|nil)}
---@return table session
local function build_session(source, opts)
  local display = {
    id = source.id,
    cwd = source.cwd,
    blocks = {},
    version = (opts.version or 0) + 1,
    tracked = false,
    historical = true,
    trimmed = source.trimmed,
  }
  function display:toggle(block)
    block.toggled = true
    block.expanded = not block.expanded
    if opts.on_toggle then
      opts.on_toggle(block)
    end
  end
  function display:finish_turn() end

  local blocks = display.blocks
  local next_id = 0
  local function add(block, id)
    if id then
      block.id = id
    elseif not block.id then
      next_id = next_id + 1
      block.id = "watch-" .. next_id
    end
    blocks[#blocks + 1] = block
    return block
  end

  local supplement = opts.supplement
  if supplement then
    add({
      kind = "system",
      text = "会话过长，只显示观察开始之后的内容",
      id = "watch-banner",
    })
    for index, message in ipairs(type(supplement.messages) == "table" and supplement.messages or {}) do
      local task = message.task
      local title = string.format(
        "%s → %s%s",
        tostring(message.from or "?"),
        tostring(message.kind or "message"),
        task and task ~= "_" and (" " .. task) or ""
      )
      add({
        kind = "message",
        title = title,
        text = tostring(message.body or ""),
        id = "watch-message-" .. index,
      })
    end
    local turns = type(supplement.turns) == "table" and supplement.turns or {}
    for index = math.max(1, #turns - 2), #turns do
      local turn = turns[index]
      if type(turn) == "table" and type(turn.text) == "string" and turn.text ~= "" then
        add({
          kind = "agent",
          text = turn.text,
          id = "watch-turn-text-" .. index,
        })
      end
    end
  end

  -- First pass: turn groups. A user block is a prompt and opens a turn.
  local groups = {}
  local current = nil
  for _, block in ipairs(source.blocks or {}) do
    if block.kind == "user" then
      current = { prompt = block, body = {} }
      groups[#groups + 1] = current
    elseif current then
      current.body[#current.body + 1] = block
    else
      add(block)
    end
  end

  for turn_index, group in ipairs(groups) do
    local prompt = group.prompt
    local bus = parse_bus(prompt.text or "")
    local origin = (type(prompt.bus) == "table" and prompt.bus.origin) or (bus and "bus") or "prompt"
    local timing = opts.turn_times and opts.turn_times[prompt.id] or nil
    local started = timing and timing.started_at or nil
    local ended = timing and timing.ended_at or nil
    local label
    if bus then
      label = string.format(
        "%s → %s%s",
        bus.from or "?",
        bus.kind or "message",
        bus.task and bus.task ~= "" and (" " .. bus.task) or ""
      )
    else
      label = origin
    end
    local tools = 0
    for _, block in ipairs(group.body) do
      if block.kind == "tool" then
        tools = tools + 1
      end
    end
    local parts = { string.format("── turn %d", turn_index), origin, label }
    if tools > 0 then
      parts[#parts + 1] = string.format("%d tool%s", tools, tools == 1 and "" or "s")
    end
    if started and ended and ended >= started then
      parts[#parts + 1] = string.format("%.1fs", (ended - started) / 1000)
    end
    local collapsed = opts.collapsed[turn_index] == true
    if collapsed then
      parts[#parts + 1] = "(collapsed)"
    end
    add({
      kind = "system",
      text = table.concat(parts, " · "),
      id = "watch-turn-" .. turn_index,
    })

    local text = prompt.text or ""
    -- The role card belongs to the first bus prompt only.
    local role, message = nil, text
    if turn_index == 1 and bus then
      role, message = split_role(text)
    end
    if role then
      local role_id = "watch-role-" .. turn_index
      add({
        kind = "message",
        title = "role card",
        text = role,
        collapsible = true,
        expanded = opts.expanded[role_id] == true,
        display_text = "",
        id = role_id,
      }, role_id)
    end
    local bus_message = parse_bus(message)
    add({
      kind = "message",
      title = label,
      text = bus_message and bus_message.body or unescape(message),
      id = "watch-prompt-" .. turn_index,
    }, "watch-prompt-" .. turn_index)

    if not collapsed then
      for body_index, block in ipairs(group.body) do
        local message_block = bus_tool(block)
        if message_block then
          add({
            kind = "message",
            title = message_block.title ~= "" and message_block.title or "bus",
            text = message_block.text,
            id = "watch-bus-" .. tostring(block.id or body_index) .. "-" .. body_index,
          }, "watch-bus-" .. tostring(block.id or body_index) .. "-" .. body_index)
        else
          add(block)
        end
      end
    end
  end

  return display
end

---@param opts {team: table, config: fun(): table, notify: fun(message: string)|nil,
---  leader_chat: (fun(): table|nil)|nil, on_change: (fun()|nil)|nil}
---@return table
function M.new(opts)
  return setmetatable({
    team = opts.team,
    config = opts.config,
    notify = opts.notify,
    leader_chat = opts.leader_chat,
    on_change = opts.on_change,
    win = nil,
    buf = nil,
    chat = nil,
    source = nil,
    display = nil,
    team_id = nil,
    participant = nil,
    title = nil,
    replayed = true,
    supplement = nil,
    supplement_for = nil,
    collapsed = {},
    expanded = {},
    turn_times = {},
    generation = 0,
    closing = false,
    leader_active = false,
  }, Watch)
end

function Watch:current_team()
  return self.team_id
end

function Watch:current_participant()
  return self.participant
end

function Watch:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function Watch:changed()
  if self.on_change then
    pcall(self.on_change, self)
  end
end

---The configuration for the view: the app's, with the built-in turn dividers
---turned off because this view draws its own headings.
---@return table
function Watch:watch_config()
  local ok, cfg = pcall(self.config)
  cfg = ok and type(cfg) == "table" and vim.deepcopy(cfg) or {}
  cfg.ui = cfg.ui or {}
  cfg.ui.separator = cfg.ui.separator or {}
  cfg.ui.separator.form = "off"
  cfg.ui.render = cfg.ui.render or {}
  cfg.ui.render.pagination = vim.tbl_extend("force", cfg.ui.render.pagination or {}, { enabled = false })
  return cfg
end

function Watch:update_header()
  if not self:is_open() or not self.participant then
    return
  end
  local entry = self.team:participant(self.team_id, self.participant)
  local task = entry and entry.task or "-"
  local state = entry and entry.state or "?"
  local header = string.format(" %s · %s · %s ", self.participant, tostring(task), tostring(state))
  pcall(function()
    vim.wo[self.win].winbar = header
  end)
end

function Watch:ensure_window()
  if self.chat then
    return
  end
  self.generation = self.generation + 1
  local generation = self.generation
  self.closing = false
  self.chat = Chat.new({ config = self:watch_config() })
  self.buf = self.chat.buf
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "ade_team_watch"
  vim.bo[self.buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, self.buf, string.format("ade://watch/%s/%s", tostring(self.team_id), tostring(self.participant)))

  local previous = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  self.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.win, self.buf)
  self.chat.win = self.win
  vim.wo[self.win].number = false
  vim.wo[self.win].wrap = true
  self:map_keys()
  vim.api.nvim_set_current_win(previous)

  local buf = self.buf
  local group = vim.api.nvim_create_augroup("AdeTeamWatch" .. tostring(buf), { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if generation ~= self.generation or self.buf ~= buf then
          return
        end
        self:window_gone()
      end)
    end,
  })
  self:changed()
end

function Watch:map_keys()
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true })
  end
  map("za", function()
    self:toggle_at_cursor()
  end)
  map("[[", function()
    self:jump_turn(-1)
  end)
  map("]]", function()
    self:jump_turn(1)
  end)
  map("G", function()
    if self.chat then
      self.chat:resume_follow()
    end
  end)
  map("<CR>", function()
    self:toggle_at_cursor()
  end)
  -- Use the same configurable block keys as the chat view (`<Tab>`, `[b`,
  -- `]b`, `G`, `gg`, `g?`). Only actions that make sense read-only are bound.
  local config = self:watch_config()
  keymaps.attach("chat", self.buf, (config.keymaps or {}).chat or {}, {
    on_toggle_block = function()
      self:toggle_at_cursor()
    end,
    on_prev_block = function()
      self:jump_turn(-1)
    end,
    on_next_block = function()
      self:jump_turn(1)
    end,
    on_scroll_bottom = function()
      if self.chat then
        self.chat:resume_follow()
      end
    end,
    on_scroll_top = function()
      if self.chat then
        self.chat:scroll_to_top()
      end
    end,
    on_help = function()
      if self.notify then
        self.notify(
          "watch: za/<Tab>/<CR> toggle · [[ / ]] previous/next turn · G follow · q close"
        )
      end
    end,
  })
  map("q", function()
    self:close()
  end)
end

---Close the view without touching the service watch (used when a new watch
---replaces this one).
function Watch:destroy_view()
  self.generation = self.generation + 1
  self.closing = true
  local chat = self.chat
  self.chat, self.buf = nil, nil
  local win = self.win
  self.win = nil
  self.source, self.display = nil, nil
  if chat then
    pcall(chat.destroy, chat)
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  self.closing = false
  self:changed()
end

function Watch:window_gone()
  if self.closing then
    return
  end
  self:destroy_view()
  -- Idempotent: a superseded request may already have cleared `participant`.
  self.team:unwatch()
  self.participant, self.team_id, self.title = nil, nil, nil
  self.leader_active = false
  self:changed()
end

---@param session table|nil
---@param title string|nil
function Watch:on_watch(session, title)
  if not session then
    self:destroy_view()
    self.participant, self.team_id, self.title = nil, nil, nil
    self.leader_active = false
    self:changed()
    return
  end
  local watching = self.team.watching
  if watching then
    self.team_id = watching.team_id or self.team_id
    self.participant = watching.participant or self.participant
    self.replayed = watching.replayed ~= false
  elseif title then
    local team, name = tostring(title):match("^([^/]+)/(.+)$")
    self.team_id, self.participant = team or self.team_id, name or self.participant
  end
  self.leader_active = false
  self.title = title
  local first = self.source ~= session
  if first then
    self:destroy_view()
    self.source = session
    self.supplement = nil
    self.supplement_for = nil
    self.collapsed = {}
    self.expanded = {}
    self.turn_times = (watching and watching.turn_times) or {}
    self:ensure_window()
  elseif watching and watching.turn_times then
    self.turn_times = watching.turn_times
  end
  if not self:is_open() then
    return
  end
  self:refresh(first)
  self:update_header()
  if not self.replayed and self.supplement_for ~= session and self.team_id and self.participant then
    self.supplement_for = session
    self.team:read(self.team_id, self.participant, nil, function(ok, value)
      if ok and self.source == session then
        self.supplement = type(value) == "table" and value or nil
        self:refresh(false)
      end
    end)
  end
  self:changed()
end

---Rebuild the display session and render.
---@param first boolean|nil
function Watch:refresh(first)
  if not self.source or not self.chat then
    return
  end
  local display = build_session(self.source, {
    collapsed = self.collapsed,
    expanded = self.expanded,
    turn_times = self.turn_times,
    supplement = self.supplement,
    version = self.display and self.display.version or 0,
    on_toggle = function(block)
      self.expanded[block.id] = block.expanded
    end,
  })
  self.display = display
  if first or not self.chat.session then
    self.chat:set_session(display)
  else
    self.chat.session = display
    self.chat:schedule_render("content")
  end
end

---Turn heading lines, read back from the buffer so the mapping stays correct
---across every re-render.
---@return {line: integer, number: integer, id: string}[]
function Watch:turn_lines()
  local out = {}
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return out
  end
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  for index, line in ipairs(lines) do
    local number = tonumber(line:match("^── turn (%d+)"))
    if number then
      out[#out + 1] = { line = index, number = number, id = "watch-turn-" .. number }
    end
  end
  return out
end

function Watch:toggle_at_cursor()
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local turns = self:turn_lines()
  local target = nil
  for _, entry in ipairs(turns) do
    if entry.line == line then
      target = entry
      break
    end
  end
  if target then
    self.collapsed[target.number] = not self.collapsed[target.number]
    self:refresh(false)
    return
  end
  if self.chat then
    self.chat:toggle_current()
  end
end

---@param direction integer
function Watch:jump_turn(direction)
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local current = vim.api.nvim_win_get_cursor(win)[1]
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
  end
  if target then
    pcall(vim.api.nvim_win_set_cursor, win, { target.line, 0 })
    if self.chat then
      self.chat.follow = false
    end
  end
end

---Focus the existing leader chat. The leader is not watched and gets no second
---Chat or input area.
---@return boolean
function Watch:focus_leader()
  self:destroy_view()
  self.team:unwatch()
  self.participant, self.team_id, self.title = "leader", nil, nil
  self.leader_active = true
  self:changed()
  local chat = self.leader_chat and self.leader_chat() or nil
  if chat and chat.win and vim.api.nvim_win_is_valid(chat.win) then
    pcall(vim.api.nvim_set_current_win, chat.win)
    return true
  end
  if self.notify then
    self.notify("the leader chat window is not open")
  end
  return false
end

---Open a participant, or close when the same one is already open.
---@param team string
---@param participant string
---@return boolean
function Watch:open(team, participant)
  if participant == "leader" then
    if self.leader_active then
      self.leader_active = false
      self.participant = nil
      return true
    end
    self:focus_leader()
    return true
  end
  if self.participant == participant and self.team_id == team and self:is_open() then
    self:close()
    return true
  end
  self:switch(team, participant)
  return true
end

---@param team string
---@param participant string
function Watch:switch(team, participant)
  self:destroy_view()
  -- Release any current watch first: unwatch is idempotent and may clear the
  -- participant through `on_watch(nil)`, so the new target is set afterwards.
  self.team:unwatch()
  self.participant, self.team_id, self.title = participant, team, nil
  self.replayed = true
  self.supplement, self.supplement_for = nil, nil
  self.collapsed = {}
  self.expanded = {}
  self.turn_times = {}
  self.leader_active = false
  self.generation = self.generation + 1
  local generation = self.generation
  self.team:watch(team, participant, true, function(ok, value)
    if generation ~= self.generation then
      -- The request was superseded or the view was closed while it was in
      -- flight; its late failure must not clear the current watch.
      return
    end
    if not ok then
      if self.notify then
        local message = type(value) == "table" and (value.message or value.code) or tostring(value)
        self.notify(tostring(message))
      end
      self.participant, self.team_id = nil, nil
      self:changed()
    end
  end)
  self:changed()
end

function Watch:close()
  self:destroy_view()
  -- Idempotent and unconditional: a switch may have cleared `participant`
  -- through `on_watch(nil)` while its new request is still in flight.
  self.team:unwatch()
  self.participant, self.team_id, self.title = nil, nil, nil
  self.leader_active = false
  self:changed()
end

M.Watch = Watch
M.build_session = build_session
M.parse_bus = parse_bus
M.split_role = split_role
M.bus_tool = bus_tool

return M
