local ffi = require("ffi")
local macos = require("crier_obs.secrets.keyring.macos")
local linux = require("crier_obs.secrets.keyring.linux")
local windows = require("crier_obs.secrets.keyring.windows")
local null = require("crier_obs.secrets.keyring.null")
local json = require("crier_obs.json")
local function run_backend(factory, answer, operation, value)
	local plans = {}
	local b = factory.new({
		state_dir = "/state",
		spawner = {
			spawn = function(plan)
				plans[#plans + 1] = plan
				return {
					poll = function()
						return answer
					end,
				}
			end,
		},
	})
	local result, err
	if operation == "store" then
		b.store("default/publish.telegram.token", value, function(v, e)
			result, err = v, e
		end)
	else
		b[operation]("default/publish.telegram.token", function(v, e)
			result, err = v, e
		end)
	end
	b.tick()
	return result, err, plans[1]
end
describe("credential keyrings", function()
	it("sends macOS passwords only as stdin hex and maps locked keychains", function()
		local secret = 'spaces "quotes" \\ slashes 😀'
		local ok, err, plan = run_backend(macos, { code = 0 }, "store", secret)
		assert.is_true(ok)
		assert.is_nil(err)
		assert.same({ "-i" }, plan.args)
		assert.is_nil(table.concat(plan.args):find(secret, 1, true))
		assert.equal("keyring", plan.kind)
		assert.equal(60, plan.timeout)
		assert.is_truthy(plan.stdin_data:find("737061636573", 1, true))
		assert.is_nil(plan.stdin_data:find(secret, 1, true))
		local _, locked =
			run_backend(macos, { code = 36, stderr = "User interaction is not allowed; keychain locked" }, "lookup")
		assert.equal("unavailable", locked.kind)
		assert.is_truthy(locked.message:find("locked"))
		local missing, missing_err = run_backend(macos, { code = 0, stdout = "" }, "lookup")
		assert.is_nil(missing)
		assert.equal("missing", missing_err.kind)
		local v = run_backend(macos, { code = 0, stdout = secret .. "\n" }, "lookup")
		assert.equal(secret, v)
		local forgotten = run_backend(macos, { code = 44 }, "forget")
		assert.is_true(forgotten)
	end)
	it("handles Secret Service lookup, store, forget and timeout without secret argv", function()
		local ok, _, plan = run_backend(linux, { code = 0 }, "store", "secret")
		assert.is_true(ok)
		assert.equal("secret", plan.stdin_data)
		assert.is_nil(table.concat(plan.args):find("secret", 1, true))
		local value = run_backend(linux, { code = 0, stdout = "secret\n" }, "lookup")
		assert.equal("secret", value)
		local forgotten = run_backend(linux, { code = 1 }, "forget")
		assert.is_true(forgotten)
		local _, err = run_backend(linux, { code = 0, timed_out = true }, "lookup")
		assert.equal("unavailable", err.kind)
	end)
	it("cancels active pipe jobs on close without late callbacks", function()
		local cancelled, called = 0, false
		local b = macos.new({
			spawner = {
				spawn = function()
					return {
						poll = function()
							return nil
						end,
						cancel = function()
							cancelled = cancelled + 1
						end,
					}
				end,
			},
		})
		b.lookup("account", function()
			called = true
		end)
		b.close()
		b.tick()
		assert.equal(1, cancelled)
		assert.is_false(called)
	end)
	it("maps generic failures and cancels pending processes on close without callbacks", function()
		local _, err = run_backend(macos, { code = 7, stderr = "unavailable" }, "lookup")
		assert.equal("unavailable", err.kind)
		local cancelled = 0
		local b = macos.new({
			spawner = {
				spawn = function()
					return {
						poll = function()
							return nil
						end,
						cancel = function()
							cancelled = cancelled + 1
							return true
						end,
					}
				end,
			},
		})
		b.lookup("account", function()
			assert.is_true(false)
		end)
		b.tick()
		b.close()
		b.tick()
		assert.equal(1, cancelled)
	end)
	it("leaves Flatpak host wrapping to the shared spawner", function()
		local plan
		local b = linux.new({
			env = {
				flatpak = function()
					return true
				end,
			},
			spawner = {
				spawn = function(p)
					plan = p
					return {
						poll = function()
							return { code = 1 }
						end,
					}
				end,
			},
		})
		b.lookup("account", function() end)
		b.tick()
		assert.equal("secret-tool", plan.executable)
		assert.equal("lookup", plan.args[1])
		assert.is_nil(table.concat(plan.args, " "):find("--host", 1, true))
	end)
	it("cancels a failed native poll before delivering its error callback", function()
		local cancelled, callback = false, false
		local b = macos.new({
			spawner = {
				spawn = function()
					return {
						poll = function()
							return nil, { kind = "process", message = "poll failed" }
						end,
						cancel = function()
							cancelled = true
						end,
					}
				end,
			},
		})
		b.lookup("account", function(value, err)
			assert.is_nil(value)
			assert.is_true(cancelled)
			assert.equal("poll failed", err.message)
			callback = true
		end)
		b.tick()
		assert.is_true(callback)
		b.close()
	end)
	it("reports null store unavailability for every operation", function()
		local b = null.new({ reason = "No credential store" })
		local function check(v, e)
			assert.is_nil(v)
			assert.equal("unavailable", e.kind)
		end
		b.store("a", "secret", check)
		b.lookup("a", check)
		b.forget("a", check)
		b.exists("a", check)
		b.tick()
		b.close()
		null.new({}).lookup("a", function(_, e)
			assert.equal("Credential store unavailable", e.message)
			assert.equal("keyring_unavailable", e.message_text.key)
		end)
	end)
	it("uses DPAPI entropy, anchors buffers, zeros bytes and frees output allocations", function()
		local files, held, freed, buffers = {}, {}, 0, {}
		local C = {}
		local function transform(input, _, entropy, _, _, flags, output)
			collectgarbage()
			local junk = string.rep("x", 50000)
			assert.equal(50000, #junk)
			assert.equal(1, flags)
			assert.equal("default/token", ffi.string(entropy.pbData, entropy.cbData))
			local value = ffi.string(input.pbData, input.cbData)
			local out = value:sub(1, 4) == "enc:" and value:sub(5) or "enc:" .. value
			local buf = ffi.new("unsigned char[?]", #out)
			ffi.copy(buf, out, #out)
			held[#held + 1] = buf
			output.cbData, output.pbData = #out, buf
			return 1
		end
		C.CryptProtectData, C.CryptUnprotectData = transform, transform
		C.GetLastError = function()
			return 5
		end
		C.LocalFree = function(ptr)
			freed = freed + 1
			assert.equal(0, tonumber(ffi.cast("unsigned char*", ptr)[0]))
		end
		local fs = {
			exists = function(path)
				return files[path] ~= nil
			end,
			read = function(path)
				return files[path]
			end,
			mkdir_private = function()
				return true
			end,
			write_private = function(path, data)
				files[path] = data
				return true
			end,
			remove = function(path)
				files[path] = nil
				return true
			end,
			remove_private = function(path)
				files[path] = nil
				return true
			end,
		}
		local b = windows.new({
			fs = fs,
			state_dir = "/state",
			C = C,
			before_crypt = function(a, e)
				buffers[#buffers + 1] = a
				buffers[#buffers + 1] = e
			end,
		})
		b.store("default/token", "secret😀", function(ok)
			assert.is_true(ok)
		end)
		b.lookup("default/token", function(value)
			assert.equal("secret😀", value)
		end)
		assert.equal(2, freed)
		for _, buf in ipairs(buffers) do
			assert.equal(0, tonumber(buf[0]))
		end
		for _, data in pairs(files) do
			assert.is_nil(data:find("secret😀", 1, true))
			assert.is_table(json.decode(data))
		end
		C.CryptUnprotectData = function()
			return 0
		end
		b.lookup("default/token", function(value, err)
			assert.is_nil(value)
			assert.equal("unavailable", err.kind)
		end)
		b.forget("default/token", function(ok)
			assert.is_true(ok)
		end)
	end)

	it("keeps no previous DPAPI record behind after a re-save, and Forget removes every copy", function()
		local obs = require("obslua")
		local fs_module = require("crier_obs.ports.fs")
		local state = os.tmpname()
		os.remove(state)
		local windows_fs = fs_module.new({ obs = obs, platform = "Windows" })
		local host_fs = fs_module.new({ obs = obs })
		assert(host_fs.mkdir(state))
		local C = {
			GetLastError = function()
				return 5
			end,
			LocalFree = function() end,
		}
		local held = {}
		local function transform(input, _, _, _, _, _, output)
			local value = ffi.string(input.pbData, input.cbData)
			local out = value:sub(1, 4) == "enc:" and value:sub(5) or "enc:" .. value
			local buf = ffi.new("unsigned char[?]", #out)
			ffi.copy(buf, out, #out)
			held[#held + 1] = buf
			output.cbData, output.pbData = #out, buf
			return 1
		end
		C.CryptProtectData, C.CryptUnprotectData = transform, transform
		local b = windows.new({ fs = windows_fs, state_dir = state, C = C })
		local record = require("crier_obs.secrets.keyring.file").record_path(state .. "/secrets", "default/token")
		local function leftovers()
			local found = {}
			for _, path in ipairs(host_fs.glob(state .. "/secrets/*")) do
				if path:sub(1, #record) == record then
					found[#found + 1] = path
				end
			end
			return found
		end
		b.store("default/token", "first", function(ok)
			assert.is_true(ok)
		end)
		b.store("default/token", "second", function(ok)
			assert.is_true(ok)
		end)
		assert.same({ record }, leftovers())
		b.lookup("default/token", function(value)
			assert.equal("second", value)
		end)
		-- A record rewritten by an earlier build with a backup extension is purged on Forget as well.
		assert(obs.os_quick_write_utf8_file_safe(record, "old", 3, false, "tmp", "bak"))
		assert.is_true(host_fs.exists(record .. ".bak"))
		b.forget("default/token", function(ok)
			assert.is_true(ok)
		end)
		assert.same({}, leftovers())
	end)
end)

local lock_module = require("crier_obs.secrets.lock")
describe("Windows credential index mutex", function()
	it("uses a stable named mutex and releases abandoned/successful handles", function()
		local state, names, released, closed = 0, {}, 0, 0
		local C = {
			CreateMutexW = function(_, _, name)
				collectgarbage()
				local units = {}
				local i = 0
				while name[i] ~= 0 do
					units[#units + 1] = string.char(name[i])
					i = i + 1
				end
				names[#names + 1] = table.concat(units)
				return ffi.cast("void*", 123)
			end,
			WaitForSingleObject = function(_, delay)
				assert.equal(0, delay)
				return state
			end,
			ReleaseMutex = function()
				released = released + 1
			end,
			CloseHandle = function()
				closed = closed + 1
			end,
		}
		local locked = lock_module.new({ platform = "Windows", state_dir = "C:/state", lock_C = C })
		assert.is_true(locked(function()
			return true
		end))
		state = 128
		assert.is_true(locked(function()
			return true
		end))
		assert.equal(names[1], names[2])
		state = 258
		local ok, err = locked(function()
			assert.is_true(false)
		end)
		assert.is_nil(ok)
		assert.equal("busy", err.kind)
		assert.equal(2, released)
		assert.equal(3, closed)
		C.CreateMutexW = function()
			return ffi.cast("void*", nil)
		end
		assert.is_nil(locked(function()
			return true
		end))
	end)
end)
