local M = {}
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.encode(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		out[#out + 1] = alphabet:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
			.. alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
			.. (b and alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
			.. (c and alphabet:sub(n % 64 + 1, n % 64 + 1) or "=")
	end
	return table.concat(out)
end
function M.decode(data)
	if type(data) ~= "string" or #data % 4 ~= 0 or data:find("[^A-Za-z0-9+/=]") then
		return nil, { kind = "credential", message = "Invalid credential encoding" }
	end
	local out = {}
	for i = 1, #data, 4 do
		local chunk = data:sub(i, i + 3)
		local a, b, c, d = chunk:sub(1, 1), chunk:sub(2, 2), chunk:sub(3, 3), chunk:sub(4, 4)
		if a == "=" or b == "=" or (c == "=" and d ~= "=") or (chunk:find("=") and i + 3 ~= #data) then
			return nil, { kind = "credential", message = "Invalid credential encoding" }
		end
		local function digit(v)
			return v == "=" and 0 or alphabet:find(v, 1, true) - 1
		end
		local n = digit(a) * 262144 + digit(b) * 4096 + digit(c) * 64 + digit(d)
		out[#out + 1] = string
			.char(math.floor(n / 65536), math.floor(n / 256) % 256, n % 256)
			:sub(1, c == "=" and 1 or d == "=" and 2 or 3)
	end
	local decoded = table.concat(out)
	if M.encode(decoded) ~= data then
		return nil, { kind = "credential", message = "Invalid credential encoding" }
	end
	return decoded
end
return M
