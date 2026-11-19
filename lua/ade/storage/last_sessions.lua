-- One small pointer per agent and cwd. Independent files prevent two editors
-- working in different projects from replacing each other's records.
local M = {}
local uv = vim.uv

function M.dir()
  return vim.fn.stdpath("state") .. "/ade/last_sessions"
end

local function path(agent, cwd)
  return M.dir() .. "/" .. vim.fn.sha256(vim.json.encode({ agent, cwd })) .. ".json"
end

local function read(file)
  local fh = io.open(file, "rb")
  if not fh then
    return nil
  end
  local raw = fh:read(65537)
  fh:close()
  if raw and #raw <= 65536 then
    local ok, data = pcall(vim.json.decode, raw)
    if ok and type(data) == "table" and type(data.id) == "string" and data.id ~= "" then
      return data
    end
  end
end

function M.get(agent, cwd)
  local record = read(path(agent, cwd))
  return record and record.agent == agent and record.cwd == cwd and record.id or nil
end

function M.set(agent, cwd, id)
  if type(agent) ~= "string" or type(cwd) ~= "string" or cwd == "" or type(id) ~= "string" or id == "" then
    return
  end
  if M.get(agent, cwd) == id then
    return
  end
  pcall(vim.fn.mkdir, M.dir(), "p", 448)
  local file = path(agent, cwd)
  local data = vim.json.encode({ agent = agent, cwd = cwd, id = id })
  local fd, tmp = uv.fs_mkstemp(file .. ".XXXXXX")
  if fd then
    local wrote = uv.fs_write(fd, data, 0)
    local closed = uv.fs_close(fd)
    if wrote == #data and closed and uv.fs_rename(tmp, file) then
      return
    end
    uv.fs_unlink(tmp)
  end
  require("ade.log").warn("unable to save the last session pointer for %s", cwd)
end

function M.forget(agent, cwd, id)
  if M.get(agent, cwd) == id then
    uv.fs_unlink(path(agent, cwd))
  end
end

function M.forget_session(agent, id)
  local files = uv.fs_scandir(M.dir())
  if not files then
    return
  end
  while true do
    local name = uv.fs_scandir_next(files)
    if not name then
      break
    end
    if name:match("^%x+%.json$") then
      local record = read(M.dir() .. "/" .. name)
      if record and record.agent == agent and record.id == id and type(record.cwd) == "string" then
        M.forget(agent, record.cwd, id)
      end
    end
  end
end

return M
