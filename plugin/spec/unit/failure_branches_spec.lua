-- Failure branches that used to share a line with their condition, so line coverage counted them
-- whenever the condition ran. Each one is driven here on its own.
local ffi = require("ffi")
local b64 = require("crier_obs.secrets.base64")
local file = require("crier_obs.secrets.keyring.file")
local windows = require("crier_obs.secrets.keyring.windows")
local queue_module = require("crier_obs.run.queue")

local account = "default/publish.telegram.token"

local function memory_fs()
	local files = {}
	return {
		files = files,
		mkdir_private = function()
			return true
		end,
		exists = function(path)
			return files[path] ~= nil
		end,
		read = function(path)
			if files[path] == nil then
				return nil, { kind = "filesystem", message = "Cannot read " .. path }
			end
			return files[path]
		end,
		random_bytes = function(n)
			return string.rep("k", n)
		end,
		create_private = function(path, data)
			if files[path] ~= nil then
				return nil, { kind = "filesystem", message = "exists" }
			end
			files[path] = data
			return true
		end,
		write_private = function(path, data)
			files[path] = data
			return true
		end,
		remove_private = function(path)
			files[path] = nil
			return true
		end,
	}
end

local function call(backend, operation, value)
	local result, err
	local function done(v, e)
		result, err = v, e
	end
	if operation == "store" then
		backend.store(account, value, done)
	else
		backend[operation](account, done)
	end
	return result, err
end

local function failing(message)
	return function()
		return nil, { kind = "filesystem", message = message }
	end
end

describe("encrypted file keyring failures", function()
	local key_path = "/state/secrets/key"
	local record_path = file.record_path("/state/secrets", account)

	it("reports each step that can fail while creating the key or the record", function()
		local fs = memory_fs()
		fs.mkdir_private = failing("no folder")
		local ok, err = call(file.new({ fs = fs, state_dir = "/state" }), "store", "secret")
		assert.is_nil(ok)
		assert.equal("no folder", err.message)

		fs = memory_fs()
		fs.random_bytes = failing("no entropy")
		ok, err = call(file.new({ fs = fs, state_dir = "/state" }), "store", "secret")
		assert.is_nil(ok)
		assert.equal("no entropy", err.message)

		fs = memory_fs()
		fs.create_private = nil
		ok, err = call(file.new({ fs = fs, state_dir = "/state" }), "store", "secret")
		assert.is_nil(ok)
		assert.equal("Exclusive private key creation is unavailable", err.message)

		fs = memory_fs()
		fs.create_private = failing("denied")
		ok, err = call(file.new({ fs = fs, state_dir = "/state" }), "store", "secret")
		assert.is_nil(ok)
		assert.equal("denied", err.message)

		fs = memory_fs()
		local random = fs.random_bytes
		fs.random_bytes = function(n)
			if n == 12 then
				return nil, { kind = "filesystem", message = "no nonce" }
			end
			return random(n)
		end
		ok, err = call(file.new({ fs = fs, state_dir = "/state" }), "store", "secret")
		assert.is_nil(ok)
		assert.equal("no nonce", err.message)
		assert.is_nil(fs.files[record_path])
	end)

	it("reports a missing, unreadable or corrupted key on lookup", function()
		local fs = memory_fs()
		fs.files[record_path] = "{}"
		local value, err = call(file.new({ fs = fs, state_dir = "/state" }), "lookup")
		assert.is_nil(value)
		assert.equal("missing", err.kind)

		fs.files[key_path] = "unreadable"
		local read = fs.read
		fs.read = function(path)
			if path == key_path then
				return nil, { kind = "filesystem", message = "key unreadable" }
			end
			return read(path)
		end
		value, err = call(file.new({ fs = fs, state_dir = "/state" }), "lookup")
		assert.is_nil(value)
		assert.equal("key unreadable", err.message)

		fs.read = read
		fs.files[key_path] = b64.encode(string.rep("k", 16))
		local backend = file.new({ fs = fs, state_dir = "/state" })
		value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("Credential key is missing or corrupted", err.message)
		-- A corrupted key is not cached: a repaired key file is read on the next call.
		fs.files[key_path] = b64.encode(string.rep("k", 32))
		value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("credential", err.kind)
		assert.equal("Credential missing or corrupted", err.message)
	end)

	it("reports unreadable, malformed and empty records on lookup", function()
		local fs = memory_fs()
		local backend = file.new({ fs = fs, state_dir = "/state" })
		assert.is_true(call(backend, "store", "secret"))
		assert.equal("secret", call(backend, "lookup"))

		local read = fs.read
		fs.read = function(path)
			if path == record_path then
				return nil, { kind = "filesystem", message = "record unreadable" }
			end
			return read(path)
		end
		local value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("record unreadable", err.message)
		fs.read = read

		fs.files[record_path] = "not json"
		value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("Credential missing or corrupted", err.message)

		fs.files[record_path] = '{"nonce":"AAAA"}'
		value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("Credential missing or corrupted", err.message)

		assert.is_true(call(backend, "store", ""))
		value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("missing", err.kind)
	end)

	it("answers presence without decrypting and reports a record it cannot remove", function()
		local fs = memory_fs()
		local backend = file.new({ fs = fs, state_dir = "/state" })
		local present, err = call(backend, "exists")
		assert.is_nil(present)
		assert.equal("missing", err.kind)
		fs.files[record_path] = "not decrypted"
		assert.is_true(call(backend, "exists"))
		fs.remove_private = function()
			return false
		end
		local forgotten
		forgotten, err = call(backend, "forget")
		assert.is_nil(forgotten)
		assert.equal("Cannot forget credential", err.message)
	end)
end)

describe("Windows DPAPI keyring failures", function()
	local record_path = file.record_path("/state/secrets", account)
	local function dpapi()
		local held = {}
		local C = {
			GetLastError = function()
				return 5
			end,
			LocalFree = function() end,
		}
		local function transform(input, _, _, _, _, _, output)
			local value = ffi.string(input.pbData, input.cbData)
			local out = value:sub(1, 4) == "enc:" and value:sub(5) or "enc:" .. value
			local buf = ffi.new("unsigned char[?]", #out + 1)
			ffi.copy(buf, out, #out)
			held[#held + 1] = buf
			output.cbData, output.pbData = #out, buf
			return 1
		end
		C.CryptProtectData, C.CryptUnprotectData = transform, transform
		return C
	end

	it("reports a store that cannot create the folder or encrypt", function()
		local fs = memory_fs()
		fs.mkdir_private = failing("no folder")
		local ok, err = call(windows.new({ fs = fs, state_dir = "/state", C = dpapi() }), "store", "secret")
		assert.is_nil(ok)
		assert.equal("no folder", err.message)

		local C = dpapi()
		C.CryptProtectData = function()
			return 0
		end
		fs = memory_fs()
		ok, err = call(windows.new({ fs = fs, state_dir = "/state", C = C }), "store", "secret")
		assert.is_nil(ok)
		assert.equal("unavailable", err.kind)
		assert.equal(5, err.win32)
		assert.is_nil(fs.files[record_path])
	end)

	it("reports missing, unreadable, malformed and empty records on lookup", function()
		local fs = memory_fs()
		local backend = windows.new({ fs = fs, state_dir = "/state", C = dpapi() })
		local value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("missing", err.kind)

		fs.files[record_path] = "{}"
		local read = fs.read
		fs.read = failing("record unreadable")
		value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("record unreadable", err.message)
		fs.read = read

		for _, record in ipairs({ "not json", "{}", '{"dpapi":"not base64"}' }) do
			fs.files[record_path] = record
			value, err = call(backend, "lookup")
			assert.is_nil(value)
			assert.equal("Credential missing or corrupted", err.message)
		end

		assert.is_true(call(backend, "store", ""))
		value, err = call(backend, "lookup")
		assert.is_nil(value)
		assert.equal("missing", err.kind)
	end)

	it("answers presence without decrypting and reports a record it cannot remove", function()
		local C = dpapi()
		C.CryptUnprotectData = function()
			assert(false, "presence must not decrypt")
		end
		local fs = memory_fs()
		local backend = windows.new({ fs = fs, state_dir = "/state", C = C })
		local present, err = call(backend, "exists")
		assert.is_nil(present)
		assert.equal("missing", err.kind)
		fs.files[record_path] = "{}"
		assert.is_true(call(backend, "exists"))
		fs.remove_private = function()
			return false
		end
		local forgotten
		forgotten, err = call(backend, "forget")
		assert.is_nil(forgotten)
		assert.equal("Cannot forget credential", err.message)
	end)
end)

describe("queue unload failures", function()
	local function job(event)
		local self = { event = event, state = "queued" }
		function self.start()
			self.state = "resolving_secrets"
		end
		function self.tick() end
		function self.finished()
			return self.state == "done"
		end
		function self.cancel()
			self.state = "cancelled"
		end
		return self
	end
	local function backlog(append)
		return {
			size = function()
				return 0
			end,
			append = append or function()
				return true
			end,
			ack = function() end,
		}
	end

	it("reports an active critical post that was spilled but could not be parked", function()
		for _, case in ipairs({
			{ { kind = "park", message = "journal unwritable" }, "journal unwritable" },
			{ nil, "Cannot park queued post safely" },
		}) do
			local active = job("start")
			active.park = function()
				return nil, case[1]
			end
			local q = queue_module.new({ backlog = backlog() })
			q.push(active)
			q.tick()
			local records, err = q.detach()
			assert.is_nil(records)
			assert.equal(case[2], err.message)
			assert.equal("resolving_secrets", active.state)
		end
	end)

	it("cancels a pending critical post it cannot spill and reports why", function()
		local pending = job("end")
		local q = queue_module.new({
			backlog = backlog(function()
				return nil, { message = "disk full" }
			end),
		})
		assert.is_true(q.push(pending))
		local records, err = q.detach()
		assert.is_nil(records)
		assert.equal("queue", err.kind)
		assert.equal("cannot preserve queued post: disk full", err.message)
		assert.equal("cancelled", pending.state)
		assert.equal(0, q.size())
	end)
end)
