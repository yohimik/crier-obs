local M = {}
function M.new(deps)
  local self = {name = 'null'}
  local function unavailable(_, callback) callback(nil, {kind = 'unavailable', message = deps.reason or 'Credential store unavailable'}) end
  self.lookup, self.forget = unavailable, unavailable
  function self.store(_, _, callback) unavailable(nil, callback) end
  function self.tick() end
  return self
end
return M
