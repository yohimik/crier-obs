local M = {}
function M.new(deps)
	local clock = deps.clock
	local self = { live = false, cache = {}, interval_index = 0 }
	function self.start(estimated, minutes)
		self.generation = (self.generation or 0) + 1
		self.live = true
		self.started_mono = clock.now_mono()
		self.started_at = clock.now_wall()
		self.estimated = estimated or false
		self.interval_index = 0
		self.next_due = self.started_mono + math.max(1, minutes or 60) * 60
		self.cache = {}
		self.cache_ready = false
		self.cache_error = nil
	end
	function self.stop()
		self.live = false
		self.next_due = nil
	end
	function self.uptime()
		return self.started_mono and math.max(0, clock.now_mono() - self.started_mono) or 0
	end
	function self.rearm(minutes)
		if self.live then
			self.next_due = clock.now_mono() + math.max(1, minutes or 60) * 60
		end
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
			started_at = self.started_at,
			estimated = self.estimated,
			interval_index = self.interval_index,
			uptime = self.uptime(),
		}
	end
	return self
end
return M
