--!strict
-- The native reader: one article, fetched and drawn by a Tern block. The window half launches this
-- on an article URL (window.luau `tern-rss://read` route); this block fetches the page, splits it
-- into interleaved Markdown and image blocks (lib/feed.luau feed.article) and draws them in
-- document order: ui.md for text, ui.node("image") for pictures, inline where the article put them.
-- A page it can't read (error, non-HTML, too little text) is handed to Tern's browser through the
-- window's `tern-rss://browser` route, and this pane closes so the browser takes its place.
--
-- Launch arguments: the article URL, the RSS pane the reader sits beside (so the browser can take
-- over beside it) and the number of the click that opened it. Later articles arrive through the
-- RSS block's target file for that pane (lib/target.luau), which this block polls: the RSS block
-- records every click there before it opens the link, so the reader follows the latest click even
-- when it was opened for an earlier one. The window's plugin manifest declares this block with
-- palette = false, so the window route is its only caller.

local feed = require("../lib/feed")
local url = require("../lib/url")
local fmt = require("../lib/fmt")
local poll = require("../lib/poll")
local target_file = require("../lib/target")

local ui = tern.ui

local cards = require("../lib/cards")

-- A block, not a value: `state` is per pane, so two readers are two independent reads.
type State = {
	-- The article URL this reader is showing.
	target: string,
	-- Fetching, read (blocks there), or fallback (nothing to draw; the browser takes over).
	phase: "fetching" | "read" | "fallback",
	error: string?,
	blocks: { feed.ArticleBlock }?,
	-- The article's heading, when the container started with one: the header card shows it.
	title: string?,
	-- Image sources fetched so far, to their blob ids; "" marks one that failed.
	blobs: { [string]: string }?,
	-- Bumped by every load: a fetch that finishes for an older article sees a different number
	-- and drops its result.
	gen: number,
}

-- An image bigger than this isn't forwarded to the window (tern.fetch reads up to 16 MiB of any
-- response), so one article can't push more than 12 times this.
local IMAGE_BYTES_MAX = 4 * 1024 * 1024
-- How often the block checks its target file (and that its pane still exists).
local POLL_MS = 500
-- How long a click newer than the one a reader was launched for stays believable: the window may
-- take a moment to start the reader, and an older file means the link is stale or hand-made.
local FRESH_S = 30

-- Fetches one image and stores its blob id, then renders. Failures mark the source as "" and the
-- view draws its alt text instead: a source tern.fetch refuses (it raises), a bad status, an
-- empty or oversized body, or anything that isn't served as an image. `alive` says whether the
-- pane is still there to draw into.
local function fetch_image(state: State, cx: BlockCx, src: string, gen: number, alive: () -> boolean)
	local blobs = state.blobs
	if blobs == nil or blobs[src] ~= nil then
		return
	end
	local function settle(id: string)
		if state.gen ~= gen or not alive() then
			return
		end
		blobs[src] = id
		cx:render()
	end
	local ok = pcall(tern.fetch, src, nil, function(r: FetchResult, _cx: WindowCx?)
		if state.gen ~= gen then
			return
		end
		local bytes = if r and r.status < 400 and r.error == nil then r.body else nil
		local mime = if r then string.match(string.lower((r.headers or {})["content-type"] or ""), "^%s*([^;%s]+)") else nil
		if bytes == nil or #bytes == 0 or #bytes > IMAGE_BYTES_MAX or mime == nil or not string.find(mime, "^image/") then
			settle("")
			return
		end
		local blob_ok, id = pcall(function()
			return cx:blob(bytes, mime :: string)
		end)
		settle(if blob_ok then (id :: string) else "")
	end)
	if not ok then
		settle("")
	end
end

-- The article's first heading block, when the extraction began with one: it becomes the header
-- card's title instead of a `#` line the reader repeats below. The text is Markdown-escaped
-- (feed.article), and the title is drawn as a plain span, so the escapes come off.
local function pull_title(blocks: { feed.ArticleBlock }): string?
	local first = blocks[1]
	if first and first.kind == "md" and first.text then
		local level, text, after = string.match(first.text, "^(#+)%s*(%S[^\n]*)()")
		if level and text and after then
			local rest = string.sub(first.text, after)
			if string.match(rest, "%S") then
				first.text = rest
			else
				table.remove(blocks, 1)
			end
			return (string.gsub(text, "\\(%p)", "%1"))
		end
	end
	return nil
end

local reader: BlockDef<State> = {
	init = function(cx: BlockCx, args: { string }, _saved)
		local raw = args[1] or ""
		local owner = tonumber(args[2])
		local state: State = { target = raw, phase = "fetching", gen = 0 }
		-- The newest click this reader has applied. A click is anything the target file holds
		-- under another number. A link's own number is only believed when the file agrees with it
		-- or is newer and was written just now: a hand-made link (any `seq` it likes) or a click
		-- whose file write failed would otherwise show the file's older article instead of the
		-- link's, so a stale file is taken as already applied. A reader opened with no number
		-- starts from whatever the file holds, which is an older click's.
		local launched = tonumber(args[3])
		local seen_seq: number
		local latest = if owner then target_file.read(owner) else nil
		local fresh = latest ~= nil
			and launched ~= nil
			and latest.seq > launched
			and latest.at ~= nil
			and latest.at >= os.time() - FRESH_S
		if launched and (latest == nil or latest.seq == launched or fresh) then
			seen_seq = launched
		elseif latest then
			seen_seq = latest.seq
		else
			seen_seq = 0
		end

		-- Whether this pane still exists; once it doesn't, nothing here renders or opens anything
		-- (the window may have closed it for a newer article while a fetch was out). Checked once
		-- per callback, and the answer sticks: a late callback finds every gen stale. A pane the
		-- host hasn't listed yet (init runs first) is taken to exist until it has been seen once.
		local stopped = false
		local seen_pane = false
		local settled = false -- init has returned: every later call is a callback or a tick
		local function alive(): boolean
			if stopped then
				return false
			end
			local ok, here = pcall(poll.alive, cx.pane)
			if ok and here then
				seen_pane = true
			elseif ok and (seen_pane or settled) then
				stopped = true
				state.gen += 1
				return false
			end
			return true
		end

		-- Declared ahead: handing off first looks for a newer click, which loads it.
		local check_target: (handing: boolean) -> boolean
		local handed = false

		-- Hands the article to Tern's browser, once, and closes this pane: the window's browser
		-- route docks it where the reader sat, and only accepts it from this pane, so a reader the
		-- window has already replaced can't pull the browser away from the user's last click. With
		-- no RSS pane to dock beside (a reader launched by hand), Tern's own link handling opens it.
		-- A click that arrived since the page was requested names another article: that one is
		-- shown instead.
		local function hand_off(why: string)
			if handed or not alive() then
				return
			end
			if check_target(true) then
				return
			end
			state.phase = "fallback"
			state.error = why
			cx:render()
			handed = true
			if string.find(state.target, "^https?://") then
				if owner then
					cx:open(`tern-rss://browser/{owner}?from={cx.pane}&url={url.encode(state.target)}`)
				else
					cx:open(state.target)
				end
			end
			cx:exit(0)
		end

		-- Loads `at` (a normalized URL) into `state`, from a clean slate, and re-renders.
		local function load(at: string)
			state.gen += 1
			local gen = state.gen
			state.target = at
			state.phase = "fetching"
			state.blocks = nil
			state.title = nil
			state.blobs = {}
			state.error = nil
			cx:render()
			local sent = pcall(tern.fetch, at, nil, function(r: FetchResult, _cx: WindowCx?)
				-- A fetch for an article the user has since moved past, or for a pane that is
				-- gone, must not draw over the new one or open anything.
				if state.gen ~= gen or not alive() then
					return
				end
				if r == nil or r.status >= 400 or r.error ~= nil then
					hand_off(
						if r == nil then "The page didn't answer."
							elseif r.error then r.error
							else `The page answered {r.status}.`
					)
					return
				end
				local ctype = (r.headers or {})["content-type"] or ""
				if not (feed.is_html(r.body, ctype) or string.find(ctype, "html", 1, true)) then
					hand_off("That URL isn't an article page.")
					return
				end
				local article = feed.article(r.body, at, ctype)
				if #article.text < 400 then
					hand_off("Couldn't extract this page's text.")
					return
				end
				state.phase = "read"
				state.blocks = article.blocks
				state.title = pull_title(article.blocks)
				cx:render()
				for _, b in article.blocks do
					if b.kind == "img" and b.src then
						fetch_image(state, cx, b.src, gen, alive)
					end
				end
			end)
			if not sent then
				hand_off("That address can't be fetched.")
			end
		end

		-- Reads the RSS block's target file for a click this reader hasn't applied. Returns whether
		-- it took over (loaded another article, or handed one off) rather than left things as they
		-- are. `handing`: called from hand_off, which carries on by itself unless this loaded a page;
		-- an address that can't be fetched becomes the hand-off's own target then.
		check_target = function(handing: boolean): boolean
			if owner == nil or handed then
				return false
			end
			local latest = target_file.read(owner)
			if latest == nil or latest.seq == seen_seq then
				return false
			end
			seen_seq = latest.seq
			local at = url.normalize(latest.url)
			if at == nil then
				state.target = latest.url
				if not handing then
					hand_off("That address can't be fetched.")
				end
				return not handing
			end
			if at == state.target then
				return false
			end
			load(at)
			return true
		end

		-- Re-arms until the pane is gone (blocks have no close hook). One failed tick never stops
		-- the loop.
		local warned = false
		local function tick()
			if handed or not alive() then
				return
			end
			local ok, err = pcall(check_target, false)
			if not ok and not warned then
				warned = true
				tern.log.warn("tern-rss reader: target check failed", err)
			end
			tern.timer(POLL_MS, tick)
		end

		local first = if raw ~= "" then url.normalize(raw) else nil
		if first == nil then
			hand_off("That address can't be fetched.")
		elseif not check_target(false) then
			load(first)
		end
		if not handed then
			tern.timer(POLL_MS, tick)
		end
		settled = true
		return state
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		if state.phase == "fallback" then
			return {
				main = ui.col({
					cards.error(
						"Couldn't read this article here",
						state.error or "No text came out of that page.",
						{ detail = "Opening it in Tern's browser instead." }
					),
				}),
			}
		end
		if state.phase == "fetching" then
			return {
				main = ui.col({
					ui.node("spinner", { key = "fetch", style = "dots", label = { ui.span("Reading the page…") } }),
				}),
			}
		end
		local blobs = state.blobs or {}
		local parts: { Node } = {}
		local blocks: { feed.ArticleBlock } = state.blocks or {}
		for i, b in blocks do
			if b.kind == "md" and b.text then
				table.insert(parts, cards.with(ui.md(b.text), { key = "b" .. i }))
			elseif b.kind == "img" and b.src then
				local id = blobs[b.src]
				local props: { [string]: any } = { key = "b" .. i, alt = b.alt or "image" }
				if b.w and b.w > 0 then
					props.w = b.w
				end
				if b.h and b.h > 0 then
					props.h = b.h
				end
				if id ~= nil and id ~= "" then
					props.blob = id
					table.insert(parts, ui.node("image", props))
				elseif id == nil then
					-- Still out: the placeholder names it, and the blob swap-in is one prop change.
					table.insert(parts, ui.node("image", props))
				else
					table.insert(parts, cards.with(ui.text({ ui.span("⌫ " .. (b.alt or "image failed"), "muted") }), { key = "f" .. i }))
				end
			end
		end
		local head: { Span | string } = { ui.span(state.title or "Article", "strong") }
		local header = cards.with(
			ui.card(head, {
				cards.with(
					ui.kv({
						{ "From", ui.link(url.host(state.target), state.target, "muted") },
					}),
					{ key = "meta" }
				),
			}),
			{ key = "head" }
		)
		return { main = ui.col({ header, table.unpack(parts) }) }
	end,

	title = function(state: State): string?
		if state.phase == "fallback" then
			return "Reader"
		end
		local t = state.title
		if t and #t > 4 then
			return "Reader · " .. fmt.clip(t, 40)
		end
		return "Reader · " .. url.host(state.target)
	end,
}

return reader
