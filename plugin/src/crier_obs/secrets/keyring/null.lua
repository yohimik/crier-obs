local i18n = require("crier_obs.i18n")
local M = {}
-- deps.reason / deps.reason_text: why no store is usable, in English and as a dialog message.
function M.new(deps)
	local self = { name = "null" }
	local function unavailable(_, callback)
		local err = { kind = "unavailable", message = deps.reason, message_text = deps.reason_text }
		if not err.message then
			i18n.with(err, "keyring_unavailable")
		end
		callback(nil, err)
	end
	self.lookup, self.forget, self.exists = unavailable, unavailable, unavailable
	function self.store(_, _, callback)
		unavailable(nil, callback)
	end
	function self.tick() end
	function self.close() end
	return self
end
return M
