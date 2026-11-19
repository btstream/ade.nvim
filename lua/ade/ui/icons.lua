-- Icon set. Nerd Font glyphs by default, with an ASCII fallback.
--
-- Nerd Font is assumed unless `ui.icons = false`. Every glyph below lives in
-- the Nerd Fonts Nerd Fonts-patched range, so no extra plugin is required.
local M = {}

-- These surfaces already used Unicode even with the ASCII icon set. Keep
-- their existing defaults while making the glyphs individually replaceable.
local glyphs = {
  agent_error = "✗",
  agent_installed = "✓",
  agent_system = "●",
  agent_missing = "○",
  agent_update = "→",
  agent_warning = "⚠",
  team_working = "●",
  team_idle = "○",
  team_waiting = "?",
  team_exited = "✕",
  team_paused = "⏸",
  team_mail = "✉",
  team_activity = "↳",
  team_send = "→",
  team_leader = "★",
  team_worker = "◆",
  team_pending = "◇",
  team_approval = "⚑",
  choice_checked = "☒",
  choice_unchecked = "☐",
  choice_cursor = "❯",
  review_accepted = "✓",
  review_rejected = "✗",
  review_pending = "▎",
  review_result = "→",
  turn_dot = "●",
  history_load = "↑",
  team_collapse = "▾",
  team_hint_left = "‹",
  team_hint_right = "›",
  choice_text_checked = "[x]",
  choice_text_unchecked = "[ ]",
  team_question = "?",
  review_original = "A",
  review_proposal = "B",
  tool_caret = "›",
}

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_ascii = { "|", "/", "-", "\\" }

local function configured()
  local cfg = require("ade.config").current
  return cfg and cfg.ui.icon_overrides
end

function M.override(overrides, key)
  overrides = overrides or configured()
  if type(overrides) == "table" then
    return overrides[key]
  end
end

function M.glyph(key, fallback)
  local overrides = configured()
  local value = overrides and overrides[key]
  if value == false then
    return ""
  end
  return value or fallback or glyphs[key]
end

function M.frames(use_icons, overrides)
  local frames = M.override(overrides, "spinner_frames")
  if frames ~= nil then
    return frames
  end
  return use_icons == false and spinner_ascii or spinner
end

---Nerd Font glyphs (default).
---@return table<string, string>
function M.nerd()
  return {
    tool = "󰒓", -- cog
    tool_ok = "󰄬", -- check
    tool_fail = "󰅖", -- close
    tool_run = "󰝱", -- loading
    tool_pending = "󰝦", -- circle-outline
    user = "󰀄", -- account
    assistant = "󰚩", -- robot
    thought = "󰟷", -- brain
    plan = "󰉹", -- format-list
    notice = "󰋼", -- information
    compaction = "󰏘", -- compress
    child = "󱍔", -- subdirectory
    more = "󰇘", -- dots-horizontal
    chevron_down = "󰅀", -- chevron-down
    chevron_right = "󰅂", -- chevron-right
    arrow_down = "󰁅", -- arrow-down
    trash = "󰩹", -- trash
    session = "󰈔", -- message-text
    model = "󰍣", -- chip
    mode = "󰣢", -- tune
    file = "󰈔", -- file
    error = "󰅙", -- alert-circle
    warning = "󰀪", -- alert
    check_circle = "󰗠", -- check-circle
    spinner = "󰝱", -- loading
    ellipsis = "󰇘", -- dots-horizontal
    cursor = "󰜠", -- cursor-default
    close = "󰅖", -- close
    plus = "󰐕", -- plus
    history = "󰋚", -- history
    arrow_right = "󰁔", -- arrow-right
    -- Toolbar: mode and status are shown as glyphs rather than words.
    mode_plan = "󰫽", -- format-list-bulleted (same family as `plan`)
    mode_build = "󰫯", -- cog
    status_idle = "󰝦", -- circle-outline
    status_waiting = "󰀪", -- alert
    status_cancelling = "󰅖", -- close
  }
end

---Plain ASCII fallback for terminals without a patched font.
---@return table<string, string>
function M.ascii()
  return {
    tool = "*",
    tool_ok = "v",
    tool_fail = "x",
    tool_run = "o",
    tool_pending = ".",
    user = ">",
    assistant = "#",
    thought = "+",
    plan = "*",
    notice = "!",
    compaction = "=",
    child = ">",
    more = "...",
    chevron_down = "v",
    chevron_right = ">",
    arrow_down = "v",
    trash = "x",
    session = "=",
    model = "M",
    mode = "T",
    file = "f",
    error = "E",
    warning = "W",
    check_circle = "v",
    spinner = "*",
    ellipsis = "...",
    cursor = ">",
    close = "x",
    plus = "+",
    history = "H",
    arrow_right = ">",
    -- Toolbar fallbacks: short letters, since ASCII has no glyphs for these.
    mode_plan = "P",
    mode_build = "B",
    status_idle = "o",
    status_waiting = "!",
    status_cancelling = "x",
  }
end

-- The sets are immutable from the callers' point of view (they only read), so
-- build each one once. `get()` runs on every winbar redraw, where allocating a
-- fresh 30-key table each time is pure churn.
local nerd_set = nil
local ascii_set = nil
local resolved = setmetatable({}, { __mode = "k" })

---Resolve the active icon set.
---@param use_icons boolean|nil
---@return table<string, string>
function M.get(use_icons, overrides)
  local base
  if use_icons == false then
    ascii_set = ascii_set or M.ascii()
    base = ascii_set
  else
    nerd_set = nerd_set or M.nerd()
    base = nerd_set
  end
  overrides = overrides or configured()
  if not overrides or next(overrides) == nil then
    return base
  end
  local cache = resolved[overrides] or {}
  resolved[overrides] = cache
  if not cache[base] then
    local set = {}
    for key, default in pairs(base) do
      local value = overrides[key]
      set[key] = value == false and "" or (value or default)
    end
    cache[base] = set
  end
  return cache[base]
end

---The protocol value is case-sensitive; never use the display label as a custom key.
---Return nil if there is no icon, so callers can fall back to the mode name.
function M.mode_icon(label, id, icons, overrides, agent, profile)
  local modes = M.override(overrides, "modes")
  local by_agent = modes and modes[agent]
  local by_profile = modes and modes[profile]
  local value = by_agent and by_agent[id]
  if value == nil then
    value = by_profile and by_profile[id]
  end
  if value == nil then
    local function builtin(key)
      key = type(key) == "string" and key:lower() or nil
      return key == "plan" and "mode_plan" or key == "build" and "mode_build" or nil
    end
    local key = builtin(id) or builtin(label)
    value = key and icons[key]
  end
  return type(value) == "string" and value ~= "" and value or nil
end

return M
