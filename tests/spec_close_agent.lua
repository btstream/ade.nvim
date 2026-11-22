return function(t)
  local Flow = require("ade.app.connection_flow")
  local Commands = require("ade.service.commands")
  local fake = require("tests.fake_connection")

  t.describe("close agent flow", function()
    local function row(id, agent, fields)
      return vim.tbl_extend("force", { instance = id, agent = agent, cwd = "/proj" }, fields or {})
    end

    local function run(stopped, remaining, replace_client)
      local state = {
        config = { backend = "service", agent = "pi", agents = { pi = {}, opencode = {}, claude = {} } },
        conn = { client = { proc = { instance = "current-pi" } }, service = {} },
        sess = { all = {} },
      }
      local reads, switched, opened, hidden = 0, nil, false, false
      local connection = fake.new({
        responders = {
          ["agent.list"] = function()
            reads = reads + 1
            return true, { instances = reads == 1 and { stopped } or remaining }
          end,
          ["agent.stop"] = function()
            if replace_client then
              state.conn.client = {}
            end
            return true, {}
          end,
        },
      })
      local original = Commands.close_agent
      t.cleanup(function()
        Commands.close_agent = original
      end)
      Commands.close_agent = function(name, opts)
        opts.connection = connection
        return original(name, opts)
      end
      Flow.new({
        state = function()
          return state
        end,
        cwd = function()
          return "/proj"
        end,
        notify = function() end,
        setup = function(opts)
          switched = opts.agent
        end,
        open = function()
          opened = true
        end,
        hide = function()
          hidden = true
        end,
      }):close_agent("pi")
      t.truthy(vim.wait(1000, function()
        return connection.pending == 0
      end, 5))
      t.eq(opened, switched ~= nil)
      return switched, reads, hidden
    end

    t.it("switches and opens the sole eligible fallback after stopping the current instance", function()
      local switched, reads = run(row("current-pi", "pi"), {
        row("opencode", "opencode"),
        row("other-cwd", "claude", { cwd = "/other" }),
        row("worker", "claude", { team = "team-1" }),
        row("stopping", "claude", { stopping = true }),
        row("unconfigured", "custom"),
      })
      t.eq("opencode", switched)
      t.eq(2, reads)
    end)

    t.it("does not switch after stopping a same-name background instance", function()
      local switched, reads = run(row("background-pi", "pi"), { row("opencode", "opencode") })
      t.eq(nil, switched)
      t.eq(1, reads)
    end)

    t.it("does not switch when the panel client has changed", function()
      local switched = run(row("current-pi", "pi"), { row("opencode", "opencode") }, true)
      t.eq(nil, switched)
    end)

    t.it("does not switch when more than one candidate remains", function()
      local switched, _, hidden = run(row("current-pi", "pi"), { row("opencode", "opencode"), row("claude", "claude") })
      t.eq(nil, switched)
      t.falsy(hidden)
    end)

    t.it("hides the panel after stopping the last agent in the project", function()
      local switched, _, hidden = run(row("current-pi", "pi"), { row("other", "opencode", { cwd = "/other" }) })
      t.eq(nil, switched)
      t.truthy(hidden)
    end)
  end)
end
