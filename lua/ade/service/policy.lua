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

---Whether this connection must leave permission decisions to the service.
---@return boolean
function Policy:active()
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

---The `config` set for `permissions.auto_allow`, or nil when empty (17.6).
---@return table|nil
function Policy:config_set()
  local cfg = self.config() or {}
  local permissions = type(cfg.permissions) == "table" and cfg.permissions or {}
  local auto = permissions.auto_allow or {}
  if #auto == 0 then
    return nil
  end
  local allow_always = false
  for _, kind in ipairs(auto) do
    if kind == "allow_always" then
      allow_always = true
    end
  end
  return {
    name = "config",
    keep = "service",
    priority = 0,
    allow_always = allow_always,
    rules = {
      { choose = vim.deepcopy(auto), pick = "offered" },
    },
  }
end

---Install or clear the configuration set.
---
---`force` re-sends an unchanged set; hello does this because the service may
---have lost its sets while this connection was away.
---@param force boolean|nil
---@return boolean|nil active nil when policy is not in use
function Policy:reconcile(force)
  if not self:active() then
    return nil
  end
  local raw = self:_raw()
  local set = self:config_set()
  if not set then
    if self.sent ~= false then
      raw:request_tracked("policy.clear", { name = "config" }, function(ok)
        if ok then
          self.sent = false
        end
      end)
      self.sent = false
    end
    return true
  end
  if not force and vim.deep_equal(set, self.sent) then
    return true
  end
  self.sent = set
  raw:request_tracked("policy.set", { set = set }, function(ok, value)
    if not ok then
      -- Try again on the next reconcile/hello; never leave a set marked as
      -- installed when the service refused it.
      self.sent = nil
      log.warn("policy.set config failed: %s", tostring(value and (value.message or value) or "unknown"))
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
    if not seen[kind] then
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
  raw:request_tracked("policy.set", { set = set }, function(ok, value)
    if ok then
      inv.policy_fallback = nil
      inv.policy_set = true
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
  return async.await(function(done)
    self:set_inline(inv, function(ok, value)
      done(ok, value)
    end)
  end) == true
end

M.Policy = Policy

return M
