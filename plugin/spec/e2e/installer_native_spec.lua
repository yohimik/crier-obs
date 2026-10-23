local ffi = require("ffi")
local obs = require("obslua")
local fs_module = require("crier_obs.ports.fs")
local spawner_module = require("crier_obs.proc.spawner")
local resolver_module = require("crier_obs.proc.resolver")
local installer_module = require("crier_obs.invoke.installer")
ffi.cdef(
	"int setenv(const char*,const char*,int); int unsetenv(const char*); char* getcwd(char*,unsigned long); int usleep(unsigned int);"
)
describe("official installer integration #posix", function()
	it("runs the pinned installer through a local curl URL and refreshes discovery after success", function()
		local current = ffi.string(ffi.C.getcwd(ffi.new("char[4096]"), 4096))
		local fakes = current .. (current:match("/plugin$") and "/spec/fakes" or "/plugin/spec/fakes")
		local state = os.tmpname()
		os.remove(state)
		local fs = fs_module.new({ obs = obs })
		assert(fs.mkdir(state))
		ffi.C.setenv("FAKE_INSTALL_SOURCE", fakes .. "/crier", 1)
		local spawner = spawner_module.new({ fs = fs })
		local resolver = resolver_module.new({ fs = fs, spawner = spawner, pin = "1.1.1", state_dir = state })
		local installer = installer_module.new({
			spawner = spawner,
			resolver = resolver,
			fs = fs,
			env = { os = "OSX" },
			pin = "1.1.1",
			state_dir = state,
			url = "file://" .. fakes .. "/install.sh",
		})
		assert(installer.start())
		local result
		for _ = 1, 500 do
			result = installer.tick()
			if result.state ~= "installing" then
				break
			end
			ffi.C.usleep(2000)
		end
		assert.equal("installed", result.state)
		assert.equal(state .. "/bin/crier", resolver.status().path)
		assert.equal("1.1.1", resolver.status().version)
		ffi.C.setenv("FAKE_INSTALL_FAIL", "1", 1)
		assert(installer.start())
		for _ = 1, 500 do
			result = installer.tick()
			if result.state ~= "installing" then
				break
			end
			ffi.C.usleep(2000)
		end
		ffi.C.unsetenv("FAKE_INSTALL_SOURCE")
		ffi.C.unsetenv("FAKE_INSTALL_FAIL")
		assert.equal("failed", result.state)
		assert.is_truthy(result.message:find("digest mismatch", 1, true))
	end)
end)
