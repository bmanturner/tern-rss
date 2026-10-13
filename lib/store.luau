--!strict
-- Feed subscriptions, read state, catch-up watermarks, per-feed caches, background refresh, favorite
-- toasts, adding feeds (with probing) and Carly's find-a-feed searches; host half only (uses tern.fs,
-- tern.fetch and tern.pane). State is module-level, so every RSS block in this host VM shares one feed
-- list and one refresh loop. The loop runs while at least one attached block is alive and restarts on
-- the next store.attach.

local feed = require("./feed")
local url = require("./url")
local config = require("./config")
local poll = require("./poll")
local carly = require("./carly")
local filter = require("./filter")
local fmt = require("./fmt")

local store = {}

-- `seen_until`: when the user last caught up on this feed; posts first seen after it are new.
export type Feed = {
	id: string,
	url: string,
	title: string,
	site: string?,
	-- The subscription group the user put it in; nil or "" is ungrouped.
	folder: string?,
	-- True when `title` is the user's own, so a refresh stops overwriting it with the feed's.
	title_set: boolean,
	favorite: boolean,
	added: number,
	seen_until: number?,
}
-- `seen`: when the store first saw the post (not its publish date, which feeds backdate).
export type Item = {
	key: string,
	feed: string,
	title: string,
	link: string?,
	preview: string?,
	published: number?,
	sort: number,
	seen: number,
}
export type Status = { state: "idle" | "loading" | "ok" | "error", error: string?, checked: number? }
-- Why store.add failed: a bad address, a feed already followed, a host that can't be reached, or a
-- reachable site where no feed was found (the case worth handing to Carly).
export type AddFailure = "invalid" | "duplicate" | "unreachable" | "no_feed"
-- A find-a-feed search Carly is working on.
export type Search = { id: string, site: string, at: number }

type CachedItem = {
	key: string,
	title: string,
	link: string?,
	preview: string?,
	published: number?,
	sort: number,
	seen: number?,
}
type Cache = {
	title: string?,
	site: string?,
	fetched: number,
	etag: string?,
	modified: string?,
	keys: { string },
	items: { CachedItem },
}
type Subscriber = { cx: BlockCx, on_change: () -> () }

local TICK_MS = 60000
local MAX_INFLIGHT = 4
local FETCH_TIMEOUT_MS = 20000
-- Guessed feed addresses: a shorter timeout, a few at a time.
local PROBE_TIMEOUT_MS = 10000
local PROBE_CONCURRENCY = 4
-- Carly searches: answer polling, and how long before a search counts as abandoned.
local CARLY_POLL_MS = 1000
local CARLY_TIMEOUT_S = 600
local CARLY_RESULT_TTL_S = 300
local MAX_BYTES = 4 * 1024 * 1024
local CACHE_ITEMS = 50
local CACHE_KEYS = 1000
local READ_TTL_S = 180 * 86400

local ACCEPT =
	"application/rss+xml, application/atom+xml, application/rdf+xml;q=0.9, application/xml;q=0.8, text/xml;q=0.8, text/html;q=0.5, */*;q=0.1"

local cfg = config.rss()

local DIR = tern.plugin.data .. "/rss"
local FEEDS_PATH = DIR .. "/feeds.json"
local READ_PATH = DIR .. "/read.json"
local FILTER_PATH = DIR .. "/filters.json"

local loaded = false
local dir_ready = false
local feeds_list: { Feed } = {}
local read_map: { [string]: number } = {}
-- The Latest tab's filter, shared by every RSS block (see lib/filter).
local filter_cfg: filter.Config = filter.empty()
local caches: { [string]: Cache } = {}
local statuses: { [string]: Status } = {}
local next_at: { [string]: number } = {}
local inflight: { [string]: boolean } = {}
local inflight_n = 0
-- Feeds whose retarget probe is out, by id.
local retargeting: { [string]: boolean } = {}
-- Old id -> the id a retarget gave that feed, so a block that still holds the old id can follow it.
local rekeyed: { [string]: string } = {}
local items_memo: { Item }? = nil
local read_timer: TimerHandle? = nil
local subscribers: { [number]: Subscriber } = {}
local running = false
-- Carly searches by request id, and the last answer number handled for each.
local searches: { [string]: Search } = {}
local handled: { [string]: number } = {}
local carly_polling = false
-- The last stamp handed out by stamp(); seeded from saved watermarks and seen times on load.
local last_stamp = 0

-- Refresh interval in seconds; read on every scheduling decision so kv changes apply.
local function interval(): number
	local minutes = cfg.get("refresh_minutes")
	if type(minutes) ~= "number" then
		minutes = 15
	end
	return math.max(5, minutes) * 60
end

local function nonempty(s: string?): string?
	if s and string.find(s, "%S") then
		return s
	end
	return nil
end

-- A store-wide, strictly increasing time for `seen` and `seen_until`, so a post fetched in the same
-- second as a catch-up still lands on the right side of it.
local function stamp(): number
	last_stamp = math.max(os.time(), last_stamp + 0.001)
	return last_stamp
end

local function cache_path(id: string): string
	return DIR .. "/cache/" .. id .. ".json"
end

-- Whether `u` points at this machine or a private network: localhost names, loopback, private and
-- link-local IPv4 (including unusual numeric spellings), and IPv6 loopback, unique-local and link-local.
local function is_private(u: string): boolean
	local host = string.lower(url.host(u))
	if host == "localhost" or host == "localhost." or string.find(host, "%.localhost%.?$") ~= nil then
		return true
	end
	local v6 = string.match(host, "^%[(.*)%]$")
	if v6 then
		local mapped = string.match(v6, "^::ffff:(%d+%.%d+%.%d+%.%d+)$")
		if mapped == nil then
			return v6 == "::1"
				or v6 == "::"
				or string.find(v6, "^f[cd]") ~= nil
				or string.find(v6, "^fe[89ab]") ~= nil
		end
		host = mapped
	end
	if string.find(host, "^%d+$") or string.find(host, "^0x%x+$") then
		return true
	end
	local a, b, c, d = string.match(host, "^(%d+)%.(%d+)%.(%d+)%.(%d+)%.?$")
	if a == nil or b == nil or c == nil or d == nil then
		return false
	end
	for _, part in { a, b, c, d } do
		if #part > 1 and string.sub(part, 1, 1) == "0" then
			return true -- octal spelling
		end
	end
	local x, y = tonumber(a) :: number, tonumber(b) :: number
	return x == 0
		or x == 10
		or x == 127
		or (x == 172 and y >= 16 and y <= 31)
		or (x == 192 and y == 168)
		or (x == 169 and y == 254)
end

-- Files ---------------------------------------------------------------------------------------------

local function read_file(path: string): string?
	local ok, exists = pcall(tern.fs.exists, path)
	if not ok or not exists then
		return nil
	end
	local ok2, text = pcall(tern.fs.read, path)
	if not ok2 then
		tern.log.warn("tern-rss store: cannot read", path, text)
		return nil
	end
	return text :: string
end

local function decode(text: string): any
	local ok, v = pcall(tern.json.decode, text)
	if ok then
		return v
	end
	return nil
end

local function write_text(path: string, text: string)
	if not dir_ready then
		dir_ready = pcall(tern.fs.mkdir, DIR .. "/cache")
	end
	local ok, err = pcall(function()
		tern.fs.write(path, text)
	end)
	if not ok then
		tern.log.warn("tern-rss store: cannot write", path, err)
	end
end

local function write_json(path: string, value: any)
	local ok, text = pcall(tern.json.encode, value)
	if not ok then
		tern.log.warn("tern-rss store: cannot encode", path, text)
		return
	end
	write_text(path, text :: string)
end

local function save_feeds()
	write_json(FEEDS_PATH, { version = 1, feeds = tern.json.array(table.clone(feeds_list)) })
end

-- Rule lines, so filters.json stays readable and hand-editable.
local function save_filter()
	write_json(FILTER_PATH, filter.encode(filter_cfg))
end

local function save_cache(id: string, c: Cache)
	write_json(cache_path(id), {
		title = c.title,
		site = c.site,
		fetched = c.fetched,
		etag = c.etag,
		modified = c.modified,
		keys = tern.json.array(table.clone(c.keys)),
		items = tern.json.array(table.clone(c.items)),
	})
end

-- One debounced write of read.json, 1 s after the last change.
local function save_read_soon()
	if read_timer then
		return
	end
	read_timer = tern.timer(1000, function()
		read_timer = nil
		write_json(READ_PATH, read_map)
	end)
end

local function opt_string(v: any): string?
	return if type(v) == "string" then v else nil
end

local function opt_number(v: any): number?
	return if type(v) == "number" then v else nil
end

local function parse_feed_record(v: any): Feed?
	if type(v) ~= "table" or type(v.url) ~= "string" then
		return nil
	end
	local u: string = v.url
	return {
		-- The id names the cache file, so only the hex hash main writes is trusted; anything else is
		-- the hash of the URL.
		id = if type(v.id) == "string" and string.find(v.id, "^%x+$") then v.id else feed.hash(u),
		url = u,
		title = nonempty(opt_string(v.title)) or url.host(u),
		site = opt_string(v.site),
		folder = nonempty(opt_string(v.folder)),
		title_set = v.title_set == true,
		favorite = v.favorite == true,
		added = opt_number(v.added) or os.time(),
		seen_until = opt_number(v.seen_until),
	}
end

local function parse_cache(v: any): Cache?
	if type(v) ~= "table" then
		return nil
	end
	local keys: { string } = {}
	if type(v.keys) == "table" then
		for _, k in ipairs(v.keys) do
			if type(k) == "string" then
				table.insert(keys, k)
			end
		end
	end
	local items: { CachedItem } = {}
	if type(v.items) == "table" then
		for _, it in ipairs(v.items) do
			if type(it) == "table" and type(it.key) == "string" and type(it.title) == "string" and type(it.sort) == "number" then
				table.insert(items, {
					key = it.key,
					title = it.title,
					link = opt_string(it.link),
					preview = opt_string(it.preview),
					published = opt_number(it.published),
					sort = it.sort,
					seen = opt_number(it.seen),
				})
			end
		end
	end
	return {
		title = opt_string(v.title),
		site = opt_string(v.site),
		fetched = opt_number(v.fetched) or 0,
		etag = opt_string(v.etag),
		modified = opt_string(v.modified),
		keys = keys,
		items = items,
	}
end

-- Whether the subscription list is trustworthy: false when feeds.json exists but couldn't be read or
-- decoded. The empty list is then not the user's, and nothing derived from it (the group prune) may
-- be written back.
local function load_feeds(): boolean
	local ok, exists = pcall(tern.fs.exists, FEEDS_PATH)
	if not ok or not exists then
		return true
	end
	local text = read_file(FEEDS_PATH)
	if not text then
		return false
	end
	local data = decode(text)
	if type(data) ~= "table" or (data.feeds ~= nil and type(data.feeds) ~= "table") then
		write_text(FEEDS_PATH .. ".bad", text)
		tern.log.warn("tern-rss store: feeds.json unreadable; saved as feeds.json.bad")
		return false
	end
	local seen: { [string]: boolean } = {}
	for _, v in ipairs(data.feeds or {}) do
		local f = parse_feed_record(v)
		if f and not seen[f.id] then
			seen[f.id] = true
			table.insert(feeds_list, f)
		end
	end
	return true
end

local function load_read()
	local text = read_file(READ_PATH)
	if not text then
		return
	end
	local data = decode(text)
	if type(data) ~= "table" then
		return
	end
	local cutoff = os.time() - READ_TTL_S
	for k, t in pairs(data) do
		if type(k) == "string" and type(t) == "number" and t >= cutoff then
			read_map[k] = t
		end
	end
end

-- The Latest tab's filter. A file that doesn't decode is kept aside, like feeds.json.
local function load_filter()
	local text = read_file(FILTER_PATH)
	if not text then
		return
	end
	local data = decode(text)
	if type(data) ~= "table" then
		write_text(FILTER_PATH .. ".bad", text)
		tern.log.warn("tern-rss store: filters.json unreadable; saved as filters.json.bad")
		return
	end
	local cfg, bad = filter.decode(data)
	filter_cfg = cfg
	if bad > 0 then
		tern.log.warn(`tern-rss store: {bad} filter rule(s) in filters.json don't parse; kept, not applied`)
	end
end

-- The group names the subscribed feeds carry, for the filter panel and the tree.
local function folder_set(): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, f in feeds_list do
		out[filter.group(f)] = true
	end
	return out
end

local start_carly_poll: () -> ()

-- Resumes Carly searches a reload interrupted and drops leftovers of finished ones.
local function load_searches()
	local now = os.time()
	local requests: { [string]: boolean } = {}
	local files = carly.files()
	for _, f in files do
		if f.kind == "request" then
			requests[f.id] = true
			local req = carly.read(f.id, "request")
			if type(req) == "table" and type(req.site) == "string" and type(req.at) == "number" then
				searches[f.id] = { id = f.id, site = req.site, at = req.at }
				local res = carly.read(f.id, "result")
				handled[f.id] = if type(res) == "table" and type(res.n) == "number" then res.n else 0
			else
				carly.remove(f.id, "request")
			end
		end
	end
	for _, f in files do
		if f.kind == "answer" and not requests[f.id] then
			carly.remove(f.id, "answer")
		elseif f.kind == "asked" and not requests[f.id] then
			carly.remove(f.id, "asked")
		elseif f.kind == "result" and not requests[f.id] then
			local res = carly.read(f.id, "result")
			if type(res) ~= "table" or type(res.at) ~= "number" or res.at < now - CARLY_RESULT_TTL_S then
				carly.remove(f.id, "result")
			end
		end
	end
	if next(searches) ~= nil then
		start_carly_poll()
	end
end

local function ensure_loaded()
	if loaded then
		return
	end
	loaded = true
	local feeds_ok = load_feeds()
	load_read()
	load_filter()
	-- A group no feed carries any more (feeds.json edited by hand, or a crash between the two writes)
	-- must not keep hiding every post. Not against a list that failed to load: that one is empty, and
	-- pruning it would erase the user's groups for good.
	if feeds_ok and filter.prune(filter_cfg, folder_set()) then
		save_filter()
	end
	local iv = interval()
	for _, f in feeds_list do
		last_stamp = math.max(last_stamp, f.seen_until or 0)
		local text = read_file(cache_path(f.id))
		local c = if text then parse_cache(decode(text)) else nil
		if c then
			for _, it in c.items do
				last_stamp = math.max(last_stamp, it.seen or 0)
			end
			caches[f.id] = c
			statuses[f.id] = { state = "idle", checked = if c.fetched > 0 then c.fetched else nil }
			next_at[f.id] = c.fetched + iv
		else
			next_at[f.id] = 0
		end
	end
	load_searches()
end

-- Subscribers ---------------------------------------------------------------------------------------

local function notify()
	for pane, sub in subscribers do
		local ok, err = pcall(function()
			sub.on_change()
		end)
		if not ok then
			tern.log.warn("tern-rss store: on_change failed", pane, err)
		end
	end
end

local function toast(level: ToastLevel, text: string, sub: string?)
	for _, s in subscribers do
		if pcall(function()
			s.cx:toast(level, text, sub)
		end) then
			return
		end
	end
end

local function find(id: string): (Feed?, number?)
	for i, f in feeds_list do
		if f.id == id then
			return f, i
		end
	end
	return nil, nil
end

-- The feed other than `except` that already follows `u`, by URL or by id: ids are URL hashes, but a
-- record written before retargets re-keyed them may carry an id that no longer matches its URL.
local function url_taken(u: string, except: Feed?): Feed?
	local id = feed.hash(u)
	for _, f in feeds_list do
		if f ~= except and (f.url == u or f.id == id) then
			return f
		end
	end
	return nil
end

-- Deletes feed `id`'s cached posts, from memory and from disk.
local function drop_cache(id: string)
	caches[id] = nil
	local path = cache_path(id)
	local ok, exists = pcall(tern.fs.exists, path)
	if ok and exists then
		local removed, err = pcall(function()
			tern.fs.remove(path)
		end)
		if not removed then
			tern.log.warn("tern-rss store: cannot remove", path, err)
		end
	end
end

-- Fetching ------------------------------------------------------------------------------------------

local function request_headers(c: Cache?): { [string]: string }
	local h: { [string]: string } = { ["User-Agent"] = "tern-rss/0.1", Accept = ACCEPT }
	if c then
		if c.etag then
			h["If-None-Match"] = c.etag
		end
		if c.modified then
			h["If-Modified-Since"] = c.modified
		end
	end
	return h
end

-- Starts a GET; `cb` gets the response, or nil when tern.fetch raised (malformed URL).
local function get(target: string, c: Cache?, cb: (r: FetchResult?) -> (), timeout_ms: number?)
	local opts = { timeout_ms = timeout_ms or FETCH_TIMEOUT_MS, headers = request_headers(c) }
	local ok = pcall(tern.fetch, target, opts, function(r: FetchResult)
		cb(r)
	end)
	if not ok then
		cb(nil)
	end
end

-- The user-facing error for a response that is not a usable body, or nil. 304 is not an error.
local function response_error(r: FetchResult?, host: string): string?
	if r == nil or r.error ~= nil then
		if r and r.timed_out then
			return `{host} took too long to answer.`
		end
		return `Couldn't reach {host}.`
	end
	if r.timed_out then
		return `{host} took too long to answer.`
	end
	if r.status == 304 then
		return nil
	end
	if r.status >= 400 then
		return `{host} answered HTTP {r.status}.`
	end
	if #r.body > MAX_BYTES then
		return "That feed is over 4 MB."
	end
	return nil
end

-- Merges a parsed feed into feed `f`'s cache and writes it. Returns how many items are new (always 0
-- without a previous cache), the newest new item's title, and whether f.title/f.site changed.
local function apply(f: Feed, parsed: feed.Parsed, r: FetchResult): (number, string?, boolean)
	local id = f.id
	local prev = caches[id]
	local now = os.time()
	local seen_at = stamp()

	local prev_keys: { [string]: boolean } = {}
	local prev_sort: { [string]: number } = {}
	local prev_seen: { [string]: number } = {}
	if prev then
		for _, h in prev.keys do
			prev_keys[h] = true
		end
		for _, it in prev.items do
			prev_sort[it.key] = it.sort
			prev_seen[it.key] = it.seen or prev.fetched
		end
	end

	local hashes: { string } = {}
	local seen: { [string]: boolean } = {}
	local seen_key: { [string]: boolean } = {}
	local merged: { CachedItem } = {}
	local new_n = 0
	local newest_title: string? = nil
	local newest_sort = -math.huge
	for i, it in parsed.items do
		local h = feed.hash(it.id)
		if not seen[h] then
			seen[h] = true
			table.insert(hashes, h)
			local key = id .. "-" .. h
			seen_key[key] = true
			-- Undated items keep their first sort so they never jump on later refreshes. One the previous
			-- fetch already knew but kept out of its cached window is old: it stays below that window and
			-- counts as seen then, so it never resurfaces as new.
			local evicted_at: number? = if prev and prev_keys[h] and prev_sort[key] == nil then prev.fetched else nil
			local sort = it.published or prev_sort[key] or ((evicted_at or now) - i)
			table.insert(merged, {
				key = key,
				title = it.title,
				link = it.link,
				preview = it.preview,
				published = it.published,
				sort = sort,
				seen = prev_seen[key] or evicted_at or seen_at,
			})
			if prev and not prev_keys[h] then
				new_n += 1
				if sort > newest_sort then
					newest_sort = sort
					newest_title = it.title
				end
			end
		end
	end
	if prev then
		for _, it in prev.items do
			if not seen_key[it.key] then
				it.seen = it.seen or prev.fetched
				table.insert(merged, it)
			end
		end
		for _, h in prev.keys do
			if #hashes >= CACHE_KEYS then
				break
			end
			if not seen[h] then
				seen[h] = true
				table.insert(hashes, h)
			end
		end
	end
	table.sort(merged, function(a: CachedItem, b: CachedItem): boolean
		if a.sort ~= b.sort then
			return a.sort > b.sort
		end
		return a.key < b.key
	end)
	local items: { CachedItem } = {}
	for i = 1, math.min(#merged, CACHE_ITEMS) do
		items[i] = merged[i]
	end
	local keys: { string } = {}
	for i = 1, math.min(#hashes, CACHE_KEYS) do
		keys[i] = hashes[i]
	end

	local headers = r.headers or {}
	local title = nonempty(parsed.title)
	local cache: Cache = {
		title = title,
		site = parsed.site,
		fetched = now,
		etag = headers["etag"],
		modified = headers["last-modified"],
		keys = keys,
		items = items,
	}
	caches[id] = cache
	items_memo = nil
	save_cache(id, cache)

	local changed = false
	-- A title the user typed wins over the feed's own, or every refresh would undo the rename.
	if title and not f.title_set and title ~= f.title then
		f.title = title
		changed = true
	end
	if parsed.site and parsed.site ~= f.site then
		f.site = parsed.site
		changed = true
	end
	return new_n, newest_title, changed
end

local pump: () -> ()

local function fetch_feed(f: Feed)
	local id = f.id
	local host = url.host(f.url)
	local sent = f.url
	inflight[id] = true
	inflight_n += 1
	local prev = statuses[id]
	statuses[id] = { state = "loading", checked = if prev then prev.checked else nil }
	notify()

	local function finish(err: string?)
		inflight[id] = nil
		inflight_n -= 1
		-- Removed, removed and re-added, or retargeted while in flight: drop the result.
		if find(id) == f and f.url == sent then
			local now = os.time()
			if err then
				statuses[id] = { state = "error", error = err, checked = now }
			else
				statuses[id] = { state = "ok", checked = now }
			end
			next_at[id] = now + interval()
		end
		notify()
		pump()
	end

	get(f.url, caches[id], function(r: FetchResult?)
		-- A retarget while the request was out leaves this response about a URL the feed no longer has.
		if find(id) ~= f or f.url ~= sent then
			finish(nil)
			return
		end
		local ok, err = pcall(function(): string?
			local e = response_error(r, host)
			if e then
				return e
			end
			local res = r :: FetchResult
			if res.status == 304 then
				local c = caches[id]
				if c then
					c.fetched = os.time()
				end
				return nil
			end
			local parsed = feed.parse(res.body, f.url)
			if not parsed then
				return `{host} isn't serving an RSS or Atom feed.`
			end
			local had_cache = caches[id] ~= nil
			local n, newest, changed = apply(f, parsed, res)
			if changed then
				save_feeds()
			end
			if had_cache and n > 0 and f.favorite then
				local more = if n > 1 then "  +" .. (n - 1) .. " more" else ""
				toast("info", "★ " .. f.title, (newest or "") .. more)
			end
			return nil
		end)
		if not ok then
			tern.log.warn("tern-rss store: refresh failed", f.url, err)
			finish(`{host} isn't serving an RSS or Atom feed.`)
			return
		end
		finish(err :: string?)
	end)
end

pump = function()
	if not running then
		return
	end
	local now = os.time()
	for _, f in table.clone(feeds_list) do
		if inflight_n >= MAX_INFLIGHT then
			break
		end
		if not inflight[f.id] and (next_at[f.id] or 0) <= now then
			fetch_feed(f)
		end
	end
end

-- Loop ----------------------------------------------------------------------------------------------

local tick: () -> ()
tick = function()
	for pane in table.clone(subscribers) do
		local ok, alive = pcall(poll.alive, pane)
		if ok and not alive then
			subscribers[pane] = nil
		end
	end
	if next(subscribers) == nil then
		running = false
		return
	end
	local ok, err = pcall(function()
		pump()
		notify()
	end)
	if not ok then
		tern.log.warn("tern-rss store: tick failed", err)
	end
	tern.timer(TICK_MS, tick)
end

-- Public API ----------------------------------------------------------------------------------------

-- Registers block `cx` (by pane) to get `on_change` after every store change, and starts the
-- refresh loop when it is stopped.
function store.attach(cx: BlockCx, on_change: () -> ())
	ensure_loaded()
	subscribers[cx.pane] = { cx = cx, on_change = on_change }
	if not running then
		running = true
		tern.timer(0, tick)
	end
end

-- Subscribed feeds in subscription order.
function store.feeds(): { Feed }
	ensure_loaded()
	return feeds_list
end

function store.feed(id: string): Feed?
	ensure_loaded()
	return (find(id))
end

-- Every cached item of every feed, newest first (memoized; do not mutate).
function store.items(): { Item }
	ensure_loaded()
	local memo = items_memo
	if memo then
		return memo
	end
	local out: { Item } = {}
	for _, f in feeds_list do
		local c = caches[f.id]
		if c then
			for _, it in c.items do
				table.insert(out, {
					key = it.key,
					feed = f.id,
					title = it.title,
					link = it.link,
					preview = it.preview,
					published = it.published,
					sort = it.sort,
					seen = it.seen or c.fetched,
				})
			end
		end
	end
	table.sort(out, function(a: Item, b: Item): boolean
		if a.sort ~= b.sort then
			return a.sort > b.sort
		end
		return a.key < b.key
	end)
	items_memo = out
	return out
end

function store.status(id: string): Status
	ensure_loaded()
	return statuses[id] or { state = "idle" }
end

function store.is_read(key: string): boolean
	ensure_loaded()
	return read_map[key] ~= nil
end

function store.set_read(key: string, read: boolean)
	ensure_loaded()
	if read then
		if read_map[key] then
			return
		end
		read_map[key] = os.time()
	else
		if not read_map[key] then
			return
		end
		read_map[key] = nil
	end
	save_read_soon()
	notify()
end

-- Marks `keys` in one write and one notify, so marking a list of posts is not one save each.
-- Returns how many changed.
function store.set_read_many(keys: { string }, read: boolean): number
	ensure_loaded()
	local n = 0
	local now = os.time()
	for _, key in keys do
		if read then
			if read_map[key] == nil then
				read_map[key] = now
				n += 1
			end
		elseif read_map[key] ~= nil then
			read_map[key] = nil
			n += 1
		end
	end
	if n > 0 then
		save_read_soon()
		notify()
	end
	return n
end

-- Whether `item` arrived after its feed was last caught up on.
function store.is_new(item: Item): boolean
	local f = find(item.feed)
	local until_t = if f then f.seen_until else nil
	return until_t == nil or item.seen > until_t
end

-- New posts not yet read, optionally only those `filter` accepts.
function store.new_count(filter: ((Item) -> boolean)?): number
	local watermark: { [string]: number } = {}
	for _, f in feeds_list do
		watermark[f.id] = f.seen_until or -math.huge
	end
	local n = 0
	for _, it in store.items() do
		if read_map[it.key] == nil and it.seen > (watermark[it.feed] or -math.huge) and (filter == nil or filter(it)) then
			n += 1
		end
	end
	return n
end

-- Catches up on feeds `ids`: every post seen so far stops being new. Returns each feed's previous
-- watermark (false where it had none), for store.restore_seen.
function store.catch_up(ids: { string }): { [string]: number | false }
	ensure_loaded()
	local now = stamp()
	local prev: { [string]: number | false } = {}
	for _, id in ids do
		local f = find(id)
		if f then
			prev[id] = f.seen_until or false
			f.seen_until = now
		end
	end
	if next(prev) ~= nil then
		save_feeds()
		notify()
	end
	return prev
end

-- Undoes a store.catch_up with the watermarks it returned.
function store.restore_seen(prev: { [string]: number | false })
	ensure_loaded()
	for id, t in prev do
		local f = find(id)
		if f then
			f.seen_until = if type(t) == "number" then t else nil
		end
	end
	save_feeds()
	notify()
end

-- Groups and filters --------------------------------------------------------------------------------

-- The folders the subscribed feeds carry, sorted, ungrouped last: the tree's and the panel's order.
function store.folders(): { string }
	ensure_loaded()
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, f in feeds_list do
		local g = filter.group(f)
		if not seen[g] then
			seen[g] = true
			table.insert(out, g)
		end
	end
	table.sort(out, function(a: string, b: string): boolean
		local a_ungrouped = a == filter.UNGROUPED
		local b_ungrouped = b == filter.UNGROUPED
		if a_ungrouped ~= b_ungrouped then
			return b_ungrouped
		end
		-- Case-insensitive, so "ai" and "AI" sit together; the exact name breaks ties.
		local la, lb = string.lower(a), string.lower(b)
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return out
end

-- The subscribed feeds in `folder`, in subscription order.
function store.feeds_in(folder: string): { Feed }
	ensure_loaded()
	local out: { Feed } = {}
	for _, f in feeds_list do
		if filter.group(f) == folder then
			table.insert(out, f)
		end
	end
	return out
end

-- Puts `id` in folder `name`; nil or "" clears it. The name is the user's text, trimmed and clipped
-- to 60 characters. False when there is no such feed.
function store.set_folder(id: string, name: string?): boolean
	ensure_loaded()
	local f = find(id)
	if not f then
		return false
	end
	local want = fmt.trim(name or "")
	local g: string? = if want == "" then nil else fmt.clip(want, 60)
	if f.folder == g then
		return true
	end
	f.folder = g
	save_feeds()
	if filter.prune(filter_cfg, folder_set()) then
		save_filter()
	end
	notify()
	return true
end

-- The Latest tab's filter, shared by every RSS block in this host.
function store.filter(): filter.Config
	ensure_loaded()
	return filter_cfg
end

function store.set_filter(cfg: filter.Config)
	ensure_loaded()
	filter_cfg = cfg
	save_filter()
	notify()
end

function store.toggle_favorite(id: string)
	ensure_loaded()
	local f = find(id)
	if not f then
		return
	end
	f.favorite = not f.favorite
	items_memo = nil
	save_feeds()
	notify()
end

function store.remove(id: string)
	ensure_loaded()
	local f, i = find(id)
	if not f or not i then
		return
	end
	table.remove(feeds_list, i)
	statuses[id] = nil
	next_at[id] = nil
	items_memo = nil
	drop_cache(id)
	-- A group whose last feed just left stops hiding posts in the filter.
	if filter.prune(filter_cfg, folder_set()) then
		save_filter()
	end
	save_feeds()
	notify()
end

-- The parsed feed in response `r` for `target`, or nil when it isn't one (an error, an HTML page,
-- anything that doesn't parse as RSS or Atom).
local function as_feed(r: FetchResult?, target: string): feed.Parsed?
	if response_error(r, url.host(target)) ~= nil then
		return nil
	end
	local res = r :: FetchResult
	if res.status == 304 or feed.is_html(res.body, (res.headers or {})["content-type"]) then
		return nil
	end
	local ok, parsed = pcall(function(): feed.Parsed?
		return (feed.parse(res.body, target))
	end)
	return if ok then parsed else nil
end

-- Fetches `candidates` a few at a time and calls `done` with the first in list order that is a feed,
-- so a slow good candidate still beats a fast later one; nils when none is.
local function probe(candidates: { string }, done: (target: string?, r: FetchResult?, parsed: feed.Parsed?) -> ())
	local found: { [number]: { r: FetchResult, parsed: feed.Parsed } } = {}
	local failed: { [number]: boolean } = {}
	local next_i = 1
	local active = 0
	local finished = false
	local function settle()
		if finished then
			return
		end
		for i = 1, #candidates do
			local hit = found[i]
			if hit then
				finished = true
				done(candidates[i], hit.r, hit.parsed)
				return
			elseif not failed[i] then
				return
			end
		end
		finished = true
		done(nil, nil, nil)
	end
	local function launch()
		while not finished and next_i <= #candidates and active < PROBE_CONCURRENCY do
			local i = next_i
			local target = candidates[i]
			next_i += 1
			active += 1
			get(target, nil, function(r: FetchResult?)
				active -= 1
				local parsed = as_feed(r, target)
				if parsed then
					found[i] = { r = r :: FetchResult, parsed = parsed }
				else
					failed[i] = true
				end
				settle()
				launch()
			end, PROBE_TIMEOUT_MS)
		end
	end
	if #candidates == 0 then
		done(nil, nil, nil)
		return
	end
	launch()
end

-- The id `id` has become after retargets, or `id` itself when it never moved.
function store.resolve(id: string): string
	local at = id
	-- Ids never form a cycle (a retarget clears its new id's own entry); the bound only guards a bug.
	for _ = 1, 64 do
		local nxt = rekeyed[at]
		if nxt == nil then
			break
		end
		at = nxt
	end
	return at
end

-- Renames `id` to `title` and moves it to `url`. Empty strings mean "leave as it is", so a feed can
-- be renamed without refetching and retargeted without renaming; only a title that differs from the
-- current one counts as the user's own. A URL that is the feed's own, as stored or once normalized, is
-- no retarget. A new URL is normalized like an added one and probed (it must itself be a feed; the
-- page discovery of store.add is not run): `done` gets the error when it isn't a feed or another feed
-- already follows it, and then nothing changes, the title included: a title typed with a retarget
-- lands only with it. One retarget at a time per feed: a second while the probe is out gets an
-- error. A retarget is a different feed, so on success its cached posts go and it takes the new URL's
-- hash as its id (store.add finds duplicates by that hash); `done` gets that id. Returns false when
-- there is no such feed or nothing to change.
function store.rename(id: string, title: string, target: string, done: (err: string?, new_id: string?) -> ()): boolean
	ensure_loaded()
	local f = find(id)
	if not f then
		return false
	end
	-- The same clip the parser uses, so a hand-edited title is the same length a fetched one is.
	local want = nonempty(title)
	want = if want then fmt.clip(want, 200) else nil
	local to: string? = nil
	local typed = nonempty(target)
	-- Stored URLs aren't always normalized (a page's link keeps its scheme case and inner spaces), and
	-- the edit field prefills the stored text: the same text, or the same once normalized, is no change.
	if typed and typed ~= f.url then
		to = url.normalize(typed)
		if to == nil then
			done("That doesn't look like a web address.")
			return true
		end
		if to == f.url or to == url.normalize(f.url) then
			to = nil
		end
	end
	local retitle = want ~= nil and want ~= f.title
	local retarget = to ~= nil
	if not retitle and not retarget then
		return false
	end
	if to ~= nil and retarget then
		if retargeting[id] then
			done("Still checking the last change to this feed. Try again in a moment.")
			return true
		end
		local taken = url_taken(to, f)
		if taken then
			done(`You already follow {taken.title}.`)
			return true
		end
	end
	if retitle and want and not retarget then
		f.title = want
		f.title_set = true
		items_memo = nil
		save_feeds()
		notify()
	end
	-- The record on disk keeps the old URL until the probe passes: a saved bad URL would survive a
	-- restart, and then every refresh of this feed would fail until the user edited it again.
	if to == nil or not retarget then
		done(nil, id)
		return true
	end
	-- A different URL is a different feed: show it fetching while the probe is out. next_at stays, so
	-- the poller doesn't fetch the old URL meanwhile and merge its posts after the switch.
	local before = statuses[id]
	statuses[id] = { state = "loading" }
	retargeting[id] = true
	notify()
	local dest: string = to
	probe({ dest }, function(hit: string?, r: FetchResult?, parsed: feed.Parsed?)
		retargeting[id] = nil
		local again = find(id)
		if again == nil then
			-- Removed while the probe was out; the caller's field is still waiting on an answer.
			done("That feed is gone.")
			return
		end
		local function refuse(message: string)
			-- The feed itself is as healthy as it was; the message goes to the caller.
			statuses[id] = before
			notify()
			done(message)
		end
		if hit == nil or parsed == nil or r == nil then
			refuse(`{url.host(dest)} isn't serving an RSS or Atom feed.`)
			return
		end
		local taken = url_taken(dest, again)
		if taken then
			refuse(`You already follow {taken.title}.`)
			return
		end
		drop_cache(id)
		local new_id = feed.hash(dest)
		statuses[id] = nil
		next_at[id] = nil
		again.url = dest
		again.id = new_id
		rekeyed[new_id] = nil
		rekeyed[id] = new_id
		if retitle and want then
			again.title = want
			again.title_set = true
		end
		items_memo = nil
		apply(again, parsed, r)
		-- The URL and id changed, so this write is not optional: apply() only reports the title.
		save_feeds()
		statuses[new_id] = { state = "ok", checked = os.time() }
		next_at[new_id] = os.time() + interval()
		notify()
		done(nil, new_id)
	end)
	return true
end


-- Follows the feed at `input`: a feed URL, or a page whose feed its links, its platform or the usual
-- paths lead to. Calls `cb` exactly once: with the new feed, or with an error message and why.
function store.add(input: string, cb: (feed: Feed?, err: string?, why: AddFailure?) -> ())
	ensure_loaded()
	local done = false
	local function reply(f: Feed?, err: string?, why: AddFailure?)
		if done then
			return
		end
		done = true
		local ok, e = pcall(function()
			cb(f, err, why)
		end)
		if not ok then
			tern.log.warn("tern-rss store: add callback failed", e)
		end
	end

	local u = url.normalize(input)
	if not u then
		reply(nil, "That doesn't look like a web address.", "invalid")
		return
	end
	local existing = url_taken(u)
	if existing then
		reply(nil, `You already follow {existing.title}.`, "duplicate")
		return
	end
	local host = url.host(u)
	-- Addresses the page picks may reach this machine or the local network only when the user's own does.
	local local_ok = is_private(u)

	local function follow(final: string, r: FetchResult, parsed: feed.Parsed)
		local id = feed.hash(final)
		local dup = url_taken(final)
		if dup then
			reply(nil, `You already follow {dup.title}.`, "duplicate")
			return
		end
		local ok, e = pcall(function()
			local f: Feed = {
				id = id,
				url = final,
				title = nonempty(parsed.title) or url.host(final),
				site = parsed.site,
				title_set = false,
				favorite = false,
				added = os.time(),
			}
			table.insert(feeds_list, f)
			apply(f, parsed, r)
			local now = os.time()
			statuses[id] = { state = "ok", checked = now }
			next_at[id] = now + interval()
			items_memo = nil
			save_feeds()
			notify()
			reply(f, nil, nil)
		end)
		if not ok then
			tern.log.warn("tern-rss store: add failed", final, e)
			reply(nil, `{url.host(final)} isn't serving an RSS or Atom feed.`, "no_feed")
		end
	end

	local function on_page(r: FetchResult?)
		-- Unreachable (or a malformed URL): guessing other paths on the same host won't help.
		if r == nil or r.error ~= nil or r.timed_out then
			local message = response_error(r, host) or `Couldn't reach {host}.`
			reply(nil, message .. " Check the address and your connection.", "unreachable")
			return
		end
		local res = r :: FetchResult
		-- An HTTP error page can still sit on a site whose feed lives elsewhere, so keep looking.
		local page_error = response_error(res, host)
		local candidates: { string } = {}
		if page_error == nil then
			if feed.is_html(res.body, (res.headers or {})["content-type"]) then
				for _, link in feed.links(res.body, u) do
					if local_ok or not is_private(link) then
						table.insert(candidates, link)
					end
				end
			else
				local parsed = as_feed(res, u)
				if parsed then
					follow(u, res, parsed)
					return
				end
			end
		end
		for _, g in feed.guesses(u) do
			if not table.find(candidates, g) then
				table.insert(candidates, g)
			end
		end
		probe(candidates, function(target: string?, r2: FetchResult?, parsed: feed.Parsed?)
			if target and r2 and parsed then
				follow(target, r2, parsed)
			else
				reply(nil, page_error or `No feed found on {host}.`, "no_feed")
			end
		end)
	end

	get(u, nil, function(r: FetchResult?)
		local ok, e = pcall(function()
			on_page(r)
		end)
		if not ok then
			tern.log.warn("tern-rss store: add failed", u, e)
			reply(nil, `{host} isn't serving an RSS or Atom feed.`, "no_feed")
		end
	end)
end

-- Carly searches --------------------------------------------------------------------------------------

-- Searches whose answer is being followed right now (never timed out mid-add).
local carly_adding: { [string]: boolean } = {}

local function end_search(id: string)
	searches[id] = nil
	handled[id] = nil
	carly.remove(id, "request")
	carly.remove(id, "answer")
	carly.remove(id, "asked")
	-- The result outlives the search for Carly's waiting `found` call; load_searches prunes leftovers.
	tern.timer(CARLY_RESULT_TTL_S * 1000, function()
		carly.remove(id, "result")
	end)
	notify()
end

local function result(id: string, n: number, ok: boolean, title: string?, err: string?)
	carly.write(id, "result", { n = n, ok = ok, title = title, error = err, at = os.time() })
end

-- Handles answer `n` of search `s`: a feed URL to follow, or Carly's reason there is none.
local function handle_answer(s: Search, n: number, answer: { [string]: any })
	local id = s.id
	local site_host = url.host(s.site)
	local feed_url: string? = if type(answer.url) == "string" then answer.url else nil
	if feed_url == nil then
		local reason: string = if type(answer.reason) == "string" and answer.reason ~= ""
			then answer.reason
			else "Carly found no feed."
		toast("error", "No feed for " .. site_host, reason)
		end_search(id)
		return
	end
	-- Carly read the site's pages, so her answer may point where the page wanted: keep it off this
	-- machine and the local network unless the site itself is there.
	if is_private(feed_url) and not is_private(s.site) then
		result(id, n, false, nil, "That address is on this machine or a private network; find the site's public feed URL.")
		return
	end
	local normalized = url.normalize(feed_url)
	local existing = if normalized then url_taken(normalized) else nil
	if existing then
		result(id, n, true, existing.title, nil)
		toast("info", "You already follow " .. existing.title)
		end_search(id)
		return
	end
	carly_adding[id] = true
	store.add(feed_url, function(f: Feed?, err: string?, why: AddFailure?)
		carly_adding[id] = nil
		local live = searches[id] ~= nil
		if f then
			result(id, n, true, f.title, nil)
			toast("success", "Following " .. f.title, "Carly found the feed for " .. site_host .. ".")
			if live then
				end_search(id)
			end
		else
			result(id, n, false, nil, err)
			if live and why == "duplicate" then
				toast("info", err or "You already follow that feed.")
				end_search(id)
			end
		end
	end)
end

local function carly_tick()
	local ok, err = pcall(function()
		local now = os.time()
		for id, s in table.clone(searches) do
			local answer = carly.read(id, "answer")
			local n = if type(answer) == "table" and type(answer.n) == "number" then answer.n else 0
			if n > (handled[id] or 0) and not carly_adding[id] then
				handled[id] = n
				handle_answer(s, n, answer)
			elseif not carly_adding[id] and now - s.at > CARLY_TIMEOUT_S then
				toast("error", "No feed for " .. url.host(s.site), "Carly didn't finish the search.")
				end_search(id)
			end
		end
	end)
	if not ok then
		tern.log.warn("tern-rss store: carly poll failed", err)
	end
	if next(searches) == nil then
		carly_polling = false
		return
	end
	tern.timer(CARLY_POLL_MS, carly_tick)
end

start_carly_poll = function()
	if carly_polling then
		return
	end
	carly_polling = true
	tern.timer(CARLY_POLL_MS, carly_tick)
end

-- Hands `input`, a site where store.add found no feed, to Carly through the window's carly route; call
-- it only when the user asks for it. Carly gets the site from the request file, never from the link.
-- Returns the search (an existing one for the same site), or nil when it couldn't start.
function store.ask_carly(input: string, cx: BlockCx): Search?
	ensure_loaded()
	local site = url.normalize(input)
	if site == nil then
		return nil
	end
	for _, s in searches do
		if s.site == site then
			return s
		end
	end
	local id = carly.new_id()
	while searches[id] ~= nil or carly.read(id, "request") ~= nil or carly.read(id, "result") ~= nil do
		id = carly.new_id()
	end
	local s: Search = { id = id, site = site, at = os.time() }
	if not carly.write(id, "request", { site = site, at = s.at }) then
		return nil
	end
	searches[id] = s
	handled[id] = 0
	cx:open("tern-rss://carly/" .. id)
	start_carly_poll()
	notify()
	return s
end

-- Carly searches in progress, oldest first.
function store.searches(): { Search }
	ensure_loaded()
	local out: { Search } = {}
	for _, s in searches do
		table.insert(out, s)
	end
	table.sort(out, function(a: Search, b: Search): boolean
		return a.at < b.at
	end)
	return out
end

-- Fetches every feed now (feeds already in flight finish their current request).
function store.refresh_all()
	ensure_loaded()
	for _, f in feeds_list do
		next_at[f.id] = 0
	end
	pump()
end

-- Feeds being fetched right now.
function store.busy(): number
	return inflight_n
end

-- When any feed was last checked, or nil when none ever was.
function store.checked(): number?
	ensure_loaded()
	local best: number? = nil
	for _, s in statuses do
		if s.checked and (best == nil or s.checked > best) then
			best = s.checked
		end
	end
	return best
end

return store
