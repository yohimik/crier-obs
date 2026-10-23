local ffi = require("ffi")
local M = {}
local function numeric_compare(a, b)
  if #a ~= #b then return #a < #b and -1 or 1 end
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
function M.new(deps)
	local fs, env = deps.fs, deps.env or {}
	local windows = (env.os or ffi.os) == "Windows"
	local sep = windows and "\\" or "/"
	local exe = windows and "crier.exe" or "crier"
	local current = { state = "missing", message = "crier is not installed", button = "Install crier" }
	local process
	local self = {}
	function self.find(explicit)
		if explicit and explicit ~= "" then
			if fs.exists(explicit) then
				return explicit
			end
			return nil, { kind = "missing", message = "Configured crier path does not exist" }
		end
		local paths = {}
		if deps.state_dir then
			paths[#paths + 1] = deps.state_dir .. sep .. "bin" .. sep .. exe
		end
		local path = env.augmented_path or env.path
		if type(path) == "function" then
			path = path()
		end
		path = path or (env.getenv and env.getenv("PATH")) or ""
		for dir in path:gmatch(windows and "[^;]+" or "[^:]+") do
			paths[#paths + 1] = dir .. sep .. exe
		end
    local known = windows and {} or {
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", ((env.getenv and env.getenv("HOME")) or "") .. "/.local/bin",
    }
    for _, dir in ipairs(known) do paths[#paths + 1] = dir .. sep .. exe end
		for _, p in ipairs(paths) do
			if fs.exists(p) then
				return p
			end
		end
		return nil, { kind = "missing", message = "crier is not installed" }
	end
	function self.probe(explicit)
		if process then
			return nil, { kind = "busy", message = "Version check is already running" }
		end
		local path, e = self.find(explicit)
		if not path then
			current = { state = "missing", message = e.message, button = "Install crier" }
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
			current = { state = "failed", message = e.message, button = "Install crier" }
			return nil, e
		end
		current = { state = "checking", path = path, message = "Checking crier version…", button = "Install crier" }
		return process
	end
	function self.tick()
		if not process then
			return current
		end
		local r, e = process.poll()
    if e then
      local failed = process; process = nil
      if failed.cancel then failed.cancel()
      elseif failed.close then failed.close()
      else
        if failed.kill then failed.kill() elseif failed.terminate then failed.terminate() end
        if failed.detach then failed.detach() end
      end
      current.state, current.message = "failed", e.message or tostring(e)
      return current, e
    end
		if not r then
			return current, e
		end
		process = nil
		if r.code ~= 0 or r.timed_out then
			current.state = "failed"
			current.message = r.timed_out and "Version check timed out" or r.stderr or "Version check failed"
			return current
		end
		local data = deps.json and deps.json.decode(r.stdout or "")
		local version = type(data) == "table" and (data.version or data.Version)
			or (r.stdout or ""):match("(%d+%.%d+%.%d+[%w.+%-]*)")
		if not version then
			current.state = "failed"
			current.message = "Cannot read crier version"
			return current
		end
		local cmp = M.compare(version, deps.pin or "1.1.1")
		if cmp == nil then
			current.state = "failed"
			current.message = "Invalid crier version"
			return current
		end
		current.version = version
		current.state = cmp < 0 and "outdated" or "ready"
		current.button = cmp < 0 and "Update crier" or "Install crier"
		current.message = "crier " .. version .. " at " .. current.path
		if cmp < 0 then
			current.message = current.message .. " (older than " .. (deps.pin or "1.1.1") .. ")"
		end
		return current
	end
	function self.status()
		return current
	end
	function self.detach()
		if process then
      local pending = process
      process = nil
      if pending.cancel then pending.cancel()
      elseif pending.close then pending.close()
      else
        if pending.kill then pending.kill() elseif pending.terminate then pending.terminate() end
        if pending.detach then pending.detach() end
      end
      current.state, current.message = "cancelled", "Version check cancelled"
		end
	end
	return self
end
M.semver_compare = M.compare
return M
