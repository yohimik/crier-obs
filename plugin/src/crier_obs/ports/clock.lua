local M = {}
function M.new(deps)
	local obs = assert(deps.obs)
	return {
		now_wall = function()
			return os.time()
		end,
		now_mono = function()
			return tonumber(obs.os_gettime_ns()) / 1e9
		end,
	}
end
return M
