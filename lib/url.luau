--!strict
-- URL helpers: percent-encoding, user-input normalization, host display, private-address test and
-- relative-reference resolution. Both halves.

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

-- Whether the 32-bit address `n` is loopback, "this network", private or link-local.
local function v4_private(n: number): boolean
	local x = n // 16777216
	local y = (n // 65536) % 256
	return x == 0
		or x == 10
		or x == 127
		or (x == 172 and y >= 16 and y <= 31)
		or (x == 192 and y == 168)
		or (x == 169 and y == 254)
end

-- One dotted-IPv4 piece the way WHATWG reads it: 0x.. hex, a leading 0 octal, else decimal. nil when
-- it isn't a number (or is too long to matter).
local function v4_piece(p: string): number?
	if #p > 16 then
		return nil
	end
	if string.find(p, "^0[xX]%x*$") then
		return if #p == 2 then 0 else tonumber(string.sub(p, 3), 16)
	end
	if string.find(p, "^0%d+$") then
		return tonumber(p, 8)
	end
	if string.find(p, "^%d+$") then
		return tonumber(p)
	end
	return nil
end

-- `host` as an IPv4 address: 1 to 4 pieces ("127.1", "0x7f.1", "2130706433"). nil when it is a
-- domain name; `false` when it looks numeric but no browser would accept it (answered as private,
-- since nothing good fetches such a host).
local function parse_v4(host: string): (number | boolean)?
	local h = string.gsub(host, "%.$", "")
	local last = string.match(h, "([^.]*)$") or ""
	if not (string.find(last, "^%d+$") or string.find(last, "^0[xX]%x*$")) then
		return nil
	end
	local pieces: { string } = {}
	local at = 1
	while true do
		local dot = string.find(h, ".", at, true)
		table.insert(pieces, string.sub(h, at, (dot or #h + 1) - 1))
		if #pieces > 4 then
			return false
		end
		if dot == nil then
			break
		end
		at = dot + 1
	end
	local n = 0
	for i, p in pieces do
		local v = v4_piece(p)
		if v == nil then
			return false
		end
		if i < #pieces then
			if v > 255 then
				return false
			end
			n += v * 256 ^ (4 - i)
		else
			if v >= 256 ^ (5 - i) then
				return false
			end
			n += v
		end
	end
	return n
end

-- `v6` (the text inside the brackets) as eight 16-bit groups, or nil when malformed.
local function parse_v6(v6: string): { number }?
	local s = v6
	local tail = string.match(s, ":(%d+%.%d+%.%d+%.%d+)$")
	if tail then
		local a, b, c, d = string.match(tail, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		local na, nb, nc, nd = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
		if na == nil or nb == nil or nc == nil or nd == nil or na > 255 or nb > 255 or nc > 255 or nd > 255 then
			return nil
		end
		s = string.sub(s, 1, #s - #tail) .. string.format("%x:%x", na * 256 + nb, nc * 256 + nd)
	end
	if string.find(s, "[^%x:]") or string.find(s, ":::", 1, true) then
		return nil
	end
	local head, rest = s, nil
	local gap = string.find(s, "::", 1, true)
	if gap then
		head, rest = string.sub(s, 1, gap - 1), string.sub(s, gap + 2)
		if string.find(rest, "::", 1, true) then
			return nil
		end
	end
	local function groups(part: string): { number }?
		local out: { number } = {}
		if part == "" then
			return out
		end
		for g in string.gmatch(part .. ":", "([^:]*):") do
			if g == "" or #g > 4 then
				return nil
			end
			table.insert(out, tonumber(g, 16) :: number)
		end
		return out
	end
	local front = groups(head)
	local back: { number }? = if rest then groups(rest) else {}
	if front == nil or back == nil then
		return nil
	end
	local out = front
	if rest then
		if #front + #back > 7 then
			return nil
		end
		for _ = 1, 8 - #front - #back do
			table.insert(out, 0)
		end
	end
	for _, g in back do
		table.insert(out, g)
	end
	if #out ~= 8 then
		return nil
	end
	return out
end

-- Whether `u` points at this machine or a private network: localhost names, loopback, private and
-- link-local IPv4 however it is spelled (127.1, 0x7f.1, 2130706433, octal), and IPv6 loopback,
-- unique-local and link-local, including IPv4 hidden in an IPv6 address (::ffff:7f00:1).
function url.is_private(u: string): boolean
	local host = string.lower(url.host(u))
	if host == "localhost" or host == "localhost." or string.find(host, "%.localhost%.?$") ~= nil then
		return true
	end
	local v6 = string.match(host, "^%[(.*)%]$")
	if v6 then
		local g = parse_v6(v6)
		if g == nil then
			return true
		end
		if g[1] >= 0xfc00 and g[1] <= 0xfdff or g[1] >= 0xfe80 and g[1] <= 0xfebf then
			return true
		end
		local zeros = function(from: number, to: number): boolean
			for i = from, to do
				if g[i] ~= 0 then
					return false
				end
			end
			return true
		end
		local low = g[7] * 65536 + g[8]
		if zeros(1, 5) and (g[6] == 0xffff or g[6] == 0) then
			return v4_private(low) -- IPv4-mapped, or IPv4-compatible (which includes :: and ::1)
		end
		return g[1] == 0x64 and g[2] == 0xff9b and zeros(3, 6) and v4_private(low)
	end
	local n = parse_v4(host)
	if n == nil then
		return false
	end
	if type(n) == "boolean" then
		return true
	end
	return v4_private(n)
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
