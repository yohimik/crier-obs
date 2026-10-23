local old, new = assert(arg[1]), assert(arg[2])
assert(old:match("^%d+%.%d+%.%d+$") and new:match("^%d+%.%d+%.%d+$"))
local p = assert(io.popen('find docs -type f -name "*.md"'))
local paths = { "README.md", "plugin/src/crier_obs/version.lua" }
for path in p:lines() do
  paths[#paths + 1] = path
end
assert(p:close())
local pattern = old:gsub("%.", "%%.")
local meta = assert(loadfile("plugin/src/crier_obs/registry/meta.lua"))()
for _, path in ipairs(paths) do
  local f = assert(io.open(path))
  local body = f:read("*a")
  f:close()
  body =
    body:gsub("v" .. pattern, "v" .. new):gsub('CRIER_VERSION = "' .. pattern .. '"', 'CRIER_VERSION = "' .. new .. '"')
  if path == "README.md" then
    body = body:gsub("all %d+ fixed crier settings", "all " .. meta.count .. " fixed crier settings"):gsub(
      "the %d+ settings for each custom platform",
      "the " .. meta.custom_count .. " settings for each custom platform"
    )
  end
  f = assert(io.open(path, "w"))
  f:write(body)
  f:close()
end
