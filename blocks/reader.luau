--!strict
-- The native reader: one article, fetched and drawn by a Tern block. The RSS block launches this
-- on an article URL (blocks/rss.luau `visit`); this block fetches the page, splits it into
-- interleaved Markdown and image blocks (lib/feed.luau feed.article) and draws them in document
-- order: ui.md for text, ui.node("image") for pictures, inline where the article put them. A page
-- whose text cannot be extracted falls back to the window's browser route.
--
-- Launch takes the article URL as its only argument. The window's plugin manifest declares this
-- block with palette = false, so the RSS block is its only caller.

local feed = require("../lib/feed")
local url = require("../lib/url")
local fmt = require("../lib/fmt")

local ui = tern.ui

local cards = require("../lib/cards")

-- A block, not a value: `state` is per pane, so two readers are two independent reads.
type State = {
	-- The article URL this reader was launched with.
	target: string,
	-- Fetching, read (blocks there), or fallback (nothing to draw; the caller opens the browser).
	phase: "fetching" | "read" | "fallback",
	error: string?,
	blocks: { feed.ArticleBlock }?,
	-- The article's heading, when the container started with one: the header card shows it.
	title: string?,
	-- Image sources fetched so far, to their blob ids; "" marks one that failed.
	blobs: { [string]: string }?,
	-- How many image fetches are still out.
	pending: number,
}

-- The most images one article shows.
-- Fetches one image and stores its blob id, then renders. Failures mark the source as "" and the
-- view draws its alt text instead.
local function fetch_image(state: State, cx: BlockCx, src: string)
	local blobs = state.blobs
	if blobs == nil or blobs[src] ~= nil then
		return
	end
	state.pending += 1
	tern.fetch(src, nil, function(r: FetchResult, _cx: WindowCx?)
		state.pending -= 1
		local bytes = if r and r.status < 400 and r.error == nil then r.body else nil
		local mime = if r then ((r.headers or {})["content-type"] or "image/png") else "image/png"
		local ok, id = pcall(function()
			return cx:blob(bytes or "", mime)
		end)
		if blobs then
			blobs[src] = if ok and bytes and #bytes > 0 then (id :: string) else ""
		end
		cx:render()
	end)
end

-- The article's first heading block, when the extraction began with one: it becomes the header
-- card's title instead of a `#` line the reader repeats below.
local function pull_title(blocks: { feed.ArticleBlock }): string?
	local first = blocks[1]
	if first and first.kind == "md" and first.text then
		local level, text = string.match(first.text, "^(#+)%s*(%S[^\n]*)")
		if level then
			local rest = string.sub(first.text, #level + #text + 1)
			if string.match(rest, "%S") then
				first.text = rest
			else
				table.remove(blocks, 1)
			end
			return text
		end
	end
	return nil
end

-- Where the window half points this reader: it rewrites the file and the block re-reads on change.
local TARGET_PATH = tern.plugin.data .. "/reader-target.txt"
-- How often the block checks that file, and how long it stays quiet once nothing changes.
local POLL_MS = 1000

local reader: BlockDef<State> = {
	init = function(cx: BlockCx, args: { string }, _saved)
		local target = if #args > 0 then url.normalize(args[1]) else nil
		if target == nil or not string.find(target, "^https?://") then
			return { target = "", phase = "fallback", error = "No article URL.", pending = 0 }
		end
		local state: State = { target = target, phase = "fetching", pending = 0 }

		-- Loads `target` into `state`, from a clean slate, and re-renders.
		local function load(at: string)
			state.target = at
			state.phase = "fetching"
			state.blocks = nil
			state.title = nil
			state.blobs = {}
			state.error = nil
			state.pending = 0
			cx:render()
			tern.fetch(at, nil, function(r: FetchResult, _cx: WindowCx?)
				if r == nil or r.status >= 400 or r.error ~= nil then
					state.phase = "fallback"
					state.error = if r == nil then "The page didn't answer."
						elseif r.error then r.error
						else `The page answered {r.status}.`
					cx:render()
					return
				end
				local ctype = (r.headers or {})["content-type"] or ""
				if not (feed.is_html(r.body, ctype) or string.find(ctype, "html", 1, true)) then
					state.phase = "fallback"
					state.error = "That URL isn't an article page."
					cx:render()
					return
				end
				local article = feed.article(r.body, at)
				if #article.text < 400 then
					state.phase = "fallback"
					state.error = "Couldn't extract this page's text."
					cx:render()
					return
				end
				state.phase = "read"
				state.blocks = article.blocks
				state.title = pull_title(article.blocks)
				cx:render()
				for _, b in article.blocks do
					if b.kind == "img" and b.src then
						fetch_image(state, cx, b.src)
					end
				end
			end)
		end

		-- The window half points one reader at every article: when it rewrites the target file,
		-- this re-reads. The pane itself is never closed and reopened.
		local function poll()
			local ok, exists = pcall(tern.fs.exists, TARGET_PATH)
			if ok and exists then
				local ok2, text = pcall(tern.fs.read, TARGET_PATH)
				if ok2 and text ~= nil then
					local at = url.normalize(text)
					if at ~= state.target and string.find(at, "^https?://") then
						load(at)
					end
				end
			end
			tern.timer(POLL_MS, poll)
		end

		load(target)
		tern.timer(POLL_MS, poll)
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
				if props.w == nil and props.h == nil then
					-- No declared size: a default box keeps the layout stable while the bytes are
					-- out, instead of collapsing to the alt-text height.
					props.w, props.h = 640, 360
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
