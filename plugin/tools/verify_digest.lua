package.path = "src/?.lua;" .. package.path
local json = require("crier_obs.json")
local f = assert(io.open(arg[1]))
local release = assert(json.decode(f:read("*a")))
f:close()
local expected
for _, asset in ipairs(release.assets or {}) do
  if asset.name == arg[2] then
    expected = asset.digest
  end
end
assert(expected and expected:match("^sha256:%x+$"), "release has no SHA-256 digest")
local function quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
local p = assert(io.popen("openssl dgst -sha256 " .. quote(arg[3])))
local actual = p:read("*a"):match("(%x+)%s*$")
assert(p:close())
assert("sha256:" .. tostring(actual) == expected, "release digest mismatch")
