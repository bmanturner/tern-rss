--!strict
-- The Latest tab's filter: the read gate, the group gate, and an ordered list of pattern rules over
-- a post's full text (title and the feed's preview).
--
-- A rule is one line, written the way a wiki page says it:
--
--   /pattern/            hide matching posts, everywhere
--   @group /pattern/i    hide them in one group, case-insensitively
--   #Feed Name /pattern/ hide them in one feed, named by its title, id, host or URL
--   @group keep /pat/    keep matching posts in that group (an exception to a drop)
--   @"News / Tech" /x/   a name with a slash, or ending in the word keep or drop, goes in quotes
--
-- The pattern opens at the first slash that starts a word, so `@News/Tech /x/` is the group
-- `News/Tech`; inside quotes `\"` and `\\` are escapes.
--
-- The pattern is a real regular expression with flags (`i` caseless, `m` multiline, `s` dotall,
-- `x` extended), because "Luau patterns" are a dialect nobody has learned and this file's readers
-- have. Tern has no dependency manager, so the engine is vendored: lib/regexp.luau (MIT, Roblox's
-- luau-regexp). Patterns compile once, when the rule is parsed, and the engine stops any one search at a step limit.
--
-- Rules are read in order and the FIRST that matches decides the post: `drop` hides it, `keep`
-- shows it. With no rule matching, the group gate decides; an excluded group is the one thing no
-- rule overrides. A pattern is matched against the post's
-- text as it is; use the `i` flag where case matters.
--
-- Pure in spirit (only lib/regexp, no tern API), so either half can load it and the store can hold
-- the config.

local regexp = require("./regexp")

local filter = {}

export type Scope = { kind: "all" } | { kind: "group", name: string } | { kind: "feed", key: string }
-- What a rule remembers of one post it judged, valid while the post's title and preview stay as they
-- were.
export type Hit = { title: string, preview: string?, hit: boolean }
-- A rule: the scope, the action, the pattern, its flags, and the compiled pattern. `raw` is the line
-- as typed, so the panel and filters.json show it back. `broken` is why a stored line does not parse
-- (the rule is kept and written back, never applied); `slow` is set when a real post ran the pattern
-- out of steps (it is skipped from then on); `memo` is the posts it has judged.
export type Rule = {
	scope: Scope,
	drop: boolean,
	pat: string,
	flags: string,
	rx: any,
	raw: string,
	broken: string?,
	slow: boolean,
	memo: { [string]: Hit },
	memo_n: number,
}
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

-- What lib/regexp raises when one search outruns its step limit.
local STEP_ERROR = "step limit"

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

-- The index just past the escape at `i` (a backslash): its pair, or all of a `\Q…\E` quote.
local function skip_escape(pat: string, i: number): number
	if string.sub(pat, i + 1, i + 1) == "Q" then
		local close = string.find(pat, "\\E", i + 2, true)
		return if close then close + 2 else #pat + 1
	end
	return i + 2
end

-- The index just past the class that opens at `i`. A `]` first in the class, an escaped one and one
-- closing a `[:posix:]` name do not end it.
local function skip_class(pat: string, i: number): number
	local j = i + 1
	if string.sub(pat, j, j) == "^" then
		j += 1
	end
	if string.sub(pat, j, j) == "]" then
		j += 1
	end
	while j <= #pat do
		local c = string.sub(pat, j, j)
		if c == "\\" then
			j = skip_escape(pat, j)
		elseif c == "[" and string.sub(pat, j + 1, j + 1) == ":" then
			local close = string.find(pat, ":]", j + 2, true)
			j = if close then close + 2 else j + 1
		elseif c == "]" then
			return j + 1
		else
			j += 1
		end
	end
	return #pat + 1
end

-- What the pattern carries that matters before it compiles: a `|` at its top level (outside any
-- group, class, comment or `\Q…\E` quote, and not escaped), and a `\b` or `\B` outside a quote. In
-- `x` mode a `#` comment runs to the end of the line and holds neither.
local function scan(pat: string, extended: boolean): (boolean, boolean)
	local depth, i = 0, 1
	local alternation, boundary = false, false
	while i <= #pat do
		local c = string.sub(pat, i, i)
		if c == "\\" then
			local nxt = string.sub(pat, i + 1, i + 1)
			if nxt == "b" or nxt == "B" then
				boundary = true
			end
			i = skip_escape(pat, i)
		elseif c == "(" then
			if string.sub(pat, i, i + 2) == "(?#" then
				local close = string.find(pat, ")", i + 3, true)
				i = if close then close + 1 else #pat + 1
			else
				-- A group, a flag group or a look-around: each closes with a `)`.
				depth += 1
				i += 1
			end
		elseif c == ")" then
			depth -= 1
			i += 1
		elseif c == "[" then
			i = skip_class(pat, i)
		elseif c == "#" and extended then
			local newline = string.find(pat, "\n", i + 1, true)
			i = if newline then newline + 1 else #pat + 1
		else
			if c == "|" and depth == 0 then
				alternation = true
			end
			i += 1
		end
	end
	return alternation, boundary
end

-- Text a pattern has to survive when the rule is added: empty, short, runs of one letter, words,
-- spaces, and the near-miss endings that make nested quantifiers backtrack. Each test is bounded by
-- the engine's step limit, so a pattern that cannot finish on one of these is refused here instead of
-- being found out on a real post.
local SAMPLES: { string } = {
	"",
	"b",
	string.rep("a", 40),
	string.rep("a", 28) .. "!",
	string.rep("ab", 20) .. "!",
	string.rep("a ", 20) .. "!",
	string.rep("word ", 8) .. "!",
	string.rep(" ", 40),
}

-- Compiles `pat` with `flags`. Returns the compiled pattern, or nil and the engine's complaint.
--
-- Three of the vendored engine's behaviours are worked around here, all verified against it:
--
--   * Top-level alternation only ever matches at the first position, so `/ads|广告/` misses a post
--     whose title starts with something else. Wrapping the pattern in a group fixes it, and only a
--     pattern that really carries a top-level `|` is wrapped: a group around a pattern that matches
--     nothing on its own, such as a lone lookahead, would change what the pattern matches. In `x`
--     mode the group closes on a new line, so a trailing `# comment` cannot swallow its `)`.
--   * `\b` and `\B` raise at match time rather than compile time. They are refused here, so the
--     problem shows up under the field instead of in the middle of a list.
--   * A quantified group that can match empty never finishes, and nested quantifiers can backtrack
--     without end. lib/regexp counts its steps and raises past a limit; the samples above find the
--     patterns that hit it, and the same limit marks a rule slow if a real post finds one first.
function filter.compile(pat: string, flags: string): (any?, string?)
	for i = 1, #flags do
		local c = string.sub(flags, i, i)
		if not FLAGS[c] then
			return nil, `Unknown flag "{c}"; the flags are i, m, s and x`
		end
	end
	local alternation, boundary = scan(pat, string.find(flags, "x", 1, true) ~= nil)
	if boundary then
		return nil, "The engine cannot run \\b or \\B; use a capture like (^| )word, or stop at spaces"
	end
	local close = if string.find(flags, "x", 1, true) then "\n)" else ")"
	local source = if alternation then `(?:{pat}{close}` else pat
	local ok, rx = pcall(function()
		return regexp.new(source, flags)
	end)
	if not ok then
		-- The engine names its own file and line; the field wants the complaint, not the path.
		local message = string.match(tostring(rx), "^[^:]*:%d+: (.*)$") or tostring(rx)
		return nil, `Pattern error: {message}`
	end
	for _, sample in SAMPLES do
		local ran, err = pcall(function()
			return rx:test(sample)
		end)
		if not ran and string.find(tostring(err), STEP_ERROR, 1, true) then
			return nil, "That pattern can loop or backtrack without end; simplify its repeated groups"
		end
	end
	return rx
end

-- Whether `pat` compiles. Used by the field to refuse a typo before it is stored.
function filter.valid(pat: string, flags: string): boolean
	return filter.compile(pat, flags) ~= nil
end

local function is_action(word: string): boolean
	local w = string.lower(word)
	return w == "keep" or w == "drop"
end

local function skip_space(s: string, i: number): number
	return string.find(s, "%S", i) or #s + 1
end

-- Whether the next non-space character from `i` is the pattern's opening slash.
local function slash_follows(s: string, i: number): boolean
	return string.sub(s, skip_space(s, i), skip_space(s, i)) == "/"
end

-- A bare scope name takes words up to the action word or the opening slash, so `#Rust Weekly keep /x/`
-- names a feed of two words and `@News/Tech /x/` a group with a slash in it. Returns the name and
-- the index where it ended.
local function read_bare_name(s: string, from: number): (string, number)
	local start = skip_space(s, from)
	local pos = start
	while pos <= #s do
		local word = string.match(s, "^%S+", pos) :: string
		if string.sub(word, 1, 1) == "/" then
			break
		end
		local lead = string.match(string.lower(word), "^(%a+)/")
		if (is_action(word) and slash_follows(s, pos + #word)) or (lead ~= nil and is_action(lead)) then
			break
		end
		pos = skip_space(s, pos + #word)
	end
	return trim(string.sub(s, start, pos - 1)), pos
end

-- A quoted name, from the character after the opening quote: `\"` and `\\` are escapes. Returns the
-- name and the index past the closing quote, or nil when it never closes.
local function read_quoted(s: string, from: number): (string?, number)
	local out: { string } = {}
	local i = from
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == "\\" and (string.sub(s, i + 1, i + 1) == '"' or string.sub(s, i + 1, i + 1) == "\\") then
			table.insert(out, string.sub(s, i + 1, i + 1))
			i += 2
		elseif c == '"' then
			return table.concat(out), i + 1
		else
			table.insert(out, c)
			i += 1
		end
	end
	return nil, i
end

-- A name is written bare unless that would be read back differently: a slash, a quote, or an action
-- word in it.
local function quote_name(name: string): string
	local plain = string.find(name, '[/"]') == nil
	for word in string.gmatch(name, "%S+") do
		if is_action(word) then
			plain = false
		end
	end
	if plain then
		return name
	end
	return '"' .. string.gsub(string.gsub(name, "\\", "\\\\"), '"', '\\"') .. '"'
end

local function new_rule(scope: Scope, drop: boolean, pat: string, flags: string, rx: any, raw: string): Rule
	return { scope = scope, drop = drop, pat = pat, flags = flags, rx = rx, raw = raw, broken = nil, slow = false, memo = {}, memo_n = 0 }
end

-- One rule line, as documented at the top of this file. Returns the rule, or nil and a reason to
-- show under the field.
function filter.parse(line: string): (Rule?, string?)
	local s = trim(line)
	if s == "" then
		return nil, "Type a rule: /pattern/ or @group drop /pattern/i"
	end
	-- Before the pattern: an optional scope, then an optional action word.
	local scope: Scope = { kind = "all" }
	local i = 1
	local mark = string.sub(s, 1, 1)
	if mark == "@" or mark == "#" then
		local name: string?, after: number
		if string.sub(s, 2, 2) == '"' then
			name, after = read_quoted(s, 3)
			if name == nil then
				return nil, "That name has no closing quote"
			end
		else
			name, after = read_bare_name(s, 2)
		end
		if name == "" then
			return nil, `A scope needs a name: @group or #feed`
		end
		scope = if mark == "@" then { kind = "group", name = name } else { kind = "feed", key = name }
		i = after
	end
	local action = "drop"
	i = skip_space(s, i)
	local word = string.match(s, "^%a+", i)
	if word ~= nil and is_action(word) and slash_follows(s, i + #word) then
		action = string.lower(word)
		i = skip_space(s, i + #word)
	end
	if string.sub(s, i, i) ~= "/" then
		local slash = string.find(s, "/", i, true)
		if slash == nil then
			return nil, "A rule needs a /pattern/; the flags go after the closing slash"
		end
		return nil, `Don't know "{trim(string.sub(s, i, slash - 1))}"; a scope is @group or #feed, or leave it out for every feed`
	end
	local open = i
	-- The pattern runs from the opening slash to the last one, so a slash inside it is fine, and the
	-- flags are what follows the last one.
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
	local rx, err = filter.compile(pat, flags)
	if rx == nil then
		return nil, err
	end
	return new_rule(scope, action == "drop", pat, flags, rx, s)
end

-- A stored line that no longer parses, held in its place so a save writes it back untouched. It is
-- never applied; the panel shows it with `reason` and `d` deletes it.
function filter.broken(line: string, reason: string): Rule
	local r = new_rule({ kind = "all" }, true, "", "", nil, line)
	r.broken = reason
	return r
end

-- The scope written back as a line prefix: `@group`, `#feed`, or "" for every feed.
function filter.scope_text(scope: Scope): string
	if scope.kind == "group" then
		return "@" .. quote_name(scope.name)
	end
	if scope.kind == "feed" then
		return "#" .. quote_name(scope.key)
	end
	return ""
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
	if want == string.lower(f.id) or want == string.lower(f.title) or want == string.lower(f.url) then
		return true
	end
	local m = string.match(f.url, "^%a[%w+.-]*://([^/?#]+)")
	return want == string.lower(m or f.url)
end

-- The text a rule sees: the title and the preview the feed gave.
function filter.text(item: { title: string, preview: string? }): string
	if item.preview == nil or item.preview == "" then
		return item.title
	end
	return item.title .. " " .. item.preview
end

-- Where a pass over the posts has to stop (an os.clock time); no limit until `filter.budget` sets one.
local deadline = math.huge

-- Limits the matching that follows to `seconds` from now, or lifts the limit with nil. Past it,
-- `filter.visible` answers nil for a post it has not yet judged, and a later call picks up from the
-- cache without redoing the rest. The host kills a handler that overruns its own budget, so a list
-- too long to judge in one call has to be judged in several.
function filter.budget(seconds: number?)
	deadline = if seconds then os.clock() + seconds else math.huge
end

-- Judgements one rule remembers before it starts over, so posts that left the store don't pile up.
local MEMO_MAX = 20000

-- Whether `r` matches `item`, or nil when the budget is spent first. The result is remembered per
-- post for as long as its title and preview stay as they were, so a pattern runs once per change to
-- the post rather than once per render.
local function matches(r: Rule, item: { key: string, title: string, preview: string? }): boolean?
	local seen = r.memo[item.key]
	if seen and seen.title == item.title and seen.preview == item.preview then
		return seen.hit
	end
	if os.clock() > deadline then
		return nil
	end
	-- pcall catches the engine's step-limit error, so a pattern that cannot finish is skipped from
	-- then on. It could not catch the host's own time budget, which would disable the whole view.
	local ran, hit = pcall(function()
		return r.rx:test(filter.text(item))
	end)
	if not ran and string.find(tostring(hit), STEP_ERROR, 1, true) then
		r.slow = true
		return false
	end
	if r.memo_n >= MEMO_MAX then
		r.memo, r.memo_n = {}, 0
	end
	if r.memo[item.key] == nil then
		r.memo_n += 1
	end
	local result = ran and hit == true
	r.memo[item.key] = { title = item.title, preview = item.preview, hit = result }
	return result
end

-- How many rules gave up on a real post. A pass that raises this mid-way judged earlier posts with a
-- rule it later skipped, so the caller runs the pass again.
function filter.slow_count(cfg: Config): number
	local n = 0
	for _, r in cfg.rules do
		if r.slow then
			n += 1
		end
	end
	return n
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

-- Whether a post is shown: true or false, or nil when `filter.budget` ran out before the rules could
-- say. `feed` is its feed, when the store still knows it, and `read` its read state. The read gate is
-- absolute: it decides before any rule does, so "Unread" means unread. An excluded group comes next,
-- because it always loses, whatever a `keep` rule says; a group that is merely not checked is a
-- default a `keep` rule may override.
function filter.visible(
	cfg: Config,
	item: { key: string, title: string, preview: string? },
	feed: any,
	read: boolean
): boolean?
	if cfg.read == "unread" and read then
		return false
	elseif cfg.read == "read" and not read then
		return false
	end
	local group = filter.group(feed)
	if cfg.excluded[group] then
		return false
	end
	for _, r in cfg.rules do
		if r.broken == nil and not r.slow and in_scope(r.scope, feed) then
			local hit = matches(r, item)
			if hit == nil then
				return nil
			elseif hit then
				return not r.drop
			end
		end
	end
	return next(cfg.groups) == nil or cfg.groups[group] == true
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

-- The stored form: rule lines, so the file stays readable and hand-editable. A broken line is
-- written back as it was found.
function filter.encode(cfg: Config): { [string]: any }
	local rules: { string } = {}
	for _, r in cfg.rules do
		table.insert(rules, r.raw)
	end
	return { version = 1, read = cfg.read, groups = cfg.groups, excluded = cfg.excluded, rules = rules }
end

-- The config in `v`, and how many stored rule lines no longer parse (they stay in the list as
-- broken rules, in place).
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
				local r, reason = filter.parse(line)
				if r then
					table.insert(cfg.rules, r)
				else
					bad += 1
					table.insert(cfg.rules, filter.broken(line, reason or "Does not parse"))
				end
			end
		end
	end
	return cfg, bad
end
return filter
