local session_module = require("crier_obs.run.session")
local M = {}
function M.new(deps)
	local obs = deps.obs
	local stream = session_module.new(deps)
	local recording = session_module.new(deps)
	local closing = false
	local model = deps.model
	local self = { stream = stream, recording = recording }
	local function enabled(event)
		local t = model.triggers[event]
		return t and t.enabled
	end
	local function emit(event, session, extra)
		if enabled(event) then
			deps.enqueue(event, session, extra)
		end
	end
	function self.load()
		if obs.obs_frontend_streaming_active() then
			stream.start(true, model.interval_minutes)
			if deps.resolve_live then
				deps.resolve_live(stream)
			end
		end
		if obs.obs_frontend_recording_active and obs.obs_frontend_recording_active() then
			recording.start(true, model.interval_minutes)
		end
	end
	function self.update(value)
		local changed = value.interval_minutes ~= model.interval_minutes
		model = value
		if changed then
			stream.rearm(model.interval_minutes)
		end
	end
	function self.event(event)
		if closing then
			return
		end
		if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
			if not stream.live then
				stream.start(false, model.interval_minutes)
				if deps.resolve_live then
					deps.resolve_live(stream)
				end
				emit("start", stream)
			end
		elseif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
			if stream.live then
				if deps.drop_intervals then
					deps.drop_intervals()
				end
				emit("end", stream)
				stream.stop()
			end
		elseif event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
			closing = true
			if stream.live and enabled("quit") then
				deps.enqueue("quit", stream, { immediate = true, discard_output = true, cached_secrets = stream.cache })
			else
				deps.log.info("quit post skipped")
			end
			stream.stop()
		elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
			if not recording.live then
				recording.start(false, model.interval_minutes)
				emit("rec_start", recording)
			end
		elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
			if recording.live then
				emit("rec_end", recording)
				recording.stop()
			end
		elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
			emit("replay", stream)
		end
	end
	function self.tick()
		if closing then
			return
		end
		-- An observed stop wins over an interval even if the frontend stop callback is pending.
		if stream.live and not obs.obs_frontend_streaming_active() then
			self.event(obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
			return
		end
		if enabled("interval") and stream.due(model.interval_minutes) then
			emit("interval", stream)
		end
	end
	function self.closing()
		return closing
	end
	return self
end
return M
