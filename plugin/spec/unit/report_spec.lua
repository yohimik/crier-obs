local report = require("crier_obs.invoke.report")
local errors = require("crier_obs.errors")
local job_module = require("crier_obs.run.job")

describe("crier exit codes and reports", function()
	it("maps every exit code to its message, kind, hint and log level", function()
		local cases = {
			{ 0, "ok", "Posted successfully", "info" },
			{ 1, "exit", "Invalid configuration", "error" },
			{ 2, "exit", "Invalid command arguments", "error" },
			{ 3, "exit", "Rendering failed", "error" },
			{ 4, "exit", "Some platforms failed", "warn" },
			{ 5, "exit", "Publishing failed", "error" },
			{ 6, "exit", "Staging failed", "error" },
			{ 97, "exit", "Run directory is missing", "error" },
			{ 126, "exit", "crier is not executable", "error" },
			{ 127, "exit", "crier was not found", "error" },
			{ 42, "exit", "crier exited with code 42", "error" },
		}
		for _, case in ipairs(cases) do
			local r = report.parse({ code = case[1], stdout = "", stderr = "" })
			assert.equal(case[2], r.kind, "exit " .. case[1])
			assert.equal(case[3], r.message, "exit " .. case[1])
			assert.equal(case[4], r.level, "exit " .. case[1])
			assert.equal(case[1] == 0, r.ok)
			if case[1] == 126 then
				assert.equal("On macOS, check the downloaded binary’s quarantine attribute.", r.hint)
			else
				assert.is_nil(r.hint)
			end
		end
		local signalled = report.parse({ code = 137, signal = 9 })
		assert.equal("signal", signalled.kind)
		assert.equal("crier stopped by signal 9", signalled.message)
		assert.equal("error", signalled.level)
		local crashed = report.parse({ code = 0xc0000005 })
		assert.equal("crashed", crashed.kind)
		assert.equal("crier crashed (NTSTATUS 0xc0000005)", crashed.message)
		local timed = report.parse({ code = 0, timed_out = true })
		assert.equal("timeout", timed.kind)
		assert.equal("error", timed.level)
		assert.is_false(timed.ok)
		assert.same({
			kind = "timeout",
			message = "crier exceeded the run timeout",
			message_text = { key = "exit_timeout", n = 0 },
		}, errors.timeout())
	end)

	it("names the platforms that failed and summarises dry runs", function()
		local log = require("crier_obs.log").new({})
		log.register_secret("TOKEN42")
		local partial = report.parse({
			code = 4,
			stdout = '{"results":[{"platform":"telegram","ok":true},{"platform":"discord","ok":false,"error":"401 TOKEN42"}]}',
			stderr = "",
		}, log)
		assert.equal("Some platforms failed (discord)", partial.message)
		assert.same({ { platform = "discord", error = "401 ***" } }, partial.failed)
		local dry = report.parse({
			code = 0,
			stdout = '{"dryRun":true,"plan":[{"platform":"telegram"},{"platform":"x"},{"bad":1}]}',
		}, log)
		assert.equal("Dry run planned 2 posts: telegram, x", dry.summary)
		assert.equal("Dry run planned 0 posts", report.parse({ code = 0, stdout = '{"dryRun":true}' }).summary)
		assert.equal(
			"Dry run planned 1 post: x",
			report.parse({ code = 0, stdout = '{"dryRun":true,"plan":[{"platform":"x"}]}' }).summary
		)
		local lines = {}
		for i = 1, 30 do
			lines[i] = "line " .. i
		end
		local tail = report.parse({ code = 1, stderr = table.concat(lines, "\n") })
		assert.equal(20, select(2, tail.stderr:gsub("line", "")))
		assert.equal("line 11", tail.stderr:match("^[^\n]+"))
	end)

	it("keeps only bounded output and scrubs nothing it does not keep", function()
		local text = string.rep("x", 100) .. "\n" .. string.rep("y", 50)
		assert.equal(string.rep("y", 50), job_module.tail(text, 60))
		assert.equal(text, job_module.tail(text, 1000))
		assert.equal(string.rep("z", 10), job_module.tail(string.rep("z", 100), 10))
		local scrubbed = {}
		local log = require("crier_obs.log").new({})
		local scrub = log.scrub
		log.scrub = function(value)
			scrubbed[#scrubbed + 1] = #tostring(value or "")
			return scrub(value)
		end
		local saved
		local huge = string.rep("debug line with TOKEN\n", 200000)
		local job = job_module.new({
			event = "manual",
			plan = { files = {}, needs_secrets = {}, env = {} },
			run = {},
			fs = {},
			log = log,
			runs = {
				finish = function(_, result)
					saved = result
					return true
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
							return { code = 0, stdout = '{"results":[]}' .. string.rep(" ", 2 * 1048576), stderr = huge }
						end,
						cancel = function()
							return true
						end,
					}
				end,
			},
		})
		job.start()
		job.tick()
		assert.equal("done", job.state)
		for _, size in ipairs(scrubbed) do
			assert.is_true(size <= job_module.STDOUT_LIMIT, "scrubbed " .. size .. " bytes")
		end
		assert.is_true(#saved.stderr <= job_module.STDERR_LIMIT)
		assert.equal("debug line with TOKEN", saved.stderr:match("^[^\n]+"))
	end)
end)
