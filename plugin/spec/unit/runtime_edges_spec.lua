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
		cancel = function()
			return true
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
		result.cancel = function()
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
			pin = "1.1.1",
		})
		assert.is_nil(missing.probe())
		assert.equal("missing", missing.status().state)
		local failed = resolver_module.new({
			fs = fs,
			pin = "1.1.1",
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
			status = function()
				return status
			end,
		}
		local installer = installer_module.new({
			state_dir = "/state",
			pin = "1.1.1",
			log = log,
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
				log = log,
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
			log = log,
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
		assert.equal("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", plans[1].executable)
		assert.equal("-NoProfile", plans[1].args[1])
		local invalid = installer_module.new({ state_dir = "/state", pin = "bad", env = {}, log = log })
		assert.is_nil(invalid.start())
		local failure = installer_module.new({
			state_dir = "/state",
			pin = "1.1.1",
			log = log,
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
			pin = "1.1.1",
			log = log,
			env = {},
			spawner = {
				spawn = function()
					return {
						poll = function() end,
						cancel = function()
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
							cancel = function()
								return true
							end,
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
						cancel = function()
							return true
						end,
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

	it("never adopts a run journaled before a reboot, and journals it as finished", function()
		local fs, files = memoryfs()
		local paths = {
			root = "/state",
			runs = "/state/runs",
			bin = "/state/bin",
			templates = "/state/templates",
			template = "/state/templates/live.html",
			secrets = "/state/secrets",
		}
		local clock = {
			now_wall = function()
				return 50
			end,
		}
		local before = runs_module.new({ fs = fs, clock = clock, paths = paths, pid = 7, boot_id = "boot-a" })
		assert(before.init())
		local run = assert(before.create("start"))
		assert(before.journal(run, { state = "detached", pid = 4242 }))
		assert.equal("boot-a", require("crier_obs.json").decode(files[run.journal]).boot_id)
		local same = runs_module.new({ fs = fs, clock = clock, paths = paths, pid = 8, boot_id = "boot-a" })
		assert.equal(1, #same.adopt())
		local after = runs_module.new({ fs = fs, clock = clock, paths = paths, pid = 7, boot_id = "boot-b" })
		assert.same({}, after.adopt())
		local journal = require("crier_obs.json").decode(files[run.journal])
		assert.equal("failed", journal.state)
		assert.matches("result is unknown", journal.error, 1, true)
		after.sweep(7, 0)
		assert.is_nil(files[run.journal])
		local unknown = runs_module.new({ fs = fs, clock = clock, paths = paths, pid = 9 })
		local other = assert(unknown.create("end"))
		assert(unknown.journal(other, { state = "detached", pid = 4343 }))
		assert.equal(
			1,
			#runs_module.new({ fs = fs, clock = clock, paths = paths, pid = 9, boot_id = "boot-c" }).adopt()
		)
		assert.has_error(function()
			runs_module.new({ fs = fs, clock = clock, paths = paths })
		end)
	end)
	it("identifies this boot on macOS and Linux #posix", function()
		local id = require("crier_obs.ports.env").new({}).boot_id()
		assert.is_string(id)
		assert.equal(id, require("crier_obs.ports.env").new({}).boot_id())
		assert.is_nil(require("crier_obs.ports.env").new({ platform = "Windows" }).boot_id())
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
local native_env = {
	sandbox_status = function()
		return { kind = "native", ok = true }
	end,
}
describe("setup error rows", function()
	it("reports Flatpak tools, config errors and failed keyring lookup", function()
		local rows
		local p = ping_module.new({
			env = {
				sandbox_status = function()
					return { kind = "flatpak", ok = false, message = "flatpak-spawn is missing" }
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
		assert.equal("flatpak", rows[4].target)
		assert.is_false(rows[4].ok)
		p = ping_module.new({
			env = native_env,
			find_binary = function() end,
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
				backend_status = function()
					return { state = "ready", label = "macOS Keychain" }
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
	it("turns crier platforms problems other than credentials into warning rows", function()
		local rows
		local outputs = {
			platforms = '[{"name":"telegram","enabled":true,"ready":false,"problem":"publish.telegram: publish.telegram.token is required"},'
				.. '{"name":"discord","enabled":true,"ready":false,"problem":"publish.discord: publish.discord.channel-id is required"},'
				.. '{"name":"vk","enabled":false,"ready":false,"problem":"publish.vk: publish.vk.owner-id is required"},'
				.. '{"name":"x","enabled":true,"ready":true}]',
			ping = '{"results":[{"target":"telegram","ok":true,"account":"@bot","ms":5}]}',
		}
		local spawned = {}
		local p = ping_module.new({
			env = native_env,
			find_binary = function() end,
			fs = {
				write = function()
					return true
				end,
			},
			log = log,
			runs = {
				finish = function()
					return true
				end,
			},
			secrets = {
				resolve = function(_, _, cb)
					cb({ ["publish.telegram.token"] = "TOKEN" })
				end,
				backend_status = function()
					return { state = "ready", label = "macOS Keychain" }
				end,
			},
			spawner = {
				spawn = function(plan)
					spawned[#spawned + 1] = plan
					return finished(0, outputs[plan.args[1]])
				end,
			},
		})
		assert(
			p.start(
				model(),
				"/crier",
				{ files = {}, args = { "--config", "/run/config.json" }, needs_secrets = {}, run = {} }
			)
		)
		rows = p.tick()
		assert.same({ "platforms", "--json", "--config", "/run/config.json" }, spawned[1].args)
		assert.is_nil(spawned[1].env.CRIER_PUBLISH_TELEGRAM_TOKEN)
		assert.same({ "ping", "--json", "--config", "/run/config.json" }, spawned[2].args)
		assert.equal("TOKEN", spawned[2].env.CRIER_PUBLISH_TELEGRAM_TOKEN)
		local by_target = {}
		for _, row in ipairs(rows) do
			by_target[row.target] = by_target[row.target] or {}
			table.insert(by_target[row.target], row)
		end
		assert.equal("macOS Keychain", by_target.keyring[1].message)
		assert.equal(1, #by_target.discord)
		assert.is_true(by_target.discord[1].warning)
		assert.equal("publish.discord: publish.discord.channel-id is required", by_target.discord[1].message)
		assert.is_nil(by_target.vk)
		assert.equal(1, #by_target.telegram)
		assert.is_true(by_target.telegram[1].ok)
	end)
	it("ignores a stale lookup callback after detachment", function()
		local callback
		local terminated = false
		local p = ping_module.new({
			env = native_env,
			find_binary = function() end,
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
						cancel = function()
							terminated = true
						end,
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
