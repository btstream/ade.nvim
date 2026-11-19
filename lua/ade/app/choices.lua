-- The queue behind the inline choice component (W0 v2, draft 5/8).
--
-- Sources are the team inbox (questions with options, spawn requests,
-- worker permissions, turn limits) and ACP requests (the agent's own
-- permission and elicitation). ACP requests come first because the agent is
-- blocked on them. A question without options never enters the component: it
-- only notifies and is answered with `:Ade team answer <name>`.
local Choice = require("ade.ui.choice")
local schema = require("ade.elicitation_schema")

local M = {}
local Choices = {}
Choices.__index = Choices

---@param opts table
---@return table
function M.new(opts)
  return setmetatable({
    deps = opts,
    view = Choice.new({ notify = opts.notify }),
    current = nil,
    signature = nil,
    notified = {},
    -- Keys the person put off with Esc, answered with "hold", or whose answer
    -- is in flight. They stay pending but are not shown until asked for.
    deferred = {},
    handled = {},
    answering = {},
    auto_answer = {},
    auto_failed = {},
    notified_native = {},
  }, Choices)
end

function Choices:status_fn(team_id)
  return function()
    local counts = self:pending_counts(team_id)
    local total = counts.question + counts.approval
    return total > 1 and ("还有 " .. (total - 1) .. " 个待处理") or nil
  end
end

function Choices:defer(key)
  if key then
    self.deferred[key] = true
  end
end

function Choices:team()
  local ok, team = pcall(self.deps.team)
  return ok and team or nil
end

---Open inbox items live in `team.inbox`, keyed by id (rows keep the snapshot
---without a live inbox array).
---@param team table
---@param team_id string|nil
---@return table[]
function Choices:items(team, team_id)
  local out = {}
  if type(team.inbox) == "table" then
    for _, item in pairs(team.inbox) do
      if not team_id or item.team == team_id then
        out[#out + 1] = item
      end
    end
  else
    -- Test doubles and older callers keep items on each row.
    for _, row in ipairs(team:list_rows()) do
      if not team_id or row.id == team_id then
        for _, item in ipairs(row.inbox or {}) do
          item.team = item.team or row.id
          out[#out + 1] = item
        end
      end
    end
  end
  table.sort(out, function(a, b)
    local aa, bb = tostring(a.at or ""), tostring(b.at or "")
    if aa == bb then
      return tostring(a.id) < tostring(b.id)
    end
    return aa < bb
  end)
  return out
end

---A question item is selectable if any of its questions offers options; a
---mixed item still shows the free-text question as an input row in the
---component (B5).
---@param item table
---@return boolean
local function item_has_options(item)
  if type(item.questions) == "table" then
    for _, question in ipairs(item.questions) do
      if type(question.options) == "table" and #question.options > 0 then
        return true
      end
    end
  end
  -- A legacy top-level `options` list is answered with `vim.ui.input`
  -- (`answer_participant`); the component only renders `questions`.
  return false
end

function Choices:interactions()
  local ok, interactions = pcall(self.deps.interactions)
  return ok and interactions or nil
end

function Choices:notify(message, level)
  pcall(self.deps.notify, message, level)
end

function Choices:mount()
  local chat = self.deps.chat_win and self.deps.chat_win() or nil
  if not chat or not vim.api.nvim_win_is_valid(chat) then
    return nil
  end
  local input_win = self.deps.input_win
  local input = input_win and input_win() or nil
  return {
    win = chat,
    focus_wins = { chat, input },
    return_win = function()
      local target = input_win and input_win() or nil
      if target and vim.api.nvim_win_is_valid(target) then
        return target
      end
      return chat
    end,
    reserve = self.deps.reserve,
    focus_hint = self.deps.focus_hint and self.deps.focus_hint() or nil,
    on_detach = function()
      self:refresh()
    end,
  }
end

---Move the cursor into the card, showing the next pending item first when
---nothing is on screen.
function Choices:focus()
  if not self.view:is_open() then
    self:show_pending(nil)
  end
  return self.view:focus()
end

function Choices:visible()
  return self.deps.panel_visible and self.deps.panel_visible() or false
end

-- -- pending model ----------------------------------------------------------

local function option(label, value, extra)
  return vim.tbl_extend("force", { label = label, value = value }, extra or {})
end

function Choices:question_model(team, item, pending)
  local questions = {}
  if type(item.questions) == "table" and #item.questions > 0 then
    for index, question in ipairs(item.questions) do
      local options = {}
      for _, entry in ipairs(question.options or {}) do
        options[#options + 1] = option(entry.label, entry.label, { description = entry.description })
      end
      questions[#questions + 1] = {
        header = question.header or ("Q" .. index),
        question = question.question or item.body or "",
        options = options,
        multi_select = question.multi_select == true,
        allow_custom = true,
      }
    end
  else
    questions[1] = {
      header = "Question",
      question = item.body or "",
      options = {},
      allow_custom = true,
    }
  end
  local who = tostring(item.from or "worker")
  local entry = self:participant(team, item.team, item.from)
  if entry and entry.label and entry.label ~= "" then
    who = who .. "（" .. tostring(entry.label) .. "）"
  end
  return {
    title = who .. " 提问 · team " .. tostring(item.team),
    status_fn = self:status_fn(item.team),
    questions = questions,
    on_cancel = function()
      self:refresh()
    end,
    on_submit = function(answers)
      self:answer_question(team, item, questions, answers)
    end,
  }
end

function Choices:answer_question(team, item, questions, answers)
  local payload = {}
  for index, answer in ipairs(answers or {}) do
    local selected = answer.selected or {}
    local text = answer.text
    if answer.skipped then
      selected, text = {}, nil
    end
    payload[index] = { selected = vim.deepcopy(selected), text = text }
  end
  team:answer(item.id, { answers = payload }, function(ok, value)
    if not ok then
      self:notify("cannot answer the question: " .. tostring(value and value.message or value), vim.log.levels.WARN)
    end
    self:refresh()
  end)
  self:refresh()
end

function Choices:spawn_model(team, item, pending)
  local group = item.group
  local in_group = 0
  if group then
    for _, other in ipairs(self:items(team)) do
      if other.state == "open" and other.group == group and other.kind == "spawn" then
        in_group = in_group + 1
      end
    end
  end
  local details = {
    "模板 " .. tostring(item.template or "?"),
    "agent " .. tostring(item.agent or "?"),
  }
  if item.model then
    details[#details + 1] = "模型 " .. tostring(item.model)
  end
  if item.label then
    details[#details + 1] = "label " .. tostring(item.label)
  end
  if item.role and item.role ~= "" then
    details[#details + 1] = "角色 " .. tostring(item.role)
  end
  local options = {
    option("批准", "allow"),
    option("拒绝", "reject"),
  }
  if in_group > 1 then
    options[#options + 1] = option("全部批准（" .. in_group .. " 个）", "allow_group")
  end
  return {
    title = "启动 worker " .. tostring(item.name or "?") .. " · team " .. tostring(item.team),
    status_fn = self:status_fn(item.team),
    questions = {
      {
        header = "Spawn",
        question = table.concat(details, " · "),
        options = options,
      },
    },
    on_cancel = function()
      self:refresh()
    end,
    on_submit = function(answers)
      local answer = answers[1] or {}
      local index = (answer.selected_index or {})[1]
      local picked = index and options[index]
      local choice = picked and picked.value or answer.selected[1]
      if choice == "allow_group" then
        team:answer_group(group, true, function(ok, value)
          if not ok then
            self:notify("cannot approve the group: " .. tostring(value and value.message or value), vim.log.levels.WARN)
          end
          self:refresh()
        end)
        self:refresh()
        return
      end
      local allow = choice == "allow"
      team:answer(item.id, { allow = allow }, function(ok, value)
        if not ok then
          self:notify(
            "cannot answer the spawn request: " .. tostring(value and value.message or value),
            vim.log.levels.WARN
          )
        end
        self:refresh()
      end)
      self:refresh()
    end,
  }
end

function Choices:team_permission_model(team, item, pending)
  local options = {}
  local ids = {}
  for _, entry in ipairs(item.options or {}) do
    local label = tostring(entry.name or entry.optionId or "?")
    options[#options + 1] = option(label, entry.optionId, { description = entry.kind })
    ids[label] = entry.optionId
  end
  if #options == 0 then
    options[1] = option("取消请求", "cancel")
    ids["取消请求"] = nil
  else
    options[#options + 1] = option("取消请求", "cancel")
  end
  return {
    title = "worker " .. tostring(item.from or "?") .. " 请求权限 · team " .. tostring(item.team),
    status_fn = self:status_fn(item.team),
    submit_single = true,
    questions = { { header = "Permission", question = item.body or "Permission required", options = options } },
    on_cancel = function()
      -- Esc is "later" for team items, including a worker permission.
      self:refresh()
    end,
    on_submit = function(answers)
      local answer = answers[1] or {}
      local index = (answer.selected_index or {})[1]
      local entry = index and (item.options or {})[index]
      local label = answer.selected[1]
      team:answer(item.id, { option = entry and entry.optionId or (label and ids[label]) or nil }, function()
        self:refresh()
      end)
    end,
  }
end

function Choices:limit_model(team, item, pending)
  return {
    title = "回合上限 · " .. tostring(item.from or "team"),
    status_fn = self:status_fn(item.team),
    questions = {
      {
        header = "Limit",
        question = item.body or "Turn limit reached",
        options = { option("继续（重置计数）", "continue"), option("保持暂停", "hold") },
      },
    },
    on_cancel = function()
      self:refresh()
    end,
    on_submit = function(answers)
      local answer = answers[1] or {}
      local index = (answer.selected_index or {})[1]
      local options = { { value = "continue" }, { value = "hold" } }
      local choice = answer.selected[1]
      if index and options[index] then
        choice = options[index].value
      end
      if choice == "continue" then
        team:reset_limits(item.team, function()
          self:refresh()
        end)
      else
        -- "Keep paused" is an answer for the purposes of the queue.
        self.handled["team:" .. item.team .. ":" .. item.id] = true
        self:refresh()
      end
    end,
  }
end

function Choices:participant(team, team_id, name)
  local row = team and team:team(team_id)
  for _, entry in ipairs(row and row.participants or {}) do
    if entry.name == name then
      return entry
    end
  end
end

---Open team items and their models, newest sources first by priority.
function Choices:team_entries(team_id)
  local team = self:team()
  if not team then
    return {}
  end
  local open = {}
  local question_count = 0
  local approval_count = 0
  for _, item in ipairs(self:items(team, team_id)) do
    if item.state == "open" then
      if item.kind == "question" then
        question_count = question_count + 1
        if item_has_options(item) then
          open[#open + 1] = {
            key = "team:" .. item.team .. ":" .. item.id,
            kind = "question",
            team = item.team,
            item = item,
            build = function(self_, pending)
              return self_:question_model(team, item, pending)
            end,
          }
        end
      elseif item.kind == "spawn" then
        approval_count = approval_count + 1
        open[#open + 1] = {
          key = "team:" .. item.team .. ":" .. item.id,
          kind = "approval",
          team = item.team,
          item = item,
          build = function(self_, pending)
            return self_:spawn_model(team, item, pending)
          end,
        }
      elseif item.kind == "permission" then
        approval_count = approval_count + 1
        if #(item.options or {}) == 0 then
          -- A worker permission without options cannot be shown; answer it
          -- with the cancelled outcome as the old picker did.
          local key = "team:" .. item.team .. ":" .. item.id
          if not self.auto_answer[key] and not self.auto_failed[key] then
            self.auto_answer[key] = true
            team:answer(item.id, {}, function(ok, value)
              self.auto_answer[key] = nil
              if not ok then
                self.auto_failed[key] = true
                self:notify(
                  "cannot cancel the worker permission: "
                    .. tostring(value and value.message or value)
                    .. "（:Ade team answer 重试）",
                  vim.log.levels.WARN
                )
              end
              self:refresh()
            end)
          end
        else
          open[#open + 1] = {
            key = "team:" .. item.team .. ":" .. item.id,
            kind = "approval",
            team = item.team,
            item = item,
            build = function(self_, pending)
              return self_:team_permission_model(team, item, pending)
            end,
          }
        end
      elseif item.kind == "limit" then
        approval_count = approval_count + 1
        open[#open + 1] = {
          key = "team:" .. item.team .. ":" .. item.id,
          kind = "approval",
          team = item.team,
          item = item,
          build = function(self_, pending)
            return self_:limit_model(team, item, pending)
          end,
        }
      end
    end
  end
  table.sort(open, function(left, right)
    local function key(entry)
      local number = tonumber(tostring(entry.team):match("^t(%d+)$"))
      return number or 0, entry.key
    end
    local ln, lk = key(left)
    local rn, rk = key(right)
    if ln ~= rn then
      return ln < rn
    end
    return lk < rk
  end)
  return open, question_count, approval_count
end

---Pending counts for the dashboard (worker1's interface).
---@param team_id string|nil
---@return {question: integer, approval: integer}
function Choices:pending_counts(team_id)
  local _, questions, approvals = self:team_entries(team_id)
  local interactions = self:interactions()
  if interactions then
    for _, interaction in ipairs(interactions.order or {}) do
      if interaction.state == "pending" then
        if interaction.type == "elicitation" then
          questions = questions + 1
        else
          approvals = approvals + 1
        end
      end
    end
  end
  return { question = questions, approval = approvals }
end

---How many pending entries the inline component can actually show.
---Free-text questions are answered with `vim.ui.input`, not selected here.
---@param team_id string|nil
---@return integer
function Choices:selectable_count(team_id)
  local open = self:team_entries(team_id)
  local count = #open
  local interactions = self:interactions()
  if interactions then
    count = count + #interactions:pending()
  end
  return count
end

function Choices:update_notice(open, interactions)
  local keys = {}
  for _, entry in ipairs(open) do
    keys[#keys + 1] = entry.key
  end
  for _, interaction in ipairs(interactions and interactions.order or {}) do
    if interaction.state == "pending" then
      keys[#keys + 1] = "acp:" .. interaction.id
    end
  end
  table.sort(keys)
  local signature = table.concat(keys, "\n")
  if signature ~= self.signature then
    self.signature = signature
    local team_id = open[1] and open[1].team or nil
    vim.api.nvim_exec_autocmds("User", {
      pattern = "AdeChoicesChanged",
      data = { team = team_id },
    })
  end
  if #open == 0 or self:visible() then
    return
  end
  local key = signature
  if not self.notified[key] then
    self.notified[key] = true
    self:notify("有 " .. #open .. " 个需要选择；:Ade team answer 或 :Ade open", vim.log.levels.INFO)
  end
end

function Choices:show(entry, open)
  local model = entry.build(self, #open)
  if not model then
    return false
  end
  local cancel = model.on_cancel
  model.on_cancel = function()
    self.current = nil
    self:defer(entry.key)
    if cancel then
      pcall(cancel)
    end
    self:refresh()
  end
  local submit = model.on_submit
  model.on_submit = function(answers)
    self.current = nil
    self.answering[entry.key] = true
    vim.defer_fn(function()
      self.answering[entry.key] = nil
      self:refresh()
    end, 2000)
    if submit then
      pcall(submit, answers)
    end
    self:refresh()
  end
  local mount = self:mount()
  if not mount then
    return false
  end
  self.current = entry
  if not self.view:show(model, mount) then
    self.current = nil
    return false
  end
  return true
end

function Choices:dismiss_fallback(replacing)
  self.replacing = replacing == true
  if self.deps.permission_dismiss then
    pcall(self.deps.permission_dismiss)
  end
  if self.deps.elicitation_dismiss then
    pcall(self.deps.elicitation_dismiss)
  end
  self.replacing = false
end

---Whether the fallback picker can be closed from Lua without answering. The
---default `vim.ui.select` prompt cannot; replacing it would leave a stale
---prompt on screen next to the component.
function Choices:fallback_closable()
  local config = self.deps.config and self.deps.config() or {}
  return (config.ui or {}).picker == "internal"
end

---Take the card off screen without answering (the panel went away). An ACP
---request it was showing goes back to the queue so the fallback can show it.
---@param interactions table|nil
function Choices:drop_current(interactions)
  if not self.view:is_open() then
    return
  end
  local current = self.current
  self.view:close()
  self.current = nil
  if current and current.kind == "acp" and interactions then
    interactions:unshow(current.interaction and current.interaction.id or nil)
  end
end

---Recompute the queue and show the next item when possible.
function Choices:refresh()
  local open = self:team_entries(nil)
  -- A team that closed takes its pending choices with it, including the one
  -- currently on screen (a local close may arrive before `team.changed`).
  local team_model = self:team()
  if self.current and self.current.team and team_model and not team_model:team(self.current.team) then
    if self.view:is_open() then
      self.view:close()
    end
    self.current = nil
  end
  local interactions = self:interactions()
  local acp_pending = interactions and #interactions:pending() > 0 or false
  local keys = {}
  for _, entry in ipairs(open) do
    keys[entry.key] = true
  end
  for _, set in ipairs({ self.deferred, self.handled, self.answering }) do
    for key in pairs(set) do
      if not keys[key] then
        set[key] = nil
      end
    end
  end
  local showable = {}
  for _, entry in ipairs(open) do
    if not self.deferred[entry.key] and not self.handled[entry.key] and not self.answering[entry.key] then
      showable[#showable + 1] = entry
    end
  end
  self:update_notice(open, interactions)
  if interactions then
    local pending = {}
    for _, interaction in ipairs(interactions:pending()) do
      pending[interaction.id] = true
    end
    for id in pairs(self.notified_native) do
      if not pending[id] then
        self.notified_native[id] = nil
      end
    end
  end

  if self.current and not self.view:is_open() then
    if self.current.kind == "acp" and interactions then
      interactions:unshow(self.current.id)
    end
    self.current = nil
  end
  local mount = self:mount()
  local visible = self:visible() and mount ~= nil
  if acp_pending then
    local permissions = (self.deps.config and self.deps.config() or {}).permissions or {}
    if permissions.prompt ~= "select" then
      -- `show_next` only presents the first pending request; native requests
      -- deserve one notification each without blocking the team queue.
      for _, interaction in ipairs(interactions:pending()) do
        if interaction.type == "permission" then
          self:present_interaction(interaction)
        end
      end
    end
    if self.current and self.current.kind ~= "acp" then
      self.view:close()
      self.current = nil
    end
    if visible then
      if interactions.shown and not self.view:is_open() then
        -- A fallback picker was shown while the panel was hidden. Replace it
        -- only when it can be closed without answering; the default
        -- vim.ui.select prompt cannot and stays until the person answers.
        if not self:fallback_closable() then
          return
        end
        self:dismiss_fallback(true)
        interactions:unshow(interactions.shown)
      end
      if not self.view:is_open() then
        interactions:show_next()
      end
      if interactions.shown or self.view:is_open() then
        return
      end
    else
      self:drop_current(interactions)
      -- No chat window: keep the old picker/form so the agent is not blocked.
      -- Never call show_next again while it is already on screen: its floats
      -- fire WinNew/BufWinEnter and would make refresh loop.
      if not interactions.shown then
        interactions:show_next()
      end
      return
    end
  end
  if not visible then
    self:drop_current(interactions)
    return
  end
  if self.current and self.view:is_open() then
    return
  end
  if vim.fn.mode():sub(1, 1) == "i" or vim.fn.getcmdwintype() ~= "" then
    return
  end
  if showable[1] then
    self:show(showable[1], open)
  end
end

---Force the queue on screen (the `:Ade team answer` command).
---@param team_id string|nil
function Choices:show_pending(team_id)
  local open = self:team_entries(team_id)
  local interactions = self:interactions()
  if not self:visible() then
    local count = #open
    for _, entry in ipairs(open) do
      if self.handled[entry.key] then
        count = count - 1
      end
    end
    if interactions then
      count = count + #interactions:pending()
    end
    if count == 0 then
      self:notify("没有待处理的提问或申请", vim.log.levels.INFO)
    else
      self:notify("有 " .. count .. " 个需要选择；先打开面板（:Ade open）", vim.log.levels.INFO)
    end
    return
  end
  pcall(vim.cmd, "stopinsert")
  -- Explicitly asking for the queue clears everything put off with Esc and
  -- retries permissions whose automatic cancel failed.
  self.deferred = {}
  self.auto_failed = {}
  self:refresh()
  if self.view:is_open() then
    return
  end
  if interactions and #interactions:pending() > 0 then
    if interactions.shown then
      if not self:fallback_closable() then
        self:notify("请在已经打开的选择框里回答", vim.log.levels.INFO)
        return
      end
      self:dismiss_fallback(true)
      interactions:unshow(interactions.shown)
    end
    interactions:show_next()
    if self.view:is_open() then
      return
    end
  end
  local first
  for _, entry in ipairs(open) do
    if not self.handled[entry.key] then
      first = entry
      break
    end
  end
  if first then
    self.current = nil
    self:show(first, open)
    if not self.view:is_open() then
      self:notify("先打开聊天窗口（:Ade open）再显示选择组件", vim.log.levels.INFO)
    end
    return
  end
  local free = 0
  local team = self:team()
  for _, row in ipairs(team and self:items(team, team_id) or {}) do
    if row.state == "open" and row.kind == "question" and not item_has_options(row) then
      free = free + 1
    end
  end
  if free > 0 then
    self:notify(
      "有 " .. free .. " 个提问需要输入；在成员上按 a 或 :Ade team answer <name>",
      vim.log.levels.INFO
    )
  else
    self:notify("没有待处理的提问或申请", vim.log.levels.INFO)
  end
end

---Answer a question without options with the composer input.
---@param team_id string
---@param name string
function Choices:answer_participant(team_id, name)
  local team = self:team()
  local free, option_entry
  for _, entry in ipairs(team and self:items(team, team_id) or {}) do
    if entry.state == "open" and entry.kind == "question" and entry.from == name then
      if item_has_options(entry) then
        option_entry = option_entry or entry
      else
        free = free or entry
      end
    end
  end
  if option_entry then
    local open = self:team_entries(team_id)
    for _, candidate in ipairs(open) do
      if candidate.item == option_entry then
        self:show(candidate, open)
        if not self:is_open() then
          self:notify("先打开聊天窗口（:Ade open）再显示选择组件", vim.log.levels.INFO)
        end
        return
      end
    end
  end
  if free then
    vim.ui.input({ prompt = (free.body or "answer") .. ": " }, function(text)
      if text == nil then
        return
      end
      team:answer(free.id, { text = text }, function(ok, value)
        if not ok then
          self:notify("cannot answer: " .. tostring(value and value.message or value), vim.log.levels.WARN)
        end
        self:refresh()
      end)
    end)
    return
  end
  if #self:team_entries(team_id) > 0 then
    self:show_pending(team_id)
    return
  end
  self:notify("没有来自 " .. tostring(name) .. " 的待回答提问", vim.log.levels.INFO)
end

-- -- ACP requests -----------------------------------------------------------

function Choices:permission_model(interaction)
  local request = interaction.request or {}
  local options = {}
  for _, entry in ipairs(request.options or {}) do
    options[#options + 1] =
      option(tostring(entry.name or entry.optionId or "?"), entry.optionId, { description = entry.kind })
  end
  if #options == 0 then
    return nil
  end
  local tool = request.toolCall or request.tool_call or {}
  local title = "权限请求: " .. tostring(tool.title or tool.kind or "agent")
  return {
    title = title,
    questions = {
      { header = "Permission", question = tostring(tool.title or "Permission required"), options = options },
    },
    on_details = function()
      if self.deps.permission_details then
        pcall(self.deps.permission_details, interaction)
      end
    end,
    on_submit = function(answers)
      local answer = answers[1] or {}
      local index = (answer.selected_index or {})[1]
      local option_id = index and (request.options or {})[index] and request.options[index].optionId
      if not option_id then
        for _, entry in ipairs(request.options or {}) do
          if entry.name == answer.selected[1] then
            option_id = entry.optionId
          end
        end
      end
      self:answer_acp(interaction, { outcome = { outcome = "selected", optionId = option_id } })
    end,
    on_cancel = function()
      self:cancel_acp(interaction)
    end,
  }
end

function Choices:elicitation_model(interaction)
  local request = interaction.request or {}
  local parsed = schema.parse(request.requestedSchema)
  if not parsed then
    return nil
  end
  local fields = parsed.fields
  local questions = {}
  local initial = {}
  for index, field in ipairs(fields) do
    local options = {}
    if field.kind == "boolean" then
      options = { option("是", true), option("否", false) }
    elseif field.kind == "choice" or field.kind == "multi" then
      for _, entry in ipairs(field.options) do
        options[#options + 1] = option(entry.label, entry.value, { description = entry.description })
      end
    end
    if not field.required then
      options[#options + 1] = option("跳过", nil, { skip = true })
    end
    questions[index] = {
      header = tostring(field.title or field.key),
      question = tostring(field.description or field.title or field.key),
      options = options,
      multi_select = field.kind == "multi",
      -- "Other" is only offered when the schema has a `<key>_custom` slot.
      allow_custom = field.custom_key ~= nil and (field.kind == "choice" or field.kind == "multi"),
      free_text = field.kind == "text" or field.kind == "number" or field.kind == "integer",
    }
    -- Preselect the schema default exactly as the old form did.
    local default = field.default
    if default ~= nil then
      if field.kind == "boolean" then
        initial[index] = { selected = { default and "是" or "否" } }
      elseif field.kind == "multi" then
        local labels = {}
        local indexes = {}
        for _, value in ipairs(type(default) == "table" and default or {}) do
          for option_index, entry in ipairs(field.options) do
            if entry.value == value then
              labels[#labels + 1] = entry.label
              indexes[#indexes + 1] = option_index
            end
          end
        end
        initial[index] = { selected = labels, selected_index = indexes }
      elseif field.kind == "choice" then
        for option_index, entry in ipairs(field.options) do
          if entry.value == default then
            initial[index] = { selected = { entry.label }, selected_index = { option_index } }
          end
        end
      else
        initial[index] = { text = tostring(default) }
      end
    end
  end
  local model = {
    title = tostring(request.message or "Agent question"),
    questions = questions,
    initial = initial,
  }
  local function values_from(answers)
    local values = {}
    for index, field in ipairs(fields) do
      local answer = answers[index] or {}
      if not answer.skipped then
        if field.kind == "multi" then
          local picked = {}
          for _, option_index in ipairs(answer.selected_index or {}) do
            local entry = field.options[option_index]
            if entry then
              picked[#picked + 1] = entry.value
            end
          end
          if #picked > 0 then
            values[field.key] = picked
          end
          if field.custom_key and answer.text and answer.text ~= "" then
            values[field.custom_key] = answer.text
          end
        elseif field.kind == "choice" then
          local option_index = (answer.selected_index or {})[1]
          local entry = option_index and field.options[option_index]
          if entry then
            values[field.key] = entry.value
          end
          if field.custom_key and answer.text and answer.text ~= "" then
            values[field.custom_key] = answer.text
          end
        elseif field.kind == "boolean" then
          values[field.key] = (answer.selected or {})[1] == "是"
        elseif answer.text ~= nil and answer.text ~= "" then
          values[field.key] = answer.text
        end
      end
    end
    return values
  end
  model.validate = function(answers)
    local ok, content = schema.validate(fields, values_from(answers))
    if ok then
      self.pending_content = content
      return true
    end
    return false, content
  end
  model.on_submit = function()
    local content = self.pending_content
    self.pending_content = nil
    self:answer_acp(interaction, { action = "accept", content = content })
  end
  model.on_cancel = function()
    self.pending_content = nil
    self:answer_acp(interaction, { action = "cancel" })
  end
  return model
end

function Choices:present_interaction(interaction)
  local config = self.deps.config and self.deps.config() or {}
  local permissions = config.permissions or {}
  local mount = self:mount()
  if interaction.type == "permission" and permissions.prompt ~= "select" then
    -- `native` leaves the request to the agent's own UI, as before. Notify
    -- once per interaction, not once per refresh.
    if self.notified_native[interaction.id] then
      return false
    end
    self.notified_native[interaction.id] = true
    if self.deps.permission_present then
      return self.deps.permission_present(interaction)
    end
    return false
  end
  if not self:visible() or not mount then
    -- No chat window to float over (panel hidden). ACP requests are
    -- blocking, so keep the old picker/form as the single-agent fallback.
    if interaction.type == "permission" and self.deps.permission_present then
      return self.deps.permission_present(interaction)
    elseif interaction.type == "elicitation" and self.deps.elicitation_present then
      return self.deps.elicitation_present(interaction)
    end
    self:notify("有 1 个需要选择；:Ade team answer 或 :Ade open", vim.log.levels.INFO)
    return false
  end
  local model
  if interaction.type == "permission" then
    model = self:permission_model(interaction)
    if not model then
      -- The old picker cancelled a permission without options; do the same
      -- instead of leaving the agent (and the queue) blocked.
      self:notify("the agent sent a permission request without options; cancelling it", vim.log.levels.WARN)
      self:cancel_acp(interaction)
      return false
    end
    model.submit_single = true
    if permissions.show_details ~= false and self.deps.permission_details then
      pcall(self.deps.permission_details, interaction)
    end
  elseif interaction.type == "elicitation" then
    local request = interaction.request or {}
    local url = request.url or (request._meta and request._meta.url)
    if request.mode == "url" or url then
      if self.deps.elicitation_present then
        return self.deps.elicitation_present(interaction)
      end
      return false
    end
    model = self:elicitation_model(interaction)
    if not model then
      -- Unsupported schema: decline rather than block the agent.
      self:notify("unsupported elicitation schema", vim.log.levels.WARN)
      self:answer_acp(interaction, { action = "decline" })
      return false
    end
  end
  if not model then
    return false
  end
  model.on_cancel = model.on_cancel or function()
    self:cancel_acp(interaction)
  end
  self.current = { kind = "acp", key = "acp:" .. interaction.id, interaction = interaction }
  return self.view:show(model, mount)
end

function Choices:answer_acp(interaction, response)
  local interactions = self:interactions()
  self.current = nil
  if interactions then
    interactions:answer(interaction.id, response)
  end
  self:refresh()
end

function Choices:cancel_acp(interaction)
  local interactions = self:interactions()
  self.current = nil
  if interactions then
    interactions:cancel(interaction.id, "dismissed")
  end
  self:refresh()
end

function Choices:dismiss()
  self.view:close()
  self.current = nil
  self:dismiss_fallback(false)
  self:refresh()
end

function Choices:is_open()
  return self.view:is_open()
end

M.Choices = Choices

return M
