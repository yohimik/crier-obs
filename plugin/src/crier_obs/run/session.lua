local M = {}
function M.new(deps)
	local clock = deps.clock
	local self = { live = false, cache = {}, interval_index = 0 }
	-- estimated_uptime is how long the stream had run before the script saw it (loaded mid-stream).
	function self.start(estimated, minutes, estimated_uptime)
		self.generation = (self.generation or 0) + 1
		self.live = true
		local offset = estimated and math.max(0, estimated_uptime or 0) or 0
		self.started_mono = clock.now_mono() - offset
		self.started_at = clock.now_wall() - math.floor(offset)
		self.estimated = estimated or false
		self.interval_index = 0
		self.next_due = clock.now_mono() + math.max(1, minutes or 60) * 60
		self.cache = {}
		self.cache_ready = false
		self.cache_error = nil
	end
	-- A finished session keeps nothing: later offline posts carry no uptime, and the credentials
	-- resolved for the live session are dropped with it.
	function self.stop()
		self.live = false
		self.next_due = nil
		self.started_mono = nil
		self.started_at = nil
		self.estimated = false
		self.interval_index = 0
		self.cache = {}
		self.cache_ready = false
		self.cache_error = nil
		self.base_custom_names, self.base_fingerprint = nil, nil
		self.base_config_ready, self.base_config_path = false, nil
	end
	function self.uptime()
		return self.live and self.started_mono and math.max(0, clock.now_mono() - self.started_mono) or 0
	end
	function self.rearm(minutes)
		if self.live then
			self.next_due = clock.now_mono() + math.max(1, minutes or 60) * 60
		end
		return self.next_due
	end
	function self.due(minutes)
		if self.live and self.next_due and clock.now_mono() >= self.next_due then
			self.interval_index = self.interval_index + 1
			self.rearm(minutes)
			return true
		end
		return false
	end
	function self.snapshot()
		return {
			live = self.live,
			started_at = self.live and self.started_at or nil,
			estimated = self.live and self.estimated or false,
			interval_index = self.interval_index,
			uptime = self.uptime(),
		}
	end
	return self
end
return M
