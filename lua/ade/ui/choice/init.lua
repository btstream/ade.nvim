-- The inline choice component (W0 v2, draft 8).
--
-- A card floating over the bottom of the chat window, with its own buffer: the
-- composer and its draft stay untouched and visible. The card is as tall as its
-- wrapped content (capped to part of the chat window) and follows every
-- re-render, so switching questions or typing a custom answer resizes it. The
-- chat transcript reserves the same number of rows below its last line, so the
-- card never hides the latest output. `b:ade_choice` marks the card buffer.
local M = {}
local Icons = require("ade.ui.icons")
local ns = vim.api.nvim_create_namespace("ade_choice")
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
    vim.api.nvim_buf_call(buf, function()
      pcall(cmp.setup.buffer, { enabled = false })
    end)
  end
end

---@param text string
---@return string[]
local function split_lines(text)
  return vim.split(tostring(text or ""), "\n", { plain = true })
end

local function paint(buf, row, first, last, group)
  if last > first then
    vim.api.nvim_buf_set_extmark(buf, ns, row, first, {
      end_col = last,
      hl_group = group,
      end_right_gravity = false,
    })
  end
end

function View:notify_message(message, level)
  pcall(self.notify, message, level)
end

function View:answer(index)
  return self.answers[index] or { selected = {}, selected_index = {}, text = nil, skipped = false }
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
  local marks = {}
  local function add(parts)
    local row, col, text = #lines, 0, {}
    for i, part in ipairs(parts) do
      local piece = tostring(part[1]):gsub("[\r\n]", " ")
      text[i] = piece
      if part[2] then
        marks[#marks + 1] = { row, col, col + #piece, part[2] }
      end
      col = col + #piece
    end
    lines[row + 1] = table.concat(text)
  end
  local function hint(keys)
    local parts = { { " " } }
    for i, pair in ipairs(keys) do
      parts[#parts + 1] = { i == 1 and "" or " · ", "AdeChoiceMuted" }
      parts[#parts + 1] = { pair[1], "AdeChoiceHint" }
      parts[#parts + 1] = { " " .. pair[2], "AdeChoiceMuted" }
    end
    add(parts)
  end
  local title = tostring(model.title or "需要选择")
  local status = model.status_fn and model.status_fn() or model.status
  local count = #(model.questions or {})
  add({
    { " " .. title, "AdeChoiceTitle" },
    { status and status ~= "" and ("    " .. tostring(status)) or "", "AdeChoiceMuted" },
    { string.format("    %d/%d", self.tab, count + 1), "AdeChoiceMuted" },
  })
  local tabs = { { " " } }
  for index, question in ipairs(model.questions or {}) do
    local header = tostring(question.header or ("Q" .. index))
    local active, answered = self.tab == index, self:answered(index)
    local group = active and "AdeChoiceTabActive" or "AdeChoiceTab"
    tabs[#tabs + 1] = { active and "[" or " ", group }
    tabs[#tabs + 1] = {
      Icons.glyph(answered and "choice_checked" or "choice_unchecked"),
      answered and "AdeChoiceSelected" or group,
    }
    tabs[#tabs + 1] = { " " .. header .. (active and "]" or " "), group }
    tabs[#tabs + 1] = { "  " }
  end
  local submit = self.tab == count + 1
  tabs[#tabs + 1] = { submit and "[提交]" or " 提交 ", submit and "AdeChoiceTabActive" or "AdeChoiceTab" }
  add(tabs)
  lines[#lines + 1] = ""
  if self.tab <= count then
    local question = model.questions[self.tab]
    local question_lines = split_lines(question.question)
    if not self.expanded and #question_lines > 8 then
      question_lines = vim.list_slice(question_lines, 1, 6)
      question_lines[#question_lines + 1] = " …（K 展开）"
    end
    for _, line in ipairs(question_lines) do
      add({ { " " .. line, "AdeChoiceQuestion" } })
    end
    lines[#lines + 1] = ""
    local options = self:options(question)
    local answer = self:answer(self.tab)
    for index, option in ipairs(options) do
      local active = not self.custom and self.cursor == index
      local marker = active and Icons.glyph("choice_cursor") or " "
      local picked = not answer.skipped and vim.tbl_contains(answer.selected_index or {}, index)
      local selected = question.multi_select and Icons.glyph(picked and "choice_checked" or "choice_unchecked") or ""
      local description = option.description and ("    " .. tostring(option.description)) or ""
      add({
        { " " .. marker, "AdeChoiceOptionActive" },
        { " " .. selected, picked and "AdeChoiceSelected" or "AdeChoiceMuted" },
        { string.format(" %d. ", index), active and "AdeChoiceOptionActive" or "AdeChoiceMuted" },
        { tostring(option.label), active and "AdeChoiceOptionActive" or (picked and "AdeChoiceSelected" or nil) },
        { description, "AdeChoiceMuted" },
      })
      maps.options[#lines] = index
      if active then
        maps.focus_line = #lines
      end
    end
    if self.custom then
      maps.custom_line = self.custom_line
    end
    lines[#lines + 1] = ""
    hint({
      { "Tab", "切换" },
      { "↑↓/jk", "选择" },
      { "1-9", "直接选" },
      { "Space", "多选" },
      { "Enter", "确认" },
      { "Esc", "稍后" },
    })
  else
    add({ { " 提交前确认：", "AdeChoiceQuestion" } })
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
      add({
        { string.format(" %d. %s: ", index, tostring(question.header or "Q")), "AdeChoiceQuestion" },
        { text, not answer.skipped and self:answered(index) and "AdeChoiceSelected" or "AdeChoiceMuted" },
      })
    end
    lines[#lines + 1] = ""
    hint({ { "Enter", "提交" }, { "Tab", "返回" }, { "Esc", "稍后" } })
  end
  return lines, maps, marks
end

function View:render()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local lines, maps, marks = self:line_list()
  self.maps = maps
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  if maps.focus_line then
    vim.api.nvim_buf_set_extmark(self.buf, ns, maps.focus_line - 1, 0, { line_hl_group = "AdeChoiceFocus" })
  end
  for _, mark in ipairs(marks) do
    paint(self.buf, unpack(mark))
  end
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
  self:resize()
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
  local question = self.model.questions[self.tab] or {}
  if not question.multi_select then
    answer.selected = {}
    answer.selected_index = {}
  end
  self.custom = true
  self.custom_line = line
  -- Repaint before replacing the editable row so a direct numeric selection
  -- cannot leave an arrow or focus background on another option.
  self:render()
  vim.bo[self.buf].modifiable = true
  local prompt = " 其他: "
  vim.api.nvim_buf_clear_namespace(self.buf, ns, line - 1, line)
  vim.api.nvim_buf_set_lines(self.buf, line - 1, line, false, { prompt })
  paint(self.buf, line - 1, 0, #prompt, "AdeChoiceCustom")
  vim.api.nvim_win_set_cursor(self.win, { line, #prompt })
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
    local next_index = {}
    local removed = false
    for _, index_value in ipairs(answer.selected_index or {}) do
      if index_value == index then
        removed = true
      else
        next_index[#next_index + 1] = index_value
        local label = options[index_value] and options[index_value].label
        if label then
          next_selected[#next_selected + 1] = label
        end
      end
    end
    if not removed then
      next_index[#next_index + 1] = index
      next_selected[#next_selected + 1] = option.label
    end
    answer.selected = next_selected
    answer.selected_index = next_index
    answer.text = nil
    answer.skipped = false
    self:render()
  else
    answer.selected = { option.label }
    answer.selected_index = { index }
    answer.text = nil
    answer.skipped = false
    if self.model.submit_single and #(self.model.questions or {}) == 1 then
      self:submit()
    else
      self:advance()
    end
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
      selected_index = vim.deepcopy(answer.selected_index or {}),
      text = answer.text,
      skipped = answer.skipped,
    }
  end
  if self.model.validate then
    local ok, problem = self.model.validate(answers)
    if not ok then
      self:notify_message(tostring(problem or "invalid answer"), vim.log.levels.WARN)
      return
    end
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
  -- Habitual insert keys must not start an insert session in a read-only
  -- choice buffer (E21) or cancel the request with the first Esc.
  for _, key in ipairs({ "i", "a", "o", "I", "A", "O", "x", "X", "p", "P", "s", "S", "u", "<C-r>" }) do
    map(key, function() end)
  end
  map("K", function()
    self.expanded = not self.expanded
    self:render()
  end)
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---Fit the card to its content: full chat width, bottom-aligned, as tall as the
---wrapped text up to `max_ratio` of the chat window. Scrolls past that.
function View:resize()
  local host, win = self.host, self.win
  if not valid_win(host) or not valid_win(win) then
    return
  end
  local host_height = vim.api.nvim_win_get_height(host)
  local function place(height)
    pcall(vim.api.nvim_win_set_config, win, {
      relative = "win",
      win = host,
      anchor = "SW",
      row = host_height,
      col = 0,
      width = math.max(10, vim.api.nvim_win_get_width(host) - 2),
      height = height,
    })
  end
  -- Width first: the wrapped height depends on it.
  place(vim.api.nvim_win_get_height(win))
  local height = vim.api.nvim_buf_line_count(self.buf)
  local ok, info = pcall(vim.api.nvim_win_text_height, win, { start_row = 0, end_row = -1 })
  if ok and type(info) == "table" and type(info.all) == "number" then
    height = info.all
  end
  -- Two rows of border; keep a few transcript rows visible above.
  local max = math.max(1, math.min(math.floor(host_height * self.max_ratio) - 2, host_height - 3))
  height = math.max(1, math.min(height, max))
  place(height)
  if self.reserve then
    pcall(self.reserve, math.min(height + 2, host_height))
  end
end

---Move the cursor into the card.
---@return boolean focused
function View:focus()
  if not valid_win(self.win) then
    return false
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    pcall(vim.cmd, "stopinsert")
  end
  return pcall(vim.api.nvim_set_current_win, self.win)
end

---@param model table
---@param mount {win: integer, focus_wins: integer[]|nil, return_win: (fun(): integer|nil)|nil,
---  reserve: fun(rows: integer)|nil, max_ratio: number|nil, focus_hint: string|nil,
---  on_detach: fun()|nil} `on_detach` runs when the card goes without an answer
---  because its chat window closed or someone closed the card itself.
---@return boolean shown
function View:show(model, mount)
  self:close()
  local host = mount and mount.win
  if not valid_win(host) then
    return false
  end
  self.model = model
  self.answers = {}
  for index = 1, #(model.questions or {}) do
    local initial = model.initial and model.initial[index] or {}
    self.answers[index] = {
      selected = vim.deepcopy(initial.selected or {}),
      selected_index = vim.deepcopy(initial.selected_index or {}),
      text = initial.text,
      skipped = initial.skipped == true,
    }
  end
  self.tab = 1
  self.cursor = 1
  self.custom = false
  self.expanded = false
  self.host = host
  self.reserve = mount.reserve
  self.return_win = mount.return_win
  self.on_detach = mount.on_detach
  self.max_ratio = mount.max_ratio or 0.6
  local current = vim.api.nvim_get_current_win()
  local enter = current == host
  for _, focus_win in ipairs(mount.focus_wins or {}) do
    if focus_win == current then
      enter = true
    end
  end
  if enter and vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    pcall(vim.cmd, "stopinsert")
  end
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "ade_choice"
  vim.bo[self.buf].buflisted = false
  vim.bo[self.buf].modifiable = false
  vim.b[self.buf].ade_choice = true
  vim.b[self.buf].completion = false
  dispose_cmp(self.buf)
  local ok, win = pcall(vim.api.nvim_open_win, self.buf, enter, {
    relative = "win",
    win = host,
    anchor = "SW",
    row = vim.api.nvim_win_get_height(host),
    col = 0,
    width = math.max(10, vim.api.nvim_win_get_width(host) - 2),
    height = 1,
    style = "minimal",
    border = "rounded",
    zindex = 45,
  })
  if not ok then
    self:close()
    return false
  end
  self.win = win
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight =
    "Normal:AdeChoiceNormal,NormalNC:AdeChoiceNormal,FloatBorder:AdeChoiceBorder,FloatTitle:AdeChoiceTitle"
  self:keys()
  if not enter then
    local now = vim.uv.now()
    if not self.focus_notice_at or now - self.focus_notice_at > 5000 then
      self.focus_notice_at = now
      local hint = mount.focus_hint and ("在聊天窗口按 " .. mount.focus_hint .. " 进入，") or ""
      self:notify_message("需要你的选择：" .. hint .. "或 :Ade team answer", vim.log.levels.INFO)
    end
  end
  local group = vim.api.nvim_create_augroup("AdeChoiceCard" .. self.buf, { clear = true })
  self.augroup = group
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = self.buf,
    callback = function()
      if self.custom then
        local text = ""
        if self.custom_line and self.custom_line <= vim.api.nvim_buf_line_count(self.buf) then
          text = vim.api.nvim_buf_get_lines(self.buf, self.custom_line - 1, self.custom_line, false)[1] or ""
          text = text:gsub("^%s*其他:%s*", "")
        end
        if text ~= "" then
          self:answer(self.tab).text = text
        end
        self.custom = false
        vim.bo[self.buf].modifiable = false
        self:render()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        self:resize()
      end)
    end,
  })
  -- The card has no life of its own: when the chat window goes (panel hidden)
  -- or someone closes the card with :q, drop it without answering. The queue
  -- notices on its next refresh and shows the item again later.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed == self.host or closed == self.win then
        vim.schedule(function()
          if self.host == host then
            local on_detach = self.on_detach
            self:close()
            if on_detach then
              pcall(on_detach)
            end
          end
        end)
      end
    end,
  })
  self:render()
  return true
end

function View:close()
  local win, buf, group = self.win, self.buf, self.augroup
  local had_focus = valid_win(win) and vim.api.nvim_get_current_win() == win
  local reserve, return_win = self.reserve, self.return_win
  self.win, self.buf, self.augroup, self.host = nil, nil, nil, nil
  self.model, self.answers, self.custom = nil, nil, false
  self.reserve, self.return_win, self.on_detach = nil, nil, nil
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  if had_focus and vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    pcall(vim.cmd, "stopinsert")
  end
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if reserve then
    pcall(reserve, 0)
  end
  if had_focus and return_win then
    local target = return_win()
    if valid_win(target) then
      pcall(vim.api.nvim_set_current_win, target)
    end
  end
end

function View:is_open()
  return valid_win(self.win)
end

M.View = View

return M
