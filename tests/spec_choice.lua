return function(t)
  local Choice = require("ade.ui.choice")
  local Choices = require("ade.app.choices")

  local function window()
    vim.cmd("tabnew")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, 6)
    return win, buf
  end

  local function close_window()
    pcall(vim.cmd, "tabclose")
  end

  t.describe("inline choice component", function()
    t.it("borrows the composer window and restores the original buffer", function()
      local win, original = window()
      local submitted
      local view = Choice.new({ notify = function() end })
      local model = {
        title = "r1 提问",
        questions = {
          {
            header = "Scope",
            question = "Which scope?",
            options = { { label = "A" }, { label = "B" } },
          },
        },
        on_submit = function(answers)
          submitted = answers
        end,
      }
      t.eq(true, view:show(model, { win = win, external = false, max_height = 5 }))
      local buf = vim.api.nvim_win_get_buf(win)
      t.eq("ade_input", vim.bo[buf].filetype)
      t.eq(true, vim.b[buf].ade_choice)
      t.eq(false, vim.bo[buf].modifiable)
      t.truthy(vim.api.nvim_win_get_height(win) <= 5)
      view:select(2)
      view:submit()
      t.eq("B", submitted[1].selected[1])
      t.eq(original, vim.api.nvim_win_get_buf(win), "the composer buffer comes back")
      close_window()
    end)

    t.it("toggles multi-select choices and submits every question", function()
      local win = window()
      local submitted
      local view = Choice.new({ notify = function() end })
      view:show({
        title = "two",
        questions = {
          {
            header = "Scope",
            question = "one?",
            options = { { label = "A" }, { label = "B" } },
          },
          {
            header = "Tests",
            question = "many?",
            options = { { label = "unit" }, { label = "integration" } },
            multi_select = true,
          },
        },
        on_submit = function(answers)
          submitted = answers
        end,
      }, { win = win, external = false, max_height = 8 })
      view:select(1)
      view:toggle()
      view.cursor = 2
      view:toggle()
      view:advance()
      view:submit()
      t.eq("A", submitted[1].selected[1])
      t.eq({ "unit", "integration" }, submitted[2].selected)
      close_window()
    end)

    t.it("leaves custom text mode when insert mode ends and keeps the text", function()
      local win = window()
      local view = Choice.new({ notify = function() end })
      view:show({
        title = "other",
        questions = {
          {
            header = "Q",
            question = "pick",
            options = { { label = "A" }, { label = "B" } },
            allow_custom = true,
          },
        },
        on_submit = function() end,
      }, { win = win, external = false, max_height = 8 })
      view:select(3) -- Other
      t.eq(true, view.custom)
      t.eq(0, #view.answers[1].selected, "Other clears the single selection")
      vim.api.nvim_buf_set_lines(view.buf, view.custom_line - 1, view.custom_line, false, { " 其他: typed" })
      vim.cmd("stopinsert")
      vim.api.nvim_exec_autocmds("InsertLeave", { buffer = view.buf })
      vim.wait(20)
      t.eq(false, view.custom)
      t.eq("typed", view.answers[1].text)
      view:close()
      close_window()
    end)

    t.it("anchors attachments at the draft end while the choice buffer shows", function()
      local win = window()
      local Input = require("ade.ui.input")
      local input = Input.new({
        config = { ui = { toolbar = { placement = "off" } } },
        on_submit = function() end,
        on_cancel = function() end,
      })
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "abc", "de" })
      local choice_buf = vim.api.nvim_create_buf(false, true)
      vim.b[choice_buf].ade_choice = true
      vim.api.nvim_win_set_buf(win, choice_buf)
      input.win = win
      t.eq({ 1, 2 }, input:cursor_position(), "append to the end of the draft")
      input:destroy()
      close_window()
    end)

    t.it("does not resize under edgy and restores the native height", function()
      local win = window()
      local view = Choice.new({ notify = function() end })
      local before = vim.api.nvim_win_get_height(win)
      view:show({
        title = "external",
        questions = { { header = "Q", question = "q", options = { { label = "A" } } } },
        on_cancel = function() end,
      }, { win = win, external = true })
      t.eq(before, vim.api.nvim_win_get_height(win), "edgy owns the size")
      view:close()

      local view2 = Choice.new({ notify = function() end })
      view2:show({
        title = "native",
        questions = { { header = "Q", question = "q", options = { { label = "A" } } } },
      }, { win = win, external = false, max_height = 3 })
      t.truthy(vim.api.nvim_win_get_height(win) <= 3)
      view2:close()
      t.eq(before, vim.api.nvim_win_get_height(win), "native height is restored")
      close_window()
    end)
  end)

  t.describe("choice queue", function()
    local function fake_team(items)
      local team = { rows = {}, answered = {}, groups = {} }
      local row = { id = "t1", cwd = "/tmp", state = "active", inbox = items, participants = {} }
      team.rows = { row }
      function team:list_rows()
        return self.rows
      end
      function team:team(id)
        return self.rows[1]
      end
      function team:answer(id, fields, cb)
        self.answered[#self.answered + 1] = { id = id, fields = fields }
        for _, item in ipairs(row.inbox) do
          if item.id == id then
            item.state = "answered"
          end
        end
        if cb then
          cb(true, {})
        end
      end
      function team:answer_group(group, allow, cb)
        self.groups[#self.groups + 1] = { group = group, allow = allow }
        for _, item in ipairs(row.inbox) do
          if item.group == group then
            item.state = "answered"
          end
        end
        if cb then
          cb(true, {})
        end
      end
      function team:reset_limits(id, cb)
        self.reset = id
        if cb then
          cb(true, {})
        end
      end
      return team
    end

    local function question_item(id)
      return {
        id = id,
        team = "t1",
        kind = "question",
        from = "w1",
        state = "open",
        body = "keep?",
        questions = {
          {
            header = "Scope",
            question = "keep?",
            options = { { label = "yes" }, { label = "no" } },
            multi_select = false,
          },
        },
      }
    end

    t.it("counts pending items and shows a team question in the input window", function()
      local win = window()
      local team = fake_team({ question_item("i1") })
      local notices = {}
      local choices = Choices.new({
        team = function()
          return team
        end,
        interactions = function()
          return nil
        end,
        notify = function(message)
          notices[#notices + 1] = message
        end,
        input_win = function()
          return win
        end,
        chat_win = function()
          return win
        end,
        external = function()
          return false
        end,
        panel_visible = function()
          return true
        end,
      })
      t.eq({ question = 1, approval = 0 }, choices:pending_counts("t1"))
      choices:refresh()
      t.eq(true, choices.view:is_open())
      choices.view:select(2)
      choices.view:submit()
      vim.wait(20)
      t.eq("i1", team.answered[1].id)
      t.eq("no", team.answered[1].fields.answers[1].selected[1])
      t.eq(0, #notices)
      close_window()
    end)

    t.it("notifies instead of opening while the panel is hidden", function()
      local notices = {}
      local choices = Choices.new({
        team = function()
          return fake_team({ question_item("i1") })
        end,
        interactions = function()
          return nil
        end,
        notify = function(message)
          notices[#notices + 1] = message
        end,
        panel_visible = function()
          return false
        end,
      })
      choices:refresh()
      t.eq(false, choices.view:is_open())
      t.match("需要选择", table.concat(notices, "\n"))
    end)

    t.it("approves a whole spawn group and continues a limited worker", function()
      local win = window()
      local team = fake_team({
        {
          id = "i1",
          team = "t1",
          kind = "spawn",
          from = "leader",
          state = "open",
          name = "w1",
          template = "dev",
          agent = "opencode",
          group = "g1",
        },
        {
          id = "i2",
          team = "t1",
          kind = "spawn",
          from = "leader",
          state = "open",
          name = "w2",
          template = "dev",
          agent = "opencode",
          group = "g1",
        },
        {
          id = "i3",
          team = "t1",
          kind = "limit",
          from = "team",
          state = "open",
          participant = "w1",
          body = "limit",
        },
      })
      local choices = Choices.new({
        team = function()
          return team
        end,
        interactions = function()
          return nil
        end,
        notify = function() end,
        input_win = function()
          return win
        end,
        chat_win = function()
          return win
        end,
        external = function()
          return false
        end,
        panel_visible = function()
          return true
        end,
      })
      t.eq({ question = 0, approval = 3 }, choices:pending_counts())
      choices:refresh()
      local options = choices.view:options(choices.view.model.questions[1])
      t.eq("全部批准（2 个）", options[3].label)
      choices.view:select(3)
      choices.view:submit()
      vim.wait(20)
      t.eq(1, #team.groups)
      t.eq(true, team.groups[1].allow)
      choices:refresh()
      t.eq("i3", choices.view.model and choices.view.model.title and "i3" or "i3")
      choices.view:select(1)
      choices.view:submit()
      vim.wait(20)
      t.eq("t1", team.reset)
      close_window()
    end)

    t.it("approves or rejects a single spawn request", function()
      local win = window()
      local team = fake_team({
        {
          id = "i1",
          team = "t1",
          kind = "spawn",
          from = "leader",
          state = "open",
          name = "w1",
          template = "dev",
          agent = "opencode",
        },
      })
      local choices = Choices.new({
        team = function()
          return team
        end,
        interactions = function()
          return nil
        end,
        notify = function() end,
        input_win = function()
          return win
        end,
        chat_win = function()
          return win
        end,
        external = function()
          return false
        end,
        panel_visible = function()
          return true
        end,
      })
      choices:refresh()
      choices.view:select(2)
      choices.view:submit()
      vim.wait(20)
      t.eq(false, team.answered[1].fields.allow)
      close_window()
    end)

    t.it("cancels a worker permission without options instead of hanging", function()
      local win = window()
      local team = fake_team({
        {
          id = "i1",
          team = "t1",
          kind = "permission",
          from = "w1",
          state = "open",
          body = "odd permission",
          options = {},
        },
      })
      local choices = Choices.new({
        team = function()
          return team
        end,
        interactions = function()
          return nil
        end,
        notify = function() end,
        input_win = function()
          return win
        end,
        chat_win = function()
          return win
        end,
        external = function()
          return false
        end,
        panel_visible = function()
          return true
        end,
      })
      choices:refresh()
      vim.wait(20)
      t.eq(false, choices.view:is_open(), "a zero-option permission is not displayed")
      t.eq("i1", team.answered[1].id)
      t.eq({}, team.answered[1].fields)
      choices:refresh()
      vim.wait(20)
      t.eq(1, #team.answered, "it is answered once")
      close_window()
    end)

    t.it("does not repeat a failing zero-option cancel until asked", function()
      local win = window()
      local row = {
        id = "t1",
        cwd = "/tmp",
        state = "active",
        participants = {},
        inbox = {
          {
            id = "i1",
            team = "t1",
            kind = "permission",
            from = "w1",
            state = "open",
            body = "odd",
            options = {},
          },
        },
      }
      local calls = {}
      local team = {
        list_rows = function()
          return { row }
        end,
        team = function()
          return row
        end,
        answer = function(_, id, fields, cb)
          calls[#calls + 1] = { id = id, fields = fields, cb = cb }
        end,
      }
      local notices = {}
      local choices = Choices.new({
        team = function()
          return team
        end,
        interactions = function()
          return nil
        end,
        notify = function(message)
          notices[#notices + 1] = message
        end,
        input_win = function()
          return win
        end,
        chat_win = function()
          return win
        end,
        external = function()
          return false
        end,
        panel_visible = function()
          return true
        end,
      })
      choices:refresh()
      choices:refresh()
      choices:refresh()
      t.eq(1, #calls, "the request must be in flight once")
      calls[1].cb(false, { message = "denied" })
      vim.wait(20)
      t.match("cannot cancel", table.concat(notices, "\n"))
      choices:refresh()
      t.eq(1, #calls, "a failure must not retry in a loop")
      choices:show_pending("t1")
      vim.wait(20)
      t.eq(2, #calls, "`:Ade team answer` retries it")
      close_window()
    end)

    t.it("does not stack the component over an unclosable fallback", function()
      local win = window()
      local interactions = {
        shown = "p1",
        order = { { id = "p1", state = "pending", type = "permission" } },
        pending = function(self)
          return self.order
        end,
        show_next = function(self)
          self.showed = true
        end,
        unshow = function(self)
          self.shown = nil
        end,
      }
      local notices = {}
      local choices = Choices.new({
        team = function()
          return nil
        end,
        interactions = function()
          return interactions
        end,
        config = function()
          return { ui = { picker = "vim" }, permissions = { prompt = "select" } }
        end,
        notify = function(message)
          notices[#notices + 1] = message
        end,
        input_win = function()
          return win
        end,
        chat_win = function()
          return win
        end,
        external = function()
          return false
        end,
        panel_visible = function()
          return true
        end,
      })
      choices:show_pending(nil)
      t.eq(false, choices.view:is_open(), "no component on top of vim.ui.select")
      t.falsy(interactions.showed, "show_next is not called again")
      t.match("选择框", table.concat(notices, "\n"))
      close_window()
    end)

    t.it("answers a question without options through vim.ui.input", function()
      local team = fake_team({
        {
          id = "i1",
          team = "t1",
          kind = "question",
          from = "w1",
          state = "open",
          body = "free?",
        },
      })
      local choices = Choices.new({
        team = function()
          return team
        end,
        interactions = function()
          return nil
        end,
        notify = function() end,
      })
      local original = vim.ui.input
      vim.ui.input = function(_, cb)
        cb("typed")
      end
      choices:answer_participant("t1", "w1")
      vim.ui.input = original
      t.eq("typed", team.answered[1].fields.text)
    end)

    t.it("routes ACP permissions through the component when the panel is visible", function()
      local win = window()
      local answered, cancelled
      local interactions = {
        order = {},
        shown = nil,
        answer = function(_, id, response)
          answered = { id = id, response = response }
        end,
        cancel = function(_, id)
          cancelled = id
        end,
        pending = function()
          return {}
        end,
      }
      local choices = Choices.new({
        team = function()
          return nil
        end,
        interactions = function()
          return interactions
        end,
        config = function()
          return { permissions = { prompt = "select", show_details = false } }
        end,
        notify = function() end,
        input_win = function()
          return win
        end,
        chat_win = function()
          return win
        end,
        external = function()
          return false
        end,
        panel_visible = function()
          return true
        end,
      })
      local interaction = {
        id = "perm1",
        type = "permission",
        request = {
          toolCall = { title = "npm test", kind = "execute" },
          options = {
            { optionId = "a", name = "Allow", kind = "allow_once" },
            { optionId = "r", name = "Reject", kind = "reject_once" },
          },
        },
      }
      t.eq(true, choices:present_interaction(interaction))
      choices.view:select(1)
      t.eq("selected", answered.response.outcome.outcome)
      t.eq("a", answered.response.outcome.optionId)
      _ = cancelled
      close_window()
    end)
  end)
end
