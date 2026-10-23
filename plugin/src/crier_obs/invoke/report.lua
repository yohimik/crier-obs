local json = require("crier_obs.json")
local errors = require("crier_obs.errors")
local M = {}
function M.parse(result, log)
	local scrub = log and log.scrub or function(s)
		return tostring(s or "")
	end
	local function clean(v)
		if type(v) == "string" then
			return scrub(v)
		elseif type(v) == "table" then
			local t = {}
			for k, x in pairs(v) do
				t[k] = clean(x)
			end
			return t
		end
		return v
	end
	local data = json.decode(result.stdout or "")
	local err = result.timed_out and errors.timeout() or errors.from_exit(result.code, result.signal)
	local lines = {}
	for line in (result.stderr or ""):gmatch("[^\r\n]+") do
		lines[#lines + 1] = line
	end
	local tail = {}
	for i = math.max(1, #lines - 19), #lines do
		tail[#tail + 1] = lines[i]
	end
	return {
		code = result.code,
		ok = result.code == 0 and not result.timed_out,
		level = result.code == 4 and "warn" or result.code == 0 and "info" or "error",
		kind = err.kind,
		message = scrub(err.message),
		hint = err.hint and scrub(err.hint),
		stderr = scrub(table.concat(tail, "\n")),
		results = clean(data and (data.results or data.outcomes or data) or {}),
		timed_out = result.timed_out or false,
	}
end
function M.new(deps)
	return {
		parse = function(r)
			return M.parse(r, deps.log)
		end,
	}
end
return M
