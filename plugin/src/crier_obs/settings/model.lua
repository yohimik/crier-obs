local descriptor = require("crier_obs.schema.descriptor")
local store_module = require("crier_obs.settings.store")
local M = {}
M.trigger_defaults = {
  start = { enabled = true, caption = "🔴 Live now: {{ .title }}" },
  ["end"] = { enabled = true, caption = "Thanks for watching! {{ .title }}" },
  interval = { enabled = true, caption = "Still live ({{ .uptime }}): {{ .title }}" },
  quit = { enabled = false, caption = "Something went wrong on our side. Don't leave, we are coming back!" },
  rec_start = { enabled = false, caption = "Recording started: {{ .title }}" },
  rec_end = { enabled = false, caption = "Recording done: {{ .title }}" },
  replay = { enabled = false, caption = "Clip: {{ .title }}" },
}
M.fields = {
  { key = "section", kind = "string", default = "platforms", label = "Section" },
  { key = "platform", kind = "string", default = "telegram", label = "Platform to configure" },
  { key = "custom_platform", kind = "string", default = "", label = "Custom platform to configure" },
  { key = "custom_names", kind = "list", default = {}, label = "Custom platform names" },
  {
    key = "interval_minutes",
    kind = "int",
    default = 60,
    min = 1,
    max = 1440,
    step = 1,
    label = "Interval in minutes",
  },
  { key = "title", kind = "string", default = "", label = "Stream title" },
  { key = "game", kind = "string", default = "", label = "Game" },
  { key = "url", kind = "string", default = "", label = "Stream URL" },
  { key = "custom_fields", kind = "list", default = {}, label = "Custom data fields (key=value)" },
  { key = "base_config", kind = "string", widget = "path", default = "", label = "Base configuration file" },
  { key = "crier_path", kind = "string", widget = "path", default = "", label = "crier path override" },
  { key = "credential_set", kind = "string", default = "default", label = "Credential set" },
  { key = "timeout", kind = "int", default = 900, min = 1, max = 86400, step = 1, label = "Run timeout in seconds" },
  {
    key = "retention_days",
    kind = "int",
    default = 7,
    min = 1,
    max = 3650,
    step = 1,
    label = "Keep run folders for days",
  },
  {
    key = "retention_count",
    kind = "int",
    default = 50,
    min = 1,
    max = 10000,
    step = 1,
    label = "Maximum run folders",
  },
  { key = "debug", kind = "bool", default = false, label = "Debug logging" },
  { key = "manual_caption", kind = "string", default = "🔴 Live now: {{ .title }}", label = "Manual caption" },
}
function M.equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not M.equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end
function M.diff(previous, current)
  local changes = {}
  for k, v in pairs(current) do
    if not previous or not M.equal(v, previous[k]) then
      changes[k] = v
    end
  end
  return changes
end
function M.new(deps)
  local store = deps.store or store_module.new(deps)
  local self = {}
  function self.defaults(data, template)
    for _, d in ipairs(descriptor.build()) do
      if not d.secret then
        store.default(data, d.key, d, d.default)
      end
    end
    for _, f in ipairs(M.fields) do
      store.default(data, "cobs." .. f.key, f, f.default)
    end
    for event, v in pairs(M.trigger_defaults) do
      store.default(data, "cobs.trigger." .. event .. ".enabled", "bool", v.enabled)
      store.default(data, "cobs.trigger." .. event .. ".caption", "string", v.caption)
    end
    store.default(data, "render.width", "int", 1080)
    store.default(data, "render.height", "int", 1080)
    store.default(data, "render.format", "string", "png")
    store.default(data, "render.hermetic-fonts", "bool", true)
    if template then
      store.default(data, "render.template", "string", template)
    end
  end
  function self.snapshot(data)
    local model = { values = {}, touched = {}, platforms = {}, triggers = {} }
    for _, f in ipairs(M.fields) do
      model[f.key] = store.get(data, "cobs." .. f.key, f)
    end
    model.interval_minutes = math.max(1, math.min(1440, model.interval_minutes))
    for _, d in ipairs(descriptor.build(model.custom_names)) do
      if not d.secret then
        if d.custom and not store.has(data, d.key) then
          model.values[d.key] = d.default
        else
          model.values[d.key] = store.get(data, d.key, d)
        end
        model.touched[d.key] = store.has(data, d.key)
      end
      if d.key:match("%.enabled$") and d.platform then
        model.platforms[d.platform] = model.values[d.key]
      end
    end
    for event in pairs(M.trigger_defaults) do
      model.triggers[event] = {
        enabled = store.get(data, "cobs.trigger." .. event .. ".enabled", "bool"),
        caption = store.get(data, "cobs.trigger." .. event .. ".caption", "string"),
      }
    end
    model.mode = model.base_config ~= "" and "advanced" or "generated"
    model.paths = { base_config = model.base_config, crier_path = model.crier_path }
    return model
  end
  self.diff = M.diff
  return self
end
return M
