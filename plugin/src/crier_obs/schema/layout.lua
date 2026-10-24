local M = {}
M.sections = { "platforms", "custom", "render", "video", "staging", "advanced" }
function M.visible(d, settings)
	local section = settings.section or "platforms"
	if d.section ~= section then
		return false
	end
	if section == "platforms" then
		return not d.platform or d.platform == (settings.platform or "telegram")
	end
	if section == "custom" then
		return d.platform == settings.custom_platform
	end
	return true
end
return M
