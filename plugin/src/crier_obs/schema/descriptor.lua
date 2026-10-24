local keys = require("crier_obs.registry.keys")
local custom = require("crier_obs.registry.custom")
local overrides = require("crier_obs.schema.overrides")
local M = {}
local platforms = {}
for _, d in ipairs(keys) do
	if d.platform then
		platforms[d.platform] = true
	end
end
function M.platforms()
	local out = {}
	for name in pairs(platforms) do
		out[#out + 1] = name
	end
	table.sort(out)
	return out
end
function M.valid_custom(name)
	return type(name) == "string" and name:match("^[a-z0-9][a-z0-9%-]*$") ~= nil and not platforms[name]
end
local function descriptor(original, name)
	local d = {}
	for k, v in pairs(original) do
		d[k] = v
	end
	if name then
		d.key = d.key:gsub("<name>", name)
		d.platform = name
		d.custom = true
	end
	if d.key:match("%.env%.<VAR>$") then
		d.key = d.key:gsub("%.<VAR>$", "")
		d.kind = "list"
		d.default = {}
	end
	d.label = d.key
	for k, v in pairs(overrides.for_key(d)) do
		d[k] = v
	end
	d.widget = d.secret and "password"
		or (d.enum and "enum")
		or (d.kind == "list" and "list")
		or (d.path and "path")
		or d.widget
		or d.kind
	return d
end
function M.build(names)
	local out = {}
	for _, d in ipairs(keys) do
		out[#out + 1] = descriptor(d)
	end
	local seen = {}
	for _, name in ipairs(names or {}) do
		if M.valid_custom(name) and not seen[name] then
			seen[name] = true
			for _, d in ipairs(custom) do
				out[#out + 1] = descriptor(d, name)
			end
		end
	end
	return out
end
return M
