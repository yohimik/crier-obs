local M = {}
-- crier starts a tunnel only with stage.mode server and no stage.server.public-url of its own.
local guidance = "Instagram needs a public URL. For a tunnel, first set Stage mode (stage.mode) to server and "
guidance = guidance .. "leave stage.server.public-url empty. ngrok: install it, sign up, run ngrok config "
guidance = guidance .. "add-authtoken <token>, then set stage.server.tunnel.mode to ngrok. The free tier interstitial "
guidance = guidance .. "breaks Meta fetching; use a paid plan or zrok. zrok: install it, run zrok invite and zrok "
guidance = guidance .. "enable <token>, then set stage.server.tunnel.mode to zrok. S3 is an alternative without a "
guidance = guidance .. "tunnel: set Stage mode (stage.mode) to s3 and fill in the stage.s3 settings."
local flatpak_bridge = "Flatpak host bridge requires flatpak-spawn --env-fd support and shared home paths; "
flatpak_bridge = flatpak_bridge .. "Check setup verifies the host command"

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
		-- The crier row: discovery, version check and Install crier. %s is a version, a path, or what
		-- crier, its installer or the operating system reported.
		crier_path_missing = "Configured crier path does not exist",
		crier_checking = "Checking crier version…",
		crier_ready = "crier %s at %s",
		crier_outdated = "crier %s at %s (older than %s)",
		crier_check_failed = "Version check failed",
		crier_check_failed_reason = "Version check failed: %s",
		crier_check_timed_out = "Version check timed out",
		crier_check_cancelled = "Version check cancelled",
		crier_version_unreadable = "Cannot read crier version",
		crier_version_invalid = "Invalid crier version",
		install_running = "Installing crier %s…",
		install_checking = "Checking installed crier…",
		install_failed = "Install failed: %s",
		install_timed_out = "Installation timed out",
		install_exit_failed = "Installation failed",
		install_cancelled = "Installation cancelled because the script unloaded",
		-- The credential store row and the credential status rows.
		keyring_macos = "macOS Keychain",
		keyring_windows = "Windows DPAPI (current user)",
		keyring_linux = "Secret Service",
		keyring_file = "Encrypted credential file",
		keyring_file_fallback = "%s (Secret Service unavailable)",
		keyring_unusable = "The %s cannot be used: %s",
		keyring_unavailable = "Credential store unavailable",
		credential_invalid_account = "Invalid credential set or key",
		credential_index_corrupted = "Credential index is corrupted",
		credential_service_closed = "Credential service is closed",
		credential_empty = "Enter a credential before saving",
		credential_backend_locked = "Stored credential backend is unavailable; unlock or restore it",
		credential_backend_unsaved = "Stored credential backend is unavailable; restore it before saving",
		credential_backend_unavailable = "Stored credential backend is unavailable",
		credential_missing = "Stored credential is missing; re-enter it",
		credential_not_saved = "Credential could not be saved",
		credential_unverified = "Credential verification failed; it was not saved",
		-- The last run row: how crier's run ended.
		exit_0 = "Posted successfully",
		exit_1 = "Invalid configuration",
		exit_2 = "Invalid command arguments",
		exit_3 = "Rendering failed",
		exit_4 = "Some platforms failed",
		exit_5 = "Publishing failed",
		exit_6 = "Staging failed",
		exit_97 = "Run directory is missing",
		exit_126 = "crier is not executable",
		exit_127 = "crier was not found",
		exit_other = "crier exited with code %s",
		exit_signal = "crier stopped by signal %s",
		exit_crashed = "crier crashed (NTSTATUS %s)",
		exit_timeout = "crier exceeded the run timeout",
		run_failed_platforms = "%s (%s)",
		post_failed = "Post failed: %s",
		post_base_changed = "Base configuration changed after destination checks; post skipped",
		post_journal_failed = "Cannot journal the running post",
		-- Check setup result rows: a mark, then what was checked and what it reported.
		result_ok = "✓",
		result_failed = "✗",
		result_warning = "!",
		result_pending = "…",
		result_ms = "%s ms",
		target_crier = "crier",
		target_keyring = "keyring",
		target_stage = "stage",
		target_ffmpeg = "ffmpeg",
		target_tunnel = "tunnel",
		target_config = "config",
		target_platforms = "platforms",
		target_ping = "ping",
		target_setup = "setup",
		target_snap = "snap",
		target_flatpak = "flatpak",
		check_staging_disabled = "Staging is not enabled",
		check_stage_no_credentials = "This staging mode has no credentials to check",
		check_not_found = "Cannot find %s",
		check_base_changed = "Base configuration changed while it was being checked",
		check_failed_code = "Check failed with code %s",
		check_tunnel_needs_server = "The %s tunnel starts only when Stage mode (stage.mode) is server",
		sandbox_snap = "Snap may isolate host tools and credential services; use a native OBS package",
		sandbox_flatpak_missing = "Flatpak host access is unavailable: flatpak-spawn is missing; use a native OBS package",
		sandbox_flatpak_bridge = flatpak_bridge,
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
-- A message the dialog shows, kept as its key and arguments so the dialog renders it in the OBS
-- locale while logs and error tables keep the English text. An argument is a plain value shown as
-- it is (a path, a version, crier's output, an operating system error) or another message.
function M.message(key, ...)
	return { key = key, n = select("#", ...), ... }
end
function M.render(t, value)
	if type(value) ~= "table" or value.key == nil then
		return value
	end
	local args = {}
	for i = 1, value.n do
		args[i] = M.render(t, value[i])
	end
	return t(value.key, unpack(args, 1, value.n))
end
-- Sets object[field] (English, for logs and errors) and object[field .. "_text"] (for the dialog).
function M.set(object, field, key, ...)
	local text = M.message(key, ...)
	object[field], object[field .. "_text"] = M.render(M.t, text), text
	return object
end
function M.with(object, key, ...)
	return M.set(object, "message", key, ...)
end
-- What the dialog shows for object[field]: the message kept in object[field .. "_text"] when there
-- is one, otherwise the plain value.
function M.shown(t, object, field)
	field = field or "message"
	local text = object[field .. "_text"]
	if text ~= nil then
		return M.render(t, text)
	end
	return object[field]
end
-- An error or status as an argument for another message: its message when it has one.
function M.of(object)
	return object.message_text or object.message
end
return M
