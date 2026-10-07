--!strict
-- Typed per-block config over tern.kv (<plugin data>/kv.json), usable from both halves. Every key has
-- a declared default whose type the stored value must match. Config never holds secrets.

local config = {}

export type Value = string | number | boolean
export type Defaults = { [string]: Value }
export type Namespace = {
	get: (key: string) -> any,
	set: (key: string, value: Value?) -> (),
}

-- Warn-once memo for this VM: kv keys already reported as mistyped, and whether a read failure was.
local warned: { [string]: boolean } = {}
local read_warned = false

local function namespace(prefix: string, defaults: Defaults): Namespace
	local function kvkey(key: string): string
		if defaults[key] == nil then
			error(`config: unknown key "{key}" in {prefix}`, 3)
		end
		return prefix .. "/" .. key
	end

	return {
		get = function(key: string): any
			local k = kvkey(key)
			local default = defaults[key]
			local ok, v = pcall(tern.kv.get, k)
			if not ok then
				if not read_warned then
					read_warned = true
					tern.log.warn(`tern-rss config: cannot read kv.json ({v}); using defaults`)
				end
				return default
			end
			if v == nil then
				return default
			end
			if type(v) ~= type(default) then
				if not warned[k] then
					warned[k] = true
					tern.log.warn(`tern-rss config: {k} holds a {type(v)}, expected a {type(default)}; using the default`)
				end
				return default
			end
			return v
		end,
		set = function(key: string, value: Value?)
			local k = kvkey(key)
			if value == nil then
				tern.kv.set(k, nil)
				return
			end
			local want = type(defaults[key])
			if type(value) ~= want then
				error(`config: {k} expects a {want}, got a {type(value)}`, 2)
			end
			tern.kv.set(k, value)
		end,
	}
end

-- Settings of block `name` (kv keys `config/block/<name>/<key>`) with the given defaults.
function config.for_block(name: string, defaults: Defaults): Namespace
	if type(name) ~= "string" or not string.find(name, "^[a-z][a-z0-9-]*$") then
		error(`config.for_block("{name}"): the name must match ^[a-z][a-z0-9-]*$`, 2)
	end
	for key, default in defaults do
		local t = type(default)
		if t ~= "string" and t ~= "number" and t ~= "boolean" then
			error(`config.for_block("{name}"): default "{key}" must be a string, number or boolean, got a {t}`, 2)
		end
	end
	return namespace("config/block/" .. name, table.clone(defaults))
end

return config
