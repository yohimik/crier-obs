local M = {}
local guidance = "Instagram needs a public URL. ngrok: install it, sign up, run ngrok config add-authtoken <token>, "
guidance = guidance .. "then select ngrok. The free tier interstitial breaks Meta fetching; use a paid plan or zrok. "
guidance = guidance .. "zrok: install it, run zrok invite and zrok enable <token>, then select zrok. "
guidance = guidance .. "S3 is an alternative without a tunnel."

-- Every string the dialog and the status rows show, by key. crier key names and crier's own key
-- descriptions are shown as crier documents them and are not part of this table.
M.strings = {
	["en-US"] = {
		status = "Status",
		posting = "Posting",
		section = "Section",
		platforms = "Platforms",
		custom = "Custom platforms",
		render = "Render",
		video = "Video",
		staging = "Staging",
		advanced = "Advanced",
		install = "Install crier",
		update = "Update crier",
		refresh = "Refresh results",
		check = "Check setup",
		dry_run = "Send a test post (dry run)",
		post = "Post now",
		save = "Save credentials",
		forget = "Forget credentials",
		forget_all = "Forget all credentials in this credential set",
		platform = "Platform to configure",
		custom_platform = "Custom platform to configure",
		guide = "How to get these values",
		custom_guide = "Custom platform guide",
		install_docs = "Install crier documentation",
		staging_guide = "Staging guide",
		tunnel_guide = "Tunnel guide",
		install_ngrok = "Install ngrok",
		install_zrok = "Install zrok",
		tunnel_guidance = guidance,
		-- Status rows: label on the left, state on the right.
		crier_label = "crier",
		keyring_label = "Credential store",
		last_run_label = "Last run",
		logs_label = "Run logs",
		credential_status = "Credential status",
		crier_missing = "crier is not installed",
		keyring_checking = "checking…",
		keyring_state = "%s (%s)",
		no_posts = "No posts yet",
		logs_unknown = "Run logs are stored in the crier-obs state folder",
		state_unavailable = "State folder is unavailable: %s",
		last_run_code = "Last run finished with code %d",
		checking = "checking…",
		saving = "saving…",
		forgetting = "forgetting…",
		not_stored = "not stored",
		not_stored_reason = "not stored: %s",
		stored = "stored ✓",
		stored_unavailable = "stored in keyring (keyring unavailable: %s)",
		-- Posting block.
		post_to = "Post to",
		post_to_platform = "Post every enabled trigger to %s",
		trigger_start = "When streaming starts",
		trigger_end = "When streaming ends",
		trigger_interval = "Every N minutes while live",
		trigger_quit = "When OBS quits while live",
		trigger_rec_start = "When recording starts",
		trigger_rec_end = "When recording ends",
		trigger_replay = "When a replay is saved",
		trigger_caption = "%s: caption",
		trigger_usage = "Post when this happens, with the caption below",
		caption_usage = "Caption for this trigger; {{ .title }}, {{ .uptime }} and the other data document fields work",
		field_custom_names = "Custom platform names",
		field_interval_minutes = "Interval in minutes",
		field_title = "Stream title",
		field_game = "Game",
		field_url = "Stream URL",
		field_custom_fields = "Custom data fields (key=value)",
		field_base_config = "Base configuration file",
		field_crier_path = "crier path override",
		field_credential_set = "Credential set",
		field_timeout = "Run timeout in seconds",
		field_retention_days = "Keep run folders for days",
		field_retention_count = "Maximum run folders",
		field_debug = "Debug logging",
		field_manual_caption = "Manual caption",
		field_section = "Section",
		field_platform = "Platform to configure",
		field_custom_platform = "Custom platform to configure",
		button_usage = "%s",
		link_usage = "Opens %s",
	},
}
function M.new(locale)
	local strings = M.strings[locale] or M.strings["en-US"]
	return function(key, ...)
		local s = strings[key] or M.strings["en-US"][key] or key
		if select("#", ...) > 0 then
			return string.format(s, ...)
		end
		return s
	end
end
M.t = M.new("en-US")
return M
