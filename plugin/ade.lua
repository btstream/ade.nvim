-- User commands.
local function api()
  local ok, mod = pcall(require, "ade")
  if not ok then
    return nil
  end
  return mod
end

local SUBCOMMANDS = {
  "open",
  "hide",
  "toggle",
  "new",
  "stop",
  "reconnect",
  "login",
  "logout",
  "agent",
  "agents",
  "install",
  "update",
  "uninstall",
  "config",
  "disconnect",
  "permission",
  "sessions",
  "delete",
  "model",
  "mode",
  "file",
  "files",
  "image",
  "inline",
  "inline-stop",
  "inline-reset",
  "diagnostics",
  "service",
}

---Subcommands of `:Ade service`.
local SERVICE_SUBCOMMANDS = { "install", "status", "start", "stop", "agents", "kill" }

---Complete subcommands, and agent ids for the commands that take one.
local function complete(arglead, cmdline)
  local words = vim.split(vim.trim(cmdline), "%s+")
  local typing_first = #words == 1 or (#words == 2 and not cmdline:match("%s$"))
  local candidates
  if typing_first then
    candidates = SUBCOMMANDS
  else
    local sub = words[2]
    if sub == "install" or sub == "update" or sub == "uninstall" then
      local ok, registry = pcall(require, "ade.manager.registry")
      candidates = {}
      if ok then
        for _, id in ipairs(registry.ids()) do
          if registry.package_of(id) then
            candidates[#candidates + 1] = id
          end
        end
      end
    elseif sub == "agent" then
      local ok, config = pcall(require, "ade.config")
      local current = ok and (config.current or config.defaults) or {}
      candidates = vim.tbl_keys(current.agents or {})
      table.sort(candidates)
    elseif sub == "service" then
      candidates = SERVICE_SUBCOMMANDS
    else
      return {}
    end
  end
  return vim.tbl_filter(function(item)
    return vim.startswith(item, arglead)
  end, candidates)
end

local function define(name, fn, desc, range, completer)
  pcall(
    vim.api.nvim_create_user_command,
    name,
    fn,
    { desc = "ade.nvim: " .. desc, nargs = "*", range = range, complete = completer }
  )
end

local function setup()
  define(
    "Ade",
    function(args)
      local ade = api()
      if not ade then
        return
      end
      local sub = args.args ~= "" and args.args or "toggle"
      local rest = ""
      local head, tail = sub:match("^(%S+)%s+(.+)$")
      if head then
        sub, rest = head, tail
      end
      if sub == "open" then
        ade.open()
      elseif sub == "hide" or sub == "close" then
        ade.hide()
      elseif sub == "toggle" then
        ade.toggle()
      elseif sub == "new" then
        ade.new_session()
      elseif sub == "stop" or sub == "cancel" then
        ade.cancel()
      elseif sub == "sessions" then
        ade.pick_session()
      elseif sub == "delete" then
        ade.delete_session()
      elseif sub == "reconnect" then
        ade.reconnect()
      elseif sub == "login" then
        ade.login()
      elseif sub == "logout" then
        ade.logout()
      elseif sub == "agent" then
        ade.pick_agent(rest ~= "" and rest or nil)
      elseif sub == "agents" then
        ade.manage_agents()
      elseif sub == "team" then
        ade.open_team()
      elseif sub == "install" or sub == "update" then
        -- Like :MasonInstall, the window opens so the install is visible.
        local id, version = rest:match("^(%S+)%s*(%S*)$")
        if not id then
          if sub == "update" then
            ade.update_agent(nil)
          end
          ade.manage_agents()
          return
        end
        local fn = sub == "install" and ade.install_agent or ade.update_agent
        if fn(id, version ~= "" and { version = version } or nil) then
          ade.manage_agents()
        end
      elseif sub == "uninstall" then
        if rest == "" then
          ade.manage_agents()
          return
        end
        ade.uninstall_agent(rest)
      elseif sub == "config" then
        ade.pick_config()
      elseif sub == "disconnect" then
        ade.disconnect()
      elseif sub == "permission" then
        ade.show_permission()
      elseif sub == "model" then
        ade.pick_model()
      elseif sub == "mode" then
        ade.pick_mode()
      elseif sub == "file" then
        ade.add_file()
      elseif sub == "files" then
        ade.pick_file()
      elseif sub == "image" then
        if rest ~= "" then
          ade.add_image(vim.fn.expand(rest))
        else
          ade.paste_image()
        end
      elseif sub == "inline" then
        local opts = {}
        if rest ~= "" then
          opts.review = rest
        end
        if args.range > 0 then
          opts.mode = "V"
          opts.pos1 = { 0, args.line1, 1, 0 }
          opts.pos2 = { 0, args.line2, 1, 0 }
        end
        ade.inline(opts)
      elseif sub == "inline-stop" then
        ade.inline_stop()
      elseif sub == "inline-reset" then
        ade.inline_reset()
      elseif sub == "diagnostics" then
        ade.add_diagnostics()
      elseif sub == "service" then
        -- `rest` is "<sub> [arg]"; `kill` needs the instance id it carries.
        local service_sub, service_rest = rest:match("^(%S+)%s*(.-)%s*$")
        if service_sub then
          require("ade.service.commands").dispatch(service_sub, {
            rest = service_rest ~= "" and service_rest or nil,
          })
        else
          require("ade.service.commands").dispatch(nil)
        end
      else
        vim.notify("ade.nvim: unknown subcommand " .. sub, vim.log.levels.WARN)
      end
    end,
    "open|hide|toggle|new|stop|reconnect|login|logout|agent|agents|team|install|update|uninstall|config|disconnect|permission|sessions|delete|model|mode|file|files|image|inline|inline-stop|inline-reset|diagnostics|service",
    true,
    complete
  )

  define("AdeCompletionRefresh", function()
    local m = api()
    if m then
      m.refresh_completion()
    end
  end, "refresh project file completion indexes")

  define("AdeLog", function()
    local m = api()
    if m then
      m.show_log()
    end
  end, "open the log file")

  define("AdeDebug", function()
    local m = api()
    if m then
      m.debug_state()
    end
  end, "print controller state")
end

setup()

return {}
