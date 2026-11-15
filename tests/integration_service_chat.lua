-- Integration: the service backend end to end, through the panel.
--
-- Uses `tests/fake_service_bin.py`, which speaks the api_version 2 tunnel and
-- runs the real `tests/mock_agent.py` child. This is the plugin-side proof that
-- the service path works before the Rust service is merged.
--
--   ADE_TEST_SERVICE_BIN=tests/fake_service_bin.py \
--     nvim --headless -u tests/minimal_init.lua -l tests/integration_service_chat.lua
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

local service_bin = os.getenv("ADE_TEST_SERVICE_BIN")
if not service_bin or service_bin == "" then
  service_bin = root .. "tests/fake_service_bin.py"
end
if vim.fn.executable(service_bin) ~= 1 and vim.fn.filereadable(service_bin) ~= 1 then
  io.write("SKIP: no service binary (set ADE_TEST_SERVICE_BIN)\n")
  vim.cmd("qa!")
  return
end

local isolated = string.format("/tmp/opencode/ade-svc-chat-%d", vim.uv.os_getpid())
vim.fn.delete(isolated, "rf")
vim.env.NVIM_ADE_SERVER_DIR = isolated .. "/server"
vim.env.XDG_DATA_HOME = isolated .. "/data"
vim.env.XDG_STATE_HOME = isolated .. "/state"
vim.env.XDG_CACHE_HOME = isolated .. "/cache"
for _, dir in ipairs({
  vim.env.NVIM_ADE_SERVER_DIR,
  vim.env.XDG_DATA_HOME,
  vim.env.XDG_STATE_HOME,
  vim.env.XDG_CACHE_HOME,
}) do
  vim.fn.mkdir(dir, "p", 448)
end

local ade = require("ade")
local controller = require("ade.controller")

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
  if not vim.wait(timeout or 10000, cond, 20) then
    error("timed out: " .. (label or "condition"), 2)
  end
end

local function setup(overrides)
  ade.setup(vim.tbl_deep_extend("force", {
    backend = "service",
    service = { path = service_bin, keep_alive = true, idle_timeout = 60 },
    agent = "opencode",
    agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
    ui = {},
    layout = { input_height = 6 },
  }, overrides or {}))
end

---The service connection the plugin is using.
local function connection()
  return require("ade.service.connection").shared()
end

---Ask the service for its instance list.
---
---`connection():request` connects lazily, and the reply arrives on the main
---loop (the client defers dispatch), so this has to wait rather than read a
---variable straight after the call.
local function instances()
  local result = nil
  local done = false
  connection():request("agent.list", {}, function(ok, value)
    done = true
    if ok and type(value) == "table" then
      result = value.instances or {}
    else
      result = nil
    end
  end)
  vim.wait(10000, function()
    return done
  end, 20)
  if not done then
    return nil, "agent.list did not answer"
  end
  return result
end

setup()
ade.open()
local st = controller.state()
wait(function()
  return st.session ~= nil and st.connection == "ready"
end, 20000, "session over the service")

check("a prompt round-trips through the service", function()
  local before = #(st.session.blocks or {})
  controller.submit("Reply with exactly: SERVICE_OK", {})
  -- The mock agent answers every prompt with its scripted reply; what matters
  -- here is that the answer arrives through the service tunnel at all.
  wait(function()
    for _, block in ipairs(st.session.blocks or {}) do
      if block.kind == "agent" and (block.text or ""):find("Hello from the mock agent", 1, true) then
        return true
      end
    end
    return false
  end, 20000, "agent answer")
  assert(#st.session.blocks > before, "no new blocks")
  wait(function()
    return st.session.status == "idle"
  end, 20000, "turn finished")
end)

check("the service holds exactly one instance for the panel", function()
  local list, failure = instances()
  assert(list, "agent.list failed: " .. vim.inspect(failure))
  assert(#list == 1, "expected one instance, got " .. vim.inspect(list))
  assert(list[1].attached >= 1, "the panel is not attached")
end)

check("a second attach with the same key reuses the instance", function()
  local list = instances()
  assert(list and #list == 1, "unexpected instance count")
  local id = list[1].instance
  -- Attaching with the *same* key the plugin used must reuse the instance; this
  -- is what makes "reopen Neovim and continue" possible. The key is taken from
  -- the live instance so the identity (command, args, cwd, capabilities) is
  -- exactly what the first attach sent.
  local attach = nil
  connection():request("agent.attach", {
    key = {
      agent = list[1].agent,
      command = list[1].command,
      args = list[1].args,
      cwd = list[1].cwd,
    },
    client_capabilities = st.conn.client.client_capabilities,
    env = require("ade.service.transport").child_env(nil),
  }, function(ok, value)
    attach = { ok = ok, value = value }
  end)
  vim.wait(10000, function()
    return attach ~= nil
  end, 20)
  assert(attach, "the second attach did not answer")
  assert(attach.ok, vim.inspect(attach.value))
  assert(attach.value.instance == id, "a second attach created a new instance: " .. tostring(attach.value.instance))
  assert(attach.value.created == false, "created must be false for a live instance")
  assert(attach.value.initialized == true, "the cached initialize must be reported")
end)

check("stopping an instance leaves agent.list immediately visible as stopping", function()
  -- PROTOCOL.md 3.4/3.5: the stopped instance leaves the identity lookup at
  -- once, and stays listed with `stopping` until it exits.
  local list = instances()
  assert(list and #list >= 1, "expected a running instance")
  local id = list[1].instance
  local stopped = nil
  connection():request("agent.stop", { instance = id }, function(ok, value)
    stopped = { ok = ok, value = value }
  end)
  vim.wait(5000, function()
    return stopped ~= nil
  end, 20)
  assert(stopped and stopped.ok, "agent.stop failed: " .. vim.inspect(stopped))
  local after = instances()
  for _, instance in ipairs(after or {}) do
    assert(instance.instance ~= id, "the stopped instance is still in the identity lookup")
  end
end)

check("disconnect stops the agent", function()
  controller.disconnect()
  wait(function()
    local list = instances()
    return list ~= nil and #list == 0
  end, 15000, "agent stopped by disconnect")
  assert(st.connection ~= "ready", "the panel is still connected")
end)

check("leaving the panel detaches and keeps the agent", function()
  setup()
  ade.open()
  wait(function()
    return st.session ~= nil and st.connection == "ready"
  end, 20000, "reconnected session")
  local list = instances()
  assert(list and #list == 1, "expected one running instance before leaving")
  local id = list[1].instance
  -- `terminate` is the VimLeavePre path; it must detach, not kill.
  st.conn.service:terminate()
  wait(function()
    local now = instances()
    return now ~= nil and #now == 1 and now[1].attached == 0
  end, 10000, "instance detached but alive")
  local after = instances()
  assert(after[1].instance == id, "the instance was replaced instead of detached")
end)

-- Clean up: stop whatever is left so the run leaves no process behind.
pcall(function()
  for _, instance in ipairs(instances() or {}) do
    require("ade.service.commands").kill(instance.instance, { notify = function() end })
  end
  require("ade.service.commands").stop({ notify = function() end })
end)
vim.fn.delete(isolated, "rf")

if #failures > 0 then
  io.write("\n" .. #failures .. " service chat failures:\n")
  for _, failure in ipairs(failures) do
    io.write("  - " .. failure .. "\n")
  end
  vim.cmd("cq 1")
else
  io.write("\nall service chat checks passed\n")
  vim.cmd("qa!")
end
