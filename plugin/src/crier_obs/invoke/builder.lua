local json = require("crier_obs.json")
local descriptors = require("crier_obs.schema.descriptor")
local equal = require("crier_obs.settings.model").equal
local plan_module = require("crier_obs.invoke.plan")
local copy = require("crier_obs.invoke.datadoc").copy
local M = {}
local function set(t, key, value)
	local parts = {}
	for part in key:gmatch("[^.]+") do
		parts[#parts + 1] = part
	end
	for i = 1, #parts - 1 do
		t[parts[i]] = t[parts[i]] or {}
		t = t[parts[i]]
	end
	t[parts[#parts]] = value
end
local function directory(path)
	return path:match("^(.*)[/\\][^/\\]+$") or "."
end
local function absolute(path, base)
	if
		path == ""
		or path == "-"
		or path:match("^env:")
		or path:match("^%a[%w+.-]*://")
		or path:match("^/")
		or path:match("^%a:[/\\]")
		or path:match("^\\\\")
	then
		return path
	end
	return base .. "/" .. path
end
function M.build(input)
	local model = assert(input.model)
	local run = assert(input.run)
	local base = model.mode == "advanced" and directory(model.base_config) or (input.source_dir or run.dir)
	local flat, warnings, secrets = {}, {}, {}
	local ds = descriptors.build(model.custom_names)
	local custom_names, seen_custom = {}, {}
	for _, d in ipairs(ds) do
		if d.custom and not seen_custom[d.platform] then
			seen_custom[d.platform] = true
			custom_names[#custom_names + 1] = d.platform
		end
	end
	for _, d in ipairs(ds) do
		if d.secret then
			local inherited_stage = model.mode == "advanced" and not model.touched["stage.mode"]
			local stage_selected = not d.key:match("^stage%.s3%.")
				or model.values["stage.mode"] == "s3"
				or inherited_stage
			local enabled_platform = d.platform and model.platforms[d.platform]
			if enabled_platform or (not d.platform and stage_selected) then
				secrets[#secrets + 1] = d.key
			end
		else
			local value = model.values[d.key]
			if value == nil then
				value = d.default
			end
			value = copy(value)
			if d.kind == "list" then
				value = json.array(value or {})
			end
			if d.path and value ~= "" and value ~= nil then
				if type(value) == "table" then
					for i, v in ipairs(value) do
						value[i] = absolute(v, base)
					end
				else
					value = absolute(value, base)
				end
			end
			local force = d.key:match("^publish%.[^.]+%.enabled$") or d.key:match("^publish%.custom%..+%.enabled$")
			if force then
				value = model.platforms[d.platform] or false
			end
			if d.custom and d.key:match("%.env$") then
				for _, entry in ipairs(value) do
					local name, content = entry:match("^([%a_][%w_]*)=(.*)$")
					if name then
						flat[d.key .. "." .. name] = content
					else
						warnings[#warnings + 1] = "Invalid custom environment entry for " .. d.platform
					end
				end
			else
				local changed = not equal(value, d.default)
				local touched = model.mode == "advanced" and model.touched[d.key]
				if force or touched or (model.mode ~= "advanced" and changed) then
					flat[d.key] = value
				end
			end
		end
	end
	flat["publish.caption"] = input.caption or ""
	flat["render.data"] = input.data_path or run.data
	if input.clip and input.clip ~= "" then
		flat["publish.input"] = absolute(input.clip, base)
	end
	local args = { "--config", model.mode == "advanced" and model.base_config or run.config, "--json" }
	if model.mode ~= "advanced" or model.touched["log.level"] then
		args[#args + 1] = "--log-level"
		args[#args + 1] = model.values["log.level"] or "info"
	end
	if input.dry_run then
		args[#args + 1] = "--publish-dry-run"
		args[#args + 1] = "--render-output"
		args[#args + 1] = run.preview
	end
	if input.clip and input.clip ~= "" then
		args[#args + 1] = "--publish-input"
		args[#args + 1] = absolute(input.clip, base)
	end
	local files = {}
	if model.mode == "advanced" then
		local keys = {}
		for key in pairs(flat) do
			keys[#keys + 1] = key
		end
		table.sort(keys)
		for _, key in ipairs(keys) do
			local value = flat[key]
			if type(value) == "table" then
				for _, v in ipairs(value) do
					if v:find(",", 1, true) then
						warnings[#warnings + 1] = "List "
							.. key
							.. " contains a comma, which crier splits in --set values"
					end
				end
				value = table.concat(value, ",")
			else
				value = tostring(value)
			end
			args[#args + 1] = "--set"
			args[#args + 1] = key .. "=" .. value
		end
	else
		local config = {}
		for key, value in pairs(flat) do
			set(config, key, value)
		end
		local data, e = json.encode(config)
		if not data then
			return nil, e
		end
		files[run.config] = data
	end
	local length = #(input.executable or "") + 1
	for _, arg in ipairs(args) do
		length = length + #arg + 3
	end
	if length > (input.argv_limit or 30000) then
		return nil,
			{
				kind = "arguments",
				message = "Configuration exceeds the command-line limit; use generated configuration mode",
			}
	end
	local plan = plan_module.new({
		executable = input.executable,
		args = args,
		env = {},
		files = files,
		cwd = model.mode == "advanced" and directory(model.base_config) or run.dir,
		stdin = nil,
		capture_stdout = not input.discard_output,
		capture_stderr = not input.discard_output,
		status_path = run.status,
		pid_path = run.pid,
		timeout = model.timeout or 900,
		kind = input.kind or "publish",
		needs_secrets = secrets,
		warnings = warnings,
		run = run,
		base_config = model.mode == "advanced" and not input.skip_base_probe and model.base_config or nil,
		selected_custom_names = custom_names,
		base_path = model.mode == "advanced" and model.base_config or nil,
		base_fingerprint = input.base_fingerprint,
		argv_limit = input.argv_limit,
	})
	if input.base_custom_names then
		local values = {}
		for _, name in ipairs(input.base_custom_names) do
			values["publish.custom." .. name .. ".enabled"] = true
		end
		local names, e = plan_module.disable_base_custom(plan, assert(json.encode({ values = values })))
		if not names then
			return nil, e
		end
	end
	return plan
end
function M.new(deps)
	return {
		build = function(input)
			if deps then
				input.argv_limit = input.argv_limit or deps.argv_limit
			end
			return M.build(input)
		end,
	}
end
M.absolute = absolute
return M
