-- A1/A2: team pane placement (`teams.layout`) in native and external mode.
--
-- These cases drive `layout_pane` directly with a stub dashboard: placement is
-- window geometry, not team state, so no service is needed.
return function(t)
  local LayoutPane = require("ade.ui.team.layout_pane")
  local Board = require("ade.ui.team.board")
  local config = require("ade.config")
  local ade_layout = require("ade.layout")

  ---@param over table|nil
  ---@return table
  local function cfg(over)
    return config.validate(config.merge(config.defaults, over or {}), over)
  end

  local function dashboard(settings)
    return {
      config = function()
        return settings
      end,
      notify = function() end,
      attach_keys = function() end,
      render_pane = function()
        return { "pane" }, {}, {}, {}
      end,
      selected_pane = nil,
    }
  end

  local function pane(t, settings)
    local p = LayoutPane.new(dashboard(settings))
    t.cleanup(function()
      pcall(function()
        p:close()
      end)
    end)
    return p
  end

  local function screen(t, columns, lines)
    local old_columns, old_lines = vim.o.columns, vim.o.lines
    if columns then
      vim.o.columns = columns
    end
    if lines then
      vim.o.lines = lines
    end
    t.cleanup(function()
      vim.o.columns = old_columns
      vim.o.lines = old_lines
      pcall(vim.cmd, "wincmd =")
    end)
  end

  local function lines_total()
    return vim.o.lines - vim.o.cmdheight
  end

  local function assert_side(win, side, columns)
    local placed = vim.api.nvim_win_get_position(win)
    local width = vim.api.nvim_win_get_width(win)
    if side == "left" then
      t.eq(0, placed[2], "a left pane starts at the left edge")
    elseif side == "right" then
      t.eq(columns, placed[2] + width, "a right pane ends at the right edge")
    elseif side == "top" then
      t.eq(0, placed[1], "a top pane starts at the top edge")
    elseif side == "bottom" then
      t.truthy(placed[1] > 0, "a bottom pane sits below the base window")
    end
  end

  t.describe("team pane positions", function()
    t.it("places each pane on its configured side with its size", function()
      for _, case in ipairs({
        { side = "right", width = 32 },
        { side = "left", width = 40 },
      }) do
        screen(t, 200, 50)
        local settings = cfg({
          teams = { layout = { panes = { members = { position = case.side, size = case.width } } } },
        })
        local p = pane(t, settings)
        t.eq(true, p:show("members"))
        local win = p:win("members")
        t.truthy(win, case.side .. " pane did not open")
        t.eq("", vim.api.nvim_win_get_config(win).relative, "expected a split")
        t.eq(case.width, vim.api.nvim_win_get_width(win), case.side .. " pane width")
        t.eq(true, vim.wo[win].winfixwidth, case.side .. " pane is pinned")
        assert_side(win, case.side, vim.o.columns)
        p:close()
      end
    end)

    t.it("places top and bottom panes with their height", function()
      for _, side in ipairs({ "top", "bottom" }) do
        screen(t, 200, 50)
        local settings = cfg({
          teams = { layout = { panes = { members = { position = side, size = 6 } } } },
        })
        local p = pane(t, settings)
        t.eq(true, p:show("members"))
        local win = p:win("members")
        t.eq("", vim.api.nvim_win_get_config(win).relative, "expected a split")
        t.eq(6, vim.api.nvim_win_get_height(win), side .. " pane height")
        t.eq(true, vim.wo[win].winfixheight, side .. " pane is pinned")
        t.eq(false, vim.wo[win].winfixwidth, side .. " pane does not pin its width")
        assert_side(win, side, vim.o.columns)
        p:close()
      end
    end)

    t.it("treats sizes up to 1 as fractions and clamps columns", function()
      screen(t, 200, 50)

      local settings = cfg({ teams = { layout = { panes = { members = { position = "right", size = 0.25 } } } } })
      local p = pane(t, settings)
      t.eq(true, p:show("members"))
      t.eq(50, vim.api.nvim_win_get_width(p:win("members")), "0.25 of 200 columns")
      p:close()

      -- 0.05 of 200 is 10 cells: clamped to the 16-column minimum. Vim keeps
      -- the focused window at least 'winwidth' wide, so that is the effective
      -- floor for the pane we focus after opening it.
      settings = cfg({ teams = { layout = { panes = { members = { position = "right", size = 0.05 } } } } })
      p = pane(t, settings)
      t.eq(true, p:show("members"))
      t.eq(math.max(16, vim.o.winwidth), vim.api.nvim_win_get_width(p:win("members")), "clamped to the minimum width")
      p:close()

      -- A fraction of the editor lines, for a top/bottom pane.
      settings = cfg({ teams = { layout = { panes = { members = { position = "bottom", size = 0.5 } } } } })
      p = pane(t, settings)
      t.eq(true, p:show("members"))
      t.eq(math.floor(lines_total() * 0.5 + 0.5), vim.api.nvim_win_get_height(p:win("members")))
      p:close()
    end)

    t.it("always floats an explicit float position", function()
      screen(t, 200, 50)
      local settings = cfg({ teams = { layout = { panes = { board = { position = "float" } } } } })
      local p = pane(t, settings)
      t.eq(true, p:show("board"))
      local win = p:win("board")
      t.truthy(vim.api.nvim_win_get_config(win).relative ~= "", "an explicit float must float")
      p:close()
    end)

    t.it("gives every pane its own column by default (stack off)", function()
      screen(t, 200, 50)
      local p = pane(t, cfg())
      t.eq(true, p:show("members"))
      local members = p:win("members")
      t.eq(true, p:show("board"))
      local board = p:win("board")
      t.eq("", vim.api.nvim_win_get_config(board).relative, "the board is a split")
      t.eq(32, vim.api.nvim_win_get_width(members), "members keeps its size")
      t.eq(true, vim.wo[members].winfixwidth)
      t.truthy(
        vim.api.nvim_win_get_position(board)[2] > vim.api.nvim_win_get_position(members)[2],
        "the board opens its own column to the right of members"
      )
      t.truthy(vim.api.nvim_win_get_width(board) > 32, "a pane without a size takes the free space")
      t.eq(
        vim.api.nvim_win_get_height(members),
        vim.api.nvim_win_get_height(board),
        "the board spans the full height, not below members"
      )
      p:close()
    end)

    t.it("stacks same-side panes in PANES order whatever the open order", function()
      for _, order in ipairs({ { "tree", "members", "board" }, { "board", "members", "tree" } }) do
        screen(t, 200, 50)
        local p = pane(t, cfg({ teams = { layout = { stack = true } } }))
        for _, name in ipairs(order) do
          t.eq(true, p:show(name), name .. " did not open")
        end
        local tree, members, board = p:win("tree"), p:win("members"), p:win("board")
        for _, win in ipairs({ tree, members, board }) do
          t.eq("", vim.api.nvim_win_get_config(win).relative, "stacked panes are splits")
        end
        local col = vim.api.nvim_win_get_position(tree)[2]
        t.eq(col, vim.api.nvim_win_get_position(members)[2], "tree and members share a column")
        t.eq(col, vim.api.nvim_win_get_position(board)[2], "the board joins the column")
        t.truthy(
          vim.api.nvim_win_get_position(tree)[1] < vim.api.nvim_win_get_position(members)[1],
          "members sits below the tree"
        )
        t.truthy(
          vim.api.nvim_win_get_position(members)[1] < vim.api.nvim_win_get_position(board)[1],
          "the board sits below members"
        )
        t.eq(32, vim.api.nvim_win_get_width(tree))
        t.eq(32, vim.api.nvim_win_get_width(members))
        t.eq(32, vim.api.nvim_win_get_width(board), "a pane without a size shares the column width")
        p:close()
      end
    end)

    t.it("stacks bottom panes left to right in PANES order", function()
      for _, order in ipairs({ { "tree", "members", "board" }, { "board", "members", "tree" } }) do
        screen(t, 200, 50)
        local p = pane(
          t,
          cfg({
            teams = {
              layout = {
                stack = true,
                panes = {
                  tree = { position = "bottom", size = 5 },
                  members = { position = "bottom", size = 5 },
                  board = { position = "bottom", size = 5 },
                },
              },
            },
          })
        )
        for _, name in ipairs(order) do
          t.eq(true, p:show(name), name .. " did not open")
        end
        local tree, members, board = p:win("tree"), p:win("members"), p:win("board")
        local row = vim.api.nvim_win_get_position(tree)[1]
        t.eq(row, vim.api.nvim_win_get_position(members)[1], "tree and members share a row")
        t.eq(row, vim.api.nvim_win_get_position(board)[1], "the board joins the row")
        t.truthy(
          vim.api.nvim_win_get_position(tree)[2] < vim.api.nvim_win_get_position(members)[2],
          "members sits right of the tree"
        )
        t.truthy(
          vim.api.nvim_win_get_position(members)[2] < vim.api.nvim_win_get_position(board)[2],
          "the board sits right of members"
        )
        t.eq(5, vim.api.nvim_win_get_height(tree))
        t.eq(5, vim.api.nvim_win_get_height(members))
        t.eq(5, vim.api.nvim_win_get_height(board))
        p:close()
      end
    end)

    t.it("re-inserts a closed and reopened stacked pane in order", function()
      screen(t, 200, 50)
      local p = pane(t, cfg({ teams = { layout = { stack = true } } }))
      for _, name in ipairs({ "board", "tree", "members" }) do
        t.eq(true, p:show(name))
      end
      p:close_pane("members")
      t.eq(nil, p:win("members"))
      t.eq(true, p:show("members"))
      local tree, members, board = p:win("tree"), p:win("members"), p:win("board")
      t.truthy(
        vim.api.nvim_win_get_position(tree)[1] < vim.api.nvim_win_get_position(members)[1],
        "the reopened members sits below the tree"
      )
      t.truthy(
        vim.api.nvim_win_get_position(members)[1] < vim.api.nvim_win_get_position(board)[1],
        "the reopened members stays above the board"
      )
      p:close()
    end)

    t.it("keeps a split pane a split when another pane asks for a float", function()
      for _, backend in ipairs({ "native", "external" }) do
        screen(t, 200, 50)
        local settings = cfg({
          layout = { backend = backend },
          teams = { layout = { panes = { board = { position = "float" } } } },
        })
        local p = pane(t, settings)
        t.eq(true, p:show("members"))
        local members = p:win("members")
        local before = vim.api.nvim_win_get_width(members)
        t.eq(true, p:show("board"))
        local board = p:win("board")
        t.truthy(vim.api.nvim_win_get_config(board).relative ~= "", "the board is a float")
        t.eq("", vim.api.nvim_win_get_config(members).relative, backend .. ": members stays a split")
        t.eq(before, vim.api.nvim_win_get_width(members), backend .. ": the split keeps its width")
        t.eq(nil, p.floats.members, "members is not recorded as a float")
        p:close()
      end
    end)

    t.it("returns a float to a split when its position is not float", function()
      screen(t, 100, 50)
      local p = pane(t, cfg())
      t.eq(true, p:show("members"))
      t.truthy(vim.api.nvim_win_get_config(p:win("members")).relative ~= "", "narrow editor floats")
      p:close_pane("members")
      screen(t, 200, 50)
      t.eq(true, p:show("members"))
      t.eq("", vim.api.nvim_win_get_config(p:win("members")).relative, "a wide editor splits")
      p:close()
    end)

    t.it("floats every pane below float_below and splits above it", function()
      screen(t, 100, 50)
      local p = pane(t, cfg())
      t.eq(true, p:show("members"))
      t.truthy(vim.api.nvim_win_get_config(p:win("members")).relative ~= "", "narrow editor floats")
      p:close()

      local settings = cfg({
        teams = { layout = { float_below = 80, panes = { members = { position = "right", size = 32 } } } },
      })
      p = pane(t, settings)
      t.eq(true, p:show("members"))
      t.eq("", vim.api.nvim_win_get_config(p:win("members")).relative, "above float_below it splits")
      t.eq(32, vim.api.nvim_win_get_width(p:win("members")))
      p:close()
    end)

    t.it("keeps pinned ordinary windows where they were", function()
      screen(t, 200, 50)
      vim.cmd("vsplit")
      local side = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_width(side, 30)
      vim.wo[side].winfixwidth = true
      local p = pane(t, cfg())
      t.eq(true, p:show("members"))
      t.eq(30, vim.api.nvim_win_get_width(side), "a pinned sidebar keeps its width")
      t.eq(true, vim.wo[side].winfixwidth)
      p:close()
    end)

    t.it("cleans up a pane closed from outside", function()
      screen(t, 200, 50)
      local p = pane(t, cfg())
      t.eq(true, p:show("members"))
      local win = p:win("members")
      local buf = p:buf("members")
      vim.api.nvim_win_close(win, true)
      vim.wait(200, function()
        return p.windows.members == nil
      end, 20)
      t.eq(nil, p.windows.members, "the WinClosed handler forgot the window")
      t.falsy(vim.api.nvim_buf_is_valid(buf), "the pane buffer is deleted")
    end)
  end)

  t.describe("team pane external backend", function()
    t.it("follows layout.backend through inherit", function()
      local settings = cfg({ layout = { backend = "external" } })
      local p = pane(t, settings)
      t.eq("external", p:backend())
      settings = cfg({
        layout = { backend = "external" },
        teams = { layout = { backend = "native" } },
      })
      t.eq("native", pane(t, settings):backend())
      settings = cfg({
        layout = { backend = "native" },
        teams = { layout = { backend = "external" } },
      })
      t.eq("external", pane(t, settings):backend())
    end)

    t.it("splits without sizing, pinning or a narrow float fallback", function()
      screen(t, 100, 50)
      local settings = cfg({
        layout = { backend = "external" },
        teams = { layout = { panes = { members = { position = "right", size = 40 } } } },
      })
      local p = pane(t, settings)
      t.eq(true, p:show("members"))
      local win = p:win("members")
      t.eq("", vim.api.nvim_win_get_config(win).relative, "no float fallback for a narrow editor")
      t.falsy(vim.api.nvim_win_get_width(win) == 40, "the configured width must not be applied")
      t.eq(false, vim.wo[win].winfixwidth, "no width pin")
      p:close()

      settings = cfg({
        layout = { backend = "external" },
        teams = { layout = { panes = { members = { position = "top", size = 6 } } } },
      })
      p = pane(t, settings)
      t.eq(true, p:show("members"))
      win = p:win("members")
      t.falsy(vim.api.nvim_win_get_height(win) == 6, "the configured height must not be applied")
      t.eq(false, vim.wo[win].winfixheight, "no height pin")
      p:close()
    end)

    t.it("still floats an explicit float position", function()
      screen(t, 200, 50)
      local settings = cfg({
        layout = { backend = "external" },
        teams = { layout = { panes = { board = { position = "float" } } } },
      })
      local p = pane(t, settings)
      t.eq(true, p:show("board"))
      t.truthy(vim.api.nvim_win_get_config(p:win("board")).relative ~= "", "explicit float under external")
      p:close()
    end)

    t.it("ignores stack: the layout manager owns the placement", function()
      screen(t, 200, 50)
      local settings = cfg({
        layout = { backend = "external" },
        teams = { layout = { stack = true } },
      })
      local p = pane(t, settings)
      t.eq(true, p:show("members"))
      t.eq(true, p:show("board"))
      local members, board = p:win("members"), p:win("board")
      t.truthy(
        vim.api.nvim_win_get_position(board)[2] > vim.api.nvim_win_get_position(members)[2],
        "external opens a separate column instead of stacking"
      )
      t.eq(vim.api.nvim_win_get_height(members), vim.api.nvim_win_get_height(board))
      p:close()
    end)

    t.it("adopts a dragged members width natively but never externally", function()
      screen(t, 200, 50)
      local p = pane(t, cfg({ layout = { backend = "native" } }))
      t.eq(true, p:show("members"))
      -- `install_events` ignores resizes for 200ms while it settles.
      vim.wait(250)
      vim.api.nvim_win_set_width(p:win("members"), 70)
      vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
      vim.wait(50)
      t.eq(70, p.adopted_width, "native mode keeps the dragged width")
      p:close()

      p = pane(t, cfg({ layout = { backend = "external" } }))
      t.eq(true, p:show("members"))
      vim.wait(250)
      vim.api.nvim_win_set_width(p:win("members"), 70)
      vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
      vim.wait(50)
      t.eq(nil, p.adopted_width, "external mode adopts nothing")
      p:close()
    end)

    t.it("only closes windows, never restores geometry", function()
      screen(t, 200, 50)
      local p = pane(t, cfg({ layout = { backend = "external" } }))
      t.eq(true, p:show("members"))
      t.eq(true, p:show("board"))
      local widths, heights = 0, 0
      local real_width = vim.api.nvim_win_set_width
      local real_height = vim.api.nvim_win_set_height
      vim.api.nvim_win_set_width = function(...)
        widths = widths + 1
        return real_width(...)
      end
      vim.api.nvim_win_set_height = function(...)
        heights = heights + 1
        return real_height(...)
      end
      t.cleanup(function()
        vim.api.nvim_win_set_width = real_width
        vim.api.nvim_win_set_height = real_height
      end)
      p:close_pane("board")
      t.eq(0, widths, "close_pane must not set a width")
      t.eq(0, heights, "close_pane must not set a height")
      p:close()
      t.eq(0, widths, "close must not set a width")
      t.eq(0, heights, "close must not set a height")
    end)
  end)

  t.describe("teams.layout configuration", function()
    t.it("maps the deprecated dashboard keys when the new ones are not set", function()
      local merged = cfg({ teams = { dashboard = { wide = 100, members_width = 40 } } })
      t.eq(100, merged.teams.layout.float_below)
      t.eq(40, merged.teams.layout.panes.members.size)
      t.eq(40, merged.teams.layout.panes.tree.size)
      t.eq(nil, merged.teams.layout.panes.board.size, "the board still takes the free space")
    end)

    t.it("keeps a value set at the new key", function()
      local merged = cfg({
        teams = {
          dashboard = { wide = 100, members_width = 40 },
          layout = { float_below = 220, panes = { members = { size = 24 } } },
        },
      })
      t.eq(220, merged.teams.layout.float_below)
      t.eq(24, merged.teams.layout.panes.members.size)
      t.eq(40, merged.teams.layout.panes.tree.size, "tree still follows the old key")
    end)

    t.it("does not apply aliases without the raw user table", function()
      -- `validate(merged)` cannot tell a default from a value the user set, so
      -- it must not let the old keys overwrite the new ones.
      local merged = config.validate(config.merge(config.defaults, {
        teams = {
          dashboard = { wide = 100, members_width = 40 },
          layout = { float_below = 220 },
        },
      }))
      t.eq(220, merged.teams.layout.float_below, "the new key survives without raw opts")
      t.eq(32, merged.teams.layout.panes.members.size, "the old key is not guessed over the default")
      t.eq(32, merged.teams.layout.panes.tree.size)
    end)

    t.it("rejects invalid layout settings", function()
      t.raises(function()
        cfg({ teams = { layout = { backend = "edgy" } } })
      end, "teams.layout.backend must be one of")
      t.raises(function()
        cfg({ teams = { layout = { float_below = 20 } } })
      end, "teams.layout.float_below")
      t.raises(function()
        cfg({ teams = { layout = { stack = "yes" } } })
      end, "teams.layout.stack must be a boolean")
      t.raises(function()
        cfg({ teams = { layout = { panes = { tree = { position = "centre" } } } } })
      end, "teams.layout.panes.tree.position must be one of")
      t.raises(function()
        cfg({ teams = { layout = { panes = { board = { size = "wide" } } } } })
      end, "teams.layout.panes.board.size must be a number")
      t.raises(function()
        cfg({ teams = { layout = { panes = { board = { size = 0 } } } } })
      end, "teams.layout.panes.board.size")
      t.raises(function()
        cfg({ teams = { layout = false } })
      end, "teams.layout must be a table")
    end)

    t.it("reads a dashboard-only configuration table at the pane", function()
      -- Hand-built tables (tests, third-party callers) carry only the old
      -- keys; the pane still honours them without normalisation.
      local p = pane(t, {
        layout = { backend = "native" },
        teams = { dashboard = { wide = 120, members_width = 44 } },
      })
      t.eq(120, p:wide())
      t.eq(44, p:size("members", "right"))
      t.eq(44, p:size("tree", "right"))
      t.eq(nil, p:size("board", "right"))
    end)
  end)

  t.describe("team pane lock guard", function()
    t.it("turns a split of a team pane into a scratch window", function()
      screen(t, 200, 50)
      ade_layout.setup(cfg({ layout = { backend = "native" } }))
      t.cleanup(function()
        pcall(ade_layout.setup, cfg())
      end)
      local settings = cfg()
      local p = pane(t, settings)
      t.eq(true, p:show("members"))
      local win = p:win("members")
      t.truthy(vim.api.nvim_get_option_value("winfixbuf", { win = win }), "the pane window is locked")
      vim.api.nvim_set_current_win(win)
      vim.cmd("split")
      local other = vim.api.nvim_get_current_win()
      t.truthy(other ~= win)
      t.falsy(vim.bo[vim.api.nvim_win_get_buf(other)].filetype == "ade_team_members")
      t.eq("ade_team_members", vim.bo[vim.api.nvim_win_get_buf(win)].filetype, "the pane keeps its buffer")
      t.truthy(vim.api.nvim_get_option_value("winfixbuf", { win = win }))
      pcall(vim.api.nvim_win_close, other, true)
      p:close()
    end)

    t.it("does not remember a team pane as the focus to restore", function()
      screen(t, 200, 50)
      ade_layout.setup(cfg({ layout = { backend = "native" } }))
      t.cleanup(function()
        pcall(ade_layout.setup, cfg())
      end)
      local ordinary = vim.api.nvim_get_current_win()
      ade_layout.remember_focus()
      t.eq(ordinary, ade_layout.saved_focus())
      local p = pane(t, cfg())
      t.eq(true, p:show("members"))
      vim.api.nvim_set_current_win(p:win("members"))
      ade_layout.remember_focus()
      t.eq(ordinary, ade_layout.saved_focus(), "the team pane must not replace the remembered window")
      p:close()
    end)
  end)

  t.describe("team board in a bottom pane", function()
    t.it("keeps its column layout within a short window", function()
      screen(t, 200, 50)
      local settings = cfg({
        teams = { layout = { panes = { board = { position = "bottom", size = 6 } } } },
      })
      local p = pane(t, settings)
      t.eq(true, p:show("board"))
      local win = p:win("board")
      t.eq(6, vim.api.nvim_win_get_height(win))
      local width = vim.api.nvim_win_get_width(win)
      local board = {
        rev = 1,
        columns = { "待开发", "进行中", "已完成" },
        cards = {
          { id = "T1", title = "fix it", column = "进行中", fields = {}, archived = false },
          { id = "T2", title = "ship it", column = "已完成", fields = {}, archived = false },
        },
      }
      local lines = Board.lines(board, {}, { width = width })
      t.truthy(#lines > 0, "the board renders")
      for _, line in ipairs(lines) do
        t.truthy(vim.fn.strdisplaywidth(line) <= width, line)
      end
      p:close()
    end)
  end)
end
