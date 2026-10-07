--!strict
-- Formatting shared by API-backed blocks: timestamps, relative ages, counts, durations, clipping.
-- Both halves.

local fmt = {}

-- Seconds since the epoch of a UTC civil date and time (proleptic Gregorian, days-from-civil).
function fmt.utc(y: number, m: number, d: number, hh: number, mi: number, ss: number): number
	local year = y
	if m <= 2 then
		year -= 1
	end
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (if m > 2 then m - 3 else m + 9) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + hh * 3600 + mi * 60 + ss
end

-- Seconds since the epoch of an ISO 8601 UTC timestamp ("2026-01-02T03:04:05…"); nil if malformed.
function fmt.epoch(iso: string): number?
	local y, m, d, hh, mm, ss = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not (y and m and d and hh and mm and ss) then
		return nil
	end
	return fmt.utc(
		tonumber(y) :: number,
		tonumber(m) :: number,
		tonumber(d) :: number,
		tonumber(hh) :: number,
		tonumber(mm) :: number,
		tonumber(ss) :: number
	)
end

-- os.date as a string; "" when it can't format `t` (Luau answers nil for negative times).
local function date(format: string, t: number): string
	return (os.date(format, t) :: string?) or ""
end

-- `t` (epoch seconds) as a compact age for list values: "now", "5m", "3h", "2d", "4 Mar",
-- "4 Mar 2025"; "" when unknown or before 1970.
function fmt.age(t: number?, now: number): string
	if t == nil or t < 0 then
		return ""
	end
	local d = now - t
	if d < 60 then
		return "now"
	elseif d < 3600 then
		return d // 60 .. "m"
	elseif d < 86400 then
		return d // 3600 .. "h"
	elseif d < 7 * 86400 then
		return d // 86400 .. "d"
	end
	local day = (string.gsub(date("%d %b", t), "^0", ""))
	if date("%Y", t) ~= date("%Y", now) then
		return day .. date(" %Y", t)
	end
	return day
end

-- `t` (epoch seconds) relative to `now`: "just now", "5min ago", "3h ago", "yesterday", "4 Mar";
-- "unknown" when missing or before 1970.
function fmt.ago(t: number?, now: number): string
	if t == nil or t < 0 then
		return "unknown"
	end
	local d = now - t
	if d < 45 then
		return "just now"
	elseif d < 3600 then
		return math.max(1, d // 60) .. "min ago"
	elseif d < 86400 then
		return d // 3600 .. "h ago"
	elseif date("%Y-%m-%d", t) == date("%Y-%m-%d", now - 86400) then
		return "yesterday"
	elseif date("%Y", t) == date("%Y", now) then
		return (string.gsub(date("%d %b", t), "^0", ""))
	end
	return (string.gsub(date("%d %b %Y", t), "^0", ""))
end

-- 950, 1.2k, 34k, 1.5M: keeps the count column narrow.
function fmt.compact(n: number): string
	if n < 1000 then
		return tostring(n)
	elseif n < 10000 then
		return (string.gsub(string.format("%.1fk", n / 1000), "%.0k$", "k"))
	elseif n < 1000000 then
		return n // 1000 .. "k"
	end
	return (string.gsub(string.format("%.1fM", n / 1000000), "%.0M$", "M"))
end

-- `text` cut to `max` characters, the last one an ellipsis.
function fmt.clip(text: string, max: number): string
	local length = utf8.len(text)
	if length == nil then -- not UTF-8: count bytes
		return if #text <= max then text else string.sub(text, 1, max - 1) .. "…"
	end
	if length <= max then
		return text
	end
	local cut = utf8.offset(text, max) or (#text + 1)
	return string.sub(text, 1, cut - 1) .. "…"
end

-- `ms` as "8.4s", "42s", "1m 12s" or "2h 5m".
function fmt.duration(ms: number): string
	if ms < 10000 then
		return string.format("%.1fs", ms / 1000)
	end
	local seconds = math.floor(ms / 1000)
	if seconds < 60 then
		return string.format("%ds", seconds)
	end
	local minutes = seconds // 60
	if minutes < 60 then
		return string.format("%dm %ds", minutes, seconds % 60)
	end
	return string.format("%dh %dm", minutes // 60, minutes % 60)
end

-- The first line of `text`, without its line break.
function fmt.first_line(text: string): string
	return string.match(text, "^[^\r\n]*") or ""
end

return fmt
