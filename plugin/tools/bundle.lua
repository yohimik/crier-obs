local output = arg[1] or "dist/crier-obs.lua"
local version = arg[2] or "0.0.0-dev"
assert(version:match("^[%w%.%+%-]+$"), "invalid bundle version")
local f = assert(io.open("crier.version"))
local pin = f:read("*l")
f:close()
local p = assert(io.popen('find src/crier_obs -type f -name "*.lua"', "r"))
local paths = {}
for path in p:lines() do
	paths[#paths + 1] = path
end
assert(p:close())
table.sort(paths)
local chunks = { "-- crier-obs " .. version .. " | crier v" .. pin .. " | MIT License\n" }
for _, path in ipairs(paths) do
	local file = assert(io.open(path))
	local body = file:read("*a")
	file:close()
	local name = path:gsub("^src/", ""):gsub("%.lua$", ""):gsub("/", ".")
	if name == "crier_obs.version" then
		body = body:gsub("0%.0%.0%-dev", version)
	end
	if name ~= "crier_obs.templates" then
		chunks[#chunks + 1] = "package.preload["
			.. string.format("%q", name)
			.. "]=function(...)\n"
			.. body
			.. "\nend\n"
	end
end
local template = assert(io.open("templates/live.html"))
local html = template:read("*a")
template:close()
chunks[#chunks + 1] = 'package.preload["crier_obs.templates"]=function() local live='
	.. string.format("%q", html)
	.. ';return {live=live,["live.html"]=live} end\n'
chunks[#chunks + 1] = 'require("crier_obs.main")\n'
local out = assert(io.open(output, "w"))
out:write(table.concat(chunks))
out:close()
print(output .. " (" .. version .. ", crier " .. pin .. ")")
