-- Move crier's own version references from <old> to <new>: links into crier's repository at its tag,
-- "crier v<old>" and "pinned v<old>" prose, and CRIER_VERSION in version.lua. crier-obs's own tags share
-- crier's version line and are left alone, as is any longer version such as v<old>0 or v<old>-rc.1.
local old, new = assert(arg[1]), assert(arg[2])
assert(old:match("^%d+%.%d+%.%d+$") and new:match("^%d+%.%d+%.%d+$"))
local pattern = old:gsub("%.", "%%.")
local leads = {
	"github%.com/yohimik/crier/[%a/]-v", -- blob/, tree/, releases/tag/, releases/download/
	"raw%.githubusercontent%.com/yohimik/crier/v",
	"yohimik/crier@v",
	"%f[%w%-][Cc]rier v",
	"%f[%w%-][Pp]inned v",
}
local function rewrite(body)
	local count = 0
	for _, lead in ipairs(leads) do
		local subject = body
		body = subject:gsub("(" .. lead .. ")" .. pattern .. "()", function(prefix, after)
			local rest = subject:sub(after, after + 1)
			if rest:match("^%d") or rest:match("^[%.%-+]%w") then
				return nil
			end
			count = count + 1
			return prefix .. new
		end)
	end
	return body, count
end
local p = assert(io.popen('find docs -type f -name "*.md"'))
local paths = { "README.md", "plugin/src/crier_obs/version.lua" }
for path in p:lines() do
	paths[#paths + 1] = path
end
assert(p:close())
local meta = assert(loadfile("plugin/src/crier_obs/registry/meta.lua"))()
for _, path in ipairs(paths) do
	local f = assert(io.open(path))
	local body = f:read("*a")
	f:close()
	local count, pinned
	body, count = rewrite(body)
	if path == "plugin/src/crier_obs/version.lua" then
		body, pinned = body:gsub('CRIER_VERSION = "' .. pattern .. '"', 'CRIER_VERSION = "' .. new .. '"')
		assert(pinned == 1, "version.lua does not pin crier " .. old)
		count = count + pinned
	end
	if path == "README.md" then
		body = body:gsub("all %d+ fixed crier settings", "all " .. meta.count .. " fixed crier settings"):gsub(
			"the %d+ settings for each custom platform",
			"the " .. meta.custom_count .. " settings for each custom platform"
		)
	end
	f = assert(io.open(path, "w"))
	f:write(body)
	f:close()
	if count > 0 then
		print(path .. ": " .. count .. " crier reference(s) moved to " .. new)
	end
end
