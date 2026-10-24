-- Exercise the delivered chunk in OBS's nonthrowing error/print environment.
-- The bundle runs alone. The OBS stub (spec/stub) is the only file read from the checkout, and every
-- crier_obs module, including the json and utf16 modules the stub itself uses, must come from the
-- bundle's package.preload: a module the bundle lacks fails the smoke instead of loading from src/.
package.path = "spec/?.lua"
package.cpath = ""
local loaders = package.loaders
local preload_loader, lua_loader = loaders[1], loaders[2]
for i = #loaders, 1, -1 do
	loaders[i] = nil
end
loaders[1] = preload_loader
loaders[2] = function(name)
	if name:match("^stub%.") then
		return lua_loader(name)
	end
	return "\n\tno module '" .. name .. "' in the bundle under test"
end
local ffi = require("ffi")
-- Loaded lazily, after the bundle has registered its modules, so the stub's own requires resolve there.
package.preload.obslua = function()
	return require("stub.obslua")
end
local obs
local function stub()
	obs = obs or require("obslua")
	return obs
end
local path = arg[1] or "dist/crier-obs.lua"
local source = assert(io.open(path, "rb"))
local text = source:read("*a")
source:close()
local bundled = {}
for name in text:gmatch('package%.preload%["([^"]+)"%]=function') do
	bundled[name] = true
end
-- Every module name the bundle spells out, including platform-specific ones this host never loads.
for _, name in text:gmatch("([\"'])(crier_obs%.[%w_%.]+)%1") do
	assert(name:sub(-1) == "." or bundled[name], "bundle does not contain module " .. name)
end
local expected_version, expected_pin
for i = 2, #arg do
	if arg[i] == "--version" then
		expected_version = arg[i + 1]
	end
	if arg[i] == "--pin" then
		expected_pin = arg[i + 1]
	end
end
local original_error, original_print = error, print
local state = os.tmpname() .. "-crier-obs-smoke"
os.remove(state:gsub("%-crier%-obs%-smoke$", ""))
local cwd
if ffi.os == "Windows" then
	ffi.cdef("int _putenv(const char*); char *_getcwd(char*,int); void __stdcall Sleep(unsigned long);")
	assert(ffi.C._putenv("CRIER_OBS_STATE_DIR=" .. state) == 0)
	cwd = ffi.string(ffi.C._getcwd(ffi.new("char[4096]"), 4096))
else
	ffi.cdef("int setenv(const char*,const char*,int); int usleep(unsigned int); char *getcwd(char*,unsigned long);")
	assert(ffi.C.setenv("CRIER_OBS_STATE_DIR", state, 1) == 0)
	cwd = ffi.string(ffi.C.getcwd(ffi.new("char[4096]"), 4096))
end
local fake = cwd .. (ffi.os == "Windows" and "/spec/fakes/crier_win/crier.exe" or "/spec/fakes/crier")
local settings
local function run()
	error = function(message)
		local o = stub()
		o.script_log(o.LOG_ERROR, tostring(message))
	end
	print = function(...)
		local values = { ... }
		for i, v in ipairs(values) do
			values[i] = tostring(v)
		end
		local o = stub()
		o.script_log(o.LOG_INFO, table.concat(values, "\t"))
	end
	local chunk = assert(loadfile(path))
	chunk()
	stub()
	assert(obs.os_file_exists(fake), "native fake crier is missing: " .. fake)
	local version = require("crier_obs.version")
	local meta = require("crier_obs.registry.meta")
	assert(not expected_version or version.VERSION == expected_version, "bundle version differs")
	assert(not expected_pin or version.CRIER_VERSION == expected_pin, "bundle crier pin differs")
	assert(meta.version == version.CRIER_VERSION, "registry and bundle pin differ")
	assert(type(script_description) == "function" and script_description():find(version.VERSION, 1, true))
	settings = obs.obs_data_create()
	script_defaults(settings)
	obs.obs_data_set_string(settings, "cobs.crier_path", fake)
	obs.obs_data_set_string(settings, "cobs.title", "Bundle smoke 🔴")
	-- A custom destination needs no real keyring lookup or account credentials.
	local names = obs.obs_data_array_create()
	local item = obs.obs_data_create()
	obs.obs_data_set_string(item, "value", "smoke")
	obs.obs_data_array_push_back(names, item)
	obs.obs_data_set_array(settings, "cobs.custom_names", names)
	obs.obs_data_array_release(names)
	obs.obs_data_release(item)
	obs.obs_data_set_bool(settings, "publish.custom.smoke.enabled", true)
	script_load(settings)
	script_update(settings)
	local props = assert(script_properties(), "properties were not built")
	for _, d in ipairs(require("crier_obs.registry.keys")) do
		assert(props.by_name[d.key], "registry property missing: " .. d.key)
	end
	local fs = require("crier_obs.ports.fs").new({ obs = obs })
	local json = require("crier_obs.json")
	local function completed(event)
		for _, dir in ipairs(fs.glob(state .. "/runs/*")) do
			local raw = fs.read(dir .. "/journal.json")
			local journal = raw and json.decode(raw)
			if journal and journal.event == event and journal.state == "done" then
				local config = assert(json.decode(assert(fs.read(dir .. "/config.json"))))
				local data = assert(json.decode(assert(fs.read(dir .. "/data.json"))))
				assert(data.title == "Bundle smoke 🔴", "context title differs")
				assert(config.publish.custom.smoke.enabled == true, "destination was not enabled")
				assert(
					(config.render.width or 1080) == 1080
						and config.render.height == 1080
						and config.render["hermetic-fonts"] == true,
					"plugin render defaults were omitted"
				)
				local expected = event == "start" and "🔴 Live now: {{ .title }}"
					or "Thanks for watching! {{ .title }}"
				assert(config.publish.caption == expected, "trigger caption differs")
				return true
			end
		end
		return false
	end
	local function wait_for(event)
		for _ = 1, 500 do
			obs.advance(0.5)
			if completed(event) then
				return
			end
			if ffi.os == "Windows" then
				ffi.C.Sleep(5)
			else
				ffi.C.usleep(5000)
			end
		end
		original_error("Bundle smoke did not complete " .. event .. " post")
	end
	obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
	wait_for("start")
	obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
	wait_for("end")
	script_save(settings)
	script_unload()
	obs.obs_data_release(settings)
	settings = nil
	obs.assert_no_leaks()
	assert(obs.timer_count() == 0, "heartbeat was not removed")
	for _, line in ipairs(obs.logs) do
		if line.level == obs.LOG_ERROR then
			original_error("Bundle smoke logged an error: " .. line.text)
		end
	end
	for name in pairs(package.loaded) do
		assert(not name:match("^crier_obs%.") or bundled[name], "module loaded from outside the bundle: " .. name)
	end
	return version
end
local ok, result = pcall(run)
error = original_error
print = original_print
if not ok then
	if script_unload then
		pcall(script_unload)
	end
	if settings then
		obs.obs_data_release(settings)
	end
	original_error(result)
end
print("Bundle smoke passed: " .. result.VERSION .. ", crier " .. result.CRIER_VERSION)
