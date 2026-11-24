-- Real bootstrap path for the inline choice component: default config, the
-- mock agent, and a visible chat panel (draft 8).
return function(t)
  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local ade = require("ade")
  local controller = require("ade.controller")

  local function wait(cond, timeout, label)
    if not vim.wait(timeout or 10000, cond, 20) then
      error("timed out: " .. (label or "condition"), 2)
    end
  end

  local function setup(overrides)
    ade.setup(vim.tbl_deep_extend("force", {
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = {},
      layout = { input_height = 6 },
    }, overrides or {}))
    controller.open()
    local S = controller.state()
    wait(function()
      return S.session ~= nil and S.input and S.input.win and vim.api.nvim_win_is_valid(S.input.win)
    end, 15000, "the visible panel")
    return S
  end

  local function form_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.b[vim.api.nvim_win_get_buf(win)].ade_form then
        return win
      end
    end
  end

  local function picker_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.b[vim.api.nvim_win_get_buf(win)].ade_picker then
        return win
      end
    end
  end

  local function focus_float()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.relative ~= "" then
        local ok = pcall(vim.api.nvim_set_current_win, win)
        if ok and vim.api.nvim_get_current_win() == win then
          return win
        end
      end
    end
  end

  local function cleanup(S)
    t.cleanup(function()
      if S and S.view and S.view.interactions then
        for _, interaction in ipairs(S.view.interactions:pending()) do
          S.view.interactions:cancel(interaction.id, "test over")
        end
      end
      if S and S.view and S.view.choices then
        S.view.choices:dismiss()
        S.view.choices:dismiss_fallback()
      end
      pcall(function()
        require("ade.ui.permission_details").close()
      end)
      pcall(controller.hide)
    end)
  end

  t.describe("choice component over the real panel", function()
    t.it("shows an ACP permission in the composer and answers it", function()
      local S = setup()
      cleanup(S)
      local responded
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Write file", kind = "edit" },
        options = {
          { optionId = "a", name = "Allow", kind = "allow_once" },
          { optionId = "r", name = "Reject", kind = "reject_once" },
        },
      }, function(response)
        responded = response
      end, 1)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the permission component")
      t.eq(S.input.buf, vim.api.nvim_win_get_buf(S.input.win), "the composer stays as it was")
      local card = choices.view
      t.eq("ade_choice", vim.bo[card.buf].filetype)
      t.eq(true, vim.b[card.buf].ade_choice)
      t.eq(S.chat.win, vim.api.nvim_win_get_config(card.win).win, "the card floats over the chat window")
      t.eq(vim.api.nvim_win_get_height(card.win) + 2, S.chat.bottom_reserve, "the transcript reserves its rows")
      t.truthy(not vim.tbl_isempty(S.view.interactions:pending()), "the request stays pending")
      choices.view:select(1)
      wait(function()
        return responded ~= nil
      end, 5000, "the permission answer")
      t.eq("a", responded.outcome.optionId)
    end)

    t.it("submits an elicitation form with the validated content", function()
      local S = setup()
      cleanup(S)
      local responded
      S.view.interactions:open("elicitation", {
        sessionId = "s1",
        message = "Configure the run",
        requestedSchema = {
          type = "object",
          properties = {
            db = { type = "string", enum = { "Postgres", "Redis" } },
            verbose = { type = "boolean" },
            tags = { type = "array", items = { enum = { "fast", "safe" } } },
          },
          required = { "db" },
        },
      }, function(response)
        responded = response
      end, 2)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the form component")
      -- Field order is db, tags, verbose; db: Postgres; tags: fast; verbose: yes.
      choices.view:select(1)
      choices.view:select(1)
      choices.view:advance()
      choices.view:select(1)
      choices.view:submit()
      wait(function()
        return responded ~= nil
      end, 5000, "the form answer")
      t.eq("accept", responded.action)
      t.eq("Postgres", responded.content.db)
      t.eq(true, responded.content.verbose)
      t.eq({ "fast" }, responded.content.tags)
    end)

    t.it("keeps the answers when form validation fails", function()
      local S = setup()
      cleanup(S)
      local responded
      S.view.interactions:open("elicitation", {
        sessionId = "s1",
        message = "Required",
        requestedSchema = {
          type = "object",
          properties = { db = { type = "string", enum = { "Postgres", "Redis" } } },
          required = { "db" },
        },
      }, function(response)
        responded = response
      end, 6)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the required form")
      choices.view:submit()
      t.eq(nil, responded, "an unanswered required field must not be sent")
      t.eq(true, choices.view:is_open(), "the form stays open")
      choices.view:select(1)
      choices.view:submit()
      wait(function()
        return responded ~= nil
      end, 5000, "the retried form")
      t.eq("Postgres", responded.content.db)
    end)

    t.it("sends the schema's custom field with the chosen option", function()
      local S = setup()
      cleanup(S)
      local responded
      S.view.interactions:open("elicitation", {
        sessionId = "s1",
        message = "Other",
        requestedSchema = {
          type = "object",
          properties = {
            db = { type = "string", enum = { "Postgres", "Redis" } },
            db_custom = { type = "string" },
          },
        },
      }, function(response)
        responded = response
      end, 7)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the custom form")
      choices.view.answers[1].selected = { "Postgres" }
      choices.view.answers[1].selected_index = { 1 }
      choices.view.answers[1].text = "OtherDB"
      choices.view:submit()
      wait(function()
        return responded ~= nil
      end, 5000, "the custom answer")
      t.eq("Postgres", responded.content.db)
      t.eq("OtherDB", responded.content.db_custom)
    end)

    t.it("keeps a team question pending after Esc instead of reopening it", function()
      local S = setup()
      cleanup(S)
      local team = S.view.team
      local item = {
        id = "i1",
        team = "t1",
        kind = "question",
        from = "w1",
        state = "open",
        body = "keep?",
        questions = {
          { header = "Q", question = "keep?", options = { { label = "yes" }, { label = "no" } } },
        },
      }
      team.teams["t1"] = {
        id = "t1",
        cwd = S.config.cwd or vim.fn.getcwd(),
        state = "active",
        participants = {},
        inbox = { item },
      }
      team.inbox["i1"] = item
      local choices = S.view.choices
      choices:refresh()
      wait(function()
        return choices.view:is_open()
      end, 5000, "the team question")
      choices.view:cancel()
      t.eq(false, choices.view:is_open())
      t.eq(true, choices.deferred["team:t1:i1"])
      choices:refresh()
      t.eq(false, choices.view:is_open(), "Esc must not reopen the same item")
      choices:show_pending("t1")
      wait(function()
        return choices.view:is_open()
      end, 5000, "the explicit reopen")
    end)

    t.it("drops a closed team's pending choices and the one on screen", function()
      local S = setup()
      cleanup(S)
      local team = S.view.team
      local function item(id, team_id, body)
        return {
          id = id,
          team = team_id,
          kind = "question",
          from = "w1",
          state = "open",
          body = body,
          questions = {
            { header = "Q", question = body, options = { { label = "yes" }, { label = "no" } } },
          },
        }
      end
      local first = item("i1", "t1", "close me")
      local second = item("i2", "t2", "keep me")
      for _, entry in ipairs({ { "t1", first }, { "t2", second } }) do
        team.teams[entry[1]] = {
          id = entry[1],
          cwd = S.config.cwd or vim.fn.getcwd(),
          state = "active",
          participants = {},
          inbox = { entry[2] },
        }
        team.inbox[entry[2].id] = entry[2]
      end
      local choices = S.view.choices
      choices:refresh()
      wait(function()
        return choices.view:is_open() and choices.current and choices.current.team == "t1"
      end, 5000, "the first team's question")
      t.eq(true, vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()), "the component has focus")
      team:forget_team("t1")
      team:closed("t1")
      wait(function()
        return not (choices.current and choices.current.team == "t1")
      end, 5000, "the closed team's question")
      t.eq(true, vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()), "focus stays on a live window")
      t.eq(0, #choices:team_entries("t1"), "no t1 item stays queued")
      t.eq(1, #choices:team_entries("t2"), "the other team's item stays queued")
      choices:dismiss()
    end)

    t.it("keeps the default vim fallback while the panel is hidden", function()
      local S = setup()
      cleanup(S)
      local original_select = vim.ui.select
      local fallback_shown = false
      vim.ui.select = function()
        fallback_shown = true
        -- The default prompt cannot be closed; do not answer it.
      end
      t.cleanup(function()
        vim.ui.select = original_select
      end)
      local responded
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run", kind = "execute" },
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function(response)
        responded = response
      end, 3)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the first component")
      controller.hide()
      wait(function()
        return fallback_shown and #S.view.interactions:pending() == 1
      end, 5000, "the hidden fallback")
      t.eq(false, choices.view:is_open())
      controller.open()
      vim.wait(150)
      t.eq(false, choices.view:is_open(), "the unclosable fallback stays on screen")
      t.truthy(S.view.interactions.shown, "the request is still presented")
      t.eq(1, #S.view.interactions:pending(), "the request stayed pending")
      S.view.interactions:answer(S.view.interactions.order[1].id, {
        outcome = { outcome = "selected", optionId = "a" },
      })
      wait(function()
        return responded ~= nil
      end, 5000, "the fallback answer")
      t.eq("a", responded.outcome.optionId)
    end)

    t.it("replaces an internal picker without rejecting the request", function()
      local S = setup({ ui = { picker = "internal" } })
      cleanup(S)
      local responded
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run", kind = "execute" },
        options = {
          { optionId = "a", name = "Allow", kind = "allow_once" },
          { optionId = "r", name = "Reject", kind = "reject_once" },
        },
      }, function(response)
        responded = response
      end, 8)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the internal first component")
      controller.hide()
      wait(function()
        return not choices.view:is_open() and #S.view.interactions:pending() == 1
      end, 5000, "the internal fallback")
      -- A real user leaves the pointer on the internal picker; the panel
      -- switch must not turn that focus change into a rejection.
      local picker_win = focus_float()
      t.truthy(picker_win, "the internal picker float is focusable")
      t.eq(picker_win, vim.api.nvim_get_current_win(), "the picker is the current window")
      controller.open()
      wait(function()
        return choices.view:is_open()
      end, 5000, "the internal component after reopen")
      t.eq(nil, responded, "replacing the picker must not answer it")
      choices.view:select(1)
      wait(function()
        return responded ~= nil
      end, 5000, "the internal answer")
      t.eq("selected", responded.outcome.outcome)
      t.eq("a", responded.outcome.optionId)
    end)

    t.it("keeps a hidden-panel permission picker visible after focus leaves", function()
      local S = setup({ ui = { picker = "internal" } })
      cleanup(S)
      local responded
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run", kind = "execute" },
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function(response)
        responded = response
      end, 13)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the component before hide")
      controller.hide()
      wait(function()
        return not choices.view:is_open() and #S.view.interactions:pending() == 1 and picker_win() ~= nil
      end, 5000, "the hidden picker")
      local picker = picker_win()
      t.truthy(picker, "the hidden picker exists")
      local ok = pcall(vim.api.nvim_set_current_win, picker)
      t.truthy(ok)
      t.eq(picker, vim.api.nvim_get_current_win())
      vim.cmd("wincmd p")
      vim.wait(150)
      t.eq(nil, responded, "leaving the picker must not answer it")
      t.eq(1, #S.view.interactions:pending())
      t.eq(picker, picker_win(), "the picker stays on screen")
      local floats = 0
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= "" then
          floats = floats + 1
        end
      end
      t.truthy(floats >= 2, "the picker and its details float stay")
      controller.open()
      wait(function()
        return choices.view:is_open()
      end, 5000, "the component after the picker leave")
      choices.view:select(1)
      wait(function()
        return responded ~= nil
      end, 5000, "the hidden-picker answer")
      t.eq("a", responded.outcome.optionId)
    end)

    t.it("replaces an internal elicitation form without cancelling it", function()
      local S = setup({ ui = { picker = "internal" } })
      cleanup(S)
      local responded
      S.view.interactions:open("elicitation", {
        sessionId = "s1",
        message = "Pick",
        requestedSchema = {
          type = "object",
          properties = { db = { type = "string", enum = { "Postgres", "Redis" } } },
          required = { "db" },
        },
      }, function(response)
        responded = response
      end, 11)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the internal form")
      controller.hide()
      wait(function()
        return not choices.view:is_open() and #S.view.interactions:pending() == 1
      end, 5000, "the internal form fallback")
      controller.open()
      wait(function()
        return choices.view:is_open()
      end, 5000, "the internal form after reopen")
      t.eq(nil, responded, "reopening must not cancel the form")
      choices.view:select(1)
      choices.view:submit()
      wait(function()
        return responded ~= nil
      end, 5000, "the internal form answer")
      t.eq("accept", responded.action)
      t.eq("Postgres", responded.content.db)
    end)

    t.it("withdrawing a request closes the real fallback floats", function()
      local S = setup({ ui = { picker = "internal" } })
      cleanup(S)
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run", kind = "execute" },
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function() end, 12)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the component before withdraw")
      controller.hide()
      wait(function()
        return #S.view.interactions:pending() == 1 and not choices.view:is_open()
      end, 5000, "the internal fallback before withdraw")
      S.view.interactions:cancel(S.view.interactions.order[1].id, "agent withdrew")
      wait(function()
        return #S.view.interactions:pending() == 0
      end, 5000, "the withdrawn request")
      vim.wait(100)
      local float = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(win)
        if config.relative ~= "" and config.zindex ~= nil then
          local ok, name = pcall(vim.api.nvim_buf_get_name, vim.api.nvim_win_get_buf(win))
          _ = name
          _ = ok
          float = true
        end
      end
      -- The picker/detail floats are closed; editor splits may remain.
      t.eq(false, float, "fallback floats must be closed on withdraw")
    end)

    t.it("does not loop when the composer is closed with :q", function()
      local S = setup()
      cleanup(S)
      local responded
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run", kind = "execute" },
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function(response)
        responded = response
      end, 9)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the component before :q")
      local count = 0
      local original = choices.refresh
      choices.refresh = function(self_, ...)
        count = count + 1
        return original(self_, ...)
      end
      local original_select = vim.ui.select
      vim.ui.select = function() end
      local win = S.input.win
      vim.api.nvim_win_close(win, true)
      vim.wait(400)
      vim.ui.select = original_select
      choices.refresh = original
      t.truthy(count < 25, "refresh must not storm, got " .. count)
      t.eq(1, #S.view.interactions:pending(), "the request is still pending")
      S.view.interactions:answer(S.view.interactions.order[1].id, {
        outcome = { outcome = "selected", optionId = "a" },
      })
      wait(function()
        return responded ~= nil
      end, 5000, "the :q answer")
    end)

    t.it("notifies a native permission once, not on every refresh", function()
      local S = setup({ permissions = { prompt = "native" } })
      cleanup(S)
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      t.cleanup(function()
        vim.notify = original_notify
      end)
      for index = 1, 2 do
        S.view.interactions:open("permission", {
          sessionId = "s1",
          toolCall = { title = "Run " .. index, kind = "execute" },
          options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
        }, function() end, 10 + index)
      end
      for _ = 1, 5 do
        S.view.choices:refresh()
      end
      local count = 0
      for _, message in ipairs(notices) do
        if message:find("Permission required", 1, true) then
          count = count + 1
        end
      end
      t.eq(2, count, "each native request is notified exactly once")
    end)

    t.it("cancels a permission without options instead of blocking", function()
      local S = setup()
      cleanup(S)
      local responded
      S.view.interactions:open(
        "permission",
        { sessionId = "s1", toolCall = { title = "Odd" }, options = {} },
        function(response)
          responded = response
        end,
        4
      )
      wait(function()
        return responded ~= nil
      end, 5000, "the zero-option answer")
      t.eq("cancelled", responded.outcome.outcome)
    end)

    t.it("takes focus from the panel but not from an editor window", function()
      local S = setup()
      cleanup(S)
      local choices = S.view.choices
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run", kind = "execute" },
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function() end, 15)
      wait(function()
        return choices.view:is_open()
      end, 5000, "the first focus component")
      t.eq(choices.view.win, vim.api.nvim_get_current_win(), "the card takes focus")
      choices.view:close()
      S.view.interactions:answer(S.view.interactions.order[1].id, {
        outcome = { outcome = "selected", optionId = "a" },
      })

      vim.cmd("vsplit")
      local editor = vim.api.nvim_get_current_win()
      local notices = {}
      local original_notify = vim.notify
      vim.notify = function(message)
        notices[#notices + 1] = tostring(message)
      end
      t.cleanup(function()
        vim.notify = original_notify
      end)
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run 2", kind = "execute" },
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function() end, 16)
      wait(function()
        return choices.view:is_open()
      end, 5000, "the editor-focus component")
      t.eq(editor, vim.api.nvim_get_current_win(), "an editor window keeps focus")
      t.match("需要你的选择", table.concat(notices, "\n"))
      t.match("<M%-a>", table.concat(notices, "\n"), "the hint names the focus key")
      -- The focus key from the chat window moves into the card.
      vim.api.nvim_set_current_win(S.chat.win)
      local map = vim.fn.maparg("<M-a>", "n", false, true)
      t.truthy(map.callback, "the chat window maps focus_choice")
      map.callback()
      t.eq(choices.view.win, vim.api.nvim_get_current_win())
      pcall(vim.api.nvim_win_close, editor, true)
    end)

    t.it("keeps a hidden-panel elicitation form after focus leaves", function()
      local S = setup({ ui = { picker = "internal" } })
      cleanup(S)
      S.view.interactions:open("elicitation", {
        sessionId = "s1",
        message = "Pick",
        requestedSchema = {
          type = "object",
          properties = {
            db = { type = "string", enum = { "Postgres", "Redis" } },
            note = { type = "string" },
          },
          required = { "db" },
        },
      }, function() end, 17)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the form component")
      controller.hide()
      wait(function()
        return not choices.view:is_open() and form_win() ~= nil
      end, 5000, "the hidden form")
      vim.cmd("wincmd p")
      vim.wait(120)
      t.truthy(form_win(), "the form stays after focus leaves")
    end)

    t.it("mounts the component in the consumer of a worker transcript", function()
      local S = setup({ teams = { dashboard = { wide = 40 } } })
      cleanup(S)
      t.eq(true, controller.open_team())
      local ui = S.view.team_ui
      wait(function()
        return ui.layout:is_open_pane("members")
      end, 5000, "the members pane")
      -- The worker transcript is the ordinary chat/input pair, so the choice
      -- component still mounts in the one composer window.
      local before = S.view.input.win
      t.truthy(before)
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run", kind = "execute" },
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function() end, 18)
      local choices = S.view.choices
      wait(function()
        return choices.view:is_open()
      end, 5000, "the component in the shared composer")
      -- The component floats over a shared window rather than opening a
      -- second composer: it is a `relative = "win"` float with a host.
      local config = vim.api.nvim_win_get_config(choices.view.win)
      t.eq("win", config.relative)
      t.truthy(choices.view.host and vim.api.nvim_win_is_valid(choices.view.host), "the host is the shared window")
      t.truthy(vim.api.nvim_win_is_valid(before))
      choices:dismiss()
      ui:close()
    end)

    t.it("stops insert mode before mounting the component", function()
      local S = setup()
      cleanup(S)
      vim.cmd("startinsert")
      S.view.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Run", kind = "execute" },
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function() end, 5)
      wait(function()
        return S.view.choices.view:is_open()
      end, 5000, "the insert-mode component")
      t.truthy(vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i", "insert mode must end")
    end)
  end)
end
