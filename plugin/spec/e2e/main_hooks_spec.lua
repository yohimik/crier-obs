local ffi = require("ffi")
local obs = require("obslua")
ffi.cdef(
	"int setenv(const char*,const char*,int); int unsetenv(const char*); char* getcwd(char*,unsigned long); int usleep(unsigned int);"
)
describe("OBS entry points #posix", function()
	it("loads the source entry under OBS error/print hooks, then releases callbacks and borrowed settings", function()
		obs.reset()
		local state = os.tmpname()
		os.remove(state)
		ffi.C.setenv("CRIER_OBS_STATE_DIR", state, 1)
		local current = ffi.string(ffi.C.getcwd(ffi.new("char[4096]"), 4096))
		local fake = current .. (current:match("/plugin$") and "/spec/fakes/crier" or "/plugin/spec/fakes/crier")
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
