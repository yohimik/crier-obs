local ffi = require("ffi")
local obs = require("obslua")
local json = require("crier_obs.json")
local plugin_module = require("crier_obs.plugin")
local fs_module = require("crier_obs.ports.fs")
ffi.cdef(
	[[int usleep(unsigned int); char *getcwd(char*,unsigned long); int setenv(const char*,const char*,int); int unsetenv(const char*);]]
)
local function cwd()
	return ffi.string(ffi.C.getcwd(ffi.new("char[4096]"), 4096))
end
local root = ffi.os == "Windows" and "." or cwd()
local fake = root .. (root:match("/plugin$") and "/spec/fakes/crier" or "/plugin/spec/fakes/crier")
local function fake_secrets()
	local tasks = {}
	local s = { backend_name = "fake" }
	function s.resolve(_, keys, cb)
		tasks[#tasks + 1] = function()
			local values = {}
			for _, key in ipairs(keys) do
				if key == "publish.telegram.token" then
					values[key] = "VERY_SECRET_TOKEN"
				end
			end
			cb(values)
		end
	end
	function s.tick()
		local jobs = tasks
		tasks = {}
		for _, fn in ipairs(jobs) do
			fn()
		end
	end
	function s.status()
		return { state = "stored", message = "stored ✓" }
	end
	function s.scrub(settings)
		obs.obs_data_unset_user_value(settings, "publish.telegram.token")
	end
	function s.pending() end
	function s.clear_cache() end
	function s.unload()
		tasks = {}
	end
	return s
end
local function setup()
	obs.reset()
	local path = os.tmpname()
	os.remove(path)
	local data = obs.obs_data_create()
	local p = plugin_module.new({ obs = obs, state_dir = path, secrets = fake_secrets() })
	p.defaults(data)
	obs.obs_data_set_string(data, "cobs.crier_path", fake)
	obs.obs_data_set_bool(data, "publish.telegram.enabled", true)
	obs.obs_data_set_int(data, "cobs.interval_minutes", 1)
	p.load(data)
	p.update(data)
	return p, data, path, fs_module.new({ obs = obs })
end
local function pump(_p, n)
	for _ = 1, n or 30 do
		obs.advance(0.5)
		ffi.C.usleep(2000)
	end
end
local function events(fs, path)
	local out = {}
	for _, dir in ipairs(fs.glob(path .. "/runs/*")) do
		local data = fs.read(dir .. "/data.json")
		if data then
			local doc = assert(json.decode(data))
			out[#out + 1] = { doc = doc, dir = dir }
		end
	end
	table.sort(out, function(a, b)
		return a.dir < b.dir
	end)
	return out
end
describe("runtime lifecycle through native spawning #posix", function()
	after_each(function()
		ffi.C.unsetenv("FAKE_CRIER_LEAK")
	end)
	it("posts snapshots of all seven triggers and scrubs leaked tokens before persistence", function()
		ffi.C.setenv("FAKE_CRIER_LEAK", "VERY_SECRET_TOKEN", 1)
		local p, data, path, fs = setup()
		for _, event in ipairs({ "quit", "rec_start", "rec_end", "replay" }) do
			obs.obs_data_set_bool(data, "cobs.trigger." .. event .. ".enabled", true)
		end
		p.update(data)
		obs.obs_data_set_string(data, "cobs.title", "First title")
		p.update(data)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		pump(p, 20)
		obs.obs_data_set_string(data, "cobs.title", "Later title")
		p.update(data)
		obs.advance(61)
		pump(p, 20)
		obs.emit(obs.OBS_FRONTEND_EVENT_RECORDING_STARTED)
		pump(p, 20)
		obs.last_recording = "/tmp/saved recording.mp4"
		obs.emit(obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED)
		pump(p, 20)
		obs.last_replay = "/tmp/clip 🔴.mp4"
		obs.emit(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
		pump(p, 20)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
		pump(p, 20)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		pump(p, 20)
		obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		local list = events(fs, path)
		local counts = {}
		for _, item in ipairs(list) do
			counts[item.doc.event] = (counts[item.doc.event] or 0) + 1
			for _, file in ipairs(fs.glob(item.dir .. "/*")) do
				local text = fs.read(file)
				if text then
					assert.is_nil(text:find("VERY_SECRET_TOKEN", 1, true))
				end
			end
		end
		assert.equal(2, counts.start)
		assert.equal(1, counts["end"])
		assert.equal(1, counts.interval)
		assert.equal(1, counts.quit)
		assert.equal(1, counts.recording_start)
		assert.equal(1, counts.recording_end)
		assert.equal(1, counts.replay)
		assert.equal("First title", list[1].doc.title)
		for _, line in ipairs(obs.logs) do
			assert.is_nil(line.text:find("VERY_SECRET_TOKEN", 1, true))
		end
		p.unload()
		assert.equal(0, obs.timer_count())
		obs.obs_data_release(data)
		obs.assert_no_leaks()
	end)
	it("coalesces a sleep burst and records end data at enqueue while a start is running", function()
		local p, data, path, fs = setup()
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		obs.obs_data_set_string(data, "cobs.title", "End snapshot")
		p.update(data)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
		obs.obs_data_set_string(data, "cobs.title", "Changed after enqueue")
		p.update(data)
		pump(p, 30)
		local list = events(fs, path)
		assert.equal(2, #list)
		assert.equal("end", list[2].doc.event)
		assert.equal("End snapshot", list[2].doc.title)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		obs.advance(1000)
		pump(p, 30)
		local count = 0
		for _, item in ipairs(events(fs, path)) do
			if item.doc.event == "interval" then
				count = count + 1
			end
		end
		assert.equal(1, count)
		p.unload()
		obs.obs_data_release(data)
		obs.assert_no_leaks()
	end)
	it("loads midstream without a start post and never performs I/O during update", function()
		local p, data, path, fs = setup()
		p.unload()
		obs.streaming = true
		p.load(data)
		pump(p, 10)
		assert.equal(0, #events(fs, path))
		local spawn = p.spawner.spawn
		local reads, writes = 0, 0
		local oldread, oldwrite = fs.read, fs.write
		fs.read = function(...)
			reads = reads + 1
			return oldread(...)
		end
		fs.write = function(...)
			writes = writes + 1
			return oldwrite(...)
		end
		p.spawner.spawn = function()
			assert(false, "spawn during update")
		end
		obs.obs_data_set_int(data, "cobs.interval_minutes", 3)
		p.update(data)
		assert.equal(0, reads)
		assert.equal(0, writes)
		p.spawner.spawn = spawn
		p.unload()
		obs.obs_data_release(data)
		obs.assert_no_leaks()
	end)
end)
