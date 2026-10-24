local descriptors = require("crier_obs.schema.descriptor")
local layout = require("crier_obs.schema.layout")
local models = require("crier_obs.settings.model")
local stores = require("crier_obs.settings.store")
local i18n = require("crier_obs.i18n")
local meta = require("crier_obs.registry.meta")
local M = {}
local TRIGGERS = { "start", "end", "interval", "quit", "rec_start", "rec_end", "replay" }
local ADVANCED_FIELDS = { "base_config", "crier_path", "credential_set", "debug", "timeout", "retention_days", "retention_count" }
local POSTING_FIELDS = { "title", "game", "url", "custom_fields" }
local RESULT_ROWS = 32
local function field(key)
	for _, f in ipairs(models.fields) do
		if f.key == key then
			return f
		end
	end
end
-- Staging shows the tunnel keys first: they are what Instagram users need.
local function staging_rank(d)
	if d.key == "stage.mode" then
		return 1
	elseif d.key:match("^stage%.server%.tunnel%.") then
		return 2
	end
	return 3
end
-- Descriptors in the order the dialog shows them, section by section. Within Platforms each platform's
-- keys are followed by its guide link; the shared publish.* keys come after every platform.
local function ordered(list)
	local rank = {}
	for i, section in ipairs(layout.sections) do
		rank[section] = i
	end
	local position = {}
	for i, d in ipairs(list) do
		position[d] = i
	end
	local out = {}
	for _, d in ipairs(list) do
		out[#out + 1] = d
	end
	table.sort(out, function(a, b)
		if a.section ~= b.section then
			return (rank[a.section] or 99) < (rank[b.section] or 99)
		end
		if a.section == "platforms" and (a.platform or "~") ~= (b.platform or "~") then
			return (a.platform or "~") < (b.platform or "~")
		end
		if a.section == "staging" and staging_rank(a) ~= staging_rank(b) then
			return staging_rank(a) < staging_rank(b)
		end
		return position[a] < position[b]
	end)
	return out
end
function M.new(deps)
	local obs = assert(deps.obs)
	local store = deps.store or stores.new(deps)
	local model = deps.model or models.new({ obs = obs, store = store })
	local t = deps.translate or i18n.new(obs.obs_get_locale())
	local callbacks = deps.callbacks or {}
	local self = {}
	-- OBS keeps every Lua callback registered by script_properties until the script unloads, so every
	-- build reuses the same function objects: one navigator handler, one per button action and key,
	-- and one no-op for link buttons. They reach the latest build through `current`.
	local current
	local handlers = {}
	local function noop()
		return false
	end
	local function read_status()
		return type(deps.status) == "function" and deps.status() or deps.status or {}
	end
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
		-- Value fields have no modified callback: OBS treats a missing one as "no refresh".
		return describe(p, t(d.description or d.label or name))
	end
	local function button(props, name, label, callback)
		return describe(obs.obs_properties_add_button(props, name, t(label), callback), t("button_usage", t(label)))
	end
	local function url(props, name, label, target)
		local p = describe(obs.obs_properties_add_button(props, name, t(label), noop), t("link_usage", target))
		obs.obs_property_button_set_type(p, obs.OBS_BUTTON_URL)
		obs.obs_property_button_set_url(p, target)
		return p
	end
	-- OBS draws an info row as its description on the left and the settings value on the right; with no
	-- value and no long description the description spans the row. A row never repeats its text.
	local function set_row(state, name, text)
		if state.settings then
			obs.obs_data_set_default_string(state.settings, name, text)
		end
	end
	local function info(state, props, name, label, text, kind)
		local p
		if label and state.settings then
			p = obs.obs_properties_add_text(props, name, t(label), obs.OBS_TEXT_INFO)
			set_row(state, name, text)
		else
			p = obs.obs_properties_add_text(props, name, label and (t(label) .. ": " .. text) or text, obs.OBS_TEXT_INFO)
		end
		obs.obs_property_text_set_info_type(p, kind or obs.OBS_TEXT_INFO_NORMAL)
		obs.obs_property_text_set_info_word_wrap(p, true)
		return p
	end
	local function update_row(state, name, label, text)
		local p = obs.obs_properties_get(state.props, name)
		if label and state.settings then
			set_row(state, name, text)
		else
			obs.obs_property_set_description(p, label and (t(label) .. ": " .. text) or text)
		end
		return p
	end
	local function credential_text(status)
		if type(status) ~= "table" then
			return t("not_stored")
		elseif status.state == "stored" then
			return t("stored")
		elseif status.state == "checking" or status.state == "saving" or status.state == "forgetting" then
			return t(status.state)
		elseif status.state == "unavailable" and status.bound then
			return t("stored_unavailable", status.message or "")
		elseif status.message and status.message ~= "" then
			return t("not_stored_reason", status.message)
		end
		return t("not_stored")
	end
	local function row_text(row)
		if row.text then
			return row.text
		end
		local parts = { row.ok == false and "✗" or row.warning and "!" or row.ok and "✓" or "…" }
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
	local function sync_status(state)
		local status = read_status()
		update_row(state, "cobs.status.crier", "crier_label", status.crier or t("crier_missing"))
		update_row(state, "cobs.status.keyring", "keyring_label", status.keyring or t("keyring_checking"))
		update_row(state, "cobs.status.last_run", "last_run_label", status.last_run or t("no_posts"))
		update_row(state, "cobs.status.logs", "logs_label", status.logs or t("logs_unknown"))
		obs.obs_property_text_set_info_type(
			obs.obs_properties_get(state.props, "cobs.status.crier"),
			status.crier_level == "error" and obs.OBS_TEXT_INFO_ERROR
				or status.crier_level == "warning" and obs.OBS_TEXT_INFO_WARNING
				or obs.OBS_TEXT_INFO_NORMAL
		)
		obs.obs_property_set_description(
			obs.obs_properties_get(state.props, "cobs.install"),
			t(status.update_available and "update" or "install")
		)
		for _, d in ipairs(state.list) do
			if d.secret then
				update_row(state, d.key .. ".status", "credential_status", credential_text((status.secrets or {})[d.key]))
			end
		end
		local rows = status.results or {}
		for index = 1, RESULT_ROWS do
			local row = rows[index]
			local name = "cobs.result." .. index
			local p = obs.obs_properties_get(state.props, name)
			obs.obs_property_set_visible(p, row ~= nil)
			if row then
				obs.obs_property_set_description(p, tostring(row.target or t("check")))
				set_row(state, name, row_text(row))
				obs.obs_property_text_set_info_type(
					p,
					row.ok == false and obs.OBS_TEXT_INFO_ERROR
						or row.warning and obs.OBS_TEXT_INFO_WARNING
						or obs.OBS_TEXT_INFO_NORMAL
				)
			end
		end
	end
	local function visible(p, value)
		obs.obs_property_set_visible(p, value)
	end
	local add_descriptor
	-- Custom platforms added or removed while the dialog is open. Their "Post to" box lives in the
	-- Post to group, so it appears there and not at the end of the dialog.
	local function sync_custom(state, snapshot)
		if models.equal(state.custom_names, snapshot.custom_names) then
			return
		end
		local next_list = descriptors.build(snapshot.custom_names)
		local present = {}
		for _, d in ipairs(next_list) do
			present[d.key] = true
		end
		for _, d in ipairs(state.list) do
			if d.custom and not present[d.key] then
				obs.obs_properties_remove_by_name(d.key:match("%.enabled$") and state.post_to or state.props, d.key)
				state.groups[d.key] = nil
			end
		end
		local previous = {}
		for _, d in ipairs(state.list) do
			previous[d.key] = true
		end
		for _, d in ipairs(next_list) do
			if d.custom and not previous[d.key] then
				store.default(state.settings, d.key, d, d.default)
				add_descriptor(state, d)
			end
		end
		obs.obs_property_list_clear(state.custom)
		state.listed = {}
		for _, name in ipairs(snapshot.custom_names) do
			if descriptors.valid_custom(name) and not state.listed[name] then
				obs.obs_property_list_add_string(state.custom, name, name)
				state.listed[name] = true
			end
		end
		state.custom_names = snapshot.custom_names
		state.list = next_list
	end
	local function visibility(data)
		local state = current
		if not state then
			return false
		end
		local snapshot = model.snapshot(data or state.settings)
		sync_custom(state, snapshot)
		sync_status(state)
		for _, d in ipairs(state.list) do
			for _, p in ipairs(state.groups[d.key] or {}) do
				visible(p, layout.visible(d, snapshot))
			end
		end
		for _, extra in ipairs(state.extras) do
			visible(extra.property, extra.visible(snapshot))
		end
		return true
	end
	local function navigator(_, _, data)
		return visibility(data)
	end
	local function handler(action, key)
		local id = action .. "\0" .. (key or "")
		if not handlers[id] then
			handlers[id] = function()
				if callbacks[action] then
					callbacks[action](key)
				end
				visibility(nil)
				return true
			end
		end
		return handlers[id]
	end
	function add_descriptor(state, d)
		if d.platform and d.key:match("%.enabled$") then
			local p = value_property(state.post_to, d.key, { kind = "bool", label = d.platform })
			describe(p, t("post_to_platform", d.platform))
			return
		end
		local props = state.props
		local p = value_property(props, d.key, d)
		state.groups[d.key] = { p }
		if d.secret then
			local group = state.groups[d.key]
			group[#group + 1] = button(props, d.key .. ".save", "save", handler("save_secret", d.key))
			group[#group + 1] = info(state, props, d.key .. ".status", "credential_status", t("checking"))
			group[#group + 1] = button(props, d.key .. ".forget", "forget", handler("forget_secret", d.key))
		end
	end
	local function in_section(name)
		return function(snapshot)
			return snapshot.section == name
		end
	end
	function self.build(settings)
		local values = model.snapshot(settings)
		local props = obs.obs_properties_create()
		local state = {
			props = props,
			settings = settings,
			list = descriptors.build(values.custom_names),
			custom_names = values.custom_names,
			groups = {},
			extras = {},
			listed = {},
		}
		current = state
		local function extra(p, predicate)
			state.extras[#state.extras + 1] = { property = p, visible = predicate }
			return p
		end
		local docs = "https://github.com/yohimik/crier/blob/" .. meta.tag .. "/docs/"
		-- Status
		info(state, props, "cobs.status.crier", "crier_label", t("crier_missing"))
		button(props, "cobs.install", "install", handler("install"))
		url(props, "cobs.install_docs", "install_docs", docs .. "operations/install.md")
		info(state, props, "cobs.status.keyring", "keyring_label", t("keyring_checking"))
		info(state, props, "cobs.status.last_run", "last_run_label", t("no_posts"))
		info(state, props, "cobs.status.logs", "logs_label", t("logs_unknown"))
		-- Posting
		for _, event in ipairs(TRIGGERS) do
			local label = "trigger_" .. event
			describe(
				value_property(props, "cobs.trigger." .. event .. ".enabled", { kind = "bool", label = label }),
				t("trigger_usage")
			)
			describe(
				value_property(
					props,
					"cobs.trigger." .. event .. ".caption",
					{ kind = "string", label = t("trigger_caption", t(label)), multiline = true }
				),
				t("caption_usage")
			)
			if event == "interval" then
				value_property(props, "cobs.interval_minutes", field("interval_minutes"))
			end
		end
		state.post_to = obs.obs_properties_create()
		describe(obs.obs_properties_add_group(props, "cobs.post_to", t("post_to"), obs.OBS_GROUP_NORMAL, state.post_to), t("post_to"))
		for _, custom in ipairs({ false, true }) do
			for _, d in ipairs(state.list) do
				if d.platform and d.key:match("%.enabled$") and (d.custom or false) == custom then
					add_descriptor(state, d)
				end
			end
		end
		for _, key in ipairs(POSTING_FIELDS) do
			value_property(props, "cobs." .. key, field(key))
		end
		button(props, "cobs.check", "check", handler("check"))
		button(props, "cobs.refresh", "refresh", handler("refresh"))
		button(props, "cobs.dry_run", "dry_run", handler("dry_run"))
		value_property(props, "cobs.manual_caption", field("manual_caption"))
		button(props, "cobs.post", "post", handler("post"))
		for index = 1, RESULT_ROWS do
			info(state, props, "cobs.result." .. index, "check", "…")
		end
		-- Navigator
		local section = value_property(
			props,
			"cobs.section",
			{ kind = "string", widget = "enum", enum = layout.sections, label = "field_section" }
		)
		local platform = extra(
			value_property(
				props,
				"cobs.platform",
				{ kind = "string", widget = "enum", enum = descriptors.platforms(), label = "field_platform" }
			),
			in_section("platforms")
		)
		local custom_names = {}
		for _, name in ipairs(values.custom_names) do
			if descriptors.valid_custom(name) and not state.listed[name] then
				state.listed[name] = true
				custom_names[#custom_names + 1] = name
			end
		end
		extra(value_property(props, "cobs.custom_names", field("custom_names")), in_section("custom"))
		state.custom = extra(
			value_property(
				props,
				"cobs.custom_platform",
				{ kind = "string", widget = "enum", enum = custom_names, label = "field_custom_platform" }
			),
			in_section("custom")
		)
		-- Sections, in dialog order.
		local list = ordered(state.list)
		local guided = {}
		local function guide_for(name)
			if not guided[name] then
				guided[name] = true
				extra(url(props, "cobs.guide." .. name, "guide", docs .. "publishing/" .. name .. ".md"), function(snapshot)
					return snapshot.section == "platforms" and snapshot.platform == name
				end)
			end
		end
		local staging_guidance = false
		for i, d in ipairs(list) do
			if d.section == "staging" and not staging_guidance then
				staging_guidance = true
				extra(info(state, props, "cobs.tunnel_guidance", nil, t("tunnel_guidance")), in_section("staging"))
				extra(url(props, "cobs.install.ngrok", "install_ngrok", "https://ngrok.com/downloads"), in_section("staging"))
				extra(
					url(props, "cobs.install.zrok", "install_zrok", "https://docs.zrok.io/docs/getting-started/"),
					in_section("staging")
				)
				extra(
					url(props, "cobs.guide.staging", "staging_guide", docs .. "configuration/stage/README.md"),
					in_section("staging")
				)
				extra(url(props, "cobs.guide.tunnels", "tunnel_guide", docs .. "staging/tunnels.md"), in_section("staging"))
			end
			if d.section == "advanced" and not state.advanced then
				state.advanced = true
				for _, key in ipairs(ADVANCED_FIELDS) do
					extra(value_property(props, "cobs." .. key, field(key)), in_section("advanced"))
					if key == "credential_set" then
						extra(button(props, "cobs.forget_all", "forget_all", handler("forget_all")), in_section("advanced"))
					end
				end
			end
			if not (d.platform and d.key:match("%.enabled$")) then
				add_descriptor(state, d)
			end
			local following = list[i + 1]
			if d.section == "platforms" and d.platform and (not following or following.platform ~= d.platform) then
				guide_for(d.platform)
			end
			if d.section == "custom" and (not following or following.section ~= "custom") then
				extra(url(props, "cobs.guide.custom", "custom_guide", docs .. "publishing/custom.md"), in_section("custom"))
				state.custom_guide = true
			end
		end
		if not state.custom_guide then
			extra(url(props, "cobs.guide.custom", "custom_guide", docs .. "publishing/custom.md"), in_section("custom"))
		end
		for _, p in ipairs({ section, platform, state.custom }) do
			obs.obs_property_set_modified_callback(p, navigator)
		end
		visibility(settings)
		return props
	end
	return self
end
return M
