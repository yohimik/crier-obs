local bit = require("bit")
local plans = require("crier_obs.invoke.plan")
local M = {}
local K = {
	0x428a2f98,
	0x71374491,
	0xb5c0fbcf,
	0xe9b5dba5,
	0x3956c25b,
	0x59f111f1,
	0x923f82a4,
	0xab1c5ed5,
	0xd807aa98,
	0x12835b01,
	0x243185be,
	0x550c7dc3,
	0x72be5d74,
	0x80deb1fe,
	0x9bdc06a7,
	0xc19bf174,
	0xe49b69c1,
	0xefbe4786,
	0x0fc19dc6,
	0x240ca1cc,
	0x2de92c6f,
	0x4a7484aa,
	0x5cb0a9dc,
	0x76f988da,
	0x983e5152,
	0xa831c66d,
	0xb00327c8,
	0xbf597fc7,
	0xc6e00bf3,
	0xd5a79147,
	0x06ca6351,
	0x14292967,
	0x27b70a85,
	0x2e1b2138,
	0x4d2c6dfc,
	0x53380d13,
	0x650a7354,
	0x766a0abb,
	0x81c2c92e,
	0x92722c85,
	0xa2bfe8a1,
	0xa81a664b,
	0xc24b8b70,
	0xc76c51a3,
	0xd192e819,
	0xd6990624,
	0xf40e3585,
	0x106aa070,
	0x19a4c116,
	0x1e376c08,
	0x2748774c,
	0x34b0bcb5,
	0x391c0cb3,
	0x4ed8aa4a,
	0x5b9cca4f,
	0x682e6ff3,
	0x748f82ee,
	0x78a5636f,
	0x84c87814,
	0x8cc70208,
	0x90befffa,
	0xa4506ceb,
	0xbef9a3f7,
	0xc67178f2,
}
local function word(n)
	return string.char(
		bit.band(bit.rshift(n, 24), 255),
		bit.band(bit.rshift(n, 16), 255),
		bit.band(bit.rshift(n, 8), 255),
		bit.band(n, 255)
	)
end
function M.sha256(text)
	local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	local length = #text
	local padded = text
		.. "\128"
		.. string.rep("\0", (55 - length) % 64)
		.. word(math.floor(length / 536870912))
		.. word(length * 8)
	for start = 1, #padded, 64 do
		local w = {}
		for i = 0, 15 do
			local a, b, c, d = padded:byte(start + i * 4, start + i * 4 + 3)
			w[i + 1] = bit.tobit(a * 16777216 + b * 65536 + c * 256 + d)
		end
		for i = 17, 64 do
			local x, y = w[i - 15], w[i - 2]
			local s0 = bit.bxor(bit.ror(x, 7), bit.ror(x, 18), bit.rshift(x, 3))
			local s1 = bit.bxor(bit.ror(y, 17), bit.ror(y, 19), bit.rshift(y, 10))
			w[i] = bit.tobit(w[i - 16] + s0 + w[i - 7] + s1)
		end
		local a, b, c, d, e, f, g, k = unpack(h)
		for i = 1, 64 do
			local s1 = bit.bxor(bit.ror(e, 6), bit.ror(e, 11), bit.ror(e, 25))
			local ch = bit.bxor(bit.band(e, f), bit.band(bit.bnot(e), g))
			local t1 = bit.tobit(k + s1 + ch + K[i] + w[i])
			local s0 = bit.bxor(bit.ror(a, 2), bit.ror(a, 13), bit.ror(a, 22))
			local maj = bit.bxor(bit.band(a, b), bit.band(a, c), bit.band(b, c))
			local t2 = bit.tobit(s0 + maj)
			k, g, f, e, d, c, b, a = g, f, e, bit.tobit(d + t1), c, b, a, bit.tobit(t1 + t2)
		end
		for i, value in ipairs({ a, b, c, d, e, f, g, k }) do
			h[i] = bit.tobit(h[i] + value)
		end
	end
	local out = {}
	for _, value in ipairs(h) do
		out[#out + 1] = bit.tohex(value)
	end
	return table.concat(out)
end
function M.fingerprint(fs, path)
	local text, e = fs.read(path)
	if not text then
		return nil, e or { kind = "configuration", message = "Cannot read base configuration" }
	end
	if #text > 8388608 then
		return nil, { kind = "configuration", message = "Base configuration exceeds 8 MiB" }
	end
	return M.sha256(text)
end
-- Runs `crier config --json --all` on the plan's base file with a plain environment. poll() returns
-- nil while it runs, the report text once the probe exits 0 and the file still has the fingerprint
-- it had when the probe started, or false and an error. cancel() is the process's own.
function M.inspect(spawner, fs, plan)
	local fingerprint, e = M.fingerprint(fs, plan.base_config)
	if not fingerprint then
		return nil, e
	end
	local process, spawn_error = spawner.spawn(plans.base_probe(plan))
	if not process then
		return nil, spawn_error
	end
	local inspection = { fingerprint = fingerprint, process = process }
	function inspection.poll()
		local r, poll_error = process.poll()
		if poll_error then
			return false, poll_error
		end
		if not r then
			return nil
		end
		if r.code ~= 0 or r.timed_out then
			return false,
				{
					kind = "configuration",
					message = "Cannot inspect the base configuration (exit " .. tostring(r.code) .. ")",
				}
		end
		local current, read_error = M.fingerprint(fs, plan.base_config)
		if current ~= fingerprint then
			return false,
				read_error or {
					kind = "configuration",
					message = "Base configuration changed while it was being checked",
				}
		end
		return r.stdout or ""
	end
	function inspection.cancel()
		return process.cancel()
	end
	return inspection
end
return M
