--!strict
-- The Latest tab's filter: the read gate, the group gate, and an ordered list of pattern rules over
-- a post's full text (title and the feed's preview).
--
-- A rule is one line, written the way a wiki page says it:
--
--   /pattern/            hide matching posts, everywhere
--   @group /pattern/i    hide them in one group, case-insensitively
--   #Feed Name /pattern/ hide them in one feed
--   @group keep /pat/    keep matching posts in that group (an exception to a drop)
--
-- The pattern is a real regular expression with flags (`i` caseless, `m` multiline, `s` dotall,
-- `x` extended), because "Luau patterns" are a dialect nobody has learned and this file's readers
-- have. Tern has no dependency manager, so the engine is vendored: lib/regexp.luau (MIT, Roblox's
-- luau-regexp). Patterns compile once, when the rule is parsed.
--
-- Rules are read in order and the FIRST that matches decides the post: `drop` hides it, `keep`
-- shows it. With no rule matching, the group gate decides. A pattern is matched against the post's
-- text as it is; use the `i` flag where case matters.
--
-- Pure in spirit (only lib/regexp, no tern API), so either half can load it and the store can hold
-- the config.

local regexp = require("./regexp")

local filter = {}

export type Scope = { kind: "all" } | { kind: "group", name: string } | { kind: "feed", key: string }
-- A rule: the scope, the action, the pattern, its flags, and the compiled pattern. `raw` is the line
-- as typed, so the panel and filters.json show it back.
export type Rule = { scope: Scope, drop: boolean, pat: string, flags: string, rx: any, raw: string }
-- Which posts the read state lets through.
export type ReadState = "all" | "unread" | "read"
export type Config = {
	-- Included groups, a whitelist; empty means every group. `filter.UNGROUPED` is the feeds
	-- without a folder.
	groups: { [string]: boolean },
	-- Excluded groups, which always lose.
	excluded: { [string]: boolean },
	-- The read gate, applied before the groups and the rules.
	read: ReadState,
	-- In order; the first match decides.
	rules: { Rule },
}
-- A post's group when its feed has no folder.
filter.UNGROUPED = ""

-- Which flags a pattern may carry, after its closing slash.
local FLAGS: { [string]: boolean } = { i = true, m = true, s = true, x = true }

-- The read states the panel steps through, in order.
local READ_STATES: { ReadState } = { "all", "unread", "read" }

function filter.empty(): Config
	-- Read starts at unread: a feed reader that shows what you have already read by default buries
	-- what you have not. `space` on the read row widens it.
	return { groups = {}, excluded = {}, read = "unread", rules = {} }
end

-- The state after `state` in the cycle.
function filter.next_read(state: ReadState): ReadState
	for i, s in READ_STATES do
		if s == state then
			return READ_STATES[i % #READ_STATES + 1]
		end
	end
	return "all"
end

local SPACE: { [number]: boolean } = { [9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [32] = true }

local function trim(s: string): string
	local first = string.find(s, "%S")
	if first == nil then
		return ""
	end
	local last = #s
	while last > first and SPACE[string.byte(s, last)] do
		last -= 1
	end
	return string.sub(s, first, last)
end

-- Whether `pat` carries a `|` at its top level, outside any group or class and not escaped. Only
-- such a pattern needs the group the engine requires.
local function has_top_alternation(pat: string): boolean
	local depth, i = 0, 1
	while i <= #pat do
		local c = string.sub(pat, i, i)
		if c == "\\" then
			i += 1
		elseif c == "(" then
			-- A group, a flag group or a look-around: each closes with a `)`.
			depth += 1
		elseif c == ")" then
			depth -= 1
		elseif c == "[" then
			local close = string.find(pat, "]", i + 1, true)
			i = if close then close else #pat
		elseif c == "|" and depth == 0 then
			return true
		end
		i += 1
	end
	return false
end

-- Compiles `pat` with `flags`. Returns the compiled pattern, or nil and the engine's complaint.
--
-- Two of the vendored engine's behaviours are worked around here, both verified against it:
--
--   * Top-level alternation only ever matches at the first position, so `/ads|广告/` misses a post
--     whose title starts with something else. Wrapping the pattern in a group fixes it, and only a
--     pattern that really carries a top-level `|` is wrapped: a group around a pattern that matches
--     nothing on its own, such as a lone lookahead, would change what the pattern matches.
--   * `\b` and `\B` raise at match time rather than compile time. They are refused here, so the
--     problem shows up under the field instead of in the middle of a list.
function filter.compile(pat: string, flags: string): (any?, string?)
	for i = 1, #flags do
		local c = string.sub(flags, i, i)
		if not FLAGS[c] then
			return nil, `Unknown flag "{c}"; the flags are i, m, s and x`
		end
	end
	if string.find(pat, "\\[bB]") then
		return nil, "The engine cannot run \\b or \\B; use a capture like (^| )word, or stop at spaces"
	end
	local source = if has_top_alternation(pat) then `(?:{pat})` else pat
	local ok, rx = pcall(function()
		return regexp.new(source, flags)
	end)
	if not ok then
		-- The engine names its own file and line; the field wants the complaint, not the path.
		local message = string.match(tostring(rx), "^[^:]*:%d+: (.*)$") or tostring(rx)
		return nil, `Pattern error: {message}`
	end
	return rx
end

-- Whether `pat` compiles. Used by the field to refuse a typo before it is stored.
function filter.valid(pat: string, flags: string): boolean
	return filter.compile(pat, flags) ~= nil
end

-- One rule line, as documented at the top of this file. Returns the rule, or nil and a reason to
-- show under the field.
function filter.parse(line: string): (Rule?, string?)
	local s = trim(line)
	if s == "" then
		return nil, "Type a rule: /pattern/ or @group drop /pattern/i"
	end
	-- The pattern runs from the first slash to the last one, so a slash inside it is fine, and the
	-- flags are what follows the last one.
	local open = string.find(s, "/", 1, true)
	if open == nil then
		return nil, "A rule needs a /pattern/; the flags go after the closing slash"
	end
	local close = #s
	while close > open and string.sub(s, close, close) ~= "/" do
		close -= 1
	end
	if close == open then
		return nil, "That pattern has no closing /"
	end
	local pat = string.sub(s, open + 1, close - 1)
	local flags = string.sub(s, close + 1)
	if pat == "" then
		return nil, "That pattern is empty"
	end
	-- Before the pattern: an optional action word, then an optional scope.
	local head = trim(string.sub(s, 1, open - 1))
	local action = "drop"
	local lower = string.lower(head)
	-- The bare word and the trailing word are separate cases: stripping " keep" off the four-letter
	-- "keep" would take a negative count and leave the word in place.
	if lower == "keep" then
		action = "keep"
		head = ""
	elseif lower == "drop" then
		head = ""
	elseif string.sub(lower, -5) == " keep" then
		action = "keep"
		head = trim(string.sub(head, 1, #head - 5))
	elseif string.sub(lower, -5) == " drop" then
		head = trim(string.sub(head, 1, #head - 5))
	end
	local scope: Scope = { kind = "all" }
	local mark = string.sub(head, 1, 1)
	if mark == "@" or mark == "#" then
		local name = trim(string.sub(head, 2))
		if name == "" then
			return nil, `A scope needs a name: @group or #feed`
		end
		scope = if mark == "@" then { kind = "group", name = name } else { kind = "feed", key = name }
	elseif head ~= "" then
		return nil, `Don't know "{head}"; a scope is @group or #feed, or leave it out for every feed`
	end
	local rx, err = filter.compile(pat, flags)
	if rx == nil then
		return nil, err
	end
	return { scope = scope, drop = action == "drop", pat = pat, flags = flags, rx = rx, raw = s }
end

-- The scope written back as a line prefix: `@group`, `#feed`, or "" for every feed.
function filter.scope_text(scope: Scope): string
	if scope.kind == "group" then
		return "@" .. scope.name
	end
	if scope.kind == "feed" then
		return "#" .. scope.key
	end
	return ""
end

-- The rule written back as one line.
function filter.format(r: Rule): string
	local pat = string.gsub(r.pat, "/", "\\/")
	local line = `/{pat}/{r.flags}`
	local scope = filter.scope_text(r.scope)
	if scope ~= "" then
		line = scope .. " " .. line
	end
	return if r.drop then line else `keep {line}`
end

function filter.group(f: { folder: string? }?): string
	local g = if f then f.folder else nil
	return if g == nil or g == "" then filter.UNGROUPED else g
end

-- Whether `scope` covers posts of `f`.
local function in_scope(scope: Scope, f: { id: string, title: string, url: string, folder: string? }?): boolean
	if scope.kind == "all" then
		return true
	end
	if f == nil then
		return false
	end
	if scope.kind == "group" then
		return filter.group(f) == scope.name
	end
	local want = string.lower(scope.key)
	if want == string.lower(f.id) or want == string.lower(f.title) then
		return true
	end
	local host = f.url
	local m = string.match(host, "^%a[%w+.-]*://([^/?#]+)")
	return want == string.lower(m or host)
end

-- The text a rule sees: the title and the preview the feed gave.
function filter.text(item: { title: string, preview: string? }): string
	if item.preview == nil or item.preview == "" then
		return item.title
	end
	return item.title .. " " .. item.preview
end

-- A compiled pattern, run defensively: a pattern slow enough to be pathological must not take the
-- block down with it.
local function matches(r: Rule, text: string): boolean
	local ok, hit = pcall(function()
		return r.rx:test(text)
	end)
	return ok and hit == true
end

-- Whether the group gate alone lets a post of `folder` through, ignoring the rules.
function filter.group_allows(cfg: Config, folder: string): boolean
	if cfg.excluded[folder] then
		return false
	end
	if next(cfg.groups) == nil then
		return true
	end
	return cfg.groups[folder] == true
end

-- Whether a post is shown. `feed` is its feed, when the store still knows it, and `read` its read
-- state. The read gate is absolute: it decides before any rule does, so "Unread" means unread.
function filter.visible(cfg: Config, item: { title: string, preview: string? }, feed: any, read: boolean): boolean
	if cfg.read == "unread" and read then
		return false
	elseif cfg.read == "read" and not read then
		return false
	end
	local text: string? = nil
	for _, r in cfg.rules do
		if in_scope(r.scope, feed) then
			if text == nil then
				text = filter.text(item)
			end
			if matches(r, text) then
				return not r.drop
			end
		end
	end
	return filter.group_allows(cfg, filter.group(feed))
end

-- Whether the filter changes anything.
function filter.active(cfg: Config): boolean
	return next(cfg.groups) ~= nil or next(cfg.excluded) ~= nil or cfg.read ~= "all" or #cfg.rules > 0
end

-- Drops group names that no feed carries any more, so a checkmark for a group the user removed
-- never goes on hiding everything.
function filter.prune(cfg: Config, folders: { [string]: boolean }): boolean
	local changed = false
	for name in pairs(cfg.groups) do
		if not folders[name] then
			cfg.groups[name] = nil
			changed = true
		end
	end
	for name in pairs(cfg.excluded) do
		if not folders[name] then
			cfg.excluded[name] = nil
			changed = true
		end
	end
	return changed
end

-- The stored form: rule lines, so the file stays readable and hand-editable.
function filter.encode(cfg: Config): { [string]: any }
	local rules: { string } = {}
	for _, r in cfg.rules do
		table.insert(rules, r.raw)
	end
	return { version = 1, read = cfg.read, groups = cfg.groups, excluded = cfg.excluded, rules = rules }
end

-- The config in `v`, and how many stored rule lines no longer parse.
function filter.decode(v: any): (Config, number)
	local cfg = filter.empty()
	if type(v) ~= "table" then
		return cfg, 0
	end
	local function names(t: any): { [string]: boolean }
		local out: { [string]: boolean } = {}
		if type(t) == "table" then
			for k, on in pairs(t) do
				if type(k) == "string" and on == true then
					out[k] = true
				end
			end
		end
		return out
	end
	cfg.groups = names(v.groups)
	cfg.excluded = names(v.excluded)
	for _, state in READ_STATES do
		if v.read == state then
			cfg.read = state
		end
	end
	local bad = 0
	if type(v.rules) == "table" then
		for _, line in ipairs(v.rules) do
			if type(line) == "string" then
				local r = filter.parse(line)
				if r then
					table.insert(cfg.rules, r)
				else
					bad += 1
				end
			end
		end
	end
	return cfg, bad
end
return filter
