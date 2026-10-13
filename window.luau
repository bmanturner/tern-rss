--!strict
-- Tern RSS window half: one "Open <title>" command per declared block, the article routes and the
-- Carly hand-off.
-- Articles: an RSS block opens one with
-- cx:open("tern-rss://read/<pane>?url=<encoded>&seq=<click>&mode=<native|browser>"). The route shows
-- it in one article pane docked right of that RSS pane: the native reader block
-- (blocks/reader.luau), reused for later articles and reopened when the user closed it, or Tern's
-- browser. The RSS block, which runs where the reader runs, decides which (its `reader` setting,
-- config/block/rss/reader) and sends the choice in the link; the window follows it. It also records
-- each click in a file the reader polls (lib/target.luau), so the window never writes files and
-- works the same for a remote host. A reader that can't read a page asks for the browser with
-- "tern-rss://browser/<pane>?from=<reader pane>&url=<encoded>"; the window honours it only from
-- the article pane it has beside that RSS pane, and the browser replaces the reader, so an RSS pane
-- never has two article panes and a reader that was already replaced can't pull the browser away
-- from the user's last click. The RSS pane rides in the URL because link.pane is the focused pane;
-- any program can print such a link, so the routes dock only beside a real RSS block pane and
-- leave other links to Tern's own link handling.
-- Carly: when the user asks Carly to find a site's feed, the RSS block writes a request file and opens
-- "tern-rss://carly/<id>"; the route asks Carly once per request, about the site in that file (never
-- text from the link), and Carly answers through the `found` / `not_found` exports, which write the
-- answer where the block's store polls for it (see lib/carly.luau).

local manifest = require("./lib/manifest")
local url = require("./lib/url")
local carly = require("./lib/carly")
local config = require("./lib/config")

local READER_BLOCK = tern.plugin.id .. ".reader"

-- RSS pane -> the article pane beside it, and what that pane is. Kept in tern.kv (key `articles`,
-- {"<rss pane>": {pane, kind}}), because the window's Lua state is lost on a plugin reload, a
-- window restart or a move to another window, and the pane beside the RSS block outlives all
-- three. Never trusted as is: `live_article` checks it against the session.
type Article = { pane: number, kind: "reader" | "browser" }
local ARTICLES_KEY = "articles"

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

-- The tab holding `pane`, or nil when unknown.
local function tab_of(cx: WindowCx, pane: number): number?
	local ok, tab = pcall(function()
		return cx.session:tab_of(pane)
	end)
	if ok then
		return tab
	end
	return nil
end

-- Whether `a` and `b` can share a tab: they do, or one's tab isn't known.
local function same_tab(cx: WindowCx, a: number, b: number): boolean
	local x, y = tab_of(cx, a), tab_of(cx, b)
	return x == nil or y == nil or x == y
end

-- Records `art` as RSS pane `owner`'s article pane, or forgets it when nil.
local function record(owner: number, art: Article?)
	local ok, all = pcall(tern.kv.get, ARTICLES_KEY)
	local map: { [string]: any } = if ok and type(all) == "table" then table.clone(all :: any) else {}
	map[tostring(owner)] = if art then { pane = art.pane, kind = art.kind } else nil
	pcall(tern.kv.set, ARTICLES_KEY, map)
end

-- What was last recorded as RSS pane `owner`'s article pane, whether or not it still exists.
local function recorded(owner: number): Article?
	local ok, all = pcall(tern.kv.get, ARTICLES_KEY)
	local entry = if ok and type(all) == "table" then (all :: any)[tostring(owner)] else nil
	if type(entry) ~= "table" or type(entry.pane) ~= "number" or (entry.kind ~= "reader" and entry.kind ~= "browser") then
		return nil
	end
	return { pane = entry.pane, kind = entry.kind }
end

-- The article pane beside RSS pane `owner` if it is still open, still what we docked there and
-- still in the RSS pane's tab (pane ids start again after a restart, so an id can name something
-- else now, and that must not be reused or closed); forgets it otherwise.
local function live_article(cx: WindowCx, owner: number): Article?
	local art = recorded(owner)
	if art == nil then
		return nil
	end
	local info = pane_info(cx, art.pane)
	local same = info ~= nil
		and if art.kind == "browser" then info.kind == "browser" else info.kind == "plugin" and info.block == READER_BLOCK
	if not same or not same_tab(cx, owner, art.pane) then
		record(owner, nil)
		return nil
	end
	return art
end

-- Closes article pane `pane`, which is being replaced. Failure leaves the pane open; nothing else
-- to do.
local function close_article(cx: WindowCx, pane: number)
	pcall(function()
		cx.layout:close(pane)
	end)
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
			record(owner, { pane = block, kind = "browser" })
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
-- else (the reader) is replaced by a new one. `from` is the reader pane a hand-off came from, so
-- it is the one replaced when the window has lost track of the article pane.
local function show_browser(cx: WindowCx, owner: number, target: string, from: number?)
	local art = live_article(cx, owner)
	if art and art.kind == "browser" then
		cx.browser:call({ op = "goto", block = art.pane, url = target }):next(function(res, err, wcx)
			if wcx and (err or (res and res.error)) then
				open_browser(wcx, owner, target, art.pane)
			end
		end)
		return
	end
	open_browser(cx, owner, target, if art then art.pane else from)
end

-- Shows `target` in the native reader docked right of `owner` without taking focus: a running
-- reader is docked again (it follows the RSS block's target file by itself), otherwise one opens
-- for click `seq`, replacing a browser left there.
local function show_reader(cx: WindowCx, owner: number, target: string, seq: string)
	local art = live_article(cx, owner)
	if art and art.kind == "reader" then
		cx.layout:dock(art.pane, owner, "right", { focus = false })
		return
	end
	local block = cx:new_block(READER_BLOCK, { target, tostring(owner), seq }, "beside", { focus = false })
	if block == nil then
		-- No reader block on this host (an older install): the browser is the honest fallback.
		tern.log.warn("tern-rss: no native reader block on this host; using the browser")
		show_browser(cx, owner, target, nil)
		return
	end
	record(owner, { pane = block, kind = "reader" })
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

-- The `key=value` pairs of a link's query; the first of a repeated key wins.
local function query_params(query: string): { [string]: string }
	local out: { [string]: string } = {}
	local at = 1
	while at <= #query + 1 do
		local amp = string.find(query, "&", at, true) or #query + 1
		local part = string.sub(query, at, amp - 1)
		local eq = string.find(part, "=", 1, true)
		if eq and out[string.sub(part, 1, eq - 1)] == nil then
			out[string.sub(part, 1, eq - 1)] = string.sub(part, eq + 1)
		end
		at = amp + 1
	end
	return out
end

-- Whether the browser hand-off from reader pane `from` is the article pane's own, not that of a
-- reader the window has since replaced. Judged by the record, not by the pane: a reader closes
-- itself right after it asks, so it is gone by the time this runs. A reader the window never
-- recorded (the kv was cleared) is taken as the article pane's own.
local function owns_handoff(owner: number, from: number): boolean
	local art = recorded(owner)
	return art == nil or (art.kind == "reader" and art.pane == from)
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local id = string.match(link.url, "^tern%-rss://carly/(%x+)$")
	if id then
		ask_carly(cx, id)
		return { handled = true }
	end
	local route, pane, query = string.match(link.url, "^tern%-rss://(%a+)/(%d+)%?(.+)$")
	if (route ~= "read" and route ~= "browser") or pane == nil or query == nil then
		return nil
	end
	local params = query_params(query)
	local target = url.decode(params.url or "")
	if not string.find(target, "^https?://") then
		return { handled = true }
	end
	local owner = tonumber(pane) :: number
	if not is_rss_pane(cx, owner) then
		return { url = target }
	end
	if route == "browser" then
		local from = tonumber(params.from)
		if from and not owns_handoff(owner, from) then
			return { handled = true }
		end
		show_browser(cx, owner, target, from)
	else
		-- The RSS block names the mode (its host's setting, which the `b` key flips); a link
		-- without one (older, or made by hand) takes this machine's setting.
		local mode = if params.mode == "browser" or params.mode == "native" then params.mode else config.reader_mode()
		if mode == "browser" then
			show_browser(cx, owner, target, nil)
		else
			show_reader(cx, owner, target, params.seq or "")
		end
	end
	return { handled = true }
end)
