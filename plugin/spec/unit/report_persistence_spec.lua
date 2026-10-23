local runs_module = require("crier_obs.state.runs")
local job_module = require("crier_obs.run.job")
local obs = require("obslua")
describe("run report persistence diagnostics", function()
	it("returns a failed status write before replacing the running journal", function()
		local written = {}
		local runs = runs_module.new({
			pid = 7,
			clock = {},
			paths = {},
			fs = {
				write = function(path, data)
					if path == "/status" then
						return nil, { kind = "filesystem", message = "disk full" }
					end
					written[path] = data
					return true
				end,
			},
		})
		local result, e = runs.finish(
			{ stdout = "/stdout", stderr = "/stderr", status = "/status", journal = "/journal" },
			{ code = 0, stdout = "safe report", stderr = "" }
		)
		assert.is_nil(result)
		assert.equal("filesystem", e.kind)
		assert.equal("safe report", written["/stdout"])
		assert.is_nil(written["/journal"])
	end)
	it("keeps the successful publish outcome while warning with a scrubbed storage error", function()
		local log = require("crier_obs.log").new({ obs = obs })
		log.register_secret("STORE_SECRET")
		local start = #obs.logs
		local job = job_module.new({
			event = "start",
			plan = { args = {}, env = {}, files = {}, needs_secrets = {} },
			run = {},
			fs = {},
			log = log,
			runs = {
				journal = function()
					return true
				end,
				finish = function()
					return nil, { kind = "filesystem", message = "Cannot persist STORE_SECRET" }
				end,
			},
			spawner = {
				spawn = function()
					return {
						pid = 1,
						poll = function()
							return { code = 0, stdout = "{}", stderr = "" }
						end,
					}
				end,
			},
		})
		job.start()
		job.tick()
		assert.equal("done", job.state)
		assert.is_true(job.result.ok)
		assert.equal("Posted successfully", job.result.message)
		local warning = false
		for i = start + 1, #obs.logs do
			local line = obs.logs[i]
			assert.is_nil(line.text:find("STORE_SECRET", 1, true))
			if line.text:find("Cannot save run report:", 1, true) then
				warning = true
				assert.is_truthy(line.text:find("***", 1, true))
			end
		end
		assert.is_true(warning)
	end)
end)
