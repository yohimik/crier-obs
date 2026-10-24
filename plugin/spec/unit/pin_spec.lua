local version = require("crier_obs.version")
local meta = require("crier_obs.registry.meta")
local keys = require("crier_obs.registry.keys")
local custom = require("crier_obs.registry.custom")
local overrides = require("crier_obs.schema.overrides")
local plan = require("crier_obs.invoke.plan")

local function read(path)
	local f = assert(io.open(path, "rb"))
	local text = f:read("*a")
	f:close()
	return text
end
local function write(path, text)
	local f = assert(io.open(path, "wb"))
	f:write(text)
	f:close()
end

describe("crier pin", function()
	it("mirrors crier v1.1.1's 293 fixed keys and 15 custom-platform key shapes", function()
		-- Literal on purpose: a pin bump that changes the key set must be reviewed here.
		assert.equal(293, meta.count)
		assert.equal(15, meta.custom_count)
		assert.equal(meta.count, #keys)
		assert.equal(meta.custom_count, #custom)
		assert.equal("v" .. version.CRIER_VERSION, meta.tag)
		assert.equal(version.CRIER_VERSION, meta.version)
		local known = {}
		for _, d in ipairs(keys) do
			known[d.key] = true
		end
		for key, presentation in pairs(overrides) do
			if type(presentation) == "table" then
				assert.is_true(known[key] == true, "override names no crier key: " .. key)
			end
		end
		assert.equal("CRIER_PUBLISH_TELEGRAM_TOKEN", plan.env_name("publish.telegram.token"))
		assert.equal("CRIER_RENDER_VIDEO_FRAMES_INPUT", plan.env_name("render.video.frames-input"))
	end)

	it("names the crier version only in version.lua and the generated registry", function()
		local p = assert(io.popen('find src/crier_obs -name "*.lua" -type f'))
		local offenders = {}
		local literal = version.CRIER_VERSION:gsub("%.", "%%.")
		for path in p:lines() do
			if not path:match("/version%.lua$") and not path:match("/registry/") then
				local body = read(path)
				if body:find("%f[%d]" .. literal .. "%f[^%d]") then
					offenders[#offenders + 1] = path
				end
			end
		end
		p:close()
		assert.same({}, offenders)
	end)

	it("moves only crier's own version references when the pin is bumped", function()
		pending("needs plugin/tools/update_pin.lua from the tools branch; main's copy also rewrites crier-obs links")
		local root = os.tmpname()
		os.remove(root)
		assert(os.execute("mkdir -p '" .. root .. "/docs' '" .. root .. "/plugin/src/crier_obs/registry'"))
		write(root .. "/plugin/src/crier_obs/registry/meta.lua", read("src/crier_obs/registry/meta.lua"))
		write(root .. "/plugin/src/crier_obs/version.lua", 'return { VERSION = "0.0.0-dev", CRIER_VERSION = "1.1.1" }\n')
		local fixture = table.concat({
			"See https://github.com/yohimik/crier/blob/v1.1.1/docs/configuration/README.md for keys.",
			"Install: curl -fsSL https://raw.githubusercontent.com/yohimik/crier/v1.1.1/install.sh | sh",
			"Download https://github.com/yohimik/crier-obs/releases/download/v1.1.0-rc.0/crier-obs.lua",
			"This is crier-obs v1.1.1, built for crier v1.1.1.",
			"",
		}, "\n")
		write(root .. "/README.md", fixture)
		write(root .. "/docs/setup.md", fixture)
		local tool = assert(io.popen("pwd")):read("*l") .. "/tools/update_pin.lua"
		assert(os.execute("cd '" .. root .. "' && luajit '" .. tool .. "' 1.1.1 1.2.0 >/dev/null"))
		for _, path in ipairs({ "/README.md", "/docs/setup.md" }) do
			local body = read(root .. path)
			assert.matches("github.com/yohimik/crier/blob/v1.2.0/docs/configuration/README.md", body, 1, true)
			assert.matches("raw.githubusercontent.com/yohimik/crier/v1.2.0/install.sh", body, 1, true)
			assert.matches("crier-obs/releases/download/v1.1.0-rc.0/crier-obs.lua", body, 1, true)
			assert.matches("This is crier-obs v1.1.1, built for crier v1.2.0.", body, 1, true)
		end
		assert.matches('CRIER_VERSION = "1.2.0"', read(root .. "/plugin/src/crier_obs/version.lua"), 1, true)
	end)
end)
