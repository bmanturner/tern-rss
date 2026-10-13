--!strict
-- The channel from an RSS block's clicks to the reader beside it; host half only (tern.fs on the
-- host's own data folder, which is where the RSS block and the readers it opens both run, local or
-- remote). The RSS block writes `reader-<its pane>.json` ({url, seq}) before it opens the link
-- route; a reader launched for that pane polls the file, so it always follows the latest click,
-- including clicks made while it was starting or failing over to the browser. The window half
-- never touches it. Files stay behind when a pane closes: they are a few bytes, keyed by RSS pane
-- id, and the next click on that id overwrites them. Each click bumps `seq`, so a reader tells a
-- new click from the one it was opened for (or from nothing, for a hand-made link) by comparing it
-- with the number it has already applied.

local target = {}

export type Target = { url: string, seq: number }

local dir_ready = false

local function path(owner: number): string
	return `{tern.plugin.data}/reader-{owner}.json`
end

-- The latest click recorded for RSS pane `owner`, or nil when there is none or it is unreadable
-- (a half-written file reads again on the next poll).
function target.read(owner: number): Target?
	local ok, exists = pcall(tern.fs.exists, path(owner))
	if not (ok and exists) then
		return nil
	end
	local read_ok, text = pcall(tern.fs.read, path(owner))
	if not read_ok then
		return nil
	end
	local decode_ok, doc = pcall(tern.json.decode, text)
	if not decode_ok or type(doc) ~= "table" then
		return nil
	end
	local u, seq = (doc :: any).url, (doc :: any).seq
	if type(u) ~= "string" or type(seq) ~= "number" then
		return nil
	end
	return { url = u, seq = seq }
end

-- Records a click on `u` for RSS pane `owner` and returns its number (one past the file's last).
function target.write(owner: number, u: string): number
	if not dir_ready then
		dir_ready = true
		pcall(tern.fs.mkdir, tern.plugin.data) -- the folder may not exist before the first kv write
	end
	local prev = target.read(owner)
	local seq = (if prev then prev.seq else 0) + 1
	local ok, err = pcall(tern.fs.write, path(owner), tern.json.encode({ url = u, seq = seq }))
	if not ok then
		tern.log.warn("tern-rss: cannot record the reader target", err)
	end
	return seq
end

return target
