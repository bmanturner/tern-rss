--!strict
-- The `rss` block (host half): a river of headlines under three tabs (Latest, ★ Favorites, Feeds).
-- Feeds, read state, caches and polling live in lib/store, shared by every RSS block; this file is the
-- view, the keys and the clicks. Articles open through the window's `tern-rss://read/<pane>` route,
-- which docks one article pane (the native reader, or Tern's browser) beside the block and reuses it.

local store = require("../lib/store")
local url = require("../lib/url")
local fmt = require("../lib/fmt")
local cards = require("../lib/cards")
local filter = require("../lib/filter")
local config = require("../lib/config")

local ui = tern.ui
local span = ui.span

type Tab = "latest" | "favorites" | "feeds"

-- What the one-line field does on Enter.
type Intent = "add" | "folder" | "rule" | "feed"

-- The one-line field, and what it is for: following a feed, setting the selected feed's group, or
-- The one-line field, and what it is for: following a feed, setting the selected feed's group,
-- adding a filter rule, or editing a feed. `target` is the feed id for "folder" and "feed".
type Field = {
	text: string,
	-- Byte offset of the caret (bytes before it).
	cursor: number,
	intent: Intent,
	target: string?,
}

type State = {
	cx: BlockCx,
	tab: Tab,
	-- Selected item key per headline tab, selected feed id, selected starter index.
	sel: { latest: string?, favorites: string?, feeds: string?, starter: number },
	-- Row position of the last resolved headline selection per tab, so a vanished post hands the
	-- cursor to the row that took its place rather than to the top.
	sel_at: { latest: number, favorites: number },
	-- The selected headline shows its preview card.
	preview: boolean,
	-- The add field, while it is open.
	adding: Field?,
	-- The Latest tab's filter panel: whether it is up, and the row it points at (see panel_rows).
	panel: boolean,
	panel_at: number,
	-- A timer is already set to finish judging the posts the filter has not reached (see judge).
	judging: boolean,
	-- The field whose add request is in flight; a closed field's request reports by toast.
	add_busy: Field?,
	add_error: string?,
	-- Feed id armed for removal by a first `d`.
	confirm: string?,
	-- Starter index being followed.
	starting: number?,
	-- Watermarks the last catch-up replaced, while `u` can still undo it.
	undo: { [string]: number | false }?,
	-- The last add found no feed on a reachable site: `c` asks Carly to look, `esc` dismisses. Not saved.
	missed: { site: string, error: string }?,
}

-- Headline rows drawn per tab; past 200 a list goes virtual and drops item actions.
local MAX_ROWS = 150

-- A list row is one terminal line plus 6px, up to about 1.45 lines; `max = {lines}` counts rows. How
-- many rows fit in `free` terminal lines, so the tab strip above a long list never scrolls out of view.
local function rows_fitting(free: number, floor: number): number
	return math.max(floor, math.floor(free / 1.45))
end

local TABS: { Tab } = { "latest", "favorites", "feeds" }

local STARTERS = {
	{ title = "Stencil", url = "https://stencil.so/rss.xml", about = "Notes from the team behind Tern" },
	{ title = "Hacker News", url = "https://hnrss.org/frontpage", about = "Front page stories" },
	{ title = "Lobsters", url = "https://lobste.rs/rss", about = "Computing-focused links and discussion" },
	{ title = "Simon Willison", url = "https://simonwillison.net/atom/everything/", about = "LLMs, Python and the web" },
}

local function plural(n: number, one: string, many: string): string
	return tostring(n) .. " " .. (if n == 1 then one else many)
end

local function strip_prefix(s: string?, prefix: string): string?
	if s == nil or string.sub(s, 1, #prefix) ~= prefix then
		return nil
	end
	return string.sub(s, #prefix + 1)
end

local function as_tab(v: string?): Tab?
	if v == "latest" then
		return "latest"
	elseif v == "favorites" then
		return "favorites"
	elseif v == "feeds" then
		return "feeds"
	end
	return nil
end

local function is_favorite(item: store.Item): boolean
	local f = store.feed(item.feed)
	return f ~= nil and f.favorite
end

local function any_favorite(): boolean
	for _, f in store.feeds() do
		if f.favorite then
			return true
		end
	end
	return false
end

-- What the Latest filter makes of the posts. Matching a pattern costs far more than a render may,
-- so the result is a snapshot: `shown` holds the keys of the posts the filter lets through, `hidden`
-- counts those it hides, and `pending` those it has not reached yet (they are neither).
type Latest = { active: boolean, shown: { [string]: boolean }, hidden: number, pending: number }

-- The most one host call spends matching, a share of the 2 s the host allows a handler. A single
-- capped pattern test can run past it by about 60 ms, so a call stays under 250 ms.
local JUDGE_BUDGET = 0.1

-- Judges every post once for the Latest tab. filter.visible remembers what each pattern said about a
-- post, so only posts that are new or changed cost anything here; the rest is a lookup. When the
-- budget runs out before every post is judged, a timer renders again and the next call carries on.
local function judge(state: State): Latest
	local cfg = store.filter()
	local latest: Latest = { active = filter.active(cfg), shown = {}, hidden = 0, pending = 0 }
	if not latest.active then
		return latest
	end
	local feeds: { [string]: store.Feed } = {}
	for _, f in store.feeds() do
		feeds[f.id] = f
	end
	-- A rule that gives up on a post is skipped from then on, so the posts judged before that were
	-- judged with a rule the rest are not: the pass runs again, which is all lookups.
	for _ = 1, 2 do
		local slow = filter.slow_count(cfg)
		latest.shown, latest.hidden, latest.pending = {}, 0, 0
		filter.budget(JUDGE_BUDGET)
		for _, it in store.items() do
			local shown = filter.visible(cfg, it, feeds[it.feed], store.is_read(it.key))
			if shown == nil then
				latest.pending += 1
			elseif shown then
				latest.shown[it.key] = true
			else
				latest.hidden += 1
			end
		end
		filter.budget(nil)
		if filter.slow_count(cfg) == slow then
			break
		end
	end
	if latest.pending > 0 and not state.judging then
		state.judging = true
		-- 50 ms between slices, so keys and other blocks get the host between them.
		tern.timer(50, function()
			state.judging = false
			pcall(function()
				state.cx:render()
			end)
		end)
	end
	return latest
end

-- For the tabs the filter does not scope.
local UNFILTERED: Latest = { active = false, shown = {}, hidden = 0, pending = 0 }

local function is_shown(latest: Latest, key: string): boolean
	return not latest.active or latest.shown[key] == true
end

-- Every post a tab shows, posts new since the last catch-up first, then the rest, each group newest
-- first; and how many of them are new. The filter scopes the Latest tab; Favorites stays the starred
-- feeds as they are.
local function shown_items(tab: Tab, latest: Latest): ({ store.Item }, number)
	local fresh: { store.Item } = {}
	local older: { store.Item } = {}
	for _, it in store.items() do
		if tab ~= "favorites" or is_favorite(it) then
			if tab ~= "latest" or is_shown(latest, it.key) then
				if store.is_new(it) then
					table.insert(fresh, it)
				else
					table.insert(older, it)
				end
			end
		end
	end
	local n_fresh = #fresh
	table.move(older, 1, #older, n_fresh + 1, fresh)
	return fresh, n_fresh
end

-- The headlines a tab draws, at most MAX_ROWS. Also returns how many were left out and how many rows
-- are new. `latest` is the snapshot when the caller already took one.
local function headlines(state: State, tab: Tab, latest: Latest?): ({ store.Item }, number, number)
	local all, n_fresh = shown_items(tab, if tab == "latest" then latest or judge(state) else UNFILTERED)
	local out = table.move(all, 1, math.min(#all, MAX_ROWS), 1, {})
	return out, #all - #out, math.min(n_fresh, MAX_ROWS)
end

local function sel_key(state: State): string?
	if state.tab == "latest" then
		return state.sel.latest
	elseif state.tab == "favorites" then
		return state.sel.favorites
	end
	return state.sel.feeds
end

local function set_sel(state: State, key: string?)
	if state.tab == "latest" then
		state.sel.latest = key
	elseif state.tab == "favorites" then
		state.sel.favorites = key
	else
		state.sel.feeds = key
	end
end

-- The selected headline and its index. When the remembered one is gone: the row now at its old
-- position (clamped to the list), so the cursor stays where it was.
local function selected_item(state: State, rows: { store.Item }): (store.Item?, number)
	local key = sel_key(state)
	local tab = state.tab
	for i, it in rows do
		if it.key == key then
			if tab == "latest" then
				state.sel_at.latest = i
			elseif tab == "favorites" then
				state.sel_at.favorites = i
			end
			return it, i
		end
	end
	local at = if tab == "favorites" then state.sel_at.favorites else state.sel_at.latest
	local i = math.clamp(at, 1, math.max(1, #rows))
	return rows[i], i
end

local function selected_feed(state: State, feeds: { store.Feed }): (store.Feed?, number)
	for i, f in feeds do
		if f.id == state.sel.feeds then
			return f, i
		end
	end
	return feeds[1], 1
end

-- The row index of the remembered selection, or 1 when it is gone (selected_item's fallback).
local function find_item(key: string): store.Item?
	for _, it in store.items() do
		if it.key == key then
			return it
		end
	end
	return nil
end

-- Filter panel --------------------------------------------------------------------------------------
--
-- The Latest tab's filter editor: the read-state row, then the all-groups row, one row per
-- subscription group, then one per rule in the order the rules are read. panel_rows is the one
-- source of that order, shared by the view and the keys, so a key always acts on the row under the
-- cursor.

-- Which kind of row a panel line is.
type RowKind = "read" | "all" | "group" | "rule"

type PanelRow = { kind: RowKind, name: string?, index: number? }

local function panel_rows(): { PanelRow }
	local rows: { PanelRow } = {
		{ kind = "read", name = nil, index = nil },
		{ kind = "all", name = nil, index = nil },
	}
	for _, name in store.folders() do
		table.insert(rows, { kind = "group", name = name, index = nil })
	end
	for i = 1, #store.filter().rules do
		table.insert(rows, { kind = "rule", name = nil, index = i })
	end
	return rows
end

-- A short summary of the filter for the status line above the headlines.
local function describe_filter(cfg: filter.Config): string
	local groups, excluded = 0, 0
	for _ in pairs(cfg.groups) do
		groups += 1
	end
	for _ in pairs(cfg.excluded) do
		excluded += 1
	end
	local out: { string } = {}
	if cfg.read ~= "all" then
		table.insert(out, cfg.read .. " only")
	end
	if groups > 0 then
		table.insert(out, plural(groups, "group", "groups") .. " in")
	end
	if excluded > 0 then
		table.insert(out, plural(excluded, "group", "groups") .. " out")
	end
	if #cfg.rules > 0 then
		table.insert(out, plural(#cfg.rules, "rule", "rules"))
	end
	return if #out == 0 then "off" else table.concat(out, " · ")
end

-- Space checks a group, `x` excludes it. Checking a group is what keeps it in the Latest tab; with
-- nothing checked every group is in. A group is never both, and space on the top row unchecks all.
-- Space checks a group, `x` excludes it. Checking a group is what keeps it in the Latest tab; with
-- nothing checked every group is in. A group is never both, and space on the all-groups row unchecks
-- them all. The read row steps a single cycle instead: every post, unread only, read only.
local function panel_toggle(row: PanelRow, pressed: string): boolean
	local cfg = store.filter()
	local name = row.name
	if row.kind == "read" then
		if pressed ~= "space" and pressed ~= "x" then
			return false
		end
		cfg.read = filter.next_read(cfg.read)
	elseif row.kind == "all" and pressed == "space" then
		if next(cfg.groups) == nil then
			return false
		end
		cfg.groups = {}
	elseif row.kind == "group" and name ~= nil then
		if pressed == "space" then
			if cfg.groups[name] then
				cfg.groups[name] = nil
			else
				cfg.groups[name] = true
				cfg.excluded[name] = nil
			end
		elseif pressed == "x" then
			if cfg.excluded[name] then
				cfg.excluded[name] = nil
			else
				cfg.excluded[name] = true
				cfg.groups[name] = nil
			end
		else
			return false
		end
	else
		return false
	end
	store.set_filter(cfg)
	return true
end

-- K and J move a rule, which changes the order the rules are read in.
local function panel_move_rule(state: State, index: number, up: boolean): boolean
	local cfg = store.filter()
	local to = if up then index - 1 else index + 1
	if to < 1 or to > #cfg.rules then
		return false
	end
	table.insert(cfg.rules, to, table.remove(cfg.rules, index))
	store.set_filter(cfg)
	state.panel_at += if up then -1 else 1
	return true
end

local function panel_delete_rule(state: State, index: number): boolean
	local cfg = store.filter()
	if cfg.rules[index] == nil then
		return false
	end
	table.remove(cfg.rules, index)
	store.set_filter(cfg)
	state.panel_at = math.clamp(state.panel_at, 1, #panel_rows())
	return true
end

-- What `a` fills the rule field with: the group under the cursor, when there is one.
local function panel_prefill(row: PanelRow): string
	if row.kind == "group" and row.name ~= nil and row.name ~= filter.UNGROUPED then
		return filter.scope_text({ kind = "group", name = row.name }) .. " "
	end
	return ""
end

-- New unread posts: those from favorite feeds, per feed id, and those the Latest filter shows.
local function tally(latest: Latest): (number, { [string]: number }, number)
	local fav, shown = 0, 0
	local per: { [string]: number } = {}
	for _, it in store.items() do
		if not store.is_read(it.key) and store.is_new(it) then
			per[it.feed] = (per[it.feed] or 0) + 1
			if is_favorite(it) then
				fav += 1
			end
			if is_shown(latest, it.key) then
				shown += 1
			end
		end
	end
	return fav, per, shown
end

-- Feed ids a catch-up covers: every feed on Latest, starred ones on Favorites, the selected one on Feeds.
-- Feed ids a catch-up covers: on Latest the feeds the filter's groups keep, starred ones on
-- Favorites, the selected one on Feeds. Posts a rule hides are caught up with their feed.
local function catch_up_scope(state: State): { string }
	local ids: { string } = {}
	local feeds = store.feeds()
	if state.tab == "feeds" then
		local f = selected_feed(state, feeds)
		if f then
			table.insert(ids, f.id)
		end
		return ids
	end
	local cfg = store.filter()
	local gated = state.tab == "latest" and filter.active(cfg)
	for _, f in feeds do
		if state.tab == "latest" then
			if not gated or filter.group_allows(cfg, filter.group(f)) then
				table.insert(ids, f.id)
			end
		elseif f.favorite then
			table.insert(ids, f.id)
		end
	end
	return ids
end

-- Selection movement for a key: a delta, or ±huge for the ends; nil when the key doesn't move.
local function nav_delta(k: Key): number?
	local n = k.name
	if k.text == "G" or (n == "g" and k.shift) or n == "end" then
		return math.huge
	elseif n == "g" or n == "home" then
		return -math.huge
	elseif n == "j" or n == "down" then
		return 1
	elseif n == "k" or n == "up" then
		return -1
	elseif n == "page_down" then
		return 10
	elseif n == "page_up" then
		return -10
	end
	return nil
end

local function moved(index: number, delta: number, count: number): number
	return math.clamp(if delta == math.huge then count elseif delta == -math.huge then 1 else index + delta, 1, count)
end

-- `text` split at blank lines.
local function paragraphs(text: string): { string }
	local out: { string } = {}
	local pos = 1
	while pos <= #text do
		local s, e = string.find(text, "\n[ \t]*\n%s*", pos)
		local chunk = string.sub(text, pos, if s then s - 1 else #text)
		chunk = string.match(chunk, "^%s*(.-)%s*$") or ""
		if chunk ~= "" then
			table.insert(out, chunk)
		end
		if e == nil then
			break
		end
		pos = e + 1
	end
	return out
end

-- Splits the edit field into a title and a URL. A URL is whatever starts with a scheme, so the title
-- is the text before it; with no URL the whole line is the title. Both come back trimmed and empty
-- strings come back nil, which is what store.rename reads as "keep this one".
-- Splits the edit field into a title and a URL. The URL is the text from the first `scheme://`
-- that stands alone after a space (so `K.I.S.S` doesn't end in a fake scheme); with no URL the
-- whole line is the title. Both come back trimmed and empty strings come back nil, which is what
-- store.rename reads as "keep this one".
-- Splits the edit field into a title and a URL. The URL is the text from the first `scheme://`
-- that starts the line or follows a space, so `K.I.S.S` doesn't end in a fake scheme; with no URL
-- the whole line is the title. Both come back trimmed and empty strings come back nil, which is
-- what store.rename reads as "keep this one".
-- Splits the edit field into a title and a URL. The URL is the text from the first `scheme://`
-- that starts the line or follows a space, so the `.S` of `K.I.S.S` doesn't read as a scheme; with
-- no URL the whole line is the title. Both come back trimmed and empty strings come back nil, which
-- is what store.rename reads as "keep this one".
local function split_feed_fields(text: string): (string?, string?)
	local s = string.match(text, "^%s*(.-)%s*$") or ""
	if s == "" then
		return nil, nil
	end
	-- `^[%w+.-]+://` or `%s[%w+.-]+://`: the scheme must start the line or follow a space, so a
	-- title ending in letters never counts as one.
	local head = string.find(s, "^[%w+.-]+://")
	-- In the second case the space is matched too, so the URL starts one byte later.
	local at = head or (function()
		local space = string.find(s, "%s[%w+.-]+://")
		return if space then space + 1 else nil
	end)()
	if at == nil then
		return s, nil
	end
	-- `at` is the start of the URL, or the space in front of it in the second case, and the title is
	-- everything before that either way.
	local title = string.match(string.sub(s, 1, at - 1), "^%s*(.-)%s*$")
	local u = string.match(string.sub(s, at), "^%s*(.-)%s*$")
	return if title == "" then nil else title, if u == "" then nil else u
end

-- Add field ------------------------------------------------------------------------------------------

local function is_cont(b: number?): boolean
	return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Start (1-based) of the character that ends at byte `cursor`.
local function char_before(text: string, cursor: number): number
	local st = cursor
	while st > 1 and is_cont(string.byte(text, st)) do
		st -= 1
	end
	return st
end

-- End (1-based) of the character that starts at byte `cursor + 1`.
local function char_after(text: string, cursor: number): number
	local en = cursor + 1
	while en < #text and is_cont(string.byte(text, en + 1)) do
		en += 1
	end
	return en
end

-- Opens the one-line field. `intent` decides what Enter does: "add" follows a feed and jumps to the
-- Feeds tab, "folder" groups `target`, "rule" appends a filter rule on the Latest panel.
local function open_field(state: State, cx: BlockCx, intent: Intent, prefill: string?, target: string?)
	local text = prefill or ""
	state.adding = { text = text, cursor = #text, intent = intent, target = target }
	state.add_error = nil
	state.missed = nil
	state.confirm = nil
	if intent == "add" and #store.feeds() > 0 then
		state.tab = "feeds"
	end
	-- Draw the field first, so the focus op finds it.
	cx:render()
	cx:frame({ { "focus", "main.add" } })
end

local function close_field(state: State, cx: BlockCx)
	state.adding = nil
	state.add_error = nil
	local op: { any } = { "focus", tern.json.null }
	cx:frame({ op })
end

-- The add field is drawn on the welcome view and the Feeds tab only.
-- Whether the current view draws the field: the add and group fields live on the welcome view and
-- the Feeds tab, the rule field on the latest panel.
-- Whether the view where `intent`'s field belongs is the view now: the add, group and feed fields
-- live on the welcome view and the Feeds tab, the rule field on the Latest panel.
local function field_view(state: State, intent: Intent): boolean
	if intent == "rule" then
		return state.panel and state.tab == "latest"
	elseif intent == "folder" or intent == "feed" then
		return state.tab == "feeds"
	end
	return state.tab == "feeds" or #store.feeds() == 0
end

-- Whether the open field is drawn where the view is now. A field whose view is gone is closed.
local function field_shown(state: State): boolean
	local field = state.adding
	return field ~= nil and field_view(state, field.intent)
end

-- Whether the view now is one with the no-feed offer beside the add field.
local function offer_shown(state: State): boolean
	return state.tab == "feeds" or #store.feeds() == 0
end

-- The group field is synchronous: it writes the folder and closes. An empty line clears the group.
local function submit_folder(state: State, cx: BlockCx, field: Field)
	local target = field.target
	local name = field.text
	close_field(state, cx)
	if target == nil then
		return
	end
	store.set_folder(target, name)
	cx:toast("success", if name == "" then "Left its group" else "Grouped under " .. name)
end

-- The rule field appends to the end of the rule list; a line that doesn't parse stays in the field
-- with the reason under it.
local function submit_rule(state: State, cx: BlockCx, field: Field)
	local rule, err = filter.parse(field.text)
	if rule == nil then
		state.add_error = err
		cx:render()
		return
	end
	local cfg = store.filter()
	table.insert(cfg.rules, rule)
	close_field(state, cx)
	-- store.set_filter renders, and the cursor follows the rule the user just added.
	state.panel_at = #panel_rows()
	store.set_filter(cfg)
end

-- The feed field edits the selected feed: `title` and `url`. A title, a URL, or both, in that order;
-- one field holds both, so the user sees the whole feed on one line.
local function submit_feed(state: State, cx: BlockCx, field: Field)
	local target = field.target
	local text = field.text
	if target == nil then
		close_field(state, cx)
		return
	end
	local title, u = split_feed_fields(text)
	if title == nil and u == nil then
		state.add_error = "Type a title, a URL, or a title and a URL in one line"
		cx:render()
		return
	end
	close_field(state, cx)
	local ok = store.rename(target, title or "", u or "", function(err: string?)
		if err then
			cx:toast("error", "Couldn't read that feed", err)
		else
			cx:toast("success", "Updated")
		end
	end)
	if not ok then
		cx:toast("info", "Nothing to change")
	end
end

local function submit(state: State, cx: BlockCx)
	local field = state.adding
	if field == nil or state.add_busy == field then
		return
	end
	if field.intent == "folder" then
		submit_folder(state, cx, field)
		return
	elseif field.intent == "rule" then
		submit_rule(state, cx, field)
		return
	elseif field.intent == "feed" then
		submit_feed(state, cx, field)
		return
	end
	state.add_busy = field
	state.add_error = nil
	store.add(field.text, function(f, err, why)
		if state.add_busy == field then
			state.add_busy = nil
		end
		local open = state.adding == field
		if f then
			if open then
				close_field(state, cx)
				state.tab = "feeds"
				state.sel.feeds = f.id
			end
			cx:toast("success", "Following " .. f.title)
		elseif why == "no_feed" then
			-- Carly is ask-first: offer it beside the error and wait for the user to choose it.
			local site = url.normalize(field.text) or field.text
			state.missed = { site = site, error = err or "No feed found on that page." }
			if open then
				close_field(state, cx)
			else
				cx:toast("error", "No feed found on " .. url.host(site), "Open Feeds and press c to ask Carly.")
			end
		elseif open then
			state.add_error = err
		else
			cx:toast("error", "Couldn't add that feed", err)
		end
		cx:render()
	end)
end

local function field_key(state: State, f: Field, k: Key, cx: BlockCx): boolean
	local text, cursor = f.text, f.cursor
	if k.name == "enter" then
		submit(state, cx)
		return true
	elseif k.name == "escape" then
		close_field(state, cx)
		return true
	elseif k.name == "paste" then
		local line = string.match(k.text or "", "^[^\r\n]*") or ""
		line = string.match(line, "^%s*(.-)%s*$") or ""
		if line == "" then
			return false
		end
		f.text = string.sub(text, 1, cursor) .. line .. string.sub(text, cursor + 1)
		f.cursor = cursor + #line
	elseif k.name == "backspace" then
		if cursor == 0 then
			return false
		end
		local st = char_before(text, cursor)
		f.text = string.sub(text, 1, st - 1) .. string.sub(text, cursor + 1)
		f.cursor = st - 1
	elseif k.name == "delete" then
		if cursor >= #text then
			return false
		end
		f.text = string.sub(text, 1, cursor) .. string.sub(text, char_after(text, cursor) + 1)
	elseif k.name == "left" then
		if cursor == 0 then
			return false
		end
		f.cursor = char_before(text, cursor) - 1
		return true
	elseif k.name == "right" then
		if cursor >= #text then
			return false
		end
		f.cursor = char_after(text, cursor)
		return true
	elseif k.name == "home" then
		f.cursor = 0
		return true
	elseif k.name == "end" then
		f.cursor = #text
		return true
	elseif k.name == "space" and (k.text == nil or k.text == "") then
		-- A space key that carries no text still types a space, so a field never silently eats it.
		f.text = string.sub(text, 1, cursor) .. " " .. string.sub(text, cursor + 1)
		f.cursor = cursor + 1
	elseif k.text and k.text ~= "" and not (k.ctrl or k.meta) then
		f.text = string.sub(text, 1, cursor) .. k.text .. string.sub(text, cursor + 1)
		f.cursor = cursor + #k.text
	else
		return false
	end
	state.add_error = nil
	return true
end

-- The panel's keys. Escape and f close it; space and x change the group under the cursor; a opens
-- the rule field, d deletes a rule, K and J move one in the order the rules are read.
local function panel_key(state: State, k: Key, cx: BlockCx): boolean
	local rows = panel_rows()
	local at = math.clamp(state.panel_at, 1, #rows)
	local row = rows[at]
	local n = k.name
	local index = if row.kind == "rule" then row.index else nil
	-- A rule row moves before navigation reads K and J as k and j.
	if index and (n == "K" or (n == "k" and k.shift)) then
		return panel_move_rule(state, index, true)
	elseif index and (n == "J" or (n == "j" and k.shift)) then
		return panel_move_rule(state, index, false)
	end
	local delta = nav_delta(k)
	if delta then
		local i = moved(at, delta, #rows)
		if i == at then
			return false
		end
		state.panel_at = i
		return true
	elseif n == "escape" or n == "f" then
		state.panel = false
		if state.adding then
			close_field(state, cx)
		end
		return true
	elseif n == "space" or n == "x" then
		return panel_toggle(row, n)
	elseif n == "a" then
		open_field(state, cx, "rule", panel_prefill(row), nil)
		return true
	elseif n == "d" and index then
		return panel_delete_rule(state, index)
	end
	return false
end

-- Actions --------------------------------------------------------------------------------------------

-- Leaving for a headline tab closes the add field and drops the no-feed offer, which only the
-- Feeds tab draws.
local function switch_tab(state: State, cx: BlockCx, tab: Tab)
	state.tab = tab
	state.confirm = nil
	state.undo = nil
	if tab ~= "feeds" then
		state.missed = nil
		if state.adding then
			close_field(state, cx)
		end
	end
end

-- Hands the site the last add missed to Carly, only on the user's explicit request.
local function ask_carly(state: State, cx: BlockCx)
	local m = state.missed
	if m == nil then
		return
	end
	state.missed = nil
	-- ask_carly answers nil only when the request can't be written (or the site doesn't parse).
	if store.ask_carly(m.site, cx) == nil then
		cx:toast("error", "Couldn't ask Carly", "Tern couldn't start a search for " .. url.host(m.site) .. ".")
	end
end

local function follow_starter(state: State, cx: BlockCx, i: number)
	local s = STARTERS[i]
	if s == nil or state.starting ~= nil then
		return
	end
	state.sel.starter = i
	state.starting = i
	store.add(s.url, function(f, err)
		state.starting = nil
		if f then
			switch_tab(state, cx, "latest")
			cx:toast("success", "Following " .. f.title)
		else
			cx:toast("error", "Couldn't add that feed", err)
		end
		cx:render()
	end)
end

-- Opens `link` for reading through the window's route: the native reader block (blocks/reader.luau)
-- fetches the page itself and draws its text and images, and hands the page to Tern's browser when
-- it can't read it. The window keeps one article pane per RSS pane, so a second article lands in
-- the same reading pane.
local function open_article(cx: BlockCx, link: string)
	cx:open("tern-rss://read/" .. cx.pane .. "?url=" .. url.encode(link))
end

local function visit(cx: BlockCx, item: store.Item)
	local link = item.link
	if link == nil then
		cx:toast("error", "This post has no link")
		return
	end
	store.set_read(item.key, true)
	open_article(cx, link)
end

local function toggle_read(item: store.Item)
	store.set_read(item.key, not store.is_read(item.key))
end

-- Marks every post the tab shows read, or unread when they all already are, in one write. This is
-- what follows a read filter: narrow Latest to unread, then clear the list with one key.
local function toggle_all_read(state: State): boolean
	local rows = headlines(state, state.tab)
	if #rows == 0 then
		return false
	end
	local keys: { string } = {}
	local all_read = true
	for _, it in rows do
		table.insert(keys, it.key)
		if not store.is_read(it.key) then
			all_read = false
		end
	end
	store.set_read_many(keys, not all_read)
	return true
end

-- First call arms, second removes; the selection moves to the next feed, else the previous one.
local function remove_feed(state: State, id: string)
	if state.confirm ~= id then
		state.confirm = id
		return
	end
	local feeds = store.feeds()
	local next_id: string? = nil
	for i, f in feeds do
		if f.id == id then
			local n = feeds[i + 1] or feeds[i - 1]
			next_id = if n then n.id else nil
		end
	end
	state.confirm = nil
	store.remove(id)
	state.sel.feeds = next_id
end

-- Catches up on the current scope (see catch_up_scope); `u` undoes it until the tab changes.
local function catch_up(state: State): boolean
	local ids = catch_up_scope(state)
	if #ids == 0 then
		return false
	end
	state.undo = store.catch_up(ids)
	return true
end

local function undo_catch_up(state: State): boolean
	local prev = state.undo
	if prev == nil then
		return false
	end
	state.undo = nil
	store.restore_seen(prev)
	return true
end

-- View -----------------------------------------------------------------------------------------------

-- The caret in UTF-16 code units, as the `input` element counts it.
local function utf16_len(s: string): number
	local n = 0
	for _, c in utf8.codes(s) do
		n += if c > 0xFFFF then 2 else 1
	end
	return n
end

-- The field's prompt glyph and placeholder, per intent.
local function field_prompt(f: Field): Span
	if f.intent == "folder" then
		return span("# ", "accent")
	elseif f.intent == "rule" then
		return span("- ", "accent")
	elseif f.intent == "feed" then
		return span("~ ", "accent")
	end
	return span("+ ", "accent")
end

local function field_placeholder(f: Field): string
	if f.intent == "folder" then
		return "Group name, then Enter (an empty line leaves the group)"
	elseif f.intent == "rule" then
		return "/sponsor/ or @group /sponsor/i — hides matching posts"
	elseif f.intent == "feed" then
		return "Title and URL, then Enter (leave one out to keep it)"
	end
	return "Paste a site or feed URL, then press Enter"
end

local function add_nodes(state: State, f: Field): { Node }
	local prefix = string.sub(f.text, 1, f.cursor)
	local nodes: { Node } = {
		ui.node("input", {
			key = "add",
			text = f.text,
			cursor = if utf8.len(prefix) then utf16_len(prefix) else f.cursor,
			placeholder = field_placeholder(f),
			prompt = { field_prompt(f) },
		}),
	}
	if state.add_busy == f then
		table.insert(nodes, ui.node("spinner", { key = "add-busy", style = "dots", label = "Looking for a feed…" }))
	elseif state.add_error then
		table.insert(nodes, cards.with(ui.text({ span(state.add_error, "error") }), { key = "add-error" }))
	end
	return nodes
end

local function append(parts: { Node }, nodes: { Node })
	for _, n in nodes do
		table.insert(parts, n)
	end
end

-- The no-feed offer: the error, then "Ask Carly to find it" and "Dismiss".
local function missed_nodes(m: { site: string, error: string }): { Node }
	return {
		cards.with(ui.text({ span(m.error, "error") }), { key = "missed" }),
		cards.with(
			ui.row({
				cards.with(ui.badge("Ask Carly to find it", "accent"), { key = "ask", actions = { click = "ask-carly" } }),
				cards.with(ui.badge("Dismiss", "neutral"), { key = "dismiss", actions = { click = "dismiss" } }),
				cards.with(
					ui.text({ span("c", "key"), span(" ask Carly   ", "muted"), span("esc", "key"), span(" dismiss", "muted") }),
					{ key = "missed-keys" }
				),
			}),
			{ key = "missed-acts" }
		),
	}
end

local function welcome_view(state: State): { Node }
	local parts: { Node } = {}
	table.insert(parts, cards.with(ui.text({ span("Follow your first feed", "strong") }), { key = "hello" }))
	table.insert(
		parts,
		cards.with(
			ui.text({
				span("Press ", "muted"),
				span("enter", "key"),
				span(" to follow the highlighted feed, ", "muted"),
				span("a", "key"),
				span(" to add your own, or paste any site or feed URL.", "muted"),
			}),
			{ key = "hello-hint" }
		)
	)
	if state.adding then
		append(parts, add_nodes(state, state.adding))
	elseif state.missed then
		append(parts, missed_nodes(state.missed))
	end
	local rows: { Node } = {}
	for i, s in STARTERS do
		table.insert(
			rows,
			ui.node("item", {
				key = "s" .. i,
				label = { span(s.title, "strong") },
				detail = s.about,
				value = { span("+ Follow", "accent") },
				actions = { click = "starter=" .. i },
			})
		)
	end
	table.insert(parts, ui.node("list", { key = "starters", selected = "main.starters.s" .. state.sel.starter }, rows))
	if state.starting then
		table.insert(
			parts,
			ui.node("spinner", { key = "starting", style = "dots", label = "Following " .. STARTERS[state.starting].title .. "…" })
		)
	end
	for _, s in store.searches() do
		table.insert(
			parts,
			ui.node("spinner", { key = "carly-" .. s.id, style = "dots", label = "Carly is looking for a feed on " .. url.host(s.site) .. "…" })
		)
	end
	return parts
end

local function preview_card(item: store.Item, feed: store.Feed?, read: boolean): Node
	local head: { Span | string } = { span(if feed then feed.title else "", "muted") }
	if item.published then
		table.insert(head, span(" · " .. os.date("%a %d %b, %H:%M", item.published), "muted"))
	end
	local body: { Node } = {}
	local paras: { string } = if item.preview then paragraphs(item.preview) else {}
	if #paras > 0 then
		for i, p in paras do
			table.insert(body, cards.with(ui.text(p), { key = "para" .. i }))
		end
	else
		table.insert(
			body,
			cards.with(
				ui.text({ span("No preview in this feed. ", "muted"), span("enter", "key"), span(" opens the article.", "muted") }),
				{ key = "none" }
			)
		)
	end
	local badges: { Node } = {}
	local keys: { Span | string } = {}
	if item.link then
		table.insert(badges, cards.with(ui.badge("↗ Open", "accent"), { key = "visit", actions = { click = "visit=" .. item.key } }))
		table.insert(keys, span("enter", "key"))
		table.insert(keys, span(" open   ", "muted"))
	end
	table.insert(
		badges,
		cards.with(
			ui.badge(if read then "○ Mark unread" else "✓ Mark read", "neutral"),
			{ key = "mark", actions = { click = "mark=" .. item.key } }
		)
	)
	table.insert(keys, span("m", "key"))
	table.insert(keys, span(if read then " unread" else " read", "muted"))
	table.insert(badges, cards.with(ui.text(keys), { key = "keys" }))
	table.insert(body, cards.with(ui.row(badges), { key = "acts" }))
	return cards.with(ui.card(head, body), { key = "p-" .. item.key, role = "tern-rss.preview" })
end

-- The latest catch-up among the feeds a tab shows, or nil when none was ever caught up on.
local function caught_up_at(tab: Tab): number?
	local best: number? = nil
	for _, f in store.feeds() do
		if (tab ~= "favorites" or f.favorite) and f.seen_until and (best == nil or f.seen_until > best) then
			best = f.seen_until
		end
	end
	return best
end

local function headlines_view(state: State, cx: BlockCx, parts: { Node }, latest: Latest)
	local rows, hidden, n_new = headlines(state, state.tab, latest)
	-- The filter's state sits above the list, so a post it hides is never a surprise.
	if state.tab == "latest" then
		local cfg = store.filter()
		local spans: { Span | string } = {
			span("Filter ", "muted"),
			span(describe_filter(cfg), if filter.active(cfg) then "accent" else "muted"),
		}
		if latest.hidden > 0 then
			table.insert(spans, span(" · " .. plural(latest.hidden, "post", "posts") .. " hidden", "muted"))
		end
		if latest.pending > 0 then
			table.insert(spans, span(" · filtering " .. plural(latest.pending, "more post", "more posts"), "muted"))
		end
		table.insert(spans, span("   "))
		table.insert(spans, span("f", "key"))
		table.insert(spans, span(" edit", "muted"))
		table.insert(parts, cards.with(ui.text(spans), { key = "filter-bar", actions = { click = "filter-open" } }))
	end
	if #rows == 0 then
		if state.tab == "favorites" and not any_favorite() then
			table.insert(parts, cards.with(ui.text({ span("No favorites yet.", "strong") }), { key = "empty" }))
			table.insert(
				parts,
				cards.with(ui.text({ span("Star a feed in Feeds (s) and its new posts will toast you.", "muted") }), {
					key = "empty-hint",
				})
			)
		elseif store.busy() > 0 then
			table.insert(parts, ui.node("spinner", { key = "empty", style = "dots", label = "Fetching your feeds…" }))
		else
			table.insert(parts, cards.with(ui.text({ span("No headlines yet. Press r to check again.", "muted") }), { key = "empty" }))
		end
		return
	end

	local sel = selected_item(state, rows)
	-- Pin a fallback selection (first visit, or the remembered post is gone), so a post arriving on
	-- top doesn't move the cursor.
	if sel and sel.key ~= sel_key(state) then
		set_sel(state, sel.key)
	end
	-- The list scrolls itself: `max = { lines }` caps its height and keeps the selection in view, so
	-- every row is drawn and the list owns the window. `bars` is what surrounds it (tab strip, filter
	-- line, the tab's own note, the dock), plus two lines of daylight so the dock clears the edge.
	local bars = 8 + (if state.tab == "latest" then 1 else 0) + (if state.preview then 8 else 0)
	local cap = math.max(4, rows_fitting(cx.rows - bars, 4))
	local now = os.time()
	-- The divider sits where the user last caught up: under the new posts, or on top when none are new.
	local caught = caught_up_at(state.tab)
	local divider_before = if caught then n_new + 1 else nil
	-- Narrow panes squeeze the feed name to "…" fragments: drop it there and mark favorites in the label.
	local narrow = cx.cols < 90
	local children: { Node } = {}
	for i = 1, #rows do
		local it = rows[i]
		if i == divider_before and caught then
			table.insert(children, cards.with(ui.rule("caught up " .. fmt.ago(caught, now)), { key = "caught-up" }))
		end
		local feed = store.feed(it.feed)
		local read = store.is_read(it.key)
		local fresh = not read and i <= n_new
		local feed_title = if feed then feed.title else ""
		local starred = state.tab == "latest" and feed ~= nil and feed.favorite
		-- New: a dot and a strong title. Older, unopened: plain. Read: muted.
		local label: { Span | string } = { if fresh then span("● ", "accent") else span("  ") }
		if narrow and starred then
			table.insert(label, span("★ ", "accent"))
		end
		table.insert(label, if fresh then span(it.title, "strong") elseif read then span(it.title, "muted") else span(it.title))
		local detail: Spans? = nil
		if not narrow then
			detail = if starred then { span("★ ", "accent"), span(feed_title) } else feed_title
		end
		table.insert(
			children,
			ui.node("item", {
				key = it.key,
				label = label,
				detail = detail,
				value = fmt.age(it.published, now),
			})
		)
		if state.preview and sel and it.key == sel.key then
			table.insert(children, preview_card(it, feed, read))
		end
	end
	table.insert(
		parts,
		ui.node("list", {
			key = "items",
			selected = if sel then "main.items." .. sel.key else nil,
			-- The list caps its own height and scrolls, keeping the selection in view.
			max = { lines = cap },
		}, children)
	)
	-- Posts past the row cap: the list scrolls the drawn rows itself, so only this note is left.
	if hidden > 0 then
		table.insert(
			parts,
			cards.with(ui.text({ span("↓ " .. plural(hidden, "headline", "headlines") .. " not shown", "muted") }), { key = "more" })
		)
	end
end

-- The Latest tab's filter editor: the read gate, the group gate, then the ordered rules. Rows
-- come from panel_rows, so the cursor and the view never disagree about which row is under it.
local function panel_view(state: State, cx: BlockCx, parts: { Node }, latest: Latest)
	local cfg = store.filter()
	local rows = panel_rows()
	local at = math.clamp(state.panel_at, 1, #rows)
	table.insert(
		parts,
		cards.with(
			ui.text({
				span("Filter ", "strong"),
				span("Latest", "accent"),
				span("   "),
				span("esc", "key"),
				span(" close", "muted"),
			}),
			{ key = "filter-head" }
		)
	)
	local children: { Node } = {}
	local keys: { string } = {}
	for i, row in rows do
		if row.kind == "read" then
			table.insert(keys, "read")
			table.insert(
				children,
				ui.node("item", {
					key = "read",
					label = {
						span(if cfg.read == "all" then "☑" else "☐", if cfg.read == "all" then "accent" else "muted"),
						span(" "),
						span("Every post", "strong"),
					},
					detail = if cfg.read == "all" then "space shows unread only" else cfg.read .. " only",
					value = { span("space · x", "muted") },
				})
			)
		elseif row.kind == "all" then
			table.insert(keys, "all")
			table.insert(
				children,
				ui.node("item", {
					key = "all",
					label = {
						span(if next(cfg.groups) == nil then "☑" else "☐", "accent"),
						span(" "),
						span("Every group", "strong"),
					},
					detail = "space unchecks every group",
					value = { span(plural(#store.folders(), "group", "groups"), "num") },
				})
			)
		elseif row.kind == "group" then
			local name = row.name :: string
			local feeds = store.feeds_in(name)
			table.insert(keys, "g:" .. name)
			local marks: { Span | string } = {
				span(if cfg.groups[name] then "☑" else "☐", if cfg.groups[name] then "accent" else "muted"),
				span(" "),
				span(if name == filter.UNGROUPED then "Ungrouped" else name, "strong"),
			}
			if cfg.excluded[name] then
				table.insert(marks, span("  ⊘ excluded", "warning"))
			end
			table.insert(
				children,
				ui.node("item", {
					key = "g:" .. name,
					label = marks,
					detail = plural(#feeds, "feed", "feeds"),
					value = { span("space · x", "muted") },
				})
			)
		else
			local index = row.index :: number
			local rule = cfg.rules[index]
			if rule and rule.broken then
				-- Kept in its place and written back as it was; it does nothing until fixed or deleted.
				table.insert(keys, "r" .. index)
				table.insert(
					children,
					ui.node("item", {
						key = "r" .. index,
						label = { span(tostring(index) .. " ", "num"), span("⚠ " .. rule.raw, "warning") },
						detail = "not applied: " .. rule.broken,
						value = { span("K/J · d", "muted") },
					})
				)
			elseif rule then
				local where = if rule.scope.kind == "all" then "every feed" else filter.scope_text(rule.scope)
				table.insert(keys, "r" .. index)
				table.insert(
					children,
					ui.node("item", {
						key = "r" .. index,
						label = {
							span(tostring(index) .. " ", "num"),
							span(if rule.drop then "" else "keep ", if rule.drop then "muted" else "accent"),
							span(`/{rule.pat}/{rule.flags}`, if rule.drop then "error" else "accent"),
						},
						detail = if rule.slow then where .. " · skipped: too slow on a post" else where,
						value = { span("K/J · d", "muted") },
					})
				)
			end
		end
	end
	table.insert(
		parts,
		ui.node("list", {
			key = "filter",
			selected = "main.filter." .. (keys[at] or "all"),
			max = { lines = rows_fitting(cx.rows - 12, 4) },
		}, children)
	)
	if state.adding and state.adding.intent == "rule" then
		append(parts, add_nodes(state, state.adding))
	end
	local hint: { Span | string } = {
		span("space", "key"),
		span(" check a group   ", "muted"),
		span("x", "key"),
		span(" exclude   ", "muted"),
		span("a", "key"),
		span(" add rule   ", "muted"),
		span("d", "key"),
		span(" delete   ", "muted"),
		span("K/J", "key"),
		span(" move", "muted"),
	}
	table.insert(parts, cards.with(ui.text(hint), { key = "filter-keys" }))
	table.insert(
		parts,
		cards.with(
			ui.text({
				span("Rules are read in order and the first match decides: ", "muted"),
				span("/pattern/", "error"),
				span(" hides, ", "muted"),
				span("keep", "accent"),
				span(" shows. Flags follow the closing slash: ", "muted"),
				span("i", "code"),
				span(" caseless, ", "muted"),
				span("m", "code"),
				span(" multiline, ", "muted"),
				span("s", "code"),
				span(" dotall, ", "muted"),
				span("x", "code"),
				span(" spaced.", "muted"),
			}),
			{ key = "filter-help" }
		)
	)
	if latest.hidden > 0 then
		table.insert(
			parts,
			cards.with(ui.text({ span(plural(latest.hidden, "post", "posts") .. " hidden right now", "muted") }), { key = "filter-hid" })
		)
	end
end

-- A group header row in the Feeds list: not selectable, so selection stays on feed ids.
local function group_head(name: string, count: number): Node
	return ui.node("item", {
		key = "head:" .. name,
		label = {
			span("▾ ", "muted"),
			span(if name == filter.UNGROUPED then "Ungrouped" else name, "strong"),
		},
		detail = plural(count, "feed", "feeds"),
		tone = "pending",
		disabled = true,
	})
end

local function feeds_view(state: State, cx: BlockCx, parts: { Node }, per: { [string]: number })
	if state.adding then
		append(parts, add_nodes(state, state.adding))
	elseif state.missed then
		append(parts, missed_nodes(state.missed))
	else
		table.insert(
			parts,
			cards.with(ui.text({ span("+ ", "accent"), span("Add a feed", "muted") }), { key = "add-cta", actions = { click = "add" } })
		)
	end

	local feeds = store.feeds()
	local sel = selected_feed(state, feeds)
	local rows: { Node } = {}
	-- One header per folder, once the user groups anything, drawn directly above that folder's own
	-- feeds (ungrouped last). A flat subscription list draws as it always did. Headers are not
	-- selectable, so selection stays on feed ids.
	local folders = store.folders()
	local grouped = #folders > 1 or (folders[1] ~= nil and folders[1] ~= filter.UNGROUPED)
	local drawn: { { name: string?, feed: store.Feed? } } = {}
	if grouped then
		for _, name in folders do
			table.insert(drawn, { name = name, feed = nil })
			for _, f in store.feeds_in(name) do
				table.insert(drawn, { name = nil, feed = f })
			end
		end
	else
		for _, f in feeds do
			table.insert(drawn, { name = nil, feed = f })
		end
	end
	for _, entry in drawn do
		local f = entry.feed
		if f == nil and entry.name ~= nil then
			table.insert(rows, group_head(entry.name, #store.feeds_in(entry.name)))
		elseif f ~= nil then
			local st = store.status(f.id)
			local fresh = per[f.id] or 0
			local value: Spans
			local tone: string? = nil
			if state.confirm == f.id then
				value, tone = { span("remove?", "warning") }, "warning"
			elseif st.state == "loading" then
				value = { span("checking…", "muted") }
			elseif st.state == "error" then
				value, tone = { span("can't refresh", "error") }, "error"
			elseif fresh > 0 then
				value = { span(fresh .. " new", "num") }
			else
				value = { span("caught up", "muted") }
			end
			table.insert(
				rows,
				ui.node("item", {
					key = f.id,
					label = {
						span(if f.favorite then "★" else "☆", if f.favorite then "accent" else "muted"),
						span(" "),
						span(f.title, "strong"),
					},
					detail = url.host(f.url),
					value = value,
					tone = tone,
				})
			)
		end
	end
	-- Sites Carly is still searching: shown under the feeds, not selectable.
	for _, s in store.searches() do
		table.insert(
			rows,
			ui.node("item", {
				key = "carly-" .. s.id,
				label = { span("⋯ ", "muted"), span(url.host(s.site), "strong") },
				detail = "Carly is looking for its feed",
				value = { span("searching…", "muted") },
				tone = "pending",
				disabled = true,
			})
		)
	end
	table.insert(
		parts,
		ui.node("list", {
			key = "feeds",
			selected = if sel then "main.feeds." .. sel.id else nil,
			-- A group header takes a row too, so the budget shrinks by the headers drawn.
			max = { lines = rows_fitting(cx.rows - 12 - if grouped then #folders else 0, 4) },
		}, rows)
	)

	if sel == nil then
		return
	end
	local st = store.status(sel.id)
	if st.state == "error" and st.error then
		table.insert(parts, cards.with(ui.text({ span(st.error, "error") }), { key = "feed-error" }))
	end
	local armed = state.confirm == sel.id
	if armed then
		table.insert(
			parts,
			cards.with(
				ui.text({
					span("Press ", "muted"),
					span("d", "key"),
					span(" again to remove " .. sel.title .. ", or ", "muted"),
					span("esc", "key"),
					span(" to keep it.", "muted"),
				}),
				{ key = "confirm-hint" }
			)
		)
	end
	table.insert(
		parts,
		cards.with(
			ui.row({
				cards.with(
					ui.badge(if sel.favorite then "Unstar" else "Star", "neutral"),
					{ key = "star", actions = { click = "star=" .. sel.id } }
				),
				cards.with(
					ui.badge(if armed then "Confirm remove" else "Remove", if armed then "error" else "neutral"),
					{ key = "remove", actions = { click = "remove=" .. sel.id } }
				),
			}),
			{ key = "feed-acts" }
		)
	)
end

-- Dock widths: below 70 columns labels shorten, below 56 (a pane beside the reader) only the three
-- essential keys show, so the bar never wraps.
-- Cells a hint pair needs, its separator included. A keycap chip renders no wider than its text, so
-- text length is a safe upper bound and the measured bar stays a little narrower than reality.
local function pair_width(pair: { string }, gap: number, first: boolean): number
	local w = #pair[1]
	if pair[2] ~= "" then
		w += 1 + #pair[2]
	end
	return w + (if first then 0 else gap)
end

-- The longest prefix of `pairs` that fits in `cols`: the bar drops its least useful keys instead of
-- wrapping under the pane.
local function fit_pairs(pairs: { { string } }, cols: number, gap: number): { { string } }
	local kept: { { string } } = {}
	local used = 0
	for i, pair in pairs do
		local w = pair_width(pair, gap, i == 1)
		if used + w > cols then
			break
		end
		used += w
		table.insert(kept, pair)
	end
	return kept
end

-- Dock hints, most useful key first, trimmed to the room the refresh status leaves. Below 70 columns
-- the labels shorten and the separators tighten.
local function hints_text(state: State, cx: BlockCx, has_feeds: boolean, reserve: number): Node
	local narrow = cx.cols < 70
	local catch: { string } = if state.undo then { "u", "undo" } else { "shift+m", "catch up" }
	-- Last on the tabs that have it, so it is the first hint to go when the bar is tight.
	local reader: { string } = { "b", if config.reader_mode() == "browser" then "browser" else "reader" }
	local pairs: { { string } }
	if not has_feeds then
		pairs = { { "enter", "follow" }, { "a", "add" }, { "j", "move" } }
	elseif state.panel and state.tab == "latest" then
		pairs = { { "space", "check" }, { "x", "exclude" }, { "a", "rule" }, { "K/J", "move" }, { "f", "close" } }
	elseif state.tab == "feeds" then
		pairs = { { "s", "star" }, { "t", "group" }, { "e", "edit" }, { "d", "remove" }, catch, { "a", "add" }, { "r", "refresh" }, reader }
	else
		pairs = {
			{ "enter", "open" },
			{ "space", if narrow then "peek" else "preview" },
			{ "f", "filter" },
			catch,
			{ "m", "read" },
			{ "R", "read all" },
			{ "a", "add" },
			{ "r", "refresh" },
			reader,
		}
	end
	local gap = if narrow then 2 else 3
	local kept = fit_pairs(pairs, math.max(0, cx.cols - reserve), gap)
	local spans: { Span | string } = {}
	for i, pair in kept do
		if i > 1 then
			table.insert(spans, span(if narrow then "  " else "   "))
		end
		table.insert(spans, span(pair[1], "key"))
		if pair[2] ~= "" then
			table.insert(spans, span(" " .. pair[2], "muted"))
		end
	end
	return cards.with(ui.text(spans), { key = "hints" })
end

-- The bar: key hints on the stable left edge, then refresh status and failures after a separator.
local function dock_view(state: State, cx: BlockCx, has_feeds: boolean): Node
	-- What the right-hand status costs, separator included, so the hints get the rest of the line.
	local status: { Node } = {}
	local reserve = 0
	local busy = store.busy()
	if busy > 0 then
		reserve = 3 + #("Checking " .. plural(busy, "feed", "feeds"))
	else
		local checked = store.checked()
		-- A pane beside the reader has no room for it; the refresh state shows on the Feeds tab too.
		if checked and cx.cols >= 56 then
			local now = os.time()
			local ago = if cx.cols < 70 then fmt.age(checked, now) else fmt.ago(checked, now)
			reserve = 3 + #("Updated " .. ago)
		end
	end
	local failing = 0
	for _, f in store.feeds() do
		if store.status(f.id).state == "error" then
			failing += 1
		end
	end
	if failing > 0 then
		reserve += 3 + #(plural(failing, "feed", "feeds") .. " failing")
	end
	local items: { Node } = { hints_text(state, cx, has_feeds, reserve) }
	if busy > 0 then
		table.insert(
			status,
			ui.node("spinner", { key = "status", style = "dots", label = { span("Checking " .. plural(busy, "feed", "feeds"), "muted") } })
		)
	else
		local checked = store.checked()
		-- A pane beside the reader has no room for it; the refresh state shows on the Feeds tab too.
		if checked and cx.cols >= 56 then
			local now = os.time()
			local ago = if cx.cols < 70 then fmt.age(checked, now) else fmt.ago(checked, now)
			table.insert(status, cards.with(ui.text({ span("Updated " .. ago, "muted") }), { key = "status" }))
		end
	end
	if failing > 0 then
		table.insert(
			status,
			cards.with(ui.text({ span(plural(failing, "feed", "feeds") .. " failing", "warning") }), {
				key = "failing",
				actions = { click = "tab=feeds" },
			})
		)
	end
	if #status > 0 then
		table.insert(items, cards.with(ui.text({ span("·", "muted") }), { key = "sep" }))
		append(items, status)
	end
	-- One blank line under the hints. The dock's box ends at the pane's own bottom edge, where the
	-- window's inset and rounded corner clip it; the slack line keeps the keys off that edge.
	return ui.col({ cards.with(ui.row(items), { key = "bar" }), ui.text({ span(" ") }) })
end

-- Keys -----------------------------------------------------------------------------------------------

local function welcome_key(state: State, k: Key, cx: BlockCx): boolean
	local delta = nav_delta(k)
	if delta then
		local i = moved(state.sel.starter, delta, #STARTERS)
		if i == state.sel.starter then
			return false
		end
		state.sel.starter = i
		return true
	elseif k.name == "enter" then
		follow_starter(state, cx, state.sel.starter)
		return true
	end
	return false
end

local function headlines_key(state: State, k: Key, cx: BlockCx): boolean
	local rows = headlines(state, state.tab)
	local item, index = selected_item(state, rows)
	if item == nil then
		return false
	end
	local delta = nav_delta(k)
	local n = k.name
	if delta then
		local i = moved(index, delta, #rows)
		if rows[i].key == sel_key(state) then
			return false
		end
		set_sel(state, rows[i].key)
	elseif n == "space" then
		state.preview = not state.preview
	elseif n == "right" or n == "l" then
		if state.preview then
			return false
		end
		state.preview = true
	elseif n == "left" or n == "h" or n == "escape" then
		if not state.preview then
			return false
		end
		state.preview = false
	elseif n == "enter" or n == "o" then
		visit(cx, item)
	elseif n == "m" and not k.shift then
		toggle_read(item)
	else
		return false
	end
	return true
end

local function feeds_key(state: State, k: Key, cx: BlockCx): boolean
	local feeds = store.feeds()
	local feed, index = selected_feed(state, feeds)
	local n = k.name
	-- `d` arms the removal and `d` again confirms. A bare backspace used to delete the feed, which is
	-- one stray keypress away from losing a subscription while editing a field.
	if feed and n == "d" and not k.shift then
		remove_feed(state, feed.id)
		return true
	elseif feed and n == "t" and not k.shift then
		-- `t` groups the selected feed: the field opens with its current group, empty to leave it.
		-- Not `g`: that jumps to the top of the list.
		open_field(state, cx, "folder", feed.folder or "", feed.id)
		return true
	elseif feed and n == "e" and not k.shift then
		-- `e` edits the selected feed: its title and its URL, on one line.
		open_field(state, cx, "feed", feed.title .. " " .. feed.url, feed.id)
		return true
	end
	local had_confirm = state.confirm ~= nil
	state.confirm = nil
	local delta = nav_delta(k)
	if feed and delta then
		state.sel.feeds = feeds[moved(index, delta, #feeds)].id
	elseif feed and n == "s" then
		store.toggle_favorite(feed.id)
	else
		return had_confirm
	end
	return true
end

-- Block ----------------------------------------------------------------------------------------------

local rss: BlockDef<State> = {
	init = function(cx, _args, saved)
		local s: { [string]: any } = if type(saved) == "table" then saved else {}
		local sel: { [string]: any } = if type(s.sel) == "table" then s.sel else {}
		local function str(v: any): string?
			return if type(v) == "string" then v else nil
		end
		local state: State = {
			cx = cx,
			tab = if s.tab == "latest" or s.tab == "favorites" or s.tab == "feeds" then s.tab else "latest",
			sel = {
				latest = str(sel.latest),
				favorites = str(sel.favorites),
				feeds = str(sel.feeds),
				starter = if type(sel.starter) == "number" and STARTERS[sel.starter] then sel.starter else 1,
			},
			sel_at = { latest = 1, favorites = 1 },
			preview = s.preview == true,
			judging = false,
			panel = s.panel == true,
			panel_at = if type(s.panel_at) == "number" then s.panel_at else 1,
		}
		store.attach(cx, function()
			cx:render()
		end)
		return state
	end,

	-- Only new posts from starred feeds count here: the pane title is for what matters, not a backlog.
	title = function(_state)
		local n = store.new_count(is_favorite)
		return if n > 0 then "RSS · ★ " .. n .. " new" else "RSS"
	end,

	view = function(state, cx)
		local feeds = store.feeds()
		if #feeds == 0 then
			return { main = ui.col(welcome_view(state)), dock = dock_view(state, cx, false) }
		end
		local latest = judge(state)
		local fav, per, shown = tally(latest)
		local function tab_label(text: string, n: number): { Span | string }
			return { text, span(tostring(n), "num") }
		end
		local parts: { Node } = {
			ui.node("tabs", {
				key = "tabs",
				active = state.tab,
				items = {
					{ id = "latest", label = tab_label("Latest ", shown) },
					{ id = "favorites", label = tab_label("★ Favorites ", fav) },
					{ id = "feeds", label = tab_label("Feeds ", #feeds) },
				},
			}),
		}
		if state.panel and state.tab == "latest" then
			panel_view(state, cx, parts, latest)
		elseif state.tab == "feeds" then
			feeds_view(state, cx, parts, per)
		else
			headlines_view(state, cx, parts, latest)
		end
		return { main = ui.col(parts), dock = dock_view(state, cx, true) }
	end,

	key = function(state, k, cx)
		local field = state.adding
		if field and field_shown(state) then
			return field_key(state, field, k, cx)
		elseif field then
			-- The view no longer draws the field (a feed arrived under the welcome view): drop it.
			close_field(state, cx)
		end
		if k.ctrl or k.alt or k.meta then
			return false
		end
		local n = k.name
		-- The no-feed offer, where it's drawn (welcome view, Feeds tab).
		if state.missed and offer_shown(state) then
			if n == "c" and not k.shift then
				ask_carly(state, cx)
				return true
			elseif n == "escape" then
				state.missed = nil
				state.confirm = nil
				return true
			end
		end
		-- The filter panel takes the keys while it is up on the Latest tab.
		if state.panel and state.tab == "latest" then
			return panel_key(state, k, cx)
		end
		if n == "paste" then
			local u = url.normalize(k.text or "")
			if u == nil then
				return false
			end
			open_field(state, cx, "add", u, nil)
			submit(state, cx)
			return true
		elseif n == "a" then
			open_field(state, cx, "add", nil, nil)
			return true
		elseif n == "f" and state.tab == "latest" then
			state.panel = true
			state.panel_at = math.clamp(state.panel_at, 1, #panel_rows())
			return true
		elseif n == "r" and not k.shift then
			store.refresh_all()
			return true
		elseif n == "b" and not k.shift then
			-- Shared by every RSS block (kv), so the window route sees it on the next click.
			local to: config.ReaderMode = if config.reader_mode() == "browser" then "native" else "browser"
			config.set_reader_mode(to)
			cx:toast("info", if to == "browser" then "Articles open in Tern's browser" else "Articles open in the reader")
			return true
		end

		if #store.feeds() == 0 then
			return welcome_key(state, k, cx)
		end

		local tab_index = table.find(TABS, state.tab) or 1
		if n == "1" or n == "2" or n == "3" then
			local tab: Tab = TABS[if n == "1" then 1 elseif n == "2" then 2 else 3]
			if tab == state.tab then
				return false
			end
			switch_tab(state, cx, tab)
			return true
		elseif n == "tab" then
			switch_tab(state, cx, TABS[(tab_index - 1 + (if k.shift then -1 else 1)) % #TABS + 1])
			return true
		end

		if k.text == "M" or (n == "m" and k.shift) then
			state.confirm = nil
			return catch_up(state)
		elseif k.text == "R" or (n == "r" and k.shift) then
			-- Headline tabs only: the Feeds list holds feeds, not posts.
			if state.tab == "feeds" then
				return false
			end
			return toggle_all_read(state)
		elseif n == "u" and not k.shift then
			return undo_catch_up(state)
		end

		if state.tab == "feeds" then
			return feeds_key(state, k, cx)
		end
		return headlines_key(state, k, cx)
	end,

	event = function(state, ev, cx)
		if ev.ev == "select" and ev.id == "main.tabs" then
			local tab: Tab? = as_tab(ev.item)
			if tab then
				switch_tab(state, cx, tab)
			end
		elseif ev.ev == "select" and ev.id == "main.items" then
			-- A click on the selected row does nothing: a double-click's first click lands here before
			-- its `activate`. Space, l/h and the card badges toggle the preview.
			local key = strip_prefix(ev.item, "main.items.")
			if key == nil then
				return
			end
			local current = selected_item(state, (headlines(state, state.tab)))
			if not (current and current.key == key) then
				set_sel(state, key)
			end
		elseif ev.ev == "activate" and ev.id == "main.items" then
			local key = strip_prefix(ev.item, "main.items.")
			local item = if key then find_item(key) else nil
			if item then
				visit(cx, item)
			end
		elseif ev.ev == "select" and ev.id == "main.feeds" then
			local id = strip_prefix(ev.item, "main.feeds.")
			-- Group headers are not feeds: a click on one keeps the selection where it is.
			if id and store.feed(id) ~= nil then
				if state.confirm ~= id then
					state.confirm = nil
				end
				state.sel.feeds = id
			end
		elseif ev.ev == "select" and ev.id == "main.filter" then
			local key = strip_prefix(ev.item, "main.filter.")
			if key then
				for i, row in panel_rows() do
					local row_key = if row.kind == "rule"
						then "r" .. tostring(row.index)
						elseif row.kind == "group" then "g:" .. (row.name or "")
						else "all"
					if row_key == key then
						state.panel_at = i
						break
					end
				end
			end
		elseif ev.ev == "action" then
			local act, value = ev.act, ev.value
			if act == "visit" or act == "mark" then
				local item = if value then find_item(value) else nil
				if item and act == "visit" then
					visit(cx, item)
				elseif item then
					toggle_read(item)
				end
			elseif act == "star" and value then
				store.toggle_favorite(value)
			elseif act == "remove" and value then
				remove_feed(state, value)
			elseif act == "add" then
				open_field(state, cx, "add", nil, nil)
			elseif act == "filter-open" then
				state.panel = true
				state.panel_at = math.clamp(state.panel_at, 1, #panel_rows())
			elseif act == "ask-carly" then
				ask_carly(state, cx)
			elseif act == "dismiss" then
				state.missed = nil
			elseif act == "starter" then
				local i = tonumber(value)
				if i then
					follow_starter(state, cx, i)
				end
			elseif act == "tab" then
				local tab: Tab? = as_tab(value)
				if tab then
					switch_tab(state, cx, tab)
				end
			end
		elseif ev.ev == "focus" and ev.id then
			cx:frame({ { "focus", ev.id } })
		end
	end,

	save = function(state)
		return { tab = state.tab, preview = state.preview, sel = state.sel, panel = state.panel, panel_at = state.panel_at }
	end,
}

return rss
