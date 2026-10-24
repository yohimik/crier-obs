-- Strict JSON with explicit array and null values; failures are returned, never thrown.
local M = {}
M.null = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})
local array_mt = { __json_array = true }
function M.array(t)
	return setmetatable(t or {}, array_mt)
end
local escapes = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}
local unescapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
local function quote(s)
	local escaped = s:gsub('[%z\1-\31\\"]', function(c)
		return escapes[c] or string.format("\\u%04x", c:byte())
	end)
	return '"' .. escaped .. '"'
end
function M.encode(value)
	local seen = {}
	local function enc(v)
		if v == M.null then
			return "null"
		end
		local kind = type(v)
		if kind == "string" then
			return quote(v)
		end
		if kind == "boolean" then
			return tostring(v)
		end
		if kind == "number" then
			if v ~= v or v == math.huge or v == -math.huge then
				return nil, "non-finite JSON number"
			end
			return string.format("%.17g", v)
		end
		if kind ~= "table" then
			return nil, "unsupported JSON type: " .. kind
		end
		if seen[v] then
			return nil, "cyclic JSON value"
		end
		seen[v] = true
		local n, is_array = #v, getmetatable(v) == array_mt or #v > 0
		local keys = {}
		for k in pairs(v) do
			if is_array and (type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0) then
				seen[v] = nil
				return nil, "sparse or mixed JSON array"
			end
			if not is_array and type(k) ~= "string" then
				seen[v] = nil
				return nil, "non-string JSON object key"
			end
			keys[#keys + 1] = k
		end
		table.sort(keys)
		local out = {}
		for _, k in ipairs(keys) do
			local s, err = enc(v[k])
			if not s then
				seen[v] = nil
				return nil, err
			end
			out[#out + 1] = is_array and s or quote(k) .. ":" .. s
		end
		seen[v] = nil
		return (is_array and "[" or "{") .. table.concat(out, ",") .. (is_array and "]" or "}")
	end
	local s, err = enc(value)
	if not s then
		return nil, { kind = "json", message = err }
	end
	return s
end
local function utf8(n)
	if n < 128 then
		return string.char(n)
	end
	if n < 2048 then
		return string.char(192 + math.floor(n / 64), 128 + n % 64)
	end
	if n < 65536 then
		return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64)
	end
	return string.char(
		240 + math.floor(n / 262144),
		128 + math.floor(n / 4096) % 64,
		128 + math.floor(n / 64) % 64,
		128 + n % 64
	)
end
function M.decode(s)
	if type(s) ~= "string" then
		return nil, { kind = "json", message = "JSON input must be text" }
	end
	local i, failure, depth = 1, nil, 0
	local function fail(msg)
		failure = failure or (msg .. " at byte " .. i)
		return nil
	end
	local function ws()
		local _, b = s:find("^[ \t\r\n]*", i)
		i = (b or i - 1) + 1
	end
	local function str()
		i = i + 1
		local out = {}
		while i <= #s do
			local c = s:sub(i, i)
			i = i + 1
			if c == '"' then
				return table.concat(out)
			end
			if c == "\\" then
				local e = s:sub(i, i)
				i = i + 1
				if unescapes[e] then
					out[#out + 1] = unescapes[e]
				elseif e == "u" then
					local h = s:sub(i, i + 3)
					if not h:match("^%x%x%x%x$") then
						return fail("invalid Unicode escape")
					end
					local n = tonumber(h, 16)
					i = i + 4
					if n >= 0xD800 and n <= 0xDBFF then
						local h2 = s:sub(i + 2, i + 5)
						if s:sub(i, i + 1) ~= "\\u" or not h2:match("^%x%x%x%x$") then
							return fail("missing low surrogate")
						end
						local low = tonumber(h2, 16)
						if low < 0xDC00 or low > 0xDFFF then
							return fail("invalid low surrogate")
						end
						n = 0x10000 + (n - 0xD800) * 1024 + low - 0xDC00
						i = i + 6
					elseif n >= 0xDC00 and n <= 0xDFFF then
						return fail("unpaired low surrogate")
					end
					out[#out + 1] = utf8(n)
				else
					return fail("invalid escape")
				end
			elseif c:byte() < 32 then
				return fail("control character in string")
			else
				out[#out + 1] = c
			end
		end
		return fail("unterminated string")
	end
	local parse
	parse = function()
		ws()
		depth = depth + 1
		if depth > 128 then
			return fail("JSON nesting limit")
		end
		local c = s:sub(i, i)
		local v
		if c == '"' then
			v = str()
		elseif c == "{" or c == "[" then
			local close = c == "{" and "}" or "]"
			v = c == "[" and M.array() or {}
			i = i + 1
			ws()
			if s:sub(i, i) == close then
				i = i + 1
			else
				while not failure do
					local k
					if c == "{" then
						if s:sub(i, i) ~= '"' then
							return fail("expected object key")
						end
						k = str()
						ws()
						if s:sub(i, i) ~= ":" then
							return fail("expected colon")
						end
						i = i + 1
						if v[k] ~= nil then
							return fail("duplicate object key")
						end
					else
						k = #v + 1
					end
					local x = parse()
					if failure then
						return nil
					end
					v[k] = x
					ws()
					local sep = s:sub(i, i)
					i = i + 1
					if sep == close then
						break
					end
					if sep ~= "," then
						return fail("expected comma or closing delimiter")
					end
					ws()
				end
			end
		elseif s:sub(i, i + 3) == "true" then
			v = true
			i = i + 4
		elseif s:sub(i, i + 4) == "false" then
			v = false
			i = i + 5
		elseif s:sub(i, i + 3) == "null" then
			v = M.null
			i = i + 4
		else
			local token = s:match("^%-?%d+%.?%d*[eE]?[+%-]?%d*", i)
			if not token or token == "" then
				return fail("expected JSON value")
			end
			local mantissa = token:match("^(.-)[eE]([+%-]?%d+)$")
			local numeric = mantissa or token
			if
				not numeric:match("^%-?0$")
				and not numeric:match("^%-?[1-9]%d*$")
				and not numeric:match("^%-?0%.%d+$")
				and not numeric:match("^%-?[1-9]%d*%.%d+$")
			then
				return fail("invalid number")
			end
			v = tonumber(token)
			if not v or v == math.huge or v == -math.huge then
				return fail("invalid number")
			end
			i = i + #token
		end
		depth = depth - 1
		return v
	end
	local v = parse()
	ws()
	if not failure and i <= #s then
		fail("trailing data")
	end
	if failure then
		return nil, { kind = "json", message = failure }
	end
	return v
end
return M
