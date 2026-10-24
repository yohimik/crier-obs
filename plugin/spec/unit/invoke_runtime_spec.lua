local obs = require("obslua")
local json = require("crier_obs.json")
local datadoc = require("crier_obs.invoke.datadoc")
local builder = require("crier_obs.invoke.builder")
local models = require("crier_obs.settings.model")
local report = require("crier_obs.invoke.report")
local plans = require("crier_obs.invoke.plan")
local queue_module = require("crier_obs.run.queue")
local session_module = require("crier_obs.run.session")
local ping_module = require("crier_obs.run.ping")
local log = require("crier_obs.log").new({})
local function snapshot()
	local d = obs.obs_data_create()
	local m = models.new({ obs = obs })
	m.defaults(d, "/state/templates/live.html")
	local value = m.snapshot(d)
	obs.obs_data_release(d)
	return value
end
local run = {
	dir = "/state/runs/1",
	config = "/state/runs/1/config.json",
	data = "/state/runs/1/data.json",
	preview = "/state/runs/1/preview.png",
	status = "/state/runs/1/status",
	pid = "/state/runs/1/pid",
}
describe("invocation snapshots", function()
	it("sends plugin defaults and all platform enables while omitting credentials", function()
		local m = snapshot()
		m.values["publish.telegram.token"] = "SECRET"
		m.platforms.telegram = true
		local p = assert(builder.build({ model = m, run = run, executable = "/bin/crier", caption = "🔴 hi" }))
		local config = assert(json.decode(p.files[run.config]))
		assert.equal(1080, config.render.height)
		assert.is_true(config.render["hermetic-fonts"])
		assert.is_true(config.publish.telegram.enabled)
		assert.is_false(config.publish.discord.enabled)
		assert.is_nil(config.publish.telegram.token)
		assert.is_nil(config.publish.input)
		assert.equal("🔴 hi", config.publish.caption)
		assert.is_nil(table.concat(p.args, " "):find("SECRET", 1, true))
		assert.is_true(p.capture_stdout)
		local env = plans.with_secrets(p, { ["publish.telegram.token"] = "SECRET" }, log).env
		assert.equal("SECRET", env.CRIER_PUBLISH_TELEGRAM_TOKEN)
	end)
	it("preserves untouched base keys and configured inputs while forcing platform disables", function()
		local m = snapshot()
		m.mode = "advanced"
		m.base_config = "/config/base.json"
		m.touched["render.width"] = true
		m.values["render.width"] = 720
		local p = assert(builder.build({ model = m, run = run, executable = "/bin/crier", caption = "end" }))
		local text = table.concat(p.args, "|")
		assert.is_truthy(text:find("render.width=720", 1, true))
		assert.is_nil(text:find("render.height=", 1, true))
		assert.is_nil(text:find("--log-level", 1, true))
		assert.is_truthy(text:find("publish.discord.enabled=false", 1, true))
		assert.is_nil(text:find("publish.input=", 1, true))
		assert.equal("/config", p.cwd)
		assert.is_nil(next(p.files))
	end)
	it("pins the untouched dialog's generated config and advanced --set list exactly", function()
		local platforms = { "boosty", "discord", "facebook", "instagram", "linkedin", "mastodon", "reddit", "slack",
			"telegram", "threads", "tiktok", "vk", "x", "youtube" }
		local m = snapshot()
		local p = assert(builder.build({ model = m, run = run, executable = "/bin/crier", caption = "c" }))
		assert.same({ "--config", run.config, "--json", "--log-level", "info" }, p.args)
		local publish = { caption = "c" }
		for _, name in ipairs(platforms) do
			publish[name] = { enabled = false }
		end
		assert.same({
			publish = publish,
			render = {
				data = run.data,
				height = 1080,
				["hermetic-fonts"] = true,
				template = "/state/templates/live.html",
			},
		}, json.decode(p.files[run.config]))
		m.mode, m.base_config = "advanced", "/config/base.json"
		local q = assert(builder.build({ model = m, run = run, executable = "/bin/crier", caption = "c" }))
		local expected = { "--config", "/config/base.json", "--json" }
		local sets = { "publish.caption=c", "render.data=" .. run.data }
		for _, name in ipairs(platforms) do
			sets[#sets + 1] = "publish." .. name .. ".enabled=false"
		end
		table.sort(sets)
		for _, set in ipairs(sets) do
			expected[#expected + 1] = "--set"
			expected[#expected + 1] = set
		end
		assert.same(expected, q.args)
		assert.same({}, q.files)
	end)
	it("turns crier's own video rendering off for a clip and leaves out platforms that cannot post video", function()
		local m = snapshot()
		m.custom_names = { "images", "clips" }
		m.values["publish.custom.clips.kinds"] = { " Video " }
		m.values["render.video.enabled"] = true
		m.values["render.video.frames-input"] = "/frames"
		for _, name in ipairs({ "boosty", "telegram", "youtube", "images", "clips" }) do
			m.platforms[name] = true
		end
		local p = assert(builder.build({ model = m, run = run, executable = "/bin/crier", clip = "/clips/a.mp4" }))
		local config = assert(json.decode(p.files[run.config]))
		assert.is_false(config.render.video.enabled)
		assert.equal("", config.render.video["frames-input"])
		assert.equal("/clips/a.mp4", config.publish.input)
		assert.is_false(config.publish.boosty.enabled)
		assert.is_false(config.publish.custom.images.enabled)
		assert.is_true(config.publish.custom.clips.enabled)
		assert.is_true(config.publish.telegram.enabled)
		assert.is_true(config.publish.youtube.enabled)
		assert.same({ "Clip post leaves out platforms that cannot post video: boosty, images" }, p.warnings)
		m.mode, m.base_config = "advanced", "/config/base.json"
		local q = assert(builder.build({ model = m, run = run, executable = "/bin/crier", clip = "/clips/a.mp4" }))
		local sets = {}
		for i, arg in ipairs(q.args) do
			if arg == "--set" then
				sets[q.args[i + 1]] = true
			end
		end
		for _, set in ipairs({ "render.video.enabled=false", "render.video.frames-input=", "publish.boosty.enabled=false",
			"publish.custom.images.enabled=false", "publish.custom.clips.enabled=true", "publish.input=/clips/a.mp4" }) do
			assert.is_true(sets[set], set)
		end
		m.mode = "generated"
		for name in pairs(m.platforms) do
			m.platforms[name] = false
		end
		m.platforms.boosty, m.platforms.images = true, true
		local none, why = builder.build({ model = m, run = run, executable = "/bin/crier", clip = "/clips/a.mp4" })
		assert.is_nil(none)
		assert.equal("skipped", why.kind)
		assert.equal("Clip post skipped: none of the selected platforms can post video (boosty, images)", why.message)
		-- Credentials of the platforms left out are not resolved for the clip.
		m.platforms.telegram = true
		local r = assert(builder.build({ model = m, run = run, executable = "/bin/crier", clip = "/clips/a.mp4" }))
		for _, key in ipairs(r.needs_secrets) do
			assert.is_nil(key:find("boosty", 1, true))
		end
	end)
	it("expands custom environment entries as config objects and clips with Unicode paths", function()
		local m = snapshot()
		m.custom_names = { "community" }
		m.platforms.community = true
		m.values["publish.custom.community.kinds"] = { "image", "video" }
		m.values["publish.custom.community.env"] = { "FOO=a=b", "OTHER=🔴" }
		local p = assert(builder.build({ model = m, run = run, executable = "/bin/crier", clip = "/clips/a 🔴.mp4" }))
		local config = assert(json.decode(p.files[run.config]))
		assert.equal("a=b", config.publish.custom.community.env.FOO)
		assert.equal("🔴", config.publish.custom.community.env.OTHER)
		assert.is_true(config.publish.custom.community.enabled)
		assert.equal("/clips/a 🔴.mp4", config.publish.input)
		assert.is_truthy(table.concat(p.args, "|"):find("--publish-input|/clips/a 🔴.mp4", 1, true))
	end)
	it("reports comma list ambiguity and refuses oversized advanced argv", function()
		local m = snapshot()
		m.mode = "advanced"
		m.base_config = "/base.json"
		m.touched["render.css"] = true
		m.values["render.css"] = { "has,comma.css" }
		local p = assert(builder.build({ model = m, run = run, executable = "/bin/crier" }))
		assert.equal(1, #p.warnings)
		local value, e = builder.build({ model = m, run = run, executable = "/bin/crier", argv_limit = 10 })
		assert.is_nil(value)
		assert.equal("arguments", e.kind)
	end)
	it("merges user documents without losing explicit nulls, arrays or context fields", function()
		local user = assert(json.decode('{"title":"user title","fields":{"one":"user"},"nil":null,"array":[]}'))
		local merged =
			datadoc.merge(user, { title = "stream", fields = { one = "context", two = "kept" }, event = "start" })
		assert.equal("user title", merged.title)
		assert.equal("kept", merged.fields.two)
		assert.equal(json.null, merged["nil"])
		assert.equal("[]", json.encode(merged.array))
		assert.equal("user", merged.fields.one)
		assert.equal("start", merged.event)
		local doc = datadoc.build({
			event = "start",
			model = { custom_fields = { "a=b=c" }, platforms = { telegram = true } },
			frontend = { scene = "Scene", stream_key = "NOT_ALLOWED" },
			now = 1,
			uptime = 3661,
		})
		assert.equal("b=c", doc.fields.a)
		assert.equal("01:01:01", doc.uptime)
		assert.is_nil(doc.stream_key)
	end)
	it("scrubs every structured string, exit message and only the final 20 stderr lines", function()
		log.register_secret("LEAK_TOKEN")
		local lines = {}
		for i = 1, 30 do
			lines[#lines + 1] = "line " .. i .. " LEAK_TOKEN"
		end
		local result = report.parse(
			{ code = 4, stdout = '{"results":[{"error":"LEAK_TOKEN"}]}', stderr = table.concat(lines, "\n") },
			log
		)
		assert.equal("warn", result.level)
		assert.equal("***", result.results[1].error)
		assert.is_nil(result.stderr:find("LEAK_TOKEN", 1, true))
		assert.is_nil(result.stderr:find("line 10 ", 1, true))
		assert.is_truthy(result.stderr:find("line 11 ", 1, true))
	end)
end)
describe("advanced staging credentials", function()
	it("resolves stored S3 keys when an untouched dialog allows the base to select S3", function()
		local m = snapshot()
		m.mode = "advanced"
		m.base_config = "/base.json"
		local p = assert(builder.build({ model = m, run = run, executable = "/crier" }))
		local selected = {}
		for _, key in ipairs(p.needs_secrets) do
			selected[key] = true
		end
		assert.is_true(selected["stage.s3.secret-key"])
		m.touched["stage.mode"] = true
		p = assert(builder.build({ model = m, run = run, executable = "/crier" }))
		selected = {}
		for _, key in ipairs(p.needs_secrets) do
			selected[key] = true
		end
		assert.is_nil(selected["stage.s3.secret-key"])
	end)
end)

describe("queue, monotonic sessions and setup jobs", function()
	it("coalesces intervals, keeps important events, and cancels evicted snapshots", function()
		local cancelled = 0
		local function job(event)
			return {
				event = event,
				start = function() end,
				tick = function() end,
				finished = function()
					return false
				end,
				cancel = function()
					cancelled = cancelled + 1
				end,
			}
		end
		local q = queue_module.new({ bound = 2 })
		assert(q.push(job("interval")))
		assert.is_false(q.push(job("interval")))
		assert(q.push(job("manual")))
		assert(q.push(job("end")))
		assert.equal(1, cancelled)
		assert.equal("manual", q.items()[1].event)
		q.drop_intervals()
		assert.equal(2, q.size())
	end)
	it("rearms intervals after a sleep gap and tracks session generations", function()
		local now = 0
		local s = session_module.new({
			clock = {
				now_mono = function()
					return now
				end,
				now_wall = function()
					return 100 + now
				end,
			},
		})
		s.start(true, 1)
		local first = s.generation
		now = 600
		assert.is_true(s.due(1))
		assert.is_false(s.due(1))
		assert.equal(1, s.interval_index)
		s.stop()
		assert.is_false(s.due(1))
		s.start(false, 1)
		assert.equal(first + 1, s.generation)
	end)
	it("keeps check requests exclusive and renders structured failures with nonzero exits", function()
		local spawned = 0
		local pending = {}
		local ping = ping_module.new({
			fs = {
				write = function()
					return true
				end,
			},
			env = {
				sandbox_status = function()
					return { kind = "native", ok = true }
				end,
			},
			find_binary = function() end,
			runs = {
				finish = function()
					return true
				end,
			},
			log = log,
			secrets = {
				backend_status = function()
					return { state = "ready", name = "fake" }
				end,
				resolve = function(_, _, cb)
					pending[#pending + 1] = cb
				end,
			},
			spawner = {
				spawn = function(plan)
					spawned = spawned + 1
					local done = false
					return {
						poll = function()
							if done then
								return nil
							end
							done = true
							return {
								code = plan.kind == "ping" and 5 or 0,
								stdout = plan.kind == "ping"
										and '{"results":[{"target":"telegram","ok":false,"error":"LEAK_TOKEN"},{"target":"stage","ok":true}]}'
									or "{}",
							}
						end,
					}
				end,
			},
		})
		local m = snapshot()
		local plan = assert(builder.build({ model = m, run = run, executable = "/bin/crier" }))
		assert(ping.start(m, "/bin/crier", plan))
		assert.is_false(ping.start(m, "/bin/crier", plan))
		pending[1]({})
		assert.is_false(ping.start(m, "/bin/crier", plan))
		ping.tick()
		local found = false
		for _, row in ipairs(ping.rows()) do
			if row.target == "telegram" then
				found = true
				assert.is_false(row.ok)
				assert.equal("***", row.error)
			end
		end
		assert.is_true(found)
		assert.equal(2, spawned)
	end)
end)
