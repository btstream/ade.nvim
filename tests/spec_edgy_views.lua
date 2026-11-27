return function(t)
  local edgy_views = require("ade.integrations.edgy")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local has_edgy = (function()
    for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
      if vim.fn.isdirectory(dir .. "/lua/edgy") == 1 then
        return true
      end
    end
    return false
  end)()

  t.describe("edgy view registration", function()
    t.it("builds array entries, not named keys", function()
      local opts = { right = {} }
      edgy_views.extend(opts)
      -- The array part must hold every view; a named key would be ignored by
      -- edgy, which only iterates `ipairs(views)`.
      t.eq(5, #opts.right)
      local fts = {}
      for _, view in ipairs(opts.right) do
        fts[view.ft] = true
      end
      for _, ft in ipairs({ "ade_chat", "ade_input", "ade_team_tree", "ade_team_members", "ade_team_board" }) do
        t.truthy(fts[ft], ft .. " missing")
      end
    end)

    t.it("returns team views with their default sizes unless disabled", function()
      local views = edgy_views.views()
      t.eq("ade_team_tree", views.tree.ft)
      t.eq("ade_team_members", views.members.ft)
      t.eq("ade_team_board", views.board.ft)
      t.eq(32, views.tree.size.width)
      t.eq(32, views.members.size.width)
      t.eq(nil, views.board.size, "the board has no configured size")
      t.eq(false, views.tree.wo.winbar, "ade owns the pane winbar")

      local plain = edgy_views.views({ team = false })
      t.eq(nil, plain.tree)
      t.eq(nil, plain.members)
      t.eq(nil, plain.board)
      t.truthy(plain.chat and plain.input)
    end)

    t.it("places the team views by default where the chat panel is", function()
      local opts = { left = {} }
      edgy_views.extend(opts, { position = "left" })
      local fts = {}
      for _, view in ipairs(opts.left) do
        fts[view.ft] = true
      end
      t.truthy(fts.ade_chat)
      t.truthy(fts.ade_team_tree)
      t.truthy(fts.ade_team_members)
      t.truthy(fts.ade_team_board)
    end)

    t.it("places individual team views in the requested positions", function()
      local opts = { right = {}, left = {}, bottom = {} }
      edgy_views.extend(opts, {
        team = { tree = "left", members = "left", board = "bottom" },
      })
      local function has(list, ft)
        for _, view in ipairs(list) do
          if type(view) == "table" and view.ft == ft then
            return true
          end
        end
        return false
      end
      t.truthy(has(opts.left, "ade_team_tree"))
      t.truthy(has(opts.left, "ade_team_members"))
      t.truthy(has(opts.bottom, "ade_team_board"))
      t.falsy(has(opts.right, "ade_team_board"))
    end)

    t.it("skips the team views with team = false and never duplicates them", function()
      local opts = { right = {} }
      edgy_views.extend(opts, { team = false })
      t.eq(2, #opts.right, "only the chat pair")
      local again = { right = { { ft = "ade_team_board" } } }
      edgy_views.extend(again)
      local boards = 0
      for _, view in ipairs(again.right) do
        if type(view) == "table" and view.ft == "ade_team_board" then
          boards = boards + 1
        end
      end
      t.eq(1, boards, "an existing team view is kept, not repeated")
    end)

    t.it("skips a team view already registered on another side", function()
      local opts = {
        right = {},
        left = { { ft = "ade_team_tree", title = "Mine" } },
      }
      edgy_views.extend(opts)
      local function count(list, ft)
        local found = 0
        for _, view in ipairs(list) do
          if type(view) == "table" and view.ft == ft then
            found = found + 1
          end
        end
        return found
      end
      t.eq(0, count(opts.right, "ade_team_tree"), "a tree on the left must not be added to the right")
      t.eq(1, count(opts.left, "ade_team_tree"), "the user's tree view is kept as it was")
      t.eq("Mine", opts.left[1].title)
      t.eq(1, count(opts.right, "ade_team_members"), "the other views are still added")
    end)

    t.it("never duplicates views across two extend calls with different mappings", function()
      local opts = { right = {}, left = {}, bottom = {} }
      edgy_views.extend(opts, { team = { tree = "left", members = "left", board = "bottom" } })
      edgy_views.extend(opts, { team = { tree = "right", members = "right", board = "right" } })
      for _, ft in ipairs({ "ade_chat", "ade_input", "ade_team_tree", "ade_team_members", "ade_team_board" }) do
        local found = 0
        for _, side in ipairs({ "right", "left", "bottom", "top" }) do
          for _, view in ipairs(opts[side] or {}) do
            if type(view) == "table" and view.ft == ft then
              found = found + 1
            end
          end
        end
        t.eq(1, found, ft .. " must be registered exactly once")
      end
      local function has(list, ft)
        for _, view in ipairs(list) do
          if type(view) == "table" and view.ft == ft then
            return true
          end
        end
        return false
      end
      t.truthy(has(opts.left, "ade_team_tree"), "the first mapping wins")
      t.falsy(has(opts.right, "ade_team_tree"))
    end)

    if not has_edgy then
      t.it("has_view reports false without edgy", function()
        t.falsy(edgy_views.has_view("ade_chat"))
      end)
      t.it("check_registered does not raise without edgy", function()
        edgy_views._checked = nil
        edgy_views._team_checked = nil
        local ok = pcall(edgy_views.check_registered)
        t.truthy(ok)
        local ok_team = pcall(edgy_views.check_team_registered)
        t.truthy(ok_team)
      end)
      return
    end

    local function with_edgy_config(right, fn)
      package.loaded["edgy.config"] = nil
      local config = require("edgy.config")
      config.setup({ right = right, animate = { enabled = false } })
      edgy_views._checked = nil
      edgy_views._team_checked = nil
      local ok, err = pcall(fn, config)
      package.loaded["edgy.config"] = nil
      edgy_views._checked = nil
      edgy_views._team_checked = nil
      if not ok then
        error(err, 0)
      end
    end

    t.it("detects both views when configured correctly", function()
      with_edgy_config({
        { ft = "ade_chat", title = "Agent" },
        { ft = "ade_input", title = "Message", size = { height = 0.2 } },
      }, function()
        t.truthy(edgy_views.has_view("ade_chat"), "ade_chat not detected")
        t.truthy(edgy_views.has_view("ade_input"), "ade_input not detected")
      end)
    end)

    t.it("detects a view registered by filetype string", function()
      with_edgy_config({ "ade_chat", { ft = "ade_input" } }, function()
        t.truthy(edgy_views.has_view("ade_chat"), "string entry not detected")
        t.truthy(edgy_views.has_view("ade_input"))
      end)
    end)

    t.it("detects the missing view in a named-key config", function()
      -- This is the mistake that leaves the composer outside the edgebar:
      -- `input = {...}` is a named key, so edgy's array part holds only one
      -- view and never builds that position.
      with_edgy_config({
        { ft = "ade_chat", title = "Agent" },
        input = { ft = "ade_input", title = "Message" },
      }, function()
        t.truthy(edgy_views.has_view("ade_chat"), "ade_chat should be found")
        t.falsy(edgy_views.has_view("ade_input"), "ade_input must be reported missing")
      end)
    end)

    t.it("reports nothing when both views are registered", function()
      with_edgy_config({
        { ft = "ade_chat" },
        { ft = "ade_input" },
      }, function()
        local warned = false
        local original = vim.notify
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN and tostring(msg):find("ade.nvim", 1, true) then
            warned = true
          end
        end
        edgy_views.check_registered()
        vim.wait(200)
        vim.notify = original
        t.falsy(warned, "warned although both views are registered")
      end)
    end)

    t.it("warns when a view is missing", function()
      with_edgy_config({
        { ft = "ade_chat" },
        input = { ft = "ade_input" },
      }, function()
        local messages = {}
        local original = vim.notify
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN then
            messages[#messages + 1] = tostring(msg)
          end
        end
        edgy_views.check_registered()
        vim.wait(300)
        vim.notify = original
        t.truthy(#messages > 0, "no warning was shown")
        t.match("ade_input", messages[1])
        t.match("array", messages[1])
      end)
    end)

    t.it("warns only once", function()
      with_edgy_config({
        { ft = "ade_chat" },
        input = { ft = "ade_input" },
      }, function()
        local count = 0
        local original = vim.notify
        vim.notify = function(_, level)
          if level == vim.log.levels.WARN then
            count = count + 1
          end
        end
        edgy_views.check_registered()
        edgy_views.check_registered()
        edgy_views.check_registered()
        vim.wait(300)
        vim.notify = original
        t.eq(1, count, "the warning must not repeat")
      end)
    end)

    t.it("warns once about missing team views", function()
      with_edgy_config({
        { ft = "ade_chat" },
        { ft = "ade_input" },
      }, function()
        local messages = {}
        local original = vim.notify
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN then
            messages[#messages + 1] = tostring(msg)
          end
        end
        edgy_views.check_team_registered()
        edgy_views.check_team_registered()
        vim.wait(300)
        vim.notify = original
        t.eq(1, #messages, "the team warning must appear exactly once")
        t.match("ade_team_tree", messages[1])
        t.match("team", messages[1])
      end)
    end)

    t.it("reports nothing when the team views are registered", function()
      with_edgy_config({
        { ft = "ade_chat" },
        { ft = "ade_input" },
        { ft = "ade_team_tree" },
        { ft = "ade_team_members" },
        { ft = "ade_team_board" },
      }, function()
        local warned = false
        local original = vim.notify
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN and tostring(msg):find("ade.nvim", 1, true) then
            warned = true
          end
        end
        edgy_views.check_team_registered()
        vim.wait(200)
        vim.notify = original
        t.falsy(warned, "warned although every team view is registered")
      end)
    end)
  end)
end
