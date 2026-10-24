-- Flatpak host bridge: a sandboxed OBS reaches crier and the keyring tools on the host through
-- flatpak-spawn --host, and every path the child sees must be one the host shares (the home folder).
-- Plans name their path-valued crier keys in plan.path_keys ({key = kind}); the builder fills it.
local json = require("crier_obs.json")
local M = {}
local function unavailable()
	return nil,
		{
			kind = "sandbox",
			message = "Flatpak host paths cannot be mapped safely. Keep the state folder, configuration, "
				.. "templates and media under the shared home directory, or use a native OBS package",
		}
end
local function lookup(config, key)
	local value = config
	for part in key:gmatch("[^.]+") do
		if type(value) ~= "table" then
			return nil
		end
		value = value[part]
	end
	return value
end
-- Returns the plan to spawn: the same plan outside Flatpak, a flatpak-spawn plan inside it, or nil
-- and an error when the plan cannot run on the host safely.
function M.prepare(plan, env, fs)
	if not (env.flatpak and env.flatpak()) then
		return plan
	end
	local status = env.sandbox_status(fs)
	if not status.helper then
		return nil, { kind = "sandbox", message = status.message }
	end
	local home = env.getenv("HOME")
	local function shared(path)
		if type(path) ~= "string" or path == "" then
			return true
		end
		if path == "-" or path:match("^env:") or path:match("^%a[%w+.-]*://") then
			return true
		end
		if not home or home == "" or path:find("/../", 1, true) or path:match("/%.%.$") then
			return false
		end
		if path:sub(1, 1) ~= "/" then
			return false
		end
		return path == home or path:sub(1, #home + 1) == home .. "/"
	end
	local cwd = plan.cwd or home
	if type(cwd) ~= "string" or cwd == "" or not shared(cwd) then
		return unavailable()
	end
	local executable = plan.executable or (plan.argv and plan.argv[1])
	if
		type(executable) ~= "string"
		or executable == ""
		or executable:match("^/app/")
		or executable:match("^/tmp/")
		or executable:match("^/run/")
		or executable:find("/../", 1, true)
	then
		return unavailable()
	end
	for _, name in ipairs({ "stdin", "stdout", "stderr", "status_path", "pid_path" }) do
		if plan[name] and not shared(plan[name]) then
			return unavailable()
		end
	end
	local path_keys = plan.path_keys or {}
	for file, body in pairs(plan.files or {}) do
		if not shared(file) then
			return unavailable()
		end
		if file:match("config%.json$") then
			local config = json.decode(body)
			if type(config) ~= "table" then
				return unavailable()
			end
			for key in pairs(path_keys) do
				local value = lookup(config, key)
				if type(value) == "table" then
					for _, item in ipairs(value) do
						if not shared(item) then
							return unavailable()
						end
					end
				elseif value and not shared(value) then
					return unavailable()
				end
			end
		end
	end
	local args = plan.args or {}
	for i, arg in ipairs(args) do
		if arg == "--config" or arg == "--publish-input" or arg == "--render-output" then
			if not shared(args[i + 1]) then
				return unavailable()
			end
		elseif arg == "--set" then
			local key, value = (args[i + 1] or ""):match("^([^=]+)=(.*)$")
			local kind = key and path_keys[key]
			if kind == "list" then
				for item in value:gmatch("[^,]+") do
					if not shared(item) then
						return unavailable()
					end
				end
			elseif kind and not shared(value) then
				return unavailable()
			end
		end
	end
	local names = {}
	for name, value in pairs(plan.env or {}) do
		if name:find("%z") or name:find("=", 1, true) or tostring(value):find("%z") then
			return nil, { kind = "environment", message = "Invalid host environment entry" }
		end
		if not name:match("^LD_") and not name:match("^FLATPAK_") then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	local block = {}
	for _, name in ipairs(names) do
		block[#block + 1] = name .. "=" .. tostring(plan.env[name]) .. "\0"
	end
	local host_args = { "--host", "--env-fd=3", "--clear-env", "--watch-bus", "--directory=" .. cwd, "--", executable }
	for _, value in ipairs(args) do
		host_args[#host_args + 1] = value
	end
	local prepared = {}
	for key, value in pairs(plan) do
		prepared[key] = value
	end
	prepared.executable = status.helper
	prepared.args = host_args
	prepared.cwd = nil
	prepared.env_fd_data = table.concat(block)
	return prepared
end
return M
