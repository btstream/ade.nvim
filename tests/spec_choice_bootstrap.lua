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

  local function setup()
    ade.setup({
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = {},
      layout = { input_height = 6 },
    })
    controller.open()
    local S = controller.state()
    wait(function()
      return S.session ~= nil and S.input and S.input.win and vim.api.nvim_win_is_valid(S.input.win)
    end, 15000, "the visible panel")
    return S
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
      local win = S.input.win
      local buf = vim.api.nvim_win_get_buf(win)
      t.eq("ade_input", vim.bo[buf].filetype)
      t.eq(true, vim.b[buf].ade_choice)
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

    t.it("survives hiding and reopening the panel", function()
      local S = setup()
      cleanup(S)
      -- While hidden the old picker is the fallback; in headless tests it must
      -- not block on the default vim.ui.select prompt.
      local original_select = vim.ui.select
      vim.ui.select = function(_, _, cb)
        if cb then
          cb(nil)
        end
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
      controller.open()
      wait(function()
        return choices.view:is_open()
      end, 5000, "the component after reopening")
      choices.view:select(1)
      wait(function()
        return responded ~= nil
      end, 5000, "the answer after reopening")
      t.eq("a", responded.outcome.optionId)
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
