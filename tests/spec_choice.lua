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
    t.it("colors the question, focus, selected answer and custom prompt independently", function()
      local win = window()
      local view = Choice.new({})
      t.cleanup(function()
        view:close()
      end)
      t.truthy(view:show({
        title = "Questions",
        questions = {
          {
            header = "范围",
            question = "选哪一项？",
            multi_select = true,
            allow_custom = true,
            options = { { label = "范围 A", description = "说明" }, { label = "范围 B" } },
          },
        },
      }, { win = win, focus_wins = { win } }))
      local ns = vim.api.nvim_get_namespaces().ade_choice
      local function spans()
        local out, focus = {}, nil
        local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, 0, -1, { details = true })) do
          local row, col, spec = mark[2], mark[3], mark[4]
          if spec.line_hl_group == "AdeChoiceFocus" then
            focus = row + 1
          else
            local text = lines[row + 1]:sub(col + 1, spec.end_col)
            out[vim.trim(text)] = spec.hl_group
          end
        end
        return out, focus
      end
      local styled, focus = spans()
      t.eq("AdeChoiceQuestion", styled["选哪一项？"])
      t.eq("AdeChoiceTabActive", styled["范围]"])
      t.eq("AdeChoiceOptionActive", styled["范围 A"])
      t.eq("AdeChoiceMuted", styled["说明"])
      t.eq("AdeChoiceHint", styled.Tab)
      t.eq(1, view.maps.options[focus])

      view:select(1)
      view.cursor = 2
      view:render()
      styled, focus = spans()
      t.eq("AdeChoiceSelected", styled["范围 A"])
      t.eq(2, view.maps.options[focus])

      view:select(3)
      styled, focus = spans()
      t.eq("AdeChoiceCustom", styled["其他:"])
      t.falsy(styled["其他（自己输入）…"], "do not leave the old option highlight on the editable line")
      t.eq(nil, focus, "direct selection clears the previous option's focus background")
      t.eq(nil, styled[require("ade.ui.icons").glyph("choice_cursor")], "the previous option loses its focus arrow")
      view:close()
      close_window()
    end)

    t.it("marks only the chosen index when two choices have the same label", function()
      local win = window()
      local view = Choice.new({})
      t.cleanup(function()
        view:close()
      end)
      t.truthy(view:show({
        questions = {
          { question = "范围？", multi_select = true, options = { { label = "同名" }, { label = "同名" } } },
        },
      }, { win = win }))
      view:select(2)
      local selected = {}
      local ns = vim.api.nvim_get_namespaces().ade_choice
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, 0, -1, { details = true })) do
        local index = view.maps.options[mark[2] + 1]
        if index and mark[4].hl_group == "AdeChoiceSelected" then
          selected[index] = true
        end
      end
      t.eq({ [2] = true }, selected)
      view:close()
      close_window()
    end)

    t.it("floats a card over the bottom of the chat window and leaves it untouched", function()
      local win, original = window()
      vim.api.nvim_win_set_height(win, 20)
      local submitted, reserved
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
      t.eq(
        true,
        view:show(model, {
          win = win,
          focus_wins = { win },
          reserve = function(rows)
            reserved = rows
          end,
        })
      )
      t.eq(original, vim.api.nvim_win_get_buf(win), "the chat window keeps its buffer")
      local config = vim.api.nvim_win_get_config(view.win)
      t.eq("win", config.relative)
      t.eq(win, config.win)
      t.eq("SW", config.anchor)
      t.eq(view.win, vim.api.nvim_get_current_win(), "focused from the chat window")
      t.eq("ade_choice", vim.bo[view.buf].filetype)
      t.eq(true, vim.b[view.buf].ade_choice)
      t.eq(false, vim.bo[view.buf].modifiable)
      t.eq(config.height + 2, reserved, "the transcript reserves the card's rows")
      view:select(2)
      view:submit()
      t.eq("B", submitted[1].selected[1])
      t.eq(false, view:is_open())
      t.eq(0, reserved, "the reserve is released")
      close_window()
    end)

    t.it("fits its height to each question's content and caps it", function()
      local win = window()
      vim.api.nvim_win_set_height(win, 30)
      local view = Choice.new({ notify = function() end })
      local options = {}
      for i = 1, 9 do
        options[i] = { label = "option " .. i }
      end
      view:show({
        title = "fit",
        questions = {
          { header = "Short", question = "one?", options = { { label = "A" } } },
          { header = "Long", question = "many?", options = options },
          { header = "Huge", question = string.rep("word ", 2000), options = options },
        },
        on_cancel = function() end,
      }, { win = win })
      local short = vim.api.nvim_win_get_height(view.win)
      view.tab = 2
      view:render()
      local long = vim.api.nvim_win_get_height(view.win)
      t.truthy(long > short, "more options make a taller card")
      view.expanded = true
      view.tab = 3
      view:render()
      local huge = vim.api.nvim_win_get_height(view.win)
      t.truthy(huge + 2 <= math.floor(30 * 0.6), "the card is capped to part of the chat window")
      view.tab = 1
      view:render()
      t.eq(short, vim.api.nvim_win_get_height(view.win), "and shrinks back")
      view:close()
      close_window()
    end)

    t.it("does not take focus from other windows and closes with the chat window", function()
      local win = window()
      vim.api.nvim_win_set_height(win, 20)
      vim.cmd("split")
      local other = vim.api.nvim_get_current_win()
      local notices = {}
      local view = Choice.new({
        notify = function(message)
          notices[#notices + 1] = message
        end,
      })
      view:show({
        title = "away",
        questions = { { header = "Q", question = "q", options = { { label = "A" } } } },
        on_cancel = function() end,
      }, { win = win, focus_wins = { win }, focus_hint = "<M-a>" })
      t.eq(other, vim.api.nvim_get_current_win())
      t.match("<M%-a>", notices[1] or "")
      t.eq(true, view:focus())
      t.eq(view.win, vim.api.nvim_get_current_win())
      vim.api.nvim_win_close(win, true)
      vim.wait(50, function()
        return not view:is_open()
      end)
      t.eq(false, view:is_open(), "the card goes with its chat window")
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
      }, { win = win })
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
      }, { win = win })
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

    t.it("renders the live pending count from status_fn", function()
      local win = window()
      local view = Choice.new({ notify = function() end })
      view:show({
        title = "count",
        status_fn = function()
          return "还有 2 个待处理"
        end,
        questions = { { header = "Q", question = "q", options = { { label = "A" } } } },
        on_cancel = function() end,
      }, { win = win })
      local text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
      t.match("还有 2 个待处理", text)
      view:close()
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

    t.it("stamps team on row-fallback inbox items", function()
      local item = { id = "i1", kind = "question", state = "open", from = "w1", body = "q" }
      local team = {
        list_rows = function()
          return { { id = "t1", cwd = "/tmp", state = "active", inbox = { item } } }
        end,
      }
      local choices = Choices.new({
        team = function()
          return team
        end,
        interactions = function()
          return nil
        end,
        notify = function() end,
      })
      local items = choices:items(team)
      t.eq(1, #items)
      t.eq("t1", items[1].team)
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

    t.it("shows the handover inbox card with move and refuse, and answers through team.answer", function()
      local win = window()
      local answered = {}
      local team = fake_team({
        {
          id = "h1",
          team = "t1",
          kind = "handover",
          from = { instance = "i2", sessionId = "s9" },
          leader = { instance = "i2", sessionId = "s9" },
          state = "open",
          body = "another chat leads",
        },
      })
      team.answer = function(self, id, fields, cb)
        answered[#answered + 1] = { id = id, fields = fields }
        if cb then
          cb(true, {})
        end
      end
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
        panel_visible = function()
          return true
        end,
      })
      t.eq({ question = 0, approval = 1 }, choices:pending_counts("t1"))
      choices:refresh()
      t.eq(true, choices.view:is_open(), "the handover card is shown")
      local labels = {}
      for _, option in ipairs(choices.view.model.questions[1].options) do
        labels[#labels + 1] = option.label
      end
      t.truthy(table.concat(labels, "|"):match("移交"))
      t.truthy(table.concat(labels, "|"):match("拒绝"))
      choices.view:select(2)
      choices.view:submit()
      vim.wait(30)
      t.eq(1, #answered)
      t.eq("h1", answered[1].id)
      t.eq("refuse", answered[1].fields.option)
      t.eq(true, choices.handled["team:t1:h1"])
      close_window()
    end)

    t.it("keeps a failed handover answer answerable", function()
      local win = window()
      local attempts = 0
      local team = fake_team({
        {
          id = "h1",
          team = "t1",
          kind = "handover",
          from = { instance = "i2", sessionId = "s9" },
          leader = { instance = "i2", sessionId = "s9" },
          state = "open",
          body = "another chat leads",
        },
      })
      team.answer = function(self, id, fields, cb)
        attempts = attempts + 1
        if cb then
          cb(false, { message = "the request is gone" })
        end
      end
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
        panel_visible = function()
          return true
        end,
      })
      choices:refresh()
      local item = choices:team_entries("t1")[1]
      choices:show(item, { item })
      choices.view:select(1)
      choices.view:submit()
      vim.wait(30)
      t.eq(1, attempts)
      t.eq(nil, choices.handled["team:t1:h1"], "a failed answer is retryable")
      t.match("cannot answer the handover", table.concat(notices, "\n"))
      close_window()
    end)

    t.it("builds a card from Choices:ask instead of throwing", function()
      local win = window()
      local choices = Choices.new({
        team = function()
          return nil
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
        panel_visible = function()
          return true
        end,
      })
      local picked
      t.eq(
        true,
        choices:ask({
          title = "团队已有 leader",
          question = "交给本会话？",
          options = {
            { label = "移交", value = "move" },
            { label = "取消", value = "cancel" },
          },
          on_choice = function(value)
            picked = value
          end,
        })
      )
      t.eq(true, choices.view:is_open())
      choices.view:select(1)
      choices.view:submit()
      vim.wait(20)
      t.eq("move", picked)
      close_window()
    end)
  end)
end
