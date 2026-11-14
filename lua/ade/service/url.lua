-- URL rules for the service release host.
--
-- `service.release_base` points at the directory holding both the archive and
-- its `SHA256SUMS`. Those two files are only trustworthy together if the
-- transport itself cannot be rewritten: over plain http a network attacker can
-- replace both and the checksum check passes on the attacker's archive. So
-- https is required, with one exception for a loopback host, where there is no
-- network in between and a local test server is genuinely useful.
local M = {}

---Hosts that are guaranteed to be the local machine.
M.LOOPBACK_HOSTS = {
  ["localhost"] = true,
  ["127.0.0.1"] = true,
  ["[::1]"] = true,
}

---Split a URL into its lowercase scheme and host.
---
---This is a *splitter*, not a validator: it answers "what would this parse as",
---which is useful for error messages and for the predicates below. Validation
---lives in `syntax_error`, and every public predicate here consults it, because
---a URL the parsers disagree about must never be treated as loopback.
---
---Returns nil for anything that is not `scheme://…`.
---@param url string|nil
---@return {scheme: string, host: string}|nil
function M.parse(url)
  if type(url) ~= "string" then
    return nil
  end
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if not scheme then
    return nil
  end
  local authority = rest:match("^([^/?#]*)") or ""
  -- `user:pass@host` is legal; the host is what matters here. `release_base`
  -- rejects userinfo outright (see `syntax_error`), but the splitter still
  -- reports the host so diagnostics can name it.
  authority = authority:gsub("^.*@", "")
  local host = authority:match("^(%[.-%])")
  if not host then
    host = authority:match("^([^:]*):%d+$") or authority
  end
  return { scheme = scheme:lower(), host = (host or ""):lower() }
end

---Reject URL shapes that different parsers read differently.
---
---`release_base` has no legitimate use for any of these, and each one is a way
---to make our host check and curl's host resolution disagree:
---
---   * a backslash — browsers normalise it to `/`, so `http://evil.example\@127.0.0.1/`
---     is "host 127.0.0.1" here and "path on evil.example" elsewhere;
---   * whitespace or control characters, including NUL and newlines — trimming
---     or line splitting differs per implementation;
---   * userinfo (`@` in the authority) — two parsers can disagree about which
---     side is the host.
---
---Applies to https as well as the loopback-http exception: there is no reason
---for a release host to need them, and the safe answer is to refuse.
---@param url string|nil
---@return string|nil err nil when the shape is acceptable
function M.syntax_error(url)
  if type(url) ~= "string" or url == "" then
    return "service.release_base must be a non-empty URL"
  end
  for index = 1, #url do
    local byte = url:byte(index)
    if byte == 92 then -- backslash
      return "service.release_base must not contain a backslash: URL parsers disagree about whether it"
        .. " begins the path or the host"
    end
    -- Control characters (NUL, newline, tab, …) and the space character.
    if byte < 0x20 or byte == 0x7f or byte == 0x20 then
      return "service.release_base must not contain whitespace or control characters"
    end
  end
  local _, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if rest then
    local authority = rest:match("^([^/?#]*)") or ""
    if authority:find("@", 1, true) then
      return "service.release_base must not contain credentials: parsers disagree about which side of"
        .. " '@' is the host"
    end
  end
  return nil
end

---@param url string|nil
---@return boolean
local function usable(url)
  return M.syntax_error(url) == nil
end

---Whether the URL points at the local machine.
---@param url string|nil
---@return boolean
function M.is_loopback(url)
  if not usable(url) then
    return false
  end
  local parsed = M.parse(url)
  return parsed ~= nil and M.LOOPBACK_HOSTS[parsed.host] == true
end

---Whether the URL is an http URL on the local machine.
---
---A malformed URL is never "loopback http", so the transport rules below can
---never be relaxed by a spelling that another parser reads as a remote host.
---@param url string|nil
---@return boolean
function M.is_loopback_http(url)
  if not usable(url) then
    return false
  end
  local parsed = M.parse(url)
  return parsed ~= nil and parsed.scheme == "http" and M.LOOPBACK_HOSTS[parsed.host] == true
end

---Whether a URL may be fetched at all: https anywhere, http on loopback only.
---@param url string|nil
---@return boolean
function M.allows_fetch(url)
  if not usable(url) then
    return false
  end
  local parsed = M.parse(url)
  if not parsed then
    return false
  end
  if parsed.scheme == "https" then
    return true
  end
  return parsed.scheme == "http" and M.LOOPBACK_HOSTS[parsed.host] == true
end

---Validate a configured `service.release_base`.
---@param url string|nil
---@return string|nil err nil when the value is acceptable
function M.release_base_error(url)
  if type(url) ~= "string" or url == "" then
    return "service.release_base must be an https:// URL"
  end
  -- Shape first: a URL two parsers read differently is never acceptable, and
  -- reporting that is more useful than "must be https".
  local shape = M.syntax_error(url)
  if shape then
    return shape
  end
  local parsed = M.parse(url)
  if not parsed then
    return "service.release_base must be an https:// URL"
  end
  if parsed.scheme ~= "https" and parsed.scheme ~= "http" then
    return "service.release_base must be an https:// URL"
  end
  if parsed.host == "" then
    return "service.release_base must name a host"
  end
  if parsed.scheme == "https" then
    return nil
  end
  if parsed.scheme == "http" and M.LOOPBACK_HOSTS[parsed.host] == true then
    return nil
  end
  return "service.release_base must use https://: over http a network attacker could replace both the archive"
    .. " and its SHA256SUMS, defeating the checksum. http:// is only allowed for a loopback host"
    .. " (localhost, 127.0.0.1 or [::1]) in local testing"
end

return M
