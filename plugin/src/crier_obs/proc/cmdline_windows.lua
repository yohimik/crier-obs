local utf16 = require("crier_obs.utf16")
local M = {}
function M.quote(arg)
	if arg ~= "" and not arg:find('[%s"]') then
		return arg
	end
	local out, slashes = { '"' }, 0
	for i = 1, #arg do
		local c = arg:sub(i, i)
		if c == "\\" then
			slashes = slashes + 1
		elseif c == '"' then
			out[#out + 1] = string.rep("\\", slashes * 2 + 1) .. '"'
			slashes = 0
		else
			out[#out + 1] = string.rep("\\", slashes) .. c
			slashes = 0
		end
	end
	out[#out + 1] = string.rep("\\", slashes * 2) .. '"'
	return table.concat(out)
end
function M.command(executable, args)
	local out = { M.quote(executable) }
	for _, a in ipairs(args or {}) do
		out[#out + 1] = M.quote(tostring(a))
	end
	return table.concat(out, " ")
end
function M.environment(env)
	local names = {}
	for name in pairs(env) do
		names[#names + 1] = name
	end
	table.sort(names, function(a, b)
		return a:lower() < b:lower()
	end)
	local out = {}
	for _, name in ipairs(names) do
		if name:find("\0", 1, true) or tostring(env[name]):find("\0", 1, true) then
			return nil, { kind = "environment", message = "NUL in environment" }
		end
		out[#out + 1] = name .. "=" .. tostring(env[name])
	end
	return utf16.encode(table.concat(out, "\0") .. "\0\0")
end
-- CreateProcessW completes a relative lpApplicationName from the current directory and never
-- searches PATH, so Windows system tools are always named by their absolute path.
function M.powershell(system_root)
	if type(system_root) ~= "string" or system_root == "" then
		system_root = "C:\\Windows"
	end
	return (system_root:gsub("[\\/]+$", "")) .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
end
return M
