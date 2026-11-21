-- The composer window: editable buffer, winbar toolbar, per-session drafts.
local log = require("ade.log")
local memory = require("ade.session.memory")
local paste_draft = require("ade.storage.paste_draft")
local image_ns = vim.api.nvim_create_namespace("ade.input.images")
local anchor_ns = vim.api.nvim_create_namespace("ade.input.image_anchor")
local paste_ns = vim.api.nvim_create_namespace("ade.input.pastes")

local M = {}

---@class AdeInputView
---@field buf integer
---@field win integer|nil
---@field attachments table[]
---@field drafts table<string, {text: string|nil, attachments: table[]|nil, pastes: table[]|nil}>
local Input = {}
Input.__index = Input

---@param opts {config: table, on_submit: fun(text: string, attachments: table[]), on_cancel: fun()}
---@return AdeInputView
function M.new(opts)
  local self = setmetatable({
    config = opts.config,
    on_submit = opts.on_submit,
    on_cancel = opts.on_cancel,
    buf = nil,
    win = nil,
    attachments = {},
    image_marks = {},
    paste_marks = {},
    paste_bytes = 0,
    paste_count = 0,
    draft_epoch = 0,
    drafts = {},
    session_key = nil,
    toolbar = "",
    toolbar_running = false,
  }, Input)

  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "ade_input"
  vim.bo[self.buf].buflisted = false
  vim.bo[self.buf].undolevels = 1000
  vim.bo[self.buf].textwidth = 0

  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { "" })
  vim.bo[self.buf].modified = false

  local group = vim.api.nvim_create_augroup("AdeInput" .. self.buf, { clear = true })
  self.augroup = group
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:apply_winbar()
      if vim.api.nvim_get_current_buf() == self.buf then
        vim.cmd("startinsert")
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      vim.cmd("stopinsert")
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = self.buf,
    callback = function()
      self.win = nil
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:sync_images()
    end,
  })
  self:map_token_delete()

  return self
end

---Tear down the composer: drop its buffer and autocmd group.
function Input:destroy()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
  self.win = nil
end

---@return boolean ok
---@return string|nil err observable by the chrome owner; focus events may ignore it
function Input:apply_winbar()
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false, "composer window is not visible"
  end
  local placement = self.config.ui.toolbar.placement
  if placement == "off" then
    return pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
  end
  -- Set once: the expression re-renders on every redraw with the real window
  -- width, so resizes and layout managers can never leave a stale bar behind.
  if vim.api.nvim_get_option_value("winbar", { win = win }) ~= "%{%v:lua.AdeComposerBar()%}" then
    return pcall(vim.api.nvim_set_option_value, "winbar", "%{%v:lua.AdeComposerBar()%}", { win = win })
  end
  return true
end

---@param parts string[]
function Input:set_toolbar(parts)
  self.toolbar = table.concat(parts, "  ")
  self:apply_winbar()
end

---Save the visible buffer into the current draft slot.
function Input:save_draft()
  self:sync_images()
  self:save_image_positions()
  if not self.session_key then
    return
  end
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local preview = self.history
    and self.history.tick == vim.api.nvim_buf_get_changedtick(self.buf)
    and #self.attachments == 0
  local text = preview and "" or table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
  local pastes = self:live_pastes()
  local limit = self.config.memory.max_block_bytes
  local bytes, dirty = 0, false
  for _, item in ipairs(pastes) do
    bytes = bytes + #item.text
    dirty = dirty or item.dirty
  end
  local attachments = self.attachments
  if #pastes > 0 and (dirty or #text + bytes > math.min(limit, paste_draft.max_draft_bytes)) then
    -- Fall back to a plain draft rather than persisting a label whose payload
    -- cannot fit. Translate attachment positions to the unfolded text.
    text, attachments = self:unfold_draft(text, pastes)
    pastes, bytes = {}, 0
  end
  local draft = { text = text, attachments = attachments }
  memory.bound_block(draft, limit - bytes)
  draft.pastes = paste_draft.valid(pastes, vim.split(draft.text or "", "\n", { plain = true }))
  draft.used = vim.uv.hrtime()
  self.drafts[self.draft_slot or self.session_key] = draft
  local keys = vim.tbl_keys(self.drafts)
  if #keys > self.config.memory.max_drafts then
    table.sort(keys, function(a, b)
      return self.drafts[a].used < self.drafts[b].used
    end)
    for i = 1, #keys - self.config.memory.max_drafts do
      self.drafts[keys[i]] = nil
    end
  end
  if self.on_draft then
    self.on_draft(self.session_key, text, attachments, self.draft_owner, #pastes > 0 and pastes or nil)
  end
end

---Switch drafts when the active session changes.
---@param key string|nil
---@param restored {text: string, attachments: table[], pastes: table[]|nil}|nil
function Input:switch_session(key, restored, owner)
  local slot = owner and (owner.cwd .. "\0" .. tostring(key)) or key
  if self.session_key == key and self.draft_slot == slot then
    return
  end
  self:save_draft()
  self.history = nil
  self.draft_epoch = self.draft_epoch + 1
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_clear_namespace(self.buf, anchor_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, image_ns, 0, -1)
  end
  self.image_marks = {}
  self.session_key = key
  self.draft_slot = slot
  self.draft_owner = owner and { id = owner.id or key, cwd = owner.cwd } or nil
  -- Prefer the live draft: the persisted copy is trimmed for size, so using it
  -- while the full attachments are still in memory would send clipped text.
  local draft = (slot and self.drafts[slot]) or restored
  self.attachments = draft and draft.attachments or {}
  local lines = draft and draft.text or { "" }
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    self:replace_draft_lines(lines)
    vim.bo[self.buf].modified = false
  end
  if draft and vim.api.nvim_buf_is_valid(self.buf) then
    for _, item in ipairs(paste_draft.valid(draft.pastes, lines)) do
      self:track_paste(item.row, item.col, item.text)
    end
  end
  self:render_images()
end

---A replaced draft no longer owns the old payloads. Do not let undo resurrect
---their bare labels into this draft.
function Input:replace_draft_lines(lines)
  vim.bo[self.buf].modifiable = true
  local had_pastes = self.paste_count > 0
  local undolevels = vim.bo[self.buf].undolevels
  if had_pastes then
    vim.bo[self.buf].undolevels = -1
  end
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  if had_pastes then
    vim.bo[self.buf].undolevels = undolevels
  end
  vim.api.nvim_buf_clear_namespace(self.buf, paste_ns, 0, -1)
  self.paste_marks, self.paste_bytes, self.paste_count = {}, 0, 0
end

function Input:track_paste(row, col, text)
  local label = paste_draft.label(text)
  local id = vim.api.nvim_buf_set_extmark(self.buf, paste_ns, row, col, {
    end_row = row,
    end_col = col + #label,
    hl_group = "AdeInputPaste",
    right_gravity = true,
    end_right_gravity = false,
    invalidate = true,
    undo_restore = true,
  })
  self.paste_marks[id] = { text = text, input_token = label }
  self.paste_bytes = self.paste_bytes + #text
  self.paste_count = self.paste_count + 1
end

function Input:live_pastes()
  local out = {}
  if self.paste_count == 0 then
    return out
  end
  for _, entry in ipairs(vim.api.nvim_buf_get_extmarks(self.buf, paste_ns, 0, -1, { details = true })) do
    local item, row, col, details = self.paste_marks[entry[1]], entry[2], entry[3], entry[4]
    if item and not details.invalid and (details.end_row > row or details.end_col > col) then
      local current =
        table.concat(vim.api.nvim_buf_get_text(self.buf, row, col, details.end_row, details.end_col, {}), "\n")
      local text, label = item.text, item.input_token
      if current ~= label then
        -- The label is not prompt text. Retain the original and any new text
        -- in the edited portion rather than sending a broken placeholder.
        local first, last = 0, 0
        while first < math.min(#current, #label) and current:byte(first + 1) == label:byte(first + 1) do
          first = first + 1
        end
        while
          last < math.min(#current, #label) - first
          and current:byte(#current - last) == label:byte(#label - last)
        do
          last = last + 1
        end
        text = text .. current:sub(first + 1, #current - last)
      end
      out[#out + 1] = {
        row = row,
        col = col,
        end_row = details.end_row,
        end_col = details.end_col,
        text = text,
        payload_bytes = #item.text,
        dirty = current ~= label,
      }
    end
  end
  return out
end

local function line_offsets(lines)
  local starts, length = {}, 0
  for row, line in ipairs(lines) do
    starts[row] = length
    length = length + #line + 1
  end
  return starts
end

function Input:unfold_draft(raw, pastes)
  local starts = line_offsets(vim.split(raw, "\n", { plain = true }))
  local edits, parts, cursor = {}, {}, 0
  for _, item in ipairs(pastes) do
    local start = starts[item.row + 1] + item.col
    local finish = starts[item.end_row + 1] + item.end_col
    edits[#edits + 1] = { start = start, finish = finish, bytes = #item.text }
    parts[#parts + 1] = raw:sub(cursor + 1, start)
    parts[#parts + 1] = item.text
    cursor = finish
  end
  parts[#parts + 1] = raw:sub(cursor + 1)
  local text = table.concat(parts)
  local new_starts = line_offsets(vim.split(text, "\n", { plain = true }))
  local attachments = {}
  for _, att in ipairs(self.attachments) do
    local pos = att.input_position
    if self.image_marks[att] and pos then
      local original = starts[pos[1] + 1] + pos[2]
      local offset = original
      for _, edit in ipairs(edits) do
        if original < edit.finish then
          break
        end
        offset = offset + edit.bytes - (edit.finish - edit.start)
      end
      local lo, hi = 1, #new_starts
      while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if new_starts[mid] <= offset then
          lo = mid
        else
          hi = mid - 1
        end
      end
      att = vim.tbl_extend("force", att, { input_position = { lo - 1, offset - new_starts[lo] } })
    end
    attachments[#attachments + 1] = att
  end
  return text, attachments
end

---Replace a large paste with an inline label. If retaining the original is
---not possible, let Neovim paste it normally rather than dropping any bytes.
function Input:preview_paste(lines)
  local cfg = self.config.ui.paste_preview
  local mode = vim.api.nvim_get_mode().mode
  if not cfg.enabled or (mode ~= "n" and mode:sub(1, 1) ~= "i") or vim.fn.getcmdtype() ~= "" then
    return false
  end
  if vim.api.nvim_get_current_buf() ~= self.buf or not vim.bo[self.buf].modifiable then
    return false
  end
  local text = table.concat(lines, "\n")
  if
    (#lines < cfg.min_lines and #text < cfg.min_bytes)
    or #text + self.paste_bytes > paste_draft.max_retained_bytes
    or self.paste_count >= paste_draft.max_retained_items
  then
    return false
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  if mode == "n" then
    col = math.max(col, vim.fn.matchend(vim.api.nvim_get_current_line(), ".", col))
  end
  local pastes, bytes = self:live_pastes(), #text
  for _, item in ipairs(pastes) do
    bytes = bytes + item.payload_bytes
    if self:inside_paste(item, row, col) then
      return false
    end
  end
  if #pastes >= paste_draft.max_items or bytes > paste_draft.max_bytes then
    return false
  end
  local label = paste_draft.label(text)
  vim.api.nvim_buf_set_text(self.buf, row, col, row, col, { label })
  self:track_paste(row, col, text)
  vim.api.nvim_win_set_cursor(0, { row + 1, col + #label - (mode == "n" and 1 or 0) })
  return true
end

function Input:inside_paste(item, row, col)
  return (row > item.row or (row == item.row and col > item.col))
    and (row < item.end_row or (row == item.end_row and col < item.end_col))
end

local function token_range(first, last, line, col, backward)
  if col == (backward and last or first) then
    return first, last
  end
  if backward and col == last + 1 and line:sub(col, col) == " " then
    return first, col
  end
end

function Input:deletion_range(row, col, backward)
  local function tracked(ns, items, by_id)
    for item, id in pairs(items) do
      if by_id then
        item, id = id, item
      end
      local mark = vim.api.nvim_buf_get_extmark_by_id(self.buf, ns, id, { details = true })
      local details = mark[3]
      if by_id and details and not details.invalid and (details.end_row > mark[1] or details.end_col > mark[2]) then
        local edge_row, edge_col = mark[1], mark[2]
        if backward then
          edge_row, edge_col = details.end_row, details.end_col
        end
        if row == edge_row and col == edge_col then
          return mark[2], details.end_col, mark[1], details.end_row
        end
      elseif mark[1] == row and self:token_matches(item, mark) then
        local first, last = mark[2], mark[3].end_col
        if col == (backward and last or first) then
          return first, last
        end
      end
    end
  end
  local first, last, start_row, end_row = tracked(image_ns, self.image_marks)
  if not first then
    first, last, start_row, end_row = tracked(paste_ns, self.paste_marks, true)
  end
  if first then
    return first, last, start_row, end_row
  end
  if vim.bo[self.buf].filetype ~= "ade_input" then
    return
  end
  local line = vim.api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1] or ""
  local completion = require("ade.completion")
  local binding = completion.binding(self.buf)
  local session = binding and binding.getter()
  local command = line:match("^/(%S+)")
  if command then
    first, last = token_range(0, #command + 1, line, col, backward)
    if first then
      for _, item in ipairs(session and type(session.commands) == "table" and session.commands or {}) do
        if type(item) == "table" and item.name == command then
          return first, last
        end
      end
    end
  end
  local mentions = require("ade.completion.mentions")
  for _, token in ipairs(mentions.tokens(line)) do
    first, last = token_range(token.first, token.last, line, col, backward)
    if first and mentions.readable_path(token.path, session and session.cwd or self.config.cwd) then
      return first, last
    end
  end
end

function Input:map_token_delete()
  local pending
  local plug = "<Plug>(ade-delete-input-token)"
  vim.keymap.set("i", plug, function()
    local range = pending
    pending = nil
    if range and vim.api.nvim_get_current_buf() == self.buf then
      local row, first, end_row, last = unpack(range)
      vim.api.nvim_buf_set_text(self.buf, row, first, end_row, last, { "" })
      vim.api.nvim_win_set_cursor(0, { row + 1, first })
      self:sync_images()
      if self.on_refresh then
        self.on_refresh()
      end
    end
  end, { buffer = self.buf })
  for key, backward in pairs({ ["<BS>"] = true, ["<Del>"] = false }) do
    vim.keymap.set("i", key, function()
      pending = nil
      if vim.fn.pumvisible() == 0 and vim.bo[self.buf].modifiable then
        local cursor = vim.api.nvim_win_get_cursor(0)
        local row = cursor[1] - 1
        local first, last, start_row, end_row = self:deletion_range(row, cursor[2], backward)
        if first then
          pending = { start_row or row, first, end_row or row, last }
          return "<C-g>u" .. plug .. "<C-g>u"
        end
      end
      return key
    end, { buffer = self.buf, expr = true, desc = "Delete input token or character" })
  end
end

---Recall recent user messages from the selected transcript, without attachments.
---A snapshot keeps navigation stable if more messages arrive while browsing.
---@param direction 1|-1 1 for older, -1 for newer
---@param blocks table[]|nil
---@return boolean handled
function Input:recall(direction, blocks)
  if vim.fn.pumvisible() == 1 or not vim.bo[self.buf].modifiable then
    return false
  end
  local tick = vim.api.nvim_buf_get_changedtick(self.buf)
  local history = self.history
  if history and (history.tick ~= tick or #self.attachments > 0) then
    self.history, history = nil, nil
  end
  if not history then
    local limit = self.config.ui.input_history_limit
    if direction < 0 or limit == 0 or not blocks or #self.attachments > 0 then
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(self.buf, 0, 2, false)
    if #lines ~= 1 or lines[1] ~= "" then
      return false
    end
    local items = {}
    for i = #blocks, 1, -1 do
      local block = blocks[i]
      if block.kind == "user" and not block.generated_prompt and block.text and block.text:find("%S") then
        items[#items + 1] = block.text
        if #items >= limit then
          break
        end
      end
    end
    if #items == 0 then
      return false
    end
    history = { items = items, index = 0 }
  end

  local index = math.min(history.index + direction, #history.items)
  if index == history.index then
    return true
  end
  local lines = vim.split(history.items[index] or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == self.buf then
    vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  end
  history.index = index
  history.tick = vim.api.nvim_buf_get_changedtick(self.buf)
  self.history = index > 0 and history or nil
  return true
end

---@return string
function Input:text()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  self:sync_images()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local starts = line_offsets(lines)
  local raw = table.concat(lines, "\n")
  local edits, parts, cursor, offset, order = {}, {}, 0, 0, 0
  for _, item in ipairs(self:live_pastes()) do
    local start = starts[item.row + 1] + item.col
    edits[#edits + 1] = { start = start, finish = starts[item.end_row + 1] + item.end_col, text = item.text }
  end
  local marks = vim.api.nvim_buf_get_extmarks(self.buf, image_ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    for att, id in pairs(self.image_marks) do
      if id == mark[1] and self:token_matches(att, { mark[2], mark[3], mark[4] }) then
        local start = starts[mark[2] + 1] + mark[3]
        local finish = starts[mark[2] + 1] + mark[4].end_col
        edits[#edits + 1] = { start = start, finish = finish, attachment = att }
      end
    end
  end
  table.sort(edits, function(a, b)
    return a.start < b.start
  end)
  for _, edit in ipairs(edits) do
    local prefix = raw:sub(cursor + 1, edit.start)
    parts[#parts + 1] = prefix
    offset = offset + #prefix
    if edit.attachment then
      order = order + 1
      edit.attachment.prompt_offset = offset
      edit.attachment.prompt_order = order
    else
      parts[#parts + 1] = edit.text
      offset = offset + #edit.text
    end
    cursor = edit.finish
  end
  parts[#parts + 1] = raw:sub(cursor + 1)
  return table.concat(parts)
end

function Input:clear()
  self.history = nil
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self:replace_draft_lines({ "" })
  self.attachments = {}
  vim.api.nvim_buf_clear_namespace(self.buf, image_ns, 0, -1)
  self.image_marks = {}
  self.draft_epoch = self.draft_epoch + 1
  vim.api.nvim_buf_clear_namespace(self.buf, anchor_ns, 0, -1)
  self:render_images()
  if self.session_key then
    self.drafts[self.draft_slot or self.session_key] = nil
    if self.on_draft then
      self.on_draft(self.session_key, "", {}, self.draft_owner)
    end
  end
end

---Clear the originating draft without touching a newly selected composer.
function Input:discard_draft(owner)
  self.drafts[owner.cwd .. "\0" .. owner.id] = nil
  self.drafts[owner.id] = nil -- compatibility for callers without explicit owners
  if self.on_draft then
    self.on_draft(owner.id, "", {}, owner)
  end
end

function Input:restore(text)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self:replace_draft_lines(vim.split(text, "\n", { plain = true }))
end

---@param attachment {kind: string, label: string, path?: string, uri?: string, text?: string}
function Input:add_attachment(attachment, position)
  self:sync_images()
  if attachment.kind == "image" or attachment.kind == "selection" then
    attachment.input_position = position or self:cursor_position()
    for _, item in ipairs(self:live_pastes()) do
      if self:inside_paste(item, unpack(attachment.input_position)) then
        attachment.input_position = { item.end_row, item.end_col }
        break
      end
    end
  end
  if attachment.kind == "selection" and not attachment.input_token then
    attachment.input_token = "[" .. (attachment.label or "selection") .. "]"
  end
  for i, existing in ipairs(self.attachments) do
    if existing.kind == attachment.kind and existing.path == attachment.path and existing.uri == attachment.uri then
      if existing.kind == "image" or existing.kind == "selection" then
        return false -- Keeping the existing token avoids an orphan.
      end
      self.attachments[i] = attachment
      self:refresh()
      return false
    end
  end
  self.attachments[#self.attachments + 1] = attachment
  self:refresh()
  return true
end

---@param index integer
function Input:remove_attachment(index)
  local att = self.attachments[index]
  local id = att and self.image_marks[att]
  if id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(self.buf, image_ns, id, { details = true })
    self.image_marks[att] = nil
    vim.api.nvim_buf_del_extmark(self.buf, image_ns, id)
    if self:token_matches(att, mark) then
      vim.api.nvim_buf_set_text(self.buf, mark[1], mark[2], mark[3].end_row, mark[3].end_col, { "" })
    end
  end
  table.remove(self.attachments, index)
  self:refresh()
end

function Input:clear_attachments()
  for i = #self.attachments, 1, -1 do
    self:remove_attachment(i)
  end
  vim.api.nvim_buf_clear_namespace(self.buf, image_ns, 0, -1)
  self.image_marks = {}
  self.attachments = {}
  self:refresh()
end

function Input:refresh()
  self:render_images()
  if self.on_refresh then
    self.on_refresh()
  end
end

-- Highlighted buffer tokens are editable; only tracked tokens are stripped
-- from prompt text. Identical text typed by the user stays ordinary text.
function Input:cursor_position()
  if self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_buf(self.win) == self.buf then
    local p = vim.api.nvim_win_get_cursor(self.win)
    return { p[1] - 1, p[2] }
  end
  return { 0, 0 }
end

function Input:image_anchor()
  local p = self:cursor_position()
  return vim.api.nvim_buf_set_extmark(self.buf, anchor_ns, p[1], p[2], {})
end

function Input:take_image_anchor(id)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return nil
  end
  local p = vim.api.nvim_buf_get_extmark_by_id(self.buf, anchor_ns, id, {})
  vim.api.nvim_buf_del_extmark(self.buf, anchor_ns, id)
  return #p == 2 and p or nil
end

function Input:save_image_positions()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  for attachment, id in pairs(self.image_marks) do
    local p = vim.api.nvim_buf_get_extmark_by_id(self.buf, image_ns, id, {})
    if #p == 2 then
      attachment.input_position = p
    end
  end
end

function Input:token_matches(att, mark)
  if not att.input_token or #mark == 0 then
    return false
  end
  local d = mark[3]
  if not d or d.invalid or d.end_row ~= mark[1] then
    return false
  end
  local text = vim.api.nvim_buf_get_text(self.buf, mark[1], mark[2], d.end_row, d.end_col, {})
  return table.concat(text, "\n") == att.input_token
end

function Input:sync_images()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local attachments, images = {}, {}
  for _, att in ipairs(self.attachments) do
    if (att.kind ~= "image" and att.kind ~= "selection") or not self.image_marks[att] then
      attachments[#attachments + 1] = att
    end
  end
  for att, id in pairs(self.image_marks) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(self.buf, image_ns, id, { details = true })
    if self:token_matches(att, mark) then
      images[#images + 1] = { att = att, id = id }
    end
  end
  table.sort(images, function(a, b)
    return a.id < b.id
  end)
  for _, entry in ipairs(images) do
    attachments[#attachments + 1] = entry.att
  end
  self.attachments = attachments
end

function Input:render_images()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self:save_image_positions()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local function coordinate(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge and math.max(0, math.floor(value))
      or 0
  end
  local image_index = 0
  for att in pairs(self.image_marks) do
    if att.kind == "image" then
      image_index = math.max(image_index, tonumber((att.input_token or ""):match("%d+")) or 0)
    end
  end
  for _, att in ipairs(self.attachments) do
    if (att.kind == "image" or att.kind == "selection") and not self.image_marks[att] then
      local p = type(att.input_position) == "table" and att.input_position or {}
      local row = math.min(coordinate(p[1]), #lines - 1)
      local col = math.min(coordinate(p[2]), #lines[row + 1])
      while
        col > 0
        and col < #lines[row + 1]
        and lines[row + 1]:byte(col + 1) >= 128
        and lines[row + 1]:byte(col + 1) < 192
      do
        col = col - 1 -- clamp restored positions to a UTF-8 boundary
      end
      if att.kind == "image" then
        image_index = image_index + 1
      end
      local label = att.input_token or string.format("[Image %d]", image_index)
      local current = vim.api.nvim_buf_get_text(self.buf, row, col, row, math.min(col + #label, #lines[row + 1]), {})[1]
      if not att.input_token or current ~= label then
        vim.api.nvim_buf_set_text(self.buf, row, col, row, col, { label })
        if self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_get_current_win() == self.win then
          local cursor = vim.api.nvim_win_get_cursor(self.win)
          if cursor[1] == row + 1 and cursor[2] == col then
            vim.api.nvim_win_set_cursor(self.win, { row + 1, col + #label })
          end
        end
        lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
      end
      att.input_token = label
      self.image_marks[att] = vim.api.nvim_buf_set_extmark(self.buf, image_ns, row, col, {
        end_row = row,
        end_col = col + #label,
        hl_group = "AdeInputImage",
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
        undo_restore = true,
      })
    end
  end
end

function Input:submit()
  local text = self:text()
  if text:match("^%s*$") and #self.attachments == 0 then
    return
  end
  if self.on_submit then
    self.on_submit(text, self.attachments)
  end
end

function Input:cancel()
  if self.on_cancel then
    self.on_cancel()
  end
end

---Resize the composer window within configured bounds.
---@param delta integer
function Input:resize(delta)
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local height = vim.api.nvim_win_get_height(win)
  local target =
    math.max(self.config.layout.min_input_height, math.min(self.config.layout.max_input_height, height + delta))
  if target == height then
    return
  end
  local ok = pcall(vim.api.nvim_win_set_height, win, target)
  if not ok then
    log.debug("input resize failed")
  end
end

function Input:is_visible()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

return M
