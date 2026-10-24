-- Presentation only: registry defaults remain the source of crier semantics.
local M = {
	["render.format"] = { enum = { "png", "jpeg" } },
	["render.width"] = { min = 0, max = 10000, step = 1 },
	["render.height"] = { min = 0, max = 10000, step = 1 },
	["render.scale"] = { min = 0.01, max = 4, step = 0.01 },
	["render.pages-max"] = { min = 1, max = 20, step = 1 },
	["render.media-type"] = { enum = { "screen", "print" } },
	["render.video.format"] = { enum = { "mp4", "gif" } },
	["render.video.codec-preset"] = { enum = { "h264", "h265", "vp9", "none" } },
	["render.video.frames-input"] = { directory = true },
	["publish.reddit.kind"] = { enum = { "auto", "image", "video", "link" } },
	["publish.youtube.privacy-status"] = { enum = { "private", "unlisted", "public" } },
	["publish.boosty.access"] = { enum = { "free", "paid", "level" } },
	["render.jpeg-quality"] = { min = 1, max = 100, step = 1 },
	["render.video.fps"] = { min = 1, max = 240, step = 1 },
	["stage.mode"] = { enum = { "none", "server", "s3", "url" } },
	["stage.server.tunnel.mode"] = { enum = { "none", "ngrok", "zrok", "custom" } },
	["log.level"] = { enum = { "trace", "debug", "info", "warn", "error" } },
	["log.format"] = { enum = { "console", "json" } },
}
function M.for_key(d)
	local out = {}
	if d.kind == "int" then
		out.min = 0
		out.max = 2147483647
		out.step = 1
	end
	if d.kind == "float" then
		out.min = 0
		out.max = 1e9
		out.step = 0.01
	end
	if d.custom and d.key:match("%.format$") then
		out.enum = { "png", "jpeg" }
	end
	if d.key:match("%.fit$") then
		out.enum = { "none", "cover", "contain", "stretch" }
	end
	if d.kind == "duration" or d.key:match("timeout$") then
		out.widget = "duration"
	end
	if d.path then
		out.filter = "All files (*.*)"
	end
	for k, v in pairs(M[d.key] or {}) do
		out[k] = v
	end
	return out
end
return M
