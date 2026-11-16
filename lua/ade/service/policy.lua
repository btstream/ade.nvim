-- Permission policy installed into nvim_ade_server (PROTOCOL.md section 17).
--
-- The service answers `session/request_permission` itself when a rule set the
-- front end installed decides it, with or without a front end attached. The
-- sets are data; this module is the only place that translates the plugin's
-- existing configuration and inline-turn policy into those sets, so the two
-- implementations cannot drift.
--
-- When the running service does not advertise `"policy"` (an older service, or
-- the direct backend) `active()` is false and every caller keeps the Lua
-- behaviour.
local async = require("ade.async")
local log = require("ade.log")

local M = {}

---A failure caused by the connection going away (teardown/reconnect) is not a
---policy error the user can act on; the next hello re-installs the set.
---@param value any
---@return boolean
local function closed_error(value)
  local message = type(value) == "table" and tostring(value.message or "") or tostring(value or "")
  return message:find("closed by the client", 1, true) ~= nil
    or message:find("connection was closed", 1, true) ~= nil
    or message:find("not connected", 1, true) ~= nil
    or message:find("not finish connecting", 1, true) ~= nil
end

local Policy = {}
Policy.__index = Policy

---@param opts {config: fun(): table, connection: fun(): table|nil,
---  notify?: fun(message: string, level: integer|nil),
---  on_applied?: fun(payload: table)|nil}
---@return table
function M.new(opts)
  return setmetatable({
    config = opts.config,
    connection = opts.connection,
    notify = opts.notify or function() end,
    on_applied = opts.on_applied,
    -- The set last installed successfully, so a reconfiguration does not spam
    -- the service. `false` means "known cleared".
    sent = nil,
    raw = nil,
    -- One warning per kind list/config error, not per reconcile.
    warned_kinds = nil,
    warned_config = false,
  }, Policy)
end

---The live service connection, when there is one.
---@return table|nil
function Policy:_raw()
  local app = self.connection()
  if not app or type(app.service_connection) ~= "function" then
    return nil
  end
  local ok, connection = pcall(app.service_connection, app)
  if not ok or type(connection) ~= "table" then
    return nil
  end
  return connection
end

---Register the hello and notification hooks once per connection object.
---@param raw table
function Policy:_attach(raw)
  if self.raw == raw then
    return
  end
  self.raw = raw
  self.sent = nil
  if type(raw.on_hello) == "function" then
    raw:on_hello("policy", function()
      -- A service that restarted forgot every keep = "service" set (17.1).
      self:reconcile(true)
    end)
  end
  if type(raw.subscribe) == "function" then
    raw:subscribe("policy", "policy.applied", function(payload)
      if self.on_applied then
        pcall(self.on_applied, payload)
      end
    end)
  end
end

---Whether a service with the `policy` feature is connected at all.
---@return boolean
function Policy:available()
  local cfg = self.config() or {}
  if cfg.backend == "direct" then
    return false
  end
  local raw = self:_raw()
  if not raw then
    return false
  end
  self:_attach(raw)
  return raw:is_connected() and raw:has_feature("policy")
end

---Whether this connection must leave permission decisions to the service.
---
---The *agent client* must actually run through the service. `backend = auto`
---may have fallen back to direct while some other path (the agent manager,
---`:Ade service ...`) connected the shared service connection; letting the
---service own permissions then would leave the direct agent's requests
---unanswered.
---@return boolean
function Policy:active()
  if not self:available() then
    return false
  end
  local app = self.connection()
  return app ~= nil and app.backend_service == true
end

---Whether the configuration set should be installed now.
---
---`keep = "service"` sets outlive the agent connection and are what keeps
---auto_allow working while nobody watches, so they go in after every hello even
---before an agent attaches. Once this Neovim has an agent, the answer is strict:
---only a service-backed client may speak for it (an auto fallback to direct
---must not install rules that affect other front ends' agents).
---@return boolean
function Policy:should_install_config()
  if not self:available() then
    return false
  end
  local app = self.connection()
  if not app then
    return false
  end
  return app.backend_service == true or app.client == nil
end

---The `config` set for `permissions.auto_allow`, or nil when empty (17.6).
---
---Only option kinds the protocol knows are sent: an unknown kind would make
---the service refuse the whole set with -32050, silently disabling every
---auto_allow while the Lua policy has already stepped aside.
---@return table|nil set
---@return table|nil invalid kinds that were ignored
function Policy:config_set()
  local cfg = self.config() or {}
  local permissions = type(cfg.permissions) == "table" and cfg.permissions or {}
  local auto = permissions.auto_allow or {}
  if #auto == 0 then
    return nil
  end
  local known = {
    allow_once = true,
    allow_always = true,
    reject_once = true,
    reject_always = true,
  }
  local choose, invalid = {}, nil
  local allow_always = false
  for _, kind in ipairs(auto) do
    if known[kind] then
      choose[#choose + 1] = kind
      if kind == "allow_always" then
        allow_always = true
      end
    else
      invalid = invalid or {}
      invalid[#invalid + 1] = tostring(kind)
    end
  end
  if #choose == 0 then
    return nil, invalid
  end
  return {
    name = "config",
    keep = "service",
    priority = 0,
    allow_always = allow_always,
    rules = {
      { choose = choose, pick = "offered" },
    },
  },
    invalid
end

---Install or clear the configuration set.
---
---`force` re-sends an unchanged set; hello does this because the service may
---have lost its sets while this connection was away.
---@param force boolean|nil
---@return boolean|nil active nil when policy is not in use
function Policy:reconcile(force)
  if not self:should_install_config() then
    return nil
  end
  local raw = self:_raw()
  local set, invalid = self:config_set()
  if invalid then
    local joined = table.concat(invalid, ", ")
    if self.warned_kinds ~= joined then
      self.warned_kinds = joined
      local message = "permissions.auto_allow ignores unknown option kind(s): " .. joined
      log.warn("%s", message)
      self.notify(message, vim.log.levels.WARN)
    end
  end
  if not set then
    if force or self.sent ~= false then
      raw:request_tracked("policy.clear", { name = "config" }, function(ok, value)
        if ok then
          self.sent = false
        else
          self.sent = nil
          log.warn("policy.clear config failed: %s", tostring(value and (value.message or value) or "unknown"))
          if not self.warned_config then
            self.warned_config = true
            self.notify(
              "permissions.auto_allow could not be cleared in the service: "
                .. tostring(value and (value.message or value) or "unknown"),
              vim.log.levels.WARN
            )
          end
        end
      end)
    end
    return true
  end
  if not force and vim.deep_equal(set, self.sent) then
    return true
  end
  raw:request_tracked("policy.set", { set = set }, function(ok, value)
    if ok then
      self.sent = set
      self.warned_config = false
      return
    end
    -- Try again on the next reconcile/hello; never leave a set marked as
    -- installed when the service refused it.
    self.sent = nil
    if closed_error(value) then
      return
    end
    local message = tostring(value and (value.message or value) or "unknown")
    log.warn("policy.set config failed: %s", message)
    if not self.warned_config then
      self.warned_config = true
      self.notify("permissions.auto_allow could not be installed in the service: " .. message, vim.log.levels.WARN)
    end
  end)
  return true
end

---The `inline:<session>` set for one inline turn (17.6, order is normative).
---@param inv table
---@return table
function Policy:inline_set(inv)
  local cfg = inv.config or self.config()
  local inline = type(cfg.inline) == "table" and cfg.inline or {}
  local session = inv.session
  local cwd = session and session.cwd or vim.fn.getcwd()
  local kinds = { "read", "search", "think", "fetch" }
  local seen = { read = true, search = true, think = true, fetch = true }
  for _, kind in ipairs(inline.allow_kinds or {}) do
    -- The Lua policy never lets allow_kinds authorise edits: edits are limited
    -- to the private copy (plus allow_writes). Sending "edit" in this rule
    -- would make the service more permissive than the Lua implementation.
    if kind ~= "edit" and not seen[kind] then
      seen[kind] = true
      kinds[#kinds + 1] = kind
    end
  end
  if inline.allow_commands == true and not seen.execute then
    kinds[#kinds + 1] = "execute"
  end
  local choose = { "allow_once", "reject_once" }
  local rules = {
    -- The private copy is the one edit the inline turn may make.
    { kinds = { "edit" }, paths = { inv.copy }, choose = choose },
  }
  if inline.allow_writes == true then
    rules[#rules + 1] = { kinds = { "edit" }, choose = choose }
  end
  rules[#rules + 1] = { kinds = kinds, choose = choose }
  -- Everything else is refused, and the set-level fallback covers requests
  -- that name no kind or no path.
  rules[#rules + 1] = { choose = { "reject_once" } }
  return {
    name = "inline:" .. tostring(session and session.id or ""),
    session = session and session.id or nil,
    ["until"] = "turn_end",
    priority = 100,
    fallback = "cancelled",
    cwd = cwd,
    rules = rules,
  }
end

---Install the inline set before the prompt is sent.
---
---The caller waits for this callback before calling `session/prompt`; a failure
---marks the turn so the Lua inline policy keeps answering its permissions.
---@param inv table
---@param cb fun(ok: boolean, value: any)
function Policy:set_inline(inv, cb)
  if not self:active() then
    cb(false, "policy is not provided by this service")
    return
  end
  local raw = self:_raw()
  local set = self:inline_set(inv)
  -- Remembered before the request: a cancellation between the set and the
  -- prompt must clear it even if the reply never arrives.
  inv.policy_requested = true
  raw:request_tracked("policy.set", { set = set }, function(ok, value)
    if ok then
      inv.policy_fallback = nil
      inv.policy_set = true
      -- Remember which connection holds the turn_end set: a reconnect between
      -- this reply and the prompt would otherwise bind it to a new prompt.
      inv.policy_connection = raw
      cb(true, value)
      return
    end
    inv.policy_fallback = true
    local message = type(value) == "table" and (value.message or value.code) or tostring(value)
    log.warn("inline policy.set failed; falling back to the Lua policy: %s", tostring(message))
    cb(false, value)
  end)
end

---Await `set_inline` from a prompt coroutine.
---@param inv table
---@return boolean ok
function Policy:prepare_inline(inv)
  if not self:active() then
    return false
  end
  local ok = async.await(function(done)
    self:set_inline(inv, function(result, value)
      done(result, value)
    end)
  end) == true
  if not ok then
    return false
  end
  -- The set belongs to the connection that installed it. If `ensure()`
  -- reconnected while we waited, the service dropped it; do not send the
  -- prompt under the illusion that the rules are in place.
  local raw = self:_raw()
  if not raw or raw ~= inv.policy_connection or not raw:is_connected() then
    inv.policy_set = nil
    inv.policy_fallback = true
    log.warn("inline policy connection changed before the prompt; falling back to Lua")
    return false
  end
  return true
end

---Remove a turn-scoped set whose prompt was never sent.
---
---A `turn_end` set binds to the *next* prompt for its session on that
---connection (PROTOCOL.md 17.3); leaving one behind after a cancellation would
---apply the inline rules to an ordinary chat prompt.
---@param session_id string|nil
function Policy:clear_inline(session_id)
  if type(session_id) ~= "string" or session_id == "" or not self:active() then
    return
  end
  local raw = self:_raw()
  if not raw then
    return
  end
  raw:request_tracked("policy.clear", { name = "inline:" .. session_id }, function() end)
end

M.Policy = Policy

return M
