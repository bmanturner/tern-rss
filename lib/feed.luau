--!strict
-- RSS 2.0, RSS 1.0 (RDF) and Atom parsing, feed candidates for a web page (its links, platform
-- rewrites, usual paths), feed dates and item hashes. Pure Luau (no tern.* calls); both halves. Every
-- scan is linear: string.find with plain/init positions, gsub passes and table.concat, so a
-- multi-megabyte feed stays inside the 2 s host budget.

local fmt = require("./fmt")
local url = require("./url")

local feed = {}

export type ParsedItem = { id: string, title: string, link: string?, preview: string?, published: number? }
export type Parsed = { title: string?, site: string?, items: { ParsedItem } }

-- One XML element. `text` is the direct text (entities decoded, CDATA raw); `from`..`to` is the raw
-- inner source span, used when markup sits unescaped inside an element (Atom xhtml, sloppy RSS).
type Element = {
	name: string, -- lowercased, prefix kept ("content:encoded")
	lname: string, -- local name ("encoded")
	attrs: { [string]: string },
	children: { Element },
	text: string,
	buf: { string },
	from: number,
	to: number,
}

local MAX_DEPTH = 64
-- Parsing stops after this many closed item/entry elements: a hostile feed can't flood the store.
local MAX_ITEMS = 200
-- Previews keep three paragraphs at most, so long article bodies are cut before HTML stripping.
local PREVIEW_SOURCE_MAX = 16384
local PREVIEW_MAX = 600
local TITLE_FROM_PREVIEW = 80
-- Titles are cut to TITLE_SOURCE_MAX bytes before cleaning and TITLE_MAX characters after; ids and
-- links to ID_MAX bytes.
local TITLE_SOURCE_MAX = 4096
local TITLE_MAX = 300
local ID_MAX = 2048
-- A tag longer than this is skipped when reading attributes for feed links.
local TAG_MAX = 4096
-- feed.links reads only the start of a page.
local LINKS_SCAN_MAX = 512 * 1024

local BOM = "\239\187\191"

--------------------------------------------------------------------------------------------------
-- Text helpers

local ENTITIES: { [string]: string } = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	nbsp = " ",
	mdash = "—",
	ndash = "–",
	hellip = "…",
	lsquo = "‘",
	rsquo = "’",
	ldquo = "“",
	rdquo = "”",
	laquo = "«",
	raquo = "»",
	bull = "•",
	middot = "·",
	copy = "©",
	reg = "®",
	trade = "™",
	times = "×",
	eacute = "é",
	egrave = "è",
	agrave = "à",
	ccedil = "ç",
	uuml = "ü",
	ouml = "ö",
	auml = "ä",
}

-- Windows-1252 code points for bytes 0x80–0x9F (index = byte - 0x7F); nil marks the five undefined
-- slots, which keep their U+0080-range code point. Browsers decode latin-1 and numeric references
-- 128–159 through this same table.
local CP1252: { number? } = {
	0x20AC, nil, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, nil, 0x017D, nil,
	nil, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, nil, 0x017E, 0x0178,
}

local function cp1252(n: number): number
	if n >= 0x80 and n <= 0x9F then
		return CP1252[n - 0x7F] or n
	end
	return n
end

local function entity(ref: string): string?
	if string.byte(ref, 1) ~= 35 then -- not "#": named
		return ENTITIES[ref]
	end
	local second = string.sub(ref, 2, 2)
	local n = if second == "x" or second == "X"
		then tonumber(string.sub(ref, 3), 16)
		else tonumber(string.sub(ref, 2), 10)
	if n == nil or n < 1 or n > 0x10FFFF or n ~= math.floor(n) or (n >= 0xD800 and n <= 0xDFFF) then
		return nil -- left as is
	end
	if n == 160 then
		return " "
	end
	return utf8.char(cp1252(n))
end

local function decode_entities(s: string): string
	if not string.find(s, "&", 1, true) then
		return s
	end
	return (string.gsub(s, "&(#?%w+);", function(ref: string): string
		return entity(ref) or ("&" .. ref .. ";") -- unknown: left as is
	end))
end

-- Linear: a pattern like "^%s*(.-)%s*$" is quadratic on long whitespace runs.
local function trim(s: string): string
	local first = string.find(s, "%S")
	if first == nil then
		return ""
	end
	local last = #s
	while last > first do
		local b = string.byte(s, last)
		if b ~= 32 and (b < 9 or b > 13) then
			break
		end
		last -= 1
	end
	return string.sub(s, first, last)
end

-- `s` cut to at most `max` bytes without splitting a UTF-8 sequence.
local function cut(s: string, max: number): string
	if #s <= max then
		return s
	end
	local at = max
	while at > 1 and (string.byte(s, at + 1) or 0) >= 0x80 and (string.byte(s, at + 1) or 0) < 0xC0 do
		at -= 1 -- don't split a UTF-8 sequence
	end
	return string.sub(s, 1, at)
end

-- Whitespace runs (newlines included) become single spaces.
local function collapse(s: string): string
	return trim((string.gsub(s, "%s+", " ")))
end

-- Spaces/tabs collapsed, lines trimmed, at most one blank line in a row, trimmed.
local function tidy(s: string): string
	s = string.gsub(s, "\194\160", " ") -- U+00A0
	s = string.gsub(s, "\r\n?", "\n")
	s = string.gsub(s, "[ \t\f\v]+", " ")
	s = string.gsub(s, " ?\n ?", "\n")
	s = string.gsub(s, "\n\n\n+", "\n\n")
	return trim(s)
end

-- Paragraph-ending tags become blank lines so previews can be cut by paragraph.
local BREAKS: { { string } } = {
	{ "<[Bb][Rr]>", "\n" },
	{ "<[Bb][Rr][%s/][^>]*>", "\n" },
	{ "</[Pp]%s*>", "\n\n" },
	{ "</[Dd][Ii][Vv]%s*>", "\n" },
	{ "</[Ll][Ii]%s*>", "\n" },
	{ "</[Hh][1-6]%s*>", "\n\n" },
	{ "</[Bb][Ll][Oo][Cc][Kk][Qq][Uu][Oo][Tt][Ee]%s*>", "\n\n" },
	{ "</[Tt][Rr]%s*>", "\n" },
	{ "<[Ll][Ii]>", "• " },
	{ "<[Ll][Ii]%s[^>]*>", "• " },
}

-- `max` raises the source cap above the preview's, for callers that measure a whole page.
local function html_to_text(s: string, max: number?): string
	local limit = max or PREVIEW_SOURCE_MAX
	if #s > limit then
		s = cut(s, limit)
		s = string.gsub(s, "<[^>]*$", "") -- a tag cut in half
	end
	s = string.gsub(s, "<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", "")
	s = string.gsub(s, "<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]%s*>", "")
	for _, rule in BREAKS do
		s = string.gsub(s, rule[1], rule[2])
	end
	s = string.gsub(s, "<[^>]+>", "")
	return tidy(decode_entities(s))
end

-- `s` is already XML-decoded; html titles may still carry markup and HTML entities.
local function clean_title(s: string, html: boolean): string
	s = cut(s, TITLE_SOURCE_MAX)
	if html then
		s = string.gsub(s, "<[^>]+>", "")
	end
	return fmt.clip(collapse(decode_entities(s)), TITLE_MAX)
end

--------------------------------------------------------------------------------------------------
-- Tokenizer

local function decode_attrs(s: string, loose: boolean?): { [string]: string }
	local attrs: { [string]: string } = {}
	if not string.find(s, "=", 1, true) then
		return attrs
	end
	for name, _, value in string.gmatch(s, "([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
		if name and value then
			attrs[string.lower(name)] = decode_entities(value)
		end
	end
	if loose then -- HTML also allows unquoted values (rel=alternate type=application/rss+xml)
		local rest = string.gsub(s, "[%w_:%-%.]+%s*=%s*([\"']).-%1", " ")
		for name, value in string.gmatch(rest, "([%w_:%-%.]+)%s*=%s*([^%s\"'>]+)") do
			if name and value then
				local key = string.lower(name)
				if attrs[key] == nil then
					attrs[key] = decode_entities(value)
				end
			end
		end
	end
	return attrs
end

local function new_element(name: string, attrs: { [string]: string }, from: number): Element
	local lower = string.lower(name)
	return {
		name = lower,
		lname = string.match(lower, "[^:]*$") or lower,
		attrs = attrs,
		children = {},
		text = "",
		buf = {},
		from = from,
		to = from - 1,
	}
end

local function close(el: Element, to: number)
	el.text = table.concat(el.buf)
	table.clear(el.buf)
	el.to = to
end

-- Single-byte encodings declared in the XML declaration are widened byte for byte to UTF-8, with
-- 0x80–0x9F read as windows-1252 (as browsers do for latin-1 too).
local function to_utf8(body: string): string
	local encoding = string.match(string.sub(body, 1, 300), "^[^<]*<%?xml[^>]-encoding%s*=%s*[\"']([^\"']+)")
	if encoding == nil then
		return body
	end
	encoding = string.lower(encoding)
	if
		string.find(encoding, "iso%-8859%-1")
		or string.find(encoding, "latin%-?1")
		or string.find(encoding, "windows%-1252")
	then
		return (string.gsub(body, "[\128-\255]", function(c: string): string
			return utf8.char(cp1252(string.byte(c)))
		end))
	end
	return body
end

-- Longest tag name read; a longer one is text.
local NAME_MAX = 256

-- A forgiving XML tree: unknown close tags are ignored, unclosed elements end where an ancestor
-- closes (or at the end of input). Parsing stops after MAX_ITEMS closed item/entry elements.
-- Returns a synthetic document element and the (UTF-8) source. Linear on any input: names are read
-- from bounded slices and every ">" is searched for once.
local function parse_xml(source: string): (Element, string)
	local body = to_utf8(source)
	local n = #body
	local doc = new_element("#doc", {}, 1)
	local stack: { Element } = { doc }
	local pos = 1
	local last = n -- where elements still open at the end are closed
	local items = 0

	-- The first ">" at or after `from` (nil when none). `gt_at` is the first ">" after an earlier
	-- position, so it is still the answer whenever it is not before `from`.
	local gt_at = 0
	local function next_gt(from: number): number?
		if gt_at < from then
			gt_at = string.find(body, ">", from, true) or n + 1
		end
		return if gt_at <= n then gt_at else nil
	end

	local function finish(el: Element, to: number)
		close(el, to)
		if el.lname == "item" or el.lname == "entry" then
			items += 1
		end
	end

	while pos <= n do
		local top = stack[#stack]
		local lt = string.find(body, "<", pos, true)
		if lt == nil then
			table.insert(top.buf, decode_entities(string.sub(body, pos)))
			break
		end
		if lt > pos then
			table.insert(top.buf, decode_entities(string.sub(body, pos, lt - 1)))
		end
		local c = string.byte(body, lt + 1)
		if c == 33 then -- "<!"
			if string.sub(body, lt, lt + 8) == "<![CDATA[" then
				local stop = string.find(body, "]]>", lt + 9, true)
				table.insert(top.buf, string.sub(body, lt + 9, (stop or n + 1) - 1))
				pos = if stop then stop + 3 else n + 1
			elseif string.sub(body, lt, lt + 3) == "<!--" then
				local _, stop = string.find(body, "-->", lt + 4, true)
				pos = if stop then stop + 1 else n + 1
			else -- <!DOCTYPE …> with an optional [ internal subset ]
				local gt = next_gt(lt)
				if gt and string.find(string.sub(body, lt, gt), "[", 1, true) then
					local subset_end = string.find(body, "]", lt, true)
					gt = if subset_end then string.find(body, ">", subset_end, true) else nil
				end
				pos = if gt then gt + 1 else n + 1
			end
		elseif c == 63 then -- "<?"
			local _, stop = string.find(body, "?>", lt + 2, true)
			pos = if stop then stop + 1 else n + 1
		else
			local gt = next_gt(lt)
			if gt == nil then -- no tag can follow: the rest is text
				table.insert(top.buf, decode_entities(string.sub(body, lt)))
				break
			end
			if c == 47 then -- "</"
				local name =
					string.match(string.sub(body, lt, math.min(gt, lt + NAME_MAX + 2)), "^</%s*([^%s>]+)%s*>$")
				if name then
					local lname = string.lower(name)
					for i = #stack, 2, -1 do
						if stack[i].name == lname then
							for j = #stack, i, -1 do
								finish(stack[j], lt - 1)
								stack[j] = nil
							end
							break
						end
					end
					pos = gt + 1
				else
					table.insert(top.buf, "<")
					pos = lt + 1
				end
			else
				local name = string.match(string.sub(body, lt + 1, lt + NAME_MAX), "^[%a_][%w_:%-%.]*")
				if name and #name < NAME_MAX then
					local rest = string.sub(body, lt + 1 + #name, gt - 1)
					if #stack <= MAX_DEPTH then
						local el = new_element(name, decode_attrs(cut(rest, TAG_MAX)), gt + 1)
						table.insert(top.children, el)
						if string.byte(rest, -1) == 47 then -- "/>"
							finish(el, gt)
						else
							table.insert(stack, el)
						end
					end
					pos = gt + 1
				else -- a stray "<" in text
					table.insert(top.buf, "<")
					pos = lt + 1
				end
			end
			if items >= MAX_ITEMS then
				last = pos - 1
				break
			end
		end
	end
	for j = #stack, 1, -1 do
		close(stack[j], last)
	end
	return doc, body
end

--------------------------------------------------------------------------------------------------
-- Tree helpers

-- First child named `name`. A prefixed name ("content:encoded") matches only in full; a bare name
-- prefers an unprefixed child, else any child with that local name.
local function child(el: Element, name: string): Element?
	local prefixed = string.find(name, ":", 1, true) ~= nil
	local fallback: Element? = nil
	for _, c in el.children do
		if c.name == name then
			return c
		end
		if fallback == nil and not prefixed and c.lname == name then
			fallback = c
		end
	end
	return fallback
end

-- Trimmed direct text, cut to ID_MAX bytes (ids, links, dates and RSS titles come from here).
local function text_of(el: Element?): string
	return if el then cut(trim(el.text), ID_MAX) else ""
end

-- Inner markup of `el`: its text, or the raw source span (CDATA unwrapped; the first
-- PREVIEW_SOURCE_MAX bytes only) when markup was parsed into child elements.
local function inner(el: Element, body: string): string
	if #el.children == 0 then
		return el.text
	end
	local span = string.sub(body, el.from, math.min(el.to, el.from + PREVIEW_SOURCE_MAX - 1))
	return (string.gsub(span, "<!%[CDATA%[(.-)%]%]>", "%1"))
end

-- An Atom text construct and whether it holds HTML.
local function atom_text(el: Element, body: string): (string, boolean)
	local kind = string.lower(el.attrs.type or "text")
	if kind == "xhtml" then
		return inner(el, body), true
	end
	return el.text, string.find(kind, "html", 1, true) ~= nil
end

-- Atom link: rel="alternate" (text/html preferred), else the first link without rel.
local function atom_link(el: Element, base: string): string?
	local alternate: string? = nil
	local html: string? = nil
	local plain: string? = nil
	for _, c in el.children do
		local href = c.attrs.href
		if c.lname == "link" and href and trim(href) ~= "" then
			local rel = c.attrs.rel
			if rel == nil or trim(rel) == "" then
				plain = plain or trim(href)
			elseif string.lower(trim(rel)) == "alternate" then
				alternate = alternate or trim(href)
				if html == nil and string.lower(c.attrs.type or "") == "text/html" then
					html = trim(href)
				end
			end
		end
	end
	local href = html or alternate or plain
	return if href then url.resolve(base, cut(href, ID_MAX)) else nil
end

-- First RSS `link` with text (skips atom:link, whose text is empty).
local function rss_link(el: Element): string?
	for _, c in el.children do
		if c.lname == "link" then
			local t = trim(c.text)
			if t ~= "" then
				return cut(t, ID_MAX)
			end
		end
	end
	return nil
end

-- At most three paragraphs, clipped; nil when empty or just the title again.
local function finish_preview(text: string, title: string): string?
	if text == "" then
		return nil
	end
	local paragraphs: { string } = {}
	local pos = 1
	while #paragraphs < 3 do
		local s, e = string.find(text, "\n\n", pos, true)
		if s and e then
			table.insert(paragraphs, string.sub(text, pos, s - 1))
			pos = e + 1
		else
			table.insert(paragraphs, string.sub(text, pos))
			break
		end
	end
	local out = fmt.clip(table.concat(paragraphs, "\n\n"), PREVIEW_MAX)
	if out == "" or out == title then
		return nil
	end
	return out
end

local function fallback_title(title: string, preview: string): string
	if title ~= "" then
		return title
	end
	local from_preview = collapse(preview)
	if from_preview ~= "" then
		return fmt.clip(from_preview, TITLE_FROM_PREVIEW)
	end
	return "(untitled)"
end

local function rss_item(el: Element, body: string, base: string): ParsedItem
	local preview = ""
	local description = child(el, "description")
	if description then
		preview = html_to_text(inner(description, body))
	end
	if preview == "" then
		local encoded = child(el, "content:encoded")
		if encoded then
			preview = html_to_text(inner(encoded, body))
		end
	end
	local title = fallback_title(clean_title(text_of(child(el, "title")), false), preview)

	local link = rss_link(el)
	local guid_el = child(el, "guid")
	local guid = text_of(guid_el)
	if
		link == nil
		and guid_el
		and string.lower(guid_el.attrs.ispermalink or "") ~= "false"
		and string.find(guid, "^[Hh][Tt][Tt][Pp]")
	then
		link = guid
	end
	if link then
		link = url.resolve(base, link)
	end

	return {
		id = if guid ~= "" then guid else (link or title),
		title = title,
		link = link,
		preview = finish_preview(preview, title),
		published = feed.date(text_of(child(el, "pubdate"))) or feed.date(text_of(child(el, "dc:date"))),
	}
end

local function atom_entry(el: Element, body: string, base: string): ParsedItem
	local preview = ""
	for _, name in { "summary", "content" } do
		local part = child(el, name)
		if part and preview == "" then
			local text, html = atom_text(part, body)
			preview = if html then html_to_text(text) else tidy(decode_entities(text))
		end
	end
	local title = ""
	local title_el = child(el, "title")
	if title_el then
		local text, html = atom_text(title_el, body)
		title = clean_title(text, html)
	end
	title = fallback_title(title, preview)
	local link = atom_link(el, base)
	local id = text_of(child(el, "id"))

	return {
		id = if id ~= "" then id else (link or title),
		title = title,
		link = link,
		preview = finish_preview(preview, title),
		published = feed.date(text_of(child(el, "published"))) or feed.date(text_of(child(el, "updated"))),
	}
end

--------------------------------------------------------------------------------------------------
-- API

-- FNV-1a 32-bit as 8 lowercase hex chars. h * 16777619 is split as h * 2^24 + h * 403 so every
-- intermediate stays exact in a double.
function feed.hash(s: string): string
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	return string.format("%08x", h)
end

-- Whether a response is an HTML page (to look for a feed link in) rather than a feed. A body that
-- starts like XML or a feed wins over a `text/html` header (some servers mislabel their feeds).
function feed.is_html(body: string, content_type: string?): boolean
	local start = if string.sub(body, 1, 3) == BOM then 4 else 1
	local first = string.find(body, "%S", start)
	if first == nil then
		return false
	end
	local head = string.lower(string.sub(body, first, first + 13))
	if head == "<!doctype html" or string.sub(head, 1, 5) == "<html" then
		return true
	end
	if string.sub(head, 1, 5) == "<?xml" then
		-- XHTML pages may open with a prolog: skip it and any further PIs, comments and whitespace,
		-- then look again. Anything else after a prolog is XML (a feed or not), never HTML.
		local pos = first
		while true do
			local at = string.find(body, "%S", pos)
			if at == nil then
				return false
			end
			local stop: number? = nil
			if string.sub(body, at, at + 1) == "<?" then
				stop = select(2, string.find(body, "?>", at + 2, true))
			elseif string.sub(body, at, at + 3) == "<!--" then
				stop = select(2, string.find(body, "-->", at + 4, true))
			else
				head = string.lower(string.sub(body, at, at + 13))
				return head == "<!doctype html" or string.sub(head, 1, 5) == "<html"
			end
			if stop == nil then
				return false
			end
			pos = stop + 1
		end
	end
	if string.find(head, "^<rss[%s>]") or string.find(head, "^<feed[%s>]") or string.find(head, "^<rdf:") then
		return false
	end
	return content_type ~= nil and string.find(string.lower(content_type), "text/html", 1, true) ~= nil
end

local FEED_TYPES: { [string]: boolean } = {
	["application/rss+xml"] = true,
	["application/atom+xml"] = true,
	["application/rdf+xml"] = true,
}

-- Query values that select a feed on WordPress-style sites (?feed=rss2, ?feed=atom).
local FEED_QUERY: { [string]: boolean } = { rss = true, rss2 = true, atom = true, rdf = true }

-- Whether a lowercased href looks like a feed address (not a sitemap or a feedback page).
local function feedlike(href: string): boolean
	local path = string.match(href, "^[^?#]*") or href
	if string.find(path, "sitemap", 1, true) then
		return false
	end
	local query = string.match(href, "^[^?#]*%?([^#]*)")
	if query then
		local value = string.match("&" .. query, "&feed=([^&]*)")
		if value and FEED_QUERY[value] then
			return true
		end
	end
	return string.find(path, "rss", 1, true) ~= nil
		or string.find(path, "atom%.xml$") ~= nil
		or string.find(path, "/atom/?$") ~= nil
		or string.find(path, "%.atom$") ~= nil
		or string.find(path, "/feed/?$") ~= nil
		or string.find(path, "/feeds/", 1, true) ~= nil
		or string.find(path, "feed%.xml$") ~= nil
		or string.find(path, "/index%.xml$") ~= nil
		or string.find(href, "feedburner", 1, true) ~= nil
end

-- Plain anchors read for feed-looking links, at most.
local MAX_ANCHOR_LINKS = 4

-- The `<name …>` tags of `html` (`name` lowercase, matched case-insensitively and followed by
-- whitespace). Tags of TAG_MAX bytes or more are skipped. Linear: every ">" is searched for once.
local function tags(html: string, name: string): { string }
	local out: { string } = {}
	local n = #html
	local len = #name
	local pos = 1
	local gt_at = 0 -- the first ">" after an earlier "<": still the next one while not before it
	while true do
		local lt = string.find(html, "<", pos, true)
		if lt == nil then
			break
		end
		pos = lt + 1
		if string.lower(string.sub(html, lt + 1, lt + len)) == name and string.find(html, "^%s", lt + len + 1) then
			if gt_at < lt then
				gt_at = string.find(html, ">", lt, true) or n + 1
			end
			if gt_at > n then
				break
			end
			if gt_at - lt < TAG_MAX then
				table.insert(out, string.sub(html, lt, gt_at))
			end
			pos = gt_at + 1
		end
	end
	return out
end

-- Feed addresses an HTML page points at, best first: its <link rel="alternate"> RSS/Atom/RDF links,
-- then <a href> links that look like feeds. Resolved against `base`, without duplicates. Only the
-- first LINKS_SCAN_MAX bytes of the page are read.
function feed.links(page: string, base: string): { string }
	local html = cut(page, LINKS_SCAN_MAX)
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(href: string)
		local u = url.resolve(base, href)
		if not seen[u] then
			seen[u] = true
			table.insert(out, u)
		end
	end
	for _, tag in tags(html, "link") do
		local attrs = decode_attrs(tag, true)
		local rel = string.lower(attrs.rel or "")
		local kind = string.match(string.lower(attrs.type or ""), "^%s*([^;%s]+)") or ""
		local href = trim(attrs.href or "")
		if string.find(rel, "alternate", 1, true) and FEED_TYPES[kind] and href ~= "" then
			add(href)
		end
	end
	local anchors = 0
	for _, tag in tags(html, "a") do
		if anchors >= MAX_ANCHOR_LINKS then
			break
		end
		local href = trim(decode_attrs(tag, true).href or "")
		local lower = string.lower(href)
		local scheme = string.match(lower, "^(%a[%w+.-]*):")
		if href ~= "" and (scheme == nil or scheme == "http" or scheme == "https") and feedlike(lower) then
			add(href)
			anchors += 1
		end
	end
	return out
end

-- Paths sites usually serve their feed at.
local USUAL_PATHS = { "/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml" }

-- Feed addresses to try for `page` without reading it, best first: known platforms' feed URLs
-- (YouTube, Reddit, GitHub, Medium, Bluesky, Mastodon-style @profiles), then the usual paths at the
-- site root and under the page's own path. Never includes `page` itself.
function feed.guesses(page: string): { string }
	local scheme, host, path = string.match(page, "^(https?)://([^/?#]+)([^?#]*)")
	if scheme == nil or host == nil or path == nil then
		return {}
	end
	local origin = scheme .. "://" .. host
	local h = string.lower(host)
	h = string.gsub(h, ":%d+$", "")
	h = string.gsub(h, "^www%.", "")
	local p = string.gsub(path, "/+$", "")

	local out: { string } = {}
	local seen: { [string]: boolean } = { [page] = true }
	local function add(u: string)
		if not seen[u] then
			seen[u] = true
			table.insert(out, u)
		end
	end

	if h == "youtube.com" or h == "m.youtube.com" then
		local channel = string.match(p, "^/channel/(UC[%w_%-]+)")
		if channel then
			add("https://www.youtube.com/feeds/videos.xml?channel_id=" .. channel)
		end
		local list = string.match(page, "[?&]list=([%w_%-]+)")
		if list then
			add("https://www.youtube.com/feeds/videos.xml?playlist_id=" .. list)
		end
	elseif h == "reddit.com" or h == "old.reddit.com" or h == "new.reddit.com" then
		local sub = string.match(p, "^(/r/[^/]+)") or string.match(p, "^(/u/[^/]+)") or string.match(p, "^(/user/[^/]+)")
		if sub then
			add("https://www.reddit.com" .. sub .. "/.rss")
		end
	elseif h == "github.com" then
		local owner, repo = string.match(p, "^/([^/]+)/([^/]+)")
		if owner and repo then
			add("https://github.com/" .. owner .. "/" .. repo .. "/releases.atom")
			add("https://github.com/" .. owner .. "/" .. repo .. "/commits.atom")
		else
			local user = string.match(p, "^/([^/]+)$")
			if user then
				add("https://github.com/" .. user .. ".atom")
			end
		end
	elseif h == "medium.com" then
		local name = string.match(p, "^/([^/]+)")
		if name then
			add("https://medium.com/feed/" .. name)
		end
	elseif string.find(h, "%.medium%.com$") then
		add(origin .. "/feed")
	elseif h == "bsky.app" then
		local handle = string.match(p, "^/profile/([^/]+)")
		if handle then
			add("https://bsky.app/profile/" .. handle .. "/rss")
		end
	end
	if h ~= "medium.com" and string.find(p, "^/@[%w_%.%-]+$") then
		add(origin .. p .. ".rss")
	end

	for _, name in USUAL_PATHS do
		add(origin .. name)
	end
	if p ~= "" then
		for _, name in USUAL_PATHS do
			add(origin .. p .. name)
		end
	end
	return out
end

-- Parses an RSS 2.0, RSS 1.0 or Atom document; links resolve against `base`. nil, "not_feed" when the
-- root element is none of rss, rdf:RDF or feed.
function feed.parse(body: string, base: string): (Parsed?, string?)
	local doc, source = parse_xml(body)
	local root: Element? = nil
	for _, c in doc.children do
		if c.lname == "rss" or c.lname == "rdf" or c.lname == "feed" then
			root = c
			break
		end
	end
	if root == nil then
		return nil, "not_feed"
	end

	local items: { ParsedItem } = {}
	local title = ""
	local site: string? = nil
	if root.lname == "feed" then
		local title_el = child(root, "title")
		if title_el then
			local text, html = atom_text(title_el, source)
			title = clean_title(text, html)
		end
		site = atom_link(root, base)
		for _, c in root.children do
			if c.lname == "entry" then
				table.insert(items, atom_entry(c, source, base))
			end
		end
	else
		local channel = child(root, "channel")
		local container = if root.lname == "rss" then channel else root
		if container == nil then
			return nil, "not_feed"
		end
		if channel then
			title = clean_title(text_of(child(channel, "title")), false)
			local link = rss_link(channel)
			site = if link then url.resolve(base, link) else nil
		end
		for _, c in container.children do
			if c.lname == "item" then
				table.insert(items, rss_item(c, source, base))
			end
		end
	end

	return { title = if title ~= "" then title else nil, site = site, items = items }, nil
end

local MONTHS: { [string]: number } = {
	jan = 1,
	feb = 2,
	mar = 3,
	apr = 4,
	may = 5,
	jun = 6,
	jul = 7,
	aug = 8,
	sep = 9,
	oct = 10,
	nov = 11,
	dec = 12,
}

-- Hours east of UTC.
local ZONES: { [string]: number } = {
	gmt = 0,
	ut = 0,
	utc = 0,
	z = 0,
	est = -5,
	edt = -4,
	cst = -6,
	cdt = -5,
	mst = -7,
	mdt = -6,
	pst = -8,
	pdt = -7,
}

local function num(s: string?): number
	return tonumber(s) or 0
end

-- Dates before 1970 (Go's zero time 0001-01-01 included) count as unknown: os.date can't format them.
local function after_epoch(t: number): number?
	return if t >= 0 then t else nil
end

-- Longest date string read; real dates are far shorter.
local DATE_MAX = 128

-- Epoch seconds of an RFC 822 (RSS) or ISO 8601 (Atom, dc:date) date; nil when unrecognized or
-- before 1970.
function feed.date(s: string): number?
	if s == "" then
		return nil
	end
	s = string.sub(s, 1, DATE_MAX)

	-- ISO 8601: 2026-10-07T16:44:34-04:00, …Z, …+0000, fractions allowed, or a date alone.
	local _, stop, y, mo, d, hh, mi, ss = string.find(s, "^%s*(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):?(%d*)")
	if stop then
		local month, day = num(mo), num(d)
		if month < 1 or month > 12 or day < 1 or day > 31 then
			return nil
		end
		local rest = string.gsub(string.sub(s, stop + 1), "^[%.,]%d+", "")
		local offset = 0
		local sign, oh, om = string.match(rest, "^%s*([%+%-])(%d%d):?(%d?%d?)")
		if sign then
			offset = (num(oh) * 3600 + num(om) * 60) * (if sign == "-" then -1 else 1)
		end
		return after_epoch(fmt.utc(num(y), month, day, num(hh), num(mi), num(ss)) - offset)
	end
	local dy, dm, dd = string.match(s, "^%s*(%d%d%d%d)-(%d%d)-(%d%d)")
	if dy then
		local month, day = num(dm), num(dd)
		if month < 1 or month > 12 or day < 1 or day > 31 then
			return nil
		end
		return after_epoch(fmt.utc(num(dy), month, day, 0, 0, 0))
	end

	-- RFC 822: Wed, 07 Oct 2026 19:53:17 +0000 / … +05:30 / … GMT / … EDT, two-digit years allowed.
	local rd, rmon, ry, rh, rmi, rs, zone =
		string.match(s, "(%d%d?)%s+(%a%a%a)%a*%s+(%d+)%s+(%d%d?):(%d%d):?(%d*)%s*([%w%+%-:]*)")
	if rd == nil or rmon == nil then
		return nil
	end
	local month = MONTHS[string.lower(rmon)]
	if month == nil then
		return nil
	end
	local year = num(ry)
	if year < 100 then
		year += if year < 70 then 2000 else 1900
	end
	local offset = 0
	local zsign, zh, zm = string.match(zone or "", "^([%+%-])(%d%d):?(%d?%d?)")
	if zsign then
		offset = (num(zh) * 3600 + num(zm) * 60) * (if zsign == "-" then -1 else 1)
	else
		offset = (ZONES[string.lower(zone or "")] or 0) * 3600
	end
	return after_epoch(fmt.utc(year, month, num(rd), num(rh), num(rmi), num(rs)) - offset)
end

--------------------------------------------------------------------------------------------------
-- Article extraction (the native reader)
--
-- Turns an HTML page into interleaved Markdown and image blocks a reader block draws in order.
-- This is deliberately not a readability algorithm -- it takes the container with the most
-- paragraph text and walks its tags. A page that defeats it falls back to Tern's browser, which
-- is why this runs best-effort.

-- One block of the article, in document order: a run of text drawn as Markdown, or one image.
export type ArticleBlock = {
	-- "md" draws `text` with the view's Markdown renderer; "img" draws `src`.
	kind: "md" | "img",
	text: string?,
	src: string?,
	alt: string?,
	-- Natural width and height from the <img> attributes, when declared: the view sizes the
	-- image from them instead of jumping when the bytes arrive.
	w: number?,
	h: number?,
}
export type Article = { blocks: { ArticleBlock }, text: string }

-- The largest HTML prefix the extractor reads; beyond it the browser is the honest answer.
local ARTICLE_SOURCE_MAX = 1_500_000
-- Beyond this many characters of extracted text the article is truncated (about 40 screens).
local ARTICLE_TEXT_MAX = 120_000
-- At most this many images ship with one article.
local ARTICLE_IMAGES_MAX = 12

-- The container the reader reads, named by tag: the semantic one (`article`, `main`, …) with the
-- longest text, and `body` only when none has a readable amount. Body always holds at least as
-- much text as anything inside it, so measured against the rest it would win on every page with a
-- nav bar or a footer. Tags are found in a lowercased copy (same byte offsets) so `<ARTICLE>`
-- counts, and every candidate is measured over the whole page, not the preview's first 16 KB.
local function article_container(html: string): (string, string, string)
	local lower = string.lower(html)
	local function measure(kind: string): (string?, string?)
		local open = string.find(lower, "<" .. kind .. "[%s>/]")
		if open == nil then
			return nil, nil
		end
		local gt = string.find(html, ">", open, true) or open
		local close = string.find(lower, "</" .. kind .. ">", gt, true)
		local inner = string.sub(html, gt + 1, if close then close - 1 else #html)
		return inner, html_to_text(inner, ARTICLE_SOURCE_MAX)
	end
	local best_kind, best_src, best_text = "body", html, ""
	for _, kind in { "article", "main", "content", "post" } do
		local inner, text = measure(kind)
		if inner and text and #text > #best_text and #text > 400 then
			best_kind, best_src, best_text = kind, inner, text
		end
	end
	if best_text == "" then
		local inner, text = measure("body")
		if inner and text and #text > 400 then
			best_src, best_text = inner, text
		end
	end
	return best_kind, best_src, best_text
end

-- `s` as literal Markdown text: page prose is data, not markup. Without this "$5 or $10" typesets
-- as math and a printed `[x](tern-rss://read/…)` becomes a clickable route link. Backslash escapes
-- cover the metacharacters ui.md's dialect reads; the structure this file adds (`#`, `- `) is
-- written after escaping, so it stays live. Only `[` is escaped, never `]`: the dialect reads
-- `\[…\]` as display math, so an escaped pair would typeset the text between.
local function md_escape(s: string): string
	s = string.gsub(s, "[\\`*_%[<>#|~$]", "\\%0")
	-- A decoded "&amp;lt;" must not read as an entity again.
	s = string.gsub(s, "&(#?%w+;)", "\\&%1")
	-- Bare URLs autolink; this plugin's own route scheme must not be printable as a link.
	s = string.gsub(s, "([Tt][Ee][Rr][Nn]%-[Rr][Ss][Ss]:)//", "%1\\//")
	return s
end

-- Tag names that break a text run, and what they leave behind. `<br>` and `<li>` key their opening
-- form, the rest their closing form.
local BREAKS_HTML: { [string]: string } = {
	["<br"] = "\n",
	["</p"] = "\n\n",
	["</div"] = "\n",
	["</li"] = "\n",
	["</ul"] = "\n\n",
	["</ol"] = "\n\n",
	["</h1"] = "\n\n",
	["</h2"] = "\n\n",
	["</h3"] = "\n\n",
	["</h4"] = "\n\n",
	["</h5"] = "\n\n",
	["</h6"] = "\n\n",
	["</blockquote"] = "\n\n",
	["</tr"] = "\n",
}

-- The article in `body` (an HTML page), read for the native reader: the container's content as
-- interleaved Markdown and image blocks, in document order, plus the whole text for the "is there
-- anything here" check. `blocks` is empty when nothing useful came out, and the caller falls back
-- to the browser. The walk is the preview's html_to_text with two differences: <img> becomes an
-- image block instead of vanishing, and headings become Markdown `#` lines so ui.md draws the
-- structure. Linear: every "<" and ">" is searched for once.
function feed.article(body: string, base: string): Article
	local html = if #body > ARTICLE_SOURCE_MAX then string.sub(body, 1, ARTICLE_SOURCE_MAX) else body
	local _kind, inner = article_container(html)
	if inner == "" then
		return { blocks = {}, text = "" }
	end
	-- Lowercased once: tag names are matched here, and a copy per <script> was quadratic.
	local lower = string.lower(inner)
	local blocks: { ArticleBlock } = {}
	local buf: { string } = {}
	local images = 0
	-- Markdown bytes flushed so far; the walk stops once the article is past the cap.
	local total = 0

	local function flush()
		local md = tidy(table.concat(buf))
		buf = {}
		if md ~= "" then
			total += #md
			table.insert(blocks, { kind = "md", text = md })
		end
	end

	local function add_text(s: string)
		table.insert(buf, md_escape(decode_entities(s)))
	end

	local pos = 1
	while total <= ARTICLE_TEXT_MAX do
		local lt = string.find(inner, "<", pos, true)
		if lt == nil then
			add_text(string.sub(inner, pos))
			break
		end
		if lt > pos then
			add_text(string.sub(inner, pos, lt - 1))
		end
		local gt = string.find(inner, ">", lt, true)
		if gt == nil then -- a half tag at the source cap: the rest is text
			add_text(string.sub(inner, lt))
			break
		end
		pos = gt + 1
		local raw = string.sub(inner, lt + 1, gt - 1)
		-- Both captures matter: the slash (a closing tag) and the name. The name takes digits too:
		-- `h1`-`h6` never matched as letters only, so no heading was ever drawn as one.
		local slash, bare = string.match(string.lower(raw), "^%s*(/?)%s*([%w%-]+)")
		if bare == nil then
			continue
		end
		local closing = slash == "/"
		if not closing and (bare == "script" or bare == "style") then
			-- Skip to the end of the closing tag; a cut that lands inside it (or no closing tag at
			-- all) ends the walk or resumes after the opening tag, never past the source.
			local close = string.find(lower, "</" .. bare, gt, true)
			if close then
				local close_gt = string.find(inner, ">", close, true)
				pos = if close_gt then close_gt + 1 else #inner + 1
			end
		elseif bare == "img" and not closing then
			images += 1
			if images <= ARTICLE_IMAGES_MAX then
				local attrs = decode_attrs("<" .. raw .. ">", true)
				local src = trim(attrs.src or "")
				-- Only absolute http(s) without whitespace is fetchable: `javascript:`, `data:` and
				-- friends would each raise in tern.fetch.
				local abs = if src ~= "" then url.resolve(base, src) else ""
				if string.find(abs, "^[hH][tT][tT][pP][sS]?://[^%s/?#]") and not string.find(abs, "%s") then
					flush()
					table.insert(blocks, {
						kind = "img",
						src = abs,
						alt = collapse(attrs.alt or ""),
						w = tonumber(attrs.width),
						h = tonumber(attrs.height),
					})
				end
			end
		else
			local left = BREAKS_HTML["<" .. bare]
			local right = BREAKS_HTML["</" .. bare]
			if bare == "li" then
				-- A list item is Markdown's "- ", on its own line, so ui.md draws a real list.
				if not closing then
					table.insert(buf, "\n- ")
				end
			elseif not closing and left then
				table.insert(buf, left)
			elseif closing and right then
				flush()
				table.insert(buf, right)
			elseif not closing and string.match(bare, "^h[1-6]$") then
				flush()
				table.insert(buf, string.rep("#", tonumber(string.sub(bare, 2, 2)) :: number) .. " ")
			end
		end
	end
	flush()

	-- The cap applies to what ships, blocks and text alike: cut the block that crosses it and drop
	-- the rest.
	local text_parts: { string } = {}
	local used = 0
	for i, b in blocks do
		local part = if b.kind == "md" then (b.text :: string) else (b.alt or "image")
		if used + #part > ARTICLE_TEXT_MAX then
			if b.kind == "md" then
				part = cut(part, math.max(0, ARTICLE_TEXT_MAX - used)) .. "\n\n\u{2026}"
				b.text = part
				table.insert(text_parts, part)
				for j = #blocks, i + 1, -1 do
					table.remove(blocks, j)
				end
			else
				for j = #blocks, i, -1 do
					table.remove(blocks, j)
				end
			end
			break
		end
		used += #part
		table.insert(text_parts, part)
	end
	return { blocks = blocks, text = table.concat(text_parts, "\n") }
end

return feed
