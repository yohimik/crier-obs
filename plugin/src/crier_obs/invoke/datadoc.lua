local M = {}
local json = require("crier_obs.json")
local function copy(value)
	if type(value) ~= "table" or value == json.null then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = copy(v)
	end
	return setmetatable(out, getmetatable(value))
end
M.copy = copy
function M.merge(user, context)
	local out = copy(context or {})
	for k, v in pairs(user or {}) do
		if type(v) == "table" and type(out[k]) == "table" and #v == 0 and #out[k] == 0 and not getmetatable(v) then
			out[k] = M.merge(v, out[k])
		else
			out[k] = copy(v)
		end
	end
	return out
end
function M.build(input)
	local model, front, session = input.model or {}, input.frontend or {}, input.session or {}
	local now = input.now or os.time()
	local uptime = math.max(0, math.floor(input.uptime or 0))
	local fields = {}
	for _, entry in ipairs(model.custom_fields or {}) do
		local key, value = entry:match("^([^=]+)=(.*)$")
		if key then
			fields[key] = value
		end
	end
	local platforms = {}
	for name, enabled in pairs(model.platforms or {}) do
		if enabled then
			platforms[#platforms + 1] = name
		end
	end
	table.sort(platforms)
	return {
		event = input.event,
		now = os.date("%Y-%m-%dT%H:%M:%S%z", now),
		now_utc = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
		started_at = session.started_at and os.date("!%Y-%m-%dT%H:%M:%SZ", session.started_at) or "",
		started_at_estimated = session.estimated or false,
		uptime_seconds = uptime,
		uptime = string.format("%02d:%02d:%02d", math.floor(uptime / 3600), math.floor(uptime / 60) % 60, uptime % 60),
		interval_index = session.interval_index or 0,
		scene = front.scene or "",
		profile = front.profile or "",
		scene_collection = front.scene_collection or "",
		service = front.service or "",
		server = front.server or "",
		title = model.title or "",
		game = model.game or "",
		url = model.url or "",
		fields = fields,
		platforms = platforms,
		recording_path = front.recording_path or "",
		replay_path = front.replay_path or "",
		obs_version = front.obs_version or "",
		plugin_version = input.plugin_version or "",
	}
end
function M.frontend(obs)
	local out = {}
	local scene = obs.obs_frontend_get_current_scene and obs.obs_frontend_get_current_scene()
	if scene then
		out.scene = obs.obs_source_get_name(scene)
		obs.obs_source_release(scene)
	end
	if obs.obs_frontend_get_current_profile then
		out.profile = obs.obs_frontend_get_current_profile()
	end
	if obs.obs_frontend_get_current_scene_collection then
		out.scene_collection = obs.obs_frontend_get_current_scene_collection()
	end
	if obs.obs_frontend_get_last_recording then
		out.recording_path = obs.obs_frontend_get_last_recording()
	end
	if obs.obs_frontend_get_last_replay then
		out.replay_path = obs.obs_frontend_get_last_replay()
	end
	if obs.obs_get_version_string then
		out.obs_version = obs.obs_get_version_string()
	end
	local service = obs.obs_frontend_get_streaming_service and obs.obs_frontend_get_streaming_service()
	if service and obs.obs_service_get_settings then
		local settings = obs.obs_service_get_settings(service)
		if settings then
			out.service = obs.obs_data_get_string(settings, "service")
			out.server = obs.obs_data_get_string(settings, "server")
			obs.obs_data_release(settings)
		end
	end
	return out
end
return M
