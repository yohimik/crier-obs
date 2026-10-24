local ffi = require("ffi")
local bit = require("bit")
local fs_module = require("crier_obs.ports.fs")
local consts = require("crier_obs.proc.consts")
local lock_module = require("crier_obs.secrets.lock")

-- A directory stream that hands out records in the layout of the symbols it is reached through.
local function directory_C(names, layout)
	local calls = {}
	local C = {}
	local function stream(kind)
		return function()
			calls[#calls + 1] = kind .. "opendir"
			local at = 0
			local records = {}
			for i, name in ipairs(names) do
				local record = ffi.new(layout)
				ffi.copy(record.name, name)
				records[i] = record
			end
			return {
				next = function()
					at = at + 1
					return records[at]
				end,
				records = records,
			}
		end
	end
	local function reader(kind)
		return function(dir)
			calls[#calls + 1] = kind .. "readdir"
			local record = dir.next()
			return record and ffi.cast("void*", record) or nil
		end
	end
	C.opendir, C.readdir = stream("plain "), reader("plain ")
	C.cobs_opendir_inode64, C.cobs_readdir_inode64 = stream("inode64 "), reader("inode64 ")
	C.closedir = function()
		calls[#calls + 1] = "closedir"
		return 0
	end
	return C, calls
end

describe("native ABI selection", function()
	it("reads Intel macOS directories through the 64-bit-inode symbols and arm64 through the plain ones", function()
		local names = { ".", "..", "1700000000-42-1", "queued.json", "名字 🔴" }
		for _, case in ipairs({
			{ "OSX", "x64", "inode64 ", "cobs_dirent_darwin" },
			{ "OSX", "arm64", "plain ", "cobs_dirent_darwin" },
			{ "Linux", "x64", "plain ", "cobs_dirent_linux" },
			{ "Linux", "arm64", "plain ", "cobs_dirent_linux" },
		}) do
			local C, calls = directory_C(names, case[4])
			local fs = fs_module.new({ obs = {}, C = C, platform = case[1], arch = case[2] })
			assert.same({ "/runs/1700000000-42-1", "/runs/queued.json", "/runs/名字 🔴" }, fs.glob("/runs/*"))
			assert.equal(case[3] .. "opendir", calls[1])
			assert.equal(case[3] .. "readdir", calls[2])
			assert.equal("closedir", calls[#calls])
		end
	end)

	it("returns this host's directory names byte for byte #posix", function()
		local obs = require("obslua")
		local fs = fs_module.new({ obs = obs })
		local root = os.tmpname()
		os.remove(root)
		assert(fs.mkdir(root))
		local names = { "a", "1700000000-4242-17", string.rep("long-name-", 20), "pañuelo 🔴", "with space" }
		for _, name in ipairs(names) do
			assert(fs.write(root .. "/" .. name, name))
		end
		local expected = {}
		for _, name in ipairs(names) do
			expected[#expected + 1] = root .. "/" .. name
		end
		table.sort(expected)
		assert.same(expected, fs.glob(root .. "/*"))
		assert.same({ root .. "/a" }, fs.glob(root .. "/a"))
		for _, name in ipairs(names) do
			fs.remove(root .. "/" .. name)
		end
		fs.rmdir(root)
	end)

	it("secures private directories with the open flags of each architecture", function()
		local expected = {
			{ "OSX", "arm64", 0x100000 + 0x100 },
			{ "OSX", "x64", 0x100000 + 0x100 },
			{ "Linux", "x64", 0x10000 + 0x20000 },
			{ "Linux", "x86", 0x10000 + 0x20000 },
			{ "Linux", "arm64", 0x4000 + 0x8000 },
			{ "Linux", "arm", 0x4000 + 0x8000 },
			{ "Linux", "ppc", 0x4000 + 0x8000 },
			{ "Linux", "mips64el", 0x10000 + 0x20000 },
		}
		for _, case in ipairs(expected) do
			local opened
			local C = {
				open = function(_, flags)
					opened = flags
					return 7
				end,
				fchmod = function(_, mode)
					assert.equal(448, mode)
					return 0
				end,
				close = function()
					return 0
				end,
			}
			local obs = {
				os_mkdirs = function()
					return 0
				end,
			}
			local fs = fs_module.new({ obs = obs, C = C, platform = case[1], arch = case[2] })
			assert(fs.mkdir_private("/state/secrets"))
			assert.equal(case[3], opened, case[1] .. "/" .. case[2])
		end
	end)

	it("opens the credential index lock without following links on every architecture", function()
		for _, case in ipairs({
			{ "Linux", "arm64", 2 + 0x40 + 0x8000 },
			{ "Linux", "x64", 2 + 0x40 + 0x20000 },
			{ "Linux", "mips", 2 + 0x100 + 0x20000 },
			{ "OSX", "arm64", 2 + 0x200 + 0x100 },
		}) do
			local opened, locks = nil, {}
			local C = {
				open = function(_, flags, mode)
					opened = flags
					assert.equal(384, tonumber(mode))
					return 5
				end,
				flock = function(_, operation)
					locks[#locks + 1] = operation
					return 0
				end,
				close = function()
					return 0
				end,
			}
			local locked = lock_module.new({ state_dir = "/state", platform = case[1], arch = case[2], lock_C = C })
			assert.is_true(locked(function()
				return true
			end))
			assert.equal(case[3], opened)
			assert.same({ bit.bor(2, 4), 8 }, locks)
		end
	end)

	it("keeps the platform constants apart", function()
		local darwin, linux, arm, mips =
			consts.of("OSX", "arm64"),
			consts.of("Linux", "x64"),
			consts.of("Linux", "arm64"),
			consts.of("Linux", "mipsel")
		assert.equal(35, darwin.EAGAIN)
		assert.equal(11, linux.EAGAIN)
		assert.equal(4, darwin.O_NONBLOCK)
		assert.equal(0x800, linux.O_NONBLOCK)
		assert.equal(0x80, mips.O_NONBLOCK)
		assert.equal(1, darwin.SIG_BLOCK)
		assert.equal(0, linux.SIG_BLOCK)
		assert.equal(1, mips.SIG_BLOCK)
		assert.equal(0x4000, arm.O_DIRECTORY)
		assert.equal(linux, consts.of("Linux", "x64"))
		assert.equal(consts.of(ffi.os, ffi.arch), consts.of())
	end)
end)
