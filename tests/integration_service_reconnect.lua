-- Integration: the panel recovers after the service connection drops.
--
-- PROTOCOL.md 7 and 9: the front end reconnects and re-attaches. This drives the
-- real controller against the stand-in service, kills it mid-conversation, and
-- checks that `:Ade reconnect` restores a working panel.
--
--   nvim --headless -u tests/minimal_init.lua -l tests/integration_service_reconnect.lua
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

local service_bin = os.getenv("ADE_TEST_SERVICE_BIN")
if not service_bin or service_bin == "" then
  service_bin = root .. "tests/fake_service_bin.py"
end

local base = string.format("/tmp/opencode/ade-svc-reconnect-it-%d", vim.uv.os_getpid())
vim.fn.delete(base, "rf")
vim.env.NVIM_ADE_SERVER_DIR = base .. "/server"
vim.env.XDG_DATA_HOME = base .. "/data"
vim.env.XDG_STATE_HOME = base .. "/state"
vim.env.XDG_CACHE_HOME = base .. "/cache"
for _, dir in ipairs({
  vim.env.NVIM_ADE_SERVER_DIR,
  vim.env.XDG_DATA_HOME,
  vim.env.XDG_STATE_HOME,
  vim.env.XDG_CACHE_HOME,
}) do
  vim.fn.mkdir(dir, "p", 448)
end

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
  if not vim.wait(timeout or 15000, cond, 20) then
    error("timed out: " .. (label or "condition"), 2)
  end
end

local ade = require("ade")
local controller = require("ade.controller")
local Connection = require("ade.service.connection")

ade.setup({
  backend = "service",
  service = { path = service_bin, keep_alive = false, idle_timeout = 60 },
  agent = "opencode",
  agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
  ui = {},
  layout = { input_height = 6 },
})

ade.open()
local st = controller.state()
wait(function()
  return st.session ~= nil and st.connection == "ready"
end, 25000, "session over the service")

---The stand-in service is a separate process (laid out by
---`tests/fake_service_bin.py`); find it through `/proc` and kill it.
local function service_pids()
  local pids = {}
  -- `NVIM_ADE_SERVER_DIR` is inherited by the stand-in, so /proc/environ is the
  -- reliable way to find it. Unreadable processes (other users) are skipped.
  local wanted = "NVIM_ADE_SERVER_DIR=" .. vim.env.NVIM_ADE_SERVER_DIR
  local script = "for p in /proc/[0-9]*/environ; do "
    .. "pid=$(echo $p | cut -d/ -f3); "
    .. "if { tr '\\0' '\\n' < $p 2>/dev/null || true; } 2>/dev/null | grep -qxF \"$WANTED\"; then "
    .. "{ tr '\\0' ' ' < $(dirname $p)/cmdline 2>/dev/null || true; } | grep -q fake_service && echo $pid; "
    .. "fi; done"
  -- The whole scan writes nothing to stderr: reading another user's /proc entry
  -- is expected to fail and must not clutter the test output.
  local handle =
    io.popen("WANTED=" .. vim.fn.shellescape(wanted) .. " sh -c " .. vim.fn.shellescape(script) .. " 2>/dev/null")
  for line in handle:lines() do
    pids[#pids + 1] = line
  end
  handle:close()
  return pids
end

check("a conversation works before the service is killed", function()
  controller.submit("Reply with exactly: BEFORE", {})
  wait(function()
    for _, block in ipairs(st.session.blocks or {}) do
      if block.kind == "agent" and (block.text or ""):find("Hello from the mock agent", 1, true) then
        return true
      end
    end
    return false
  end, 25000, "agent answer before the kill")
  wait(function()
    return st.session.status == "idle"
  end, 25000, "turn finished")
end)

check("killing the service reports a disconnected panel", function()
  local pids = service_pids()
  assert(#pids > 0, "could not find the stand-in service process")
  for _, pid in ipairs(pids) do
    vim.fn.system("kill -9 " .. pid)
  end
  wait(function()
    return st.connection ~= "ready"
  end, 15000, "the panel notices the drop")
  assert(st.connection ~= "ready", "the panel still claims to be ready")
end)

check(":Ade reconnect restores the connection and the conversation", function()
  controller.reconnect()
  wait(function()
    return st.connection == "ready" and st.session ~= nil
  end, 25000, "reconnected session")

  local before = #(st.session.blocks or {})
  controller.submit("Reply with exactly: AFTER", {})
  wait(function()
    return #(st.session.blocks or {}) > before
  end, 25000, "a new answer after reconnecting")
  wait(function()
    return st.session.status == "idle"
  end, 25000, "turn finished after reconnecting")
end)

check("the shared connection object is still usable", function()
  local shared = Connection.shared()
  -- A closed singleton could never reconnect; this is the bug the task fixed.
  assert(shared.closed ~= true, "the shared connection was marked permanently closed")
  assert(shared:is_connected(), "the shared connection is not connected")
end)

pcall(controller.disconnect)
pcall(function()
  require("ade.service.commands").stop({ notify = function() end })
end)
pcall(function()
  for _, pid in ipairs(service_pids()) do
    vim.fn.system("kill -9 " .. pid)
  end
end)
vim.fn.delete(base, "rf")

if #failures > 0 then
  io.write("\n" .. #failures .. " service-reconnect integration failures:\n")
  for _, failure in ipairs(failures) do
    io.write("  - " .. failure .. "\n")
  end
  vim.cmd("cq 1")
else
  io.write("\nall service reconnect integration checks passed\n")
  vim.cmd("qa!")
end
