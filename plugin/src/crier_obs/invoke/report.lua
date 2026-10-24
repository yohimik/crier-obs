local json = require("crier_obs.json")
local errors = require("crier_obs.errors")
local M = {}
local TAIL_LINES = 20
-- crier's exit code decides the log level: 0 info, 4 (some platforms failed) warn, anything else error.
function M.level(code, timed_out)
	if timed_out then
		return "error"
	end
	return code == 0 and "info" or code == 4 and "warn" or "error"
end
local function plain(v)
	return type(v) == "string" and v or ""
end
-- Turns a finished crier run (exit code, --json stdout, stderr) into what the dialog and the log show.
-- Every string that leaves here has passed log.scrub.
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
	for i = math.max(1, #lines - TAIL_LINES + 1), #lines do
		tail[#tail + 1] = lines[i]
	end
	local results = type(data) == "table" and type(data.results) == "table" and clean(data.results) or {}
	local failed = {}
	for _, outcome in ipairs(results) do
		if type(outcome) == "table" and outcome.ok == false then
			failed[#failed + 1] = { platform = plain(outcome.platform), error = plain(outcome.error) }
		end
	end
	local message = scrub(err.message)
	if #failed > 0 then
		local names = {}
		for _, outcome in ipairs(failed) do
			names[#names + 1] = outcome.platform
		end
		message = message .. " (" .. table.concat(names, ", ") .. ")"
	end
	local summary
	if type(data) == "table" and data.dryRun then
		local planned = {}
		for _, post in ipairs(type(data.plan) == "table" and data.plan or {}) do
			if type(post) == "table" and type(post.platform) == "string" then
				planned[#planned + 1] = scrub(post.platform)
			end
		end
		local noun = #planned == 1 and " post" or " posts"
		summary = "Dry run planned " .. #planned .. noun .. (#planned > 0 and (": " .. table.concat(planned, ", ")) or "")
	end
	return {
		code = result.code,
		ok = result.code == 0 and not result.timed_out,
		level = M.level(result.code, result.timed_out),
		kind = err.kind,
		message = message,
		hint = err.hint and scrub(err.hint),
		stderr = scrub(table.concat(tail, "\n")),
		results = results,
		failed = failed,
		summary = summary or "Dry run finished",
		timed_out = result.timed_out or false,
	}
end
return M
