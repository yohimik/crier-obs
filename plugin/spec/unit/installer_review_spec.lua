local installer = require("crier_obs.invoke.installer")
local function recorder()
	local lines = {}
	local log = require("crier_obs.log").new({
		obs = {
			LOG_DEBUG = 1,
			LOG_INFO = 2,
			LOG_WARNING = 3,
			LOG_ERROR = 4,
			script_log = function(level, text)
				lines[#lines + 1] = { level = level, text = text }
			end,
		},
	})
	return log, lines
end
local function fixture(process, resolve, log)
	return installer.new({
		state_dir = "/state",
		pin = "1.1.1",
		env = { os = "Linux" },
		log = log or recorder(),
		spawner = {
			spawn = function()
				return process
			end,
		},
		resolver = resolve or {
			probe = function()
				return {}
			end,
			status = function()
				return { state = "ready", message = "installed" }
			end,
		},
	})
end
describe("installer completion and error cleanup", function()
	it("serializes installation through the asynchronous version check", function()
		local checking = true
		local probed
		local instance = fixture({
			poll = function()
				return { code = 0 }
			end,
		}, {
			probe = function(path)
				probed = path
				return {}
			end,
			status = function()
				return { state = checking and "checking" or "ready", message = "crier 1.1.1" }
			end,
		})
		assert(instance.start(""))
		instance.tick()
		local value, err = instance.start()
		assert.is_nil(value)
		assert.equal("busy", err.kind)
		assert.equal("installing", instance.tick().state)
		checking = false
		assert.equal("installed", instance.tick().state)
		assert.is_nil(probed)
		assert(instance.start())
	end)
	it("verifies the explicit crier path and says Update does not replace it", function()
		local log, lines = recorder()
		local probed
		local instance = fixture({
			poll = function()
				return { code = 0 }
			end,
		}, {
			probe = function(path)
				probed = path
				return {}
			end,
			status = function()
				return { state = "outdated", message = "crier 1.0.0 at /opt/crier (older than 1.1.1)" }
			end,
		}, log)
		assert(instance.start("/opt/crier"))
		instance.tick()
		assert.equal("/opt/crier", probed)
		local status = instance.tick()
		assert.equal("failed", status.state)
		assert.equal("Install failed: crier 1.0.0 at /opt/crier (older than 1.1.1)", status.message)
		assert.equal(3, lines[1].level)
		assert.matches("crier path set in Advanced still wins: /opt/crier", lines[1].text, 1, true)
	end)
	it("closes failed polls, reports them as errors and permits an explicit retry", function()
		local log, lines = recorder()
		log.register_secret("TOKEN123")
		local cleaned = 0
		local process = {
			poll = function()
				return nil, { kind = "process", message = "poll failed near TOKEN123" }
			end,
			cancel = function()
				cleaned = cleaned + 1
				return true
			end,
		}
		local instance = fixture(process, nil, log)
		assert(instance.start())
		local status, err = instance.tick()
		assert.equal("failed", status.state)
		assert.equal("Install failed: poll failed near ***", status.message)
		assert.equal("process", err.kind)
		assert.equal(1, cleaned)
		assert.equal(4, lines[#lines].level)
		assert.equal("crier-obs: Install failed: poll failed near ***", lines[#lines].text)
		assert(instance.start())
	end)
	it("permits retry after spawn, install or verification failure", function()
		local attempts = 0
		local log, lines = recorder()
		local instance = installer.new({
			state_dir = "/state",
			pin = "1.1.1",
			env = { os = "Linux" },
			log = log,
			spawner = {
				spawn = function()
					attempts = attempts + 1
					if attempts == 1 then
						return nil, { kind = "spawn", message = "spawn failed" }
					end
					return {
						poll = function()
							return { code = 1, stderr = "sha256 digest mismatch" }
						end,
					}
				end,
			},
		})
		assert.is_nil(instance.start())
		assert.equal("Install failed: spawn failed", instance.status().message)
		assert(instance.start())
		local failed = instance.tick()
		assert.equal("failed", failed.state)
		assert.equal("Install failed: sha256 digest mismatch", failed.message)
		assert.equal("crier-obs: Install failed: sha256 digest mismatch", lines[#lines].text)
		assert(instance.start())
		local probe_failure = fixture({
			poll = function()
				return { code = 0 }
			end,
		}, {
			probe = function()
				return nil, { message = "probe failed" }
			end,
		})
		assert(probe_failure.start())
		assert.equal("failed", probe_failure.tick().state)
		assert(probe_failure.start())
	end)
	it("cancels installer work on unload and leaves verification cleanup to the resolver owner", function()
		local cancelled = 0
		local process = {
			poll = function()
				return nil
			end,
			cancel = function()
				cancelled = cancelled + 1
				return { pid = 42 }
			end,
		}
		local instance = fixture(process)
		assert(instance.start())
		assert.equal(42, instance.detach().pid)
		assert.equal(1, cancelled)
		assert.equal("cancelled", instance.status().state)
		assert(instance.start())
		local version_reads, version_closes = 0, 0
		local resolver = {
			probe = function()
				return {}
			end,
			status = function()
				version_reads = version_reads + 1
				return { state = "checking" }
			end,
			detach = function()
				version_closes = version_closes + 1
			end,
		}
		local verifying = fixture({
			poll = function()
				return { code = 0 }
			end,
		}, resolver)
		assert(verifying.start())
		verifying.tick()
		verifying.detach()
		assert.equal("cancelled", verifying.tick().state)
		assert.equal(0, version_reads)
		assert.equal(0, version_closes)
		resolver.detach()
		assert.equal(1, version_closes)
		assert(verifying.start())
	end)
end)
