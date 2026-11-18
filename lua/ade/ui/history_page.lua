-- A contiguous materialised range into the existing Session, not another model.
local M = {}
local Page = {}
Page.__index = Page

local function cost(block)
  return block._bytes or (type(block.text) == "string" and #block.text or 0)
end

function M.new(cfg)
  return setmetatable({ cfg = cfg }, Page)
end

---@return integer stop, string|nil continuation
local function edge(blocks, start, direction, cfg)
  local stop, bytes = start, 0
  for i = start, direction < 0 and 1 or #blocks, direction do
    local size = cost(blocks[i])
    if math.abs(i - start) >= cfg.page_blocks or (bytes > 0 and bytes + size > cfg.page_bytes) then
      break
    end
    stop, bytes = i, bytes + size
  end
  if direction >= 0 or not cfg.turn_start then
    return stop, nil
  end
  -- Optional turn alignment (the watch view only). Backtrack at most one
  -- extra page of blocks/bytes; a very long turn starts mid-turn and gets a
  -- continuation heading instead of swallowing the whole history.
  local added, added_bytes, continuation = 0, 0, false
  while stop > 1 and not cfg.turn_start(blocks[stop]) do
    local size = cost(blocks[stop - 1])
    if added + 1 > cfg.page_blocks or (added_bytes > 0 and added_bytes + size > cfg.page_bytes) then
      continuation = true
      break
    end
    stop, added, added_bytes = stop - 1, added + 1, added_bytes + size
  end
  if continuation and cfg.turn_name then
    for i = stop - 1, 1, -1 do
      if cfg.turn_start(blocks[i]) then
        local name = cfg.turn_name(blocks[i])
        if name then
          return stop, name .. " 续"
        end
        break
      end
    end
  end
  return stop, nil
end

function Page:set(blocks, first, last, continuation)
  self.first, self.last = first, last
  self.continuation = continuation
  self.first_id = blocks[first] and blocks[first].id
  self.last_id = blocks[last] and blocks[last].id
end

function Page:sync(session, follow)
  local blocks, n = session.blocks, #session.blocks
  if n == 0 then
    self:set(blocks, 1, 0)
    return 1, 0
  end
  local first
  for i, block in ipairs(blocks) do
    if block.id == self.first_id then
      first = i
      break
    end
  end
  -- The newest block is always materialised: new output must appear without a
  -- manual "load newer" step. Only the older side is paged.
  local continuation
  if follow or not first then
    -- Keep a reader near the old page when the block that owned its first row
    -- disappeared (e.g. a collapsed turn), rather than jumping to the tail.
    local start = n
    if not follow and self.first then
      start = math.max(1, math.min(self.first, n))
    end
    first, continuation = edge(blocks, start, -1, self.cfg)
  end
  if not continuation and not follow and first ~= nil then
    continuation = self.continuation
  end
  self:set(blocks, first, n, continuation)
  return self.first, self.last
end

---Load one older page. The newest edge never moves, so live output keeps
---arriving. The window grows while the user is reading old history; it is
---trimmed when they return to the bottom. A contiguous range cannot both keep
---the live tail and enforce a hard cap while loading arbitrarily old history.
---@param session AdeSessionState
---@param direction integer only negative directions load more history
---@param pins {first: integer, last: integer}|nil
---@return boolean changed
function Page:load(session, direction, pins)
  self:sync(session, false)
  local blocks = session.blocks
  if direction >= 0 or #blocks == 0 or self.first == 1 then
    return false
  end
  local first, continuation = edge(blocks, self.first - 1, -1, self.cfg)
  self:set(blocks, first, self.last, continuation)
  return true
end

function Page:beginning(session)
  local blocks = session.blocks
  self:set(blocks, 1, #blocks, nil)
end

---Return to the newest window, dropping older pages the user no longer reads.
function Page:trim(session, pins)
  local blocks, n = session.blocks, #session.blocks
  if n == 0 then
    self:set(blocks, 1, 0)
    return
  end
  local first = edge(blocks, n, -1, self.cfg)
  if pins then
    first = math.min(first, pins.first)
  end
  local bytes = 0
  for i = first, n do
    bytes = bytes + cost(blocks[i])
  end
  local max_bytes = self.cfg.page_bytes * math.ceil(self.cfg.max_blocks / self.cfg.page_blocks)
  while first < n and (n - first + 1 > self.cfg.max_blocks or bytes > max_bytes) do
    if pins and first <= pins.last and first >= pins.first then
      break
    end
    bytes = bytes - cost(blocks[first])
    first = first + 1
  end
  if self.cfg.turn_start then
    while first < n and not self.cfg.turn_start(blocks[first]) do
      first = first + 1
    end
  end
  self:set(blocks, first, n, nil)
end

function M.selected(view)
  if vim.api.nvim_get_current_buf() ~= view.buf then
    return false
  end
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19"
end

function M.release(block)
  for key in pairs(block) do
    if type(key) == "string" and (key:match("^_md_") or key == "_diff_cache") then
      block[key] = nil
    end
  end
end

function M.evict(old, current)
  for id, entry in pairs(old) do
    if not current[id] then
      M.release(entry.block)
    end
  end
end

return M
