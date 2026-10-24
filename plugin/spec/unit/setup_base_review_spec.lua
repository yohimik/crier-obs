local ping_module = require("crier_obs.run.ping")
local builder = require("crier_obs.invoke.builder")
local obs = require("obslua")
local log = require("crier_obs.log").new({})
local function build()
	local data = obs.obs_data_create()
	local m = require("crier_obs.settings.model").new({ obs = obs })
	m.defaults(data)
	local model = m.snapshot(data)
	obs.obs_data_release(data)
	model.mode = "advanced"
	model.base_config = "/base.yaml"
	model.values["stage.mode"] = "server"
	local run = { dir = "/run", config = "/run/config.json", data = "/run/data.json" }
	return model, assert(builder.build({ model = model, run = run, executable = "/crier" }))
end
local function fixture(options)
	options = options or {}
	local content = "base"
	local spawned, cancelled, journaled = {}, 0, 0
	local callback
	local fs = {
		read = function()
			if options.unreadable then
				return nil, { kind = "filesystem", message = "missing base" }
			end
			return content
		end,
		write = function()
			return true
		end,
	}
	local ping = ping_module.new({
		fs = fs,
		env = {
			sandbox_status = function()
				return { kind = "flatpak", ok = false, message = "missing host helper" }
			end,
		},
		log = log,
		runs = {
			finish = function()
				return true
			end,
			journal = function()
				journaled = journaled + 1
				return true
			end,
		},
		find_binary = function() end,
		secrets = {
			resolve = function(_, _, cb)
				if options.delay then
					callback = cb
				else
					cb({})
				end
			end,
			backend_status = function()
				return { state = "ready", label = "test store" }
			end,
		},
		spawner = {
			spawn = function(plan)
				spawned[#spawned + 1] = plan
				if plan.args[1] == "config" and options.spawn_error then
					return nil, { kind = "spawn", message = "cannot spawn config" }
				end
				return {
					poll = function()
						if plan.args[1] == "config" then
							if options.poll_error then
								return nil, { kind = "poll", message = "cannot poll config" }
							end
							if options.changed then
								content = "changed base"
							end
							return { code = options.code or 0, stdout = options.invalid and "{}" or '{"values":{}}' }
						end
						return { code = 0, stdout = "{}" }
					end,
					cancel = function()
						cancelled = cancelled + 1
						return { pid = 9 }
					end,
				}
			end,
		},
	})
	local model, plan = build()
	return ping,
		model,
		plan,
		spawned,
		function()
			return cancelled, journaled
		end,
		function(value)
			content = value
		end,
		function()
			return callback
		end
end
describe("setup base inspection recovery", function()
	it("shows sandbox failures and pending rows before report refresh completes", function()
		local ping, model, plan = fixture()
		assert(ping.start(model, "/crier", plan))
		local rows = ping.rows()
		assert.equal("setup", rows[#rows].target)
		assert.is_false(rows[4].ok)
		ping.tick()
		ping.tick()
		assert.is_false(ping.busy())
		assert.equal("This staging mode has no credentials to check", ping.rows()[3].message)
	end)
	it("surfaces missing files, spawn failures, fatal polls, invalid reports and changed base content", function()
		for _, options in ipairs({
			{ unreadable = true },
			{ spawn_error = true },
			{ poll_error = true },
			{ code = 1 },
			{ invalid = true },
			{ changed = true },
		}) do
			local ping, model, plan, _, counts = fixture(options)
			ping.start(model, "/crier", plan)
			ping.tick()
			ping.tick()
			assert.is_false(ping.busy())
			local found = false
			for _, row in ipairs(ping.rows()) do
				if row.target == "config" and row.ok == false then
					found = true
				end
			end
			assert.is_true(found)
			if options.poll_error then
				local cancelled, journaled = counts()
				assert.equal(1, cancelled)
				assert.equal(1, journaled)
			end
		end
	end)
	it("checks the fingerprint again after a delayed credential lookup", function()
		local ping, model, plan, spawned, _, change, getcallback = fixture({ delay = true })
		ping.start(model, "/crier", plan)
		ping.tick()
		change("modified while resolving")
		getcallback()({})
		ping.tick()
		assert.is_false(ping.busy())
		assert.equal(2, #spawned)
		local found = false
		for _, row in ipairs(ping.rows()) do
			if row.target == "config" and row.ok == false then
				found = true
			end
		end
		assert.is_true(found)
	end)
end)
