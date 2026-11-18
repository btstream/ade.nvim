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
  }, Choices)
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

function Choices:interactions()
  local ok, interactions = pcall(self.deps.interactions)
  return ok and interactions or nil
end

function Choices:notify(message, level)
  pcall(self.deps.notify, message, level)
end

function Choices:mount()
  local win = self.deps.input_win and self.deps.input_win() or nil
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local chat = self.deps.chat_win and self.deps.chat_win() or nil
  local max_height
  if chat and vim.api.nvim_win_is_valid(chat) then
    max_height = math.max(4, math.floor(vim.api.nvim_win_get_height(chat) / 2))
  end
  return {
    win = win,
    external = self.deps.external and self.deps.external() or false,
    max_height = max_height,
  }
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
    status = pending > 1 and ("还有 " .. (pending - 1) .. " 个待处理") or nil,
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
  _ = questions
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
    status = pending > 1 and ("还有 " .. (pending - 1) .. " 个待处理") or nil,
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
      local choice = answers[1] and answers[1].selected[1]
      if choice and choice:find("全部批准", 1, true) then
        team:answer_group(group, true, function(ok, value)
          if not ok then
            self:notify("cannot approve the group: " .. tostring(value and value.message or value), vim.log.levels.WARN)
          end
          self:refresh()
        end)
        self:refresh()
        return
      end
      local allow = choice == "批准"
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
    return nil
  end
  return {
    title = "worker " .. tostring(item.from or "?") .. " 请求权限 · team " .. tostring(item.team),
    status = pending > 1 and ("还有 " .. (pending - 1) .. " 个待处理") or nil,
    questions = { { header = "Permission", question = item.body or "Permission required", options = options } },
    on_cancel = function()
      team:answer(item.id, {}, function()
        self:refresh()
      end)
    end,
    on_submit = function(answers)
      local label = answers[1] and answers[1].selected[1]
      team:answer(item.id, { option = label and ids[label] or nil }, function()
        self:refresh()
      end)
    end,
  }
end

function Choices:limit_model(team, item, pending)
  return {
    title = "回合上限 · " .. tostring(item.from or "team"),
    status = pending > 1 and ("还有 " .. (pending - 1) .. " 个待处理") or nil,
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
      local choice = answers[1] and answers[1].selected[1]
      if choice == "继续（重置计数）" then
        team:reset_limits(item.team, function()
          self:refresh()
        end)
      else
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
        local has_options = type(item.questions) == "table" and #item.questions > 0
        if has_options then
          local any = false
          for _, question in ipairs(item.questions) do
            if type(question.options) == "table" and #question.options > 0 then
              any = true
            end
          end
          if any then
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
        open[#open + 1] = {
          key = "team:" .. item.team .. ":" .. item.id,
          kind = "approval",
          team = item.team,
          item = item,
          build = function(self_, pending)
            return self_:team_permission_model(team, item, pending)
          end,
        }
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
    if cancel then
      pcall(cancel)
    end
    self:refresh()
  end
  local submit = model.on_submit
  model.on_submit = function(answers)
    self.current = nil
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

---Recompute the queue and show the next item when possible.
function Choices:refresh()
  local team = self:team()
  local open = self:team_entries(nil)
  local interactions = self:interactions()
  local acp_pending = interactions and #interactions:pending() > 0 or false
  self:update_notice(open, interactions)
  if self.current and not self.view:is_open() then
    self.current = nil
  end

  if self.current and self.current.kind ~= "acp" then
    local still = false
    for _, entry in ipairs(open) do
      if entry.key == self.current.key then
        still = true
        break
      end
    end
    if not still then
      self.view:close()
      self.current = nil
    end
  end
  if acp_pending then
    if self.current and self.current.kind == "team" then
      self.view:close()
      self.current = nil
    end
    if self:visible() and not (interactions.shown and self.view:is_open()) then
      interactions:show_next()
    end
    return
  end
  if self.current then
    return
  end
  if not self:visible() or vim.fn.mode():sub(1, 1) == "i" or vim.fn.getcmdwintype() ~= "" then
    return
  end
  if #open > 0 then
    self:show(open[1], open)
  end
end

---Force the queue on screen (the `:Ade team answer` command).
---@param team_id string|nil
function Choices:show_pending(team_id)
  if not self:visible() then
    local count = 0
    local open = self:team_entries(team_id)
    count = #open
    local interactions = self:interactions()
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
  local interactions = self:interactions()
  if interactions and #interactions:pending() > 0 then
    interactions:show_next()
    if self.view:is_open() then
      return
    end
  end
  self.current = nil
  local open = self:team_entries(team_id)
  if #open == 0 then
    local free = 0
    local team = self:team()
    for _, row in ipairs(team and self:items(team, team_id) or {}) do
      if row.state == "open" and row.kind == "question" then
        local first = type(row.questions) == "table" and row.questions[1] or nil
        if not (first and type(first.options) == "table" and #first.options > 0) then
          free = free + 1
        end
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
    return
  end
  self:show(open[1], open)
end

---Answer a question without options with the composer input.
---@param team_id string
---@param name string
function Choices:answer_participant(team_id, name)
  local team = self:team()
  local free, option_entry
  for _, entry in ipairs(team and self:items(team, team_id) or {}) do
    if entry.state == "open" and entry.kind == "question" and entry.from == name then
      local first = type(entry.questions) == "table" and entry.questions[1] or nil
      local has_options = first and type(first.options) == "table" and #first.options > 0
      if has_options then
        option_entry = option_entry or entry
      else
        free = free or entry
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
      local label = answers[1] and answers[1].selected[1]
      local option_id
      for _, entry in ipairs(options) do
        if entry.label == label then
          option_id = entry.value
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
  local mapping = {}
  for index, field in ipairs(fields) do
    local options = {}
    if field.kind == "boolean" then
      options = { option("是", true), option("否", false) }
    elseif field.kind == "choice" then
      for _, entry in ipairs(field.options) do
        options[#options + 1] = option(entry.label, entry.value, { description = entry.description })
      end
    elseif field.kind == "multi" then
      for _, entry in ipairs(field.options) do
        options[#options + 1] = option(entry.label, entry.value, { description = entry.description })
      end
    end
    if not field.required then
      options[#options + 1] = option("跳过", nil, { skip = true })
    end
    questions[#questions + 1] = {
      header = tostring(field.title or field.key),
      question = tostring(field.description or field.title or field.key),
      options = options,
      multi_select = field.kind == "multi",
      allow_custom = field.kind == "choice" or field.kind == "multi",
      free_text = field.kind == "text" or field.kind == "number" or field.kind == "integer",
    }
    mapping[index] = field
  end
  return {
    title = tostring(request.message or "Agent question"),
    questions = questions,
    on_submit = function(answers)
      local values = {}
      for index, field in ipairs(fields) do
        local answer = answers[index] or {}
        if not answer.skipped then
          if field.kind == "multi" then
            local picked = {}
            for _, label in ipairs(answer.selected) do
              for _, entry in ipairs(field.options) do
                if entry.label == label then
                  picked[#picked + 1] = entry.value
                end
              end
            end
            if answer.text and answer.text ~= "" then
              if field.custom_key then
                values[field.custom_key] = answer.text
              end
            elseif #picked > 0 then
              values[field.key] = picked
            end
          elseif field.kind == "choice" then
            local value = answer.selected[1]
            if value ~= nil then
              for _, entry in ipairs(field.options) do
                if entry.label == value then
                  values[field.key] = entry.value
                end
              end
            end
            if answer.text and answer.text ~= "" then
              if field.custom_key then
                values[field.custom_key] = answer.text
              else
                values[field.key] = answer.text
              end
            end
          elseif field.kind == "boolean" then
            values[field.key] = answer.selected[1] == "是"
          elseif answer.text and answer.text ~= "" then
            if field.kind == "number" or field.kind == "integer" then
              values[field.key] = tonumber(answer.text) or answer.text
            else
              values[field.key] = answer.text
            end
          end
        end
      end
      local problem = schema.validate(fields, values)
      if problem then
        self:notify("form: " .. problem, vim.log.levels.WARN)
        self.current = nil
        self:present_interaction(interaction)
        return
      end
      self:answer_acp(interaction, { action = "accept", content = values })
    end,
    on_cancel = function()
      self:answer_acp(interaction, { action = "cancel" })
    end,
  }
end

function Choices:present_interaction(interaction)
  local mount = self:mount()
  if not self:visible() or not mount then
    -- No composer to borrow (panel hidden or no window). ACP requests are
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
  self:refresh()
end

function Choices:is_open()
  return self.view:is_open()
end

M.Choices = Choices

return M
