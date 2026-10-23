local M = {}
local json = require("crier_obs.json")
function M.env_name(key)
	return "CRIER_" .. key:upper():gsub("[.%-]", "_")
end
function M.new(values)
	local plan = { args = {}, env = {}, files = {}, needs_secrets = {} }
	for k, v in pairs(values or {}) do
		plan[k] = v
	end
	plan.argv = plan.args
	return plan
end
function M.with_secrets(plan, values, log)
	local env = {}
	for k, v in pairs(plan.env or {}) do
		env[k] = v
	end
	for key, value in pairs(values or {}) do
		if value and value ~= "" then
			env[M.env_name(key)] = value
			if log then
				log.register_secret(value)
			end
		end
	end
	local out = {}
	for k, v in pairs(plan) do
		out[k] = v
	end
	out.env = env
	return out
end
function M.disable_base_custom(plan, report)
	local data = json.decode(report or "")
	if type(data) ~= "table" or type(data.values) ~= "table" or getmetatable(data.values) ~= nil then
		return nil, { kind = "configuration", message = "Cannot inspect custom destinations in the base configuration" }
	end
	if not plan.base_custom_args then
		plan.base_custom_args = {}
		for i, arg in ipairs(plan.args) do
			plan.base_custom_args[i] = arg
		end
	end
	plan.args = {}
	for i, arg in ipairs(plan.base_custom_args) do
		plan.args[i] = arg
	end
	plan.argv = plan.args
	local names, seen, selected = {}, {}, {}
	for _, name in ipairs(plan.selected_custom_names or {}) do
		selected[name] = true
	end
	for key in pairs(data.values) do
		local name = type(key) == "string" and key:match("^publish%.custom%.([^.]+)%.")
		if name and not seen[name] then
			if not name:match("^[a-z0-9%-]+$") then
				return nil, { kind = "configuration", message = "Invalid custom destination in base configuration" }
			end
			seen[name] = true
			names[#names + 1] = name
		end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		if not selected[name] then
			plan.args[#plan.args + 1] = "--set"
			plan.args[#plan.args + 1] = "publish.custom." .. name .. ".enabled=false"
		end
	end
	local length = 0
	for _, arg in ipairs(plan.args) do
		length = length + #arg + 3
	end
	if length > (plan.argv_limit or 30000) then
		return nil, { kind = "arguments", message = "Base custom destinations exceed the command-line limit" }
	end
	return names
end
function M.base_probe(plan)
	return {
		executable = plan.executable,
		args = { "config", "--json", "--all", "--config", plan.base_config },
		env = {},
		cwd = plan.cwd,
		capture_stdout = true,
		capture_stderr = true,
		timeout = 30,
		kind = "probe",
	}
end

return M
