-- The team router: the ordinary chat/input pair is the only worker transcript
-- and the only composer. These tests pin the sending semantics the old watch
-- composer had (queued notice, cc to the leader, explicit interrupt), the
-- per-target draft isolation, and the stale-callback safety.
return function(t)
  local Router = require("ade.ui.team.router")
  local Config = require("ade.config")
  local State = require("ade.session.state")

  ---@param router table
  ---@return string|nil
  local function session_id(router)
    return router.chat and router.chat.session and router.chat.session.id
  end

  local function fake_team(over)
    over = over or {}
    local row = {
      id = "t1",
      cwd = "/tmp",
      state = "active",
      participants = {
        { name = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w1", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "w2", state = "idle", task = "_", queued = 0, turns = {}, state = over.w2_state or "idle" },
      },
      inbox = {},
    }
    local team = { sends = {}, rows = { row }, watching = nil, unwatches = 0 }
    function team:list_rows()
      return self.rows
    end
    function team:team(id)
      return id == "t1" and row or nil
    end
    function team:resolve_cwd()
      return "/tmp"
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
      self.watching = { session = session, team_id = team_id, participant = name, replayed = true }
      if self.defer_watch then
        self.deferred = function()
          cb(true, { sessionId = "sess-" .. name, replayed = true })
          if self.on_watch then
            self.on_watch(session, team_id .. "/" .. name)
          end
        end
        return
      end
      cb(true, { sessionId = "sess-" .. name, replayed = true })
      if self.on_watch then
        self.on_watch(session, team_id .. "/" .. name)
      end
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
    function team:unwatch()
      self.watching = nil
      self.unwatches = self.unwatches + 1
      if self.on_watch then
        self.on_watch(nil, nil)
      end
    end
    return team
  end

  local function fake_chat(cfg)
    local chat = {
      buf = vim.api.nvim_create_buf(false, true),
      win = nil,
      session = nil,
      follow = true,
      renders = 0,
      config = vim.deepcopy(cfg or Config.defaults),
    }
    vim.bo[chat.buf].filetype = "ade_chat"
    chat.win = vim.api.nvim_open_win(chat.buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 50,
      height = 10,
      style = "minimal",
    })
    function chat:set_session(session)
      self.session = session
    end
    function chat:schedule_render()
      self.renders = self.renders + 1
    end
    function chat:toggle_current()
      return false
    end
    return chat
  end

  local function fake_input()
    local input = { buf = vim.api.nvim_create_buf(false, true), drafts = {}, attachments = {} }
    vim.bo[input.buf].filetype = "ade_input"
    local function set(lines)
      vim.bo[input.buf].modifiable = true
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, lines)
      vim.bo[input.buf].modifiable = false
    end
    set({ "" })
    function input:text()
      return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
    end
    function input:lines()
      return vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
    end
    function input:set_lines(lines)
      set(lines)
    end
    function input:clear()
      if self.key then
        self.drafts[self.key] = nil
      end
      self.attachments = {}
      set({ "" })
    end
    input.session_key = nil
    input.draft_epoch = 0
    function input:switch_session(key, restored)
      if self.session_key then
        self.drafts[self.session_key] = table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
      end
      self.session_key = key
      self.draft_epoch = self.draft_epoch + 1
      local text = (restored and restored.text) or self.drafts[key] or ""
      self.attachments = {}
      set(vim.split(text, "\n", { plain = true }))
    end
    function input:apply_winbar()
      return true
    end
    input.win = vim.api.nvim_open_win(input.buf, false, {
      relative = "editor",
      row = 12,
      col = 0,
      width = 50,
      height = 4,
      style = "minimal",
    })
    return input
  end

  local function setup(t, over)
    over = over or {}
    local team = fake_team(over)
    local chat = fake_chat(over.config or Config.defaults)
    local input = fake_input()
    local leader = State.new("leader", "/tmp")
    local router = Router.new({
      team = team,
      config = function()
        return over.config or Config.defaults
      end,
      notify = function() end,
      panel = function()
        return nil
      end,
      leader_chat = function()
        return chat
      end,
      leader_input = function()
        return input
      end,
      current_session = function()
        return leader
      end,
    })
    team.on_watch = function(session, title)
      router:on_watch(session, title)
    end
    t.cleanup(function()
      pcall(router.close, router)
      if chat.win and vim.api.nvim_win_is_valid(chat.win) then
        pcall(vim.api.nvim_win_close, chat.win, true)
      end
    end)
    return router, team, chat, input, leader
  end

  t.it("rejects an interrupt key that clashes with the send key", function()
    local config = vim.deepcopy(Config.defaults)
    config.teams.dashboard.keys.interrupt = "<C-s>"
    local ok = pcall(Config.validate, config)
    t.eq(false, ok)
  end)

  t.describe("team router", function()
    t.it("queues a notice and copies the leader", function()
      local router, team, chat, input = setup(t)
      t.eq(true, router:select("t1", "w1"))
      t.truthy(chat._ade_team_display, "the shared chat shows the display session")
      t.eq("watch:w1", chat.session and chat.session.id)
      router:submit("hello w1", {})
      t.eq(1, #team.sends)
      t.eq("w1", team.sends[1].to)
      t.eq("notice", team.sends[1].kind)
      t.eq({ "leader" }, team.sends[1].extra.cc)
      t.eq(false, team.sends[1].extra.interrupt)
      t.eq("", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
    end)

    t.it("requires a second interrupt press and then sets interrupt", function()
      local router, team, _, input = setup(t)
      router:select("t1", "w1")
      input:set_lines({ "stop" })
      router:interrupt()
      t.eq(0, #team.sends, "the first press only arms the interrupt")
      t.eq(true, router.interrupt_armed)
      t.truthy(router.interrupt_win, "the confirmation hint is visible")
      router:interrupt()
      t.eq(1, #team.sends)
      t.eq(true, team.sends[1].extra.interrupt)
      t.eq(false, router.interrupt_armed)
      t.eq(nil, router.interrupt_win)
    end)

    t.it("keeps the text and reports a failed send", function()
      local router, team, _, input = setup(t)
      local notices = {}
      router.notify_fn = function(message)
        notices[#notices + 1] = tostring(message)
      end
      router:select("t1", "w1")
      team.fail = true
      -- Simulate the bus refusing the send.
      team.send = function(self, team_id, to, kind, body, extra, cb)
        self.sends[#self.sends + 1] = { to = to, kind = kind, body = body, extra = extra }
        if cb then
          cb(false, { message = "refused" })
        end
      end
      input:set_lines({ "keep me" })
      router:submit("keep me", {})
      t.eq("keep me", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      t.truthy(table.concat(notices, "\n"):find("refused", 1, true))
    end)

    t.it("does not arm an empty interrupt", function()
      local router, team, _, input = setup(t)
      router:select("t1", "w1")
      input:set_lines({ "  " })
      router:interrupt()
      t.eq(false, router.interrupt_armed)
      t.eq(0, #team.sends)
    end)

    t.it("keeps a draft per worker, isolated from the leader", function()
      local router, _, _, input, leader = setup(t)
      router:select("t1", "w1")
      input:set_lines({ "for w1" })
      router:select("t1", "w2")
      t.eq("", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      input:set_lines({ "for w2" })
      router:select("t1", "w1")
      t.eq("for w1", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      router:restore_leader(true)
      t.eq(nil, router.target)
      t.eq(leader.id, session_id(router), "the leader session is back in the transcript")
      t.eq(leader.id, input.session_key)
    end)

    t.it("returns to the leader and leaves the ordinary session untouched", function()
      local router, _, chat, input, leader = setup(t)
      leader.blocks = { { id = "a", kind = "agent", text = "leader reply" } }
      router:select("t1", "w1")
      router:restore_leader(true)
      t.eq(nil, router.target)
      t.eq(leader, chat.session)
      t.eq(nil, chat._ade_team_display)
      t.eq(leader.id, input.session_key)
    end)

    t.it("refuses attachments with a notice and keeps the draft", function()
      local router, team, _, input = setup(t)
      local notices = {}
      router.notify_fn = function(message)
        notices[#notices + 1] = tostring(message)
      end
      router:select("t1", "w1")
      input:set_lines({ "see attached" })
      router:submit("see attached", { { kind = "file", path = "/tmp/a.lua" } })
      t.eq(0, #team.sends, "nothing is sent without the attachment")
      t.eq("see attached", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      t.match("附件", table.concat(notices, "\n"))
    end)

    t.it("only replays an exited worker and refuses to send", function()
      local router, team, chat, input = setup(t, { w2_state = "exited" })
      router:select("t1", "w2")
      t.truthy(chat._ade_team_display, "the transcript is still shown")
      local notices = {}
      router.notify_fn = function(message)
        notices[#notices + 1] = tostring(message)
      end
      input:set_lines({ "still there?" })
      router:submit("still there?", {})
      t.eq(0, #team.sends)
      t.match("已退出", table.concat(notices, "\n"))
    end)

    t.it("ignores a stale frame from a superseded target", function()
      local router, team, chat = setup(t)
      router:select("t1", "w1")
      local first = router.source
      router:select("t1", "w2")
      -- A late frame from w1's replay must not repaint w2's transcript.
      router:on_watch(first, "t1/w1")
      t.eq("w2", router.target.participant)
      t.eq("watch:w2", router.source and router.source.id)
      t.eq("watch:w2", chat.session.id)
      t.eq("w2", team.watching.participant)
    end)

    t.it("serializes replays and skips intermediate targets", function()
      local router, team = setup(t)
      local started = {}
      team.defer_watch = true
      local queue = {}
      team.deferred = nil
      team.watch = function(self, team_id, name, _, cb)
        started[#started + 1] = name
        queue[#queue + 1] = function()
          self.watching = { session = State.new("watch:" .. name, "/tmp"), participant = name, team_id = team_id }
          cb(true, { sessionId = "sess-" .. name, replayed = true })
          if self.on_watch then
            self.on_watch(self.watching.session, team_id .. "/" .. name)
          end
        end
      end
      router:select("t1", "w1")
      router:select("t1", "w2")
      router:select("t1", "w3")
      t.eq("w1", started[1], "only the first request is in flight")
      queue[1]()
      t.eq("w3", started[2], "the intermediate target is skipped")
      queue[2]()
      t.eq("w3", router.target.participant)
      t.eq(2, #started)
    end)

    t.it("returns to the leader when the watch is released", function()
      local router, team, chat = setup(t)
      router:select("t1", "w1")
      team.on_watch(nil, nil)
      t.eq(nil, router.target)
      t.eq(nil, chat._ade_team_display)
    end)

    t.it("a late send callback never clears another target's draft", function()
      local router, team, _, input, leader = setup(t)
      local pending
      team.send = function(self, team_id, to, kind, body, extra, cb)
        self.sends[#self.sends + 1] = { to = to, body = body, extra = extra }
        pending = cb
      end
      router:select("t1", "w1")
      input:set_lines({ "for w1" })
      router:submit("for w1", {})
      t.eq(1, #team.sends)
      -- The person leaves before the service answers.
      router:restore_leader(true)
      input:set_lines({ "leader draft" })
      pending(true, {})
      t.eq("leader draft", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
      t.eq(leader.id, input.session_key)
    end)

    t.it("a late send callback keeps text typed after the send", function()
      local router, team, _, input = setup(t)
      local pending
      team.send = function(self, _, to, kind, body, extra, cb)
        self.sends[#self.sends + 1] = { to = to, body = body }
        pending = cb
      end
      router:select("t1", "w1")
      input:set_lines({ "first" })
      router:submit("first", {})
      -- The person starts typing the next message before the answer arrives.
      input:set_lines({ "second" })
      pending(true, {})
      t.eq("second", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
    end)

    t.it("clears only the composer that submitted the message", function()
      local router, team, _, input = setup(t)
      local pending
      team.send = function(self, _, to, kind, body, extra, cb)
        self.sends[#self.sends + 1] = { to = to, body = body }
        pending = cb
      end
      router:select("t1", "w1")
      input:set_lines({ "hello" })
      router:submit("hello", {})
      pending(true, {})
      t.eq("", table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n"))
    end)

    t.it("release restores the ordinary chat config and paging", function()
      local router, _, chat = setup(t)
      local ordinary = chat.config
      local ordinary_pagination = ordinary.ui.render.pagination
      router:select("t1", "w1")
      t.truthy(chat.config ~= ordinary, "the worker view uses its own config")
      t.eq(true, chat.config.ui.render.pagination.enabled)
      t.eq(ordinary_pagination.enabled, ordinary.ui.render.pagination.enabled, "the shared config is untouched")
      t.eq(nil, ordinary.ui.render.pagination.turn_start, "no paging hooks leaked into the ordinary config")
      router:restore_leader(false)
      t.eq(ordinary, chat.config, "the ordinary config is back")
    end)

    t.it("release restores the keys the worker view replaced", function()
      local router, _, chat = setup(t)
      local calls = 0
      local function map_of(lhs)
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(chat.buf, "n")) do
          if map.lhs == lhs then
            return map
          end
        end
      end
      vim.keymap.set("n", "gl", function()
        calls = calls + 1
      end, { buffer = chat.buf, desc = "ordinary mapping" })
      local before = map_of("gl")
      t.truthy(before and before.callback, "the ordinary gl mapping exists")
      router:select("t1", "w1")
      local mapped = map_of("gl")
      t.truthy(mapped and mapped.callback, "the worker view binds gl")
      t.eq(1, mapped.callback ~= before.callback and 1 or 0, "the worker view replaced the key")
      router:restore_leader(false)
      local restored = map_of("gl")
      t.truthy(restored and restored.callback, "the previous gl mapping is restored")
      restored.callback()
      t.eq(1, calls, "the ordinary mapping runs again")
    end)

    t.it("a late frame cannot reopen a released worker", function()
      local router, team, chat = setup(t)
      router:select("t1", "w1")
      local stale = router.source
      router:restore_leader(false)
      -- The team no longer holds a watch; the frame belongs to nobody.
      team.watching = nil
      router:on_watch(stale, "t1/w1")
      t.eq(nil, router.target, "the stale frame must not re-adopt the worker")
      t.eq(nil, chat._ade_team_display)
      t.eq(nil, team.watching)
    end)

    t.it("a superseded watch answer cannot clear the newer request", function()
      local router, team = setup(t)
      local callbacks = {}
      team.watch = function(self, team_id, name, _, cb)
        callbacks[#callbacks + 1] = { name = name, cb = cb }
        self.watching = { participant = name, team_id = team_id, session = State.new("watch:" .. name, "/tmp") }
      end
      router:select("t1", "w1")
      t.eq("w1", callbacks[1].name, "the first request starts immediately")
      -- A newer select while w1's replay is still in flight.
      router:select("t1", "w2")
      t.eq(true, router.watch_inflight, "w1 is still in flight")
      callbacks[1].cb(false, { message = "stale failure" })
      t.eq(true, router.watch_inflight, "the stale answer must not clear the newer request")
      t.eq("w2", router.target.participant, "the target is unchanged")
      -- The stale answer releases the in-flight slot and starts the queued
      -- request; it never touches the newer target itself.
      t.eq("w2", callbacks[#callbacks].name, "the queued target starts next")
      t.truthy(#callbacks <= 2, "no request is duplicated")
    end)
  end)
end
