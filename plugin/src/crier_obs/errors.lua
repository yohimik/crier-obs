local i18n = require("crier_obs.i18n")
local M = {}
function M.new(kind, message, hint)
	return { kind = kind, message = message, hint = hint }
end
-- crier's documented exit codes; i18n names each one exit_<code> for the last run row.
local codes = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }
codes[97], codes[126], codes[127] = true, true, true
-- message is English for the log, message_text what the last run row shows; the hint is only logged.
function M.from_exit(code, signal)
	if signal then
		return i18n.with(M.new("signal"), "exit_signal", tostring(signal))
	end
	if code and code >= 0x80000000 then
		return i18n.with(M.new("crashed"), "exit_crashed", string.format("0x%08x", code))
	end
	local err = M.new(
		code == 0 and "ok" or "exit",
		nil,
		code == 126 and "On macOS, check the downloaded binary’s quarantine attribute." or nil
	)
	if codes[code] then
		return i18n.with(err, "exit_" .. code)
	end
	return i18n.with(err, "exit_other", tostring(code))
end
function M.timeout()
	return i18n.with(M.new("timeout"), "exit_timeout")
end
return M
