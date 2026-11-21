-- Route composer pastes to image attachments, text previews, or Neovim.
--
-- A terminal can only forward text when the user drops a file or pastes a path,
-- so this is the one paste path that carries something a screenshot cannot:
-- the image file itself.
local M = {}

local image = require("ade.context.image")
local paste_draft = require("ade.storage.paste_draft")

---Bracketed-paste content arrives as one string may be wrapped in the paste
---markers by callers that synthesise it; strip them before inspecting.
---@param lines string[]
---@return string
local function join(lines)
  local text = table.concat(lines, "\n")
  text = text:gsub("^\27%[200~", ""):gsub("\27%[201~$", "")
  return text
end

---Normalise a pasted location into a filesystem path.
---
---Terminals and file managers send `file://` URIs, quoted paths, and Windows
---paths with escapes. Only the shapes that can name a local file are accepted.
---@param text string
---@return string|nil
function M.path_of(text)
  local value = vim.trim(text):gsub("^['\"]", ""):gsub("['\"]$", "")
  if value == "" or value:find("\n", 1, true) then
    return nil
  end
  if value:find("^file://") then
    local ok, decoded = pcall(vim.uri_to_fname, value)
    if not ok then
      return nil
    end
    value = decoded
  elseif value:find("^https?://") then
    -- A web URL is text the user wanted to paste, not a local image.
    return nil
  end
  -- Unescape the backslash form some terminals use for spaces in paths.
  if not value:match("^%a:[/\\]") and vim.fn.filereadable(value) ~= 1 then
    value = value:gsub("\\ ", " ")
  end
  if value:sub(1, 1) ~= "/" and not value:match("^%a:[/\\]") and not value:match("^~") then
    return nil
  end
  return vim.fn.fnamemodify(value, ":p")
end

---Whether `path` is a supported image file within the size budget.
---@param path string
---@param limit integer
---@return boolean
function M.is_image(path, limit)
  return image.is_file(path, limit)
end

---Install the handler for one composer buffer.
---
---The override is process-wide because `vim.paste` is, but it delegates unless
---the cursor is in an opted-in composer.
---@param buf integer
---@param opts {config: fun(): table, on_image: fun(path: string): boolean, is_active: fun(): boolean, on_text?: fun(lines: string[]): boolean, epoch?: fun(): integer}
function M.attach(buf, opts)
  if M.installed then
    M.followers[buf] = opts
    -- Another plugin (or a test double) may have replaced `vim.paste` after our
    -- wrapper was installed; re-wrap so this follower is actually reachable.
    if vim.paste ~= M.paste then
      M.original = vim.paste
      vim.paste = M.paste
    end
    return
  end
  M.followers = { [buf] = opts }
  local followers = M.followers -- This installation's owners, even if wrapped by another plugin.
  M.installed = true
  local original = vim.paste
  M.original = original

  local function delegate(lines, phase)
    local target = M.original
    if not target or target == M.paste then
      target = original
    end
    return target(lines, phase)
  end

  local function claim(owner, lines)
    local path = #lines == 1 and M.path_of(join(lines))
    if path then
      local images = owner.config().context.images
      if images.enabled ~= false and M.is_image(path, images.max_bytes) and owner.on_image(path) then
        return true
      end
    end
    return owner.on_text and owner.on_text(lines) or false
  end

  local stream
  M.paste = function(lines, phase)
    local buf = vim.api.nvim_get_current_buf()
    local owner = followers[buf]
    local active = owner and owner.is_active()
    if phase < 2 then
      stream = nil
    end
    if phase == -1 then
      if active and claim(owner, lines) then
        return true
      end
    elseif
      phase == 1
      and active
      and owner.on_text
      and owner.config().ui.paste_preview.enabled
      and vim.fn.getcmdtype() == ""
      and vim.api.nvim_get_mode().mode:match("^[ni]")
    then
      stream = { buf = buf, owner = owner, epoch = owner.epoch and owner.epoch(), chunks = {}, bytes = 0 }
    end
    if stream then
      local current = stream
      if
        not active
        or buf ~= current.buf
        or owner ~= current.owner
        or (owner.epoch and owner.epoch() ~= current.epoch)
      then
        stream = nil
        return false
      end
      if phase == 3 then
        stream = nil
      end
      if current.chunks then
        local text = table.concat(lines, "\n")
        if #text + current.bytes <= paste_draft.max_bytes then
          if text ~= "" then
            current.chunks[#current.chunks + 1] = text
            current.bytes = current.bytes + #text
          end
          if phase ~= 3 then
            return true
          end
          local combined = vim.split(table.concat(current.chunks), "\n", { plain = true })
          return claim(owner, combined) or delegate(combined, -1)
        end
        local chunks = current.chunks
        current.chunks = nil
        if phase ~= 1 and not delegate(vim.split(table.concat(chunks), "\n", { plain = true }), 1) then
          stream = nil
          return false
        end
      end
    end
    return delegate(lines, phase)
  end
  vim.paste = M.paste
end

---Stop handling pastes for `buf`.
---@param buf integer
function M.detach(buf)
  if M.followers then
    M.followers[buf] = nil
  end
  if M.installed and next(M.followers or {}) == nil then
    M.installed = false
    M.followers = nil
    -- Only restore our own wrapper: another plugin may have wrapped `vim.paste`
    -- after us, and clobbering it would silently disable that handler.
    if M.original and vim.paste == M.paste then
      vim.paste = M.original
    end
  end
end

return M
