--!strict
-- URL helpers: percent-encoding, user-input normalization, host display and relative-reference
-- resolution. Both halves.

local url = {}

-- RFC 3986 percent-encoding: every byte outside [A-Za-z0-9-._~] becomes %XX.
function url.encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Turns every %XX into its byte; "+" stays as is.
function url.decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- A typed or pasted address as an http(s) URL: trimmed, first line only, "https://" added when it
-- has no scheme; nil when it isn't one.
function url.normalize(input: string): string?
	local line = string.match(input, "^%s*([^\r\n]*)") or ""
	local s = string.match(line, "^(.-)%s*$") or ""
	if s == "" then
		return nil
	end
	if string.find(s, "^%a[%w+.-]*://") then
		s = string.gsub(s, "^(%a[%w+.-]*)://", function(scheme: string): string
			return string.lower(scheme) .. "://" -- schemes are case-insensitive (HTTPS://, Https://)
		end)
	else
		s = "https://" .. s
	end
	if not string.find(s, "^https?://[^%s/?#]+") or string.find(s, "%s") then
		return nil
	end
	return s
end

-- The host of `u` without a "www." prefix, or `u` itself when it has none.
function url.host(u: string): string
	local host = string.match(u, "^%a[%w+.-]*://([^/?#]+)")
	if host == nil then
		return u
	end
	host = string.gsub(host, "^[^@]*@", "") -- userinfo
	host = string.gsub(host, ":%d*$", "") -- port
	host = string.gsub(host, "^[wW][wW][wW]%.", "")
	if host == "" then
		return u
	end
	return host
end

-- `href` resolved against `base` (no ".." normalization). "?query" keeps the base path, "#frag" the
-- base path and query.
function url.resolve(base: string, href: string): string
	if string.find(href, "^%a[%w+.-]*:") then
		return href
	end
	local scheme = string.match(base, "^(%a[%w+.-]*):") or "https"
	if string.sub(href, 1, 2) == "//" then
		return scheme .. ":" .. href
	end
	local origin = string.match(base, "^%a[%w+.-]*://[^/?#]*") or ""
	local first = string.sub(href, 1, 1)
	if first == "/" then
		return origin .. href
	end
	local rest = string.sub(base, #origin + 1)
	if first == "#" then
		return origin .. (string.match(rest, "^[^#]*") or "") .. href
	end
	local path = string.match(rest, "^[^?#]*") or ""
	if first == "?" then
		return origin .. (if path == "" then "/" else path) .. href
	end
	local dir = string.match(path, "^(.*/)") or "/"
	return origin .. dir .. href
end

return url
