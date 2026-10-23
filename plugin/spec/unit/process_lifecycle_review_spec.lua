local ffi = require("ffi")
local posix = require("crier_obs.proc.posix")
local job_module = require("crier_obs.run.job")
local ping_module = require("crier_obs.run.ping")
local log = require("crier_obs.log").new({})
ffi.cdef("int usleep(unsigned int);")
describe("process cancellation review #posix", function()
	it("propagates captured pipe read failures and closes/reaps the process group", function()
		local C = setmetatable({
			read = function()
				ffi.errno(5)
				return -1
			end,
		}, {
			__index = function(_, name)
				return ffi.C[name]
			end,
		})
		local backend = posix.new({ C = C })
		local p = assert(
			backend.spawn({ executable = "/bin/sleep", args = { "1" }, capture_stdout = true, capture_stderr = true })
		)
		local result, e = p.poll()
		assert.is_nil(result)
		assert.equal("pipe", e.kind)
		p.cancel()
		for _ = 1, 100 do
			backend.reap()
			if ffi.C.kill(p.pid, 0) ~= 0 then
				return
			end
			ffi.C.usleep(1000)
		end
		assert(false, "cancelled wrapper not reaped")
	end)
	it("reaps the primary wrapper if the env-fd writer cannot be spawned", function()
		local calls = 0
		local C = setmetatable({
			posix_spawnp = function(...)
				calls = calls + 1
				if calls == 2 then
					return 2
				end
				return ffi.C.posix_spawnp(...)
			end,
		}, {
			__index = function(_, name)
				return ffi.C[name]
			end,
		})
		local backend = posix.new({ C = C })
		local process, e = backend.spawn({ executable = "/bin/sleep", args = { "1" }, env_fd_data = "KEY=secret\0" })
		assert.is_nil(process)
		assert.equal("spawn", e.kind)
		for _ = 1, 100 do
			local completed = backend.reap()
			if #completed > 0 then
				assert.equal(137, completed[1].code)
				return
			end
			ffi.C.usleep(1000)
		end
		assert(false, "failed spawn wrapper not reaped")
	end)
	it("preserves a status written by a wrapper that another reaper already collected", function()
		local waits = 0
		local written
		local C = setmetatable({
			waitpid = function()
				waits = waits + 1
				if waits == 1 then
					return 0
				end
				ffi.errno(10)
				return -1
			end,
		}, {
			__index = function(_, name)
				return ffi.C[name]
			end,
		})
		local backend = posix.new({
			C = C,
			fs = {
				read = function()
					return "6"
				end,
				write = function(_, value)
					written = value
					return true
				end,
			},
		})
		-- Native spawn succeeds; cancel immediately kills the group, scripted wait simulates a concurrent reaper.
		local p = assert(backend.spawn({ executable = "/bin/sleep", args = { "1" }, status_path = "/status" }))
		assert.is_table(p.cancel())
		local records = backend.reap()
		assert.equal(6, records[1].code)
		assert.equal("6", written)
		local status = ffi.new("int[1]")
		for _ = 1, 100 do
			if ffi.C.waitpid(p.pid, status, 1) ~= 0 then
				return
			end
			ffi.C.usleep(1000)
		end
	end)
	it("cancels and reaps adopted groups after fatal poll errors without losing journal ownership", function()
		local waits = 0
		local signals = {}
		local C = {
			waitpid = function(_, status)
				waits = waits + 1
				if waits == 1 then
					ffi.errno(22)
					return -1
				elseif waits == 2 then
					return 0
				else
					status[0] = 137 * 256
					return 123
				end
			end,
			kill = function(pid, signal)
				signals[#signals + 1] = { pid, signal }
				return 0
			end,
		}
		local backend = posix.new({ C = C })
		assert.is_nil(backend.adopt({ pid = 0 }))
		local process =
			assert(backend.adopt({ pid = 123, event = "start", journal = "/journal", status_path = "/status" }))
		local result, e = process.poll()
		assert.is_nil(result)
		assert.equal(22, e.errno)
		local record = process.cancel()
		assert.equal(123, record.pid)
		assert.equal(-123, signals[1][1])
		local completed = backend.reap()
		assert.equal(137, completed[1].code)
		assert.equal("/journal", completed[1].run.journal)
	end)
	it("captures ECHILD before missing status-file reads overwrite errno", function()
		local C = {
			waitpid = function()
				ffi.errno(10)
				return -1
			end,
			kill = function()
				ffi.errno(3)
				return -1
			end,
		}
		local backend = posix.new({
			C = C,
			fs = {
				read = function()
					ffi.errno(2)
					return nil, { kind = "filesystem", message = "not yet written" }
				end,
			},
		})
		local process = assert(backend.adopt({ pid = 123, status_path = "/missing" }))
		assert.equal(1, process.poll().code)
		assert.is_false(process.terminate())
		assert.is_true(process.kill())
		assert(process.cancel())
	end)
	it("journals and reaps a partial output-drainer handoff when the second helper fails", function()
		local calls = 0
		local C = setmetatable({
			posix_spawnp = function(...)
				calls = calls + 1
				if calls == 3 then
					return 2
				end
				return ffi.C.posix_spawnp(...)
			end,
		}, {
			__index = function(_, name)
				return ffi.C[name]
			end,
		})
		local backend = posix.new({ C = C })
		local process = assert(
			backend.spawn({ executable = "/bin/sleep", args = { "1" }, capture_stdout = true, capture_stderr = true })
		)
		assert.is_nil(process.detach())
		local record = process.cancel()
		assert.is_table(record)
		assert.equal(1, #record.drainers)
		for _ = 1, 100 do
			backend.reap()
			if ffi.C.kill(record.pid, 0) ~= 0 and ffi.C.kill(record.drainers[1].pid, 0) ~= 0 then
				return
			end
			ffi.C.usleep(1000)
		end
		assert(false, "partial handoff children not reaped")
	end)
end)
describe("runtime journal review", function()
	local function fixture(fail_journal)
		local acknowledged, cancelled, journals = false, 0, 0
		local process = {
			pid = 9,
			poll = function()
				return nil, { kind = "poll", message = "failed" }
			end,
			cancel = function()
				cancelled = cancelled + 1
				return true
			end,
			detach = function()
				return { pid = 9 }
			end,
			kill = function()
				cancelled = cancelled + 1
			end,
		}
		local deps = {
			event = "start",
			plan = { files = {}, needs_secrets = {}, env = {} },
			run = {},
			fs = {},
			spawner = {
				spawn = function()
					return process
				end,
				adopt = function()
					return process
				end,
			},
			log = log,
			runs = {
				finish = function() end,
				journal = function()
					journals = journals + 1
					if fail_journal and journals >= fail_journal then
						return nil, { kind = "filesystem", message = "journal failed" }
					end
					return true
				end,
			},
			on_spawn = function()
				acknowledged = true
			end,
		}
		return job_module.new(deps), function()
			return acknowledged, cancelled
		end, deps
	end
	it("does not acknowledge a durable snapshot unless the running PID was journaled", function()
		local job, state = fixture(1)
		job.start()
		local acknowledged, cancelled = state()
		assert.is_false(acknowledged)
		assert.equal(1, cancelled)
		assert.equal("failed", job.state)
	end)
	it("cancels and closes a child on fatal poll errors and surfaces park/detach journal failures", function()
		local job, state = fixture()
		job.start()
		job.tick()
		local _, cancelled = state()
		assert.equal(1, cancelled)
		assert.equal("failed", job.state)
		job = fixture(2)
		job.start()
		local record, e = job.detach()
		assert.is_nil(record)
		assert.equal("filesystem", e.kind)
		job = fixture(1)
		local ok, problem = job.park()
		assert.is_nil(ok)
		assert.equal("filesystem", problem.kind)
	end)
	it("cancels setup subprocesses on fatal polling errors", function()
		local cancelled = 0
		local process = {
			poll = function()
				return nil, { kind = "poll", message = "failed" }
			end,
			cancel = function()
				cancelled = cancelled + 1
			end,
		}
		local ping = ping_module.new({
			env = {},
			fs = {
				write = function()
					return true
				end,
			},
			log = log,
			secrets = {
				resolve = function(_, _, cb)
					cb({})
				end,
			},
			spawner = {
				spawn = function()
					return process
				end,
			},
		})
		ping.start(
			{ values = { ["stage.mode"] = "none", ["stage.server.tunnel.mode"] = "none" }, credential_set = "default" },
			"/crier",
			{ args = {}, needs_secrets = {}, files = {} }
		)
		ping.tick()
		assert.equal(2, cancelled)
		assert.is_false(ping.busy())
	end)
	it("kills a detached process if reopening for failed-journal cleanup is unavailable", function()
		local job, state, deps = fixture(2)
		deps.spawner.adopt = nil
		job.start()
		assert.is_nil(job.detach())
		local _, cancelled = state()
		assert.equal(1, cancelled)
	end)
end)
