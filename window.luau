--!strict
-- Tern RSS window half: one "Open <title>" command per declared block, the reader route and the
-- Carly hand-off.
-- Reader: an RSS block opens an article with cx:open("tern-rss://read/<pane>?url=<encoded>"); the
-- route shows it in one browser docked right of that RSS pane, reused (navigated) for later articles
-- and reopened when the user closed it. The pane rides in the URL because link.pane is the focused pane;
-- any program can print such a link, so the route docks only beside a real RSS block pane and leaves
-- other links to Tern's own link handling.
-- Carly: when the user asks Carly to find a site's feed, the RSS block writes a request file and opens
-- "tern-rss://carly/<id>"; the route asks Carly once per request, about the site in that file (never
-- text from the link), and Carly answers through the `found` / `not_found` exports, which write the
-- answer where the block's store polls for it (see lib/carly.luau).

local manifest = require("./lib/manifest")
local url = require("./lib/url")
local carly = require("./lib/carly")

-- RSS pane -> its reader browser pane.
local readers: { [number]: number } = {}

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
-- RSS list keeps the keyboard. Falls back to Tern's built-in link handling when no browser opens.
local function open_reader(cx: WindowCx, owner: number, target: string)
	cx.browser:call({ op = "open", owner = owner, url = target }):next(function(res, err, wcx)
		local block = res and res.ok and tonumber(res.ok.block)
		if wcx == nil then
			return
		end
		if block then
			readers[owner] = block
			wcx.layout:dock(block, owner, "right", { focus = false })
		else
			tern.log.warn("tern-rss: browser open failed", err or (res and res.error and res.error.message))
			wcx:open(target)
		end
	end)
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

-- Whether `pane` is one of this plugin's RSS blocks in this window's session.
local function is_rss_pane(cx: WindowCx, pane: number): boolean
	local ok, info = pcall(function()
		return cx.session:pane(pane)
	end)
	return ok and info ~= nil and info.kind == "plugin" and info.block == tern.plugin.id .. ".rss"
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
	local pane, encoded = string.match(link.url, "^tern%-rss://read/(%d+)%?url=(.+)$")
	if pane == nil or encoded == nil then
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
	local reader = readers[owner]
	local info = if reader then cx.session:pane(reader) else nil
	if reader and info and info.kind == "browser" then
		cx.browser:call({ op = "goto", block = reader, url = target }):next(function(res, err, wcx)
			if wcx and (err or (res and res.error)) then
				open_reader(wcx, owner, target)
			end
		end)
	else
		open_reader(cx, owner, target)
	end
	return { handled = true }
end)
