-- One-shot migration of the directories written by the old plugin name.
--
-- Renaming the plugin renamed everything it owns on disk: `acp` became `ade`
-- under the data and state directories, and the log file gained a new name.
-- Users who already installed agents or have drafts must not lose them, so the
-- first setup of a process moves each old path into place.
--
-- The rule is deliberately conservative:
--
--   * old exists, new missing  -> rename (atomic on one filesystem)
--   * both exist              -> keep both, warn: merging is not predictable
--   * rename fails            -> warn, the plugin keeps working with new paths
--   * data tree still in use  -> defer, retry on the next start
--
-- Nothing is ever deleted, copied or merged. A warning is the whole recovery
-- story for the ambiguous cases: the user knows best which copy to keep.
--
-- The data directory deserves one extra guard. Another Neovim may still be
-- running from before the update, with a managed agent loaded lazily through a
-- lease, or an install in progress under a lock. Renaming the tree out from
-- under it breaks that instance, so a live record under `agents/.locks` or
-- `agents/.leases` defers the data move (state and log still migrate) and the
-- migration is retried on the next start.
--
-- `stdpath("run")` is not migrated: it only holds spill files of a live
-- process, and a stale one is swept on the next start anyway.
local M = {}

local log = require("ade.log")

---Whether the migration already ran in this process.
local done = false

---Paths to migrate, derived from the stdpath roots.
---
---Testing hook: `opts.data_dir`, `opts.state_dir` and `opts.log_dir` override
---the roots, so a test never has to move the shared test directories.
---@param opts table|nil
---@return {label: string, from: string, to: string}[]
function M.targets(opts)
  opts = opts or {}
  local data = opts.data_dir or vim.fn.stdpath("data")
  local state = opts.state_dir or vim.fn.stdpath("state")
  local log_dir = opts.log_dir
  if type(log_dir) ~= "string" or log_dir == "" then
    log_dir = vim.fn.stdpath("log")
    if type(log_dir) ~= "string" or log_dir == "" then
      log_dir = vim.fn.stdpath("cache")
    end
  end
  return {
    { label = "log", from = log_dir .. "/acp.nvim.log", to = log_dir .. "/ade.nvim.log" },
    { label = "data", from = data .. "/acp", to = data .. "/ade" },
    { label = "state", from = state .. "/acp", to = state .. "/ade" },
  }
end

---Move one entry. Returns a status string, never raises.
---@param item {label: string, from: string, to: string}
---@param fs table
---@return "absent"|"migrated"|"conflict"|"failed"
---@return string|nil reason
local function migrate_one(item, fs)
  local source = fs.fs_stat(item.from)
  if not source then
    return "absent"
  end
  if fs.fs_stat(item.to) then
    return "conflict",
      string.format(
        "both %s and %s exist; the old path was left untouched, move or remove %s manually",
        item.from,
        item.to,
        item.from
      )
  end
  local ok, err = fs.fs_rename(item.from, item.to)
  if not ok then
    return "failed",
      string.format(
        "unable to move %s to %s (%s); the new path will be used and the old one is left as is",
        item.from,
        item.to,
        tostring(err)
      )
  end
  return "migrated"
end

---Whether an old data directory is still being used by another Neovim.
---
---Renaming `data/acp` would pull the files out from under a running instance:
---a leased install is loaded lazily and an install in progress writes into its
---own release directory. The agent manager already records both cases, so the
---probe reuses its liveness rules rather than inventing a second notion of
---"in use".
---@param data_dir string the pre-migration data directory
---@return boolean busy
---@return string|nil reason
local function data_in_use(data_dir)
  local ok, busy, reason = pcall(function()
    return require("ade.manager.lock").in_use(data_dir .. "/agents")
  end)
  if not ok then
    -- Never block a migration because the probe itself failed.
    return false
  end
  return busy == true, reason
end

---Rewrite absolute cache paths inside `drafts.json`.
---
---Attachments record the absolute path of the image cache file, so after the
---state directory moves an old draft would point at a file that no longer
---exists. Only image attachments are touched, only paths under `old_dir`, and
---only when the moved file really is there: anything else keeps its value.
---@param file string drafts.json path
---@param old_dir string the pre-migration state directory
---@param new_dir string the post-migration state directory
---@param fs table
---@return integer repaired
---@return string|nil err
local function repair_drafts(file, old_dir, new_dir, fs)
  if not fs.fs_stat(file) then
    return 0
  end
  local fh = io.open(file, "rb")
  if not fh then
    return 0, "unable to read " .. file
  end
  local text = fh:read("*a")
  fh:close()
  local ok, store = pcall(vim.json.decode, text or "")
  if not ok or type(store) ~= "table" then
    return 0, file .. " is not valid JSON; left as is"
  end
  local prefix = old_dir .. "/"
  local repaired = 0
  for _, entry in pairs(store) do
    if type(entry) == "table" and type(entry.attachments) == "table" then
      for _, att in ipairs(entry.attachments) do
        if type(att) == "table" and att.kind == "image" and type(att.path) == "string" then
          local tail = att.path:sub(1, #prefix) == prefix and att.path:sub(#prefix + 1)
          local moved = tail and (new_dir .. "/" .. tail)
          if moved and fs.fs_stat(moved) then
            att.path = moved
            att.uri = "file://"
              .. moved:gsub("[^%w%-%._~/]", function(c)
                return string.format("%%%02X", string.byte(c))
              end)
            repaired = repaired + 1
          end
        end
      end
    end
  end
  if repaired == 0 then
    return 0
  end
  local encoded_ok, encoded = pcall(vim.json.encode, store)
  if not encoded_ok then
    return 0, "unable to encode " .. file .. "; left as is"
  end
  local tmp = file .. ".migrate-" .. tostring(fs.hrtime and fs.hrtime() or os.time())
  local out = io.open(tmp, "wb")
  if not out then
    return 0, "unable to write " .. tmp
  end
  local written = out:write(encoded)
  out:close()
  if not written or not fs.fs_rename(tmp, file) then
    pcall(fs.fs_unlink, tmp)
    return 0, "unable to replace " .. file .. "; left as is"
  end
  return repaired
end

---Migrate every old path, at most once per process.
---
---Nothing is logged while entries are being moved: the log itself may be one
---of the targets, and writing a warning before that rename would create the
---new log at the destination and turn the move into a conflict.
---
---@param opts {data_dir?: string, state_dir?: string, log_dir?: string, force?: boolean,
---  fs?: table, notify?: boolean}|nil
---@return {label: string, from: string, to: string, status: string, reason?: string}[]
function M.run(opts)
  opts = opts or {}
  if done and not opts.force then
    return {}
  end
  done = true
  local fs = opts.fs or vim.uv
  local results = {}
  local deferred = false
  for _, item in ipairs(M.targets(opts)) do
    local busy, busy_reason
    -- Probe only when the move would actually happen. If both directories
    -- exist the conflict is the actionable answer; deferring on top of it would
    -- hide that and never resolve.
    if item.label == "data" and fs.fs_stat(item.from) and not fs.fs_stat(item.to) then
      busy, busy_reason = data_in_use(item.from)
    end
    if busy then
      -- Not a failure and not done: another instance still has this tree open,
      -- so the move is retried on the next start (and on a later setup in this
      -- process) instead of being recorded as completed.
      item.status = "deferred"
      item.reason = "另一个 Neovim 仍在使用旧目录，关闭它们后重启即可完成迁移"
      item.detail = busy_reason
      deferred = true
    else
      item.status, item.reason = migrate_one(item, fs)
    end
    results[#results + 1] = item
  end
  -- A deferred data move leaves the whole run unfinished: `setup` may run again
  -- in this process (agent switch, reconfigure) and must be allowed to retry.
  done = not deferred
  -- Drafts store absolute image-cache paths, which the state move invalidates.
  -- Repair them only when the state directory really moved, and never let a
  -- failure here affect the migration result.
  for _, item in ipairs(results) do
    if item.label == "state" and item.status == "migrated" then
      local repaired, err = repair_drafts(item.to .. "/drafts.json", item.from, item.to, fs)
      if err then
        item.reason = err
      elseif repaired > 0 then
        item.repaired = repaired
      end
    end
  end
  for _, item in ipairs(results) do
    if item.status == "migrated" then
      log.info("migrated %s to %s", item.from, item.to)
    end
    if item.repaired then
      log.info("repaired %d image path(s) in %s/drafts.json", item.repaired, item.to)
    end
    if item.reason then
      log.warn("%s", item.reason)
      if item.detail then
        log.warn("  evidence: %s", item.detail)
      end
      if opts.notify ~= false then
        pcall(vim.notify, "ade.nvim: " .. item.reason, vim.log.levels.WARN)
      end
    end
  end
  return results
end

---Forget that the migration ran. Only for tests that need to exercise it.
function M.reset()
  done = false
end

return M
