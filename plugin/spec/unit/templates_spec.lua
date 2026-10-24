-- src/ runs read the default template from crier_obs.templates, while tools/bundle.lua embeds
-- templates/live.html in the bundle. Both read it the same way: this spec opens the file in text mode
-- as the bundler does, so a Windows CRLF checkout compares what the bundle would embed.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.-)spec[/\\]unit[/\\]templates_spec%.lua$") or ""
describe("default template", function()
	it("is byte for byte the same in src/ and in templates/live.html, which the bundle embeds", function()
		local file = assert(io.open(root .. "templates/live.html", "r"))
		local html = file:read("*a")
		file:close()
		-- The source module itself, not a bundle that may shadow it in package.preload.
		local mirrored = assert(loadfile(root .. "src/crier_obs/templates.lua"))()
		assert.equal(html, mirrored.live)
		assert.equal(html, mirrored["live.html"])
	end)
end)
