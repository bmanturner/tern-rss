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
	-- A sequence is at most 4 bytes, so at most 3 continuation bytes are backed over: a run of
	-- stray continuation bytes (not UTF-8 at all) must not walk the cut back to the start.
	for _ = 1, 3 do
		local b = string.byte(s, at + 1) or 0
		if at <= 1 or b < 0x80 or b >= 0xC0 then
			break
		end
		at -= 1
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

-- Longest tag name the HTML scanner reads; a longer one is no tag it knows.
local HTML_NAME_MAX = 32

-- The HTML scanner behind previews, titles and the reader: calls `on_text(from, to)` for each run
-- of text and `on_tag(name, closing, lt, gt)` for each tag (`name` lowercase; `lt`/`gt` the
-- positions of its "<" and ">"). A callback that returns true (text) or a position (tag) ends the
-- walk or resumes it there. <script>/<style> bodies and comments are skipped here, and an
-- unclosed one ends the document, as it does in a browser. `lower` is `s` lowercased (same
-- offsets), `truncated` says `s` was cut mid-document, so a half tag at the end is dropped.
--
-- Linear on any input: the cursor only moves forward and every search (plain find or a pattern
-- without backtracking) starts at it, so a page of "<" or of unclosed <script> costs no more than
-- a page of text. This replaces gsub patterns like "<[^>]+>" and "<script.-</script>", which
-- rescan to the end of the input from every "<".
local function walk(
	s: string,
	lower: string,
	truncated: boolean,
	on_text: (from: number, to: number) -> boolean?,
	on_tag: (name: string, closing: boolean, lt: number, gt: number) -> number?
)
	local n = #s
	local text_from = 1
	local pos = 1
	while true do
		-- A "<" only opens a tag before a letter, "/", "!" or "?": "a < b" is text.
		local lt = string.find(s, "<[%a/!?]", pos)
		if lt == nil then
			if text_from <= n then
				on_text(text_from, n)
			end
			return
		end
		if lt > text_from and on_text(text_from, lt - 1) then
			return
		end
		text_from = lt
		if string.sub(s, lt, lt + 3) == "<!--" then
			local close = string.find(s, "-->", lt + 4, true)
			if close == nil then
				return
			end
			text_from = close + 3
			pos = text_from
			continue
		end
		local gt = string.find(s, ">", lt + 1, true)
		if gt == nil then
			if not truncated then
				on_text(lt, n)
			end
			return
		end
		text_from = gt + 1
		pos = text_from
		local _, _, slash, name = string.find(lower, "^(/?)([%w%-]*)", lt + 1)
		if name == nil or name == "" or #name > HTML_NAME_MAX then
			continue -- <!doctype>, <?xml?>, a stray "</>", a name no tag has
		end
		if slash == "" and (name == "script" or name == "style") then
			local close = string.find(lower, "</" .. name, gt + 1, true)
			local close_gt = if close then string.find(s, ">", close, true) else nil
			if close_gt == nil then
				return
			end
			text_from = close_gt + 1
			pos = text_from
			continue
		end
		local jump = on_tag(name, slash == "/", lt, gt)
		if jump then
			text_from = jump
			pos = jump
		end
	end
end

-- What an opening or closing tag leaves behind in a preview, so it can be cut by paragraph.
local PREVIEW_OPEN: { [string]: string } = { br = "\n", p = "\n\n", li = "• " }
local PREVIEW_CLOSE: { [string]: string } = {
	p = "\n\n",
	div = "\n",
	li = "\n",
	h1 = "\n\n",
	h2 = "\n\n",
	h3 = "\n\n",
	h4 = "\n\n",
	h5 = "\n\n",
	h6 = "\n\n",
	blockquote = "\n\n",
	tr = "\n",
}

-- Plain text of an HTML fragment, cut to PREVIEW_SOURCE_MAX bytes first.
local function html_to_text(s: string): string
	local truncated = #s > PREVIEW_SOURCE_MAX
	if truncated then
		s = cut(s, PREVIEW_SOURCE_MAX)
	end
	local buf: { string } = {}
	-- Right after a bullet: the item's own leading whitespace (pretty-printed markup) goes.
	local lead = false
	walk(s, string.lower(s), truncated, function(from: number, to: number): boolean?
		local text = string.sub(s, from, to)
		if lead then
			local first = string.find(text, "%S")
			if first == nil then
				return nil
			end
			text = string.sub(text, first)
			lead = false
		end
		table.insert(buf, text)
		return nil
	end, function(name: string, closing: boolean): number?
		local mark = if closing then PREVIEW_CLOSE[name] else PREVIEW_OPEN[name]
		if mark then
			table.insert(buf, mark)
			lead = name == "li" and not closing
		end
		return nil
	end)
	return tidy(decode_entities(table.concat(buf)))
end

-- `s` without its tags (no breaks), for titles.
local function strip_tags(s: string): string
	local buf: { string } = {}
	walk(s, string.lower(s), false, function(from: number, to: number): boolean?
		table.insert(buf, string.sub(s, from, to))
		return nil
	end, function(): number?
		return nil
	end)
	return table.concat(buf)
end

-- `s` is already XML-decoded; html titles may still carry markup and HTML entities.
local function clean_title(s: string, html: boolean): string
	s = cut(s, TITLE_SOURCE_MAX)
	if html then
		s = strip_tags(s)
	end
	return fmt.clip(collapse(decode_entities(s)), TITLE_MAX)
end

--------------------------------------------------------------------------------------------------
-- Tokenizer

-- `name="value"` pairs of a tag's source, names lowercased and values entity-decoded; `loose` also
-- reads unquoted values (rel=alternate type=application/rss+xml). One forward pass: each search is
-- anchored at the cursor, so a long run of name characters is read once, not once per start.
local function decode_attrs(s: string, loose: boolean?): { [string]: string }
	local attrs: { [string]: string } = {}
	if not string.find(s, "=", 1, true) then
		return attrs
	end
	local pos = 1
	while true do
		local name_from, name_to = string.find(s, "[%w_:%-%.]+", pos)
		if name_from == nil then
			break
		end
		local _, eq_to = string.find(s, "^%s*=%s*", name_to + 1)
		if eq_to == nil then
			pos = name_to + 1
			continue
		end
		local key = string.lower(string.sub(s, name_from, name_to))
		local quote = string.sub(s, eq_to + 1, eq_to + 1)
		if quote == '"' or quote == "'" then
			local close = string.find(s, quote, eq_to + 2, true)
			if close == nil then
				break
			end
			attrs[key] = decode_entities(string.sub(s, eq_to + 2, close - 1))
			pos = close + 1
		else
			local _, value_to = string.find(s, "^[^%s\"'>]+", eq_to + 1)
			if value_to == nil then
				pos = eq_to + 1
				continue
			end
			if loose and attrs[key] == nil then
				attrs[key] = decode_entities(string.sub(s, eq_to + 1, value_to))
			end
			pos = value_to + 1
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
-- Page text read per run and queued per block, before escaping: a megabyte of one paragraph is
-- never all shipped, so it is never all processed.
local READ_MAX = 2 * ARTICLE_TEXT_MAX
-- At most this many images ship with one article.
local ARTICLE_IMAGES_MAX = 12
-- Less text than this and the page counts as unreadable: the reader hands it to the browser.
local ARTICLE_MIN_TEXT = 400
-- A <pre> block keeps at most this many source bytes.
local PRE_MAX = 60_000
-- Declared image sizes are clamped to 1..this.
local IMAGE_DIM_MAX = 10_000
-- Bytes of a page that aren't UTF-8 are repaired one by one up to this many; past it the page is
-- plainly not UTF-8 and the rest is widened wholesale.
local REPAIR_MAX = 5000

-- Single bytes 0x80-0xFF as the UTF-8 of their windows-1252 character, for gsub.
local WIDE: { [string]: string } = {}
for byte = 0x80, 0xFF do
	WIDE[string.char(byte)] = utf8.char(cp1252(byte))
end
-- Charset names (lowercase, without "-" and "_") read as windows-1252, like browsers read latin-1.
local LATIN1: { [string]: boolean } = { iso88591 = true, latin1 = true, l1 = true, windows1252 = true, cp1252 = true }

-- The charset a page declares: the Content-Type header's, else a <meta> in the first 2 KB.
local function page_charset(body: string, content_type: string?): string?
	local name = string.match(string.lower(content_type or ""), "charset%s*=%s*[\"']?([%w_%-]+)")
	if name == nil then
		local head = string.lower(string.sub(body, 1, 2048))
		name = string.match(head, "<meta[^>]-charset%s*=%s*[\"']?([%w_%-]+)")
	end
	if name == nil then
		return nil
	end
	return (string.gsub(name, "[%-_]", ""))
end

-- `body` as valid UTF-8, which the view needs (Tern raises on anything else): a latin-1 or
-- windows-1252 page is widened through the cp1252 table, and any other bytes that aren't UTF-8
-- (a charset this plugin has no table for) are mapped the same way, so the page stays readable
-- instead of failing every render.
local function page_utf8(body: string, content_type: string?): string
	local charset = page_charset(body, content_type)
	if charset and LATIN1[charset] then
		return (string.gsub(body, "[\128-\255]", WIDE))
	end
	if utf8.len(body) then
		return body
	end
	local out: { string } = {}
	local from = 1
	local fixes = 0
	while true do
		local ok, bad = utf8.len(body, from)
		if ok then
			table.insert(out, string.sub(body, from))
			break
		end
		table.insert(out, string.sub(body, from, (bad :: number) - 1))
		fixes += 1
		if fixes > REPAIR_MAX then
			table.insert(out, (string.gsub(string.sub(body, bad :: number), "[\128-\255]", WIDE)))
			break
		end
		table.insert(out, WIDE[string.sub(body, bad :: number, bad :: number)])
		from = (bad :: number) + 1
	end
	return table.concat(out)
end

type Span = { from: number, cum: number, depth: number, closed: boolean, to: number, len: number }

-- The container the reader reads, named by tag: `article` or `main` with the most text, and `body`
-- only when neither has a readable amount. Body always holds at least as much text as anything
-- inside it, so measured against the rest it would win on every page with a nav bar or a footer.
-- One scan measures them all: text bytes seen so far at each tag, and a container ends at the
-- close tag that matches its open (a nested `<article>`, as comments and embeds use, doesn't end
-- it). Only the first container of each kind counts. Whitespace-only runs don't count as text.
-- Returns the kind and the container's source.
local function article_container(html: string, lower: string): (string, string)
	local spans: { [string]: Span } = {}
	local seen = 0
	walk(html, lower, false, function(from: number, to: number): boolean?
		local first = string.find(html, "%S", from)
		if first and first <= to then
			seen += to - first + 1
		end
		return nil
	end, function(name: string, closing: boolean, lt: number, gt: number): number?
		if name ~= "article" and name ~= "main" and name ~= "body" then
			return nil
		end
		local span = spans[name]
		if not closing then
			if span == nil then
				spans[name] = { from = gt + 1, cum = seen, depth = 1, closed = false, to = #html, len = 0 }
			elseif not span.closed then
				span.depth += 1
			end
		elseif span and not span.closed then
			span.depth -= 1
			if span.depth == 0 then
				span.closed = true
				span.to = lt - 1
				span.len = seen - span.cum
			end
		end
		return nil
	end)
	for _, span in spans do
		if not span.closed then
			span.len = seen - span.cum
		end
	end
	local best_kind = "body"
	local best: Span? = nil
	for _, kind in { "article", "main" } do
		local span = spans[kind]
		if span and span.len > ARTICLE_MIN_TEXT and (best == nil or span.len > best.len) then
			best_kind, best = kind, span
		end
	end
	if best == nil then
		local body = spans.body
		if body and body.len > ARTICLE_MIN_TEXT then
			best = body
		end
	end
	if best == nil then
		return "body", html
	end
	return best_kind, string.sub(html, best.from, best.to)
end

-- `s` as literal Markdown text: page prose is data, not markup. Without this "$5 or $10" typesets
-- as math and a printed `[x](tern-rss://read/…)` becomes a clickable route link. Backslash escapes
-- cover the metacharacters ui.md's dialect reads inside a line; what only means something at the
-- start of a line (`-`, `1.`, `===`) is escaped once the lines are known (finish_md), and the
-- structure this file adds (`#`, `- `, `> `) is written after that, so it stays live. Only `[` is
-- escaped, never `]`: the dialect reads `\[…\]` as display math, so an escaped pair would
-- typeset the text between.
local function md_escape(s: string): string
	s = string.gsub(s, "[\\`*_%[<>#|~$]", "\\%0")
	-- A decoded "&amp;lt;" must not read as an entity again.
	s = string.gsub(s, "&(#?%w+;)", "\\&%1")
	return s
end

-- Structure markers the walk writes into the text before it is tidied, as control bytes that page
-- text can't carry (it is stripped of them): \1 a bullet, \2<n>\3 a numbered item, \4<n>\3 a
-- heading of that level, \5 before a newline a hard break. `finish_md` turns them into Markdown.

-- Prefixes every line of `text` with the blockquote marker.
local function quote_lines(text: string): string
	local out: { string } = {}
	local at = 1
	local n = #text
	while at <= n + 1 do
		local nl = string.find(text, "\n", at, true) or n + 1
		local line = string.sub(text, at, nl - 1)
		table.insert(out, if line == "" then ">" else "> " .. line)
		at = nl + 1
	end
	return table.concat(out, "\n")
end

-- Tidied text carrying the walk's markers, as Markdown: markers resolved, text at the start of a
-- line that would read as a list, rule or heading underline escaped (`- x`, `+ x`, `2024. x`,
-- `---`, `===`), this plugin's route scheme made unprintable as a link (on the joined text, so
-- tags between its letters don't hide it), and blockquote lines prefixed when `quoted`.
local function finish_md(text: string, quoted: boolean): string
	if not string.find(text, "%S") then
		return ""
	end
	text = string.gsub(text, "([Tt][Ee][Rr][Nn]%-[Rr][Ss][Ss]:)//", "%1\\//")
	text = string.gsub(text, "\5\n([^\n])", "  \n%1")
	text = string.gsub(text, "\5", "")
	local out: { string } = {}
	local at = 1
	local n = #text
	while at <= n + 1 do
		local nl = string.find(text, "\n", at, true) or n + 1
		local line = string.sub(text, at, nl - 1)
		at = nl + 1
		local prefix = ""
		local mark = string.byte(line, 1)
		if mark == 1 then
			prefix, line = "- ", string.sub(line, 2)
		elseif mark == 2 or mark == 4 then
			local num, rest = string.match(line, "^[\2\4](%d+)\3(.*)$")
			if num then
				prefix = if mark == 2 then num .. ". " else string.rep("#", tonumber(num) :: number) .. " "
				line = rest
			end
		end
		local first = string.sub(line, 1, 1)
		if first == "-" or first == "+" or first == "=" then
			line = "\\" .. line
		elseif string.find(line, "^%d+[.)]") then
			line = string.gsub(line, "^(%d+)([.)])", "%1\\%2")
		end
		line = prefix .. line
		table.insert(out, if quoted and line ~= "" then "> " .. line elseif quoted then ">" else line)
	end
	return trim(table.concat(out, "\n"))
end

-- The text of a <pre> source fragment: tags dropped (a <br> is a newline), entities decoded,
-- line endings normalised, the blank lines around it gone, indentation kept.
local function pre_text(fragment: string): string
	fragment = cut(fragment, PRE_MAX)
	local parts: { string } = {}
	walk(fragment, string.lower(fragment), true, function(from: number, to: number): boolean?
		table.insert(parts, string.sub(fragment, from, to))
		return nil
	end, function(name: string): number?
		if name == "br" then
			table.insert(parts, "\n")
		end
		return nil
	end)
	local text = decode_entities(table.concat(parts))
	text = string.gsub(text, "\r\n?", "\n")
	text = string.gsub(text, "^\n", "")
	local last = #text
	while last > 0 do
		local b = string.byte(text, last)
		if b ~= 32 and (b < 9 or b > 13) then
			break
		end
		last -= 1
	end
	return string.sub(text, 1, last)
end

-- A code fence around `text` that no run of backticks inside it can close.
local function fenced(text: string): string
	local longest = 0
	for run in string.gmatch(text, "`+") do
		longest = math.max(longest, #run)
	end
	local fence = string.rep("`", math.max(3, longest + 1))
	return fence .. "\n" .. text .. "\n" .. fence
end

-- A declared width or height as a finite number of pixels in 1..IMAGE_DIM_MAX; nothing for
-- percentages, units, huge or non-numeric values (an `inf` would break the view).
local function dimension(value: string?): number?
	local digits = if value then string.match(value, "^%s*(%d+)%s*[pP]?[xX]?%s*$") else nil
	local n = if digits then tonumber(digits) else nil
	if n == nil or n < 1 then
		return nil
	end
	return math.min(n, IMAGE_DIM_MAX)
end

-- Where an <img> keeps the picture, best first: the lazy-load attributes hold the real file when
-- `src` is a placeholder, and `srcset` is the last resort.
local IMAGE_SOURCES = { "data-src", "data-lazy-src", "data-original", "src", "srcset", "data-srcset" }

-- The address of the first usable source among `attrs`, resolved against `base`: absolute
-- http(s) without whitespace (`javascript:`, `data:` and friends would each raise in tern.fetch),
-- and not a private or loopback address unless `private_ok` (the article itself is one).
local function image_src(attrs: { [string]: string }, base: string, private_ok: boolean): string?
	for _, key in IMAGE_SOURCES do
		local value = attrs[key]
		if value and (key == "srcset" or key == "data-srcset") then
			value = string.match(value, "^%s*([^%s,]+)") -- the first candidate's URL
		end
		value = trim(value or "")
		if value ~= "" and #value < 2048 then
			local abs = url.resolve(base, value)
			if
				string.find(abs, "^[hH][tT][tT][pP][sS]?://[^%s/?#]")
				and not string.find(abs, "%s")
				and (private_ok or not url.is_private(abs))
			then
				return abs
			end
		end
	end
	return nil
end

-- Subtrees that are page furniture, not the article: dropped whole, counting nested ones of the
-- same name. `header` is the article's own byline when the container is an <article>.
local FURNITURE: { [string]: boolean } = {
	nav = true,
	aside = true,
	footer = true,
	header = true,
	form = true,
	button = true,
}

-- What an opening tag leaves in the text, and what a closing one that ends a block does after the
-- text so far is flushed.
local OPEN_BREAK: { [string]: string } = { p = "\n\n", div = "\n\n", dd = "\n\n", dt = "\n\n", table = "\n\n" }
local CLOSE_BREAK: { [string]: string } = { p = "\n\n", div = "\n", table = "\n\n" }

-- Walks `inner` (the container's source) into blocks. `furniture` drops FURNITURE subtrees; the
-- second result says whether any was dropped. The walk is the preview's html_to_text with
-- structure kept: <img> becomes an image block, headings, list items, quotes, code and line
-- breaks become the Markdown ui.md draws.
local function render(inner: string, kind: string, base: string, furniture: boolean): (Article, boolean)
	local lower = string.lower(inner)
	local private_ok = url.is_private(base)
	local blocks: { ArticleBlock } = {}
	local buf: { string } = {}
	local images = 0
	-- Markdown bytes flushed so far; the walk stops once the article is past the cap.
	local total = 0
	local quotes = 0 -- open <blockquote>s
	local lists: { { ordered: boolean, n: number } } = {}
	-- The marker ("li" or "h1".."h6") the next text opens with. It is written only once text
	-- arrives, so an empty item or heading leaves nothing behind and the whitespace between a
	-- marker and its text (pretty-printed markup) is dropped.
	local pending: string? = nil
	local in_heading = false
	local cells = 0 -- cells so far in the current row
	local skip_name: string? = nil
	local skip_depth = 0
	local dropped = false
	-- Page text queued since the last flush, and whether the walk has read all it will ship: a
	-- page that is all one paragraph never flushes, so the queue is bounded by the source read
	-- (twice the cap leaves room for the whitespace tidy drops).
	local queued = 0
	local done = false

	local function flush()
		local md = finish_md(tidy(table.concat(buf)), quotes > 0)
		buf = {}
		queued = 0
		if md ~= "" then
			total += #md
			table.insert(blocks, { kind = "md", text = md })
		end
	end

	-- Drops the whitespace queued at the end of the text, so a list item starts on the line after
	-- the last one (a blank line between items would draw a loose list).
	local function trim_tail()
		while #buf > 0 do
			local last = buf[#buf]
			local first = string.find(last, "%S")
			if first == nil then
				table.remove(buf)
			else
				local at = #last
				while at > first do
					local b = string.byte(last, at)
					if b ~= 32 and (b < 9 or b > 13) then
						break
					end
					at -= 1
				end
				buf[#buf] = string.sub(last, 1, at)
				return
			end
		end
	end

	local function marker(of: string): string
		if of == "li" then
			local list = lists[#lists]
			if list and list.ordered then
				list.n += 1
				return "\2" .. list.n .. "\3"
			end
			return "\1"
		end
		return "\4" .. string.sub(of, 2, 2) .. "\3"
	end

	walk(inner, lower, false, function(from: number, to: number): boolean?
		if skip_depth > 0 then
			return nil
		end
		local text = decode_entities(cut(string.sub(inner, from, math.min(to, from + READ_MAX)), READ_MAX))
		text = string.gsub(text, "[\1-\5]", "")
		if not string.find(text, "%S") then
			text = " " -- the newlines and indentation between tags mean nothing
		end
		if in_heading then
			text = string.gsub(text, "%s+", " ")
		end
		if pending ~= nil then
			text = string.gsub(text, "\194\160", " ")
			local first = string.find(text, "%S")
			if first == nil then
				return nil
			end
			text = string.sub(text, first)
			table.insert(buf, "\n" .. marker(pending))
			pending = nil
		end
		table.insert(buf, md_escape(text))
		queued += #text
		done = total > ARTICLE_TEXT_MAX or queued > READ_MAX
		return done
	end, function(name: string, closing: boolean, lt: number, gt: number): number?
		if done or total > ARTICLE_TEXT_MAX then
			return math.huge
		end
		if skip_depth > 0 then
			if name == skip_name then
				skip_depth += if closing then -1 else 1
			end
			return nil
		end
		if furniture and not closing and FURNITURE[name] and not (name == "header" and kind == "article") then
			skip_name, skip_depth, dropped = name, 1, true
			return nil
		end
		local heading = string.match(name, "^h[1-6]$") ~= nil
		if closing then
			if name == "li" then
				pending = nil
			elseif heading then
				if pending == name then
					pending = nil
				end
				in_heading = false
				flush()
				table.insert(buf, "\n\n")
			elseif name == "ul" or name == "ol" then
				table.remove(lists)
				pending = nil
				flush()
				table.insert(buf, "\n\n")
			elseif name == "blockquote" then
				flush()
				quotes = math.max(0, quotes - 1)
				table.insert(buf, "\n\n")
			elseif CLOSE_BREAK[name] then
				flush()
				table.insert(buf, CLOSE_BREAK[name])
			elseif name == "tr" then
				table.insert(buf, "\5\n")
			elseif name == "dd" or name == "dt" then
				table.insert(buf, "\n")
			end
			return nil
		end
		if heading then
			flush()
			pending = name
			in_heading = true
		elseif name == "li" then
			trim_tail()
			pending = "li"
		elseif name == "ul" or name == "ol" then
			table.insert(lists, { ordered = name == "ol", n = 0 })
			table.insert(buf, "\n")
		elseif name == "blockquote" then
			flush()
			quotes += 1
		elseif name == "br" then
			table.insert(buf, "\5\n")
		elseif name == "tr" then
			cells = 0
		elseif name == "td" or name == "th" then
			if cells > 0 then
				table.insert(buf, " \\| ") -- an escaped pipe, as md_escape writes a page's own
			end
			cells += 1
		elseif OPEN_BREAK[name] then
			table.insert(buf, OPEN_BREAK[name])
		elseif name == "img" then
			if images < ARTICLE_IMAGES_MAX and gt - lt < TAG_MAX then
				local attrs = decode_attrs(string.sub(inner, lt, gt), true)
				local src = image_src(attrs, base, private_ok)
				if src then
					images += 1
					pending = nil
					flush()
					table.insert(blocks, {
						kind = "img",
						src = src,
						alt = collapse(attrs.alt or ""),
						w = dimension(attrs.width),
						h = dimension(attrs.height),
					})
				end
			end
		elseif name == "pre" then
			pending = nil
			flush()
			local close = string.find(lower, "</pre", gt + 1, true)
			local text = pre_text(string.sub(inner, gt + 1, if close then close - 1 else #inner))
			if string.find(text, "%S") then
				local code = fenced(text)
				if quotes > 0 then
					code = quote_lines(code)
				end
				total += #code
				table.insert(blocks, { kind = "md", text = code })
			end
			local close_gt = if close then string.find(inner, ">", close, true) else nil
			return if close_gt then close_gt + 1 else math.huge
		end
		return nil
	end)
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
	return { blocks = blocks, text = table.concat(text_parts, "\n") }, dropped
end

-- The article in `body` (an HTML page, `content_type` its Content-Type header), read for the
-- native reader: the container's content as interleaved Markdown and image blocks, in document
-- order, plus the whole text for the "is there anything here" check. `blocks` is empty when
-- nothing useful came out, and the caller falls back to the browser. Linear in the page: the
-- container scan and the walk each read it once (see `walk`).
function feed.article(body: string, base: string, content_type: string?): Article
	local html = page_utf8(cut(body, ARTICLE_SOURCE_MAX), content_type)
	local kind, inner = article_container(html, string.lower(html))
	if inner == "" then
		return { blocks = {}, text = "" }
	end
	local article, dropped = render(inner, kind, base, true)
	if dropped and #article.text < ARTICLE_MIN_TEXT then
		-- Furniture swallowed the page (an ASP.NET page wraps everything in one <form>): read it whole.
		article = render(inner, kind, base, false)
	end
	return article
end

return feed
