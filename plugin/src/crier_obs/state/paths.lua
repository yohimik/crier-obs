local ffi = require("ffi")
local M = {}
function M.new(deps)
	deps = deps or {}
	local env = deps.env or {}
	local get = env.getenv or os.getenv
	local platform = env.os or ffi.os
	local root = deps.state_dir
	if not root then
		if platform == "Windows" then
			root = (get("LOCALAPPDATA") or get("APPDATA") or get("USERPROFILE") or ".") .. "\\crier-obs"
		elseif platform == "OSX" then
			root = (get("HOME") or ".") .. "/Library/Application Support/crier-obs"
		else
			root = (get("XDG_STATE_HOME") or ((get("HOME") or ".") .. "/.local/state")) .. "/crier-obs"
		end
	end
	return {
		root = root,
		state = root,
		bin = root .. "/bin",
		runs = root .. "/runs",
		secrets = root .. "/secrets",
		templates = root .. "/templates",
		template = root .. "/templates/live.html",
	}
end
return M
