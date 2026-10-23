local log = require("crier_obs.log").new({})
local resolver_module = require("crier_obs.proc.resolver")
local installer_module = require("crier_obs.invoke.installer")
local job_module = require("crier_obs.run.job")
local ping_module = require("crier_obs.run.ping")
local runs_module = require("crier_obs.state.runs")
local function err(message)
	return { kind = "test", message = message or "refused" }
end
local function finished(code, stdout, stderr)
	return {
		poll = function()
			return { code = code, stdout = stdout or "", stderr = stderr or "" }
		end,
		detach = function()
			return { pid = 1 }
		end,
	}
end
local function model()
	return {
		values = { ["stage.mode"] = "s3", ["stage.server.tunnel.mode"] = "zrok", ["render.video.enabled"] = true },
		credential_set = "default",
	}
end
local function memoryfs()
	local files, dirs = {}, {}
	return {
		exists = function(p)
			return files[p] ~= nil or dirs[p]
		end,
		read = function(p)
			return files[p]
		end,
		write = function(p, s)
			files[p] = s
			return true
		end,
		mkdir = function(p)
			dirs[p] = true
			return true
		end,
		mkdir_private = function(p)
			dirs[p] = true
			return true
		end,
		glob = function(pattern)
			local base = pattern:sub(1, -3)
			local out = {}
			for p in pairs(files) do
				if p:match("^(.*)/[^/]+$") == base then
					out[#out + 1] = p
				end
			end
			for p in pairs(dirs) do
				if p:match("^(.*)/[^/]+$") == base then
					out[#out + 1] = p
				end
			end
			return out
		end,
		remove = function(p)
			files[p] = nil
		end,
		rmdir = function(p)
			dirs[p] = nil
		end,
	},
		files,
		dirs
end
describe("resolver and installer failure recovery", function()
	it("resolves precedence, parses legacy version output, and reports errors", function()
		local result = finished(0, "crier 1.0.0")
		local detached = false
		local fs = {
			exists = function(p)
				return p == "/state/bin/crier" or p == "/explicit" or p == "/path/crier"
			end,
		}
		local r = resolver_module.new({
			fs = fs,
			env = {
				os = "Linux",
				path = function()
					return "/path"
				end,
			},
			state_dir = "/state",
			pin = "1.1.1",
			spawner = {
				spawn = function()
					return result
				end,
			},
		})
		assert.equal("/explicit", r.find("/explicit"))
		assert.equal("/state/bin/crier", r.find())
		assert.is_nil(r.find("/missing"))
		assert(r.probe())
		assert.is_nil(r.probe())
		assert.equal("outdated", r.tick().state)
		result = finished(1, "", "failure")
		assert(r.probe())
		assert.equal("failed", r.tick().state)
		result = finished(0, "unknown")
		assert(r.probe())
		assert.equal("failed", r.tick().state)
		result = finished(0, "not-a-version")
		result.detach = function()
			detached = true
		end
		assert(r.probe())
		r.detach()
		assert.is_true(detached)
		local missing = resolver_module.new({
			fs = {
				exists = function()
					return false
				end,
			},
			env = { os = "Windows", path = "C:\\bin" },
			spawner = {},
		})
		assert.is_nil(missing.probe())
		assert.equal("missing", missing.status().state)
		local failed = resolver_module.new({
			fs = fs,
			spawner = {
				spawn = function()
					return nil, err("spawn failed")
				end,
			},
		})
		assert.is_nil(failed.probe("/explicit"))
		assert.equal("failed", failed.status().state)
	end)
	it("installs the pinned version, ignores quarantine removal failures, then verifies discovery", function()
		local plans, phase = {}, 0
		local status = { state = "checking" }
		local resolver = {
			probe = function()
				return {}
			end,
			tick = function()
				return status
			end,
		}
		local installer = installer_module.new({
			state_dir = "/state",
			pin = "1.1.1",
			env = { os = "OSX" },
			resolver = resolver,
			spawner = {
				spawn = function(plan)
					plans[#plans + 1] = plan
					phase = phase + 1
					return finished(phase == 2 and 1 or 0)
				end,
			},
		})
		assert(installer.start())
		assert.is_nil(installer.start())
		installer.tick()
		assert.equal("/usr/bin/xattr", plans[2].executable)
		installer.tick()
		assert.equal("installing", installer.tick().state)
		status = { state = "ready", message = "crier 1.1.1" }
		assert.equal("installed", installer.tick().state)
		assert.is_truthy(plans[1].args[2]:find("CRIER_VERSION=", 1, true))
		assert.equal(300, plans[1].timeout)
	end)
	it("shows digest failures, timeouts, failed probes and Windows no-profile installer plans", function()
		for _, result in ipairs({ { code = 1, stderr = "sha256 digest mismatch" }, { code = 1, timed_out = true } }) do
			local i = installer_module.new({
				state_dir = "/state",
				pin = "1.1.1",
				env = { os = "Linux" },
				resolver = {},
				spawner = {
					spawn = function()
						return {
							poll = function()
								return result
							end,
						}
					end,
				},
			})
			assert(i.start())
			assert.equal("failed", i.tick().state)
		end
		local plans = {}
		local i = installer_module.new({
			state_dir = "C:\\space dir",
			pin = "1.1.1",
			env = { os = "Windows" },
			resolver = {
				probe = function()
					return nil, err("missing after install")
				end,
			},
			spawner = {
				spawn = function(p)
					plans[#plans + 1] = p
					return finished(0)
				end,
			},
		})
		i.start()
		assert.equal("failed", i.tick().state)
		assert.equal("powershell.exe", plans[1].executable)
		assert.equal("-NoProfile", plans[1].args[1])
		local invalid = installer_module.new({ state_dir = "/state", pin = "bad", env = {} })
		assert.is_nil(invalid.start())
		local failure = installer_module.new({
			state_dir = "/state",
			spawner = {
				spawn = function()
					return nil, err()
				end,
			},
			env = {},
		})
		assert.is_nil(failure.start())
		assert.equal("failed", failure.status().state)
		local detached = false
		local detach = installer_module.new({
			state_dir = "/state",
			env = {},
			spawner = {
				spawn = function()
					return {
						poll = function() end,
						detach = function()
							detached = true
						end,
					}
				end,
			},
		})
		detach.start()
		detach.detach()
		assert.is_true(detached)
	end)
end)
describe("run execution failures and journals", function()
	local function make(overrides)
		local saves = {}
		local deps = {
			event = "manual",
			credential_set = "default",
			plan = { files = { config = "{}" }, needs_secrets = { "key" }, env = {} },
			run = {},
			fs = {
				write = function()
					return true
				end,
			},
			runs = {
				finish = function(_, r)
					saves[#saves + 1] = r
				end,
				journal = function()
					return true
				end,
			},
			log = log,
			secrets = {
				resolve = function(_, _, cb)
					cb({ key = "secret" })
				end,
			},
			spawner = {
				spawn = function()
					return finished(0)
				end,
			},
		}
		for k, v in pairs(overrides or {}) do
			deps[k] = v
		end
		return job_module.new(deps), saves
	end
	it("persists filesystem, missing-backend, spawn and poll failures as terminal results", function()
		local cases = {
			{ fs = {
				write = function()
					return nil, err("write")
				end,
			} },
			{ secrets = {
				resolve = function(_, _, cb)
					cb(nil, err("backend"))
				end,
			} },
			{ spawner = {
				spawn = function()
					return nil, err("spawn")
				end,
			} },
			{
				spawner = {
					spawn = function()
						return {
							poll = function()
								return nil, err("poll")
							end,
							kill = function() end,
						}
					end,
				},
			},
		}
		for _, case in ipairs(cases) do
			local job, saves = make(case)
			job.start()
			job.tick()
			assert.is_true(job.finished())
			assert.equal("failed", job.state)
			assert.equal(1, #saves)
		end
	end)
	it("cancels queued snapshots and does not spawn after an async resolution returns late", function()
		local callback
		local spawned = false
		local job = make({
			secrets = {
				resolve = function(_, _, cb)
					callback = cb
				end,
			},
			spawner = {
				spawn = function()
					spawned = true
				end,
			},
		})
		job.start()
		job.cancel()
		callback({ key = "value" })
		assert.is_false(spawned)
		assert.equal("cancelled", job.state)
	end)
	it("returns detach errors and supports immediate cached-credential jobs", function()
		local job = make({
			cached_secrets = {},
			spawner = {
				spawn = function()
					return {
						pid = 1,
						kill = function() end,
						poll = function() end,
						detach = function()
							return nil, err("handoff")
						end,
					}
				end,
			},
		})
		job.start()
		assert.is_nil(job.detach())
		assert.equal("failed", job.state)
		local queued = make()
		assert.equal("cancelled", queued.detach().state)
	end)
	it("creates private state, adopts detached runs and sweeps completed runs by age/count", function()
		local fs, files = memoryfs()
		local time = 100
		local paths = {
			root = "/state",
			runs = "/state/runs",
			bin = "/state/bin",
			templates = "/state/templates",
			template = "/state/templates/live.html",
			secrets = "/state/secrets",
		}
		local runs = runs_module.new({
			fs = fs,
			clock = {
				now_wall = function()
					return time
				end,
			},
			paths = paths,
			pid = 7,
		})
		assert(runs.init())
		local a = assert(runs.create("start"))
		time = 101
		local b = assert(runs.create("end"))
		runs.journal(a, { state = "detached", pid = 123, child_pid = 124, drainers = { { pid = 125 } } })
		assert.equal(1, #runs.adopt())
		runs.finish(a, { code = 0, stdout = "safe", stderr = "" })
		runs.finish(b, { code = 1, stderr = "failed" })
		runs.sweep(7, 1)
		assert.is_nil(files[a.journal])
		assert.is_truthy(files[b.journal])
		time = 1000000
		runs.sweep(1, 5)
		assert.is_nil(files[b.journal])
		local broken = runs_module.new({
			fs = {
				mkdir = function()
					return nil, err()
				end,
			},
			clock = {},
			paths = paths,
			pid = 7,
		})
		assert.is_nil(broken.init())
	end)
	it("avoids run directory collisions and adopts cleanup helpers without changing queued journals", function()
		local fs, files = memoryfs()
		local paths = {
			root = "/state",
			runs = "/state/runs",
			bin = "/state/bin",
			templates = "/state/templates",
			template = "/state/templates/live.html",
			secrets = "/state/secrets",
		}
		local deps = { fs = fs, clock = {
			now_wall = function()
				return 1
			end,
		}, paths = paths, pid = 7 }
		local first = runs_module.new(deps)
		assert(first.init())
		local a = assert(first.create("start"))
		local second = runs_module.new(deps)
		local b = assert(second.create("end"))
		assert.is_not.equal(a.dir, b.dir)
		assert(first.journal(a, { state = "queued", drainers = { { pid = 99 } } }))
		local helpers = first.adopt()
		assert.equal("drainer", helpers[1].event)
		assert.is_nil(helpers[1].journal)
		local original = fs.mkdir_private
		fs.mkdir_private = function()
			return nil, err("private directory")
		end
		assert.is_nil(second.init())
		fs.mkdir_private = original
		fs.write = function()
			return nil, err("disk full")
		end
		assert.is_nil(first.finish(a, { code = 1 }))
		assert.is_nil(first.create("manual"))
		assert.is_truthy(files[a.journal])
	end)

	it("uses each operating system state convention and respects explicit paths", function()
		local paths = require("crier_obs.state.paths")
		local get = function(k)
			return ({ HOME = "/home/me", LOCALAPPDATA = "C:\\AppData", XDG_STATE_HOME = "/custom" })[k]
		end
		assert.equal("C:\\AppData\\crier-obs", paths.new({ env = { os = "Windows", getenv = get } }).root)
		assert.equal(
			"/home/me/Library/Application Support/crier-obs",
			paths.new({ env = { os = "OSX", getenv = get } }).root
		)
		assert.equal("/custom/crier-obs", paths.new({ env = { os = "Linux", getenv = get } }).root)
		assert.equal("/explicit", paths.new({ state_dir = "/explicit" }).root)
	end)
end)
describe("setup error rows", function()
	it("reports Flatpak tools, config errors and failed keyring lookup", function()
		local rows
		local p = ping_module.new({
			env = {
				flatpak = function()
					return true
				end,
			},
			fs = {
				write = function()
					return nil, err("config")
				end,
			},
			log = log,
			find_binary = function() end,
			secrets = {},
			spawner = {
				spawn = function()
					return finished(1, "", "error")
				end,
			},
		})
		assert.is_nil(p.start(model(), "/crier", { files = { config = "{}" }, args = {}, needs_secrets = {} }))
		rows = p.tick()
		assert.is_true(#rows >= 6)
		p = ping_module.new({
			env = {},
			fs = {
				write = function()
					return true
				end,
			},
			log = log,
			secrets = {
				resolve = function(_, _, cb)
					cb(nil, err("locked"))
				end,
			},
			spawner = {
				spawn = function()
					return nil, err("spawn")
				end,
			},
		})
		assert(p.start(model(), "/crier", { files = {}, args = {}, needs_secrets = { "key" } }))
		rows = p.tick()
		assert.is_false(rows[2].ok)
	end)
	it("ignores a stale lookup callback after detachment", function()
		local callback
		local terminated = false
		local p = ping_module.new({
			env = {},
			fs = {
				write = function()
					return true
				end,
			},
			log = log,
			secrets = {
				resolve = function(_, _, cb)
					callback = cb
				end,
			},
			spawner = {
				spawn = function()
					return {
						terminate = function()
							terminated = true
						end,
						detach = function() end,
						poll = function() end,
					}
				end,
			},
		})
		p.start(model(), "/crier", { files = {}, args = {}, needs_secrets = { "key" } })
		p.detach()
		callback({})
		assert.is_true(terminated)
		assert.equal("checking…", p.rows()[2].message)
	end)
end)
