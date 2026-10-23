local queue_module = require("crier_obs.run.queue")
local scheduler_module = require("crier_obs.run.scheduler")
local job_module = require("crier_obs.run.job")
local builder = require("crier_obs.invoke.builder")
local plans = require("crier_obs.invoke.plan")
local report = require("crier_obs.invoke.report")
local doc = require("crier_obs.invoke.datadoc")
local obs = require("obslua")
local log = require("crier_obs.log").new({})
local function model()
	local data = obs.obs_data_create()
	local models = require("crier_obs.settings.model").new({ obs = obs })
	models.defaults(data)
	local m = models.snapshot(data)
	obs.obs_data_release(data)
	return m
end
describe("remaining pure runtime boundaries", function()
	it("completes queued work in order and detaches active work with pending cancellation", function()
		local done, cancelled = 0, 0
		local terminal = false
		local q = queue_module.new({
			bound = 1,
			on_done = function()
				done = done + 1
			end,
		})
		local function job(event, immediate)
			return {
				event = event,
				start = function() end,
				tick = function()
					terminal = true
				end,
				finished = function()
					return immediate or terminal
				end,
				detach = function()
					return { pid = 1 }
				end,
				cancel = function()
					cancelled = cancelled + 1
				end,
			}
		end
		assert(q.push(job("manual", true)))
		q.tick()
		assert.equal(1, done)
		assert.is_nil(q.active())
		assert(q.push(job("manual")))
		q.tick()
		assert.is_truthy(q.active())
		q.tick()
		assert.equal(2, done)
		terminal = false
		assert(q.push(job("start")))
		q.tick()
		assert(q.push(job("interval")))
		q.drop_intervals()
		assert.equal(1, cancelled)
		assert(q.push(job("manual")))
		local accepted, reason = q.push(job("manual"))
		assert.is_false(accepted)
		assert.equal("full", reason)
		local records = assert(q.detach())
		assert.equal(1, #records)
		assert.equal(2, cancelled)
		q = queue_module.new({})
		local active = job("start")
		active.detach = function()
			return nil, { kind = "detach", message = "failed" }
		end
		q.push(active)
		q.tick()
		assert.is_nil(q.detach())
	end)
	it("handles recording adoption, unobserved stop, disabled quit and closing guards", function()
		obs.reset()
		obs.streaming = true
		obs.recording = true
		local m = model()
		local emitted, logs = {}, {}
		local scheduler = scheduler_module.new({
			obs = obs,
			clock = {
				now_mono = function()
					return 0
				end,
				now_wall = function()
					return 1
				end,
			},
			model = m,
			log = {
				info = function(s)
					logs[#logs + 1] = s
				end,
			},
			enqueue = function(event)
				emitted[#emitted + 1] = event
			end,
		})
		scheduler.load()
		assert.is_true(scheduler.recording.estimated)
		assert.is_true(scheduler.stream.estimated)
		obs.streaming = false
		scheduler.tick()
		assert.equal("end", emitted[1])
		scheduler.event(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
		assert.is_true(scheduler.closing())
		assert.equal("quit post skipped", logs[1])
		scheduler.event(obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		scheduler.tick()
		assert.equal(1, #emitted)
		obs.reset()
	end)
	it("builds dry runs, warns about malformed custom env, and returns JSON numeric errors", function()
		local m = model()
		m.custom_names = { "community" }
		m.values["publish.custom.community.env"] = { "bad entry" }
		local run = { dir = "/run", config = "/run/config", data = "/run/data", preview = "/run/preview" }
		local b = builder.new({ argv_limit = 20000 })
		local p = assert(b.build({ model = m, run = run, dry_run = true }))
		assert.equal(1, #p.warnings)
		assert.is_truthy(table.concat(p.args, "|"):find("--publish-dry-run|--render-output|/run/preview", 1, true))
		assert(builder.new().build({ model = m, run = run }))
		m.values["render.scale"] = math.huge
		assert.is_nil(builder.build({ model = m, run = run }))
		local merged = plans.with_secrets({ env = { PATH = "/safe" } }, {}, log)
		assert.equal("/safe", merged.env.PATH)
		local parsed = report.new({ log = log }).parse({ code = 0, stdout = "{}", stderr = "" })
		assert.is_true(parsed.ok)
		assert.equal("crier exceeded the run timeout", report.parse({ code = 1, timed_out = true }).message)
	end)
	it("captures optional frontend metadata while releasing owned references", function()
		local released = 0
		local value = doc.frontend({
			obs_frontend_get_current_scene = function()
				return {}
			end,
			obs_source_get_name = function()
				return "scene"
			end,
			obs_source_release = function()
				released = released + 1
			end,
			obs_frontend_get_current_scene_collection = function()
				return "collection"
			end,
			obs_get_version_string = function()
				return "32.2.2"
			end,
		})
		assert.equal("collection", value.scene_collection)
		assert.equal("32.2.2", value.obs_version)
		assert.equal(1, released)
	end)
	it("handles warning-only plans, jobs without credentials and cancellation after spawn", function()
		local kills = 0
		local saves = {}
		local deps = {
			event = "manual",
			plan = { files = {}, needs_secrets = {}, warnings = { "comma" }, env = {} },
			run = {},
			fs = {},
			log = log,
			runs = {
				finish = function(_, result)
					saves[#saves + 1] = result
				end,
				journal = function()
					return true
				end,
			},
			spawner = {
				spawn = function()
					return {
						pid = 1,
						poll = function()
							return { code = 1, timed_out = true, stdout = "", stderr = "" }
						end,
						kill = function()
							kills = kills + 1
						end,
					}
				end,
			},
		}
		local job = job_module.new(deps)
		job.start()
		job.start()
		job.tick()
		assert.equal("timed_out", job.state)
		job = job_module.new(deps)
		job.start()
		job.cancel()
		assert.equal(1, kills)
		assert.equal("cancelled", job.state)
	end)
end)
