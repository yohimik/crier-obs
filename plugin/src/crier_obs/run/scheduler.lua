local session_module = require("crier_obs.run.session")
local M = {}
function M.new(deps)
	local obs = deps.obs
	local log = deps.log
	local stream = session_module.new(deps)
	local recording = session_module.new(deps)
	local closing = false
	-- The quit post fires once per load: from SCRIPTING_SHUTDOWN, or from the unload that ends OBS
	-- without one (a macOS application quit skips the shutdown path). A scene-collection switch also
	-- unloads the script but is not a quit; CHANGING or CLEANUP announces it first.
	local quit_handled = false
	local collection_switch = false
	local model = deps.model
	local self = { stream = stream, recording = recording }
	local function enabled(event)
		local t = model.triggers[event]
		return t and t.enabled
	end
	-- Returns the queued job, or nil when the trigger is off or the post was refused.
	local function emit(event, session, extra)
		if enabled(event) then
			log.debug("scheduler: " .. event .. " post")
			return deps.enqueue(event, session, extra)
		end
		log.debug("scheduler: " .. event .. " trigger is off")
		return nil
	end
	local function armed()
		if enabled("interval") and stream.next_due then
			log.info("Interval post armed: next post in " .. model.interval_minutes .. " min")
		end
	end
	local function stream_ended(queued)
		stream.stop()
		if not queued and deps.on_stream_end then
			deps.on_stream_end()
		end
	end
	function self.load()
		if obs.obs_frontend_streaming_active() then
			stream.start(true, model.interval_minutes, deps.stream_uptime and deps.stream_uptime())
			log.info("Loaded while live; no start post for this stream")
			armed()
			if deps.resolve_live then
				deps.resolve_live(stream)
			end
		end
		if obs.obs_frontend_recording_active() then
			recording.start(true, model.interval_minutes)
		end
	end
	function self.update(value)
		local was_enabled = enabled("interval")
		local changed = value.interval_minutes ~= model.interval_minutes
		model = value
		-- Turning the trigger on counts the interval from now, not from the stream start.
		if changed or (enabled("interval") and not was_enabled) then
			stream.rearm(model.interval_minutes)
			armed()
		end
	end
	local function quit(origin)
		quit_handled = true
		closing = true
		if stream.live and enabled("quit") then
			log.debug("scheduler: quit post from " .. origin)
			deps.enqueue("quit", stream, {
				immediate = true,
				discard_output = true,
				cached_secrets = stream.cache,
				-- At unload the frontend may already be torn down; its last snapshot is used instead.
				cached_frontend = origin ~= "SCRIPTING_SHUTDOWN",
			})
		else
			log.info("quit post skipped")
		end
		stream_ended(true)
	end
	function self.event(event, extra)
		if
			event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING
			or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP
		then
			collection_switch = true
		end
		if closing then
			return
		end
		if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
			if not stream.live then
				stream.start(false, model.interval_minutes)
				armed()
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
				stream_ended(emit("end", stream, extra) ~= nil)
			end
		elseif event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
			quit("SCRIPTING_SHUTDOWN")
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
	-- Called by the plugin's unload before it tears anything down.
	function self.unload()
		if not quit_handled and not collection_switch then
			quit("unload without SCRIPTING_SHUTDOWN")
		end
	end
	-- Runs on the graphics thread: only thread-safe frontend getters, and posts built from the
	-- frontend snapshot the UI thread keeps (extra.cached_frontend).
	function self.tick()
		if closing then
			return
		end
		-- An observed stop wins over an interval even if the frontend stop callback is pending.
		if stream.live and not obs.obs_frontend_streaming_active() then
			log.debug("scheduler: stream stopped before its frontend event; the end post wins")
			self.event(obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED, { cached_frontend = true })
			return
		end
		if enabled("interval") and stream.due(model.interval_minutes) then
			emit("interval", stream, { cached_frontend = true })
		end
	end
	function self.closing()
		return closing
	end
	return self
end
return M
