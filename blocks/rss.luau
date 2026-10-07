--!strict
-- The `rss` block (host half): a river of headlines under three tabs (Latest, ★ Favorites, Feeds).
-- Feeds, read state, caches and polling live in lib/store, shared by every RSS block; this file is the
-- view, the keys and the clicks. Articles open through the window's `tern-rss://read/<pane>` route,
-- which docks one reader browser beside the block and reuses it.

local store = require("../lib/store")
local url = require("../lib/url")
local fmt = require("../lib/fmt")
local cards = require("../lib/cards")

local ui = tern.ui
local span = ui.span

type Tab = "latest" | "favorites" | "feeds"

type Field = {
	text: string,
	-- Byte offset of the caret (bytes before it).
	cursor: number,
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

-- The headlines a tab draws, at most MAX_ROWS: posts new since the last catch-up first, then the
-- rest, each group newest first. Also returns how many were left out and how many rows are new.
local function headlines(tab: Tab): ({ store.Item }, number, number)
	local fresh: { store.Item } = {}
	local older: { store.Item } = {}
	for _, it in store.items() do
		if tab ~= "favorites" or is_favorite(it) then
			if store.is_new(it) then
				table.insert(fresh, it)
			else
				table.insert(older, it)
			end
		end
	end
	local out: { store.Item } = {}
	for _, group in { fresh, older } do
		for _, it in group do
			if #out >= MAX_ROWS then
				break
			end
			table.insert(out, it)
		end
	end
	return out, #fresh + #older - #out, math.min(#fresh, MAX_ROWS)
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

local function find_item(key: string): store.Item?
	for _, it in store.items() do
		if it.key == key then
			return it
		end
	end
	return nil
end

-- New unread posts: all, favorite feeds only, and per feed id.
local function tally(): (number, number, { [string]: number })
	local all, fav = 0, 0
	local per: { [string]: number } = {}
	for _, it in store.items() do
		if not store.is_read(it.key) and store.is_new(it) then
			all += 1
			per[it.feed] = (per[it.feed] or 0) + 1
			if is_favorite(it) then
				fav += 1
			end
		end
	end
	return all, fav, per
end

-- Feed ids a catch-up covers: every feed on Latest, starred ones on Favorites, the selected one on Feeds.
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
	for _, f in feeds do
		if state.tab == "latest" or f.favorite then
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

local function open_field(state: State, cx: BlockCx, prefill: string?)
	local text = prefill or ""
	state.adding = { text = text, cursor = #text }
	state.add_error = nil
	state.missed = nil
	state.confirm = nil
	if #store.feeds() > 0 then
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
local function field_shown(state: State): boolean
	return state.tab == "feeds" or #store.feeds() == 0
end

local function submit(state: State, cx: BlockCx)
	local field = state.adding
	if field == nil or state.add_busy == field then
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
	elseif k.text and k.text ~= "" and not (k.ctrl or k.meta) then
		f.text = string.sub(text, 1, cursor) .. k.text .. string.sub(text, cursor + 1)
		f.cursor = cursor + #k.text
	else
		return false
	end
	state.add_error = nil
	return true
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

local function visit(cx: BlockCx, item: store.Item)
	local link = item.link
	if link == nil then
		cx:toast("error", "This post has no link")
		return
	end
	store.set_read(item.key, true)
	cx:open("tern-rss://read/" .. cx.pane .. "?url=" .. url.encode(link))
end

local function toggle_read(item: store.Item)
	store.set_read(item.key, not store.is_read(item.key))
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

local function add_nodes(state: State, f: Field): { Node }
	local prefix = string.sub(f.text, 1, f.cursor)
	local nodes: { Node } = {
		ui.node("input", {
			key = "add",
			text = f.text,
			cursor = if utf8.len(prefix) then utf16_len(prefix) else f.cursor,
			placeholder = "Paste a site or feed URL, then press Enter",
			prompt = { span("+ ", "accent") },
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

local function headlines_view(state: State, cx: BlockCx, parts: { Node })
	local rows, hidden, n_new = headlines(state.tab)
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
	local now = os.time()
	-- The divider sits where the user last caught up: under the new posts, or on top when none are new.
	local caught = caught_up_at(state.tab)
	local divider_before = if caught and n_new < #rows then n_new + 1 else nil
	-- Narrow panes squeeze the feed name to "…" fragments: drop it there and mark favorites in the label.
	local narrow = cx.cols < 90
	local children: { Node } = {}
	for i, it in rows do
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
			max = { lines = rows_fitting(cx.rows - 8, 6) },
		}, children)
	)
	if hidden > 0 then
		table.insert(parts, cards.with(ui.text({ span("… " .. plural(hidden, "older headline", "older headlines"), "muted") }), {
			key = "more",
		}))
	end
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
	for _, f in feeds do
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
			max = { lines = rows_fitting(cx.rows - 12, 4) },
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
local function hints_text(state: State, cx: BlockCx, has_feeds: boolean): Node
	local narrow = cx.cols < 70
	local tiny = cx.cols < 56
	local catch: { string } = if state.undo then { "u", "undo" } else { "shift+m", "catch up" }
	local pairs: { { string } }
	if not has_feeds then
		pairs = { { "enter", "follow" }, { "j", "" }, { "k", "move" }, { "a", "add" } }
	elseif state.tab == "feeds" then
		pairs = if tiny
			then { { "s", "star" }, catch, { "d", "remove" } }
			else { { "s", "star" }, catch, { "d", "remove" }, { "a", "add" }, { "r", "refresh" } }
		if narrow and not tiny then
			table.remove(pairs, 4)
		end
	elseif tiny then
		pairs = { { "enter", "open" }, { "space", "peek" }, catch }
	else
		pairs = { { "enter", "open" }, { "space", if narrow then "peek" else "preview" }, { "m", "read" }, catch, { "a", "add" }, { "r", "refresh" } }
		if narrow then
			table.remove(pairs, 5)
		end
	end
	local spans: { Span | string } = {}
	for i, pair in pairs do
		if i > 1 and pairs[i - 1][2] ~= "" then
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
	local items: { Node } = { hints_text(state, cx, has_feeds) }
	local status: { Node } = {}
	local busy = store.busy()
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
	local failing = 0
	for _, f in store.feeds() do
		if store.status(f.id).state == "error" then
			failing += 1
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
	return ui.col({ cards.with(ui.row(items), { key = "bar" }) })
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
	local rows = headlines(state.tab)
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

local function feeds_key(state: State, k: Key): boolean
	local feeds = store.feeds()
	local feed, index = selected_feed(state, feeds)
	local n = k.name
	if feed and (n == "d" or n == "delete" or n == "backspace") then
		remove_feed(state, feed.id)
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
		local all, fav, per = tally()
		local function tab_label(text: string, n: number): { Span | string }
			return { text, span(tostring(n), "num") }
		end
		local parts: { Node } = {
			ui.node("tabs", {
				key = "tabs",
				active = state.tab,
				items = {
					{ id = "latest", label = tab_label("Latest ", all) },
					{ id = "favorites", label = tab_label("★ Favorites ", fav) },
					{ id = "feeds", label = tab_label("Feeds ", #feeds) },
				},
			}),
		}
		if state.tab == "feeds" then
			feeds_view(state, cx, parts, per)
		else
			headlines_view(state, cx, parts)
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
		if state.missed and field_shown(state) then
			if n == "c" and not k.shift then
				ask_carly(state, cx)
				return true
			elseif n == "escape" then
				state.missed = nil
				state.confirm = nil
				return true
			end
		end
		if n == "paste" then
			local u = url.normalize(k.text or "")
			if u == nil then
				return false
			end
			open_field(state, cx, u)
			submit(state, cx)
			return true
		elseif n == "a" then
			open_field(state, cx)
			return true
		elseif n == "r" then
			store.refresh_all()
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
		elseif n == "u" and not k.shift then
			return undo_catch_up(state)
		end

		if state.tab == "feeds" then
			return feeds_key(state, k)
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
			local current = selected_item(state, (headlines(state.tab)))
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
			if id then
				if state.confirm ~= id then
					state.confirm = nil
				end
				state.sel.feeds = id
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
				open_field(state, cx)
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
		return { tab = state.tab, preview = state.preview, sel = state.sel }
	end,
}

return rss
