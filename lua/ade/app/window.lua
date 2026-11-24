-- Panel wiring: window events and buffer-local keymaps.
--
-- These run once per `setup`. They only need the state, the config and the
-- controller's public entry points, so they live here instead of in the
-- controller's already-largest function.
local keymaps = require("ade.ui.keymaps")
local drafts = require("ade.storage.drafts")
local last_sessions = require("ade.storage.last_sessions")
local inline = require("ade.inline")

local M = {}

---@param deps {state: fun(): table, config: fun(): table, actions: table,
---  refresh_chrome: fun(), stop_spinner: fun(), sync_spinner: fun(),
---  update_title: fun(), prune_sessions: fun()}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps }, { __index = M })
end

function M:state()
  return self.deps.state()
end

---Whether two session objects are the same logical conversation.
---
---A load or resume replaces the object with a new projection of the same
---`(instance, sessionId)`; leaving that session is not "switching away", so the
---idle-close below must not fire for it (it would close the session the load
---just produced, revoking its fresh token).
---@param a table|nil
---@param b table|nil
---@return boolean
local function same_session(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  if a.id ~= b.id then
    return false
  end
  return a.instance == nil or b.instance == nil or a.instance == b.instance
end

---The instance of the live, ready agent client, or nil.
---@return string|nil
function M:live_instance()
  local S = self:state()
  if S.conn.phase ~= "ready" then
    return nil
  end
  local client = S.conn.client
  return client and client.proc and client.proc.instance or nil
end

---Make `session` the one on screen.
---
---Switching away leaves the previous session active on the agent side. Ask it to
---release the resources, but never while a turn is still in flight: closing a
---running session would kill work the user only meant to leave in the
---background. Agents without `session/close` simply ignore the request.
---@param session table|nil
function M:select_session(session)
  local S = self:state()
  local previous = S.sess.current
  -- A team worker transcript is only a view of a worker session; switching the
  -- real session must never leave the composer pointed at a former target.
  if S.view.team_ui and S.view.team_ui.detach then
    pcall(S.view.team_ui.detach, S.view.team_ui)
  end
  S.sess.current = session
  S.sess.runtime:select(session)
  if session and not session.needs_load and S.conn.client and S.conn.client.created ~= nil then
    local cfg = self.deps.config()
    if cfg.service and cfg.service.restore_on_restart then
      last_sessions.set(cfg.agent, session.cwd, session.id)
    end
  end
  -- An idle close is only safe when the old session belongs to the instance
  -- that is connected right now: a session restored onto a new instance (`same
  -- id`, new owner) or one left behind by a dead instance must never be closed
  -- through the new client, which would release the freshly restored token.
  local live = self:live_instance()
  local owner = type(previous) == "table" and previous.instance or nil
  -- A session that recorded an instance may only be closed while exactly that
  -- instance is the ready client's. A session without an instance id (the
  -- direct backend never has one) is owned by whatever client is live.
  local owned = owner == nil or (live ~= nil and owner == live)
  if
    previous
    and owned
    and not same_session(previous, session)
    and previous.status == "idle"
    and #(previous.queue or {}) == 0
    and S.sess.service
  then
    local protected = S.view.team ~= nil and S.view.team:leads_team(previous)
    if not protected then
      pcall(S.sess.service.close, S.sess.service, previous.id)
    end
  end
  if S.view.chat then
    S.view.chat:set_session(session)
    S.view.chat.pending_new = false
  end
  if S.view.input then
    local drafts = require("ade.storage.drafts")
    local restored = session and drafts.get(session.cwd, session.id) or nil
    S.view.input:switch_session(session and session.id or nil, restored, session)
  end
  self.deps.refresh_chrome()
  self.deps.prune_sessions()
end

---Show the panel, starting the agent when needed.
function M:open()
  local S = self:state()
  if S.view.panel then
    S.view.panel:set_views(S.view.chat, S.view.input)
    S.view.panel:show()
  end
  self.deps.sync_spinner()
  if S.conn.phase == "ready" then
    local current = S.sess.current
    if (not current or current.needs_load) and not S.conn.replaying and not S.conn.creating_session then
      local client, restore = S.conn.client, S.conn.restore
      local restoring = client and client.created == true and restore and restore:after_restart(current)
      if not restoring and not current then
        self.deps.actions.new_session()
      end
    end
    return
  end
  if S.conn.phase == "starting" then
    return
  end
  self.deps.actions.connect()
end

---Hide the panel without stopping the session.
function M:hide()
  local S = self:state()
  if S.view.panel then
    S.view.panel:set_views(S.view.chat, S.view.input)
    S.view.panel:hide()
  end
  self.deps.stop_spinner()
end

function M:toggle()
  local S = self:state()
  if S.view.panel and S.view.panel:is_visible() then
    self:hide()
  else
    self:open()
  end
end

---@param which "input"|"chat"
function M:focus(which)
  local S = self:state()
  if S.view.panel and S.view.panel:focus(which) then
    return
  end
  self:open()
end

function M:install_window_events()
  local S = self:state()
  if not S.view.panel then
    return
  end
  local deps = self.deps
  S.view.panel:install_events({
    on_all_closed = deps.stop_spinner,
    on_resize = deps.refresh_chrome,
    on_leave = function()
      deps.stop_spinner()
      if S.view.input then
        pcall(S.view.input.save_draft, S.view.input)
      end
      pcall(drafts.flush)
      -- Release active sessions before the process goes away.
      if S.sess.service and S.conn.client then
        pcall(function()
          S.sess.service:close_all_on_exit()
        end)
      end
      if S.conn.service then
        -- Do not let a stray agent process outlive the editor.
        S.conn.service:terminate()
      end
    end,
  })
end

function M:install_input_keymaps()
  local S = self:state()
  local actions = self.deps.actions
  local cfg = self.deps.config()
  -- While the composer sends to a team worker, the leader's session is not what
  -- the person is looking at: history, the empty-`<C-s>` stop and `<C-c>` must
  -- not read or cancel `S.sess.current`.
  local function team_target()
    local S = self:state()
    local ui = S.view and S.view.team_ui
    return ui and ui.is_worker_target and ui:is_worker_target() and ui or nil
  end
  local function history(direction)
    if cfg.ui.input_history_limit == 0 then
      return nil
    end
    return function()
      local ui = team_target()
      local session = self:state().sess.current
      local blocks = session and session.blocks
      if ui then
        -- The worker's own display transcript, never the leader's.
        local display = ui.router and ui.router.display
        blocks = display and display.blocks or nil
      end
      return S.view.input:recall(direction, blocks)
    end
  end
  keymaps.attach_input(S.view.input.buf, {
    keymaps = cfg.keymaps.input,
    config = cfg,
    on_history_prev = history(1),
    on_history_next = history(-1),
    get_session = function()
      return self:state().session
    end,
    on_send = function()
      local sessions = self:state()
      -- Ctrl-S submits; when a turn is running and the composer is empty it stops instead.
      -- The stop only ever targets the session the person is looking at.
      local ui = team_target()
      if ui then
        -- A worker has no local turn to cancel. An empty composer still
        -- submits nothing, but it must not cancel the leader's turn.
        if S.view.input:text():match("^%s*$") and #S.view.input.attachments == 0 then
          ui:cancel_target()
          return
        end
        S.view.input:submit()
        return
      end
      local running = sessions.sess.current and sessions.sess.current.status == "running"
      if running and S.view.input:text():match("^%s*$") and #S.view.input.attachments == 0 then
        actions.cancel()
        return
      end
      S.view.input:submit()
    end,
    on_cancel = function()
      local ui = team_target()
      if ui then
        ui:cancel_target()
        return
      end
      actions.cancel()
    end,
    on_hide = actions.hide,
    on_add_selection = actions.add_selection,
    on_pick_model = actions.pick_model,
    on_pick_mode = actions.pick_mode,
    on_cycle_mode = actions.cycle_mode,
    on_pick_thinking = actions.pick_thinking,
    on_pick_file = actions.pick_file,
    on_paste_image = actions.paste_image,
    on_paste_image_path = actions.add_image,
    on_paste_text = function(lines)
      return S.view.input:preview_paste(lines)
    end,
    paste_epoch = function()
      return S.view.input.draft_epoch
    end,
    on_pick_session = actions.pick_session,
    on_focus_choice = function()
      if S.view.choices then
        S.view.choices:focus()
      end
    end,
  })
end

---Find the global mapping for `lhs`, so a replaced map can be restored later.
---@param mode string
---@param lhs string
---@return table|nil
function M.global_map(mode, lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if vim.keycode(map.lhs) == vim.keycode(lhs) then
      return map
    end
  end
end

function M:install_inline_keymaps()
  -- Removing the maps this module installed last time keeps `setup()` idempotent
  -- and restores whatever the user had before.
  local installed_maps = self.inline_maps or {}
  for _, installed in ipairs(installed_maps) do
    local map = M.global_map(installed.mode, installed.lhs)
    if map and map.callback == installed.callback then
      vim.keymap.del(installed.mode, map.lhs)
      if installed.previous then
        vim.fn.mapset(installed.mode, false, installed.previous)
      end
    end
  end
  self.inline_maps = {}
  local spec = self.deps.config().keymaps.inline or {}
  local function install(value, modes)
    for _, entry in ipairs(keymaps.expand(value, modes)) do
      local previous = M.global_map(entry.mode, entry.lhs)
      local callback = function()
        inline.open()
      end
      vim.keymap.set(entry.mode, entry.lhs, callback, { desc = "ade.nvim: inline prompt" })
      self.inline_maps[#self.inline_maps + 1] = {
        mode = entry.mode,
        lhs = entry.lhs,
        callback = callback,
        previous = previous,
      }
    end
  end
  install(spec.normal, { "n" })
  install(spec.visual, { "x" })
end

function M:install_chat_keymaps()
  local S = self:state()
  local actions = self.deps.actions
  local update_title = self.deps.update_title
  keymaps.attach_chat(S.view.chat.buf, {
    keymaps = self.deps.config().keymaps.chat,
    on_hide = actions.hide,
    on_focus_input = function()
      actions.focus("input")
    end,
    on_toggle_block = function()
      if not S.view.chat:toggle_current() then
        actions.focus("input")
      end
    end,
    on_prev_block = function()
      S.view.chat:jump_block(-1)
      update_title()
    end,
    on_next_block = function()
      S.view.chat:jump_block(1)
      update_title()
    end,
    on_open_location = function()
      if S.view.chat:activate_page() then
        return
      end
      actions.open_location()
    end,
    on_help = actions.show_help,
    on_add_selection = actions.add_selection,
    on_add_file = actions.add_file,
    on_add_diagnostics = actions.add_diagnostics,
    on_pick_model = actions.pick_model,
    on_pick_mode = actions.pick_mode,
    on_cycle_mode = actions.cycle_mode,
    on_pick_thinking = actions.pick_thinking,
    on_new_session = actions.new_session,
    on_pick_session = actions.pick_session,
    on_scroll_bottom = function()
      S.view.chat:scroll_to_bottom()
      update_title()
    end,
    on_scroll_top = function()
      S.view.chat:scroll_to_top()
      update_title()
    end,
    on_focus_choice = function()
      if S.view.choices then
        S.view.choices:focus()
      end
    end,
  })
end

return M
