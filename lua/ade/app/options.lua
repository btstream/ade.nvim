-- Session control pickers: mode, model, thinking level and extra options.
--
-- Every choice is driven by `session.controls` (session/controls.lua), so the
-- picker never has to guess which agent reported what. Changing a control uses
-- the method that produced it: `session/set_mode` for legacy `modes`, and
-- `session/set_config_option` for config options.
local presenter = require("ade.app.presenter")
local controls_mod = require("ade.session.controls")
local Icons = require("ade.ui.icons")

local Options = {}
Options.__index = Options

---@param opts {config: fun(): table, current: fun(): AdeSessionState|nil,
---  client: fun(): table|nil, generation: fun(): integer,
---  ui_current: fun(client: table|nil, generation: integer, session: AdeSessionState|nil): boolean,
---  run: fun(key: string, client: table|nil, session: AdeSessionState|nil, fn: fun(task: table)),
---  on_changed: fun(), notify: fun(message: string, level: integer|nil)}
function Options.new(opts)
  return setmetatable({
    config = opts.config,
    current = opts.current,
    get_client = opts.client,
    generation = opts.generation,
    ui_current = opts.ui_current,
    run = opts.run,
    on_changed = opts.on_changed,
    notify = opts.notify,
    changes = setmetatable({}, { __mode = "k" }),
  }, Options)
end

---Whether a captured session is still the right target for a write.
---@param client table|nil
---@param generation integer
---@param session table
---@return boolean
function Options:still_current(client, generation, session)
  return self.ui_current(client, generation, session) and self.current() == session
end

---Whether the connection context of a captured write is still valid.
---
---Unlike `still_current` this ignores which chat is on screen: a write the
---person asked for through a command (`:Ade team start`) targets a session, not
---the UI selection, so switching chats meanwhile must not drop it.
---@param client table|nil
---@param generation integer
---@return boolean
function Options:context_current(client, generation)
  return self.ui_current(client, generation, nil)
end

-- ACP replies can replace all configOptions; serialize writes per session so
-- an older snapshot can never arrive after a newer write.
function Options:apply(control, value, client, generation, session, cycling)
  if not client or not self:still_current(client, generation, session) then
    return
  end
  local queue = self.changes[session]
  if not queue then
    queue = { pending = {} }
    self.changes[session] = queue
  end
  if cycling and queue.cycling then
    return
  end
  if cycling then
    queue.cycling = true
  end
  queue.pending[#queue.pending + 1] = {
    id = control.id,
    value = value,
    client = client,
    generation = generation,
    cycling = cycling,
  }
  self:drain(session, queue)
end

---Set a control on an explicit session, independent of the UI selection.
---
---Used by flows that act on a chosen session (a team start on the tree's row).
---The write still fences on the client/generation it was issued for, and the
---outcome is reported through `cb` so the caller can say what really happened.
---@param control table
---@param value any
---@param client table|nil
---@param generation integer
---@param session table
---@param cb fun(ok: boolean, err: any)|nil
---@return boolean queued
function Options:set_for(control, value, client, generation, session, cb)
  if not client or not session or not self:context_current(client, generation) then
    if cb then
      pcall(cb, false, "the session is no longer available")
    end
    return false
  end
  local queue = self.changes[session]
  if not queue then
    queue = { pending = {} }
    self.changes[session] = queue
  end
  queue.pending[#queue.pending + 1] = {
    id = control.id,
    value = value,
    client = client,
    generation = generation,
    unattended = true,
    cb = cb,
  }
  self:drain(session, queue)
  return true
end

function Options:drain(session, queue)
  if queue.active then
    return
  end
  while #queue.pending > 0 do
    local change = table.remove(queue.pending, 1)
    local valid = change.unattended and self:context_current(change.client, change.generation)
      or self:still_current(change.client, change.generation, session)
    local control = valid and session.controls and controls_mod.by_id(session.controls, change.id)
    local value
    if control then
      value = change.value
      if type(value) == "function" then
        value = value(control)
      end
      -- A prior change (e.g. model) may have removed this option.
      if
        control.kind == "select"
        and not vim.iter(control.options or {}):any(function(entry)
          return entry.value == value
        end)
      then
        value = nil
      end
    end
    if control and value ~= nil then
      queue.active = true
      self:write(control, value, change, session, function()
        queue.active = false
        if change.cycling then
          queue.cycling = nil
        end
        self:drain(session, queue)
      end)
      return
    end
    if change.cycling then
      queue.cycling = nil
    end
    if change.cb then
      pcall(change.cb, false, control and "the agent no longer offers that value" or "the session is gone")
    end
  end
  self.changes[session] = nil
end

function Options:write(control, value, change, session, on_finally)
  -- A queued write can be cancelled by a reload of the same session or by a
  -- reconnect; the scoped task then ends without `on_error`, so the caller must
  -- still be settled here (`on_finally` runs for every ending).
  local settled = false
  local function settle(ok, err)
    if settled then
      return
    end
    settled = true
    if change.cb then
      pcall(change.cb, ok, err)
    end
  end
  self.run("control:" .. session.id, change.client, session, function(task)
    local ok, result
    if control.source == "modes" then
      ok, result = task:call("set_mode", session.id, value)
    else
      ok, result = task:call("set_config_option", session.id, control.id, value)
    end
    if not ok then
      task.status = "failed"
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      settle(false, message)
      self.notify("unable to change " .. (control.name or control.id) .. ": " .. message, vim.log.levels.ERROR)
      return
    end
    if control.source == "modes" then
      session.current_mode = value
      session:refresh_controls()
    elseif result and type(result) == "table" and result.configOptions then
      session:configure(result)
    else
      -- The agent acknowledged without a new option list. Record the value on
      -- the option itself: controls are derived from it on every refresh, so
      -- writing only `control.current` would be overwritten immediately.
      control.current = value
      if control.option then
        control.option.currentValue = value
      end
      session:refresh_controls()
    end
    session._toolbar_labels = nil
    self.on_changed()
    settle(true, nil)
  end, function(err)
    settle(false, err)
    self.notify("unable to change " .. (control.name or control.id) .. ": " .. tostring(err), vim.log.levels.ERROR)
  end, function()
    -- Cancelled (reload/reconnect) or superseded: no error callback fires, so
    -- report the failure here rather than leaving the caller waiting. The
    -- queue continuation still runs for every ending.
    settle(false, "the change was cancelled")
    if on_finally then
      on_finally()
    end
  end)
end

---Toggle a boolean control.
---@param control table
---@param client table|nil
---@param generation integer
---@param session table
function Options:toggle(control, client, generation, session)
  if control.source == "modes" then
    -- A boolean never comes from `modes`; guard anyway.
    return
  end
  self:apply(control, function(latest)
    return not latest.current
  end, client, generation, session)
end

---Picker title for a control: avoid repeating the same name twice.
---@param control table
---@param title string|nil
---@return string
local function picker_title(control, title)
  local name = control.name or control.id
  if not title or title == "" or title == name then
    return name
  end
  return title .. " · " .. name
end

local function model_group(control, entry)
  local name = entry.name or tostring(entry.value)
  local prefix, short = name:match("^([^/]+)/(.+)$")
  local group = control.option_groups and control.option_groups[entry]
  local id = group and group.group or (type(entry.value) == "string" and entry.value:match("^([^/]+)/.+$")) or prefix
  local display = group and group.name or nil
  local label = display or (prefix and id and prefix:lower() == id:lower() and prefix) or id
  if prefix and id and (prefix:lower() == id:lower() or (display and prefix:lower() == display:lower())) then
    name = short
  end
  return id, label, name, display ~= nil
end

---Picker for a select control.
---@param control table
---@param title string|nil
---@param client table|nil
---@param generation integer
---@param session table
function Options:pick_control(control, title, client, generation, session)
  local cfg = self.config()
  local ic = Icons.get(cfg.ui.icons, cfg.ui.icon_overrides)
  local items = {}
  local is_model = session.controls and control == session.controls.model
  local groups, order, ungrouped = {}, {}, {}
  for _, entry in ipairs(control.options or {}) do
    local marked = entry.value == control.current and ic.check_circle or ic.tool_pending
    local name = entry.name or tostring(entry.value)
    local mode_icon
    if session.controls and control == session.controls.mode then
      mode_icon = Icons.mode_icon(
        name,
        entry.value,
        ic,
        cfg.ui.icon_overrides,
        session.agent_name or cfg.agent,
        session.profile and session.profile.name
      )
    end
    local bucket = items
    if is_model then
      local id, label, explicit
      id, label, name, explicit = model_group(control, entry)
      if id then
        local key = id:lower()
        if not groups[key] then
          groups[key] = { name = label, items = {} }
          order[#order + 1] = groups[key]
        end
        if explicit then
          groups[key].name = label
        end
        bucket = groups[key].items
      else
        bucket = ungrouped
      end
    end
    bucket[#bucket + 1] = {
      label = (marked ~= "" and marked .. " " or "") .. (mode_icon and mode_icon .. " " or "") .. name,
      description = entry.description,
      value = entry.value,
    }
  end
  if is_model then
    for _, group in ipairs(order) do
      for _, item in ipairs(group.items) do
        item.label = group.name .. " / " .. item.label
        items[#items + 1] = item
      end
    end
    for _, item in ipairs(ungrouped) do
      if #order > 0 then
        item.label = "Other / " .. item.label
      end
      items[#items + 1] = item
    end
  end
  if #items == 0 then
    self.notify("this option has no values", vim.log.levels.INFO)
    return
  end
  presenter.select({
    title = picker_title(control, title),
    items = items,
    on_choice = function(value)
      self:apply(control, value, client, generation, session)
    end,
  })
end

---Select by control key ("mode" | "model" | "thinking") or control id.
---@param key string
---@param title string
function Options:pick(key, title)
  local session = self.current()
  if not session then
    return
  end
  if not session.controls then
    session:refresh_controls()
  end
  local client, generation = self.get_client(), self.generation()
  local control = session.controls[key]
  if not control then
    control = controls_mod.by_id(session.controls, key)
  end
  if not control then
    self.notify("this agent does not offer " .. key .. " selection", vim.log.levels.INFO)
    return
  end
  if control.kind == "boolean" then
    self:toggle(control, client, generation, session)
    return
  end
  self:pick_control(control, title, client, generation, session)
end

function Options:pick_model()
  self:pick("model", "Model")
end

function Options:pick_mode()
  self:pick("mode", "Mode")
end

function Options:cycle_mode()
  local session, client = self.current(), self.get_client()
  if not session or not client then
    return
  end
  if not session.controls then
    session:refresh_controls()
  end
  local mode = session.controls.mode
  if not mode or mode.kind ~= "select" then
    return
  end
  self:apply(mode, function(latest)
    local values = latest.options or {}
    if #values < 2 then
      return
    end
    local index = 0
    for i, entry in ipairs(values) do
      if entry.value == latest.current then
        index = i
        break
      end
    end
    for step = 1, #values do
      local entry = values[(index + step - 1) % #values + 1]
      local full_access = type(entry._meta) == "table" and entry._meta.kind == "full_access"
      if entry.value ~= latest.current and entry.value ~= "bypassPermissions" and not full_access then
        return entry.value
      end
    end
  end, client, self.generation(), session, true)
end

function Options:pick_thinking()
  self:pick("thinking", "Thinking")
end

---One picker for every control the agent offers.
function Options:pick_config()
  local session = self.current()
  if not session then
    return
  end
  if not session.controls then
    session:refresh_controls()
  end
  local client, generation = self.get_client(), self.generation()
  local items = {}
  for _, key in ipairs({ "mode", "model", "thinking" }) do
    local control = session.controls[key]
    if control then
      items[#items + 1] = {
        label = string.format("%s: %s", control.name or control.id, controls_mod.label(control) or "?"),
        description = control.description,
        value = { control = control, title = control.name },
      }
    end
  end
  for _, control in ipairs(session.controls.extras or {}) do
    items[#items + 1] = {
      label = string.format("%s: %s", control.name or control.id, controls_mod.label(control) or "?"),
      description = control.description,
      value = { control = control, title = control.name },
    }
  end
  if #items == 0 then
    self.notify("this agent offers no session options", vim.log.levels.INFO)
    return
  end
  presenter.select({
    title = "Configure",
    items = items,
    on_choice = function(choice)
      if not self:still_current(client, generation, session) then
        return
      end
      if choice.control.kind == "boolean" then
        self:toggle(choice.control, client, generation, session)
      else
        self:pick_control(choice.control, choice.title, client, generation, session)
      end
    end,
  })
end

return Options
