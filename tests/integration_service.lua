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
  local Version = require("ade.service.version")
  -- The stand-in takes its versions from the plugin's constants, so a bump in
  -- the merge commit needs no edit here and the handshake keeps working.
  fh:write(
    string.format(
      '#!/bin/sh\nexec %s %s %s %s %s "$@"\n',
      vim.fn.exepath("python3"),
      root .. "tests/fake_service.py",
      "--dir " .. vim.env.NVIM_ADE_SERVER_DIR,
      "--server-version " .. Version.VERSION,
      "--api-version " .. tostring(Version.API_VERSION)
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
  assert(info.api_version == require("ade.service.version").API_VERSION, vim.inspect(info))
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

check("managed installs go through the service store (PROTOCOL 16)", function()
  local client = Client.new({ timeout = 5000 })
  local connected = false
  client:connect(function(ok)
    connected = ok
  end)
  assert(connected, "the client did not connect")
  local install_root = base .. "/agents"
  vim.fn.mkdir(install_root, "p")

  local resolved, resolve_err = nil, nil
  client:request("install.resolve", {
    root = install_root,
    package = "@geohar/pi-acp",
    spec = "latest",
    npm = "npm",
    env = { PATH = vim.env.PATH or "" },
  }, function(ok, value)
    if ok then
      resolved = value.version
    else
      resolve_err = value
    end
  end)
  wait(function()
    return resolved ~= nil or resolve_err ~= nil
  end, 5000, "install.resolve")
  assert(resolved, vim.inspect(resolve_err))
  assert(type(resolved) == "string" and resolved ~= "latest", tostring(resolved))

  local run, run_err = nil, nil
  client:request("install.run", {
    job = "it-install-1",
    root = install_root,
    agent = "pi",
    action = "install",
    package = "@geohar/pi-acp",
    entry = "dist/index.js",
    version = resolved,
    npm = "npm",
    env = { PATH = vim.env.PATH or "" },
  }, function(ok, value)
    if ok then
      run = value
    else
      run_err = value
    end
  end)
  wait(function()
    return run ~= nil or run_err ~= nil
  end, 15000, "install.run")
  assert(run, vim.inspect(run_err))
  assert(run.status == "committed", vim.inspect(run))
  assert(vim.fn.filereadable(install_root .. "/pi/current.json") == 1, "no pointer was written")
  local entry = install_root .. "/pi/releases/" .. run.installId .. "/node_modules/@geohar/pi-acp/dist/index.js"
  assert(vim.fn.filereadable(entry) == 1, "the entrypoint was not installed: " .. entry)

  local removed, remove_err = nil, nil
  client:request("install.uninstall", {
    job = "it-uninstall-1",
    root = install_root,
    agent = "pi",
    installId = run.installId,
  }, function(ok, value)
    if ok then
      removed = value
    else
      remove_err = value
    end
  end)
  wait(function()
    return removed ~= nil or remove_err ~= nil
  end, 5000, "install.uninstall")
  assert(removed, vim.inspect(remove_err))
  assert(vim.fn.filereadable(install_root .. "/pi/current.json") == 0, "the pointer survived the uninstall")
  client:close()
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
