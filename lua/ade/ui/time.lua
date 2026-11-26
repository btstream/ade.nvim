-- Session timestamps, shown in the user's local time.
--
-- Agents report `updatedAt` as ISO 8601, usually in UTC (`...Z`) or with a
-- numeric offset. Printing the date part verbatim (the old behaviour) showed
-- UTC in a +08:00 editor, which reads as a session updated eight hours ago.
-- The parser is deliberately small: it accepts the shapes ACP agents send and
-- returns nil for anything else, so callers can fall back to the raw text.
local M = {}

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

---@param year integer
---@return boolean
local function is_leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

---@param year integer
---@param month integer
---@return integer
local function days_in_month(year, month)
  if month == 2 and is_leap_year(year) then
    return 29
  end
  return DAYS_IN_MONTH[month]
end

---Days since 1970-01-01 for a proleptic Gregorian date.
---
---Howard Hinnant's `days_from_civil`: pure arithmetic, so it cannot be shifted
---by the machine's zone or by a DST transition. Applying it to the timestamp's
---own fields (and subtracting the input's offset) is what keeps a UTC value
---stable across a DST boundary — `os.time` on UTC fields plus an offset
---correction double-counts the local shift.
---@param year integer
---@param month integer
---@param day integer
---@return integer
local function days_from_civil(year, month, day)
  local y = month <= 2 and year - 1 or year
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
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
    zone_hours, zone_minutes = tonumber(zone_hours), tonumber(zone_minutes)
    if zone_hours > 23 or zone_minutes > 59 then
      return nil
    end
    zone = zone_hours * 3600 + zone_minutes * 60
    if sign == "-" then
      zone = -zone
    end
  end

  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute = tonumber(hour), tonumber(minute)
  if month < 1 or month > 12 then
    return nil
  end
  if day < 1 or day > days_in_month(year, month) then
    return nil
  end
  if hour > 23 or minute > 59 or second > 59 then
    return nil
  end

  if zone == "local" then
    -- No zone means local wall time: the C library applies this machine's
    -- offset (and DST) to the broken-down table, which is exactly right here.
    return os.time({ year = year, month = month, day = day, hour = hour, min = minute, sec = second })
  end

  -- Zoned input: build the UTC instant arithmetically, then subtract the
  -- zone's offset. No local time is involved, so a DST boundary on this
  -- machine cannot move the result.
  local days = days_from_civil(year, month, day)
  return days * 86400 + hour * 3600 + minute * 60 + second - zone
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
