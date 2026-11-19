-- Public API.
local controller = require("ade.controller")

local M = {}

local configured = false

---Configure ade.nvim. Safe to call multiple times.
---@param opts table|nil
---@param action {discard_queued?: boolean}|nil explicit consent to drop unsent messages
function M.setup(opts, action)
  controller.setup(opts, action)
  configured = true
end

local function ensure()
  if not configured then
    M.setup({})
  end
  return controller
end

---Open the agent manager (install, update and choose agents).
function M.manage_agents()
  ensure().manage_agents()
end

---Open the team panel. With no team this shows nothing.
---@return boolean opened
function M.open_team()
  return ensure().open_team()
end

---Start a named team workflow (`:Ade team start [workflow]`).
---@param workflow string|nil picks one when absent
function M.start_team(workflow)
  ensure().start_team(workflow)
end

---Close the team of this cwd, after a confirmation.
function M.close_team()
  ensure().close_team()
end

---Show pending choices, or answer a participant's question
---(`:Ade team answer [name]`).
---@param name string|nil
function M.answer_team(name)
  return ensure().answer_team(name)
end

---Open the named workflows window (`:Ade workflows`).
---@return boolean
function M.workflows()
  return ensure().workflows()
end

---Install one managed agent. Nothing is downloaded without user confirmation.
---@param id string
---@param opts {version?: string}|nil
---@return boolean started
function M.install_agent(id, opts)
  return ensure().install_agent(id, opts)
end

---Update one managed agent.
---@param id string
---@param opts {version?: string}|nil
---@return boolean started
function M.update_agent(id, opts)
  return ensure().update_agent(id, opts)
end

---Remove the manager-owned copy of one agent.
---@param id string
---@return boolean started
function M.uninstall_agent(id)
  return ensure().uninstall_agent(id)
end

function M.open()
  ensure().open()
end

function M.hide()
  ensure().hide()
end

function M.toggle()
  ensure().toggle()
end

---@param which "input"|"chat"
function M.focus(which)
  ensure().focus(which or "input")
end

function M.new_session()
  ensure().new_session()
end

---Log in with whatever method the agent offered.
function M.login()
  ensure().login()
end

---Log out, when the agent supports it.
function M.logout()
  ensure().logout()
end

function M.cancel()
  ensure().cancel()
end

---@param path string|nil
function M.add_file(path)
  ensure().add_file(path)
end

function M.pick_file(opts)
  return ensure().pick_file(opts)
end

---Attach an image file to the composer.
---@param path string
function M.add_image(path)
  return ensure().add_image(path)
end

---Read an image from the clipboard and attach it.
---@param opts {command?: string[]|false}|nil
function M.paste_image(opts)
  return ensure().paste_image(opts)
end

---Switch to another configured agent, or pick one.
---@param name string|nil
function M.pick_agent(name)
  ensure().pick_agent(name)
end

---Open the picker for the agent's session controls.
function M.pick_config()
  ensure().pick_config()
end

---Start an inline edit at the cursor or visual selection.---@param opts {review?: "diff"|"write"}|nil
function M.inline(opts)
  ensure()
  return require("ade.inline").open(opts)
end

---Stop the active inline edit.
function M.inline_stop()
  return require("ade.inline").stop()
end

---Forget the current buffer's "always accept" inline state.
function M.inline_reset()
  require("ade.inline").reset()
end

function M.refresh_completion()
  require("ade.completion").refresh()
end

function M.add_selection()
  ensure().add_selection()
end

function M.add_diagnostics()
  ensure().add_diagnostics()
end

function M.pick_model()
  ensure().pick_model()
end

function M.pick_mode()
  ensure().pick_mode()
end

function M.cycle_mode()
  ensure().cycle_mode()
end

function M.pick_thinking()
  ensure().pick_thinking()
end

function M.pick_session()
  ensure().pick_session()
end

---Delete a stored session (asks for confirmation first).
function M.delete_session()
  ensure().delete_session_flow()
end

---Reconnect to the agent after a crash or an explicit disconnect.
function M.reconnect()
  ensure().reconnect()
end

---Stop the agent process without closing the panel.
function M.disconnect()
  ensure().disconnect()
end

---Open the oldest pending permission request.
function M.show_permission()
  ensure().show_pending_permission()
end

function M.status()
  return ensure().status()
end

---Short statusline component. Returns text only; it never sets an option.
---@return string
function M.statusline()
  return ensure().statusline()
end

function M.health()
  return require("ade.health").check()
end

---Open the log file.
function M.show_log()
  ensure().show_log()
end

---Print controller diagnostics.
function M.debug_state()
  ensure().debug_state()
end

return M
