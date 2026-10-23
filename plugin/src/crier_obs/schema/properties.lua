local descriptors = require("crier_obs.schema.descriptor")
local layout = require("crier_obs.schema.layout")
local models = require("crier_obs.settings.model")
local stores = require("crier_obs.settings.store")
local i18n = require("crier_obs.i18n")
local meta = require("crier_obs.registry.meta")
local M = {}
function M.new(deps)
  local obs = assert(deps.obs)
  local store = deps.store or stores.new(deps)
  local model = deps.model or models.new({ obs = obs, store = store })
  local t = deps.translate or i18n.new(obs.obs_get_locale())
  local callbacks = deps.callbacks or {}
  local self = {}
  local function describe(p, text)
    obs.obs_property_set_long_description(p, text)
    return p
  end
  local function value_property(props, name, d)
    local label = t(d.label or d.key or name)
    local p
    if d.widget == "enum" then
      p = obs.obs_properties_add_list(props, name, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
      for _, v in ipairs(d.enum) do
        obs.obs_property_list_add_string(p, t(v), v)
      end
    elseif d.secret or d.widget == "password" then
      p = obs.obs_properties_add_text(props, name, label, obs.OBS_TEXT_PASSWORD)
    elseif d.kind == "bool" then
      p = obs.obs_properties_add_bool(props, name, label)
    elseif d.kind == "int" then
      p = obs.obs_properties_add_int(props, name, label, d.min or 0, d.max or 2147483647, d.step or 1)
    elseif d.kind == "float" then
      p = obs.obs_properties_add_float(props, name, label, d.min or 0, d.max or 1e9, d.step or 0.01)
    elseif d.kind == "list" then
      p = obs.obs_properties_add_editable_list(props, name, label, obs.OBS_EDITABLE_LIST_TYPE_STRINGS, "", "")
    elseif d.path or d.widget == "path" then
      p = obs.obs_properties_add_path(
        props,
        name,
        label,
        d.directory and obs.OBS_PATH_DIRECTORY or obs.OBS_PATH_FILE,
        d.filter or "All files (*.*)",
        nil
      )
    else
      p =
        obs.obs_properties_add_text(props, name, label, d.multiline and obs.OBS_TEXT_MULTILINE or obs.OBS_TEXT_DEFAULT)
    end
    describe(p, t(d.description or d.label or name))
    obs.obs_property_set_modified_callback(p, function()
      return false
    end)
    return p
  end
  local function button(props, name, label, callback)
    return describe(
      obs.obs_properties_add_button(props, name, t(label), callback or function()
        return false
      end),
      t(label)
    )
  end
  local function url(props, name, label, target)
    local p = button(props, name, label)
    if obs.obs_property_button_set_type then
      obs.obs_property_button_set_type(p, obs.OBS_BUTTON_URL or 1)
    end
    if obs.obs_property_button_set_url then
      obs.obs_property_button_set_url(p, target)
    end
    return p
  end
  local function info(props, name, text, kind)
    text = t(text)
    local p = describe(obs.obs_properties_add_text(props, name, text, obs.OBS_TEXT_INFO), text)
    obs.obs_property_text_set_info_type(p, kind or obs.OBS_TEXT_INFO_NORMAL)
    if obs.obs_property_text_set_info_word_wrap then
      obs.obs_property_text_set_info_word_wrap(p, true)
    end
    return p
  end
  local function invoke(name, ...)
    if callbacks[name] then
      callbacks[name](...)
    end
    return true
  end
  function self.build(settings)
    local values = model.snapshot(settings)
    local props = obs.obs_properties_create()
    local list = descriptors.build(values.custom_names)
    local refresh_visibility
    local function refresh_action(name, ...)
      invoke(name, ...)
      if refresh_visibility then
        refresh_visibility(nil, nil, settings)
      end
      return true
    end
    local function read_status()
      return type(deps.status) == "function" and deps.status() or deps.status or {}
    end
    local status = read_status()
    info(props, "cobs.status.crier", t(status.crier or "crier is not installed"))
    button(props, "cobs.install", status.update_available and "update" or "install", function()
      return refresh_action("install")
    end)
    local docs = "https://github.com/yohimik/crier/blob/" .. meta.tag .. "/docs/"
    url(props, "cobs.install_docs", "Install crier documentation", docs .. "operations/install.md")
    info(props, "cobs.status.keyring", t(status.keyring or "Credential store: checking…"))
    info(props, "cobs.status.last_run", t(status.last_run or "No posts yet"))
    info(props, "cobs.status.logs", t(status.logs or "Run logs are stored in the crier-obs state folder"))
    local order = { "start", "end", "interval", "quit", "rec_start", "rec_end", "replay" }
    local labels = {
      start = "When streaming starts",
      ["end"] = "When streaming ends",
      interval = "Every N minutes while live",
      quit = "When OBS quits while live",
      rec_start = "When recording starts",
      rec_end = "When recording ends",
      replay = "When a replay is saved",
    }
    for _, event in ipairs(order) do
      value_property(props, "cobs.trigger." .. event .. ".enabled", { kind = "bool", label = labels[event] })
      value_property(
        props,
        "cobs.trigger." .. event .. ".caption",
        { kind = "string", label = labels[event] .. " caption", multiline = true }
      )
    end
    local platform_names = descriptors.platforms()
    local custom_names, seen_names = {}, {}
    for _, name in ipairs(values.custom_names) do
      if descriptors.valid_custom(name) and not seen_names[name] then
        seen_names[name] = true
        platform_names[#platform_names + 1] = name
        custom_names[#custom_names + 1] = name
      end
    end
    for _, name in ipairs(platform_names) do
      value_property(
        props,
        "publish." .. (descriptors.valid_custom(name) and "custom." or "") .. name .. ".enabled",
        { kind = "bool", label = "Post to: " .. name, description = "Post every enabled trigger to " .. name }
      )
    end
    for _, f in ipairs(models.fields) do
      if f.key ~= "section" and f.key ~= "platform" and f.key ~= "custom_platform" then
        value_property(props, "cobs." .. f.key, f)
      end
    end
    for _, name in ipairs({ "check", "refresh", "dry_run", "post" }) do
      local action = name
      button(props, "cobs." .. name, name, function()
        return refresh_action(action)
      end)
    end
    local result_properties = {}
    local function row_text(row)
      if row.text then
        return row.text
      end
      local parts =
        { row.ok == false and "✗" or row.warning and "!" or row.ok and "✓" or "…", tostring(row.target or "") }
      for _, name in ipairs({ "account", "message", "error" }) do
        if row[name] and row[name] ~= "" then
          parts[#parts + 1] = tostring(row[name])
        end
      end
      if row.ms then
        parts[#parts + 1] = tostring(row.ms) .. " ms"
      end
      return table.concat(parts, "  ")
    end
    local function update_results()
      local rows = status.results or {}
      for i = 1, math.max(32, #rows) do
        if not result_properties[i] then
          result_properties[i] = info(props, "cobs.result." .. i, t("Check setup result"))
        end
      end
      for index, p in ipairs(result_properties) do
        local row = rows[index]
        obs.obs_property_set_visible(p, row ~= nil)
        if row then
          local text = row_text(row)
          obs.obs_property_set_description(p, text)
          describe(p, text)
          obs.obs_property_text_set_info_type(
            p,
            row.ok == false and obs.OBS_TEXT_INFO_ERROR
              or row.warning and obs.OBS_TEXT_INFO_WARNING
              or obs.OBS_TEXT_INFO_NORMAL
          )
        end
      end
    end
    update_results()
    local section = value_property(
      props,
      "cobs.section",
      { kind = "string", widget = "enum", enum = layout.sections, label = "section" }
    )
    local platform = value_property(
      props,
      "cobs.platform",
      { kind = "string", widget = "enum", enum = descriptors.platforms(), label = "platform" }
    )
    local custom = value_property(
      props,
      "cobs.custom_platform",
      { kind = "string", widget = "enum", enum = custom_names, label = "custom_platform" }
    )
    local groups = {}
    local function add_descriptor(d)
      if d.platform and d.key:match("%.enabled$") then
        return
      end
      local p = value_property(props, d.key, d)
      groups[d.key] = { p }
      if d.secret then
        local key = d.key
        groups[d.key][#groups[d.key] + 1] = button(props, key .. ".save", "save", function()
          return refresh_action("save_secret", key, settings)
        end)
        local text = (status.secrets or {})[key] or t("not_stored")
        groups[d.key][#groups[d.key] + 1] = info(props, key .. ".status", text)
        groups[d.key][#groups[d.key] + 1] = button(props, key .. ".forget", "forget", function()
          return refresh_action("forget_secret", key)
        end)
      end
    end
    for _, d in ipairs(list) do
      add_descriptor(d)
    end
    local guides = {}
    for _, name in ipairs(descriptors.platforms()) do
      guides[name] = url(props, "cobs.guide." .. name, "guide", docs .. "publishing/" .. name .. ".md")
    end
    local custom_guide = url(props, "cobs.guide.custom", "Custom platform guide", docs .. "publishing/custom.md")
    local tunnel = info(props, "cobs.tunnel_guidance", t("tunnel_guidance"))
    local stage_guide = url(props, "cobs.guide.staging", "Staging guide", docs .. "configuration/stage/README.md")
    local tunnel_guide = url(props, "cobs.guide.tunnels", "Tunnel guide", docs .. "staging/tunnels.md")
    local ngrok = url(props, "cobs.install.ngrok", "Install ngrok", "https://ngrok.com/downloads")
    local zrok = url(props, "cobs.install.zrok", "Install zrok", "https://docs.zrok.io/docs/getting-started/")
    local forget_all = button(props, "cobs.forget_all", "Forget all credentials in this credential set", function()
      return refresh_action("forget_all")
    end)
    local function sync_status()
      status = read_status()
      for name, fallback in pairs({
        crier = "crier is not installed",
        keyring = "Credential store: checking…",
        last_run = "No posts yet",
        logs = "Run logs are stored in the crier-obs state folder",
      }) do
        local p = obs.obs_properties_get(props, "cobs.status." .. name)
        local text = t(status[name] or fallback)
        obs.obs_property_set_description(p, text)
        describe(p, text)
      end
      obs.obs_property_set_description(
        obs.obs_properties_get(props, "cobs.install"),
        t(status.update_available and "update" or "install")
      )
      for _, d in ipairs(list) do
        if d.secret then
          local p = obs.obs_properties_get(props, d.key .. ".status")
          local text = (status.secrets or {})[d.key] or t("not_stored")
          obs.obs_property_set_description(p, text)
          describe(p, text)
        end
      end
      update_results()
    end
    local known_names = values.custom_names
    local function sync_custom(snapshot)
      if models.equal(known_names, snapshot.custom_names) then
        return
      end
      local next_list = descriptors.build(snapshot.custom_names)
      local present = {}
      for _, d in ipairs(next_list) do
        present[d.key] = true
      end
      for _, d in ipairs(list) do
        if d.custom and not present[d.key] then
          obs.obs_properties_remove(props, d.key)
          groups[d.key] = nil
        end
      end
      local previous = {}
      for _, d in ipairs(list) do
        previous[d.key] = true
      end
      for _, d in ipairs(next_list) do
        if d.custom and not previous[d.key] then
          store.default(settings, d.key, d, d.default)
          if d.key:match("%.enabled$") then
            value_property(props, d.key, { kind = "bool", label = "Post to: " .. d.platform })
          else
            add_descriptor(d)
          end
        end
      end
      obs.obs_property_list_clear(custom)
      local seen = {}
      for _, name in ipairs(snapshot.custom_names) do
        if descriptors.valid_custom(name) and not seen[name] then
          obs.obs_property_list_add_string(custom, name, name)
          seen[name] = true
        end
      end
      known_names = snapshot.custom_names
      list = next_list
    end
    local function visibility(_, _, data)
      local snapshot = model.snapshot(data)
      sync_custom(snapshot)
      sync_status()
      for _, d in ipairs(list) do
        for _, p in ipairs(groups[d.key] or {}) do
          obs.obs_property_set_visible(p, layout.visible(d, snapshot))
        end
      end
      obs.obs_property_set_visible(platform, snapshot.section == "platforms")
      obs.obs_property_set_visible(custom, snapshot.section == "custom")
      for name, p in pairs(guides) do
        obs.obs_property_set_visible(p, snapshot.section == "platforms" and name == snapshot.platform)
      end
      obs.obs_property_set_visible(custom_guide, snapshot.section == "custom")
      obs.obs_property_set_visible(obs.obs_properties_get(props, "cobs.custom_names"), snapshot.section == "custom")
      for _, p in ipairs({ tunnel, stage_guide, tunnel_guide, ngrok, zrok }) do
        obs.obs_property_set_visible(p, snapshot.section == "staging")
      end
      for _, name in ipairs({
        "base_config",
        "crier_path",
        "credential_set",
        "timeout",
        "retention_days",
        "retention_count",
        "debug",
      }) do
        obs.obs_property_set_visible(obs.obs_properties_get(props, "cobs." .. name), snapshot.section == "advanced")
      end
      obs.obs_property_set_visible(forget_all, snapshot.section == "advanced")
      return true
    end
    refresh_visibility = visibility
    for _, p in ipairs({ section, platform, custom }) do
      obs.obs_property_set_modified_callback(p, visibility)
    end
    visibility(nil, nil, settings)
    return props
  end
  return self
end
return M
