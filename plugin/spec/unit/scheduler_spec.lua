local scheduler_module = require("crier_obs.run.scheduler")
local obs = require("obslua")

local function harness(triggers)
	obs.reset()
	local now = 0
	local posts, logs = {}, {}
	local model = { interval_minutes = 10, triggers = {} }
	for _, event in ipairs({ "start", "end", "interval", "quit", "rec_start", "rec_end", "replay" }) do
		model.triggers[event] = { enabled = triggers[event] or false }
	end
	local ended = 0
	local scheduler = scheduler_module.new({
		obs = obs,
		clock = {
			now_mono = function()
				return now
			end,
			now_wall = function()
				return 1700000000 + now
			end,
		},
		model = model,
		log = {
			info = function(text)
				logs[#logs + 1] = text
			end,
			debug = function() end,
		},
		enqueue = function(event, session, extra)
			posts[#posts + 1] = { event = event, at = now, uptime = session.snapshot().uptime, extra = extra or {} }
			return {}
		end,
		on_stream_end = function()
			ended = ended + 1
		end,
	})
	return {
		scheduler = scheduler,
		model = model,
		posts = posts,
		logs = logs,
		at = function(t)
			now = t
		end,
		ended = function()
			return ended
		end,
		events = function()
			local out = {}
			for _, post in ipairs(posts) do
				out[#out + 1] = post.event .. "@" .. post.at
			end
			return table.concat(out, " ")
		end,
	}
end
local function emit(h, event)
	if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
		obs.streaming = true
	elseif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
		obs.streaming = false
	end
	h.scheduler.event(event)
end

describe("trigger scheduling", function()
	it("counts the interval from the moment the trigger is turned on mid-stream", function()
		local h = harness({ start = true })
		emit(h, obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		h.at(3 * 3600)
		h.scheduler.tick()
		local enabled = { interval_minutes = 10, triggers = {} }
		for event, t in pairs(h.model.triggers) do
			enabled.triggers[event] = { enabled = t.enabled }
		end
		enabled.triggers.interval.enabled = true
		h.scheduler.update(enabled)
		assert.equal("Interval post armed: next post in 10 min", h.logs[#h.logs])
		h.at(3 * 3600 + 1)
		h.scheduler.tick()
		assert.equal("start@0", h.events())
		h.at(3 * 3600 + 600)
		h.scheduler.tick()
		assert.equal("start@0 interval@11400", h.events())
		assert.is_true(h.posts[2].extra.cached_frontend)
	end)
	it("posts start and end once per stream through flapping and never for a failed start", function()
		local h = harness({ start = true, ["end"] = true })
		emit(h, obs.OBS_FRONTEND_EVENT_STREAMING_STARTING)
		emit(h, obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
		assert.equal("", h.events())
		for i = 1, 3 do
			h.at(i * 10)
			emit(h, obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
			emit(h, obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
			h.at(i * 10 + 2)
			emit(h, obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
			emit(h, obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
		end
		assert.equal("start@10 end@12 start@20 end@22 start@30 end@32", h.events())
		assert.equal(2, h.posts[2].uptime)
		assert.equal(0, h.ended())
	end)
	it("lets an observed stop win over a due interval and ends sessions without an end post", function()
		local h = harness({ interval = true })
		emit(h, obs.OBS_FRONTEND_EVENT_STREAMING_STARTED)
		h.at(601)
		obs.streaming = false
		h.scheduler.tick()
		assert.equal("", h.events())
		assert.equal(1, h.ended())
		assert.is_false(h.scheduler.stream.live)
		assert.equal(0, h.scheduler.stream.snapshot().uptime)
		h.at(2000)
		h.scheduler.tick()
		assert.equal("", h.events())
	end)
	it("estimates how long the stream ran when the script loads mid-stream", function()
		obs.reset()
		obs.streaming = true
		local now = 500
		local scheduler = scheduler_module.new({
			obs = obs,
			clock = {
				now_mono = function()
					return now
				end,
				now_wall = function()
					return 1700000500
				end,
			},
			model = { interval_minutes = 1, triggers = { interval = { enabled = true } } },
			log = { info = function() end, debug = function() end },
			enqueue = function() end,
			stream_uptime = function()
				return 120
			end,
		})
		scheduler.load()
		assert.is_true(scheduler.stream.estimated)
		assert.equal(120, scheduler.stream.uptime())
		assert.equal(1700000380, scheduler.stream.snapshot().started_at)
		obs.reset()
	end)
end)
