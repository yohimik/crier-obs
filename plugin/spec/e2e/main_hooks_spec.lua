local ffi = require("ffi")
local obs = require("obslua")
ffi.cdef("int setenv(const char*,const char*,int); int unsetenv(const char*); int usleep(unsigned int);")
describe("OBS entry points #posix", function()
	it("loads the source entry under OBS error/print hooks, then releases callbacks and borrowed settings", function()
		obs.reset()
		local state = os.tmpname()
		os.remove(state)
		ffi.C.setenv("CRIER_OBS_STATE_DIR", state, 1)
		local fake = require("fakes.paths").crier
		local oldservice, oldmain = package.loaded["crier_obs.secrets.service"], package.loaded["crier_obs.main"]
		local olderror, oldprint = _G.error, _G.print
		local secret = {
			tick = function() end,
			resolve = function(_, _, cb)
				cb({})
			end,
			status = function()
				return { state = "not stored" }
			end,
			scrub = function(data)
				obs.obs_data_unset_user_value(data, "publish.telegram.token")
			end,
			backend_status = function()
				return { state = "ready", label = "test store" }
			end,
			clear_cache = function() end,
			pending = function() end,
			close = function() end,
		}
		package.loaded["crier_obs.secrets.service"] = {
			new = function()
				return secret
			end,
		}
		package.loaded["crier_obs.main"] = nil
		_G.error = function(message)
			obs.script_log(obs.LOG_ERROR, tostring(message))
		end
		_G.print = function() end
		local data = obs.obs_data_create()
		local main
		local ok, message = pcall(function()
			main = require("crier_obs.main")
			assert.is_truthy(main.script_description():find("crier%-obs"))
			main.script_defaults(data)
			obs.obs_data_set_string(data, "cobs.crier_path", fake)
			obs.obs_data_set_bool(data, "publish.telegram.enabled", true)
			main.script_load(data)
			main.script_update(data)
			assert.is_truthy(main.script_properties())
			obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
			for _ = 1, 20 do
				obs.advance(0.5)
				ffi.C.usleep(2000)
			end
			obs.obs_data_set_string(data, "publish.telegram.token", "typed secret")
			main.script_save(data)
			assert.is_false(obs.obs_data_has_user_value(data, "publish.telegram.token"))
			main.script_unload()
			assert.equal(0, obs.timer_count())
		end)
		_G.error = olderror
		_G.print = oldprint
		package.loaded["crier_obs.secrets.service"] = oldservice
		package.loaded["crier_obs.main"] = oldmain
		ffi.C.unsetenv("CRIER_OBS_STATE_DIR")
		obs.obs_data_release(data)
		obs.assert_no_leaks()
		assert.is_true(ok, message)
	end)
end)
describe("spec environment", function()
	it("runs every crier_obs chunk with OBS's error and print hooks, from the bundle when asked", function()
		obs.reset()
		local plugin = require("crier_obs.plugin")
		local environment = getfenv(plugin.new)
		assert.is_nil(environment.error("hooked failure"))
		environment.print("hooked", 1)
		assert.same({ level = obs.LOG_ERROR, text = "hooked failure" }, obs.logs[1])
		assert.same({ level = obs.LOG_INFO, text = "hooked\t1" }, obs.logs[2])
		assert.is_not.equal(_G.error, environment.error)
		local source = debug.getinfo(plugin.new, "S").source
		local bundle = os.getenv("CRIER_OBS_E2E_BUNDLE")
		if bundle and bundle ~= "" then
			assert.equal("@" .. bundle, source)
		else
			assert.matches("src/crier_obs/plugin%.lua$", source)
		end
		assert.matches("^/tmp/crier%-obs%-spec%-%d+/", os.tmpname())
	end)
end)
