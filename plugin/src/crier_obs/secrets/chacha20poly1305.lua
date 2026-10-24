local bit = require("bit")
local M = {}
local function word(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	return bit.tobit(a + b * 256 + c * 65536 + d * 16777216)
end
local function little(n)
	return string.char(
		bit.band(n, 255),
		bit.band(bit.rshift(n, 8), 255),
		bit.band(bit.rshift(n, 16), 255),
		bit.band(bit.rshift(n, 24), 255)
	)
end
local function quarter(x, a, b, c, d)
	x[a] = bit.tobit(x[a] + x[b])
	x[d] = bit.rol(bit.bxor(x[d], x[a]), 16)
	x[c] = bit.tobit(x[c] + x[d])
	x[b] = bit.rol(bit.bxor(x[b], x[c]), 12)
	x[a] = bit.tobit(x[a] + x[b])
	x[d] = bit.rol(bit.bxor(x[d], x[a]), 8)
	x[c] = bit.tobit(x[c] + x[d])
	x[b] = bit.rol(bit.bxor(x[b], x[c]), 7)
end
function M.block(key, counter, nonce)
	if #key ~= 32 or #nonce ~= 12 then
		return nil, { kind = "credential", message = "Invalid encryption key or nonce" }
	end
	local initial = { 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 }
	for i = 1, 8 do
		initial[4 + i] = word(key, i * 4 - 3)
	end
	initial[13] = counter
	for i = 1, 3 do
		initial[13 + i] = word(nonce, i * 4 - 3)
	end
	local x = {}
	for i = 1, 16 do
		x[i] = initial[i]
	end
	for _ = 1, 10 do
		quarter(x, 1, 5, 9, 13)
		quarter(x, 2, 6, 10, 14)
		quarter(x, 3, 7, 11, 15)
		quarter(x, 4, 8, 12, 16)
		quarter(x, 1, 6, 11, 16)
		quarter(x, 2, 7, 12, 13)
		quarter(x, 3, 8, 9, 14)
		quarter(x, 4, 5, 10, 15)
	end
	local out = {}
	for i = 1, 16 do
		out[i] = little(bit.tobit(x[i] + initial[i]))
	end
	return table.concat(out)
end
local function crypt(key, nonce, data)
	local out = {}
	for i = 1, #data, 64 do
		local stream = M.block(key, math.floor((i - 1) / 64) + 1, nonce)
		local chunk = {}
		for j = i, math.min(i + 63, #data) do
			chunk[#chunk + 1] = string.char(bit.bxor(data:byte(j), stream:byte(j - i + 1)))
		end
		out[#out + 1] = table.concat(chunk)
	end
	return table.concat(out)
end
-- Base 2^13 limbs keep every product exactly representable in a Lua double.
local base = 8192
local function limbs(data)
	local out, accumulator, bits = {}, 0, 0
	for i = 1, #data do
		accumulator = accumulator + data:byte(i) * 2 ^ bits
		bits = bits + 8
		if bits >= 13 then
			out[#out + 1] = accumulator % base
			accumulator = math.floor(accumulator / base)
			bits = bits - 13
		end
	end
	if bits > 0 then
		out[#out + 1] = accumulator
	end
	for i = #out + 1, 10 do
		out[i] = 0
	end
	return out
end
function M.poly1305(message, key)
	if #key ~= 32 then
		return nil, { kind = "credential", message = "Invalid authentication key" }
	end
	local bytes = { key:byte(1, 16) }
	for _, i in ipairs({ 4, 8, 12, 16 }) do
		bytes[i] = bit.band(bytes[i], 15)
	end
	for _, i in ipairs({ 5, 9, 13 }) do
		bytes[i] = bit.band(bytes[i], 252)
	end
	local r, h = limbs(string.char(unpack(bytes))), limbs("")
	for offset = 1, #message, 16 do
		local n = limbs(message:sub(offset, offset + 15) .. "\1")
		for i = 1, 10 do
			h[i] = h[i] + n[i]
		end
		local product = {}
		for i = 1, 19 do
			product[i] = 0
		end
		for i = 1, 10 do
			for j = 1, 10 do
				product[i + j - 1] = product[i + j - 1] + h[i] * r[j]
			end
		end
		for i = 19, 11, -1 do
			product[i - 10] = product[i - 10] + product[i] * 5
		end
		for i = 1, 10 do
			h[i] = product[i]
		end
		local carry
		repeat
			for i = 1, 9 do
				carry = math.floor(h[i] / base)
				h[i] = h[i] % base
				h[i + 1] = h[i + 1] + carry
			end
			carry = math.floor(h[10] / base)
			h[10] = h[10] % base
			h[1] = h[1] + carry * 5
		until carry == 0
	end
	local above = true
	for i = 10, 1, -1 do
		local p = i == 1 and base - 5 or base - 1
		if h[i] ~= p then
			above = h[i] > p
			break
		end
	end
	if above then
		local borrow = 0
		for i = 1, 10 do
			local n = h[i] - (i == 1 and base - 5 or base - 1) - borrow
			borrow = n < 0 and 1 or 0
			h[i] = n % base
		end
	end
	local out, accumulator, bits, at = {}, 0, 0, 1
	for i = 1, 16 do
		while bits < 8 do
			accumulator = accumulator + h[at] * 2 ^ bits
			bits = bits + 13
			at = at + 1
		end
		out[i] = accumulator % 256
		accumulator = math.floor(accumulator / 256)
		bits = bits - 8
	end
	local carry = 0
	for i = 1, 16 do
		local n = out[i] + key:byte(16 + i) + carry
		out[i] = n % 256
		carry = math.floor(n / 256)
	end
	return string.char(unpack(out))
end
local function pad(data)
	return data .. string.rep("\0", (16 - #data % 16) % 16)
end
local function length64(n)
	return little(n % 4294967296) .. little(math.floor(n / 4294967296))
end
local function tag(key, nonce, aad, ciphertext)
	local first = M.block(key, 0, nonce)
	return M.poly1305(pad(aad) .. pad(ciphertext) .. length64(#aad) .. length64(#ciphertext), first:sub(1, 32))
end
function M.encrypt(key, nonce, plaintext, aad)
	if type(key) ~= "string" or #key ~= 32 or type(nonce) ~= "string" or #nonce ~= 12 then
		return nil, { kind = "credential", message = "Invalid encryption key or nonce" }
	end
	local ciphertext = crypt(key, nonce, plaintext)
	return ciphertext, tag(key, nonce, aad or "", ciphertext)
end
function M.decrypt(key, nonce, ciphertext, mac, aad)
	if
		type(key) ~= "string"
		or #key ~= 32
		or type(nonce) ~= "string"
		or #nonce ~= 12
		or type(mac) ~= "string"
		or #mac ~= 16
	then
		return nil, { kind = "credential", message = "Credential missing or corrupted" }
	end
	local expected, different = tag(key, nonce, aad or "", ciphertext), 0
	for i = 1, 16 do
		different = bit.bor(different, bit.bxor(expected:byte(i), mac:byte(i)))
	end
	if different ~= 0 then
		return nil, { kind = "credential", message = "Credential missing or corrupted" }
	end
	return crypt(key, nonce, ciphertext)
end
return M
