-- Integration: a pending permission request survives the front end leaving.
--
-- PROTOCOL.md 5.4 and 9.5: while an instance has no attached front end its
-- pending agent->client requests are kept, and handed to the next front end that
-- attaches. This drives the real Client + service channel against the stand-in
-- service, so it covers the whole path from the ACP request to the re-delivery.
--
--   nvim --headless -u tests/minimal_init.lua -l tests/integration_service_leave.lua
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
local base = string.format("/tmp/opencode/ade-svc-leave-%d", vim.uv.os_getpid())
vim.fn.delete(base, "rf")
vim.env.NVIM_ADE_SERVER_DIR = base .. "/server"
vim.fn.mkdir(vim.env.NVIM_ADE_SERVER_DIR, "p", 448)

local Version = require("ade.service.version")
local fake = require("tests.fake_service")
local Framing = require("ade.transport.framing")
local service_transport = require("ade.service.transport")
local Connection = require("ade.service.connection")
local client_mod = require("ade.protocol.client")
local Interactions = require("ade.app.interactions")

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

-- The stand-in service, running a real mock agent.
local service = fake.new({ dir = vim.env.NVIM_ADE_SERVER_DIR })
local jobs = {}
service.spawn_agent = function(instance)
  local decoder = Framing.new_decoder()
  local job = vim.fn.jobstart({ "python3", root .. "tests/mock_agent.py" }, {
    stdin = "pipe",
    stdout_buffered = false,
    on_stdout = function(_, data)
      for _, chunk in ipairs(data or {}) do
        if chunk ~= "" then
          decoder:feed(chunk .. "\n", function(line)
            if line == "" then
              return
            end
            local ok, message = pcall(vim.json.decode, line)
            if ok and type(message) == "table" then
              service:deliver(instance, message)
            end
          end)
        end
      end
    end,
  })
  jobs[#jobs + 1] = job
  instance.handler = function(message, reply)
    pcall(vim.fn.chansend, job, vim.json.encode(message) .. "\n")
    if reply then
      reply(nil)
    end
  end
  instance.stop_agent = function()
    pcall(vim.fn.jobstop, job)
  end
  return job > 0
end
assert(service:listen())
local connection = Connection.new({
  resolve_binary = function()
    return { path = "/fake", version = Version.VERSION, api_version = Version.API_VERSION }
  end,
  ensure_service = function()
    return true
  end,
  timeout = 5000,
})
local ok, err
connection:ensure(function(result, reason)
  ok, err = result, reason
end)
assert(ok, tostring(err))

---One front end: a Client plus an interaction broker with a recording picker.
local function front_end(opts)
  opts = opts or {}
  local presented = {}
  local interactions = Interactions.new({
    presenters = {
      permission = {
        present = function(interaction)
          presented[#presented + 1] = interaction
          return true
        end,
        dismiss = function() end,
      },
      elicitation = {
        present = function(interaction)
          presented[#presented + 1] = interaction
          return true
        end,
        dismiss = function() end,
      },
    },
    notify = function() end,
    on_changed = function() end,
  })
  local events = {}
  local client = client_mod.new({
    agent = { command = "python3", args = { root .. "tests/mock_agent.py" } },
    cwd = root,
    client_capabilities = require("ade.protocol.capabilities").client(require("ade.config").effective()),
    interactions = interactions,
    agent_id = "opencode",
    transport = service_transport,
    connection = connection,
    keep_alive = opts.keep_alive ~= false,
    on_event = function(name, payload)
      events[#events + 1] = { name = name, payload = payload }
    end,
  })
  local ready
  client:start(function(started, start_err)
    ready = { ok = started, err = start_err }
  end)
  wait(function()
    return ready ~= nil
  end, 15000, "client start")
  assert(ready.ok, vim.inspect(ready.err))
  return client, interactions, presented, events
end

---Ask the service how many requests the instance has pending.
local function pending_requests()
  local count, done = nil, false
  connection:request("agent.list", {}, function(listed, value)
    done = true
    if listed and type(value) == "table" then
      count = 0
      for _, instance in ipairs(value.instances or {}) do
        count = count + (instance.pending_requests or 0)
      end
    end
  end)
  vim.wait(5000, function()
    return done
  end, 20)
  return count
end

check("a pending permission survives leave and is re-delivered", function()
  local first, interactions, presented = front_end({ keep_alive = true })
  local session
  first.start_co = require("ade.async").run(function()
    local created, result = first:new_session(root)
    assert(created, vim.inspect(result))
    session = result.sessionId
    assert(first:prompt(session, { { type = "text", text = "permission" } }, nil))
  end)
  wait(function()
    return #presented > 0
  end, 20000, "permission request reaches the first front end")
  wait(function()
    return (pending_requests() or 0) > 0
  end, 10000, "the service records the pending request")

  -- Leaving on purpose: the request must stay pending, unanswered.
  first:leave(true)
  wait(function()
    return pending_requests() == 1
  end, 10000, "the request is still pending after leave")
  assert(pending_requests() == 1, "leave must not answer the permission request")
  assert(#interactions:pending() == 0, "the local copy must be gone")

  -- A second front end attaches to the same instance and receives it again.
  local second, second_interactions, second_presented = front_end({ keep_alive = false })
  wait(function()
    return #second_presented > 0
  end, 20000, "the request is re-delivered to the new front end")
  local interaction = second_presented[1]
  assert(interaction, "the re-delivered request has no interaction")
  assert(
    second_interactions:answer(interaction.id, {
      outcome = { outcome = "selected", optionId = "allow" },
    }),
    "the re-delivered request could not be answered"
  )
  -- The mock agent waits 10 s for the answer; give the round trip a little
  -- longer so the assertion is about the answer, not about that timeout.
  wait(function()
    return pending_requests() == 0
  end, 20000, "answering it settles the request")
  second:shutdown(true)
end)

check("keep_alive = false answers the request instead of leaving it", function()
  local client, interactions, presented = front_end({ keep_alive = false })
  local session
  client.start_co = require("ade.async").run(function()
    local created, result = client:new_session(root)
    assert(created, vim.inspect(result))
    session = result.sessionId
    assert(client:prompt(session, { { type = "text", text = "permission" } }, nil))
  end)
  wait(function()
    return #presented > 0
  end, 20000, "permission request")
  client:leave(true)
  -- The agent was stopped, so nothing may be left waiting in the service.
  wait(function()
    return pending_requests() == 0
  end, 10000, "a stopped agent leaves no pending request")
  assert(#interactions:pending() == 0)
end)

-- Clean up.
for _, job in ipairs(jobs) do
  pcall(vim.fn.jobstop, job)
end
pcall(function()
  connection:request("agent.list", {}, function(listed, value)
    for _, instance in ipairs((listed and value.instances) or {}) do
      connection:request("agent.stop", { instance = instance.instance, force = true }, function() end)
    end
  end)
  vim.wait(3000)
  connection:close()
end)
service:close()
vim.fn.delete(base, "rf")

if #failures > 0 then
  io.write("\n" .. #failures .. " leave-integration failures:\n")
  for _, failure in ipairs(failures) do
    io.write("  - " .. failure .. "\n")
  end
  vim.cmd("cq 1")
else
  io.write("\nall service leave checks passed\n")
  vim.cmd("qa!")
end
