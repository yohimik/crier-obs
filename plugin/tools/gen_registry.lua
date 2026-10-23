-- Read generated reference tables at the exact git tag, never the working tree.
package.path = "src/?.lua;src/?/init.lua;" .. package.path
local json = require("crier_obs.json")
local pinfile = assert(io.open("crier.version"))
local pin = pinfile:read("*l")
pinfile:close()
local source = arg[1] or "../../crier"
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
local function git(command)
  local p = assert(io.popen("git -C " .. shell_quote(source) .. " " .. command, "r"))
  local s = p:read("*a")
  assert(p:close(), "cannot read pinned crier source")
  return s
end
local tag = "v" .. pin
local paths = git("ls-tree -r --name-only " .. shell_quote(tag) .. " docs/configuration")
local fixed, custom = {}, {}
local function default(kind, text)
  local s = text:match("`(.-)`") or ""
  s = s:gsub("&#124;", "|"):gsub("&lt;", "<"):gsub("&gt;", ">")
  if kind == "bool" then
    return s == "true"
  end
  if kind == "int" or kind == "float" then
    return tonumber(s) or 0
  end
  if kind == "list" then
    local out = {}
    for v in s:gmatch("[^,]+") do
      out[#out + 1] = v:match("^%s*(.-)%s*$")
    end
    return out
  end
  return s
end
for path in paths:gmatch("[^\n]+") do
  local text = git("show " .. shell_quote(tag .. ":" .. path))
  for line in text:gmatch("[^\n]+") do
    local key, typ, def, desc = line:match("^| `([^`]+)`.- | ([^|]+) | ([^|]+) | (.-) |$")
    if key then
      local kind = typ:match("^%s*([^,%s]+)")
      local platform = key:match("^publish%.([^.]+)%.")
      local section = key:match("^publish%.") and "platforms"
        or (key:match("^render%.video%.") and "video")
        or (key:match("^render%.") and "render")
        or (key:match("^stage%.") and "staging")
        or "advanced"
      local d = {
        key = key,
        kind = kind,
        default = default(kind, def),
        secret = desc:find("**Secret**", 1, true) ~= nil,
        path = typ:find("path", 1, true) ~= nil,
        description = desc:gsub(" %*%*Secret%*%*:.*", ""),
        section = section,
        platform = platform,
      }
      if key:find("<name>", 1, true) then
        d.section = "custom"
        d.platform = nil
        custom[#custom + 1] = d
      else
        fixed[#fixed + 1] = d
      end
    end
  end
end
table.sort(fixed, function(a, b)
  return a.key < b.key
end)
assert(#fixed > 0 and #custom > 0, "pinned reference tables have no configuration keys")
if pin == "1.1.1" then
  assert(#fixed == 293, "expected 293 fixed keys, got " .. #fixed)
  assert(#custom == 15, "expected 15 custom key shapes, got " .. #custom)
end
local function lua(v)
  if type(v) == "string" then
    return string.format("%q", v)
  end
  if type(v) ~= "table" then
    return tostring(v)
  end
  if #v > 0 then
    local parts = {}
    for _, x in ipairs(v) do
      parts[#parts + 1] = lua(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    out[#out + 1] = "[" .. lua(k) .. "]=" .. lua(v[k])
  end
  return "{" .. table.concat(out, ",") .. "}"
end
local function emit(name, value)
  local f = assert(io.open("src/crier_obs/registry/" .. name .. ".lua", "w"))
  f:write("-- Generated from crier " .. tag .. "; run tools/gen_registry.lua.\nreturn ", lua(value), "\n")
  f:close()
end
-- Optional pinned binary output cross-check; use `crier init --full --format json`.
if arg[2] then
  local f = assert(io.open(arg[2]))
  local binary = assert(json.decode(f:read("*a")))
  f:close()
  for _, d in ipairs(fixed) do
    local v = binary
    for key in d.key:gmatch("[^.]+") do
      if type(v) == "table" then
        v = v[key]
      else
        v = nil
      end
    end
    assert(v ~= nil, "binary missing " .. d.key)
    if d.secret then
      assert(
        type(v) == "string" and (v == "" or v:match("^<your%-.+>$")),
        "unexpected binary secret placeholder " .. d.key
      )
    elseif type(d.default) == "table" then
      assert(type(v) == "table", "binary type differs for " .. d.key)
      if v ~= json.null then
        assert(#v == #d.default, "binary list differs for " .. d.key)
      end
    else
      assert(
        (d.kind == "float" and tonumber(v) == d.default) or v == d.default,
        "binary default differs for " .. d.key .. ": " .. tostring(v) .. " / " .. tostring(d.default)
      )
    end
  end
end
emit("keys", fixed)
emit("custom", custom)
emit("meta", {
  version = pin,
  tag = tag,
  count = #fixed,
  custom_count = #custom,
  source_commit = git("rev-parse " .. shell_quote(tag)):gsub("%s+$", ""),
})
print("Registry: " .. #fixed .. " fixed + " .. #custom .. " custom keys at " .. tag)
