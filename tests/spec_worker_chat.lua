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
        cb(not self.fail, self.fail and { message = "failed" } or {})
      end
    end
    return team
  end

  local function setup(t, over)
    vim.cmd("tabnew")
    local host = vim.api.nvim_get_current_win()
    local team = fake_team()
    local watch = Watch.new({
      team = team,
      config = function()
        return over and over.config or Config.defaults
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

  t.it("rejects an interrupt key that clashes with the send key", function()
    local config = vim.deepcopy(Config.defaults)
    config.teams.dashboard.keys.interrupt = "<C-s>"
    local ok = pcall(Config.validate, config)
    t.eq(false, ok)
  end)

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

    t.it("keeps the text and reports a failed send", function()
      local watch, team = setup(t)
      team.fail = true
      vim.api.nvim_buf_set_lines(watch.input.buf, 0, -1, false, { "keep me" })
      watch:submit("keep me", false)
      t.eq(1, #team.sends)
      t.eq("keep me", table.concat(vim.api.nvim_buf_get_lines(watch.input.buf, 0, -1, false), "\n"))
    end)

    t.it("does not arm an empty interrupt and shows its own winbar", function()
      local watch, team = setup(t)
      vim.api.nvim_buf_set_lines(watch.input.buf, 0, -1, false, { "" })
      watch:interrupt()
      t.eq(false, watch.interrupt_armed)
      t.eq(0, #team.sends)
      watch.input:apply_winbar()
      local winbar = vim.api.nvim_get_option_value("winbar", { win = watch.input.win })
      t.match("→ w1", winbar)
      t.falsy(winbar:find("AdeComposerBar", 1, true))
    end)

    t.it("expands key list and false send configuration", function()
      local config = vim.deepcopy(Config.defaults)
      config.keymaps.input.send = { "<C-s>", "<C-x>" }
      local watch = setup(t, { config = config })
      local maps = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(watch.input.buf, "n")) do
        maps[map.lhs:lower()] = true
      end
      t.eq(true, maps["<c-x>"], "the second configured send key is bound")

      local second = setup(t, {
        config = (function()
          local copy = vim.deepcopy(Config.defaults)
          copy.keymaps.input.send = false
          return copy
        end)(),
      })
      local c_s = false
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(second.input.buf, "n")) do
        if map.lhs:lower() == "<c-s>" then
          c_s = true
        end
      end
      t.eq(false, c_s, "send=false must not bind <C-s>")
    end)

    t.it("resizes the composer together with the watch and stays stable", function()
      local Tab = require("ade.ui.team.layout_tab")
      local function new_window()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        return buf
      end
      vim.cmd("tabnew")
      local tab = Tab.new({})
      tab.tab = vim.api.nvim_get_current_tabpage()
      new_window()
      tab.panels.members = vim.api.nvim_get_current_win()
      vim.cmd("vsplit")
      new_window()
      tab.panels.board = vim.api.nvim_get_current_win()
      vim.cmd("vsplit")
      new_window()
      tab.watch_win = vim.api.nvim_get_current_win()
      vim.cmd("split")
      local input_buf = new_window()
      local input = vim.api.nvim_get_current_win()
      vim.bo[input_buf].filetype = "ade_team_input"
      t.cleanup(function()
        if vim.api.nvim_tabpage_is_valid(tab.tab) then
          pcall(vim.cmd, "tabclose")
        end
      end)
      t.eq(2, #tab:right_windows(), "the watch and its composer share the column")
      vim.o.columns = 200
      tab.members_width = 32
      tab:resize()
      local watch_width = vim.api.nvim_win_get_width(tab.watch_win)
      t.eq(watch_width, vim.api.nvim_win_get_width(input))
      for _ = 1, 3 do
        tab:resize()
      end
      t.eq(watch_width, vim.api.nvim_win_get_width(tab.watch_win))
      t.eq(watch_width, vim.api.nvim_win_get_width(input))
    end)

    t.it("focuses the composer with i", function()
      local watch = setup(t)
      vim.api.nvim_set_current_win(watch.win)
      local maps = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(watch.buf, "n")) do
        maps[map.lhs] = map.callback
      end
      t.truthy(maps["i"])
      maps["i"]()
      t.eq(watch.input.win, vim.api.nvim_get_current_win())
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
