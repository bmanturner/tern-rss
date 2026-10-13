--!strict
-- Tern RSS window half: one "Open <title>" command per declared block, the article routes and the
-- Carly hand-off.
-- Articles: an RSS block opens one with cx:open("tern-rss://read/<pane>?url=<encoded>"). The route
-- shows it in one article pane docked right of that RSS pane: the native reader block
-- (blocks/reader.luau), reused for later articles and reopened when the user closed it, or Tern's
-- browser when the `reader` setting (config/block/rss/reader) says "browser". A reader that can't
-- read a page asks for the browser with "tern-rss://browser/<pane>?url=<encoded>", and the browser
-- replaces it, so an RSS pane never has two article panes. The RSS pane rides in the URL because
-- link.pane is the focused pane; any program can print such a link, so the routes dock only beside
-- a real RSS block pane and leave other links to Tern's own link handling.
-- Carly: when the user asks Carly to find a site's feed, the RSS block writes a request file and opens
-- "tern-rss://carly/<id>"; the route asks Carly once per request, about the site in that file (never
-- text from the link), and Carly answers through the `found` / `not_found` exports, which write the
-- answer where the block's store polls for it (see lib/carly.luau).

local manifest = require("./lib/manifest")
local url = require("./lib/url")
local carly = require("./lib/carly")
local config = require("./lib/config")

-- RSS pane -> the article pane beside it, and what that pane is. Window state persists between
-- route calls (observed); a pane that has since closed is noticed through the session, never
-- trusted from this table.
type Article = { pane: number, kind: "reader" | "browser" }
local articles: { [number]: Article } = {}

-- `pane`'s record in this window's session, or nil when it is gone. `cx.session:pane` raises for
-- some ids, so a failure counts as gone.
local function pane_info(cx: WindowCx, pane: number): PaneInfo?
	local ok, info = pcall(function()
		return cx.session:pane(pane)
	end)
	if ok then
		return info
	end
	return nil
end

-- The article pane beside RSS pane `owner` if it is still open and still what we docked there (a
-- pane id Tern reused for something else must not be hijacked); forgets it otherwise.
local function live_article(cx: WindowCx, owner: number): Article?
	local art = articles[owner]
	if art == nil then
		return nil
	end
	local info = pane_info(cx, art.pane)
	local same = info ~= nil
		and if art.kind == "browser" then info.kind == "browser" else info.kind == "plugin" and info.block == tern.plugin.id .. ".reader"
	if not same then
		articles[owner] = nil
		return nil
	end
	return art
end

-- Closes article pane `pane`, which is being replaced, and drops the target file a reader there
-- would have read. Failure leaves the pane open; nothing else to do.
local function close_article(cx: WindowCx, pane: number)
	pcall(function()
		cx.layout:close(pane)
	end)
	pcall(tern.fs.remove, `{tern.plugin.data}/reader-{pane}.json`)
end

-- Points the reader in `pane` at `target`: it reads reader-<pane>.json and re-fetches when the URL
-- changes. A plugin block pane's launch arguments are fixed, so this is the only way to send a
-- running reader somewhere else.
local function point_reader(pane: number, target: string)
	pcall(tern.fs.write, `{tern.plugin.data}/reader-{pane}.json`, tern.json.encode({ url = target }))
end

-- How long `found` waits for the RSS block to try Carly's URL, polling its result file.
local FOUND_WAIT_MS = 90000
local FOUND_POLL_MS = 500

-- Opens the block `how`: beside the focused pane, or alone in a new tab. A new tab gets the whole
-- width, which is what a reading session wants; "beside" is the sidebar the block has always used.
local function open_block(cx: WindowCx, decl_id: string, title: string, how: How)
	if cx:new_block(tern.plugin.id .. "." .. decl_id, nil, how) == nil then
		cx:toast("error", title .. " is not loaded on this host", "Run `tern plugin list` to see why.")
	end
end

for _, decl in manifest.blocks() do
	-- A block the manifest marks `palette = false` is opened by a caller, not from the palette:
	-- the reader is launched on an article URL, so a palette row for it would open a blank one.
	if not decl.palette then
		continue
	end
	tern.command({
		id = "open-" .. decl.id,
		title = "Open " .. decl.title,
		run = function(cx)
			open_block(cx, decl.id, decl.title, "beside")
		end,
	})
	tern.command({
		id = "open-" .. decl.id .. "-tab",
		title = "Open " .. decl.title .. " in a new tab",
		run = function(cx)
			open_block(cx, decl.id, decl.title, "tab")
		end,
	})
end

-- Opens `target` in a new browser over `owner`, then docks it right without taking focus, so the
-- RSS list keeps the keyboard. `replace` is the article pane the browser takes the place of; it is
-- closed once the browser is up. Falls back to Tern's built-in link handling when no browser opens.
local function open_browser(cx: WindowCx, owner: number, target: string, replace: number?)
	cx.browser:call({ op = "open", owner = owner, url = target }):next(function(res, err, wcx)
		local block = res and res.ok and tonumber(res.ok.block)
		if wcx == nil then
			return
		end
		if block then
			articles[owner] = { pane = block, kind = "browser" }
			wcx.layout:dock(block, owner, "right", { focus = false })
			if replace and replace ~= block then
				close_article(wcx, replace)
			end
		else
			tern.log.warn("tern-rss: browser open failed", err or (res and res.error and res.error.message))
			wcx:open(target)
		end
	end)
end

-- Shows `target` in Tern's browser beside `owner`: the browser already there navigates, anything
-- else (the reader) is replaced by a new one.
local function show_browser(cx: WindowCx, owner: number, target: string)
	local art = live_article(cx, owner)
	if art and art.kind == "browser" then
		cx.browser:call({ op = "goto", block = art.pane, url = target }):next(function(res, err, wcx)
			if wcx and (err or (res and res.error)) then
				open_browser(wcx, owner, target, art.pane)
			end
		end)
		return
	end
	open_browser(cx, owner, target, if art then art.pane else nil)
end

-- Shows `target` in the native reader docked right of `owner` without taking focus: a running
-- reader is pointed at it, otherwise one opens (replacing a browser left there).
local function show_reader(cx: WindowCx, owner: number, target: string)
	local art = live_article(cx, owner)
	if art and art.kind == "reader" then
		point_reader(art.pane, target)
		cx.layout:dock(art.pane, owner, "right", { focus = false })
		return
	end
	local block = cx:new_block(tern.plugin.id .. ".reader", { target, tostring(owner) }, "beside", { focus = false })
	if block == nil then
		-- No reader block on this host (an older install): the browser is the honest fallback.
		tern.log.warn("tern-rss: no native reader block on this host; using the browser")
		show_browser(cx, owner, target)
		return
	end
	articles[owner] = { pane = block, kind = "reader" }
	cx.layout:dock(block, owner, "right", { focus = false })
	if art then
		close_article(cx, art.pane)
	end
end

-- Records Carly's next answer for search `id`: its number, or nil when no such search is open.
local function answer(id: any, feed_url: string?, reason: string?): number?
	if not carly.valid_id(id) or carly.read(id, "request") == nil then
		return nil
	end
	local prev = carly.read(id, "answer")
	local n = (if type(prev) == "table" and type(prev.n) == "number" then prev.n else 0) + 1
	if not carly.write(id, "answer", { n = n, url = feed_url, reason = reason }) then
		return nil
	end
	return n
end

-- Asks Carly about request `id`, once. Unknown ids (a forged link, or a remote host's block whose data
-- folder this window can't see) are ignored silently.
local function ask_carly(cx: WindowCx, id: string)
	if not carly.valid_id(id) then
		return
	end
	local req = carly.read(id, "request")
	if type(req) ~= "table" or type(req.site) ~= "string" or url.normalize(req.site) ~= req.site then
		return
	end
	local site: string = req.site
	if carly.read(id, "asked") ~= nil or not carly.write(id, "asked", { at = os.time() }) then
		return
	end
	local ok, err = pcall(function()
		cx:ask_carly(carly.prompt(id, site))
	end)
	if not ok then
		tern.log.warn("tern-rss: ask_carly failed", err)
		answer(id, nil, "Carly isn't available in this window.")
	end
end

-- Whether `pane` is one of this plugin's RSS blocks in this window's session: a forged link names
-- no real pane, or some other pane.
local function is_rss_pane(cx: WindowCx, pane: number): boolean
	local info = pane_info(cx, pane)
	return info ~= nil and info.kind == "plugin" and info.block == tern.plugin.id .. ".rss"
end

tern.carly.export("found", {
	sig = "(request: string, feed_url: string) -> {ok: boolean, title: string?, error: string?}",
	doc = "Answers an RSS block find-a-feed request with the feed URL you found. The RSS block follows it and "
		.. "answers {ok = true, title} once it does, or {ok = false, error} when the URL isn't a feed it can read; "
		.. "then try another URL or call not_found.",
}, function(request: any, feed_url: any, _cx: WindowCx, call: ExportCall)
	if type(feed_url) ~= "string" or not string.find(feed_url, "^https?://") then
		return { ok = false, error = "feed_url must be an http(s) URL." }
	end
	local n = answer(request, feed_url, nil)
	if n == nil then
		return { ok = false, error = "No open find-a-feed request " .. tostring(request) .. "." }
	end
	local waited = 0
	local function check()
		if call.cancelled then
			return
		end
		local res = carly.read(request, "result")
		if type(res) == "table" and res.n == n then
			call:reply({ ok = res.ok == true, title = res.title, error = res.error })
			return
		end
		waited += FOUND_POLL_MS
		if waited >= FOUND_WAIT_MS then
			call:reply({ ok = false, error = "The RSS block didn't answer in time; it may still follow the feed." })
			return
		end
		tern.timer(FOUND_POLL_MS, check)
	end
	tern.timer(FOUND_POLL_MS, check)
	return call:wait(FOUND_WAIT_MS + 5000)
end)

tern.carly.export("not_found", {
	sig = "(request: string, reason: string) -> boolean",
	doc = "Answers an RSS block find-a-feed request when the site has no RSS or Atom feed. reason is one "
		.. "sentence shown to the user in a toast. Returns false when no such request is open.",
}, function(request: any, reason: any, _cx: WindowCx, _call: ExportCall)
	local text = if type(reason) == "string" and string.find(reason, "%S") then reason else nil
	return answer(request, nil, text) ~= nil
end)

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local id = string.match(link.url, "^tern%-rss://carly/(%x+)$")
	if id then
		ask_carly(cx, id)
		return { handled = true }
	end
	local route, pane, encoded = string.match(link.url, "^tern%-rss://(%a+)/(%d+)%?url=(.+)$")
	if (route ~= "read" and route ~= "browser") or pane == nil or encoded == nil then
		return nil
	end
	local target = url.decode(encoded)
	if not string.find(target, "^https?://") then
		return { handled = true }
	end
	local owner = tonumber(pane) :: number
	if not is_rss_pane(cx, owner) then
		return { url = target }
	end
	-- The setting is read per click: the RSS block's `b` key flips it while this half runs on.
	if route == "browser" or config.reader_mode() == "browser" then
		show_browser(cx, owner, target)
	else
		show_reader(cx, owner, target)
	end
	return { handled = true }
end)
