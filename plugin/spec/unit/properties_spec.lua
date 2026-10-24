local obs = require("stub.obslua")
local exports = require("stub.obslua_exports")
local properties = require("crier_obs.schema.properties")
local models = require("crier_obs.settings.model")
local descriptors = require("crier_obs.schema.descriptor")
local store = require("crier_obs.settings.store").new({ obs = obs })

local function source_files()
	local p = assert(io.popen('find src/crier_obs -name "*.lua" -type f'))
	local out = {}
	for path in p:lines() do
		out[#out + 1] = path
	end
	p:close()
	return out
end
local function read(path)
	local f = assert(io.open(path, "rb"))
	local text = f:read("*a")
	f:close()
	return text
end
local function names(props)
	local out = {}
	local function walk(ps)
		for _, p in ipairs(ps.ordered) do
			out[#out + 1] = p.name
			if p.content then
				walk(p.content)
			end
		end
	end
	walk(props)
	return out
end
local function index_of(list, name)
	for i, value in ipairs(list) do
		if value == name then
			return i
		end
	end
end
local function navigate(props, data, section, extra)
	obs.obs_data_set_string(data, "cobs.section", section)
	for k, v in pairs(extra or {}) do
		obs.obs_data_set_string(data, k, v)
	end
	return props.by_name["cobs.section"].modified(props, props.by_name["cobs.section"], data)
end

describe("OBS script properties", function()
	local data, model
	before_each(function()
		obs.reset()
		data = obs.obs_data_create()
		model = models.new({ obs = obs })
		model.defaults(data, "/template.html")
	end)
	after_each(function()
		obs.obs_data_release(data)
		obs.assert_no_leaks()
	end)

	it("only calls obs functions that OBS 32.2.2 gives Lua scripts", function()
		local missing = {}
		for _, path in ipairs(source_files()) do
			for name in read(path):gmatch("[^%w_]obs%.([%a_][%w_]*)") do
				if not exports[name] then
					missing[#missing + 1] = path .. ": obs." .. name
				end
			end
		end
		assert.same({}, missing)
		assert.has_error(function()
			return obs.obs_properties_remove
		end)
	end)

	it("never shows an info row's text twice and describes every other property", function()
		local ui = properties.new({
			obs = obs,
			model = model,
			status = {
				crier = "crier 1.1.1 at /bin/crier",
				keyring = "macOS Keychain",
				results = {
					{ target = "telegram", ok = false, error = "unavailable" },
					{ text = "Warning", warning = true },
				},
			},
		})
		local props = ui.build(data)
		local rows = 0
		local function check(ps)
			for _, p in ipairs(ps.ordered) do
				if p.kind == "text" and p.args[1] == obs.OBS_TEXT_INFO then
					rows = rows + 1
					assert.is_nil(p.description, p.name)
					local left, right = obs.render_info(p, data)
					assert.is_string(right, p.name)
					assert.is_not.equal(left, right, p.name)
				else
					assert.is_string(p.description, p.name)
					assert.is_true(#p.description > 0, p.name)
				end
				if p.content then
					check(p.content)
				end
			end
		end
		check(props)
		assert.is_true(rows > 50)
		assert.same(
			{ "crier", "crier 1.1.1 at /bin/crier" },
			{ obs.render_info(props.by_name["cobs.status.crier"], data) }
		)
		assert.same(
			{ "Credential store", "macOS Keychain" },
			{ obs.render_info(props.by_name["cobs.status.keyring"], data) }
		)
		assert.same({ "telegram", "✗  unavailable" }, { obs.render_info(props.by_name["cobs.result.1"], data) })
		assert.equal(obs.OBS_TEXT_INFO_ERROR, props.by_name["cobs.result.1"].info_type)
		assert.equal(obs.OBS_TEXT_INFO_WARNING, props.by_name["cobs.result.2"].info_type)
		assert.is_false(props.by_name["cobs.result.3"].visible)
		local left, right = obs.render_info(props.by_name["cobs.tunnel_guidance"], data)
		assert.is_nil(left)
		assert.matches("Instagram needs a public URL", right, 1, true)
		-- Row text lives in defaults, so it never reaches the saved scene collection.
		assert.is_nil(obs.obs_data_get_json(data):find("crier 1.1.1 at", 1, true))
	end)

	it("puts callbacks only on navigators and buttons, and reuses them across builds", function()
		local calls = {}
		local ui = properties.new({
			obs = obs,
			model = model,
			callbacks = {
				save_secret = function(key)
					calls[#calls + 1] = key
				end,
			},
		})
		local first = ui.build(data)
		local navigators = 0
		for _, p in pairs(first.by_name) do
			if p.modified then
				navigators = navigators + 1
				assert.is_truthy(
					({ ["cobs.section"] = 1, ["cobs.platform"] = 1, ["cobs.custom_platform"] = 1 })[p.name]
				)
			end
		end
		assert.equal(3, navigators)
		local second = ui.build(data)
		local buttons = 0
		for name, p in pairs(first.by_name) do
			if p.kind == "button" then
				buttons = buttons + 1
				assert.equal(p.callback, second.by_name[name].callback, name)
			end
			if p.modified then
				assert.equal(p.modified, second.by_name[name].modified, name)
			end
		end
		assert.is_true(buttons > 40 and buttons < 90)
		assert.is_true(second.by_name["publish.telegram.token.save"].callback())
		assert.same({ "publish.telegram.token" }, calls)
	end)

	it("orders sections as the dialog promises: guides after their platform, tunnel keys first in Staging", function()
		local props = properties.new({ obs = obs, model = model }).build(data)
		local order = names(props)
		local function before(a, b)
			assert.is_truthy(index_of(order, a), a)
			assert.is_truthy(index_of(order, b), b)
			assert.is_true(index_of(order, a) < index_of(order, b), a .. " before " .. b)
		end
		before("cobs.trigger.interval.caption", "cobs.interval_minutes")
		before("cobs.interval_minutes", "cobs.trigger.quit.enabled")
		before("publish.telegram.token.forget", "cobs.guide.telegram")
		before("cobs.guide.telegram", "cobs.guide.threads")
		before("cobs.guide.youtube", "publish.caption")
		before("cobs.tunnel_guidance", "stage.mode")
		before("cobs.guide.tunnels", "stage.mode")
		before("stage.mode", "stage.server.tunnel.mode")
		before("stage.server.tunnel.url-pattern", "stage.s3.access-key")
		before("stage.server.tunnel.mode", "stage.server.listen")
		before("cobs.base_config", "http.retry-base-delay")
		before("cobs.credential_set", "cobs.forget_all")
		local group = props.by_name["cobs.post_to"]
		assert.equal("group", group.kind)
		assert.is_truthy(group.content.by_name["publish.telegram.enabled"])
		before("cobs.post_to", "publish.telegram.enabled")
		before("publish.youtube.enabled", "cobs.title")
		navigate(props, data, "staging")
		assert.is_true(props.by_name["cobs.tunnel_guidance"].visible)
		assert.is_true(props.by_name["stage.server.tunnel.mode"].visible)
		assert.is_false(props.by_name["publish.telegram.token"].visible)
		navigate(props, data, "platforms", { ["cobs.platform"] = "discord" })
		assert.is_true(props.by_name["cobs.guide.discord"].visible)
		assert.is_false(props.by_name["cobs.guide.telegram"].visible)
		assert.is_true(props.by_name["publish.caption"].visible)
	end)

	it(
		"renames and removes custom platforms through obs_properties_remove_by_name, keeping Post to in place",
		function()
			local props = properties.new({ obs = obs, model = model }).build(data)
			store.set(data, "cobs.custom_names", "list", { "mine" })
			navigate(props, data, "custom", { ["cobs.custom_platform"] = "mine" })
			local group = props.by_name["cobs.post_to"].content
			assert.is_truthy(group.by_name["publish.custom.mine.enabled"])
			assert.is_true(props.by_name["publish.custom.mine.command"].visible)
			assert.same(
				{ "mine" },
				(function()
					local out = {}
					for _, item in ipairs(props.by_name["cobs.custom_platform"].items) do
						out[#out + 1] = item.value
					end
					return out
				end)()
			)
			store.set(data, "cobs.custom_names", "list", { "next" })
			navigate(props, data, "custom", { ["cobs.custom_platform"] = "next" })
			assert.is_nil(props.by_name["publish.custom.mine.command"])
			assert.is_nil(group.by_name["publish.custom.mine.enabled"])
			assert.is_truthy(group.by_name["publish.custom.next.enabled"])
			assert.is_true(props.by_name["publish.custom.next.command"].visible)
			store.set(data, "cobs.custom_names", "list", { "next", "next", "BAD" })
			local again = properties.new({ obs = obs, model = model }).build(data)
			assert.is_truthy(again.by_name["publish.custom.next.command"])
			assert.is_nil(again.by_name["publish.custom.BAD.command"])
		end
	)

	it("shows credential and status states in the dialog's words", function()
		local status = { secrets = {} }
		local props = properties
			.new({
				obs = obs,
				model = model,
				status = function()
					return status
				end,
			})
			.build(data)
		local function row(key)
			return select(2, obs.render_info(props.by_name[key .. ".status"], data))
		end
		local cases = {
			{ { state = "checking" }, "checking…" },
			{ { state = "saving" }, "saving…" },
			{ { state = "stored" }, "stored ✓" },
			{ { state = "not stored" }, "not stored" },
			{
				{ state = "not stored", message = "Credential store is locked" },
				"not stored: Credential store is locked",
			},
			{
				{ state = "unavailable", bound = true, message = "unlock it" },
				"stored in keyring (keyring unavailable: unlock it)",
			},
			{ { state = "unavailable", message = "no Secret Service" }, "not stored: no Secret Service" },
		}
		for _, case in ipairs(cases) do
			status.secrets["publish.telegram.token"] = case[1]
			props.by_name["cobs.refresh"].callback()
			assert.equal(case[2], row("publish.telegram.token"))
		end
		status.crier, status.crier_level, status.update_available = "Install failed: digest mismatch", "error", true
		props.by_name["cobs.refresh"].callback()
		assert.equal(
			"Install failed: digest mismatch",
			select(2, obs.render_info(props.by_name["cobs.status.crier"], data))
		)
		assert.equal(obs.OBS_TEXT_INFO_ERROR, props.by_name["cobs.status.crier"].info_type)
		assert.equal("Update crier", props.by_name["cobs.install"].label)
	end)

	it("heads the Status and Posting blocks", function()
		local props = properties.new({ obs = obs, model = model }).build(data)
		local at = {}
		for index, p in ipairs(props.ordered) do
			at[p.name] = index
		end
		assert.equal(1, at["cobs.heading.status"])
		assert.same({ nil, "Status" }, { obs.render_info(props.by_name["cobs.heading.status"], data) })
		assert.equal(2, at["cobs.status.crier"])
		assert.equal(at["cobs.trigger.start.enabled"] - 1, at["cobs.heading.posting"])
		assert.is_true(at["cobs.heading.posting"] > at["cobs.status.logs"])
		assert.same({ nil, "Posting" }, { obs.render_info(props.by_name["cobs.heading.posting"], data) })
	end)

	it("links the staging guide to crier's staging docs at the pinned tag", function()
		local props = properties.new({ obs = obs, model = model }).build(data)
		local tag = require("crier_obs.registry.meta").tag
		assert.equal(
			"https://github.com/yohimik/crier/blob/" .. tag .. "/docs/staging/README.md",
			props.by_name["cobs.guide.staging"].url
		)
	end)

	it("starts the tunnel guidance with Stage mode server, and points S3 users at Stage mode s3", function()
		local props = properties.new({ obs = obs, model = model }).build(data)
		local _, guidance = obs.render_info(props.by_name["cobs.tunnel_guidance"], data)
		local server = guidance:find("set Stage mode (stage.mode) to server", 1, true)
		assert.is_truthy(server)
		assert.is_true(server < guidance:find("ngrok:", 1, true))
		assert.is_true(server < guidance:find("zrok:", 1, true))
		assert.is_truthy(guidance:find("leave stage.server.public-url empty", 1, true))
		assert.is_truthy(guidance:find("set Stage mode (stage.mode) to s3", 1, true))
	end)

	it("gives every numeric field a 32-bit range holding its default", function()
		local props = properties.new({ obs = obs, model = model }).build(data)
		local checked = 0
		for _, p in pairs(props.by_name) do
			if p.kind == "int" then
				local min, max, step = p.args[1], p.args[2], p.args[3]
				assert.is_true(min >= -2147483648 and max <= 2147483647 and step >= 1, p.name)
				local default = data.defaults[p.name]
				if default ~= nil then
					assert.is_true(default >= min and default <= max, p.name .. " default " .. tostring(default))
				end
				checked = checked + 1
			elseif p.kind == "float" then
				assert.is_true(p.args[1] <= p.args[2] and p.args[3] > 0, p.name)
			end
		end
		assert.is_true(checked > 20)
		assert.same({ 1, 1440, 1 }, props.by_name["cobs.interval_minutes"].args)
		for _, d in ipairs(descriptors.build({ "mine" })) do
			if d.kind == "int" then
				assert.is_true(d.max <= 2147483647, d.key)
			end
		end
	end)
end)
