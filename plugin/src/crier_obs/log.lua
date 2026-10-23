local json = require("crier_obs.json")
local M = {}
function M.new(deps)
  deps = deps or {}
  local secrets, last = {}, {}
  local self = {}
  function self.register_secret(v)
    if type(v) ~= "string" or v == "" then
      return
    end
    local function percent(text, allow, form)
      local transformed = text:gsub(allow, function(c)
        if form and c == " " then
          return "+"
        end
        return string.format("%%%02X", c:byte())
      end)
      return transformed
    end
    local forms = {
      v,
      percent(v, "([^A-Za-z0-9%-._~])", false),
      percent(v, "([^A-Za-z0-9%-._~])", true),
      percent(v, "([^A-Za-z0-9%-._~$&+:=@])", false),
    }
    local variants = {}
    for _, form in ipairs(forms) do
      variants[#variants + 1] = form
      variants[#variants + 1] = form:gsub("%%(%x%x)", function(hex)
        return "%" .. hex:lower()
      end)
    end
    for _, value in ipairs(variants) do
      secrets[value] = true
      local encoded = json.encode(value)
      if encoded then
        local escaped = encoded:sub(2, -2)
        secrets[escaped] = true
        escaped = escaped
          :gsub("[<>&]", function(c)
            return c == "<" and "\\u003c" or c == ">" and "\\u003e" or "\\u0026"
          end)
          :gsub("\226\128\168", "\\u2028")
          :gsub("\226\128\169", "\\u2029")
        secrets[escaped] = true
      end
    end
  end
  function self.set_debug(enabled)
    deps.debug = enabled == true
  end
  function self.clear_secrets()
    secrets = {}
  end
  function self.scrub(v)
    local s = tostring(v or "")
    local sorted = {}
    for key in pairs(secrets) do
      sorted[#sorted + 1] = key
    end
    table.sort(sorted, function(a, b)
      return #a > #b
    end)
    for _, key in ipairs(sorted) do
      s = s:gsub(key:gsub("([^%w])", "%%%1"), "***")
    end
    s = s:gsub("([?&][%w_%-]*[Tt][Oo][Kk][Ee][Nn]=)[^&%s]+", "%1***")
    s = s:gsub("(bot%d+:)[%w_%-]+", "%1***")
    s = s:gsub("(/api/webhooks/%d+/)[^/%s?]+", "%1***")
    s = s:gsub("([%w_.%-]*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[=:]%s*)[^%s,;]+", "%1***")
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
    local function quoted_end(first)
      local at = first + 1
      while at <= #s do
        local c = s:sub(at, at)
        if c == "\\" then
          at = at + 2
        elseif c == '"' then
          return at
        else
          at = at + 1
        end
      end
      return nil
    end
    local out, cursor, search = {}, 1, 1
    while true do
      local first = s:find('"', search, true)
      if not first then
        break
      end
      local close_quote = quoted_end(first)
      if not close_quote then
        break
      end
      local after = s:match("^%s*():", close_quote + 1)
      local key = json.decode(s:sub(first, close_quote))
      local value_start = after and s:match("^%s*()", after + 1)
      if value_start and s:sub(value_start, value_start) == '"' then
        local value_end = quoted_end(value_start)
        if key and sensitive(key) then
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
    s = table.concat(out)
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
      obs.script_log(
        obs[level == "warn" and "LOG_WARNING" or "LOG_" .. level:upper()] or 200,
        "crier-obs: " .. self.scrub(msg)
      )
    end
    return true
  end
  for _, level in ipairs({ "debug", "info", "warn", "error" }) do
    local name = level
    self[name] = function(msg, key, seconds)
      if name == "debug" and not deps.debug then
        return false
      end
      return emit(name, msg, key, seconds)
    end
  end
  return self
end
local default = M.new()
M.scrub = default.scrub
M.register_secret = default.register_secret
return M
