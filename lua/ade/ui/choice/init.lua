-- The inline choice component (W0 v2, draft 8).
--
-- It borrows the chat composer window with its own buffer, so the person's
-- draft, undo history, attachments and images stay untouched. The buffer keeps
-- filetype `ade_input` for edgy; `b:ade_choice` tells ade.nvim's composer,
-- completion, submit and attachment code to stay out of the way.
local layout = require("ade.layout")

local M = {}
local View = {}
View.__index = View

---@param opts {notify: fun(message: string, level: integer|nil)|nil}
---@return table
function M.new(opts)
  return setmetatable({ notify = opts.notify or function() end }, View)
end

local function dispose_cmp(buf)
  local ok, cmp = pcall(require, "cmp")
  if ok and type(cmp) == "table" and type(cmp.setup) == "table" and type(cmp.setup.buffer) == "function" then
    pcall(cmp.setup.buffer, { enabled = false })
  end
  _ = buf
end

---@param text string
---@return string[]
local function split_lines(text)
  return vim.split(tostring(text or ""), "\n", { plain = true })
end

function View:notify_message(message, level)
  pcall(self.notify, message, level)
end

function View:answer(index)
  return self.answers[index] or { selected = {}, text = nil, skipped = false }
end

function View:answered(index)
  local answer = self:answer(index)
  return answer.skipped or #answer.selected > 0 or (answer.text ~= nil and answer.text ~= "")
end

---@param question table
---@return table[]
function View:options(question)
  local options = {}
  for _, option in ipairs(question.options or {}) do
    options[#options + 1] = option
  end
  if question.free_text then
    options[#options + 1] = { label = "输入…", custom = true }
  elseif question.allow_custom then
    options[#options + 1] = { label = "其他（自己输入）…", custom = true }
  end
  return options
end

function View:line_list()
  local model = self.model
  local lines = {}
  local maps = { options = {} }
  local title = tostring(model.title or "需要选择")
  if model.status and model.status ~= "" then
    title = title .. "    " .. tostring(model.status)
  end
  lines[#lines + 1] = " " .. title
  local tabs = {}
  for index, question in ipairs(model.questions or {}) do
    local header = tostring(question.header or ("Q" .. index))
    if self.tab == index then
      tabs[#tabs + 1] = "[" .. header .. "]"
    else
      tabs[#tabs + 1] = " " .. header .. " "
    end
  end
  tabs[#tabs + 1] = self.tab == #(model.questions or {}) + 1 and "[提交]" or " 提交 "
  lines[#lines + 1] = " " .. table.concat(tabs, "  ")
  lines[#lines + 1] = ""
  local count = #(model.questions or {})
  if self.tab <= count then
    local question = model.questions[self.tab]
    for _, line in ipairs(split_lines(question.question)) do
      lines[#lines + 1] = " " .. line
    end
    lines[#lines + 1] = ""
    local options = self:options(question)
    local answer = self:answer(self.tab)
    for index, option in ipairs(options) do
      local marker = self.cursor == index and "❯" or " "
      local selected
      if question.multi_select then
        local picked = false
        for _, label in ipairs(answer.selected) do
          if label == option.label then
            picked = true
            break
          end
        end
        selected = picked and "☒" or "☐"
      else
        selected = ""
      end
      local description = option.description and ("    " .. tostring(option.description)) or ""
      local line = string.format(" %s %s %d. %s%s", marker, selected, index, tostring(option.label), description)
      lines[#lines + 1] = line
      maps.options[#lines] = index
    end
    if self.custom then
      maps.custom_line = self.custom_line
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = " Tab 切换 · ↑↓/jk 选择 · 1-9 直接选 · Space 多选 · Enter 确认 · Esc 稍后"
  else
    lines[#lines + 1] = " 提交前确认："
    lines[#lines + 1] = ""
    for index, question in ipairs(model.questions or {}) do
      local answer = self:answer(index)
      local text
      if answer.skipped then
        text = "（跳过）"
      elseif #answer.selected > 0 then
        text = table.concat(answer.selected, ", ")
        if answer.text and answer.text ~= "" then
          text = text .. " / " .. answer.text
        end
      elseif answer.text and answer.text ~= "" then
        text = answer.text
      else
        text = "（未答）"
      end
      lines[#lines + 1] = string.format(" %d. %s: %s", index, tostring(question.header or "Q"), text)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = " Enter 提交 · Tab 返回 · Esc 稍后"
  end
  return lines, maps
end

function View:render()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local lines, maps = self:line_list()
  self.maps = maps
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local line = 1
    if self.maps.options then
      for index, option_index in pairs(self.maps.options) do
        if option_index == self.cursor then
          line = index
          break
        end
      end
    end
    pcall(vim.api.nvim_win_set_cursor, self.win, { math.max(1, line), 0 })
  end
end

function View:advance()
  local count = #(self.model.questions or {})
  if self.tab <= count then
    self.tab = self.tab + 1
    if self.tab > count then
      self.tab = count + 1
    end
    self.cursor = 1
  end
  self:render()
end

function View:begin_custom(line)
  if not line then
    return
  end
  local answer = self:answer(self.tab)
  self.custom = true
  self.custom_line = line
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, line - 1, line, false, { " 其他: " })
  vim.api.nvim_win_set_cursor(self.win, { line, #" 其他: " })
  vim.cmd("startinsert!")
  vim.keymap.set("i", "<CR>", function()
    local text = vim.api.nvim_get_current_line():gsub("^%s*其他:%s*", "")
    self.custom = false
    vim.cmd("stopinsert")
    vim.bo[self.buf].modifiable = false
    if text == "" then
      self:render()
      return
    end
    answer.text = text
    self:advance()
  end, { buffer = self.buf, nowait = true })
  vim.keymap.set("i", "<Esc>", function()
    self.custom = false
    vim.cmd("stopinsert")
    vim.bo[self.buf].modifiable = false
    self:render()
  end, { buffer = self.buf, nowait = true })
end

function View:select(index)
  if self.custom then
    return
  end
  local question = self.model.questions[self.tab]
  if not question then
    return
  end
  local options = self:options(question)
  local option = options[index]
  if not option then
    return
  end
  local answer = self:answer(self.tab)
  if option.custom then
    local line
    for line_index, option_index in pairs(self.maps.options or {}) do
      if option_index == index then
        line = line_index
      end
    end
    self:begin_custom(line)
    return
  end
  if option.skip then
    answer.skipped = true
    answer.selected = {}
    answer.text = nil
    self:advance()
    return
  end
  if question.multi_select then
    local next_selected = {}
    local removed = false
    for _, label in ipairs(answer.selected) do
      if label == option.label then
        removed = true
      else
        next_selected[#next_selected + 1] = label
      end
    end
    if not removed then
      next_selected[#next_selected + 1] = option.label
    end
    answer.selected = next_selected
    answer.text = nil
    answer.skipped = false
    self:render()
  else
    answer.selected = { option.label }
    answer.text = nil
    answer.skipped = false
    self:advance()
  end
end

function View:toggle()
  local question = self.model.questions[self.tab]
  if question and question.multi_select then
    self:select(self.cursor)
  elseif question then
    self:select(self.cursor)
  end
end

function View:submit()
  local first_missing
  for index = 1, #(self.model.questions or {}) do
    if not self:answered(index) then
      first_missing = first_missing or index
    end
  end
  if first_missing then
    self.tab = first_missing
    self.cursor = 1
    self:render()
    self:notify_message("回答第 " .. first_missing .. " 题后再提交", vim.log.levels.WARN)
    return
  end
  local answers = {}
  for index = 1, #(self.model.questions or {}) do
    local answer = self:answer(index)
    answers[index] = {
      selected = vim.deepcopy(answer.selected),
      text = answer.text,
      skipped = answer.skipped,
    }
  end
  local on_submit = self.model.on_submit
  self:close()
  if on_submit then
    pcall(on_submit, answers)
  end
end

function View:cancel()
  local on_cancel = self.model and self.model.on_cancel
  self:close()
  if on_cancel then
    pcall(on_cancel)
  end
end

function View:details()
  if self.model and self.model.on_details then
    pcall(self.model.on_details)
  end
end

function View:keys()
  local opts = { buffer = self.buf, nowait = true, silent = true }
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, opts)
  end
  map("<Tab>", function()
    local count = #(self.model.questions or {})
    self.tab = self.tab % (count + 1) + 1
    self.cursor = 1
    self:render()
  end)
  map("<S-Tab>", function()
    local count = #(self.model.questions or {})
    self.tab = (self.tab - 2) % (count + 1) + 1
    self.cursor = 1
    self:render()
  end)
  for _, key in ipairs({ "<Right>", "l" }) do
    map(key, function()
      local count = #(self.model.questions or {})
      self.tab = self.tab % (count + 1) + 1
      self.cursor = 1
      self:render()
    end)
    map(key == "<Right>" and "<Left>" or "h", function()
      local count = #(self.model.questions or {})
      self.tab = (self.tab - 2) % (count + 1) + 1
      self.cursor = 1
      self:render()
    end)
  end
  map("<Down>", function()
    local count = #self:options(self.model.questions[self.tab] or {})
    if count > 0 then
      self.cursor = self.cursor % count + 1
      self:render()
    end
  end)
  map("j", function()
    local count = #self:options(self.model.questions[self.tab] or {})
    if count > 0 then
      self.cursor = self.cursor % count + 1
      self:render()
    end
  end)
  map("<Up>", function()
    local count = #self:options(self.model.questions[self.tab] or {})
    if count > 0 then
      self.cursor = (self.cursor - 2) % count + 1
      self:render()
    end
  end)
  map("k", function()
    local count = #self:options(self.model.questions[self.tab] or {})
    if count > 0 then
      self.cursor = (self.cursor - 2) % count + 1
      self:render()
    end
  end)
  for index = 1, 9 do
    map(tostring(index), function()
      if self.tab <= #(self.model.questions or {}) then
        self:select(index)
      end
    end)
  end
  map("<Space>", function()
    self:toggle()
  end)
  map("<CR>", function()
    if self.custom then
      return
    end
    if self.tab > #(self.model.questions or {}) then
      self:submit()
      return
    end
    local question = self.model.questions[self.tab]
    local options = self:options(question)
    local option = options[self.cursor]
    if option and option.custom then
      self:select(self.cursor)
      return
    end
    if question and question.multi_select then
      self:advance()
      return
    end
    self:select(self.cursor)
  end)
  map("<Esc>", function()
    self:cancel()
  end)
  map("d", function()
    self:details()
  end)
end

---@param model table
---@param mount {win: integer, external: boolean|nil, max_height: integer|nil}
---@return boolean shown
function View:show(model, mount)
  self:close()
  local win = mount and mount.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  self.model = model
  self.answers = {}
  for index = 1, #(model.questions or {}) do
    self.answers[index] = { selected = {}, text = nil, skipped = false }
  end
  self.tab = 1
  self.cursor = 1
  self.custom = false
  self.win = win
  self.original_buf = vim.api.nvim_win_get_buf(win)
  self.saved_winbar = vim.api.nvim_get_option_value("winbar", { win = win })
  self.saved_wrap = vim.api.nvim_get_option_value("wrap", { win = win })
  self.saved_height = vim.api.nvim_win_get_height(win)
  self.external = mount.external == true
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "ade_input"
  vim.bo[self.buf].buflisted = false
  vim.bo[self.buf].modifiable = false
  vim.b[self.buf].ade_choice = true
  vim.b[self.buf].completion = false
  dispose_cmp(self.buf)
  pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
  local ok = layout.set_window_buffer(win, self.buf)
  if not ok then
    self:close()
    return false
  end
  pcall(vim.api.nvim_set_option_value, "wrap", true, { win = win })
  self:keys()
  self:render()
  local lines = vim.api.nvim_buf_line_count(self.buf)
  if not self.external then
    local max = mount.max_height or math.max(4, math.floor((vim.o.lines - 2) / 2))
    pcall(vim.api.nvim_win_set_height, win, math.max(3, math.min(lines, max)))
  end
  return true
end

function View:close()
  local win = self.win
  local buf = self.buf
  self.win, self.buf = nil, nil
  self.model, self.answers, self.custom = nil, nil, false
  if win and vim.api.nvim_win_is_valid(win) then
    if self.original_buf and vim.api.nvim_buf_is_valid(self.original_buf) then
      layout.set_window_buffer(win, self.original_buf)
    end
    if self.saved_winbar ~= nil then
      pcall(vim.api.nvim_set_option_value, "winbar", self.saved_winbar, { win = win })
    end
    if self.saved_wrap ~= nil then
      pcall(vim.api.nvim_set_option_value, "wrap", self.saved_wrap, { win = win })
    end
    if not self.external and self.saved_height then
      pcall(vim.api.nvim_win_set_height, win, self.saved_height)
    end
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  self.original_buf, self.saved_winbar, self.saved_height = nil, nil, nil
end

function View:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

M.View = View

return M
