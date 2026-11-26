-- Session timestamps, shown in the user's local time.
--
-- Agents report `updatedAt` as ISO 8601, usually in UTC (`...Z`) or with a
-- numeric offset. Printing the date part verbatim (the old behaviour) showed
-- UTC in a +08:00 editor, which reads as a session updated eight hours ago.
-- The parser is deliberately small: it accepts the shapes ACP agents send and
-- returns nil for anything else, so callers can fall back to the raw text.
local M = {}

---The local zone's UTC offset in seconds at `epoch`.
---@param epoch integer
---@return integer
local function local_offset(epoch)
  local text = os.date("%z", epoch)
  local sign, hours, minutes = text:match("^([+-])(%d%d)(%d%d)$")
  if not sign then
    return 0
  end
  local offset = tonumber(hours) * 3600 + tonumber(minutes) * 60
  return sign == "-" and -offset or offset
end

---Parse an ISO 8601 timestamp into a unix time.
---
---Accepts `YYYY-MM-DD[T ]HH:MM[:SS][.fraction][Z|±HH:MM|±HHMM]`. A timestamp
---without a zone is already local time, exactly as `os.date` expects.
---@param value any
---@return integer|nil epoch seconds, or nil when the shape is not understood
function M.parse(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local year, month, day, hour, minute, rest = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d)(.*)$")
  if not year then
    return nil
  end

  local second = 0
  local seconds, tail = rest:match("^:(%d%d)(.*)$")
  if seconds then
    second = tonumber(seconds)
    rest = tail
  end
  -- Fractional seconds do not change the displayed minute, but they are part
  -- of the shape and must be consumed before the zone.
  local fraction, after_fraction = rest:match("^(%.%d+)(.*)$")
  if fraction then
    rest = after_fraction
  end

  local zone = nil
  if rest == "" then
    zone = "local"
  elseif rest == "Z" or rest == "z" then
    zone = 0
  else
    local sign, zone_hours, zone_minutes = rest:match("^([+-])(%d%d):?(%d%d)$")
    if not sign then
      return nil
    end
    zone = tonumber(zone_hours) * 3600 + tonumber(zone_minutes) * 60
    if sign == "-" then
      zone = -zone
    end
  end

  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute = tonumber(hour), tonumber(minute)
  if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60 then
    return nil
  end

  -- `os.time` interprets the table as local wall time, so its result is the
  -- epoch of those fields in *this* zone. Shifting by the difference between
  -- the timestamp's zone and the local one yields the real instant.
  local wall = os.time({ year = year, month = month, day = day, hour = hour, min = minute, sec = second })
  if not wall then
    return nil
  end
  if zone == "local" then
    return wall
  end
  local epoch = wall + local_offset(wall) - zone
  -- One refinement for a DST boundary crossed between the two readings.
  return wall + local_offset(epoch) - zone
end

---Format a timestamp as a local "YYYY-MM-DD HH:MM".
---
---Returns "" for an absent value and falls back to the raw text (trimmed the
---old way) when the timestamp does not parse.
---@param value any
---@return string
function M.short(value)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  local epoch = M.parse(value)
  if not epoch then
    return value:sub(1, 16)
  end
  return os.date("%Y-%m-%d %H:%M", epoch)
end

return M
