-- Media kinds each built-in platform accepts at the pinned crier tag: the Kinds field of every
-- publisher's Needs() in crier's internal/publish/*.go. Custom platforms declare theirs in
-- publish.custom.<name>.kinds (crier's default is image only).
local M = {}
local image = { "image" }
local image_video = { "image", "video" }
local image_video_gif = { "image", "video", "gif" }
M.kinds = {
	boosty = image,
	discord = image_video_gif,
	facebook = image_video,
	instagram = image_video,
	linkedin = image_video,
	mastodon = image_video_gif,
	reddit = image_video_gif,
	slack = image_video_gif,
	telegram = image_video_gif,
	threads = image_video,
	tiktok = image_video,
	vk = image_video_gif,
	x = image_video_gif,
	youtube = { "video" },
}
local function has(list, kind)
	for _, value in ipairs(list or {}) do
		if type(value) == "string" and value:lower():match("^%s*(.-)%s*$") == kind then
			return true
		end
	end
	return false
end
-- Whether a ticked platform can take a post of this kind, given the dialog's values.
function M.accepts(name, kind, values)
	local builtin = M.kinds[name]
	if builtin then
		return has(builtin, kind)
	end
	local declared = values and values["publish.custom." .. name .. ".kinds"]
	if type(declared) ~= "table" or #declared == 0 then
		declared = image
	end
	return has(declared, kind)
end
return M
