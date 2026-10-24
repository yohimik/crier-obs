local obs = require("obslua")
local json = require("crier_obs.json")
local plugin_module = require("crier_obs.plugin")
local service_module = require("crier_obs.secrets.service")
local fs_module = require("crier_obs.ports.fs")
local log_module = require("crier_obs.log")
local store_module = require("crier_obs.settings.store")
local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end
local function setup(bound_missing, options)
	options = options or {}
	obs.reset()
	local path = os.tmpname()
	os.remove(path)
	local fs = fs_module.new({ obs = obs })
	assert(fs.mkdir_private(path))
	assert(fs.mkdir_private(path .. "/secrets"))
	if bound_missing then
		assert(
			fs.write_private(
				path .. "/secrets/index.json",
				json.encode({ ["default/publish.telegram.token"] = "missing-keyring" })
			)
		)
	end
	local log = log_module.new({ obs = obs, debug = true })
	local store = store_module.new({ obs = obs })
	local backend = { name = "test", values = {}, stores = 0, closed = false }
	function backend.store(account, value, cb)
		backend.stores = backend.stores + 1
		backend.values[account] = value
		cb(true)
	end
	function backend.lookup(account, cb)
		local value = backend.values[account]
		cb(value, not value and { kind = "missing" } or nil)
	end
	function backend.forget(account, cb)
		backend.values[account] = nil
		cb(true)
	end
	function backend.exists(account, cb)
		backend.exists_calls = (backend.exists_calls or 0) + 1
		cb(backend.values[account] and true or nil, not backend.values[account] and { kind = "missing" } or nil)
	end
	function backend.tick() end
	function backend.close()
		backend.closed = true
	end
	local secrets = service_module.new({ fs = fs, state_dir = path, store = store, log = log, backend = backend })
	local plans, processes = {}, {}
	local spawner = {}
	function spawner.spawn(plan)
		plans[#plans + 1] = { args = copy(plan.args), env = copy(plan.env), kind = plan.kind, run = plan.run }
		local output, code, stderr = { results = { { platform = "telegram", ok = true } } }, 0, ""
		if plan.kind == "probe" and plan.args[1] == "config" then
			output = { values = {} }
		elseif options.publish_ok and plan.kind == "publish" then
			output = { results = { { platform = "telegram", ok = true } } }
		elseif plan.kind == "publish" then
			local secret = plan.env and plan.env.CRIER_PUBLISH_TELEGRAM_TOKEN or ""
			output = { results = { { platform = "telegram", ok = false, error = "rejected " .. secret } } }
			stderr, code = "transport failed " .. secret, 5
		elseif plan.kind == "ping" then
			local secret = plan.env and plan.env.CRIER_PUBLISH_TELEGRAM_TOKEN or ""
			output = { results = { { target = "telegram", ok = false, error = "rejected " .. secret } } }
			code = 5
		elseif plan.kind == "platforms" then
			output = { { name = "telegram", enabled = true, ready = true } }
		end
		local p = { pid = 400 + #plans, child_pid = 400 + #plans }
		function p.poll()
			return { code = code, stdout = json.encode(output), stderr = stderr }
		end
		function p.detach()
			return { pid = p.pid, child_pid = p.pid }
		end
		function p.cancel()
			return true
		end
		processes[#processes + 1] = p
		return p
	end
	function spawner.adopt()
		return nil, { message = "No process to adopt" }
	end
	function spawner.reap()
		return {}
	end
	function spawner.current_pid()
		return options.pid or 9000
	end
	function spawner.alive()
		return false
	end
	local resolver = {
		find = function()
			return "/fake/crier"
		end,
		probe = function()
			return true
		end,
		status = function()
			return { state = "ready", message = "crier installed" }
		end,
		tick = function()
			return { state = "ready", message = "crier installed" }
		end,
		detach = function() end,
		find_binary = function() end,
	}
	local p = plugin_module.new({
		obs = obs,
		fs = fs,
		state_dir = path,
		log = log,
		store = store,
		secrets = secrets,
		spawner = spawner,
		resolver = resolver,
	})
	local settings = obs.obs_data_create()
	p.defaults(settings)
	obs.obs_data_set_bool(settings, "publish.telegram.enabled", true)
	obs.obs_data_set_string(settings, "cobs.crier_path", "/fake/crier")
	p.load(settings)
	p.update(settings)
	return p, settings, backend, plans, path, fs
end
local function pump(p, n)
	for _ = 1, n or 20 do
		p.tick()
	end
end
local function cleanup(p, settings)
	p.unload()
	obs.obs_data_release(settings)
	obs.assert_no_leaks()
	assert.equal(0, obs.timer_count())
end
describe("credential UI and publishing security", function()
	it("only saves on the Save button and scrubs reports/logs before persistence", function()
		local p, settings, backend, plans, path, fs = setup()
		local secret = "GUI_SECRET_😀_VALUE"
		obs.obs_data_set_string(settings, "publish.telegram.token", secret)
		p.update(settings)
		pump(p)
		assert.equal(0, backend.stores)
		p.save(settings)
		assert.is_nil(obs.obs_data_get_json(settings):find(secret, 1, true))
		assert.is_false(obs.obs_data_has_user_value(settings, "publish.telegram.token"))
		assert.equal(0, backend.stores)
		local properties = p.properties()
		assert.is_table(properties.by_name["publish.telegram.token"])
		p.callbacks.save_secret("publish.telegram.token")
		pump(p)
		assert.equal(1, backend.stores)
		assert.equal("stored", p.secrets.status("default", "publish.telegram.token").state)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		pump(p)
		assert.is_truthy(p.scheduler.stream.cache["publish.telegram.token"])
		p.callbacks.check()
		pump(p)
		local publishes, pings, probes = 0, 0, 0
		for _, plan in ipairs(plans) do
			assert.is_nil(table.concat(plan.args, " "):find(secret, 1, true))
			if plan.kind == "publish" then
				publishes = publishes + 1
				assert.equal(secret, plan.env.CRIER_PUBLISH_TELEGRAM_TOKEN)
			elseif plan.kind == "ping" then
				pings = pings + 1
				assert.equal(secret, plan.env.CRIER_PUBLISH_TELEGRAM_TOKEN)
			else
				probes = probes + 1
				assert.is_nil(plan.env.CRIER_PUBLISH_TELEGRAM_TOKEN)
			end
		end
		assert.equal(1, publishes)
		assert.equal(1, pings)
		assert.is_true(probes > 0)
		for _, dir in ipairs(fs.glob(path .. "/runs/*")) do
			for _, file in ipairs(fs.glob(dir .. "/*")) do
				local data = fs.read(file)
				if data then
					assert.is_nil(data:find(secret, 1, true), file)
				end
			end
		end
		for _, line in ipairs(obs.logs) do
			assert.is_nil(line.text:find(secret, 1, true))
		end
		for _, row in ipairs(p.status().results) do
			assert.is_nil((row.error or ""):find(secret, 1, true))
		end
		obs.obs_data_set_string(settings, "publish.telegram.token", "REPLACED_SECRET")
		p.update(settings)
		p.callbacks.save_secret("publish.telegram.token")
		pump(p)
		assert.equal("REPLACED_SECRET", p.scheduler.stream.cache["publish.telegram.token"])
		p.callbacks.forget_secret("publish.telegram.token")
		pump(p)
		assert.is_nil(p.scheduler.stream.cache["publish.telegram.token"])
		assert.equal("not stored", p.secrets.status("default", "publish.telegram.token").state)
		cleanup(p, settings)
	end)
	it("refuses to spawn a post or ping with an unavailable indexed credential", function()
		local p, settings, _, plans = setup(true)
		obs.obs_data_set_bool(settings, "cobs.trigger.quit.enabled", true)
		p.update(settings)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		p.callbacks.check()
		pump(p)
		obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		for _, plan in ipairs(plans) do
			assert.is_not.equal("publish", plan.kind)
			assert.is_not.equal("ping", plan.kind)
		end
		assert.equal("unavailable", p.secrets.status("default", "publish.telegram.token").state)
		cleanup(p, settings)
	end)
	it("shows a credential kept in an unavailable store as stored, and an unindexed one as not stored", function()
		local p, settings, backend = setup(true)
		obs.obs_data_set_bool(settings, "publish.discord.enabled", true)
		p.update(settings)
		local exists = backend.exists
		function backend.exists(account, cb)
			if account == "default/publish.discord.webhook-url" then
				return cb(
					nil,
					{ kind = "unavailable", message = "Credential store is locked; unlock it and try again" }
				)
			end
			return exists(account, cb)
		end
		p.properties()
		pump(p)
		local props = p.properties()
		local function row(key)
			return select(2, obs.render_info(props.by_name[key .. ".status"], settings))
		end
		assert.equal("stored in keyring (keyring unavailable: missing-keyring)", row("publish.telegram.token"))
		assert.equal(
			"not stored: Credential store is locked; unlock it and try again",
			row("publish.discord.webhook-url")
		)
		cleanup(p, settings)
	end)
	it("drops the credentials of platforms unticked mid-stream from the service cache", function()
		local p, settings, backend = setup()
		backend.values["default/publish.telegram.token"] = "TELEGRAM_SECRET"
		backend.values["default/publish.discord.webhook-url"] = "DISCORD_SECRET"
		obs.obs_data_set_bool(settings, "publish.discord.enabled", true)
		p.update(settings)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		pump(p)
		assert.equal("TELEGRAM_SECRET", p.secrets.cache["default/publish.telegram.token"])
		assert.equal("DISCORD_SECRET", p.secrets.cache["default/publish.discord.webhook-url"])
		obs.obs_data_set_bool(settings, "publish.discord.enabled", false)
		p.update(settings)
		assert.is_nil(p.secrets.cache["default/publish.discord.webhook-url"])
		assert.equal("TELEGRAM_SECRET", p.secrets.cache["default/publish.telegram.token"])
		pump(p)
		assert.is_nil(p.scheduler.stream.cache["publish.discord.webhook-url"])
		assert.equal("TELEGRAM_SECRET", p.scheduler.stream.cache["publish.telegram.token"])
		cleanup(p, settings)
	end)
	it("does not put an old credential-set resolution back into the current session cache", function()
		local p, settings, backend = setup()
		backend.values["default/publish.telegram.token"] = "OLD_SECRET"
		backend.values["other/publish.telegram.token"] = "NEW_SECRET"
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		obs.obs_data_set_string(settings, "cobs.credential_set", "other")
		p.update(settings)
		p.tick()
		assert.is_not.equal("OLD_SECRET", p.scheduler.stream.cache["publish.telegram.token"])
		pump(p)
		assert.equal("NEW_SECRET", p.scheduler.stream.cache["publish.telegram.token"])
		cleanup(p, settings)
	end)
	it("scrubs typed unsaved values during unload and cancels backend ownership", function()
		local p, settings, backend = setup()
		obs.obs_data_set_string(settings, "publish.telegram.token", "UNSAVED_SECRET")
		p.update(settings)
		p.unload()
		assert.is_true(backend.closed)
		assert.equal(0, backend.stores)
		assert.is_false(obs.obs_data_has_user_value(settings, "publish.telegram.token"))
		local found = false
		for _, line in ipairs(obs.logs) do
			assert.is_nil(line.text:find("UNSAVED_SECRET", 1, true))
			if line.text:lower():find("credentials typed but not saved", 1, true) then
				found = true
			end
		end
		assert.is_true(found)
		obs.obs_data_release(settings)
		obs.assert_no_leaks()
	end)
end)

local function count(plans, kind, event)
	local n = 0
	for _, plan in ipairs(plans) do
		if plan.kind == kind and (not event or (plan.run and plan.run.event == event)) then
			n = n + 1
		end
	end
	return n
end
local function logged(text)
	local found = {}
	for _, line in ipairs(obs.logs) do
		if line.text:find(text, 1, true) then
			found[#found + 1] = line.text
		end
	end
	return found
end
local function live(options)
	local p, settings, backend, plans, path, fs = setup(false, options)
	backend.values["default/publish.telegram.token"] = "LIVE_SECRET"
	obs.obs_data_set_bool(settings, "cobs.trigger.quit.enabled", true)
	p.update(settings)
	obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
	pump(p)
	assert.is_true(p.scheduler.stream.cache_ready)
	return p, settings, backend, plans, path, fs
end
local function release(settings)
	obs.obs_data_release(settings)
	obs.assert_no_leaks()
	assert.equal(0, obs.timer_count())
end
describe("quit post across every way OBS ends", function()
	it("posts once from SCRIPTING_SHUTDOWN, then neither the cleanup nor the unload posts again", function()
		local p, settings, _, plans = live()
		obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		obs.emit(obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP)
		p.unload()
		assert.equal(1, count(plans, "publish", "quit"))
		assert.equal("LIVE_SECRET", plans[#plans].env.CRIER_PUBLISH_TELEGRAM_TOKEN)
		assert.equal(1, #logged("quit post spawned"))
		assert.equal(0, #logged("quit post skipped"))
		release(settings)
	end)
	it("posts once from the unload when OBS ends without SCRIPTING_SHUTDOWN (macOS application quit)", function()
		local p, settings, _, plans = live()
		p.unload()
		assert.equal(1, count(plans, "publish", "quit"))
		assert.equal("LIVE_SECRET", plans[#plans].env.CRIER_PUBLISH_TELEGRAM_TOKEN)
		assert.equal(1, #logged("quit post spawned"))
		release(settings)
	end)
	it("does not treat a scene-collection switch as a quit", function()
		for _, event in ipairs({
			obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING,
			obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP,
		}) do
			local p, settings, _, plans = live()
			obs.emit(event)
			p.unload()
			assert.equal(0, count(plans, "publish", "quit"))
			assert.equal(0, #logged("quit post"))
			release(settings)
		end
	end)
	it("logs the skip once when OBS ends while offline or with the quit trigger off", function()
		local p, settings, _, plans = setup()
		p.unload()
		assert.equal(0, count(plans, "publish", "quit"))
		assert.equal(1, #logged("quit post skipped"))
		release(settings)
		p, settings, _, plans = live()
		obs.obs_data_set_bool(settings, "cobs.trigger.quit.enabled", false)
		p.update(settings)
		obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		p.unload()
		assert.equal(0, count(plans, "publish", "quit"))
		assert.equal(1, #logged("quit post skipped"))
		release(settings)
	end)
	it("keeps the quit post after Save with an empty field or a save that fails", function()
		for _, failing in ipairs({ false, true }) do
			local p, settings, backend, plans = live()
			if failing then
				obs.obs_data_set_string(settings, "publish.telegram.token", "WRONG_SECRET")
				p.update(settings)
				backend.lookup_original = backend.lookup
				local lookups = 0
				backend.lookup = function(account, cb)
					lookups = lookups + 1
					if lookups == 1 then
						cb("mismatch")
					else
						backend.lookup_original(account, cb)
					end
				end
			end
			p.callbacks.save_secret("publish.telegram.token")
			pump(p, 40)
			if not failing then
				assert.equal(1, #logged("Enter a credential before saving"))
			end
			assert.is_true(p.scheduler.stream.cache_ready)
			obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
			assert.equal(1, count(plans, "publish", "quit"))
			assert.equal("LIVE_SECRET", plans[#plans].env.CRIER_PUBLISH_TELEGRAM_TOKEN)
			assert.equal(0, #logged("credentials are not ready"))
			p.unload()
			release(settings)
		end
	end)
	it("posts the quit post in advanced mode even when no earlier post probed the base file", function()
		local p, settings, backend, plans, path, fs = setup(false, { publish_ok = true })
		backend.values["default/publish.telegram.token"] = "LIVE_SECRET"
		assert(fs.write(path .. "/base.json", "{}"))
		obs.obs_data_set_string(settings, "cobs.base_config", path .. "/base.json")
		obs.obs_data_set_bool(settings, "cobs.trigger.start.enabled", false)
		obs.obs_data_set_bool(settings, "cobs.trigger.quit.enabled", true)
		p.update(settings)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		pump(p)
		assert.is_true(p.scheduler.stream.base_config_ready)
		obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		assert.equal(1, count(plans, "publish", "quit"))
		assert.equal(0, #logged("base configuration is not ready"))
		p.unload()
		release(settings)
	end)
	it("never publishes posts still queued at quit when OBS starts again", function()
		local p, settings, backend, plans = setup()
		backend.values["default/publish.telegram.token"] = "LIVE_SECRET"
		local lookup = backend.lookup
		backend.lookup = function() end -- the start post waits on the keyring when OBS quits
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		pump(p, 3)
		assert.equal("resolving_secrets", p.queue.active().state)
		obs.emit(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		p.unload()
		assert.equal(1, #logged("Post skipped: OBS quit before it started"))
		obs.streaming = false
		backend.lookup = lookup
		p.load(settings)
		p.update(settings)
		pump(p, 20)
		assert.equal(0, count(plans, "publish"))
		p.unload()
		release(settings)
	end)
	it("drops the live credentials when the stream ends without an end post, and status rows keep none", function()
		local p, settings, backend = live()
		obs.obs_data_set_bool(settings, "cobs.trigger.end.enabled", false)
		p.update(settings)
		pump(p)
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
		pump(p)
		assert.is_nil(next(p.scheduler.stream.cache))
		assert.is_nil(next(p.secrets.cache))
		p.properties()
		pump(p, 40)
		assert.is_true((backend.exists_calls or 0) > 0)
		assert.is_nil(next(p.secrets.cache))
		assert.equal("stored", p.secrets.status("default", "publish.telegram.token").state)
		p.unload()
		release(settings)
	end)
	it("drops the live credentials once the end post has them", function()
		local p, settings, _, plans = live()
		obs.emit(obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
		pump(p)
		assert.equal(1, count(plans, "publish", "end"))
		assert.equal("LIVE_SECRET", plans[#plans].env.CRIER_PUBLISH_TELEGRAM_TOKEN)
		assert.is_nil(next(p.scheduler.stream.cache))
		assert.is_nil(next(p.secrets.cache))
		-- A later offline post carries no uptime from the stream that ended.
		p.callbacks.post()
		pump(p)
		assert.equal(0, p.scheduler.stream.snapshot().uptime)
		assert.is_nil(p.scheduler.stream.snapshot().started_at)
		p.unload()
		release(settings)
	end)
end)
