-- Integration test: a real service process, a real socket, the real launcher.
--
-- Uses `tests/fake_service.py` as the server, so the Rust crate is not needed.
-- Everything is isolated under NVIM_ADE_SERVER_DIR and a temporary data root.
--
--   nvim --headless -u tests/minimal_init.lua -l tests/integration_service.lua
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
vim.opt.runtimepath:append(root)

local base = string.format("/tmp/opencode/ade-svc-it-%d", vim.uv.os_getpid())
vim.fn.delete(base, "rf")
vim.env.NVIM_ADE_SERVER_DIR = base .. "/server"
vim.fn.mkdir(vim.env.NVIM_ADE_SERVER_DIR, "p", 448)
-- The install root is derived from stdpath("data"), so the fake install has to
-- live there for `current_binary` (and therefore the status) to find it.
vim.env.XDG_DATA_HOME = base .. "/xdgdata"
vim.fn.mkdir(vim.env.XDG_DATA_HOME, "p")

local failures = {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    io.write("ok   " .. name .. "\n")
  else
    failures[#failures + 1] = name .. ": " .. tostring(err)
    io.write("FAIL " .. name .. "\n")
  end
end

local function wait(cond, timeout, label)
  if not vim.wait(timeout or 8000, cond, 20) then
    error("timed out: " .. (label or "condition"), 2)
  end
end

---Write a wrapper script that runs the fake server with the right --dir.
local function install_fake()
  local data = vim.fn.stdpath("data")
  local dir = data .. "/ade/service/" .. require("ade.service.version").VERSION
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/nvim_ade_server"
  local fh = assert(io.open(script, "wb"))
  fh:write(
    string.format(
      '#!/bin/sh\nexec %s %s %s "$@"\n',
      vim.fn.exepath("python3"),
      root .. "tests/fake_service.py",
      "--dir " .. vim.env.NVIM_ADE_SERVER_DIR
    )
  )
  fh:close()
  vim.uv.fs_chmod(script, 448)
  -- A pointer, so `current_binary` finds it.
  local pointer = assert(io.open(data .. "/ade/service/current", "wb"))
  pointer:write(vim.json.encode({ schemaVersion = 1, version = require("ade.service.version").VERSION }))
  pointer:close()
  return script, data
end

local script, data = install_fake()
local Install = require("ade.service.install")
local Launcher = require("ade.service.launcher")
local Client = require("ade.service.client")

check("the fake binary reports the required version", function()
  local ok, err = Install.verify_binary(script)
  assert(ok, tostring(err))
end)

check("launcher starts the service and reports ready", function()
  local ok, err, info = Launcher.ensure({ bin = script, timeout = 8000, data_dir = data })
  assert(ok, tostring(err))
  assert(info.status.status == "ready", vim.inspect(info.status))
  wait(function()
    return vim.fn.filereadable(vim.env.NVIM_ADE_SERVER_DIR .. "/nvim_ade_server.token") == 1
  end, 5000, "token file")
end)

check("a second ensure() reuses the running service", function()
  local ok, err, info = Launcher.ensure({ bin = script, timeout = 8000, data_dir = data })
  assert(ok, tostring(err))
  assert(info.status.status == "already_running", vim.inspect(info.status))
end)

check("the client completes hello and ping", function()
  local client = Client.new({ timeout = 5000 })
  local ok, info
  client:connect(function(result, value)
    ok, info = result, value
  end)
  assert(ok, tostring(info))
  assert(info.api_version == 1, vim.inspect(info))
  local pinged, ping_err = false, nil
  client:ping(function(result, value)
    pinged, ping_err = result, value
  end)
  assert(pinged, tostring(ping_err))
  client:close()
end)

check(":Ade service status reports the running service", function()
  local messages = {}
  require("ade.service.commands").status({
    config = require("ade.config").effective(),
    notify = function(message, level)
      messages[#messages + 1] = tostring(level) .. " " .. tostring(message)
    end,
  })
  local joined = table.concat(messages, "\n")
  assert(joined:find("service is running", 1, true), joined)
end)

check(":Ade service stop asks the service to exit", function()
  local messages = {}
  local stopped = require("ade.service.commands").stop({
    notify = function(message)
      messages[#messages + 1] = tostring(message)
    end,
  })
  assert(stopped, table.concat(messages, "\n"))
  wait(function()
    return not Launcher.probe(require("ade.service.paths").paths())
  end, 8000, "service exit")
end)

check("checkhealth's service section stays read-only", function()
  local status = require("ade.service.status").collect({ config = require("ade.config").effective() })
  assert(status.installed_version == require("ade.service.version").VERSION, vim.inspect(status))
  assert(status.running == false, "the service was stopped just before this check")
end)

vim.fn.delete(base, "rf")
if #failures > 0 then
  io.write("\n--- failures ---\n" .. table.concat(failures, "\n") .. "\n")
  vim.cmd("cq 1")
else
  io.write("\nall service integration checks passed\n")
  vim.cmd("qa!")
end
