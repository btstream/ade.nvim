-- Burst pressure: a streaming agent must not starve the main loop.
--
-- Both backends dispatch inbound frames through the shared work scheduler in
-- bounded slices. This test pushes 5000 `session/update` notifications back to
-- back and checks that a 50 ms timer keeps firing: if a slice ever held the loop
-- for the whole burst, the gap between timer ticks would blow up.
--
-- The direct case runs the same shape through `process.spawn` with a scripted
-- process, so the two numbers are comparable (the report quotes both).
return function(t)
  local Scheduler = require("ade.ui.work_scheduler")
  local service_client = require("ade.service.client")
  local service_transport = require("ade.service.transport")
  local fake = require("tests.fake_service")

  local COUNT = 5000
  local TICK_MS = 50
  local MAX_GAP_MS = 200

  local counter = 0
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-burst-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.mkdir(dir, "p")
    t.cleanup(function()
      vim.fn.delete(dir, "rf")
    end)
    return dir
  end

  ---A scheduler with a real budget, shared by the client under test.
  local function new_scheduler()
    local scheduler = Scheduler.new({ budget_ms = 4 })
    t.cleanup(function()
      if scheduler.dispose then
        scheduler:dispose()
      end
    end)
    return scheduler
  end

  ---Record the largest gap between timer ticks while `run` executes.
  ---@param run fun(done: fun())
  ---@return table result `{max_gap_ms, ticks, elapsed_ms}`
  local function measure_ticks(run)
    local timer
    local last = vim.uv.hrtime()
    local max_gap = 0
    local ticks = 0
    local started = vim.uv.hrtime()
    timer = vim.uv.new_timer()
    timer:start(
      TICK_MS,
      TICK_MS,
      vim.schedule_wrap(function()
        local now = vim.uv.hrtime()
        local gap = (now - last) / 1e6
        if gap > max_gap then
          max_gap = gap
        end
        last = now
        ticks = ticks + 1
      end)
    )
    local finished = false
    run(function()
      finished = true
    end)
    vim.wait(60000, function()
      return finished
    end, 5)
    -- Let one more tick land so the final gap is measured too.
    vim.wait(TICK_MS * 2)
    pcall(function()
      timer:stop()
      timer:close()
    end)
    return {
      max_gap_ms = max_gap,
      ticks = ticks,
      elapsed_ms = (vim.uv.hrtime() - started) / 1e6,
    }
  end

  ---One `session/update` notification, shaped like a streamed chunk.
  local function chunk(index)
    return {
      jsonrpc = "2.0",
      method = "session/update",
      params = {
        sessionId = "sess_mock",
        update = {
          sessionUpdate = "agent_message_chunk",
          content = { type = "text", text = "chunk " .. index },
        },
      },
    }
  end

  t.describe("inbox bound", function()
    t.it("drops the connection instead of a frame when the ceiling is passed", function()
      local scheduler = new_scheduler()
      local client = service_client.new({
        scheduler = scheduler,
        dispatch_budget_ms = 4,
        -- Small ceiling: each frame below is a few hundred bytes.
        max_inbox_bytes = 2000,
      })
      client.rpc = { handle = function() end, close = function() end }
      client.ready = true
      local reasons = {}
      -- `Client:on_disconnect` is the method; the callback it invokes is the
      -- `on_disconnect_cb` field, set by `Connection:install_handlers`.
      client.on_disconnect_cb = function(reason)
        reasons[#reasons + 1] = reason
      end

      -- Fill past the ceiling. Dispatch never runs, so the queue keeps growing
      -- until the overflow has to be handled.
      for index = 1, 100 do
        client:enqueue(chunk(index))
      end

      -- PROTOCOL.md 7: never drop a frame silently. The front end gives up the
      -- connection instead, because a missing response or permission request
      -- would hang or corrupt state invisibly.
      t.eq(1, #reasons, "the overflow must be reported exactly once")
      t.eq(service_client.OVERFLOW_REASON, reasons[1])
      t.match("overflow", reasons[1])
      t.eq(true, client.closed, "the client must consider the connection gone")
      t.eq(0, #client.inbox, "the inbox must be cleared")
      t.eq(0, client.inbox_bytes, "the byte accounting must be reset")
      t.eq(0, client.dispatches, "no frame may be dispatched after the overflow")
    end)

    t.it("tells the instance channels the front end could not keep up", function()
      -- The wording matters: an overflow is the front end's failure, not the
      -- agent's, and the message has to say reconnecting will help.
      local transport = require("ade.service.transport")
      local channel_exit = nil
      local channel = assert(transport.spawn({
        connection = {
          subscribe = function() end,
          unsubscribe_all = function() end,
          request = function(_, _, _, cb)
            if cb then
              cb(true, { instance = "inst-1" })
            end
          end,
          notify = function()
            return true
          end,
        },
        command = "agent",
        args = {},
        cwd = "/tmp",
        on_exit = function(code, stderr)
          channel_exit = { code = code, stderr = stderr }
        end,
      }))
      -- This is what `Connection:on_disconnect` fan-outs with after an overflow.
      channel:on_service_lost({ reason = service_client.OVERFLOW_REASON })
      t.truthy(channel_exit, "the channel must be told the connection is gone")
      t.eq(-1, channel_exit.code)
      t.match("client inbox overflow", channel_exit.stderr)
      t.match("stopped keeping up", channel_exit.stderr)
      t.match("reconnecting resumes", channel_exit.stderr)
      t.eq(false, channel:is_alive())
    end)

    t.it("dispatches everything when the ceiling is not reached", function()
      local scheduler = new_scheduler()
      local decoded = 0
      local client = service_client.new({ scheduler = scheduler, dispatch_budget_ms = 4 })
      client.rpc = {
        handle = function()
          decoded = decoded + 1
        end,
        close = function() end,
      }
      client.ready = true
      for index = 1, 200 do
        client:enqueue(chunk(index))
      end
      client:schedule_drain()
      vim.wait(10000, function()
        return decoded >= 200
      end, 5)
      t.eq(200, decoded)
      t.eq(false, client.inbox_overflowed, "a burst under the ceiling must not disconnect")
      t.eq(false, client.closed)
      client:close()
    end)
  end)

  t.describe("burst pressure", function()
    t.it("service path keeps timers alive under 5000 chunks", function()
      -- The inbox is filled *before* draining starts. A live socket delivers a
      -- burst in several reads, which would make the burst look smaller than it
      -- is; what has to survive here is the dispatcher holding 5000 pending
      -- frames at once.
      local scheduler = new_scheduler()
      local decoded = 0
      -- Each frame costs real work: without a time budget the whole burst would
      -- hold the loop for hundreds of milliseconds, which is exactly what the
      -- timer-gap assertion below is meant to catch.
      local WORK = 4000
      local function handle()
        local acc = 0
        for index = 1, WORK do
          acc = acc + index % 7
        end
        decoded = decoded + (acc >= 0 and 1 or 0)
      end

      local client = service_client.new({ scheduler = scheduler, dispatch_budget_ms = 4 })
      client.rpc = { handle = handle, close = function() end }
      client.ready = true

      local result = measure_ticks(function(done)
        for index = 1, COUNT do
          client:enqueue(chunk(index))
        end
        client:schedule_drain()
        vim.wait(60000, function()
          return decoded >= COUNT and not client.inbox[1] and not client.draining
        end, 5)
        done()
      end)

      t.eq(COUNT, decoded, "every frame must be dispatched")
      t.truthy(
        result.max_gap_ms < MAX_GAP_MS,
        string.format("a timer stalled for %.1f ms (limit %d)", result.max_gap_ms, MAX_GAP_MS)
      )
      t.truthy(client.dispatch_slices > 1, "dispatch must be split into slices")
      t.truthy(client.max_dispatch_ms <= 40, string.format("one dispatch slice took %.1f ms", client.max_dispatch_ms))
      client:close()
      io.write(
        string.format(
          "     service: %d frames, %d slices, max slice %.2f ms, elapsed %.0f ms, max tick gap %.2f ms\n",
          decoded,
          client.dispatch_slices,
          client.max_dispatch_ms,
          result.elapsed_ms,
          result.max_gap_ms
        )
      )
    end)

    t.it("service path dispatches real socket frames in the same bounds", function()
      -- A smaller live check that the bytes really do travel: 800 frames over a
      -- real unix socket, still sliced.
      local scheduler = new_scheduler()
      local dir = tmpdir("svc-live")
      local service = fake.new({ dir = dir })
      t.cleanup(function()
        service:close()
      end)
      assert(service:listen())
      local saved = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved
      end)

      local live_count = 800
      local decoded = 0
      local client = service_client.new({ scheduler = scheduler, dispatch_budget_ms = 4, timeout = 3000 })
      client.rpc = {
        handle = function()
          decoded = decoded + 1
        end,
        close = function() end,
      }
      local connected = false
      client.pipe = vim.uv.new_pipe(false)
      client.pipe:connect(service:socket(), function(err)
        connected = err == nil
      end)
      vim.wait(3000, function()
        return connected
      end, 10)
      t.truthy(connected)
      client:read_loop()
      local peer = service.clients[#service.clients]
      t.truthy(peer, "the fake service did not accept the connection")
      for index = 1, live_count do
        peer.peer:write(vim.json.encode({
          jsonrpc = "2.0",
          method = "tunnel.recv",
          params = { instance = "inst-1", seq = index, message = chunk(index) },
        }) .. "\n")
      end
      vim.wait(30000, function()
        return decoded >= live_count
      end, 5)
      t.eq(live_count, decoded, "every socket frame must be dispatched")
      client:close()
      service:close()
    end)

    t.it("direct path keeps timers alive under the same burst", function()
      -- Drive the *real* receive path: script jobstart, feed one stdout callback
      -- with the whole burst, and let the direct transport's own budget loop
      -- dispatch it. That is the mechanism the service path has to match.
      local process = require("ade.transport.process")
      local work = require("ade.ui.work_scheduler")
      local scheduler = work.new({ budget_ms = 4 })
      t.cleanup(function()
        if scheduler.dispose then
          scheduler:dispose()
        end
      end)

      local original_start, original_stop = vim.fn.jobstart, vim.fn.jobstop
      local callbacks
      vim.fn.jobstart = function(_, value)
        callbacks = value
        return 999999
      end
      vim.fn.jobstop = function() end
      t.cleanup(function()
        vim.fn.jobstart, vim.fn.jobstop = original_start, original_stop
      end)

      local delivered = 0
      -- Same per-frame cost as the service case, so the two measurements are
      -- comparable: a cheap handler would finish the whole burst inside the
      -- first callback and prove nothing about scheduling.
      local WORK = 4000
      local proc = assert(process.spawn({
        command = "mock",
        scheduler = scheduler,
        dispatch_budget_ms = 4,
        max_line_bytes = 1024 * 1024,
        on_line = function()
          local acc = 0
          for index = 1, WORK do
            acc = acc + index % 7
          end
          delivered = delivered + (acc >= 0 and 1 or 0)
        end,
        on_exit = function() end,
      }))
      t.cleanup(function()
        proc:stop(true)
      end)

      local data = {}
      for index = 1, COUNT do
        data[index] = vim.json.encode(chunk(index))
      end
      data[#data + 1] = ""

      local result = measure_ticks(function(done)
        callbacks.on_stdout(999999, data)
        vim.wait(60000, function()
          return delivered >= COUNT and scheduler:depth() == 0
        end, 10)
        done()
      end)

      t.eq(COUNT, delivered, "every line must be dispatched")
      -- `input_resumes` may be 1: a single callback can finish a burst of small
      -- frames within its budget, which is correct. The bound that matters is
      -- the timer gap below.
      t.truthy(
        result.max_gap_ms < MAX_GAP_MS,
        string.format("a timer stalled for %.1f ms (limit %d)", result.max_gap_ms, MAX_GAP_MS)
      )
      io.write(
        string.format(
          "     direct:  %d lines, elapsed %.0f ms, max tick gap %.2f ms\n",
          delivered,
          result.elapsed_ms,
          result.max_gap_ms
        )
      )
    end)
  end)
end
