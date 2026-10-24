local ffi = require("ffi")
local i18n = require("crier_obs.i18n")
local M = {}
-- Numeric identifiers compared as digit strings, so no precision is lost past 2^53.
local function numeric_compare(a, b)
	if #a ~= #b then
		return #a < #b and -1 or 1
	end
	return a < b and -1 or 1
end
function M.compare(a, b)
	local function identifiers(text, prerelease)
		if
			text == ""
			or text:find("[^%w%.%-]")
			or text:find("..", 1, true)
			or text:sub(1, 1) == "."
			or text:sub(-1) == "."
		then
			return false
		end
		for part in text:gmatch("[^.]+") do
			if prerelease and part:match("^%d+$") and #part > 1 and part:sub(1, 1) == "0" then
				return false
			end
		end
		return true
	end
	local function parse(s)
		local x, y, z, tail = tostring(s):match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
		if not x then
			return nil
		end
		for _, part in ipairs({ x, y, z }) do
			if #part > 1 and part:sub(1, 1) == "0" then
				return nil
			end
		end
		local before, build = tail:match("^(.-)%+(.*)$")
		if before then
			if not identifiers(build, false) then
				return nil
			end
			tail = before
		end
		local pre
		if tail ~= "" then
			if tail:sub(1, 1) ~= "-" then
				return nil
			end
			pre = tail:sub(2)
			if not identifiers(pre, true) then
				return nil
			end
		end
		return { x, y, z, pre }
	end
	local x, y = parse(a), parse(b)
	if not x or not y then
		return nil, { kind = "version", message = "Invalid semantic version" }
	end
	for i = 1, 3 do
		if x[i] ~= y[i] then
			return numeric_compare(x[i], y[i])
		end
	end
	if x[4] == y[4] then
		return 0
	end
	if not x[4] then
		return 1
	elseif not y[4] then
		return -1
	end
	local ax, ay = {}, {}
	for s in x[4]:gmatch("[^.]+") do
		ax[#ax + 1] = s
	end
	for s in y[4]:gmatch("[^.]+") do
		ay[#ay + 1] = s
	end
	for i = 1, math.max(#ax, #ay) do
		if not ax[i] then
			return -1
		elseif not ay[i] then
			return 1
		elseif ax[i] ~= ay[i] then
			local n, m = ax[i]:match("^%d+$"), ay[i]:match("^%d+$")
			if n and m then
				return numeric_compare(n, m)
			elseif n then
				return -1
			elseif m then
				return 1
			else
				return ax[i] < ay[i] and -1 or 1
			end
		end
	end
end
-- crier discovery and version check. The explicit path from the dialog wins; then the copy the
-- installer put in <state>/bin; then the augmented PATH the env port builds (shell-profile and
-- Homebrew directories included, since OBS started from the Dock does not have them).
function M.new(deps)
	local fs, env = deps.fs, deps.env or {}
	local pin = assert(deps.pin, "resolver needs the pinned crier version")
	local windows = (env.os or ffi.os) == "Windows"
	local sep = windows and "\\" or "/"
	-- message is English for the log; message_text is what the dialog's crier row shows.
	local current = i18n.with({ state = "missing" }, "crier_missing")
	local process
	local self = {}
	local function set(state, key, ...)
		current = i18n.with({ state = state, path = current.path }, key, ...)
		return current
	end
	local function search_path()
		local path = env.augmented_path or env.path
		if type(path) == "function" then
			path = path()
		end
		return path or (env.getenv and env.getenv("PATH")) or ""
	end
	-- An executable by absolute path, or the first match on the augmented PATH (".exe" on Windows).
	function self.find_binary(binary)
		if type(binary) ~= "string" or binary == "" then
			return nil
		end
		if binary:find("[/\\]") then
			return fs.exists(binary) and binary or nil
		end
		for dir in search_path():gmatch(windows and "[^;]+" or "[^:]+") do
			local full = dir .. sep .. binary
			if fs.exists(full) then
				return full
			end
			if windows and not binary:lower():match("%.exe$") and fs.exists(full .. ".exe") then
				return full .. ".exe"
			end
		end
		return nil
	end
	function self.find(explicit)
		if explicit and explicit ~= "" then
			if fs.exists(explicit) then
				return explicit
			end
			return nil, i18n.with({ kind = "missing" }, "crier_path_missing")
		end
		local managed = deps.state_dir
			and (deps.state_dir .. sep .. "bin" .. sep .. (windows and "crier.exe" or "crier"))
		if managed and fs.exists(managed) then
			return managed
		end
		local found = self.find_binary("crier")
		if found then
			return found
		end
		return nil, i18n.with({ kind = "missing" }, "crier_missing")
	end
	function self.probe(explicit)
		if process then
			return nil, { kind = "busy", message = "Version check is already running" } -- logged only
		end
		local path, e = self.find(explicit)
		if not path then
			current = { state = "missing", message = e.message, message_text = e.message_text }
			return nil, e
		end
		process, e = deps.spawner.spawn({
			executable = path,
			args = { "--version", "--json" },
			env = {},
			capture_stdout = true,
			capture_stderr = true,
			timeout = 15,
			kind = "probe",
		})
		if not process then
			current = i18n.with({ state = "failed" }, "crier_check_failed_reason", i18n.of(e))
			return nil, e
		end
		current = i18n.with({ state = "checking", path = path }, "crier_checking")
		return process
	end
	function self.tick()
		if not process then
			return current
		end
		local r, e = process.poll()
		if e then
			local failed = process
			process = nil
			failed.cancel()
			return set("failed", "crier_check_failed_reason", e.message or tostring(e)), e
		end
		if not r then
			return current
		end
		process = nil
		if r.timed_out then
			return set("failed", "crier_check_timed_out")
		end
		if r.code ~= 0 then
			local stderr = (r.stderr or ""):match("^%s*(.-)%s*$")
			if stderr == "" then
				return set("failed", "crier_check_failed")
			end
			return set("failed", "crier_check_failed_reason", stderr)
		end
		local data = deps.json and deps.json.decode(r.stdout or "")
		local version = type(data) == "table" and (data.version or data.Version)
			or (r.stdout or ""):match("(%d+%.%d+%.%d+[%w.+%-]*)")
		if not version then
			return set("failed", "crier_version_unreadable")
		end
		local cmp = M.compare(version, pin)
		if cmp == nil then
			return set("failed", "crier_version_invalid")
		end
		if cmp < 0 then
			set("outdated", "crier_outdated", version, current.path, pin)
		else
			set("ready", "crier_ready", version, current.path)
		end
		current.version = version
		return current
	end
	function self.status()
		return current
	end
	function self.detach()
		if process then
			local pending = process
			process = nil
			pending.cancel()
			set("cancelled", "crier_check_cancelled")
		end
	end
	return self
end
return M
