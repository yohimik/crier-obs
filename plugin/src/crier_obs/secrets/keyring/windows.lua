local ffi = require("ffi")
local b64 = require("crier_obs.secrets.base64")
local json = require("crier_obs.json")
local file = require("crier_obs.secrets.keyring.file")
ffi.cdef([[
typedef struct { uint32_t cbData; unsigned char *pbData; } COBS_DPAPI_BLOB;
int __stdcall CryptProtectData(COBS_DPAPI_BLOB*,const uint16_t*,COBS_DPAPI_BLOB*,void*,void*,uint32_t,COBS_DPAPI_BLOB*);
int __stdcall CryptUnprotectData(COBS_DPAPI_BLOB*,uint16_t**,COBS_DPAPI_BLOB*,void*,void*,uint32_t,COBS_DPAPI_BLOB*);
void * __stdcall LocalFree(void*); uint32_t __stdcall GetLastError(void);
]])
local M = {}
function M.new(deps)
	local crypto = deps.crypt32 or deps.C or ffi.load("crypt32")
	local kernel = deps.kernel32 or deps.C or ffi.load("kernel32")
	local fs, dir = deps.fs, deps.state_dir .. "/secrets"
	local self = { name = "windows" }
	local function protect(account, input, decrypt)
		local bytes, entropy = ffi.new("unsigned char[?]", #input + 1), ffi.new("unsigned char[?]", #account + 1)
		ffi.copy(bytes, input, #input)
		ffi.copy(entropy, account, #account)
		local blob, extra, output = ffi.new("COBS_DPAPI_BLOB"), ffi.new("COBS_DPAPI_BLOB"), ffi.new("COBS_DPAPI_BLOB")
		blob.cbData, blob.pbData = #input, bytes
		extra.cbData, extra.pbData = #account, entropy
		if deps.before_crypt then
			deps.before_crypt(bytes, entropy)
		end
		local ok
		if decrypt then
			ok = crypto.CryptUnprotectData(blob, nil, extra, nil, nil, 1, output)
		else
			ok = crypto.CryptProtectData(blob, nil, extra, nil, nil, 1, output)
		end
		local code = ok == 0 and tonumber(kernel.GetLastError()) or nil
		ffi.fill(bytes, ffi.sizeof(bytes))
		ffi.fill(entropy, ffi.sizeof(entropy))
		if ok == 0 then
			return nil,
				{ kind = "unavailable", message = "Windows credential cannot be decrypted; re-enter it", win32 = code }
		end
		local value = ffi.string(output.pbData, output.cbData)
		ffi.fill(output.pbData, output.cbData)
		kernel.LocalFree(output.pbData)
		return value
	end
	function self.store(account, value, callback)
		local ok, err = fs.mkdir_private(dir)
		if not ok then
			callback(nil, err)
			return
		end
		local encrypted
		encrypted, err = protect(account, value, false)
		if not encrypted then
			callback(nil, err)
			return
		end
		ok, err = fs.write_private(file.record_path(dir, account), json.encode({ dpapi = b64.encode(encrypted) }))
		callback(ok, err)
	end
	function self.lookup(account, callback)
		local path = file.record_path(dir, account)
		if not fs.exists(path) then
			callback(nil, { kind = "missing", message = "Credential not stored" })
			return
		end
		local data, err = fs.read(path)
		if not data then
			callback(nil, err)
			return
		end
		local record = json.decode(data)
		local encrypted = type(record) == "table" and b64.decode(record.dpapi)
		if not encrypted then
			callback(nil, { kind = "credential", message = "Credential missing or corrupted" })
			return
		end
		local value
		value, err = protect(account, encrypted, true)
		if value == "" then
			value, err = nil, { kind = "missing", message = "Credential not stored" }
		end
		callback(value, err)
	end
	function self.forget(account, callback)
		local path = file.record_path(dir, account)
		-- A record rewritten by an older build can have left <record>.bak or <record>.tmp beside it.
		if fs.remove_private(path) then
			callback(true)
			return
		end
		callback(nil, { kind = "filesystem", message = "Cannot forget credential" })
	end
	-- Presence only: the record is not decrypted.
	function self.exists(account, callback)
		if fs.exists(file.record_path(dir, account)) then
			callback(true)
			return
		end
		callback(nil, { kind = "missing", message = "Credential not stored" })
	end
	function self.tick() end
	function self.close() end
	return self
end
return M
