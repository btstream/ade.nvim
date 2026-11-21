-- Winbar/statusline rendering.
--
-- Two rules keep this robust across resizes and layout managers:
--
--  * Alignment is delegated to Vim via `%=`. We never pad by hand, so a stale
--    width can never make the string wider than the window.
--  * Text is truncated to the measured budget before markers are added, so
--    escape sequences never get cut in half.

local Icons = require("ade.ui.icons")

local M = {}

---Neovim 0.12 adds inheriting statusline highlights. Older releases only
---understand %#group#; their window-local WinBar mapping supplies the surface.
---@param group string
---@return string
function M.highlight(group)
  if vim.fn.has("nvim-0.12") == 1 then
    return "%$" .. group .. "$"
  end
  return "%#" .. group .. "#"
end

---Escape agent supplied text for use inside a winbar.
---@param s string
---@return string
function M.escape(s)
  return (tostring(s):gsub("%%", "%%%%"))
end

local function dw(s)
  return vim.api.nvim_strwidth(s)
end

---Byte offsets where each UTF-8 codepoint starts (1-based, plus #s+1).
---LuaJIT has no `utf8` library, so this walks continuation bytes directly.
---@param s string
---@return integer[]
local function char_starts(s)
  local starts = { 1 }
  local i = 1
  local len = #s
  while i <= len do
    local byte = s:byte(i)
    local width = 1
    if byte >= 0xF0 then
      width = 4
    elseif byte >= 0xE0 then
      width = 3
    elseif byte >= 0xC0 then
      width = 2
    end
    i = i + width
    starts[#starts + 1] = i
  end
  return starts
end

---Truncate to a display width, appending an ellipsis when shortened.
---@param s string
---@param max integer
---@return string
function M.truncate(s, max)
  if max <= 0 then
    return ""
  end
  if dw(s) <= max then
    return s
  end
  local ellipsis = "…"
  local ellipsis_width = dw(ellipsis)
  if max <= 1 or max < ellipsis_width then
    return ""
  end
  -- Display width grows monotonically with the prefix, so binary search finds
  -- the longest fitting prefix in O(log n) width measurements instead of one
  -- per character (this runs on every winbar redraw).
  local starts = char_starts(s)
  local lo, hi = 1, #starts - 1 -- number of codepoints to keep
  local best = 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if dw(s:sub(1, starts[mid + 1] - 1)) <= max - ellipsis_width then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return s:sub(1, starts[best + 1] - 1) .. ellipsis
end

---Wrap text in a highlight group.
---
---Uses `%$name$` rather than `%#name#`: `$` inherits the attributes already in
---effect (notably the background) instead of restarting from `WinBar`. That
---matters because a layout manager may remap `WinBar` to its own group, which
---would otherwise repaint every region that only sets a foreground.
---@param text string
---@param hl string|nil
---@return string
local function hl(text, hl_group)
  local escaped = M.escape(text)
  if not hl_group then
    return escaped
  end
  return M.highlight(hl_group) .. escaped .. M.highlight("AdeToolbar")
end

---Render a clickable region.
---@param text string
---@param hl_group string|nil
---@param action string|nil global function name, e.g. "AdePickModel"
---@return string
local function clickable(text, hl_group, action)
  local body = hl(text, hl_group)
  if action then
    -- `%T` terminates the clickable region; any text between it and the next
    -- `%T` is rendered, so no tooltip text may be added here.
    body = "%@v:lua." .. action .. "@" .. body .. "%T"
  end
  return body
end

---Candidate strings to test, most specific first.
---@param mode string|nil
---@param key string|nil
---@return string[]
local function mode_candidates(mode, key)
  local out = {}
  if type(key) == "string" and key ~= "" then
    out[#out + 1] = key
  end
  if type(mode) == "string" and mode ~= "" then
    out[#out + 1] = mode
  end
  return out
end

---Text for the mode region: a glyph for known modes, the raw label otherwise.
---
---Use the mode name when no icon is defined or an override disables it.
---@param mode string display label
---@param ic table<string, string>
---@param key string|nil value id, preferred for the glyph decision
---@return string
function M.mode_text(mode, ic, key, overrides, agent, profile)
  return Icons.mode_icon(mode, key, ic, overrides, agent, profile) or mode
end

---Highlight group for the mode region, so plan and build read differently.
---@param mode string display label
---@param key string|nil value id, preferred for the style decision
---@param plan boolean|nil the agent's own semantic kind, when it reported one
---@return string
function M.mode_hl(mode, key, plan, mode_highlights, agent, profile)
  if mode_highlights and key then
    local by_agent, by_profile = mode_highlights[agent], mode_highlights[profile]
    local group = (by_agent and by_agent[key]) or (by_profile and by_profile[key])
    if group then
      return group
    end
  end
  if plan then
    return "AdeToolbarModePlan"
  end
  for _, candidate in ipairs(mode_candidates(mode, key)) do
    local lower = candidate:lower()
    if lower == "plan" or lower == "architect" then
      return "AdeToolbarModePlan"
    elseif lower == "build" then
      return "AdeToolbarModeBuild"
    end
  end
  return "AdeToolbarAccent"
end

---Text for the status region.
---
---`running` shows the animation frame instead of a static glyph so the toolbar
---still reads as "busy"; every other state is a single glyph.
---@param status "waiting"|"running"|"cancelling"|"idle"
---@param ic table<string, string>
---@param spinner string|nil
---@return string
function M.status_text(status, ic, spinner, overrides)
  if status == "running" then
    local static = Icons.override(overrides, "status_running")
    if static == false then
      return ""
    end
    return spinner or static or ic.tool_run
  end
  local key = "status_" .. status
  return ic[key] or ic.tool_pending
end

---Build the composer toolbar.
---@param info {mode: string|nil, mode_key: string|nil, mode_plan: boolean|nil, model: string|nil, thinking: string|nil, status: string, waiting: boolean|nil, queued: integer|nil, usage: table|nil, spinner: string|nil, show_usage: boolean|nil, chips: string[]|nil}
---@param width integer available cells (the whole window width)
---@return string
function M.render(info, width)
  local ic = Icons.get(info.icons, info.icon_overrides)
  local defaults = require("ade.config").defaults.ui.toolbar
  return require("ade.ui.toolbar_sections").render(
    M,
    info,
    width,
    ic,
    info.toolbar or defaults,
    defaults,
    clickable,
    hl
  )
end

---Build the transcript window title.
---@param opts {agent: string, profile: string|nil, title: string|nil, pending_new: boolean|nil, icons: boolean|nil, icon_overrides: table|nil}
---@param width integer
---@return string
function M.chat_title(opts, width)
  local base = "%#AdeNormal#"
  if width <= 2 then
    return base .. string.rep(" ", math.max(0, width))
  end
  width = width - 2 -- One inset cell at each edge.

  local title = opts.title
  if not title or title == "" then
    title = "No session"
  end
  local icons = Icons.get(opts.icons, opts.icon_overrides)
  local icon = Icons.chat_agent_icon(icons, opts.icon_overrides, opts.agent, opts.profile)
  local prefix = icon ~= "" and (icon .. " ") or ""
  local agent = opts.agent

  -- Leave a gap between the two sides. When both labels are long, give each
  -- room to truncate; a short session title can yield its unused space.
  local title_width = dw(title)
  local left_budget = width >= 5 and math.max(math.floor((width - 1) / 2), width - 1 - title_width) or width
  local agent_width = dw(agent)
  local prefix_width = dw(prefix)
  if agent_width + prefix_width > left_budget and (agent_width <= left_budget or left_budget - prefix_width < 3) then
    prefix, prefix_width = "", 0
  end
  agent = prefix .. M.truncate(agent, left_budget - prefix_width)
  local right_budget = width - dw(agent) - (agent ~= "" and 1 or 0)
  local suffix = opts.pending_new and ("  " .. (icons.arrow_down ~= "" and icons.arrow_down .. " " or "") .. "new")
    or ""
  if right_budget < dw(suffix) + math.min(title_width, 2) then
    suffix = ""
  end
  title = M.truncate(title, right_budget - dw(suffix))

  -- The title bar sits on the transcript's own background, not the statusline
  -- colour: it is the transcript's header, not a separate strip. `AdeNormal`
  -- opens that background and every region inherits it with `%$...$`, so a
  -- layout manager remapping `WinBar` cannot repaint any of them.
  local left = agent ~= "" and (M.highlight("AdeChatAgentName") .. M.escape(agent) .. base) or ""
  local right = title ~= "" and (M.highlight("AdeChatSessionName") .. M.escape(title) .. base) or ""
  if right ~= "" and suffix ~= "" then
    right = right .. M.highlight("AdeStreaming") .. M.escape(suffix) .. base
  end
  return base .. " " .. left .. "%=" .. right .. " "
end

return M
