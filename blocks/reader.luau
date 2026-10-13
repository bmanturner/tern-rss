--!strict
-- The native reader: one article, fetched and drawn by a Tern block. The window half launches this
-- on an article URL (window.luau `tern-rss://read` route); this block fetches the page, splits it
-- into interleaved Markdown and image blocks (lib/feed.luau feed.article) and draws them in
-- document order: ui.md for text, ui.node("image") for pictures, inline where the article put them.
-- A page it can't read (error, non-HTML, too little text) is handed to Tern's browser through the
-- window's `tern-rss://browser` route, and this pane closes so the browser takes its place.
--
-- Launch arguments: the article URL, then the RSS pane the reader sits beside (so the browser can
-- take over beside it). Later articles arrive through the per-pane target file below. The window's
-- plugin manifest declares this block with palette = false, so the window route is its only caller.

local feed = require("../lib/feed")
local url = require("../lib/url")
local fmt = require("../lib/fmt")
local poll = require("../lib/poll")

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

-- Fetches one image and stores its blob id, then renders. Failures mark the source as "" and the
-- view draws its alt text instead. A source tern.fetch refuses (it raises) is one such failure.
local function fetch_image(state: State, cx: BlockCx, src: string, gen: number)
	local blobs = state.blobs
	if blobs == nil or blobs[src] ~= nil then
		return
	end
	local function settle(id: string)
		if state.gen ~= gen then
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
		local mime = if r then ((r.headers or {})["content-type"] or "image/png") else "image/png"
		local blob_ok, id = pcall(function()
			return cx:blob(bytes or "", mime)
		end)
		settle(if blob_ok and bytes and #bytes > 0 then (id :: string) else "")
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
		if level then
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

-- Where the window half points a running reader at the next article: it writes
-- `reader-<pane>.json` ({"url": …}) and the block re-reads on change. One file per reader pane, so
-- every reader follows only its own clicks.
local TARGET_DIR = tern.plugin.data
-- How often the block checks its file (and that its pane still exists).
local POLL_MS = 500

local function target_path(pane: number): string
	return `{TARGET_DIR}/reader-{pane}.json`
end

local reader: BlockDef<State> = {
	init = function(cx: BlockCx, args: { string }, _saved)
		local target = if #args > 0 then url.normalize(args[1]) else nil
		if target == nil then
			return { target = "", phase = "fallback", error = "No article URL.", gen = 0 }
		end
		local owner = if args[2] then tonumber(args[2]) else nil
		local state: State = { target = target, phase = "fetching", gen = 0 }
		local path = target_path(cx.pane)

		-- Hands the article to Tern's browser, once, and closes this pane: the window's browser
		-- route docks it where the reader sat. With no RSS pane to dock beside (a reader launched
		-- by hand), Tern's own link handling opens it.
		local handed = false
		local function hand_off(why: string)
			state.phase = "fallback"
			state.error = why
			cx:render()
			if handed then
				return
			end
			handed = true
			if owner then
				cx:open(`tern-rss://browser/{owner}?url={url.encode(state.target)}`)
			else
				cx:open(state.target)
			end
			pcall(tern.fs.remove, path)
			cx:exit(0)
		end

		-- Loads `at` into `state`, from a clean slate, and re-renders.
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
			-- A fetch for an article the user has since moved past must not draw over the new one.
			local function current(): boolean
				return state.gen == gen
			end
			local sent = pcall(tern.fetch, at, nil, function(r: FetchResult, _cx: WindowCx?)
				if not current() then
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
				local article = feed.article(r.body, at)
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
						fetch_image(state, cx, b.src, gen)
					end
				end
			end)
			if not sent then
				hand_off("That address can't be fetched.")
			end
		end

		-- The window half names the next article in this pane's target file. A half-written file
		-- fails to decode and is read again on the next tick.
		local function check_target()
			local ok, exists = pcall(tern.fs.exists, path)
			if not (ok and exists) then
				return
			end
			local read_ok, text = pcall(tern.fs.read, path)
			if not read_ok or text == nil then
				return
			end
			local decode_ok, doc = pcall(tern.json.decode, text)
			if not decode_ok or type(doc) ~= "table" or type((doc :: any).url) ~= "string" then
				return
			end
			local at = url.normalize((doc :: any).url)
			if at ~= nil and at ~= state.target then
				load(at)
			end
		end

		-- Re-arms until the pane is gone (blocks have no close hook), then removes its file. One
		-- failed tick never stops the loop.
		local warned = false
		local function tick()
			local alive_ok, alive = pcall(poll.alive, cx.pane)
			if alive_ok and not alive then
				pcall(tern.fs.remove, path)
				return
			end
			local ok, err = pcall(check_target)
			if not ok and not warned then
				warned = true
				tern.log.warn("tern-rss reader: target check failed", err)
			end
			tern.timer(POLL_MS, tick)
		end

		load(target)
		tern.timer(POLL_MS, tick)
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
		for i, b in state.blocks or {} do
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
