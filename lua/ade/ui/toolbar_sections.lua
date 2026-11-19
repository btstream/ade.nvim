-- Compose plain display cells first; emit statusline markup only after fitting.
local M = {}
local dw = vim.api.nvim_strwidth

local components = {
  mode = function(t, info, ic)
    if info.mode and info.mode ~= "" then
      return t.mode_text(info.mode, ic, info.mode_key, info.icon_overrides, info.agent, info.profile),
        t.mode_hl(info.mode, info.mode_key, info.mode_plan),
        "AdePickMode"
    end
  end,
  model = function(_, info)
    return info.model, "AdeToolbarAccent", "AdePickModel"
  end,
  thinking = function(_, info)
    return info.thinking, "AdeMuted", "AdePickThinking"
  end,
  status = function(t, info, ic)
    local status = info.waiting and "waiting" or info.status
    if status ~= "waiting" and status ~= "running" and status ~= "cancelling" then
      status = "idle"
    end
    return t.status_text(status, ic, info.spinner, info.icon_overrides),
      "AdeToolbar" .. status:sub(1, 1):upper() .. status:sub(2)
  end,
  queue = function(_, info)
    if info.queued and info.queued > 0 then
      return string.format("+%d queued", info.queued), "AdeMuted"
    end
  end,
  context = function(_, info)
    local usage = info.usage
    if usage and usage.size and usage.size > 0 then
      return "Context " .. math.floor((usage.used or 0) / usage.size * 100 + 0.5) .. "%", "AdeMuted"
    end
  end,
  cost = function(_, info)
    local cost = info.usage and info.usage.cost
    if type(cost) == "table" and type(cost.amount) == "number" and cost.amount > 0 then
      local text = string.format(cost.amount < 0.0001 and "%.2e" or "%.4f", cost.amount)
      return text .. (cost.currency and cost.currency ~= "" and (" " .. cost.currency) or ""), "AdeMuted"
    end
  end,
  attachments = function(_, info)
    local labels = {}
    for _, label in ipairs(info.chips or {}) do
      if label ~= "" then
        labels[#labels + 1] = "[" .. label .. "]"
      end
    end
    return table.concat(labels, " "), "AdeUserChip"
  end,
}
M.components = components

local priorities = { status = 100, mode = 90, model = 80, thinking = 60, queue = 50, attachments = 20 }

local function plain(value)
  return (type(value) == "string" or type(value) == "number") and tostring(value):gsub("%c", " ") or ""
end

-- User callbacks run during redraw; a callback error must not break the bar.
local function call(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok then
    return value
  end
end

local function prepare(section, toolbar, info, ic)
  local out = {}
  for _, entry in ipairs(section) do
    local spec = type(entry) == "table" and entry or { entry }
    local key = spec[1]
    if not spec.cond or call(spec.cond, info) then
      local text, color, action
      if type(key) == "function" then
        text = call(key, info)
      else
        text, color, action = components[key](toolbar, info, ic)
      end
      if spec.fmt and plain(text) ~= "" then
        text = call(spec.fmt, text, info)
      end
      text = plain(text)
      if spec.max_width then
        text = toolbar.truncate(text, spec.max_width)
      end
      if text ~= "" then
        local sep = spec.separator
        local edges = type(sep) == "table" and sep.text == nil
        local padding = spec.padding or (key == "mode" and 1 or 0)
        local seg = {
          text = text,
          color = spec.color or color,
          action = action,
          right = sep,
          cap = edges,
          pad_left = type(padding) == "table" and (padding.left or 0) or padding,
          pad_right = type(padding) == "table" and (padding.right or 0) or padding,
          priority = spec.priority or priorities[key] or 40,
        }
        if edges then
          seg.left, seg.right = sep.left, sep.right
        end
        out[#out + 1] = seg
      end
    end
  end
  return out
end

local function between(before, after, default)
  if before.right ~= nil then
    return before.right, before.color
  elseif after.left ~= nil then
    return after.left, after.color
  end
  return default, before.color
end

local function walk(section, default, add_separator, add_component)
  for i, seg in ipairs(section) do
    if i == 1 then
      add_separator(seg.left, seg.color)
    else
      add_separator(between(section[i - 1], seg, default))
    end
    add_component(seg)
  end
  local last = section[#section]
  if last and last.cap then
    add_separator(last.right, last.color)
  end
end

local function sep_text(sep)
  return plain(type(sep) == "table" and sep.text or sep)
end

function M.render(toolbar, info, width, ic, config, defaults, clickable, hl)
  local layout = config.sections or {}
  local sep = config.component_separator
  if sep == nil then
    sep = defaults.component_separator
  end
  local left = prepare(layout.left or defaults.sections.left, toolbar, info, ic)
  local right = prepare(layout.right or defaults.sections.right, toolbar, info, ic)
  local right_padding = config.right_padding or 0
  local function measure(section)
    local cells = 0
    walk(section, sep, function(value)
      cells = cells + dw(sep_text(value))
    end, function(seg)
      cells = cells + dw(seg.text) + seg.pad_left + seg.pad_right
    end)
    return cells
  end
  while true do
    local excess = measure(left) + measure(right) + (#left > 0 and #right > 0 and 1 or 0) - width
    if excess <= 0 then
      break
    end
    local section, index, lowest
    for _, list in ipairs({ left, right }) do
      for i, seg in ipairs(list) do
        if not lowest or seg.priority <= lowest.priority then
          section, index, lowest = list, i, seg
        end
      end
    end
    if not lowest then
      break
    end
    local clipped = toolbar.truncate(lowest.text, dw(lowest.text) - excess)
    if clipped ~= "" and dw(clipped) < dw(lowest.text) then
      lowest.text = clipped
    else
      table.remove(section, index)
    end
  end
  local function render(section)
    local parts = {}
    walk(section, sep, function(value, color)
      local text = sep_text(value)
      if text ~= "" then
        parts[#parts + 1] = hl(text, (type(value) == "table" and value.hl) or color)
      end
    end, function(seg)
      local text = string.rep(" ", seg.pad_left) .. seg.text .. string.rep(" ", seg.pad_right)
      parts[#parts + 1] = clickable(text, seg.color, seg.action)
    end)
    return table.concat(parts)
  end
  -- Keep the trailing inset only when it fits without hiding a component.
  local inset = #right > 0
      and math.min(right_padding, math.max(0, width - measure(left) - measure(right) - (#left > 0 and 1 or 0)))
    or 0
  return "%#AdeToolbar#" .. render(left) .. (#right > 0 and "%=" or "") .. render(right) .. string.rep(" ", inset)
end

return M
