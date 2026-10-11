--!strict
-- The Latest tab's filter: which subscription groups are shown, and an ordered list of pattern
-- rules over a post's full text (title and preview). Rules are read in order and the FIRST that
-- matches decides the post: `drop` hides it, `keep` shows it. With no rule matching, the group
-- gate decides: an empty include set means every group, and an excluded group always loses.
--
-- Patterns are Luau (Lua) patterns, not regular expressions: `%d` is a digit, `.-` is lazy, and
-- there is no `|` or `(?:)`. parse() rejects a pattern Luau cannot compile, so a typo shows up in
-- the field instead of silently matching nothing. Patterns are matched against the text as it is,
-- so write `[Ss]ponsor` where case matters.
--
-- Pure: no tern API, so the rules are testable and the store can hold them.

local filter = {}

export type Scope = { kind: "all" } | { kind: "group", name: string } | { kind: "feed", key: string }
-- A rule as the user typed it; `raw` is kept so the panel shows the line back.
export type Rule = { scope: Scope, drop: boolean, pat: string, raw: string }
-- Which posts the read state lets through.
export type ReadState = "all" | "unread" | "read"
export type Config = {
	-- Included groups, a whitelist; empty means every group. `filter.UNGROUPED` is the feeds
	-- without a folder.
	groups: { [string]: boolean },
	-- Excluded groups, which always lose.
	excluded: { [string]: boolean },
	-- The read gate: a hard gate, applied before the rules.
	read: ReadState,
	-- In order; the first match decides.
	rules: { Rule },
}
-- A post's group when its feed has no folder.
filter.UNGROUPED = ""

function filter.empty(): Config
	return { groups = {}, excluded = {}, read = "all", rules = {} }
end

-- The read states the panel offers, in order.
-- The read states the panel steps through, in order. Declared as a local so the field keeps the
-- type: a module field cannot carry an annotation of its own.
local READ_STATES: { ReadState } = { "all", "unread", "read" }
filter.READ_STATES = READ_STATES

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

-- The first field of `s` (a quoted field may hold spaces), and the rest without it.
local function field(s: string): (string, string)
	local first = string.sub(s, 1, 1)
	if first == '"' or first == "'" then
		local close = string.find(s, first, 2, true)
		if close then
			return string.sub(s, 2, close - 1), trim(string.sub(s, close + 1))
		end
		return string.sub(s, 2), ""
	end
	local space = string.find(s, "%s")
	if space == nil then
		return s, ""
	end
	return string.sub(s, 1, space - 1), trim(string.sub(s, space + 1))
end

-- Whether Luau can compile `pat`; a malformed pattern raises in string.find, so run it once here.
function filter.valid(pat: string): boolean
	return pcall(string.find, "", pat)
end

local function scope_of(f: string): Scope?
	if f == "" or f == "all" or f == "*" then
		return { kind = "all" }
	end
	if string.sub(f, 1, 2) == "g:" then
		return { kind = "group", name = string.sub(f, 3) }
	end
	if string.sub(f, 1, 2) == "f:" then
		return { kind = "feed", key = string.sub(f, 3) }
	end
	return nil
end

-- A `g:` or `f:` scope reads its name quoted, since a group or feed name holds spaces: `f:"Rust
-- Weekly" drop x`. Returns the scope text and the rest, or "" and the whole line when there is no
-- scope prefix.
local function scope_field(s: string): (string, string)
	local prefix = string.sub(s, 1, 2)
	if prefix ~= "g:" and prefix ~= "f:" then
		return "", s
	end
	local body = string.sub(s, 3)
	local first = string.sub(body, 1, 1)
	if first == '"' or first == "'" then
		local close = string.find(body, first, 2, true)
		if close then
			return prefix .. string.sub(body, 2, close - 1), trim(string.sub(body, close + 1))
		end
		return prefix .. string.sub(body, 2), ""
	end
	local space = string.find(body, "%s")
	if space == nil then
		return s, ""
	end
	return prefix .. string.sub(body, 1, space - 1), trim(string.sub(body, space + 1))
end

-- A name with spaces, quoted for the scope text.
local function quote(name: string): string
	return if string.find(name, "%s") then `"{name}"` else name
end

-- The scope written back: `all`, `g:<group>` or `f:<feed>`.
function filter.scope_text(scope: Scope): string
	if scope.kind == "group" then
		return "g:" .. quote(scope.name)
	end
	if scope.kind == "feed" then
		return "f:" .. quote(scope.key)
	end
	return "all"
end

-- One rule line: `[scope] drop|keep pattern`, where scope is `all` (the default), `g:<group>` or
-- `f:<feed>`. Returns the rule, or nil and a reason to show under the field.
function filter.parse(line: string): (Rule?, string?)
	local s = trim(line)
	if s == "" then
		return nil, "Type a rule: [scope] drop|keep pattern"
	end
	local scope: Scope = { kind = "all" }
	local rest = s
	local scoped, tail = scope_field(s)
	if scoped ~= "" then
		local parsed = scope_of(scoped)
		if parsed == nil then
			return nil, `A rule reads "[scope] drop|keep pattern"; got "{scoped}"`
		end
		scope = parsed
		rest = tail
	else
		local head, after = field(s)
		local parsed = scope_of(head)
		if parsed then
			scope = parsed
			rest = after
		end
	end
	local action, pat = field(rest)
	if action == "" then
		return nil, "The rule needs drop or keep after its scope"
	end
	if action ~= "drop" and action ~= "keep" then
		return nil, `A rule reads "[scope] drop|keep pattern"; got "{action}"`
	end
	if pat == "" then
		return nil, "The rule needs a pattern after drop or keep"
	end
	if not filter.valid(pat) then
		return nil, `Luau can't compile "{pat}"; %d is a digit and .- is lazy, with no | or (?:)`
	end
	return { scope = scope, drop = action == "drop", pat = pat, raw = s }
end

-- The rule written back as one line.
function filter.format(r: Rule): string
	local pat = if string.find(r.pat, "%s") then `"{r.pat}"` else r.pat
	return `{filter.scope_text(r.scope)} {if r.drop then "drop" else "keep"} {pat}`
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

local function match(pat: string, text: string): boolean
	local ok, at = pcall(string.find, text, pat)
	return ok and at ~= nil
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

-- Whether a post is shown. `feed` is its feed, when the store still knows it.
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
			if match(r.pat, text) then
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
	return { version = 1, groups = cfg.groups, excluded = cfg.excluded, read = cfg.read, rules = rules }
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
	for _, state in filter.READ_STATES do
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
