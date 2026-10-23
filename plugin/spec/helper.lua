jit.off()
require("luacov")
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.-)spec/helper.lua$") or ""
package.path = root .. "src/?.lua;" .. root .. "src/?/init.lua;" .. root .. "spec/?.lua;" .. package.path
package.preload.obslua = function()
  return require("stub.obslua")
end

return function(busted)
  busted.api.after_each(function()
    require("stub.obslua").assert_no_leaks()
  end)
  return true
end
