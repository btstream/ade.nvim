-- edgy.nvim integration helpers.
--
-- ade.nvim exposes two ordinary views (`ade_chat` and `ade_input`) so that a
-- layout manager can own their position. The team panes (`ade_team_tree`,
-- `ade_team_members`, `ade_team_board`) are ordinary views too. This module
-- builds the recommended edgy view definitions without touching the user's
-- configuration.
local M = {}

---Team pane filetypes and their titles, in dashboard order.
M.TEAM_VIEWS = {
  { name = "tree", ft = "ade_team_tree", title = "Team" },
  { name = "members", ft = "ade_team_members", title = "Members" },
  { name = "board", ft = "ade_team_board", title = "Board" },
}

---@param opts {agent_title?: string, width?: number, input_height?: number, toolbar_winbar?: boolean, title_winbar?: boolean, team?: boolean}|nil
---@return table
function M.views(opts)
  opts = opts or {}
  local toolbar_winbar = opts.toolbar_winbar ~= false
  local title_winbar = opts.title_winbar == true
  local views = {
    chat = {
      ft = "ade_chat",
      title = opts.agent_title or "Agent",
      size = { width = opts.width or require("ade.config").defaults.layout.width },
      wo = {
        -- ade renders a richer title (session name, new-output marker) by
        -- default. Set title_winbar = true to let edgy own it instead.
        winbar = title_winbar,
        winfixwidth = true,
      },
    },
    input = {
      ft = "ade_input",
      title = "Message",
      size = { height = opts.input_height or require("ade.config").defaults.layout.input_height },
      wo = {
        winbar = not toolbar_winbar,
        winfixwidth = true,
        winfixheight = true,
      },
    },
  }
  if opts.team ~= false then
    local panes = require("ade.config").defaults.teams.layout.panes
    for _, team in ipairs(M.TEAM_VIEWS) do
      local pane = panes[team.name] or {}
      views[team.name] = {
        ft = team.ft,
        title = team.title,
        -- The board has no configured size: it takes what the edgebar gives it.
        size = pane.size and { width = pane.size } or nil,
        wo = {
          -- ade owns the pane winbar (team, workers, turns).
          winbar = false,
          winfixwidth = pane.size ~= nil,
        },
      }
    end
  end
  return views
end

---The filetypes registered on every side of an edgy config.
---
---edgy only reads the array parts of `left`/`right`/`top`/`bottom`. A view is
---registered once no matter which side it sits on, so extending must never add
---a second definition for an ft that already appears somewhere else.
---@param edgy_opts table
---@return table<string, boolean>
local function registered(edgy_opts)
  local present = {}
  for _, side in ipairs({ "left", "right", "top", "bottom" }) do
    local views = edgy_opts[side]
    if type(views) == "table" then
      for _, view in ipairs(views) do
        if type(view) == "table" and view.ft then
          present[view.ft] = true
        elseif type(view) == "string" then
          present[view] = true
        end
      end
    end
  end
  return present
end

---Default positions of the team views: the same side as the chat panel.
---@param position string
---@return table<string, string>
local function default_team_positions(position)
  return { tree = position, members = position, board = position }
end

---Append the ADE views to an edgy config in place.
---Use inside a lazy.nvim `opts` function:
---
---   opts = function(_, opts)
---     require("ade.integrations.edgy").extend(opts)
---   end
---
---`view_opts.team` moves the team views per pane:
---
---   extend(opts, { team = { tree = "left", members = "left", board = "bottom" } })
---
---`team = false` leaves them out; the default is the chat panel's position.
---@param edgy_opts table
---@param view_opts table|nil
---@return table
function M.extend(edgy_opts, view_opts)
  edgy_opts = edgy_opts or {}
  -- Honour the configured panel side instead of always using `right`.
  local position = "right"
  local ok, config = pcall(require, "ade.config")
  if ok and config.defaults and config.defaults.layout then
    position = config.defaults.layout.position or "right"
  end
  if view_opts and view_opts.position then
    position = view_opts.position
  end
  edgy_opts[position] = edgy_opts[position] or {}
  local target = edgy_opts[position]
  local views = M.views(view_opts)
  -- Registered means present on any side: a user who put ade_team_tree on
  -- `left` must not get a second tree on `right`.
  local present = registered(edgy_opts)
  if not present["ade_chat"] then
    table.insert(target, 1, views.chat)
    present["ade_chat"] = true
  end
  if not present["ade_input"] then
    -- Never insert past the end: when ade_chat lives on another side the
    -- target list can be empty, and `insert(list, 2, ...)` would create a
    -- sparse table whose array part `ipairs` never sees.
    table.insert(target, math.min(2, #target + 1), views.input)
    present["ade_input"] = true
  end
  local team = view_opts and view_opts.team
  if team ~= false then
    local sides = type(team) == "table" and team or default_team_positions(position)
    for _, view in ipairs(M.TEAM_VIEWS) do
      local side = sides[view.name] or position
      if views[view.name] and side ~= false and not present[view.ft] then
        local list = edgy_opts[side]
        if type(list) ~= "table" then
          list = {}
          edgy_opts[side] = list
        end
        -- Append only: always #list + 1, so the array part stays contiguous
        -- even when the side was created empty.
        table.insert(list, views[view.name])
        present[view.ft] = true
      end
    end
  end
  return edgy_opts
end

---Whether edgy is installed and loaded.
---
---Uses `package.loaded` first so merely checking availability cannot trigger a
---lazy-load of edgy as a side effect.
---@return boolean
function M.available()
  if package.loaded["edgy"] ~= nil then
    return true
  end
  local ok, edgy = pcall(require, "edgy")
  return ok and edgy ~= nil
end

---Whether a view for `ft` is registered with edgy.
---
---edgy only builds a layout for a position when its view list has a non-empty
---array part (`#views > 0`). A config written as `right = { chat = {...} }`
---therefore silently registers nothing, and the panel windows stay where ade
---creates them. Detecting this lets us warn instead of leaving the user with a
---misplaced layout.
---@param ft string
---@return boolean
function M.has_view(ft)
  local ok, config = pcall(require, "edgy.config")
  if not ok or type(config) ~= "table" then
    return false
  end
  for _, position in ipairs({ "left", "right", "bottom", "top" }) do
    local views = config[position]
    if type(views) == "table" then
      for _, view in ipairs(views) do
        if type(view) == "table" and view.ft == ft then
          return true
        end
        if view == ft then
          return true
        end
      end
    end
  end
  return false
end

---Warn when edgy is the layout backend but the ADE views are not registered.
---
---Registers a single delayed check so the warning appears at most once per
---session, and only when the user actually opened the panel.
function M.check_registered()
  M.check_views({ "ade_chat", "ade_input" }, "chat", "_checked")
end

---Warn when edgy is the layout backend but the team pane views are not
---registered. Called the first time a team pane opens in external mode.
function M.check_team_registered()
  local fts = {}
  for _, view in ipairs(M.TEAM_VIEWS) do
    fts[#fts + 1] = view.ft
  end
  M.check_views(fts, "team", "_team_checked")
end

---Shared once-only registration check.
---@param fts string[]
---@param what string what the views belong to (for the warning)
---@param flag string module field guarding the once-only warning
function M.check_views(fts, what, flag)
  if not M.available() then
    return
  end
  if M[flag] then
    return
  end
  M[flag] = true
  local missing = {}
  for _, ft in ipairs(fts) do
    if not M.has_view(ft) then
      missing[#missing + 1] = ft
    end
  end
  if #missing == 0 then
    return
  end
  vim.schedule(function()
    vim.notify(
      string.format(
        "ade.nvim: %s %s view(s) are not registered with edgy. Add the views as array "
          .. "entries (not as named keys) or call require('ade.integrations.edgy').extend(opts).",
        what,
        table.concat(missing, " and ")
      ),
      vim.log.levels.WARN
    )
  end)
end

return M
