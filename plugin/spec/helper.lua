jit.off()
require("luacov")
local ffi = require("ffi")
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.-)spec/helper.lua$") or ""
package.path = root .. "src/?.lua;" .. root .. "src/?/init.lua;" .. root .. "spec/?.lua;" .. package.path

-- OBS replaces error and print in every script state (obs-scripting-lua.c, hook_error and hook_print):
-- both log and return, so an error() used for control flow would continue with nils inside OBS.
-- Every crier_obs chunk therefore runs in an environment with those hooks; specs keep the real ones.
local function stub()
	return require("stub.obslua")
end
local function hook_error(message)
	stub().script_log(stub().LOG_ERROR, tostring(message))
end
local function hook_print(...)
	local parts = { ... }
	for i = 1, select("#", ...) do
		parts[i] = tostring(parts[i])
	end
	stub().script_log(stub().LOG_INFO, table.concat(parts, "\t"))
end
local obs_environment = setmetatable({}, {
	__index = function(_, name)
		if name == "error" then
			return hook_error
		elseif name == "print" then
			return hook_print
		end
		return _G[name]
	end,
	__newindex = _G,
})
table.insert(package.loaders, 2, function(name)
	if not name:match("^crier_obs%.") then
		return nil
	end
	local path = package.searchpath(name, root .. "src/?.lua")
	if not path then
		return nil
	end
	local chunk = assert(loadfile(path))
	return setfenv(chunk, obs_environment)
end)

-- CRIER_OBS_E2E_BUNDLE=dist/crier-obs.lua runs the specs against the built bundle: its package.preload
-- entries shadow src/, so the delivered chunk is what the lifecycle specs exercise.
local bundle = os.getenv("CRIER_OBS_E2E_BUNDLE")
if bundle and bundle ~= "" then
	local file = assert(io.open(bundle, "rb"))
	local text = file:read("*a")
	file:close()
	local body, entries = text:gsub('\nrequire%("crier_obs%.main"%)\n$', "\n")
	assert(entries == 1, "bundle does not end with its entry point")
	setfenv(assert(loadstring(body, "@" .. bundle)), obs_environment)()
end

package.preload.obslua = function()
	return require("stub.obslua")
end

-- Deterministic scratch space: every temporary name and the stub's config path live under one
-- per-run directory, which child processes also receive as TMPDIR.
ffi.cdef("int getpid(void); int setenv(const char*,const char*,int); int mkdir(const char*,unsigned int);")
local scratch = "/tmp/crier-obs-spec-" .. tonumber(ffi.C.getpid())
if ffi.os ~= "Windows" then
	ffi.C.mkdir(scratch, 448)
	ffi.C.setenv("TMPDIR", scratch, 1)
	local counter = 0
	os.tmpname = function() -- luacheck: ignore 122
		counter = counter + 1
		local name = scratch .. "/tmp" .. counter
		local file = assert(io.open(name, "wb"))
		file:close()
		return name
	end
	require("stub.obslua").tmp_root = scratch .. "/obs-config/"
end

return function(busted)
	busted.api.after_each(function()
		local obs = require("stub.obslua")
		local ok, err = pcall(obs.assert_no_leaks)
		if not ok then
			obs.forget_references()
			assert(false, err)
		end
	end)
	busted.subscribe({ "suite", "end" }, function()
		if ffi.os ~= "Windows" then
			os.execute("rm -rf '" .. scratch .. "'")
		end
		return nil, true
	end)
	return true
end
