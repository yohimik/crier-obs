-- Every text an info or status row shows must come from the i18n table: a string from it, or one of
-- its templates whose holes hold dynamic values (paths, versions, numbers, and what crier, the
-- installer or the system reported). OBS runs in a pseudo-locale that wraps every en-US string in
-- «…», so English that bypasses the table shows up unwrapped even where it repeats an en-US string.
-- The plugin runs with its real resolver, installer, Check setup and credential service; only
-- processes, files and the credential backend are fakes.
local obs = require("obslua")
local i18n = require("crier_obs.i18n")
local plugin = require("crier_obs.plugin")
local service = require("crier_obs.secrets.service")
local env_module = require("crier_obs.ports.env")
local log_module = require("crier_obs.log")

local PSEUDO = "x-pseudo"
local pseudo = {}
for key, text in pairs(i18n.strings["en-US"]) do
	pseudo[key] = "«" .. text .. "»"
end
i18n.strings[PSEUDO] = pseudo
local say = i18n.new(PSEUDO)

local templates = {}
for key, text in pairs(pseudo) do
	local holes = 0
	local pattern = text:gsub("%%[sd]", "\1"):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("\1", function()
		holes = holes + 1
		return "(.-)"
	end)
	templates[#templates + 1] = { key = key, text = text, pattern = "^" .. pattern .. "$", holes = holes }
end

-- True when text is an i18n string, a dynamic value, or an i18n template filled with explained parts.
local function explained(text, dynamic)
	if dynamic[text] or text:match("^%-?%d+$") then
		return true
	end
	for _, template in ipairs(templates) do
		if template.holes == 0 then
			if text == template.text then
				return true
			end
		else
			local parts = { text:match(template.pattern) }
			local ok = #parts == template.holes
			for _, part in ipairs(parts) do
				ok = ok and part ~= text and explained(part, dynamic)
			end
			if ok then
				return true
			end
		end
	end
	return false
end

-- Walks every info row of a fresh dialog. Result rows join their parts with two spaces.
-- verdicts remembers each text's answer, since most rows repeat from one walk to the next.
local function walk(p, data, dynamic, seen, verdicts)
	local unexplained = {}
	local function visit(ps)
		for _, property in ipairs(ps.ordered) do
			if property.kind == "text" and property.args[1] == obs.OBS_TEXT_INFO then
				local left, right = obs.render_info(property, data)
				for _, text in ipairs({ left or "", right or "" }) do
					seen[text] = true
					for part in (text .. "  "):gmatch("(.-)  ") do
						if verdicts[part] == nil then
							verdicts[part] = part == "" or explained(part, dynamic)
						end
						if not verdicts[part] then
							unexplained[#unexplained + 1] = property.name .. ": " .. part
						end
					end
				end
			end
			if property.content then
				visit(property.content)
			end
		end
	end
	visit(p.properties())
	return unexplained
end

local function credential_backend(options)
	local values = {}
	local backend = { name = options.name or "macos", values = values }
	function backend.store(account, value, callback)
		values[account] = options.store_as or value
		callback(true)
	end
	function backend.lookup(account, callback)
		if values[account] then
			callback(values[account])
		else
			callback(nil, { kind = "missing", message = "not found" })
		end
	end
	function backend.exists(account, callback)
		if values[account] then
			callback(true)
		else
			callback(nil, { kind = "missing", message = "not found" })
		end
	end
	function backend.forget(account, callback)
		values[account] = nil
		callback(true)
	end
	function backend.tick() end
	function backend.close() end
	return backend
end

-- options.script[kind] lists what each spawn of that kind does: { result = r, wait = n } finishes
-- after n empty polls, { fail = message } cannot start, { poll_error = message } fails while running.
local function fixture(options)
	options = options or {}
	obs.reset()
	local files, binaries = {}, options.binaries or {}
	local fs = {}
	function fs.exists(path)
		return files[path] ~= nil or binaries[path] == true
	end
	function fs.read(path)
		return files[path]
	end
	function fs.write(path, value)
		files[path] = value
		return true
	end
	fs.write_private = fs.write
	function fs.mkdir_private()
		return true
	end
	function fs.remove(path)
		files[path] = nil
		return true
	end
	fs.remove_private = fs.remove
	function fs.glob()
		return {}
	end
	function fs.random_bytes(n)
		return string.rep("r", n)
	end
	function fs.create_private(path, value)
		if files[path] then
			return nil, { kind = "exists", message = "exists" }
		end
		files[path] = value
		return true
	end
	local script = options.script or {}
	local spawner, spawned = {}, {}
	function spawner.spawn(plan)
		spawned[#spawned + 1] = plan
		local outcome = table.remove(script[plan.kind] or {}, 1) or { result = { code = 0, stdout = "", stderr = "" } }
		if outcome.fail then
			return nil, { kind = "process", message = outcome.fail }
		end
		local waits = outcome.wait or 0
		return {
			pid = 100,
			poll = function()
				if waits > 0 then
					waits = waits - 1
					return nil
				end
				if outcome.poll_error then
					return nil, { kind = "process", message = outcome.poll_error }
				end
				return outcome.result
			end,
			cancel = function()
				return true
			end,
			detach = function()
				return { pid = 100 }
			end,
		}
	end
	function spawner.reap()
		return {}
	end
	function spawner.current_pid()
		return 4242
	end
	function spawner.alive()
		return false
	end
	function spawner.adopt()
		return {
			poll = function()
				return { code = 3 }
			end,
			cancel = function()
				return true
			end,
		}
	end
	local count = 0
	local runs = {
		init = function()
			if options.init_fail then
				return false, { kind = "filesystem", message = "read-only file system" }
			end
			return true
		end,
		sweep = function() end,
		create = function(event)
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
		finish = function()
			return true
		end,
		journal = function()
			return true
		end,
		adopt = function()
			return options.adopt or {}
		end,
	}
	local sandbox = options.sandbox_env
	local env = {
		os = options.os or "OSX",
		getenv = function()
			return nil
		end,
		augmented_path = function()
			return "/usr/local/bin"
		end,
		crier_names = function()
			return {}
		end,
		sandbox_status = function(f)
			return sandbox and sandbox.sandbox_status(f) or { kind = "native", ok = true }
		end,
		boot_id = function()
			return "boot"
		end,
	}
	local backend = credential_backend(options.backend or {})
	local store = require("crier_obs.settings.store").new({ obs = obs })
	local secrets = service.new({
		fs = fs,
		log = log_module.new({}),
		state_dir = "/state",
		platform = options.platform or "OSX",
		backend = not options.no_backend and backend or nil,
		backends = options.backends,
		store = store,
		lock = function(callback)
			return callback()
		end,
	})
	local p = plugin.new({
		obs = obs,
		fs = fs,
		env = env,
		paths = { root = "/state", runs = "/state/runs", template = "/state/template.html" },
		spawner = spawner,
		runs = runs,
		-- options.own_secrets lets the plugin build its credential service from its own ports.
		secrets = not options.own_secrets and secrets or nil,
		store = store,
	})
	local data = obs.obs_data_create()
	p.defaults(data)
	obs.obs_data_set_bool(data, "publish.telegram.enabled", true)
	for key, value in pairs(options.strings or {}) do
		obs.obs_data_set_string(data, key, value)
	end
	for key, value in pairs(options.bools or {}) do
		obs.obs_data_set_bool(data, key, value)
	end
	p.load(data)
	p.update(data)
	local dynamic = { ["/state/runs"] = true, ["/state/bin/crier"] = true, ["1.1.1"] = true }
	for _, value in ipairs(options.dynamic or {}) do
		dynamic[value] = true
	end
	local seen, verdicts = {}, {}
	local self = {
		p = p,
		data = data,
		script = script,
		binaries = binaries,
		secrets = p.secrets,
		seen = seen,
		spawned = spawned,
	}
	function self.tick(times)
		for _ = 1, times or 1 do
			p.tick()
		end
	end
	function self.check()
		local unexplained = walk(p, data, dynamic, seen, verdicts)
		assert.same({}, unexplained)
	end
	function self.crier_path(path, outcome)
		binaries[path] = true
		script.probe = { outcome }
		obs.obs_data_set_string(data, "cobs.crier_path", path)
		p.update(data)
		self.tick()
	end
	function self.close()
		p.unload()
		obs.obs_data_release(data)
		obs.assert_no_leaks()
	end
	return self
end

local function assert_seen(f, texts)
	for _, text in ipairs(texts) do
		assert.is_true(f.seen[text] == true, "never shown: " .. text)
	end
end
-- A Check setup result row: its mark, then its parts.
local function result(mark, ...)
	return table.concat({ say(mark), ... }, "  ")
end

describe("dialog row text", function()
	before_each(function()
		obs.locale = PSEUDO
	end)
	after_each(function()
		obs.locale = "en-US"
	end)

	it("rejects English that is not in the i18n table", function()
		local values = { ["1.1.1"] = true, ["/bin/crier"] = true }
		assert.is_true(explained(say("crier_ready", "1.1.1", "/bin/crier"), values))
		assert.is_true(explained(say("not_stored_reason", say("credential_missing")), {}))
		assert.is_false(explained("crier 1.1.1 at /bin/crier", values))
		assert.is_false(explained(say("not_stored_reason", "Stored credential is missing; re-enter it"), {}))
		assert.is_false(explained("«crier 1.1.1 lives at /bin/crier»", values))
		assert.is_false(explained("Version check is already running", {}))
	end)

	it("words every crier row state of install and version checks through i18n", function()
		local f = fixture({
			dynamic = {
				"curl: (22) 404",
				"cannot spawn /bin/sh",
				"unknown flag: --json",
				"exec format error",
				"pipe closed",
				"/opt/old/crier",
				"/opt/bad/crier",
				"/opt/ok/crier",
				"1.0.0",
			},
		})
		f.check()
		f.script.installer = {
			{ result = { code = 1, stdout = "", stderr = "curl: (22) 404" } },
			{ result = { code = 1, stdout = "", stderr = "", timed_out = true } },
			{ result = { code = 1, stdout = "", stderr = "" } },
			{ fail = "cannot spawn /bin/sh" },
		}
		for _ = 1, 4 do
			f.p.callbacks.install()
			f.check()
			f.tick()
			f.check()
		end
		f.binaries["/state/bin/crier"] = true
		f.script.installer = { { result = { code = 0, stdout = "", stderr = "" } }, { result = { code = 1 } } }
		f.script.probe = { { result = { code = 0, stdout = '{"version":"1.1.1"}' }, wait = 1 } }
		f.p.callbacks.install()
		f.tick(2)
		f.check()
		f.tick(2)
		f.check()
		for _, case in ipairs({
			{ "/opt/old/crier", { result = { code = 0, stdout = '{"version":"1.0.0"}' } } },
			{ "/opt/bad/crier", { result = { code = 0, stdout = "no version here" } } },
			{ "/opt/bad/crier2", { result = { code = 0, stdout = '{"version":"01.1.1"}' } } },
			{ "/opt/bad/crier3", { result = { code = 2, stdout = "", stderr = "unknown flag: --json\n" } } },
			{ "/opt/bad/crier4", { result = { code = 2, stdout = "", stderr = "" } } },
			{ "/opt/bad/crier5", { result = { code = 1, stdout = "", timed_out = true } } },
			{ "/opt/bad/crier6", { fail = "exec format error" } },
			{ "/opt/bad/crier7", { poll_error = "pipe closed" } },
			{ "/opt/ok/crier", { result = { code = 0, stdout = '{"version":"1.1.1"}' } } },
		}) do
			f.crier_path(case[1], case[2])
			f.check()
			f.tick()
			f.check()
		end
		obs.obs_data_set_string(f.data, "cobs.crier_path", "/missing/crier")
		f.p.update(f.data)
		f.tick()
		f.check()
		assert_seen(f, {
			say("crier_missing"),
			say("install_running", "1.1.1"),
			say("install_failed", "curl: (22) 404"),
			say("install_failed", say("install_timed_out")),
			say("install_failed", say("install_exit_failed")),
			say("install_failed", "cannot spawn /bin/sh"),
			say("install_checking"),
			say("crier_ready", "1.1.1", "/state/bin/crier"),
			say("crier_outdated", "1.0.0", "/opt/old/crier", "1.1.1"),
			say("crier_version_unreadable"),
			say("crier_version_invalid"),
			say("crier_check_failed_reason", "unknown flag: --json"),
			say("crier_check_failed"),
			say("crier_check_timed_out"),
			say("crier_check_failed_reason", "exec format error"),
			say("crier_check_failed_reason", "pipe closed"),
			say("crier_checking"),
			say("crier_ready", "1.1.1", "/opt/ok/crier"),
			say("crier_path_missing"),
		})
		-- The log keeps English whatever the dialog's locale.
		local english = 0
		for _, line in ipairs(obs.logs) do
			assert.is_nil(line.text:find("«", 1, true), line.text)
			english = english + (line.text:find("Install failed: curl: (22) 404", 1, true) and 1 or 0)
		end
		assert.equal(1, english)
		f.close()
	end)

	it("words Check setup rows, last run results and credential states through i18n", function()
		local f = fixture({
			binaries = { ["/state/bin/crier"] = true, ["/usr/local/bin/zrok"] = true },
			bools = { ["render.video.enabled"] = true },
			strings = { ["stage.server.tunnel.mode"] = "zrok" },
			script = {
				probe = { { result = { code = 0, stdout = '{"version":"1.1.1"}' } } },
				platforms = {
					{
						result = {
							code = 0,
							stdout = '[{"name":"telegram","enabled":true,"problem":"chat id is missing"}]',
						},
					},
					{ fail = "spawn denied" },
				},
				ping = {
					{
						result = {
							code = 0,
							stdout = '{"results":[{"target":"telegram","ok":true,"account":"@crier_bot",'
								.. '"note":"token valid","ms":42}]}',
						},
					},
					{ result = { code = 3, stdout = '{"results":[]}', stderr = "config: invalid" } },
				},
				publish = {
					{
						result = {
							code = 4,
							stdout = '{"results":[{"platform":"telegram","ok":false,"error":"429"}]}',
							stderr = "",
						},
					},
					{ result = { code = 0, stdout = '{"results":[]}', stderr = "" } },
					{ result = { code = 137, signal = 9, stdout = "", stderr = "" } },
					{ result = { code = 1, timed_out = true, stdout = "", stderr = "" } },
					{ result = { code = 42, stdout = "", stderr = "" } },
					{ fail = "spawn denied" },
				},
			},
			adopt = { { pid = 7, event = "start", created_at = os.time() } },
			dynamic = {
				"/usr/local/bin/zrok",
				"zrok",
				"ffmpeg",
				"telegram",
				"chat id is missing",
				"@crier_bot",
				"token valid",
				"config: invalid",
				"spawn denied",
			},
		})
		f.tick(2)
		f.check()
		f.p.callbacks.check()
		f.check()
		f.tick(3)
		f.check()
		obs.obs_data_set_string(f.data, "stage.mode", "server")
		f.p.update(f.data)
		f.p.callbacks.check()
		f.tick(3)
		f.check()
		for _ = 1, 6 do
			f.p.callbacks.post()
			f.tick(4)
			f.check()
		end
		local key = "publish.telegram.token"
		f.secrets.commit("default", key, "s3cret")
		f.check()
		f.tick(2)
		f.check()
		f.secrets.forget("default", key)
		f.check()
		f.tick(2)
		f.check()
		assert_seen(f, {
			say("last_run_code", 3),
			say("target_crier"),
			say("target_setup"),
			result("result_ok", "/state/bin/crier"),
			result("result_warning", say("checking")),
			result("result_ok", say("check_staging_disabled")),
			result("result_failed", say("check_not_found", "ffmpeg")),
			result("result_ok", "/usr/local/bin/zrok"),
			result("result_warning", say("check_tunnel_needs_server", "zrok")),
			result("result_ok", say("keyring_macos")),
			result("result_warning", "chat id is missing"),
			result("result_ok", "@crier_bot", "token valid", say("result_ms", "42")),
			result("result_failed", "spawn denied"),
			result("result_failed", say("check_failed_code", "3"), "config: invalid"),
			result("result_ok", say("check_stage_no_credentials")),
			say("run_failed_platforms", say("exit_4"), "telegram"),
			say("exit_0"),
			say("exit_signal", "9"),
			say("exit_timeout"),
			say("exit_other", "42"),
			say("post_failed", "spawn denied"),
			say("saving"),
			say("stored"),
			say("forgetting"),
			say("not_stored"),
		})
		f.close()
	end)

	it("words credential failures and every credential store row through i18n", function()
		local f = fixture({ backend = { store_as = "something else" } })
		f.tick(2)
		f.secrets.commit("default", "publish.telegram.token", "s3cret")
		f.tick(2)
		f.check()
		assert_seen(f, { say("not_stored_reason", say("credential_unverified")), say("keyring_macos") })
		f.close()

		f = fixture({ platform = "Linux", no_backend = true, backends = { linux = credential_backend({}) } })
		f.check()
		assert_seen(f, { say("keyring_state", say("keyring_linux"), say("checking")) })
		f.close()

		f = fixture({ platform = "Linux", backend = { name = "file" } })
		f.check()
		assert_seen(f, { say("keyring_file_fallback", say("keyring_file")) })
		f.close()

		local windows = require("crier_obs.secrets.keyring.windows")
		local original = windows.new
		windows.new = function()
			_G.error("crypt32.dll not found", 0)
		end
		local ok, err = pcall(function()
			f = fixture({ platform = "Windows", no_backend = true, dynamic = { "crypt32.dll not found" } })
		end)
		windows.new = original
		assert(ok, err)
		-- Showing the dialog asks for every credential's status; the service answers two per heartbeat.
		f.check()
		f.tick(60)
		f.check()
		local unusable = say("keyring_unusable", say("keyring_windows"), "crypt32.dll not found")
		assert_seen(f, { unusable, say("not_stored_reason", unusable) })
		f.close()

		f = fixture({ init_fail = true, dynamic = { "read-only file system" } })
		f.check()
		assert_seen(f, { say("state_unavailable", "read-only file system") })
		f.close()
	end)

	it("runs the secret-tool the augmented PATH holds, and names a missing one in the store row", function()
		-- The plugin's own credential service on Linux; the fixture's augmented PATH is /usr/local/bin.
		local canary = string.rep("72", 12)
		local f = fixture({
			os = "Linux",
			own_secrets = true,
			binaries = { ["/usr/local/bin/secret-tool"] = true },
			script = {
				keyring = {
					{ result = { code = 0, stdout = "", stderr = "" } },
					{ result = { code = 0, stdout = canary .. "\n", stderr = "" } },
				},
			},
		})
		f.tick(3)
		f.check()
		assert_seen(f, { say("keyring_linux") })
		local keyring = 0
		for _, plan in ipairs(f.spawned) do
			if plan.kind == "keyring" then
				keyring = keyring + 1
				assert.equal("/usr/local/bin/secret-tool", plan.executable)
			end
		end
		assert.is_true(keyring >= 3)
		f.close()

		f = fixture({ os = "Linux", own_secrets = true })
		f.tick(3)
		f.check()
		assert_seen(f, { say("keyring_file_no_secret_tool", say("keyring_file")) })
		for _, plan in ipairs(f.spawned) do
			assert.is_not.equal("keyring", plan.kind)
		end
		f.close()
	end)

	it("words the sandbox rows of Check setup through i18n", function()
		for _, case in ipairs({
			{ { SNAP = "/snap/obs-studio/1" }, {}, result("result_failed", say("sandbox_snap")) },
			{
				{ FLATPAK_ID = "com.obsproject.Studio", PATH = "/app/bin" },
				{},
				result("result_failed", say("sandbox_flatpak_missing")),
			},
			{
				{ FLATPAK_ID = "com.obsproject.Studio", PATH = "/app/bin" },
				{ ["/app/bin/flatpak-spawn"] = true },
				result("result_pending", say("sandbox_flatpak_bridge")),
			},
		}) do
			local vars = case[1]
			-- A Linux environment on any host: no /.flatpak-info probe through the host's C library.
			local sandbox_env = env_module.new({
				platform = "Linux",
				getenv = function(name)
					return vars[name]
				end,
				fs = {
					exists = function()
						return false
					end,
				},
			})
			local binaries = case[2]
			binaries["/state/bin/crier"] = true
			local f = fixture({
				sandbox_env = sandbox_env,
				binaries = binaries,
				script = { probe = { { result = { code = 0, stdout = '{"version":"1.1.1"}' } } } },
			})
			f.tick()
			f.p.callbacks.check()
			f.tick(3)
			f.check()
			assert_seen(f, { case[3] })
			f.close()
		end
	end)
end)
