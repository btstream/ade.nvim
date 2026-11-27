-- Highlight coverage for the pickers the plugin draws itself.
--
-- Both dialogs must colour every region through the `AdePicker*` groups so a
-- user can restyle them without touching the panel's groups.
return function(t)
  local highlights = require("ade.ui.highlights")
  local picker = require("ade.ui.picker")

  ---Highlight groups used by the extmarks of `buf` in namespace `name`.
  ---@param buf integer
  ---@param name string
  ---@return table<string, integer[]> groups -> rows (1-based)
  local function marks(buf, name)
    local ns = vim.api.nvim_create_namespace(name)
    local seen = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local details = mark[4]
      local hl = details.hl_group
      if hl and hl ~= "" then
        seen[hl] = seen[hl] or {}
        table.insert(seen[hl], mark[2] + 1)
      end
      -- Virtual text carries its own group per chunk.
      for _, chunk in ipairs(details.virt_text or {}) do
        seen[chunk[2]] = seen[chunk[2]] or {}
        table.insert(seen[chunk[2]], mark[2] + 1)
      end
    end
    return seen
  end

  ---Close every window created for a picker so the next test starts clean.
  local function close_all()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      local ft = vim.bo[buf].filetype
      if
        ft == "ade_sessions" or (vim.bo[buf].buftype == "nofile" and vim.api.nvim_win_get_config(win).relative ~= "")
      then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  t.describe("picker highlights", function()
    t.it("defines a group for every picker region", function()
      highlights.setup()
      for key, name in pairs(highlights.picker) do
        t.truthy(highlights.groups[name], name .. " (" .. key .. ") is not in the group table")
        local hl = vim.api.nvim_get_hl(0, { name = name })
        t.truthy(hl and next(hl) ~= nil, name .. " was not defined")
      end
    end)

    t.it("maps the floating window chrome onto the picker groups", function()
      local winhl = highlights.picker_winhl()
      for _, pair in ipairs({
        "Normal:AdePickerNormal",
        "NormalNC:AdePickerNormal",
        "FloatBorder:AdePickerBorder",
        "FloatTitle:AdePickerTitle",
      }) do
        t.truthy(winhl:find(pair, 1, true), "winhighlight is missing " .. pair)
      end
    end)

    t.it("applies the picker chrome after style = minimal", function()
      local wins = {}
      local original = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(...)
        local win = original(...)
        wins[#wins + 1] = win
        return win
      end
      local ok, err = pcall(function()
        picker._internal_select({
          title = "Pick",
          items = { { label = "one", value = 1 } },
          on_choice = function() end,
        })
      end)
      vim.api.nvim_open_win = original
      if not ok then
        close_all()
        error(err)
      end
      local win = wins[#wins]
      t.truthy(win and vim.api.nvim_win_is_valid(win), "no window was opened")
      local winhl = vim.api.nvim_get_option_value("winhighlight", { win = win })
      t.truthy(winhl:find("Normal:AdePickerNormal", 1, true), "minimal style overrode the picker background")
      t.truthy(winhl:find("FloatBorder:AdePickerBorder", 1, true), "minimal style overrode the picker border")
      close_all()
    end)

    t.it("colours rows, the cursor row and descriptions", function()
      local buf
      local wins = {}
      local original = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(...)
        local win = original(...)
        wins[#wins + 1] = win
        return win
      end
      local ok, err = pcall(function()
        picker._internal_select({
          title = "Pick",
          filter = false,
          items = {
            { label = "one", description = "first", value = 1 },
            { label = "two", value = 2 },
          },
          on_choice = function() end,
        })
      end)
      vim.api.nvim_open_win = original
      if not ok then
        close_all()
        error(err)
      end
      buf = vim.api.nvim_win_get_buf(wins[#wins])

      local groups = marks(buf, "ade_picker")
      t.truthy(groups.AdePickerItem, "rows have no item group")
      t.eq({ 1, 2 }, groups.AdePickerItem, "every row should carry the item group")
      t.eq({ 1 }, groups.AdePickerSelection, "only the cursor row should be selected")
      t.eq({ 1 }, groups.AdePickerDescription, "the description is drawn with its own group")

      -- The selected row keeps its item mark *and* gains the selection, so a
      -- foreground-only override still shows the floating background.
      t.truthy(vim.tbl_contains(groups.AdePickerItem, 1))
      close_all()
    end)

    t.it("colours the filter prompt and the empty-state line", function()
      local win = nil
      local original = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(...)
        win = original(...)
        return win
      end
      local items = {}
      for i = 1, 12 do
        items[i] = { label = "item " .. i, value = i }
      end
      picker._internal_select({ title = "Pick", items = items, on_choice = function() end })
      vim.api.nvim_open_win = original
      local buf = vim.api.nvim_win_get_buf(win)
      local groups = marks(buf, "ade_picker")
      t.truthy(groups.AdePickerPrompt, "the filter row has no prompt group")
      close_all()

      -- Empty state: the "no match" line uses its own group.
      win = nil
      vim.api.nvim_open_win = function(...)
        win = original(...)
        return win
      end
      picker._internal_select({ title = "Pick", items = {}, filter = false, on_choice = function() end })
      vim.api.nvim_open_win = original
      buf = vim.api.nvim_win_get_buf(win)
      groups = marks(buf, "ade_picker")
      t.truthy(groups.AdePickerEmpty, "the empty state has no group")
      close_all()
    end)

    t.it("reports fuzzy match ranges", function()
      t.eq({ { s = 0, e = 1 } }, picker.fuzzy_ranges("a", "abc"), "a single character match")
      -- Adjacent characters merge into one range.
      t.eq({ { s = 0, e = 2 } }, picker.fuzzy_ranges("ab", "abc"))
      -- A gap produces two ranges.
      t.eq({ { s = 0, e = 1 }, { s = 2, e = 3 } }, picker.fuzzy_ranges("ac", "abc"))
      t.eq(nil, picker.fuzzy_ranges("z", "abc"), "a miss must not return ranges")
      t.eq({}, picker.fuzzy_ranges("", "abc"), "an empty query matches without marking")
    end)
  end)

  t.describe("session browser highlights", function()
    local internal = require("ade.ui.session_browser.internal")

    ---A browser state with the two rows the highlight cases need.
    local function browser_state(over)
      return vim.tbl_extend("force", {
        scopes = { "here", "agent", "all" },
        scope = "here",
        entries = {
          {
            agent = "opencode",
            sessionId = "aaa",
            title = "First",
            cwd = "/tmp/project",
            updatedAt = "2026-11-07T10:49:33.899Z",
            source = "live",
          },
          { agent = "opencode", sessionId = "bbb", title = "Second", cwd = "/tmp/project", source = "live" },
        },
        agents = { "opencode" },
        agent_state = {},
        refreshing = {},
        unavailable = {},
        current_agent = "opencode",
        current_id = "aaa",
        use_icons = true,
        can_delete = function()
          return true
        end,
        on_open = function() end,
        on_delete = function(_, done)
          done(true)
        end,
        on_refresh = function() end,
        on_cycle_scope = function() end,
        on_close = function() end,
        is_dir = function()
          return true
        end,
      }, over or {})
    end

    ---Keymap callbacks by lhs.
    local function maps_of(buf)
      local maps = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        maps[map.lhs] = map
      end
      return maps
    end

    t.it("colours the current marker, separator, metadata and footer", function()
      local browser = internal.open(browser_state())
      local groups = marks(browser.buf, "ade_session_browser")

      t.truthy(groups.AdePickerItem, "rows have no item group")
      -- Rows start below the scope line, the agent status and the rule.
      t.eq({ 4 }, groups.AdePickerSelection, "only the cursor row should be selected")
      t.truthy(vim.tbl_contains(groups.AdePickerCurrent, 4), "the current session arrow lost its group")
      t.falsy(vim.tbl_contains(groups.AdePickerCurrent, 5), "a plain row was marked as current")
      t.eq({ 4 }, groups.AdePickerCurrentItem, "the current session title lost its emphasis")
      t.truthy(groups.AdePickerMeta, "the timestamp has no group")
      t.truthy(groups.AdePickerSeparator, "the rules have no group")
      t.truthy(groups.AdePickerFooter, "the footer hint has no group")

      -- Rows are items, the rules and footer are not.
      t.falsy(vim.tbl_contains(groups.AdePickerItem, 3), "the header rule must not be painted as a row")
      pcall(vim.api.nvim_win_close, browser.win, true)
    end)

    t.it("colours the typed query with the prompt group", function()
      local browser = internal.open(browser_state())
      -- Drive the filter mapping the way a keystroke would.
      maps_of(browser.buf).F.callback()
      local groups = marks(browser.buf, "ade_session_browser")
      t.truthy(groups.AdePickerPrompt, "the live query has no group")
      -- "First" matched F: the match is marked inside the title, after the marker.
      t.truthy(groups.AdePickerMatch, "the filter match has no group")
      pcall(vim.api.nvim_win_close, browser.win, true)
    end)

    t.it("marks the empty state", function()
      local browser = internal.open(browser_state())
      maps_of(browser.buf).Z.callback()
      local groups = marks(browser.buf, "ade_session_browser")
      t.truthy(groups.AdePickerEmpty, "the empty state has no group")
      pcall(vim.api.nvim_win_close, browser.win, true)
    end)
  end)
end
