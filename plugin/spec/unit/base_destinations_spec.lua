local base = require("crier_obs.invoke.base")
local plans = require("crier_obs.invoke.plan")
local builder = require("crier_obs.invoke.builder")
local job_module = require("crier_obs.run.job")
local ping_module = require("crier_obs.run.ping")
local json = require("crier_obs.json")
local obs = require("obslua")
local log = require("crier_obs.log").new({})
local function model()
	local settings = obs.obs_data_create()
	local port = require("crier_obs.settings.model").new({ obs = obs })
	port.defaults(settings)
	local m = port.snapshot(settings)
	obs.obs_data_release(settings)
	m.mode = "advanced"
	m.base_config = "/base.yaml"
	m.custom_names = { "visible", "-not-ui" }
	m.platforms.visible = true
	return m
end
local run =
	{ dir = "/run", config = "/run/config.json", data = "/run/data.json", status = "/run/status", pid = "/run/pid" }
local data = json.encode({
	values = {
		["publish.custom.hidden.enabled"] = true,
		["publish.custom.visible.enabled"] = true,
		["publish.custom.removed.command"] = "publish",
		["publish.custom.-not-ui.enabled"] = true,
	},
})
local function fixture(options)
	options = options or {}
	local content = "original base"
	local probe_polls = 0
	local spawned, cancelled, callbacks, finished = {}, {}, {}, {}
	local plan = assert(builder.build({ model = model(), run = run, executable = "/crier" }))
	local fs = {
		read = function()
			if options.read_fail then
				return nil, { kind = "filesystem", message = "unreadable" }
			end
			return content
		end,
		write = function()
			return true
		end,
	}
	local spawner = {
		spawn = function(p)
			spawned[#spawned + 1] = p
			if options.spawn_fail then
				return nil, { kind = "spawn", message = "spawn refused" }
			end
			if p.args[1] == "config" then
				return {
					poll = function()
						probe_polls = probe_polls + 1
						if options.pending_probe and probe_polls == 1 then
							return nil
						end
						if options.poll_error then
							return nil, { kind = "poll", message = "poll failed" }
						end
						if options.changed_during_probe then
							content = "changed base"
						end
						return {
							code = options.code or 0,
							stdout = options.stdout or data,
							timed_out = options.timed_out,
						}
					end,
					cancel = function()
						cancelled[#cancelled + 1] = true
						return { pid = 9 }
					end,
				}
			end
			return {
				pid = 10,
				poll = function()
					return { code = 0, stdout = "{}", stderr = "" }
				end,
				detach = function()
					return { pid = 10 }
				end,
			}
		end,
	}
	local job = job_module.new({
		event = "start",
		plan = plan,
		run = run,
		fs = fs,
		spawner = spawner,
		log = log,
		runs = {
			journal = function()
				return true
			end,
			finish = function(_, r)
				finished[#finished + 1] = r
			end,
		},
		secrets = {
			resolve = function(_, _, cb)
				if options.delay_secret then
					callbacks[1] = cb
				else
					cb({})
				end
			end,
		},
		on_base_custom = function(names, fingerprint)
			callbacks.names = names
			callbacks.fingerprint = fingerprint
		end,
	})
	return job, plan, spawned, cancelled, callbacks, function(v)
		content = v
	end, fs, finished
end
describe("base configuration destination checks", function()
	it("matches SHA256 vectors and reports unreadable or oversized base files", function()
		assert.equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", base.sha256(""))
		assert.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", base.sha256("abc"))
		assert.equal(
			"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
			base.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
		)
		assert.is_nil(base.fingerprint({ read = function() end }, "/missing"))
		assert.is_nil(base.fingerprint({
			read = function()
				return string.rep("x", 8388609)
			end,
		}, "/large"))
	end)
	it("inspects redacted effective config with plain env then disables hidden and removed destinations", function()
		local job, plan, spawned, _, callbacks = fixture()
		job.start()
		assert.equal("inspecting_base", job.state)
		assert.equal("config", spawned[1].args[1])
		assert.is_nil(next(spawned[1].env))
		job.tick()
		assert.equal("running", job.state)
		assert.equal(2, #spawned)
		local args = table.concat(spawned[2].args, "|")
		assert.is_truthy(args:find("publish.custom.hidden.enabled=false", 1, true))
		assert.is_truthy(args:find("publish.custom.removed.enabled=false", 1, true))
		assert.is_truthy(args:find("publish.custom.-not-ui.enabled=false", 1, true))
		assert.is_truthy(args:find("publish.custom.visible.enabled=true", 1, true))
		assert.equal(base.sha256("original base"), callbacks.fingerprint)
		local length = #plan.args
		assert(plans.disable_base_custom(plan, data))
		assert.equal(length, #plan.args)
		job.tick()
		assert.equal("done", job.state)
	end)
	it("fails closed on unreadable, malformed, timed-out and failed config probes", function()
		for _, options in ipairs({
			{ read_fail = true },
			{ spawn_fail = true },
			{ code = 1 },
			{ timed_out = true },
			{ stdout = "{}" },
			{ stdout = "{broken" },
		}) do
			local job, _, spawned = fixture(options)
			job.start()
			job.tick()
			assert.equal("failed", job.state)
			assert.is_true(#spawned <= 1)
		end
		local job, _, _, cancelled = fixture({ poll_error = true })
		job.start()
		job.tick()
		assert.equal("failed", job.state)
		assert.equal(1, #cancelled)
	end)
	it("rejects invalid custom names and excessive injected argument lists", function()
		local plan = { args = {}, selected_custom_names = {} }
		assert.is_nil(
			plans.disable_base_custom(plan, json.encode({ values = { ["publish.custom.bad_name.enabled"] = true } }))
		)
		plan = { args = {}, selected_custom_names = {}, argv_limit = 3 }
		assert.is_nil(plans.disable_base_custom(plan, data))
	end)
	it("rejects base changes during inspection and while credentials are resolving", function()
		local job, _, spawned = fixture({ changed_during_probe = true })
		job.start()
		job.tick()
		assert.equal("failed", job.state)
		assert.equal(1, #spawned)
		local callbacks, change
		job, _, spawned, _, callbacks, change = fixture({ delay_secret = true })
		job.start()
		job.tick()
		assert.equal("resolving_secrets", job.state)
		change("different base")
		callbacks[1]({})
		assert.equal("failed", job.state)
		assert.equal(1, #spawned)
	end)
	it("uses verified names on quit but refuses a changed base without probing or publishing", function()
		local m = model()
		local plan = assert(builder.build({
			model = m,
			run = run,
			executable = "/crier",
			skip_base_probe = true,
			base_custom_names = { "hidden" },
			base_fingerprint = base.sha256("verified"),
		}))
		local spawns = 0
		local job = job_module.new({
			event = "quit",
			plan = plan,
			run = run,
			fs = {
				read = function()
					return "changed"
				end,
			},
			cached_secrets = {},
			log = log,
			runs = { finish = function() end },
			spawner = {
				spawn = function()
					spawns = spawns + 1
				end,
			},
		})
		job.start()
		assert.equal("failed", job.state)
		assert.equal(0, spawns)
	end)
	it("parks an unfinished config probe without posting or marking its queued snapshot failed", function()
		local job, _, spawned, cancelled = fixture()
		job.start()
		assert(job.park())
		assert.equal(1, #cancelled)
		assert.equal(1, #spawned)
		assert.equal("parked", job.state)
	end)
	it("applies the same destination checks to setup ping before credential resolution", function()
		local captured = {}
		local fs = {
			read = function()
				return "base"
			end,
			write = function()
				return true
			end,
		}
		local p = ping_module.new({
			fs = fs,
			env = {},
			log = log,
			secrets = {
				resolve = function(_, _, cb)
					cb({})
				end,
			},
			spawner = {
				spawn = function(plan)
					captured[#captured + 1] = plan
					return {
						poll = function()
							return { code = 0, stdout = plan.args[1] == "config" and data or "{}" }
						end,
					}
				end,
			},
		})
		local plan = assert(builder.build({ model = model(), run = run, executable = "/crier" }))
		assert(p.start(model(), "/crier", plan))
		p.tick()
		p.tick()
		assert.equal(3, #captured)
		assert.equal("ping", captured[3].args[1])
		assert.is_truthy(table.concat(captured[3].args, "|"):find("publish.custom.hidden.enabled=false", 1, true))
	end)
	it("waits for a running preflight and refuses invalid cached destination names", function()
		local job = fixture({ pending_probe = true })
		job.start()
		job.tick()
		assert.equal("inspecting_base", job.state)
		job.tick()
		assert.equal("running", job.state)
		assert.is_nil(builder.build({
			model = model(),
			run = run,
			executable = "/crier",
			skip_base_probe = true,
			base_custom_names = { "bad_name" },
		}))
	end)
end)
