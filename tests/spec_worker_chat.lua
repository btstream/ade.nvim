-- Worker watch composer: queued send, two-step interrupt, per-worker drafts.
return function(t)
  local Watch = require("ade.ui.team.watch")
  local Config = require("ade.config")
  local State = require("ade.session.state")

  local function fake_team()
    local row = {
      id = "t1",
      cwd = "/tmp",
      state = "active",
      participants = {
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w2", state = "idle", task = "_", queued = 0, turns = {} },
      },
      inbox = {},
    }
    local team = { sends = {}, rows = { row } }
    function team:list_rows()
      return self.rows
    end
    function team:team(id)
      return id == "t1" and row or nil
    end
    function team:participant(team_id, name)
      for _, entry in ipairs(row.participants) do
        if entry.name == name then
          return entry
        end
      end
    end
    function team:watch(team_id, name, _, cb)
      local session = State.new("watch:" .. name, row.cwd)
      session.historical = true
      self.watching = {
        session = session,
        team_id = team_id,
        participant = name,
        replayed = false,
      }
      cb(true, session)
      if self.on_watch then
        self.on_watch(session, team_id .. "/" .. name)
      end
    end
    function team:unwatch() end
    function team:read(_, _, _, cb)
      cb(true, { messages = {}, turns = {} })
    end
    function team:send(team_id, to, kind, body, extra, cb)
      self.sends[#self.sends + 1] = {
        team = team_id,
        to = to,
        kind = kind,
        body = body,
        extra = extra,
      }
      if cb then
        cb(true, {})
      end
    end
    return team
  end

  local function setup(t)
    vim.cmd("tabnew")
    local host = vim.api.nvim_get_current_win()
    local team = fake_team()
    local watch = Watch.new({
      team = team,
      config = function()
        return Config.defaults
      end,
      notify = function() end,
    })
    watch.host_win = host
    team.on_watch = function(session, title)
      watch:on_watch(session, title)
    end
    t.cleanup(function()
      pcall(watch.close, watch)
      pcall(vim.cmd, "tabclose")
    end)
    watch:open("t1", "w1")
    t.eq(true, watch:is_open())
    return watch, team
  end

  t.describe("worker watch composer", function()
    t.it("queues a notice and copies the leader", function()
      local watch, team = setup(t)
      t.truthy(watch.input and watch.input.win and vim.api.nvim_win_is_valid(watch.input.win))
      t.eq("ade_team_input", vim.bo[watch.input.buf].filetype)
      watch:submit("hello w1", false)
      t.eq(1, #team.sends)
      t.eq("w1", team.sends[1].to)
      t.eq("notice", team.sends[1].kind)
      t.eq({ "leader" }, team.sends[1].extra.cc)
      t.eq(false, team.sends[1].extra.interrupt)
      t.eq("", table.concat(vim.api.nvim_buf_get_lines(watch.input.buf, 0, -1, false), "\n"))
    end)

    t.it("requires a second interrupt press and then sets interrupt", function()
      local watch, team = setup(t)
      vim.api.nvim_buf_set_lines(watch.input.buf, 0, -1, false, { "stop" })
      watch:interrupt()
      t.eq(0, #team.sends, "the first press only arms the interrupt")
      t.eq(true, watch.interrupt_armed)
      t.truthy(watch.input_hint and vim.api.nvim_win_is_valid(watch.input_hint))
      watch:interrupt()
      t.eq(1, #team.sends)
      t.eq(true, team.sends[1].extra.interrupt)
      t.eq(false, watch.interrupt_armed)
    end)

    t.it("keeps a draft per worker and hides the input for the leader", function()
      local watch = setup(t)
      vim.api.nvim_buf_set_lines(watch.input.buf, 0, -1, false, { "for w1" })
      watch:switch("t1", "w2")
      vim.wait(50)
      t.eq("w2", watch.participant)
      t.eq("", table.concat(vim.api.nvim_buf_get_lines(watch.input.buf, 0, -1, false), "\n"))
      vim.api.nvim_buf_set_lines(watch.input.buf, 0, -1, false, { "for w2" })
      watch:switch("t1", "w1")
      vim.wait(50)
      t.eq("for w1", table.concat(vim.api.nvim_buf_get_lines(watch.input.buf, 0, -1, false), "\n"))
      watch:open("t1", "leader")
      t.eq(true, watch.leader_active)
      t.eq(false, watch.input.win ~= nil and vim.api.nvim_win_is_valid(watch.input.win))
    end)
  end)
end
