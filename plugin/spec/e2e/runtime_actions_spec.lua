local obs = require("obslua")
local json = require("crier_obs.json")
local plugin = require("crier_obs.plugin")
local function failure(message)
	return { kind = "test", message = message or "failed" }
end
local function fixture(options)
	options = options or {}
	obs.reset()
	local files, records, finishes = {}, {}, {}
	local pending = {}
	local spawned = {}
	local count = 0
	local fs = {
		exists = function(path)
			return path == "/fake/crier"
				or path == "C:/tools/ffmpeg.exe"
				or path == "C:/tools/zrok.exe"
				or files[path] ~= nil
		end,
		read = function(path)
			return files[path]
		end,
		write = function(path, data)
			if options.write_fail and path:match(options.write_fail) then
				return nil, failure("disk full")
			end
			files[path] = data
			return true
		end,
	}
	fs.glob = function()
		return {}
	end
	fs.write_private = fs.write
	fs.remove = function(path)
		files[path] = nil
		return true
	end
	local runs = {
		init = function()
			return not options.init_fail, options.init_fail and failure("state unavailable")
		end,
		sweep = function() end,
		create = function(event)
			if options.create_fail then
				return nil, failure("run unavailable")
			end
			count = count + 1
			local dir = "/state/runs/" .. count
			return {
				dir = dir,
				event = event,
				config = dir .. "/config.json",
				data = dir .. "/data.json",
				stdout = dir .. "/stdout",
				stderr = dir .. "/stderr",
				status = dir .. "/status",
				pid = dir .. "/pid",
				preview = dir .. "/preview.png",
				journal = dir .. "/journal.json",
			}
		end,
		finish = function(run, result)
			finishes[#finishes + 1] = { run = run, result = result }
		end,
		journal = function(run, record)
			records[#records + 1] = { run = run, record = record }
			return true
		end,
		adopt = function()
			return options.adopt or {}
		end,
	}
	local spawner = {
		spawn = function(plan)
			spawned[#spawned + 1] = plan
			if options.spawn_fail then
				return nil, failure("spawn unavailable")
			end
			local result = { code = 0, stdout = '{"results":[]}', stderr = "" }
			return {
				pid = 100 + #spawned,
				poll = function()
					return result
				end,
				detach = function()
					if options.detach_fail then
						return nil, failure("cannot handoff")
					end
					return { pid = 100 + #spawned }
				end,
				cancel = function()
					return true
				end,
			}
		end,
		reap = function()
			return {}
		end,
		current_pid = function()
			return 4242
		end,
		alive = function()
			return false
		end,
		adopt = function(record)
			if record.pid == 3 then
				return nil, failure("adoption unavailable")
			end
			return {
				poll = function()
					if options.adopt_pending then
						return nil
					end
					if record.pid == 4 then
						return nil, failure("poll failed")
					end
					return { code = 0 }
				end,
				cancel = function()
					records[#records + 1] = { cancelled = true }
					return true
				end,
				detach = function()
					records[#records + 1] = { detached = true }
				end,
			}
		end,
	}
	local state = options.resolver_state or { state = "ready", message = "crier ready", path = "/fake/crier" }
	local resolver = {
		find = function()
			if options.missing then
				return nil, failure("missing crier")
			end
			return "/fake/crier"
		end,
		find_binary = function(name)
			return fs.exists("C:/tools/" .. name .. ".exe") and "C:/tools/" .. name .. ".exe" or nil
		end,
		probe = function()
			return {}
		end,
		tick = function()
			return state
		end,
		status = function()
			return state
		end,
		detach = function() end,
	}
	local secret = {
		backend_status = function()
			return { state = "ready", label = "Test credential store" }
		end,
		forget_all = function(_, cb)
			cb(not options.secret_fail, options.secret_fail and failure("forget failed"))
		end,
		tick = function()
			local jobs = pending
			pending = {}
			for _, fn in ipairs(jobs) do
				fn()
			end
		end,
		resolve = function(_, _, cb)
			pending[#pending + 1] = function()
				if options.resolve_fail then
					cb(nil, failure("keyring unavailable"))
				else
					cb({})
				end
			end
		end,
		status = function()
			return { state = "stored" }
		end,
		pending = function()
			return options.pending_secret
		end,
		scrub = function(data)
			obs.obs_data_unset_user_value(data, "publish.telegram.token")
		end,
		commit = function(_, _, _, cb)
			cb(not options.secret_fail, options.secret_fail and failure("save failed"))
		end,
		forget = function(_, _, cb)
			cb(not options.secret_fail, options.secret_fail and failure("forget failed"))
		end,
		clear_cache = function() end,
		close = function() end,
	}
	local install = options.install or { state = "idle", message = "" }
	local installer = {
		start = function()
			return nil, failure("installer failed")
		end,
		status = function()
			return install
		end,
		tick = function()
			return install
		end,
		detach = function() end,
	}
	local paths = { root = "/state", runs = "/state/runs", template = "/state/template.html" }
	local p = plugin.new({
		obs = obs,
		fs = fs,
		env = {
			os = "Windows",
			augmented_path = function()
				return "C:/tools"
			end,
			crier_names = function()
				return options.inherited or {}
			end,
			sandbox_status = function()
				return options.sandbox or { kind = "native", ok = true }
			end,
		},
		paths = paths,
		spawner = spawner,
		resolver = resolver,
		secrets = secret,
		installer = installer,
		runs = runs,
	})
	local data = obs.obs_data_create()
	p.defaults(data)
	obs.obs_data_set_bool(data, "publish.telegram.enabled", true)
	obs.obs_data_set_string(data, "cobs.crier_path", "/fake/crier")
	p.load(data)
	p.update(data)
	return p,
		data,
		{
			files = files,
			spawned = spawned,
			records = records,
			finishes = finishes,
			options = options,
			resolver = state,
			install = install,
		}
end
local function finish(p, data)
	p.unload()
	obs.obs_data_release(data)
	obs.assert_no_leaks()
end
local function lines(level, text)
	local out = {}
	for _, line in ipairs(obs.logs) do
		if (not level or line.level == level) and (not text or line.text:find(text, 1, true)) then
			out[#out + 1] = line.text
		end
	end
	return out
end
describe("dialog actions and recovery", function()
	it("runs manual, dry-run and setup actions, refreshing credentials and discovered tool rows", function()
		local p, data, state = fixture({ pending_secret = "new secret", secret_fail = true })
		obs.obs_data_set_bool(data, "render.video.enabled", true)
		obs.obs_data_set_string(data, "stage.server.tunnel.mode", "zrok")
		p.update(data)
		assert(p.callbacks.install())
		assert(p.callbacks.refresh())
		assert(p.callbacks.post())
		assert(p.callbacks.dry_run())
		assert(p.callbacks.check())
		p.callbacks.save_secret("publish.telegram.token")
		p.callbacks.forget_secret("publish.telegram.token")
		p.callbacks.forget_all()
		for _ = 1, 10 do
			p.tick()
		end
		local dry = false
		for _, plan in ipairs(state.spawned) do
			for _, arg in ipairs(plan.args or {}) do
				if arg == "--publish-dry-run" then
					dry = true
				end
			end
		end
		assert.is_true(dry)
		local rows = p.status().results
		local found, warnings = {}, {}
		for _, row in ipairs(rows) do
			if row.warning then
				warnings[row.target] = row
			else
				found[row.target] = row
			end
		end
		assert.is_true(found.ffmpeg.ok)
		assert.is_true(found.tunnel.ok)
		-- Stage mode is still none, so the tunnel the dialog names would never start.
		assert.equal("The zrok tunnel starts only when Stage mode (stage.mode) is server", warnings.tunnel.message)
		assert.equal("crier ready", p.status().crier)
		obs.obs_data_set_string(data, "cobs.crier_path", "/changed")
		p.update(data)
		p.tick()
		finish(p, data)
	end)
	it("merges user JSON, passes YAML through and recovers from an invalid document", function()
		local p, data, state = fixture()
		state.files["/state/user.json"] = '{"title":"user title","extra":42}'
		obs.obs_data_set_string(data, "render.data", "user.json")
		obs.obs_data_set_string(data, "cobs.title", "stream title")
		p.update(data)
		p.callbacks.post()
		assert.equal("user title", json.decode(state.files["/state/runs/1/data.json"]).title)
		assert.equal(42, json.decode(state.files["/state/runs/1/data.json"]).extra)
		obs.obs_data_set_string(data, "render.data", "user.yaml")
		p.update(data)
		p.callbacks.post()
		assert.is_nil(state.files["/state/runs/2/data.json"])
		state.files["/state/broken.json"] = "{"
		obs.obs_data_set_string(data, "render.data", "broken.json")
		p.update(data)
		p.callbacks.post()
		assert.equal("stream title", json.decode(state.files["/state/runs/3/data.json"]).title)
		obs.obs_data_set_string(data, "render.data", "env:PREFIX")
		p.update(data)
		p.callbacks.post()
		finish(p, data)
	end)
	it("reports a missing crier at error level once per rate window, and spawns nothing", function()
		local p, data, state = fixture({ missing = true })
		for _ = 1, 5 do
			p.callbacks.post()
		end
		assert.equal(0, #state.spawned)
		assert.same({ "crier-obs: missing crier" }, lines(obs.LOG_ERROR, "missing crier"))
		obs.advance(31)
		p.callbacks.post()
		assert.equal(2, #lines(obs.LOG_ERROR, "missing crier"))
		finish(p, data)
	end)
	it("still reports a post's missing crier right after the status row said it is not installed", function()
		local p, data =
			fixture({ missing = true, resolver_state = { state = "missing", message = "crier is not installed" } })
		p.tick()
		assert.same(
			{ "crier-obs: crier is not installed; click Install crier" },
			lines(obs.LOG_WARNING, "click Install")
		)
		p.callbacks.post()
		assert.same({ "crier-obs: missing crier" }, lines(obs.LOG_ERROR, "missing crier"))
		finish(p, data)
	end)
	it("shows an unwritable state folder in the Run logs row and the log", function()
		local p, data, state = fixture({ init_fail = true })
		assert.equal("State folder is unavailable: state unavailable", p.status().logs)
		assert.same({ "crier-obs: state unavailable" }, lines(obs.LOG_ERROR, "state unavailable"))
		p.callbacks.post()
		p.callbacks.check()
		assert.equal(0, #state.spawned)
		assert.equal(1, #lines(obs.LOG_ERROR, "State directory is unavailable"))
		finish(p, data)
		p, data, state = fixture({ create_fail = true })
		p.callbacks.post()
		p.callbacks.check()
		assert.equal(0, #state.spawned)
		assert.equal(2, #lines(obs.LOG_ERROR, "run unavailable"))
		finish(p, data)
		p, data, state = fixture()
		obs.obs_data_set_bool(data, "publish.telegram.enabled", false)
		p.update(data)
		p.callbacks.post()
		assert.equal(0, #state.spawned)
		assert.equal(1, #lines(obs.LOG_WARNING, "No platform is selected"))
		finish(p, data)
	end)
	it("persists failed JSON/data/config preparation and bounds queued manual requests", function()
		local p, data, state = fixture({ write_fail = "/data.json$" })
		p.callbacks.post()
		p.callbacks.check()
		assert.equal(2, #state.finishes)
		for _, item in ipairs(state.finishes) do
			assert.equal(1, item.result.code)
			assert.equal("disk full", item.result.stderr)
		end
		finish(p, data)
		p, data, state = fixture()
		obs.obs_data_set_double(data, "render.scale", math.huge)
		p.update(data)
		p.callbacks.post()
		p.callbacks.check()
		assert.equal(2, #state.finishes)
		finish(p, data)
		p, data, state = fixture()
		for _ = 1, 8 do
			p.callbacks.post()
		end
		assert.equal(5, p.queue.size())
		assert.equal(3, #state.finishes)
		finish(p, data)
	end)
	it("adopts journals, reports completed/failed adoptions and detaches adopted jobs at unload", function()
		local records = {
			{
				pid = 1,
				event = "start",
				journal = "/one",
				status_path = "/status",
				pid_path = "/pid",
				drainers = {
					{ pid = 2 },
				},
			},
			{ pid = 3, event = "end" },
			{ pid = 4, event = "manual" },
		}
		local p, data, state = fixture({ adopt = records })
		assert.same({ "crier-obs: adoption unavailable" }, lines(obs.LOG_WARNING, "adoption unavailable"))
		assert.same({ "crier-obs: Adopted 2 detached posts from an earlier load" }, lines(obs.LOG_INFO, "Adopted 2"))
		p.tick()
		assert.equal("Last run finished with code 0", p.status().last_run)
		assert.same({ "crier-obs: Adopted start post finished with code 0" }, lines(obs.LOG_INFO, "finished with code"))
		assert.same({ "crier-obs: poll failed" }, lines(obs.LOG_WARNING, "poll failed"))
		local journaled
		for _, item in ipairs(state.records) do
			if item.record and item.run and item.run.journal == "/one" then
				journaled = item.record
			end
		end
		assert.equal("done", journaled.state)
		local cancelled = false
		for _, item in ipairs(state.records) do
			cancelled = cancelled or item.cancelled == true
		end
		assert.is_true(cancelled)
		finish(p, data)
		p, data, state =
			fixture({ adopt = { { pid = 1, event = "start", created_at = os.time() } }, adopt_pending = true })
		finish(p, data)
		assert.is_true(state.records[1].detached)
	end)
	it("stops polling an adopted run that outlived its timeout and journals it as unknown", function()
		local p, data, state = fixture({
			adopt = { { pid = 1, event = "start", created_at = os.time() - 900 - 3601, journal = "/stale" } },
			adopt_pending = true,
		})
		p.tick()
		assert.same(
			{ "crier-obs: Adopted start post stopped reporting; its result is unknown" },
			lines(obs.LOG_WARNING, "stopped reporting")
		)
		assert.equal("failed", state.records[#state.records].record.state)
		assert.equal("Run stopped reporting", state.records[#state.records].record.error)
		p.tick()
		assert.equal(1, #lines(obs.LOG_WARNING, "stopped reporting"))
		finish(p, data)
	end)
	it("shows an installer failure in the crier row and logs the outdated crier once", function()
		local p, data, state = fixture({
			install = { state = "failed", message = "Install failed: sha256 digest mismatch" },
			resolver_state = {
				state = "outdated",
				version = "1.0.0",
				path = "/fake/crier",
				message = "crier 1.0.0 at /fake/crier (older than 1.1.1)",
			},
		})
		local status = p.status()
		assert.equal("Install failed: sha256 digest mismatch", status.crier)
		assert.equal("error", status.crier_level)
		assert.is_true(status.update_available)
		for _ = 1, 5 do
			p.tick()
		end
		assert.same(
			{ "crier-obs: crier 1.0.0 at /fake/crier is older than 1.1.1; click Update crier" },
			lines(obs.LOG_WARNING, "older than")
		)
		state.install.state, state.install.message = "idle", ""
		assert.equal("crier 1.0.0 at /fake/crier (older than 1.1.1)", p.status().crier)
		assert.equal("warning", p.status().crier_level)
		state.resolver.state, state.resolver.version, state.resolver.message =
			"ready", "1.1.1", "crier 1.1.1 at /fake/crier"
		p.tick()
		assert.same({ "crier-obs: crier 1.1.1 at /fake/crier" }, lines(obs.LOG_INFO, "crier 1.1.1 at"))
		finish(p, data)
	end)
	it("names inherited CRIER_* variables once Debug logging is on and warns about sandbox limits once", function()
		local p, data = fixture({
			inherited = { "CRIER_CONFIG", "CRIER_PUBLISH_TELEGRAM_TOKEN" },
			sandbox = { kind = "flatpak", ok = false, message = "Flatpak host access is unavailable" },
		})
		assert.same({}, lines(nil, "inherited CRIER_* variables"))
		assert.same({ "crier-obs: Flatpak host access is unavailable" }, lines(obs.LOG_WARNING, "Flatpak"))
		obs.obs_data_set_bool(data, "cobs.debug", true)
		p.update(data)
		local named = lines(obs.LOG_INFO, "[debug] inherited CRIER_* variables")
		assert.equal(1, #named)
		assert.matches("CRIER_CONFIG, CRIER_PUBLISH_TELEGRAM_TOKEN", named[1], 1, true)
		finish(p, data)
	end)
	it("refreshes live credentials only on heartbeat and skips a quit without ready credentials", function()
		local p, data, state = fixture({ resolve_fail = true })
		obs.obs_data_set_bool(data, "cobs.trigger.quit.enabled", true)
		p.update(data)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		p.tick()
		p.tick()
		obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		assert.equal(0, #state.spawned)
		assert.same(
			{ "crier-obs: quit post skipped: credentials are not ready" },
			lines(obs.LOG_WARNING, "quit post skipped")
		)
		finish(p, data)
		local resolved = 0
		p, data = fixture({ pending_secret = "new" })
		local resolve = p.secrets.resolve
		-- Counts the live-session resolutions (the ones that keep values); posts resolve on their own.
		p.secrets.resolve = function(set, keys, cb, options)
			if options and options.remember then
				resolved = resolved + 1
			end
			return resolve(set, keys, cb, options)
		end
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		p.tick()
		assert.is_true(p.scheduler.stream.cache_ready)
		obs.obs_data_set_bool(data, "publish.discord.enabled", true)
		p.update(data)
		assert.is_false(p.scheduler.stream.cache_ready)
		p.tick()
		p.tick()
		assert.is_true(p.scheduler.stream.cache_ready)
		assert.equal(2, resolved)
		p.callbacks.save_secret("publish.telegram.token")
		assert.is_false(p.scheduler.stream.cache_ready)
		p.tick()
		p.tick()
		assert.is_true(p.scheduler.stream.cache_ready)
		assert.equal(3, resolved)
		p.callbacks.forget_secret("publish.telegram.token")
		p.tick()
		p.tick()
		assert.equal(4, resolved)
		p.callbacks.forget_all()
		p.tick()
		p.tick()
		assert.equal(5, resolved)
		finish(p, data)
	end)
	it("skips an absent replay clip and never reports a failed quit spawn as posted", function()
		local p, data, state = fixture()
		p.enqueue("replay")
		assert.equal(0, #state.spawned)
		finish(p, data)
		p, data = fixture({ spawn_fail = true })
		obs.obs_data_set_bool(data, "cobs.trigger.quit.enabled", true)
		p.update(data)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		p.tick()
		p.tick()
		obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		for _, line in ipairs(obs.logs) do
			assert.is_nil(line.text:find("quit post spawned", 1, true))
		end
		finish(p, data)
	end)
	it("reads no frontend getter on update, while events and buttons keep the post snapshot fresh", function()
		local p, data, state = fixture()
		local calls, originals = {}, {}
		for _, name in ipairs({
			"obs_frontend_get_current_scene",
			"obs_frontend_get_current_profile",
			"obs_frontend_get_current_scene_collection",
			"obs_frontend_get_last_recording",
			"obs_frontend_get_last_replay",
			"obs_frontend_get_streaming_service",
		}) do
			originals[name] = obs[name]
			obs[name] = function(...)
				calls[#calls + 1] = name
				return originals[name](...)
			end
		end
		finally(function()
			for name, fn in pairs(originals) do
				obs[name] = fn
			end
			obs.scene_name, obs.profile_name = "Scene", "Profile"
		end)
		local function doc(event)
			for path, text in pairs(state.files) do
				local decoded = path:match("/data%.json$") and json.decode(text)
				if type(decoded) == "table" and decoded.event == event then
					return decoded
				end
			end
		end
		-- OBS calls script_update on every keystroke, and each getter returns a string OBS allocates.
		for _, title in ipairs({ "L", "Li", "Live" }) do
			obs.obs_data_set_string(data, "cobs.title", title)
			p.update(data)
		end
		assert.same({}, calls)
		obs.profile_name = "Evening"
		p.callbacks.post()
		assert.is_true(#calls > 0)
		assert.equal("Evening", doc("manual").profile)
		assert.equal("Live", doc("manual").title)
		-- The interval post runs on the graphics thread from the copy the last frontend event took.
		obs.obs_data_set_bool(data, "cobs.trigger.interval.enabled", true)
		obs.obs_data_set_int(data, "cobs.interval_minutes", 1)
		p.update(data)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		obs.scene_name = "Gameplay"
		obs.emit(obs.OBS_FRONTEND_EVENT_SCENE_CHANGED)
		local before = #calls
		obs.obs_data_set_string(data, "cobs.title", "Live again")
		p.update(data)
		obs.advance(61)
		assert.equal(before, #calls)
		assert.equal("Gameplay", doc("interval").scene)
		assert.equal("Evening", doc("interval").profile)
		finish(p, data)
	end)
end)
