local M = {}
local function bad(message)
	return nil, { kind = "encoding", message = message }
end
function M.encode(text)
	local units, i = {}, 1
	while i <= #text do
		local a = text:byte(i)
		local cp, n
		if a < 128 then
			cp, n = a, 1
		elseif a >= 194 and a <= 223 then
			cp, n = a - 192, 2
		elseif a >= 224 and a <= 239 then
			cp, n = a - 224, 3
		elseif a >= 240 and a <= 244 then
			cp, n = a - 240, 4
		else
			return bad("Invalid UTF-8 lead byte")
		end
		for j = 1, n - 1 do
			local b = text:byte(i + j)
			if not b or b < 128 or b > 191 then
				return bad("Invalid UTF-8 continuation")
			end
			cp = cp * 64 + b - 128
		end
		if
			(n == 2 and cp < 128)
			or (n == 3 and cp < 2048)
			or (n == 4 and cp < 65536)
			or cp > 1114111
			or (cp >= 55296 and cp <= 57343)
		then
			return bad("Invalid UTF-8 code point")
		end
		if cp < 65536 then
			units[#units + 1] = cp
		else
			cp = cp - 65536
			units[#units + 1] = 55296 + math.floor(cp / 1024)
			units[#units + 1] = 56320 + cp % 1024
		end
		i = i + n
	end
	local bytes = {}
	for _, u in ipairs(units) do
		bytes[#bytes + 1] = string.char(u % 256, math.floor(u / 256))
	end
	return table.concat(bytes)
end
function M.decode(bytes)
	if #bytes % 2 ~= 0 then
		return bad("Odd UTF-16 byte count")
	end
	local out, i = {}, 1
	local function unit(p)
		return bytes:byte(p) + 256 * bytes:byte(p + 1)
	end
	while i <= #bytes do
		local cp = unit(i)
		i = i + 2
		if cp >= 55296 and cp <= 56319 then
			if i > #bytes then
				return bad("Missing UTF-16 low surrogate")
			end
			local low = unit(i)
			if low < 56320 or low > 57343 then
				return bad("Invalid UTF-16 low surrogate")
			end
			cp = 65536 + (cp - 55296) * 1024 + low - 56320
			i = i + 2
		elseif cp >= 56320 and cp <= 57343 then
			return bad("Unpaired UTF-16 low surrogate")
		end
		if cp < 128 then
			out[#out + 1] = string.char(cp)
		elseif cp < 2048 then
			out[#out + 1] = string.char(192 + math.floor(cp / 64), 128 + cp % 64)
		elseif cp < 65536 then
			out[#out + 1] = string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
		else
			out[#out + 1] = string.char(
				240 + math.floor(cp / 262144),
				128 + math.floor(cp / 4096) % 64,
				128 + math.floor(cp / 64) % 64,
				128 + cp % 64
			)
		end
	end
	return table.concat(out)
end
M.to_utf16le = M.encode
M.from_utf16le = M.decode
return M
