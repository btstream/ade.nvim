-- Changed files in one worker's git worktree (the data half of Team Changed
-- Files).
--
-- The service stores the commit a worker's branch started from as
-- `worktree.base` in a participant snapshot. `scan` compares the worktree with
-- that commit and adds nonignored untracked files, so one list holds the
-- worker's net change: committed, staged and unstaged work together.
--
-- Every git call uses argv (never a shell) and NUL-delimited output, so paths
-- containing spaces, tabs, newlines or non-UTF-8 bytes stay untouched. `-C`
-- keeps the editor's cwd and the worktree itself unchanged.
local M = {}

local GIT_TIMEOUT_MS = 60_000
local MAX_STDERR = 4 * 1024

-- The variables that would point git at another repository or index. The
-- editor's environment must not leak them into a worker's worktree.
local STRIPPED_ENV = {
  GIT_DIR = true,
  GIT_WORK_TREE = true,
  GIT_INDEX_FILE = true,
  GIT_OBJECT_DIRECTORY = true,
  GIT_COMMON_DIR = true,
}

---@param text string
---@return string
local function trimmed(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param text string
---@return string
local function capped(text)
  if #text <= MAX_STDERR then
    return text
  end
  return text:sub(1, MAX_STDERR)
end

---Run a callback on the main loop, never before the caller's stack unwinds.
---@param callback fun(err: string|nil, value: any)
---@param err string|nil
---@param value any
local function settle(callback, err, value)
  vim.schedule(function()
    callback(err, value)
  end)
end

---The current environment without the GIT_* variables that redirect git.
---@return table<string, string>
local function git_env()
  local env = {}
  local ok, current = pcall(vim.fn.environ)
  if ok and type(current) == "table" then
    for key, value in pairs(current) do
      if type(key) == "string" and type(value) == "string" and not STRIPPED_ENV[key] then
        env[key] = value
      end
    end
  end
  env.GIT_TERMINAL_PROMPT = "0"
  -- Stable diagnostics: git otherwise localises its stderr.
  env.LC_ALL = "C"
  env.LANG = "C"
  -- A read must not refresh or write the index as a side effect.
  env.GIT_OPTIONAL_LOCKS = "0"
  return env
end

---Run one git command for a worktree.
---
---`callback(err, stdout)` receives raw bytes; an error is a human-readable
---string that includes git's stderr when there is one.
---@param path string
---@param args string[]
---@param callback fun(err: string|nil, stdout: string)
local function run_git(path, args, callback)
  local argv = { "git", "-C", path }
  vim.list_extend(argv, args)
  local command = "git " .. table.concat(args, " ")
  local spawned, proc = pcall(vim.system, argv, {
    clear_env = true,
    env = git_env(),
    text = false,
    timeout = GIT_TIMEOUT_MS,
  }, function(result)
    local code = result.code or -1
    local stdout = result.stdout or ""
    local stderr = type(result.stderr) == "string" and result.stderr or ""
    vim.schedule(function()
      if code == 0 then
        callback(nil, stdout)
        return
      end
      local detail = trimmed(stderr)
      if detail == "" then
        detail = string.format("exit code %d", code)
      end
      callback(string.format("%s failed: %s", command, capped(detail)), stdout)
    end)
  end)
  if not spawned then
    vim.schedule(function()
      callback(string.format("cannot run %s: %s", command, tostring(proc)), "")
    end)
  end
end

---Split NUL-delimited git output without replacing any byte in a path.
---@param output string
---@return string[]
local function nul_fields(output)
  local fields = {}
  local start = 1
  while start <= #output do
    local at = output:find("\0", start, true)
    if not at then
      fields[#fields + 1] = output:sub(start)
      break
    end
    fields[#fields + 1] = output:sub(start, at - 1)
    start = at + 1
  end
  return fields
end

---Parse `git diff --name-status -z` output.
---@param output string
---@return table[]|nil files
---@return string|nil err
local function parse_name_status(output)
  local fields = nul_fields(output)
  local files = {}
  local index = 1
  while index <= #fields do
    local status = fields[index]
    local code = status:match("^([A-Z])%d*$")
    if not code then
      return nil, "git returned malformed --name-status output"
    end
    index = index + 1
    if code == "R" or code == "C" then
      local old_path = fields[index]
      local new_path = fields[index + 1]
      if not old_path or old_path == "" or not new_path or new_path == "" then
        return nil, "git returned an incomplete rename record"
      end
      files[#files + 1] = { status = code, path = new_path, old_path = old_path }
      index = index + 2
    else
      local path = fields[index]
      if not path or path == "" then
        return nil, "git returned an incomplete change record"
      end
      files[#files + 1] = { status = code, path = path }
      index = index + 1
    end
  end
  return files
end

---A path relative to the worktree root and inside it.
---@param path any
---@return string|nil relative
---@return string|nil err
local function relative_path(path)
  if type(path) ~= "string" or path == "" then
    return nil, "the file path is missing"
  end
  if path:find("\0", 1, true) then
    return nil, "the file path contains a NUL byte"
  end
  if path:sub(1, 1) == "/" then
    return nil, "the file path must be relative to the worktree: " .. path
  end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      return nil, "the file path must stay inside the worktree: " .. path
    end
    if part ~= "." then
      parts[#parts + 1] = part
    end
  end
  if #parts == 0 then
    return nil, "the file path is missing"
  end
  return table.concat(parts, "/")
end

---Check the worktree before any scan: it must exist, be the root of its own
---git work tree (not a subdirectory of a parent repository) and carry a base
---commit id.
---@param worktree any
---@param callback fun(err: string|nil)
local function ensure_worktree(worktree, callback)
  if type(worktree) ~= "table" then
    return settle(callback, "the worktree is missing")
  end
  local path = worktree.path
  if type(path) ~= "string" or path == "" then
    return settle(callback, "the worktree path is missing")
  end
  if path:find("\0", 1, true) then
    return settle(callback, "the worktree path contains a NUL byte")
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return settle(callback, string.format("the worktree %s does not exist", path))
  end
  if stat.type ~= "directory" then
    return settle(callback, string.format("the worktree %s is not a directory", path))
  end
  local base = worktree.base
  if type(base) ~= "string" or base == "" then
    return settle(callback, "the worktree has no base commit")
  end
  if not base:match("^[0-9a-fA-F]+$") then
    return settle(callback, "the worktree base is not a commit id: " .. base)
  end
  run_git(path, { "rev-parse", "--show-prefix" }, function(err, stdout)
    if err then
      callback("the worktree is not a usable git work tree: " .. err)
      return
    end
    if trimmed(stdout) ~= "" then
      callback(string.format("the worktree %s is not a git worktree root", path))
      return
    end
    callback(nil)
  end)
end

---Whether the file now at `relative` has the same content as its base blob.
---
---Regular files go through git (`hash-object --path`), so clean filters are
---honoured; a symlink is compared by its target, which is what git stores.
---`callback(err, same, missing)`: `same` is nil when the path disappeared after
---`ls-files` listed it, and the caller then keeps the deletion it already has.
---@param root string
---@param base string
---@param relative string
---@param callback fun(err: string|nil, same: boolean|nil, missing: boolean|nil)
local function same_as_base(root, base, relative, callback)
  local full = root .. "/" .. relative
  local stat = vim.uv.fs_lstat(full)
  if not stat then
    vim.schedule(function()
      callback(nil, nil, true)
    end)
    return
  end
  if stat.type == "link" then
    run_git(root, { "cat-file", "blob", base .. ":" .. relative }, function(err, content)
      if err then
        callback(err)
        return
      end
      local target, read_err = vim.uv.fs_readlink(full)
      if not target then
        callback(string.format("cannot read the symlink %s: %s", relative, tostring(read_err)))
        return
      end
      callback(nil, target == content, false)
    end)
    return
  end
  local remaining = 2
  local failure
  local base_hash
  local current_hash
  local function finish()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end
    if failure then
      callback(failure)
      return
    end
    callback(nil, trimmed(base_hash) == trimmed(current_hash), false)
  end
  run_git(root, { "rev-parse", base .. ":" .. relative }, function(err, stdout)
    if err then
      failure = failure or err
    else
      base_hash = stdout
    end
    finish()
  end)
  run_git(root, { "hash-object", "--path=" .. relative, "--", relative }, function(err, stdout)
    if err then
      failure = failure or err
    else
      current_hash = stdout
    end
    finish()
  end)
end

---Compare every recreated path with its base blob.
---@param root string
---@param base string
---@param paths string[]
---@param callback fun(err: string|nil, same: table<string, boolean>|nil)
local function compare_reused(root, base, paths, callback)
  local results = {}
  local remaining = #paths
  local failure
  if remaining == 0 then
    callback(nil, results)
    return
  end
  for _, relative in ipairs(paths) do
    same_as_base(root, base, relative, function(err, same, missing)
      if err then
        failure = failure or err
      elseif not missing then
        results[relative] = same
      end
      remaining = remaining - 1
      if remaining == 0 then
        if failure then
          callback(failure)
        else
          callback(nil, results)
        end
      end
    end)
  end
end

---The worker's net changed files since its saved base commit.
---
---`worktree` is a participant snapshot's `{path, branch, base}`. The callback
---is asynchronous: `(err, files)` with `err` nil on success. Each file is
---`{status, path, old_path?}`, where `status` is git's letter (`M`, `A`, `D`,
---`R`, `??`, ...) and `path` is relative to the worktree root. The list is
---sorted by path and has one entry per path.
---
---A path that git reports as deleted can still exist on disk: `git rm a` then
---recreating `a` leaves `D a` in the diff and lists `a` as untracked. The same
---goes for the source of a rename. Those paths are compared with the base
---blob: a different file becomes `M` (the panel must open the current file,
---never the historical one), an identical file is omitted as unchanged, and a
---rename whose source still exists is reported as an addition plus a
---modification instead of a rename.
---@param worktree table
---@param callback fun(err: string|nil, files: table[]|nil)
function M.scan(worktree, callback)
  if type(callback) ~= "function" then
    error("team_files.scan requires a callback", 2)
  end
  ensure_worktree(worktree, function(err)
    if err then
      callback(err)
      return
    end
    local path = worktree.path
    local base = worktree.base
    local remaining = 2
    local failure
    local tracked
    local untracked

    ---Merge the parsed diff and the untracked list into the net change list.
    ---@param same table<string, boolean>
    ---@param untracked_set table<string, boolean>
    local function complete(same, untracked_set)
      local seen = {}
      local handled = {}
      local modified = {}
      local files = {}
      for _, file in ipairs(tracked or {}) do
        local out = file
        local keep = true
        if file.status == "D" and untracked_set[file.path] then
          -- The path exists on disk again: a deletion record here would make
          -- the panel open the base version instead of the current file.
          handled[file.path] = true
          local state = same[file.path]
          if state == true then
            keep = false
          elseif state == false then
            out = { status = "M", path = file.path }
          end
        elseif (file.status == "R" or file.status == "C") and file.old_path and untracked_set[file.old_path] then
          -- The rename source still exists, so the net change is not a rename:
          -- the destination is an addition and the source may be modified.
          handled[file.old_path] = true
          local state = same[file.old_path]
          if state ~= nil then
            out = { status = "A", path = file.path }
            if state == false then
              modified[file.old_path] = true
            end
          end
        end
        if keep and not seen[out.path] then
          seen[out.path] = true
          files[#files + 1] = out
        end
      end
      for relative in pairs(modified) do
        if not seen[relative] then
          seen[relative] = true
          files[#files + 1] = { status = "M", path = relative }
        end
      end
      for _, name in ipairs(untracked or {}) do
        if not handled[name] and not seen[name] then
          seen[name] = true
          files[#files + 1] = { status = "??", path = name }
        end
      end
      table.sort(files, function(left, right)
        return left.path < right.path
      end)
      callback(nil, files)
    end

    local function finish()
      remaining = remaining - 1
      if remaining > 0 then
        return
      end
      if failure then
        callback(failure)
        return
      end
      local untracked_set = {}
      for _, name in ipairs(untracked or {}) do
        untracked_set[name] = true
      end
      -- Only these recreated paths need a content comparison; a normal
      -- deletion or a normal rename keeps git's answer.
      local compare = {}
      local seen_compare = {}
      local function add(relative)
        if not seen_compare[relative] then
          seen_compare[relative] = true
          compare[#compare + 1] = relative
        end
      end
      for _, file in ipairs(tracked or {}) do
        if file.status == "D" and untracked_set[file.path] then
          add(file.path)
        elseif (file.status == "R" or file.status == "C") and file.old_path and untracked_set[file.old_path] then
          add(file.old_path)
        end
      end
      if #compare == 0 then
        complete({}, untracked_set)
        return
      end
      compare_reused(path, base, compare, function(compare_err, same)
        if compare_err then
          callback("cannot compare a recreated path with the base commit: " .. compare_err)
          return
        end
        complete(same or {}, untracked_set)
      end)
    end

    run_git(path, { "diff", "--name-status", "-z", "--find-renames", base, "--" }, function(diff_err, stdout)
      if diff_err then
        failure = failure or ("cannot list the worktree changes: " .. diff_err)
      else
        local parsed, parse_err = parse_name_status(stdout)
        if parse_err then
          failure = failure or parse_err
        else
          tracked = parsed
        end
      end
      finish()
    end)

    run_git(path, { "ls-files", "--others", "--exclude-standard", "-z" }, function(untracked_err, stdout)
      if untracked_err then
        failure = failure or ("cannot list untracked files: " .. untracked_err)
      else
        local names = nul_fields(stdout)
        for _, name in ipairs(names) do
          if name == "" then
            failure = failure or "git returned an empty untracked path"
            break
          end
        end
        untracked = names
      end
      finish()
    end)
  end)
end

---Read one file's content as it exists in the worker's base commit.
---
---This is what a deleted entry needs: the file is gone from the worktree but
---its old content is still in the saved commit. `path` is relative to the
---worktree root (the `path` returned by `scan`). The callback is asynchronous:
---`(err, content)` with raw bytes on success.
---@param worktree table
---@param path string
---@param callback fun(err: string|nil, content: string|nil)
function M.read_base(worktree, path, callback)
  if type(callback) ~= "function" then
    error("team_files.read_base requires a callback", 2)
  end
  local relative, path_err = relative_path(path)
  if not relative then
    return settle(callback, path_err)
  end
  ensure_worktree(worktree, function(err)
    if err then
      callback(err)
      return
    end
    local base = worktree.base
    run_git(worktree.path, { "cat-file", "blob", base .. ":" .. relative }, function(git_err, stdout)
      if git_err then
        callback(string.format("cannot read %s from base %s: %s", relative, base, git_err))
        return
      end
      callback(nil, stdout)
    end)
  end)
end

return M
