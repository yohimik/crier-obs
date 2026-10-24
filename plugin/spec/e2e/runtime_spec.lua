local ffi = require("ffi")
local obs = require("obslua")
local json = require("crier_obs.json")
local plugin_module = require("crier_obs.plugin")
local fs_module = require("crier_obs.ports.fs")
ffi.cdef(
	[[int usleep(unsigned int); char *getcwd(char*,unsigned long); int setenv(const char*,const char*,int); int unsetenv(const char*);
int pipe(int[2]); int socket(int,int,int); int fcntl(int,int,...); int close(int); int kill(int,int);]]
)
local function cwd()
	return ffi.string(ffi.C.getcwd(ffi.new("char[4096]"), 4096))
end
local root = ffi.os == "Windows" and "." or cwd()
local fake = root .. (root:match("/plugin$") and "/spec/fakes/crier" or "/plugin/spec/fakes/crier")
local function fake_secrets()
	local tasks = {}
	local s = {}
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
		return { state = "stored" }
	end
	function s.backend_status()
		return { state = "ready", label = "fake store" }
	end
	function s.scrub(settings)
		obs.obs_data_unset_user_value(settings, "publish.telegram.token")
	end
	function s.pending() end
	function s.clear_cache() end
	function s.close()
		tasks = {}
	end
	return s
end
-- Counts every file operation of the very fs instance the plugin uses.
local function counting_fs()
	local fs = fs_module.new({ obs = obs })
	local counts = { reads = 0, writes = 0 }
	for _, name in ipairs({ "read", "write", "write_private", "create_private", "mkdir", "mkdir_private", "remove" }) do
		local original = fs[name]
		fs[name] = function(...)
			counts[name:match("^read") and "reads" or "writes"] = counts[name:match("^read") and "reads" or "writes"]
				+ 1
			return original(...)
		end
	end
	return fs, counts
end
local function setup(options)
	options = options or {}
	obs.reset()
	local path = os.tmpname()
	os.remove(path)
	local data = obs.obs_data_create()
	local fs, counts = counting_fs()
	local p = plugin_module.new({ obs = obs, fs = fs, state_dir = path, secrets = fake_secrets() })
	p.defaults(data)
	obs.obs_data_set_string(data, "cobs.crier_path", options.crier or fake)
	obs.obs_data_set_bool(data, "publish.telegram.enabled", true)
	obs.obs_data_set_int(data, "cobs.interval_minutes", 1)
	p.load(data)
	p.update(data)
	return p, data, path, fs, counts
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
local function finish_post(p, count)
	for _ = 1, count or 200 do
		obs.advance(0.5)
		ffi.C.usleep(2000)
		if not p.queue.active() and p.queue.size() == 0 then
			return
		end
	end
	assert(false, "post did not finish")
end
local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end
local function logged(level, text)
	local out = {}
	for _, line in ipairs(obs.logs) do
		if line.level == level and line.text:find(text, 1, true) then
			out[#out + 1] = line.text
		end
	end
	return out
end
local function cleanup(p, data)
	obs.emit(obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING)
	p.unload()
	obs.obs_data_release(data)
	obs.assert_no_leaks()
end
describe("runtime lifecycle through native spawning #posix", function()
	after_each(function()
		for _, name in ipairs({
			"FAKE_CRIER_LEAK",
			"FAKE_CRIER_EXIT",
			"FAKE_CRIER_OUT",
			"FAKE_CRIER_SLEEP",
			"FAKE_CRIER_IGNORE_TERM",
		}) do
			ffi.C.unsetenv(name)
		end
	end)
	it("maps every crier exit code to the last-run row and the log level", function()
		local expected = {
			{ 1, "Invalid configuration", obs.LOG_ERROR },
			{ 2, "Invalid command arguments", obs.LOG_ERROR },
			{ 3, "Rendering failed", obs.LOG_ERROR },
			{ 4, "Some platforms failed", obs.LOG_WARNING },
			{ 5, "Publishing failed", obs.LOG_ERROR },
			{ 6, "Staging failed", obs.LOG_ERROR },
			{ 97, "Run directory is missing", obs.LOG_ERROR },
			{ 0, "Posted successfully", obs.LOG_INFO },
		}
		for _, case in ipairs(expected) do
			ffi.C.setenv("FAKE_CRIER_EXIT", tostring(case[1]), 1)
			local p, data = setup()
			p.callbacks.post()
			finish_post(p)
			assert.equal(case[2], p.status().last_run, "exit " .. case[1])
			assert.equal(1, #logged(case[3], "crier-obs: " .. case[2]), "exit " .. case[1])
			cleanup(p, data)
		end
	end)
	it("reports a crier that is not executable or cannot start, with the quarantine hint", function()
		local dir = os.tmpname()
		os.remove(dir)
		assert(fs_module.new({ obs = obs }).mkdir(dir))
		local plain = dir .. "/crier-not-executable"
		local f = assert(io.open(plain, "wb"))
		f:write("#!/bin/sh\nexit 0\n")
		f:close()
		-- Found when the post was queued, gone when it starts: the wrapper's exec fails with 127.
		local vanishing = dir .. "/crier-vanishing"
		f = assert(io.open(vanishing, "wb"))
		f:write("#!/bin/sh\nexit 0\n")
		f:close()
		os.execute("chmod 755 '" .. vanishing .. "'")
		for _, case in ipairs({ { plain, "crier is not executable" }, { vanishing, "crier was not found" } }) do
			local p, data = setup({ crier = case[1] })
			p.callbacks.post()
			if case[1] == vanishing then
				os.remove(vanishing)
			end
			finish_post(p)
			assert.equal(case[2], p.status().last_run)
			local line = logged(obs.LOG_ERROR, case[2])
			assert.equal(1, #line)
			if case[2] == "crier is not executable" then
				assert.matches("quarantine", line[1], 1, true)
			end
			cleanup(p, data)
		end
	end)
	it("stops a timed-out crier that ignores TERM and leaves none of its processes behind", function()
		local out = os.tmpname()
		os.remove(out)
		-- Set after load, so only the post (not the version probe) runs the stubborn crier.
		local p, data = setup()
		ffi.C.setenv("FAKE_CRIER_OUT", out, 1)
		ffi.C.setenv("FAKE_CRIER_SLEEP", "30", 1)
		ffi.C.setenv("FAKE_CRIER_IGNORE_TERM", "1", 1)
		obs.obs_data_set_int(data, "cobs.timeout", 1)
		p.update(data)
		p.callbacks.post()
		local child
		for _ = 1, 400 do
			-- Stub time only runs once crier is up, so TERM reaches a crier that ignores it.
			child = child or tonumber(read_file(out .. "/pid"))
			if child then
				ffi.C.usleep(20000)
				obs.advance(0.5)
			else
				p.tick()
			end
			ffi.C.usleep(5000)
			if child and not p.queue.active() then
				break
			end
		end
		assert.is_number(child)
		assert.is_nil(p.queue.active())
		assert.equal("crier exceeded the run timeout", p.status().last_run)
		local gone = false
		for _ = 1, 200 do
			if ffi.C.kill(child, 0) == -1 and ffi.errno() == 3 then
				gone = true
				break
			end
			ffi.C.usleep(5000)
		end
		assert.is_true(gone, "crier " .. child .. " survived the timeout")
		cleanup(p, data)
	end)
	it("hands crier no descriptor of OBS beyond the standard streams", function()
		local out = os.tmpname()
		os.remove(out)
		ffi.C.setenv("FAKE_CRIER_OUT", out, 1)
		-- An inheritable pipe and socket, the way OBS leaves its RTMP and websocket descriptors.
		local fds = ffi.new("int[2]")
		assert.equal(0, ffi.C.pipe(fds))
		local socket = ffi.C.socket(1, 1, 0)
		assert.is_true(socket >= 0)
		local high = {}
		for i, fd in ipairs({ fds[0], fds[1], socket }) do
			high[i] = ffi.C.fcntl(fd, 0, ffi.new("int", 60 + i))
			ffi.C.close(fd)
		end
		local p, data = setup()
		p.callbacks.post()
		finish_post(p)
		for _, fd in ipairs(high) do
			ffi.C.close(fd)
		end
		local listed = assert(read_file(out .. "/fds"))
		local seen = {}
		for fd in listed:gmatch("%d+") do
			seen[#seen + 1] = tonumber(fd)
			-- 0-2 are the standard streams; ls itself opens 3 (and 4 on macOS) to list /dev/fd.
			assert.is_true(tonumber(fd) <= 4, "inherited descriptor " .. fd)
		end
		assert.is_true(#seen >= 3)
		for _, fd in ipairs(high) do
			assert.is_true(fd > 60)
		end
		cleanup(p, data)
	end)
	it("posts the quit post once when OBS ends without SCRIPTING_SHUTDOWN, from the unload", function()
		local p, data, path, fs = setup()
		obs.obs_data_set_bool(data, "cobs.trigger.quit.enabled", true)
		p.update(data)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		pump(p, 20)
		p.unload()
		local quits = 0
		for _, item in ipairs(events(fs, path)) do
			if item.doc.event == "quit" then
				quits = quits + 1
			end
		end
		assert.equal(1, quits)
		assert.equal(1, #logged(obs.LOG_INFO, "quit post spawned"))
		obs.obs_data_release(data)
		obs.assert_no_leaks()
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
		-- Each event carries only its own file.
		for _, item in ipairs(list) do
			local doc = item.doc
			assert.equal(
				doc.event == "recording_end" and "/tmp/saved recording.mp4" or "",
				doc.recording_path,
				doc.event
			)
			assert.equal(doc.event == "replay" and "/tmp/clip 🔴.mp4" or "", doc.replay_path, doc.event)
		end
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
		local p, data, path, fs, counts = setup()
		obs.emit(obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING)
		p.unload()
		obs.streaming = true
		obs.stream_frames = 60 * 90
		p.load(data)
		pump(p, 10)
		assert.equal(0, #events(fs, path))
		-- The stream had run 90 s (frames / fps) before the script saw it.
		assert.is_true(p.scheduler.stream.estimated)
		assert.is_true(p.scheduler.stream.uptime() >= 90)
		local spawn = p.spawner.spawn
		p.spawner.spawn = function()
			assert(false, "spawn during update")
		end
		counts.reads, counts.writes = 0, 0
		obs.obs_data_set_int(data, "cobs.interval_minutes", 3)
		obs.obs_data_set_string(data, "cobs.title", "typing")
		p.update(data)
		obs.obs_data_set_string(data, "cobs.crier_path", "/elsewhere/crier")
		p.update(data)
		assert.equal(0, counts.reads)
		assert.equal(0, counts.writes)
		p.spawner.spawn = spawn
		obs.emit(obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING)
		p.unload()
		obs.obs_data_release(data)
		obs.assert_no_leaks()
	end)
end)
