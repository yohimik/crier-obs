local ffi = require("ffi")
local posix = require("crier_obs.proc.posix")
local spawner = require("crier_obs.proc.spawner")
local pipes = require("crier_obs.proc.pipes")
local function fake(options)
	options = options or {}
	local actions, closed, signals = {}, 0, {}
	local status = options.status or { 0 }
	local index = 0
	local reads = 0
	local C = {
		fcntl = function()
			return 0
		end,
		close = function()
			closed = closed + 1
			return 0
		end,
		posix_spawn_file_actions_init = function()
			return options.init or 0
		end,
		posix_spawn_file_actions_destroy = function()
			return 0
		end,
		posix_spawn_file_actions_addinherit_np = function(_, fd)
			actions[#actions + 1] = { "inherit", fd }
			return options.action or 0
		end,
		posix_spawn_file_actions_adddup2 = function(_, a, b)
			actions[#actions + 1] = { "dup", a, b }
			return 0
		end,
		posix_spawn_file_actions_addclose = function(_, fd)
			actions[#actions + 1] = { "close", fd }
			return 0
		end,
		posix_spawnattr_init = function()
			return options.attr or 0
		end,
		posix_spawnattr_destroy = function()
			return 0
		end,
		posix_spawnattr_setpgroup = function()
			return 0
		end,
		posix_spawnattr_setflags = function()
			return 0
		end,
		posix_spawnp = function(pid)
			pid[0] = 123
			return options.spawn or 0
		end,
		waitpid = function(_, out)
			index = index + 1
			local item = status[math.min(index, #status)]
			if type(item) == "table" then
				ffi.errno(item.errno)
				return -1
			end
			out[0] = item
			return item == false and 0 or 123
		end,
		kill = function(pid, signal)
			signals[#signals + 1] = { pid, signal }
			if options.dead then
				ffi.errno(3)
				return -1
			end
			return 0
		end,
		dirfd = function()
			return 99
		end,
		closedir = function()
			return 0
		end,
		opendir = function()
			if options.no_dir then
				return nil
			end
			return ffi.cast("void*", 1)
		end,
		readdir = function()
			reads = reads + 1
			if reads > 1 then
				return nil
			end
			local b = ffi.new("char[256]")
			ffi.copy(b + 19, "7")
			options.entry = b
			return b
		end,
	}
	if options.closefrom then
		C.posix_spawn_file_actions_addclosefrom_np = function(_, fd)
			actions[#actions + 1] = { "closefrom", fd }
			return 0
		end
	else
		setmetatable(C, {
			__index = function(_, k)
				if k == "posix_spawn_file_actions_addclosefrom_np" then
					assert(false, "missing symbol")
				end
			end,
		})
	end
	return C, actions, signals
end
describe("POSIX native API failure contracts #posix", function()
	it("validates inputs and reports native setup failures without spawning", function()
		local p = posix.new({ C = fake(), platform = "OSX" })
		assert.is_nil(p.spawn({ executable = "" }))
		assert.is_nil(p.spawn({ executable = "/bin/crier", env = { ["bad=name"] = "x" } }))
		assert.is_nil(p.spawn({ executable = "/bin/crier", args = { "NUL\0" } }))
		assert.is_nil(p.spawn({ executable = "/bin/crier", env = { KEY = "NUL\0" } }))
		for _, options in ipairs({ { init = 12 }, { attr = 12 }, { action = 9 }, { spawn = 2 } }) do
			local native = posix.new({ C = fake(options), platform = "OSX" })
			local value, e = native.spawn({ executable = "/bin/crier" })
			assert.is_nil(value)
			assert.is_truthy(e.message:find("errno", 1, true))
		end
	end)
	it("uses atomic Linux closefrom or fails closed on unsupported libc", function()
		local C, actions = fake({ closefrom = true })
		local p = posix.new({ C = C, platform = "Linux" })
		assert(p.spawn({ executable = "/bin/crier" }))
		assert.equal("closefrom", actions[1][1])
		assert.equal(3, actions[1][2])
		C = fake({})
		p = posix.new({ C = C, platform = "Linux" })
		local child, e = p.spawn({ executable = "/bin/crier" })
		assert.is_nil(child)
		assert.equal(95, e.errno)
	end)
	it("closes every listed descriptor above the standard streams when the libc has no closefrom", function()
		for _, directory in ipairs({ "/proc/self/fd", "/dev/fd" }) do
			local C, actions = fake({})
			local globbed = {}
			local fs = {
				glob = function(pattern)
					globbed[#globbed + 1] = pattern
					if pattern ~= directory .. "/*" then
						return {}
					end
					local out = {}
					for _, fd in ipairs({ 0, 1, 2, 3, 9, 12, 31 }) do
						out[#out + 1] = directory .. "/" .. fd
					end
					return out
				end,
			}
			local p = posix.new({ C = C, platform = "Linux", fs = fs })
			assert(p.spawn({ executable = "/bin/crier" }))
			local closed = {}
			for _, a in ipairs(actions) do
				if a[1] == "close" then
					closed[#closed + 1] = a[2]
				end
			end
			assert.same({ 3, 9, 12, 31 }, closed)
			assert.equal("/proc/self/fd/*", globbed[1])
		end
	end)
	it("reads the child pid only when a record needs it, never on every heartbeat", function()
		local reads = {}
		local fs = {
			read = function(path)
				reads[path] = (reads[path] or 0) + 1
				return path == "/run/pid" and "124" or nil
			end,
		}
		local p = posix.new({ C = fake({ status = { false } }), platform = "OSX", fs = fs })
		local child = assert(p.spawn({ executable = "/bin/crier", pid_path = "/run/pid", status_path = "/run/status" }))
		for _ = 1, 20 do
			assert.is_nil(child.poll())
		end
		assert.is_nil(reads["/run/pid"])
		local record = assert(child.detach())
		assert.equal(124, record.child_pid)
		assert.equal(1, reads["/run/pid"])
	end)
	it("never leaves argument or environment bytes in memory when spawning fails before the call", function()
		local allocated = {}
		local original = ffi.new
		ffi.new = function(ct, ...)
			local value = original(ct, ...)
			if ct == "char[?]" then
				allocated[#allocated + 1] = value
			end
			return value
		end
		local ok, err = pcall(function()
			for _, options in ipairs({ { init = 12 }, { attr = 12 }, { action = 9 }, { spawn = 2 } }) do
				allocated = {}
				local native = posix.new({ C = fake(options), platform = "OSX" })
				assert.is_nil(
					native.spawn({ executable = "/bin/crier", env = { CRIER_PUBLISH_X_TOKEN = "TOPSECRET" } })
				)
				for _, buffer in ipairs(allocated) do
					assert.is_nil(ffi.string(buffer, ffi.sizeof(buffer)):find("TOPSECRET", 1, true))
				end
			end
		end)
		ffi.new = original
		assert(ok, err)
	end)
	it("handles EINTR, native poll failure, ECHILD status adoption and signals", function()
		local p = posix.new({ C = fake({ status = { { errno = 4 }, { errno = 22 } } }), platform = "OSX" })
		local child = assert(p.spawn({ executable = "/bin/crier" }))
		assert.is_nil(child.poll())
		local r, e = child.poll()
		assert.is_nil(r)
		assert.equal(22, e.errno)
		p = posix.new({
			C = fake({ status = { { errno = 10 } } }),
			platform = "OSX",
			fs = {
				read = function()
					return "6"
				end,
			},
		})
		child = assert(p.spawn({ executable = "/bin/crier", status_path = "/status" }))
		assert.equal(6, child.poll().code)
		assert.equal(6, child.poll().code)
		p = posix.new({ C = fake({ status = { 9 } }), platform = "OSX" })
		child = assert(p.spawn({ executable = "/bin/crier" }))
		assert.equal(9, child.poll().signal)
		p = posix.new({ C = fake({ status = { { errno = 10 } }, dead = true }), platform = "OSX" })
		child = assert(p.spawn({ executable = "/bin/crier" }))
		assert.equal(1, child.poll().code)
	end)
	it("adopts unavailable children, forwards adopted signals and cancels native direct jobs", function()
		local C, _, signals = fake({ status = { { errno = 10 } }, dead = true })
		local p = posix.new({ C = C, platform = "OSX" })
		local record = { pid = 123, child_pid = 124 }
		local adopted = p.adopt(record)
		assert.equal(1, adopted.poll().code)
		assert.equal(1, adopted.poll().code)
		adopted.terminate()
		adopted.kill()
		assert.equal(record, adopted.detach())
		assert.is_true(#signals >= 1)
		local native = posix.new({})
		local child =
			assert(native.spawn({ executable = "/bin/sleep", args = { "1" }, kind = "keyring", capture_stdout = true }))
		assert(child.cancel())
	end)
	it("propagates backend spawn/poll failures and supports an unsupported-adoption boundary", function()
		local s = spawner.new({
			env = {
				path = "/plain",
				inherited = function()
					return {}
				end,
			},
			backend = {
				spawn = function()
					return nil, { kind = "spawn", message = "failed" }
				end,
			},
		})
		assert.is_nil(s.spawn({ executable = "/crier" }))
		assert.is_nil(s.adopt({}))
		s = spawner.new({
			env = {
				inherited = function()
					return {}
				end,
			},
			backend = {
				spawn = function()
					return {
						poll = function()
							return nil, { kind = "poll", message = "failed" }
						end,
						terminate = function() end,
						kill = function() end,
					}
				end,
				adopt = function()
					return { pid = 1 }
				end,
			},
		})
		assert.equal(1, s.adopt({}).pid)
		local p = assert(s.spawn({ executable = "/crier" }))
		local r, e = p.poll()
		assert.is_nil(r)
		assert.equal("poll", e.kind)
	end)
	it("feeds and closes a real nonblocking pipe and reports invalid read descriptors", function()
		local pool = pipes.new({})
		local p = assert(pool.open())
		assert(p.feed("value"))
		assert.equal("value", p.read())
		p.close_write()
		assert(p.flush())
		assert.equal("", p.read())
		p.close()
		p = assert(pool.open())
		ffi.C.close(p.read_fd)
		local value, e = p.read()
		assert.is_nil(value)
		assert.equal("pipe", e.kind)
		p.read_fd = nil
		p.close()
		local broken = pipes.new({ C = {
			pipe = function()
				ffi.errno(24)
				return -1
			end,
		} })
		assert.is_nil(broken.open())
		broken = pipes.new({
			C = {
				pipe = function(fds)
					fds[0] = 1
					fds[1] = 2
					return 0
				end,
				fcntl = function()
					return -1
				end,
				close = function() end,
			},
		})
		assert.is_nil(broken.open())
	end)
end)
