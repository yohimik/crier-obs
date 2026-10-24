local json = require("crier_obs.json")
local M = {}
local function percent(text, allow, form)
  local transformed = text:gsub(allow, function(c)
    if form and c == " " then
      return "+"
    end
    return string.format("%%%02X", c:byte())
  end)
  return transformed
end
-- Every spelling a secret can take in crier's output: raw, URL-encoded (path, form, lax), with
-- lower-case escapes, and JSON-escaped including Go's HTML-safe escapes.
local function variants(v)
  local forms = {
    v,
    percent(v, "([^A-Za-z0-9%-._~])", false),
    percent(v, "([^A-Za-z0-9%-._~])", true),
    percent(v, "([^A-Za-z0-9%-._~$&+:=@])", false),
  }
  local out = {}
  for _, form in ipairs(forms) do
    out[#out + 1] = form
    out[#out + 1] = (form:gsub("%%(%x%x)", function(hex)
      return "%" .. hex:lower()
    end))
  end
  for i = 1, #out do
    local encoded = json.encode(out[i])
    if encoded then
      local escaped = encoded:sub(2, -2)
      out[#out + 1] = escaped
      out[#out + 1] = (
        escaped
          :gsub("[<>&]", function(c)
            return c == "<" and "\\u003c" or c == ">" and "\\u003e" or "\\u0026"
          end)
          :gsub("\226\128\168", "\\u2028")
          :gsub("\226\128\169", "\\u2029")
      )
    end
  end
  return out
end
local function sensitive(key)
  key = key:lower()
  return key:find("token", 1, true)
    or key:find("secret", 1, true)
    or key:find("password", 1, true)
    or key:find("authorization", 1, true)
    or key:find("access-key", 1, true)
    or key:find("access_key", 1, true)
    or key:find("webhook", 1, true)
    or key:find("client-id", 1, true)
    or key:find("device-id", 1, true)
    or key:find("***", 1, true)
end
-- Index of the quote that closes the JSON string opening at `first`, skipping escaped characters.
local function quoted_end(s, first)
  local at = first + 1
  while true do
    local stop = s:find('[\\"]', at)
    if not stop then
      return nil
    end
    if s:byte(stop) == 92 then
      at = stop + 2
    else
      return stop
    end
  end
end
-- Replaces the string value of every JSON member whose key looks like a credential.
local function redact_members(s)
  local out, cursor, search = {}, 1, 1
  while true do
    local first = s:find('"', search, true)
    if not first then
      break
    end
    local close_quote = quoted_end(s, first)
    if not close_quote then
      break
    end
    local after = s:match("^%s*():", close_quote + 1)
    local value_start = after and s:match("^%s*()", after + 1)
    if value_start and s:byte(value_start) == 34 then
      local value_end = quoted_end(s, value_start)
      local raw = s:sub(first + 1, close_quote - 1)
      local key = raw:find("\\", 1, true) and json.decode(s:sub(first, close_quote)) or raw
      if type(key) == "string" and sensitive(key) then
        out[#out + 1] = s:sub(cursor, value_start - 1)
        out[#out + 1] = '"***"'
        cursor = (value_end or #s) + 1
      end
      search = (value_end or #s) + 1
    else
      search = close_quote + 1
    end
  end
  out[#out + 1] = s:sub(cursor)
  return table.concat(out)
end
function M.new(deps)
  deps = deps or {}
  -- Exact secret spellings and their escaped Lua patterns, longest first, rebuilt only on change.
  local secrets, patterns, last = {}, nil, {}
  local self = {}
  function self.register_secret(v)
    if type(v) ~= "string" or v == "" or secrets[v] then
      return
    end
    secrets[v] = true
    for _, form in ipairs(variants(v)) do
      if not secrets[form] then
        secrets[form] = true
        patterns = nil
      end
    end
    patterns = nil
  end
  function self.set_debug(enabled)
    deps.debug = enabled == true
  end
  function self.debug_enabled()
    return deps.debug == true
  end
  -- Forgets every registered value; called when the plugin unloads.
  function self.clear_secrets()
    secrets, patterns = {}, nil
  end
  local function compiled()
    if not patterns then
      local sorted = {}
      for key in pairs(secrets) do
        sorted[#sorted + 1] = key
      end
      table.sort(sorted, function(a, b)
        return #a > #b or (#a == #b and a < b)
      end)
      patterns = {}
      for i, key in ipairs(sorted) do
        patterns[i] = key:gsub("([^%w])", "%%%1")
      end
    end
    return patterns
  end
  function self.scrub(v)
    local s = tostring(v or "")
    for _, pattern in ipairs(compiled()) do
      s = s:gsub(pattern, "***")
    end
    s = s:gsub("([?&][%w_%-]*[Tt][Oo][Kk][Ee][Nn]=)[^&%s]+", "%1***")
    s = s:gsub("(bot%d+:)[%w_%-]+", "%1***")
    s = s:gsub("(/api/webhooks/%d+/)[^/%s?]+", "%1***")
    s = s:gsub("([%w_.%-]*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[=:]%s*)[^%s,;]+", "%1***")
    if s:find('"', 1, true) then
      s = redact_members(s)
    end
    s = s:gsub("([%w_.%-]+)(%s*=%s*)([^&%s,;]+)", function(key, separator, value)
      return key .. separator .. (sensitive(key) and "***" or value)
    end)
    return s
  end
  local function emit(level, msg, key, seconds)
    local now = deps.clock and deps.clock.now_mono() or os.time()
    if key and last[key] and now - last[key] < (seconds or 30) then
      return false
    end
    if key then
      last[key] = now
    end
    local obs = deps.obs
    if obs and obs.script_log then
      local text = "crier-obs: " .. self.scrub(msg)
      local severity = level == "warn" and "LOG_WARNING" or "LOG_" .. level:upper()
      -- OBS drops LOG_DEBUG lines unless it runs with --verbose, so the Debug logging setting
      -- raises the plugin's debug lines to LOG_INFO, marked as such.
      if level == "debug" and deps.debug then
        severity, text = "LOG_INFO", "crier-obs: [debug] " .. self.scrub(msg)
      end
      obs.script_log(obs[severity] or 200, text)
    end
    return true
  end
  for _, level in ipairs({ "debug", "info", "warn", "error" }) do
    local name = level
    self[name] = function(msg, key, seconds)
      return emit(name, msg, key, seconds)
    end
  end
  return self
end
local default = M.new()
M.scrub = default.scrub
M.register_secret = default.register_secret
return M
