local json = require("crier_obs.json")
local descriptors = require("crier_obs.schema.descriptor")
local equal = require("crier_obs.settings.model").equal
local plan_module = require("crier_obs.invoke.plan")
local copy = require("crier_obs.invoke.datadoc").copy
local platform_kinds = require("crier_obs.schema.platforms")
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
-- The credential keys a post needs: those of the ticked platforms, plus the staging keys when S3
-- staging is selected (or, in advanced mode, may be selected by the untouched base file).
function M.needs_secrets(model, platforms)
	platforms = platforms or model.platforms
	local keys = {}
	for _, d in ipairs(descriptors.build(model.custom_names)) do
		if d.secret then
			local inherited_stage = model.mode == "advanced" and not model.touched["stage.mode"]
			local stage_selected = not d.key:match("^stage%.s3%.")
				or model.values["stage.mode"] == "s3"
				or inherited_stage
			if (d.platform and platforms[d.platform]) or (not d.platform and stage_selected) then
				keys[#keys + 1] = d.key
			end
		end
	end
	return keys
end
-- Path-valued crier keys ({key = kind}), so the Flatpak bridge can check every path the child sees.
function M.path_keys(custom_names)
	local keys = {}
	for _, d in ipairs(descriptors.build(custom_names)) do
		if d.path then
			keys[d.key] = d.kind
		end
	end
	return keys
end
-- A saved replay is an MP4 crier publishes as is. crier refuses publish.input next to its own video
-- rendering, and refuses the whole post when any enabled platform cannot take video, so a clip post
-- turns rendering off and leaves such platforms out with a warning.
local function clip_platforms(model, warnings)
	local platforms, refused, accepted = {}, {}, 0
	for name, enabled in pairs(model.platforms) do
		if enabled and not platform_kinds.accepts(name, "video", model.values) then
			refused[#refused + 1] = name
			platforms[name] = false
		else
			platforms[name] = enabled
			accepted = accepted + (enabled and 1 or 0)
		end
	end
	table.sort(refused)
	if accepted == 0 then
		local message = "Clip post skipped: none of the selected platforms can post video (%s)"
		return nil, { kind = "skipped", message = message:format(table.concat(refused, ", ")) }
	end
	if #refused > 0 then
		warnings[#warnings + 1] = "Clip post leaves out platforms that cannot post video: "
			.. table.concat(refused, ", ")
	end
	return platforms
end
function M.build(input)
	local model = assert(input.model)
	local run = assert(input.run)
	local base = model.mode == "advanced" and directory(model.base_config) or (input.source_dir or run.dir)
	local flat, warnings = {}, {}
	local clip = input.clip and input.clip ~= "" and input.clip or nil
	local platforms = model.platforms
	if clip then
		local refusal
		platforms, refusal = clip_platforms(model, warnings)
		if not platforms then
			return nil, refusal
		end
	end
	local ds = descriptors.build(model.custom_names)
	local custom_names, seen_custom = {}, {}
	for _, d in ipairs(ds) do
		if d.custom and not seen_custom[d.platform] then
			seen_custom[d.platform] = true
			custom_names[#custom_names + 1] = d.platform
		end
	end
	for _, d in ipairs(ds) do
		if not d.secret then
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
				value = platforms[d.platform] or false
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
	if clip then
		flat["publish.input"] = absolute(clip, base)
		flat["render.video.enabled"] = false
		flat["render.video.frames-input"] = ""
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
	if clip then
		args[#args + 1] = "--publish-input"
		args[#args + 1] = absolute(clip, base)
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
	if plan_module.argv_length(input.executable, args) > (input.argv_limit or plan_module.ARGV_LIMIT) then
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
		needs_secrets = M.needs_secrets(model, platforms),
		path_keys = M.path_keys(model.custom_names),
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
