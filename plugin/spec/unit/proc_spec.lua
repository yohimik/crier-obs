package.path = "plugin/src/?.lua;" .. package.path
local ffi = require("ffi")
local utf16 = require("crier_obs.utf16")
local quote = require("crier_obs.proc.cmdline_windows")
local posix = require("crier_obs.proc.posix")
local spawner = require("crier_obs.proc.spawner")
local resolver = require("crier_obs.proc.resolver")
ffi.cdef(
	[[int usleep(unsigned int); char *getcwd(char*,unsigned long);
int open(const char*,int,...); int mkdir(const char*,unsigned int); int rmdir(const char*);]]
)
local function wait(p)
	for _ = 1, 2000 do
		local r, e = p.poll()
		assert.is_nil(e)
		if r then
			return r
		end
		ffi.C.usleep(1000)
	end
	p.kill()
	assert(false, "process did not finish")
end
local function read(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local d = f:read("*a")
	f:close()
	return d
end
local fs = {
	read = read,
	exists = function(path)
		local f = io.open(path, "rb")
		if f then
			f:close()
			return true
		end
		return false
	end,
}
local cwd = ffi.os == "Windows" and "." or ffi.string(ffi.C.getcwd(ffi.new("char[4096]"), 4096))
local fake_path = fs.exists(cwd .. "/plugin/spec/fakes/crier") and cwd .. "/plugin/spec/fakes/crier"
	or cwd .. "/spec/fakes/crier"
describe("UTF-16 and Windows command construction", function()
	it("round-trips Unicode including non-BMP captions and rejects malformed encodings", function()
		local text = "Live 🔴 привет 日本語"
		assert.equal(text, utf16.decode(assert(utf16.encode(text))))
		assert.is_nil(utf16.encode("\192\128"))
		assert.is_nil(utf16.encode("\237\160\128"))
		assert.is_nil(utf16.decode("\0\216"))
	end)
	it("quotes empty strings, embedded quotes and trailing slashes", function()
		assert.equal('""', quote.quote(""))
		assert.equal("plain", quote.quote("plain"))
		assert.equal('"a b\\\\"', quote.quote("a b\\"))
		assert.equal('"a\\"b"', quote.quote('a"b'))
		local bytes = assert(quote.environment({ Z = "🔴", A = "one", ["=C:"] = "C:\\" }))
		assert.equal("=C:=C:\\\0A=one\0Z=🔴\0\0", utf16.decode(bytes))
	end)
	it("compares prerelease identifiers numerically", function()
		assert.equal(-1, resolver.compare("1.1.0-rc.9", "1.1.0-rc.10"))
		assert.equal(1, resolver.compare("1.1.0", "1.1.0-rc.10"))
		assert.equal(0, resolver.compare("v1.1.1+build", "1.1.1"))
	end)
end)
describe("native POSIX process isolation #posix", function()
	local native = posix.new({
		fs = fs,
		before_spawn = function()
			collectgarbage()
			collectgarbage()
			local junk = {}
			for i = 1, 3000 do
				junk[i] = string.rep("z", 100)
			end
			assert.equal(3000, #junk)
		end,
	})
	it("anchors environment and arguments across collection, strips wrapper env, and preserves cwd", function()
		local env = posix.inherited()
		env.VALUE = 'token " ☺'
		local args = { "-c", 'printf "%s|%s|%s" "$VALUE" "$PWD" "${COBS_CWD-unset}"' }
		local p = assert(native.spawn({
			executable = "/bin/sh",
			args = args,
			env = env,
			cwd = "/tmp",
			capture_stdout = true,
			capture_stderr = true,
		}))
		local r = wait(p)
		assert.equal(0, r.code)
		assert.equal('token " ☺|/tmp|unset', r.stdout)
	end)
	it("pumps stdin larger than pipe capacity and captures all output", function()
		local data = string.rep("secret 🔴\n", 20000)
		local p = assert(native.spawn({
			executable = "/bin/cat",
			env = posix.inherited(),
			stdin_data = data,
			capture_stdout = true,
			capture_stderr = true,
		}))
		local r = wait(p)
		assert.equal(0, r.code)
		assert.equal(data, r.stdout)
	end)
	it("survives writes after the reader exits", function()
		local p = assert(native.spawn({
			executable = "/usr/bin/true",
			env = posix.inherited(),
			stdin_data = string.rep("x", 200000),
			capture_stdout = true,
			capture_stderr = true,
		}))
		assert.equal(0, wait(p).code)
	end)
	it("reports every crier exit category plus missing and non-executable commands", function()
		for _, code in ipairs({ 0, 1, 2, 3, 4, 5, 6, 97, 126, 127 }) do
			local p = assert(native.spawn({
				executable = "/bin/sh",
				args = { "-c", "exit " .. code },
				env = posix.inherited(),
				capture_stderr = true,
			}))
			assert.equal(code, wait(p).code)
		end
		local p =
			assert(native.spawn({ executable = "/nonexistent/crier", env = posix.inherited(), capture_stderr = true }))
		assert.equal(127, wait(p).code)
	end)
	it("closes inherited descriptors beyond standard streams", function()
		local fd = ffi.C.open("/dev/null", 0)
		assert.is_true(fd > 2)
		local p = assert(native.spawn({
			executable = "/bin/sh",
			args = { "-c", "if test -e /dev/fd/" .. fd .. "; then exit 77; fi" },
			env = posix.inherited(),
		}))
		assert.equal(0, wait(p).code)
		ffi.C.close(fd)
	end)
	it("removes inherited CRIER credentials from probes and overlays explicit job credentials", function()
		local s = spawner.new({
			fs = fs,
			env = {
				inherited = function()
					return { PATH = "/usr/bin:/bin", CRIER_TOKEN = "inherited", CRIER_SECRET = "bad" }
				end,
			},
		})
		local p = assert(s.spawn({
			executable = "/bin/sh",
			args = { "-c", 'printf "%s/%s" "${CRIER_TOKEN-unset}" "${CRIER_SECRET-unset}"' },
			env = { CRIER_TOKEN = "stored" },
			capture_stdout = true,
		}))
		assert.equal("stored/unset", wait(p).stdout)
	end)
	it("reads crier version through its asynchronous probe", function()
		local s = spawner.new({ fs = fs })
		local r = resolver.new({ fs = fs, spawner = s, pin = "1.1.1" })
		assert(r.probe(fake_path))
		for _ = 1, 2000 do
			local status = r.tick()
			if status.state ~= "checking" then
				assert.equal("ready", status.state)
				assert.equal("1.1.1", status.version)
				return
			end
			ffi.C.usleep(1000)
		end
		assert(false, "probe did not finish")
	end)
	it("hands captured output to discard drainers at detach and adopts its exit status", function()
		local dir = os.tmpname()
		os.remove(dir)
		assert.equal(0, ffi.C.mkdir(dir, 448))
		local p = assert(native.spawn({
			executable = "/bin/sh",
			args = { "-c", "sleep .03; dd if=/dev/zero bs=4096 count=100 2>/dev/null; exit 6" },
			env = posix.inherited(),
			capture_stdout = true,
			capture_stderr = true,
			status_path = dir .. "/status",
			pid_path = dir .. "/pid",
		}))
		local record = assert(p.detach())
		assert.equal(2, #record.drainers)
		local adopted = assert(native.adopt(record))
		assert.equal(6, wait(adopted).code)
		for _, drainer in ipairs(record.drainers) do
			assert.equal(0, wait(assert(native.adopt(drainer))).code)
		end
		os.remove(dir .. "/status")
		os.remove(dir .. "/pid")
		ffi.C.rmdir(dir)
	end)
	it("preserves the child own exit code after forwarding TERM", function()
		local dir = os.tmpname()
		os.remove(dir)
		ffi.C.mkdir(dir, 448)
		local p = assert(native.spawn({
			executable = "/bin/sh",
			args = { "-c", "trap 'exit 6' TERM; while :; do :; done" },
			env = posix.inherited(),
			status_path = dir .. "/status",
			pid_path = dir .. "/pid",
		}))
		for _ = 1, 100 do
			p.poll()
			if fs.exists(dir .. "/pid") then
				break
			end
			ffi.C.usleep(1000)
		end
		ffi.C.usleep(10000)
		assert.is_true(p.terminate())
		assert.equal(6, wait(p).code)
		os.remove(dir .. "/status")
		os.remove(dir .. "/pid")
		ffi.C.rmdir(dir)
	end)
	it("escalates a timed out child that ignores TERM without blocking the caller", function()
		local time = 0
		local dir = os.tmpname()
		os.remove(dir)
		ffi.C.mkdir(dir, 448)
		local s = spawner.new({ fs = fs, clock = {
			now_mono = function()
				return time
			end,
		} })
		local p = assert(s.spawn({
			executable = "/bin/sh",
			args = { "-c", "trap '' TERM; while :; do :; done" },
			env = {},
			status_path = dir .. "/status",
			pid_path = dir .. "/pid",
			timeout = 1,
			kill_grace = 0.01,
		}))
		for _ = 1, 100 do
			p.poll()
			if fs.exists(dir .. "/pid") then
				break
			end
			ffi.C.usleep(1000)
		end
		ffi.C.usleep(10000)
		time = 2
		p.poll()
		time = 3
		p.poll()
		local r = wait(p)
		assert.is_true(r.timed_out)
		assert.equal(137, r.code)
		os.remove(dir .. "/status")
		os.remove(dir .. "/pid")
		ffi.C.rmdir(dir)
	end)
	it("transports host secrets on a dedicated fd while keeping stdin independent", function()
		local p = assert(native.spawn({
			executable = "/bin/sh",
			args = { "-c", "cat <&3; printf '|stdin:'; cat" },
			stdin_data = "keyring-input",
			env_fd_data = "A=host-secret\0Z=🔴\0",
			capture_stdout = true,
			capture_stderr = true,
		}))
		local r = wait(p)
		assert.equal(0, r.code)
		assert.equal("A=host-secret\0Z=🔴\0|stdin:keyring-input", r.stdout)
		for _ = 1, 10 do
			native.reap()
			ffi.C.usleep(1000)
		end
	end)
end)
