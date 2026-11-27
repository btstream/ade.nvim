-- snacks.nvim backend for the unified session browser.
--
-- snacks provides fuzzy matching (fzf syntax), a live preview pane and the
-- user's picker theme, so this module only supplies the rows and the
-- ADE-specific actions: open, delete, scope and agent cycling, refresh. The
-- owner's state table is read on every finder call, so a `sessions.updated`
-- update only needs `picker:refresh()`.
--
-- snacks is optional: `open()` returns nil when it is unavailable and the
-- caller falls back to the built-in window.
local Icons = require("ade.ui.icons")
local highlights = require("ade.ui.highlights")
local model = require("ade.ui.session_browser.model")

-- Only the rows are ours to colour: snacks owns the window chrome, so the
-- `AdePickerNormal`/`Border`/`Title` groups of the built-in pickers do not
-- apply here and the user's snacks theme keeps working.
local HL = highlights.picker

local M = {}

---Load snacks, returning nil when it is not installed or not configured.
---@return table|nil
local function load_snacks()
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then
    return nil
  end
  -- The picker module must be available too; a `snacks.nvim` install with
  -- `picker = { enabled = false }` should not be treated as usable.
  local picker_ok, picker = pcall(require, "snacks.picker")
  if not picker_ok or type(picker) ~= "table" then
    return nil
  end
  return snacks
end

---Whether the snacks backend can be used right now.
---@return boolean
function M.available()
  return load_snacks() ~= nil
end

---The picker title: scope plus the shared per-agent status.
---
---snacks has no footer or status area, so the agent states (unavailable,
---refreshing, list errors) and a refresh failure live in the title and are
---redrawn by `handle:update`.
---@param state table
---@param icons table
---@return string
local function title_for(state, icons)
  local label = model.scope_titles[state.scope or "here"] or tostring(state.scope)
  local parts = { "Sessions · " .. label }
  local header = model.agent_header_text(state, icons, 80)
  if type(header) == "string" and header ~= "" then
    parts[#parts + 1] = model.truncate(header, 80)
  end
  if type(state.status) == "string" and state.status ~= "" then
    parts[#parts + 1] = model.truncate(state.status, 60)
  end
  return " " .. table.concat(parts, " · ") .. " "
end

---Preview text shown to the right of the list.
---@param entry table
---@return string
local function render_preview(entry)
  local lines = {
    "# " .. model.label_of(entry),
    "",
    "- **Agent**: `" .. tostring(entry.agent or "") .. "`",
    "- **ID**: `" .. tostring(entry.sessionId) .. "`",
  }
  if type(entry.cwd) == "string" and entry.cwd ~= "" then
    lines[#lines + 1] = "- **Directory**: `" .. entry.cwd .. "`"
  end
  local updated = model.short_time(entry.updatedAt)
  if updated ~= "" then
    lines[#lines + 1] = "- **Updated**: " .. updated
  end
  local created = model.short_time(entry.createdAt)
  if created ~= "" then
    lines[#lines + 1] = "- **Created**: " .. created
  end
  return table.concat(lines, "\n")
end

---Open the snacks session browser.
---@param view table the same state table the built-in window takes
---@return table|nil handle nil when snacks is unavailable
function M.open(view)
  local Snacks = load_snacks()
  if not Snacks then
    return nil
  end

  local icon_set = Icons.get(view.use_icons)
  local state = view
  -- The agent filter is a view concern; it only applies to the `all` scope.
  local agent_filter = nil
  -- While a modal picker owns focus (the delete or switch confirmation), the
  -- picker must stay open instead of snacks' auto_close closing it.
  local busy = false

  local function finder()
    local items = {}
    for _, entry in ipairs(state.entries or {}) do
      if state.scope ~= "all" or agent_filter == nil or entry.agent == agent_filter then
        items[#items + 1] = {
          -- Same per-scope haystack as the built-in window: here matches only
          -- title/id, agent/all also match the agent and directory.
          text = model.haystack(entry, state.scope),
          session = entry,
          preview = {
            text = render_preview(entry),
            ft = "markdown",
            loc = false,
          },
        }
      end
    end
    return items
  end

  local picker
  -- `auto_close` is suspended while a modal period owns focus. The original
  -- value (nil means snacks' own default, false is a user config) is captured
  -- on the outermost entry and restored exactly on the outermost exit.
  local modal_depth = 0
  local original_auto_close = nil
  local function enter_modal()
    if modal_depth == 0 then
      original_auto_close = picker.opts and picker.opts.auto_close
      if picker.opts then
        picker.opts.auto_close = false
      end
    end
    modal_depth = modal_depth + 1
  end
  local function leave_modal()
    if modal_depth == 0 then
      return
    end
    modal_depth = modal_depth - 1
    if modal_depth == 0 and picker.opts then
      picker.opts.auto_close = original_auto_close
    end
  end

  picker = Snacks.picker({
    title = title_for(state, icon_set),
    layout = { preset = "select" },
    preview = "preview",
    show_empty = true,
    format = function(item)
      local entry = item.session
      local current = entry.agent == state.current_agent and entry.sessionId == state.current_id
      local marker = current and (icon_set.arrow_right .. " ") or "  "
      local when_text = model.short_time(entry.updatedAt or entry.createdAt)

      local ret = {
        { marker, current and HL.current or HL.description },
        { tostring(entry.agent or "") .. "  ", HL.meta },
        { model.label_of(entry), current and HL.current_item or HL.item },
      }
      local cwd = model.short_path(entry.cwd)
      if cwd ~= "" then
        ret[#ret + 1] = { "  " .. model.truncate_left(cwd, 36), HL.description }
      end
      if when_text ~= "" then
        ret[#ret + 1] = {
          when_text,
          HL.meta,
          virt_text = true,
          virt_text_pos = "right_align",
        }
      end
      return ret
    end,
    finder = finder,
    actions = {
      ---Open the selected session.
      ade_open = function(_, item)
        if busy or not item then
          return
        end
        -- The app closes the window when a load really starts: a missing
        -- directory, a pinned cwd or a cancelled agent switch keeps it open.
        vim.schedule(function()
          state.on_open(item.session)
        end)
      end,

      ---Delete the selected session, keeping the picker open.
      ade_delete = function(p, item)
        if busy or not item then
          return
        end
        local entry = item.session
        if type(state.can_delete) == "function" and not state.can_delete(entry) then
          vim.notify("ade.nvim: this agent cannot delete sessions", vim.log.levels.WARN)
          return
        end
        busy = true
        enter_modal()
        vim.ui.select({ "Delete", "Cancel" }, {
          prompt = string.format('Delete "%s"?', model.label_of(entry)),
          kind = "ade_confirm_delete",
        }, function(choice)
          vim.schedule(function()
            busy = false
            leave_modal()
            if choice ~= "Delete" or p.closed then
              return
            end
            if type(state.on_delete) ~= "function" then
              return
            end
            state.on_delete(entry, function(ok)
              if not ok or p.closed then
                return
              end
              p:refresh()
            end)
          end)
        end)
      end,

      ---Cycle the scope (here -> agent -> all -> here).
      ade_scope = function(p)
        if busy then
          return
        end
        if type(state.on_cycle_scope) == "function" then
          state.on_cycle_scope()
        end
        if not p.closed then
          p:refresh()
        end
      end,

      ---Cycle the agent filter of the `all` scope.
      ade_agent = function(p)
        if busy or state.scope ~= "all" then
          return
        end
        local agents = state.agents or {}
        if #agents == 0 then
          return
        end
        local index = 0
        if agent_filter then
          for position, agent in ipairs(agents) do
            if agent == agent_filter then
              index = position
              break
            end
          end
        end
        agent_filter = agents[index + 1]
        p:refresh()
      end,

      ---Refresh the current scope.
      ade_refresh = function()
        if busy then
          return
        end
        if type(state.on_refresh) == "function" then
          state.on_refresh()
        end
      end,
    },
    on_close = function()
      if type(state.on_close) == "function" then
        state.on_close()
      end
    end,
    confirm = "ade_open",
    win = {
      input = {
        keys = {
          ["<C-d>"] = { "ade_delete", mode = { "n", "i" }, desc = "Delete session" },
          ["<Tab>"] = { "ade_scope", mode = { "n", "i" }, desc = "Next scope" },
          ["<S-Tab>"] = { "ade_agent", mode = { "n", "i" }, desc = "Agent filter" },
          ["<C-r>"] = { "ade_refresh", mode = { "n", "i" }, desc = "Refresh" },
        },
      },
      list = {
        keys = {
          ["<C-d>"] = { "ade_delete", desc = "Delete session" },
          ["<Tab>"] = { "ade_scope", desc = "Next scope" },
          ["<S-Tab>"] = { "ade_agent", desc = "Agent filter" },
          ["<C-r>"] = { "ade_refresh", desc = "Refresh" },
        },
      },
    },
  })

  if not picker then
    return nil
  end

  local handle = {}
  ---Keep the picker open while a modal confirmation owns focus.
  function handle:set_busy(value)
    if value == true then
      busy = true
      enter_modal()
    else
      busy = false
      leave_modal()
    end
  end
  function handle:update(next_state)
    if next_state then
      state = next_state
    end
    if picker.closed then
      return
    end
    local title = title_for(state, icon_set)
    if picker.title ~= title then
      picker.title = title
      if picker.opts then
        picker.opts.title = title
      end
      pcall(picker.update_titles, picker)
    end
    pcall(picker.refresh, picker)
  end
  function handle:close()
    if not picker.closed then
      picker:close()
    end
  end
  function handle:is_open()
    return picker ~= nil and not picker.closed
  end
  function handle:agent_filter()
    return agent_filter
  end
  handle.picker = picker
  return handle
end

return M
